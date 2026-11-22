#import "ApolloBudgetPauseCell.h"
#import "ApolloCommon.h"   // ApolloLog

// How often the live line is asked for again while the cell is on screen.
static const NSTimeInterval kApolloBudgetPauseStatusInterval = 5.0;

// Apollo runs a full-width back-swipe pan above its settings screens. A drag
// that starts on the slider is a pan too, and on Liquid Glass the back swipe
// won it: the screen popped instead of the thumb moving. This recognizer sits
// on the slider and begins the moment a touch lands on it; the pans up the
// ancestor chain are made to wait for it to fail (see the slider below), and it
// never fails for a touch on an enabled slider, so that touch is the slider's
// alone. Same approach as the AI and Inline Media settings sliders.
//
// There is one of these for the whole app (ApolloBudgetPauseSharedClaim), moved
// onto whichever slider is on screen. A failure requirement can't be taken
// back, and the pans it goes on (Apollo's navigation pans, the tab bar's) live
// as long as the app does; with a claim per slider, every visit to the screen
// would leave another one hanging off each of them.
@interface ApolloBudgetPauseSliderClaim : UIGestureRecognizer
@property (nonatomic, weak) UITouch *claimedTouch;
@end

@implementation ApolloBudgetPauseSliderClaim
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        // Only ever a gate for other recognizers: the slider's own touch
        // handling must see every touch, untouched and undelayed.
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible) return;   // a second finger changes nothing
    UIControl *control = [self.view isKindOfClass:[UIControl class]] ? (UIControl *)self.view : nil;
    // A disabled slider claims nothing: swipe-back works over it as usual.
    if (control && !control.isEnabled) { self.state = UIGestureRecognizerStateFailed; return; }
    self.claimedTouch = touches.anyObject;
    self.state = UIGestureRecognizerStateBegan;
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateChanged;
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // Held until the claimed finger lifts; another finger ending doesn't release it.
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    self.state = UIGestureRecognizerStateCancelled;
}
- (void)reset {
    [super reset];
    self.claimedTouch = nil;
}
@end

// Main thread only, like everything that touches them.
static ApolloBudgetPauseSliderClaim *ApolloBudgetPauseSharedClaim(void) {
    static ApolloBudgetPauseSliderClaim *claim;
    if (!claim) claim = [[ApolloBudgetPauseSliderClaim alloc] initWithTarget:nil action:NULL];
    return claim;
}

// The pans already made to wait on the shared claim (weak: they belong to
// their views), so each is wired once however often the row comes and goes.
static NSHashTable<UIGestureRecognizer *> *ApolloBudgetPauseWaitingPans(void) {
    static NSHashTable<UIGestureRecognizer *> *pans;
    if (!pans) pans = [NSHashTable weakObjectsHashTable];
    return pans;
}

// The row's slider. Two things a stock UISlider doesn't do on this screen:
//
//  - Its touches are its own (the claim above), on every build.
//  - It follows the finger through plain UIControl tracking. On iOS 26 UISlider
//    moves its thumb with a private "fluid" interaction instead, and that
//    interaction lost the drag here: the thumb stayed put. So the interaction
//    is refused and the classic begin / continue / end sequence drives the
//    thumb, the way the AI and Inline Media settings sliders already do (their
//    notes on -isTracking and -_deferFinalActions, read from UIKitCore 26.1,
//    are in ApolloAISettingsViewController.m).
//
// The thumb sits under the finger while it's down, wherever on the track the
// touch began, so a tap on the track moves it there too. Control events are the
// stock ones: value-changed as it moves, touch-up when the finger lifts.
@interface ApolloBudgetPauseSlider : UISlider
// Our own tracking flag; see -isTracking.
@property (nonatomic) BOOL fingerDown;
@end

@implementation ApolloBudgetPauseSlider

