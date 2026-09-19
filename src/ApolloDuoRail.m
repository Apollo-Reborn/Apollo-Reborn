#import "ApolloDuoRail.h"
#import "ApolloDuoRailLayout.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDeviceDisplay.h"
#import "ApolloDeviceGeometry.h"
#import "ApolloFeedSplitLayout.h"
#import "ApolloThemeRuntime.h"

// One Duo chrome path. Open Duo (wide landscape UIWindow) is a
// reserved leading 112pt sidebar and hides UITabBar. Closed Duo
// (portrait-sized Duo window) is Phone-like: stock bottom tab bar,
// no Apollo side rail. Regular iPhone stays on the stock tab bar.
// Selected item uses the theme accent (blue on stock) as a rounded
// pill. FeedSplit tiling stays off. Per-cell RedditList Tighten is
// a no-op except a hang-safe Closed star frame nudge (unused while
// Closed has no rail).
//
// Mode keys off UIWindow.bounds (never UIScreen.mainScreen). First
// show defaults to Subs: stock popToRoot onto RedditList. Navigation
// reuses Apollo's own tab selectors and RedditList row 0 (Home),
// plus apollo://reddit.com/r/popular|all.

typedef NS_ENUM(NSInteger, ApolloDuoRailItem) {
    ApolloDuoRailItemSubreddits = 0,
    ApolloDuoRailItemHome,
    ApolloDuoRailItemPopular,
    ApolloDuoRailItemAll,
    ApolloDuoRailItemProfile,
    ApolloDuoRailItemSettings,
    ApolloDuoRailItemCount,
};

static const char *kApolloDuoRailTitles[] = {
    "Posts/Subs", "Home", "Popular", "All", "Profile", "Settings",
};
static const char *kApolloDuoRailSymbols[] = {
    "list.bullet", "house", "flame", "globe", "person", "gearshape",
};

static char kApolloDuoRailViewKey;
static char kApolloDuoRailActiveKey;
static char kApolloDuoRailModeKey;
static char kApolloDuoRailSelectedKey;
static char kApolloDuoRailSavedContentInsetLeftKey;
static char kApolloDuoRailSavedPreferredSizeKey;
static char kApolloDuoRailSavedAdditionalLeftKey;
static char kApolloDuoRailSavedSeparatorRightKey;
static char kApolloDuoRailRowLeadingClaimedKey;
static char kApolloDuoRailRowDisabledConstraintsKey;
static BOOL sApolloDuoRailPickingSubreddits = NO;
static BOOL sApolloDuoRailOpenedDefaultDirectory = NO;

BOOL ApolloDuoRailIsPickingSubreddits(void) {
    return sApolloDuoRailPickingSubreddits;
}

void ApolloDuoRailSetPickingSubreddits(BOOL picking) {
    if (sApolloDuoRailPickingSubreddits == picking) return;
    sApolloDuoRailPickingSubreddits = picking;
    ApolloLog(@"[DuoRail] My Subreddits picking=%d", picking ? 1 : 0);
}

static UINavigationController *ApolloDuoRailNavFromController(UIViewController *controller) {
    if ([controller isKindOfClass:[UINavigationController class]]) {
        return (UINavigationController *)controller;
    }
    if ([controller.navigationController isKindOfClass:[UINavigationController class]]) {
        return controller.navigationController;
    }
    return nil;
}

// Posts tab without goToHomeTab — that selector pops to RedditList / opens
// Home and would wipe a restored directory (or race a feed push that
// re-dismisses RedditList while picking is YES).
static UINavigationController *ApolloDuoRailFindPostsNav(UITabBarController *tabs, BOOL selectTab) {
    if (!tabs) return nil;
    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    Class apolloNav = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    UINavigationController *best = nil;
    for (UIViewController *child in tabs.viewControllers) {
        UINavigationController *nav = ApolloDuoRailNavFromController(child);
        if (!nav) continue;
        BOOL looksPosts = NO;
        for (UIViewController *vc in nav.viewControllers) {
            if ((listClass && [vc isKindOfClass:listClass])
                || (postsClass && [vc isKindOfClass:postsClass])) {
                looksPosts = YES;
                break;
            }
        }
        if (looksPosts) {
            best = nav;
            break;
        }
        if (!best && apolloNav && [nav isKindOfClass:apolloNav]) {
            best = nav;
        }
    }
    if (!best && tabs.viewControllers.count > 0) {
        best = ApolloDuoRailNavFromController(tabs.viewControllers.firstObject);
    }
    if (selectTab && best && tabs.selectedViewController != best
        && [tabs.viewControllers containsObject:best]) {
        tabs.selectedViewController = best;
    }
    return best;
}

static UINavigationController *ApolloDuoRailPostsNav(UITabBarController *tabs) {
    if (!tabs) return nil;
    if ([tabs respondsToSelector:@selector(goToHomeTab)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToHomeTab));
        } @catch (NSException *exception) {
            ApolloLog(@"[DuoRail] goToHomeTab threw: %@", exception);
        }
    }
    return ApolloDuoRailNavFromController(tabs.selectedViewController)
        ?: ApolloDuoRailFindPostsNav(tabs, NO);
}

static BOOL ApolloDuoRailOpenListRow(UINavigationController *nav, NSInteger row) {
    if (!nav) return NO;
    [nav popToRootViewControllerAnimated:NO];
    UIViewController *root = nav.viewControllers.firstObject;
    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    if (!listClass || ![root isKindOfClass:listClass]) {
        ApolloLog(@"[DuoRail] Posts root is not RedditListViewController (%@)", root);
        return NO;
    }
    if (!root.isViewLoaded) [root loadViewIfNeeded];
    UITableView *tableView = nil;
    if ([root respondsToSelector:@selector(tableView)]) {
        @try {
            tableView = ((UITableView *(*)(id, SEL))objc_msgSend)(root, @selector(tableView));
        } @catch (NSException *exception) {
            ApolloLog(@"[DuoRail] tableView read failed: %@", exception);
        }
    }
    if (![root respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(root, @selector(tableView:didSelectRowAtIndexPath:), tableView, path);
        return YES;
    } @catch (NSException *exception) {
        ApolloLog(@"[DuoRail] didSelectRow failed: %@", exception);
        return NO;
    }
}

static void ApolloDuoRailPerformItem(ApolloDuoRailItem item) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[DuoRail] no tab bar controller yet");
        return;
    }
    objc_setAssociatedObject(tabs, &kApolloDuoRailSelectedKey, @(item), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (item == ApolloDuoRailItemProfile) {
        ApolloDuoRailSetPickingSubreddits(NO);
        if ([tabs respondsToSelector:@selector(goToProfileTab)]) {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToProfileTab));
        }
        return;
    }
    if (item == ApolloDuoRailItemSettings) {
        ApolloDuoRailSetPickingSubreddits(NO);
        if ([tabs respondsToSelector:@selector(goToSettingsTab)]) {
            ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToSettingsTab));
        }
        return;
    }

    if (item == ApolloDuoRailItemSubreddits) {
        UINavigationController *nav = ApolloDuoRailFindPostsNav(tabs, YES);
        ApolloFeedSplitShowSubredditPicker(nav);
        return;
    }
    UINavigationController *nav = ApolloDuoRailPostsNav(tabs);
    ApolloDuoRailSetPickingSubreddits(NO);
    if (item == ApolloDuoRailItemHome) {
        if (ApolloDuoRailOpenListRow(nav, 0)) {
            ApolloLog(@"[DuoRail] opened Home feed");
        }
        return;
    }

    NSURL *url = nil;
    if (item == ApolloDuoRailItemPopular) {
        url = [NSURL URLWithString:@"apollo://reddit.com/r/popular"];
    } else if (item == ApolloDuoRailItemAll) {
        url = [NSURL URLWithString:@"apollo://reddit.com/r/all"];
    }
    if (url && ApolloRouteURLThroughApp(url)) {
        ApolloLog(@"[DuoRail] routed %@", url.absoluteString);
        return;
    }
    ApolloLog(@"[DuoRail] URL route failed for item %ld", (long)item);
}

