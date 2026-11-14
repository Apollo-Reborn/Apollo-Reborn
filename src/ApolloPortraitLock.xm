#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "ApolloDuoSplitView.h"
#import "ApolloSwiftRuntime.h"

// Apollo 1.15.11: the lazy getter (0x1003495c4) creates a UIControl.
// Fresh offers setAlpha:1 (0x10034b800); animated dismissal setsAlpha:0
// (0x10037a110), then removes it and asynchronously resets alpha to 1
// (0x10037a2e0-31c). Verified in the local base binary with llvm-objdump.
// There is no ObjC show-offer method. Intercept this class's alpha writes,
// not UIView or motion delivery; leave native tracking/attachment untouched.
static BOOL ApolloNativeRotationOfferSuppressed(void) {
    // UIKit callbacks arrive on main; never query the shared UI policy off it.
    return NSThread.isMainThread && ApolloDuoSplitIsUnfolded();
}

static void ApolloNativeRotationOfferSyncButton(UIView *button) {
    if (!button || !ApolloNativeRotationOfferSuppressed()) return;
    [UIView performWithoutAnimation:^{ button.alpha = 0.0; }];
    // A visible offer may already be mid-fade when the display unfolds.
    [button.layer removeAnimationForKey:@"opacity"];
    // Deliberately no fold branch: never replay a pre-unfold show request.
    // The next native alpha decision, not our lifecycle hook, may show it.
    // Both native show branches reset alpha to 1 (0x10034b800, 0x10034bc40),
    // even for an attached control. The same-offer early exit at 0x10034b610
    // does not: that old offer stays suppressed until a new native decision.
}

static void ApolloNativeRotationOfferSyncViewer(UIViewController *viewer) {
    if (!ApolloNativeRotationOfferSuppressed()) return;
    // Read existing lazy storage only; do not initialize it or inspect Swift
    // trackedRotationData. Missing/changed class or storage is a safe no-op.
    id button = ApolloObjectIvar(viewer, "$__lazy_storage_$_rotationOfferingButton");
    static Class buttonClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ buttonClass = NSClassFromString(@"_TtC6Apollo22RotationOfferingButton"); });
    if (buttonClass && [button isKindOfClass:buttonClass] && [button isKindOfClass:UIControl.class]) {
        ApolloNativeRotationOfferSyncButton(button);
    }
}

%hook _TtC6Apollo22RotationOfferingButton

- (void)setAlpha:(CGFloat)alpha {
    BOOL suppressed = ApolloNativeRotationOfferSuppressed();
    %orig(suppressed ? 0.0 : alpha);
    if (suppressed) [((UIView *)self).layer removeAnimationForKey:@"opacity"];
}

- (void)didMoveToSuperview {
    %orig;
    // Native can attach a newly created control at its default alpha, without
    // going through a setter first. Suppress it before the first rendered frame.
    ApolloNativeRotationOfferSyncButton((UIView *)self);
}

%end

%hook _TtC6Apollo21MediaViewerController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloNativeRotationOfferSyncViewer((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloNativeRotationOfferSyncViewer((UIViewController *)self);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    UIViewController *viewer = (UIViewController *)self;
    ApolloNativeRotationOfferSyncViewer(viewer);
    %orig(size, coordinator);
    ApolloNativeRotationOfferSyncViewer(viewer);
    // Re-read the shared predicate each time. It already uses target dimensions
    // while the main tabs resize; never infer pose from this fullscreen page.
    __weak UIViewController *weakViewer = viewer;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        UIViewController *strongViewer = weakViewer;
        ApolloNativeRotationOfferSyncViewer(strongViewer);
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        UIViewController *strongViewer = weakViewer;
        ApolloNativeRotationOfferSyncViewer(strongViewer);
    }];
}

- (void)rotationOfferingButtonTappedWithSender:(id)sender {
    // Already queued actions must not rotate after an unfold, even if the
    // control was removed or the current viewer has no lazy button yet.
    if (ApolloNativeRotationOfferSuppressed()) return;
    %orig;
}

%end
