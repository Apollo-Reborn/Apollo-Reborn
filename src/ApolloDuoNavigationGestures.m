#import "ApolloDuoNavigationGestures.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>

// Apollo's pans use the whole navigation surface for edge checks. On Duo a
// visible pane can start well inside that surface, and the outer stack is a
// containment host. Qualify a right swipe at the *pane's* left content edge,
// then perform one native animated Back on that exact navigation controller.
// At the feed root the same gesture reveals the subreddit drawer. Calling the
// native pop entry point keeps the author's feed/thread restoration animation.
// Keep row swipe actions elsewhere, and honor Apollo's navigation-gesture opt-out.
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

// Gestures > Disable Left Swipes turns off the row actions a right swipe would
// trigger, and Apollo's own Back pan then starts anywhere on the page. Give a
// Duo pane the same reach; with the setting off only the edge strip qualifies.
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

// Away from the edge strip, content with its own sideways drag keeps it: a
// gallery or carousel that can still page back, and sliders/switches.
static BOOL ApolloDuoBackSwipeTouchOwnsHorizontalDrag(UIView *view, UIView *container) {
    for (UIView *candidate = view; candidate && candidate != container; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UISlider.class] || [candidate isKindOfClass:UISwitch.class]) return YES;
        if (![candidate isKindOfClass:UIScrollView.class]) continue;
        UIScrollView *scroll = (UIScrollView *)candidate;
        if (scroll.scrollEnabled && scroll.contentSize.width > CGRectGetWidth(scroll.bounds) + 1.0
            && scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5) return YES;
    }
    return NO;
}

@interface ApolloDuoBackSwipe : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UINavigationController *navigation;
@property(nonatomic, strong) UISwipeGestureRecognizer *swipe;
@end

@implementation ApolloDuoBackSwipe
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    UINavigationController *navigation = self.navigation;
    CGPoint point = [touch locationInView:navigation.view];
    if (gesture != self.swipe || !ApolloDuoBackSwipeAcceptsPoint(navigation, point)) return NO;
    return ApolloDuoBackSwipeInEdgeStrip(ApolloDuoBackSwipePane(navigation), point)
        || !ApolloDuoBackSwipeTouchOwnsHorizontalDrag(touch.view, navigation.view);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return gesture == self.swipe && ApolloDuoBackSwipeCanNavigate(self.navigation);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Vertical table scrolling should not wait for a discrete right swipe.
    return gesture == self.swipe && [other.view isKindOfClass:UIScrollView.class]
        && other == ((UIScrollView *)other.view).panGestureRecognizer;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // At the narrow edge strip, give Back priority over horizontal row actions.
    // Away from that strip shouldReceiveTouch: rejects this recognizer outright
    // unless Disable Left Swipes has already turned those row actions off.
    BOOL scrollPan = [other.view isKindOfClass:UIScrollView.class]
        && other == ((UIScrollView *)other.view).panGestureRecognizer;
    return gesture == self.swipe && [other isKindOfClass:UIPanGestureRecognizer.class] && !scrollPan;
}
- (void)swiped:(UISwipeGestureRecognizer *)gesture {
    UINavigationController *navigation = self.navigation;
    if (gesture.state != UIGestureRecognizerStateRecognized || !ApolloDuoBackSwipeCanNavigate(navigation)) return;
    if (navigation.viewControllers.count == 1) {
        ApolloLog(@"[DuoSwipe] feed root: reveal subreddit drawer");
        ApolloDuoSplitRevealPostsList(navigation);
        return;
    }
    ApolloLog(@"[DuoSwipe] Back in pane; stack pages=%lu", (unsigned long)navigation.viewControllers.count);
    [navigation popViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()];
}
@end

static char kApolloDuoBackSwipe;
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
    objc_setAssociatedObject(navigation, &kApolloDuoBackSwipe, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation.view addGestureRecognizer:swipe];
}
