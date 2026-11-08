#import "ApolloDuoSplitDivider.h"
#import "ApolloDuoDividerGeometry.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"

@interface ApolloDuoSplitDivider () <UIGestureRecognizerDelegate>
@property(nonatomic) BOOL dragging;
@property(nonatomic) BOOL available;
@property(nonatomic) CGFloat divider;
@property(nonatomic) CGFloat trailingInset;
@property(nonatomic) CGFloat startingWidth;
@property(nonatomic) CGFloat touchOffset;
@property(nonatomic) CGSize startingSize;
@property(nonatomic) int lastTick;
@property(nonatomic) int lastLimit;
@property(nonatomic) CGFloat lastSnap;
@property(nonatomic) CFTimeInterval lastFeedback;
@property(nonatomic, strong) UILongPressGestureRecognizer *press;
@property(nonatomic, strong) UIView *scrim;
@property(nonatomic, strong) UIView *guide;
@property(nonatomic, strong) UIView *liftedGrip;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UIImpactFeedbackGenerator *impact;
@property(nonatomic, strong) UISelectionFeedbackGenerator *selection;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) CGFloat appliedWidth;
@end

@implementation ApolloDuoSplitDivider
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Feed and thread divider";
        self.accessibilityTraits = UIAccessibilityTraitAdjustable;
        self.accessibilityCustomActions = @[[[UIAccessibilityCustomAction alloc] initWithName:@"Equal widths" target:self selector:@selector(resetWidth)]];
        self.press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pressed:)];
        self.press.minimumPressDuration = 0.25;
        self.press.allowableMovement = 10;
        self.press.delegate = self;
        [self addGestureRecognizer:self.press];
        UITapGestureRecognizer *reset = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
        reset.numberOfTapsRequired = 2;
        reset.delegate = self;
        [reset requireGestureRecognizerToFail:self.press];
        [self addGestureRecognizer:reset];
        self.accessibilityHint = @"Swipe up or down to change the feed width. Use the Equal widths action to restore the default.";
        self.impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        self.selection = [UISelectionFeedbackGenerator new];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cancel) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self cancel];
}
- (void)drawRect:(CGRect)rect {
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor;
    UIBezierPath *pill = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 14, 5) cornerRadius:8];
    if (!self.dragging) {
        // An opaque, themed backing keeps the tinted grip legible over text and media.
        [(ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemBackgroundColor) setFill];
        [pill fill];
    }
    [(self.dragging ? accent : [accent colorWithAlphaComponent:0.3]) setFill];
    [pill fill];
    if (!self.dragging) {
        [[accent colorWithAlphaComponent:0.7] setStroke];
        pill.lineWidth = 1;
        [pill stroke];
    }
    UIColor *dot = UIColor.labelColor;
    if (self.dragging) dot = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
    [dot setFill];
    for (NSInteger i = -1; i <= 1; i++) {
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(20.5, 20.5 + i * 6, 3, 3)] fill];
    }
}
- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self setNeedsDisplay];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsDisplay];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return self.available && self.window && (!self.canBegin || self.canBegin());
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    [self.impact prepare];
    return self.available;
}
- (void)updateWithDivider:(CGFloat)x trailingInset:(CGFloat)inset enabled:(BOOL)enabled {
    self.available = enabled;
    self.trailingInset = inset;
    if (self.dragging && (!enabled || !CGSizeEqualToSize(self.startingSize, self.superview.bounds.size))) {
        // Layout callbacks never resize columns recursively.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf cancel]; });
    }
    self.hidden = !enabled;
    if (!self.dragging) self.divider = x;
    self.bounds = CGRectMake(0, 0, 44, 44);
    self.center = CGPointMake(self.divider, CGRectGetMidY(self.superview.bounds));
    self.accessibilityValue = [NSString stringWithFormat:@"Feed %.0f percent, thread %.0f percent", x / MAX(1, self.superview.bounds.size.width) * 100, 100 - x / MAX(1, self.superview.bounds.size.width) * 100];
}
- (void)begin {
    self.dragging = YES;
    self.startingWidth = self.divider;
    self.startingSize = self.superview.bounds.size;
    self.lastTick = (int)round(self.divider / self.startingSize.width * ApolloDuoDividerTicksPerWhole);
    self.lastSnap = -1;
    self.lastLimit = ApolloDuoDividerLimit(self.divider, self.startingSize.width, self.trailingInset, 0);
    self.lastFeedback = CACurrentMediaTime();
    self.scrim = [[UIView alloc] initWithFrame:self.window.bounds];
    self.scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Match the native account sheet: its UIDimmingView is black at 20%
    // opacity (verified on the Duo iOS 27.1 runtime).
    self.scrim.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.2];
    self.scrim.alpha = 0;
    // Cover the native side rail too, just as a sheet does. Keep the gesture
    // view in its original hierarchy; moving it would cancel the held touch.
    [self.window addSubview:self.scrim];
    self.liftedGrip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 34)];
    UIColor *accent = ApolloThemeAccentColor() ?: self.tintColor;
    self.liftedGrip.backgroundColor = accent;
    // Gesture callbacks run with the ambient trait collection; resolve against
    // this view so the dot contrast matches the variant actually drawn.
    accent = [accent resolvedColorWithTraitCollection:self.traitCollection];
    self.liftedGrip.layer.cornerRadius = 8;
    self.liftedGrip.userInteractionEnabled = NO;
    for (NSInteger i = -1; i <= 1; ++i) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(6.5, 15.5 + i * 6, 3, 3)];
        dot.backgroundColor = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
        dot.layer.cornerRadius = 1.5;
        [self.liftedGrip addSubview:dot];
    }
    [self.scrim addSubview:self.liftedGrip];
    self.guide = [UIView new];
    self.guide.backgroundColor = ApolloThemeAccentColor() ?: self.tintColor;
    self.guide.userInteractionEnabled = NO;
    [self.scrim insertSubview:self.guide belowSubview:self.liftedGrip];
    self.valueLabel = [UILabel new];
    self.valueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.valueLabel.textColor = UIColor.labelColor;
    self.valueLabel.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemBackgroundColor;
    self.valueLabel.textAlignment = NSTextAlignmentCenter;
    self.valueLabel.layer.cornerRadius = 10;
    self.valueLabel.clipsToBounds = YES;
    [self.scrim addSubview:self.valueLabel];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.18 animations:^{ self.scrim.alpha = 1; }];
    [self setNeedsDisplay];
    [self.impact impactOccurred];
    [self.selection prepare];
    [self updatePreview:self.divider feedback:NO];
    self.appliedWidth = self.divider;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(resizeFrame:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    ApolloLog(@"[DuoDivider] grabbed at %.1f", self.divider);
}
- (void)updatePreview:(CGFloat)x feedback:(BOOL)feedback {
    CGFloat width = self.startingSize.width;
    self.divider = ApolloDuoDividerClamp(x, width, self.trailingInset);
    CGFloat snapped = ApolloDuoDividerSnap(self.divider, width, self.trailingInset);
    BOOL near = fabs(snapped - self.divider) > 0.01;
    // Exact landmark positions should show the guide too.
    for (NSNumber *stop in @[@(1.0/3.0), @0.4, @0.5, @0.6])
        if (fabs(self.divider - stop.doubleValue * width) < 0.01) near = YES;
    self.guide.hidden = !near;
    self.guide.frame = [self.superview convertRect:CGRectMake(snapped - 0.5, 0, 1, self.startingSize.height) toView:self.scrim];
    self.center = CGPointMake(self.divider, self.startingSize.height / 2);
    self.liftedGrip.center = [self.superview convertPoint:self.center toView:self.scrim];
    // The label and guide describe the same destination that release commits.
    self.valueLabel.text = [NSString stringWithFormat:@"%.0f / %.0f", snapped / width * 100, 100 - snapped / width * 100];
    self.valueLabel.frame = [self.superview convertRect:CGRectMake(self.divider - 48, self.center.y - 66, 96, 32) toView:self.scrim];
    int tick = ApolloDuoDividerTick(self.divider / width, self.lastTick);
    CFTimeInterval now = CACurrentMediaTime();
    int limit = ApolloDuoDividerLimit(self.divider, width, self.trailingInset, self.lastLimit);
    if (feedback && limit && limit != self.lastLimit) {
        [self.impact impactOccurredWithIntensity:1.0];
        self.lastFeedback = now;
    } else if (feedback && now - self.lastFeedback >= 0.08) {
        if (near && (self.lastSnap < 0 || fabs(self.lastSnap - snapped) > 1)) {
            [self.impact impactOccurredWithIntensity:0.6];
            self.lastFeedback = now;
        } else if (tick != self.lastTick) {
            [self.selection selectionChanged];
            self.lastFeedback = now;
        }
    }
    self.lastTick = tick;
    self.lastLimit = limit;
    // Wider exit threshold prevents repeated landmark ticks from finger jitter.
    if (near) self.lastSnap = snapped;
    else if (fabs(self.divider - self.lastSnap) > 16) self.lastSnap = -1;
}
// Coalesce touch samples to one UIKit width change per display frame. The
// same clock promptly cancels a hold if navigation/presentation changes.
- (void)resizeFrame:(CADisplayLink *)link {
    if (!self.available || !self.window || (self.canBegin && !self.canBegin())
        || !CGSizeEqualToSize(self.startingSize, self.superview.bounds.size)) {
        [self cancel];
        return;
    }
    if (fabs(self.appliedWidth - self.divider) < 0.5) return;
    self.appliedWidth = self.divider;
    if (self.changeWidth) self.changeWidth(self.divider, NO);
}
- (void)pressed:(UILongPressGestureRecognizer *)press {
    CGFloat x = [press locationInView:self.superview].x;
    if (press.state == UIGestureRecognizerStateBegan) {
        self.touchOffset = x - self.divider;
        [self begin];
    } else if (press.state == UIGestureRecognizerStateChanged && self.dragging) {
        if (!self.available || !CGSizeEqualToSize(self.startingSize, self.superview.bounds.size)
            || (self.canBegin && !self.canBegin())) { [self cancel]; return; }
        [self updatePreview:x - self.touchOffset feedback:YES];
    } else if (press.state == UIGestureRecognizerStateEnded && self.dragging) {
        if (!self.available || !CGSizeEqualToSize(self.startingSize, self.superview.bounds.size)
            || (self.canBegin && !self.canBegin())) { [self cancel]; return; }
        [self updatePreview:x - self.touchOffset feedback:NO];
        CGFloat target = ApolloDuoDividerSnap(self.divider, self.startingSize.width, self.trailingInset);
        self.dragging = NO;
        if (self.changeWidth) self.changeWidth(target, YES);
        // Confirmation takes priority over the movement tick's rate limit.
        [self.impact impactOccurredWithIntensity:0.7];
        [self finishVisuals:YES];
        ApolloLog(@"[DuoDivider] committed %.1f", target);
    } else if (press.state == UIGestureRecognizerStateCancelled || press.state == UIGestureRecognizerStateFailed) {
        [self cancel];
    }
}
- (void)finishVisuals:(BOOL)animated {
    [self.displayLink invalidate]; self.displayLink = nil;
    UIView *scrim = self.scrim;
    self.scrim = nil;
    // Stop intercepting touches before fading; the next grab owns its own scrim.
    scrim.userInteractionEnabled = NO;
    [self.liftedGrip removeFromSuperview]; self.liftedGrip = nil;
    [self.guide removeFromSuperview]; self.guide = nil;
    [self.valueLabel removeFromSuperview]; self.valueLabel = nil;
    [self setNeedsDisplay];
    [UIView animateWithDuration:animated && !UIAccessibilityIsReduceMotionEnabled() ? 0.18 : 0 animations:^{ scrim.alpha = 0; }
                     completion:^(BOOL finished) { [scrim removeFromSuperview]; }];
}
- (void)cancel {
    if (!self.dragging) return;
    self.dragging = NO;
    self.press.enabled = NO; self.press.enabled = YES;
    if (self.changeWidth) self.changeWidth(self.startingWidth, NO);
    [self finishVisuals:NO];
    ApolloLog(@"[DuoDivider] cancelled");
}
- (void)adjustBy:(CGFloat)delta {
    if (!self.available || (self.canBegin && !self.canBegin())) return;
    [self cancel];
    CGFloat width = self.superview.bounds.size.width;
    CGFloat target = ApolloDuoDividerClamp(self.divider + delta * width, width, self.trailingInset);
    if (self.changeWidth) self.changeWidth(target, YES);
    [self.selection selectionChanged];
}
- (void)accessibilityIncrement { [self adjustBy:0.05]; }
- (void)accessibilityDecrement { [self adjustBy:-0.05]; }
// No accessibilityActivate: a VoiceOver double-tap must not silently discard the
// saved width. Resetting stays on the explicit Equal widths custom action.
- (void)doubleTapped:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) [self resetWidth];
}
- (BOOL)resetWidth { [self adjustBy:0.5 - self.divider / MAX(1, self.superview.bounds.size.width)]; return YES; }
@end
