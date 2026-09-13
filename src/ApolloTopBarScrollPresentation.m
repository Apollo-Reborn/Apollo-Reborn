#import "ApolloTopBarScrollPresentation.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>

static char kApolloTopBarScrollStateKey;
static NSString *const ApolloTopBarScrollAnimationKey = @"apollo.topBar.scrollTranslation";
static NSString *const ApolloTopBarScrollGenerationKey = @"apollo.topBar.generation";

// UIKit draws the top scroll-edge region inside the content scroll view,
// independently of UINavigationBar. This owner remains present even when the
// selected Header Style makes its effect transparent. Keep each exact top
// effect owner with the same presentation animation; its siblings include the
// BOTTOM effect and a capture-only source.
@interface ApolloTopBarHeaderPart : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic) BOOL originalInteractionEnabled;
@property (nonatomic) BOOL originalAccessibilityHidden;
@end
@implementation ApolloTopBarHeaderPart
@end

@class ApolloTopBarScrollState;
static NSHashTable<ApolloTopBarScrollState *> *sApolloTopBarActiveStates;
static void ApolloTopBarRestoreHeaderParts(ApolloTopBarScrollState *state);

@interface ApolloTopBarScrollState : NSObject <CAAnimationDelegate>
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic, weak) UINavigationBar *bar;
@property (nonatomic) BOOL hidden;
@property (nonatomic) BOOL originalInteractionEnabled;
@property (nonatomic) BOOL originalAccessibilityHidden;
@property (nonatomic) CGFloat hiddenOffset;
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) NSMutableArray<ApolloTopBarHeaderPart *> *headerParts;
@end

