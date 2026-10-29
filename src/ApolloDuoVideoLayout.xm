// Duo tabletop playback. Native controls keep their targets, delegates, KVO,
// slider tracking and player ownership; this module owns only their geometry.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloDeviceDisplay.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoVideoGeometry.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"

@interface SMScrollView : UIScrollView
- (void)scaleToFit;
@end
@interface _TtC6Apollo21MediaViewerController : UIViewController
@end
@interface _TtC6Apollo17VideoControlsView : UIVisualEffectView
@end

@interface ApolloDuoVideoRoutePicker : AVRoutePickerView
@property (nonatomic, strong) UIImageView *glyph;
@end
@implementation ApolloDuoVideoRoutePicker
- (void)layoutSubviews {
    [super layoutSubviews];
    // Keep the system button and its full tile-sized hit area. Its animated
    // artwork scales with the large bounds, so draw one consistently sized
    // glyph while retaining the native action and accessibility behavior.
    if (!self.glyph) {
        self.glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"airplayvideo"]];
        self.glyph.contentMode = UIViewContentModeScaleAspectFit;
        self.glyph.userInteractionEnabled = NO;
        self.glyph.isAccessibilityElement = NO;
        [self addSubview:self.glyph];
    }
    CGRect frame = CGRectMake(CGRectGetMidX(self.bounds) - 12, CGRectGetMidY(self.bounds) - 12, 24, 24);
    if (!CGRectEqualToRect(self.glyph.frame, frame)) self.glyph.frame = frame;
    self.glyph.tintColor = self.tintColor;
    for (UIView *child in self.subviews) {
        if ([child isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)child;
            button.imageView.alpha = 0;
            self.glyph.tintColor = button.selected ? self.activeTintColor : self.tintColor;
        }
    }
    // Recent AVKit also draws the system icon using shape layers outside the
    // button's image view. Hide only those drawing layers, never the native
    // control (which must remain visible to UIKit hit testing/accessibility).
    NSMutableArray<CALayer *> *layers = [self.layer.sublayers mutableCopy];
    NSUInteger visited = 0;
    while (layers.count && visited++ < 80) {
        CALayer *layer = layers.lastObject;
        [layers removeLastObject];
        if (layer == self.glyph.layer) continue;
        if ([layer isKindOfClass:CAShapeLayer.class]) layer.hidden = YES;
        [layers addObjectsFromArray:layer.sublayers ?: @[]];
    }
    [self bringSubviewToFront:self.glyph];
}
@end

static char kDuoVideoCoordinator, kDuoVideoOwner, kDuoVideoFrame;
static void *kDuoVideoVisibility = &kDuoVideoVisibility;
@class ApolloDuoVideoCoordinator;

// Views must not retain the coordinator (the viewer owns it).
@interface ApolloDuoVideoOwner : NSObject
@property (nonatomic, weak) ApolloDuoVideoCoordinator *coordinator;
@end
@implementation ApolloDuoVideoOwner
@end

static UIView *DuoVideoView(id object, const char *name) {
    id value = ApolloObjectIvar(object, name);
    return [value isKindOfClass:UIView.class] ? value : nil;
}
static void DuoVideoFrame(UIView *view, CGRect frame) {
    if (view && !CGRectEqualToRect(view.frame, frame)) view.frame = frame;
}

