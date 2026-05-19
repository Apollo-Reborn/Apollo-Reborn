#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloState.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloUserProfileCache.h"

// Mirrors the profile-banner pattern in ApolloUserAvatars.xm exactly:
// - Only hooks `_TtC6Apollo19PostsViewController`.
// - Wraps `tableView.tableHeaderView` -- our header view sits above the
//   native Apollo header content in a wrapper UIView, which becomes the
//   new tableHeaderView.
// - No scroll fighting. No force-top, no setContentOffset hook, no pinning.
//   Apollo's tableview runs untouched.
// - Subreddit-name detection requires either a real ivar/property on the
//   controller or a slug-shaped navigation title; we never match by
//   class-name substring so global search-results VCs don't get a header.

static CGFloat const ApolloSubredditBannerHeight = 120.0;
static CGFloat const ApolloSubredditIconDiameter = 72.0;
static CGFloat const ApolloSubredditHeaderBottomPadding = 16.0;
static CGFloat const ApolloSubredditSidePadding = 20.0;
static CGFloat const ApolloSubredditAboutMaxHeight = 180.0;
static CGFloat const ApolloSubredditTopSpacing = 10.0;

static const void *kApolloSubredditHeaderViewKey = &kApolloSubredditHeaderViewKey;
static const void *kApolloSubredditWrappedHeaderKey = &kApolloSubredditWrappedHeaderKey;
static const void *kApolloSubredditOriginalHeaderKey = &kApolloSubredditOriginalHeaderKey;
static const void *kApolloSubredditNameKey = &kApolloSubredditNameKey;
static const void *kApolloSubredditWrapperMarkerKey = &kApolloSubredditWrapperMarkerKey;
// Set on the UITableView itself so our hooks can fast-path out for every
// scrollview/tableview in the app except the few we actually patched.
static const void *kApolloSubredditManagedTableKey = &kApolloSubredditManagedTableKey;
// Strong ref to our header view stored on the table -- used by the
// setTableHeaderView hook to re-wrap on the fly without needing a VC lookup.
static const void *kApolloSubredditTableManagedHeaderKey = &kApolloSubredditTableManagedHeaderKey;
// Guard so the setTableHeaderView re-wrap can call %orig without recursing.
static const void *kApolloSubredditRewrapInProgressKey = &kApolloSubredditRewrapInProgressKey;
// Weak-ish ownership path back to the live PostsViewController; used so the
// table hook can keep controller/bookkeeping aligned when Apollo swaps the
// native header during search transitions.
static const void *kApolloSubredditManagedViewControllerKey = &kApolloSubredditManagedViewControllerKey;

@interface ApolloSubredditHeaderView : UIView
@property(nonatomic, strong) UIImageView *bannerImageView;
@property(nonatomic, strong) UIImageView *iconImageView;
@property(nonatomic, strong) UILabel *displayNameLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *aboutLabel;
@property(nonatomic, weak) UIViewController *hostViewController;
@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic, copy) void (^heightInvalidationBlock)(void);
- (void)applyInfo:(ApolloSubredditInfo *)info fallbackSubredditName:(NSString *)subredditName;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

@interface ApolloSubredditHeaderWrapperView : UIView
@property(nonatomic, strong) ApolloSubredditHeaderView *apolloHeaderView;
@property(nonatomic, strong) UIView *apolloOriginalHeaderView;
@end

static void ApolloSubredditLoadImages(ApolloSubredditHeaderView *header, NSString *subredditName, BOOL forceRefresh);
static void ApolloSubredditLayoutWrappedHeader(UIView *wrappedHeader,
                                               ApolloSubredditHeaderView *header,
                                               UIView *originalHeader,
                                               CGFloat width);
static void ApolloSubredditSyncAssociations(UITableView *tableView,
                                            UIViewController *viewController,
                                            ApolloSubredditHeaderView *header,
                                            UIView *wrappedHeader,
                                            UIView *originalHeader);
