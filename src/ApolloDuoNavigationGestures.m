#import "ApolloDuoNavigationGestures.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

// Apollo's pans use the whole navigation surface for edge checks. On Duo a
// visible pane can start well inside that surface, and the outer stack is a
// containment host. Qualify a rightward pan at the *pane's* left content edge,
// then perform one native animated Back on that exact navigation controller.
// At the feed root the same gesture reveals the subreddit drawer. Calling the
// native pop entry point keeps the author's feed/thread restoration animation.
// Keep row swipe actions elsewhere, and honor Apollo's navigation-gesture opt-out.
// The same pan, leftward from the pane's trailing edge, is the forward swipe:
// it brings back the thread a Back closed beside the Posts feed.

// Shared by every Duo pane gesture: Apollo's navigation-gesture opt-out, and
// nothing while the panes resize, navigate or sit behind a sheet.
static BOOL ApolloDuoPaneGestureAllowed(UINavigationController *navigation) {
    BOOL eligible = ApolloDeviceIsDuo() && navigation.viewIfLoaded.window
        && ![NSUserDefaults.standardUserDefaults boolForKey:@"DisableNavigationGestures"]
        && !ApolloDuoSplitIsResizing() && !navigation.transitionCoordinator
        && !navigation.presentedViewController && !navigation.topViewController.presentedViewController
        && !navigation.isBeingDismissed;
    if (!eligible) return NO;
    // Sheets can belong to the containing split, tab, or outer navigation
    // controller rather than the pane itself. Never navigate behind one.
    for (UIViewController *parent = navigation.parentViewController; parent; parent = parent.parentViewController) {
        if (parent.presentedViewController || parent.isBeingDismissed || parent.transitionCoordinator) return NO;
    }
    return YES;
}

static BOOL ApolloDuoBackSwipeCanNavigate(UINavigationController *navigation) {
    // A visited profile is a visit of the whole account split, header column
    // included: from either column, Back leaves the profile.
    BOOL pane = (navigation.viewControllers.count > 1 || ApolloDuoSplitCanRevealPostsListWithSwipe(navigation))
        && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && ApolloDuoSplitDetailNavigation(navigation) == navigation;
    return (pane || ApolloDuoSplitCanReturnFromVisitedProfile(navigation)) && ApolloDuoPaneGestureAllowed(navigation);
}

// Gestures > Disable Left Swipes turns off the row actions a right swipe would
// trigger, and Apollo's own Back pan then starts anywhere on the page. Give a
// Duo pane the same reach; with the setting off only the edge strip qualifies.
// Either way a swipe acts on the pane it starts in: the feed's own Back while
// a thread stays open beside it, the thread's Back from the thread.
static BOOL ApolloDuoBackSwipeStartsAnywhere(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"DisableLeftSwipeGestureActions"];
}

// Apollo's own interactive Back: its left edge pan, a Swift ivar. UIKit's
// interactivePopGestureRecognizer never runs on Apollo's stacks.
UIGestureRecognizer *ApolloDuoNativeBackPan(UINavigationController *navigation) {
    Ivar ivar = navigation ? class_getInstanceVariable(navigation.class, "leftScreenEdgePanGestureRecognizer") : NULL;
    id pan = ivar ? object_getIvar(navigation, ivar) : nil;
    return [pan isKindOfClass:UIGestureRecognizer.class] ? pan : nil;
}

// Apollo's own Back pan follows the finger. Let it own every pop onto a real
// page of the same pane, and every pop with no split (folded, portrait), with
// or without Disable Left Swipes; the discrete pane swipe stands down for it.
// The pane swipe keeps what that pan can't do: closing the thread right above
// the Posts backstop (a column change, not a page pop), leaving a visited
// profile, revealing the drawer at the feed root, and the pops onto a page
// only the split lays out, or beside a thread (ApolloDuoSplitPopRevealsContent).
BOOL ApolloDuoNativeBackPanOwns(UINavigationController *navigation) {
    return navigation.viewControllers.count > 1 && !ApolloDuoSplitIsResizing()
        && !ApolloDuoSplitCanReturnFromVisitedProfile(navigation)
        && ApolloDuoSplitPopRevealsContent(navigation);
}

static CGRect ApolloDuoBackSwipePane(UINavigationController *navigation) {
    UIView *view = navigation.view;
    CGRect pane = ApolloDuoSplitContentFrame(navigation, view);
    if (CGRectIsNull(pane)) {
        CGRect safe = view.safeAreaLayoutGuide.layoutFrame;
        // A full-width landscape screen can inset content for a camera or
        // rounded corner. Back still begins at its physical left edge.
        pane = CGRectMake(CGRectGetMinX(view.bounds), CGRectGetMinY(safe),
                          CGRectGetWidth(view.bounds), CGRectGetHeight(safe));
    }
    return pane;
}

static BOOL ApolloDuoBackSwipeInEdgeStrip(CGRect pane, CGPoint point) {
    return point.x <= CGRectGetMinX(pane) + 28.0;
}

static BOOL ApolloDuoBackSwipeAcceptsPoint(UINavigationController *navigation, CGPoint point) {
    if (!ApolloDuoBackSwipeCanNavigate(navigation)) return NO;
    CGRect pane = ApolloDuoBackSwipePane(navigation);
    if (CGRectIsEmpty(pane) || !CGRectContainsPoint(pane, point)) return NO;
    return ApolloDuoBackSwipeInEdgeStrip(pane, point) || ApolloDuoBackSwipeStartsAnywhere();
}

// The forward swipe mirrors Back. Apollo's own forward pan re-pushes a page
// popped on a regular iPhone; on the Duo's Posts feed a leftward pan from the
// pane's trailing edge brings back the thread a Back closed beside it. Gestures
// > Disable Right Swipes turns off the row actions a left swipe would trigger,
// and the forward swipe then starts anywhere in the pane.
static BOOL ApolloDuoForwardSwipeStartsAnywhere(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"DisableRightSwipeGestureActions"];
}

static BOOL ApolloDuoForwardSwipeCanNavigate(UINavigationController *navigation) {
    return ApolloDuoSplitCanRestoreClosedThread(navigation) && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && ApolloDuoSplitDetailNavigation(navigation) == navigation && ApolloDuoPaneGestureAllowed(navigation);
}