// Normalize native compact-layout writes at their setters rather than fixing
// frames from layoutSubviews. Only the panel's own control instances are tagged.
static void DuoVideoPanelFrame(UIView *view, CGRect frame) {
    if (!view) return;
    NSValue *previous = objc_getAssociatedObject(view, &kDuoVideoFrame);
    if (!previous || !CGRectEqualToRect(previous.CGRectValue, frame)) {
        objc_setAssociatedObject(view, &kDuoVideoFrame, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    DuoVideoFrame(view, frame);
}

@interface ApolloDuoVideoSnapshot : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic) CGRect frame;
@property (nonatomic) CGFloat alpha;
@property (nonatomic) BOOL hidden;
@property (nonatomic, strong) UIColor *background;
@property (nonatomic) CGFloat radius;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *images;
@property (nonatomic, strong) UIColor *minimumTrackTint;
@property (nonatomic, strong) UIColor *maximumTrackTint;
@property (nonatomic, strong) UIColor *thumbTint;
@end
@implementation ApolloDuoVideoSnapshot
@end

@interface ApolloDuoVideoCoordinator : NSObject
@property (nonatomic, weak) UIViewController *viewer;
@property (nonatomic, strong) SMScrollView *scroll;
@property (nonatomic, strong) UIVisualEffectView *controls;
@property (nonatomic, strong) NSMutableArray<ApolloDuoVideoSnapshot *> *snapshots;
@property (nonatomic, strong) NSMutableArray<UIView *> *visibleViews;
@property (nonatomic, strong) id<UIInteraction> hinge;
@property (nonatomic, strong) UIVisualEffect *nativeEffect;
@property (nonatomic, strong) UIView *soundTile;
@property (nonatomic, strong) UIView *airPlayTile;
@property (nonatomic, strong) UIView *timelineTile;
@property (nonatomic, strong) AVRoutePickerView *routePicker;
@property (nonatomic) ApolloDuoVideoGeometry geometry;
@property (nonatomic) CGRect nativeScrollFrame;
@property (nonatomic) CGRect nativeControlsFrame;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL applying;
@property (nonatomic) BOOL scheduled;
@property (nonatomic) BOOL appeared;
- (void)schedule;
- (void)update;
- (void)restore;
- (void)rememberImage:(UIImage *)image button:(UIButton *)button state:(UIControlState)state;
- (void)layoutUtilities:(ApolloDuoVideoControlGeometry)layout;
@end

static ApolloDuoVideoCoordinator *DuoVideoOwner(UIView *view) {
    ApolloDuoVideoOwner *box = objc_getAssociatedObject(view, &kDuoVideoOwner);
    return box.coordinator;
}
static void DuoVideoSetOwner(UIView *view, ApolloDuoVideoCoordinator *owner) {
    if (!view) return;
    ApolloDuoVideoOwner *box = [ApolloDuoVideoOwner new];
    box.coordinator = owner;
    objc_setAssociatedObject(view, &kDuoVideoOwner, owner ? box : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@implementation ApolloDuoVideoCoordinator
- (void)rememberImage:(UIImage *)image button:(UIButton *)button state:(UIControlState)state {
    for (ApolloDuoVideoSnapshot *snapshot in self.snapshots) {
        if (snapshot.view != button) continue;
        if (!snapshot.images) snapshot.images = [NSMutableDictionary dictionary];
        snapshot.images[@(state)] = image ?: NSNull.null;
        break;
    }
}
- (instancetype)init {
    if ((self = [super init])) {
        _snapshots = [NSMutableArray array];
        _visibleViews = [NSMutableArray array];
    }
    return self;
}
- (void)remember:(UIView *)view visible:(BOOL)visible {
    if (!view) return;
    for (ApolloDuoVideoSnapshot *snapshot in self.snapshots) if (snapshot.view == view) return;
    ApolloDuoVideoSnapshot *snapshot = [ApolloDuoVideoSnapshot new];
    snapshot.view = view;
    snapshot.frame = view.frame;
    snapshot.alpha = view.alpha;
    snapshot.hidden = view.hidden;
    snapshot.background = view.backgroundColor;
    snapshot.radius = view.layer.cornerRadius;
    if ([view isKindOfClass:UISlider.class]) {
        UISlider *slider = (UISlider *)view;
        snapshot.minimumTrackTint = slider.minimumTrackTintColor;
        snapshot.maximumTrackTint = slider.maximumTrackTintColor;
        snapshot.thumbTint = slider.thumbTintColor;
    }
    [self.snapshots addObject:snapshot];
    if (visible) {
        [self.visibleViews addObject:view];
        [view addObserver:self forKeyPath:@"alpha" options:0 context:kDuoVideoVisibility];
        [view addObserver:self forKeyPath:@"hidden" options:0 context:kDuoVideoVisibility];
    }
}
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kDuoVideoVisibility) {
        [super observeValueForKeyPath:path ofObject:object change:change context:context];
        return;
    }
    // Native timeout/focus fades may run without a layout callback. Clamp only
    // views owned by the active panel; leave unrelated media/chrome untouched.
    if (!self.active || self.applying) return;
    if (![path isEqualToString:@"alpha"] && ![path isEqualToString:@"hidden"]) {
        [self schedule];
        return;
    }
    self.applying = YES;
    UIView *view = object;
    if (view.hidden) view.hidden = NO;
    if (view.alpha != 1) view.alpha = 1;
    self.applying = NO;
}
- (void)schedule {
    if (self.scheduled) return;
    self.scheduled = YES;
    __weak ApolloDuoVideoCoordinator *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDuoVideoCoordinator *owner = weakSelf;
        owner.scheduled = NO;
        [owner update];
    });
}
- (void)observeHinge {
    if (self.hinge) return;
    if (@available(iOS 27.1, *)) {
        // Cold setup, matching DuoSplit's dynamically resolved public API.
        Class cls = objc_getClass("UIHingeInteraction");
        if (!cls || ![cls instancesRespondToSelector:@selector(initWithUpdateHandler:)]) return;
        __weak ApolloDuoVideoCoordinator *weakSelf = self;
        id interaction = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], @selector(initWithUpdateHandler:),
            ^(__unused id sender, __unused id update) {
                [weakSelf schedule];
                // UIKit can publish the reserved region just after the hinge.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    [weakSelf schedule];
                });
            });
        self.hinge = interaction;
        [self.viewer.view addInteraction:interaction];
    }
}
- (void)layoutUtilities:(ApolloDuoVideoControlGeometry)layout {
    UIView *content = self.controls.contentView;
    if (!self.routePicker) {
        self.soundTile = [UIView new];
        self.soundTile.userInteractionEnabled = NO;
        self.airPlayTile = [UIView new];
        self.timelineTile = [UIView new];
        self.timelineTile.userInteractionEnabled = NO;
        for (UIView *tile in @[self.soundTile, self.airPlayTile, self.timelineTile]) {
            tile.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
            tile.layer.cornerRadius = 14;
            [content insertSubview:tile atIndex:0];
        }
        // MPVolumeView hides Apollo's original route button when it reports
        // no receiver, and its zero-size host cannot offer a useful tap area.
        // AVRoutePickerView always offers the system picker and routes the same
        // playback audio session. No private selector or synthetic button tap.
        self.routePicker = [ApolloDuoVideoRoutePicker new];
        self.routePicker.accessibilityIdentifier = @"ApolloDuoTabletopAirPlay";
        self.routePicker.tintColor = UIColor.whiteColor;
        self.routePicker.activeTintColor = ApolloThemeAccentColor() ?: content.tintColor;
        self.routePicker.prioritizesVideoDevices = YES;
        [self.airPlayTile addSubview:self.routePicker];
        ApolloLog(@"[DuoVideo] tabletop timeline panel / icon toolbar installed");
    }
    DuoVideoFrame(self.soundTile, layout.utilities[0]);
    DuoVideoFrame(self.airPlayTile, layout.utilities[1]);
    DuoVideoFrame(self.timelineTile, layout.timeline);
    DuoVideoFrame(self.routePicker, self.airPlayTile.bounds);
    UIView *sound = DuoVideoView(self.controls, "muteUnmuteButton");
    [self remember:sound visible:YES];
    sound.backgroundColor = UIColor.clearColor;
    DuoVideoPanelFrame(sound, [content convertRect:layout.utilities[0] toView:sound.superview]);

    UIView *nativeRoute = DuoVideoView(self.controls, "airPlayButton");
    [self remember:nativeRoute visible:NO];
    nativeRoute.hidden = YES;
    // Suppress only the obsolete route button while the owned picker exists.
    // Restoring clears the tag and returns its native geometry/visibility.
    DuoVideoPanelFrame(nativeRoute, CGRectZero);
}
- (void)layoutControls {
    UIVisualEffectView *controls = self.controls;
    CGRect target = [self.viewer.view convertRect:self.geometry.controls toView:controls.superview];
    DuoVideoFrame(controls, target);
    ApolloDuoVideoControlGeometry layout;
    if (!ApolloDuoVideoMakeControlGeometry(controls.bounds.size, &layout)) return;
    const char *buttons[] = {"back15Button", "playPauseButton", "forward15Button"};
    for (int i = 0; i < 3; i++) {
        UIButton *button = (id)DuoVideoView(controls, buttons[i]);
        [self remember:button visible:NO];
        button.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
        button.layer.cornerRadius = 18;
        if (!DuoVideoOwner(button)) {
            // Enlarge the actual native artwork. UIButton's layout resets
            // imageView transforms, and Apollo supplies explicitly sized images
            // that ignore preferredSymbolConfiguration on the button itself.
            NSArray<NSNumber *> *states = @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateDisabled), @(UIControlStateSelected)];
            NSMutableArray *images = [NSMutableArray array];
            for (NSNumber *state in states) [images addObject:[button imageForState:state.unsignedIntegerValue] ?: NSNull.null];
            DuoVideoSetOwner(button, self);
            for (NSUInteger index = 0; index < states.count; index++) {
                id image = images[index];
                [button setImage:image == NSNull.null ? nil : image forState:states[index].unsignedIntegerValue];
            }
        }
        CGRect frame = layout.playback[i];
        DuoVideoPanelFrame(button, [controls.contentView convertRect:frame toView:button.superview]);
    }
    UIView *slider = DuoVideoView(controls, "timeSlider");
    UIView *elapsed = DuoVideoView(controls, "currentTimeLabel");
    UIView *remaining = DuoVideoView(controls, "timeRemainingLabel");
    UIView *live = DuoVideoView(controls, "liveBroadcastLabel");
    NSArray *views = @[slider, elapsed, remaining];
    CGRect frames[] = {layout.scrubber, layout.elapsed, layout.remaining};
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        [self remember:view visible:NO];
        DuoVideoPanelFrame(view, [controls.contentView convertRect:frames[i] toView:view.superview]);
    }
    UISlider *nativeSlider = (UISlider *)slider;
    if ([nativeSlider isKindOfClass:UISlider.class]) {
        UIColor *accent = ApolloThemeAccentColor() ?: controls.tintColor;
        nativeSlider.minimumTrackTintColor = accent;
        nativeSlider.maximumTrackTintColor = [UIColor colorWithWhite:0.45 alpha:1];
        nativeSlider.thumbTintColor = accent;
    }
    [self remember:live visible:NO];
    if (live) DuoVideoPanelFrame(live, [controls.contentView convertRect:layout.scrubber toView:live.superview]);
    [self layoutUtilities:layout];
}
- (void)update {
    if (self.applying) return;
    UIViewController *viewer = self.viewer;
    UIView *view = viewer.viewIfLoaded;
    [self observeHinge];
    SMScrollView *scroll = (id)DuoVideoView(viewer, "scrollView");
    UIVisualEffectView *controls = (id)DuoVideoView(viewer, "videoControlsView");
    UIView *player = DuoVideoView(viewer, "playerLayerContainerView");
    UIEdgeInsets safe = view.safeAreaInsets;
    ApolloDuoVideoGeometry geometry;
    BOOL ready = self.appeared && view.window && !viewer.isBeingDismissed
        && !viewer.parentViewController.isBeingDismissed && player && scroll && controls
        && [controls isKindOfClass:UIVisualEffectView.class]
        && DuoVideoView(controls, "playPauseButton") && DuoVideoView(controls, "back15Button")
        && DuoVideoView(controls, "forward15Button") && DuoVideoView(controls, "timeSlider")
        && DuoVideoView(controls, "currentTimeLabel") && DuoVideoView(controls, "timeRemainingLabel");
    // The cover never reaches a 600pt short edge. Use this viewer's window,
    // rather than the presenting tabs, which can still be mid-fold adaptation.
    BOOL eligible = ready && ApolloDeviceIsDuo();
    if (!ApolloDuoVideoMakeGeometry(view.bounds, ApolloDuoActiveHorizontalDivision(view),
                                    safe.top, safe.left, safe.bottom, safe.right, eligible, &geometry)) {
        [self restore];
        return;
    }
    if (self.active && (scroll != self.scroll || controls != self.controls)) [self restore];
    BOOL entering = !self.active;
    BOOL changed = entering || !CGRectEqualToRect(geometry.video, self.geometry.video);
    self.geometry = geometry;
    self.applying = YES;
    if (entering) {
        self.scroll = scroll;
        self.controls = controls;
        self.nativeScrollFrame = scroll.frame;
        self.nativeControlsFrame = controls.frame;
        [self remember:scroll visible:NO];
        [self remember:controls visible:YES];
        self.nativeEffect = controls.effect;
        controls.effect = nil;
        controls.backgroundColor = UIColor.blackColor;
        controls.layer.cornerRadius = 0;
        self.active = YES;
        DuoVideoSetOwner(scroll, self);
        DuoVideoSetOwner(controls, self);
        // MediaPage owns post actions and Close. Keep their native positions
        // below the panel, but prevent its focus/timeout from hiding them.
        UIViewController *page = viewer.parentViewController;
        const char *names[] = {"closeButton", "shareButton", "commentsButton", "moreButton", "pointsLabel", "pageIndicatorButton"};
        for (const char *name : names) [self remember:DuoVideoView(page, name) visible:YES];
        const char *nodes[] = {"upvoteButton", "downvoteButton"};
        for (const char *name : nodes) {
            id node = ApolloObjectIvar(page, name);
            [self remember:ApolloSendObject(node, @selector(view)) visible:YES];
        }
        ApolloLog(@"[DuoVideo] tabletop entered video=%@ controls=%@", NSStringFromCGRect(geometry.video), NSStringFromCGRect(geometry.controls));
    }
    DuoVideoFrame(scroll, [view convertRect:geometry.video toView:scroll.superview]);
    [self layoutControls];
    for (UIView *visible in self.visibleViews) {
        if (visible.hidden) visible.hidden = NO;
        if (visible.alpha != 1) visible.alpha = 1;
    }
    UIView *indicators[] = {DuoVideoView(viewer, "activityIndicator"), DuoVideoView(viewer.parentViewController, "progressView")};
    for (UIView *indicator : indicators) {
        if (!indicator) continue;
        [self remember:indicator visible:NO];
        CGPoint center = [view convertPoint:CGPointMake(CGRectGetMidX(geometry.video), CGRectGetMidY(geometry.video)) toView:indicator.superview];
        if (!CGPointEqualToPoint(indicator.center, center)) indicator.center = center;
    }
    if (changed && [scroll respondsToSelector:@selector(scaleToFit)]) [scroll scaleToFit];
    self.applying = NO;
}
- (void)restore {
    if (!self.active) return;
    self.applying = YES;
    self.active = NO;
    [self.soundTile removeFromSuperview];
    [self.airPlayTile removeFromSuperview];
    [self.timelineTile removeFromSuperview];
    self.soundTile = nil;
    self.airPlayTile = nil;
    self.timelineTile = nil;
    self.routePicker = nil;
    DuoVideoSetOwner(self.scroll, nil);
    DuoVideoSetOwner(self.controls, nil);
    for (UIView *view in self.visibleViews) {
        [view removeObserver:self forKeyPath:@"alpha" context:kDuoVideoVisibility];
        [view removeObserver:self forKeyPath:@"hidden" context:kDuoVideoVisibility];
    }
    [self.visibleViews removeAllObjects];
    for (ApolloDuoVideoSnapshot *snapshot in self.snapshots) {
        UIView *view = snapshot.view;
        if (snapshot.images) {
            DuoVideoSetOwner(view, nil);
            for (NSNumber *state in snapshot.images) {
                id image = snapshot.images[state];
                [(UIButton *)view setImage:image == NSNull.null ? nil : image forState:state.unsignedIntegerValue];
            }
        }
        objc_setAssociatedObject(view, &kDuoVideoFrame, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.backgroundColor = snapshot.background;
        view.layer.cornerRadius = snapshot.radius;
        if ([view isKindOfClass:UISlider.class]) {
            UISlider *slider = (UISlider *)view;
            slider.minimumTrackTintColor = snapshot.minimumTrackTint;
            slider.maximumTrackTintColor = snapshot.maximumTrackTint;
            slider.thumbTintColor = snapshot.thumbTint;
        }
        view.alpha = snapshot.alpha;
        view.hidden = snapshot.hidden;
        if (view != self.scroll && view != self.controls) DuoVideoFrame(view, snapshot.frame);
    }
    DuoVideoFrame(self.scroll, self.nativeScrollFrame);
    DuoVideoFrame(self.controls, self.nativeControlsFrame);
    self.controls.effect = self.nativeEffect;
    self.nativeEffect = nil;
    [self.controls setNeedsLayout];
    if ([self.scroll respondsToSelector:@selector(scaleToFit)]) [self.scroll scaleToFit];
    [self.snapshots removeAllObjects];
    self.scroll = nil;
    self.controls = nil;
    self.applying = NO;
    [self.viewer.view setNeedsLayout];
    ApolloLog(@"[DuoVideo] tabletop exited; native viewer restored");
}
- (void)dealloc {
    for (UIView *view in _visibleViews) {
        [view removeObserver:self forKeyPath:@"alpha" context:kDuoVideoVisibility];
        [view removeObserver:self forKeyPath:@"hidden" context:kDuoVideoVisibility];
    }
}
@end

static ApolloDuoVideoCoordinator *DuoVideoCoordinator(UIViewController *viewer, BOOL create) {
    ApolloDuoVideoCoordinator *owner = objc_getAssociatedObject(viewer, &kDuoVideoCoordinator);
    if (!owner && create) {
        owner = [ApolloDuoVideoCoordinator new];
        owner.viewer = viewer;
        objc_setAssociatedObject(viewer, &kDuoVideoCoordinator, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return owner;
}

%hook _TtC6Apollo21MediaViewerController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoVideoCoordinator *owner = DuoVideoCoordinator((id)self, YES);
    owner.appeared = YES;
    [owner schedule];
}
- (void)viewDidLayoutSubviews {
    %orig;
    // Only enqueue work here: frame changes happen outside the layout stack.
    [DuoVideoCoordinator((id)self, NO) schedule];
}
- (void)viewSafeAreaInsetsDidChange {
    %orig;
    [DuoVideoCoordinator((id)self, NO) schedule];
}
- (void)viewWillDisappear:(BOOL)animated {
    ApolloDuoVideoCoordinator *owner = DuoVideoCoordinator((id)self, NO);
    owner.appeared = NO;
    [owner restore];
    %orig;
}
- (void)scrollViewTapped:(id)sender {
    if (DuoVideoCoordinator((id)self, NO).active) return;
    %orig;
}
%end

%hook SMScrollView
- (void)setFrame:(CGRect)frame {
    ApolloDuoVideoCoordinator *owner = DuoVideoOwner((UIView *)self);
    if (owner.active && !owner.applying) {
        owner.nativeScrollFrame = frame;
        frame = [owner.viewer.view convertRect:owner.geometry.video toView:((UIView *)self).superview];
    }
    %orig(frame);
}
%end

%hook _TtC6Apollo17VideoControlsView
- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (!view.window) return;
    // The async video load can create controls after viewDidAppear, without
    // another viewer layout. Activate as soon as native playback UI arrives.
    for (UIResponder *next = view.nextResponder; next; next = next.nextResponder) {
        if (![next isKindOfClass:ApolloClassMediaViewerController]) continue;
        [DuoVideoCoordinator((UIViewController *)next, YES) schedule];
        break;
    }
}
- (void)setFrame:(CGRect)frame {
    ApolloDuoVideoCoordinator *owner = DuoVideoOwner((UIView *)self);
    if (owner.active && !owner.applying) {
        owner.nativeControlsFrame = frame;
        frame = [owner.viewer.view convertRect:owner.geometry.controls toView:((UIView *)self).superview];
    }
    %orig(frame);
}
- (void)layoutSubviews {
    ApolloDuoVideoCoordinator *owner = DuoVideoOwner((UIView *)self);
    if (!owner.active) { %orig; return; }
    // Keep UIVisualEffectView's internal layout, replacing Apollo's compact
    // control arrangement. Owned geometry is prepared by the coordinator.
    struct objc_super parent = {self, UIVisualEffectView.class};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&parent, @selector(layoutSubviews));
}
%end


