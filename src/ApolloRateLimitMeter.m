#import <UIKit/UIKit.h>

#import "ApolloRateLimitMeter.h"
#import "ApolloCommon.h"               // ApolloLog, ApolloAllWindows
#import "ApolloDeviceDisplay.h"        // ApolloDeviceAppWindow
#import "ApolloDeviceGeometry.h"       // ApolloDevicePreferredWindowScene
#import "ApolloReduceRateLimiting.h"
#import "ApolloState.h"
#import "ApolloToast.h"
#import "ApolloWebJSON.h"              // ApolloWebJSONOptionalReadPause
#import "ApolloWebJSONBudget.h"
#import "ApolloWebSessionStore.h"
#import "UserDefaultConstants.h"

// Apollo's own "the account in use changed".
static NSString *const kApolloRateLimitMeterAccountChanged = @"com.christianselig.RedditCurrentAccountChanged";

// The account both features are about: the one in use, when it's API-Key-Free
// (the primary web-session index, as in ApolloReduceRateLimitingActive). nil
// for an API-key account or with API-Key-Free Mode off.
static NSString *ApolloRateLimitMeterAccount(void) {
    if (!sWebJSONEnabled) return nil;
    NSString *active = ApolloActiveWebSessionUsername();
    if (active.length == 0) return nil;
    return [ApolloWebSessionUsernames() containsObject:active.lowercaseString] ? active : nil;
}

static NSString *ApolloRateLimitMeterTimeLeft(NSTimeInterval seconds) {
    return seconds < 60.0 ? @"under a minute" : [NSString stringWithFormat:@"%ld min", (long)ceil(seconds / 60.0)];
}

#pragma mark - Warnings

// The fixed marks, in percent of the budget used.
static const NSInteger kApolloRateLimitWarningMarks[] = { 50, 75, 90 };
// A fixed mark this close to the Pause Extras At stop is left to the stop's own
// notice, so a stop of 70 doesn't announce 70 and then 75 a few requests on.
static const NSInteger kApolloRateLimitWarningStopMargin = 10;

static void ApolloRateLimitWarnIfDue(NSString *account) {
    if (!sRateLimitWarnings) return;
    NSInteger stop = (ApolloReduceRateLimitingActive() && sReduceRateLimitingPauseAt < 100) ? sReduceRateLimitingPauseAt : 0;
    NSInteger marks[4];
    NSUInteger count = 0;
    for (size_t i = 0; i < sizeof(kApolloRateLimitWarningMarks) / sizeof(kApolloRateLimitWarningMarks[0]); i++) {
        NSInteger mark = kApolloRateLimitWarningMarks[i];
        if (stop > 0 && labs((long)(mark - stop)) < kApolloRateLimitWarningStopMargin) continue;
        marks[count++] = mark;
    }
    if (stop > 0) marks[count++] = stop;
    NSInteger mark = ApolloWebJSONBudgetTakeMark(account, marks, count);
    if (mark == 0) return;

    ApolloWebJSONBudgetState state = ApolloWebJSONBudgetCurrent(account);
    if (!state.known) return;
    // Nothing left is Reddit refusing the account: its 429 brings up the
    // "Reddit Rate Limit Reached" notice, and this one would only cover it.
    if (state.used >= state.limit) return;
    BOOL paused = stop > 0 && state.used >= state.limit * (double)stop / 100.0;
    NSString *title = [NSString stringWithFormat:@"%ld of %ld Reddit requests used", lround(state.used), lround(state.limit)];
    NSString *reset = [NSString stringWithFormat:@"Resets in %@", ApolloRateLimitMeterTimeLeft(state.resetsIn)];
    NSString *detail = paused ? [@"Extras paused. " stringByAppendingString:reset] : reset;
    ApolloLog(@"[RateLimitWarnings] mark %ld%%: %@ (%@)", (long)mark, title, detail);
    ApolloShowToastWithStyle(title, detail, ApolloToastStyleInfo, paused ? @"pause.circle" : @"speedometer");
}

#pragma mark - Meter view

static const CGFloat kApolloRateLimitMeterHeight = 30.0;
static const CGFloat kApolloRateLimitMeterRing = 18.0;
static const CGFloat kApolloRateLimitMeterEdge = 6.0;        // gap kept from the screen's safe edges
static const NSTimeInterval kApolloRateLimitMeterExpandedFor = 4.0;
static const NSTimeInterval kApolloRateLimitMeterRefresh = 5.0;