static void ApolloSubredditInstallOrUpdateHeader(UIViewController *viewController);
static void ApolloSubredditTearDownHeader(UIViewController *viewController, BOOL restoreNativeHeader);
static void ApolloSubredditScheduleRepairPasses(UIViewController *viewController, NSString *reason);

@implementation ApolloSubredditHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        _bannerImageView = [[UIImageView alloc] init];
        _bannerImageView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.12];
        _bannerImageView.contentMode = UIViewContentModeScaleAspectFill;
        _bannerImageView.clipsToBounds = YES;
        [self addSubview:_bannerImageView];

        _iconImageView = [[UIImageView alloc] init];
        _iconImageView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.15];
        _iconImageView.contentMode = UIViewContentModeScaleAspectFill;
        _iconImageView.clipsToBounds = YES;
        [self addSubview:_iconImageView];

        _displayNameLabel = [[UILabel alloc] init];
        _displayNameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _displayNameLabel.textColor = [UIColor labelColor];
        _displayNameLabel.numberOfLines = 2;
        _displayNameLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_displayNameLabel];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _nameLabel.textColor = [UIColor secondaryLabelColor];
        _nameLabel.numberOfLines = 1;
        _nameLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_nameLabel];

        _aboutLabel = [[UILabel alloc] init];
        _aboutLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _aboutLabel.textColor = [UIColor labelColor];
        _aboutLabel.numberOfLines = 0;
        _aboutLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_aboutLabel];
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.displayNameLabel.textColor = [UIColor labelColor];
    self.nameLabel.textColor = [UIColor secondaryLabelColor];
    self.aboutLabel.textColor = [UIColor labelColor];
}

- (CGFloat)apollo_aboutHeightForWidth:(CGFloat)width {
    if (self.aboutLabel.hidden || self.aboutLabel.text.length == 0 || width <= 0.0) return 0.0;
    CGRect rect = [self.aboutLabel.text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                  attributes:@{NSFontAttributeName: self.aboutLabel.font}
                                                     context:nil];
    return MIN(ApolloSubredditAboutMaxHeight, MAX(18.0, ceil(rect.size.height)));
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    CGFloat bannerBottom = ApolloSubredditTopSpacing + ApolloSubredditBannerHeight;
    CGFloat iconBottom = bannerBottom - 20.0 + ApolloSubredditIconDiameter;
    CGFloat nameTop = bannerBottom + 12.0;
    CGFloat aboutY = MAX(iconBottom + 12.0, nameTop + 46.0);
    CGFloat aboutWidth = MAX(120.0, width - ApolloSubredditSidePadding * 2.0);
    CGFloat aboutHeight = [self apollo_aboutHeightForWidth:aboutWidth];
    if (aboutHeight <= 0.0) return aboutY + ApolloSubredditHeaderBottomPadding;
    return aboutY + aboutHeight + ApolloSubredditHeaderBottomPadding;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    NSArray<UIView *> *expectedSubviews = @[self.bannerImageView, self.iconImageView,
                                            self.displayNameLabel, self.nameLabel,
                                            self.aboutLabel];
    for (UIView *subview in expectedSubviews) {
        if (subview && subview.superview != self) {
            [self addSubview:subview];
        }
    }
    self.bannerImageView.hidden = NO;
    self.iconImageView.hidden = NO;
    self.displayNameLabel.hidden = self.displayNameLabel.text.length == 0;
    self.nameLabel.hidden = self.nameLabel.text.length == 0;
    self.aboutLabel.hidden = self.aboutLabel.text.length == 0;
    self.bannerImageView.alpha = 1.0;
    self.iconImageView.alpha = 1.0;
    self.displayNameLabel.alpha = 1.0;
    self.nameLabel.alpha = 1.0;
    self.aboutLabel.alpha = 1.0;

    CGFloat width = self.bounds.size.width;
    CGFloat bannerY = ApolloSubredditTopSpacing;
    CGFloat bannerBottom = bannerY + ApolloSubredditBannerHeight;
    self.bannerImageView.frame = CGRectMake(0.0, bannerY, width, ApolloSubredditBannerHeight);

    CGRect iconFrame = CGRectMake(ApolloSubredditSidePadding, bannerBottom - 20.0, ApolloSubredditIconDiameter, ApolloSubredditIconDiameter);
    self.iconImageView.frame = iconFrame;
    self.iconImageView.layer.cornerRadius = ApolloSubredditIconDiameter / 2.0;

    CGFloat textX = CGRectGetMaxX(iconFrame) + 14.0;
    CGFloat textWidth = MAX(80.0, width - textX - ApolloSubredditSidePadding);
    self.displayNameLabel.frame = CGRectMake(textX, bannerBottom + 12.0, textWidth, 24.0);
    self.nameLabel.frame = CGRectMake(textX, CGRectGetMaxY(self.displayNameLabel.frame) + 2.0, textWidth, 18.0);

    CGFloat aboutY = MAX(CGRectGetMaxY(iconFrame) + 12.0, CGRectGetMaxY(self.nameLabel.frame) + 10.0);
    CGFloat aboutWidth = MAX(120.0, width - ApolloSubredditSidePadding * 2.0);
    CGFloat aboutHeight = [self apollo_aboutHeightForWidth:aboutWidth];
    self.aboutLabel.frame = CGRectMake(ApolloSubredditSidePadding, aboutY, aboutWidth, aboutHeight);
}

