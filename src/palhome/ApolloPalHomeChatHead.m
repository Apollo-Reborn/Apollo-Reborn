#import "ApolloPalHomeChatHead.h"
#import "ApolloPalHomeStore.h"
#import "ApolloPalHomeChrome.h"
#import "ApolloPalHomeHaptics.h"
#import "ApolloPalHomeShelterView.h"
#import "ApolloPixelCanvas.h"
#import "ApolloPalHomeRenderer.h"
#import "ApolloCommon.h"
#if APOLLO_SIM_BUILD
#import <notify.h>
#endif

static NSString *const kSideKey = @"ApolloRebornPalHomeChatHeadSide";   // 0 left, 1 right
static NSString *const kYKey = @"ApolloRebornPalHomeChatHeadY";         // centre y as a fraction of the height

// Art pixels: a 30px disc shown at 2pt per pixel (a 60pt bubble).
enum { kDisc = 30 };
static const CGFloat kPt = 2;

#pragma mark - Window

// Only touches on the bubble (and the ✕ while dragging) land here; the rest
// fall through to Apollo. Never key (see ApolloFloatingTabsWindow).
@interface APChatHeadWindow : UIWindow
@property (nonatomic, weak) UIView *bubble;
@end

@implementation APChatHeadWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *bubble = self.bubble;
    return bubble && !bubble.hidden && hit && (hit == bubble || [hit isDescendantOfView:bubble]) ? hit : nil;
}
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface APChatHeadRoot : UIViewController
@property (nonatomic, copy) void (^onResize)(void);
@end

@implementation APChatHeadRoot
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = UIColor.clearColor; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (weakSelf.onResize) weakSelf.onResize();
    }];
}
@end

#pragma mark - Controller

typedef NS_ENUM(NSInteger, APChatMood) { APChatMoodSit, APChatMoodWalk, APChatMoodRun, APChatMoodLie, APChatMoodSleep };

@interface APChatHead : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) APChatHeadWindow *window;
@property (nonatomic, strong) UIView *bubble;
@property (nonatomic, strong) UIImageView *disc, *pal;
@property (nonatomic) BOOL suppressed, dragging;
@property (nonatomic) BOOL napping;           // asleep (a nap from its routine, or carried over from Pal Home)
@property (nonatomic, strong) NSTimer *brainTimer;
@property (nonatomic, copy) NSString *residentKey; // species|coat|style: redraw when it changes
@property (nonatomic, copy) NSString *species, *coat;
@property (nonatomic) APChatMood mood;
@property (nonatomic) BOOL facingLeft;
@property (nonatomic) CFTimeInterval lastScroll, lastFling;
@property (nonatomic) CGFloat scrollSpeed; // points per second, smoothed
@property (nonatomic) CFTimeInterval lastScrollTime;
@property (nonatomic, strong) NSTimer *settleTimer;
@property (nonatomic) CGPoint dragOffset;
@property (nonatomic) CGFloat centreShift;
@property (nonatomic) BOOL transitioning; // the iris wipe owns the window
@property (nonatomic, strong) CAShapeLayer *irisMask;
@property (nonatomic, strong) UIView *iris;
@property (nonatomic, strong) CADisplayLink *irisLink;
@property (nonatomic, copy) void (^irisStep)(CFTimeInterval elapsed);
@property (nonatomic) CFTimeInterval irisStart; // art pixels: the sprite's own centre vs the frame's
@end

@implementation APChatHead

+ (instancetype)shared {
    static APChatHead *head;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        head = [APChatHead new];
#if APOLLO_SIM_BUILD
        // Sim testing (the debug tap can't reach this window):
        //   xcrun simctl spawn <DEV> notifyutil -p apollofix.palhome.chathead.tap
        int token;
        notify_register_dispatch("apollofix.palhome.chathead.tap", &token, dispatch_get_main_queue(), ^(int t) {
            if (head.isShowing) [head tapped];
        });
#endif
    });
    return head;
}

// Pal Home on, the Pal shown (Apollo's PixelPalsEnabled), and shown as the bubble.
- (BOOL)wanted {
    return ApolloPalHomeStore.isPalHomeEnabled && ApolloPalHomeStore.palDisplay == APPalDisplayBubble && [ApolloPalHomeStore new].islandEnabled;
}