// Green with nothing used, through yellow and orange, to red with everything
// used. A little deeper in light mode so the number stays readable on the
// pill's material.
static UIColor *ApolloRateLimitMeterColor(double fraction) {
    fraction = MIN(1.0, MAX(0.0, fraction));
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        return [UIColor colorWithHue:(1.0 - fraction) * 0.36
                          saturation:dark ? 0.78 : 0.92
                          brightness:dark ? 0.96 : 0.68
                               alpha:1.0];
    }];
}

// The pill: a ring that fills as the budget is used, and the count beside it.
@interface ApolloRateLimitMeterView : UIView
@property (nonatomic, strong) UIVisualEffectView *material;
@property (nonatomic, strong) CAShapeLayer *ringTrack;
@property (nonatomic, strong) CAShapeLayer *ringFill;
@property (nonatomic, strong) UIImageView *pausedGlyph;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) double fraction;
// Shows the time left after the count; set for a few seconds by a tap.
@property (nonatomic) BOOL expanded;
@end

@implementation ApolloRateLimitMeterView

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.18;
    self.layer.shadowRadius = 6.0;
    self.layer.shadowOffset = CGSizeMake(0, 2);

    _material = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    _material.clipsToBounds = YES;
    _material.layer.cornerRadius = kApolloRateLimitMeterHeight / 2.0;
    _material.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _material.userInteractionEnabled = NO;
    [self addSubview:_material];

    _ringTrack = [CAShapeLayer layer];
    _ringFill = [CAShapeLayer layer];
    for (CAShapeLayer *ring in @[ _ringTrack, _ringFill ]) {
        ring.fillColor = UIColor.clearColor.CGColor;
        ring.lineWidth = 3.0;
        ring.lineCap = kCALineCapRound;
        [_material.contentView.layer addSublayer:ring];
    }

    UIImageSymbolConfiguration *small = [UIImageSymbolConfiguration configurationWithPointSize:7.0 weight:UIImageSymbolWeightBold];
    _pausedGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pause.fill" withConfiguration:small]];
    _pausedGlyph.contentMode = UIViewContentModeCenter;
    _pausedGlyph.hidden = YES;
    [_material.contentView addSubview:_pausedGlyph];

    _label = [[UILabel alloc] init];
    [_material.contentView addSubview:_label];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton | UIAccessibilityTraitUpdatesFrequently;
    self.accessibilityLabel = @"Reddit requests used";
    self.accessibilityHint = @"Shows the time left. Drag to move.";
    return self;
}

- (void)showUsed:(double)used limit:(double)limit resetsIn:(NSTimeInterval)resetsIn known:(BOOL)known paused:(BOOL)paused {
    self.fraction = limit > 0 ? MIN(1.0, MAX(0.0, used / limit)) : 0.0;
    UIColor *color = ApolloRateLimitMeterColor(self.fraction);
    NSString *count = [NSString stringWithFormat:@"%ld", lround(MIN(used, limit))];
    NSString *rest = [NSString stringWithFormat:@"/%ld", lround(limit)];
    NSString *time = known ? ApolloRateLimitMeterTimeLeft(resetsIn) : nil;
    if (self.expanded) rest = [rest stringByAppendingFormat:@" · %@", time ? [@"resets in " stringByAppendingString:time] : @"nothing used yet"];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:count attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: color }];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:rest attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor }]];
    self.label.attributedText = text;
    self.pausedGlyph.hidden = !paused;
    self.pausedGlyph.tintColor = color;
    self.accessibilityValue = [NSString stringWithFormat:@"%@ of %ld%@%@", count, lround(limit),
                               time ? [@", resets in " stringByAppendingString:time] : @"",
                               paused ? @", extras paused" : @""];
    [self apollo_applyColors];
    [self setNeedsLayout];
}

