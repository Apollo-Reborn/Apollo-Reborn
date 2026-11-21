#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Foundation-only UIKit doubles. Animation completions and debounce work stay
// queued so tests can deliver them after a fold, just like a busy main queue.
typedef NS_ENUM(NSInteger, UIInterfaceOrientation) {
    UIInterfaceOrientationUnknown, UIInterfaceOrientationPortrait,
    UIInterfaceOrientationPortraitUpsideDown, UIInterfaceOrientationLandscapeLeft,
    UIInterfaceOrientationLandscapeRight
};
typedef NS_ENUM(NSInteger, UIDeviceOrientation) {
    UIDeviceOrientationUnknown, UIDeviceOrientationPortrait,
    UIDeviceOrientationPortraitUpsideDown, UIDeviceOrientationLandscapeLeft,
    UIDeviceOrientationLandscapeRight, UIDeviceOrientationFaceUp, UIDeviceOrientationFaceDown
};
static BOOL UIInterfaceOrientationIsPortrait(UIInterfaceOrientation orientation) {
    return orientation == UIInterfaceOrientationPortrait || orientation == UIInterfaceOrientationPortraitUpsideDown;
}
enum { UIControlStateNormal, ApolloGalleryMediaKindImage, ApolloGalleryMediaKindGIF };
static BOOL unfolded, onMainThread = YES;
static NSUInteger sensorReads, poseReads;
static NSMutableArray *delayed, *completions, *mainQueue;
static BOOL __attribute__((unused)) ApolloDuoSplitIsUnfolded(void) {
    NSCAssert(onMainThread, @"Pose predicate must run on main thread");
    ++poseReads;
    return unfolded;
}
@interface TestThread : NSObject
+ (BOOL)isMainThread;
@end
@implementation TestThread
+ (BOOL)isMainThread { return onMainThread; }
@end
@interface TestDefaults : NSObject
@property (nonatomic, strong) NSMutableDictionary *values;
+ (instancetype)standardUserDefaults;
- (id)objectForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
@end
@implementation TestDefaults
+ (instancetype)standardUserDefaults {
    static TestDefaults *defaults;
    if (!defaults) { defaults = [self new]; defaults.values = [NSMutableDictionary new]; }
    return defaults;
}
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
- (void)removeObjectForKey:(NSString *)key { [self.values removeObjectForKey:key]; }
@end
@interface UIDevice : NSObject
@property (nonatomic) UIDeviceOrientation physicalOrientation;
+ (instancetype)currentDevice;
- (UIDeviceOrientation)orientation;
@end
@implementation UIDevice
+ (instancetype)currentDevice { static UIDevice *device; if (!device) device = [self new]; return device; }
- (UIDeviceOrientation)orientation { ++sensorReads; return self.physicalOrientation; }
@end
@interface UIWindowScene : NSObject
@property (nonatomic) UIInterfaceOrientation interfaceOrientation;
@end
@implementation UIWindowScene @end
@interface UIWindow : NSObject
@property (nonatomic, strong) UIWindowScene *windowScene;
@end
@implementation UIWindow @end
@interface UIView : NSObject
@property (nonatomic) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nonatomic) CGRect bounds;
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic) NSUInteger layoutRequests;
+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations;
+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations completion:(void (^)(BOOL))completion;
- (void)setNeedsLayout;
@end
@implementation UIView
+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations {
    (void)duration; animations();
}
+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations completion:(void (^)(BOOL))completion {
    (void)duration; animations(); [completions addObject:[completion copy]];
}
- (void)setNeedsLayout { ++self.layoutRequests; }
@end
@interface UIButtonConfiguration : NSObject
@property (nonatomic, copy) NSString *title;
@end
@implementation UIButtonConfiguration @end
@interface UIButton : UIView
@property (nonatomic, strong) UIButtonConfiguration *configuration;
@property (nonatomic, copy) NSString *title;
- (void)setTitle:(NSString *)title forState:(NSInteger)state;
@end
@implementation UIButton
- (void)setTitle:(NSString *)title forState:(NSInteger)state { (void)state; self.title = title; }
@end
@interface UICollectionViewCell : UIView @end
@implementation UICollectionViewCell @end
@interface ApolloGalleryViewerCell : UICollectionViewCell
- (void)pausePlayback;
@end
@implementation ApolloGalleryViewerCell
- (void)pausePlayback {}
@end
@interface UICollectionView : UIView
@property (nonatomic, copy) NSArray *visibleCells;
@end
@implementation UICollectionView @end
@interface TestLayout : NSObject
- (void)invalidateLayout;
@end
@implementation TestLayout
- (void)invalidateLayout {}
@end
@interface ApolloGalleryItem : NSObject
@property (nonatomic) BOOL playsAsVideo;
@property (nonatomic) NSInteger kind;
@end
@implementation ApolloGalleryItem @end
@interface TestController : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic) BOOL isBeingDismissed;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)viewDidLayoutSubviews;
- (void)setNeedsUpdateOfSupportedInterfaceOrientations;
@end
@implementation TestController
- (void)viewDidAppear:(BOOL)animated { (void)animated; }
- (void)viewWillDisappear:(BOOL)animated { (void)animated; }
- (void)viewDidLayoutSubviews {}
- (void)setNeedsUpdateOfSupportedInterfaceOrientations {}
@end
@interface ApolloGalleryImageViewer : TestController
#include "GalleryRotationProperties.inc"
@property (nonatomic) BOOL isDismissing;
@property (nonatomic, strong) ApolloGalleryItem *item;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) TestLayout *layout;
@property (nonatomic) CGSize lastLaidOutPageSize;
@property (nonatomic) NSUInteger requests;
@property (nonatomic) UIInterfaceOrientation requestedOrientation;
- (void)apollo_updateRotationOffer;
- (void)apollo_hideRotationOffer;
- (void)apollo_rotateOfferTapped;
- (void)apollo_deviceOrientationChanged:(NSNotification *)notification;
- (UIInterfaceOrientation)apollo_currentInterfaceOrientation;
- (ApolloGalleryItem *)apollo_currentItem;
- (void)apollo_requestInterfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)apollo_layoutChrome;
@end