@interface ApolloDuoRailButton : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation ApolloDuoRailButton

- (instancetype)initWithItem:(ApolloDuoRailItem)item {
    self = [super initWithFrame:CGRectZero];
    if (!self) return self;
    self.tag = item;
    self.isAccessibilityElement = YES;
    NSString *title = [NSString stringWithUTF8String:kApolloDuoRailTitles[item]];
    self.accessibilityLabel = (item == ApolloDuoRailItemSubreddits) ? @"Posts / Subreddits" : title;
    self.accessibilityTraits = UIAccessibilityTraitButton;

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightMedium];
        self.iconView.image = [UIImage systemImageNamed:[NSString stringWithUTF8String:kApolloDuoRailSymbols[item]]
                                      withConfiguration:config];
    }
    [self addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = title;
    self.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.72;
    [self addSubview:self.titleLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat icon = 20.0;
    CGFloat iconY = 8.0;
    self.iconView.frame = CGRectMake((width - icon) * 0.5, iconY, icon, icon);
    self.titleLabel.frame = CGRectMake(3.0, iconY + icon + 4.0, width - 6.0, MAX(13.0, height - iconY - icon - 8.0));
}

- (void)apollo_applyForeground:(UIColor *)color selected:(BOOL)selected fill:(UIColor *)fill {
    self.backgroundColor = selected ? fill : UIColor.clearColor;
    self.iconView.tintColor = color;
    self.titleLabel.textColor = color;
    self.titleLabel.font = selected
        ? [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold]
        : [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    self.layer.cornerRadius = 16.0;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }
    self.accessibilityTraits = selected
        ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected)
        : UIAccessibilityTraitButton;
}

@end

@interface ApolloDuoRailView : UIView
@property (nonatomic, copy) NSArray<ApolloDuoRailButton *> *buttons;
@property (nonatomic, strong) UIView *separatorView;
@property (nonatomic, assign) ApolloDuoRailItem selectedItem;
@property (nonatomic, assign) BOOL leading;
- (void)apollo_applyTheme;
- (void)apollo_setSelectedItem:(ApolloDuoRailItem)item;
@end

@implementation ApolloDuoRailView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;
    self.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    self.accessibilityTraits = UIAccessibilityTraitTabBar;

    NSMutableArray<ApolloDuoRailButton *> *buttons = [NSMutableArray arrayWithCapacity:ApolloDuoRailItemCount];
    for (NSInteger i = 0; i < ApolloDuoRailItemCount; i++) {
        ApolloDuoRailButton *button = [[ApolloDuoRailButton alloc] initWithItem:(ApolloDuoRailItem)i];
        [button addTarget:self action:@selector(apollo_tapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:button];
        [buttons addObject:button];
    }
    self.buttons = buttons;
    self.separatorView = [[UIView alloc] initWithFrame:CGRectZero];
    self.separatorView.userInteractionEnabled = NO;
    [self addSubview:self.separatorView];
    self.selectedItem = ApolloDuoRailItemSubreddits;
    self.leading = YES;
    [self apollo_applyTheme];
    return self;
}

- (void)apollo_tapped:(ApolloDuoRailButton *)sender {
    ApolloDuoRailItem item = (ApolloDuoRailItem)sender.tag;
    [self apollo_setSelectedItem:item];
    ApolloDuoRailPerformItem(item);
}

- (void)apollo_setSelectedItem:(ApolloDuoRailItem)item {
    self.selectedItem = item;
    [self apollo_applyTheme];
}

- (void)apollo_applyTheme {
    UIColor *page = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
    UIColor *muted = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel) ?: UIColor.secondaryLabelColor;
    self.backgroundColor = page;
    self.separatorView.backgroundColor = ApolloThemeSeparatorColor()
        ?: (UIColor.separatorColor ?: [UIColor colorWithWhite:0.0 alpha:0.08]);
    UIColor *onAccent = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
    for (ApolloDuoRailButton *button in self.buttons) {
        BOOL selected = button.tag == (NSInteger)self.selectedItem;
        [button apollo_applyForeground:(selected ? onAccent : muted) selected:selected fill:accent];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Frame already starts at safe.top + 8. Keep Profile / Settings
    // docked to the bottom; the four feed items stay a compact stack.
    CGFloat top = 10.0;
    CGFloat bottom = 10.0;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat usable = height - top - bottom;
    if (usable < 1.0) return;

    NSInteger count = (NSInteger)self.buttons.count;
    CGFloat itemHeight = MIN(62.0, usable / (CGFloat)count);
    CGFloat y = top;
    for (NSInteger i = 0; i < count; i++) {
        UIView *button = self.buttons[(NSUInteger)i];
        if (i == ApolloDuoRailItemProfile) {
            CGFloat remaining = height - bottom - (itemHeight * 2.0);
            if (remaining > y) y = remaining;
        }
        button.frame = CGRectMake(7.0, y, width - 14.0, itemHeight - 6.0);
        y += itemHeight;
    }
    CGFloat hairline = 1.0 / MAX(self.window.screen.scale, 1.0);
    CGFloat separatorX = self.leading ? (width - hairline) : 0.0;
    self.separatorView.frame = CGRectMake(separatorX, 0.0, hairline, height);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self apollo_applyTheme];
}

@end

