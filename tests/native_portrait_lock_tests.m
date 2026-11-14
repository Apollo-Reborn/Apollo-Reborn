#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <assert.h>

// Foundation-only UIKit doubles. The runner inserts production code and turns
// Logos %orig into superclass calls; no copy of the suppression logic lives here.
@interface TestLayer : NSObject
@property BOOL opacityAnimation;
@property NSUInteger removals;
- (void)removeAnimationForKey:(NSString *)key;
@end
@implementation TestLayer
- (void)removeAnimationForKey:(NSString *)key {
    assert([key isEqualToString:@"opacity"]);
    self.opacityAnimation = NO;
    self.removals++;
}
@end

@interface UIView : NSObject
@property CGFloat alpha;
@property BOOL hidden;
@property (strong) TestLayer *layer;
@property NSUInteger moves;
+ (void)performWithoutAnimation:(void (^)(void))block;
- (void)didMoveToSuperview;
@end
@implementation UIView
- (instancetype)init {
    if ((self = [super init])) { _alpha = 1.0; _layer = [TestLayer new]; }
    return self;
}
+ (void)performWithoutAnimation:(void (^)(void))block { block(); }
- (void)didMoveToSuperview { self.moves++; }
@end
@interface UIControl : UIView @end
@implementation UIControl @end
@interface _TtC6Apollo22RotationOfferingButton : UIControl @end
@implementation _TtC6Apollo22RotationOfferingButton @end

@protocol UIViewControllerTransitionCoordinatorContext <NSObject> @end
@protocol UIViewControllerTransitionCoordinator <NSObject>
- (BOOL)animateAlongsideTransition:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                       completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion;
@end
@interface TestCoordinator : NSObject <UIViewControllerTransitionCoordinator>
@property (copy) void (^animation)(id<UIViewControllerTransitionCoordinatorContext>);
@property (copy) void (^completion)(id<UIViewControllerTransitionCoordinatorContext>);
@end
@implementation TestCoordinator
- (BOOL)animateAlongsideTransition:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))animation
                       completion:(void (^)(id<UIViewControllerTransitionCoordinatorContext>))completion {
    self.animation = animation;
    self.completion = completion;
    return YES;
}
@end

static BOOL unfolded;
static NSUInteger predicateCalls;
static BOOL ApolloDuoSplitIsUnfolded(void) {
    assert(NSThread.isMainThread);
    predicateCalls++;
    return unfolded;
}

@interface UIViewController : NSObject
@property (strong) id storedButton;
@property NSUInteger taps, layouts, appearances, transitions;
@property BOOL nativeTransitionShows;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewDidLayoutSubviews;
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator;
- (void)rotationOfferingButtonTappedWithSender:(id)sender;
@end
@implementation UIViewController
- (void)viewDidAppear:(BOOL)animated { self.appearances++; }
- (void)viewDidLayoutSubviews { self.layouts++; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    self.transitions++;
    if (self.nativeTransitionShows) [(UIView *)self.storedButton setAlpha:1.0];
}
- (void)rotationOfferingButtonTappedWithSender:(id)sender { self.taps++; }
@end
@interface _TtC6Apollo21MediaViewerController : UIViewController @end
@implementation _TtC6Apollo21MediaViewerController @end
static id ApolloObjectIvar(id object, const char *name) {
    assert(strcmp(name, "$__lazy_storage_$_rotationOfferingButton") == 0);
    return [(UIViewController *)object storedButton];
}

@interface TestRotationButton : _TtC6Apollo22RotationOfferingButton @end
@interface TestMediaViewer : _TtC6Apollo21MediaViewerController @end
// INSERT_PRODUCTION_NATIVE_PORTRAIT_LOCK

static void TestUnfolded(void) {
    // The shared predicate, not this module, owns hardware/size classification.
    // All unfolded shapes (inner portrait, landscape, tabletop) share YES.
    for (int pose = 0; pose < 3; pose++) {
        unfolded = YES;
        TestRotationButton *button = [TestRotationButton new];
        assert(button.alpha == 1.0); // UIKit default before native attachment
        [button didMoveToSuperview];
        assert(button.moves == 1 && button.alpha == 0.0);
        for (NSNumber *nativeAlpha in @[@1.0, @0.5, @0.0, @1.0]) {
            button.layer.opacityAnimation = YES;
            button.alpha = nativeAlpha.doubleValue;
            assert(button.alpha == 0.0 && !button.layer.opacityAnimation);
        }
        button.hidden = NO; // unhiding alone cannot revive suppressed alpha
        assert(button.alpha == 0.0);
        TestMediaViewer *viewer = [TestMediaViewer new];
        viewer.storedButton = button;
        [viewer rotationOfferingButtonTappedWithSender:button];
        [viewer rotationOfferingButtonTappedWithSender:nil];
        assert(viewer.taps == 0);
    }
}