%hook UILabel
- (void)setFrame:(CGRect)frame {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    %orig(target ? target.CGRectValue : frame);
}
- (void)setBounds:(CGRect)bounds {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    if (target) bounds.size = target.CGRectValue.size;
    %orig(bounds);
}
- (void)setCenter:(CGPoint)center {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    if (target) center = CGPointMake(CGRectGetMidX(target.CGRectValue), CGRectGetMidY(target.CGRectValue));
    %orig(center);
}
%end

%hook UISlider
- (void)setFrame:(CGRect)frame {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    %orig(target ? target.CGRectValue : frame);
}
- (void)setBounds:(CGRect)bounds {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    if (target) bounds.size = target.CGRectValue.size;
    %orig(bounds);
}
- (void)setCenter:(CGPoint)center {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    if (target) center = CGPointMake(CGRectGetMidX(target.CGRectValue), CGRectGetMidY(target.CGRectValue));
    %orig(center);
}
%end

%hook UIButton
- (void)setFrame:(CGRect)frame {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    %orig(target ? target.CGRectValue : frame);
}
- (void)setBounds:(CGRect)bounds {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    if (target) bounds.size = target.CGRectValue.size;
    %orig(bounds);
}
- (void)setCenter:(CGPoint)center {
    NSValue *target = objc_getAssociatedObject(self, &kDuoVideoFrame);
    if (target) center = CGPointMake(CGRectGetMidX(target.CGRectValue), CGRectGetMidY(target.CGRectValue));
    %orig(center);
}
- (void)setImage:(UIImage *)image forState:(UIControlState)state {
    ApolloDuoVideoCoordinator *owner = DuoVideoOwner((UIView *)self);
    if (owner.active) {
        [owner rememberImage:image button:(UIButton *)self state:state];
        if (image && image.size.width > 0 && image.size.height > 0) {
            CGSize size = CGSizeMake(48 * image.size.width / image.size.height, 48);
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
            UIImage *source = image;
            image = [[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
                [source drawInRect:(CGRect){CGPointZero, size}];
            }] imageWithRenderingMode:source.renderingMode];
        }
    }
    %orig(image, state);
}
%end

%ctor {
    if (!ApolloDeviceIsDuo()) return;
    %init;
    ApolloLog(@"[DuoVideo] tabletop video hooks installed");
}