static BOOL ApolloDuoForwardSwipeInEdgeStrip(CGRect pane, CGPoint point) {
    return point.x >= CGRectGetMaxX(pane) - 28.0;
}

static BOOL ApolloDuoForwardSwipeAcceptsPoint(UINavigationController *navigation, CGPoint point) {
    if (!ApolloDuoForwardSwipeCanNavigate(navigation)) return NO;
    CGRect pane = ApolloDuoBackSwipePane(navigation);
    if (CGRectIsEmpty(pane) || !CGRectContainsPoint(pane, point)) return NO;
    return ApolloDuoForwardSwipeInEdgeStrip(pane, point) || ApolloDuoForwardSwipeStartsAnywhere();
}

// Away from the edge strip, content with its own sideways drag keeps it: a
// gallery or carousel that can still page that way, and sliders/switches.
// When the swipe would only reveal a root's list, any sideways scroller keeps
// it, even at its leading end or when its content fits (one that bounces
// sideways still drags): a Community Highlights carousel is being scrolled,
// not asked to open the list over itself.
static BOOL ApolloDuoBackSwipeTouchOwnsHorizontalDrag(UIView *view, UIView *container, BOOL leftward, BOOL rootReveal) {
    for (UIView *candidate = view; candidate && candidate != container; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UISlider.class] || [candidate isKindOfClass:UISwitch.class]) return YES;
        if (![candidate isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (UIScrollView *)candidate;
        if (!scroll.scrollEnabled) continue;
        BOOL overflows = scroll.contentSize.width > CGRectGetWidth(scroll.bounds) + 1.0;
        if (rootReveal) {
            if (overflows || scroll.alwaysBounceHorizontal) return YES;
            continue;
        }
        if (!overflows) continue;
        BOOL canPage = leftward
            ? scroll.contentOffset.x < scroll.contentSize.width - CGRectGetWidth(scroll.bounds)
                + scroll.adjustedContentInset.right - 0.5
            : scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5;
        if (canPage) return YES;
    }
    return NO;
}

// Mirrors ApolloDuoBackRoute below. Leaving a visited profile and popping a
// page are Back; only a plain root reveals its list.
static BOOL ApolloDuoBackSwipeRevealsAtRoot(UINavigationController *navigation) {
    return navigation.viewControllers.count == 1 && !ApolloDuoSplitCanReturnFromVisitedProfile(navigation);
}

// Whether a touch-down may start each way. Away from its edge strip a swipe
// leaves content that owns that sideways drag to it.
static BOOL ApolloDuoBackSwipeAdmitsTouch(UINavigationController *navigation, UIView *view, CGPoint point) {
    if (!ApolloDuoBackSwipeAcceptsPoint(navigation, point)) return NO;
    return ApolloDuoBackSwipeInEdgeStrip(ApolloDuoBackSwipePane(navigation), point)
        || !ApolloDuoBackSwipeTouchOwnsHorizontalDrag(view, navigation.view, NO, ApolloDuoBackSwipeRevealsAtRoot(navigation));
}
static BOOL ApolloDuoForwardSwipeAdmitsTouch(UINavigationController *navigation, UIView *view, CGPoint point) {
    if (!ApolloDuoForwardSwipeAcceptsPoint(navigation, point)) return NO;
    return ApolloDuoForwardSwipeInEdgeStrip(ApolloDuoBackSwipePane(navigation), point)
        || !ApolloDuoBackSwipeTouchOwnsHorizontalDrag(view, navigation.view, YES, NO);
}

// Who performs a Back the pane pan qualified. A route with a driver of its
// own follows the finger (ApolloDuoBackRouteTracks); every other route acts
// once, on release past the commit threshold.
typedef NS_ENUM(NSInteger, ApolloDuoBackOwner) {
    ApolloDuoBackOwnerNative,          // Apollo's own Back pan; the pane pan stands down
    ApolloDuoBackOwnerThreadClose,     // the Posts split closes the thread column
    ApolloDuoBackOwnerVisitedProfile,  // ApolloDuoSplitReturnFromVisitedProfile
    ApolloDuoBackOwnerDrawer,          // the feed root reveals the subreddit list
    ApolloDuoBackOwnerSplitPop,        // popViewControllerAnimated:, which the split routes
};
typedef struct {
    ApolloDuoBackOwner owner;
} ApolloDuoBackRouting;
typedef struct {
    BOOL split;                // an unfolded split lays the navigation out
    BOOL nativeOwns;           // ApolloDuoNativeBackPanOwns
    BOOL visitedProfile;       // either column of a visited profile
    BOOL root;                 // one page left
    BOOL threadAboveBackstop;  // the Posts thread pane, [backstop, thread]
} ApolloDuoBackFacts;

// One table for the Duo Back gestures, in the priority the pane swipe always
// had. Folded or with no split, Apollo's own pan owns every pop, as on a
// regular iPhone; so does any pop onto a real page of the same pane.
static ApolloDuoBackRouting ApolloDuoBackRoute(ApolloDuoBackFacts facts) {
    if (!facts.split || facts.nativeOwns)
        return (ApolloDuoBackRouting){ApolloDuoBackOwnerNative};
    if (facts.visitedProfile)
        return (ApolloDuoBackRouting){ApolloDuoBackOwnerVisitedProfile};
    if (facts.root)
        return (ApolloDuoBackRouting){ApolloDuoBackOwnerDrawer};
    if (facts.threadAboveBackstop)
        return (ApolloDuoBackRouting){ApolloDuoBackOwnerThreadClose};
    // Onto the Account Overview under its header, or an empty detail's placeholder.
    return (ApolloDuoBackRouting){ApolloDuoBackOwnerSplitPop};
}

static ApolloDuoBackFacts ApolloDuoBackFactsForNavigation(UINavigationController *navigation) {
    return (ApolloDuoBackFacts){
        .split = ApolloDuoSplitIsActive(navigation),
        .nativeOwns = ApolloDuoNativeBackPanOwns(navigation),
        .visitedProfile = ApolloDuoSplitCanReturnFromVisitedProfile(navigation),
        .root = navigation.viewControllers.count == 1,
        .threadAboveBackstop = ApolloDuoSplitBackClosesThread(navigation),
    };
}

static ApolloDuoBackRouting ApolloDuoBackRouteForNavigation(UINavigationController *navigation) {
    return ApolloDuoBackRoute(ApolloDuoBackFactsForNavigation(navigation));
}

