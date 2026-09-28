// ApolloMessagesKeyboardInset.xm
//
// Message threads (modmail, private messages, legacy chat mirrors): keep the
// newest message clear of the reply bar on iOS 26+. Reported on a native
// modmail thread: the last message sat behind the "Reply" bar and snapped back
// under it after every scroll, and only cleared it while the keyboard was up.
//
// The thread screen is PrivateMessageViewController, the only subclass of the
// MessageKit 2.x `MessagesViewController` Apollo vendors. Its reply bar
// (MessageInputBar) is the controller's inputAccessoryView, and MessageKit keeps
// the list's bottom inset in sync with it from ONE input:
// -handleKeyboardDidChangeState:, observing UIKeyboardWillChangeFrameNotification.
// (The only other write is the first layout pass, which runs before UIKit
// installs the bar and so computes 0.) Recovered from the binary (1.15.11,
// handler body 0x10052a7dc, frame math 0x10052ac3c):
//   - the begin frame is read once, for MessageKit's iOS 11 iPad-undocking
//     workaround: an EMPTY begin frame drops the whole notification;
//   - the end frame is intersected with the collection view; a frame that does
//     not reach the list's bottom edge means "nothing docked", so the inset
//     becomes additionalBottomInset minus the safe area, i.e. 0.
//
// So the inset is only right if UIKit reports the bar-only (keyboard down)
// state with real frames. Neither current system does (measured in the sim):
//   1. iOS 26: when the thread becomes first responder and the bar docks, the
//      notification's begin frame is {screen centre, 0x0}. MessageKit drops it
//      as the iPad artefact, so the inset stays 0 and the bar covers the newest
//      message from the moment the thread opens.
//   2. iOS 26: on the way down from a keyboard UIKit posts an interim end frame
//      of CGRectZero (and iOS 27 posts a zero-height one when the app returns to
//      the foreground). MessageKit reads it as "nothing docked" and drops the
//      inset back to 0. A later re-dock event repairs that after a programmatic
//      resign; in the report's recording the thread was still cut off after the
//      keyboard was swiped away.
//   3. iOS 27: the bar docks with no keyboard notification at all, so the inset
//      stays 0 until the keyboard is first opened and closed.
//
// Fix, always letting Apollo's own calculator produce the inset (it owns
// additionalBottomInset, the safe-area subtraction,
// maintainPositionOnKeyboardFrameChanged and the inverted-list branch of the
// inset setter):
//   - (1) empty begin + a real end frame docked at the screen bottom:
//     begin := end, so the event is processed;
//   - (2) empty end while the reply bar is on screen: end := the bar's frame
//     extended to the window bottom (the shape every other bar-only event has).
//     With no bar on screen the empty frame passes through and Apollo correctly
//     computes 0;
//   - (3) when the bar joins a window, re-run the handler on the next turn with
//     the docked bar's region. The bar is laid out by then and the push
//     transition is still running (measured: ~0.1s after the move, ~0.4s before
//     viewDidAppear, before the thread's messages arrive), so Apollo's own
//     scroll-to-newest lands above the bar. Keyboard-up states are left to
//     UIKit's notifications, which both systems still send correctly.
// Real keyboard frames, threads that are not in a window, and iOS < 26 are
// untouched.

#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

@interface _TtC6Apollo22MessagesViewController : UIViewController
@end

@interface _TtC6Apollo15MessageInputBar : UIView
@end

// Zeroing-weak link from a reply bar to the thread controller that hands it to
// UIKit (the bar keeps no reachable pointer back to it).
@interface ApolloMessagesReplyBarOwnerBox : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end
@implementation ApolloMessagesReplyBarOwnerBox
@end

static const void *kApolloMessagesReplyBarOwnerKey = &kApolloMessagesReplyBarOwnerKey;

// All three shapes are iOS 26/27 behaviour; earlier systems report real frames
// and MessageKit's stock handling is correct there.
static BOOL ApolloMessagesKeyboardInsetEnabled(void) {
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

static BOOL ApolloMessagesKeyboardRectIsUsable(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height) &&
        !CGRectIsNull(rect) && !CGRectIsInfinite(rect) && !CGRectIsEmpty(rect);
}

// The reply bar's frame in the thread window's coordinates, or CGRectNull when
// it is not on screen. MessageKit converts notification frames "from
// view.window", so window coordinates are what it expects. The bar lives in
// UIKit's keyboard window; -convertRect:fromView: maps across windows through
// the screen.
static CGRect ApolloMessagesReplyBarFrame(UIViewController *controller) {
    UIWindow *window = controller.isViewLoaded ? controller.view.window : nil;
    UIView *bar = controller.inputAccessoryView;
    if (!window || !bar.window || bar.hidden || bar.alpha < 0.01) return CGRectNull;
    CGRect frame = [window convertRect:bar.bounds fromView:bar];
    if (!ApolloMessagesKeyboardRectIsUsable(frame)) return CGRectNull;
    // Parked below the window (mid-teardown): nothing covers the list.
    if (CGRectGetMinY(frame) >= CGRectGetMaxY(window.bounds) - 0.5) return CGRectNull;
    return frame;
}

