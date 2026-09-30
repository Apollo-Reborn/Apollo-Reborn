// iPad Liquid Glass uses text tabs at the top or bottom, with separate
// title/search rows beneath the top tabs.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloNavigationTitlePresentation.h"

#import "ApolloThemeRuntime.h"

static char kIPadSearchReservation;
static char kIPadBottomTabsKey;
static char kIPadBottomInset;
static char kIPadClearanceScheduled;
static char kIPadButtonRowHosts;
static char kIPadButtonRowReservation;
static char kIPadButtonNativeFrame;
static char kIPadButtonApplyingFrame;


// Search reserves a row on the navigation controller so UIKit measures its
// search field before presentation. Only the native button platter should
// counter that reservation: the title and search keep their separate rows.
// Keep the original controls, menus, accessibility and back action intact.
static void ApolloIPadAlignNavigationButtons(UINavigationController *nav) {
    UINavigationBar *bar = nav.navigationBar;
    CGFloat reservation = [objc_getAssociatedObject(nav, &kIPadSearchReservation) doubleValue];
    CGFloat wanted = IsLiquidGlass() && !sIPadTabBarBottom
        ? -reservation : 0;
    NSMutableArray<UIView *> *hosts = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    for (NSUInteger index = 0; index < queue.count; index++) {
        UIView *view = queue[index];
        if ([NSStringFromClass(view.class) containsString:@"NavigationBarPlatterContainer"]) {
            NSValue *savedFrame = objc_getAssociatedObject(view, &kIPadButtonNativeFrame);
            CGRect nativeFrame = savedFrame ? savedFrame.CGRectValue : view.frame;
            objc_setAssociatedObject(view, &kIPadButtonNativeFrame, [NSValue valueWithCGRect:nativeFrame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, &kIPadButtonRowReservation, @(wanted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CGRect target = CGRectOffset(nativeFrame, 0, wanted);
            if (!CGRectEqualToRect(view.frame, target)) {
                objc_setAssociatedObject(view, &kIPadButtonApplyingFrame, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                view.frame = target;
                objc_setAssociatedObject(view, &kIPadButtonApplyingFrame, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloLog(@"[IPadButtonRow] offset %.0fpt", wanted);
            }
            if (fabs(wanted) > 0.5) [hosts addObject:view];
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    objc_setAssociatedObject(bar, &kIPadButtonRowHosts, hosts, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The shifted buttons can sit above the navigation bar's bounds. Route only
// actual control hits through their native platter, leaving empty space to
// the floating tabs/content. A visual translation alone would lose the taps.
static UIView *ApolloIPadNavigationButtonHit(UINavigationBar *bar, CGPoint point, UIEvent *event) {
    NSArray<UIView *> *hosts = objc_getAssociatedObject(bar, &kIPadButtonRowHosts);
    for (UIView *host in hosts.reverseObjectEnumerator) {
        if (!host.window || host.hidden || host.alpha <= 0.01 || !host.userInteractionEnabled) continue;
        UIView *hit = [host hitTest:[host convertPoint:point fromView:bar] withEvent:event];
        for (UIView *view = hit; view && view != host; view = view.superview) {
            if ([view isKindOfClass:UIControl.class]) return hit;
        }
    }
    return nil;
}

// Preserve horizontal text labels without forcing UIKit's compact icon layout.
@interface ApolloIPadBottomTabs : UIVisualEffectView
@property(nonatomic, weak) UITabBarController *tabs;
@property(nonatomic, strong) UIStackView *stack;
- (void)update;
@end
@implementation ApolloIPadBottomTabs
- (instancetype)init {
    UIVisualEffect *effect = nil;
    if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    self = [super initWithEffect:effect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = 30;
        self.clipsToBounds = YES;
        _stack = [UIStackView new];
        _stack.spacing = 4;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:6],
            [_stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-6],
            [_stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [_stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6]]];
    }
    return self;
}
- (void)selectTab:(UIButton *)sender {
    UITabBarController *tabs = self.tabs;
    if (sender.tag >= tabs.viewControllers.count) return;
    UIViewController *page = tabs.viewControllers[sender.tag];
    id<UITabBarControllerDelegate> delegate = tabs.delegate;
    if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] &&
        ![delegate tabBarController:tabs shouldSelectViewController:page]) return;
    tabs.selectedViewController = page;
    if ([delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)])
        [delegate tabBarController:tabs didSelectViewController:page];
    [self update];
}
- (void)update {
    NSArray<UIViewController *> *pages = self.tabs.viewControllers;
    if (self.stack.arrangedSubviews.count != pages.count) {
        for (UIView *view in self.stack.arrangedSubviews.copy) [view removeFromSuperview];
        for (NSUInteger index = 0; index < pages.count; index++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = index;
            button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            button.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
            button.layer.cornerRadius = 22;
            [button addTarget:self action:@selector(selectTab:) forControlEvents:UIControlEventTouchUpInside];
            [self.stack addArrangedSubview:button];
            [button.heightAnchor constraintEqualToConstant:44].active = YES;
            [button.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        }
    }
    NSArray *fallback = @[@"Posts", @"Inbox", @"Profile", @"Search", @"Settings"];
    for (NSUInteger index = 0; index < pages.count; index++) {
        UIButton *button = self.stack.arrangedSubviews[index];
        NSString *title = pages[index].tabBarItem.title;
        if (!title.length) title = index < fallback.count ? fallback[index] : @"Tab";
        if (![button.currentTitle isEqualToString:title]) [button setTitle:title forState:UIControlStateNormal];
        BOOL selected = index == self.tabs.selectedIndex;
        button.accessibilityLabel = title;
        button.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
        [button setTitleColor:selected ? ApolloThemeAccentColor() : UIColor.labelColor forState:UIControlStateNormal];
        button.backgroundColor = selected ? UIColor.tertiarySystemFillColor : UIColor.clearColor;
    }
}
@end

static void ApolloIPadUpdateTabPlacement(UITabBarController *tabs) {
    if (!IsLiquidGlass()) return;
    BOOL bottom = sIPadTabBarBottom;
    if (@available(iOS 18.0, *)) {
        if (tabs.isTabBarHidden != bottom) [tabs setTabBarHidden:bottom animated:NO];
    }
    ApolloIPadBottomTabs *bar = objc_getAssociatedObject(tabs, &kIPadBottomTabsKey);
    if (bottom && !bar) {
        bar = [ApolloIPadBottomTabs new];
        bar.tabs = tabs;
        [tabs.view addSubview:bar];
        UILayoutGuide *safe = tabs.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [bar.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [bar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
            [bar.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:8]]];
        objc_setAssociatedObject(tabs, &kIPadBottomTabsKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    bar.hidden = !bottom;
    if (bottom) {
        [bar update];
        [tabs.view bringSubviewToFront:bar];
    }
    for (UIViewController *page in tabs.viewControllers) {
        CGFloat previous = [objc_getAssociatedObject(page, &kIPadBottomInset) doubleValue];
        CGFloat wanted = bottom ? 72 : 0;
        if (fabs(wanted - previous) > 0.5) {
            UIEdgeInsets insets = page.additionalSafeAreaInsets;
            insets.bottom += wanted - previous;
            objc_setAssociatedObject(page, &kIPadBottomInset, @(wanted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            page.additionalSafeAreaInsets = insets;
        }
    }
}

static void ApolloIPadPrepareSearchReservation(UINavigationController *nav, UIViewController *page) {
    if (!nav) return;
    UITabBarController *tabs = nav.tabBarController;
    BOOL floating = IsLiquidGlass() && !sIPadTabBarBottom && tabs && nav.parentViewController == tabs &&
        nav.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular;
    BOOL nativeSearch = page.navigationItem.searchController != nil || [page isKindOfClass:NSClassFromString(@"_TtC6Apollo20SearchViewController")] ||
        ApolloNavigationTitleContainsNativeSearchSurface(page.navigationItem.titleView);
    // A native searchController already gets a separate row below the title
    // from UIKit. Reserving another row on its navigation controller doubles
    // the space between the relocated title and search field. Only the Search
    // tab's title-hosted field needs the explicit top reservation.
    CGFloat wanted = floating && nativeSearch && !page.navigationItem.searchController ? 56.0 : 0;
    CGFloat previous = [objc_getAssociatedObject(nav, &kIPadSearchReservation) doubleValue];
    if (fabs(wanted - previous) < 0.5) return;
    UIEdgeInsets insets = nav.additionalSafeAreaInsets;
    insets.top += wanted - previous;
    objc_setAssociatedObject(nav, &kIPadSearchReservation, @(wanted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    nav.additionalSafeAreaInsets = insets;
    ApolloLog(@"[IPadSearchRow] reserved %.0fpt", wanted);
}

static void ApolloIPadRefreshControllerTree(UIViewController *vc) {
    if ([vc isKindOfClass:UITabBarController.class]) ApolloIPadUpdateTabPlacement((UITabBarController *)vc);
    if ([vc isKindOfClass:UINavigationController.class]) {
        ApolloIPadPrepareSearchReservation((UINavigationController *)vc, ((UINavigationController *)vc).topViewController);
        ApolloNavigationTitlePresentationRefresh(((UINavigationController *)vc).navigationBar);
    }
    for (UIViewController *child in vc.childViewControllers) ApolloIPadRefreshControllerTree(child);
    if (vc.presentedViewController) ApolloIPadRefreshControllerTree(vc.presentedViewController);
    if (vc.isViewLoaded) [vc.view setNeedsLayout];
}

%group ApolloIPadPlacement
%hook UITabBarController
- (void)viewWillAppear:(BOOL)animated {
    ApolloIPadUpdateTabPlacement(self);
    %orig(animated);
}
- (void)viewWillLayoutSubviews {
    ApolloIPadUpdateTabPlacement(self);
    %orig;
}
%end
%hook UINavigationController
- (void)viewDidLayoutSubviews {
    %orig;
    // Apply button presentation after UIKit finishes its navigation layout pass.
    if ([objc_getAssociatedObject(self, &kIPadClearanceScheduled) boolValue]) return;
    objc_setAssociatedObject(self, &kIPadClearanceScheduled, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UINavigationController *weakNav = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationController *nav = weakNav;
        if (!nav) return;
        objc_setAssociatedObject(nav, &kIPadClearanceScheduled, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloIPadAlignNavigationButtons(nav);
    });
}
- (void)viewWillAppear:(BOOL)animated {
    ApolloIPadPrepareSearchReservation(self, self.topViewController);
    %orig(animated);
}
- (void)pushViewController:(UIViewController *)page animated:(BOOL)animated {
    ApolloIPadPrepareSearchReservation(self, page);
    %orig(page, animated);
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    if (self.viewControllers.count > 1) {
        ApolloIPadPrepareSearchReservation(self, self.viewControllers[self.viewControllers.count - 2]);
    }
    return %orig(animated);
}
- (void)viewWillLayoutSubviews {
    ApolloIPadPrepareSearchReservation(self, self.topViewController);
    ApolloIPadAlignNavigationButtons(self);
    %orig;
}
%end
%hook UINavigationBar
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.hidden && self.alpha > 0.01 && self.userInteractionEnabled) {
        UIView *button = ApolloIPadNavigationButtonHit(self, point, event);
        if (button) return button;
    }
    return %orig(point, event);
}
%end
%hook _TtC6Apollo20SearchViewController
- (void)viewDidLoad {
    // The class is known before its native searchBar/titleView is constructed.
    // Reserve its row before UIKit's first measurement, not after presentation.
    UIViewController *page = (UIViewController *)self;
    ApolloIPadPrepareSearchReservation(page.navigationController, page);
    %orig;
    ApolloIPadPrepareSearchReservation(page.navigationController, page);
}
- (void)viewWillAppear:(BOOL)animated {
    UIViewController *page = (UIViewController *)self;
    ApolloIPadPrepareSearchReservation(page.navigationController, page);
    %orig(animated);
}
%end
%end


// Adjust UIKit's requested platter frame at its source, so later SwiftUI
// layout passes cannot put the buttons back on the title row.
@interface ApolloIPadButtonPlatter : UIView
@end
%group ApolloIPadButtonRow
%hook ApolloIPadButtonPlatter
- (void)setFrame:(CGRect)frame {
    if (![objc_getAssociatedObject(self, &kIPadButtonApplyingFrame) boolValue]) {
        objc_setAssociatedObject(self, &kIPadButtonNativeFrame, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFloat offset = [objc_getAssociatedObject(self, &kIPadButtonRowReservation) doubleValue];
        frame.origin.y += offset;
    }
    %orig(frame);
}
%end
%end

%ctor {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;
    %init(ApolloIPadPlacement);
    Class platter = NSClassFromString(@"UIKit.NavigationBarPlatterContainer_v2");
    if (platter) { %init(ApolloIPadButtonRow, ApolloIPadButtonPlatter = platter); }
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloIPadTabBarBottomChangedNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        for (UIWindow *window in ApolloAllWindows()) {
            ApolloIPadRefreshControllerTree(window.rootViewController);
            [window layoutIfNeeded];
        }
        ApolloLog(@"[IPadTabBarBottom] applied placement bottom=%d", sIPadTabBarBottom);
    }];
}
