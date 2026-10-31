#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import "ApolloDuoSplitDivider.h"

// UIKit, as much of it as the divider's press and drag touches.
@protocol UIGestureRecognizerDelegate <NSObject> @end
typedef NSInteger UIGestureRecognizerState;
enum { UIGestureRecognizerStatePossible = 0,
       UIGestureRecognizerStateBegan = 1, UIGestureRecognizerStateChanged = 2, UIGestureRecognizerStateEnded = 3,
       UIGestureRecognizerStateCancelled = 4, UIGestureRecognizerStateFailed = 5 };
// QuartzCore loads with Foundation on macOS; the stub layer takes its own name.
#define CALayer TestLayer
@interface CALayer : NSObject
@property(nonatomic) CGFloat cornerRadius;
@end
@implementation CALayer @end
@interface UIColor : NSObject
+ (UIColor *)opaqueSeparatorColor;
@end
@implementation UIColor
+ (UIColor *)opaqueSeparatorColor { return [UIColor new]; }
@end
@class UIGestureRecognizer;
@interface UIView : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGPoint center;
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, strong) NSMutableArray<UIView *> *subviews;
@property(nonatomic, strong) NSMutableArray<UIGestureRecognizer *> *gestureRecognizers;
@property(nonatomic, copy) NSArray *interactions;
@property(nonatomic, strong) UIColor *backgroundColor;
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic, getter=isUserInteractionEnabled) BOOL userInteractionEnabled;
- (instancetype)initWithFrame:(CGRect)frame;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture;
@end
@interface UITouch : NSObject
@property(nonatomic) CGPoint point;
@property(nonatomic, strong) UIView *view;
- (CGPoint)locationInView:(UIView *)view;
@end
@implementation UITouch
- (CGPoint)locationInView:(__unused UIView *)view { return self.point; }
@end
@interface UIGestureRecognizer : NSObject
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) id<UIGestureRecognizerDelegate> delegate;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) UIGestureRecognizerState state;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic) NSUInteger disables, failureRequirements;
@property(nonatomic) CGPoint location;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (CGPoint)locationInView:(UIView *)view;
- (void)requireGestureRecognizerToFail:(UIGestureRecognizer *)other;
- (void)reset;
@end
@implementation UIGestureRecognizer
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super init])) { _enabled = YES; _target = target; _action = action; }
    return self;
}
// UIKit cancels a recognizer that is disabled while it tracks a touch.
- (void)setEnabled:(BOOL)enabled {
    if (!enabled) {
        self.disables++;
        if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged)
            self.state = UIGestureRecognizerStateCancelled;
    }
    _enabled = enabled;
}
- (CGPoint)locationInView:(__unused UIView *)view { return self.location; }
- (void)requireGestureRecognizerToFail:(__unused UIGestureRecognizer *)other { self.failureRequirements++; }
- (void)reset { self.state = UIGestureRecognizerStatePossible; }
@end
@interface UILongPressGestureRecognizer : UIGestureRecognizer
@property(nonatomic) NSTimeInterval minimumPressDuration;
@property(nonatomic) CGFloat allowableMovement;
@end
@implementation UILongPressGestureRecognizer @end
@implementation UIView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super init])) {
        _subviews = [NSMutableArray array];
        _layer = [CALayer new];
        _userInteractionEnabled = YES;
        [self setFrame:frame];
    }
    return self;
}
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (void)setFrame:(CGRect)frame {
    _frame = frame;
    _bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    _center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}
- (void)setCenter:(CGPoint)center {
    _center = center;
    _frame.origin = CGPointMake(center.x - _frame.size.width / 2, center.y - _frame.size.height / 2);
}
- (void)addSubview:(UIView *)view {
    [view removeFromSuperview];
    [self.subviews addObject:view];
    view.superview = self;
}
- (void)removeFromSuperview {
    [self.superview.subviews removeObject:self];
    self.superview = nil;
}
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture {
    if (!self.gestureRecognizers) self.gestureRecognizers = [NSMutableArray array];
    [self.gestureRecognizers addObject:gesture];
    gesture.view = self;
}
@end

