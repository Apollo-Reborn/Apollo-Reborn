#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import "ApolloDuoPaneDrag.h"

@protocol UIGestureRecognizerDelegate <NSObject> @end
@class UIGestureRecognizer, UIPanGestureRecognizer, ApolloDuoSplitState;
@interface UILayoutGuide : NSObject
@property(nonatomic) CGRect layoutFrame;
@end
@implementation UILayoutGuide @end
@interface UIView : NSObject
@property(nonatomic) CGRect bounds;
@property(nonatomic, strong) NSObject *window;
@property(nonatomic, strong) UILayoutGuide *safeAreaLayoutGuide;
@property(nonatomic, strong) NSMutableArray *gestureRecognizers;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture;
@end
@interface UIGestureRecognizer : NSObject
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) id delegate;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) NSInteger state;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
@end
@implementation UIGestureRecognizer
- (instancetype)initWithTarget:(__unused id)target action:(__unused SEL)action { return [super init]; }
@end
@implementation UIView
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture {
    if (!self.gestureRecognizers) self.gestureRecognizers = [NSMutableArray array];
    [self.gestureRecognizers addObject:gesture]; gesture.view = self;
}
@end
@interface UIPanGestureRecognizer : UIGestureRecognizer
@property(nonatomic) NSUInteger maximumNumberOfTouches;
@property(nonatomic) BOOL enabled;
@property(nonatomic) CGPoint translation, velocity;
- (CGPoint)translationInView:(UIView *)view;
- (CGPoint)velocityInView:(UIView *)view;
@end
@implementation UIPanGestureRecognizer
- (CGPoint)translationInView:(__unused UIView *)view { return self.translation; }
- (CGPoint)velocityInView:(__unused UIView *)view { return self.velocity; }
@end
@interface UIScrollView : UIView
@property(nonatomic, strong) UIPanGestureRecognizer *panGestureRecognizer;
@end
@implementation UIScrollView @end
@interface UITouch : NSObject
@property(nonatomic) CGPoint point;
- (CGPoint)locationInView:(UIView *)view;
@end
@implementation UITouch
- (CGPoint)locationInView:(__unused UIView *)view { return self.point; }
@end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *viewIfLoaded;
@property(nonatomic, strong) UIViewController *presentedViewController;
@property(nonatomic, strong) UIViewController *parentViewController;
@property(nonatomic, strong) NSObject *transitionCoordinator;
@property(nonatomic) BOOL isBeingDismissed;
- (UIView *)view;
- (BOOL)isViewLoaded;
@end
@implementation UIViewController
- (UIView *)view { return self.viewIfLoaded; }
- (BOOL)isViewLoaded { return self.viewIfLoaded != nil; }
@end
@interface UINavigationController : UIViewController
@property(nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property(nonatomic, strong) ApolloDuoSplitState *duoState;
@property(nonatomic) CGRect pane;
@property(nonatomic) NSUInteger pops;
@property(nonatomic) BOOL lastAnimated;
- (UIViewController *)topViewController;
- (UIViewController *)popViewControllerAnimated:(BOOL)animated;
@end
@implementation UINavigationController
- (UIViewController *)topViewController { return self.viewControllers.lastObject; }
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *last = self.topViewController;
    self.viewControllers = [self.viewControllers subarrayWithRange:NSMakeRange(0, self.viewControllers.count - 1)];
    self.lastAnimated = animated; self.pops++; return last;
}
@end
@interface TestDuoHost : NSObject
@property(nonatomic) BOOL postsShowingDetail, listVisible;
@end
@implementation TestDuoHost @end
@interface ApolloDuoSplitState : NSObject
@property(nonatomic, strong) NSObject *split;
@property(nonatomic, weak) UINavigationController *feed, *secondary;
@property(nonatomic, strong) TestDuoHost *host;
@property(nonatomic) BOOL changing;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, strong) UIViewController *root;
@end
@implementation ApolloDuoSplitState @end
static BOOL duo = YES, disabled, resizing, reduceMotion;
@interface TestDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
@end
@implementation TestDefaults
+ (instancetype)standardUserDefaults { static TestDefaults *d; if (!d) d=[self new]; return d; }
- (BOOL)boolForKey:(__unused NSString *)key { return disabled; }
@end
#define NSUserDefaults TestDefaults
static BOOL ApolloDeviceIsDuo(void) { return duo; }
static BOOL ApolloDuoSplitIsResizing(void) { return resizing; }
static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, __unused BOOL create) { return nav.duoState; }
// INCLUDE_PRODUCTION_SPLIT_POLICIES
static CGRect ApolloDuoSplitContentFrame(UINavigationController *nav, __unused UIView *view) { return nav.pane; }
static BOOL UIAccessibilityIsReduceMotionEnabled(void) { return reduceMotion; }
typedef NSInteger UIGestureRecognizerState;
enum { UIGestureRecognizerStatePossible, UIGestureRecognizerStateBegan, UIGestureRecognizerStateChanged,
       UIGestureRecognizerStateEnded, UIGestureRecognizerStateCancelled, UIGestureRecognizerStateFailed };
