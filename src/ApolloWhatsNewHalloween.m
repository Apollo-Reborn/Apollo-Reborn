// ApolloWhatsNewHalloween — one-off Halloween look for the 3.9.0 What's New
// sheet (Count Helios icon, pumpkin-orange accent, bats). See
// ApolloWhatsNewHalloween.h for when it applies and how to remove it.
//
// Each bat is three nested layers:
//   flight (CALayer)      follows a two-part Bézier path from the app icon,
//                         swoops across the sheet once, then leaves past one
//                         of its edges; scales up and fades in as it leaves
//                         the icon so it reads as bursting out of it
//   tilt   (CALayer)      a slow side-to-side bank, kept off the flight layer
//                         so its rotation doesn't fight the scale animation
//   shape  (CAShapeLayer) the silhouette; its path morphs between wings-up
//                         and wings-down, bobbing a little with each stroke
//                         and jittering a few points off the flight path
//
// Every layer's model value is its final state (the flight layer sits at the
// off-screen exit point), so nothing snaps back into view when the animations
// end, and a bat whose start is still delayed waits off-screen. The overlay
// removes itself when the last animation finishes, with a timed fallback.

#import "ApolloWhatsNewHalloween.h"

#import <QuartzCore/QuartzCore.h>

#import "ApolloCommon.h"

static NSString *const kApolloWhatsNewHalloweenVersion = @"3.9.0";

static const NSUInteger kApolloBatCount = 9;
// Wing angle above horizontal, in radians, at the top and bottom of a stroke.
static const CGFloat kApolloBatWingUp = 0.75;
static const CGFloat kApolloBatWingDown = -0.30;

BOOL ApolloWhatsNewHalloweenWantedForVersion(NSString *version) {
    return [version isEqualToString:kApolloWhatsNewHalloweenVersion];
}

static UIImage *ApolloWhatsNewHalloweenBundledIcon(NSString *name) {
    NSString *path = ApolloBundledResourcePath(name, @"png");
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    return data ? [UIImage imageWithData:data scale:3.0] : nil;   // 192px = 64pt @3x
}

UIImage *ApolloWhatsNewHalloweenIcon(void) {
    UIImage *light = ApolloWhatsNewHalloweenBundledIcon(@"WhatsNewCountHelios");
    UIImage *dark = ApolloWhatsNewHalloweenBundledIcon(@"WhatsNewCountHeliosDark");
    if (!light) {
        ApolloLog(@"[WhatsNew] Count Helios icon missing from the bundle; keeping the app icon");
        return nil;
    }
    if (!dark) return light;
    // One image whose variant follows the image view's appearance.
    UITraitCollection *lightTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    UITraitCollection *darkTraits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
    UIImageAsset *asset = [[UIImageAsset alloc] init];
    [asset registerImage:light withTraitCollection:lightTraits];
    [asset registerImage:dark withTraitCollection:darkTraits];
    return [asset imageWithTraitCollection:lightTraits];
}

UIColor *ApolloWhatsNewHalloweenAccent(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:1.00 green:0.478 blue:0.10 alpha:1.0]    // #FF7A1A
            : [UIColor colorWithRed:0.93 green:0.42 blue:0.08 alpha:1.0];    // #ED6B14
    }];
}

static CGFloat ApolloBatsRandom(CGFloat lo, CGFloat hi) {
    return lo + (hi - lo) * ((CGFloat)arc4random_uniform(10001) / 10000.0);
}

// MARK: - Silhouette
//
// Built in "bat units": x right, y UP, origin at the body, 1.0 = half the
// wingspan. ApolloBatMap turns them into points in a 2r x 2r box (y down).
// Every subpath is wound clockwise on screen so the nonzero fill unions them;
// a counter-wound wing would punch a hole where it overlaps the body. Each
// call emits the same element sequence whatever the wing angle, which is what
// lets CABasicAnimation morph one path into the other.

static CGPoint ApolloBatMap(CGFloat r, CGPoint unit) {
    return CGPointMake(r + unit.x * r, r - unit.y * r);
}

static CGPoint ApolloBatPolar(CGPoint from, CGFloat length, CGFloat angle, CGFloat side) {
    return CGPointMake(from.x + side * length * cos(angle), from.y + length * sin(angle));
}

// Control point for a scalloped trailing edge: the midpoint of a and b,
// pulled 35% of the way toward the shoulder so the edge curves inward.
static CGPoint ApolloBatScallop(CGPoint a, CGPoint b, CGPoint shoulder) {
    CGPoint mid = CGPointMake((a.x + b.x) / 2.0, (a.y + b.y) / 2.0);
    return CGPointMake(mid.x + 0.35 * (shoulder.x - mid.x), mid.y + 0.35 * (shoulder.y - mid.y));
}

