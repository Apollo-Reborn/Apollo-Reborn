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
@property(nonatomic) NSUInteger superMoves, targetCount;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)addTarget:(id)target action:(SEL)action;
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)reset;
@end
@implementation UIGestureRecognizer
- (instancetype)initWithTarget:(__unused id)target action:(__unused SEL)action { return [super init]; }
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
@property(nonatomic) CGPoint velocity;
- (CGPoint)velocityInView:(UIView *)view;
@end
@implementation UIPanGestureRecognizer
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
    // Apollo's own Back pan, read through the runtime like the Swift ivar.
    UIPanGestureRecognizer *leftScreenEdgePanGestureRecognizer;
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
static CGRect ApolloDuoSplitContentFrame(UINavigationController *nav, __unused UIView *view) { return nav.pane; }
static BOOL UIAccessibilityIsReduceMotionEnabled(void) { return reduceMotion; }
typedef NSInteger UIGestureRecognizerState;
enum { UISwipeGestureRecognizerDirectionRight = 1, UIGestureRecognizerStatePossible = 0,
       UIGestureRecognizerStateBegan = 1, UIGestureRecognizerStateChanged = 2, UIGestureRecognizerStateEnded = 3,
       UIGestureRecognizerStateCancelled = 4, UIGestureRecognizerStateRecognized = 3, UIGestureRecognizerStateFailed = 5 };
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
        Check(ApolloDuoHasBackSwipe(nav) && nav.view.gestureRecognizers.count == 2, @"recognizer installation is idempotent (swipe + highlight guard)");
        ApolloDuoBackSwipe *owner = objc_getAssociatedObject(nav, &kApolloDuoBackSwipe);
        Check(owner.swipe.direction == UISwipeGestureRecognizerDirectionRight && owner.swipe.numberOfTouchesRequired == 1,
              @"Back uses a one-finger right swipe");
        UITouch *touch = [UITouch new]; touch.point = CGPointMake(5, 300);
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"real delegate accepts the content-edge touch");
        touch.point = CGPointMake(200, 300);
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"real delegate rejects interior touches");
        UIScrollView *scroll = [UIScrollView new]; scroll.panGestureRecognizer = [UIPanGestureRecognizer new];
        scroll.panGestureRecognizer.view = scroll;
        Check([owner gestureRecognizer:owner.swipe shouldRecognizeSimultaneouslyWithGestureRecognizer:scroll.panGestureRecognizer],
              @"table scrolling does not wait for the swipe");
        UIPanGestureRecognizer *row = [UIPanGestureRecognizer new];
        Check(![owner gestureRecognizer:owner.swipe shouldRecognizeSimultaneouslyWithGestureRecognizer:row],
              @"a row action cannot fire alongside Back");
        Check([owner gestureRecognizer:owner.swipe shouldBeRequiredToFailByGestureRecognizer:row]
              && ![owner gestureRecognizer:owner.swipe shouldBeRequiredToFailByGestureRecognizer:scroll.panGestureRecognizer],
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
              && [owner gestureRecognizer:owner.swipe shouldRecognizeSimultaneouslyWithGestureRecognizer:guard],
              @"highlight guard recognizes simultaneously with anything");
        Check(![owner gestureRecognizer:owner.swipe shouldBeRequiredToFailByGestureRecognizer:guard],
              @"the swipe never waits for the highlight guard");
        // Folded, the native pan owns every pop; the swipe acts for a thread
        // right above the Posts backstop.
        ApolloDuoSplitState *threadSplit = [ApolloDuoSplitState new];
        threadSplit.split = [NSObject new]; threadSplit.host = [TestDuoHost new]; threadSplit.host.postsShowingDetail = YES;
        UINavigationController *threadFeed = Navigation();
        threadSplit.feed = threadFeed; threadSplit.secondary = nav; nav.duoState = threadSplit; threadFeed.duoState = threadSplit;
        owner.swipe.state = UIGestureRecognizerStateRecognized;
        [owner swiped:owner.swipe]; [owner swiped:owner.swipe];
        Check(nav.pops == 1 && nav.viewControllers.count == 1 && nav.lastAnimated,
              @"recognized swipe performs one native animated Back and stops at root");
        Check(![owner gestureRecognizerShouldBegin:owner.swipe], @"root page has no Back gesture");
        nav.duoState = nil;
        nav = Navigation(); reduceMotion = YES; nav.duoState = threadSplit; threadSplit.secondary = nav;
        ApolloDuoInstallBackSwipe(nav); owner = objc_getAssociatedObject(nav, &kApolloDuoBackSwipe);
        owner.swipe.state = UIGestureRecognizerStateRecognized; [owner swiped:owner.swipe];
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
        owner.swipe.state = UIGestureRecognizerStateRecognized;
        [owner swiped:owner.swipe]; [owner swiped:owner.swipe];
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
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"Disable Left Swipes: the real delegate accepts an interior touch on a row");
        UIScrollView *gallery = [UIScrollView new]; gallery.superview = cell; gallery.scrollEnabled = YES;
        gallery.bounds = CGRectMake(0, 0, 400, 300); gallery.contentSize = CGSizeMake(1200, 300);
        UIView *page = [UIView new]; page.superview = gallery; touch.view = page;
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"a gallery on its first page has nothing to page back to");
        gallery.contentOffset = CGPointMake(400, 0);
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"a gallery that can page back keeps its own swipe");
        touch.point = CGPointMake(10, 300);
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"the edge strip still goes Back over a gallery, as without the setting");
        touch.point = CGPointMake(600, 300);
        gallery.scrollEnabled = NO;
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"a scroll view that cannot scroll does not block Back");
        UISlider *slider = [UISlider new]; slider.superview = cell; touch.view = slider;
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"a slider keeps its drag");

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
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch]
              && ![owner gestureRecognizer:owner.highlightGuard shouldReceiveTouch:touch],
              @"root reveal: a carousel at its leading end keeps the swipe");
        highlights.contentOffset = CGPointMake(600, 0);
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"root reveal: a scrolled carousel keeps the swipe");
        highlights.contentOffset = CGPointZero; touch.point = CGPointMake(10, 300);
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"root reveal: the edge strip still opens the list over a carousel");
        touch.point = CGPointMake(300, 300);
        highlights.contentSize = CGSizeMake(500, 200); highlights.alwaysBounceHorizontal = YES;
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch],
              @"root reveal: a carousel whose cards fit still keeps the swipe when it bounces sideways");
        highlights.alwaysBounceHorizontal = NO;
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch],
              @"root reveal: a horizontal scroll view that fits and does not bounce lets the list open");
        highlights.alwaysBounceHorizontal = YES; highlights.scrollEnabled = NO;
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch],
              @"root reveal: a scroll view with scrolling disabled lets the list open");
        highlights.scrollEnabled = YES; highlights.alwaysBounceHorizontal = NO;
        highlights.contentSize = CGSizeMake(1800, 200); touch.point = CGPointMake(10, 300);
        touch.point = CGPointMake(300, 300); touch.view = feedHeader;
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"root reveal: the rest of the feed still opens the list");
        touch.view = card; rootSplit.host.postsShowingDetail = YES;
        rootThread.viewControllers = @[[UIViewController new], [UIViewController new]];
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch],
              @"root reveal: a thread open beside the feed changes nothing, the carousel keeps the swipe");
        rootSplit.host.postsShowingDetail = NO; rootThread.viewControllers = @[[UIViewController new]];
        root.viewControllers = @[[UIViewController new], [UIViewController new]];
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"a pushed page with a carousel at its first item still goes Back");
        highlights.contentSize = CGSizeMake(500, 200); highlights.alwaysBounceHorizontal = YES;
        Check([owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch],
              @"a pushed page still goes Back over a bouncing carousel whose cards fit");
        highlights.contentSize = CGSizeMake(1800, 200); highlights.alwaysBounceHorizontal = NO;
        highlights.contentOffset = CGPointMake(600, 0);
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"a pushed page with a carousel mid-way keeps it scrolling");

        // Apollo's own interactive Back (its left edge pan) follows the
        // finger. It owns every pop onto a real page of the same pane, with or
        // without Disable Left Swipes, and the discrete pane swipe stands down.
        leftSwipesDisabled = NO;
        nav = Navigation();
        Check(ApolloDuoSplitPopRevealsContent(nav) && ApolloDuoNativeBackPanOwns(nav),
              @"folded / no split: the native pan owns every pop, as on a regular iPhone");
        ApolloDuoInstallBackSwipe(nav); owner = objc_getAssociatedObject(nav, &kApolloDuoBackSwipe);
        Check(ApolloDuoBackSwipeCanNavigate(nav) && ![owner gestureRecognizerShouldBegin:owner.swipe],
              @"no split: the pane swipe stands down for the native pan");
        owner.highlightGuard.velocity = CGPointMake(300, 40);
        Check([owner gestureRecognizerShouldBegin:owner.highlightGuard], @"the highlight guard still begins so the row drops its highlight");
        UIPanGestureRecognizer *nativeBack = [UIPanGestureRecognizer new];
        Check(!ApolloDuoNativeBackPan(nav), @"no Apollo Back pan yet: nothing is read");
        nav->leftScreenEdgePanGestureRecognizer = nativeBack;
        Check(ApolloDuoNativeBackPan(nav) == nativeBack, @"Apollo's Back pan is read from its ivar");
        Check(![owner gestureRecognizer:owner.swipe shouldBeRequiredToFailByGestureRecognizer:nativeBack],
              @"Apollo's Back pan does not wait for a pane swipe that stood down: it follows the finger from the first point");
        Check([owner gestureRecognizer:owner.swipe shouldBeRequiredToFailByGestureRecognizer:row],
              @"row actions still wait for the edge strip's Back");
        leftSwipesDisabled = YES;
        Check(ApolloDuoNativeBackPanOwns(nav) && ![owner gestureRecognizerShouldBegin:owner.swipe],
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
        Check([owner gestureRecognizerShouldBegin:owner.swipe], @"the pane swipe closes that thread");
        Check([owner gestureRecognizer:owner.swipe shouldBeRequiredToFailByGestureRecognizer:nativeBack],
              @"where the pane swipe owns Back, Apollo's pan keeps waiting for it");
        ownThread.viewControllers = @[backstop, [TestPage new], [TestPage new]];
        Check(ApolloDuoSplitPopRevealsContent(ownThread) && ApolloDuoNativeBackPanOwns(ownThread),
              @"a profile pushed over a thread: the native pan owns the pop back to the thread");
        Check(![owner gestureRecognizerShouldBegin:owner.swipe], @"the pane swipe stands down for that pop");
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
        Check(![owner gestureRecognizerShouldBegin:owner.swipe], @"the pane swipe cannot begin under a native drag");
        owner.swipe.state = UIGestureRecognizerStateRecognized;
        NSUInteger threadPops = ownThread.pops;
        [owner swiped:owner.swipe];
        Check(ownThread.pops == threadPops && ownThread.viewControllers.count == 2,
              @"a pane swipe acting mid-drag does not close the thread too");
        threadBack.state = UIGestureRecognizerStateChanged; [owner nativeBackChanged:threadBack];
        threadBack.state = UIGestureRecognizerStateEnded; [owner nativeBackChanged:threadBack];
        threadBack.state = UIGestureRecognizerStatePossible;
        Check(ApolloDuoNativeBackInFlight(ownThread), @"after release the pop is still settling");
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:kApolloDuoNativeBackSettleDelay * 1.5]];
        Check(!ApolloDuoNativeBackInFlight(ownThread) && [owner gestureRecognizerShouldBegin:owner.swipe],
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
        Check(![owner gestureRecognizerShouldBegin:owner.swipe], @"the pane swipe stands down for a deeper Settings page");
        detailPane.viewControllers = @[[TestPage new]];
        Check(!ApolloDuoNativeBackPanOwns(detailPane), @"a sidebar detail root: nothing to pop");
        detailPane.viewControllers = @[[UIViewController new], [TestPage new]];
        Check(!ApolloDuoSplitPopRevealsContent(detailPane) && !ApolloDuoNativeBackPanOwns(detailPane),
              @"an empty detail's placeholder is not content");
        Check([owner gestureRecognizerShouldBegin:owner.swipe], @"the pane swipe keeps the pop onto the placeholder");
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
        owner.swipe.state = UIGestureRecognizerStateRecognized; [owner swiped:owner.swipe];
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
        owner.swipe.state = UIGestureRecognizerStateRecognized; [owner swiped:owner.swipe];
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
        owner.swipe.state = UIGestureRecognizerStateRecognized;
        NSUInteger revealsBefore = drawerReveals;
        leftSwipesDisabled = YES;
        [owner swiped:owner.swipe];
        Check(drawerReveals == revealsBefore + 1 && thread.pops == 0 && feed2.pops == 0,
              @"Disable Left Swipes: a feed-root swipe opens the list and leaves the thread beside it open");
        posts.host.listVisible = NO;
        feed2.viewControllers = @[[UIViewController new], [UIViewController new]];
        [owner swiped:owner.swipe];
        Check(!ApolloDuoNativeBackPanOwns(feed2) && feed2.pops == 1 && thread.pops == 0 && drawerReveals == revealsBefore + 1,
              @"Disable Left Swipes: a feed-pane swipe pops the feed's own page beside a thread, and the thread stays");
        thread.viewControllers = @[[UIViewController new], [UIViewController new], [UIViewController new]];
        ApolloDuoInstallBackSwipe(thread);
        ApolloDuoBackSwipe *threadOwner = objc_getAssociatedObject(thread, &kApolloDuoBackSwipe);
        threadOwner.swipe.state = UIGestureRecognizerStateRecognized;
        [threadOwner swiped:threadOwner.swipe];
        Check(ApolloDuoNativeBackPanOwns(thread) && thread.pops == 0 && thread.viewControllers.count == 3,
              @"Disable Left Swipes: a page pushed over the thread is Apollo's own Back in the thread pane");
        thread.viewControllers = @[[UIViewController new], [UIViewController new]];
        [threadOwner swiped:threadOwner.swipe];
        Check(thread.pops == 1 && thread.viewControllers.count == 1 && feed2.pops == 1 && drawerReveals == revealsBefore + 1,
              @"Disable Left Swipes: a thread-pane swipe closes the thread itself");
        posts.host.postsShowingDetail = YES; thread.viewControllers = @[[UIViewController new], [UIViewController new]];
        feed2.viewControllers = @[[UIViewController new]];
        leftSwipesDisabled = NO;
        [owner swiped:owner.swipe];
        Check(thread.pops == 1 && drawerReveals == revealsBefore + 2,
              @"with left swipes on, the feed edge keeps #1245's per-pane behavior (opens the list)");
        leftSwipesDisabled = NO;
        touch.view = cell;
        Check(![owner gestureRecognizer:owner.swipe shouldReceiveTouch:touch], @"with left swipes on, interior touches stay with row actions");
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