- (BOOL)isShowing { return self.window && !self.window.hidden && !self.bubble.hidden; }

- (void)refresh {
    BOOL show = self.wanted && !self.suppressed && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    if (!show) {
        [self.settleTimer invalidate];
        // Mid iris wipe the window stays (the wipe is in it); just the bubble goes.
        if (self.transitioning) { self.bubble.hidden = YES; return; }
        self.window.hidden = YES;
        return;
    }
    self.bubble.hidden = NO;
    [self ensureWindow];
    if (!self.window) return; // no scene yet; refresh retries
    if (![self loadResident]) { self.window.hidden = YES; return; }
    BOOL appearing = self.window.hidden;
    self.window.hidden = NO;
    [self applyMood:self.napping ? APChatMoodSleep : (self.mood == APChatMoodSleep ? APChatMoodSit : self.mood) force:YES];
    if (appearing) [self scheduleBrain];
}

#pragma mark Building

- (void)ensureWindow {
    // A window needs a scene to be seen; at launch the scene may still be
    // connecting, so take any (active first) and otherwise try again later.
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class] || candidate.activationState == UISceneActivationStateUnattached) continue;
        if (!scene || candidate.activationState == UISceneActivationStateForegroundActive) scene = (UIWindowScene *)candidate;
    }
    if (self.window) {
        if (!self.window.windowScene && scene) self.window.windowScene = scene;
        return;
    }
    if (!scene) {
        ApolloLog(@"[PalHome] floating Pal waiting for a scene");
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
        return;
    }
    APChatHeadWindow *window = [[APChatHeadWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelNormal + 49; // just under Floating Post Tabs
    window.backgroundColor = UIColor.clearColor;
    APChatHeadRoot *root = [APChatHeadRoot new];
    __weak typeof(self) weakSelf = self;
    root.onResize = ^{ [weakSelf placeAnimated:NO]; };
    window.rootViewController = root;

    UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kDisc * kPt, kDisc * kPt)];
    bubble.layer.shadowColor = UIColor.blackColor.CGColor;
    bubble.layer.shadowOpacity = 0.35;
    bubble.layer.shadowRadius = 6;
    bubble.layer.shadowOffset = CGSizeMake(0, 3);
    UIImageView *disc = [[UIImageView alloc] initWithFrame:bubble.bounds];
    disc.layer.magnificationFilter = kCAFilterNearest;
    [bubble addSubview:disc];
    // The Pal, clipped to the inside of the disc.
    UIView *clip = [[UIView alloc] initWithFrame:CGRectInset(bubble.bounds, 2 * kPt, 2 * kPt)];
    clip.layer.cornerRadius = clip.bounds.size.width / 2;
    clip.clipsToBounds = YES;
    clip.userInteractionEnabled = NO;
    UIImageView *pal = [[UIImageView alloc] initWithFrame:CGRectZero];
    pal.layer.magnificationFilter = kCAFilterNearest;
    [clip addSubview:pal];
    [bubble addSubview:clip];
    bubble.isAccessibilityElement = YES;
    bubble.accessibilityTraits = UIAccessibilityTraitButton;
    bubble.accessibilityHint = @"Opens Pal Home. Drag to move it.";
    [bubble addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    [bubble addGestureRecognizer:pan];
    [root.view addSubview:bubble];

    window.bubble = bubble;
    self.window = window;
    self.bubble = bubble;
    self.disc = disc;
    self.pal = pal;
    window.hidden = NO;
    [self placeAnimated:NO];
    ApolloLog(@"[PalHome] floating Pal created");
}