// The iPad pane Back's thresholds: a third of the pane, or a rightward flick
// once the finger has moved at all. A backward flick cancels at any progress,
// like a native pop. Progress is the drag over the pane width.
static BOOL ApolloDuoBackShouldCommit(CGFloat progress, CGFloat velocity) {
    return velocity > -500.0 && (progress >= 0.35 || (velocity >= 500.0 && progress >= 0.05));
}

// Apollo's own forward pan: its right edge pan, a Swift ivar like the Back's.
static BOOL ApolloDuoNativeForwardInFlight(UINavigationController *navigation) {
    Ivar ivar = navigation ? class_getInstanceVariable(navigation.class, "rightScreenEdgePanGestureRecognizer") : NULL;
    id pan = ivar ? object_getIvar(navigation, ivar) : nil;
    if (![pan isKindOfClass:UIGestureRecognizer.class]) return NO;
    UIGestureRecognizerState state = ((UIGestureRecognizer *)pan).state;
    return state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
}

// The forward swipe's sibling of ApolloDuoBackRoute. Its one owner follows the
// finger (ApolloDuoSplitInteractiveRestore*), or acts once on release when the
// split has no picture of the thread to show.
typedef NS_ENUM(NSInteger, ApolloDuoForwardOwner) {
    ApolloDuoForwardOwnerNone,          // nothing to bring back here; the pan stands down
    ApolloDuoForwardOwnerClosedThread,  // ApolloDuoSplitRestoreClosedThread
};
typedef struct {
    ApolloDuoForwardOwner owner;
} ApolloDuoForwardRouting;
typedef struct {
    BOOL split;          // an unfolded split lays the navigation out
    BOOL closedThread;   // ApolloDuoSplitCanRestoreClosedThread
    BOOL paneHeld;       // the subreddit list is open, or the columns are changing
    BOOL nativeForward;  // Apollo's own forward pan is following a finger
} ApolloDuoForwardFacts;

static ApolloDuoForwardRouting ApolloDuoForwardRoute(ApolloDuoForwardFacts facts) {
    if (!facts.split || !facts.closedThread || facts.paneHeld || facts.nativeForward)
        return (ApolloDuoForwardRouting){ApolloDuoForwardOwnerNone};
    return (ApolloDuoForwardRouting){ApolloDuoForwardOwnerClosedThread};
}

// The forward route with a driver: the closed thread brought back with the finger.
static BOOL ApolloDuoForwardRouteTracks(ApolloDuoForwardRouting route) {
    return route.owner == ApolloDuoForwardOwnerClosedThread;
}

static ApolloDuoForwardRouting ApolloDuoForwardRouteForNavigation(UINavigationController *navigation) {
    return ApolloDuoForwardRoute((ApolloDuoForwardFacts){
        .split = ApolloDuoSplitIsActive(navigation),
        .closedThread = ApolloDuoSplitCanRestoreClosedThread(navigation),
        .paneHeld = !ApolloDuoSplitAllowsNavigationSwipe(navigation),
        .nativeForward = ApolloDuoNativeForwardInFlight(navigation),
    });
}

// Back's thresholds, mirrored: progress and velocity count leftward, and a
// rightward release faster than 500 pt/s cancels.
static BOOL ApolloDuoForwardShouldCommit(CGFloat progress, CGFloat velocity) {
    return ApolloDuoBackShouldCommit(-progress, -velocity);
}

// Routes with a driver of their own follow the finger from Began: the Posts
// thread close (ApolloDuoSplitInteractiveClose*) and the subreddit drawer
// (ApolloDuoSplitInteractiveDrawer*); every other route acts once on release.
static BOOL ApolloDuoBackRouteTracks(ApolloDuoBackRouting route) {
    return (route.owner == ApolloDuoBackOwnerThreadClose || route.owner == ApolloDuoBackOwnerDrawer);
}
// The driver a tracked route has, so each phase of the drag reads the same.
static BOOL ApolloDuoBackDragBegin(ApolloDuoBackRouting route, UINavigationController *navigation) {
    return route.owner == ApolloDuoBackOwnerDrawer ? ApolloDuoSplitInteractiveDrawerBegin(navigation)
        : ApolloDuoSplitInteractiveCloseBegin(navigation);
}
static BOOL ApolloDuoBackDragUpdate(ApolloDuoBackRouting route, UINavigationController *navigation, CGFloat translation) {
    return route.owner == ApolloDuoBackOwnerDrawer ? ApolloDuoSplitInteractiveDrawerUpdate(navigation, translation)
        : ApolloDuoSplitInteractiveCloseUpdate(navigation, translation);
}
static void ApolloDuoBackDragFinish(ApolloDuoBackRouting route, UINavigationController *navigation, BOOL commit, CGFloat velocity) {
    if (route.owner == ApolloDuoBackOwnerDrawer) ApolloDuoSplitInteractiveDrawerFinish(navigation, commit, velocity);
    else ApolloDuoSplitInteractiveCloseFinish(navigation, commit, velocity);
}
static void ApolloDuoBackDragCancel(ApolloDuoBackRouting route, UINavigationController *navigation, BOOL animated) {
    if (route.owner == ApolloDuoBackOwnerDrawer) ApolloDuoSplitInteractiveDrawerCancel(navigation, animated);
    else ApolloDuoSplitInteractiveCloseCancel(navigation, animated);
}

// What the release of a tracked drag does. The driver alone finishes it, so
// the route never also acts: that would be a second Back from one swipe.
typedef NS_ENUM(NSInteger, ApolloDuoBackRelease) {
    ApolloDuoBackReleaseCommit,      // past the threshold, and still this pan's Back
    ApolloDuoBackReleaseSpringBack,  // short of it, or the Back changed hands under the finger
    ApolloDuoBackReleaseCancel,      // interrupted (a sheet, a fold): removed at once, no animation
};
static ApolloDuoBackRelease ApolloDuoBackReleaseFor(BOOL commits, BOOL sameBack, BOOL interrupted) {
    if (interrupted) return ApolloDuoBackReleaseCancel;
    return commits && sameBack ? ApolloDuoBackReleaseCommit : ApolloDuoBackReleaseSpringBack;
}

