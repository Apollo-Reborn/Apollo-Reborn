// iPad Layout: a message thread's reply bar lives in the thread's own view.
//
// Native threads (PrivateMessageViewController, MessageKit's
// MessagesViewController) hand their MessageInputBar to UIKit as the
// controller's inputAccessoryView. UIKit only shows an accessory view while its
// owner is first responder, and always across the full window. On a phone that
// works because the navigation push makes the thread first responder. In the
// split view it fails both ways:
//   - nothing makes a thread opened in the detail column first responder, and
//     the sidebar, the list column and tab switches take or clear the
//     responder, so the bar was missing or vanished and you couldn't reply;
//   - when it did show, it spanned both columns.
//
// While the layout is active, return no accessory view and add the bar to the
// thread's view instead: full width of the detail column, its bottom on the
// keyboard layout guide so it rides above the keyboard, with a filler carrying
// its background through the home-indicator strip. Its visibility no longer
// depends on who is first responder.
//
// MessageKit sizes the list's bottom inset from keyboard notifications that, in
// accessory mode, include the bar. Here they would only describe the keyboard,
// so real notifications are dropped for embedded threads and Apollo's own
// handler is fed the bar's actual region (bar top to window bottom) after each
// layout pass. Apollo's calculator still owns the inset, the inverted-list
// branch and keeping the scroll position (see ApolloMessagesKeyboardInset.xm).

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloPaneLayout.h"
#import "../ApolloCommon.h"
#import "../ApolloSwiftRuntime.h"

static NSString *const kApolloPaneMessageBarRegionKey = @"ApolloPaneMessageBarRegion";
static char kApolloPaneMessageBarStateKey;

@interface ApolloPaneMessageBarState : NSObject
@property (nonatomic, weak) UIView *bar;
@property (nonatomic, strong) UIView *filler;
@property (nonatomic) CGRect lastRegion;
@end
@implementation ApolloPaneMessageBarState
@end

@interface _TtC6Apollo22MessagesViewController : UIViewController
@end

static ApolloPaneMessageBarState *ApolloPaneMessageBarStateFor(UIViewController *controller) {
    return objc_getAssociatedObject(controller, &kApolloPaneMessageBarStateKey);
}

static UIView *ApolloPaneMessageInputBar(UIViewController *controller) {
    id bar = ApolloObjectIvar(controller, "messageInputBar");
    return [bar isKindOfClass:UIView.class] ? (UIView *)bar : nil;
}

// The bar's own background, carried below it so the home-indicator strip
// matches instead of showing the list through it.
static void ApolloPaneMessageBarMatchFiller(ApolloPaneMessageBarState *state) {
    UIView *background = ApolloObjectIvar(state.bar, "backgroundView");
    UIColor *color = [background isKindOfClass:UIView.class] ? background.backgroundColor : nil;
    state.filler.backgroundColor = color ?: state.bar.backgroundColor;
}

