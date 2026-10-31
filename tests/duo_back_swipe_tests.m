#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

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
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) id delegate;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) NSInteger state;
@property(nonatomic) BOOL delaysTouchesBegan;
@property(nonatomic) NSUInteger superMoves, targetCount, disables;
// Starts enabled; counts every disable (UIKit cancels a recognizer then).
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic) CGPoint location;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (CGPoint)locationInView:(UIView *)view;
- (void)addTarget:(id)target action:(SEL)action;
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)reset;
@end
@implementation UIGestureRecognizer
- (instancetype)init { if ((self = [super init])) _enabled = YES; return self; }
- (instancetype)initWithTarget:(__unused id)target action:(__unused SEL)action { return [self init]; }
- (void)setEnabled:(BOOL)enabled { if (!enabled) self.disables++; _enabled = enabled; }
- (CGPoint)locationInView:(__unused UIView *)view { return self.location; }
- (void)addTarget:(__unused id)target action:(__unused SEL)action { self.targetCount++; }
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
@property(nonatomic) CGPoint velocity, translation;
- (CGPoint)velocityInView:(UIView *)view;
- (CGPoint)translationInView:(UIView *)view;
@end
// The split's translationInView: hook body, from production.
static CGPoint ApolloDuoSplitReleaseTranslation(UIPanGestureRecognizer *gesture, UIView *view, CGPoint translation);
@implementation UIPanGestureRecognizer
- (CGPoint)velocityInView:(__unused UIView *)view { return self.velocity; }
// Reports its translation through the split's hook body, as the hooked UIKit pan does.
- (CGPoint)translationInView:(UIView *)view { return ApolloDuoSplitReleaseTranslation(self, view, self.translation); }
@end
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
@interface UISlider : UIView @end
@implementation UISlider @end
@interface UISwitch : UIView @end
@implementation UISwitch @end
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
// A real content page, as opposed to the split's plain placeholder.
@interface TestPage : UIViewController @end
@implementation TestPage @end
@interface UINavigationController : UIViewController {
@public
    // Apollo's own pans, read through the runtime like the Swift ivars.
    UIPanGestureRecognizer *leftScreenEdgePanGestureRecognizer;
    UIPanGestureRecognizer *rightScreenEdgePanGestureRecognizer;
    UIPanGestureRecognizer *navigationBarPanGestureRecognizer;
}
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
@end
@implementation ApolloDuoSplitState @end
static BOOL duo = YES, disabled, leftSwipesDisabled, resizing, reduceMotion;
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
    return NO;
}
@end
#define NSUserDefaults TestDefaults
static BOOL ApolloDeviceIsDuo(void) { return duo; }
static BOOL ApolloDuoSplitIsResizing(void) { return resizing; }
static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, __unused BOOL create) { return nav.duoState; }
static CGRect ApolloDuoSplitContentFrame(UINavigationController *nav, __unused UIView *view) { return nav.pane; }
typedef NSInteger UIGestureRecognizerState;
enum { UIGestureRecognizerStatePossible = 0,
       UIGestureRecognizerStateBegan = 1, UIGestureRecognizerStateChanged = 2, UIGestureRecognizerStateEnded = 3,
       UIGestureRecognizerStateCancelled = 4, UIGestureRecognizerStateRecognized = 3, UIGestureRecognizerStateFailed = 5 };