typedef NS_ENUM(NSInteger, ApolloDuoBackDrag) {
    ApolloDuoBackDragNone,       // the route acts on release, if at all
    ApolloDuoBackDragTracking,   // the split's driver follows the finger
    ApolloDuoBackDragAbandoned,  // the driver let the drag go; this pan is no Back any more
};

// The row under the finger highlights on touchesBegan, before any swipe has
// moved far enough to recognize. Like UIScrollView's delaysContentTouches,
// hold that touch-down back while the guard is undecided: it recognizes on a
// clear sideways move (cancelling the row's touch), and otherwise fails on a
// vertical move or after a short delay, when UIKit delivers the withheld
// touches. Taps and press-and-hold still highlight, only that much later.
static const NSTimeInterval kApolloDuoHighlightGuardDelay = 0.12;

@interface ApolloDuoHighlightGuard : UIPanGestureRecognizer
@property(nonatomic) CGPoint touchStart;
@property(nonatomic) NSUInteger touchGeneration;
@end

@implementation ApolloDuoHighlightGuard
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        self.maximumNumberOfTouches = 1;
        self.cancelsTouchesInView = YES;
        self.delaysTouchesBegan = YES;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.state != UIGestureRecognizerStatePossible) return;
    self.touchStart = [touches.anyObject locationInView:self.view];
    NSUInteger generation = ++self.touchGeneration;
    __weak ApolloDuoHighlightGuard *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloDuoHighlightGuardDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf failIfUndecided:generation]; });
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStatePossible) {
        CGPoint point = [touches.anyObject locationInView:self.view];
        CGFloat dx = point.x - self.touchStart.x, dy = point.y - self.touchStart.y;
        // Scrolling: give the row its touch back at once.
        if (fabs(dy) > 6.0 && fabs(dy) > fabs(dx)) {
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
    }
    [super touchesMoved:touches withEvent:event];
}
- (void)failIfUndecided:(NSUInteger)generation {
    if (generation == self.touchGeneration && self.state == UIGestureRecognizerStatePossible)
        self.state = UIGestureRecognizerStateFailed;
}
// The motion since touch-down (see ApolloDuoPaneBackPan's motionSoFar).
- (CGPoint)motionSoFar {
    CGPoint now = [self locationInView:self.view];
    return CGPointMake(now.x - self.touchStart.x, now.y - self.touchStart.y);
}
- (void)reset {
    [super reset];
    self.touchGeneration++;
}
@end

// Whether the guard's touch is clearly a sideways drag, either way. The
// motion since touch-down must not be mostly vertical; then either it or the
// velocity at the pan's hysteresis must be clearly sideways. The motion
// decides a slow drag, which has no velocity to speak of.
static BOOL ApolloDuoHighlightGuardDecides(CGPoint motion, CGPoint velocity) {
    if (fabs(motion.y) > fabs(motion.x)) return NO;
    return fabs(motion.x) > fabs(motion.y) * 1.5 || fabs(velocity.x) > fabs(velocity.y) * 1.5;
}

// The selection veto: a touch that has travelled further than a tap's jitter
// since touch-down is a drag, in any direction.
static const CGFloat kApolloDuoDragClaimDistance = 10.0;
static BOOL ApolloDuoTouchIsDrag(CGPoint motion) {
    return hypot(motion.x, motion.y) > kApolloDuoDragClaimDistance;
}

// A row's touch that has become a drag belongs to whatever drags (the Back,
// a row action, scrolling) or to nothing at all: a slow sideways drag no pan
// begins for used to keep the row highlighted and select it on release. The
// claim recognizes once the touch is a drag, so the row gets its touch
// cancelled (no highlight, no selection) and a row's tap (the age alert)
// fails. It never delays a tap: an undecided touch goes straight to the row.
@interface ApolloDuoDragClaim : UIGestureRecognizer
@property(nonatomic, weak) UITouch *touch;
@property(nonatomic, weak) UIView *touchView;
@property(nonatomic) CGPoint touchStart;
@end

@implementation ApolloDuoDragClaim
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        self.cancelsTouchesInView = YES;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.touch) return;
    UITouch *touch = touches.anyObject;
    self.touch = touch;
    self.touchView = touch.view;
    self.touchStart = [touch locationInView:self.view];
}
- (CGPoint)motionSoFar {
    CGPoint now = [self.touch locationInView:self.view];
    return CGPointMake(now.x - self.touchStart.x, now.y - self.touchStart.y);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (!self.touch || ![touches containsObject:self.touch]) return;
    if (self.state == UIGestureRecognizerStatePossible) {
        if (ApolloDuoTouchIsDrag([self motionSoFar])) self.state = UIGestureRecognizerStateBegan;
    } else if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateChanged;
    }
}
- (BOOL)claimed {
    return self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (!self.touch || ![touches containsObject:self.touch]) return;
    self.state = [self claimed] ? UIGestureRecognizerStateEnded : UIGestureRecognizerStateFailed;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (!self.touch || ![touches containsObject:self.touch]) return;
    self.state = [self claimed] ? UIGestureRecognizerStateCancelled : UIGestureRecognizerStateFailed;
}
- (void)reset {
    [super reset];
    self.touch = nil;
    self.touchView = nil;
}
@end

// The pane Back keeps its first finger's touch-down: where the drag started,
// for the direction check, and the view under it, whose scrollers stop when
// Back begins. A second finger never replaces either; reset forgets both.
@interface ApolloDuoPaneBackPan : UIPanGestureRecognizer
@property(nonatomic, weak) UIView *touchView;
@property(nonatomic) CGPoint touchStart;
@property(nonatomic) BOOL tracksTouch;
// Which ways the first finger's touch-down may start: Back, the forward swipe.
@property(nonatomic) BOOL backAdmitted, forwardAdmitted;
@end

@implementation ApolloDuoPaneBackPan
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.tracksTouch || self.state != UIGestureRecognizerStatePossible) return;
    UITouch *touch = touches.anyObject;
    self.tracksTouch = YES;
    self.touchView = touch.view;
    self.touchStart = [touch locationInView:self.view];
}
// The motion since touch-down. UIKit strips its pan hysteresis from the
// translation before gestureRecognizerShouldBegin:, which leaves only the
// last few points there.
- (CGPoint)motionSoFar {
    if (!self.tracksTouch) return [self translationInView:self.view];
    CGPoint now = [self locationInView:self.view];
    return CGPointMake(now.x - self.touchStart.x, now.y - self.touchStart.y);
}
- (void)reset {
    [super reset];
    self.tracksTouch = NO;
    self.touchView = nil;
    self.backAdmitted = NO;
    self.forwardAdmitted = NO;
}
@end

