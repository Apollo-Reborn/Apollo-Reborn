#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// Apollo's screenEdgePanned: calls its Swift push helper directly, bypassing
// the ObjC pushViewController:animated: override. Capture the source at the
// gesture entry point instead. Keep it weak so an abandoned gesture cannot
// extend a page's lifetime.
@interface ApolloForwardSwipeSource : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end

@implementation ApolloForwardSwipeSource
@end

static const void *kApolloForwardSwipeSourceKey = &kApolloForwardSwipeSourceKey;
static ptrdiff_t sApolloForwardPushingOffset;
static ptrdiff_t sApolloForwardPoppingOffset;

%group ApolloForwardSwipeCancellation
%hook _TtC6Apollo26ApolloNavigationController

- (void)screenEdgePanned:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        ApolloForwardSwipeSource *source = [ApolloForwardSwipeSource new];
        source.controller = [(UINavigationController *)self topViewController];
        objc_setAssociatedObject(self, kApolloForwardSwipeSourceKey, source,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig(gesture);
}

- (void)navigationController:(UINavigationController *)navigationController
      didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    ApolloForwardSwipeSource *source = objc_getAssociatedObject(self, kApolloForwardSwipeSourceKey);
    objc_setAssociatedObject(self, kApolloForwardSwipeSourceKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Native didShow (Apollo 1.15.11, sub_10015fd98) consumes the first
    // forward entry if it equals the shown page; otherwise a pending push
    // clears ALL forward history. UIKit reports the source page on cancel,
    // so the latter branch incorrectly treats cancellation as a fresh push.
    // Mark that push finished before native bookkeeping. No Swift array
    // writes/copies are needed, and successful pushes/pops retain their
    // original history behavior. Resolve Bool offsets by name, never address.
    unsigned char *bytes = (unsigned char *)(__bridge void *)self;
    if (source.controller && source.controller == viewController &&
        navigationController == (id)self &&
        bytes[sApolloForwardPushingOffset] == 1 && !bytes[sApolloForwardPoppingOffset]) {
        bytes[sApolloForwardPushingOffset] = 0;
        ApolloLog(@"[ForwardSwipe] Cancelled push returned to source; preserved forward history");
    }
    %orig(navigationController, viewController, animated);
}

%end
%end

%ctor {
    Class navigationClass = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    Ivar pushing = class_getInstanceVariable(navigationClass, "pushing");
    Ivar popping = class_getInstanceVariable(navigationClass, "popping");
    if (!pushing || !popping) return;
    sApolloForwardPushingOffset = ivar_getOffset(pushing);
    sApolloForwardPoppingOffset = ivar_getOffset(popping);
    if (sApolloForwardPushingOffset <= 0 || sApolloForwardPoppingOffset <= 0) return;
    %init(ApolloForwardSwipeCancellation);
    ApolloLog(@"[ForwardSwipe] Cancellation hooks installed");
}