#define NSThread TestThread
#define NSUserDefaults TestDefaults
#define dispatch_after(deadline, queue, block) [delayed addObject:[(block) copy]]
#define dispatch_async(queue, block) [mainQueue addObject:[(block) copy]]
#define ApolloLog(...) ((void)0)
@implementation ApolloGalleryImageViewer
#include "GalleryRotationMethods.inc"
#include "GalleryRotationLifecycle.inc"
- (ApolloGalleryItem *)apollo_currentItem { return self.item; }
- (void)apollo_requestInterfaceOrientation:(UIInterfaceOrientation)orientation {
    NSCAssert(onMainThread, @"Geometry must run on main thread");
    ++self.requests; self.requestedOrientation = orientation;
}
- (void)apollo_layoutChrome {}
@end
#undef NSThread

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static void Drain(NSMutableArray *queue) {
    NSArray *work = [queue copy]; [queue removeAllObjects];
    for (void (^block)(void) in work) block();
}
static void FinishHides(void) {
    NSArray *work = [completions copy]; [completions removeAllObjects];
    for (void (^block)(BOOL) in work) block(YES);
}
static ApolloGalleryImageViewer *Viewer(void) {
    unfolded = NO; onMainThread = YES; sensorReads = poseReads = 0;
    delayed = [NSMutableArray new]; completions = [NSMutableArray new]; mainQueue = [NSMutableArray new];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SmartRotationLockEnabled"];
    UIDevice.currentDevice.physicalOrientation = UIDeviceOrientationLandscapeLeft;
    ApolloGalleryImageViewer *viewer = [ApolloGalleryImageViewer new];
    viewer.view = [UIView new]; viewer.view.window = [UIWindow new];
    viewer.view.window.windowScene = [UIWindowScene new];
    viewer.view.window.windowScene.interfaceOrientation = UIInterfaceOrientationPortrait;
    viewer.rotateOfferHost = [UIView new]; viewer.rotateOfferHost.hidden = YES;
    viewer.rotateOfferButton = [UIButton new]; viewer.rotateOfferButton.configuration = [UIButtonConfiguration new];
    viewer.collectionView = [UICollectionView new]; viewer.layout = [TestLayout new];
    viewer.collectionView.bounds = CGRectMake(0, 0, 390, 844);
    viewer.item = [ApolloGalleryItem new];
    return viewer;
}
static void FoldedBehavior(void) {
    ApolloGalleryImageViewer *v = Viewer();
    [v apollo_updateRotationOffer];
    Check(!v.rotateOfferHost.hidden && v.rotateOfferHost.alpha == 1, @"absent preference still enables offer");
    Check(v.rotateOfferTargetOrientation == UIInterfaceOrientationLandscapeRight, @"landscape axis remains crossed");
    Check([v.rotateOfferButton.title isEqual:@"Tap to Rotate Image"], @"image title unchanged");
    Check([v.rotateOfferButton.configuration.title isEqual:v.rotateOfferButton.title], @"configuration title updated");
    [v apollo_rotateOfferTapped];
    Check(v.requests == 1 && v.isForciblyRotated, @"explicit cover tap requests landscape");
    [v apollo_rotateOfferTapped];
    Check(v.requests == 1, @"consumed target cannot be tapped twice");
    v.view.window.windowScene.interfaceOrientation = UIInterfaceOrientationLandscapeRight;
    UIDevice.currentDevice.physicalOrientation = UIDeviceOrientationPortrait;
    [v apollo_updateRotationOffer];
    Check([v.rotateOfferButton.title isEqual:@"Tap to Rotate Back"], @"forced rotation offers return to portrait");
    FinishHides();
    Check(!v.rotateOfferHost.hidden && v.rotateOfferHost.alpha == 1, @"old fade cannot hide or dim a newer offer");
    [v apollo_rotateOfferTapped];
    Check(v.requests == 2 && !v.isForciblyRotated, @"rotate back clears forced flag");

    v = Viewer(); v.item.kind = ApolloGalleryMediaKindGIF; [v apollo_updateRotationOffer];
    Check([v.rotateOfferButton.title isEqual:@"Tap to Rotate GIF"], @"GIF title unchanged");
    v.item.playsAsVideo = YES; [v apollo_updateRotationOffer];
    Check([v.rotateOfferButton.title isEqual:@"Tap to Rotate Video"], @"video title unchanged");
    UIDevice.currentDevice.physicalOrientation = UIDeviceOrientationFaceUp;
    [v apollo_updateRotationOffer];
    Check(!v.rotateOfferHost.hidden, @"folded flat sensor retains offer");
    UIDevice.currentDevice.physicalOrientation = UIDeviceOrientationPortrait;
    [v apollo_updateRotationOffer]; FinishHides();
    Check(v.rotateOfferHost.hidden, @"agreement still hides offer");
    v = Viewer(); [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"SmartRotationLockEnabled"];
    [v apollo_updateRotationOffer];
    Check(v.rotateOfferHost.hidden && sensorReads == 0, @"disabled preference remains disabled");
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"SmartRotationLockEnabled"];
    [v apollo_updateRotationOffer];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"SmartRotationLockEnabled"];
    [v apollo_rotateOfferTapped];
    Check(v.requests == 0, @"stale tap after disabling does not rotate");
    Check([[[NSUserDefaults standardUserDefaults] objectForKey:@"SmartRotationLockEnabled"] isEqual:@NO],
          @"offer logic never rewrites explicit preference");
    v = Viewer(); [v apollo_deviceOrientationChanged:nil]; [v apollo_deviceOrientationChanged:nil];
    Check(sensorReads == 0, @"folded sensor evaluation remains debounced");
    Drain(delayed);
    Check(sensorReads == 1 && !v.rotateOfferHost.hidden, @"only newest debounced offer runs");
    Check([[NSUserDefaults standardUserDefaults] objectForKey:@"SmartRotationLockEnabled"] == nil,
          @"absent default stays absent");
    v.isDismissing = YES; [v apollo_updateRotationOffer]; FinishHides();
    [v apollo_rotateOfferTapped];
    Check(v.rotateOfferHost.hidden && v.requests == 0, @"dismissing viewer neither offers nor rotates");
}
static void UnfoldSuppression(void) {
    for (UIDeviceOrientation orientation = UIDeviceOrientationUnknown; orientation <= UIDeviceOrientationFaceDown; ++orientation) {
        ApolloGalleryImageViewer *v = Viewer(); [v apollo_updateRotationOffer];
        v.isForciblyRotated = YES;
        unfolded = YES; UIDevice.currentDevice.physicalOrientation = orientation; sensorReads = 0;
        [v apollo_updateRotationOffer];
        Check(v.rotateOfferHost.hidden && v.rotateOfferTargetOrientation == UIInterfaceOrientationUnknown,
              @"inner portrait/landscape/tabletop immediately suppresses offer");
        Check(sensorReads == 0 && !v.isForciblyRotated, @"inner guard precedes sensor and retires forced state");
        [v apollo_rotateOfferTapped]; Check(v.requests == 0, @"inner queued tap cannot request geometry");
    }
    ApolloGalleryImageViewer *v = Viewer(); [v apollo_updateRotationOffer];
    unfolded = YES; [v apollo_rotateOfferTapped];
    Check(v.requests == 0 && v.rotateOfferHost.hidden, @"tap alone rechecks live pose");
    v = Viewer(); [v apollo_updateRotationOffer];
    unfolded = YES; UIDevice.currentDevice.physicalOrientation = UIDeviceOrientationFaceDown;
    // No orientation notification, and even a zero-size layout must hide.
    v.collectionView.bounds = CGRectZero; [v viewDidLayoutSubviews];
    Check(v.rotateOfferHost.hidden, @"layout suppresses without sensor event or valid page size");
    unfolded = NO; UIDevice.currentDevice.physicalOrientation = UIDeviceOrientationLandscapeRight;
    v.collectionView.bounds = CGRectMake(0, 0, 390, 844); [v viewDidLayoutSubviews]; Drain(delayed);
    FinishHides();
    Check(!v.rotateOfferHost.hidden && v.rotateOfferHost.alpha == 1 &&
          v.rotateOfferTargetOrientation == UIInterfaceOrientationLandscapeLeft, @"fold recovers without relaunch, ignoring old fades");
    unfolded = YES; [v viewDidAppear:YES];
    Check(v.rotateOfferHost.hidden, @"appearance suppresses without resize");
    unfolded = NO; [v viewDidAppear:YES]; Drain(delayed);
    Check(!v.rotateOfferHost.hidden, @"appearance recovers on cover");

    v = Viewer(); [v apollo_deviceOrientationChanged:nil];
    unfolded = YES; [v viewDidLayoutSubviews];
    unfolded = NO; sensorReads = 0; Drain(delayed);
    Check(sensorReads == 0 && v.rotateOfferHost.hidden, @"unfold invalidates old debounced update even after fold");
    [v apollo_deviceOrientationChanged:nil];
    unfolded = YES; Drain(delayed);
    Check(v.rotateOfferHost.hidden && sensorReads == 0, @"delayed update rechecks pose at execution");
    v = Viewer(); onMainThread = NO; [v apollo_deviceOrientationChanged:nil];
    Check(poseReads == 0, @"off-main notification defers predicate");
    onMainThread = YES; unfolded = YES; Drain(mainQueue);
    Check(poseReads > 0 && delayed.count == 0, @"notification dispatch suppresses on main without debounce");
}
static void DismissalAndMissingObjects(void) {
    ApolloGalleryImageViewer *v = Viewer(); v.isForciblyRotated = YES; v.isBeingDismissed = YES;
    unfolded = YES; [v viewWillDisappear:YES];
    Check(v.requests == 0 && !v.isForciblyRotated, @"dismissal never restores portrait on inner display");
    unfolded = NO; [v viewWillDisappear:YES];
    Check(v.requests == 0, @"retired forced state stays retired after folding");
    v = Viewer(); v.isForciblyRotated = YES; [v viewWillDisappear:YES];
    Check(v.requests == 0 && v.isForciblyRotated, @"share sheet does not restore portrait");
    v.isDismissing = YES; [v viewWillDisappear:YES];
    Check(v.requests == 1 && v.requestedOrientation == UIInterfaceOrientationPortrait, @"cover dismissal still restores portrait");
    v = Viewer(); v.rotateOfferHost = nil; v.rotateOfferButton = nil; v.item = nil; v.view.window = nil;
    [v apollo_updateRotationOffer]; unfolded = YES; [v viewDidLayoutSubviews]; [v apollo_rotateOfferTapped]; FinishHides();
    Check(v.requests == 0, @"missing optional objects remain safe");
}
int main(void) {
    @autoreleasepool {
        UnfoldSuppression(); FoldedBehavior(); DismissalAndMissingObjects();
        NSLog(@"gallery portrait-lock tests passed");
    }
    return 0;
}