// The island Pal, drawn into the bubble in their home style's colours.
- (BOOL)loadResident {
    ApolloPalHomeStore *store = [ApolloPalHomeStore new];
    ApolloPalHomeResident *pal = store.residents.firstObject;
    if (!pal.species) return NO;
    NSString *style = [store roomForResident:pal.identifier][@"style"];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@", pal.species, pal.coat, style, pal.name];
    self.bubble.accessibilityLabel = [NSString stringWithFormat:@"%@, floating", pal.name ?: @"Your Pal"];
    if ([key isEqualToString:self.residentKey]) return YES;
    self.residentKey = key;
    self.species = pal.species;
    self.coat = pal.coat ?: @"original";
    // Apollo's sprites sit off-centre in their 32px frames: centre on the
    // opaque pixels of the sitting pose (one shift for every pose, no jitter).
    self.centreShift = 0;
    UIImage *sit = APPalSpriteFrames(self.species, self.coat, @"sit", 1).firstObject;
    CGImageRef cg = sit.CGImage;
    if (cg) {
        size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
        uint8_t *alpha = calloc(w * h, 1);
        CGContextRef ctx = CGBitmapContextCreate(alpha, w, h, 8, w, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
            int minX = (int)w, maxX = -1;
            for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) if (alpha[y * w + x]) { minX = MIN(minX, (int)x); maxX = MAX(maxX, (int)x); }
            if (maxX >= minX) self.centreShift = (w / 2.0) - (minX + maxX + 1) / 2.0;
            CGContextRelease(ctx);
        }
        free(alpha);
    }

    APChromeTheme t = APChromeThemeForStyle(style);
    APCanvas *c = APCanvasCreate(kDisc, kDisc);
    APEllipse(c, 0, 0, kDisc, kDisc, t.panel.o);                    // rim
    APEllipse(c, 1, 1, kDisc - 2, kDisc - 2, t.panel.l);
    APEllipse(c, 2, 2, kDisc - 4, kDisc - 4, t.panel.m);            // inside
    APEllipse(c, 2, kDisc * 0.62, kDisc - 4, kDisc * 0.36, t.panel.d); // a little floor
    // A glassy highlight, top left.
    for (int i = 0; i < 6; i++) APPx(c, 7 + i / 2, 6 + (5 - i) / 2 + (i % 2), APMix(t.panel.l, 0xFFFFFF, 0.55f));
    APPx(c, 6, 9, APMix(t.panel.l, 0xFFFFFF, 0.4f));
    CGImageRef image = APCanvasCreateCGImage(c);
    APCanvasFree(c);
    self.disc.image = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    [self applyMood:self.mood force:YES];
    return YES;
}

#pragma mark Placement

- (CGRect)safeArea {
    UIView *root = self.window.rootViewController.view;
    return UIEdgeInsetsInsetRect(root.bounds, UIEdgeInsetsMake(root.safeAreaInsets.top + 8, 8, root.safeAreaInsets.bottom + 60, 8));
}

- (void)placeAnimated:(BOOL)animated {
    if (!self.bubble) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL right = [defaults objectForKey:kSideKey] ? [defaults boolForKey:kSideKey] : YES;
    double yFrac = [defaults objectForKey:kYKey] ? [defaults doubleForKey:kYKey] : 0.62;
    CGRect safe = [self safeArea];
    CGFloat half = self.bubble.bounds.size.width / 2;
    CGPoint centre = CGPointMake(right ? CGRectGetMaxX(safe) - half : CGRectGetMinX(safe) + half,
                                 MAX(CGRectGetMinY(safe) + half, MIN(CGRectGetMaxY(safe) - half, yFrac * self.window.bounds.size.height)));
    self.facingLeft = right; // look in towards the screen
    void (^move)(void) = ^{ self.bubble.center = centre; };
    if (animated) [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.4 options:0 animations:move completion:nil];
    else move();
    [self applyMood:self.mood force:YES];
}

#pragma mark Touch

