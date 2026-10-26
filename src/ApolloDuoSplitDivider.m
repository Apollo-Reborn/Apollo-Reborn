#import "ApolloDuoSplitDivider.h"
#import "ApolloDuoSplitView.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// The divider between the Posts feed and the thread beside it, moved with a
// press and drag when Settings > Adjustable Split is on. A still press of a
// quarter second within 12pt of the divider begins it, so a swipe from there
// (the pane Back, the thread close, the drawer, row actions) never does: this
// recognizer fails on a 10pt move, and asks nothing of the pane gestures.
// Here: the admission, the grabber and the finger. The split moves the
// columns (ApolloDuoSplitDivider* in ApolloDuoSplitView.xm): while the finger
// is down only pictures of the columns move, and the columns are laid out
// once, on release.

// The divider's press and drag.
static const CGFloat kApolloDuoSplitDividerReach = 12.0;
static const NSTimeInterval kApolloDuoSplitDividerPressDuration = 0.25;
// A tap's jitter, as the drag claim's: a touch that moved further is a swipe.
static const CGFloat kApolloDuoSplitDividerJitter = 10.0;
// The grabber: the divider, thicker, while the finger holds it.
static const CGFloat kApolloDuoSplitDividerGrabberWidth = 4.0;
// A finger that rested this long before lifting lets go with no flick.
static const CFTimeInterval kApolloDuoSplitDividerStillAfter = 0.08;

BOOL ApolloDuoSplitDividerShouldBegin(BOOL adjustable, BOOL postsLandscapeWithThread, CGFloat touchX,
                                      CGFloat dividerX, CGFloat movedDistance) {
    return adjustable && postsLandscapeWithThread && fabs(touchX - dividerX) <= kApolloDuoSplitDividerReach
        && movedDistance < kApolloDuoSplitDividerJitter;
}

ApolloDuoSplitDividerRelease ApolloDuoSplitDividerReleaseOutcome(ApolloDuoSplitRelease release) {
    if (release.closesThread) return (ApolloDuoSplitDividerRelease){ApolloDuoSplitDividerOutcomeCloseThread, 0};
    if (release.fullScreen) return (ApolloDuoSplitDividerRelease){ApolloDuoSplitDividerOutcomeFullScreen, 0};
    return (ApolloDuoSplitDividerRelease){ApolloDuoSplitDividerOutcomeSnap, release.stop};
}

// The long press reports no speed. Each move's speed is eased into the last
// one, so a single uneven frame doesn't decide a flick.
static CGFloat ApolloDuoSplitDividerVelocity(CGFloat velocity, CGFloat fromX, CFTimeInterval fromTime,
                                             CGFloat toX, CFTimeInterval toTime) {
    CFTimeInterval elapsed = toTime - fromTime;
    if (elapsed <= 0.0) return velocity;
    return 0.6 * (toX - fromX) / elapsed + 0.4 * velocity;
}

static CGFloat ApolloDuoSplitDividerReleaseVelocity(CGFloat velocity, CFTimeInterval lastMove, CFTimeInterval now) {
    return now - lastMove > kApolloDuoSplitDividerStillAfter ? 0.0 : velocity;
}

@interface ApolloDuoSplitDivider : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UILongPressGestureRecognizer *press;
@property(nonatomic, strong) UIView *grabber;
// From the split's Begin until the release, a cancel or the split letting go.
@property(nonatomic) BOOL dragging;
@property(nonatomic) CGPoint touchStart;
// The finger's distance from the divider where it took hold, kept while it moves.
@property(nonatomic) CGFloat grabOffset;
@property(nonatomic) CGFloat divider;
@property(nonatomic) CGFloat velocity;
@property(nonatomic) CFTimeInterval lastMove;
@end

static char kApolloDuoSplitDividerKey;