// Layer colours don't follow light and dark by themselves.
- (void)apollo_applyColors {
    UITraitCollection *traits = self.traitCollection;
    self.ringFill.strokeColor = [ApolloRateLimitMeterColor(self.fraction) resolvedColorWithTraitCollection:traits].CGColor;
    self.ringTrack.strokeColor = [[UIColor.labelColor colorWithAlphaComponent:0.14] resolvedColorWithTraitCollection:traits].CGColor;
    self.material.layer.borderColor = [UIColor.separatorColor resolvedColorWithTraitCollection:traits].CGColor;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.ringFill.strokeEnd = (CGFloat)self.fraction;
    [CATransaction commit];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) [self apollo_applyColors];
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat text = ceil([self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, kApolloRateLimitMeterHeight)].width);
    return CGSizeMake(7.0 + kApolloRateLimitMeterRing + 6.0 + text + 11.0, kApolloRateLimitMeterHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    self.material.frame = bounds;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:CGRectGetHeight(bounds) / 2.0].CGPath;
    CGRect ring = CGRectMake(7.0, (CGRectGetHeight(bounds) - kApolloRateLimitMeterRing) / 2.0,
                             kApolloRateLimitMeterRing, kApolloRateLimitMeterRing);
    // From twelve o'clock, clockwise.
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(ring), CGRectGetMidY(ring))
                                                          radius:(kApolloRateLimitMeterRing - 3.0) / 2.0
                                                      startAngle:-M_PI_2
                                                        endAngle:1.5 * M_PI
                                                       clockwise:YES];
    self.ringTrack.path = circle.CGPath;
    self.ringFill.path = circle.CGPath;
    self.pausedGlyph.frame = ring;
    CGFloat labelX = CGRectGetMaxX(ring) + 6.0;
    self.label.frame = CGRectMake(labelX, 0, MAX(0.0, CGRectGetWidth(bounds) - labelX - 11.0), CGRectGetHeight(bounds));
}

@end

#pragma mark - Overlay window

// A window of its own above Apollo's UI, the way the floating post tabs and
// Picture in Picture do it: sheets, the media viewer and pushed screens all
// stay under it. It passes every touch through except those on the meter, and
// never becomes key (the status bar's scroll-to-top only looks in the key
// window).
@interface ApolloRateLimitMeterWindow : UIWindow
@property (nonatomic, weak) UIView *meter;
@end

@implementation ApolloRateLimitMeterWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *meter = self.meter;
    if (!hit || !meter || meter.hidden) return nil;
    return (hit == meter || [hit isDescendantOfView:meter]) ? hit : nil;
}
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

@interface ApolloRateLimitMeterRootViewController : UIViewController
@property (nonatomic, copy) void (^onGeometryChange)(void);
@property (nonatomic) CGSize lastSize;
@property (nonatomic) UIEdgeInsets lastInsets;
@end

@implementation ApolloRateLimitMeterRootViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
}
// Rotation, a fold, a change of safe area: anything that moves the edges the
// meter is kept inside.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    UIEdgeInsets insets = self.view.safeAreaInsets;
    if (CGSizeEqualToSize(size, self.lastSize) && UIEdgeInsetsEqualToEdgeInsets(insets, self.lastInsets)) return;
    self.lastSize = size;
    self.lastInsets = insets;
    if (self.onGeometryChange) self.onGeometryChange();
}
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self.view setNeedsLayout];
}
@end

#pragma mark - Controller

@interface ApolloRateLimitMeterController : NSObject
@property (nonatomic, strong) ApolloRateLimitMeterWindow *window;
@property (nonatomic, strong) ApolloRateLimitMeterRootViewController *root;
@property (nonatomic, strong) ApolloRateLimitMeterView *meter;
@property (nonatomic, strong) NSTimer *refreshTimer;
// Where the meter sits, as fractions of the space it can move in.
@property (nonatomic) CGPoint unitPosition;
@property (nonatomic) BOOL dragging;
@property (nonatomic) CGPoint dragOffset;
@property (nonatomic) NSUInteger expandGeneration;
// The limit last reported for the account shown, for the "0/100" of a fresh window.
@property (nonatomic) double lastLimit;
@end

@implementation ApolloRateLimitMeterController

+ (instancetype)shared {
    static ApolloRateLimitMeterController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ApolloRateLimitMeterController new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lastLimit = 100.0;
    // Top right, under the navigation bar, until it's been moved.
    _unitPosition = CGPointMake(1.0, 0.12);
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:UDKeyRateLimitMeterPosition];
    if (saved.count == 2 && [saved[0] isKindOfClass:[NSNumber class]] && [saved[1] isKindOfClass:[NSNumber class]]) {
        _unitPosition = CGPointMake(MIN(1.0, MAX(0.0, [saved[0] doubleValue])), MIN(1.0, MAX(0.0, [saved[1] doubleValue])));
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(budgetDidChange:) name:ApolloWebJSONBudgetDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(reevaluate) name:kApolloRateLimitMeterAccountChanged object:nil];
    [center addObserver:self selector:@selector(reevaluate) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(reevaluate) name:UISceneDidActivateNotification object:nil];
    return self;
}