static void ApolloPaneMessageBarEmbed(UIViewController *controller) {
    if (@available(iOS 15.0, *)) {
        if (ApolloPaneMessageBarStateFor(controller)) return;
        UIView *bar = ApolloPaneMessageInputBar(controller);
        UIView *view = controller.viewIfLoaded;
        if (!bar || !view) {
            ApolloLog(@"[PaneMessageBar] %@ has no reply bar to embed; keeping the accessory view",
                      NSStringFromClass(controller.class));
            return;
        }
        ApolloPaneMessageBarState *state = [ApolloPaneMessageBarState new];
        state.bar = bar;
        state.lastRegion = CGRectNull;
        // Mark the thread before touching the bar: from here on it reports no
        // accessory view, so UIKit releases the bar rather than re-hosting it.
        objc_setAssociatedObject(controller, &kApolloPaneMessageBarStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [controller reloadInputViews];
        [bar removeFromSuperview];

        UIView *filler = [UIView new];
        filler.translatesAutoresizingMaskIntoConstraints = NO;
        state.filler = filler;
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:filler];
        [view addSubview:bar];
        [NSLayoutConstraint activateConstraints:@[
            [bar.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [bar.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [bar.bottomAnchor constraintEqualToAnchor:view.keyboardLayoutGuide.topAnchor],
            [filler.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [filler.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [filler.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
            [filler.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        ]];
        ApolloPaneMessageBarMatchFiller(state);
        ApolloLog(@"[PaneMessageBar] embedded the reply bar of %@ %p in its view",
                  NSStringFromClass(controller.class), controller);
    }
}

static void ApolloPaneMessageBarRunHandler(UIViewController *controller, UIWindow *window, CGFloat top) {
    top = MIN(MAX(top, CGRectGetMinY(window.bounds)), CGRectGetMaxY(window.bounds));
    CGRect region = CGRectMake(CGRectGetMinX(window.bounds), top,
                               CGRectGetWidth(window.bounds), CGRectGetMaxY(window.bounds) - top);
    NSDictionary *userInfo = @{
        UIKeyboardFrameBeginUserInfoKey: [NSValue valueWithCGRect:region],
        UIKeyboardFrameEndUserInfoKey: [NSValue valueWithCGRect:region],
        UIKeyboardAnimationDurationUserInfoKey: @0,
        UIKeyboardAnimationCurveUserInfoKey: @(UIViewAnimationCurveEaseInOut),
        UIKeyboardIsLocalUserInfoKey: @YES,
        kApolloPaneMessageBarRegionKey: @YES,
    };
    NSNotification *notification =
        [NSNotification notificationWithName:UIKeyboardWillChangeFrameNotification
                                      object:window.screen
                                    userInfo:userInfo];
    ((void (*)(id, SEL, NSNotification *))objc_msgSend)(
        controller, @selector(handleKeyboardDidChangeState:), notification);
}

// Hand Apollo's keyboard handler the region the embedded bar covers, in the
// window coordinates and shape UIKit uses for a docked accessory bar, so the
// newest message ends exactly at the bar.
//
// Apollo turns that region into the list's contentInset, sometimes less the
// safe area (it does with the keyboard up, not with the bar docked), and the
// list then adds its own safe-area inset. Rather than mirror that rule, run
// the handler, predict the list's final bottom inset, and if it misses the
// bar's real coverage run it once more with the region corrected by the miss.
// The prediction uses the thread view's safe area: the list fills the view and
// adopts it, but only after the first layout.
static void ApolloPaneMessageBarSyncInset(UIViewController *controller) {
    ApolloPaneMessageBarState *state = ApolloPaneMessageBarStateFor(controller);
    UIView *bar = state.bar;
    UIWindow *window = controller.viewIfLoaded.window;
    UIScrollView *list = ApolloObjectIvar(controller, "messagesCollectionView");
    if (!state || !bar.window || !window || CGRectIsEmpty(bar.bounds) ||
        ![list isKindOfClass:UIScrollView.class]) return;
    CGRect frame = [bar convertRect:bar.bounds toView:window];
    CGRect listFrame = [list convertRect:list.bounds toView:window];
    CGFloat automatic = list.contentInsetAdjustmentBehavior != UIScrollViewContentInsetAdjustmentNever
        ? MAX(0.0, controller.view.safeAreaInsets.bottom) : 0.0;
    // Cache on what decides the result, not on the region we end up sending.
    CGRect key = CGRectMake(CGRectGetMinY(frame), CGRectGetMaxY(listFrame), automatic, CGRectGetWidth(window.bounds));
    if (CGRectEqualToRect(key, state.lastRegion)) return;
    state.lastRegion = key;
    ApolloPaneMessageBarMatchFiller(state);

    CGFloat coverage = MAX(0.0, CGRectGetMaxY(listFrame) - CGRectGetMinY(frame));
    ApolloPaneMessageBarRunHandler(controller, window, CGRectGetMinY(frame));
    CGFloat miss = list.contentInset.bottom + automatic - coverage;
    if (fabs(miss) > 0.5) ApolloPaneMessageBarRunHandler(controller, window, CGRectGetMinY(frame) + miss);
}

%group ApolloPaneMessageBarGroup
%hook _TtC6Apollo22MessagesViewController

- (void)viewDidLoad {
    %orig;
    if (ApolloPaneLayoutActive()) ApolloPaneMessageBarEmbed((UIViewController *)self);
}

- (UIView *)inputAccessoryView {
    if (ApolloPaneMessageBarStateFor((UIViewController *)self)) return nil;
    return %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloPaneMessageBarSyncInset((UIViewController *)self);
}

// A change in the thread's safe area changes how much of the bar's region the
// list adds itself.
- (void)viewSafeAreaInsetsDidChange {
    %orig;
    ApolloPaneMessageBarSyncInset((UIViewController *)self);
}

- (void)handleKeyboardDidChangeState:(NSNotification *)notification {
    // Real keyboard frames leave out the embedded bar; only its own region
    // describes what covers the list.
    if (ApolloPaneMessageBarStateFor((UIViewController *)self) &&
        ![notification.userInfo[kApolloPaneMessageBarRegionKey] boolValue]) return;
    %orig;
}

%end
%end

%ctor {
    if (!ApolloPaneLayoutEnabled()) return;
    Class controllerClass = objc_getClass("_TtC6Apollo22MessagesViewController");
    if (!controllerClass ||
        !class_getInstanceMethod(controllerClass, @selector(handleKeyboardDidChangeState:))) {
        ApolloLog(@"[PaneMessageBar] MessagesViewController or its keyboard handler missing; reply bar stays an accessory view");
        return;
    }
    %init(ApolloPaneMessageBarGroup);
}