static NSString *const UIApplicationWillResignActiveNotification = @"resign";
// Split surfaces the pane drag moves, recorded instead of animated.
static NSUInteger threadDragsBegun, listDragsBegun;
static CGFloat threadOffset = -1, listShown = -1;
static BOOL threadClosed, listShownAtEnd, threadCanClose;
static BOOL ApolloDuoSplitCanDragThreadClosed(__unused UINavigationController *nav) { return threadCanClose; }
static CGFloat ApolloDuoSplitBeginThreadDrag(__unused UINavigationController *nav) { threadDragsBegun++; return 0; }
static void ApolloDuoSplitDragThread(__unused UINavigationController *nav, CGFloat offset) { threadOffset = offset; }
static CGFloat ApolloDuoSplitThreadDragTravel(__unused UINavigationController *nav) { return 500; }
static void ApolloDuoSplitEndThreadDrag(__unused UINavigationController *nav, BOOL close, __unused CGFloat offset, __unused CGFloat velocity) {
    threadClosed = close;
}
static BOOL ApolloDuoSplitBeginListDrag(__unused UINavigationController *nav) { listDragsBegun++; return YES; }
static CGFloat ApolloDuoSplitListDragTravel(__unused UINavigationController *nav) { return 372; }
static CGFloat ApolloDuoSplitListDragStart(__unused UINavigationController *nav) { return 0; }
static void ApolloDuoSplitMoveListDrag(__unused UINavigationController *nav, CGFloat shown) { listShown = shown; }
static void ApolloDuoSplitEndListDrag(__unused UINavigationController *nav, BOOL show, __unused CGFloat velocity) {
    listShownAtEnd = show;
}
#define ApolloLog(...) ((void)0)
// INCLUDE_PRODUCTION_GESTURES
static NSUInteger checks;
static void Check(BOOL valid, NSString *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static UINavigationController *Navigation(void) {
    UINavigationController *nav = [UINavigationController new];
    nav.viewControllers = @[[UIViewController new], [UIViewController new]];
    nav.viewIfLoaded = [UIView new];
    nav.view.window = [NSObject new];
    nav.view.bounds = CGRectMake(0, 0, 1280, 900);
    nav.view.safeAreaLayoutGuide = [UILayoutGuide new];
    nav.view.safeAreaLayoutGuide.layoutFrame = CGRectMake(0, 80, 1100, 720);
    nav.pane = CGRectNull;
    return nav;
}
int main(void) {
    @autoreleasepool {
        UINavigationController *nav = Navigation();
        Check(ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(4, 300)), @"full-width Duo accepts a left-edge Back swipe");
        Check(!ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(150, 300)), @"ordinary row swipes stay untouched");
        Check(!ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(4, 20)), @"navigation/header controls are not swallowed");
        nav.view.safeAreaLayoutGuide.layoutFrame = CGRectMake(47, 80, 1053, 720);
        Check(ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(4, 300)), @"landscape hardware insets do not move the full-screen Back edge");
        nav.pane = CGRectMake(640, 80, 500, 720);
        Check(ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(646, 300)), @"right pane starts at its own content edge");
        Check(!ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(10, 300)), @"right pane cannot take a gesture started in the left pane");
        Check(!ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(700, 300)), @"right pane row actions remain available away from the edge");
        nav.pane = CGRectMake(0, 80, 640, 720);
        Check(ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(20, 300)), @"left pane can navigate while right pane exists");
        nav.pane = CGRectZero;
        Check(!ApolloDuoBackSwipeAcceptsPoint(nav, CGPointZero), @"detached or collapsed pane cannot recognize");
        nav.pane = CGRectNull;
        duo = NO;
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"ordinary phones are excluded");
        ApolloDuoInstallBackSwipe(nav);
        Check(!ApolloDuoHasBackSwipe(nav), @"ordinary phones get no recognizer");
        duo = YES; disabled = YES;
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"Disable Navigation Gestures is honored");
        disabled = NO; resizing = YES;
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"fold/rotation transition blocks navigation");
        resizing = NO; nav.transitionCoordinator = [NSObject new];
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"in-flight push/pop cannot be popped twice");
        nav.transitionCoordinator = nil; nav.presentedViewController = [UIViewController new];
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"presented modal blocks underlying Back");
        nav.presentedViewController = nil; nav.topViewController.presentedViewController = [UIViewController new];
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"a top-page sheet blocks underlying Back");
        nav.topViewController.presentedViewController = nil; nav.isBeingDismissed = YES;
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"dismissing navigation cannot begin Back");
        nav.isBeingDismissed = NO; UINavigationController *detail = Navigation();
        ApolloDuoSplitState *split = [ApolloDuoSplitState new];
        split.split = [NSObject new]; split.host = [TestDuoHost new]; split.secondary = detail;
        nav.duoState = split;
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"outer containment cannot compete with the real pane");
        nav.duoState = nil;
        ApolloDuoInstallBackSwipe(nav); ApolloDuoInstallBackSwipe(nav);
        Check(ApolloDuoHasBackSwipe(nav) && nav.view.gestureRecognizers.count == 1, @"recognizer installation is idempotent");
        ApolloDuoBackSwipe *owner = objc_getAssociatedObject(nav, &kApolloDuoBackSwipe);
        Check(owner.pan.maximumNumberOfTouches == 1, @"Back follows one finger");
        UITouch *touch = [UITouch new]; touch.point = CGPointMake(5, 300);
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"real delegate accepts the content-edge touch");
        touch.point = CGPointMake(200, 300);
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"real delegate rejects interior touches");
        UIScrollView *scroll = [UIScrollView new]; scroll.panGestureRecognizer = [UIPanGestureRecognizer new];
        scroll.panGestureRecognizer.view = scroll;
        UIPanGestureRecognizer *row = [UIPanGestureRecognizer new];
        Check([owner gestureRecognizer:owner.pan shouldBeRequiredToFailByGestureRecognizer:row]
              && ![owner gestureRecognizer:owner.pan shouldBeRequiredToFailByGestureRecognizer:scroll.panGestureRecognizer],
              @"edge Back has priority over row gestures without blocking table pans");
        // Folded: every pop is a real page pop, so Apollo's own interactive
        // Back owns it and the pane drag stands down.
        owner.pan.translation = CGPointMake(30, 2);
        Check(ApolloDuoPaneBackIsNative(nav) && ![owner gestureRecognizerShouldBegin:owner.pan],
              @"a page pop is left to Apollo's own Back, which follows the finger");
        owner.pan.translation = CGPointMake(2, 30);
        Check(![owner gestureRecognizerShouldBegin:owner.pan], @"vertical motion never starts Back");
        nav = Navigation(); nav.view.window = nil;
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"offscreen navigation cannot pop");

        // Exercise real split-state policy, including explicit pane Back while
        // a different pane is visible and the root-to-drawer boundary.
        reduceMotion = NO;
        UINavigationController *feed = Navigation(); detail = Navigation();
        split.feed = feed; split.secondary = detail;
        feed.duoState = split; detail.duoState = split;
        split.host.postsShowingDetail = YES;
        Check(ApolloDuoSplitDetailNavigation(feed) == feed, @"explicit left Back stays left while thread is open");
        Check(ApolloDuoSplitDetailNavigation(detail) == detail, @"explicit right Back stays right");
        nav = Navigation(); nav.duoState = split;
        Check(ApolloDuoSplitDetailNavigation(nav) == detail, @"shared rail Back still targets the visible thread");
        split.host.postsShowingDetail = NO;
        Check(ApolloDuoSplitDetailNavigation(nav) == feed, @"shared rail Back targets feed after thread closes");
        Check(!ApolloDuoSplitAllowsNavigationSwipe(nav), @"outer shell cannot swipe even when its stack has history");
        Check(ApolloDuoBackSwipeCanNavigate(feed) && ApolloDuoBackSwipeCanNavigate(detail), @"each pane can go Back independently");
        Check(!ApolloDuoSplitCanRevealPostsListWithSwipe(feed), @"feed history takes precedence over menu");
        feed.viewControllers = @[feed.viewControllers.firstObject];
        Check(ApolloDuoSplitCanRevealPostsListWithSwipe(feed) && ApolloDuoBackSwipeCanNavigate(feed), @"feed root enables menu swipe even with right thread open");
        detail.viewControllers = @[detail.viewControllers.firstObject];
        Check(!ApolloDuoBackSwipeCanNavigate(detail), @"right pane placeholder cannot open menu or pop");
        ApolloDuoInstallBackSwipe(feed); owner = objc_getAssociatedObject(feed, &kApolloDuoBackSwipe);
        owner.pan.translation = CGPointMake(30, 0);
        Check([owner gestureRecognizerShouldBegin:owner.pan] && owner.route == ApolloDuoBackRouteDrawer,
              @"feed root drag routes to the subreddit list");
        owner.pan.state = UIGestureRecognizerStateBegan; [owner panned:owner.pan];
        owner.pan.translation = CGPointMake(200, 0); owner.pan.state = UIGestureRecognizerStateChanged; [owner panned:owner.pan];
        Check(listDragsBegun == 1 && listShown == 200 && feed.pops == 0, @"the list follows the finger without popping the root");
        owner.pan.state = UIGestureRecognizerStateEnded; [owner panned:owner.pan];
        Check(listShownAtEnd, @"a release past a third of the list shows it");
        owner.pan.translation = CGPointMake(40, 0); owner.pan.state = UIGestureRecognizerStateBegan; [owner panned:owner.pan];
        owner.route = ApolloDuoBackRouteDrawer; owner.pan.state = UIGestureRecognizerStateEnded; [owner panned:owner.pan];
        Check(!listShownAtEnd, @"an early release slides the list back out");
        split.host.listVisible = YES;
        Check(!ApolloDuoBackSwipeCanNavigate(feed), @"open drawer blocks underlying feed swipe");
        split.host.listVisible = NO;
        // The thread right above the Posts backstop slides out with the finger.
        detail.viewControllers = @[[UIViewController new], [UIViewController new]];
        threadCanClose = YES; split.feed = feed;
        ApolloDuoInstallBackSwipe(detail); owner = objc_getAssociatedObject(detail, &kApolloDuoBackSwipe);
        owner.pan.translation = CGPointMake(30, 0);
        Check([owner gestureRecognizerShouldBegin:owner.pan] && owner.route == ApolloDuoBackRouteCloseThread,
              @"the thread above the backstop routes to the close drag, not a native pop");
        owner.pan.state = UIGestureRecognizerStateBegan; [owner panned:owner.pan];
        owner.pan.translation = CGPointMake(900, 0); owner.pan.state = UIGestureRecognizerStateChanged; [owner panned:owner.pan];
        Check(threadDragsBegun == 1 && threadOffset == 500, @"the thread follows the finger, held within its pane");
        owner.pan.state = UIGestureRecognizerStateCancelled; [owner panned:owner.pan];
        Check(!threadClosed, @"a cancelled drag (fold, rotation) springs the thread back");
        threadCanClose = NO; detail.viewControllers = @[detail.viewControllers.firstObject];
        split.changing = YES;
        Check(!ApolloDuoBackSwipeCanNavigate(feed), @"column migration blocks menu swipe");
        split.changing = NO; disabled = YES;
        Check(!ApolloDuoBackSwipeCanNavigate(feed), @"navigation gesture opt-out applies to root menu");
        disabled = NO; split.split = nil;
        Check(!ApolloDuoBackSwipeCanNavigate(feed), @"folded feed root keeps native root behavior");
        nav = Navigation(); nav.parentViewController = [UIViewController new];
        nav.parentViewController.presentedViewController = [UIViewController new];
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"modal presented by containing split blocks underlying swipe");
        nav.parentViewController.presentedViewController = nil;
        nav.parentViewController.transitionCoordinator = [NSObject new];
        Check(!ApolloDuoBackSwipeCanNavigate(nav), @"containing transition blocks underlying swipe");
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