// What the reply bar covers: its frame extended down to the window's bottom
// edge (above a keyboard that is bar + keyboard; docked it is bar + the
// home-indicator strip). The same shape UIKit reports for real frames.
static CGRect ApolloMessagesReplyBarRegion(UIViewController *controller) {
    CGRect bar = ApolloMessagesReplyBarFrame(controller);
    if (CGRectIsNull(bar)) return CGRectNull;
    CGRect windowBounds = controller.view.window.bounds;
    CGFloat top = MAX(CGRectGetMinY(bar), CGRectGetMinY(windowBounds));
    return CGRectMake(CGRectGetMinX(windowBounds), top,
                      CGRectGetWidth(windowBounds), CGRectGetMaxY(windowBounds) - top);
}

static NSNotification *ApolloMessagesKeyboardNotification(NSNotification *notification,
                                                          CGRect begin, CGRect end) {
    NSMutableDictionary *userInfo = [notification.userInfo mutableCopy]
        ?: [NSMutableDictionary dictionary];
    userInfo[UIKeyboardFrameBeginUserInfoKey] = [NSValue valueWithCGRect:begin];
    userInfo[UIKeyboardFrameEndUserInfoKey] = [NSValue valueWithCGRect:end];
    return [NSNotification notificationWithName:notification.name
                                          object:notification.object
                                        userInfo:userInfo];
}

// Returns the notification MessageKit should see, or nil to deliver the
// original unchanged. Only unusable frames are replaced; a real end frame is
// always trusted.
static NSNotification *ApolloMessagesNormalizedKeyboardNotification(UIViewController *controller,
                                                                    NSNotification *notification) {
    if (!ApolloMessagesKeyboardInsetEnabled()) return nil;
    // MessageKit observes globally, so threads further down a navigation stack
    // see other screens' keyboards too. Only the on-screen thread owns a docked
    // bar; everything else keeps stock handling and is re-synced by (3) when its
    // bar docks again.
    if (!controller.isViewLoaded || !controller.view.window) return nil;

    NSDictionary *userInfo = [notification.userInfo isKindOfClass:NSDictionary.class]
        ? notification.userInfo : nil;
    id beginValue = userInfo[UIKeyboardFrameBeginUserInfoKey];
    id endValue = userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![beginValue respondsToSelector:@selector(CGRectValue)] ||
        ![endValue respondsToSelector:@selector(CGRectValue)]) return nil;
    CGRect begin = [beginValue CGRectValue];
    CGRect end = [endValue CGRectValue];
    BOOL beginUsable = ApolloMessagesKeyboardRectIsUsable(begin);

    if (ApolloMessagesKeyboardRectIsUsable(end)) {
        if (beginUsable) return nil;
        // (1) The iOS 26 dock event. Only rescue frames docked at the bottom of
        // the screen; a floating or undocked keyboard keeps MessageKit's iPad
        // workaround.
        UIScreen *screen = [notification.object isKindOfClass:UIScreen.class]
            ? (UIScreen *)notification.object : controller.view.window.screen;
        if (!screen || CGRectGetMaxY(end) < CGRectGetMaxY(screen.bounds) - 0.5) return nil;
        ApolloLog(@"[MessagesKeyboardInset] empty begin frame %@ (reply bar docking) -> begin=end %@",
                  NSStringFromCGRect(begin), NSStringFromCGRect(end));
        return ApolloMessagesKeyboardNotification(notification, end, end);
    }

    // (2) An empty end frame. If the reply bar is still on screen it is what
    // covers the list, so describe it; otherwise let MessageKit see the empty
    // frame and compute 0 (bar gone, e.g. a sheet took first responder).
    CGRect region = ApolloMessagesReplyBarRegion(controller);
    if (CGRectIsNull(region)) return nil;
    ApolloLog(@"[MessagesKeyboardInset] empty end frame %@ with the reply bar on screen -> end=%@",
              NSStringFromCGRect(end), NSStringFromCGRect(region));
    return ApolloMessagesKeyboardNotification(notification, beginUsable ? begin : region, region);
}

static UIScrollView *ApolloMessagesCollectionView(UIViewController *controller) {
    static Ivar ivar = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("_TtC6Apollo22MessagesViewController");
        if (cls) ivar = class_getInstanceVariable(cls, "messagesCollectionView");
    });
    id view = ivar ? object_getIvar(controller, ivar) : nil;
    return [view isKindOfClass:UIScrollView.class] ? (UIScrollView *)view : nil;
}