@implementation ApolloTopBarScrollState
- (void)animationDidStop:(CAAnimation *)animation finished:(__unused BOOL)finished {
    if (self.hidden ||
        [[animation valueForKey:ApolloTopBarScrollGenerationKey] unsignedIntegerValue] != self.generation) return;
    UINavigationController *controller = self.navigationController;
    if (controller && objc_getAssociatedObject(controller, &kApolloTopBarScrollStateKey) == self) {
        // UIKit may recreate or unhide the scroll view's top-edge effect while
        // returning the navigation bar to its visible pose. Reassert the
        // selected Header Style after that transition; this is especially
        // visible in Gallery, where Hidden must remain transparent on reveal.
        ApolloApplyScrollEdgeEffectStyleToViewController(controller.topViewController);
        // Only the rendered bar moves; its model hit targets stay put. Keep
        // them disabled until the reveal finishes (or UIKit removes it and
        // restores the canonical visible pose).
        ApolloTopBarRestoreHeaderParts(self);
        [sApolloTopBarActiveStates removeObject:self];
        self.bar.userInteractionEnabled = self.originalInteractionEnabled;
        self.bar.accessibilityElementsHidden = self.originalAccessibilityHidden;
        objc_setAssociatedObject(controller, &kApolloTopBarScrollStateKey, nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
@end

static ApolloTopBarScrollState *ApolloTopBarState(UINavigationController *controller) {
    return objc_getAssociatedObject(controller, &kApolloTopBarScrollStateKey);
}

static BOOL ApolloTopBarScrollEnabled(void) {
    return sHideTopBarOnScroll && ApolloSupportsNativeTabBarScrollBehavior() &&
        [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyNativeHideBarsOnScroll];
}

static void ApolloTopBarRestoreHeaderPart(ApolloTopBarHeaderPart *part) {
    [part.view.layer removeAnimationForKey:ApolloTopBarScrollAnimationKey];
    part.view.userInteractionEnabled = part.originalInteractionEnabled;
    part.view.accessibilityElementsHidden = part.originalAccessibilityHidden;
}

static void ApolloTopBarRestoreHeaderParts(ApolloTopBarScrollState *state) {
    for (ApolloTopBarHeaderPart *part in state.headerParts) ApolloTopBarRestoreHeaderPart(part);
    [state.headerParts removeAllObjects];
}

static BOOL ApolloTopBarIsNativeTopEffect(UIView *view) {
    static Class effectClass;
    static ptrdiff_t edgeOffset;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        effectClass = objc_getClass("UIKit.ScrollEdgeEffectView");
        Ivar edge = class_getInstanceVariable(effectClass, "edge");
        // UIKit stores this Swift RectEdge raw value as an eight-byte field.
        // It has no ObjC getter/type encoding. Validate its storage boundary
        // before reading, and fail open if a future UIKit changes the layout.
        edgeOffset = edge ? ivar_getOffset(edge) : -1;
        Ivar next = class_getInstanceVariable(effectClass, "reducedTransparency");
        if (edgeOffset < 0 || !next || ivar_getOffset(next) - edgeOffset != sizeof(uint64_t) ||
            (size_t)edgeOffset + sizeof(uint64_t) > class_getInstanceSize(effectClass)) {
            edgeOffset = -1;
        }
    });
    if (!effectClass || edgeOffset < 0 || ![view isKindOfClass:effectClass]) return NO;
    uint64_t edge = 0;
    memcpy(&edge, (const uint8_t *)(__bridge const void *)view + edgeOffset, sizeof(edge));
    return edge == 1; // UIKit top=1, bottom=4; never move the bottom material.
}

static BOOL ApolloTopBarHeaderBelongsToState(UIView *view, ApolloTopBarScrollState *state) {
    UIView *content = state.navigationController.topViewController.viewIfLoaded;
    if (!content || view.window != state.bar.window || ![view isDescendantOfView:content] ||
        view.hidden || view.alpha < 0.01 || !ApolloTopBarIsNativeTopEffect(view)) return NO;
    CGRect frame = [view convertRect:view.bounds toView:view.window];
    CGRect barFrame = [state.bar convertRect:state.bar.bounds toView:view.window];
    // Exclude independent scroll regions inside cells. A header pocket meets
    // this navigation bar in window coordinates, even on inverted lists.
    return CGRectIntersectsRect(frame, barFrame);
}

static void ApolloTopBarCopyAnimationToHeader(ApolloTopBarScrollState *state,
    ApolloTopBarHeaderPart *part) {
    UIView *view = part.view;
    if (!view.window || !view.superview) return;
    CABasicAnimation *source = (CABasicAnimation *)[state.bar.layer animationForKey:ApolloTopBarScrollAnimationKey];
    if (!source) return;
    // Convert window-space travel to the effect's local Y direction. Inverted
    // scroll views must still move their rendered header toward the screen top.
    CGPoint zero = [view.superview convertPoint:CGPointZero fromView:view.window];
    CGPoint unit = [view.superview convertPoint:CGPointMake(0, 1) fromView:view.window];
    CGFloat scale = unit.y - zero.y;
    CAAnimation *animation;
    if (!state.hidden && [source isKindOfClass:CASpringAnimation.class]) {
        CASpringAnimation *spring = (CASpringAnimation *)source;
        CGFloat mass = spring.mass;
        CGFloat stiffness = spring.stiffness;
        CGFloat damping = spring.damping;
        CGFloat start = [spring.fromValue doubleValue];
        CGFloat target = [spring.toValue doubleValue];
        CGFloat omega0 = sqrt(stiffness / mass);
        CGFloat zeta = damping / (2.0 * sqrt(stiffness * mass));
        CGFloat omegaD = omega0 * sqrt(MAX(0.0, 1.0 - zeta * zeta));
        NSUInteger sampleCount = MAX(2, MIN(240, (NSUInteger)ceil(spring.duration * 120.0) + 1));
        NSMutableArray<NSNumber *> *translations = [NSMutableArray arrayWithCapacity:sampleCount];
        NSMutableArray<NSNumber *> *scales = [NSMutableArray arrayWithCapacity:sampleCount];
        CGFloat effectHeight = CGRectGetHeight([view convertRect:view.bounds toView:view.window]);
        for (NSUInteger index = 0; index < sampleCount; index++) {
            CFTimeInterval time = spring.duration * index / (sampleCount - 1);
            CGFloat displacement;
            if (omegaD > 0.0001) {
                CGFloat initial = start - target;
                CGFloat velocity = spring.initialVelocity * (target - start);
                displacement = exp(-zeta * omega0 * time) *
                    (initial * cos(omegaD * time) +
                     ((velocity + zeta * omega0 * initial) / omegaD) * sin(omegaD * time));
            } else {
                // The current spring is underdamped, but keep a stable path if
                // its constants change to critical damping in the future.
                displacement = (start - target) * exp(-omega0 * time);
            }
            CGFloat windowOffset = target + displacement;
            CGFloat overshoot = MAX(0.0, windowOffset - target);
            // Preserve the complete spring at the material's bottom edge.
            // During positive overshoot, move its center half as far and grow
            // it by the other half. The top edge therefore remains pinned at
            // the screen while the lower edge bounces with the bar controls.
            CGFloat centerOffset = MIN(target, windowOffset) + overshoot / 2.0;
            [translations addObject:@(centerOffset * scale)];
            [scales addObject:@(1.0 + (effectHeight > 0.0 ? overshoot / effectHeight : 0.0))];
        }
        CAKeyframeAnimation *translation = [CAKeyframeAnimation animationWithKeyPath:source.keyPath];
        translation.values = translations;
        translation.calculationMode = kCAAnimationLinear;
        translation.duration = spring.duration;
        translation.additive = spring.additive;
        CAKeyframeAnimation *stretch = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
        stretch.values = scales;
        stretch.calculationMode = kCAAnimationLinear;
        stretch.duration = spring.duration;
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations = @[translation, stretch];
        group.duration = spring.duration;
        group.fillMode = spring.fillMode;
        group.removedOnCompletion = spring.removedOnCompletion;
        animation = group;
    } else {
        CABasicAnimation *copy = [source copy];
        copy.fromValue = @([source.fromValue doubleValue] * scale);
        copy.toValue = @([source.toValue doubleValue] * scale);
        animation = copy;
    }
    animation.delegate = nil; // Only the bar owns completion/interaction cleanup.
    animation.beginTime = [view.layer convertTime:source.beginTime fromLayer:state.bar.layer];
    [view.layer addAnimation:animation forKey:ApolloTopBarScrollAnimationKey];
}

static void ApolloTopBarAttachHeader(UIView *view, ApolloTopBarScrollState *state) {
    if (!ApolloTopBarHeaderBelongsToState(view, state)) return;
    for (ApolloTopBarHeaderPart *part in state.headerParts) {
        if (part.view == view) return;
    }
    ApolloTopBarHeaderPart *part = [ApolloTopBarHeaderPart new];
    part.view = view;
    part.originalInteractionEnabled = view.userInteractionEnabled;
    part.originalAccessibilityHidden = view.accessibilityElementsHidden;
    [state.headerParts addObject:part];
    // The native effect contains a TouchBlocker. Its model-space hit region
    // must not remain over the newly exposed content while it is offscreen.
    view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
    ApolloTopBarCopyAnimationToHeader(state, part);
}

static void ApolloTopBarCollectHeaders(UIView *view, ApolloTopBarScrollState *state) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    if (ApolloTopBarIsNativeTopEffect(view)) {
        ApolloTopBarAttachHeader(view, state);
        return;
    }
    for (UIView *child in view.subviews) ApolloTopBarCollectHeaders(child, state);
}