// INCLUDE_PRODUCTION_SPLIT_POLICIES
static BOOL ApolloDuoSplitRevealPostsList(UINavigationController *nav) {
    nav.duoState.host.listVisible = YES;
    drawerReveals++;
    return YES;
}
static BOOL ApolloDuoSplitReturnFromVisitedProfile(UINavigationController *nav) {
    if (!ApolloDuoSplitCanReturnFromVisitedProfile(nav)) return NO;
    nav.duoState.profilePrefix = nil;
    profileReturns++;
    return YES;
}
static BOOL UIAccessibilityIsReduceMotionEnabled(void) { return reduceMotion; }
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
// A clear rightward move: may the pane Back begin?
static BOOL Begins(ApolloDuoBackSwipe *owner) {
    owner.pan.velocity = CGPointMake(300, 40); owner.pan.translation = CGPointMake(12, 1);
    return [owner gestureRecognizerShouldBegin:owner.pan];
}
// Drives the pane Back through began, changed and ended, as UIKit does once
// it has begun; the release has translation dx and horizontal velocity vx.
static void Drag(ApolloDuoBackSwipe *owner, CGFloat dx, CGFloat vx) {
    ApolloDuoPaneBackPan *pan = owner.pan;
    pan.translation = CGPointZero; pan.velocity = CGPointMake(300, 40);
    pan.state = UIGestureRecognizerStateBegan; [owner panned:pan];
    pan.translation = CGPointMake(dx, 4); pan.velocity = CGPointMake(vx, 10);
    pan.state = UIGestureRecognizerStateChanged; [owner panned:pan];
    pan.state = UIGestureRecognizerStateEnded; [owner panned:pan];
    pan.state = UIGestureRecognizerStatePossible;
}
// A quick flick, what the discrete swipe used to recognize.
static void Fling(ApolloDuoBackSwipe *owner) { Drag(owner, 160, 900); }
// Apollo's release rule, transcribed from -[ApolloNavigationController
// screenEdgePanned:] (Apollo 1.15.11, Swift body sub_10015e204, also behind
// navigationBarPanned:). Back finishes on vx >= 100 (0x10015e848) or
// tx >= 0.5 * view width (0x10015e8e4); Forward on vx <= -100 (0x10015e798)
// or tx <= -0.5 * view width (0x10015e834). Otherwise it cancels.
static BOOL ApolloNativeReleaseFinishes(BOOL back, CGFloat vx, CGFloat tx, CGFloat viewWidth) {
    if (back) return vx >= 100.0 || tx >= 0.5 * viewWidth;
    return vx <= -100.0 || tx <= -0.5 * viewWidth;
}
// What Apollo decides on releasing `pan` in `nav`: its own rule, fed the
// translation the split's translationInView: hook reports for that release.
static BOOL NativeReleaseFinishes(UINavigationController *nav, UIPanGestureRecognizer *pan, BOOL back, CGFloat vx, CGFloat tx) {
    pan.state = UIGestureRecognizerStateEnded;
    pan.velocity = CGPointMake(vx, 0); pan.translation = CGPointMake(tx, 0);
    CGFloat scale = ApolloDuoSplitNativePanReleaseScaleForNavigation(nav, pan);
    return ApolloNativeReleaseFinishes(back, vx, tx * scale, CGRectGetWidth(nav.view.bounds));
}
// A split pane's navigation, 951 pt wide like the unfolded landscape Duo,
// with Apollo's three navigation pans.
static UINavigationController *NativePanNavigation(ApolloDuoSplitState *state, CGRect pane) {
    UINavigationController *nav = Navigation();
    nav.view.bounds = CGRectMake(0, 0, 951, 669);
    nav.pane = pane; nav.duoState = state;
    nav->leftScreenEdgePanGestureRecognizer = [UIPanGestureRecognizer new];
    nav->rightScreenEdgePanGestureRecognizer = [UIPanGestureRecognizer new];
    nav->navigationBarPanGestureRecognizer = [UIPanGestureRecognizer new];
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
        Check(ApolloDuoHasBackSwipe(nav) && nav.view.gestureRecognizers.count == 2, @"recognizer installation is idempotent (swipe + highlight guard)");
        ApolloDuoBackSwipe *owner = objc_getAssociatedObject(nav, &kApolloDuoBackSwipe);
        Check([owner.pan isMemberOfClass:ApolloDuoPaneBackPan.class] && owner.pan.maximumNumberOfTouches == 1
              && [owner.pan.name isEqualToString:@"ApolloReborn.Duo.PaneBack"] && owner.pan.delegate == owner
              && [nav.view.gestureRecognizers containsObject:owner.pan],
              @"Back is a one-finger pan, ApolloReborn.Duo.PaneBack, beside its highlight guard");
        UITouch *touch = [UITouch new]; touch.point = CGPointMake(5, 300);
        Check([owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"real delegate accepts the content-edge touch");
        touch.point = CGPointMake(200, 300);
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"real delegate rejects interior touches");
        UIScrollView *scroll = [UIScrollView new]; scroll.panGestureRecognizer = [UIPanGestureRecognizer new];
        scroll.panGestureRecognizer.view = scroll;
        Check([owner gestureRecognizer:owner.pan shouldRecognizeSimultaneouslyWithGestureRecognizer:scroll.panGestureRecognizer],
              @"table scrolling does not wait for the swipe");
        UIPanGestureRecognizer *row = [UIPanGestureRecognizer new];
        Check(![owner gestureRecognizer:owner.pan shouldRecognizeSimultaneouslyWithGestureRecognizer:row],
              @"a row action cannot fire alongside Back");
        Check([owner gestureRecognizer:owner.pan shouldBeRequiredToFailByGestureRecognizer:row]
              && ![owner gestureRecognizer:owner.pan shouldBeRequiredToFailByGestureRecognizer:scroll.panGestureRecognizer],
              @"edge Back has priority over row gestures without blocking table pans");
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
        // Folded, the native pan owns every pop; the swipe acts for a thread
        // right above the Posts backstop.
        ApolloDuoSplitState *threadSplit = [ApolloDuoSplitState new];
        threadSplit.split = [NSObject new]; threadSplit.host = [TestDuoHost new]; threadSplit.host.postsShowingDetail = YES;
        UINavigationController *threadFeed = Navigation();
        threadSplit.feed = threadFeed; threadSplit.secondary = nav; nav.duoState = threadSplit; threadFeed.duoState = threadSplit;
        Fling(owner); Fling(owner);
        Check(nav.pops == 1 && nav.viewControllers.count == 1 && nav.lastAnimated,
              @"recognized swipe performs one native animated Back and stops at root");
        Check(!Begins(owner), @"root page has no Back gesture");
        nav.duoState = nil;
        nav = Navigation(); reduceMotion = YES; nav.duoState = threadSplit; threadSplit.secondary = nav;
        ApolloDuoInstallBackSwipe(nav); owner = objc_getAssociatedObject(nav, &kApolloDuoBackSwipe);
        Fling(owner);
        Check(nav.pops == 1 && !nav.lastAnimated, @"Reduce Motion suppresses the Back animation");
        nav.duoState = nil;
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
        Fling(owner); Fling(owner);
        Check(drawerReveals == 1 && feed.pops == 0 && split.host.listVisible, @"root swipe reveals menu once without popping root or toggling closed");
        Check(!ApolloDuoBackSwipeCanNavigate(feed), @"open drawer blocks underlying feed swipe");
        split.host.listVisible = NO; split.changing = YES;
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

        // Apollo's own interactive Back (its left edge pan) follows the
        // finger. It owns every pop onto a real page of the same pane, with or
        // without Disable Left Swipes, and the discrete pane swipe stands down.
        leftSwipesDisabled = NO;
        nav = Navigation();
        Check(ApolloDuoSplitPopRevealsContent(nav) && ApolloDuoNativeBackPanOwns(nav),
              @"folded / no split: the native pan owns every pop, as on a regular iPhone");
        ApolloDuoInstallBackSwipe(nav); owner = objc_getAssociatedObject(nav, &kApolloDuoBackSwipe);
        Check(ApolloDuoBackSwipeCanNavigate(nav) && !Begins(owner),
              @"no split: the pane swipe stands down for the native pan");
        owner.highlightGuard.velocity = CGPointMake(300, 40);
        Check([owner gestureRecognizerShouldBegin:owner.highlightGuard], @"the highlight guard still begins so the row drops its highlight");
        UIPanGestureRecognizer *nativeBack = [UIPanGestureRecognizer new];
        Check(!ApolloDuoNativeBackPan(nav), @"no Apollo Back pan yet: nothing is read");
        nav->leftScreenEdgePanGestureRecognizer = nativeBack;
        Check(ApolloDuoNativeBackPan(nav) == nativeBack, @"Apollo's Back pan is read from its ivar");
        Check(![owner gestureRecognizer:owner.pan shouldBeRequiredToFailByGestureRecognizer:nativeBack],
              @"Apollo's Back pan does not wait for a pane swipe that stood down: it follows the finger from the first point");
        Check([owner gestureRecognizer:owner.pan shouldBeRequiredToFailByGestureRecognizer:row],
              @"row actions still wait for the edge strip's Back");
        leftSwipesDisabled = YES;
        Check(ApolloDuoNativeBackPanOwns(nav) && !Begins(owner),
              @"Disable Left Swipes does not change who owns the pop");
        leftSwipesDisabled = NO; resizing = YES;
        Check(!ApolloDuoNativeBackPanOwns(nav), @"a fold or rotation in progress keeps the native pan from starting");
        resizing = NO;
        nav.viewControllers = @[[UIViewController new]];
        Check(!ApolloDuoNativeBackPanOwns(nav), @"nothing for the native pan to pop at a root");

        // The Posts split: a thread right above its backstop closes with the
        // column change, never with a native pop onto the backstop.
        UINavigationController *ownFeed = Navigation(), *ownThread = Navigation();
        ownFeed.viewControllers = @[[UIViewController new]];
        UIViewController *backstop = [UIViewController new];
        ownThread.viewControllers = @[backstop, [TestPage new]];
        ApolloDuoSplitState *ownPosts = [ApolloDuoSplitState new];
        ownPosts.split = [NSObject new]; ownPosts.host = [TestDuoHost new]; ownPosts.host.postsShowingDetail = YES;
        ownPosts.feed = ownFeed; ownPosts.secondary = ownThread; ownFeed.duoState = ownPosts; ownThread.duoState = ownPosts;
        Check(!ApolloDuoSplitPopRevealsContent(ownThread) && !ApolloDuoNativeBackPanOwns(ownThread),
              @"thread right above the backstop: not a native pop");
        ApolloDuoInstallBackSwipe(ownThread); owner = objc_getAssociatedObject(ownThread, &kApolloDuoBackSwipe);
        ownThread->leftScreenEdgePanGestureRecognizer = nativeBack;
        Check(Begins(owner), @"the pane swipe closes that thread");
        Check([owner gestureRecognizer:owner.pan shouldBeRequiredToFailByGestureRecognizer:nativeBack],
              @"where the pane swipe owns Back, Apollo's pan keeps waiting for it");
        ownThread.viewControllers = @[backstop, [TestPage new], [TestPage new]];
        Check(ApolloDuoSplitPopRevealsContent(ownThread) && ApolloDuoNativeBackPanOwns(ownThread),
              @"a profile pushed over a thread: the native pan owns the pop back to the thread");
        Check(!Begins(owner), @"the pane swipe stands down for that pop");
        Check(!ApolloDuoNativeBackPanOwns(ownFeed), @"the feed root reveals the list, not a native pop");
        ownFeed.viewControllers = @[[UIViewController new], [TestPage new]];
        Check(!ApolloDuoSplitPopRevealsContent(ownFeed) && !ApolloDuoNativeBackPanOwns(ownFeed),
              @"a feed page beside an open thread: the pane swipe keeps that pop, since Apollo's pans stay off the feed there");
        ownPosts.host.postsShowingDetail = NO; ownThread.viewControllers = @[backstop];
        Check(ApolloDuoNativeBackPanOwns(ownFeed), @"a feed-link page with no thread beside it pops natively");
        ownPosts.changing = YES;
        Check(!ApolloDuoSplitPopRevealsContent(ownFeed) && !ApolloDuoNativeBackPanOwns(ownFeed),
              @"column changes never hand a pop to the native pan");
        ownPosts.changing = NO;
        UINavigationController *ownOuter = Navigation(), *ownList = Navigation();
        ownOuter.duoState = ownPosts; ownList.duoState = ownPosts; ownPosts.primary = ownList;
        Check(!ApolloDuoNativeBackPanOwns(ownOuter) && !ApolloDuoNativeBackPanOwns(ownList),
              @"the outer host and the drawer list are not panes");

        // A native pop that still lands on the backstop (a Swift-direct pop:
        // the tab-bar pan, the goBack key command) closes the column.
        ownPosts.host.postsShowingDetail = YES;
        ownThread.viewControllers = @[backstop, [TestPage new]];
        Check(!ApolloDuoPostsPopReachedBackstop(ownPosts, ownThread, ownThread.viewControllers.lastObject),
              @"while the thread is still on top, nothing closes the column");
        UIViewController *poppedThread = ownThread.viewControllers.lastObject;
        ownThread.viewControllers = @[backstop];
        Check(ApolloDuoPostsPopReachedBackstop(ownPosts, ownThread, backstop), @"a completed pop onto the backstop closes the thread column");
        Check(!ApolloDuoPostsPopReachedBackstop(ownPosts, ownFeed, backstop)
              && !ApolloDuoPostsPopReachedBackstop(ownPosts, ownThread, poppedThread),
              @"only the thread pane showing its backstop closes the column");
        ownPosts.changing = YES;
        Check(!ApolloDuoPostsPopReachedBackstop(ownPosts, ownThread, backstop),
              @"the split's own close (setViewControllers while changing) is not mistaken for a native pop");
        ownPosts.changing = NO; ownPosts.host.postsShowingDetail = NO;
        Check(!ApolloDuoPostsPopReachedBackstop(ownPosts, ownThread, backstop), @"an already closed column is not closed again");
        ApolloDuoSplitState *noFeed = [ApolloDuoSplitState new];
        noFeed.split = [NSObject new]; noFeed.host = [TestDuoHost new]; noFeed.host.postsShowingDetail = YES;
        noFeed.secondary = ownThread;
        Check(!ApolloDuoPostsPopReachedBackstop(noFeed, ownThread, backstop), @"other splits have no thread backstop");
        ownPosts.split = nil; ownPosts.host.postsShowingDetail = YES;
        Check(!ApolloDuoPostsPopReachedBackstop(ownPosts, ownThread, backstop), @"no split, no column to close");

        // Two Backs from one swipe: Apollo's pan pops the profile over a
        // thread and changes the stack as it begins. A pane swipe that
        // recognizes mid-drag must not then close the thread as well.
        ownPosts.split = [NSObject new]; ownPosts.host.postsShowingDetail = YES; ownPosts.host.listVisible = NO;
        UIViewController *flightThread = [TestPage new];
        ownThread.viewControllers = @[backstop, flightThread, [TestPage new]];
        ownFeed.viewControllers = @[[UIViewController new]];
        UIPanGestureRecognizer *threadBack = [UIPanGestureRecognizer new];
        ownThread->leftScreenEdgePanGestureRecognizer = threadBack;
        owner = objc_getAssociatedObject(ownThread, &kApolloDuoBackSwipe);
        Check(ApolloDuoNativeBackPanOwns(ownThread) && !ApolloDuoNativeBackInFlight(ownThread), @"before the drag: native owns, nothing in flight");
        ApolloDuoNoteNativeBackBegan(ownThread); ApolloDuoNoteNativeBackBegan(ownThread);
        Check(threadBack.targetCount == 1, @"Apollo's Back pan is followed once");
        threadBack.state = UIGestureRecognizerStateBegan; [owner nativeBackChanged:threadBack];
        ownThread.viewControllers = @[backstop, flightThread];
        Check(ApolloDuoNativeBackInFlight(ownThread), @"while Apollo's pan drags its pop is in flight");
        Check(!Begins(owner), @"the pane swipe cannot begin under a native drag");
        NSUInteger threadPops = ownThread.pops;
        Fling(owner);
        Check(ownThread.pops == threadPops && ownThread.viewControllers.count == 2,
              @"a pane swipe acting mid-drag does not close the thread too");
        threadBack.state = UIGestureRecognizerStateChanged; [owner nativeBackChanged:threadBack];
        threadBack.state = UIGestureRecognizerStateEnded; [owner nativeBackChanged:threadBack];
        threadBack.state = UIGestureRecognizerStatePossible;
        Check(ApolloDuoNativeBackInFlight(ownThread), @"after release the pop is still settling");
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kApolloDuoNativeBackSettleDelay * 1.5]];
        Check(!ApolloDuoNativeBackInFlight(ownThread) && Begins(owner),
              @"once settled, the pane swipe owns the thread close again");
        ApolloDuoNoteNativeBackBegan(ownThread);
        threadBack.state = UIGestureRecognizerStateChanged;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kApolloDuoNativeBackSettleDelay * 1.5]];
        Check(ApolloDuoNativeBackInFlight(ownThread), @"a long drag stays in flight past the settle delay");
        threadBack.state = UIGestureRecognizerStateEnded;
        ApolloDuoNoteNativeBackShown(ownThread);
        Check(!ApolloDuoNativeBackInFlight(ownThread), @"didShow after the pop completes settles it at once");
        threadBack.state = UIGestureRecognizerStatePossible;
        ApolloDuoNoteNativeBackBegan(ownThread);
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kApolloDuoNativeBackSettleDelay * 1.5]];
        Check(!ApolloDuoNativeBackInFlight(ownThread), @"a pan allowed to begin that never began does not stick");

        // Sidebar splits: a real previous page pops natively; the empty
        // detail's placeholder and Account's Overview stay the split's own.
        UINavigationController *detailPane = Navigation();
        ApolloDuoSplitState *settings = [ApolloDuoSplitState new];
        settings.split = [NSObject new]; settings.host = [TestDuoHost new]; settings.kind = @"settings";
        settings.secondary = detailPane; detailPane.duoState = settings;
        detailPane.viewControllers = @[[TestPage new], [TestPage new]];
        Check(ApolloDuoSplitPopRevealsContent(detailPane) && ApolloDuoNativeBackPanOwns(detailPane),
              @"a deeper Settings page: the native pan owns the pop");
        ApolloDuoInstallBackSwipe(detailPane); owner = objc_getAssociatedObject(detailPane, &kApolloDuoBackSwipe);
        Check(!Begins(owner), @"the pane swipe stands down for a deeper Settings page");
        detailPane.viewControllers = @[[TestPage new]];
        Check(!ApolloDuoNativeBackPanOwns(detailPane), @"a sidebar detail root: nothing to pop");
        detailPane.viewControllers = @[[UIViewController new], [TestPage new]];
        Check(!ApolloDuoSplitPopRevealsContent(detailPane) && !ApolloDuoNativeBackPanOwns(detailPane),
              @"an empty detail's placeholder is not content");
        Check(Begins(owner), @"the pane swipe keeps the pop onto the placeholder");
        UINavigationController *accountPane = Navigation();
        ApolloDuoSplitState *accountDetail = [ApolloDuoSplitState new];
        accountDetail.split = [NSObject new]; accountDetail.host = [TestDuoHost new]; accountDetail.kind = @"account";
        accountDetail.root = [TestPage new]; accountDetail.secondary = accountPane; accountPane.duoState = accountDetail;
        accountPane.viewControllers = @[accountDetail.root, [TestPage new]];
        Check(!ApolloDuoSplitPopRevealsContent(accountPane) && !ApolloDuoNativeBackPanOwns(accountPane),
              @"Back to the Account Overview stays the split's own transition");
        accountPane.viewControllers = @[accountDetail.root, [TestPage new], [TestPage new]];
        Check(ApolloDuoNativeBackPanOwns(accountPane), @"a deeper Account page pops natively to the page below it");
        UINavigationController *ownProfile = Navigation();
        ownProfile.viewControllers = @[[UIViewController new]];
        ApolloDuoSplitState *ownAccount = [ApolloDuoSplitState new];
        ownAccount.split = [NSObject new]; ownAccount.host = [TestDuoHost new];
        ownAccount.kind = @"account"; ownAccount.tabKind = @"subreddits";
        ownAccount.profilePrefix = @[[UIViewController new]];
        ownAccount.secondary = ownProfile; ownAccount.root = ownProfile.viewControllers.firstObject;
        ownProfile.duoState = ownAccount;
        Check(ApolloDuoSplitCanReturnFromVisitedProfile(ownProfile) && !ApolloDuoNativeBackPanOwns(ownProfile),
              @"leaving a visited profile is not a native pop");

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
        Fling(owner);
        Check(profileReturns == 1 && profile.pops == 0, @"the swipe leaves the visited profile through its Back transition");
        Check(!ApolloDuoBackSwipeCanNavigate(profile), @"once left, the profile pane has nothing to go Back to");
        // The profile's left column (header and shortcuts) belongs to the
        // same visit, so a swipe there leaves the profile too.
        account.profilePrefix = @[[UIViewController new]];
        UINavigationController *header = Navigation();
        header.viewControllers = @[[UIViewController new]];
        header.duoState = account; account.primary = header;
        Check(ApolloDuoBackSwipeCanNavigate(header), @"the visited profile's left column can swipe Back out of the profile");
        ApolloDuoInstallBackSwipe(header); owner = objc_getAssociatedObject(header, &kApolloDuoBackSwipe);
        Fling(owner);
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
        Fling(owner);
        Check(drawerReveals == revealsBefore + 1 && thread.pops == 0 && feed2.pops == 0,
              @"Disable Left Swipes: a feed-root swipe opens the list and leaves the thread beside it open");
        posts.host.listVisible = NO;
        feed2.viewControllers = @[[UIViewController new], [UIViewController new]];
        Fling(owner);
        Check(!ApolloDuoNativeBackPanOwns(feed2) && feed2.pops == 1 && thread.pops == 0 && drawerReveals == revealsBefore + 1,
              @"Disable Left Swipes: a feed-pane swipe pops the feed's own page beside a thread, and the thread stays");
        thread.viewControllers = @[[UIViewController new], [UIViewController new], [UIViewController new]];
        ApolloDuoInstallBackSwipe(thread);
        ApolloDuoBackSwipe *threadOwner = objc_getAssociatedObject(thread, &kApolloDuoBackSwipe);
        Fling(threadOwner);
        Check(ApolloDuoNativeBackPanOwns(thread) && thread.pops == 0 && thread.viewControllers.count == 3,
              @"Disable Left Swipes: a page pushed over the thread is Apollo's own Back in the thread pane");
        thread.viewControllers = @[[UIViewController new], [UIViewController new]];
        Fling(threadOwner);
        Check(thread.pops == 1 && thread.viewControllers.count == 1 && feed2.pops == 1 && drawerReveals == revealsBefore + 1,
              @"Disable Left Swipes: a thread-pane swipe closes the thread itself");
        posts.host.postsShowingDetail = YES; thread.viewControllers = @[[UIViewController new], [UIViewController new]];
        feed2.viewControllers = @[[UIViewController new]];
        leftSwipesDisabled = NO;
        Fling(owner);
        Check(thread.pops == 1 && drawerReveals == revealsBefore + 2,
              @"with left swipes on, the feed edge keeps #1245's per-pane behavior (opens the list)");
        leftSwipesDisabled = NO;
        touch.view = cell;
        Check(![owner gestureRecognizer:owner.pan shouldReceiveTouch:touch], @"with left swipes on, interior touches stay with row actions");

        // One pan, one routing table: who owns this Back, and does it follow
        // the finger. The priority is the order the discrete swipe acted in.
        typedef ApolloDuoBackFacts Facts;
        ApolloDuoBackRouting route = ApolloDuoBackRoute((Facts){0});
        Check(route.owner == ApolloDuoBackOwnerNative, @"route: no split (folded, portrait) is Apollo's own Back");
        route = ApolloDuoBackRoute((Facts){.threadAboveBackstop = YES, .visitedProfile = YES, .root = YES});
        Check(route.owner == ApolloDuoBackOwnerNative, @"route: with no split nothing else matters");
        route = ApolloDuoBackRoute((Facts){.split = YES, .nativeOwns = YES, .root = YES});
        Check(route.owner == ApolloDuoBackOwnerNative, @"route: a pop onto a real page of the pane is native");
        route = ApolloDuoBackRoute((Facts){.split = YES, .threadAboveBackstop = YES});
        Check(route.owner == ApolloDuoBackOwnerThreadClose,
              @"route: a thread right above the backstop is the split's interactive close");
        route = ApolloDuoBackRoute((Facts){.split = YES, .visitedProfile = YES, .root = YES});
        Check(route.owner == ApolloDuoBackOwnerVisitedProfile,
              @"route: leaving a visited profile stays discrete, before the drawer");
        route = ApolloDuoBackRoute((Facts){.split = YES, .root = YES});
        Check(route.owner == ApolloDuoBackOwnerDrawer,
              @"route: the feed root pulls in the drawer");
        route = ApolloDuoBackRoute((Facts){.split = YES});
        Check(route.owner == ApolloDuoBackOwnerSplitPop,
              @"route: a pop onto the Overview or a placeholder stays the split's discrete pop");

        // The facts come from the real split policy.
        leftSwipesDisabled = NO;
        UINavigationController *routeFeed = Navigation(), *routeThread = Navigation();
        routeFeed.viewControllers = @[[UIViewController new]];
        UIViewController *routeBackstop = [UIViewController new];
        routeThread.viewControllers = @[routeBackstop, [TestPage new]];
        ApolloDuoSplitState *routePosts = [ApolloDuoSplitState new];
        routePosts.split = [NSObject new]; routePosts.host = [TestDuoHost new]; routePosts.host.postsShowingDetail = YES;
        routePosts.feed = routeFeed; routePosts.secondary = routeThread;
        routeFeed.duoState = routePosts; routeThread.duoState = routePosts;
        route = ApolloDuoBackRouteForNavigation(routeThread);
        Check(route.owner == ApolloDuoBackOwnerThreadClose,
              @"thread pane above the backstop routes to the thread close");
        routeThread.viewControllers = @[routeBackstop, [TestPage new], [TestPage new]];
        Check(ApolloDuoBackRouteForNavigation(routeThread).owner == ApolloDuoBackOwnerNative,
              @"a profile over the thread routes to the native pan");
        routeThread.viewControllers = @[routeBackstop, [TestPage new]];
        Check(ApolloDuoBackRouteForNavigation(routeFeed).owner == ApolloDuoBackOwnerDrawer,
              @"feed root beside a thread, swipe-anywhere off: the drawer, as #1245");
        leftSwipesDisabled = YES;
        Check(ApolloDuoBackRouteForNavigation(routeFeed).owner == ApolloDuoBackOwnerDrawer,
              @"feed root beside a thread, swipe-anywhere on: still the drawer; the thread is the thread pane's");
        routePosts.host.postsShowingDetail = NO;
        Check(ApolloDuoBackRouteForNavigation(routeFeed).owner == ApolloDuoBackOwnerDrawer,
              @"feed root with no thread beside: the drawer");
        routePosts.host.postsShowingDetail = YES; leftSwipesDisabled = NO;
        routePosts.split = nil;
        Check(ApolloDuoBackRouteForNavigation(routeThread).owner == ApolloDuoBackOwnerNative
              && ApolloDuoBackRouteForNavigation(routeFeed).owner == ApolloDuoBackOwnerNative,
              @"folded: every route is native");
        routePosts.split = [NSObject new];
        UINavigationController *routeDetail = Navigation();
        ApolloDuoSplitState *routeSettings = [ApolloDuoSplitState new];
        routeSettings.split = [NSObject new]; routeSettings.host = [TestDuoHost new]; routeSettings.kind = @"settings";
        routeSettings.secondary = routeDetail; routeDetail.duoState = routeSettings;
        routeDetail.viewControllers = @[[TestPage new], [TestPage new]];
        Check(ApolloDuoBackRouteForNavigation(routeDetail).owner == ApolloDuoBackOwnerNative,
              @"a deeper Settings page routes to the native pan");
        routeDetail.viewControllers = @[[UIViewController new], [TestPage new]];
        route = ApolloDuoBackRouteForNavigation(routeDetail);
        Check(route.owner == ApolloDuoBackOwnerSplitPop,
              @"a pop onto an empty detail's placeholder stays discrete");
        routeSettings.kind = @"account"; routeSettings.root = [TestPage new];
        routeDetail.viewControllers = @[routeSettings.root, [TestPage new]];
        route = ApolloDuoBackRouteForNavigation(routeDetail);
        Check(route.owner == ApolloDuoBackOwnerSplitPop,
              @"a pop onto the Account Overview stays discrete");
        routeDetail.viewControllers = @[[UIViewController new]];
        routeSettings.root = routeDetail.viewControllers.firstObject;
        routeSettings.tabKind = @"subreddits"; routeSettings.profilePrefix = @[[UIViewController new]];
        route = ApolloDuoBackRouteForNavigation(routeDetail);
        Check(route.owner == ApolloDuoBackOwnerVisitedProfile,
              @"a visited profile routes to its discrete Back");

        // Commit thresholds, as the iPad pane Back: a third of the pane, or a
        // flick that has moved at all.
        Check(ApolloDuoBackShouldCommit(0.35, 0) && ApolloDuoBackShouldCommit(1.0, 0), @"commit: past 0.35 of the pane");
        Check(!ApolloDuoBackShouldCommit(0.349, 0) && !ApolloDuoBackShouldCommit(0.34, 499), @"commit: a slow drag short of 0.35 springs back");
        Check(ApolloDuoBackShouldCommit(0.05, 500) && ApolloDuoBackShouldCommit(0.2, 1500), @"commit: a 500 pt/s flick past 0.05");
        Check(!ApolloDuoBackShouldCommit(0.049, 500) && !ApolloDuoBackShouldCommit(0, 3000), @"commit: a flick that has barely moved does not");
        Check(!ApolloDuoBackShouldCommit(0.05, 499.9) && !ApolloDuoBackShouldCommit(0.3, -900), @"commit: short of 0.35 the flick must be rightward and fast");
        Check(!ApolloDuoBackShouldCommit(0.5, -500) && !ApolloDuoBackShouldCommit(1.0, -2000),
              @"commit: a backward flick at 500 pt/s cancels at any progress, like a native pop");
        Check(ApolloDuoBackShouldCommit(0.5, -499.9) && ApolloDuoBackShouldCommit(0.35, -100),
              @"commit: a small backward jitter at lift past 0.35 still commits");

        // The pan begins only for a clearly rightward move.
        routeThread.viewControllers = @[routeBackstop, [TestPage new]];
        ApolloDuoInstallBackSwipe(routeThread);
        ApolloDuoBackSwipe *routeOwner = objc_getAssociatedObject(routeThread, &kApolloDuoBackSwipe);
        ApolloDuoPaneBackPan *paneBack = routeOwner.pan;
        // A rightward motion so far that is not clear on its own: the
        // velocity decides these.
        paneBack.translation = CGPointMake(10, 8);
        paneBack.velocity = CGPointMake(300, 40);
        Check([routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a clearly rightward move");
        paneBack.velocity = CGPointMake(300, 199);
        Check([routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: sideways by more than 1.5 to 1");
        paneBack.velocity = CGPointMake(300, 200);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a 1.5 to 1 diagonal is not clear enough");
        paneBack.velocity = CGPointMake(300, -250);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a diagonal upward move is scrolling");
        paneBack.velocity = CGPointMake(-300, 10);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a leftward move is a row action, not Back");
        paneBack.velocity = CGPointMake(20, 300);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a vertical move is scrolling");
        paneBack.velocity = CGPointZero;
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: no move, no Back");
        // Or the motion so far decides: the velocity at hysteresis can carry
        // a finger's first jitter (ApolloFeedGalleryCarousel.xm records it).
        paneBack.translation = CGPointMake(14, 2); paneBack.velocity = CGPointMake(300, 400);
        Check([routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a clean rightward motion survives a jittery velocity");
        paneBack.velocity = CGPointMake(-200, 10);
        Check([routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a clean rightward motion survives a backward jitter");
        paneBack.translation = CGPointMake(-14, 1); paneBack.velocity = CGPointMake(300, 10);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a leftward motion never begins Back, whatever the velocity");
        paneBack.translation = CGPointMake(5, 14);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a mostly vertical motion is a scroll, whatever the velocity");
        paneBack.translation = CGPointMake(0, 12);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a straight vertical motion is a scroll");
        paneBack.translation = CGPointMake(10, 8); paneBack.velocity = CGPointMake(300, 250);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: neither the motion nor the velocity is clear");
        // UIKit strips its hysteresis from the translation before this
        // callback, so the motion is measured from the first finger's touch-down.
        UITouch *firstFinger = [UITouch new]; firstFinger.point = CGPointMake(6, 300);
        [paneBack touchesBegan:[NSSet setWithObject:firstFinger] withEvent:[UIEvent new]];
        paneBack.translation = CGPointZero; paneBack.location = CGPointMake(20, 302);
        paneBack.velocity = CGPointMake(300, 400);
        Check([routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: the motion since touch-down counts even when the translation is empty");
        paneBack.location = CGPointMake(9, 316);
        paneBack.velocity = CGPointMake(300, 10);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: a vertical motion since touch-down is a scroll");
        [paneBack reset];
        paneBack.translation = CGPointMake(10, 8);
        routeThread.viewControllers = @[routeBackstop, [TestPage new], [TestPage new]];
        paneBack.velocity = CGPointMake(300, 40); paneBack.translation = CGPointMake(12, 1);
        Check(![routeOwner gestureRecognizerShouldBegin:paneBack], @"begin: never where the native pan owns the pop");
        routeThread.viewControllers = @[routeBackstop, [TestPage new]];

        // Once the pan begins, the table under the finger stops scrolling.
        UIScrollView *table = [UIScrollView new]; table.superview = routeThread.view; table.scrollEnabled = YES;
        table.panGestureRecognizer = [UIPanGestureRecognizer new]; table.panGestureRecognizer.view = table;
        UIScrollView *elsewhere = [UIScrollView new]; elsewhere.superview = routeThread.view;
        elsewhere.panGestureRecognizer = [UIPanGestureRecognizer new]; elsewhere.panGestureRecognizer.view = elsewhere;
        UIView *routeCell = [UIView new]; routeCell.superview = table;
        touch = [UITouch new]; touch.point = CGPointMake(6, 300); touch.view = routeCell;
        Check([routeOwner gestureRecognizer:paneBack shouldReceiveTouch:touch]
              && [routeOwner gestureRecognizer:paneBack shouldRecognizeSimultaneouslyWithGestureRecognizer:table.panGestureRecognizer],
              @"the pan takes the edge touch and runs alongside the table's scroll pan");
        [paneBack touchesBegan:[NSSet setWithObject:touch] withEvent:[UIEvent new]];
        UIView *secondCell = [UIView new]; secondCell.superview = elsewhere;
        UITouch *secondFinger = [UITouch new]; secondFinger.point = CGPointMake(400, 500); secondFinger.view = secondCell;
        [paneBack touchesBegan:[NSSet setWithObject:secondFinger] withEvent:[UIEvent new]];
        Check(paneBack.touchView == routeCell && CGPointEqualToPoint(paneBack.touchStart, CGPointMake(6, 300)),
              @"a second finger never replaces the first finger's touch-down");
        Check(table.panGestureRecognizer.disables == 0, @"no scroll pan is touched before the pan begins");
        NSUInteger routePops = routeThread.pops;
        Drag(routeOwner, 100, 200);
        Check(table.panGestureRecognizer.disables == 1 && table.panGestureRecognizer.enabled
              && elsewhere.panGestureRecognizer.disables == 0,
              @"the table's scroll pan under the first finger is cancelled once and re-enabled when the pan begins");
        Check(!paneBack.touchView, @"once the pan began, its touch-down view is let go");
        [paneBack reset];
        Check(!paneBack.touchView && !paneBack.tracksTouch, @"reset forgets the touch-down");
        [paneBack touchesBegan:[NSSet setWithObject:touch] withEvent:[UIEvent new]];
        Check(routeThread.pops == routePops && routeThread.viewControllers.count == 2,
              @"a slow drag short of the threshold does nothing");
        Drag(routeOwner, 1280 * 0.35, 0);
        Check(routeThread.pops == routePops + 1, @"a slow drag past a third of the pane closes the thread");
        [paneBack reset];
        Check(table.panGestureRecognizer.disables == 2 && table.panGestureRecognizer.enabled, @"each pan cancels the scroll once");

        // The route is decided again on release: a Back that changed owner
        // under the finger does nothing rather than act twice.
        routeThread.viewControllers = @[routeBackstop, [TestPage new]]; routePops = routeThread.pops;
        paneBack.velocity = CGPointMake(300, 40); paneBack.translation = CGPointZero;
        paneBack.state = UIGestureRecognizerStateBegan; [routeOwner panned:paneBack];
        routeThread.viewControllers = @[routeBackstop, [TestPage new], [TestPage new]];
        paneBack.translation = CGPointMake(600, 0); paneBack.velocity = CGPointMake(900, 0);
        paneBack.state = UIGestureRecognizerStateEnded; [routeOwner panned:paneBack];
        paneBack.state = UIGestureRecognizerStatePossible;
        Check(routeThread.pops == routePops, @"a route that became native mid-drag does not pop as well");
        routeThread.viewControllers = @[routeBackstop, [TestPage new]];
        paneBack.state = UIGestureRecognizerStateBegan; [routeOwner panned:paneBack];
        paneBack.translation = CGPointMake(600, 0);
        paneBack.state = UIGestureRecognizerStateCancelled; [routeOwner panned:paneBack];
        paneBack.state = UIGestureRecognizerStatePossible;
        Check(routeThread.pops == routePops, @"a cancelled pan does nothing");

        // The drawer, too, opens only past the threshold.
        routePosts.host.postsShowingDetail = NO; routePosts.host.listVisible = NO;
        routeFeed.pane = CGRectMake(0, 80, 640, 720);
        ApolloDuoInstallBackSwipe(routeFeed);
        ApolloDuoBackSwipe *drawerOwner = objc_getAssociatedObject(routeFeed, &kApolloDuoBackSwipe);
        NSUInteger routeReveals = drawerReveals;
        Drag(drawerOwner, 40, 300);
        Check(drawerReveals == routeReveals && !routePosts.host.listVisible, @"a slow drag at the feed root short of a third of its pane leaves the drawer closed");
        Drag(drawerOwner, 60, 700);
        Check(drawerReveals == routeReveals + 1 && routeFeed.pops == 0, @"a flick at the feed root opens the drawer once");
        // A feed-root Back beside a thread is the drawer, and stays the drawer
        // when the thread closes some other way during the drag.
        leftSwipesDisabled = YES; routePosts.host.listVisible = NO; routePosts.host.postsShowingDetail = YES;
        routeThread.viewControllers = @[routeBackstop, [TestPage new]]; routePops = routeThread.pops;
        routeReveals = drawerReveals;
        ApolloDuoPaneBackPan *feedBack = drawerOwner.pan;
        feedBack.velocity = CGPointMake(300, 40); feedBack.translation = CGPointZero;
        feedBack.state = UIGestureRecognizerStateBegan; [drawerOwner panned:feedBack];
        Check(drawerOwner.route.owner == ApolloDuoBackOwnerDrawer, @"the feed-pane pan beside a thread began as the drawer");
        routePosts.host.postsShowingDetail = NO;
        feedBack.translation = CGPointMake(400, 0); feedBack.velocity = CGPointMake(900, 0);
        feedBack.state = UIGestureRecognizerStateEnded; [drawerOwner panned:feedBack];
        feedBack.state = UIGestureRecognizerStatePossible;
        Check(drawerReveals == routeReveals + 1 && routeThread.pops == routePops,
              @"the thread closing under the finger leaves the feed's route alone: the drawer opens, the thread is untouched");
        leftSwipesDisabled = NO;
        // Carousels make ancestor pans wait for their own pan; they exempt the
        // pane Back, which already decides between carousel and Back itself.
        Check(ApolloDuoIsPaneBackPan(routeOwner.pan) && ApolloDuoIsPaneBackPan(drawerOwner.pan),
              @"the pane Back pan is recognized for the carousel exemption");
        UIPanGestureRecognizer *impostor = [UIPanGestureRecognizer new]; impostor.name = @"ApolloReborn.Duo.PaneBack";
        Check(!ApolloDuoIsPaneBackPan(routeOwner.highlightGuard) && !ApolloDuoIsPaneBackPan(row)
              && !ApolloDuoIsPaneBackPan(impostor) && !ApolloDuoIsPaneBackPan(nil),
              @"the highlight guard, row pans and unowned pans keep waiting for carousels");

        // Nested pane Backs (a visited profile's outer navigation and its
        // columns) exclude each other instead of waiting on each other.
        Check(![routeOwner gestureRecognizer:routeOwner.pan shouldBeRequiredToFailByGestureRecognizer:drawerOwner.pan]
              && ![drawerOwner gestureRecognizer:drawerOwner.pan shouldBeRequiredToFailByGestureRecognizer:routeOwner.pan],
              @"two pane Backs never wait on each other");
        Check(![routeOwner gestureRecognizer:routeOwner.pan shouldBeRequiredToFailByGestureRecognizer:drawerOwner.highlightGuard],
              @"another pane's highlight guard does not wait for this pane's Back");
        Check(![routeOwner gestureRecognizer:routeOwner.pan shouldRecognizeSimultaneouslyWithGestureRecognizer:drawerOwner.pan]
              && ![drawerOwner gestureRecognizer:drawerOwner.pan shouldRecognizeSimultaneouslyWithGestureRecognizer:routeOwner.pan],
              @"two pane Backs stay exclusive: only one begins");
        Check([routeOwner gestureRecognizer:routeOwner.pan shouldBeRequiredToFailByGestureRecognizer:row],
              @"row actions still wait for the pane Back");

        // Apollo's own Back and Forward commit a held release at half their
        // view's width. A split pane's view extends under the sidebar or the
        // feed column, so that release is judged against the visible pane.
        Check(ApolloDuoSplitNativePanReleaseScale(951, 951) == 1.0, @"release scale: a pane as wide as its view leaves the release alone");
        Check(ApolloDuoSplitNativePanReleaseScale(951, 1200) == 1.0, @"release scale: a pane wider than its view leaves the release alone");
        Check(ApolloDuoSplitNativePanReleaseScale(951, 0) == 1.0 && ApolloDuoSplitNativePanReleaseScale(951, -40) == 1.0
              && ApolloDuoSplitNativePanReleaseScale(951, NAN) == 1.0, @"release scale: a missing or empty pane leaves the release alone");
        Check(ApolloDuoSplitNativePanReleaseScale(0, 400) == 1.0 && ApolloDuoSplitNativePanReleaseScale(-951, 400) == 1.0
              && ApolloDuoSplitNativePanReleaseScale(NAN, 400) == 1.0, @"release scale: a view with no width leaves the release alone");
        Check(fabs(ApolloDuoSplitNativePanReleaseScale(951, 634) - 951.0 / 634.0) < 1e-9, @"release scale: Settings detail is view over pane");
        Check(fabs(ApolloDuoSplitNativePanReleaseScale(951, 476) - 951.0 / 476.0) < 1e-9, @"release scale: Posts thread pane is view over pane");

        // Settings: the detail view spans the 317 pt sidebar; its pane is 634 pt.
        ApolloDuoSplitState *settingsSplit = [ApolloDuoSplitState new];
        settingsSplit.split = [NSObject new]; settingsSplit.host = [TestDuoHost new]; settingsSplit.kind = @"settings";
        const CGFloat settingsPane = 634;
        UINavigationController *settingsDetail = NativePanNavigation(settingsSplit, CGRectMake(317, 0, settingsPane, 669));
        settingsSplit.secondary = settingsDetail;
        UIPanGestureRecognizer *settingsBack = settingsDetail->leftScreenEdgePanGestureRecognizer;
        UIPanGestureRecognizer *settingsForward = settingsDetail->rightScreenEdgePanGestureRecognizer;
        UIPanGestureRecognizer *settingsBarPan = settingsDetail->navigationBarPanGestureRecognizer;
        Check(!ApolloNativeReleaseFinishes(YES, 0, 0.70 * settingsPane, 951),
              @"Apollo's own rule springs a held release at 70% of the Settings pane back (the simulator repro)");
        Check(NativeReleaseFinishes(settingsDetail, settingsBack, YES, 0, 0.70 * settingsPane),
              @"Settings: a held Back released at 70% of the pane completes");
        Check(NativeReleaseFinishes(settingsDetail, settingsBack, YES, 0, 0.55 * settingsPane),
              @"Settings: a held Back released at 55% of the pane completes");
        Check(!NativeReleaseFinishes(settingsDetail, settingsBack, YES, 0, 0.45 * settingsPane),
              @"Settings: a held Back released at 45% of the pane springs back");
        Check(NativeReleaseFinishes(settingsDetail, settingsForward, NO, 0, -0.55 * settingsPane)
              && !NativeReleaseFinishes(settingsDetail, settingsForward, NO, 0, -0.45 * settingsPane),
              @"Settings: Forward is judged against the pane too, mirrored");
        Check(NativeReleaseFinishes(settingsDetail, settingsBack, YES, 300, 20)
              && NativeReleaseFinishes(settingsDetail, settingsForward, NO, -300, -20),
              @"Settings: a flick of 100 pt/s or more still completes at any translation");
        Check(NativeReleaseFinishes(settingsDetail, settingsBarPan, YES, 0, 0.55 * settingsPane)
              && !NativeReleaseFinishes(settingsDetail, settingsBarPan, YES, 0, 0.45 * settingsPane)
              && NativeReleaseFinishes(settingsDetail, settingsBarPan, NO, 0, -0.55 * settingsPane),
              @"Settings: Apollo's navigation-bar pan, which runs the same handler, is judged against the pane");

        // Posts thread pane: the secondary view spans the 475 pt feed column.
        ApolloDuoSplitState *postsSplit = [ApolloDuoSplitState new];
        postsSplit.split = [NSObject new]; postsSplit.host = [TestDuoHost new]; postsSplit.host.postsShowingDetail = YES;
        const CGFloat threadPane = 476;
        UINavigationController *threadPaneNav = NativePanNavigation(postsSplit, CGRectMake(475, 0, threadPane, 669));
        UINavigationController *postsFeed = NativePanNavigation(postsSplit, CGRectMake(0, 0, 951, 669));
        postsSplit.secondary = threadPaneNav; postsSplit.feed = postsFeed;
        Check(!ApolloNativeReleaseFinishes(YES, 0, 0.95 * threadPane, 951),
              @"Apollo's own rule cannot complete a held release anywhere in the thread pane");
        Check(NativeReleaseFinishes(threadPaneNav, threadPaneNav->leftScreenEdgePanGestureRecognizer, YES, 0, 300),
              @"Posts thread pane: a held Back released at 300 pt completes");
        Check(!NativeReleaseFinishes(threadPaneNav, threadPaneNav->leftScreenEdgePanGestureRecognizer, YES, 0, 0.45 * threadPane),
              @"Posts thread pane: a held Back short of half the pane springs back");
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(threadPaneNav, nil) == 1.0,
              @"no gesture is never mistaken for an unset Apollo pan");
        postsSplit.host.postsShowingDetail = NO;
        postsFeed->leftScreenEdgePanGestureRecognizer.state = UIGestureRecognizerStateEnded;
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(postsFeed, postsFeed->leftScreenEdgePanGestureRecognizer) == 1.0,
              @"Posts feed pane as wide as its view: unchanged");
        postsFeed.pane = CGRectMake(40, 0, 911, 669);
        Check(fabs(ApolloDuoSplitNativePanReleaseScaleForNavigation(postsFeed, postsFeed->leftScreenEdgePanGestureRecognizer) - 951.0 / 911.0) < 1e-9,
              @"Posts feed pane narrower than its view: judged against the pane");

        // Folded, or with no split, every release is Apollo's own.
        UINavigationController *foldedNav = NativePanNavigation(nil, CGRectNull);
        foldedNav.view.bounds = CGRectMake(0, 0, 466, 678);
        BOOL foldedStock = YES;
        for (CGFloat tx = -466; tx <= 466; tx += 1) {
            for (int v = -2; v <= 2; v++) {
                CGFloat vx = v * 75.0;
                foldedStock = foldedStock
                    && NativeReleaseFinishes(foldedNav, foldedNav->leftScreenEdgePanGestureRecognizer, YES, vx, tx) == ApolloNativeReleaseFinishes(YES, vx, tx, 466)
                    && NativeReleaseFinishes(foldedNav, foldedNav->rightScreenEdgePanGestureRecognizer, NO, vx, tx) == ApolloNativeReleaseFinishes(NO, vx, tx, 466);
            }
        }
        Check(foldedStock, @"folded: Back and Forward releases are exactly Apollo's own");

        // Only a release of Apollo's own pans on a visible pane is scaled.
        const CGFloat settingsScale = 951.0 / settingsPane;
        settingsBack.state = UIGestureRecognizerStateEnded;
        Check(fabs(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, settingsBack) - settingsScale) < 1e-9,
              @"gating: an ended Back in the detail pane is scaled");
        settingsBack.state = UIGestureRecognizerStateCancelled;
        Check(fabs(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, settingsBack) - settingsScale) < 1e-9,
              @"gating: a cancelled Back is a release too (Apollo cancels it without reading the translation)");
        settingsBack.state = UIGestureRecognizerStateBegan;
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, settingsBack) == 1.0,
              @"gating: the pan's beginning is unscaled");
        settingsBack.state = UIGestureRecognizerStateChanged;
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, settingsBack) == 1.0,
              @"gating: dragging is unscaled, so the page tracks the finger 1:1");
        settingsBack.state = UIGestureRecognizerStateEnded;
        UIPanGestureRecognizer *unrelatedPan = [UIPanGestureRecognizer new]; unrelatedPan.state = UIGestureRecognizerStateEnded;
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, unrelatedPan) == 1.0,
              @"gating: a pan that is not one of Apollo's navigation pans is unscaled");
        UINavigationController *settingsSidebar = NativePanNavigation(settingsSplit, CGRectMake(0, 0, 317, 669));
        settingsSplit.primary = settingsSidebar;
        settingsSidebar->leftScreenEdgePanGestureRecognizer.state = UIGestureRecognizerStateEnded;
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsSidebar, settingsSidebar->leftScreenEdgePanGestureRecognizer) == 1.0,
              @"gating: the sidebar is not a visible content pane and is unscaled");
        resizing = YES;
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, settingsBack) == 1.0,
              @"gating: a fold or rotation in progress is unscaled");
        resizing = NO; settingsSplit.changing = YES;
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, settingsBack) == 1.0,
              @"gating: a split being rebuilt is unscaled");
        settingsSplit.changing = NO; NSObject *settingsSplitView = settingsSplit.split; settingsSplit.split = nil;
        Check(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, settingsBack) == 1.0,
              @"gating: no split is unscaled");
        settingsSplit.split = settingsSplitView;
        Check(fabs(ApolloDuoSplitNativePanReleaseScaleForNavigation(settingsDetail, settingsBack) - settingsScale) < 1e-9,
              @"gating: the restored split scales again");

        // The release window: Apollo's handler reads the scaled translation of
        // its own pan in its own view, and nothing else, and only while it runs.
        settingsBack.state = UIGestureRecognizerStateEnded; settingsBack.translation = CGPointMake(200, 7);
        settingsForward.translation = CGPointMake(-200, 3);
        UIView *otherView = [UIView new];
        __block CGPoint scaledInside = CGPointZero, otherPanInside = CGPointZero, otherViewInside = CGPointZero;
        ApolloDuoSplitNativePanReleaseRun(settingsDetail, settingsBack, ^{
            scaledInside = [settingsBack translationInView:settingsDetail.view];
            otherPanInside = [settingsForward translationInView:settingsDetail.view];
            otherViewInside = [settingsBack translationInView:otherView];
        });
        Check(fabs(scaledInside.x - 200 * settingsScale) < 1e-9 && scaledInside.y == 7,
              @"release window: the handler reads its pan's translation in its view scaled, x only");
        Check(otherPanInside.x == -200 && otherViewInside.x == 200,
              @"release window: another pan, or the same pan in another view, reads unscaled");
        Check(sDuoSplitReleaseGesture == NULL && sDuoSplitReleaseView == NULL && sDuoSplitReleaseScale == 1.0
              && [settingsBack translationInView:settingsDetail.view].x == 200,
              @"release window: closed once the handler returns, so the pan reads unscaled again");
        settingsBack.state = UIGestureRecognizerStateChanged;
        __block BOOL openWhileDragging = YES;
        __block CGFloat dragInside = 0;
        ApolloDuoSplitNativePanReleaseRun(settingsDetail, settingsBack, ^{
            openWhileDragging = sDuoSplitReleaseGesture != NULL || sDuoSplitReleaseView != NULL;
            dragInside = [settingsBack translationInView:settingsDetail.view].x;
        });
        Check(!openWhileDragging && dragInside == 200, @"release window: never opened for a scale of 1 (dragging)");
        // A nested release restores the outer one's window instead of closing it.
        settingsBack.state = UIGestureRecognizerStateEnded;
        UIPanGestureRecognizer *threadPaneBack = threadPaneNav->leftScreenEdgePanGestureRecognizer;
        threadPaneBack.state = UIGestureRecognizerStateEnded; threadPaneBack.translation = CGPointMake(100, 0);
        postsSplit.host.postsShowingDetail = YES;
        __block CGFloat outerBefore = 0, innerInside = 0, outerDuringInner = 0, outerAfter = 0;
        ApolloDuoSplitNativePanReleaseRun(settingsDetail, settingsBack, ^{
            outerBefore = [settingsBack translationInView:settingsDetail.view].x;
            ApolloDuoSplitNativePanReleaseRun(threadPaneNav, threadPaneBack, ^{
                innerInside = [threadPaneBack translationInView:threadPaneNav.view].x;
                outerDuringInner = [settingsBack translationInView:settingsDetail.view].x;
            });
            outerAfter = [settingsBack translationInView:settingsDetail.view].x;
        });
        Check(fabs(innerInside - 100 * 951.0 / threadPane) < 1e-9 && outerDuringInner == 200,
              @"nested release: the inner pan is scaled by its own pane while it runs");
        Check(fabs(outerBefore - 200 * settingsScale) < 1e-9 && fabs(outerAfter - 200 * settingsScale) < 1e-9,
              @"nested release: the outer pan is scaled again once the inner one returns");
        Check(sDuoSplitReleaseGesture == NULL && sDuoSplitReleaseView == NULL && sDuoSplitReleaseScale == 1.0,
              @"nested release: both windows closed afterwards");
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