- (void)applyInfo:(ApolloSubredditInfo *)info fallbackSubredditName:(NSString *)subredditName {
    NSString *displayName = info.displayName.length > 0 ? info.displayName : [@"r/" stringByAppendingString:subredditName ?: @""];
    self.displayNameLabel.text = displayName.length > 0 ? displayName : nil;
    self.nameLabel.text = subredditName.length > 0 ? [@"r/" stringByAppendingString:subredditName] : nil;
    if ([self.displayNameLabel.text isEqualToString:self.nameLabel.text]) self.nameLabel.text = nil;
    self.aboutLabel.text = info.aboutText.length > 0 ? info.aboutText : nil;

    self.displayNameLabel.hidden = self.displayNameLabel.text.length == 0;
    self.nameLabel.hidden = self.nameLabel.text.length == 0;
    self.aboutLabel.hidden = self.aboutLabel.text.length == 0;
    [self setNeedsLayout];
    if (self.heightInvalidationBlock) self.heightInvalidationBlock();
}

// Safety net: if Apollo removes us from a marked wrapper, re-attach on the
// next turn once the wrapper finishes its own teardown/rebuild work.
- (void)willMoveToSuperview:(UIView *)newSuperview {
    UIView *previousSuperview = self.superview;
    BOOL leavingWrapper = (newSuperview == nil)
        && previousSuperview != nil
        && [objc_getAssociatedObject(previousSuperview, kApolloSubredditWrapperMarkerKey) boolValue];
    [super willMoveToSuperview:newSuperview];
    if (!leavingWrapper || !sShowSubredditHeaders) return;

    __weak typeof(self) weakSelf = self;
    __weak UIView *weakWrapper = previousSuperview;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        UIView *strongWrapper = weakWrapper;
        if (!strongSelf || !strongWrapper) return;
        if (strongSelf.superview != nil) return;
        if (![objc_getAssociatedObject(strongWrapper, kApolloSubredditWrapperMarkerKey) boolValue]) return;
        [strongWrapper addSubview:strongSelf];
        UIView *originalHeader = objc_getAssociatedObject(strongWrapper, kApolloSubredditOriginalHeaderKey);
        CGFloat width = strongWrapper.bounds.size.width > 0
            ? strongWrapper.bounds.size.width
            : UIScreen.mainScreen.bounds.size.width;
        ApolloSubredditLayoutWrappedHeader(strongWrapper, strongSelf, originalHeader, width);
        strongSelf.hidden = NO;
        strongSelf.alpha = 1.0;
    });
}

@end