static BOOL ApolloDuoRailDualDisplays(void) {
    NSMutableArray<NSValue *> *sizes = [NSMutableArray array];
    for (UIScreen *screen in [UIScreen screens]) {
        CGSize size = screen.bounds.size;
        if (size.width <= 0.0 || size.height <= 0.0) continue;
        BOOL seen = NO;
        for (NSValue *value in sizes) {
            CGSize existing = value.CGSizeValue;
            if (fabs(existing.width - size.width) < 1.0 && fabs(existing.height - size.height) < 1.0) {
                seen = YES;
                break;
            }
        }
        if (!seen) [sizes addObject:[NSValue valueWithCGSize:size]];
    }
    if (sizes.count < 2) return NO;
    CGSize a = sizes[0].CGSizeValue;
    CGSize b = sizes[1].CGSizeValue;
    return ApolloDisplayScreensAreDual(a.width, a.height, b.width, b.height);
}

static int ApolloDuoRailModeForTabs(UITabBarController *tabs) {
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) {
        return ApolloDuoModePhone;
    }
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return ApolloDuoModePhone;
    }
    UIWindow *window = tabs.view.window ?: ApolloDeviceAppWindow();
    return ApolloDuoModeFromWindow(window, ApolloDuoRailDualDisplays() ? 1 : 0);
}

static int ApolloDuoRailCurrentMode(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    NSNumber *stored = objc_getAssociatedObject(tabs, &kApolloDuoRailModeKey);
    if (stored) return stored.intValue;
    return ApolloDuoRailModeForTabs(tabs);
}

static BOOL ApolloDuoRailIsLeading(void) {
    return ApolloDuoModeIsLeading(ApolloDuoRailCurrentMode());
}

static void ApolloDuoRailSetTabBarHidden(UITabBarController *tabs, BOOL hidden) {
    if (!tabs) return;
    SEL setter = @selector(setTabBarHidden:animated:);
    if ([tabs respondsToSelector:setter]) {
        ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(tabs, setter, hidden, NO);
    } else {
        tabs.tabBar.hidden = hidden;
    }
    for (UIView *subview in tabs.view.subviews) {
        const char *name = class_getName(subview.class);
        if (name && strstr(name, "TabContainer")) {
            subview.hidden = hidden;
        }
    }
}

