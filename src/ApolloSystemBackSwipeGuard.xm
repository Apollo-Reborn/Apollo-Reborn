// ApolloSystemBackSwipeGuard — keep UIKit's own swipe-back recognizers out of Apollo's
// navigation controller, so Apollo's back/forward pans (and the Gestures settings that govern
// them) are the only swipe navigation on its stacks.
//
// THE SYMPTOM (#1330)
// With Settings > Gestures > Disable Navigation Gestures on, a swipe from the left edge of a
// thread still went back, and the comment swipe action never ran. On Liquid Glass a right swipe
// that started mid-screen could pop the thread too, even with the setting off, instead of
// running the comment's swipe action.
//
// THE CAUSE (Hopper: Apollo 1.15.11; decompiled UIKitCore 23B85; live sim trace on 27.0)
// ApolloNavigationController navigates with its own two pans on its container view
// (leftScreenEdgePanGestureRecognizer / rightScreenEdgePanGestureRecognizer, both driving
// screenEdgePanned:), and its gestureRecognizerShouldBegin: (sub_10015d644) refuses them while
// DisableNavigationGestures is set. Apollo never touches UIKit's back recognizers (the binary
// has no interactivePopGestureRecognizer reference), but UINavigationController still builds
// them on the same view: "UINavigationController.edgeSwipe" (interactivePopGestureRecognizer)
// and, in apps linked against the iOS 26 SDK (the Liquid Glass builds), the full-width
// "UINavigationController.contentSwipe" (interactiveContentPopGestureRecognizer).
//
// They normally sit out. _UINavigationInteractiveTransition's _gestureRecognizer:
// shouldReceiveEvent: refuses every event to them while the navigation controller runs a custom
// interaction controller (_shouldUseBuiltinInteractionController is NO for every Apollo push and
// pop), with one exception: if either recognizer carries failure requirements or dependents
// beyond UIKit's own edge/content pairing, UIKit assumes the app wired it deliberately and lets
// it in. Several Reborn features add exactly that, so their own drags win over swipe-back: the
// Community Highlights carousel, the feed video scrubber, the icon row magnifier, the inbox Chat
// mode pan, the standalone chat back pan, the photo composer strip, the app icon picker and the
// AI / inline media settings sliders call requireGestureRecognizerToFail: on
// interactivePopGestureRecognizer, or on every pan up their ancestor chain, which includes both
// UIKit recognizers. The first time one of them runs on a stack (the Highlights carousel does on
// any subreddit with pinned posts), UIKit's swipe-back goes live there for good. It then pops on
// its own: the edge swipe on every build, the content swipe anywhere in the page on Liquid Glass,
// with no Apollo setting able to stop it. (Measured: opening a subreddit with Community
// Highlights, or a feed video with the scrubber on, turns a thread's left-edge swipe from
// "refused" into a committed pop while Disable Navigation Gestures is on.)
//
// THE FIX
// Answer NO from that same gate for the back recognizers of an ApolloNavigationController,
// which is what UIKit answers there until something wires them. They then never see a touch,
// so they also never hold up the scroll views and swipe actions that would otherwise wait on
// them, the same as a stock Apollo stack. Navigation controllers that rely on UIKit's swipe-back
// (plain UINavigationControllers presented modally, the tweak's own sheets) are left alone, and
// the wiring above keeps working there. Apollo's own pans, the tab bar swipe (ApolloTabBarController
// tabBarPanned: drives the same pop/push handler) and the gallery's boundary hand-off all go
// through Apollo's recognizers and are unaffected.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

static Class sApolloNavigationControllerClass;

// UIKit installs both back recognizers on the navigation controller's own view, whose next
// responder is the controller itself.
static UINavigationController *ApolloSystemBackSwipeOwner(UIGestureRecognizer *recognizer) {
    UIResponder *owner = recognizer.view.nextResponder;
    return [owner isKindOfClass:sApolloNavigationControllerClass] ? (UINavigationController *)owner : nil;
}

static NSString *ApolloSystemBackSwipeKind(UINavigationController *navigationController,
                                           UIGestureRecognizer *recognizer) {
    if (recognizer == navigationController.interactivePopGestureRecognizer) return @"edge";
    if (@available(iOS 26.0, *)) {
        if (recognizer == navigationController.interactiveContentPopGestureRecognizer) return @"content";
    }
    return nil;
}

%group ApolloSystemBackSwipeGuard
%hook _UINavigationInteractiveTransition

- (BOOL)_gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveEvent:(UIEvent *)event {
    // UIKit already answers NO for every Apollo stack nothing has wired, so that common case
    // costs nothing beyond the original call.
    BOOL receive = %orig;
    if (!receive) return NO;

    UINavigationController *navigationController = ApolloSystemBackSwipeOwner(recognizer);
    if (!navigationController) return YES;
    NSString *kind = ApolloSystemBackSwipeKind(navigationController, recognizer);
    if (!kind) return YES;

    // One line per touch is plenty (UIKit asks for both recognizers on every touch down).
    static CFAbsoluteTime lastLog;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastLog > 1.0) {
        lastLog = now;
        ApolloLog(@"[SystemBackSwipe] kept UIKit's %@ back swipe out of %@ (left to Apollo's navigation pans)",
                  kind, NSStringFromClass([navigationController.topViewController class]));
    }
    return NO;
}

%end
%end

%ctor {
    sApolloNavigationControllerClass = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    Class transitionClass = objc_getClass("_UINavigationInteractiveTransition");
    SEL gate = NSSelectorFromString(@"_gestureRecognizer:shouldReceiveEvent:");
    if (!sApolloNavigationControllerClass || !transitionClass ||
        !class_getInstanceMethod(transitionClass, gate)) {
        ApolloLog(@"[SystemBackSwipe] ApolloNavigationController or UIKit's back swipe gate not found; inactive");
        return;
    }
    %init(ApolloSystemBackSwipeGuard);
    ApolloLog(@"[SystemBackSwipe] hook installed (UIKit's edge/content back swipes stay out of Apollo's navigation stacks)");
}