@implementation ApolloSubredditHeaderWrapperView

- (void)layoutSubviews {
    [super layoutSubviews];

    ApolloSubredditHeaderView *header = self.apolloHeaderView;
    UIView *originalHeader = self.apolloOriginalHeaderView;
    if (!header) return;

    if (header.superview != self) {
        [self addSubview:header];
    }
    if (originalHeader && originalHeader.superview != self) {
        [self addSubview:originalHeader];
    }

    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    ApolloSubredditLayoutWrappedHeader(self, header, originalHeader, width);
    self.hidden = NO;
    self.alpha = 1.0;
    header.hidden = NO;
    header.alpha = 1.0;
}

@end

#pragma mark - Helpers

static NSString *ApolloNormalizedSubredditName(NSString *subredditName) {
    if (![subredditName isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"] || [clean hasPrefix:@"/R/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"] || [clean hasPrefix:@"R/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    // Reject special feeds that aren't really single subreddits.
    NSArray<NSString *> *blocked = @[@"home", @"popular", @"all", @"search", @"profile",
                                     @"settings", @"inbox", @"friends", @"mod"];
    if ([blocked containsObject:clean.lowercaseString]) return nil;
    // Must look like a subreddit slug: letters/digits/underscores.
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    if ([clean rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return clean;
}

static id ApolloSubredditObjectIvarValue(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static NSString *ApolloSubredditNameFromModelObject(id object) {
    if (!object) return nil;

    NSArray<NSString *> *selectors = @[@"subreddit", @"subredditName", @"displayNamePrefixed", @"displayName", @"name"];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![object respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:[NSString class]]) {
            NSString *name = ApolloNormalizedSubredditName(value);
            if (name.length > 0) return name;
        }
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        for (NSString *key in @[@"subreddit", @"display_name", @"display_name_prefixed", @"name"]) {
            NSString *name = ApolloNormalizedSubredditName(dict[key]);
            if (name.length > 0) return name;
        }
    }
    return nil;
}

// No class-name substring fallback (that was bug #3). We rely on either a
// concrete ivar on the controller, or the navigation title. Apollo sets the
// title to the bare subreddit slug (e.g. "googlepixel"), not "r/googlepixel",
// so we accept either format. The normalizer's blocklist + slug validation
// rejects special feeds (Home/All/Popular) and multireddits ("foo+bar").
// Search results VCs are a different class and never reach this hook.
static NSString *ApolloSubredditNameFromViewController(UIViewController *viewController) {
    if (!viewController) return nil;

    NSArray<NSString *> *preferredIvars = @[@"currentSubreddit", @"selectedSubreddit", @"postSubreddit",
                                            @"subreddit", @"subredditName", @"community",
                                            @"source", @"listing", @"collection"];
    for (NSString *ivarName in preferredIvars) {
        id value = ApolloSubredditObjectIvarValue(viewController, ivarName);
        if (!value) continue;
        if ([value isKindOfClass:[NSString class]]) {
            NSString *name = ApolloNormalizedSubredditName(value);
            if (name.length > 0) return name;
        }
        NSString *name = ApolloSubredditNameFromModelObject(value);
        if (name.length > 0) return name;
    }

    NSString *title = viewController.navigationItem.title ?: viewController.title;
    return ApolloNormalizedSubredditName(title);
}

static UIView *ApolloSubredditFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = ApolloSubredditFindSubviewOfClass(subview, cls);
        if (match) return match;
    }
    return nil;
}

static UITableView *ApolloSubredditFindTableView(UIViewController *viewController) {
    if ([viewController respondsToSelector:@selector(tableView)]) {
        UITableView *(*msgSend)(id, SEL) = (UITableView *(*)(id, SEL))objc_msgSend;
        id tableView = msgSend(viewController, @selector(tableView));
        if ([tableView isKindOfClass:[UITableView class]]) return tableView;
    }
    return (UITableView *)ApolloSubredditFindSubviewOfClass(viewController.view, [UITableView class]);
}

static UIImage *ApolloSubredditPlaceholderIcon(void) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(ApolloSubredditIconDiameter, ApolloSubredditIconDiameter)];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [[UIColor secondarySystemFillColor] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.0, 0.0, ApolloSubredditIconDiameter, ApolloSubredditIconDiameter)] fill];
    }];
}