@implementation ApolloDuoSplitDivider
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    // One finger holds the divider; a second never restarts it.
    if (self.dragging || gesture != self.press) return NO;
    UIView *host = gesture.view;
    CGPoint point = [touch locationInView:host];
    BOOL adjustable = NO;
    CGFloat divider = ApolloDuoSplitDividerPosition(host, &adjustable);
    if (!ApolloDuoSplitDividerShouldBegin(adjustable, divider >= 0.0, point.x, divider, 0.0)) return NO;
    self.touchStart = point;
    return YES;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture != self.press) return NO;
    UIView *host = gesture.view;
    CGPoint point = [gesture locationInView:host];
    BOOL adjustable = NO;
    CGFloat divider = ApolloDuoSplitDividerPosition(host, &adjustable);
    CGFloat moved = hypot(point.x - self.touchStart.x, point.y - self.touchStart.y);
    return ApolloDuoSplitDividerShouldBegin(adjustable, divider >= 0.0, self.touchStart.x, divider, moved);
}
- (CGFloat)dividerAt:(CGFloat)x in:(UIView *)host {
    return MIN(MAX(0.0, x - self.grabOffset), CGRectGetWidth(host.bounds));
}
- (void)pressed:(UILongPressGestureRecognizer *)press {
    UIView *host = press.view;
    CGFloat x = [press locationInView:host].x;
    CFTimeInterval now = CACurrentMediaTime();
    switch (press.state) {
        case UIGestureRecognizerStateBegan: {
            BOOL adjustable = NO;
            CGFloat divider = ApolloDuoSplitDividerPosition(host, &adjustable);
            if (!adjustable || divider < 0.0 || !ApolloDuoSplitDividerBegin(host)) {
                // A column change or another drag got there first.
                [self resetPress];
                return;
            }
            self.dragging = YES;
            self.grabOffset = x - divider;
            self.divider = divider;
            self.velocity = 0.0;
            self.lastMove = now;
            [self showGrabberIn:host];
            return;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.dragging) return;
            CGFloat divider = [self dividerAt:x in:host];
            self.velocity = ApolloDuoSplitDividerVelocity(self.velocity, self.divider, self.lastMove, divider, now);
            self.divider = divider;
            self.lastMove = now;
            // The thread closed, the setting turned off, the columns changed.
            if (!ApolloDuoSplitDividerUpdate(host, divider)) {
                [self letGo];
                return;
            }
            self.grabber.center = CGPointMake(divider, self.grabber.center.y);
            return;
        }
        case UIGestureRecognizerStateEnded: {
            if (!self.dragging) return;
            CGFloat divider = [self dividerAt:x in:host];
            if (divider != self.divider) {
                self.velocity = ApolloDuoSplitDividerVelocity(self.velocity, self.divider, self.lastMove, divider, now);
                self.lastMove = now;
            }
            CGFloat velocity = ApolloDuoSplitDividerReleaseVelocity(self.velocity, self.lastMove, now);
            // Cleared first: the split's snap, close or full screen runs with no drag left.
            [self endDrag];
            ApolloDuoSplitDividerFinish(host, divider, velocity);
            return;
        }
        default:
            // Cancelled by the system (a second finger, resigning) or failed.
            if (!self.dragging) return;
            [self endDrag];
            ApolloDuoSplitDividerCancel(host);
            return;
    }
}
- (void)showGrabberIn:(UIView *)host {
    UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake(self.divider - kApolloDuoSplitDividerGrabberWidth / 2.0, 0,
                                                               kApolloDuoSplitDividerGrabberWidth, CGRectGetHeight(host.bounds))];
    grabber.backgroundColor = UIColor.opaqueSeparatorColor;
    grabber.layer.cornerRadius = kApolloDuoSplitDividerGrabberWidth / 2.0;
    grabber.userInteractionEnabled = NO;
    [host addSubview:grabber];
    self.grabber = grabber;
}
- (void)endDrag {
    self.dragging = NO;
    [self.grabber removeFromSuperview];
    self.grabber = nil;
}
// Ends the press at once, so the rest of its touch is no release.
- (void)resetPress {
    self.press.enabled = NO;
    self.press.enabled = YES;
}
- (void)letGo {
    if (!self.dragging) return;
    [self endDrag];
    [self resetPress];
}
@end

void ApolloDuoSplitDividerInstall(UIView *host) {
    if (!host || objc_getAssociatedObject(host, &kApolloDuoSplitDividerKey)) return;
    ApolloDuoSplitDivider *divider = [ApolloDuoSplitDivider new];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:divider action:@selector(pressed:)];
    press.minimumPressDuration = kApolloDuoSplitDividerPressDuration;
    press.allowableMovement = kApolloDuoSplitDividerJitter;
    press.name = @"ApolloReborn.Duo.SplitDivider";
    press.delegate = divider;
    divider.press = press;
    objc_setAssociatedObject(host, &kApolloDuoSplitDividerKey, divider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addGestureRecognizer:press];
}

BOOL ApolloDuoSplitDividerHolding(UIView *host) {
    ApolloDuoSplitDivider *divider = host ? objc_getAssociatedObject(host, &kApolloDuoSplitDividerKey) : nil;
    return divider.dragging && divider.press.view == host;
}

void ApolloDuoSplitDividerLetGo(UIView *host) {
    ApolloDuoSplitDivider *divider = host ? objc_getAssociatedObject(host, &kApolloDuoSplitDividerKey) : nil;
    [divider letGo];
}
