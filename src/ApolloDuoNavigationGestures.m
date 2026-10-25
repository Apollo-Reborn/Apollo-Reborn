#import "ApolloDuoNavigationGestures.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

// Apollo's pans use the whole navigation surface for edge checks. On Duo a
// visible pane can start well inside that surface, and the outer stack is a
// containment host. Qualify a right swipe at the *pane's* left content edge,
// then perform one native animated Back on that exact navigation controller.
// At the feed root the same gesture reveals the subreddit drawer. Calling the
// native pop entry point keeps the author's feed/thread restoration animation.
// Keep row swipe actions elsewhere, and honor Apollo's navigation-gesture opt-out.
static BOOL ApolloDuoBackSwipeCanNavigate(UINavigationController *navigation) {
    // A visited profile is a visit of the whole account split, header column
    // included: from either column, Back leaves the profile.
    BOOL pane = (navigation.viewControllers.count > 1 || ApolloDuoSplitCanRevealPostsListWithSwipe(navigation))
        && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && ApolloDuoSplitDetailNavigation(navigation) == navigation;
    BOOL eligible = ApolloDeviceIsDuo() && navigation.viewIfLoaded.window
        && (pane || ApolloDuoSplitCanReturnFromVisitedProfile(navigation))
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

// Away from the edge strip, content with its own sideways drag keeps it: a
// gallery or carousel that can still page back, and sliders/switches. When
// the swipe would only reveal a root's list, any sideways scroller keeps it,
// even at its leading end or when its content fits (one that bounces
// sideways still drags): a Community Highlights carousel is being scrolled,
// not asked to open the list over itself.
static BOOL ApolloDuoBackSwipeTouchOwnsHorizontalDrag(UIView *view, UIView *container, BOOL rootReveal) {
    for (UIView *candidate = view; candidate && candidate != container; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UISlider.class] || [candidate isKindOfClass:UISwitch.class]) return YES;
        if (![candidate isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (UIScrollView *)candidate;
        if (!scroll.scrollEnabled) continue;
        BOOL overflows = scroll.contentSize.width > CGRectGetWidth(scroll.bounds) + 1.0;
        if (rootReveal ? overflows || scroll.alwaysBounceHorizontal
                       : overflows && scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5) return YES;
    }
    return NO;
}

// Mirrors swiped: below. Leaving a visited profile and popping a page are
// Back; only a plain root reveals its list.
static BOOL ApolloDuoBackSwipeRevealsAtRoot(UINavigationController *navigation) {
    return navigation.viewControllers.count == 1 && !ApolloDuoSplitCanReturnFromVisitedProfile(navigation);
}

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
- (void)reset {
    [super reset];
    self.touchGeneration++;
}
@end

@interface ApolloDuoBackSwipe : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UINavigationController *navigation;
@property(nonatomic, strong) UISwipeGestureRecognizer *swipe;
// Recognizes as soon as a touch the Back swipe accepts moves clearly sideways, so the
// row under the finger gets touchesCancelled and drops its highlight. The discrete
// swipe only recognizes after the motion, which left the post highlighted throughout.
// Either direction: a leftward move is a row action, which still runs alongside.
@property(nonatomic, strong) ApolloDuoHighlightGuard *highlightGuard;
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
    CGPoint point = [touch locationInView:navigation.view];
    if ((gesture != self.swipe && gesture != self.highlightGuard)
        || !ApolloDuoBackSwipeAcceptsPoint(navigation, point)) return NO;
    return ApolloDuoBackSwipeInEdgeStrip(ApolloDuoBackSwipePane(navigation), point)
        || !ApolloDuoBackSwipeTouchOwnsHorizontalDrag(touch.view, navigation.view, ApolloDuoBackSwipeRevealsAtRoot(navigation));
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == self.highlightGuard) {
        if (!ApolloDuoBackSwipeCanNavigate(self.navigation)) return NO;
        CGPoint velocity = [self.highlightGuard velocityInView:self.navigation.view];
        return fabs(velocity.x) > fabs(velocity.y) * 1.5;
    }
    return gesture == self.swipe && ApolloDuoBackSwipeCanNavigate(self.navigation)
        && !ApolloDuoNativeBackPanOwns(self.navigation) && !ApolloDuoNativeBackInFlight(self.navigation);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // The highlight guard only cancels the row's touch; it never competes with anything.
    if (gesture == self.highlightGuard || other == self.highlightGuard) return YES;
    // Vertical table scrolling should not wait for a discrete right swipe.
    return gesture == self.swipe && [other.view isKindOfClass:UIScrollView.class]
        && other == ((UIScrollView *)other.view).panGestureRecognizer;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // At the narrow edge strip, give Back priority over horizontal row actions.
    // Away from that strip shouldReceiveTouch: rejects this recognizer outright
    // unless Disable Left Swipes has already turned those row actions off.
    // Apollo's own Back pan never waits for a swipe that stands down for it,
    // or the page would only start following the finger once the swipe failed.
    BOOL scrollPan = [other.view isKindOfClass:UIScrollView.class]
        && other == ((UIScrollView *)other.view).panGestureRecognizer;
    BOOL nativeBack = other == ApolloDuoNativeBackPan(self.navigation)
        && ApolloDuoNativeBackPanOwns(self.navigation);
    return gesture == self.swipe && other != self.highlightGuard
        && [other isKindOfClass:UIPanGestureRecognizer.class] && !scrollPan && !nativeBack;
}
- (void)guardMoved:(UIPanGestureRecognizer *)gesture {
    // Nothing to do: recognizing is the point (cancelsTouchesInView clears the row highlight).
}
- (void)swiped:(UISwipeGestureRecognizer *)gesture {
    UINavigationController *navigation = self.navigation;
    // Ownership is decided again here: Apollo's own Back may have begun since
    // this swipe started, and changed the stack under it.
    if (gesture.state != UIGestureRecognizerStateRecognized || !ApolloDuoBackSwipeCanNavigate(navigation)
        || ApolloDuoNativeBackInFlight(navigation) || ApolloDuoNativeBackPanOwns(navigation)) return;
    if (ApolloDuoSplitReturnFromVisitedProfile(navigation)) {
        ApolloLog(@"[DuoSwipe] visited profile: Back out of the profile");
        return;
    }
    if (navigation.viewControllers.count == 1) {
        ApolloLog(@"[DuoSwipe] feed root: reveal subreddit drawer");
        ApolloDuoSplitRevealPostsList(navigation);
        return;
    }
    ApolloLog(@"[DuoSwipe] Back in pane; stack pages=%lu", (unsigned long)navigation.viewControllers.count);
    [navigation popViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()];
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

BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation) {
    return objc_getAssociatedObject(navigation, &kApolloDuoBackSwipe) != nil;
}

void ApolloDuoInstallBackSwipe(UINavigationController *navigation) {
    if (!ApolloDeviceIsDuo() || !navigation.isViewLoaded || ApolloDuoHasBackSwipe(navigation)) return;
    ApolloDuoBackSwipe *owner = [ApolloDuoBackSwipe new];
    owner.navigation = navigation;
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:owner action:@selector(swiped:)];
    swipe.direction = UISwipeGestureRecognizerDirectionRight;
    swipe.numberOfTouchesRequired = 1;
    swipe.delegate = owner;
    swipe.name = @"ApolloReborn.Duo.PaneBack";
    owner.swipe = swipe;
    ApolloDuoHighlightGuard *highlightGuard = [[ApolloDuoHighlightGuard alloc] initWithTarget:owner action:@selector(guardMoved:)];
    highlightGuard.delegate = owner;
    highlightGuard.name = @"ApolloReborn.Duo.PaneBackHighlightGuard";
    owner.highlightGuard = highlightGuard;
    objc_setAssociatedObject(navigation, &kApolloDuoBackSwipe, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation.view addGestureRecognizer:swipe];
    [navigation.view addGestureRecognizer:highlightGuard];
}