// Tap: the Pal startles and hops, hearts burst out, then an iris wipe closes
// on the bubble and opens again on Pal Home (where the Pal hops in through
// the door). Reduce Motion: a haptic and a quick cross-fade instead.
- (void)tapped {
    if (self.transitioning) return;
    self.napping = NO; // tapping wakes it: it's awake at home too
    [self.brainTimer invalidate];
    APHapticPlay(APHapticSuccess);
    if (UIAccessibilityIsReduceMotionEnabled()) {
        UIView *root = self.window.rootViewController.view;
        UIView *fade = [[UIView alloc] initWithFrame:root.bounds];
        fade.backgroundColor = [UIColor colorWithRed:0.05 green:0.04 blue:0.07 alpha:1];
        fade.alpha = 0;
        fade.userInteractionEnabled = NO;
        [root addSubview:fade];
        self.transitioning = YES;
        [UIView animateWithDuration:0.18 animations:^{ fade.alpha = 1; } completion:^(BOOL finished) {
            ApolloPalHomeOpenFromAnywhere(NO);
            [UIView animateWithDuration:0.25 delay:0.05 options:0 animations:^{ fade.alpha = 0; } completion:^(BOOL done) {
                [fade removeFromSuperview];
                self.transitioning = NO;
                [self refresh];
            }];
        }];
        return;
    }
    self.transitioning = YES;
    [self.settleTimer invalidate];
    // 1. Startle and hop, with a squash, and a burst of hearts.
    [self applyMood:APChatMoodSit force:YES];
    UIImage *alert = APPalSpriteFrames(self.species, self.coat, @"alert", 1).firstObject;
    if (alert) { [self.pal stopAnimating]; self.pal.image = alert; }
    [UIView animateKeyframesWithDuration:0.42 delay:0 options:0 animations:^{
        [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.25 animations:^{
            self.bubble.transform = CGAffineTransformMakeScale(1.15, 0.85);
        }];
        [UIView addKeyframeWithRelativeStartTime:0.25 relativeDuration:0.35 animations:^{
            self.bubble.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.9, 1.12), CGAffineTransformMakeTranslation(0, -14));
        }];
        [UIView addKeyframeWithRelativeStartTime:0.6 relativeDuration:0.4 animations:^{ self.bubble.transform = CGAffineTransformIdentity; }];
    } completion:nil];
    [self burstHearts];
    // 2. The iris closes on the bubble…
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self_ = weakSelf;
        UIView *root = self_.window.rootViewController.view;
        CGPoint centre = self_.bubble.center;
        CGFloat far = hypot(MAX(centre.x, root.bounds.size.width - centre.x), MAX(centre.y, root.bounds.size.height - centre.y)) + 20;
        CGFloat ring = self_.bubble.bounds.size.width / 2 + 6;
        [self_ irisFrom:far to:ring around:centre duration:0.45 completion:^{
            APHapticPlay(APHapticThump);
            // 3. …a beat on the Pal, into the dark, and open on Pal Home.
            [UIView animateWithDuration:0.12 animations:^{ self_.bubble.transform = CGAffineTransformMakeScale(0.2, 0.2); self_.bubble.alpha = 0; }
                             completion:^(BOOL finished) {
                [self_ irisFrom:ring to:0 around:centre duration:0.08 completion:^{
                    ApolloPalHomeOpenFromAnywhere(NO);
                    self_.bubble.transform = CGAffineTransformIdentity;
                    self_.bubble.alpha = 1;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        CGPoint mid = CGPointMake(root.bounds.size.width / 2, root.bounds.size.height * 0.48);
                        CGFloat all = hypot(root.bounds.size.width, root.bounds.size.height) / 2 + 30;
                        [self_ irisFrom:0 to:all around:mid duration:0.55 completion:^{
                            [self_.iris removeFromSuperview];
                            self_.iris = nil;
                            self_.transitioning = NO;
                            [self_ refresh];
                        }];
                    });
                }];
            }];
        }];
    });
}

// Little pixel hearts popping out of the bubble.
- (void)burstHearts {
    APCanvas *c = APIconCanvas(@"smallheart");
    CGImageRef cg = APCanvasCreateCGImage(c);
    CGSize size = CGSizeMake(c->w * kPt, c->h * kPt);
    APCanvasFree(c);
    UIImage *heart = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    UIView *root = self.window.rootViewController.view;
    CGPoint origin = CGPointMake(self.bubble.center.x, self.bubble.center.y - 10);
    BOOL right = self.bubble.center.x > root.bounds.size.width / 2;
    for (int i = 0; i < 6; i++) {
        UIImageView *h = [[UIImageView alloc] initWithImage:heart];
        h.layer.magnificationFilter = kCAFilterNearest;
        h.frame = CGRectMake(0, 0, size.width, size.height);
        h.center = origin;
        h.userInteractionEnabled = NO;
        [root insertSubview:h belowSubview:self.bubble];
        // Fan out away from the screen edge, up and over.
        CGFloat angle = (right ? M_PI * 0.55 : M_PI * 0.05) + i * (M_PI * 0.4 / 5);
        CGFloat dist = 46 + (i % 3) * 12;
        CGPoint to = CGPointMake(origin.x + cos(angle) * dist * (right ? 1 : 1), origin.y - sin(angle) * dist - 10);
        if (right) to.x = origin.x - fabs(cos(angle)) * dist;
        h.transform = CGAffineTransformMakeScale(0.3, 0.3);
        [UIView animateWithDuration:0.55 delay:i * 0.025 usingSpringWithDamping:0.55 initialSpringVelocity:0.8 options:0 animations:^{
            h.center = to;
            h.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25 animations:^{ h.alpha = 0; h.center = CGPointMake(to.x, to.y - 10); }
                             completion:^(BOOL done) { [h removeFromSuperview]; }];
        }];
    }
}