@interface ApolloDuoBackSwipe : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UINavigationController *navigation;
// The pane Back. It begins on a clearly rightward move and is routed once,
// then decided again on release (ApolloDuoBackRoute, ApolloDuoBackShouldCommit).
@property(nonatomic, strong) ApolloDuoPaneBackPan *pan;
@property(nonatomic) ApolloDuoBackRouting route;
@property(nonatomic) ApolloDuoBackDrag drag;
// The pan began leftward: it is the forward swipe, routed once and decided
// again on release (ApolloDuoForwardRoute, ApolloDuoForwardShouldCommit).
@property(nonatomic) BOOL forward;
@property(nonatomic) ApolloDuoForwardRouting forwardRoute;
// Recognizes as soon as a touch the Back pan accepts moves clearly sideways, so the
// row under the finger gets touchesCancelled and drops its highlight, before the
// pan has moved far enough to begin.
// Either direction: a leftward move is a row action, which still runs alongside.
@property(nonatomic, strong) ApolloDuoHighlightGuard *highlightGuard;
// Claims a row's touch once it is a drag (ApolloDuoDragClaim).
@property(nonatomic, strong) ApolloDuoDragClaim *dragClaim;
// Apollo's own Back pan began a pop on this navigation controller and it has
// not settled yet. Apollo can change the stack as the pan begins and finish
// the pop after it ends, so the stack alone can't say who owns that Back.
@property(nonatomic) BOOL nativeBackInFlight;
@property(nonatomic) NSUInteger nativeBackGeneration;
@property(nonatomic, weak) UIGestureRecognizer *observedNativeBack;
@end

static char kApolloDuoBackSwipe;

// A pop Apollo's own Back pan drives is still running on `navigation`: the pan
// is following the finger, or it began and the pop has not settled. Neither
// the pane swipe nor the split's own pops may act on that navigation then.
static const NSTimeInterval kApolloDuoNativeBackSettleDelay = 0.5;
BOOL ApolloDuoNativeBackInFlight(UINavigationController *navigation) {
    ApolloDuoBackSwipe *owner = objc_getAssociatedObject(navigation, &kApolloDuoBackSwipe);
    UIGestureRecognizerState state = ApolloDuoNativeBackPan(navigation).state;
    return owner.nativeBackInFlight || state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
}