// A row: the table or collection cell the band touch lit.
@interface UITableViewCell : UIView
@property(nonatomic) BOOL highlighted;
@property(nonatomic) NSUInteger unhighlights;
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated;
@end
@implementation UITableViewCell
- (void)setHighlighted:(BOOL)highlighted animated:(__unused BOOL)animated {
    if (!highlighted) self.unhighlights++;
    _highlighted = highlighted;
}
@end
@interface UICollectionViewCell : UIView
@property(nonatomic, getter=isHighlighted) BOOL highlighted;
@end
@implementation UICollectionViewCell @end
// The render commit the split's picture waits for.
#define CATransaction TestTransaction
@interface CATransaction : NSObject
+ (void)flush;
@end
static NSUInteger flushes;
@implementation CATransaction
+ (void)flush { flushes++; }
@end
@interface UIContextMenuInteraction : NSObject @end
@implementation UIContextMenuInteraction @end
// What the divider logs.
static NSUInteger logs;
#define ApolloLog(...) (logs++)

// The clock the drag reads its speed from.
static CFTimeInterval testNow;
static CFTimeInterval CACurrentMediaTime(void) { return testNow; }

// The split's side of the drag, recorded.
static BOOL testAdjustable = YES;
static CGFloat testDivider = 475.5;
static BOOL testBegins = YES, testUpdates = YES;
static NSUInteger begins, cancels, finishes;
static NSMutableArray<NSNumber *> *updates;
static CGFloat finishedAt, finishedVelocity;
static BOOL draggingAtFinish, grabberAtFinish;
static UIView *testHost;
static CGFloat ApolloDuoSplitDividerPosition(__unused UIView *host, BOOL *adjustable) {
    if (adjustable) *adjustable = testAdjustable;
    return testDivider;
}
// What the touched row looks like when the split takes its picture.
static UITableViewCell *testRow;
static BOOL rowLitAtBegin;
static NSUInteger flushesAtBegin;
static BOOL ApolloDuoSplitDividerBegin(__unused UIView *host) {
    begins++;
    rowLitAtBegin = testRow.highlighted;
    flushesAtBegin = flushes;
    return testBegins;
}
static BOOL ApolloDuoSplitDividerUpdate(__unused UIView *host, CGFloat dividerX) {
    [updates addObject:@(dividerX)];
    if (!testUpdates) ApolloDuoSplitDividerLetGo(testHost);
    return testUpdates;
}
static void ApolloDuoSplitDividerCancel(UIView *host);
static void ApolloDuoSplitDividerFinish(UIView *host, CGFloat dividerX, CGFloat velocityX);

// INCLUDE_PRODUCTION_SPLIT_DIVIDER

static void ApolloDuoSplitDividerCancel(__unused UIView *host) { cancels++; }
static void ApolloDuoSplitDividerFinish(UIView *host, CGFloat dividerX, CGFloat velocityX) {
    finishes++;
    finishedAt = dividerX;
    finishedVelocity = velocityX;
    ApolloDuoSplitDivider *divider = objc_getAssociatedObject(host, &kApolloDuoSplitDividerKey);
    draggingAtFinish = divider.dragging;
    grabberAtFinish = host.subviews.count > 0;
}