- (void)budgetDidChange:(NSNotification *)notification {
    // Every answer to an API-Key-Free account lands here. With both features
    // off, which is how they ship, that's all it does.
    if (!sRateLimitWarnings && !sRateLimitMeter) return;
    NSString *account = ApolloRateLimitMeterAccount();
    NSString *changed = notification.userInfo[@"username"];
    if (!account || ![changed isKindOfClass:[NSString class]]) return;
    // Another signed-in account's count is not this one's business.
    if ([changed caseInsensitiveCompare:account] != NSOrderedSame) return;
    ApolloRateLimitWarnIfDue(account);
    [self refresh];
}

// Shows the meter when it should be up, takes it down when it shouldn't.
- (void)reevaluate {
    NSString *account = ApolloRateLimitMeterAccount();
    if (!sRateLimitMeter || !account) {
        [self tearDown];
        return;
    }
    [self ensureWindow];
    [self refresh];
}

- (void)tearDown {
    if (!self.window) return;
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
    self.expandGeneration++;
    self.window.hidden = YES;
    self.window = nil;
    self.root = nil;
    self.meter = nil;
    ApolloLog(@"[RateLimitMeter] removed");
}

// On the app window's scene, so on a foldable the meter is on the display the
// app is on.
- (UIWindowScene *)preferredScene {
    return ApolloDeviceAppWindow().windowScene ?: ApolloDevicePreferredWindowScene();
}

- (void)ensureWindow {
    UIWindowScene *scene = [self preferredScene];
    if (self.window) {
        if (scene && self.window.windowScene != scene) {
            self.window.windowScene = scene;
            ApolloLog(@"[RateLimitMeter] moved to scene %p", scene);
            [self placeMeterAnimated:NO];
        }
        self.window.hidden = NO;
        return;
    }
    // No scene yet (very early in launch): the scene's activation calls back in.
    if (!scene) return;

    ApolloRateLimitMeterWindow *window = [[ApolloRateLimitMeterWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelNormal + 49;   // over the app, just under the floating post tabs, under alerts and the keyboard
    window.backgroundColor = UIColor.clearColor;

    ApolloRateLimitMeterRootViewController *root = [ApolloRateLimitMeterRootViewController new];
    __weak typeof(self) weakSelf = self;
    root.onGeometryChange = ^{ [weakSelf placeMeterAnimated:NO]; };
    window.rootViewController = root;

    ApolloRateLimitMeterView *meter = [[ApolloRateLimitMeterView alloc] initWithFrame:CGRectZero];
    [meter addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(meterPanned:)]];
    [meter addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(meterTapped)]];
    [root.view addSubview:meter];
    window.meter = meter;

    self.window = window;
    self.root = root;
    self.meter = meter;
    window.hidden = NO;

    // The count only arrives with answers; the window ending and the time left
    // need the clock.
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:kApolloRateLimitMeterRefresh
                                                        repeats:YES
                                                          block:^(__unused NSTimer *timer) { [weakSelf refresh]; }];
    ApolloLog(@"[RateLimitMeter] shown");
}

// The overlay is its own window, so it follows the system's light or dark
// while Apollo's window can be forced to the other (a manual or scheduled
// theme). Mirror Apollo's choice.
- (void)mirrorAppAppearance {
    UIWindow *app = ApolloDeviceAppWindow();
    if (!app || app == self.window) return;
    if (self.window.overrideUserInterfaceStyle != app.overrideUserInterfaceStyle) {
        self.window.overrideUserInterfaceStyle = app.overrideUserInterfaceStyle;
    }
}

- (void)refresh {
    if (!self.meter) return;
    NSString *account = ApolloRateLimitMeterAccount();
    if (!sRateLimitMeter || !account) {
        [self tearDown];
        return;
    }
    [self mirrorAppAppearance];
    ApolloWebJSONBudgetState state = ApolloWebJSONBudgetCurrent(account);
    if (state.known) self.lastLimit = state.limit;
    // With nothing reported in this window the count is a fresh window's: none.
    [self.meter showUsed:state.known ? state.used : 0.0
                   limit:self.lastLimit
                resetsIn:state.resetsIn
                   known:state.known
                  paused:ApolloWebJSONOptionalReadPause(account) > 0];
    if (!self.dragging) [self placeMeterAnimated:NO];
}