static void ApolloTopBarSynchronizeHeaders(ApolloTopBarScrollState *state) {
    for (ApolloTopBarHeaderPart *part in [state.headerParts copy]) {
        if (!part.view || !ApolloTopBarHeaderBelongsToState(part.view, state)) {
            ApolloTopBarRestoreHeaderPart(part);
            [state.headerParts removeObject:part];
        }
    }
    ApolloTopBarCollectHeaders(state.navigationController.topViewController.viewIfLoaded, state);
}

static CGFloat ApolloTopBarHiddenOffset(ApolloTopBarScrollState *state) {
    // Include Hard's full material height and the glass/shadow overhang so the
    // band and controls both clear the screen. Model geometry stays native.
    UIWindow *window = state.bar.window;
    CGRect frame = [state.bar convertRect:state.bar.bounds toView:window];
    CGFloat bottom = CGRectGetMaxY(frame);
    for (ApolloTopBarHeaderPart *part in state.headerParts) {
        bottom = MAX(bottom, CGRectGetMaxY([part.view convertRect:part.view.bounds toView:window]));
    }
    return -MAX(0.0, bottom - CGRectGetMinY(window.bounds) + 16.0);
}

static CGFloat ApolloTopBarPresentedOffset(ApolloTopBarScrollState *state) {
    CALayer *layer = state.bar.layer;
    if (![layer animationForKey:ApolloTopBarScrollAnimationKey]) return 0.0;
    CALayer *presentation = layer.presentationLayer;
    return presentation ? presentation.transform.m42 - layer.transform.m42 : state.hiddenOffset;
}