static NSUInteger checks;
static void Check(BOOL valid, NSString *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static BOOL Near(CGFloat a, CGFloat b) { return fabs(a - b) < 0.0001; }

static UIView *NewHost(void) {
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 951, 900)];
    ApolloDuoSplitDividerInstall(host);
    testHost = host;
    return host;
}
static UILongPressGestureRecognizer *PressOf(UIView *host) {
    return (UILongPressGestureRecognizer *)host.gestureRecognizers.firstObject;
}
static ApolloDuoSplitDivider *DividerOf(UIView *host) {
    return objc_getAssociatedObject(host, &kApolloDuoSplitDividerKey);
}
static void Reset(void) {
    testAdjustable = YES; testDivider = 475.5; testBegins = YES; testUpdates = YES;
    begins = cancels = finishes = 0;
    updates = [NSMutableArray array];
    finishedAt = finishedVelocity = 0;
    draggingAtFinish = grabberAtFinish = NO;
    testNow = 100.0;
}
// Touch down at `x`, hold, and let the press begin.
static BOOL PressAt(UIView *host, CGFloat x) {
    UILongPressGestureRecognizer *press = PressOf(host);
    ApolloDuoSplitDivider *divider = DividerOf(host);
    UITouch *touch = [UITouch new];
    touch.point = CGPointMake(x, 300);
    if (![divider gestureRecognizer:press shouldReceiveTouch:(id)touch]) return NO;
    press.location = touch.point;
    if (![divider gestureRecognizerShouldBegin:press]) return NO;
    press.state = UIGestureRecognizerStateBegan;
    [divider pressed:press];
    return YES;
}
static void MoveTo(UIView *host, CGFloat x, CFTimeInterval at) {
    UILongPressGestureRecognizer *press = PressOf(host);
    testNow = at;
    press.location = CGPointMake(x, 300);
    press.state = UIGestureRecognizerStateChanged;
    [DividerOf(host) pressed:press];
}
static void Release(UIView *host, UIGestureRecognizerState state, CFTimeInterval at) {
    UILongPressGestureRecognizer *press = PressOf(host);
    testNow = at;
    press.state = state;
    [DividerOf(host) pressed:press];
}
static UIView *Grabber(UIView *host) { return host.subviews.lastObject; }

