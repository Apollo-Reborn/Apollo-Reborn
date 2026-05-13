#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// MARK: - Tab Bar Auto-Hide Reveal Fix
//
// Apollo's "Hide Bars on Scroll" (Settings > General > Other) toggles
// UINavigationController.hidesBarsOnSwipe on every nav controller. Two paths:
//
// iOS 26+ (Liquid Glass):
//   Use Apple's native UITabBarController.tabBarMinimizeBehavior. When the
//   toggle is ON we set the enclosing tab bar controller's behavior to
//   .onScrollDown (raw value 2) so the tab bar collapses to the Liquid Glass
//   pill on scroll-down and re-expands on scroll-up — matching Music/Photos.
//   We also forward setHidesBarsOnSwipe:NO to Apollo's nav controller so the
//   nav bar stays put (true Liquid Glass feel; native API only minimizes the
//   tab bar). When the toggle is OFF we restore .never (raw value 1).
//
// iOS <26 (legacy mirror):
//   Apollo's hide-on-swipe hides the bottom UITabBar but never restores it.
//   The top nav bar still reveals because iOS owns that path via
//   barHideOnSwipeGestureRecognizer. We piggyback on the working top-bar
//   show/hide and mirror it onto the enclosing UITabBarController's tab bar.

@interface UITabBarController (ApolloHideFix)
- (void)setTabBarHidden:(BOOL)hidden animated:(BOOL)animated; // private
@end

// iOS 26 SDK selector — declared via NSInteger to avoid hard SDK dependency.
// UITabBarControllerMinimizeBehaviorAutomatic = 0
// UITabBarControllerMinimizeBehaviorNever     = 1
// UITabBarControllerMinimizeBehaviorOnScrollDown = 2
// UITabBarControllerMinimizeBehaviorOnScrollUp   = 3
typedef NS_ENUM(NSInteger, ApolloTabBarMinimizeBehavior) {
    ApolloTabBarMinimizeBehaviorAutomatic = 0,
    ApolloTabBarMinimizeBehaviorNever = 1,
    ApolloTabBarMinimizeBehaviorOnScrollDown = 2,
    ApolloTabBarMinimizeBehaviorOnScrollUp = 3,
};

static char kApolloRequestedHidesBarsOnSwipeKey;

static SEL ApolloMinimizeBehaviorSetter(void) {
    return NSSelectorFromString(@"setTabBarMinimizeBehavior:");
}

static BOOL ApolloSupportsNativeTabBarMinimize(void) {
    static BOOL supported = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = IsLiquidGlass() &&
            [UITabBarController instancesRespondToSelector:ApolloMinimizeBehaviorSetter()];
    });
    return supported;
}

static void ApolloApplyMinimizeBehavior(UITabBarController *tbc, ApolloTabBarMinimizeBehavior behavior) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;
    SEL sel = ApolloMinimizeBehaviorSetter();
    NSMethodSignature *sig = [tbc methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = tbc;
    inv.selector = sel;
    NSInteger raw = (NSInteger)behavior;
    [inv setArgument:&raw atIndex:2];
    [inv invoke];
    ApolloLog(@"[AutoHideTabBarFix] Native tabBarMinimizeBehavior=%ld on %@",
              (long)raw, NSStringFromClass([tbc class]));
}

// Walk only the parentViewController chain so modally-presented nav controllers
// (share sheets, document pickers, etc.) are skipped — mirroring their hidden
// state onto the main tab bar would spuriously hide it.
static UITabBarController *ApolloLocateTabBarController(UINavigationController *nav) {
    UIViewController *vc = nav;
    while (vc) {
        if ([vc isKindOfClass:[UITabBarController class]]) return (UITabBarController *)vc;
        vc = vc.parentViewController;
    }
    return nil;
}