@implementation ApolloDuoBackSwipe
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    UINavigationController *navigation = self.navigation;
    if (gesture == self.dragClaim) return [self claimsTouch:touch];
    if (gesture != self.pan && gesture != self.highlightGuard) return NO;
    CGPoint point = [touch locationInView:navigation.view];
    BOOL back = ApolloDuoBackSwipeAdmitsTouch(navigation, touch.view, point);
    BOOL forward = ApolloDuoForwardSwipeAdmitsTouch(navigation, touch.view, point);
    // The first finger's touch-down decides which ways the pan may begin.
    if (gesture == self.pan && !self.pan.tracksTouch) {
        self.pan.backAdmitted = back;
        self.pan.forwardAdmitted = forward;
    }
    return back || forward;
}
// The drag claim takes a row's touches anywhere in an unfolded split's pane,
// except on a control the user drags on purpose (a segmented control's
// thumb, a slider, a switch, a stepper, a text field: every control but a
// plain button), a selectable text view, and a list being edited (its
// reorder handles drag).
- (BOOL)claimsTouch:(UITouch *)touch {
    UINavigationController *navigation = self.navigation;
    if (!ApolloDuoSplitIsActive(navigation)) return NO;
    BOOL row = NO;
    for (UIView *view = touch.view; view && view != navigation.view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class] && ![view isKindOfClass:UIButton.class]) return NO;
        if ([view isKindOfClass:UITextView.class] && ((UITextView *)view).selectable) return NO;
        if ([view isKindOfClass:UITableViewCell.class]) {
            if (((UITableViewCell *)view).editing) return NO;
            row = YES;
        }
        if ([view isKindOfClass:UITableView.class] && ((UITableView *)view).editing) return NO;
    }
    return row;
}
// The pane Back may not act on a navigation Apollo's own Back is popping.
- (BOOL)backIsFree:(ApolloDuoBackRouting)route {
    UINavigationController *navigation = self.navigation;
    return route.owner != ApolloDuoBackOwnerNative && ApolloDuoBackSwipeCanNavigate(navigation)
        && !ApolloDuoNativeBackInFlight(navigation);
}
// The forward swipe acts only while its route still brings something back,
// and never on a navigation Apollo's own Back is popping.
- (BOOL)forwardIsFree:(ApolloDuoForwardRouting)route {
    UINavigationController *navigation = self.navigation;
    return route.owner != ApolloDuoForwardOwnerNone && ApolloDuoForwardSwipeCanNavigate(navigation)
        && !ApolloDuoNativeBackInFlight(navigation);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == self.dragClaim) return YES;
    if (gesture == self.highlightGuard) {
        if (!ApolloDuoBackSwipeCanNavigate(self.navigation) && !ApolloDuoForwardSwipeCanNavigate(self.navigation)) return NO;
        return ApolloDuoHighlightGuardDecides([self.highlightGuard motionSoFar],
                                              [self.highlightGuard velocityInView:self.navigation.view]);
    }
    if (gesture != self.pan) return NO;
    // Clearly sideways, rightward for Back or leftward for the forward swipe;
    // a steep move is scrolling, and a way the touch-down was not taken for
    // is a row action: both fail this pan at once. The motion so far must
    // head that way and not mostly up or down; then either it or the
    // velocity at hysteresis must be clearly sideways, since a finger's first
    // points can carry vertical jitter the motion as a whole does not.
    CGPoint motion = [self.pan motionSoFar];
    CGPoint velocity = [self.pan velocityInView:self.navigation.view];
    BOOL leftward = motion.x < 0.0;
    BOOL along = motion.x != 0.0 && fabs(motion.y) <= fabs(motion.x);
    BOOL sideways = ((leftward ? velocity.x < 0.0 : velocity.x > 0.0) && fabs(velocity.x) > fabs(velocity.y) * 1.5)
        || fabs(motion.x) > fabs(motion.y) * 1.5;
    BOOL begins = along && sideways;
    if (leftward) {
        begins = begins && self.pan.forwardAdmitted
            && [self forwardIsFree:ApolloDuoForwardRouteForNavigation(self.navigation)];
    } else {
        // A touch-down only the forward swipe took (its trailing strip) is no Back.
        begins = begins && (self.pan.backAdmitted || !self.pan.forwardAdmitted)
            && [self backIsFree:ApolloDuoBackRouteForNavigation(self.navigation)];
    }
    self.forward = leftward && begins;
    return begins;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // The drag claim excludes taps alone: once it claims a touch, a row's tap
    // (the age alert, a vote) fails instead of firing on release.
    if (gesture == self.dragClaim || other == self.dragClaim) {
        UIGestureRecognizer *peer = gesture == self.dragClaim ? other : gesture;
        return ![peer isKindOfClass:UITapGestureRecognizer.class];
    }
    // The highlight guard only cancels the row's touch; it never competes with anything.
    if (gesture == self.highlightGuard || other == self.highlightGuard) return YES;
    // Vertical table scrolling should not wait for the Back pan to decide;
    // once the pan begins it stops that scrolling (stopScrollingUnderPan).
    return gesture == self.pan && [other.view isKindOfClass:UIScrollView.class]
        && other == ((UIScrollView *)other.view).panGestureRecognizer;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // At the narrow edge strips, give Back and the forward swipe priority over
    // horizontal row actions. Away from them shouldReceiveTouch: rejects this
    // recognizer outright unless Disable Left (or Right) Swipes has already
    // turned those row actions off.
    // Apollo's own Back pan never waits for a pan that stands down for it,
    // or the page would only start following the finger once that pan failed.
    // Another pane's Back (a visited profile's outer navigation and its
    // columns) and its highlight guard don't wait either: the pane Backs
    // exclude each other, and waiting both ways would lose the Back.
    BOOL scrollPan = [other.view isKindOfClass:UIScrollView.class]
        && other == ((UIScrollView *)other.view).panGestureRecognizer;
    BOOL nativeBack = other == ApolloDuoNativeBackPan(self.navigation)
        && ApolloDuoNativeBackPanOwns(self.navigation);
    BOOL duoBack = [other.delegate isKindOfClass:ApolloDuoBackSwipe.class];
    return gesture == self.pan && !duoBack
        && [other isKindOfClass:UIPanGestureRecognizer.class] && !scrollPan && !nativeBack;
}
- (void)guardMoved:(UIPanGestureRecognizer *)gesture {
    // Nothing to do: recognizing is the point (cancelsTouchesInView clears the row highlight).
}
- (void)dragClaimed:(ApolloDuoDragClaim *)claim {
    if (claim.state != UIGestureRecognizerStateBegan) return;
    CGPoint motion = [claim motionSoFar];
    BOOL sideways = fabs(motion.y) <= fabs(motion.x);
    [self cancelRowRecognizersUnder:claim sideways:sideways];
}
- (void)panned:(ApolloDuoPaneBackPan *)pan {
    if (self.forward) {
        [self forwardPanned:pan];
        return;
    }
    UINavigationController *navigation = self.navigation;
    // Measured in the window: a tracked drag moves views under the finger.
    CGFloat translation = [pan translationInView:nil].x;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.route = ApolloDuoBackRouteForNavigation(navigation);
        [self stopScrollingUnderPan];
        pan.touchView = nil;
        // A close the split can't cover (no window, another transition
        // still moving the panes) acts on release, as before.
        self.drag = ApolloDuoBackRouteTracks(self.route) && ApolloDuoBackDragBegin(self.route, navigation)
            ? ApolloDuoBackDragTracking : ApolloDuoBackDragNone;
        return;
    }
    if (pan.state == UIGestureRecognizerStateChanged) {
        if (self.drag != ApolloDuoBackDragTracking) return;
        // A sheet presented mid-drag, a resize, or a split that let the drag go.
        if (ApolloDuoBackSwipeCanNavigate(navigation) && ApolloDuoBackDragUpdate(self.route, navigation, translation)) return;
        [self abandonDrag:pan];
        return;
    }
    ApolloDuoBackDrag drag = self.drag;
    self.drag = ApolloDuoBackDragNone;
    if (pan.state != UIGestureRecognizerStateEnded) {
        // Cancelled (the app resigned active, the system took the touch) or failed.
        if (drag == ApolloDuoBackDragTracking) ApolloDuoBackDragCancel(self.route, navigation, NO);
        return;
    }
    if (drag == ApolloDuoBackDragAbandoned) return;
    // The drawer commits by the share of the drawer shown, not of the pane
    // (deliberate: that is what the finger moves), tracked or discrete alike.
    CGFloat width = CGRectGetWidth(ApolloDuoBackSwipePane(navigation));
    CGFloat progress = self.route.owner == ApolloDuoBackOwnerDrawer
        ? ApolloDuoSplitInteractiveDrawerProgress(navigation, translation)
        : (width > 0.0 ? translation / width : 0.0);
    CGFloat velocity = [pan velocityInView:nil].x;
    BOOL commits = ApolloDuoBackShouldCommit(progress, velocity);
    if (!commits && drag != ApolloDuoBackDragTracking) return;
    // Ownership is decided again on release: Apollo's own Back may have begun
    // since this pan did, and changed the stack under it.
    ApolloDuoBackRouting route = ApolloDuoBackRouteForNavigation(navigation);
    BOOL sameBack = route.owner == self.route.owner && [self backIsFree:route];
    if (drag == ApolloDuoBackDragTracking) {
        switch (ApolloDuoBackReleaseFor(commits, sameBack, !ApolloDuoBackSwipeCanNavigate(navigation))) {
            case ApolloDuoBackReleaseCommit:
                if (self.route.owner == ApolloDuoBackOwnerDrawer) ApolloLog(@"[DuoSwipe] feed root: the subreddit drawer followed the finger");
                else ApolloLog(@"[DuoSwipe] thread pane: close the thread that followed the finger");
                ApolloDuoBackDragFinish(self.route, navigation, YES, velocity);
                return;
            case ApolloDuoBackReleaseSpringBack:
                ApolloDuoBackDragFinish(self.route, navigation, NO, velocity);
                return;
            case ApolloDuoBackReleaseCancel:
                ApolloDuoBackDragCancel(self.route, navigation, NO);
                return;
        }
    }
    if (!sameBack) return;
    [self performBack:route];
}
// The forward swipe brings the closed thread back with the finger, and the
// release past the mirrored threshold finishes it, if it still brings back
// what it began for. Without a driver it acts once on release. The scrolling
// under it stops as for Back.
- (void)forwardPanned:(ApolloDuoPaneBackPan *)pan {
    UINavigationController *navigation = self.navigation;
    // Measured in the window, as Back's: the drag moves a view under the finger.
    CGFloat translation = [pan translationInView:nil].x;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.forwardRoute = ApolloDuoForwardRouteForNavigation(navigation);
        [self stopScrollingUnderPan];
        pan.touchView = nil;
        // No picture of the thread to bring in, or another transition still
        // moving the panes: the restore acts on release, as before.
        self.drag = ApolloDuoForwardRouteTracks(self.forwardRoute) && ApolloDuoSplitInteractiveRestoreBegin(navigation)
            ? ApolloDuoBackDragTracking : ApolloDuoBackDragNone;
        return;
    }
    if (pan.state == UIGestureRecognizerStateChanged) {
        if (self.drag != ApolloDuoBackDragTracking) return;
        // A sheet presented mid-drag, a resize, or a split that let the drag go.
        if (ApolloDuoForwardSwipeCanNavigate(navigation) && ApolloDuoSplitInteractiveRestoreUpdate(navigation, translation)) return;
        [self abandonDrag:pan];
        return;
    }
    ApolloDuoBackDrag drag = self.drag;
    self.drag = ApolloDuoBackDragNone;
    self.forward = NO;
    if (pan.state != UIGestureRecognizerStateEnded) {
        // Cancelled (the app resigned active, the system took the touch) or failed.
        if (drag == ApolloDuoBackDragTracking) ApolloDuoSplitInteractiveRestoreCancel(navigation, NO);
        return;
    }
    if (drag == ApolloDuoBackDragAbandoned) return;
    // A tracked restore commits by the thread pane it fills; the discrete one
    // keeps today's measure, the feed pane.
    CGFloat width = CGRectGetWidth(ApolloDuoBackSwipePane(navigation));
    CGFloat progress = drag == ApolloDuoBackDragTracking ? ApolloDuoSplitInteractiveRestoreProgress(navigation, translation)
        : (width > 0.0 ? translation / width : 0.0);
    CGFloat velocity = [pan velocityInView:nil].x;
    BOOL commits = ApolloDuoForwardShouldCommit(progress, velocity);
    if (!commits && drag != ApolloDuoBackDragTracking) return;
    ApolloDuoForwardRouting route = ApolloDuoForwardRouteForNavigation(navigation);
    BOOL sameForward = route.owner == self.forwardRoute.owner && [self forwardIsFree:route];
    if (drag == ApolloDuoBackDragTracking) {
        switch (ApolloDuoBackReleaseFor(commits, sameForward, !ApolloDuoPaneGestureAllowed(navigation))) {
            case ApolloDuoBackReleaseCommit:
                ApolloLog(@"[DuoSwipe] feed pane: bring back the thread that followed the finger");
                ApolloDuoSplitInteractiveRestoreFinish(navigation, YES, velocity);
                return;
            case ApolloDuoBackReleaseSpringBack:
                ApolloDuoSplitInteractiveRestoreFinish(navigation, NO, velocity);
                return;
            case ApolloDuoBackReleaseCancel:
                ApolloDuoSplitInteractiveRestoreCancel(navigation, NO);
                return;
        }
    }
    if (!sameForward) return;
    switch (route.owner) {
        case ApolloDuoForwardOwnerNone:
            return;
        case ApolloDuoForwardOwnerClosedThread:
            ApolloLog(@"[DuoSwipe] feed pane: bring back the thread a Back closed");
            ApolloDuoSplitRestoreClosedThread(navigation);
            return;
    }
}
// The split let the drag go (a fold, a tab switch, a push), or can't take it
// any more: remove it at once and cancel this pan, so its release is no Back.
// A navigation that is gone cancels whichever drag is active (nil below).
- (void)abandonDrag:(UIPanGestureRecognizer *)pan {
    self.drag = ApolloDuoBackDragAbandoned;
    if (self.forward) ApolloDuoSplitInteractiveRestoreCancel(self.navigation, NO);
    else ApolloDuoBackDragCancel(self.route, self.navigation, NO);
    pan.enabled = NO;
    pan.enabled = YES;
}
// A row's tap (Apollo's age alert) and a press still deciding (the info-row
// loupe) can run alongside anything by their own delegates, so excluding them
// is not enough: cancel those still undecided on the claimed touch's row. A
// vertical claim leaves presses to their own travel veto (a wobbly hold), and
// a press already showing (a hold now scrubbing, a context menu) keeps the
// touch: that is press-and-hold.
- (void)cancelRowRecognizersUnder:(ApolloDuoDragClaim *)claim sideways:(BOOL)sideways {
    UIView *container = self.navigation.view;
    for (UIView *view = claim.touchView; view && view != container; view = view.superview) {
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            BOOL tap = [recognizer isKindOfClass:UITapGestureRecognizer.class];
            BOOL press = sideways && [recognizer isKindOfClass:UILongPressGestureRecognizer.class];
            if ((!tap && !press) || recognizer.state != UIGestureRecognizerStatePossible || !recognizer.enabled) continue;
            recognizer.enabled = NO;
            recognizer.enabled = YES;
        }
    }
}
// The pan runs alongside the scrollers under the finger so vertical scrolling
// never waits for it. Once it begins it is Back: cancel their pans.
- (void)stopScrollingUnderPan {
    UIView *container = self.navigation.view;
    for (UIView *candidate = self.pan.touchView; candidate && candidate != container; candidate = candidate.superview) {
        if (![candidate isKindOfClass:UIScrollView.class]) continue;
        UIPanGestureRecognizer *scrollPan = ((UIScrollView *)candidate).panGestureRecognizer;
        if (!scrollPan.enabled) continue;
        scrollPan.enabled = NO;
        scrollPan.enabled = YES;
    }
}
- (void)performBack:(ApolloDuoBackRouting)route {
    UINavigationController *navigation = self.navigation;
    BOOL animated = !UIAccessibilityIsReduceMotionEnabled();
    switch (route.owner) {
        case ApolloDuoBackOwnerNative:
            return;
        case ApolloDuoBackOwnerThreadClose:
            ApolloLog(@"[DuoSwipe] thread pane: close the thread");
            [navigation popViewControllerAnimated:animated];
            return;
        case ApolloDuoBackOwnerVisitedProfile:
            ApolloLog(@"[DuoSwipe] visited profile: Back out of the profile");
            ApolloDuoSplitReturnFromVisitedProfile(navigation);
            return;
        case ApolloDuoBackOwnerDrawer:
            ApolloLog(@"[DuoSwipe] feed root: reveal subreddit drawer");
            ApolloDuoSplitRevealPostsList(navigation);
            return;
        case ApolloDuoBackOwnerSplitPop:
            ApolloLog(@"[DuoSwipe] Back in pane; stack pages=%lu", (unsigned long)navigation.viewControllers.count);
            [navigation popViewControllerAnimated:animated];
            return;
    }
}
- (void)noteNativeBackBegan {
    self.nativeBackInFlight = YES;
    [self settleNativeBack];
}
- (void)nativeBackChanged:(UIGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        self.nativeBackInFlight = YES;
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled
               || pan.state == UIGestureRecognizerStateFailed) {
        // The pop finishes or springs back after release: hold the flag
        // through that, unless didShow reports the pop done first.
        [self settleNativeBack];
    }
}
- (void)settleNativeBack {
    NSUInteger generation = ++self.nativeBackGeneration;
    __weak ApolloDuoBackSwipe *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloDuoNativeBackSettleDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf clearNativeBack:generation]; });
}
- (void)clearNativeBack:(NSUInteger)generation {
    if (generation != self.nativeBackGeneration) return;
    // Still following the finger: its end settles the flag again.
    UIGestureRecognizerState state = ApolloDuoNativeBackPan(self.navigation).state;
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) return;
    self.nativeBackInFlight = NO;
}
@end