static void TestNativePassthrough(void) {
    // Cover portrait/landscape, normal iPhone and iPad all yield NO upstream.
    for (int pose = 0; pose < 4; pose++) {
        unfolded = NO;
        TestRotationButton *button = [TestRotationButton new];
        [button didMoveToSuperview];
        assert(button.alpha == 1.0);
        for (NSNumber *nativeAlpha in @[@0.25, @0.0, @1.0]) {
            button.alpha = nativeAlpha.doubleValue;
            assert(button.alpha == nativeAlpha.doubleValue);
        }
        TestMediaViewer *viewer = [TestMediaViewer new];
        viewer.storedButton = button;
        [viewer viewDidLayoutSubviews];
        [viewer viewDidAppear:YES];
        [viewer rotationOfferingButtonTappedWithSender:button];
        assert(button.alpha == 1.0 && viewer.taps == 1);
        assert(viewer.layouts == 1 && viewer.appearances == 1);
        assert(button.layer.removals == 0);
    }
}

static void TestLiveTransitionAndNoStaleRestore(void) {
    unfolded = NO;
    TestMediaViewer *viewer = [TestMediaViewer new];
    TestRotationButton *button = [TestRotationButton new];
    viewer.storedButton = button;
    button.layer.opacityAnimation = YES;
    unfolded = YES;
    [viewer viewDidLayoutSubviews];
    assert(button.alpha == 0.0 && !button.layer.opacityAnimation);
    // Native removal's delayed reset must not resurrect it on inner display.
    button.alpha = 1.0;
    assert(button.alpha == 0.0);
    unfolded = NO;
    [viewer viewDidLayoutSubviews];
    [viewer viewDidAppear:NO];
    assert(button.alpha == 0.0); // no stale pre-unfold alpha replay
    button.alpha = 0.6;
    assert(button.alpha == 0.6); // fresh native decision works again

    TestCoordinator *coordinator = [TestCoordinator new];
    unfolded = YES;
    viewer.nativeTransitionShows = YES;
    [viewer viewWillTransitionToSize:(CGSize){720, 1080} withTransitionCoordinator:coordinator];
    assert(viewer.transitions == 1 && button.alpha == 0.0);
    // Bypass the setter to simulate an already-running presentation animation.
    ((UIView *)button).layer.opacityAnimation = YES;
    coordinator.animation(nil);
    assert(!button.layer.opacityAnimation);
    unfolded = NO;
    coordinator.completion(nil);
    assert(button.alpha == 0.0);
    button.alpha = 1.0;
    assert(button.alpha == 1.0);
    // Late callbacks must consult today's predicate, not captured unfold state.
    coordinator.animation(nil);
    coordinator.completion(nil);
    assert(button.alpha == 1.0);

    // No coordinator is legal and must still suppress synchronously.
    unfolded = YES;
    [viewer viewWillTransitionToSize:(CGSize){1080, 720} withTransitionCoordinator:nil];
    assert(button.alpha == 0.0);
}

static void TestAppearanceMissingObjectsAndWeakCompletion(void) {
    unfolded = YES;
    TestMediaViewer *viewer = [TestMediaViewer new];
    ApolloNativeRotationOfferSyncViewer(nil);
    [viewer viewDidLayoutSubviews]; // missing lazy storage
    viewer.storedButton = [NSObject new];
    [viewer viewDidAppear:YES]; // unknown storage type
    UIView *unrelated = [UIView new];
    viewer.storedButton = unrelated;
    [viewer viewDidLayoutSubviews];
    assert(unrelated.alpha == 1.0);
    [viewer rotationOfferingButtonTappedWithSender:nil];
    assert(viewer.taps == 0); // stale action is blocked without a button

    // Existing unhooked native instance: lifecycle sync, not only setter tests.
    _TtC6Apollo22RotationOfferingButton *native = [_TtC6Apollo22RotationOfferingButton new];
    viewer.storedButton = native;
    [viewer viewDidAppear:YES];
    assert(native.alpha == 0.0);

    TestCoordinator *coordinator = [TestCoordinator new];
    __weak TestMediaViewer *weakViewer;
    @autoreleasepool {
        TestMediaViewer *temporary = [TestMediaViewer new];
        weakViewer = temporary;
        [temporary viewWillTransitionToSize:(CGSize){720, 1080} withTransitionCoordinator:coordinator];
    }
    assert(weakViewer == nil);
    coordinator.animation(nil);
    coordinator.completion(nil);
}

static void TestNoOffMainPolicyRead(void) {
    NSUInteger calls = predicateCalls;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        assert(!ApolloNativeRotationOfferSuppressed());
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    assert(predicateCalls == calls);
}

int main(void) {
    @autoreleasepool {
        TestUnfolded();
        TestNativePassthrough();
        TestLiveTransitionAndNoStaleRestore();
        TestAppearanceMissingObjectsAndWeakCompletion();
        TestNoOffMainPolicyRead();
        puts("native portrait lock: production hooks passed");
    }
    return 0;
}