static void ApolloTopBarAnimate(ApolloTopBarScrollState *state, CGFloat from, CGFloat to, BOOL animated) {
    // Additive layer translation leaves UINavigationBar's frame, transform,
    // safe-area contribution, and UIKit's navigation transitions untouched.
    // Keep the completed hide as a presentation layer; remove only our key
    // when revealing or yielding to a real navigation transition.
    CAPropertyAnimation *animation;
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"transform.translation.y"];
        // Stretch the whole motion by 35% so the top bar keeps pace with the
        // bottom bar. Scaling stiffness by time squared and damping by time
        // preserves the spring's bounce; increasing duration alone does not
        // slow a physical spring. Header copies share these parameters/clock.
        const CGFloat timeScale = 1.35;
        spring.mass = 1.0;
        spring.stiffness = (state.hidden ? 420.0 : 320.0) / (timeScale * timeScale);
        spring.damping = (state.hidden ? 32.0 : 24.0) / timeScale;
        spring.initialVelocity = 0.0;
        spring.fromValue = @(from);
        spring.toValue = @(to);
        spring.duration = spring.settlingDuration;
        animation = spring;
    } else {
        CABasicAnimation *hold = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        hold.fromValue = @(to);
        hold.toValue = @(to);
        hold.duration = 0.001;
        animation = hold;
    }
    animation.beginTime = [state.bar.layer convertTime:CACurrentMediaTime() fromLayer:nil];
    animation.additive = YES;
    animation.fillMode = kCAFillModeBoth;
    animation.removedOnCompletion = !state.hidden;
    animation.delegate = state;
    [animation setValue:@(state.generation) forKey:ApolloTopBarScrollGenerationKey];
    [state.bar.layer addAnimation:animation forKey:ApolloTopBarScrollAnimationKey];
    for (ApolloTopBarHeaderPart *part in state.headerParts) ApolloTopBarCopyAnimationToHeader(state, part);
}

void ApolloTopBarRestoreNavigationController(UINavigationController *controller) {
    ApolloTopBarScrollState *state = ApolloTopBarState(controller);
    if (!state) return;
    state.generation++;
    ApolloTopBarRestoreHeaderParts(state);
    [sApolloTopBarActiveStates removeObject:state];
    [state.bar.layer removeAnimationForKey:ApolloTopBarScrollAnimationKey];
    state.bar.userInteractionEnabled = state.originalInteractionEnabled;
    state.bar.accessibilityElementsHidden = state.originalAccessibilityHidden;
    objc_setAssociatedObject(controller, &kApolloTopBarScrollStateKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloTopBarSetNavigationHidden(UINavigationController *controller, BOOL hidden,
    BOOL animated, NSString *reason) {
    if (!controller) return;
    UINavigationBar *bar = controller.navigationBar;
    ApolloTopBarScrollState *state = ApolloTopBarState(controller);
    if (state && state.bar != bar) {
        ApolloTopBarRestoreNavigationController(controller);
        state = nil;
    }
    if (hidden && (!ApolloTopBarScrollEnabled() || controller.navigationBarHidden ||
        !bar.window || bar.hidden || bar.alpha < 0.01)) hidden = NO;
    if (!hidden && !state) return;
    if (!hidden && (!animated || !bar.window || controller.navigationBarHidden)) {
        ApolloTopBarRestoreNavigationController(controller);
        return;
    }
    if (state && state.hidden == hidden && [bar.layer animationForKey:ApolloTopBarScrollAnimationKey]) return;
    if (!state) {
        state = [ApolloTopBarScrollState new];
        state.navigationController = controller;
        state.bar = bar;
        state.headerParts = [NSMutableArray array];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sApolloTopBarActiveStates = [NSHashTable weakObjectsHashTable];
            [[NSNotificationCenter defaultCenter] addObserverForName:ApolloScrollEdgeEffectStyleChangedNotification
                object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                    // Style changes rebuild the native pockets. Reconcile on
                    // the next turn, after the style owner's layout nudges.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        for (ApolloTopBarScrollState *active in sApolloTopBarActiveStates.allObjects) {
                            ApolloTopBarRevalidateNavigationController(active.navigationController);
                        }
                    });
                }];
        });
        [sApolloTopBarActiveStates addObject:state];
        state.originalInteractionEnabled = bar.userInteractionEnabled;
        state.originalAccessibilityHidden = bar.accessibilityElementsHidden;
        objc_setAssociatedObject(controller, &kApolloTopBarScrollStateKey, state,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloTopBarSynchronizeHeaders(state);
    CGFloat from = ApolloTopBarPresentedOffset(state);
    state.hidden = hidden;
    state.hiddenOffset = hidden ? ApolloTopBarHiddenOffset(state) : 0.0;
    state.generation++;
    bar.userInteractionEnabled = NO;
    bar.accessibilityElementsHidden = YES;
    ApolloTopBarAnimate(state, from, state.hiddenOffset, animated);
    ApolloLog(@"[AutoHideTopBar] %@ offset=%.1f headerEffects=%lu reason=%@",
        hidden ? @"hidden" : @"revealed", state.hiddenOffset, (unsigned long)state.headerParts.count, reason);
}

