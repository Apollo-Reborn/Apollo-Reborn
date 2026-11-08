#import "ApolloDuoNavigationGestures.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import "ApolloDuoPaneDrag.h"
#import <objc/runtime.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

// Apollo's pans use the whole navigation surface for edge checks. On Duo a
// visible pane can start well inside that surface, and the outer stack is a
// containment host. Qualify a rightward drag at the *pane's* left content
// edge, then route it (ApolloDuoBackRouteFor): a pop onto a real page of the
// pane goes to Apollo's own interactive Back, which follows the finger as on
// a regular iPhone; at the feed root the subreddit drawer follows the finger;
// a thread above the Posts backstop slides out with the finger and closes its
// column; any other Back runs the split's own animated pop. Keep row swipe
// actions elsewhere, and honor Apollo's navigation-gesture opt-out.
static BOOL ApolloDuoSwipeEnvironmentAllows(UINavigationController *navigation) {
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
    return (pane || ApolloDuoSplitCanReturnFromVisitedProfile(navigation)) && ApolloDuoSwipeEnvironmentAllows(navigation);
}

// Gestures > Disable Left Swipes turns off the row actions a right swipe would
// trigger, and Apollo's own Back pan then starts anywhere on the page. Give a
// Duo pane the same reach; with the setting off only the edge strip qualifies.
// Either way a swipe acts on the pane it starts in: the feed's own Back while
// a thread stays open beside it, the thread's Back from the thread.
static BOOL ApolloDuoBackSwipeStartsAnywhere(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"DisableLeftSwipeGestureActions"];
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

// The forward half. After the thread beside the Posts feed is closed, a left
// swipe on the full-width feed brings it back as it was left. It mirrors Back:
// the feed's trailing 28pt strip, or anywhere with Gestures > Disable Right
// Swipes on, which turns off the row actions a left swipe would trigger.
static BOOL ApolloDuoForwardSwipeStartsAnywhere(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"DisableRightSwipeGestureActions"];
}

static BOOL ApolloDuoForwardSwipeCanNavigate(UINavigationController *navigation) {
    return (ApolloDuoSplitCanRestoreClosedThread(navigation) || ApolloDuoSplitCanForwardInSplit(navigation))
        && ApolloDuoSwipeEnvironmentAllows(navigation);
}

// The pane runs under a trailing side rail (its content frame keeps that strip
// to center content), so measure from the visible edge, as a release does. In
// landscape the strip would otherwise sit almost entirely behind the rail.
static BOOL ApolloDuoForwardSwipeInEdgeStrip(UIView *view, CGRect pane, CGPoint point) {
    CGFloat visibleRight = MIN(CGRectGetMaxX(pane), CGRectGetWidth(view.bounds) - view.safeAreaInsets.right);
    return point.x >= visibleRight - 28.0;
}

static BOOL ApolloDuoForwardSwipeAcceptsPoint(UINavigationController *navigation, CGPoint point) {
    if (!ApolloDuoForwardSwipeCanNavigate(navigation)) return NO;
    CGRect pane = ApolloDuoBackSwipePane(navigation);
    if (CGRectIsEmpty(pane) || !CGRectContainsPoint(pane, point)) return NO;
    return ApolloDuoForwardSwipeInEdgeStrip(navigation.view, pane, point) || ApolloDuoForwardSwipeStartsAnywhere();
}

