// In-app Safari: no white page while a link loads in dark mode (issue #1008,
// inherited Apollo bug christianselig/apollo-bugs#1951).
//
// SFSafariViewController renders out of process. Its chrome comes up in the
// host's interface style (dark), but the moment WebKit's content process
// delivers its first frame the page area is an empty white document, and it
// stays white until the real page paints. Safari.app never shows that phase
// (it keeps the previous page / dark start page on screen until the new page
// paints); the view service has nothing to keep, so every dark-mode link opens
// with a white flash. Nothing in the host controls the service's page colour
// (`preferredBarTintColor` only reaches the bars, and iOS 26's glass chrome
// ignores even that), so this hides the blank phase from the host side.
//
// While the browser's trait collection is dark, an opaque black view sits over
// the remote content from the moment the browser appears:
//   - iOS ≤ 18 chrome (opaque bars, black under Apollo's dark bar tint): the
//     shield covers only the page area between the bars, so the URL, progress
//     bar and Done button stay visible.
//   - iOS 26 chrome (glass bars that float over the page and adopt its
//     colour — the view service draws them for every host app, whichever SDK
//     the app links against): the shield covers the whole surface, since
//     anything left uncovered would be the same white page showing through
//     the glass.
// It is opaque for a short hold after the service reports its web view exists
// (the point the white first frame arrives), then fades out over a second so
// a still-blank page brightens gradually instead of snapping to white, and it
// fades out immediately when the service reports the initial load finished.
// Touches pass through it, so the (hidden on glass) close button and the edge
// swipe keep working underneath.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <SafariServices/SafariServices.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

static char kApolloSafariShieldKey;
static char kApolloSafariShieldSpentKey;   // @YES once a controller has had its shield

// Opaque hold after the view service created its web view — the white first
// frame lands right after that callback, so this is where the cover matters.
static const NSTimeInterval kApolloSafariShieldHoldAfterWebView = 0.8;
// Hold used when the web-view callback never arrives (older SafariServices
// without that delegate method), measured from viewDidAppear.
static const NSTimeInterval kApolloSafariShieldHoldFallback = 1.5;
// Long fade for a page that hasn't finished loading: a gradual brightening
// instead of a flash, and painted content shows through as it goes.
static const NSTimeInterval kApolloSafariShieldRampDuration = 1.4;
// Quick fade once the service reports the initial load is done.
static const NSTimeInterval kApolloSafariShieldFinishDuration = 0.25;

typedef NS_ENUM(NSInteger, ApolloSafariShieldPhase) {
    ApolloSafariShieldPhaseHolding = 0,
    ApolloSafariShieldPhaseFading,
    ApolloSafariShieldPhaseDone,
};

@interface ApolloSafariLoadingShield : UIView
@property (nonatomic, assign) BOOL coversBars;
@property (nonatomic, assign) BOOL anchored;
@property (nonatomic, assign) ApolloSafariShieldPhase phase;
@property (nonatomic, assign) NSUInteger generation;
@end

@implementation ApolloSafariLoadingShield
@end

static ApolloSafariLoadingShield *ApolloSafariShieldFor(UIViewController *controller) {
    return objc_getAssociatedObject(controller, &kApolloSafariShieldKey);
}

static BOOL ApolloSafariShieldWanted(UIViewController *controller) {
    return controller.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}

// Page area between SFSafariViewController's legacy opaque bars: a 44pt
// (32pt in compact height) navigation bar under the status bar, and a 44pt
// toolbar above the home indicator only in compact-width / regular-height
// layouts (portrait phone, narrow iPad split) — elsewhere the toolbar items
// move into the navigation bar.
static CGRect ApolloSafariShieldPageRect(UIViewController *controller) {
    UIView *host = controller.view;
    CGRect bounds = host.bounds;
    UIEdgeInsets safe = host.safeAreaInsets;
    UITraitCollection *traits = controller.traitCollection;
    BOOL compactHeight = traits.verticalSizeClass == UIUserInterfaceSizeClassCompact;
    BOOL compactWidth = traits.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    CGFloat top = safe.top + (compactHeight ? 32.0 : 44.0);
    CGFloat bottom = (compactWidth && !compactHeight) ? safe.bottom + 44.0 : 0.0;
    CGFloat height = MAX(0.0, CGRectGetHeight(bounds) - top - bottom);
    return CGRectMake(CGRectGetMinX(bounds), CGRectGetMinY(bounds) + top, CGRectGetWidth(bounds), height);
}