static ApolloSubredditHeaderView *ApolloSubredditCreateHeader(CGFloat width) {
    ApolloSubredditHeaderView *header = [[ApolloSubredditHeaderView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 210.0)];
    header.iconImageView.image = ApolloSubredditPlaceholderIcon();
    return header;
}

static void ApolloSubredditLoadImages(ApolloSubredditHeaderView *header, NSString *subredditName, BOOL forceRefresh) {
    if (!header || subredditName.length == 0) return;

    ApolloSubredditInfoCache *cache = [ApolloSubredditInfoCache sharedCache];
    ApolloUserProfileCache *imageCache = [ApolloUserProfileCache sharedCache];
    ApolloSubredditInfo *cachedInfo = [cache cachedInfoForSubreddit:subredditName];

    void (^applyInfo)(ApolloSubredditInfo *) = ^(ApolloSubredditInfo *info) {
        if (!info) return;
        [header applyInfo:info fallbackSubredditName:subredditName];

        if (info.iconURL) {
            UIImage *icon = [imageCache cachedImageForURL:info.iconURL];
            if (icon) {
                header.iconImageView.image = icon;
            } else {
                [imageCache requestImageForURL:info.iconURL completion:^(UIImage *image) {
                    if (image) header.iconImageView.image = image;
                }];
            }
        }
        if (info.bannerURL) {
            UIImage *banner = [imageCache cachedImageForURL:info.bannerURL];
            if (banner) {
                header.bannerImageView.image = banner;
            } else {
                [imageCache requestImageForURL:info.bannerURL completion:^(UIImage *image) {
                    if (image) header.bannerImageView.image = image;
                }];
            }
        }
    };

    if (cachedInfo) applyInfo(cachedInfo);
    if (forceRefresh) {
        [cache refetchInfoForSubreddit:subredditName completion:applyInfo];
    } else {
        [cache requestInfoForSubreddit:subredditName completion:applyInfo];
    }
}

static void ApolloSubredditLayoutWrappedHeader(UIView *wrappedHeader,
                                               ApolloSubredditHeaderView *header,
                                               UIView *originalHeader,
                                               CGFloat width) {
    CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
    CGFloat headerHeight = [header preferredHeightForWidth:width];
    wrappedHeader.frame = CGRectMake(0.0, 0.0, width, headerHeight + originalHeight);
    header.frame = CGRectMake(0.0, 0.0, width, headerHeight);
    if (originalHeader) originalHeader.frame = CGRectMake(0.0, headerHeight, width, originalHeight);
}

