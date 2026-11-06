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
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, strong) NSObject *window;
@property(nonatomic, strong) UILayoutGuide *safeAreaLayoutGuide;
@property(nonatomic, strong) NSMutableArray *gestureRecognizers;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture;
@end
@interface UIEvent : NSObject @end
@implementation UIEvent @end
@class UITouch;
@interface UIGestureRecognizer : NSObject
@property(nonatomic) BOOL enabled;
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) id delegate;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) NSInteger state;
@property(nonatomic) BOOL delaysTouchesBegan;
@property(nonatomic) NSUInteger superMoves;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)reset;
@end
@implementation UIGestureRecognizer
- (instancetype)initWithTarget:(__unused id)target action:(__unused SEL)action { return [super init]; }
- (void)touchesBegan:(__unused NSSet<UITouch *> *)touches withEvent:(__unused UIEvent *)event {}
- (void)touchesMoved:(__unused NSSet<UITouch *> *)touches withEvent:(__unused UIEvent *)event { self.superMoves++; }
- (void)reset { self.state = 0; }
@end
@implementation UIView
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture {
    if (!self.gestureRecognizers) self.gestureRecognizers = [NSMutableArray array];
    [self.gestureRecognizers addObject:gesture]; gesture.view = self;
}
@end
@interface UIPanGestureRecognizer : UIGestureRecognizer
@property(nonatomic) NSUInteger maximumNumberOfTouches;
@property(nonatomic) BOOL cancelsTouchesInView;
@property(nonatomic) CGPoint translation, velocity;
- (CGPoint)translationInView:(UIView *)view;
- (CGPoint)velocityInView:(UIView *)view;
@end
@implementation UIPanGestureRecognizer
- (CGPoint)translationInView:(__unused UIView *)view { return self.translation; }
- (CGPoint)velocityInView:(__unused UIView *)view { return self.velocity; }
@end
@interface UISwipeGestureRecognizer : UIGestureRecognizer
@property(nonatomic) NSUInteger direction, numberOfTouchesRequired;
@end
@implementation UISwipeGestureRecognizer @end
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
@interface UIScrollView : UIView
@property(nonatomic, strong) UIPanGestureRecognizer *panGestureRecognizer;
@property(nonatomic) CGSize contentSize;
@property(nonatomic) CGPoint contentOffset;
@property(nonatomic) UIEdgeInsets adjustedContentInset;
@property(nonatomic, getter=isScrollEnabled) BOOL scrollEnabled;
@property(nonatomic) BOOL alwaysBounceHorizontal;
@end
@implementation UIScrollView @end
@interface UITextView : UIScrollView
@property(nonatomic, getter=isSelectable) BOOL selectable;
@property(nonatomic, getter=isEditable) BOOL editable;
@end
@implementation UITextView @end
@interface UISlider : UIView @end
@implementation UISlider @end
@interface UISwitch : UIView @end
@implementation UISwitch @end
@interface UISegmentedControl : UIView @end
@implementation UISegmentedControl @end
@interface UIStepper : UIView @end
@implementation UIStepper @end
@interface UIDatePicker : UIView @end
@implementation UIDatePicker @end
@interface UITextField : UIView @end
@implementation UITextField @end
@interface UITouch : NSObject
@property(nonatomic) CGPoint point;
@property(nonatomic, strong) UIView *view;
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
@property(nonatomic, weak) UINavigationController *feed, *secondary, *primary;
@property(nonatomic, copy) NSString *kind, *tabKind;
@property(nonatomic, copy) NSArray *profilePrefix;
@property(nonatomic, strong) UIViewController *root;
@property(nonatomic, strong) TestDuoHost *host;
@property(nonatomic) BOOL changing;
@property(nonatomic, strong) NSObject *coverDrag;
@end
@implementation ApolloDuoSplitState @end
static BOOL duo = YES, disabled, leftSwipesDisabled, rightSwipesDisabled, resizing, reduceMotion;
static NSUInteger drawerReveals, profileReturns;
@interface TestDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
@end
@implementation TestDefaults
+ (instancetype)standardUserDefaults { static TestDefaults *d; if (!d) d=[self new]; return d; }
- (BOOL)boolForKey:(NSString *)key {
    if ([key isEqualToString:@"DisableNavigationGestures"]) return disabled;
    if ([key isEqualToString:@"DisableLeftSwipeGestureActions"]) return leftSwipesDisabled;
    if ([key isEqualToString:@"DisableRightSwipeGestureActions"]) return rightSwipesDisabled;
    return NO;
}
@end
#define NSUserDefaults TestDefaults
static BOOL ApolloDeviceIsDuo(void) { return duo; }
static BOOL ApolloDuoSplitIsResizing(void) { return resizing; }
static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, __unused BOOL create) { return nav.duoState; }
// INCLUDE_PRODUCTION_SPLIT_POLICIES
static BOOL ApolloDuoSplitReturnFromVisitedProfile(UINavigationController *nav) {
    if (!ApolloDuoSplitCanReturnFromVisitedProfile(nav)) return NO;
    nav.duoState.profilePrefix = nil;
    profileReturns++;
    return YES;
}
// The split's memory of a thread a Back closed beside the feed: the feed that
// remembers one answers CanRestore while no thread shows beside it; Restore
// reopens it once.
static __weak UINavigationController *closedThreadFeed;
static NSUInteger threadRestores;
static BOOL ApolloDuoSplitCanRestoreClosedThread(UINavigationController *nav) {
    return nav && nav == closedThreadFeed && !nav.duoState.host.postsShowingDetail
        && nav.duoState.secondary.viewControllers.count <= 1;
}
static BOOL ApolloDuoSplitRestoreClosedThread(UINavigationController *nav) {
    if (!ApolloDuoSplitCanRestoreClosedThread(nav)) return NO;
    closedThreadFeed = nil;
    threadRestores++;
    return YES;
}
// Forward drags: the closed thread's picture, recorded instead of moved.
static NSUInteger restoreDragsBegun;
static CGFloat restoreShown = -1;
static BOOL restoreEnded, restoreCommitted, restoreFollows = YES;
static BOOL ApolloDuoSplitBeginRestoreDrag(UINavigationController *nav) {
    if (!restoreFollows || !ApolloDuoSplitCanRestoreClosedThread(nav)) return NO;
    restoreDragsBegun++;
    return YES;
}
static CGFloat ApolloDuoSplitRestoreDragTravel(__unused UINavigationController *nav) { return 500; }
static void ApolloDuoSplitMoveRestoreDrag(__unused UINavigationController *nav, CGFloat shown) { restoreShown = shown; }
static void ApolloDuoSplitEndRestoreDrag(UINavigationController *nav, BOOL restore, __unused CGFloat shown, __unused CGFloat velocity) {
    restoreEnded = YES;
    restoreCommitted = restore;
    if (restore) ApolloDuoSplitRestoreClosedThread(nav);
}
// Split drags (the profile here): the split's pictures, recorded instead of
// moved. Without a picture (profileDragFollows off) Begin declines and the
// swipe navigates.
static __weak UINavigationController *profileForwardPane;
static NSUInteger profileForwards, profileDragsBegun;
static BOOL profileDragFollows = YES, profileDragEnded, profileDragCommitted, profileDragForward;
static CGFloat profileDragShown = -1;
static BOOL ApolloDuoSplitCanForwardInSplit(UINavigationController *nav) {
    return nav && nav == profileForwardPane && !ApolloDuoSplitCanRestoreClosedThread(nav);
}
static BOOL ApolloDuoSplitForwardInSplit(UINavigationController *nav) {
    if (!ApolloDuoSplitCanForwardInSplit(nav)) return NO;
    profileForwardPane = nil;
    profileForwards++;
    return YES;
}
static BOOL ApolloDuoSplitBeginProfileDrag(UINavigationController *nav, BOOL forward) {
    if (!profileDragFollows) return NO;
    if (forward ? !ApolloDuoSplitCanForwardInSplit(nav) : !ApolloDuoSplitCanReturnFromVisitedProfile(nav)) return NO;
    profileDragsBegun++;
    profileDragForward = forward;
    profileDragEnded = NO;
    return YES;
}
static BOOL ApolloDuoSplitBeginBackDrag(UINavigationController *nav) { return ApolloDuoSplitBeginProfileDrag(nav, NO); }
static BOOL ApolloDuoSplitBeginForwardDrag(UINavigationController *nav) { return ApolloDuoSplitBeginProfileDrag(nav, YES); }
static CGFloat ApolloDuoSplitCoverDragTravel(__unused UINavigationController *nav) { return 900; }
static void ApolloDuoSplitMoveCoverDrag(__unused UINavigationController *nav, CGFloat shown) { profileDragShown = shown; }
static void ApolloDuoSplitEndCoverDrag(UINavigationController *nav, BOOL commit, __unused CGFloat shown, __unused CGFloat velocity) {
    profileDragEnded = YES;
    profileDragCommitted = commit;
    if (!commit) return;
    if (profileDragForward) ApolloDuoSplitForwardInSplit(nav);
    else ApolloDuoSplitReturnFromVisitedProfile(nav);
}
static CGRect ApolloDuoSplitContentFrame(UINavigationController *nav, __unused UIView *view) { return nav.pane; }
static BOOL UIAccessibilityIsReduceMotionEnabled(void) { return reduceMotion; }
typedef NSInteger UIGestureRecognizerState;
enum { UIGestureRecognizerStatePossible, UIGestureRecognizerStateBegan, UIGestureRecognizerStateChanged,
       UIGestureRecognizerStateEnded, UIGestureRecognizerStateCancelled, UIGestureRecognizerStateFailed,
       UIGestureRecognizerStateRecognized = UIGestureRecognizerStateEnded,
       UISwipeGestureRecognizerDirectionRight = 1, UISwipeGestureRecognizerDirectionLeft = 2 };
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
static void ApolloDuoSplitEndListDrag(UINavigationController *nav, BOOL show, __unused CGFloat velocity) {
    listShownAtEnd = show;
    if (show) {
        nav.duoState.host.listVisible = YES;
        drawerReveals++;
    }
}
#define ApolloLog(...) ((void)0)
// INCLUDE_PRODUCTION_GESTURES
// A forward drag `dx` to the left, then its release (velocity `vx`).
static void ForwardDrag(ApolloDuoBackSwipe *owner, CGFloat dx) {
    owner.forwardSwipe.translation = CGPointMake(dx, 0);
    if (![owner gestureRecognizerShouldBegin:owner.forwardSwipe]) return;
    owner.forwardSwipe.state = UIGestureRecognizerStateBegan; [owner forwardPanned:owner.forwardSwipe];
    owner.forwardSwipe.state = UIGestureRecognizerStateChanged; [owner forwardPanned:owner.forwardSwipe];
}
static void ForwardRelease(ApolloDuoBackSwipe *owner, CGFloat dx, CGFloat vx) {
    if (owner.forwardSwipe.state != UIGestureRecognizerStateChanged) return;
    owner.forwardSwipe.translation = CGPointMake(dx, 0);
    owner.forwardSwipe.velocity = CGPointMake(vx, 0);
    owner.forwardSwipe.state = UIGestureRecognizerStateEnded; [owner forwardPanned:owner.forwardSwipe];
    owner.forwardSwipe.state = UIGestureRecognizerStatePossible;
}
// A full rightward drag on the pane Back: begins only if the delegate lets it.
static void Drag(ApolloDuoBackSwipe *owner) {
    owner.pan.translation = CGPointMake(30, 0);
    if (![owner gestureRecognizerShouldBegin:owner.pan]) return;
    owner.pan.state = UIGestureRecognizerStateBegan; [owner panned:owner.pan];
    owner.pan.translation = CGPointMake(400, 0);
    owner.pan.state = UIGestureRecognizerStateEnded; [owner panned:owner.pan];
    owner.pan.state = UIGestureRecognizerStatePossible;
}
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
        Check(ApolloDuoHasBackSwipe(nav) && nav.view.gestureRecognizers.count == 3, @"recognizer installation is idempotent (back swipe + forward swipe + highlight guard)");
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
        UIPanGestureRecognizer *guard = owner.highlightGuard;
        Check(guard && [nav.view.gestureRecognizers containsObject:guard] && guard.maximumNumberOfTouches == 1
              && guard.cancelsTouchesInView, @"highlight guard is installed once, one finger, cancelling the row's touch");
        Check(guard.delaysTouchesBegan, @"highlight guard withholds the row's touch-down while undecided");
        UITouch *down = [UITouch new]; down.point = CGPointMake(5, 300);
        NSSet *downs = [NSSet setWithObject:down];
        [guard touchesBegan:downs withEvent:[UIEvent new]];
        Check(guard.state == UIGestureRecognizerStatePossible, @"highlight guard starts undecided");
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kApolloDuoHighlightGuardDelay / 2]];
        Check(guard.state == UIGestureRecognizerStatePossible, @"highlight guard stays undecided within the delay");
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kApolloDuoHighlightGuardDelay]];
        Check(guard.state == UIGestureRecognizerStateFailed, @"an undecided guard fails after the delay, releasing the touch-down (tap/hold highlight)");
        [guard reset]; [guard touchesBegan:downs withEvent:[UIEvent new]];
        down.point = CGPointMake(7, 312);
        [guard touchesMoved:downs withEvent:[UIEvent new]];
        Check(guard.state == UIGestureRecognizerStateFailed, @"a clearly vertical move fails the guard at once, so scrolling is unaffected");
        [guard reset]; down.point = CGPointMake(5, 300); [guard touchesBegan:downs withEvent:[UIEvent new]];
        NSUInteger superMoves = guard.superMoves;
        down.point = CGPointMake(25, 303);
        [guard touchesMoved:downs withEvent:[UIEvent new]];
        down.point = CGPointMake(-15, 303);
        [guard touchesMoved:downs withEvent:[UIEvent new]];
        Check(guard.state == UIGestureRecognizerStatePossible && guard.superMoves == superMoves + 2,
              @"horizontal moves either way go on to the pan (which begins via the delegate)");
        [guard reset];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kApolloDuoHighlightGuardDelay * 1.5]];
        Check(guard.state == UIGestureRecognizerStatePossible, @"a stale timer cannot fail the next touch after reset");
        touch.point = CGPointMake(5, 300);
        Check([owner gestureRecognizer:guard shouldReceiveTouch:touch], @"highlight guard receives the touches the swipe accepts (edge)");
        touch.point = CGPointMake(200, 300);
        Check(![owner gestureRecognizer:guard shouldReceiveTouch:touch], @"highlight guard ignores interior touches the swipe rejects");
        guard.velocity = CGPointMake(300, 40);
        Check([owner gestureRecognizerShouldBegin:guard], @"highlight guard begins for a clearly rightward move");
        guard.velocity = CGPointMake(300, 250);
        Check(![owner gestureRecognizerShouldBegin:guard], @"highlight guard ignores a diagonal move");
        guard.velocity = CGPointMake(-300, 10);
        Check([owner gestureRecognizerShouldBegin:guard], @"highlight guard also begins for a clearly leftward move (row actions run alongside)");
        guard.velocity = CGPointMake(20, 300);
        Check(![owner gestureRecognizerShouldBegin:guard], @"highlight guard ignores a vertical move");
        guard.velocity = CGPointMake(300, 40); disabled = YES;
        Check(![owner gestureRecognizerShouldBegin:guard], @"highlight guard stands down when Back cannot navigate");
        disabled = NO;
        Check([owner gestureRecognizer:guard shouldRecognizeSimultaneouslyWithGestureRecognizer:row]
              && [owner gestureRecognizer:owner.pan shouldRecognizeSimultaneouslyWithGestureRecognizer:guard],
              @"highlight guard recognizes simultaneously with anything");
        Check(![owner gestureRecognizer:owner.pan shouldBeRequiredToFailByGestureRecognizer:guard],
              @"the swipe never waits for the highlight guard");
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

        // Gestures > Disable Left Swipes frees the right swipe from row
        // actions; Apollo's own Back then starts anywhere on the page, so a
        // Duo pane's does too. Off, nothing changes (checked above).
        leftSwipesDisabled = YES;
        nav = Navigation();
        Check(ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(600, 300)), @"Disable Left Swipes: Back starts anywhere in a full-width page");
        Check(!ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(600, 20)), @"Disable Left Swipes: navigation/header controls are still not swallowed");
        nav.pane = CGRectMake(640, 80, 500, 720);
        Check(ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(900, 300)), @"Disable Left Swipes: right pane accepts a swipe anywhere inside it");
        Check(!ApolloDuoBackSwipeAcceptsPoint(nav, CGPointMake(300, 300)), @"Disable Left Swipes: a pane still never takes a swipe from the other pane");
        nav.pane = CGRectNull;
        ApolloDuoInstallBackSwipe(nav); owner = objc_getAssociatedObject(nav, &kApolloDuoBackSwipe);
        UIView *cell = [UIView new]; cell.superview = nav.view;
        touch = [UITouch new]; touch.point = CGPointMake(600, 300); touch.view = cell;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"Disable Left Swipes: the real delegate accepts an interior touch on a row");
        UIScrollView *gallery = [UIScrollView new]; gallery.superview = cell; gallery.scrollEnabled = YES;
        gallery.bounds = CGRectMake(0, 0, 400, 300); gallery.contentSize = CGSizeMake(1200, 300);
        UIView *page = [UIView new]; page.superview = gallery; touch.view = page;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"a gallery on its first page has nothing to page back to");
        gallery.contentOffset = CGPointMake(400, 0);
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"a gallery that can page back keeps its own swipe");
        touch.point = CGPointMake(10, 300);
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"the edge strip still goes Back over a gallery, as without the setting");
        touch.point = CGPointMake(600, 300);
        gallery.scrollEnabled = NO;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"a scroll view that cannot scroll does not block Back");
        UISlider *slider = [UISlider new]; slider.superview = cell; touch.view = slider;
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"a slider keeps its drag");
        for (Class control in @[UISegmentedControl.class, UIStepper.class, UIDatePicker.class, UITextField.class]) {
            UIView *view = [control new]; view.superview = cell; touch.view = view;
            Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch],
                  [NSString stringWithFormat:@"a %@ keeps its drag", NSStringFromClass(control)]);
        }
        UITextView *text = [UITextView new]; text.superview = cell; touch.view = text;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"read-only text does not block Back");
        text.selectable = YES;
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"selectable text keeps its drag");
        text.selectable = NO; text.editable = YES;
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"editable text keeps its drag");
        touch.point = CGPointMake(10, 300); text.superview = cell;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"the edge strip still goes Back over a text field's row");
        touch.point = CGPointMake(600, 300);

        // At a feed root the swipe would only reveal the list, so a sideways
        // scroller (Community Highlights) keeps the drag even at its start.
        UINavigationController *root = Navigation(); root.viewControllers = @[[UIViewController new]];
        UINavigationController *rootThread = Navigation(); rootThread.viewControllers = @[[UIViewController new]];
        ApolloDuoSplitState *rootSplit = [ApolloDuoSplitState new];
        rootSplit.split = [NSObject new]; rootSplit.host = [TestDuoHost new];
        rootSplit.feed = root; rootSplit.secondary = rootThread; root.duoState = rootSplit; rootThread.duoState = rootSplit;
        ApolloDuoInstallBackSwipe(root); owner = objc_getAssociatedObject(root, &kApolloDuoBackSwipe);
        UIView *feedHeader = [UIView new]; feedHeader.superview = root.view;
        UIScrollView *highlights = [UIScrollView new]; highlights.superview = feedHeader; highlights.scrollEnabled = YES;
        highlights.bounds = CGRectMake(0, 0, 600, 200); highlights.contentSize = CGSizeMake(1800, 200);
        UIView *card = [UIView new]; card.superview = highlights;
        touch = [UITouch new]; touch.view = card; touch.point = CGPointMake(300, 300);
        Check(ApolloDuoSplitCanRevealPostsListWithSwipe(root) && ApolloDuoBackSwipeAcceptsPoint(root, touch.point),
              @"the feed root can reveal the list from this point");
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch]
              && ![owner gestureRecognizer:owner.highlightGuard shouldReceiveTouch:touch],
              @"root reveal: a carousel at its leading end keeps the swipe");
        highlights.contentOffset = CGPointMake(600, 0);
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"root reveal: a scrolled carousel keeps the swipe");
        highlights.contentOffset = CGPointZero; touch.point = CGPointMake(10, 300);
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"root reveal: the edge strip still opens the list over a carousel");
        touch.point = CGPointMake(300, 300);
        highlights.contentSize = CGSizeMake(500, 200); highlights.alwaysBounceHorizontal = YES;
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch],
              @"root reveal: a carousel whose cards fit still keeps the swipe when it bounces sideways");
        highlights.alwaysBounceHorizontal = NO;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch],
              @"root reveal: a horizontal scroll view that fits and does not bounce lets the list open");
        highlights.alwaysBounceHorizontal = YES; highlights.scrollEnabled = NO;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch],
              @"root reveal: a scroll view with scrolling disabled lets the list open");
        highlights.scrollEnabled = YES; highlights.alwaysBounceHorizontal = NO;
        highlights.contentSize = CGSizeMake(1800, 200); touch.point = CGPointMake(10, 300);
        touch.point = CGPointMake(300, 300); touch.view = feedHeader;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"root reveal: the rest of the feed still opens the list");
        touch.view = card; rootSplit.host.postsShowingDetail = YES;
        rootThread.viewControllers = @[[UIViewController new], [UIViewController new]];
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch],
              @"root reveal: a thread open beside the feed changes nothing, the carousel keeps the swipe");
        rootSplit.host.postsShowingDetail = NO; rootThread.viewControllers = @[[UIViewController new]];
        root.viewControllers = @[[UIViewController new], [UIViewController new]];
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"a pushed page with a carousel at its first item still goes Back");
        highlights.contentSize = CGSizeMake(500, 200); highlights.alwaysBounceHorizontal = YES;
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch],
              @"a pushed page still goes Back over a bouncing carousel whose cards fit");
        highlights.contentSize = CGSizeMake(1800, 200); highlights.alwaysBounceHorizontal = NO;
        highlights.contentOffset = CGPointMake(600, 0);
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"a pushed page with a carousel mid-way keeps it scrolling");

        // A visited profile is the account split's one-page detail root: Back
        // leaves it the way its Back button does, with or without the setting.
        leftSwipesDisabled = NO;
        UINavigationController *profile = Navigation();
        profile.viewControllers = @[[UIViewController new]];
        ApolloDuoSplitState *account = [ApolloDuoSplitState new];
        account.split = [NSObject new]; account.host = [TestDuoHost new];
        account.kind = @"account"; account.tabKind = @"subreddits";
        account.profilePrefix = @[[UIViewController new]];
        account.secondary = profile; account.root = profile.viewControllers.firstObject;
        profile.duoState = account;
        Check(ApolloDuoBackSwipeCanNavigate(profile), @"a visited profile's pane can swipe Back out of the profile");
        ApolloDuoInstallBackSwipe(profile); owner = objc_getAssociatedObject(profile, &kApolloDuoBackSwipe);
        // With pictures of both sides, the profile follows the finger and
        // acts on release: an early one stays, a full one leaves.
        owner.pan.translation = CGPointMake(30, 0);
        Check([owner gestureRecognizerShouldBegin:owner.pan], @"profile Back: the drag begins");
        owner.pan.state = UIGestureRecognizerStateBegan; [owner panned:owner.pan];
        owner.pan.translation = CGPointMake(120, 0);
        owner.pan.state = UIGestureRecognizerStateChanged; [owner panned:owner.pan];
        Check(profileDragsBegun == 1 && !profileDragForward && profileDragShown == 120 && profileReturns == 0,
              @"profile Back: the profile follows the finger, nothing left yet");
        owner.pan.state = UIGestureRecognizerStateEnded; [owner panned:owner.pan];
        owner.pan.state = UIGestureRecognizerStatePossible;
        Check(profileDragEnded && !profileDragCommitted && profileReturns == 0 && account.profilePrefix.count,
              @"profile Back: an early release stays on the profile");
        owner.pan.translation = CGPointMake(30, 0);
        owner.pan.state = UIGestureRecognizerStateBegan; [owner gestureRecognizerShouldBegin:owner.pan]; [owner panned:owner.pan];
        owner.pan.state = UIGestureRecognizerStateCancelled; [owner panned:owner.pan];
        owner.pan.state = UIGestureRecognizerStatePossible;
        Check(profileDragEnded && !profileDragCommitted && profileReturns == 0,
              @"profile Back: a cancelled drag (a fold, Control Center) springs back");
        // Without a picture (Reduce Motion, a resize since) it leaves at once.
        profileDragFollows = NO;
        Drag(owner);
        profileDragFollows = YES;
        Check(profileReturns == 1 && profile.pops == 0, @"the swipe leaves the visited profile through its Back transition");
        account.profilePrefix = @[[UIViewController new]];
        Drag(owner);
        Check(profileDragsBegun == 3 && profileDragCommitted && profileReturns == 2 && profile.pops == 0,
              @"profile Back: a full drag leaves the profile under the finger");
        profileReturns = 1;
        Check(!ApolloDuoBackSwipeCanNavigate(profile), @"once left, the profile pane has nothing to go Back to");
        // The profile's left column (header and shortcuts) belongs to the
        // same visit, so a swipe there leaves the profile too.
        account.profilePrefix = @[[UIViewController new]];
        UINavigationController *header = Navigation();
        header.viewControllers = @[[UIViewController new]];
        header.duoState = account; account.primary = header;
        Check(ApolloDuoBackSwipeCanNavigate(header), @"the visited profile's left column can swipe Back out of the profile");
        ApolloDuoInstallBackSwipe(header); owner = objc_getAssociatedObject(header, &kApolloDuoBackSwipe);
        Drag(owner);
        Check(profileReturns == 2 && header.pops == 0, @"a left-column swipe leaves the visited profile the same way");
        Check(!ApolloDuoBackSwipeCanNavigate(header), @"after leaving, the left column swipe stands down");
        account.profilePrefix = @[[UIViewController new]]; account.tabKind = @"profile";
        Check(!ApolloDuoBackSwipeCanNavigate(profile), @"the Account tab's own profile is a root, not a visit");

        // Each pane's swipe acts on its own pane, with the setting on as off:
        // a swipe in the feed does the feed's own Back (the list at its root)
        // and leaves the thread beside it open; a swipe in the thread closes
        // or pops the thread.
        UINavigationController *feed2 = Navigation(); UINavigationController *thread = Navigation();
        feed2.viewControllers = @[[UIViewController new]];
        ApolloDuoSplitState *posts = [ApolloDuoSplitState new];
        posts.split = [NSObject new]; posts.host = [TestDuoHost new]; posts.host.postsShowingDetail = YES;
        posts.feed = feed2; posts.secondary = thread; feed2.duoState = posts; thread.duoState = posts;
        ApolloDuoInstallBackSwipe(feed2); owner = objc_getAssociatedObject(feed2, &kApolloDuoBackSwipe);
                NSUInteger revealsBefore = drawerReveals;
        leftSwipesDisabled = YES;
        Drag(owner);
        Check(drawerReveals == revealsBefore + 1 && thread.pops == 0 && feed2.pops == 0,
              @"Disable Left Swipes: a feed-root swipe opens the list and leaves the thread beside it open");
        posts.host.listVisible = NO;
        feed2.viewControllers = @[[UIViewController new], [UIViewController new]];
        Drag(owner);
        Check(feed2.pops == 1 && thread.pops == 0 && drawerReveals == revealsBefore + 1,
              @"Disable Left Swipes: a feed-pane swipe pops the feed's own page, not the thread beside it");
        thread.viewControllers = @[[UIViewController new], [UIViewController new], [UIViewController new]];
        ApolloDuoInstallBackSwipe(thread);
        ApolloDuoBackSwipe *threadOwner = objc_getAssociatedObject(thread, &kApolloDuoBackSwipe);
        Drag(threadOwner);
        Check(ApolloDuoPaneBackIsNative(thread) && thread.pops == 0 && feed2.pops == 1,
              @"Disable Left Swipes: a page pushed over the thread is Apollo's own Back, which follows the finger");
        thread.viewControllers = @[[UIViewController new], [UIViewController new]];
        threadCanClose = YES; threadClosed = NO;
        Drag(threadOwner);
        Check(threadClosed && thread.pops == 0 && feed2.pops == 1 && drawerReveals == revealsBefore + 1,
              @"Disable Left Swipes: the next thread-pane drag closes the thread itself, following the finger");
        threadCanClose = NO;
        posts.host.postsShowingDetail = YES; thread.viewControllers = @[[UIViewController new], [UIViewController new]];
        feed2.viewControllers = @[[UIViewController new]];
        leftSwipesDisabled = NO;
        Drag(owner);
        Check(thread.pops == 0 && drawerReveals == revealsBefore + 2,
              @"with left swipes on, the feed edge keeps #1245's per-pane behavior (opens the list)");
        leftSwipesDisabled = NO;
        touch.view = cell;
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"with left swipes on, interior touches stay with row actions");

        // The forward swipe brings back the thread a close took from beside the
        // feed, on release: from the feed's trailing strip, or anywhere with
        // Disable Right Swipes on, and only while the split has one to bring back.
        {
            UINavigationController *fwdFeed = Navigation();
            fwdFeed.viewControllers = @[[UIViewController new]];
            ApolloDuoSplitState *fwdState = [ApolloDuoSplitState new];
            fwdState.split = [NSObject new]; fwdState.host = [TestDuoHost new]; fwdState.feed = fwdFeed;
            fwdState.secondary = Navigation(); fwdState.secondary.viewControllers = @[[UIViewController new]];
            fwdFeed.duoState = fwdState;
            ApolloDuoInstallBackSwipe(fwdFeed);
            ApolloDuoBackSwipe *fwdOwner = objc_getAssociatedObject(fwdFeed, &kApolloDuoBackSwipe);
            Check(fwdOwner.forwardSwipe.maximumNumberOfTouches == 1
                  && [fwdFeed.view.gestureRecognizers containsObject:fwdOwner.forwardSwipe],
                  @"forward: a one-finger drag is installed beside Back");
            fwdOwner.forwardSwipe.translation = CGPointMake(-30, 0);
            UITouch *strip = [UITouch new]; strip.point = CGPointMake(1270, 300); strip.view = fwdFeed.view;
            UITouch *inner = [UITouch new]; inner.point = CGPointMake(600, 300); inner.view = fwdFeed.view;
            UITouch *leading = [UITouch new]; leading.point = CGPointMake(5, 300); leading.view = fwdFeed.view;
            closedThreadFeed = nil; rightSwipesDisabled = NO;
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip]
                  && ![fwdOwner gestureRecognizer:fwdOwner.highlightGuard shouldReceiveTouch:strip]
                  && ![fwdOwner gestureRecognizerShouldBegin:fwdOwner.forwardSwipe],
                  @"forward: nothing remembered, nothing to swipe");
            closedThreadFeed = fwdFeed;
            Check([fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip]
                  && [fwdOwner gestureRecognizerShouldBegin:fwdOwner.forwardSwipe],
                  @"forward: the trailing strip of the feed starts it");
            fwdOwner.forwardSwipe.translation = CGPointMake(2, 30);
            Check(![fwdOwner gestureRecognizerShouldBegin:fwdOwner.forwardSwipe], @"forward: vertical motion never starts it");
            fwdOwner.forwardSwipe.translation = CGPointMake(30, 0);
            Check(![fwdOwner gestureRecognizerShouldBegin:fwdOwner.forwardSwipe], @"forward: a rightward drag is not forward");
            fwdOwner.forwardSwipe.translation = CGPointMake(-30, 0);
            strip.point = CGPointMake(1280 - 28, 300);
            Check([fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: the strip is 28pt wide");
            strip.point = CGPointMake(1280 - 29, 300);
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: just inside the strip, row swipe actions keep the touch");
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:inner],
                  @"forward: the feed's interior keeps its row actions by default");
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:leading],
                  @"forward: the leading edge is Back's, not forward's");
            strip.point = CGPointMake(1270, 300);
            Check(![fwdOwner gestureRecognizer:fwdOwner.pan shouldReceiveTouch:strip],
                  @"forward: the Back swipe does not take the trailing strip");
            Check([fwdOwner gestureRecognizer:fwdOwner.pan shouldReceiveTouch:leading],
                  @"forward: Back keeps its leading edge with a thread to bring back");
            Check([fwdOwner gestureRecognizer:fwdOwner.highlightGuard shouldReceiveTouch:strip],
                  @"forward: the highlight guard takes the strip too, so the row drops its highlight");
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldRecognizeSimultaneouslyWithGestureRecognizer:[UIPanGestureRecognizer new]]
                  && [fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldBeRequiredToFailByGestureRecognizer:[UIPanGestureRecognizer new]],
                  @"forward: at the strip it has priority over row gestures");
            rightSwipesDisabled = YES;
            Check([fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:inner]
                  && [fwdOwner gestureRecognizer:fwdOwner.highlightGuard shouldReceiveTouch:inner],
                  @"forward: with Disable Right Swipes on, it starts anywhere in the feed");
            UIScrollView *carousel = [UIScrollView new]; carousel.scrollEnabled = YES;
            carousel.bounds = CGRectMake(0, 0, 400, 100); carousel.contentSize = CGSizeMake(1200, 100);
            carousel.contentOffset = CGPointMake(300, 0); inner.view = carousel;
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:inner],
                  @"forward: a carousel with more to scroll forward keeps its drag");
            carousel.contentOffset = CGPointMake(800, 0);
            Check([fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:inner],
                  @"forward: a carousel at its last item hands the swipe over");
            strip.view = carousel; strip.point = CGPointMake(1270, 300); carousel.contentOffset = CGPointMake(300, 0);
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: a carousel with more to scroll keeps the strip too, so one swipe never does both");
            carousel.contentOffset = CGPointMake(800, 0);
            Check([fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: the strip goes forward over a carousel at its last item");
            inner.view = fwdFeed.view; strip.view = fwdFeed.view;
            rightSwipesDisabled = NO;
            // The thread follows the finger, and acts on release, once.
            NSUInteger restoresBefore = threadRestores;
            ForwardDrag(fwdOwner, -60);
            Check(restoreDragsBegun == 1 && restoreShown == 60 && !restoreEnded && threadRestores == restoresBefore,
                  @"forward: the closed thread follows the finger, nothing restored yet");
            ForwardRelease(fwdOwner, -60, 0);
            Check(restoreEnded && !restoreCommitted && threadRestores == restoresBefore,
                  @"forward: an early release slides the thread back out");
            restoreEnded = NO;
            ForwardDrag(fwdOwner, -300); ForwardRelease(fwdOwner, -300, 0);
            Check(restoreEnded && restoreCommitted && threadRestores == restoresBefore + 1 && fwdFeed.pops == 0,
                  @"forward: a release past the threshold brings the closed thread back");
            Check(![fwdOwner gestureRecognizerShouldBegin:fwdOwner.forwardSwipe],
                  @"forward: a second drag finds nothing to bring back");
            closedThreadFeed = fwdFeed; restoreFollows = NO; restoreEnded = NO;
            ForwardDrag(fwdOwner, -300); ForwardRelease(fwdOwner, -300, 0);
            Check(!restoreEnded && threadRestores == restoresBefore + 2,
                  @"forward: with no picture to follow, it still restores on release");
            restoreFollows = YES;
            closedThreadFeed = fwdFeed; fwdState.host.postsShowingDetail = YES;
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: with a thread already beside the feed there is nothing to bring back");
            fwdState.host.postsShowingDetail = NO;
            Check([fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip], @"forward: control, restorable again");
            disabled = YES;
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: Disable Navigation Gestures is honored");
            disabled = NO; resizing = YES;
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: a fold or rotation in flight blocks it");
            resizing = NO; fwdFeed.transitionCoordinator = [NSObject new];
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: a push or pop in flight blocks it");
            fwdFeed.transitionCoordinator = nil; fwdFeed.presentedViewController = [UIViewController new];
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: never behind a sheet");
            fwdFeed.presentedViewController = nil; duo = NO;
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip],
                  @"forward: ordinary phones are excluded");
            duo = YES; closedThreadFeed = nil;

            // After a Back out of a visited profile, the Posts pane it came
            // back to brings it forward again, following the finger.
            restoreEnded = NO; profileDragEnded = NO;
            NSUInteger dragsBefore = restoreDragsBegun, forwardsBefore = profileForwards;
            profileForwardPane = fwdFeed;
            Check([fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:strip]
                  && [fwdOwner gestureRecognizerShouldBegin:fwdOwner.forwardSwipe],
                  @"forward profile: the trailing strip starts it");
            Check(![fwdOwner gestureRecognizer:fwdOwner.forwardSwipe shouldReceiveTouch:inner],
                  @"forward profile: the pane's interior keeps its row actions");
            ForwardDrag(fwdOwner, -80);
            Check(profileDragsBegun && profileDragForward && profileDragShown == 80 && profileForwards == forwardsBefore
                  && restoreDragsBegun == dragsBefore,
                  @"forward profile: the profile follows the finger, not the closed thread's picture");
            ForwardRelease(fwdOwner, -80, 0);
            Check(profileDragEnded && !profileDragCommitted && profileForwards == forwardsBefore,
                  @"forward profile: an early release slides it back out");
            ForwardDrag(fwdOwner, -400); ForwardRelease(fwdOwner, -400, 0);
            Check(profileDragCommitted && profileForwards == forwardsBefore + 1 && !restoreEnded,
                  @"forward profile: a full drag brings the profile back");
            Check(![fwdOwner gestureRecognizerShouldBegin:fwdOwner.forwardSwipe],
                  @"forward profile: once back on the profile there is nothing forward");
            profileForwardPane = fwdFeed; profileDragFollows = NO; profileDragEnded = NO;
            ForwardDrag(fwdOwner, -400); ForwardRelease(fwdOwner, -400, 0);
            Check(!profileDragEnded && profileForwards == forwardsBefore + 2,
                  @"forward profile: with no picture it still goes forward on release");
            profileDragFollows = YES;
            profileForwardPane = fwdFeed; closedThreadFeed = fwdFeed;
            ForwardDrag(fwdOwner, -400); ForwardRelease(fwdOwner, -400, 0);
            Check(restoreEnded && restoreCommitted && profileForwards == forwardsBefore + 2,
                  @"forward profile: a closed thread to bring back comes first");
            closedThreadFeed = nil; profileForwardPane = nil;
        }

        // The memory forgets the thread whenever what the feed shows changes
        // (the rules the split applies): the events and facts of the moment.
        {
            typedef ApolloDuoClosedThreadFacts ThreadFacts;
            ThreadFacts current = {.split = YES, .feedPageOnTop = YES, .feedUnchanged = YES, .accountUnchanged = YES};
            Check(!ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventCheck, current),
                  @"memory: kept while its feed page is on top and no thread is open");
            ThreadFacts folded = current; folded.split = NO;
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventCheck, folded) != nil,
                  @"memory: folding or turning to portrait forgets it");
            ThreadFacts threadOpen = current; threadOpen.threadOpen = YES;
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventCheck, threadOpen) != nil,
                  @"memory: a thread shown beside the feed forgets it");
            ThreadFacts otherPage = current; otherPage.feedPageOnTop = NO;
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventCheck, otherPage) != nil,
                  @"memory: a new feed page (subreddit switch, feed link, Search) or a gone one forgets it");
            ThreadFacts otherFeed = current; otherFeed.feedUnchanged = NO;
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventCheck, otherFeed) != nil,
                  @"memory: the same feed page showing another feed (reused in place) forgets it");
            ThreadFacts otherAccount = current; otherAccount.accountUnchanged = NO;
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventCheck, otherAccount) != nil,
                  @"memory: another account's session on the same feed page forgets it");
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventAccountChanged, current) != nil,
                  @"memory: an account switch forgets it whatever the facts say");
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventScrolledAway, current) != nil,
                  @"memory: scrolling the feed away from where it was closed forgets it");
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventFeedOpened, current) != nil,
                  @"memory: a feed opening (list row, feed link, Search, a reroot) forgets it whatever the facts say");
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventThreadOpened, current) != nil,
                  @"memory: another thread opening beside the feed forgets it");
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventMemoryWarning, current) != nil,
                  @"memory: a memory warning forgets it, as Apollo's own forward page");
            ThreadFacts away = current;
            away.away = 5.0;
            Check(!ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventForeground, away),
                  @"memory: a short trip to the background keeps it");
            away.away = kApolloDuoClosedThreadBackgroundLimit;
            Check(!ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventForeground, away),
                  @"memory: up to the background limit keeps it");
            away.away = kApolloDuoClosedThreadBackgroundLimit + 1.0;
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventForeground, away) != nil,
                  @"memory: a longer stay in the background forgets it");
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventCheck, away) == nil,
                  @"memory: only a return from the background reads the time away");
            away.away = 5.0; away.feedPageOnTop = NO;
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventForeground, away) != nil,
                  @"memory: a short trip still forgets it when the feed changed meanwhile");
            ThreadFacts onStack = current; onStack.pagesOnStack = YES;
            Check(ApolloDuoClosedThreadForgetReason(ApolloDuoClosedThreadEventCheck, onStack) != nil,
                  @"memory: pages that are on a stack again are never pushed twice");
            UIViewController *backstop = [UIViewController new], *thread = [UIViewController new], *profile = [UIViewController new];
            Check([ApolloDuoClosedThreadPages(@[backstop, thread, profile]) isEqualToArray:@[thread, profile]],
                  @"remember: the thread and every page pushed over it, without the backstop");
            Check(ApolloDuoClosedThreadPages(@[backstop]).count == 0 && ApolloDuoClosedThreadPages(@[]).count == 0,
                  @"remember: nothing when only the backstop is left");
        }
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
