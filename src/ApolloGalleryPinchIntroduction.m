#import "ApolloGalleryPinchIntroduction.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import <Symbols/Symbols.h>

static NSString *const kApolloGalleryPinchIntroductionKey = @"ApolloGalleryPinchIntroductionAcknowledged";

@interface ApolloGalleryPinchIntroduction ()
@property (nonatomic, strong) UIImageView *gestureImage;
@property (nonatomic, strong) UIButton *acknowledgeButton;
@property (nonatomic) BOOL readingDelayStarted;
@end

@implementation ApolloGalleryPinchIntroduction

+ (BOOL)hasBeenAcknowledged {
    return [NSUserDefaults.standardUserDefaults boolForKey:kApolloGalleryPinchIntroductionKey];
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.modalInPresentation = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.22];
    self.view.accessibilityViewIsModal = YES;
    self.view.accessibilityIdentifier = @"ApolloGalleryPinchIntroduction";
    // No backdrop recognizer: outside taps are consumed by this modal view.
    UIVisualEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial];
    if (@available(iOS 26.0, *)) {
        if (IsLiquidGlass()) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    }
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:effect];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 32.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    [self.view addSubview:card];

    // Keep large Dynamic Type and landscape usable without shrinking the text.
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [card.contentView addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    UILabel *title = [UILabel new];
    title.text = @"Pinch to Zoom";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.font = [UIFont fontWithDescriptor:[title.font.fontDescriptor
        fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] size:0];
    title.adjustsFontForContentSizeCategory = YES;
    title.numberOfLines = 0;
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = UIColor.labelColor;
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    [stack addArrangedSubview:title];

    UIColor *accent = ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration
        configurationWithPointSize:68.0 weight:UIImageSymbolWeightRegular];
    // hand.pinch only ships with iOS 18's SF Symbols; hand.draw (iOS 13) keeps
    // the guide from showing an empty animated gap on iOS 14-17.
    UIImage *gesture = [UIImage systemImageNamed:@"hand.pinch" withConfiguration:configuration] ?:
        [UIImage systemImageNamed:@"hand.draw" withConfiguration:configuration];
    self.gestureImage = [[UIImageView alloc] initWithImage:gesture];
    self.gestureImage.contentMode = UIViewContentModeScaleAspectFit;
    self.gestureImage.tintColor = accent;
    self.gestureImage.isAccessibilityElement = NO;
    [self.gestureImage.heightAnchor constraintEqualToConstant:94.0].active = YES;
    [stack addArrangedSubview:self.gestureImage];

    UILabel *message = [UILabel new];
    message.text = @"Pinch two fingers together to see more photos. Spread them apart to make photos larger.";
    message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    message.adjustsFontForContentSizeCategory = YES;
    message.numberOfLines = 0;
    message.textAlignment = NSTextAlignmentCenter;
    message.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:message];

    self.acknowledgeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.acknowledgeButton setTitle:@"Got it!" forState:UIControlStateNormal];
    // Near-white accents (monochromatic, chumbus) need dark text on the fill.
    UIColor *buttonText = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return ApolloColorIsLight([accent resolvedColorWithTraitCollection:traits]) ?
            UIColor.blackColor : UIColor.whiteColor;
    }];
    [self.acknowledgeButton setTitleColor:buttonText forState:UIControlStateNormal];
    self.acknowledgeButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.acknowledgeButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.acknowledgeButton.backgroundColor = accent;
    self.acknowledgeButton.layer.cornerRadius = 25.0;
    self.acknowledgeButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.acknowledgeButton.alpha = 0.0;
    self.acknowledgeButton.userInteractionEnabled = NO;
    self.acknowledgeButton.accessibilityElementsHidden = YES;
    [self.acknowledgeButton.heightAnchor constraintGreaterThanOrEqualToConstant:50.0].active = YES;
    [self.acknowledgeButton addTarget:self action:@selector(acknowledge) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.acknowledgeButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [card.widthAnchor constraintEqualToConstant:340.0];
    width.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *height = [card.heightAnchor constraintEqualToAnchor:stack.heightAnchor constant:48.0];
    height.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-40.0], width,
        [card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24.0], height,
        [scroll.topAnchor constraintEqualToAnchor:card.contentView.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24.0],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48.0],
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateGestureAnimation)
        name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updateGestureAnimation];
    if (self.readingDelayStarted) return;
    self.readingDelayStarted = YES;
    __weak typeof(self) weakSelf = self;
    // Start the full two seconds after the guide has finished appearing.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloGalleryPinchIntroduction *guide = weakSelf;
        if (!guide.view.window || guide.isBeingDismissed) return;
        guide.acknowledgeButton.userInteractionEnabled = YES;
        guide.acknowledgeButton.accessibilityElementsHidden = NO;
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.2 animations:^{
            guide.acknowledgeButton.alpha = 1.0;
        }];
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, guide.acknowledgeButton);
    });
}

- (void)updateGestureAnimation {
    [self.gestureImage.layer removeAnimationForKey:@"pinchGuide"];
    if (@available(iOS 17.0, *)) [self.gestureImage removeAllSymbolEffects];
    if (UIAccessibilityIsReduceMotionEnabled() || !self.view.window) return;
    if (@available(iOS 18.0, *)) {
        // Apple's native symbol animation gently expands/contracts the pinch
        // hand; the text remains readable and the card itself stays still.
        [self.gestureImage addSymbolEffect:[NSSymbolBreatheEffect breathePlainEffect]];
    } else {
        CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        breathe.fromValue = @0.9;
        breathe.toValue = @1.05;
        breathe.duration = 1.2;
        breathe.autoreverses = YES;
        breathe.repeatCount = HUGE_VALF;
        breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.gestureImage.layer addAnimation:breathe forKey:@"pinchGuide"];
    }
}

- (BOOL)accessibilityPerformEscape { return NO; }

- (void)acknowledge {
    if (!self.acknowledgeButton.userInteractionEnabled) return;
    self.acknowledgeButton.userInteractionEnabled = NO;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kApolloGalleryPinchIntroductionKey];
    dispatch_block_t completion = self.dismissalCompletion;
    self.dismissalCompletion = nil;
    [self dismissViewControllerAnimated:YES completion:completion];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