// Apollo's own Back pan is about to begin on `navigation` (its
// gestureRecognizerShouldBegin: said yes). Follow it until its pop settles.
void ApolloDuoNoteNativeBackBegan(UINavigationController *navigation) {
    ApolloDuoBackSwipe *owner = objc_getAssociatedObject(navigation, &kApolloDuoBackSwipe);
    UIGestureRecognizer *pan = ApolloDuoNativeBackPan(navigation);
    if (!owner || !pan) return;
    if (owner.observedNativeBack != pan) {
        [pan addTarget:owner action:@selector(nativeBackChanged:)];
        owner.observedNativeBack = pan;
    }
    [owner noteNativeBackBegan];
}

// A page finished showing on `navigation`: a native pop there has completed.
void ApolloDuoNoteNativeBackShown(UINavigationController *navigation) {
    ApolloDuoBackSwipe *owner = objc_getAssociatedObject(navigation, &kApolloDuoBackSwipe);
    UIGestureRecognizerState state = ApolloDuoNativeBackPan(navigation).state;
    if (!owner.nativeBackInFlight || state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) return;
    owner.nativeBackGeneration++;
    owner.nativeBackInFlight = NO;
}

static NSString *const kApolloDuoPaneBackName = @"ApolloReborn.Duo.PaneBack";