static UIView *ApolloSubredditBuildWrapper(ApolloSubredditHeaderView *header,
                                           UIView *originalHeader,
                                           CGFloat width) {
    if (!header) return nil;
    CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
    CGFloat headerHeight = [header preferredHeightForWidth:width];
    ApolloSubredditHeaderWrapperView *wrapper = [[ApolloSubredditHeaderWrapperView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, headerHeight + originalHeight)];
    wrapper.backgroundColor = [UIColor clearColor];
    wrapper.apolloHeaderView = header;
    wrapper.apolloOriginalHeaderView = originalHeader;
    [wrapper addSubview:header];
    if (originalHeader) [wrapper addSubview:originalHeader];
    ApolloSubredditLayoutWrappedHeader(wrapper, header, originalHeader, width);
    objc_setAssociatedObject(wrapper, kApolloSubredditWrapperMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(wrapper, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(wrapper, kApolloSubredditOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    header.hidden = NO;
    header.alpha = 1.0;
    wrapper.hidden = NO;
    wrapper.alpha = 1.0;
    return wrapper;
}

static void ApolloSubredditSyncAssociations(UITableView *tableView,
                                            UIViewController *viewController,
                                            ApolloSubredditHeaderView *header,
                                            UIView *wrappedHeader,
                                            UIView *originalHeader) {
    if (tableView) {
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, wrappedHeader ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, viewController, OBJC_ASSOCIATION_ASSIGN);
    }
    if (viewController) {
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, wrappedHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloSubredditTearDownHeader(UIViewController *viewController, BOOL restoreNativeHeader) {
    if (!viewController) return;

    UITableView *tableView = ApolloSubredditFindTableView(viewController);
    ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    UIView *wrappedHeader = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey);

    if (tableView && restoreNativeHeader && wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tableView.tableHeaderView = originalHeader;
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (header.superview == wrappedHeader) {
        [header removeFromSuperview];
    }
    if (originalHeader.superview == wrappedHeader) {
        [originalHeader removeFromSuperview];
    }

    if (tableView) {
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);

}

static void ApolloSubredditScheduleRepairPasses(UIViewController *viewController, NSString *reason) {
    if (!viewController || !sShowSubredditHeaders) return;

    NSArray<NSNumber *> *delays = @[@0.0, @0.08, @0.20, @0.45];
    __weak UIViewController *weakViewController = viewController;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongViewController = weakViewController;
            if (!strongViewController || !sShowSubredditHeaders) return;
            ApolloSubredditInstallOrUpdateHeader(strongViewController);
        });
    }
}

#pragma mark - Install / restore

static void ApolloSubredditInstallOrUpdateHeader(UIViewController *viewController) {
    if (!viewController) return;
    // Only install on Apollo's PostsViewController. The notification-refresh
    // walker previously trampled across RedditListVC / InboxListVC /
    // ApolloNavigationController because their nav titles happened to be
    // slug-shaped ("Subreddits" / "Boxes" / "Comments").
    static Class postsVCClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        postsVCClass = NSClassFromString(@"_TtC6Apollo19PostsViewController");
    });
    if (postsVCClass && ![viewController isKindOfClass:postsVCClass]) return;

    UITableView *tableView = ApolloSubredditFindTableView(viewController);
    if (!tableView) return;

    ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    UIView *wrappedHeader = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey);

    // Auto-repair: if Apollo's close-search teardown removed any of our
    // internal subviews from the header, put them back.
    if (header) {
        BOOL repairedInner = NO;
        NSArray<UIView *> *expected = @[header.bannerImageView, header.iconImageView,
                                        header.displayNameLabel, header.nameLabel,
                                        header.aboutLabel];
        for (UIView *child in expected) {
            if (child && child.superview != header) {
                [header addSubview:child];
                repairedInner = YES;
            }
            if (child && child.hidden && child != header.aboutLabel && child != header.nameLabel) {
                if (child == header.bannerImageView || child == header.iconImageView || child == header.displayNameLabel) {
                    child.hidden = NO;
                    repairedInner = YES;
                }
            }
        }
        if (repairedInner) {
            [header setNeedsLayout];
            [header layoutIfNeeded];
        }
    }

    // Setting off -> restore the native tableHeaderView and drop our state.
    if (!sShowSubredditHeaders) {
        if (wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
            tableView.tableHeaderView = originalHeader;
        }
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    NSString *subredditName = ApolloSubredditNameFromViewController(viewController);
    if (subredditName.length == 0) return;

    CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    if (!header) {
        header = ApolloSubredditCreateHeader(width);
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Recover bookkeeping from the wrapper itself in case the VC's associated
    // objects fell out of sync (e.g. after a memory warning).
    UIView *currentTableHeader = tableView.tableHeaderView;
    if (currentTableHeader && objc_getAssociatedObject(currentTableHeader, kApolloSubredditWrapperMarkerKey)) {
        wrappedHeader = currentTableHeader;
        header = objc_getAssociatedObject(currentTableHeader, kApolloSubredditHeaderViewKey) ?: header;
        originalHeader = objc_getAssociatedObject(currentTableHeader, kApolloSubredditOriginalHeaderKey);
        ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);
    }

    header.hostViewController = viewController;
    header.subredditName = subredditName;
    __weak UIViewController *weakViewController = viewController;
    header.heightInvalidationBlock = ^{
        UIViewController *strongViewController = weakViewController;
        if (strongViewController) ApolloSubredditInstallOrUpdateHeader(strongViewController);
    };

    if (!wrappedHeader || tableView.tableHeaderView != wrappedHeader) {
        originalHeader = currentTableHeader;
        // Re-wrapping during install: ensure setTableHeaderView hook treats
        // this as our own write (no double-wrap recursion).
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        wrappedHeader = ApolloSubredditBuildWrapper(header, originalHeader, width);
        ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);
        tableView.tableHeaderView = wrappedHeader;
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        BOOL repaired = NO;
        if (header.superview != wrappedHeader) {
            [wrappedHeader addSubview:header];
            repaired = YES;
        }
        if (originalHeader && originalHeader.superview == nil) {
            [wrappedHeader addSubview:originalHeader];
            repaired = YES;
        }

        CGRect frameBeforeLayout = wrappedHeader.frame;
        ApolloSubredditLayoutWrappedHeader(wrappedHeader, header, originalHeader, width);
        if (repaired || !CGRectEqualToRect(frameBeforeLayout, wrappedHeader.frame)) {
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tableView.tableHeaderView = wrappedHeader;
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    // Force-unhide every install pass in case Apollo's search-mode UI hides
    // tableHeaderView subviews to clear the chrome (this is the
    // "search-then-return shows empty space" failure mode).
    header.hidden = NO;
    header.alpha = 1.0;
    if (wrappedHeader) {
        wrappedHeader.hidden = NO;
        wrappedHeader.alpha = 1.0;
    }

    // Mark the table itself so our setTableHeaderView / setContentOffset hooks
    // can fast-path out for every other table in the app.
    ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);

    NSString *storedSubredditName = objc_getAssociatedObject(viewController, kApolloSubredditNameKey);
    if (![storedSubredditName isEqualToString:subredditName]) {
        objc_setAssociatedObject(viewController, kApolloSubredditNameKey, subredditName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        header.iconImageView.image = ApolloSubredditPlaceholderIcon();
        header.bannerImageView.image = nil;
        [header applyInfo:nil fallbackSubredditName:subredditName];
        ApolloSubredditLoadImages(header, subredditName, NO);
    }
}

static void ApolloSubredditRefreshViewControllersInTree(UIViewController *viewController, NSHashTable *visited) {
    if (!viewController || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    if (objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey) ||
        ApolloSubredditNameFromViewController(viewController).length > 0) {
        ApolloSubredditInstallOrUpdateHeader(viewController);
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloSubredditRefreshViewControllersInTree(child, visited);
    }
    if (viewController.presentedViewController) {
        ApolloSubredditRefreshViewControllersInTree(viewController.presentedViewController, visited);
    }
}

static void ApolloSubredditRefreshVisibleControllers(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            ApolloSubredditRefreshViewControllersInTree(window.rootViewController, visited);
        }
    });
}