// Launch / first rail show: Subs selected, stock RedditList (no tile).
static void ApolloDuoRailOpenDefaultDirectory(UITabBarController *tabs) {
    UINavigationController *nav = ApolloDuoRailFindPostsNav(tabs, YES);
    objc_setAssociatedObject(tabs, &kApolloDuoRailSelectedKey,
                             @(ApolloDuoRailItemSubreddits), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoRailView *rail = objc_getAssociatedObject(tabs, &kApolloDuoRailViewKey);
    [rail apollo_setSelectedItem:ApolloDuoRailItemSubreddits];
    ApolloFeedSplitShowSubredditPicker(nav);
    ApolloLog(@"[DuoRail] default Subs stock directory");
}

// Window/scene chrome only. The tab view's safeAreaInsets include our
// additionalSafeAreaInsets and would walk the rail if used for x.
static UIEdgeInsets ApolloDuoRailSystemSafeInsets(UITabBarController *tabs) {
    UIWindow *window = tabs.view.window;
    if (window) return window.safeAreaInsets;
    UIEdgeInsets viewSafe = tabs.view.safeAreaInsets;
    UIEdgeInsets extra = tabs.additionalSafeAreaInsets;
    return UIEdgeInsetsMake(MAX(0.0, viewSafe.top - extra.top),
                            MAX(0.0, viewSafe.left - extra.left),
                            MAX(0.0, viewSafe.bottom - extra.bottom),
                            MAX(0.0, viewSafe.right - extra.right));
}

CGFloat ApolloDuoRailSectionIndexTrailingForTable(UITableView *tableView) {
    if (!ApolloDuoRailIsActive() || !tableView) return 0.0;
    return (CGFloat)ApolloDuoRailSectionIndexTrailingForMode(ApolloDuoRailCurrentMode());
}

void ApolloDuoRailPinSectionIndex(UITableView *tableView) {
    if (!ApolloDuoRailIsActive() || !tableView) return;
    if (tableView.cellLayoutMarginsFollowReadableWidth) {
        tableView.cellLayoutMarginsFollowReadableWidth = NO;
    }
    CGFloat trailing = ApolloDuoRailSectionIndexTrailingForTable(tableView);
    if (trailing < 1.0) return;
    CGFloat wantMaxX = CGRectGetWidth(tableView.bounds) - trailing;
    for (UIView *subview in tableView.subviews) {
        const char *name = class_getName(subview.class);
        if (!name || !strstr(name, "TableViewIndex")) continue;
        CGRect frame = subview.frame;
        CGFloat maxX = CGRectGetMaxX(frame);
        if (fabs(maxX - wantMaxX) < 0.5) continue;
        frame.origin.x = wantMaxX - CGRectGetWidth(frame);
        if (frame.origin.x < 0.0) frame.origin.x = 0.0;
        subview.frame = frame;
    }
}

static void ApolloDuoWalkViewControllers(UIViewController *root, void (^block)(UIViewController *controller)) {
    if (!root || !block) return;
    block(root);
    for (UIViewController *child in root.childViewControllers) {
        ApolloDuoWalkViewControllers(child, block);
    }
    UIViewController *presented = root.presentedViewController;
    if (presented && presented.presentingViewController == root) {
        ApolloDuoWalkViewControllers(presented, block);
    }
}

static void ApolloDuoApplyInsetsToController(UIViewController *controller,
                                             CGFloat wantLeft,
                                             CGFloat wantBottom,
                                             CGFloat wantRight) {
    if (!controller) return;
    UIEdgeInsets current = controller.additionalSafeAreaInsets;
    if (fabs(current.left - wantLeft) < 0.5
        && fabs(current.right - wantRight) < 0.5
        && fabs(current.bottom - wantBottom) < 0.5) {
        return;
    }
    controller.additionalSafeAreaInsets = UIEdgeInsetsMake(current.top, wantLeft, wantBottom, wantRight);
}

// Show: only the tab controller and its tab-root navs get the leading
// content inset. Pushed content is frame-shifted instead so headers
// and Texture feeds clear the rail without stacking another inset.
static void ApolloDuoApplyChromeInsets(UITabBarController *tabs,
                                       CGFloat wantLeft,
                                       CGFloat wantBottom,
                                       CGFloat wantRight) {
    ApolloDuoApplyInsetsToController(tabs, wantLeft, wantBottom, wantRight);
    for (UIViewController *child in tabs.viewControllers) {
        ApolloDuoApplyInsetsToController(child, wantLeft, wantBottom, wantRight);
    }
}

// Hide / Compact / portrait: zero the leading inset on the whole
// presented tree so a leftover 68pt (or a -68 cancel) cannot leave a
// white strip beside the ActionFigures feed.
static void ApolloDuoClearLeadingChromeInsets(UITabBarController *tabs,
                                              CGFloat wantBottom,
                                              CGFloat wantRight) {
    ApolloDuoWalkViewControllers(tabs, ^(UIViewController *controller) {
        ApolloDuoApplyInsetsToController(controller, 0.0, wantBottom, wantRight);
        objc_setAssociatedObject(controller, &kApolloDuoRailSavedAdditionalLeftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static BOOL ApolloDuoCoverShouldApplyForTabs(UITabBarController *tabs) {
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return NO;
    if (tabs.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) return NO;
    return ApolloDuoCoverChromeShouldApply(0, ApolloDuoRailDualDisplays() ? 1 : 0);
}

BOOL ApolloDuoCoverChromeIsActive(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    return ApolloDuoCoverShouldApplyForTabs(tabs);
}

static BOOL ApolloDuoCoverClassLooksLikeComments(Class cls) {
    const char *name = class_getName(cls);
    return name && strstr(name, "CommentsViewController");
}

static UIView *ApolloDuoCoverFindJumpButton(UIViewController *comments) {
    Ivar ivar = class_getInstanceVariable(comments.class, "commentJumpButton");
    UIView *button = ivar ? object_getIvar(comments, ivar) : nil;
    if ([button isKindOfClass:[UIView class]]) return button;

    UIView *root = comments.view;
    if (!root) return nil;
    CGFloat rootW = CGRectGetWidth(root.bounds);
    CGFloat rootH = CGRectGetHeight(root.bounds);
    UIView *best = nil;
    CGFloat bestScore = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 120) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        if (![view isKindOfClass:[UIControl class]]) continue;
        CGFloat w = CGRectGetWidth(view.bounds);
        CGFloat h = CGRectGetHeight(view.bounds);
        if (w < 36.0 || w > 72.0 || h < 36.0 || h > 72.0) continue;
        if (fabs(w - h) > 8.0) continue;
        CGRect inRoot = [root convertRect:view.bounds fromView:view];
        if (CGRectGetMidX(inRoot) < rootW * 0.55) continue;
        if (CGRectGetMidY(inRoot) < rootH * 0.55) continue;
        CGFloat score = CGRectGetMaxX(inRoot) + CGRectGetMaxY(inRoot);
        if (score > bestScore) {
            bestScore = score;
            best = view;
        }
    }
    return best;
}

void ApolloDuoCoverAdjustJumpButton(UIViewController *comments) {
    if (!comments || !ApolloDuoCoverClassLooksLikeComments(comments.class)) return;
    if (!ApolloDuoCoverChromeIsActive() || !comments.isViewLoaded) return;

    UIEdgeInsets current = comments.additionalSafeAreaInsets;
    CGFloat wantRight = (CGFloat)ApolloDuoCoverPillWidth;
    CGFloat wantBottom = (CGFloat)ApolloDuoCoverPillBottom;
    if (fabs(current.right - wantRight) > 0.5 || fabs(current.bottom - wantBottom) > 0.5) {
        comments.additionalSafeAreaInsets = UIEdgeInsetsMake(current.top, current.left,
                                                             wantBottom, wantRight);
    }

    UIView *button = ApolloDuoCoverFindJumpButton(comments);
    if (![button isKindOfClass:[UIView class]] || !button.superview) return;
    UIView *container = button.superview;
    CGRect frame = button.frame;
    CGFloat limitX = CGRectGetWidth(container.bounds) - (CGFloat)ApolloDuoCoverPillWidth;
    CGFloat limitY = CGRectGetHeight(container.bounds) - (CGFloat)ApolloDuoCoverPillBottom;
    BOOL moved = NO;
    if (CGRectGetMaxX(frame) > limitX + 0.5) {
        frame.origin.x -= (CGRectGetMaxX(frame) - limitX);
        moved = YES;
    }
    if (CGRectGetMaxY(frame) > limitY + 0.5) {
        frame.origin.y -= (CGRectGetMaxY(frame) - limitY);
        moved = YES;
    }
    if (frame.origin.x < 0.0) frame.origin.x = 0.0;
    if (frame.origin.y < 0.0) frame.origin.y = 0.0;
    if (moved) button.frame = frame;
}

static UIView *ApolloDuoRailLayoutView(UIViewController *controller, UIView *container) {
    if (!controller.isViewLoaded || !container) return nil;
    UIView *view = controller.view;
    UIView *parent = view.superview;
    if (parent && parent != container && parent.superview == container) {
        return parent;
    }
    return view;
}

static void ApolloDuoRailExpandView(UIView *view, CGRect frame) {
    if (!view || CGRectGetWidth(frame) < 1.0 || CGRectGetHeight(frame) < 1.0) return;
    if (fabs(CGRectGetMinX(view.frame) - CGRectGetMinX(frame)) < 0.5
        && fabs(CGRectGetWidth(view.frame) - CGRectGetWidth(frame)) < 0.5
        && fabs(CGRectGetHeight(view.frame) - CGRectGetHeight(frame)) < 0.5) {
        return;
    }
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.frame = frame;
}

static void ApolloDuoRailInsetHeaderView(UIView *header, CGFloat left) {
    if (!header || left < 1.0) return;
    if ([header isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *hf = (UITableViewHeaderFooterView *)header;
        UIEdgeInsets margins = hf.contentView.layoutMargins;
        if (margins.left < left - 0.5) {
            margins.left = left;
            hf.contentView.layoutMargins = margins;
        }
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:header];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 40) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        if (![view isKindOfClass:[UILabel class]]) continue;
        UILabel *label = (UILabel *)view;
        NSString *text = [label.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0) continue;
        CGRect frame = label.frame;
        if (CGRectGetMinX(frame) + 0.5 >= left) continue;
        frame.origin.x = left;
        frame.size.width = MAX(0.0, CGRectGetWidth(header.bounds) - left - 8.0);
        label.frame = frame;
    }
}

// Closed overlay: stop header titles / hairlines before the rail so
// FAVORITES / MODERATOR / A do not clip. Frame-only; no constraint writes.
static void ApolloDuoRailInsetHeaderViewTrailing(UIView *header, CGFloat trailing) {
    if (!header || trailing < 1.0) return;
    CGFloat limit = CGRectGetWidth(header.bounds) - trailing;
    if (limit < 1.0) return;
    if ([header isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *hf = (UITableViewHeaderFooterView *)header;
        UIEdgeInsets margins = hf.contentView.layoutMargins;
        if (margins.right < trailing - 0.5) {
            margins.right = trailing;
            hf.contentView.layoutMargins = margins;
        }
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:header];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 40) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        CGRect frame = view.frame;
        if (CGRectGetMaxX(frame) <= limit + 0.5) continue;
        BOOL hairline = CGRectGetHeight(frame) <= 2.0 && CGRectGetWidth(frame) + 0.5 >= CGRectGetWidth(header.bounds) * 0.5;
        if (![view isKindOfClass:[UILabel class]] && !hairline) continue;
        frame.size.width = MAX(0.0, limit - CGRectGetMinX(frame));
        if (fabs(frame.size.width - view.frame.size.width) < 0.5) continue;
        view.frame = frame;
    }
}

static void ApolloDuoRailApplySeparatorTrailing(UITableView *tableView, CGFloat trailing) {
    if (!tableView) return;
    UIEdgeInsets inset = tableView.separatorInset;
    NSNumber *saved = objc_getAssociatedObject(tableView, &kApolloDuoRailSavedSeparatorRightKey);
    if (trailing > 0.5) {
        if (!saved) {
            objc_setAssociatedObject(tableView, &kApolloDuoRailSavedSeparatorRightKey,
                                     @(inset.right), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (fabs(inset.right - trailing) > 0.5) {
            inset.right = trailing;
            tableView.separatorInset = inset;
        }
    } else if (saved) {
        inset.right = saved.doubleValue;
        tableView.separatorInset = inset;
        objc_setAssociatedObject(tableView, &kApolloDuoRailSavedSeparatorRightKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIView *ApolloDuoRailFindStarInCell(UITableViewCell *cell) {
    if (!cell) return nil;
    if (cell.accessoryView && !cell.accessoryView.hidden && cell.accessoryView.alpha > 0.05) {
        return cell.accessoryView;
    }
    Class listCell = NSClassFromString(@"_TtC6Apollo23RedditListTableViewCell");
    if (listCell && [cell isMemberOfClass:listCell]) {
        Ivar ivar = class_getInstanceVariable(listCell, "accessoryButton");
        id value = ivar ? object_getIvar(cell, ivar) : nil;
        if ([value isKindOfClass:[UIView class]]) {
            UIView *view = (UIView *)value;
            if (!view.hidden && view.alpha > 0.05) return view;
        }
    }
    UIView *best = nil;
    CGFloat bestX = -CGFLOAT_MAX;
    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    CGFloat searchMinX = cellWidth * 0.40;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:cell];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 48) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];
        }
        if (![candidate isKindOfClass:[UIControl class]] || candidate.hidden || candidate.alpha <= 0.05) {
            continue;
        }
        CGRect inCell = [cell convertRect:candidate.bounds fromView:candidate];
        if (CGRectGetWidth(inCell) > 96.0 || CGRectGetHeight(inCell) > 96.0) continue;
        if (CGRectGetMidX(inCell) < searchMinX) continue;
        if (CGRectGetMidX(inCell) > bestX) {
            best = candidate;
            bestX = CGRectGetMidX(inCell);
        }
    }
    return best;
}

// Hang-safe: one frame write, skip when already at the visible trailing
// edge. No constraint disable, no layoutIfNeeded (25f8a7b hang).
static void ApolloDuoRailAnchorClosedStarInCell(UITableViewCell *cell) {
    if (!cell) return;
    UIView *star = ApolloDuoRailFindStarInCell(cell);
    if (!star || !star.superview) return;
    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    CGFloat wantMaxX = (CGFloat)ApolloDuoRailClosedStarMaxX(cellWidth);
    CGRect inCell = [cell convertRect:star.bounds fromView:star];
    if (!ApolloDuoRailClosedShouldNudgeStar(CGRectGetMaxX(inCell), wantMaxX)) return;
    CGRect inSuperview = [star.superview convertRect:inCell fromView:cell];
    CGFloat delta = wantMaxX - CGRectGetMaxX(inCell);
    inSuperview.origin.x += delta;
    if (inSuperview.origin.x < 0.0) inSuperview.origin.x = 0.0;
    star.frame = inSuperview;
}

static void ApolloDuoRailAnchorClosedStars(UITableView *tableView) {
    if (!tableView || ApolloDuoRailCurrentMode() != ApolloDuoModeClosed) return;
    for (UITableViewCell *cell in tableView.visibleCells) {
        ApolloDuoRailAnchorClosedStarInCell(cell);
    }
}

static CGFloat ApolloDuoRailWindowMinX(UIView *view) {
    if (!view) return 0.0;
    if (view.window) {
        return CGRectGetMinX([view convertRect:view.bounds toView:nil]);
    }
    return CGRectGetMinX(view.frame);
}

static void ApolloDuoRailReleaseLeadingView(UITableViewCell *cell) {
    if (!cell || !objc_getAssociatedObject(cell, &kApolloDuoRailRowLeadingClaimedKey)) return;
    NSArray<NSLayoutConstraint *> *disabled =
        objc_getAssociatedObject(cell, &kApolloDuoRailRowDisabledConstraintsKey);
    for (NSLayoutConstraint *constraint in disabled) {
        if (constraint) constraint.active = YES;
    }
    objc_setAssociatedObject(cell, &kApolloDuoRailRowDisabledConstraintsKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloDuoRailRowLeadingClaimedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void ApolloDuoRailTightenSubredditRow(UITableViewCell *cell) {
    // Aaron reset: per-cell readable / centerX / lead-delta writes hung
    // once (25f8a7b) and still left the wrong layout. Release any
    // leftover claim so a recycled cell cannot keep 25f8a7b/c7f33e0
    // constraint surgery alive. Closed-only: hang-safe star frame
    // nudge to the visible row trailing edge (left of A–Z / overlay).
    if (!cell) return;
    ApolloDuoRailReleaseLeadingView(cell);
    if (ApolloDuoRailIsActive() && ApolloDuoRailCurrentMode() == ApolloDuoModeClosed) {
        ApolloDuoRailAnchorClosedStarInCell(cell);
    }
}

static void ApolloDuoRailApplyScrollInsetLeft(UIScrollView *scrollView, CGFloat left) {
    if (!scrollView) return;
    UIEdgeInsets inset = scrollView.contentInset;
    NSNumber *saved = objc_getAssociatedObject(scrollView, &kApolloDuoRailSavedContentInsetLeftKey);
    if (left > 0.5) {
        if (!saved) {
            objc_setAssociatedObject(scrollView, &kApolloDuoRailSavedContentInsetLeftKey,
                                     @(inset.left), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (fabs(inset.left - left) > 0.5) {
            inset.left = left;
            scrollView.contentInset = inset;
        }
    } else if (saved) {
        inset.left = saved.doubleValue;
        scrollView.contentInset = inset;
        objc_setAssociatedObject(scrollView, &kApolloDuoRailSavedContentInsetLeftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL ApolloDuoRailScrollViewIsTexture(UIScrollView *scrollView) {
    if (!scrollView) return NO;
    const char *name = class_getName(scrollView.class);
    return name && strstr(name, "ASTable");
}

static UIScrollView *ApolloDuoRailFindPrimaryTable(UIView *view, NSInteger depth) {
    if (!view || depth < 0) return nil;
    if ([view isKindOfClass:[UIScrollView class]]
        && ([view isKindOfClass:[UITableView class]] || ApolloDuoRailScrollViewIsTexture((UIScrollView *)view))) {
        return (UIScrollView *)view;
    }
    UIScrollView *best = nil;
    for (UIView *subview in view.subviews) {
        UIScrollView *found = ApolloDuoRailFindPrimaryTable(subview, depth - 1);
        if (!found) continue;
        if (ApolloDuoRailScrollViewIsTexture(found)) return found;
        if (!best) best = found;
    }
    return best;
}

// Shift a full-bleed Texture / UIKit table so its window minX is the
// content inset. No-op when already clear. Frame write (not contentInset)
// is what Texture honors — ASDK cells ignore additionalSafeAreaInsets.
static BOOL ApolloDuoRailShiftScrollViewOffRail(UIScrollView *scrollView) {
    if (!scrollView || !scrollView.superview || !ApolloDuoRailIsActive()) return NO;
    CGFloat inset = (CGFloat)ApolloDuoRailContentLeftInset();
    CGRect frame = scrollView.frame;
    CGRect want = frame;
    if (ApolloDuoRailIsLeading()) {
        CGFloat windowX = ApolloDuoRailWindowMinX(scrollView);
        if (windowX + 0.5 >= inset) return NO;
        CGFloat bump = inset - windowX;
        want.origin.x += bump;
        want.size.width = MAX(0.0, want.size.width - bump);
    } else {
        // Closed overlays the rail. Shrinking the table by ~120pt is
        // the Image 1 crush — leave the scroll view full-bleed.
        return NO;
    }
    if (fabs(want.origin.x - frame.origin.x) < 0.5
        && fabs(want.size.width - frame.size.width) < 0.5) {
        return NO;
    }
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollView.frame = want;
    return YES;
}

void ApolloDuoRailApplyListInsets(UIScrollView *scrollView) {
    if (!scrollView) return;
    BOOL active = ApolloDuoRailIsActive();
    if (active && ApolloDuoRailScrollViewIsTexture(scrollView)) {
        // Texture paints cells to the table bounds, not the safe area.
        // Shift the ASTableView itself so vote chevrons clear the rail.
        ApolloDuoRailShiftScrollViewOffRail(scrollView);
    }
    CGFloat windowX = ApolloDuoRailWindowMinX(scrollView);
    BOOL underRail = active && ApolloDuoRailIsLeading()
        && (windowX + 0.5 < (CGFloat)ApolloDuoRailContentLeftInset());
    // UIKit RedditList cells already honor the nav safe-area inset.
    // Do not stack contentInset.left on those — that was the portrait
    // white strip. Texture got a frame shift above instead.
    ApolloDuoRailApplyScrollInsetLeft(scrollView, 0.0);

    if (![scrollView isKindOfClass:[UITableView class]]) return;
    UITableView *tableView = (UITableView *)scrollView;
    if (!active) {
        ApolloDuoRailApplySeparatorTrailing(tableView, 0.0);
        return;
    }

    if (tableView.cellLayoutMarginsFollowReadableWidth) {
        tableView.cellLayoutMarginsFollowReadableWidth = NO;
    }
    int mode = ApolloDuoRailCurrentMode();
    CGFloat headerLeft = underRail
        ? ((CGFloat)ApolloDuoRailContentLeftInset() - MAX(windowX, 0.0))
        : 0.0;
    CGFloat headerTrailing = (mode == ApolloDuoModeClosed)
        ? (CGFloat)ApolloDuoRailClosedOverlayClearance()
        : 0.0;
    ApolloDuoRailApplySeparatorTrailing(tableView, headerTrailing);
    if (headerLeft > 0.5 || headerTrailing > 0.5) {
        NSInteger sections = tableView.numberOfSections;
        for (NSInteger section = 0; section < sections && section < 24; section++) {
            UIView *header = [tableView headerViewForSection:section];
            if (header && headerLeft > 0.5) ApolloDuoRailInsetHeaderView(header, headerLeft);
            if (header && headerTrailing > 0.5) ApolloDuoRailInsetHeaderViewTrailing(header, headerTrailing);
        }
        for (UIView *subview in tableView.subviews) {
            const char *name = class_getName(subview.class);
            if (name && strstr(name, "Header")) {
                if (headerLeft > 0.5) ApolloDuoRailInsetHeaderView(subview, headerLeft);
                if (headerTrailing > 0.5) ApolloDuoRailInsetHeaderViewTrailing(subview, headerTrailing);
            }
        }
    }
    if (mode == ApolloDuoModeClosed) {
        ApolloDuoRailAnchorClosedStars(tableView);
    }
}

static void ApolloDuoRailFillController(UIViewController *controller, UIView *container) {
    if (!controller || !container || CGRectGetWidth(container.bounds) < 1.0) return;
    if (!controller.isViewLoaded) return;
    CGFloat containerWidth = CGRectGetWidth(container.bounds);
    CGFloat containerHeight = CGRectGetHeight(container.bounds);
    int mode = ApolloDuoRailCurrentMode();
    ApolloDuoRailRect want = ApolloDuoRailContentFrameInBoundsForMode(containerWidth,
                                                                     containerHeight,
                                                                     mode);
    CGRect wantFrame = CGRectMake(want.x, want.y, want.width, want.height);
    BOOL expanded = NO;
    UIView *view = controller.view;
    BOOL texture = NO;
    UIScrollView *existingTable = ApolloDuoRailFindPrimaryTable(view, 5);
    if (existingTable) texture = ApolloDuoRailScrollViewIsTexture(existingTable);
    // Full-bleed UIKit lists (RedditList) stay full-width and use the
    // nav's additionalSafeAreaInsets for cells — a frame shift here is
    // undone on scroll. Only letterboxed phone columns and Texture
    // feeds are moved to the content frame.
    UIView *layout = ApolloDuoRailLayoutView(controller, container);
    BOOL letterboxed = layout
        ? ApolloDuoRailContentIsLetterboxed(layout.frame.size.width, containerWidth)
        : NO;
    BOOL needsClearance = letterboxed || texture;
    if (needsClearance && layout && ApolloDuoModeIsLeading(mode)) {
        needsClearance = ApolloDuoRailContentNeedsLeadingClearance(layout.frame.origin.x,
                                                                  layout.frame.size.width,
                                                                  containerWidth);
    }
    if (layout && layout != container
        && needsClearance) {
        ApolloLog(@"[DuoRail] filled %@ x=%.0f w=%.0f → x=%.0f w=%.0f",
                  NSStringFromClass(controller.class),
                  layout.frame.origin.x, layout.frame.size.width, want.x, want.width);
        ApolloDuoRailExpandView(layout, wantFrame);
        expanded = YES;
    }
    letterboxed = view
        ? ApolloDuoRailContentIsLetterboxed(view.frame.size.width, containerWidth)
        : letterboxed;
    BOOL viewNeedsClearance = letterboxed || texture;
    if (viewNeedsClearance && ApolloDuoModeIsLeading(mode)) {
        viewNeedsClearance = ApolloDuoRailContentNeedsLeadingClearance(view.frame.origin.x,
                                                                      view.frame.size.width,
                                                                      containerWidth);
    }
    if (view && view != layout && view != container
        && viewNeedsClearance) {
        ApolloDuoRailExpandView(view, layout && layout != view ? layout.bounds : wantFrame);
        expanded = YES;
    }
    if (view) {
        CGSize preferred = controller.preferredContentSize;
        if (want.width > 0.5 && preferred.width + (CGFloat)ApolloDuoRailLetterboxGap < want.width) {
            if (!objc_getAssociatedObject(controller, &kApolloDuoRailSavedPreferredSizeKey)) {
                objc_setAssociatedObject(controller, &kApolloDuoRailSavedPreferredSizeKey,
                                         [NSValue valueWithCGSize:preferred],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            controller.preferredContentSize = CGSizeMake((CGFloat)want.width, preferred.height);
        }
    }
    if (controller.isViewLoaded) {
        // Never cancel inherited leading safe-area on UIKit lists. A
        // one-shot table/VC frame shift is undone on scroll, and the
        // leftover additionalSafeAreaInsets.left = -80 was why rows
        // slid under the rail while headers (separate path) stayed put.
        UIEdgeInsets extra = controller.additionalSafeAreaInsets;
        if (extra.left < -0.5) {
            extra.left = 0.0;
            controller.additionalSafeAreaInsets = extra;
        }
        objc_setAssociatedObject(controller, &kApolloDuoRailSavedAdditionalLeftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([controller respondsToSelector:@selector(tableView)]) {
        UIView *table = nil;
        @try {
            table = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        } @catch (__unused NSException *exception) {
            table = nil;
        }
        if ([table isKindOfClass:[UIScrollView class]]) {
            UIView *tableParent = table.superview ?: view;
            CGFloat parentWidth = tableParent ? CGRectGetWidth(tableParent.bounds) : containerWidth;
            CGFloat parentHeight = tableParent ? CGRectGetHeight(tableParent.bounds) : containerHeight;
            BOOL tableTexture = ApolloDuoRailScrollViewIsTexture((UIScrollView *)table);
            BOOL tableLetterboxed = ApolloDuoRailContentIsLetterboxed(table.frame.size.width, parentWidth);
            BOOL tableNeedsClearance = tableTexture || tableLetterboxed;
            if (tableNeedsClearance && ApolloDuoModeIsLeading(mode)) {
                tableNeedsClearance = ApolloDuoRailContentNeedsLeadingClearance(table.frame.origin.x,
                                                                               table.frame.size.width,
                                                                               parentWidth);
            }
            if (tableParent == container
                && tableNeedsClearance) {
                ApolloDuoRailExpandView(table, wantFrame);
                expanded = YES;
            } else if (tableParent != container
                       && tableLetterboxed) {
                table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                table.frame = CGRectMake(0.0, 0.0, parentWidth, parentHeight);
                expanded = YES;
            }
            ApolloDuoRailApplyListInsets((UIScrollView *)table);
        }
    }
    id tableNode = nil;
    Ivar nodeIvar = class_getInstanceVariable(controller.class, "tableNode");
    if (!nodeIvar) nodeIvar = class_getInstanceVariable(controller.class, "_tableNode");
    if (nodeIvar) tableNode = object_getIvar(controller, nodeIvar);
    if (tableNode) {
        UIView *nodeView = nil;
        if ([tableNode respondsToSelector:@selector(view)]) {
            nodeView = ((UIView *(*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
        }
        if ([nodeView isKindOfClass:[UIScrollView class]]) {
            if (ApolloDuoRailShiftScrollViewOffRail((UIScrollView *)nodeView)) {
                expanded = YES;
            }
            ApolloDuoRailApplyListInsets((UIScrollView *)nodeView);
        }
        if (expanded) {
            if ([tableNode respondsToSelector:@selector(setNeedsLayout)]) {
                ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(setNeedsLayout));
            }
            if ([tableNode respondsToSelector:@selector(invalidateCalculatedLayout)]) {
                ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(invalidateCalculatedLayout));
            }
            if ([tableNode respondsToSelector:@selector(relayoutItems)]) {
                ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(relayoutItems));
            }
        }
    }
    UIScrollView *found = ApolloDuoRailFindPrimaryTable(view ?: layout, 5);
    if (found) {
        if (ApolloDuoRailScrollViewIsTexture(found)
            && ApolloDuoRailShiftScrollViewOffRail(found)) {
            expanded = YES;
        }
        ApolloDuoRailApplyListInsets(found);
    }
}

void ApolloDuoRailFillOpenContent(void) {
    if (!ApolloDuoRailIsActive()) return;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return;
    UINavigationController *nav = ApolloDuoRailNavFromController(tabs.selectedViewController);
    if (!nav) nav = ApolloDuoRailFindPostsNav(tabs, NO);
    if (!nav.isViewLoaded) return;
    // Keep the nav (and its bar) full-width so "Subreddits" stays centered.
    UIView *container = nav.view ?: tabs.view;
    UIViewController *top = nav.topViewController;
    if (top) ApolloDuoRailFillController(top, container);
}

static void ApolloDuoRailRestoreController(UIViewController *controller, UIView *container) {
    if (!controller) return;
    NSValue *savedSize = objc_getAssociatedObject(controller, &kApolloDuoRailSavedPreferredSizeKey);
    if (savedSize) {
        controller.preferredContentSize = savedSize.CGSizeValue;
        objc_setAssociatedObject(controller, &kApolloDuoRailSavedPreferredSizeKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *savedLeft = objc_getAssociatedObject(controller, &kApolloDuoRailSavedAdditionalLeftKey);
    if (savedLeft) {
        UIEdgeInsets extra = controller.additionalSafeAreaInsets;
        extra.left = savedLeft.doubleValue;
        controller.additionalSafeAreaInsets = extra;
        objc_setAssociatedObject(controller, &kApolloDuoRailSavedAdditionalLeftKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!controller.isViewLoaded) return;
    UIView *layout = ApolloDuoRailLayoutView(controller, container ?: controller.view.superview);
    if (layout && layout.superview) {
        ApolloDuoRailExpandView(layout, layout.superview.bounds);
    }
    if (controller.view != layout && controller.view.superview) {
        ApolloDuoRailExpandView(controller.view, controller.view.superview.bounds);
    }
    if ([controller respondsToSelector:@selector(tableView)]) {
        UIView *table = nil;
        @try {
            table = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        } @catch (__unused NSException *exception) {
            table = nil;
        }
        if ([table isKindOfClass:[UIScrollView class]]) {
            ApolloDuoRailApplyScrollInsetLeft((UIScrollView *)table, 0.0);
            if ([table isKindOfClass:[UITableView class]]) {
                ApolloDuoRailApplySeparatorTrailing((UITableView *)table, 0.0);
            }
            if (table.superview) {
                ApolloDuoRailExpandView(table, table.superview.bounds);
            }
        }
    }
    UIScrollView *found = controller.isViewLoaded
        ? ApolloDuoRailFindPrimaryTable(controller.view, 5) : nil;
    if (found && found.superview) {
        ApolloDuoRailApplyScrollInsetLeft(found, 0.0);
        if ([found isKindOfClass:[UITableView class]]) {
            ApolloDuoRailApplySeparatorTrailing((UITableView *)found, 0.0);
        }
        ApolloDuoRailExpandView(found, found.superview.bounds);
    }
}

void ApolloDuoRailClearOpenContent(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return;
    for (UIViewController *child in tabs.viewControllers) {
        UINavigationController *nav = ApolloDuoRailNavFromController(child);
        if (!nav) {
            ApolloDuoRailRestoreController(child, child.view.superview);
            continue;
        }
        UIView *container = nav.isViewLoaded ? nav.view : nil;
        for (UIViewController *controller in nav.viewControllers) {
            ApolloDuoRailRestoreController(controller, container);
        }
    }
}

BOOL ApolloDuoRailIsActive(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    return [objc_getAssociatedObject(tabs, &kApolloDuoRailActiveKey) boolValue];
}

void ApolloDuoRailSync(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return;

    int mode = ApolloDuoRailModeForTabs(tabs);
    BOOL show = mode == ApolloDuoModeOpen;
    ApolloDuoRailView *rail = objc_getAssociatedObject(tabs, &kApolloDuoRailViewKey);
    BOOL wasActive = [objc_getAssociatedObject(tabs, &kApolloDuoRailActiveKey) boolValue];
    int previousMode = [objc_getAssociatedObject(tabs, &kApolloDuoRailModeKey) intValue];

    if (!show) {
        if (rail.superview) [rail removeFromSuperview];
        ApolloDuoClearLeadingChromeInsets(tabs, 0.0, 0.0);
        ApolloDuoRailClearOpenContent();
        ApolloDuoRailSetTabBarHidden(tabs, NO);
        objc_setAssociatedObject(tabs, &kApolloDuoRailModeKey, @(mode),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (wasActive) {
            objc_setAssociatedObject(tabs, &kApolloDuoRailActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[DuoRail] hidden; stock tab bar restored (mode=%d)", mode);
        }
        return;
    }

    if (!rail) {
        rail = [[ApolloDuoRailView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(tabs, &kApolloDuoRailViewKey, rail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL leading = ApolloDuoModeIsLeading(mode);
    rail.leading = leading;
    CGRect bounds = tabs.view.bounds;
    UIEdgeInsets safe = ApolloDuoRailSystemSafeInsets(tabs);
    ApolloDuoRailRect frame = ApolloDuoRailFrameInBoundsOnSide(bounds.size.width,
                                                              bounds.size.height,
                                                              safe.top,
                                                              safe.bottom,
                                                              0.0,
                                                              leading ? 1 : 0);
    rail.autoresizingMask = UIViewAutoresizingFlexibleHeight
        | (leading ? UIViewAutoresizingFlexibleRightMargin
                   : UIViewAutoresizingFlexibleLeftMargin);
    CGRect nextFrame = CGRectMake(frame.x, frame.y, frame.width, frame.height);
    if (fabs(rail.frame.origin.x - nextFrame.origin.x) >= 0.5
        || fabs(rail.frame.origin.y - nextFrame.origin.y) >= 0.5
        || fabs(rail.frame.size.width - nextFrame.size.width) >= 0.5
        || fabs(rail.frame.size.height - nextFrame.size.height) >= 0.5) {
        rail.frame = nextFrame;
    }
    if (rail.superview != tabs.view) {
        [tabs.view addSubview:rail];
    }
    [tabs.view bringSubviewToFront:rail];
    NSNumber *selected = objc_getAssociatedObject(tabs, &kApolloDuoRailSelectedKey);
    if (selected) {
        [rail apollo_setSelectedItem:(ApolloDuoRailItem)selected.integerValue];
    } else {
        [rail apollo_setSelectedItem:ApolloDuoRailItemSubreddits];
    }
    [rail apollo_applyTheme];

    CGFloat wantLeft = (CGFloat)ApolloDuoRailChromeLeftForMode(mode);
    CGFloat wantRight = (CGFloat)ApolloDuoRailChromeRightForMode(mode);
    CGFloat wantBottom = 0.0;
    if (mode == ApolloDuoModeClosed && ApolloDuoCoverShouldApplyForTabs(tabs)) {
        wantBottom = (CGFloat)ApolloDuoCoverPillBottom;
    }
    ApolloDuoApplyChromeInsets(tabs, wantLeft, wantBottom, wantRight);
    ApolloDuoRailSetTabBarHidden(tabs, YES);
    objc_setAssociatedObject(tabs, &kApolloDuoRailActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (wasActive && previousMode != mode && previousMode != ApolloDuoModePhone) {
        ApolloDuoRailClearOpenContent();
    }
    objc_setAssociatedObject(tabs, &kApolloDuoRailModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoRailFillOpenContent();
    if (!wasActive || previousMode != mode) {
        ApolloLog(@"[DuoRail] shown %s sidebar (%.0f,%.0f %.0fx%.0f) mode=%d",
                  leading ? "leading" : "trailing",
                  frame.x, frame.y, frame.width, frame.height, mode);
        if (!sApolloDuoRailOpenedDefaultDirectory) {
            sApolloDuoRailOpenedDefaultDirectory = YES;
            ApolloDuoRailOpenDefaultDirectory(tabs);
        }
    }
}