// Away from the edge strip, content with its own sideways drag keeps it: a
// gallery or carousel that can still page back, and controls that drag
// (sliders, switches, segmented controls, steppers, date pickers, text
// fields, and text that can be selected or edited). When
// the swipe would only reveal a root's list, any sideways scroller keeps it,
// even at its leading end or when its content fits (one that bounces
// sideways still drags): a Community Highlights carousel is being scrolled,
// not asked to open the list over itself. Forward mirrors it: a scroller keeps
// the touch until it has scrolled to its trailing end.
static BOOL ApolloDuoBackSwipeTouchOwnsHorizontalDrag(UIView *view, UIView *container, BOOL rootReveal, BOOL forward) {
    for (UIView *candidate = view; candidate && candidate != container; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UISlider.class] || [candidate isKindOfClass:UISwitch.class]
            || [candidate isKindOfClass:UISegmentedControl.class] || [candidate isKindOfClass:UIStepper.class]
            || [candidate isKindOfClass:UIDatePicker.class] || [candidate isKindOfClass:UITextField.class]) return YES;
        // A text view moves its cursor or selection with a drag; a plain
        // read-only one is only a label and leaves the swipe alone.
        if ([candidate isKindOfClass:UITextView.class]
            && (((UITextView *)candidate).isSelectable || ((UITextView *)candidate).isEditable)) return YES;
        if (![candidate isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (UIScrollView *)candidate;
        if (!scroll.scrollEnabled) continue;
        BOOL overflows = scroll.contentSize.width > CGRectGetWidth(scroll.bounds) + 1.0;
        if (forward) {
            CGFloat trailingOffset = scroll.contentSize.width + scroll.adjustedContentInset.right - CGRectGetWidth(scroll.bounds);
            if (overflows && scroll.contentOffset.x < trailingOffset - 0.5) return YES;
            continue;
        }
        if (rootReveal ? overflows || scroll.alwaysBounceHorizontal
                       : overflows && scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5) return YES;
    }
    return NO;
}

// Mirrors the routes below. Leaving a visited profile and popping a page are
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

// Leaving a visited profile is the split's own Back from either column, so
// Apollo's pan never owns it even over a real page.
BOOL ApolloDuoPaneBackIsNative(UINavigationController *navigation) {
    return !ApolloDuoSplitIsResizing() && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && !ApolloDuoSplitCanReturnFromVisitedProfile(navigation)
        && ApolloDuoSplitPopRevealsContent(navigation);
}

static ApolloDuoBackRoute ApolloDuoPaneBackRoute(UINavigationController *navigation) {
    return ApolloDuoBackRouteFor(ApolloDuoBackSwipeCanNavigate(navigation),
                                 ApolloDuoPaneBackIsNative(navigation),
                                 ApolloDuoSplitCanRevealPostsListWithSwipe(navigation)
                                     && ApolloDuoBackSwipeRevealsAtRoot(navigation),
                                 ApolloDuoSplitCanDragThreadClosed(navigation));
}

static UIGestureRecognizer *ApolloDuoNativeBackPan(UINavigationController *navigation) {
    Ivar ivar = navigation ? class_getInstanceVariable(navigation.class, "leftScreenEdgePanGestureRecognizer") : NULL;
    id pan = ivar ? object_getIvar(navigation, ivar) : nil;
    return [pan isKindOfClass:UIGestureRecognizer.class] ? pan : nil;
}

static BOOL ApolloDuoIsScrollPan(UIGestureRecognizer *gesture) {
    return [gesture.view isKindOfClass:UIScrollView.class]
        && gesture == ((UIScrollView *)gesture.view).panGestureRecognizer;
}

@interface ApolloDuoBackSwipe : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UINavigationController *navigation;
@property(nonatomic, strong) UIPanGestureRecognizer *pan;
// Decided when the drag begins and kept until it ends.
@property(nonatomic) ApolloDuoBackRoute route;
// Where the dragged surface was when the drag began: the thread pane's
// offset, or how much of the drawer showed.
@property(nonatomic) CGFloat start;
// The forward half: a left drag that brings back the thread just closed,
// following the finger when the split kept a picture of it.
@property(nonatomic, strong) UIPanGestureRecognizer *forwardSwipe;
@property(nonatomic) BOOL forwardFollows;
// The forward drag is one the split lays out (a visited profile, Account's
// detail), not the closed thread.
@property(nonatomic) BOOL forwardSplit;
// A Pop-route Back follows the finger over the split's pictures.
@property(nonatomic) BOOL coverFollows;
// Recognizes as soon as a touch the Back drag accepts moves clearly sideways,
// so the row under the finger gets touchesCancelled and drops its highlight
// before the drag itself is sure. Either direction: a leftward move is a row
// action, which still runs alongside.
@property(nonatomic, strong) ApolloDuoHighlightGuard *highlightGuard;
@end

static NSHashTable<ApolloDuoBackSwipe *> *sDuoPaneDrags;