// A dark screen with a round hole, radius stepping (chunky, retro) from
// `from` to `to` around `centre`.
- (void)irisFrom:(CGFloat)from to:(CGFloat)to around:(CGPoint)centre duration:(NSTimeInterval)duration completion:(void (^)(void))completion {
    UIView *root = self.window.rootViewController.view;
    if (!self.iris) {
        UIView *iris = [[UIView alloc] initWithFrame:root.bounds];
        iris.backgroundColor = [UIColor colorWithRed:0.05 green:0.035 blue:0.07 alpha:1];
        iris.userInteractionEnabled = NO;
        CAShapeLayer *mask = [CAShapeLayer layer];
        mask.fillRule = kCAFillRuleEvenOdd;
        iris.layer.mask = mask;
        [root insertSubview:iris belowSubview:self.bubble];
        self.iris = iris;
        self.irisMask = mask;
    }
    CGRect bounds = root.bounds;
    CAShapeLayer *mask = self.irisMask;
    void (^draw)(CGFloat) = ^(CGFloat r) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRect:bounds];
        if (r > 0.5) [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(centre.x - r, centre.y - r, r * 2, r * 2)]];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        mask.path = path.CGPath;
        [CATransaction commit];
    };
    draw(from);
    [self.irisLink invalidate];
    self.irisStart = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    self.irisStep = ^(CFTimeInterval elapsed) {
        __strong typeof(weakSelf) self_ = weakSelf;
        CGFloat t = MIN(1, elapsed / MAX(0.001, duration));
        CGFloat eased = from > to ? t * t : 1 - (1 - t) * (1 - t); // in when closing, out when opening
        CGFloat r = from + (to - from) * eased;
        draw(round(r / 6) * 6); // 6pt steps: a chunky pixel iris
        if (t >= 1) {
            [self_.irisLink invalidate];
            self_.irisLink = nil;
            draw(to);
            if (completion) completion();
        }
    };
    self.irisLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(irisTick:)];
    [self.irisLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)irisTick:(CADisplayLink *)link {
    if (self.irisStep) self.irisStep(CACurrentMediaTime() - self.irisStart);
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    UIView *root = self.window.rootViewController.view;
    CGPoint p = [pan locationInView:root];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            self.dragging = YES;
            self.napping = NO; // picked up: wide awake
            [self.brainTimer invalidate];
            self.dragOffset = CGPointMake(self.bubble.center.x - p.x, self.bubble.center.y - p.y);
            [UIView animateWithDuration:0.15 animations:^{ self.bubble.transform = CGAffineTransformMakeScale(1.08, 1.08); }];
            [self applyMood:APChatMoodWalk force:NO];
            APHapticPlay(APHapticSelect);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            self.bubble.center = CGPointMake(p.x + self.dragOffset.x, p.y + self.dragOffset.y);
            CGPoint v = [pan velocityInView:root];
            if (v.x != 0) self.facingLeft = v.x < 0;
            [self applyMood:fabs(v.x) + fabs(v.y) > 900 ? APChatMoodRun : APChatMoodWalk force:NO];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            self.dragging = NO;
            [UIView animateWithDuration:0.2 animations:^{ self.bubble.transform = CGAffineTransformIdentity; }];
            // Fling-aware: carry on a little in the throw's direction, then stick to a side.
            CGPoint v = [pan velocityInView:root];
            CGPoint landing = CGPointMake(self.bubble.center.x + v.x * 0.15, self.bubble.center.y + v.y * 0.15);
            [NSUserDefaults.standardUserDefaults setBool:landing.x > root.bounds.size.width / 2 forKey:kSideKey];
            [NSUserDefaults.standardUserDefaults setDouble:landing.y / MAX(1, root.bounds.size.height) forKey:kYKey];
            APHapticPlay(APHapticPlace);
            [self placeAnimated:YES];
            [self applyMood:APChatMoodSit force:NO];
            [self scheduleBrain];
            break;
        }
        default: break;
    }
}

