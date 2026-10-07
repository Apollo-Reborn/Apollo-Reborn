#import "ApolloIPadLayoutWelcome.h"
#import "ApolloPaneLayout.h"
#import "../ApolloCommon.h"
#import "../ApolloThemeRuntime.h"
#import "../UserDefaultConstants.h"

static UIColor *ApolloWelcomeAccent(UITraitCollection *traits) {
    return [(ApolloThemeAccentColor() ?: UIColor.systemBlueColor) resolvedColorWithTraitCollection:traits];
}

// A real inline badge, rather than more words in the setting's name. Rendering
// it at the label's current text size keeps it aligned under Dynamic Type.
NSAttributedString *ApolloIPadLayoutBetaTitle(UIFont *font, UITraitCollection *traits) {
    UIFont *badgeFont = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2 compatibleWithTraitCollection:traits];
    NSDictionary *attributes = @{NSFontAttributeName: badgeFont, NSForegroundColorAttributeName: ApolloWelcomeAccent(traits)};
    CGSize textSize = [@"BETA" sizeWithAttributes:attributes];
    CGSize size = CGSizeMake(ceil(textSize.width) + 12, ceil(textSize.height) + 6);
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[ApolloWelcomeAccent(traits) colorWithAlphaComponent:0.12] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:5] fill];
        [@"BETA" drawAtPoint:CGPointMake(6, 3) withAttributes:attributes];
    }];
    NSTextAttachment *badge = [NSTextAttachment new];
    badge.image = image;
    badge.bounds = CGRectMake(0, (font.capHeight - size.height) / 2, size.width, size.height);
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:@"iPad Layout  " attributes:@{NSFontAttributeName:font}];
    [title appendAttributedString:[NSAttributedString attributedStringWithAttachment:badge]];
    return title;
}

// A purpose-drawn preview image stays crisp, matches the active theme and
// contains no account data. The three panels illustrate the actual layout.
static UIImage *ApolloWelcomePreview(UITraitCollection *traits) {
    UIColor *accent = ApolloWelcomeAccent(traits);
    UIColor *page = [(ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor) resolvedColorWithTraitCollection:traits];
    UIColor *card = [(ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemBackgroundColor) resolvedColorWithTraitCollection:traits];
    UIColor *ink = [UIColor.labelColor resolvedColorWithTraitCollection:traits];
    CGSize size = CGSizeMake(640, 400);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        CGContextSetShadowWithColor(cg, CGSizeMake(0, 12), 24, [UIColor.blackColor colorWithAlphaComponent:0.18].CGColor);
        [UIColor.blackColor setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(20, 24, 600, 348) cornerRadius:30] fill];
        CGContextSetShadowWithColor(cg, CGSizeZero, 0, NULL);
        UIBezierPath *screen = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(30, 34, 580, 328) cornerRadius:22];
        CGContextSaveGState(cg);
        [screen addClip];
        [page setFill]; [screen fill];
        [[accent colorWithAlphaComponent:0.12] setFill];
        UIRectFill(CGRectMake(30, 34, 140, 328));
        NSDictionary *heading = @{NSFontAttributeName:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold], NSForegroundColorAttributeName:ink};
        [@"Apollo" drawAtPoint:CGPointMake(48, 50) withAttributes:heading];
        [accent setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(42, 85, 116, 30) cornerRadius:12] fill];
        UIColor *onAccent = ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor;
        NSArray *items = @[@"Posts", @"Subreddits", @"Inbox", @"Favourites"];
        for (NSUInteger index = 0; index < items.count; index++) {
            [items[index] drawAtPoint:CGPointMake(54, 93 + index * 39) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:12 weight:index == 0 ? UIFontWeightSemibold : UIFontWeightRegular], NSForegroundColorAttributeName:index == 0 ? onAccent : ink}];
        }
        [@"Posts" drawAtPoint:CGPointMake(186, 50) withAttributes:heading];
        [@"Comments" drawAtPoint:CGPointMake(392, 50) withAttributes:heading];
        for (NSUInteger index = 0; index < 3; index++) {
            CGFloat y = 85 + index * 89;
            [card setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(182, y, 182, 78) cornerRadius:10] fill];
            [[accent colorWithAlphaComponent:index == 0 ? 0.3 : 0.12] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(192, y + 10, 45, 55) cornerRadius:6] fill];
            [[ink colorWithAlphaComponent:0.65] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(248, y + 14, 103, 5) cornerRadius:2.5] fill];
            [[ink colorWithAlphaComponent:0.2] setFill];
            UIRectFill(CGRectMake(248, y + 28, 88, 4));
            UIRectFill(CGRectMake(248, y + 41, 65, 4));
        }
        for (NSUInteger index = 0; index < 5; index++) {
            CGFloat x = 390 + (index % 2) * 12, y = 97 + index * 48;
            [accent setFill]; [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x, y, 14, 14)] fill];
            [[ink colorWithAlphaComponent:0.55] setFill]; UIRectFill(CGRectMake(x + 22, y + 3, 75, 4));
            [[ink colorWithAlphaComponent:0.18] setFill];
            UIRectFill(CGRectMake(x + 22, y + 16, 151, 4));
            UIRectFill(CGRectMake(x + 22, y + 27, 121, 4));
        }
        CGContextRestoreGState(cg);
    }];
}

