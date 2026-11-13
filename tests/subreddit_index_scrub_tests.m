#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Minimal UIKit stand-ins for the production scrub recognizer and the native
// index compatibility check. The fake recognizer enforces UIKit's continuous
// gesture state transitions and, like UIKit, stops delivering touches once the
// recognizer is in a final state and resets it after the last touch lifts.

#define ApolloLog(...) do {} while (0)

typedef NS_ENUM(NSInteger, UIGestureRecognizerState) {
    UIGestureRecognizerStatePossible,
    UIGestureRecognizerStateBegan,
    UIGestureRecognizerStateChanged,
    UIGestureRecognizerStateEnded,
    UIGestureRecognizerStateCancelled,
    UIGestureRecognizerStateFailed,
};

@class UIEvent;

@interface UIControl : NSObject
@end
@implementation UIControl
@end

@interface UITouch : NSObject
@property (nonatomic) CGPoint point;
- (CGPoint)locationInView:(id)view;
@end
@implementation UITouch
- (CGPoint)locationInView:(__unused id)view { return self.point; }
@end

static unsigned checks;
static unsigned illegalTransitions;

static void Check(BOOL condition, const char *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

@interface UIGestureRecognizer : NSObject
@property (nonatomic) UIGestureRecognizerState state;
@property (nonatomic, readonly) NSUInteger numberOfTouches;
@property (nonatomic, strong) id view;
@property (nonatomic) NSUInteger fakeTouchCount;
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)fakeReset;
@end

@implementation UIGestureRecognizer {
    UIGestureRecognizerState _state;
}
- (UIGestureRecognizerState)state { return _state; }
- (void)setState:(UIGestureRecognizerState)state {
    BOOL legal = NO;
    switch (_state) {
        case UIGestureRecognizerStatePossible:
            legal = state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateFailed ||
                state == UIGestureRecognizerStateEnded;
            break;
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
            legal = state == UIGestureRecognizerStateChanged || state == UIGestureRecognizerStateEnded ||
                state == UIGestureRecognizerStateCancelled;
            break;
        default:
            legal = NO;
            break;
    }
    if (!legal) {
        illegalTransitions++;
        fprintf(stderr, "illegal transition %ld -> %ld\n", (long)_state, (long)state);
        return;
    }
    _state = state;
}
- (NSUInteger)numberOfTouches { return self.fakeTouchCount; }
- (void)touchesBegan:(__unused NSSet<UITouch *> *)touches withEvent:(__unused UIEvent *)event {}
- (void)touchesMoved:(__unused NSSet<UITouch *> *)touches withEvent:(__unused UIEvent *)event {}
- (void)touchesEnded:(__unused NSSet<UITouch *> *)touches withEvent:(__unused UIEvent *)event {}
- (void)touchesCancelled:(__unused NSSet<UITouch *> *)touches withEvent:(__unused UIEvent *)event {}
- (void)fakeReset { _state = UIGestureRecognizerStatePossible; }
@end

// INCLUDE_PRODUCTION_SCRUB_RECOGNIZER

// INCLUDE_PRODUCTION_NATIVE_INDEX_COMPATIBILITY

#pragma mark - Touch driver

static NSMutableSet<UITouch *> *activeTouches;

static BOOL Receiving(UIGestureRecognizer *gesture) {
    return gesture.state == UIGestureRecognizerStatePossible ||
        gesture.state == UIGestureRecognizerStateBegan ||
        gesture.state == UIGestureRecognizerStateChanged;
}