// Takes the shared claim onto this slider (adding a recognizer to a view takes
// it off the one it was on) and makes every pan up the ancestor chain, and the
// navigation controller's swipe-back, wait for it to fail. Scroll views' own
// pans are left out: the claim beginning already keeps them off a touch that
// started here. Safe to call again; each pan is wired once.
- (void)apollo_makeBackSwipesWait {
    ApolloBudgetPauseSliderClaim *claim = ApolloBudgetPauseSharedClaim();
    if (claim.view != self) [self addGestureRecognizer:claim];
    NSHashTable<UIGestureRecognizer *> *waiting = ApolloBudgetPauseWaitingPans();

    UIViewController *owner = nil;
    for (UIResponder *responder = self.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) { owner = (UIViewController *)responder; break; }
    }
    UIGestureRecognizer *pop = owner.navigationController.interactivePopGestureRecognizer;
    NSUInteger before = waiting.count;
    if (pop && ![waiting containsObject:pop]) {
        [pop requireGestureRecognizerToFail:claim];
        [waiting addObject:pop];
    }
    for (UIView *view = self.superview; view; view = view.superview) {
        UIGestureRecognizer *scrollPan = [view isKindOfClass:[UIScrollView class]]
            ? ((UIScrollView *)view).panGestureRecognizer : nil;
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if (gesture == claim || gesture == scrollPan || gesture == pop) continue;
            if ([waiting containsObject:gesture]) continue;
            BOOL panLike = [gesture isKindOfClass:[UIPanGestureRecognizer class]] ||
                [NSStringFromClass([gesture class]) containsString:@"ParallaxTransition"];
            if (!panLike) continue;
            [gesture requireGestureRecognizerToFail:claim];
            [waiting addObject:gesture];
        }
    }
    if (waiting.count != before) {
        ApolloLog(@"[BudgetPauseSlider] %lu back-swipe pan(s) now wait for the slider's touch (pop=%d)",
                  (unsigned long)waiting.count, pop != nil);
    }
}

// iOS 26's fluid interaction is refused (see the class comment)...
- (void)addInteraction:(id<UIInteraction>)interaction {
    if ([NSStringFromClass([interaction class]) containsString:@"FluidSliderInteraction"]) return;
    [super addInteraction:interaction];
}

// ...and removed if UIKit attached one before this class could refuse it.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    for (id<UIInteraction> interaction in [self.interactions copy]) {
        if ([NSStringFromClass([interaction class]) containsString:@"FluidSliderInteraction"]) {
            [self removeInteraction:interaction];
        }
    }
    [self apollo_makeBackSwipesWait];
}

// With the fluid element installed, UISlider reports -isTracking from that
// element's own drag state and defers the touch-up to its interaction. Neither
// exists here any more, so UIControl gets the plain answers and finishes the
// touch sequence itself.
- (BOOL)isTracking {
    return self.fingerDown;
}

- (BOOL)_deferFinalActions {
    return NO;
}

// The thumb's centre travels the track minus half a thumb at each end.
- (void)apollo_followTouch:(UITouch *)touch {
    CGRect track = [self trackRectForBounds:self.bounds];
    CGFloat thumbWidth = CGRectGetWidth([self thumbRectForBounds:self.bounds trackRect:track value:self.value]);
    CGFloat travel = MAX(1.0, CGRectGetWidth(track) - thumbWidth);
    CGFloat fraction = ([touch locationInView:self].x - CGRectGetMinX(track) - thumbWidth / 2.0) / travel;
    if (self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) fraction = 1.0 - fraction;
    fraction = MIN(1.0, MAX(0.0, fraction));
    float value = self.minimumValue + (float)fraction * (self.maximumValue - self.minimumValue);
    if (value == self.value) return;
    [self setValue:value animated:NO];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

// Hit-testing runs before any recognizer is handed the touch, so this is where
// a slider that isn't holding the claim (another one took it meanwhile) gets it
// back, and where a pan added after the row came on screen (Apollo re-adds its
// own when a push settles) is caught.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit && self.window && self.isEnabled) [self apollo_makeBackSwipesWait];
    return hit;
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.fingerDown = YES;
    [self apollo_followTouch:touch];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self apollo_followTouch:touch];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [super endTrackingWithTouch:touch withEvent:event];
    self.fingerDown = NO;
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [super cancelTrackingWithEvent:event];
    self.fingerDown = NO;
}

@end