@interface ApolloIPadLayoutWelcomeController : UIViewController
@property(nonatomic, strong) UIImageView *preview;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIButton *tryButton;
@end

@implementation ApolloIPadLayoutWelcomeController
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.accessibilityIdentifier = @"ApolloIPadLayoutWelcome";
    self.preferredContentSize = CGSizeMake(480, 720);
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    self.preview = [UIImageView new];
    self.preview.contentMode = UIViewContentModeScaleAspectFit;
    self.preview.isAccessibilityElement = YES;
    self.preview.accessibilityLabel = @"Preview of Apollo on iPad, with a favourites sidebar, posts and comments side by side";
    self.titleLabel = [self label:@"iPad Layout" style:UIFontTextStyleTitle1];
    self.titleLabel.accessibilityTraits |= UIAccessibilityTraitHeader;
    self.titleLabel.accessibilityLabel = @"iPad Layout, Beta";
    self.titleLabel.textColor = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    UILabel *description = [self label:@"A little more room for Apollo.\nKeep your favourites close and read posts and comments side by side." style:UIFontTextStyleBody];
    UILabel *beta = [self label:@"This layout is in beta. You can switch back anytime in Apollo Reborn → Interface." style:UIFontTextStyleSubheadline];
    UILabel *restart = [self label:@"Requires reopening Apollo." style:UIFontTextStyleFootnote];
    self.tryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.tryButton setTitle:@"Try Now" forState:UIControlStateNormal];
    self.tryButton.accessibilityIdentifier = @"ApolloIPadLayoutTryNow";
    self.tryButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.tryButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.tryButton.layer.cornerRadius = 16;
    [self.tryButton addTarget:self action:@selector(tryNow) forControlEvents:UIControlEventTouchUpInside];
    UIButton *later = [UIButton buttonWithType:UIButtonTypeSystem];
    [later setTitle:@"Try Later" forState:UIControlStateNormal];
    later.accessibilityIdentifier = @"ApolloIPadLayoutTryLater";
    later.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    later.titleLabel.adjustsFontForContentSizeCategory = YES;
    [later addTarget:self action:@selector(tryLater) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.preview, self.titleLabel, description, beta, self.tryButton, later, restart]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:4 afterView:later];
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-28],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-56],
        [self.preview.heightAnchor constraintEqualToAnchor:self.preview.widthAnchor multiplier:0.625],
        [self.tryButton.heightAnchor constraintGreaterThanOrEqualToConstant:54],
        [later.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    [self updateTheme];
}

