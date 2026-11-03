#import "ApolloDuoNavigationGestures.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import "ApolloDuoPaneDrag.h"
#import <objc/runtime.h>

// Apollo's pans use the whole navigation surface for edge checks. On Duo a
// visible pane can start well inside that surface, and the outer stack is a
// containment host. Qualify a rightward drag at the *pane's* left content
// edge, then route it (ApolloDuoBackRouteFor): a pop onto a real page of the
// pane goes to Apollo's own interactive Back, which follows the finger as on
// a regular iPhone; at the feed root the subreddit drawer follows the finger;
// a thread above the Posts backstop slides out with the finger and closes its
// column; any other Back runs the split's own animated pop. Keep row swipe
// actions elsewhere, and honor Apollo's navigation-gesture opt-out.
static BOOL ApolloDuoBackSwipeCanNavigate(UINavigationController *navigation) {
    BOOL eligible = ApolloDeviceIsDuo() && navigation.viewIfLoaded.window
        && (navigation.viewControllers.count > 1 || ApolloDuoSplitCanRevealPostsListWithSwipe(navigation))
        && ![NSUserDefaults.standardUserDefaults boolForKey:@"DisableNavigationGestures"]
        && !ApolloDuoSplitIsResizing() && !navigation.transitionCoordinator
        && !navigation.presentedViewController && !navigation.topViewController.presentedViewController
        && !navigation.isBeingDismissed
        && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && ApolloDuoSplitDetailNavigation(navigation) == navigation;
    if (!eligible) return NO;
    // Sheets can belong to the containing split, tab, or outer navigation
    // controller rather than the pane itself. Never navigate behind one.
    for (UIViewController *parent = navigation.parentViewController; parent; parent = parent.parentViewController) {
        if (parent.presentedViewController || parent.isBeingDismissed || parent.transitionCoordinator) return NO;
    }
    return YES;
}

static BOOL ApolloDuoBackSwipeAcceptsPoint(UINavigationController *navigation, CGPoint point) {
    if (!ApolloDuoBackSwipeCanNavigate(navigation)) return NO;
    UIView *view = navigation.view;
    CGRect pane = ApolloDuoSplitContentFrame(navigation, view);
    if (CGRectIsNull(pane)) {
        CGRect safe = view.safeAreaLayoutGuide.layoutFrame;
        // A full-width landscape screen can inset content for a camera or
        // rounded corner. Back still begins at its physical left edge.
        pane = CGRectMake(CGRectGetMinX(view.bounds), CGRectGetMinY(safe),
                          CGRectGetWidth(view.bounds), CGRectGetHeight(safe));
    }
    if (CGRectIsEmpty(pane) || !CGRectContainsPoint(pane, point)) return NO;
    return point.x <= CGRectGetMinX(pane) + 28.0;
}

BOOL ApolloDuoPaneBackIsNative(UINavigationController *navigation) {
    return !ApolloDuoSplitIsResizing() && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && ApolloDuoSplitPopRevealsContent(navigation);
}

static ApolloDuoBackRoute ApolloDuoPaneBackRoute(UINavigationController *navigation) {
    return ApolloDuoBackRouteFor(ApolloDuoBackSwipeCanNavigate(navigation),
                                 ApolloDuoPaneBackIsNative(navigation),
                                 ApolloDuoSplitCanRevealPostsListWithSwipe(navigation),
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
@end

static NSHashTable<ApolloDuoBackSwipe *> *sDuoPaneDrags;

@implementation ApolloDuoBackSwipe
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    return gesture == self.pan
        && ApolloDuoBackSwipeAcceptsPoint(self.navigation, [touch locationInView:self.navigation.view]);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
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
    return gesture == self.pan && [other isKindOfClass:UIPanGestureRecognizer.class]
        && !ApolloDuoIsScrollPan(other) && other != ApolloDuoNativeBackPan(self.navigation);
}
- (void)cancel {
    UIGestureRecognizerState state = self.pan.state;
    if (state != UIGestureRecognizerStateBegan && state != UIGestureRecognizerStateChanged) return;
    self.pan.enabled = NO;
    self.pan.enabled = YES;
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
                [self cancel];
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
            // A Back only the split lays out has no surface to follow the
            // finger; run it as soon as the drag is clearly a Back.
            [navigation popViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()];
            self.route = ApolloDuoBackRouteNone;
            break;
        default:
            self.route = ApolloDuoBackRouteNone;
            break;
    }
}
- (void)track:(UINavigationController *)navigation dx:(CGFloat)dx {
    if (self.route == ApolloDuoBackRouteDrawer) {
        ApolloDuoSplitMoveListDrag(navigation, self.start + dx);
    } else if (self.route == ApolloDuoBackRouteCloseThread) {
        ApolloDuoSplitDragThread(navigation, ApolloDuoDragClamp(self.start + dx, ApolloDuoSplitThreadDragTravel(navigation)));
    }
}
- (void)finish:(UINavigationController *)navigation dx:(CGFloat)dx velocity:(CGFloat)vx cancelled:(BOOL)cancelled {
    ApolloDuoBackRoute route = self.route;
    self.route = ApolloDuoBackRouteNone;
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
    objc_setAssociatedObject(navigation, &kApolloDuoBackSwipe, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation.view addGestureRecognizer:pan];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDuoPaneDrags = [NSHashTable weakObjectsHashTable];
        // Backgrounding mid-drag (Control Center, a call) springs it back.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { ApolloDuoCancelPaneDrags(); }];
    });
    [sDuoPaneDrags addObject:owner];
}