static void ApolloBatAddEllipse(UIBezierPath *path, CGFloat r, CGPoint unitCenter, CGFloat rx, CGFloat ry) {
    CGPoint c = ApolloBatMap(r, unitCenter);
    CGFloat ax = rx * r, ay = ry * r, k = 0.5523;
    // top -> right -> bottom -> left: clockwise on screen
    [path moveToPoint:CGPointMake(c.x, c.y - ay)];
    [path addCurveToPoint:CGPointMake(c.x + ax, c.y) controlPoint1:CGPointMake(c.x + k * ax, c.y - ay) controlPoint2:CGPointMake(c.x + ax, c.y - k * ay)];
    [path addCurveToPoint:CGPointMake(c.x, c.y + ay) controlPoint1:CGPointMake(c.x + ax, c.y + k * ay) controlPoint2:CGPointMake(c.x + k * ax, c.y + ay)];
    [path addCurveToPoint:CGPointMake(c.x - ax, c.y) controlPoint1:CGPointMake(c.x - k * ax, c.y + ay) controlPoint2:CGPointMake(c.x - ax, c.y + k * ay)];
    [path addCurveToPoint:CGPointMake(c.x, c.y - ay) controlPoint1:CGPointMake(c.x - ax, c.y - k * ay) controlPoint2:CGPointMake(c.x - k * ax, c.y - ay)];
    [path closePath];
}

static void ApolloBatAddWing(UIBezierPath *path, CGFloat r, CGFloat angle, CGFloat side) {
    CGPoint shoulder = CGPointMake(0.08 * side, 0.10);
    CGPoint root = CGPointMake(0.09 * side, -0.10);
    CGPoint tip = ApolloBatPolar(shoulder, 0.92, angle, side);
    CGPoint finger2 = ApolloBatPolar(shoulder, 0.78, angle - 0.55, side);
    CGPoint finger3 = ApolloBatPolar(shoulder, 0.55, angle - 1.05, side);
    CGPoint leading = ApolloBatPolar(shoulder, 0.58, angle + 0.30, side);   // bulges the leading edge up
    CGPoint s1 = ApolloBatScallop(tip, finger2, shoulder);
    CGPoint s2 = ApolloBatScallop(finger2, finger3, shoulder);
    CGPoint s3 = ApolloBatScallop(finger3, root, shoulder);

    [path moveToPoint:ApolloBatMap(r, shoulder)];
    if (side > 0) {
        // shoulder -> tip -> fingers -> root runs clockwise on the right
        [path addQuadCurveToPoint:ApolloBatMap(r, tip) controlPoint:ApolloBatMap(r, leading)];
        [path addQuadCurveToPoint:ApolloBatMap(r, finger2) controlPoint:ApolloBatMap(r, s1)];
        [path addQuadCurveToPoint:ApolloBatMap(r, finger3) controlPoint:ApolloBatMap(r, s2)];
        [path addQuadCurveToPoint:ApolloBatMap(r, root) controlPoint:ApolloBatMap(r, s3)];
    } else {
        // mirrored, so walk it backwards to stay clockwise
        [path addLineToPoint:ApolloBatMap(r, root)];
        [path addQuadCurveToPoint:ApolloBatMap(r, finger3) controlPoint:ApolloBatMap(r, s3)];
        [path addQuadCurveToPoint:ApolloBatMap(r, finger2) controlPoint:ApolloBatMap(r, s2)];
        [path addQuadCurveToPoint:ApolloBatMap(r, tip) controlPoint:ApolloBatMap(r, s1)];
        [path addQuadCurveToPoint:ApolloBatMap(r, shoulder) controlPoint:ApolloBatMap(r, leading)];
    }
    [path closePath];
}

static void ApolloBatAddEar(UIBezierPath *path, CGFloat r, CGFloat side) {
    CGPoint outer = CGPointMake(0.10 * side, 0.24);
    CGPoint tip = CGPointMake(0.085 * side, 0.42);
    CGPoint inner = CGPointMake(0.02 * side, 0.28);
    // outer -> tip -> inner is clockwise for the left ear; reverse on the right
    CGPoint first = side < 0 ? outer : inner;
    CGPoint last = side < 0 ? inner : outer;
    [path moveToPoint:ApolloBatMap(r, first)];
    [path addLineToPoint:ApolloBatMap(r, tip)];
    [path addLineToPoint:ApolloBatMap(r, last)];
    [path closePath];
}