// (3) Hand Apollo's handler the docked bar as a keyboard frame, exactly as iOS
// used to report it. Keyboard-down only: with the keyboard up the bar is
// hosted above it and UIKit's own notifications describe that state.
static void ApolloMessagesSyncDockedReplyBar(UIViewController *controller) {
    if (!ApolloMessagesKeyboardInsetEnabled() || !controller.isViewLoaded) return;
    UIWindow *window = controller.view.window;
    CGRect bar = ApolloMessagesReplyBarFrame(controller);
    if (!window || CGRectIsNull(bar) ||
        fabs(CGRectGetMaxY(bar) - CGRectGetMaxY(window.bounds)) > 1.0) return;
    CGRect region = ApolloMessagesReplyBarRegion(controller);
    if (CGRectIsNull(region)) return;

    NSDictionary *userInfo = @{
        UIKeyboardFrameBeginUserInfoKey: [NSValue valueWithCGRect:region],
        UIKeyboardFrameEndUserInfoKey: [NSValue valueWithCGRect:region],
        UIKeyboardAnimationDurationUserInfoKey: @0,
        UIKeyboardAnimationCurveUserInfoKey: @(UIViewAnimationCurveEaseInOut),
        UIKeyboardIsLocalUserInfoKey: @YES,
    };
    NSNotification *notification =
        [NSNotification notificationWithName:UIKeyboardWillChangeFrameNotification
                                      object:window.screen
                                    userInfo:userInfo];
    UIScrollView *list = ApolloMessagesCollectionView(controller);
    UIEdgeInsets before = list.contentInset;
    ((void (*)(id, SEL, NSNotification *))objc_msgSend)(
        controller, NSSelectorFromString(@"handleKeyboardDidChangeState:"), notification);
    UIEdgeInsets after = list.contentInset;
    if (!UIEdgeInsetsEqualToEdgeInsets(before, after)) {
        ApolloLog(@"[MessagesKeyboardInset] reply bar docked at %@ -> inset %@ -> %@",
                  NSStringFromCGRect(bar), NSStringFromUIEdgeInsets(before),
                  NSStringFromUIEdgeInsets(after));
    }
}

%hook _TtC6Apollo22MessagesViewController

- (void)handleKeyboardDidChangeState:(NSNotification *)notification {
    NSNotification *normalized = ApolloMessagesNormalizedKeyboardNotification(
        (UIViewController *)self, notification);
    %orig(normalized ?: notification);
}

// Safety net for (3): if the bar docked before the thread's view reached a
// window, the next-turn sync above bailed. By viewDidAppear both are settled.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloMessagesSyncDockedReplyBar((UIViewController *)self);
}

// UIKit asks the first responder for this right before docking the bar, so it
// is the one place that knows which controller a bar belongs to.
- (UIView *)inputAccessoryView {
    UIView *bar = %orig;
    if (bar && ApolloMessagesKeyboardInsetEnabled()) {
        ApolloMessagesReplyBarOwnerBox *box = objc_getAssociatedObject(bar, kApolloMessagesReplyBarOwnerKey);
        if (box.controller != (UIViewController *)self) {
            box = [ApolloMessagesReplyBarOwnerBox new];
            box.controller = (UIViewController *)self;
            objc_setAssociatedObject(bar, kApolloMessagesReplyBarOwnerKey, box,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return bar;
}

%end

%hook _TtC6Apollo15MessageInputBar

- (void)didMoveToWindow {
    %orig;
    if (!ApolloMessagesKeyboardInsetEnabled() || !self.window) return;
    ApolloMessagesReplyBarOwnerBox *box = objc_getAssociatedObject(self, kApolloMessagesReplyBarOwnerKey);
    if (!box.controller) return;
    // UIKit sizes and places the bar after this callback (it is still
    // zero-sized here), so measure on the next turn. Re-check everything: the
    // bar may have left again or been handed to another controller.
    __weak UIView *weakBar = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *bar = weakBar;
        UIViewController *controller = box.controller;
        if (!bar.window || !controller || controller.inputAccessoryView != bar) return;
        ApolloMessagesSyncDockedReplyBar(controller);
    });
}

%end

%ctor {
    Class controllerClass = objc_getClass("_TtC6Apollo22MessagesViewController");
    Class barClass = objc_getClass("_TtC6Apollo15MessageInputBar");
    if (!controllerClass || !barClass ||
        !class_getInstanceMethod(controllerClass, NSSelectorFromString(@"handleKeyboardDidChangeState:"))) {
        ApolloLog(@"[MessagesKeyboardInset] MessageKit classes or handler missing; hooks not installed");
        return;
    }
    %init;
    ApolloLog(@"[MessagesKeyboardInset] hooks installed (reply-bar inset on iOS 26+: dock events, empty keyboard frames, silent dock)");
}
