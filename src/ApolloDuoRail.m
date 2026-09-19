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
// Profile / Settings hugging the far right — same edge as Duo's cover
// system pill, starting fully under the inner time/Wi-Fi cluster (live
// pill maxY, floored at 104pt). The cover/front already has that pill;
// this rail is inner-only. Compact and ordinary Plus landscape keep the
// tab bar. On cover, extra trailing / bottom safe-area insets lift FABs
// off Duo's system gear. Open-Duo content is expanded to the usable
// width left of the rail so stock nav does not stay a phone column.
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
    // Frame owns the status-band inset. Duo window.safe.top is often 0
    // (pill is trailing), so do not use inherited safe.top as the Subs
    // origin — that parks the first button beside 8:08.
    CGFloat gutter = (CGFloat)ApolloDuoRailEdgeGutter;
    CGFloat top = gutter;
    CGFloat bottom = gutter;
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

// Status-bar chrome in the top band only. A full-height right-edge
// strip (height > 160) is treated as its top cluster, not maxY.
static CGFloat ApolloDuoRailStatusRectMaxY(CGRect status, UIView *tabsView) {
    if (CGRectIsNull(status) || status.size.height <= 0.0) return 0.0;
    CGRect inTabs = [tabsView convertRect:status fromView:nil];
    if (CGRectGetMinY(inTabs) > 160.0) return 0.0;
    if (status.size.height <= 160.0) {
        return (CGFloat)MAX(0.0, CGRectGetMaxY(inTabs));
    }
    if (status.size.width > 220.0) return 0.0;
    return (CGFloat)MAX(0.0, CGRectGetMinY(inTabs) + (CGFloat)ApolloDuoRailMinTopClearance);
}

static CGFloat ApolloDuoRailStatusBarViewMaxY(UIView *root, UIView *tabsView) {
    if (!root || !tabsView) return 0.0;
    CGFloat best = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 80) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        const char *name = class_getName(view.class);
        if (name && (strstr(name, "StatusBar") || strstr(name, "StatusPill")
                     || strstr(name, "_UIStatus"))) {
            CGFloat maxY = ApolloDuoRailStatusRectMaxY(
                [view convertRect:view.bounds toView:nil], tabsView);
            if (maxY > best) best = maxY;
        }
        if (inspected < 40) {
            for (UIView *subview in view.subviews) {
                [stack addObject:subview];
            }
        }
    }
    return best;
}

// Live time/Wi-Fi cluster. Do not use the nav bar — that dropped the
// rail halfway down the canvas. Probe statusBarFrame plus on-screen
// StatusBar views; ignore tall right-edge strips except their top band.
static CGFloat ApolloDuoRailStatusPillMaxY(UITabBarController *tabs) {
    UIWindow *window = tabs.view.window;
    UIWindowScene *scene = window.windowScene;
    CGFloat best = 0.0;
    if (scene.statusBarManager) {
        CGRect status = scene.statusBarManager.statusBarFrame;
        CGFloat maxY = ApolloDuoRailStatusRectMaxY(status, tabs.view);
        if (maxY > best) best = maxY;
    }
    for (UIWindow *probe in ApolloAllWindows()) {
        if (!probe || (probe != window && probe.windowScene != scene)) continue;
        CGFloat maxY = ApolloDuoRailStatusBarViewMaxY(probe, tabs.view);
        if (maxY > best) best = maxY;
    }
    if (best > 160.0) best = 160.0;
    return best;
}