int main(void) {
    @autoreleasepool {
        // Admission: only a still press on the divider of a thread beside the feed.
        Check(!ApolloDuoSplitDividerShouldBegin(NO, YES, 475.5, 475.5, 0), @"admission: the setting off leaves the divider to UIKit");
        Check(!ApolloDuoSplitDividerShouldBegin(YES, NO, 475.5, 475.5, 0), @"admission: no thread beside the feed, no divider to move");
        Check(!ApolloDuoSplitDividerShouldBegin(YES, YES, 488.5, 475.5, 0)
              && !ApolloDuoSplitDividerShouldBegin(YES, YES, 462.5, 475.5, 0),
              @"admission: 13pt either side of the divider is the pane's, not the divider's");
        Check(ApolloDuoSplitDividerShouldBegin(YES, YES, 487.5, 475.5, 0)
              && ApolloDuoSplitDividerShouldBegin(YES, YES, 463.5, 475.5, 0),
              @"admission: within 12pt either side of the divider");
        Check(!ApolloDuoSplitDividerShouldBegin(YES, YES, 475.5, 475.5, 11)
              && !ApolloDuoSplitDividerShouldBegin(YES, YES, 475.5, 475.5, 10),
              @"admission: a touch that moved a tap's jitter is a swipe (Back, close, drawer), never the divider");
        Check(ApolloDuoSplitDividerShouldBegin(YES, YES, 476, 475.5, 3), @"admission: a still press on the divider moves it");
        Check(ApolloDuoSplitDividerShouldBegin(YES, YES, 8, 0, 0) && !ApolloDuoSplitDividerShouldBegin(YES, YES, 13, 0, 0),
              @"admission: with the post over the feed the divider is at the screen's edge, the same band");

        // The finger's speed: each move eased into the last, none once it stops.
        Check(Near(ApolloDuoSplitDividerVelocity(0, 400, 1.0, 410, 1.01), 600), @"velocity: a first move's speed, eased in");
        Check(Near(ApolloDuoSplitDividerVelocity(1000, 400, 1.0, 410, 1.01), 1000), @"velocity: a steady move keeps its speed");
        Check(Near(ApolloDuoSplitDividerVelocity(500, 400, 1.0, 410, 1.0), 500), @"velocity: no time between samples changes nothing");
        Check(Near(ApolloDuoSplitDividerReleaseVelocity(800, 1.0, 1.05), 800), @"velocity: a lift while moving keeps the speed");
        Check(Near(ApolloDuoSplitDividerReleaseVelocity(800, 1.0, 1.2), 0), @"velocity: a finger that stopped before lifting flicks nothing");

        // The recognizer: a still press, named, never anyone's failure requirement.
        Reset();
        UIView *host = NewHost();
        ApolloDuoSplitDividerInstall(host);
        UILongPressGestureRecognizer *press = PressOf(host);
        Check(host.gestureRecognizers.count == 1, @"install: once per host");
        Check([press isKindOfClass:UILongPressGestureRecognizer.class] && Near(press.minimumPressDuration, 0.25)
              && Near(press.allowableMovement, 10), @"install: a 0.25s press that a 10pt move fails");
        Check([press.name isEqualToString:@"ApolloReborn.Duo.SplitDivider"] && press.delegate == (id)DividerOf(host),
              @"install: named with the Duo prefix, decided by the divider");
        Check(press.failureRequirements == 0, @"install: the pane gestures never wait on the divider");

        // UIKit's context menus wait for the press inside the band; nothing else does.
        // The names on a feed row's view, as UIKit 27.1 installs them.
        Check(ApolloDuoSplitDividerOutranks(@"com.apple.UIKit.longPressClickDriverPrimary")
              && ApolloDuoSplitDividerOutranks(@"com.apple.UIKit.clickPresentationExclusion")
              && ApolloDuoSplitDividerOutranks(@"com.apple.UIKit.clickPresentationFailure"),
              @"context menu: UIKit's touch-and-hold driver and click presentation are held off");
        Check(!ApolloDuoSplitDividerOutranks(@"com.apple.UIKit.keyPressClickDriverPrimary")
              && !ApolloDuoSplitDividerOutranks(@"com.apple.UIKit.UISplitViewController.ColumnResizeDirectPanGestureRecognizer"),
              @"context menu: a keyboard press and the split's own gestures are not");
        Check(!ApolloDuoSplitDividerOutranks(@"ApolloReborn.Duo.PaneBack") && !ApolloDuoSplitDividerOutranks(@"ApolloReborn.Duo.DragClaim")
              && !ApolloDuoSplitDividerOutranks(nil) && !ApolloDuoSplitDividerOutranks(@"com.apple.UIKit.ContextMenuDismissalTap"),
              @"context menu: pane gestures, scrolling (unnamed) and other UIKit gestures never wait");
        // A feed row under the band: its context menu, the pane Back on its
        // navigation, and a menu something else already turned off.
        UIView *navigationView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 951, 900)];
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 200, 475, 120)];
        [host addSubview:navigationView];
        [navigationView addSubview:row];
        UIGestureRecognizer *menu = [[UIGestureRecognizer alloc] initWithTarget:nil action:NULL];
        menu.name = @"com.apple.UIKit.longPressClickDriverPrimary";
        UIGestureRecognizer *exclusion = [[UIGestureRecognizer alloc] initWithTarget:nil action:NULL];
        exclusion.name = @"com.apple.UIKit.clickPresentationExclusion";
        UIGestureRecognizer *offMenu = [[UIGestureRecognizer alloc] initWithTarget:nil action:NULL];
        offMenu.name = @"com.apple.UIKit.longPressClickDriverPrimary";
        offMenu.enabled = NO;
        UIGestureRecognizer *paneBack = [[UIGestureRecognizer alloc] initWithTarget:nil action:NULL];
        paneBack.name = @"ApolloReborn.Duo.PaneBack";
        UIGestureRecognizer *scroll = [[UIGestureRecognizer alloc] initWithTarget:nil action:NULL];
        [row addGestureRecognizer:menu];
        [row addGestureRecognizer:exclusion];
        [row addGestureRecognizer:offMenu];
        [row addGestureRecognizer:scroll];
        [navigationView addGestureRecognizer:paneBack];
        UITouch *rowTouch = [UITouch new];
        rowTouch.view = row;
        rowTouch.point = CGPointMake(440, 300);
        Check(![DividerOf(host) gestureRecognizer:press shouldReceiveTouch:(id)rowTouch] && menu.enabled && exclusion.enabled,
              @"context menu: a touch outside the band leaves the row's menu alone");
        rowTouch.point = CGPointMake(470, 300);
        Check([DividerOf(host) gestureRecognizer:press shouldReceiveTouch:(id)rowTouch], @"context menu: a band touch on a row is the divider's");
        Check(!menu.enabled && !exclusion.enabled, @"context menu: the row's touch and hold is held off while the band touch is down");
        Check(paneBack.enabled && scroll.enabled && paneBack.disables == 0 && scroll.disables == 0,
              @"context menu: the pane Back and scrolling are never touched");
        [press reset];
        Check(menu.enabled && exclusion.enabled && !offMenu.enabled,
              @"context menu: the touch's end gives back only the menus the divider turned off");
        // A row whose context menu UIKit drives with recognizers the divider
        // doesn't know by name (a rename): logged, so it shows up.
        row.interactions = @[ [UIContextMenuInteraction new] ];
        NSUInteger logged = logs;
        [DividerOf(host) gestureRecognizer:press shouldReceiveTouch:(id)rowTouch];
        Check(logs == logged, @"context menu: a menu the divider holds off is not logged");
        [press reset];
        menu.name = @"com.apple.UIKit.renamedClickDriver";
        exclusion.name = @"com.apple.UIKit.renamedRelationship";
        [DividerOf(host) gestureRecognizer:press shouldReceiveTouch:(id)rowTouch];
        Check(logs == logged + 1 && menu.enabled, @"context menu: one it can't find is logged once for the touch");
        [press reset];
        [row removeFromSuperview];
        [navigationView removeFromSuperview];

        // A row the table lit under the band touch drops its tint when the hold
        // begins, and that frame is committed before the split takes its picture.
        UITableViewCell *litRow = [[UITableViewCell alloc] initWithFrame:CGRectMake(0, 200, 475, 120)];
        UIView *rowContent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 475, 120)];
        [host addSubview:litRow];
        [litRow addSubview:rowContent];
        litRow.highlighted = YES;
        testRow = litRow;
        UITouch *litTouch = [UITouch new];
        litTouch.view = rowContent;
        litTouch.point = CGPointMake(470, 300);
        Reset();
        flushes = 0;
        Check([DividerOf(host) gestureRecognizer:press shouldReceiveTouch:(id)litTouch], @"row tint: a band touch on a row is the divider's");
        Check(litRow.highlighted && litRow.unhighlights == 0, @"row tint: the touch alone leaves the row as the table lit it");
        press.location = litTouch.point;
        press.state = UIGestureRecognizerStateBegan;
        [DividerOf(host) pressed:press];
        Check(!litRow.highlighted && litRow.unhighlights == 1, @"row tint: the hold's beginning drops the row's tint");
        Check(begins == 1 && !rowLitAtBegin && flushesAtBegin == 1 && flushes == 1,
              @"row tint: the tint is gone and committed before the split's picture, not after");
        Release(host, UIGestureRecognizerStateEnded, 100.5);
        [press reset];
        // No row under the touch, and a touch that never becomes a hold: nothing to drop.
        Reset();
        flushes = 0;
        litRow.highlighted = YES;
        litRow.unhighlights = 0;
        litTouch.view = host;
        Check([DividerOf(host) gestureRecognizer:press shouldReceiveTouch:(id)litTouch], @"row tint: a band touch off any row is the divider's");
        press.location = litTouch.point;
        press.state = UIGestureRecognizerStateBegan;
        [DividerOf(host) pressed:press];
        Check(litRow.highlighted && litRow.unhighlights == 0 && flushes == 0, @"row tint: with no row under the touch no other row is touched");
        Release(host, UIGestureRecognizerStateEnded, 100.5);
        [press reset];
        [litRow removeFromSuperview];
        testRow = nil;
        Reset();

        // Touch-down: the same admission, at the live divider.
        ApolloDuoSplitDivider *divider = DividerOf(host);
        UITouch *touch = [UITouch new];
        touch.point = CGPointMake(470, 300);
        Check([divider gestureRecognizer:press shouldReceiveTouch:(id)touch], @"touch: on the divider it is the divider's");
        touch.point = CGPointMake(440, 300);
        Check(![divider gestureRecognizer:press shouldReceiveTouch:(id)touch], @"touch: away from the divider the press never starts");
        testAdjustable = NO;
        touch.point = CGPointMake(475, 300);
        Check(![divider gestureRecognizer:press shouldReceiveTouch:(id)touch], @"touch: the setting off leaves the divider alone");
        testAdjustable = YES;
        testDivider = -1;
        Check(![divider gestureRecognizer:press shouldReceiveTouch:(id)touch], @"touch: no thread beside the feed");
        testDivider = 475.5;
        Check([divider gestureRecognizer:press shouldReceiveTouch:(id)touch], @"touch: back on the divider");
        press.location = CGPointMake(486, 300);
        Check(![divider gestureRecognizerShouldBegin:press], @"begin: a press that drifted 11pt is no divider drag");

        // Begin: the split covers the columns and the grabber shows on the divider.
        Check(!ApolloDuoSplitDividerHolding(host), @"holding: no press, no drag held");
        Check(PressAt(host, 480) && begins == 1 && divider.dragging, @"begin: the split's drag begins");
        Check(ApolloDuoSplitDividerHolding(host), @"holding: a begun press holds its drag through routine split updates");
        Check(!ApolloDuoSplitDividerHolding([[UIView alloc] initWithFrame:CGRectZero]) && !ApolloDuoSplitDividerHolding(nil),
              @"holding: a host without the divider holds nothing");
        UIView *grabber = Grabber(host);
        Check(host.subviews.count == 1 && Near(grabber.center.x, 475.5) && !grabber.userInteractionEnabled,
              @"begin: the grabber shows centered on the divider and takes no touches");
        Check(Near(CGRectGetWidth(grabber.frame), 4) && Near(CGRectGetHeight(grabber.frame), 900) && Near(grabber.layer.cornerRadius, 2),
              @"begin: a thicker divider, the host's height, rounded ends");
        // The divider follows the finger from where it was grabbed.
        MoveTo(host, 600, 100.10);
        Check(updates.count == 1 && Near(updates.lastObject.doubleValue, 595.5) && Near(Grabber(host).center.x, 595.5),
              @"drag: the divider keeps the finger's offset from where it was grabbed, the grabber with it");
        MoveTo(host, -80, 100.12);
        Check(Near(updates.lastObject.doubleValue, 0) && Near(Grabber(host).center.x, 0), @"drag: never past the leading edge");
        MoveTo(host, 1200, 100.14);
        Check(Near(updates.lastObject.doubleValue, 951), @"drag: never past the trailing edge");
        MoveTo(host, 720, 100.16);
        MoveTo(host, 735, 100.17);
        // Release: drag state and grabber gone before the split acts on it.
        Release(host, UIGestureRecognizerStateEnded, 100.18);
        Check(finishes == 1 && Near(finishedAt, 730.5) && finishedVelocity > 500,
              @"release: the split gets where the divider was let go and the flick's speed");
        Check(!draggingAtFinish && !grabberAtFinish, @"release: the drag is cleared and the grabber gone before the split snaps or closes");
        Check(cancels == 0 && !divider.dragging && host.subviews.count == 0, @"release: nothing left behind");
        Check(!ApolloDuoSplitDividerHolding(host), @"holding: a released press holds nothing, so a stale drag is swept");

        // A still lift: no flick.
        Reset();
        Check(PressAt(host, 475), @"still lift: began");
        MoveTo(host, 300, 100.10);
        Release(host, UIGestureRecognizerStateEnded, 100.40);
        Check(finishes == 1 && Near(finishedAt, 300.5) && Near(finishedVelocity, 0), @"still lift: snaps by position alone");

        // The split refuses (a column change, another drag): no grabber, no drag.
        Reset();
        testBegins = NO;
        Check(PressAt(host, 475) && begins == 1 && !divider.dragging && host.subviews.count == 0,
              @"refused: no grabber when the split can't cover the columns");
        Check(press.disables == 1, @"refused: the press ends at once, so its release does nothing");
        MoveTo(host, 600, 100.1);
        Release(host, UIGestureRecognizerStateEnded, 100.2);
        Check(updates.count == 0 && finishes == 0 && cancels == 0, @"refused: the rest of the press is ignored");

        // The system cancels the press: the split removes its drag.
        Reset();
        press.disables = 0;
        Check(PressAt(host, 475), @"cancelled: began");
        Release(host, UIGestureRecognizerStateCancelled, 100.1);
        Check(cancels == 1 && finishes == 0 && !divider.dragging && host.subviews.count == 0,
              @"cancelled: the split removes its drag, the grabber goes, nothing is remembered");
        Check(!ApolloDuoSplitDividerHolding(host), @"holding: a cancelled press holds nothing");

        // The split lets the drag go mid-move (the thread closed, the setting turned off).
        Reset();
        press.disables = 0;
        Check(PressAt(host, 475), @"let go: began");
        testUpdates = NO;
        MoveTo(host, 520, 100.1);
        Check(!divider.dragging && host.subviews.count == 0 && press.disables == 1,
              @"let go: an update the split refuses removes the grabber and ends the press");
        Release(host, UIGestureRecognizerStateEnded, 100.2);
        Check(finishes == 0 && cancels == 0, @"let go: its release is no snap");

        // An interruption with the finger still (a fold, a tab switch, a sheet, resigning).
        Reset();
        press.disables = 0;
        press.state = UIGestureRecognizerStatePossible;
        Check(PressAt(host, 475), @"interrupted: began");
        ApolloDuoSplitDividerLetGo(host);
        Check(!divider.dragging && host.subviews.count == 0 && press.disables == 1 && press.enabled,
              @"interrupted: the grabber goes at once and the press is reset, still enabled for the next one");
        Check(!ApolloDuoSplitDividerHolding(host), @"holding: a press let go holds nothing");
        Release(host, UIGestureRecognizerStateCancelled, 100.2);
        Check(cancels == 0 && finishes == 0, @"interrupted: the split already removed its drag; nothing more happens");
        ApolloDuoSplitDividerLetGo(host);
        Check(press.disables == 1, @"interrupted: letting go twice is harmless");

        // A second finger never restarts a drag in progress.
        Reset();
        Check(PressAt(host, 475), @"second finger: began");
        touch.point = CGPointMake(476, 500);
        Check(![divider gestureRecognizer:press shouldReceiveTouch:(id)touch], @"second finger: not taken while dragging");
        Release(host, UIGestureRecognizerStateEnded, 100.1);

        // The post over the feed: the divider is at the screen's edge, and the
        // same hold there, dragged right, brings the feed back.
        Reset();
        testDivider = 0;
        Check(PressAt(host, 6) && begins == 1 && divider.dragging && Near(Grabber(host).center.x, 0),
              @"edge: a hold within the band at the screen's edge begins the drag, the grabber at the edge");
        MoveTo(host, 400, 100.10);
        Check(Near(updates.lastObject.doubleValue, 394) && Near(Grabber(host).center.x, 394),
              @"edge: the divider follows the finger in from the edge, keeping its offset");
        Release(host, UIGestureRecognizerStateEnded, 100.11);
        Check(finishes == 1 && Near(finishedAt, 394) && !divider.dragging && host.subviews.count == 0,
              @"edge: the release hands the split where the feed's edge was let go");

        printf("OK: %lu split divider checks\n", (unsigned long)checks);
    }
    return 0;
}