- (void)updateTheme {
    self.preview.image = ApolloWelcomePreview(self.traitCollection);
    self.titleLabel.attributedText = ApolloIPadLayoutBetaTitle(self.titleLabel.font, self.traitCollection);
    UIColor *accent = ApolloWelcomeAccent(self.traitCollection);
    self.view.tintColor = accent;
    self.tryButton.backgroundColor = accent;
    [self.tryButton setTitleColor:ApolloColorIsLight(accent) ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (self.isViewLoaded) [self updateTheme];
}

- (void)tryLater {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)tryNow {
    // The launch-time global must continue to describe the current hierarchy.
    // Save the desired state only; the existing scene installer reads it on
    // relaunch. This is the same contract as the Interface switch.
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:UDKeyIPadPaneLayout];
    UIViewController *presenter = self.presentingViewController;
    BOOL active = ApolloPaneLayoutActive();
    [self dismissViewControllerAnimated:YES completion:^{
        if (active) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Ready to Try iPad Layout"
            message:@"Your choice is saved. Quit Apollo, then reopen it to start using iPad Layout. You can switch back in Apollo Reborn → Interface."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Quit Apollo" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { exit(0); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    }];
}
@end

@interface ApolloIPadLayoutWelcomeCoordinator : NSObject
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, weak) ApolloIPadLayoutWelcomeController *card;
@end

@implementation ApolloIPadLayoutWelcomeCoordinator
- (BOOL)eligible {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad && ApolloPaneLayoutSupported() &&
        ![NSUserDefaults.standardUserDefaults boolForKey:UDKeyIPadLayoutWelcomeSeen] &&
        ![NSUserDefaults.standardUserDefaults boolForKey:UDKeyIPadPaneLayout];
}
- (void)activated {
    if (![self eligible] || self.timer) return;
    // Give crash recovery and What's New first chance at presentation. If
    // either owns a modal, wait for it to finish instead of stacking cards.
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf attempt];
    }];
}
- (void)deactivated {
    [self.timer invalidate];
    self.timer = nil;
}
- (UIViewController *)presenter {
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow && window.windowScene.activationState == UISceneActivationStateForegroundActive &&
            window.rootViewController.view.window && !window.rootViewController.presentedViewController) {
            return window.rootViewController;
        }
    }
    return nil;
}
- (void)attempt {
    if (![self eligible]) { [self deactivated]; return; }
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIViewController *presenter = [self presenter];
    if (!presenter || presenter.isBeingPresented || presenter.isBeingDismissed || presenter.transitionCoordinator) return;
    [self showFrom:presenter debug:NO];
}
- (void)showFrom:(UIViewController *)presenter debug:(BOOL)debug {
    if (self.card || !presenter.view.window || presenter.presentedViewController ||
        presenter.isBeingPresented || presenter.isBeingDismissed) return;
    ApolloIPadLayoutWelcomeController *card = [ApolloIPadLayoutWelcomeController new];
    card.modalPresentationStyle = UIModalPresentationFormSheet;
    card.preferredContentSize = CGSizeMake(480, 720);
    self.card = card;
    [presenter presentViewController:card animated:YES completion:^{
        // Only a committed real presentation consumes the invitation. A debug
        // replay leaves the marker untouched, so testing doesn't eat first run.
        if (!debug) [NSUserDefaults.standardUserDefaults setBool:YES forKey:UDKeyIPadLayoutWelcomeSeen];
        ApolloLog(@"[iPadWelcome] presented debug=%d", debug);
    }];
    [self deactivated];
}
@end

static ApolloIPadLayoutWelcomeCoordinator *sWelcomeCoordinator;
void ApolloIPadLayoutWelcomeStart(void) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad || !ApolloPaneLayoutSupported()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Existing beta testers have already made this choice. Remember it
        // once at launch, including across a later opt-out. Debug replay must
        // not consume a marker that QA deliberately cleared in this process.
        if ([NSUserDefaults.standardUserDefaults boolForKey:UDKeyIPadPaneLayout]) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:UDKeyIPadLayoutWelcomeSeen];
        }
        sWelcomeCoordinator = [ApolloIPadLayoutWelcomeCoordinator new];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:sWelcomeCoordinator selector:@selector(activated) name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:sWelcomeCoordinator selector:@selector(activated) name:UISceneDidActivateNotification object:nil];
        [center addObserver:sWelcomeCoordinator selector:@selector(deactivated) name:UIApplicationDidEnterBackgroundNotification object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ [sWelcomeCoordinator activated]; });
    });
}

void ApolloIPadLayoutWelcomePresentForDebug(UIViewController *presenter) {
    ApolloIPadLayoutWelcomeStart();
    dispatch_async(dispatch_get_main_queue(), ^{
        [sWelcomeCoordinator showFrom:presenter ?: [sWelcomeCoordinator presenter] debug:YES];
    });
}
