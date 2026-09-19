#import "ApolloDuoRail.h"
#import "ApolloDuoRailLayout.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "ApolloDeviceChromeInsets.h"
#import "ApolloDeviceDisplay.h"
#import "ApolloDeviceGeometry.h"
#import "ApolloFeedSplitLayout.h"
#import "ApolloThemeRuntime.h"

// Open-inner trailing rail. Regular + (dual screens or a wide inner canvas)
// replaces the stock tab bar with My Subreddits / Home / Popular / All /
// Profile / Settings on the far right — the same edge as Duo's cover
// system pill. The cover/front display already has that pill; this rail
// is inner-only (Compact / cover-sized canvases never install it).
// Compact and ordinary Plus landscape keep the tab bar.
//
// First show defaults to Subs: stock popToRoot onto RedditList (no
// blank tiled half). Navigation reuses Apollo's own tab selectors and
// RedditList row 0 (Home), plus apollo://reddit.com/r/popular|all.

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
    "Subs", "Home", "Popular", "All", "Profile", "Settings",
};
static const char *kApolloDuoRailSymbols[] = {
    "list.bullet", "house", "flame", "globe", "person", "gearshape",
};

static char kApolloDuoRailViewKey;
static char kApolloDuoRailActiveKey;
static char kApolloDuoRailSelectedKey;
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
    self.accessibilityLabel = (item == ApolloDuoRailItemSubreddits) ? @"My Subreddits" : title;
    self.accessibilityTraits = UIAccessibilityTraitButton;

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(iOS 13.0, *)) {
        self.iconView.image = [UIImage systemImageNamed:[NSString stringWithUTF8String:kApolloDuoRailSymbols[item]]];
    }
    [self addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = title;
    self.titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.7;
    [self addSubview:self.titleLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat icon = 22.0;
    self.iconView.frame = CGRectMake((width - icon) * 0.5, 8.0, icon, icon);
    self.titleLabel.frame = CGRectMake(2.0, 32.0, width - 4.0, MAX(14.0, height - 36.0));
}

- (void)apollo_applyForeground:(UIColor *)color selected:(BOOL)selected fill:(UIColor *)fill {
    self.backgroundColor = selected ? fill : UIColor.clearColor;
    self.iconView.tintColor = color;
    self.titleLabel.textColor = color;
    self.layer.cornerRadius = 10.0;
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
@property (nonatomic, assign) ApolloDuoRailItem selectedItem;
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
    self.selectedItem = ApolloDuoRailItemSubreddits;
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
    UIColor *onAccent = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
    for (ApolloDuoRailButton *button in self.buttons) {
        BOOL selected = button.tag == (NSInteger)self.selectedItem;
        [button apollo_applyForeground:(selected ? onAccent : muted) selected:selected fill:accent];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Frame is already window-safe inset. Keep a small gutter; if Sync
    // has not applied yet, inherited safe.top still clears the pill.
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat gutter = (CGFloat)ApolloDuoRailEdgeGutter;
    CGFloat top = MAX(safe.top, gutter);
    CGFloat bottom = MAX(safe.bottom, gutter);
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat usable = height - top - bottom;
    if (usable < 1.0) return;

    NSInteger count = (NSInteger)self.buttons.count;
    CGFloat itemHeight = MIN(72.0, usable / (CGFloat)count);
    CGFloat y = top;
    for (NSInteger i = 0; i < count; i++) {
        UIView *button = self.buttons[(NSUInteger)i];
        if (i == ApolloDuoRailItemProfile) {
            CGFloat remaining = height - bottom - (itemHeight * 2.0);
            if (remaining > y) y = remaining;
        }
        button.frame = CGRectMake(6.0, y, width - 12.0, itemHeight - 4.0);
        y += itemHeight;
    }
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

static BOOL ApolloDuoRailShouldShowForTabs(UITabBarController *tabs) {
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return NO;
    if (tabs.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassRegular) return NO;
    UIEdgeInsets safe = tabs.view.safeAreaInsets;
    UIEdgeInsets margins = tabs.view.layoutMargins;
    double extraLeft = ApolloDeviceChromeExtra(safe.left, margins.left);
    double extraRight = ApolloDeviceChromeExtra(safe.right, margins.right);
    double usable = ApolloFeedSplitUsableWidth(tabs.view.bounds.size.width, extraLeft, extraRight);
    return ApolloDuoRailShouldShow(1, ApolloDuoRailDualDisplays() ? 1 : 0, usable);
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
// additionalSafeAreaInsets.right and would walk the rail left every pass.
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

static UIEdgeInsets ApolloDuoRailSystemMargins(UITabBarController *tabs) {
    UIWindow *window = tabs.view.window;
    if (window) return window.layoutMargins;
    return tabs.view.layoutMargins;
}

static void ApolloDuoRailApplyInsets(UITabBarController *tabs, BOOL show) {
    // Stock nav: inset everyone from the trailing rail + gutter. System
    // safe.right (status pill) is already in the window safe area — do
    // not add it again or Edit/list collapse inward twice.
    CGFloat wantRight = show ? (CGFloat)ApolloDuoRailContentRightInset() : 0.0;
    UIEdgeInsets tabInsets = tabs.additionalSafeAreaInsets;
    if (fabs(tabInsets.left) > 0.5 || fabs(tabInsets.right - wantRight) > 0.5) {
        tabs.additionalSafeAreaInsets = UIEdgeInsetsMake(tabInsets.top, 0.0, tabInsets.bottom, wantRight);
    }
    for (UIViewController *child in tabs.viewControllers) {
        if (!child) continue;
        UIEdgeInsets current = child.additionalSafeAreaInsets;
        if (fabs(current.left) < 0.5 && fabs(current.right - wantRight) < 0.5) continue;
        child.additionalSafeAreaInsets = UIEdgeInsetsMake(current.top, 0.0, current.bottom, wantRight);
    }
}

BOOL ApolloDuoRailIsActive(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    return [objc_getAssociatedObject(tabs, &kApolloDuoRailActiveKey) boolValue];
}

void ApolloDuoRailSync(void) {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return;

    BOOL show = ApolloDuoRailShouldShowForTabs(tabs);
    ApolloDuoRailView *rail = objc_getAssociatedObject(tabs, &kApolloDuoRailViewKey);
    BOOL wasActive = [objc_getAssociatedObject(tabs, &kApolloDuoRailActiveKey) boolValue];

    if (!show) {
        if (rail.superview) [rail removeFromSuperview];
        ApolloDuoRailApplyInsets(tabs, NO);
        if (wasActive) {
            ApolloDuoRailSetTabBarHidden(tabs, NO);
            objc_setAssociatedObject(tabs, &kApolloDuoRailActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[DuoRail] hidden; stock tab bar restored");
        }
        return;
    }

    if (!rail) {
        rail = [[ApolloDuoRailView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(tabs, &kApolloDuoRailViewKey, rail, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect bounds = tabs.view.bounds;
    UIEdgeInsets safe = ApolloDuoRailSystemSafeInsets(tabs);
    UIEdgeInsets margins = ApolloDuoRailSystemMargins(tabs);
    ApolloDuoRailRect frame = ApolloDuoRailFrameInBounds(bounds.size.width,
                                                         bounds.size.height,
                                                         safe.top,
                                                         safe.right,
                                                         safe.bottom,
                                                         margins.right);
    rail.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin
        | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    rail.frame = CGRectMake(frame.x, frame.y, frame.width, frame.height);
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

    ApolloDuoRailApplyInsets(tabs, YES);
    ApolloDuoRailSetTabBarHidden(tabs, YES);
    objc_setAssociatedObject(tabs, &kApolloDuoRailActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!wasActive) {
        ApolloLog(@"[DuoRail] shown trailing inset (%.0f,%.0f %.0fx%.0f safe R=%.0f T=%.0f)",
                  frame.x, frame.y, frame.width, frame.height, safe.right, safe.top);
        if (!sApolloDuoRailOpenedDefaultDirectory) {
            sApolloDuoRailOpenedDefaultDirectory = YES;
            ApolloDuoRailOpenDefaultDirectory(tabs);
        }
    }
}