// Returns the UIBezierPath, not its CGPath: a CGPath read off a local path
// that is released when the function returns would dangle under ARC.
static UIBezierPath *ApolloBatPath(CGFloat r, CGFloat wingAngle) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    ApolloBatAddWing(path, r, wingAngle, -1);
    ApolloBatAddWing(path, r, wingAngle, 1);
    ApolloBatAddEllipse(path, r, CGPointMake(0, -0.02), 0.115, 0.21);   // body
    ApolloBatAddEllipse(path, r, CGPointMake(0, 0.20), 0.10, 0.10);     // head
    ApolloBatAddEar(path, r, -1);
    ApolloBatAddEar(path, r, 1);
    return path;
}

// MARK: - Flight

// Up and out of the icon first, through `via` (the swoop across the sheet),
// then out past the edge, with a continuous tangent at `via`.
static UIBezierPath *ApolloBatFlightPath(CGPoint start, CGPoint via, CGPoint exit) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:start];
    CGPoint c1 = CGPointMake(start.x + ApolloBatsRandom(-90, 90), start.y - ApolloBatsRandom(60, 150));
    CGPoint c2 = CGPointMake(via.x + ApolloBatsRandom(-90, 90), via.y + ApolloBatsRandom(-70, 70));
    [path addCurveToPoint:via controlPoint1:c1 controlPoint2:c2];
    CGPoint c3 = CGPointMake(2.0 * via.x - c2.x, 2.0 * via.y - c2.y);
    CGPoint c4 = CGPointMake(exit.x + ApolloBatsRandom(-60, 60), exit.y + ApolloBatsRandom(-60, 60));
    [path addCurveToPoint:exit controlPoint1:c3 controlPoint2:c4];
    return path;
}