CGFloat ApolloDuoRailSectionIndexTrailingForTable(UITableView *tableView) {
    if (!ApolloDuoRailIsActive() || !tableView) return 0.0;
    return (CGFloat)ApolloDuoRailSectionIndexTrailing();
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

static void ApolloDuoApplyChromeInsets(UITabBarController *tabs, CGFloat wantRight, CGFloat wantBottom) {
    UIEdgeInsets tabInsets = tabs.additionalSafeAreaInsets;
    if (fabs(tabInsets.left) > 0.5
        || fabs(tabInsets.right - wantRight) > 0.5
        || fabs(tabInsets.bottom - wantBottom) > 0.5) {
        tabs.additionalSafeAreaInsets = UIEdgeInsetsMake(tabInsets.top, 0.0, wantBottom, wantRight);
    }
    for (UIViewController *child in tabs.viewControllers) {
        if (!child) continue;
        UIEdgeInsets current = child.additionalSafeAreaInsets;
        if (fabs(current.left) < 0.5
            && fabs(current.right - wantRight) < 0.5
            && fabs(current.bottom - wantBottom) < 0.5) {
            continue;
        }
        child.additionalSafeAreaInsets = UIEdgeInsetsMake(current.top, 0.0, wantBottom, wantRight);
    }
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
    if (CGRectGetWidth(view.frame) + 0.5 >= CGRectGetWidth(frame)
        && fabs(CGRectGetMinX(view.frame) - CGRectGetMinX(frame)) < 1.0
        && fabs(CGRectGetHeight(view.frame) - CGRectGetHeight(frame)) < 1.0) {
        return;
    }
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.frame = frame;
}

static void ApolloDuoRailFillController(UIViewController *controller, UIView *container) {
    if (!controller || !container || CGRectGetWidth(container.bounds) < 1.0) return;
    if (!controller.isViewLoaded) return;
    CGFloat containerWidth = CGRectGetWidth(container.bounds);
    BOOL expanded = NO;
    UIView *layout = ApolloDuoRailLayoutView(controller, container);
    if (layout && ApolloDuoRailContentIsLetterboxed(layout.frame.size.width, containerWidth)) {
        ApolloLog(@"[DuoRail] filled letterboxed %@ %.0f → %.0f",
                  NSStringFromClass(controller.class),
                  layout.frame.size.width, containerWidth);
        ApolloDuoRailExpandView(layout, container.bounds);
        expanded = YES;
    }
    UIView *view = controller.view;
    if (view && view != layout
        && ApolloDuoRailContentIsLetterboxed(view.frame.size.width, containerWidth)) {
        ApolloDuoRailExpandView(view, layout ? layout.bounds : container.bounds);
        expanded = YES;
    }
    if (view) {
        view.preservesSuperviewLayoutMargins = NO;
        UIEdgeInsets margins = view.layoutMargins;
        if (margins.left > 16.5 || margins.right > 16.5) {
            view.layoutMargins = UIEdgeInsetsMake(margins.top, 16.0, margins.bottom, 16.0);
        }
        CGSize preferred = controller.preferredContentSize;
        CGFloat fill = (CGFloat)ApolloDuoRailContentFillWidth(containerWidth);
        if (fill > 0.5 && preferred.width + (CGFloat)ApolloDuoRailLetterboxGap < fill) {
            controller.preferredContentSize = CGSizeMake(fill, preferred.height);
        }
    }
    if ([controller respondsToSelector:@selector(tableView)]) {
        UIView *table = nil;
        @try {
            table = ((UIView *(*)(id, SEL))objc_msgSend)(controller, @selector(tableView));
        } @catch (__unused NSException *exception) {
            table = nil;
        }
        if ([table isKindOfClass:[UITableView class]]) {
            UITableView *tableView = (UITableView *)table;
            tableView.cellLayoutMarginsFollowReadableWidth = NO;
            if (view && table.superview == view
                && ApolloDuoRailContentIsLetterboxed(table.frame.size.width, view.bounds.size.width)) {
                table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                table.frame = view.bounds;
                expanded = YES;
            }
        }
    }
    id tableNode = nil;
    Ivar nodeIvar = class_getInstanceVariable(controller.class, "tableNode");
    if (nodeIvar) tableNode = object_getIvar(controller, nodeIvar);
    if (expanded && tableNode) {
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

void ApolloDuoRailFillOpenContent(void) {
    if (!ApolloDuoRailIsActive()) return;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:[UITabBarController class]] || !tabs.isViewLoaded) return;
    UIView *tabView = tabs.view;
    UINavigationController *nav = ApolloDuoRailNavFromController(tabs.selectedViewController);
    if (!nav) nav = ApolloDuoRailFindPostsNav(tabs, NO);
    if (!nav.isViewLoaded) return;
    if (ApolloDuoRailContentIsLetterboxed(nav.view.frame.size.width, tabView.bounds.size.width)) {
        ApolloDuoRailExpandView(nav.view, tabView.bounds);
    }
    UIView *container = nav.view ?: tabView;
    UIViewController *top = nav.topViewController;
    if (top) ApolloDuoRailFillController(top, container);
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
        if (ApolloDuoCoverShouldApplyForTabs(tabs)) {
            ApolloDuoApplyChromeInsets(tabs,
                                       (CGFloat)ApolloDuoCoverPillWidth,
                                       (CGFloat)ApolloDuoCoverPillBottom);
        } else {
            ApolloDuoApplyChromeInsets(tabs, 0.0, 0.0);
        }
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
    ApolloDuoRailRect frame = ApolloDuoRailFrameInBounds(bounds.size.width,
                                                         bounds.size.height,
                                                         safe.top,
                                                         safe.bottom,
                                                         ApolloDuoRailStatusPillMaxY(tabs));
    rail.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin;
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

    ApolloDuoApplyChromeInsets(tabs, (CGFloat)ApolloDuoRailContentRightInset(), 0.0);
    ApolloDuoRailSetTabBarHidden(tabs, YES);
    objc_setAssociatedObject(tabs, &kApolloDuoRailActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDuoRailFillOpenContent();
    if (!wasActive) {
        ApolloLog(@"[DuoRail] shown hugging trailing (%.0f,%.0f %.0fx%.0f pillMaxY=%.0f)",
                  frame.x, frame.y, frame.width, frame.height, ApolloDuoRailStatusPillMaxY(tabs));
        if (!sApolloDuoRailOpenedDefaultDirectory) {
            sApolloDuoRailOpenedDefaultDirectory = YES;
            ApolloDuoRailOpenDefaultDirectory(tabs);
        }
    }
}