static UITouch *Down(UIGestureRecognizer *gesture, CGFloat x, CGFloat y) {
    UITouch *touch = [UITouch new];
    touch.point = CGPointMake(x, y);
    [activeTouches addObject:touch];
    gesture.fakeTouchCount = activeTouches.count;
    if (Receiving(gesture)) [gesture touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
    return touch;
}

static void Move(UIGestureRecognizer *gesture, UITouch *touch, CGFloat x, CGFloat y) {
    touch.point = CGPointMake(x, y);
    if (Receiving(gesture)) [gesture touchesMoved:[NSSet setWithObject:touch] withEvent:nil];
}

// Lifts a touch. Returns the state the last delivered touchesEnded left, before
// the reset UIKit performs once no touches remain.
static UIGestureRecognizerState Up(UIGestureRecognizer *gesture, UITouch *touch) {
    BOOL deliver = Receiving(gesture);
    [activeTouches removeObject:touch];
    if (deliver) [gesture touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
    gesture.fakeTouchCount = activeTouches.count;
    UIGestureRecognizerState state = gesture.state;
    if (activeTouches.count == 0) [gesture fakeReset];
    return state;
}

static BOOL TapStillEnds(UIGestureRecognizer *gesture) {
    UITouch *touch = Down(gesture, 10, 100);
    BOOL possible = gesture.state == UIGestureRecognizerStatePossible;
    return possible && Up(gesture, touch) == UIGestureRecognizerStateEnded;
}

static BOOL ScrubStillBegins(UIGestureRecognizer *gesture) {
    UITouch *touch = Down(gesture, 10, 100);
    Move(gesture, touch, 10, 110);
    BOOL began = gesture.state == UIGestureRecognizerStateBegan;
    Move(gesture, touch, 10, 130);
    BOOL changed = gesture.state == UIGestureRecognizerStateChanged;
    return began && changed && Up(gesture, touch) == UIGestureRecognizerStateEnded;
}

#pragma mark - Compatibility fixtures

static BOOL FakeUpdate(__unused id self, __unused SEL _cmd, __unused id touch, __unused id event) { return YES; }

static Class MakeIndexClass(const char *name, Class superclass, const char *types) {
    Class cls = objc_allocateClassPair(superclass, name, 0);
    if (types) class_addMethod(cls, @selector(_updateSectionForTouch:withEvent:), (IMP)FakeUpdate, types);
    objc_registerClassPair(cls);
    return cls;
}

int main(void) {
    @autoreleasepool {
        activeTouches = [NSMutableSet set];
        ApolloSubredditIndexScrubGestureRecognizer *gesture = [ApolloSubredditIndexScrubGestureRecognizer new];

        // Baseline behaviour from the PR.
        Check(TapStillEnds(gesture), "a touch lifted without moving ends as a tap");
        Check(ScrubStillBegins(gesture), "a vertical drag past the slop begins and changes the scrub");
        UITouch *swipe = Down(gesture, 10, 100);
        Move(gesture, swipe, 2, 101);
        Check(gesture.state == UIGestureRecognizerStateFailed, "a mostly leftward drag past the slop fails for navigation");
        Up(gesture, swipe);

        // Second finger before the first crosses the 6 pt slop: still undecided, so Failed.
        UITouch *first = Down(gesture, 10, 100);
        Move(gesture, first, 10, 103);
        Check(gesture.state == UIGestureRecognizerStatePossible, "inside the slop the recognizer stays undecided");
        UITouch *second = Down(gesture, 12, 160);
        Check(gesture.state == UIGestureRecognizerStateFailed, "a second finger before the slop fails the undecided recognizer");
        Move(gesture, first, 10, 140);
        Check(gesture.state == UIGestureRecognizerStateFailed, "a failed recognizer stays failed while the fingers move");
        Up(gesture, second);
        Up(gesture, first);
        Check(TapStillEnds(gesture), "a tap after a two-finger touch inside the slop still works");
        Check(ScrubStillBegins(gesture), "a scrub after a two-finger touch inside the slop still works");

        // Second finger after the scrub began: active continuous gesture, so Cancelled.
        first = Down(gesture, 10, 100);
        Move(gesture, first, 10, 110);
        Check(gesture.state == UIGestureRecognizerStateBegan, "the scrub begins past the slop");
        Move(gesture, first, 10, 120);
        Check(gesture.state == UIGestureRecognizerStateChanged, "the scrub changes as the finger moves");
        second = Down(gesture, 12, 160);
        Check(gesture.state == UIGestureRecognizerStateCancelled, "a second finger cancels an active scrub instead of failing it");
        Up(gesture, first);
        Up(gesture, second);
        Check(TapStillEnds(gesture), "a tap after a cancelled scrub still works");
        Check(ScrubStillBegins(gesture), "a scrub after a cancelled scrub still works");

        // Second finger right as the scrub begins (Began, before any Changed).
        first = Down(gesture, 10, 100);
        Move(gesture, first, 10, 110);
        second = Down(gesture, 12, 160);
        Check(gesture.state == UIGestureRecognizerStateCancelled, "a second finger cancels a scrub that has just begun");
        Up(gesture, second);
        Up(gesture, first);

        // Two fingers landing together never start a scrub.
        UITouch *a = [UITouch new];
        UITouch *b = [UITouch new];
        [activeTouches addObjectsFromArray:@[a, b]];
        gesture.fakeTouchCount = 2;
        [gesture touchesBegan:[NSSet setWithObjects:a, b, nil] withEvent:nil];
        Check(gesture.state == UIGestureRecognizerStateFailed, "two simultaneous touches fail the recognizer");
        Up(gesture, a);
        Up(gesture, b);

        // System cancellation.
        first = Down(gesture, 10, 100);
        [gesture touchesCancelled:[NSSet setWithObject:first] withEvent:nil];
        Check(gesture.state == UIGestureRecognizerStateFailed, "a cancelled touch fails an undecided recognizer");
        Up(gesture, first);
        first = Down(gesture, 10, 100);
        Move(gesture, first, 10, 110);
        [gesture touchesCancelled:[NSSet setWithObject:first] withEvent:nil];
        Check(gesture.state == UIGestureRecognizerStateCancelled, "a cancelled touch cancels an active scrub");
        Up(gesture, first);

        Check(illegalTransitions == 0, "the recognizer never makes an illegal UIKit state transition");

        // Native index compatibility gate.
        Class controlSuper = [UIControl class];
        Check(ApolloNativeIndexHooksAreCompatible(MakeIndexClass("IndexBool", controlSuper, "B32@0:8@16@24")),
              "BOOL (UITouch *, UIEvent *) is compatible");
        Check(ApolloNativeIndexHooksAreCompatible(MakeIndexClass("IndexChar", controlSuper, "c32@0:8@16@24")),
              "a signed-char BOOL return is compatible");
        Check(!ApolloNativeIndexHooksAreCompatible(Nil), "a missing UITableViewIndex class is not hooked");
        Check(!ApolloNativeIndexHooksAreCompatible(MakeIndexClass("IndexMissing", controlSuper, NULL)),
              "a missing -_updateSectionForTouch:withEvent: is not hooked");
        Check(!ApolloNativeIndexHooksAreCompatible(MakeIndexClass("IndexVoid", controlSuper, "v32@0:8@16@24")),
              "a void return is not hooked");
        Check(!ApolloNativeIndexHooksAreCompatible(MakeIndexClass("IndexScalar", controlSuper, "B32@0:8@16q24")),
              "a non-object event argument is not hooked");
        Check(!ApolloNativeIndexHooksAreCompatible(MakeIndexClass("IndexPoint", controlSuper, "B40@0:8{CGPoint=dd}16@32")),
              "a struct touch argument is not hooked");
        Check(!ApolloNativeIndexHooksAreCompatible(MakeIndexClass("IndexNotControl", [NSObject class], "B32@0:8@16@24")),
              "a class that is not a UIControl is not hooked");
    }
    printf("subreddit index scrub tests: %u checks passed\n", checks);
    return 0;
}