static UINavigationController *ApolloTopBarNavigationController(UIViewController *controller) {
    return [controller isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)controller : controller.navigationController;
}

void ApolloTopBarSetScrollHidden(UITabBarController *controller, BOOL hidden,
    BOOL animated, NSString *reason) {
    UINavigationController *selected = ApolloTopBarNavigationController(controller.selectedViewController);
    // A tab switch must release the OLD bar as well as configure the new one.
    // Each navigation controller retains only its own state, with weak views.
    for (UIViewController *child in controller.viewControllers) {
        UINavigationController *navigation = ApolloTopBarNavigationController(child);
        if (navigation != selected) ApolloTopBarRestoreNavigationController(navigation);
    }
    ApolloTopBarSetNavigationHidden(selected, hidden, animated, reason);
}

void ApolloTopBarRevalidateNavigationController(UINavigationController *controller) {
    ApolloTopBarScrollState *state = ApolloTopBarState(controller);
    if (!state) return;
    UINavigationBar *bar = controller.navigationBar;
    if (!ApolloTopBarScrollEnabled() || state.bar != bar || controller.navigationBarHidden ||
        !bar.window || bar.hidden || bar.alpha < 0.01) {
        ApolloTopBarRestoreNavigationController(controller);
        return;
    }
    ApolloTopBarSynchronizeHeaders(state);
    if (!state.hidden) return;
    CGFloat offset = ApolloTopBarHiddenOffset(state);
    CAAnimation *current = [bar.layer animationForKey:ApolloTopBarScrollAnimationKey];
    if (offset < state.hiddenOffset - 0.5 || !current) {
        // A newly created/taller Hard pocket may need more travel. Retarget
        // from the rendered pose while the spring is running. Keep sufficient
        // travel when search collapses and makes the native header shorter;
        // shrinking that target mid-flight would snap it back toward the edge.
        CGFloat from = ApolloTopBarPresentedOffset(state);
        CFTimeInterval now = [bar.layer convertTime:CACurrentMediaTime() fromLayer:nil];
        BOOL inFlight = current && now < current.beginTime + current.duration;
        state.hiddenOffset = MIN(state.hiddenOffset, offset);
        state.generation++;
        ApolloTopBarAnimate(state, from, state.hiddenOffset, inFlight);
    }
}

// Called after UIKit lays out an effect. New/replaced pockets join the same
// spring at its existing timestamp instead of flashing a stationary band.
void ApolloTopBarRevalidateHeaderView(UIView *view) {
    if (!sApolloTopBarActiveStates.count) return;
    for (ApolloTopBarScrollState *state in sApolloTopBarActiveStates) {
        if (!ApolloTopBarHeaderBelongsToState(view, state)) continue;
        ApolloTopBarAttachHeader(view, state);
        if (state.hidden && ApolloTopBarHiddenOffset(state) < state.hiddenOffset - 0.5) {
            ApolloTopBarRevalidateNavigationController(state.navigationController);
        }
        for (ApolloTopBarHeaderPart *part in state.headerParts) {
            if (part.view == view && ![view.layer animationForKey:ApolloTopBarScrollAnimationKey]) {
                ApolloTopBarCopyAnimationToHeader(state, part);
            }
        }
    }
}