#pragma mark Moods

- (BOOL)isLate {
    NSInteger hour = [NSCalendar.currentCalendar component:NSCalendarUnitHour fromDate:NSDate.date];
    return hour >= 22 || hour < 7;
}

- (void)applyMood:(APChatMood)mood force:(BOOL)force {
    if (!self.species || !self.pal) return;
    if (mood == self.mood && !force) return;
    self.mood = mood;
    NSString *action = @[@"sit", @"walk", @"run", @"lie", @"sleep"][mood];
    NSArray<UIImage *> *frames = APPalSpriteFrames(self.species, self.coat, action, 1);
    if (!frames.count) frames = APPalSpriteFrames(self.species, self.coat, @"sit", 1);
    if (!frames.count) return;
    [self.pal stopAnimating];
    self.pal.animationImages = frames.count > 1 ? frames : nil;
    self.pal.image = frames.firstObject;
    double perFrame = mood == APChatMoodRun ? 0.06 : mood == APChatMoodWalk ? 0.1 : mood == APChatMoodSleep ? 0.6 : 0.16;
    self.pal.animationDuration = perFrame * frames.count;
    // 32×14 frames at 2pt per pixel, feet on the disc's little floor.
    UIView *clip = self.pal.superview;
    CGFloat w = 32 * kPt, h = 14 * kPt;
    self.pal.frame = CGRectMake(round((clip.bounds.size.width - w) / 2 / kPt) * kPt, clip.bounds.size.height - h - 5 * kPt, w, h);
    [self applyFacing];
    if (frames.count > 1 && !UIAccessibilityIsReduceMotionEnabled()) [self.pal startAnimating];
}

// Facing, plus the centring shift (mirrored with the sprite).
- (void)applyFacing {
    CGFloat shift = round(self.centreShift) * kPt;
    self.pal.transform = self.facingLeft ? CGAffineTransformMake(-1, 0, 0, 1, -shift, 0) : CGAffineTransformMakeTranslation(shift, 0);
}

// Scrolling: trot along, faster with the feed; a hop on a big fling. When it
// stops: a look round, then sit; a while later, a lie-down.
- (void)noteScroll:(CGFloat)dy {
    if (!self.isShowing || self.dragging || self.transitioning) return;
    self.napping = NO;
    [self.brainTimer invalidate];
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval dt = MAX(1.0 / 120, now - self.lastScrollTime);
    self.lastScrollTime = now;
    CGFloat speed = fabs(dy) / dt;
    self.scrollSpeed = self.scrollSpeed * 0.7 + speed * 0.3;
    // Content moving up (reading down the feed) → the Pal runs "forward".
    BOOL right = [NSUserDefaults.standardUserDefaults objectForKey:kSideKey] ? [NSUserDefaults.standardUserDefaults boolForKey:kSideKey] : YES;
    self.facingLeft = dy > 0 ? right : !right;
    [self applyMood:self.scrollSpeed > 1400 ? APChatMoodRun : APChatMoodWalk force:NO];
    [self applyFacing];
    if (self.scrollSpeed > 3500 && now - self.lastFling > 1.2 && !UIAccessibilityIsReduceMotionEnabled()) {
        self.lastFling = now;
        // Wheee: a little hop of the whole bubble.
        [UIView animateKeyframesWithDuration:0.45 delay:0 options:0 animations:^{
            [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.4 animations:^{
                self.bubble.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.94, 1.06), CGAffineTransformMakeTranslation(0, -10));
            }];
            [UIView addKeyframeWithRelativeStartTime:0.4 relativeDuration:0.6 animations:^{ self.bubble.transform = CGAffineTransformIdentity; }];
        } completion:nil];
    }
    [self.settleTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.settleTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *timer) { [weakSelf settle]; }];
}

- (void)settle {
    self.scrollSpeed = 0;
    [self applyMood:APChatMoodSit force:NO];
    [self scheduleBrain];
}