#pragma mark Placement

// The rectangle the meter's CENTRE can be in: the safe area, in by a small gap
// and half the meter.
- (CGRect)centerBoundsForSize:(CGSize)size {
    UIView *container = self.root.view;
    CGRect area = UIEdgeInsetsInsetRect(container.bounds, container.safeAreaInsets);
    area = CGRectInset(area, kApolloRateLimitMeterEdge + size.width / 2.0, kApolloRateLimitMeterEdge + size.height / 2.0);
    if (CGRectGetWidth(area) < 0) area = CGRectMake(CGRectGetMidX(container.bounds), area.origin.y, 0, area.size.height);
    if (CGRectGetHeight(area) < 0) area = CGRectMake(area.origin.x, CGRectGetMidY(container.bounds), area.size.width, 0);
    return area;
}

- (void)placeMeterAnimated:(BOOL)animated {
    ApolloRateLimitMeterView *meter = self.meter;
    if (!meter || !self.root.isViewLoaded) return;
    CGSize size = [meter sizeThatFits:CGSizeZero];
    CGRect allowed = [self centerBoundsForSize:size];
    CGPoint center = CGPointMake(CGRectGetMinX(allowed) + self.unitPosition.x * CGRectGetWidth(allowed),
                                 CGRectGetMinY(allowed) + self.unitPosition.y * CGRectGetHeight(allowed));
    void (^apply)(void) = ^{
        meter.bounds = CGRectMake(0, 0, size.width, size.height);
        meter.center = center;
        [meter layoutIfNeeded];
    };
    if (animated) {
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)meterPanned:(UIPanGestureRecognizer *)pan {
    ApolloRateLimitMeterView *meter = self.meter;
    UIView *container = self.root.view;
    if (!meter || !container) return;
    CGPoint finger = [pan locationInView:container];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            self.dragging = YES;
            self.dragOffset = CGPointMake(meter.center.x - finger.x, meter.center.y - finger.y);
            break;
        case UIGestureRecognizerStateChanged:
            meter.center = CGPointMake(finger.x + self.dragOffset.x, finger.y + self.dragOffset.y);
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            // Wherever it's let go, it stays, pulled back inside the edges if
            // it was dragged past them.
            CGRect allowed = [self centerBoundsForSize:meter.bounds.size];
            CGFloat x = MIN(CGRectGetMaxX(allowed), MAX(CGRectGetMinX(allowed), meter.center.x));
            CGFloat y = MIN(CGRectGetMaxY(allowed), MAX(CGRectGetMinY(allowed), meter.center.y));
            self.unitPosition = CGPointMake(CGRectGetWidth(allowed) > 0 ? (x - CGRectGetMinX(allowed)) / CGRectGetWidth(allowed) : 0.5,
                                            CGRectGetHeight(allowed) > 0 ? (y - CGRectGetMinY(allowed)) / CGRectGetHeight(allowed) : 0.5);
            [[NSUserDefaults standardUserDefaults] setObject:@[ @(self.unitPosition.x), @(self.unitPosition.y) ]
                                                      forKey:UDKeyRateLimitMeterPosition];
            self.dragging = NO;
            [self placeMeterAnimated:YES];
            ApolloLog(@"[RateLimitMeter] moved to (%.2f, %.2f)", self.unitPosition.x, self.unitPosition.y);
            break;
        }
        default:
            break;
    }
}

// A tap spells out the time left for a few seconds.
- (void)meterTapped {
    if (!self.meter) return;
    self.meter.expanded = YES;
    [self refresh];
    [self placeMeterAnimated:YES];
    NSUInteger generation = ++self.expandGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloRateLimitMeterExpandedFor * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        // A later tap, or the meter going away, owns the collapse instead.
        if (!strongSelf || strongSelf.expandGeneration != generation || !strongSelf.meter) return;
        strongSelf.meter.expanded = NO;
        [strongSelf refresh];
        [strongSelf placeMeterAnimated:YES];
    });
}

@end

#pragma mark - Entry points

void ApolloRateLimitMeterInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ApolloRateLimitMeterController shared] reevaluate];
        ApolloLog(@"[RateLimitMeter] installed (warnings=%d meter=%d)", sRateLimitWarnings, sRateLimitMeter);
    });
}

void ApolloRateLimitMeterSettingsChanged(void) {
    [[ApolloRateLimitMeterController shared] reevaluate];
}