#pragma mark - Hooks

// Apollo enters/exits search mode by mutating its tableHeaderView (sometimes
// replacing it with a different view, sometimes hiding subviews). The
// setTableHeaderView hook below re-wraps any view Apollo tries to install so
// our header view is always part of the live tableHeaderView. The
// force-unhide in install handles the subview-hiding case.
//
// Apollo also auto-scrolls past tableHeaderView once posts finish loading.
// The setContentOffset hooks block ONLY a scroll whose target Y exactly
// matches tableHeaderView.frame.size.height (within a few px), which is
// Apollo's specific "skip my header" signature. Search-mode scrolls and
// every other programmatic scroll have different targets and pass through.

%hook UITableView

- (void)setTableHeaderView:(UIView *)tableHeaderView {
    if (![objc_getAssociatedObject(self, kApolloSubredditManagedTableKey) boolValue]) {
        %orig;
        return;
    }
    if ([objc_getAssociatedObject(self, kApolloSubredditRewrapInProgressKey) boolValue]) {
        %orig;
        return;
    }
    // Already our wrapper -- nothing to do.
    if (tableHeaderView && objc_getAssociatedObject(tableHeaderView, kApolloSubredditWrapperMarkerKey)) {
        %orig;
        return;
    }
    ApolloSubredditHeaderView *ourHeader = objc_getAssociatedObject(self, kApolloSubredditTableManagedHeaderKey);
    if (!ourHeader || !sShowSubredditHeaders) {
        %orig;
        return;
    }

    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    UIView *wrapper = ApolloSubredditBuildWrapper(ourHeader, tableHeaderView, width);
    UIViewController *viewController = ourHeader.hostViewController;
    ApolloSubredditSyncAssociations(self, viewController, ourHeader, wrapper, tableHeaderView);
    %orig(wrapper);
    if (viewController) {
        ApolloSubredditScheduleRepairPasses(viewController, @"setTableHeaderView");
    }
}