// Feed galleries make ancestor pans wait for their own drag but exempt this
// one: its touch admission already leaves a carousel that can scroll its
// drag, and takes the edge strip. Community Highlights keeps it waiting and
// releases it at the first highlight for Back and at the last for the
// forward swipe (ahlShouldYieldToNavigation, via ApolloDuoPaneBackPanAdmits).
BOOL ApolloDuoIsPaneBackPan(UIGestureRecognizer *gesture) {
    return [gesture.name isEqualToString:kApolloDuoPaneBackName]
        && [gesture.delegate isKindOfClass:ApolloDuoBackSwipe.class]
        && gesture == ((ApolloDuoBackSwipe *)gesture.delegate).pan;
}

BOOL ApolloDuoPaneBackPanAdmits(UIGestureRecognizer *gesture, BOOL forward) {
    if (!ApolloDuoIsPaneBackPan(gesture)) return NO;
    ApolloDuoPaneBackPan *pan = (ApolloDuoPaneBackPan *)gesture;
    return pan.tracksTouch && (forward ? pan.forwardAdmitted : pan.backAdmitted);
}

BOOL ApolloDuoIsPaneGesture(UIGestureRecognizer *gesture) {
    ApolloDuoBackSwipe *owner = [gesture.delegate isKindOfClass:ApolloDuoBackSwipe.class] ? gesture.delegate : nil;
    return gesture && (gesture == owner.pan || gesture == owner.highlightGuard || gesture == owner.dragClaim);
}

BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation) {
    return objc_getAssociatedObject(navigation, &kApolloDuoBackSwipe) != nil;
}

void ApolloDuoInstallBackSwipe(UINavigationController *navigation) {
    if (!ApolloDeviceIsDuo() || !navigation.isViewLoaded || ApolloDuoHasBackSwipe(navigation)) return;
    ApolloDuoBackSwipe *owner = [ApolloDuoBackSwipe new];
    owner.navigation = navigation;
    ApolloDuoPaneBackPan *pan = [[ApolloDuoPaneBackPan alloc] initWithTarget:owner action:@selector(panned:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = owner;
    pan.name = kApolloDuoPaneBackName;
    owner.pan = pan;
    ApolloDuoHighlightGuard *highlightGuard = [[ApolloDuoHighlightGuard alloc] initWithTarget:owner action:@selector(guardMoved:)];
    highlightGuard.delegate = owner;
    highlightGuard.name = @"ApolloReborn.Duo.PaneBackHighlightGuard";
    owner.highlightGuard = highlightGuard;
    ApolloDuoDragClaim *dragClaim = [[ApolloDuoDragClaim alloc] initWithTarget:owner action:@selector(dragClaimed:)];
    dragClaim.delegate = owner;
    dragClaim.name = @"ApolloReborn.Duo.DragClaim";
    owner.dragClaim = dragClaim;
    objc_setAssociatedObject(navigation, &kApolloDuoBackSwipe, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation.view addGestureRecognizer:pan];
    [navigation.view addGestureRecognizer:highlightGuard];
    [navigation.view addGestureRecognizer:dragClaim];
}
