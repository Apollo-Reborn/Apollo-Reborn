// Host-side checks for the All+ boost slider (ApolloAPSlider in
// src/settings/CustomAPIViewController.m): the shipping class is inserted below
// over Foundation-only UIKit doubles. The UIControl double keeps UIKit's
// tracking contract: end/cancelTracking only follow a beginTracking that
// returned YES, and UISlider returns NO for a touch on the bare track.
#import <Foundation/Foundation.h>

static int sFailures;

#define CHECK(condition, ...) do { \
    if (!(condition)) { \
        sFailures++; \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
    } \
} while (0)

@class UINavigationController;

@interface UIResponder : NSObject
@property (nonatomic, weak) UIResponder *nextResponder;
@end
@implementation UIResponder
@end

@interface UIGestureRecognizer : NSObject
@property (nonatomic, getter=isEnabled) BOOL enabled;
@end
@implementation UIGestureRecognizer
@end

@interface UIView : UIResponder
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, copy) NSArray<UIGestureRecognizer *> *gestureRecognizers;
@end
@implementation UIView
@end

@interface UIViewController : UIResponder
@property (nonatomic, strong) UINavigationController *navigationController;
@end
@implementation UIViewController
@end

@interface UINavigationController : UIViewController
@property (nonatomic, strong) UIGestureRecognizer *interactivePopGestureRecognizer;
@end
@implementation UINavigationController
@end

@interface UITouch : NSObject
@end
@implementation UITouch
@end

@interface UIEvent : NSObject
@end
@implementation UIEvent
@end

@interface UIControl : UIView
@property (nonatomic) BOOL touchOnThumb;   // what UISlider's beginTracking answers
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event;
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event;
- (void)cancelTrackingWithEvent:(UIEvent *)event;
@end
@implementation UIControl
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { (void)touch; (void)event; return self.touchOnThumb; }
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { (void)touch; (void)event; }
- (void)cancelTrackingWithEvent:(UIEvent *)event { (void)event; }
@end

@interface UISlider : UIControl
@end
@implementation UISlider
@end

// INSERT_PRODUCTION_SLIDER

// The settings stack around the slider: a cell and a table with their own
// recognizers, the view controller as the table's next responder, and the
// navigation controller's interactive pop.
@interface Fixture : NSObject
@property (strong) ApolloAPSlider *slider;
@property (strong) UIView *cell;
@property (strong) UIView *table;
@property (strong) UIViewController *controller;
@property (strong) UINavigationController *navigation;
@property (strong) NSArray<UIGestureRecognizer *> *recognizers;
@end
@implementation Fixture
@end

static Fixture *MakeFixture(void) {
    Fixture *f = [Fixture new];
    f.navigation = [UINavigationController new];
    f.navigation.interactivePopGestureRecognizer = [UIGestureRecognizer new];
    f.controller = [UIViewController new];
    f.controller.navigationController = f.navigation;
    f.table = [UIView new];
    f.table.nextResponder = f.controller;
    f.cell = [UIView new];
    f.cell.superview = f.table;
    f.cell.nextResponder = f.table;
    f.slider = [ApolloAPSlider new];
    f.slider.superview = f.cell;
    f.slider.nextResponder = f.cell;
    UIGestureRecognizer *scroll = [UIGestureRecognizer new], *swipe = [UIGestureRecognizer new], *tap = [UIGestureRecognizer new];
    f.table.gestureRecognizers = @[ scroll, swipe ];
    f.cell.gestureRecognizers = @[ tap ];
    f.recognizers = @[ scroll, swipe, tap, f.navigation.interactivePopGestureRecognizer ];
    for (UIGestureRecognizer *gr in f.recognizers) gr.enabled = YES;
    return f;
}

static NSUInteger EnabledCount(Fixture *f) {
    NSUInteger n = 0;
    for (UIGestureRecognizer *gr in f.recognizers) if (gr.isEnabled) n++;
    return n;
}

// Mirrors UIControl's touch handling: tracking calls follow beginTracking only
// when it returned YES.
static BOOL Touch(Fixture *f, BOOL onThumb, BOOL cancelled) {
    UITouch *touch = [UITouch new];
    UIEvent *event = [UIEvent new];
    f.slider.touchOnThumb = onThumb;
    BOOL tracking = [f.slider beginTrackingWithTouch:touch withEvent:event];
    if (!tracking) return NO;
    CHECK(EnabledCount(f) == 0, @"a thumb drag suspends every ancestor recognizer and the pop, %lu still on", (unsigned long)EnabledCount(f));
    if (cancelled) [f.slider cancelTrackingWithEvent:event];
    else [f.slider endTrackingWithTouch:touch withEvent:event];
    return YES;
}

// icpryde's repro: a tap on the bare track must not leave Settings without
// scrolling or swipe back.
static void TestBareTrackTap(void) {
    Fixture *f = MakeFixture();
    CHECK(!Touch(f, NO, NO), @"a bare-track touch does not track");
    CHECK(EnabledCount(f) == f.recognizers.count, @"a bare-track tap leaves every recognizer on, only %lu of %lu are",
          (unsigned long)EnabledCount(f), (unsigned long)f.recognizers.count);
}

static void TestThumbDrag(void) {
    Fixture *f = MakeFixture();
    CHECK(Touch(f, YES, NO), @"a thumb touch tracks");
    CHECK(EnabledCount(f) == f.recognizers.count, @"ending a drag restores every recognizer, only %lu of %lu are",
          (unsigned long)EnabledCount(f), (unsigned long)f.recognizers.count);
}

static void TestCancelledDrag(void) {
    Fixture *f = MakeFixture();
    CHECK(Touch(f, YES, YES), @"a thumb touch tracks");
    CHECK(EnabledCount(f) == f.recognizers.count, @"a cancelled drag restores every recognizer, only %lu of %lu are",
          (unsigned long)EnabledCount(f), (unsigned long)f.recognizers.count);
}

// A recognizer that was already off stays off: the slider only restores what
// it suspended.
static void TestDisabledRecognizerStaysOff(void) {
    Fixture *f = MakeFixture();
    UIGestureRecognizer *off = f.recognizers[1];
    off.enabled = NO;
    Touch(f, YES, NO);
    CHECK(!off.isEnabled, @"a recognizer that was off before the drag stays off");
    CHECK(EnabledCount(f) == f.recognizers.count - 1, @"the others are back on");
}

// Bare-track taps between drags must not pile up suspended recognizers.
static void TestTapThenDrag(void) {
    Fixture *f = MakeFixture();
    Touch(f, NO, NO);
    Touch(f, NO, NO);
    Touch(f, YES, NO);
    CHECK(EnabledCount(f) == f.recognizers.count, @"taps then a drag leave every recognizer on, only %lu of %lu are",
          (unsigned long)EnabledCount(f), (unsigned long)f.recognizers.count);
    CHECK(f.slider.apSuspended.count == 0, @"nothing is left suspended, %lu are", (unsigned long)f.slider.apSuspended.count);
}

int main(void) {
    @autoreleasepool {
        TestBareTrackTap();
        TestThumbDrag();
        TestCancelledDrag();
        TestDisabledRecognizerStaysOff();
        TestTapThenDrag();
        printf("allplus slider: %s\n", sFailures ? "FAILED" : "passed");
    }
    return sFailures ? 1 : 0;
}