@interface ApolloBudgetPauseCell ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong, nullable) NSTimer *statusTimer;
@property (nonatomic) NSInteger step;
@property (nonatomic) NSInteger committedStop;
@end

@implementation ApolloBudgetPauseCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _step = 1;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.numberOfLines = 0;
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.textColor = UIColor.labelColor;

    _valueLabel = [[UILabel alloc] init];
    _valueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _valueLabel.adjustsFontForContentSizeCategory = YES;
    _valueLabel.textColor = UIColor.secondaryLabelColor;
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [_valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _valueLabel ]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentFirstBaseline;
    header.spacing = 12.0;

    _slider = [[ApolloBudgetPauseSlider alloc] init];
    _slider.continuous = YES;
    [_slider addTarget:self action:@selector(apollo_sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(apollo_sliderReleased:)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.numberOfLines = 0;
    _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _detailLabel.adjustsFontForContentSizeCategory = YES;
    _detailLabel.textColor = UIColor.secondaryLabelColor;

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.numberOfLines = 0;
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _statusLabel.adjustsFontForContentSizeCategory = YES;
    _statusLabel.textColor = UIColor.secondaryLabelColor;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ header, _slider, _detailLabel, _statusLabel ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6.0;
    [stack setCustomSpacing:8.0 afterView:_slider];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:11.0],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-11.0],
    ]];
    return self;
}

- (void)dealloc {
    [_statusTimer invalidate];
}

- (void)configureWithTitle:(NSString *)title
                    detail:(NSString *)detail
                      stop:(NSInteger)stop
                   minimum:(NSInteger)minimum
                   maximum:(NSInteger)maximum
                      step:(NSInteger)step
                    accent:(UIColor *)accent {
    self.step = MAX(step, 1);
    self.committedStop = stop;
    self.titleLabel.text = title;
    self.detailLabel.text = detail;
    self.slider.minimumValue = (float)minimum;
    self.slider.maximumValue = (float)maximum;
    // Not while a finger is on it: a reload mid-drag would pull the thumb back.
    if (!self.slider.isTracking) self.slider.value = (float)stop;
    self.slider.minimumTrackTintColor = accent;
    self.slider.accessibilityLabel = title;
    [self apollo_showStop:[self apollo_stopForSlider]];
    [self apollo_refreshStatus];
}

// The stop nearest the thumb.
- (NSInteger)apollo_stopForSlider {
    NSInteger step = self.step;
    NSInteger minimum = (NSInteger)lroundf(self.slider.minimumValue);
    NSInteger maximum = (NSInteger)lroundf(self.slider.maximumValue);
    NSInteger stop = minimum + ((NSInteger)lroundf((self.slider.value - (float)minimum) / (float)step)) * step;
    return MIN(MAX(stop, minimum), maximum);
}

- (void)apollo_showStop:(NSInteger)stop {
    NSString *text = self.valueText ? self.valueText(stop) : [NSString stringWithFormat:@"%ld", (long)stop];
    self.valueLabel.text = text;
    self.slider.accessibilityValue = text;
}

- (void)apollo_sliderMoved:(UISlider *)slider {
    [self apollo_showStop:[self apollo_stopForSlider]];
}

- (void)apollo_sliderReleased:(UISlider *)slider {
    NSInteger stop = [self apollo_stopForSlider];
    [slider setValue:(float)stop animated:YES];
    [self apollo_showStop:stop];
    if (stop == self.committedStop) return;
    self.committedStop = stop;
    if (self.onCommit) self.onCommit(stop);
    [self apollo_refreshStatus];
}

- (void)apollo_refreshStatus {
    NSString *status = self.statusText ? self.statusText() : nil;
    // Only the text changes between refreshes; the label keeps its place in
    // the stack either way, so the row's height doesn't move under a finger.
    self.statusLabel.text = status.length > 0 ? status : @" ";
}

// The live line only runs while the row is on screen.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.statusTimer invalidate];
    self.statusTimer = nil;
    if (!self.window) return;
    [self apollo_refreshStatus];
    __weak typeof(self) weakSelf = self;
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:kApolloBudgetPauseStatusInterval
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf apollo_refreshStatus];
    }];
}

@end
