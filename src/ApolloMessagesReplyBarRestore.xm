// ApolloMessagesReplyBarRestore.xm
//
// Message threads (modmail, private messages, legacy chat mirrors): bring the
// reply bar back after a cancelled swipe-back.
//
// The thread screen is PrivateMessageViewController, the only subclass of the
// MessageKit 2.x `MessagesViewController` Apollo vendors. Its reply bar
// (MessageInputBar) is the controller's inputAccessoryView, so UIKit only shows
// it while the controller itself is first responder.
//
// THE SYMPTOM
// Open a thread from another thread (a "Recent Modmail" link in the user-info
// bubble, a link to another conversation), start a swipe-back and let go so it
// cancels. The thread settles back without its reply bar and there is no way to
// reply until you leave and re-enter it.
//
// THE CAUSE (UIKitCore 23B85, confirmed with a runtime trace on iOS 26.5)
// When an interactive pop starts, UINavigationController's input-view pinning
// asks the INCOMING controller to become first responder. Another thread says
// yes, so the outgoing thread resigns and its bar leaves the window. When the
// swipe is cancelled, -_didCancelTransitionFromViewController:... restores the
// outgoing thread's saved input views, which sends it -becomeFirstResponder.
// That happens before UIKit replays the cancel's viewWillAppear:/viewDidAppear:,
// while the thread is still in the "disappearing" appearance state, and
// -[UIViewController _canBecomeFirstResponder] refuses any controller in that
// state. The restore still reports success because a saved entry existed, so
// UIKit skips its own becomeFirstResponder fallback, and the incoming thread
// resigns as its view leaves. Nothing is first responder, so there is no bar.
// Swiping back to a screen that can't become first responder (the modmail list,
// comments) never takes the responder away, which is why an ordinary cancelled
// swipe keeps the bar. This happens with Apollo's own animator and with the
// Liquid Glass interruptible one; both finish through the same UIKit handler.
//
// THE FIX
// When a thread that owns the responder (bar docked) begins an interactive
// disappearance, watch that transition. If it is cancelled, re-assert first
// responder on the next main-queue turn: by then UIKit's cancel handling and
// the appearance callbacks have run and the thread is "appeared" again. Only
// when the thread is the visible top of its navigation stack, nothing is
// presented over it, no other transition has started, and its bar is not in a
// window. Committed pops, threads whose keyboard was up (UIKit restores the
// text view itself), and every non-interactive path are left alone.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

@interface _TtC6Apollo22MessagesViewController : UIViewController
@end

static void ApolloMessagesRestoreReplyBarAfterCancelledPop(UIViewController *controller) {
    if (!controller.isViewLoaded || !controller.view.window) return;
    UINavigationController *navigationController = controller.navigationController;
    if (navigationController.topViewController != controller ||
        navigationController.visibleViewController != controller) return;
    if (controller.presentedViewController || navigationController.transitionCoordinator) return;
    if (controller.isFirstResponder || !controller.canBecomeFirstResponder) return;
    UIView *bar = controller.inputAccessoryView;
    // A bar in a window is docked already, or rides above a keyboard whose text
    // view UIKit did restore. Either way the thread is fine.
    if (!bar || bar.window) return;
    // UIKit docks the bar a moment after this returns, so the result is the signal.
    BOOL restored = [controller becomeFirstResponder];
    ApolloLog(@"[MessagesReplyBar] cancelled swipe-back left %@ %p without its reply bar; becomeFirstResponder -> %d",
              NSStringFromClass(controller.class), controller, restored);
}

%hook _TtC6Apollo22MessagesViewController

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    UIViewController *controller = (UIViewController *)self;
    id<UIViewControllerTransitionCoordinator> coordinator = controller.transitionCoordinator;
    // Only an interactive transition can be cancelled, and only a thread that
    // owns the responder has a docked bar for UIKit to lose.
    if (!coordinator.isInteractive || !controller.isFirstResponder) return;
    __weak UIViewController *weakController = controller;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (!context.isCancelled) return;
        // This runs inside completeTransition:, after the navigation controller's
        // cancel handling. Let the rest of the transition teardown finish first.
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloMessagesRestoreReplyBarAfterCancelledPop(weakController);
        });
    }];
}

%end

%ctor {
    Class controllerClass = objc_getClass("_TtC6Apollo22MessagesViewController");
    if (!controllerClass || !class_getInstanceMethod(controllerClass, @selector(viewWillDisappear:))) {
        ApolloLog(@"[MessagesReplyBar] MessagesViewController missing; hook not installed");
        return;
    }
    %init;
    ApolloLog(@"[MessagesReplyBar] hook installed (restore the reply bar after a cancelled swipe-back)");
}