static void ApolloStoreRequestedHidesBarsOnSwipe(UINavigationController *nav, BOOL value) {
    if (!nav) return;
    objc_setAssociatedObject(nav, &kApolloRequestedHidesBarsOnSwipeKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloNavWantsNativeTabBarMinimize(UINavigationController *nav) {
    if (!nav) return NO;
    NSNumber *stored = objc_getAssociatedObject(nav, &kApolloRequestedHidesBarsOnSwipeKey);
    if ([stored isKindOfClass:[NSNumber class]]) {
        return stored.boolValue;
    }
    return nav.hidesBarsOnSwipe;
}

static void ApolloReapplyNativeMinimizeBehavior(UITabBarController *tbc, NSString *reason) {
    if (!tbc || !ApolloSupportsNativeTabBarMinimize()) return;

    BOOL anyWantsMinimize = NO;
    for (UIViewController *child in tbc.viewControllers) {
        UINavigationController *nav = nil;
        if ([child isKindOfClass:[UINavigationController class]]) {
            nav = (UINavigationController *)child;
        }
        if (nav && ApolloNavWantsNativeTabBarMinimize(nav)) {
            anyWantsMinimize = YES;
            break;
        }
    }

    ApolloApplyMinimizeBehavior(tbc,
        anyWantsMinimize ? ApolloTabBarMinimizeBehaviorOnScrollDown
                         : ApolloTabBarMinimizeBehaviorNever);
    ApolloLog(@"[AutoHideTabBarFix] Reapplied native minimize desired=%d reason=%@",
              anyWantsMinimize, reason ?: @"unknown");
}

static BOOL ApolloTabBarLooksHidden(UITabBar *tabBar) {
    if (!tabBar) return NO;
    if (tabBar.hidden) return YES;
    if (tabBar.alpha < 0.95) return YES;
    if (tabBar.transform.ty != 0.0 || tabBar.transform.tx != 0.0) return YES;
    UIView *parent = tabBar.superview;
    if (parent && tabBar.frame.origin.y >= parent.bounds.size.height - 1.0) return YES;
    return NO;
}

static void ApolloShowTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (!ApolloTabBarLooksHidden(tabBar)) return;

    ApolloLog(@"[AutoHideTabBarFix] Show (hidden=%d alpha=%.2f tx=%.1f ty=%.1f y=%.1f)",
              tabBar.hidden, tabBar.alpha,
              tabBar.transform.tx, tabBar.transform.ty, tabBar.frame.origin.y);

    if ([tbc respondsToSelector:@selector(setTabBarHidden:animated:)]) {
        [tbc setTabBarHidden:NO animated:animated];
    }
    void (^apply)(void) = ^{
        tabBar.hidden = NO;
        tabBar.alpha = 1.0;
        tabBar.transform = CGAffineTransformIdentity;
    };
    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:apply
                         completion:nil];
    } else {
        apply();
    }
}

static void ApolloHideTabBar(UITabBarController *tbc, BOOL animated) {
    if (!tbc) return;
    UITabBar *tabBar = tbc.tabBar;
    if (tabBar.hidden) return;

    ApolloLog(@"[AutoHideTabBarFix] Hide (animated=%d)", animated);

    // Prefer the system path: it slides the tab bar AND recomputes safe-area
    // insets in one coordinated animation, so floating views anchored to the
    // safe area (e.g. the blue jump-to-bottom button in CommentsVC) reflow
    // smoothly alongside the fade instead of jumping after it completes.
    if ([tbc respondsToSelector:@selector(setTabBarHidden:animated:)]) {
        // Keep alpha at 1 so the system's slide/fade reads naturally; reset
        // any leftover transform that the broken native path may have left.
        tabBar.alpha = 1.0;
        tabBar.transform = CGAffineTransformIdentity;
        [tbc setTabBarHidden:YES animated:animated];
        // Force the floating overlay (jump-to-bottom button etc) to reflow
        // during the same animation tick by pumping a layout pass on the
        // tab bar controller's view inside the animation block.
        if (animated) {
            [UIView animateWithDuration:0.25
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                             animations:^{
                [tbc.view setNeedsLayout];
                [tbc.view layoutIfNeeded];
            } completion:nil];
        }
        return;
    }

    // Fallback (shouldn't happen on iOS): plain alpha+hidden.
    void (^apply)(void) = ^{ tabBar.alpha = 0.0; };
    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                         animations:apply
                         completion:^(BOOL finished) {
            if (finished) tabBar.hidden = YES;
        }];
    } else {
        apply();
        tabBar.hidden = YES;
    }
}