static void ApolloSafariShieldLayout(UIViewController *controller) {
    ApolloSafariLoadingShield *shield = ApolloSafariShieldFor(controller);
    UIView *host = controller.view;
    if (!shield || shield.superview != host) return;

    CGRect frame = shield.coversBars ? host.bounds : ApolloSafariShieldPageRect(controller);
    if (!CGRectEqualToRect(shield.frame, frame)) shield.frame = frame;
    // The remote view is attached after we are; keep the shield above it. Apollo's
    // own floating comments button is re-raised by its viewDidLayoutSubviews after
    // this, so it stays on top of the shield.
    if (host.subviews.lastObject != shield) [host bringSubviewToFront:shield];
}

static void ApolloSafariShieldClear(UIViewController *controller, ApolloSafariLoadingShield *shield) {
    shield.phase = ApolloSafariShieldPhaseDone;
    shield.generation += 1;
    [shield.layer removeAllAnimations];
    [shield removeFromSuperview];
    if (ApolloSafariShieldFor(controller) == shield) {
        objc_setAssociatedObject(controller, &kApolloSafariShieldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloSafariShieldFade(UIViewController *controller, NSTimeInterval duration, NSString *reason) {
    ApolloSafariLoadingShield *shield = ApolloSafariShieldFor(controller);
    if (!shield || shield.phase == ApolloSafariShieldPhaseDone) return;

    BOOL wasFading = shield.phase == ApolloSafariShieldPhaseFading;
    shield.phase = ApolloSafariShieldPhaseFading;
    shield.generation += 1;
    if (wasFading) {
        // Take over from the long ramp at its current opacity.
        CGFloat current = shield.layer.presentationLayer ? shield.layer.presentationLayer.opacity : shield.alpha;
        [shield.layer removeAllAnimations];
        shield.alpha = current;
    }
    ApolloLog(@"[SafariDark] fading shield out over %.2fs (%@)", duration, reason);

    __weak UIViewController *weakController = controller;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ shield.alpha = 0.0; }
                     completion:^(BOOL finished) {
        // A fade cut short by a later, faster fade (or by removal) reports
        // finished == NO; that later path owns the cleanup.
        if (!finished) return;
        UIViewController *strongController = weakController;
        if (strongController) ApolloSafariShieldClear(strongController, shield);
        else [shield removeFromSuperview];
    }];
}

static void ApolloSafariShieldScheduleRamp(UIViewController *controller, NSTimeInterval hold, NSString *reason) {
    ApolloSafariLoadingShield *shield = ApolloSafariShieldFor(controller);
    if (!shield || shield.phase != ApolloSafariShieldPhaseHolding) return;

    shield.generation += 1;
    NSUInteger generation = shield.generation;
    ApolloLog(@"[SafariDark] shield holds %.2fs then ramps (%@)", hold, reason);

    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        ApolloSafariLoadingShield *current = strongController ? ApolloSafariShieldFor(strongController) : nil;
        if (!current || current != shield || current.generation != generation) return;
        if (current.phase != ApolloSafariShieldPhaseHolding) return;
        ApolloSafariShieldFade(strongController, kApolloSafariShieldRampDuration, @"hold elapsed");
    });
}

