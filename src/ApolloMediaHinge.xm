// ApolloMediaHinge.xm
//
// Keep Apollo's fullscreen MediaPage chrome (close button and anything that
// mirrors it) off a hinge-sized gutter. Stock MediaViewer is a single
// full-bleed pager — wrapping it in UIArrangementViewController would break
// presentation, swipe-up comments, and PiP. UIKit reservedRegions SIGSEGVs
// on Duo even with window+scene during first commit, so avoidance is
// chrome / layoutMargins only (empty reserved list).
//
// On open Duo the viewer is pinned to the trailing half (same rect as the
// comments/detail pane) so an image opened from the right post does not
// full-bleed under the hinge. Dismiss re-applies FeedSplit (the presentation
// otherwise leaves the feed stretched across both panes).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloDeviceChromeInsets.h"
#import "ApolloDeviceReservedRegions.h"
#import "ApolloDuoRail.h"
#import "ApolloFeedSplitLayout.h"

static id ApolloMediaHingeIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static void ApolloMediaHingeAvoidPageChrome(UIViewController *page) {
    if (!page.isViewLoaded) return;
    UIView *close = ApolloMediaHingeIvar(page, "closeButton");
    if ([close isKindOfClass:[UIView class]]) {
        ApolloDeviceAvoidReservedRegionsForView(close);
    }
}

static CGRect ApolloMediaHingeTrailingFrame(UIView *container) {
    if (!container) return CGRectZero;
    CGSize size = container.bounds.size;
    if (size.width < 8.0 || size.height < 8.0) return CGRectZero;
    UIEdgeInsets safe = container.safeAreaInsets;
    UIEdgeInsets margins = container.layoutMargins;
    double extraLeft = ApolloDeviceChromeExtra(safe.left, margins.left);
    double extraRight = ApolloFeedSplitTrailingExtra(
        ApolloDeviceChromeExtra(safe.right, margins.right),
        ApolloDuoRailIsActive() ? 1 : 0);
    BOOL rtl = NO;
    if ([container respondsToSelector:@selector(effectiveUserInterfaceLayoutDirection)]) {
        rtl = container.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    }
    ApolloFeedSplitFrames frames = ApolloFeedSplitFramesMake(
        size.width, size.height,
        extraLeft, extraRight,
        ApolloFeedSplitModeTiled, rtl ? 1 : 0,
        ApolloFeedSplitTileBalanced, 0.0, 0.0,
        ApolloDuoRailIsActive() ? 1 : 0);
    if (frames.detail.width < 8.0) return CGRectZero;
    return CGRectMake((CGFloat)frames.detail.x, (CGFloat)frames.detail.y,
                      (CGFloat)frames.detail.width, (CGFloat)frames.detail.height);
}

static BOOL ApolloMediaHingeContainerIsTrailingPane(UIView *container) {
    UIView *ref = container.window ?: container.superview;
    if (!container || !ref) return NO;
    CGRect frame = [container convertRect:container.bounds toView:ref];
    return frame.origin.x + 0.5 >= ref.bounds.size.width * 0.35;
}

static void ApolloMediaHingePinToTrailingHalf(UIViewController *controller) {
    if (!controller || !ApolloDuoRailIsActive()) return;
    if (!controller.isViewLoaded) return;
    UIView *view = controller.view;
    UIView *container = view.superview;
    if (!container) return;
    CGRect target;
    if (ApolloMediaHingeContainerIsTrailingPane(container)) {
        target = container.bounds;
    } else {
        target = ApolloMediaHingeTrailingFrame(container);
    }
    if (CGRectIsEmpty(target)) return;
    view.clipsToBounds = YES;
    view.autoresizingMask = UIViewAutoresizingNone;
    if (CGRectEqualToRect(view.frame, target)) return;
    view.frame = target;
}

static void ApolloMediaHingeReapplySplitSoon(void) {
    if (!ApolloDuoRailIsActive()) return;
    ApolloFeedSplitReapplySoon();
}

%hook _TtC6Apollo21MediaViewerController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloMediaHingePinToTrailingHalf((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    ApolloMediaHingeReapplySplitSoon();
}

%end

%hook _TtC6Apollo23MediaPageViewController

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloMediaHingeAvoidPageChrome((UIViewController *)self);
    ApolloMediaHingePinToTrailingHalf((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    ApolloMediaHingeReapplySplitSoon();
}

%end

%hook _TtC6Apollo33MediaViewerPresentationController

- (void)containerViewWillLayoutSubviews {
    %orig;
    if (!ApolloDuoRailIsActive()) return;
    UIPresentationController *presentation = (UIPresentationController *)self;
    UIView *container = presentation.containerView;
    UIView *presented = presentation.presentedView;
    if (!container || !presented) return;
    CGRect trailing = ApolloMediaHingeTrailingFrame(container);
    if (CGRectIsEmpty(trailing)) return;
    presented.clipsToBounds = YES;
    presented.autoresizingMask = UIViewAutoresizingNone;
    if (!CGRectEqualToRect(presented.frame, trailing)) {
        presented.frame = trailing;
    }
}

- (void)dismissalTransitionDidEnd:(BOOL)completed {
    %orig;
    (void)completed;
    ApolloMediaHingeReapplySplitSoon();
}

%end

%ctor {
    Class page = objc_getClass("_TtC6Apollo23MediaPageViewController");
    if (!page) {
        ApolloLog(@"[MediaHinge] MediaPageViewController missing; viewer chrome skip");
        return;
    }
    %init;
    ApolloLog(@"[MediaHinge] MediaPage chrome hinge avoidance installed (Duo trailing pin)");
}