- (void)layoutSubviews {
    %orig;
}
- (void)reloadData {
    %orig;
    if (![objc_getAssociatedObject(self, kApolloSubredditManagedTableKey) boolValue]) return;
    UIViewController *viewController = objc_getAssociatedObject(self, kApolloSubredditManagedViewControllerKey);
    if (viewController) {
        ApolloSubredditScheduleRepairPasses(viewController, @"reloadData");
    }
}

%end

static BOOL ApolloSubredditShouldBlockOffset(UITableView *tableView, CGPoint newOffset) {
    if (![objc_getAssociatedObject(tableView, kApolloSubredditManagedTableKey) boolValue]) return NO;
    UIView *header = tableView.tableHeaderView;
    if (!header || !objc_getAssociatedObject(header, kApolloSubredditWrapperMarkerKey)) return NO;
    if (tableView.tracking || tableView.dragging || tableView.decelerating) return NO;

    CGFloat topY = -tableView.adjustedContentInset.top;
    BOOL atTop = (tableView.contentOffset.y - topY) <= 0.5;
    if (!atTop) return NO;
    CGFloat headerHeight = header.frame.size.height;
    CGFloat targetDelta = newOffset.y - topY;
    // Apollo's "scroll past my own tableHeaderView" call targets the exact
    // bottom of tableHeaderView. Other programmatic scrolls (search mode,
    // scroll-to-row, scroll-to-top) target different positions.
    return fabs(targetDelta - headerHeight) < 5.0;
}

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    if ([self isKindOfClass:[UITableView class]] &&
        ApolloSubredditShouldBlockOffset((UITableView *)self, contentOffset)) {
        return;
    }
    %orig;
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    if ([self isKindOfClass:[UITableView class]] &&
        ApolloSubredditShouldBlockOffset((UITableView *)self, contentOffset)) {
        return;
    }
    %orig;
}

%end

%hook UISearchController

- (void)setActive:(BOOL)active {
    BOOL wasActive = self.active;
    %orig(active);
    if (wasActive && !active && sShowSubredditHeaders) {
        ApolloSubredditRefreshVisibleControllers();
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloSubredditRefreshVisibleControllers();
        });
    }
}

%end

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLoad {
    %orig;
    ApolloSubredditInstallOrUpdateHeader((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloSubredditInstallOrUpdateHeader((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloSubredditInstallOrUpdateHeader((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloSubredditInstallOrUpdateHeader((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    BOOL movingFromParent = [(UIViewController *)self isMovingFromParentViewController];
    BOOL beingDismissed = [(UIViewController *)self isBeingDismissed];
    %orig(animated);
    if (movingFromParent || beingDismissed) {
        ApolloSubredditTearDownHeader((UIViewController *)self, YES);
    }
}

%end

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloSubredditHeaderToggleChangedNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditInfoUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];
}