// Mirror nav-bar visibility onto the tab bar. Called from every nav-bar
// hide/show entry point, including the gesture-driven path. iOS <26 only —
// on iOS 26 we use the native UITabBarController.tabBarMinimizeBehavior path.
static void ApolloMirrorNavBarStateToTabBar(UINavigationController *nav, BOOL navHidden, BOOL animated) {
    if (ApolloSupportsNativeTabBarMinimize()) return;
    UITabBarController *tbc = ApolloLocateTabBarController(nav);
    if (!tbc) return;
    if (navHidden) {
        ApolloHideTabBar(tbc, animated);
    } else {
        ApolloShowTabBar(tbc, animated);
    }
}

%hook UINavigationController

- (void)setNavigationBarHidden:(BOOL)hidden {
    %orig;
    if (ApolloSupportsNativeTabBarMinimize()) return;
    ApolloMirrorNavBarStateToTabBar(self, hidden, NO);
}

- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    %orig;
    if (ApolloSupportsNativeTabBarMinimize()) return;
    ApolloMirrorNavBarStateToTabBar(self, hidden, animated);
}

%end

// hidesBarsOnSwipe entry point. Two modes:
//   iOS 26+: hijack the toggle — instead of letting the nav bar hide on
//            swipe, set the enclosing tab bar controller's native
//            tabBarMinimizeBehavior so only the tab bar collapses (true
//            Liquid Glass feel, mirroring Music/Photos).
//   iOS <26: leave Apollo's behavior intact and observe the gesture so we
//            can mirror nav-bar visibility onto the tab bar.
%hook UINavigationController

- (void)setHidesBarsOnSwipe:(BOOL)value {
    if (ApolloSupportsNativeTabBarMinimize()) {
        // Suppress Apollo's nav-bar hide-on-swipe; the native API only
        // collapses the tab bar so we want the nav bar to stay visible.
        ApolloStoreRequestedHidesBarsOnSwipe(self, value);
        %orig(NO);
        UITabBarController *tbc = ApolloLocateTabBarController(self);
        if (tbc) {
            ApolloApplyMinimizeBehavior(tbc,
                value ? ApolloTabBarMinimizeBehaviorOnScrollDown
                      : ApolloTabBarMinimizeBehaviorNever);
        }
        return;
    }

    %orig;
    if (!value) return;
    UIPanGestureRecognizer *gr = self.barHideOnSwipeGestureRecognizer;
    if (!gr) return;
    static char kAttachedKey;
    if (objc_getAssociatedObject(gr, &kAttachedKey)) return;
    objc_setAssociatedObject(gr, &kAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gr addTarget:self action:@selector(_apolloBarHideSwipeFired:)];
    ApolloLog(@"[AutoHideTabBarFix] Attached observer to barHideOnSwipeGestureRecognizer");
}

%new
- (void)_apolloBarHideSwipeFired:(UIPanGestureRecognizer *)gr {
    if (ApolloSupportsNativeTabBarMinimize()) return;
    if (gr.state != UIGestureRecognizerStateEnded &&
        gr.state != UIGestureRecognizerStateCancelled &&
        gr.state != UIGestureRecognizerStateFailed) return;
    // After the gesture concludes, the nav controller has settled on its final
    // hidden state. Mirror it onto the tab bar so the bottom dock matches what
    // the top bar just did.
    BOOL navHidden = self.isNavigationBarHidden;
    ApolloLog(@"[AutoHideTabBarFix] Swipe ended state=%ld navHidden=%d", (long)gr.state, navHidden);
    ApolloMirrorNavBarStateToTabBar(self, navHidden, YES);
}

%end

// On iOS 26, when the app launches with the toggle already ON, Apollo sets
// hidesBarsOnSwipe before the tab bar controller is fully wired up. Re-apply
// the minimize behavior on appearance from the stored requested state. We can't
// trust the nav controller's hidesBarsOnSwipe property because the iOS 26 path
// intentionally forwards NO to keep the nav bar visible.
%hook UITabBarController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloReapplyNativeMinimizeBehavior(self, @"viewWillAppear");
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloReapplyNativeMinimizeBehavior(self, @"viewDidAppear");
}

%end