@implementation ApolloDuoBackSwipe
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    UINavigationController *navigation = self.navigation;
    CGPoint point = [touch locationInView:navigation.view];
    if (gesture != self.pan && gesture != self.forwardSwipe && gesture != self.highlightGuard) return NO;
    BOOL back = gesture != self.forwardSwipe && ApolloDuoBackSwipeAcceptsPoint(navigation, point)
        && (ApolloDuoBackSwipeInEdgeStrip(ApolloDuoBackSwipePane(navigation), point)
            || !ApolloDuoBackSwipeTouchOwnsHorizontalDrag(touch.view, navigation.view, ApolloDuoBackSwipeRevealsAtRoot(navigation), NO));
    // A carousel keeps its sideways swipes until it is at its last item, in
    // the strip too: Back gets that from the carousel's own yielding.
    BOOL forward = gesture != self.pan && ApolloDuoForwardSwipeAcceptsPoint(navigation, point)
        && !ApolloDuoBackSwipeTouchOwnsHorizontalDrag(touch.view, navigation.view, NO, YES);
    return back || forward;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // The highlight guard only cancels the row's touch; it never competes with anything.
    if (gesture == self.highlightGuard || other == self.highlightGuard) return YES;
    return NO;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == self.forwardSwipe) {
        CGPoint translation = [self.forwardSwipe translationInView:nil];
        CGPoint velocity = [self.forwardSwipe velocityInView:nil];
        return ApolloDuoDragIsLeftward(translation.x, translation.y, velocity.x, velocity.y)
            && ApolloDuoForwardSwipeCanNavigate(self.navigation);
    }
    if (gesture == self.highlightGuard) {
        if (!ApolloDuoBackSwipeCanNavigate(self.navigation) && !ApolloDuoForwardSwipeCanNavigate(self.navigation)) return NO;
        CGPoint velocity = [self.highlightGuard velocityInView:self.navigation.view];
        return fabs(velocity.x) > fabs(velocity.y) * 1.5;
    }
    if (gesture != self.pan) return NO;
    // Window coordinates: the thread route moves this pan's own view.
    CGPoint translation = [self.pan translationInView:nil];
    CGPoint velocity = [self.pan velocityInView:nil];
    if (!ApolloDuoDragIsRightward(translation.x, translation.y, velocity.x, velocity.y)) return NO;
    self.route = ApolloDuoPaneBackRoute(self.navigation);
    return self.route != ApolloDuoBackRouteNone && self.route != ApolloDuoBackRouteNative;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // In the edge strip, Back has priority over horizontal row actions; it
    // fails at once on any motion that is not a rightward drag. Table scrolling
    // never waits, and neither does Apollo's own Back pan, which this one
    // stands down for: the page would otherwise lag the finger.
    if (other == self.highlightGuard || ![other isKindOfClass:UIPanGestureRecognizer.class] || ApolloDuoIsScrollPan(other))
        return NO;
    return gesture == self.forwardSwipe || (gesture == self.pan && other != ApolloDuoNativeBackPan(self.navigation));
}
- (void)guardMoved:(UIPanGestureRecognizer *)gesture {
    // Nothing to do: recognizing is the point (cancelsTouchesInView clears the row highlight).
}
- (void)forwardPanned:(UIPanGestureRecognizer *)pan {
    UINavigationController *navigation = self.navigation;
    CGFloat shown = -[pan translationInView:nil].x;
    CGFloat vx = [pan velocityInView:nil].x;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            self.forwardSplit = !ApolloDuoSplitCanRestoreClosedThread(navigation)
                && ApolloDuoSplitCanForwardInSplit(navigation);
            self.forwardFollows = self.forwardSplit ? ApolloDuoSplitBeginForwardDrag(navigation)
                                                    : ApolloDuoSplitBeginRestoreDrag(navigation);
            ApolloLog(@"[DuoSwipe] forward drag began split=%d follows=%d", self.forwardSplit, self.forwardFollows);
            [self moveForward:navigation shown:shown];
            break;
        case UIGestureRecognizerStateChanged:
            if (ApolloDuoSplitIsResizing() || !navigation.viewIfLoaded.window) {
                [self cancelRecognizer:pan];
                break;
            }
            [self moveForward:navigation shown:shown];
            break;
        case UIGestureRecognizerStateEnded: {
            BOOL splitOwned = self.forwardSplit;
            CGFloat travel = splitOwned ? ApolloDuoSplitCoverDragTravel(navigation) : ApolloDuoSplitRestoreDragTravel(navigation);
            if (travel <= 0) travel = CGRectGetWidth(navigation.view.bounds) / 2;
            BOOL restore = ApolloDuoDragCommits(ApolloDuoDragClamp(shown, travel), travel, -vx);
            if (self.forwardFollows && splitOwned) ApolloDuoSplitEndCoverDrag(navigation, restore, shown, vx);
            else if (self.forwardFollows) ApolloDuoSplitEndRestoreDrag(navigation, restore, shown, vx);
            else if (restore && splitOwned) ApolloDuoSplitForwardInSplit(navigation);
            else if (restore) ApolloDuoSplitRestoreClosedThread(navigation);
            self.forwardFollows = NO;
            self.forwardSplit = NO;
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (self.forwardFollows && self.forwardSplit) ApolloDuoSplitEndCoverDrag(navigation, NO, shown, 0);
            else if (self.forwardFollows) ApolloDuoSplitEndRestoreDrag(navigation, NO, shown, 0);
            self.forwardFollows = NO;
            self.forwardSplit = NO;
            break;
        default:
            break;
    }
}
- (void)moveForward:(UINavigationController *)navigation shown:(CGFloat)shown {
    if (!self.forwardFollows) return;
    if (self.forwardSplit) ApolloDuoSplitMoveCoverDrag(navigation, shown);
    else ApolloDuoSplitMoveRestoreDrag(navigation, shown);
}
- (void)cancelRecognizer:(UIGestureRecognizer *)recognizer {
    UIGestureRecognizerState state = recognizer.state;
    if (state != UIGestureRecognizerStateBegan && state != UIGestureRecognizerStateChanged) return;
    recognizer.enabled = NO;
    recognizer.enabled = YES;
}
- (void)cancel {
    [self cancelRecognizer:self.pan];
    [self cancelRecognizer:self.forwardSwipe];
}
- (void)panned:(UIPanGestureRecognizer *)pan {
    UINavigationController *navigation = self.navigation;
    CGFloat dx = [pan translationInView:nil].x;
    CGFloat vx = [pan velocityInView:nil].x;
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self beginRoute:navigation];
            [self track:navigation dx:dx];
            break;
        case UIGestureRecognizerStateChanged:
            if (ApolloDuoSplitIsResizing() || !navigation.viewIfLoaded.window) {
                [self cancelRecognizer:pan];
                break;
            }
            [self track:navigation dx:dx];
            break;
        case UIGestureRecognizerStateEnded:
            [self finish:navigation dx:dx velocity:vx cancelled:NO];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self finish:navigation dx:dx velocity:0 cancelled:YES];
            break;
        default:
            break;
    }
}
- (void)beginRoute:(UINavigationController *)navigation {
    ApolloLog(@"[DuoDrag] pane Back began route=%d pages=%lu", (int)self.route,
              (unsigned long)navigation.viewControllers.count);
    switch (self.route) {
        case ApolloDuoBackRouteDrawer:
            if (!ApolloDuoSplitBeginListDrag(navigation)) self.route = ApolloDuoBackRouteNone;
            else self.start = ApolloDuoSplitListDragStart(navigation);
            break;
        case ApolloDuoBackRouteCloseThread: {
            CGFloat offset = ApolloDuoSplitBeginThreadDrag(navigation);
            if (offset < 0) self.route = ApolloDuoBackRouteNone;
            else self.start = offset;
            break;
        }
        case ApolloDuoBackRoutePop:
            // A Back the split lays out follows the finger over pictures of
            // both sides (ApolloDuoSplitBeginBackDrag). Without a picture,
            // run it as soon as the drag is clearly a Back.
            if (ApolloDuoSplitBeginBackDrag(navigation)) {
                self.coverFollows = YES;
                ApolloLog(@"[DuoSwipe] split Back drag follows the finger");
                break;
            }
            if (ApolloDuoSplitReturnFromVisitedProfile(navigation)) {
                ApolloLog(@"[DuoSwipe] visited profile: Back out of the profile");
            } else {
                [navigation popViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()];
            }
            self.route = ApolloDuoBackRouteNone;
            break;
        default:
            self.route = ApolloDuoBackRouteNone;
            break;
    }
}
- (void)track:(UINavigationController *)navigation dx:(CGFloat)dx {
    if (self.coverFollows) {
        ApolloDuoSplitMoveCoverDrag(navigation, dx);
        return;
    }
    if (self.route == ApolloDuoBackRouteDrawer) {
        ApolloDuoSplitMoveListDrag(navigation, self.start + dx);
    } else if (self.route == ApolloDuoBackRouteCloseThread) {
        ApolloDuoSplitDragThread(navigation, ApolloDuoDragClamp(self.start + dx, ApolloDuoSplitThreadDragTravel(navigation)));
    }
}
- (void)finish:(UINavigationController *)navigation dx:(CGFloat)dx velocity:(CGFloat)vx cancelled:(BOOL)cancelled {
    ApolloDuoBackRoute route = self.route;
    self.route = ApolloDuoBackRouteNone;
    if (self.coverFollows) {
        self.coverFollows = NO;
        CGFloat travel = ApolloDuoSplitCoverDragTravel(navigation);
        CGFloat shown = ApolloDuoDragClamp(dx, travel);
        ApolloDuoSplitEndCoverDrag(navigation, !cancelled && ApolloDuoDragCommits(shown, travel, vx), shown, vx);
        return;
    }
    if (route == ApolloDuoBackRouteDrawer) {
        CGFloat travel = ApolloDuoSplitListDragTravel(navigation);
        CGFloat shown = ApolloDuoDragClamp(self.start + dx, travel);
        ApolloDuoSplitEndListDrag(navigation, !cancelled && ApolloDuoDragCommits(shown, travel, vx), vx);
    } else if (route == ApolloDuoBackRouteCloseThread) {
        CGFloat travel = ApolloDuoSplitThreadDragTravel(navigation);
        CGFloat offset = ApolloDuoDragClamp(self.start + dx, travel);
        ApolloDuoSplitEndThreadDrag(navigation, !cancelled && ApolloDuoDragCommits(offset, travel, vx), offset, vx);
    }
}
@end