void ApolloWhatsNewPlayBats(UIView *hostView, CGPoint origin, NSTimeInterval delay) {
    if (!hostView) return;
    if (UIAccessibilityIsReduceMotionEnabled()) {
        ApolloLog(@"[WhatsNew] Halloween bats skipped (Reduce Motion)");
        return;
    }
    CGRect bounds = hostView.bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    if (width < 1.0 || height < 1.0) return;

    UIView *overlay = [[UIView alloc] initWithFrame:bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.userInteractionEnabled = NO;
    overlay.isAccessibilityElement = NO;
    overlay.accessibilityElementsHidden = YES;
    [hostView addSubview:overlay];

    // Near-black silhouettes. On dark sheets they carry a pumpkin-orange glow
    // so they stay visible against the near-black background.
    BOOL dark = hostView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    UIColor *fill = [UIColor colorWithRed:0.06 green:0.05 blue:0.07 alpha:0.94];
    UIColor *shadow = dark ? [UIColor colorWithRed:1.0 green:0.48 blue:0.10 alpha:1.0] : UIColor.blackColor;

    CFTimeInterval now = [overlay.layer convertTime:CACurrentMediaTime() fromLayer:nil];
    CFTimeInterval lastEnd = 0;
    __weak UIView *weakOverlay = overlay;

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        if (!weakOverlay.superview) return;
        [weakOverlay removeFromSuperview];
        ApolloLog(@"[WhatsNew] Halloween bats finished, overlay removed");
    }];
    for (NSUInteger i = 0; i < kApolloBatCount; i++) {
        CGFloat r = ApolloBatsRandom(13.0, 24.0);   // half the wingspan
        CGFloat margin = 2.0 * r + 24.0;
        CGPoint start = CGPointMake(origin.x + ApolloBatsRandom(-8, 8), origin.y + ApolloBatsRandom(-6, 6));
        CGPoint via, exit;
        switch (i % 3) {
            case 0:   // swoop right, leave left
                via = CGPointMake(width * ApolloBatsRandom(0.55, 0.85), height * ApolloBatsRandom(0.12, 0.60));
                exit = CGPointMake(-margin, height * ApolloBatsRandom(0.08, 0.70));
                break;
            case 1:   // swoop left, leave right
                via = CGPointMake(width * ApolloBatsRandom(0.15, 0.45), height * ApolloBatsRandom(0.12, 0.60));
                exit = CGPointMake(width + margin, height * ApolloBatsRandom(0.08, 0.70));
                break;
            default:  // dip down, leave through the top
                via = CGPointMake(width * ApolloBatsRandom(0.20, 0.80), height * ApolloBatsRandom(0.30, 0.65));
                exit = CGPointMake(width * ApolloBatsRandom(0.20, 0.80), -margin);
                break;
        }
        CFTimeInterval duration = ApolloBatsRandom(2.4, 3.2);
        CFTimeInterval begin = now + delay + i * 0.07 + ApolloBatsRandom(0.0, 0.10);
        lastEnd = MAX(lastEnd, begin + duration - now);

        CALayer *flight = [CALayer layer];
        flight.bounds = CGRectMake(0, 0, 2.0 * r, 2.0 * r);
        flight.position = exit;   // model value = where it ends up, off-screen
        [overlay.layer addSublayer:flight];

        CALayer *tilt = [CALayer layer];
        tilt.frame = flight.bounds;
        [flight addSublayer:tilt];

        CAShapeLayer *bat = [CAShapeLayer layer];
        bat.frame = tilt.bounds;
        bat.fillColor = fill.CGColor;
        bat.path = ApolloBatPath(r, (kApolloBatWingUp + kApolloBatWingDown) / 2.0).CGPath;
        bat.shadowColor = shadow.CGColor;
        bat.shadowOffset = dark ? CGSizeZero : CGSizeMake(0, 1);
        bat.shadowRadius = dark ? 3.0 : 1.5;
        bat.shadowOpacity = dark ? 0.85 : 0.22;
        [tilt addSublayer:bat];

        CAKeyframeAnimation *fly = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        fly.path = ApolloBatFlightPath(start, via, exit).CGPath;
        fly.calculationMode = kCAAnimationPaced;
        fly.beginTime = begin;
        fly.duration = duration;
        [flight addAnimation:fly forKey:@"apollo.bats.flight"];

        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        grow.fromValue = @0.15;
        grow.toValue = @1.0;
        grow.beginTime = begin;
        grow.duration = 0.45;
        grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [flight addAnimation:grow forKey:@"apollo.bats.grow"];

        CABasicAnimation *appear = [CABasicAnimation animationWithKeyPath:@"opacity"];
        appear.fromValue = @0.0;
        appear.toValue = @1.0;
        appear.beginTime = begin;
        appear.duration = 0.2;
        [flight addAnimation:appear forKey:@"apollo.bats.appear"];

        CGFloat bank = ApolloBatsRandom(0.10, 0.25) * (arc4random_uniform(2) ? 1.0 : -1.0);
        CAKeyframeAnimation *sway = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        sway.values = @[@0.0, @(bank), @(-0.6 * bank), @(0.4 * bank), @0.0];
        sway.beginTime = begin;
        sway.duration = duration;
        [tilt addAnimation:sway forKey:@"apollo.bats.sway"];

        // Finite repeats (not HUGE_VALF) so the transaction can complete.
        CFTimeInterval stroke = ApolloBatsRandom(0.11, 0.16);
        CFTimeInterval phase = ApolloBatsRandom(0.0, 2.0 * stroke);
        CABasicAnimation *flap = [CABasicAnimation animationWithKeyPath:@"path"];
        flap.fromValue = (__bridge id)ApolloBatPath(r, kApolloBatWingUp).CGPath;
        flap.toValue = (__bridge id)ApolloBatPath(r, kApolloBatWingDown).CGPath;
        flap.beginTime = begin;
        flap.duration = stroke;
        flap.timeOffset = phase;
        flap.autoreverses = YES;
        flap.repeatDuration = duration;
        flap.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [bat addAnimation:flap forKey:@"apollo.bats.flap"];

        // Bats don't fly smooth curves: jitter the silhouette a few points
        // off the flight path every quarter second or so.
        NSUInteger steps = MAX((NSUInteger)4, (NSUInteger)(duration / 0.25));
        NSMutableArray<NSValue *> *jitter = [NSMutableArray arrayWithCapacity:steps + 1];
        for (NSUInteger j = 0; j <= steps; j++) {
            BOOL rest = (j == 0 || j == steps);
            [jitter addObject:[NSValue valueWithCGPoint:rest ? CGPointZero
                                                             : CGPointMake(ApolloBatsRandom(-6, 6), ApolloBatsRandom(-5, 5))]];
        }
        CAKeyframeAnimation *flutter = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        flutter.values = jitter;
        flutter.additive = YES;
        flutter.calculationMode = kCAAnimationCubic;
        flutter.beginTime = begin;
        flutter.duration = duration;
        [bat addAnimation:flutter forKey:@"apollo.bats.flutter"];

        // The body rises a little on each down-stroke.
        CABasicAnimation *bob = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        bob.fromValue = @(0.06 * r);
        bob.toValue = @(-0.06 * r);
        bob.beginTime = begin;
        bob.duration = stroke;
        bob.timeOffset = phase;
        bob.autoreverses = YES;
        bob.repeatDuration = duration;
        bob.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [bat addAnimation:bob forKey:@"apollo.bats.bob"];
    }
    [CATransaction commit];

    // Fallback in case the completion never fires (e.g. animations removed
    // while the app is in the background).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((lastEnd + 1.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakOverlay.superview) return;
        [weakOverlay removeFromSuperview];
        ApolloLog(@"[WhatsNew] Halloween bats overlay removed by the fallback timer");
    });
    ApolloLog(@"[WhatsNew] Halloween bats: %lu bats from (%.0f, %.0f) across %.0fx%.0f, done in %.1fs",
              (unsigned long)kApolloBatCount, origin.x, origin.y, width, height, lastEnd);
}