// Its own little routine between your scrolls, like the Pal at home: sit and
// look about, trot on the spot, lounge, and now and then a nap (likelier late
// at night; naps end on their own, or when you scroll or pick it up).
- (void)scheduleBrain {
    [self.brainTimer invalidate];
    if (!self.isShowing) return;
    __weak typeof(self) weakSelf = self;
    NSTimeInterval wait = self.napping ? 25 + arc4random_uniform(40) : 5 + arc4random_uniform(9);
    self.brainTimer = [NSTimer scheduledTimerWithTimeInterval:wait repeats:NO block:^(NSTimer *timer) { [weakSelf think]; }];
}

- (void)think {
    if (!self.isShowing || self.dragging || self.transitioning) { [self scheduleBrain]; return; }
    if (self.napping) {
        // Waking up: a stretch (alert), then sit.
        self.napping = NO;
        [self perk];
        [self scheduleBrain];
        return;
    }
    uint32_t roll = arc4random_uniform(100);
    int napChance = [self isLate] ? 30 : 8;
    if (roll < napChance) {
        self.napping = YES;
        [self applyMood:APChatMoodSleep force:NO];
    } else if (roll < napChance + 22) {
        [self applyMood:APChatMoodLie force:NO];       // lounging
    } else if (roll < napChance + 44) {
        // A little trot on the spot, then sit.
        self.facingLeft = arc4random_uniform(2);
        [self applyMood:APChatMoodWalk force:NO];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf.mood == APChatMoodWalk && !weakSelf.dragging) [weakSelf applyMood:APChatMoodSit force:NO];
        });
    } else {
        // Sit and look about.
        self.facingLeft = !self.facingLeft;
        [self applyMood:APChatMoodSit force:YES];
    }
    [self scheduleBrain];
}

// Ears up: the alert pose for a moment, then sit.
- (void)perk {
    UIImage *alert = APPalSpriteFrames(self.species, self.coat, @"alert", 1).firstObject;
    [self applyMood:APChatMoodSit force:YES];
    if (!alert) return;
    [self.pal stopAnimating];
    self.pal.image = alert;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.mood == APChatMoodSit && !weakSelf.napping) [weakSelf applyMood:APChatMoodSit force:YES];
    });
}

// Back in the app: a nap carries on, otherwise ears up — you're back!
- (void)welcomeBack {
    if (!self.isShowing || self.napping) { [self scheduleBrain]; return; }
    [self perk];
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        [UIView animateKeyframesWithDuration:0.4 delay:0.1 options:0 animations:^{
            [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.45 animations:^{
                self.bubble.transform = CGAffineTransformMakeTranslation(0, -8);
            }];
            [UIView addKeyframeWithRelativeStartTime:0.45 relativeDuration:0.55 animations:^{ self.bubble.transform = CGAffineTransformIdentity; }];
        } completion:nil];
    }
    [self scheduleBrain];
}

@end

#pragma mark - API

void ApolloPalChatHeadRefresh(void) {
    dispatch_block_t work = ^{ [[APChatHead shared] refresh]; };
    if (NSThread.isMainThread) work(); else dispatch_async(dispatch_get_main_queue(), work);
}

void ApolloPalChatHeadSetSuppressed(BOOL suppressed) {
    APChatHead *head = [APChatHead shared];
    if (head.suppressed == suppressed) return;
    head.suppressed = suppressed;
    [head refresh];
}

BOOL ApolloPalChatHeadIsShowing(void) { return [APChatHead shared].isShowing; }

void ApolloPalChatHeadSetNapping(BOOL napping) {
    APChatHead *head = [APChatHead shared];
    head.napping = napping;
    if (head.isShowing) {
        [head applyMood:napping ? APChatMoodSleep : APChatMoodSit force:YES];
        [head scheduleBrain];
    }
}

void ApolloPalChatHeadWelcomeBack(void) { [[APChatHead shared] welcomeBack]; }

void ApolloPalChatHeadNoteScroll(UIScrollView *scrollView, CGFloat dy) {
    APChatHead *head = [APChatHead shared];
    if (!head.isShowing || scrollView.window == head.window) return;
    // Only the person scrolling counts (not programmatic jumps).
    if (!scrollView.isDragging && !scrollView.isDecelerating) return;
    [head noteScroll:dy];
}