static char kApolloDuoBackSwipe;
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation) {
    return objc_getAssociatedObject(navigation, &kApolloDuoBackSwipe) != nil;
}

void ApolloDuoCancelPaneDrags(void) {
    for (ApolloDuoBackSwipe *owner in sDuoPaneDrags.allObjects) [owner cancel];
}

void ApolloDuoInstallBackSwipe(UINavigationController *navigation) {
    if (!ApolloDeviceIsDuo() || !navigation.isViewLoaded || ApolloDuoHasBackSwipe(navigation)) return;
    ApolloDuoBackSwipe *owner = [ApolloDuoBackSwipe new];
    owner.navigation = navigation;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:owner action:@selector(panned:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = owner;
    pan.name = @"ApolloReborn.Duo.PaneBack";
    owner.pan = pan;
    UIPanGestureRecognizer *forwardSwipe = [[UIPanGestureRecognizer alloc] initWithTarget:owner action:@selector(forwardPanned:)];
    forwardSwipe.maximumNumberOfTouches = 1;
    forwardSwipe.delegate = owner;
    forwardSwipe.name = @"ApolloReborn.Duo.PaneForward";
    owner.forwardSwipe = forwardSwipe;
    ApolloDuoHighlightGuard *highlightGuard = [[ApolloDuoHighlightGuard alloc] initWithTarget:owner action:@selector(guardMoved:)];
    highlightGuard.delegate = owner;
    highlightGuard.name = @"ApolloReborn.Duo.PaneBackHighlightGuard";
    owner.highlightGuard = highlightGuard;
    objc_setAssociatedObject(navigation, &kApolloDuoBackSwipe, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation.view addGestureRecognizer:pan];
    [navigation.view addGestureRecognizer:forwardSwipe];
    [navigation.view addGestureRecognizer:highlightGuard];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDuoPaneDrags = [NSHashTable weakObjectsHashTable];
        // Backgrounding mid-drag (Control Center, a call) springs it back.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { ApolloDuoCancelPaneDrags(); }];
    });
    [sDuoPaneDrags addObject:owner];
}