static void ApolloSafariShieldInstall(UIViewController *controller) {
    if (ApolloSafariShieldFor(controller)) return;
    // One shield per browser: a re-appearance (after a full-screen modal on
    // top of it) has the page painted already, so there is nothing to cover.
    if ([objc_getAssociatedObject(controller, &kApolloSafariShieldSpentKey) boolValue]) return;
    objc_setAssociatedObject(controller, &kApolloSafariShieldSpentKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!ApolloSafariShieldWanted(controller)) {
        ApolloLog(@"[SafariDark] light interface style, no shield");
        return;
    }
    UIView *host = controller.view;
    if (!host) return;

    ApolloSafariLoadingShield *shield = [[ApolloSafariLoadingShield alloc] initWithFrame:host.bounds];
    // The chrome style is the view service's, decided by the OS, not by
    // whether Apollo itself is a Liquid Glass build.
    if (@available(iOS 26.0, *)) shield.coversBars = YES;
    else shield.coversBars = NO;
    shield.backgroundColor = UIColor.blackColor;
    shield.opaque = YES;
    shield.userInteractionEnabled = NO;
    shield.accessibilityElementsHidden = YES;
    objc_setAssociatedObject(controller, &kApolloSafariShieldKey, shield, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addSubview:shield];
    ApolloSafariShieldLayout(controller);
    ApolloLog(@"[SafariDark] shield installed on %@ (%@) frame=%@",
              NSStringFromClass(controller.class),
              shield.coversBars ? @"whole surface, iOS 26 glass chrome" : @"page area between the bars",
              NSStringFromCGRect(shield.frame));
}

static void ApolloSafariShieldRemoveNow(UIViewController *controller, NSString *reason) {
    ApolloSafariLoadingShield *shield = ApolloSafariShieldFor(controller);
    if (!shield) return;
    ApolloLog(@"[SafariDark] shield removed (%@)", reason);
    ApolloSafariShieldClear(controller, shield);
}

%group ApolloSafariDarkLoadingBase

%hook SFSafariViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloSafariShieldInstall(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Bound the shield even if the web-view callback below never fires.
    ApolloSafariLoadingShield *shield = ApolloSafariShieldFor(self);
    if (shield && !shield.anchored) {
        ApolloSafariShieldScheduleRamp(self, kApolloSafariShieldHoldFallback, @"appeared, no web view yet");
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloSafariShieldLayout(self);
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    ApolloSafariShieldRemoveNow(self, @"disappearing");
}

%end

%end

// SFBrowserRemoteViewControllerDelegate callbacks the view service sends the
// host. Only hooked when this SafariServices has them (checked in %ctor).
%group ApolloSafariDarkLoadingRemote

%hook SFSafariViewController

- (void)remoteViewControllerDidLoadWebView:(id)remoteViewController {
    %orig;
    ApolloSafariLoadingShield *shield = ApolloSafariShieldFor(self);
    if (!shield || shield.anchored) return;
    shield.anchored = YES;
    ApolloSafariShieldScheduleRamp(self, kApolloSafariShieldHoldAfterWebView, @"web view created");
}

- (void)remoteViewController:(id)remoteViewController didFinishInitialLoad:(BOOL)didLoadSuccessfully {
    %orig;
    ApolloSafariShieldFade(self, kApolloSafariShieldFinishDuration,
                           didLoadSuccessfully ? @"initial load finished" : @"initial load failed");
}

- (void)remoteViewController:(id)remoteViewController viewServiceDidTerminateWithError:(id)error {
    // The host swaps its own placeholder back in and restarts the service;
    // nothing for the shield to cover in the meantime.
    ApolloSafariShieldRemoveNow(self, @"view service terminated");
    %orig;
}

%end

%end

%ctor {
    Class safariClass = objc_getClass("SFSafariViewController");
    if (!safariClass) {
        ApolloLog(@"[SafariDark] SFSafariViewController unavailable, module idle");
        return;
    }
    %init(ApolloSafariDarkLoadingBase);

    BOOL hasWebViewCallback = class_getInstanceMethod(safariClass, @selector(remoteViewControllerDidLoadWebView:)) != NULL;
    BOOL hasFinishCallback = class_getInstanceMethod(safariClass, @selector(remoteViewController:didFinishInitialLoad:)) != NULL;
    BOOL hasTerminateCallback = class_getInstanceMethod(safariClass, @selector(remoteViewController:viewServiceDidTerminateWithError:)) != NULL;
    if (hasWebViewCallback && hasFinishCallback && hasTerminateCallback) {
        %init(ApolloSafariDarkLoadingRemote);
        ApolloLog(@"[SafariDark] module loaded (remote callbacks hooked)");
    } else {
        ApolloLog(@"[SafariDark] module loaded (remote callbacks missing: webView=%d finish=%d terminate=%d; fallback timing only)",
                  hasWebViewCallback, hasFinishCallback, hasTerminateCallback);
    }
}
