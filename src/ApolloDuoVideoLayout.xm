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
#import "ApolloImmersiveHeaderBackground.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"

@interface SMScrollView : UIScrollView
- (void)scaleToFit;
@end
@interface _TtC6Apollo21MediaViewerController : UIViewController
@end
@interface _TtC6Apollo17VideoControlsView : UIVisualEffectView
@end

// Every glyph in the panel is an SF Symbol drawn from one of three shared
// configurations, as AVKit's tabletop transport does, so the skip, play and
// accessory rows each read at a single optical size whatever Apollo's own
// (differently padded) bitmap artwork looked like.
typedef NS_ENUM(NSInteger, ApolloDuoVideoSymbolRole) {
    ApolloDuoVideoSymbolSkip,
    ApolloDuoVideoSymbolPlay,
    ApolloDuoVideoSymbolAccessory,
};
static UIImage *DuoVideoSymbol(NSString *name, ApolloDuoVideoSymbolRole role) {
    CGFloat points = role == ApolloDuoVideoSymbolPlay ? 34 : role == ApolloDuoVideoSymbolSkip ? 26 : 19;
    UIImageSymbolWeight weight = role == ApolloDuoVideoSymbolAccessory ? UIImageSymbolWeightMedium : UIImageSymbolWeightSemibold;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:points weight:weight
                                                                                         scale:UIImageSymbolScaleMedium];
    UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@interface ApolloDuoVideoRoutePicker : AVRoutePickerView
@property (nonatomic, strong) UIImageView *glyph;
@end
@implementation ApolloDuoVideoRoutePicker
- (void)layoutSubviews {
    [super layoutSubviews];
    // Keep the system button and its full tile-sized hit area. Its animated
    // artwork scales with the large bounds, so draw the shared accessory
    // symbol at its own size while retaining the native action and
    // accessibility behavior.
    if (!self.glyph) {
        self.glyph = [[UIImageView alloc] initWithImage:DuoVideoSymbol(@"airplayvideo", ApolloDuoVideoSymbolAccessory)];
        self.glyph.contentMode = UIViewContentModeCenter;
        self.glyph.userInteractionEnabled = NO;
        self.glyph.isAccessibilityElement = NO;
        [self addSubview:self.glyph];
    }
    CGSize glyph = self.glyph.image.size;
    CGRect frame = CGRectMake(round(CGRectGetMidX(self.bounds) - glyph.width / 2.0),
                              round(CGRectGetMidY(self.bounds) - glyph.height / 2.0), glyph.width, glyph.height);
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

// Rounded backing behind a native control. The material sits behind the
// glyph, never inside the UIButton: iOS 26 reorders a button's subviews over
// its image. Liquid Glass uses the shared effect, which is nil on a classic
// build; those builds keep a translucent fill in the same frame.
//
// The glass is shaped by its own corner radius rather than clipped by this
// view, so the rim highlight and refraction at the edge survive (clipping
// them is what made the tiles read as flat gray), and it is pinned to the
// dark appearance like AVKit's chrome over video.
@interface ApolloDuoVideoPlateView : UIView
@property (nonatomic, strong) UIVisualEffectView *material;
@property (nonatomic) BOOL capsule;
@property (nonatomic) BOOL pressed;
- (void)setPressed:(BOOL)pressed animated:(BOOL)animated;
@end
@implementation ApolloDuoVideoPlateView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        UIVisualEffect *effect = ApolloImmersiveGlassEffect(nil, 0, YES);
        if (effect) {
            self.backgroundColor = UIColor.clearColor;
            UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
            glass.userInteractionEnabled = NO;
            glass.layer.cornerCurve = kCACornerCurveContinuous;
            [self addSubview:glass];
            self.material = glass;
        } else {
            self.clipsToBounds = YES;
            self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
        }
    }
    return self;
}
- (CGFloat)radius {
    CGFloat side = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    return self.capsule ? side / 2.0 : MIN(28, MAX(16, side * 0.24));
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIVisualEffectView *glass = self.material;
    CGFloat radius = [self radius];
    if (glass) {
        // Bounds/center, not frame: the press scale lives in its transform.
        CGRect bounds = (CGRect){CGPointZero, self.bounds.size};
        if (!CGRectEqualToRect(glass.bounds, bounds)) glass.bounds = bounds;
        glass.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        if (@available(iOS 26.0, *)) {
            glass.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:radius]];
        } else {
            glass.layer.cornerRadius = radius;
        }
    } else {
        self.layer.cornerRadius = radius;
    }
}
- (void)setPressed:(BOOL)pressed animated:(BOOL)animated {
    if (_pressed == pressed) return;
    _pressed = pressed;
    void (^changes)(void) = ^{
        if (self.material) {
            CGFloat scale = pressed ? 0.96 : 1;
            self.material.transform = CGAffineTransformMakeScale(scale, scale);
            self.material.alpha = pressed ? 0.85 : 1;
        } else {
            self.backgroundColor = [UIColor colorWithWhite:1 alpha:pressed ? 0.24 : 0.14];
        }
    };
    if (!animated) { changes(); return; }
    [UIView animateWithDuration:pressed ? 0.12 : 0.32 delay:0 usingSpringWithDamping:pressed ? 1 : 0.6
          initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:changes completion:nil];
}
@end

// Groups every plate in one glass container so neighbouring tiles share a
// single sampling pass and blend as AVKit's do. It spans the whole panel, so
// it must never take a tap itself: only the AirPlay tile inside it does.
@interface ApolloDuoVideoGlassGroup : UIVisualEffectView
@end
@implementation ApolloDuoVideoGlassGroup
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self || hit == self.contentView ? nil : hit;
}
@end

// Weakly pairs a control with its plate; the control must not keep it alive.
@interface ApolloDuoVideoPlateBox : NSObject
@property (nonatomic, weak) ApolloDuoVideoPlateView *plate;
@end
@implementation ApolloDuoVideoPlateBox
@end

// UIControl and UIGestureRecognizer retain their targets. This proxy keeps
// that retain from cycling back into the coordinator. The owner is typed as
// id because Logos strips a forward @class before this interface.
@interface ApolloDuoVideoChromeProxy : NSObject
@property (nonatomic, weak) id owner;
- (void)chromeTouched;
- (void)toggleChrome;
- (void)scrubBegan;
- (void)scrubEnded;
- (void)refreshSpeedMenu:(id)sender;
- (void)pressDown:(id)sender;
- (void)pressUp:(id)sender;
@end

static char kDuoVideoCoordinator, kDuoVideoOwner, kDuoVideoFrame, kDuoVideoChromeHook, kDuoVideoPlate, kDuoVideoAlpha;
static void *kDuoVideoVisibility = &kDuoVideoVisibility;

// A real interface, not @class: the Logos preprocessor drops forward declarations.
@interface ApolloDuoVideoCoordinator : NSObject
@end

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
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic) NSTextAlignment alignment;
@end
@implementation ApolloDuoVideoSnapshot
@end

@interface ApolloDuoVideoCoordinator () <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *viewer;
@property (nonatomic, strong) SMScrollView *scroll;
@property (nonatomic, strong) UIVisualEffectView *controls;
@property (nonatomic, strong) NSMutableArray<ApolloDuoVideoSnapshot *> *snapshots;
@property (nonatomic, strong) NSMutableArray<UIView *> *visibleViews;
@property (nonatomic, strong) NSMutableArray<ApolloDuoVideoPlateView *> *playbackPlates;
@property (nonatomic, strong) NSMutableArray<ApolloDuoVideoPlateView *> *extraPlates;
@property (nonatomic, strong) NSMutableArray<UIButton *> *extraButtons;
@property (nonatomic, copy) NSArray<NSDictionary *> *extraItems;
@property (nonatomic) BOOL extrasResolved;
@property (nonatomic, strong) id<UIInteraction> hinge;
@property (nonatomic, strong) UIVisualEffect *nativeEffect;
@property (nonatomic, strong) ApolloDuoVideoPlateView *timelinePlate;
@property (nonatomic, strong) ApolloDuoVideoGlassGroup *glassGroup;
@property (nonatomic, strong) ApolloDuoVideoPlateView *soundTile;
@property (nonatomic, strong) ApolloDuoVideoPlateView *airPlayTile;
@property (nonatomic, strong) AVRoutePickerView *routePicker;
@property (nonatomic, strong) ApolloDuoVideoChromeProxy *chromeProxy;
@property (nonatomic, strong) UIView *chromeCatcher;
@property (nonatomic, strong) UITapGestureRecognizer *chromeTap;
@property (nonatomic) ApolloDuoVideoGeometry geometry;
@property (nonatomic) CGRect nativeScrollFrame;
@property (nonatomic) CGRect nativeControlsFrame;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL applying;
@property (nonatomic) BOOL scheduled;
@property (nonatomic) BOOL appeared;
@property (nonatomic) BOOL chromeVisible;
// Set around the coordinator's own alpha writes, which the setter hooks pass.
@property (nonatomic) BOOL settingAlpha;
@property (nonatomic) BOOL chromeAnimating;
@property (nonatomic) BOOL scrubbing;
@property (nonatomic) NSUInteger chromeGeneration;
- (void)schedule;
- (void)update;
- (void)restore;
- (void)rememberImage:(UIImage *)image button:(UIButton *)button state:(UIControlState)state;
- (void)layoutUtilities:(ApolloDuoVideoControlGeometry)layout;
- (void)applyTimelineTrack:(UISlider *)slider;
- (void)chromeTouched;
- (void)toggleChrome;
- (void)scrubBegan;
- (void)scrubEnded;
- (void)refreshSpeedMenu:(UIButton *)sender;
- (void)resolveExtras;
- (void)resyncSymbols;
- (void)scheduleSymbolResync;
- (UIMenu *)speedMenu;
- (void)refreshTimelineTrack;
- (void)addPlate:(ApolloDuoVideoPlateView *)plate;
- (void)pairControl:(UIControl *)control plate:(ApolloDuoVideoPlateView *)plate;
- (void)unpairControl:(UIControl *)control;
- (UIImage *)symbolForButton:(UIButton *)button;
@property (nonatomic) BOOL resyncing;
@property (nonatomic) BOOL resyncScheduled;
@end

// Who decides a native view's alpha while the panel is active. Apollo's own
// focus/timeout fade keeps writing alpha and hidden to these views; undoing
// those writes after the fact (KVO) made them flash mid-animation. The setter
// hooks below substitute the panel's value instead, so nothing ever flickers.
@interface ApolloDuoVideoAlphaBox : NSObject
@property (nonatomic, weak) ApolloDuoVideoCoordinator *coordinator;
@property (nonatomic) BOOL chrome; // fades with the transport; otherwise pinned visible
@end
@implementation ApolloDuoVideoAlphaBox
@end
static void DuoVideoClaimAlpha(UIView *view, ApolloDuoVideoCoordinator *owner, BOOL chrome) {
    if (!view) return;
    ApolloDuoVideoAlphaBox *box = objc_getAssociatedObject(view, &kDuoVideoAlpha);
    if (box.coordinator == owner && box.chrome == chrome) return;
    box = [ApolloDuoVideoAlphaBox new];
    box.coordinator = owner;
    box.chrome = chrome;
    objc_setAssociatedObject(view, &kDuoVideoAlpha, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
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

// The long-press menu (Share Link / Download Video / Playback Speed) is built
// by Apollo's context-menu delegate. Ask for that configuration and run its
// action provider to learn whether this video offers Playback Speed.
static UIContextMenuInteraction *DuoVideoMenuInteraction(UIView *view, id delegate, BOOL requireDelegate) {
    if (!view) return nil;
    for (id<UIInteraction> interaction in view.interactions) {
        if (![interaction isKindOfClass:UIContextMenuInteraction.class]) continue;
        UIContextMenuInteraction *menu = (UIContextMenuInteraction *)interaction;
        if (!requireDelegate || menu.delegate == delegate) return menu;
    }
    for (UIView *subview in view.subviews) {
        UIContextMenuInteraction *found = DuoVideoMenuInteraction(subview, delegate, requireDelegate);
        if (found) return found;
    }
    return nil;
}
static UIMenu *DuoVideoNativeMenu(UIViewController *viewer) {
    if (!viewer.isViewLoaded) return nil;
    SEL selector = @selector(contextMenuInteraction:configurationForMenuAtLocation:);
    if (![viewer respondsToSelector:selector]) return nil;
    UIContextMenuInteraction *interaction = DuoVideoMenuInteraction(viewer.view, viewer, YES);
    if (!interaction) interaction = DuoVideoMenuInteraction(viewer.view, viewer, NO);
    UIContextMenuConfiguration *config = ((id (*)(id, SEL, id, CGPoint))objc_msgSend)(viewer, selector, interaction, CGPointZero);
    if (![config isKindOfClass:UIContextMenuConfiguration.class]) return nil;
    typedef UIMenu *(^DuoVideoMenuProvider)(NSArray<UIMenuElement *> *);
    DuoVideoMenuProvider provider = nil;
    @try { provider = (DuoVideoMenuProvider)[config valueForKey:@"actionProvider"]; }
    @catch (__unused NSException *exception) { provider = nil; }
    if (!provider) {
        for (Class cls = object_getClass(config); cls && !provider; cls = class_getSuperclass(cls)) {
            Ivar ivar = class_getInstanceVariable(cls, "_actionProvider");
            if (!ivar) continue;
            id raw = object_getIvar(config, ivar);
            if (raw) provider = (DuoVideoMenuProvider)raw;
        }
    }
    if (!provider) return nil;
    Class blockClass = NSClassFromString(@"NSBlock");
    if (blockClass && ![provider isKindOfClass:blockClass]) return nil;
    UIMenu *menu = provider(@[]);
    return [menu isKindOfClass:UIMenu.class] ? menu : nil;
}
static UIMenuElement *DuoVideoMenuElement(UIMenu *menu, NSString *key) {
    for (UIMenuElement *element in menu.children) {
        NSString *title = element.title ?: @"";
        BOOL match = [key isEqualToString:@"speed"] && [title hasPrefix:@"Playback Speed"];
        if (match) return element;
        if ([element isKindOfClass:UIMenu.class]) {
            UIMenuElement *nested = DuoVideoMenuElement((UIMenu *)element, key);
            if (nested) return nested;
        }
    }
    return nil;
}

@implementation ApolloDuoVideoChromeProxy
- (void)chromeTouched { [(ApolloDuoVideoCoordinator *)self.owner chromeTouched]; }
- (void)toggleChrome { [(ApolloDuoVideoCoordinator *)self.owner toggleChrome]; }
- (void)scrubBegan { [(ApolloDuoVideoCoordinator *)self.owner scrubBegan]; }
- (void)scrubEnded { [(ApolloDuoVideoCoordinator *)self.owner scrubEnded]; }
- (void)refreshSpeedMenu:(id)sender { [(ApolloDuoVideoCoordinator *)self.owner refreshSpeedMenu:sender]; }
// The plates cannot take touches (the native controls above them must), so
// the control's own tracking drives the glass press.
- (void)pressDown:(id)sender {
    ApolloDuoVideoPlateBox *box = objc_getAssociatedObject(sender, &kDuoVideoPlate);
    [box.plate setPressed:YES animated:YES];
}
- (void)pressUp:(id)sender {
    ApolloDuoVideoPlateBox *box = objc_getAssociatedObject(sender, &kDuoVideoPlate);
    [box.plate setPressed:NO animated:YES];
}
@end


@implementation ApolloDuoVideoCoordinator
- (void)rememberImage:(UIImage *)image button:(UIButton *)button state:(UIControlState)state {
    for (ApolloDuoVideoSnapshot *snapshot in self.snapshots) {
        if (snapshot.view != button) continue;
        if (!snapshot.images) snapshot.images = [NSMutableDictionary dictionary];
        snapshot.images[@(state)] = image ?: NSNull.null;
        break;
    }
}
// The native play/pause and mute artwork follows the controls' own state
// ivars, so the symbol is chosen from them rather than from Apollo's image.
- (UIImage *)symbolForButton:(UIButton *)button {
    UIView *controls = self.controls;
    if (!controls) return nil;
    if (button == DuoVideoView(controls, "back15Button")) return DuoVideoSymbol(@"gobackward.15", ApolloDuoVideoSymbolSkip);
    if (button == DuoVideoView(controls, "forward15Button")) return DuoVideoSymbol(@"goforward.15", ApolloDuoVideoSymbolSkip);
    if (button == DuoVideoView(controls, "playPauseButton")) {
        BOOL paused = ApolloReadBoolIvar(controls, "isPaused", YES);
        return DuoVideoSymbol(paused ? @"play.fill" : @"pause.fill", ApolloDuoVideoSymbolPlay);
    }
    if (button == DuoVideoView(controls, "muteUnmuteButton")) {
        BOOL muted = ApolloReadBoolIvar(controls, "isMuted", YES);
        return DuoVideoSymbol(muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill", ApolloDuoVideoSymbolAccessory);
    }
    return nil;
}
// Apollo may write the image before or after flipping its state ivar.
// Re-apply the remembered native images once the current change settles.
- (void)scheduleSymbolResync {
    if (self.resyncing || self.resyncScheduled) return;
    self.resyncScheduled = YES;
    __weak ApolloDuoVideoCoordinator *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDuoVideoCoordinator *owner = weakSelf;
        owner.resyncScheduled = NO;
        [owner resyncSymbols];
    });
}
- (void)resyncSymbols {
    if (!self.active) return;
    UIView *play = DuoVideoView(self.controls, "playPauseButton");
    UIView *sound = DuoVideoView(self.controls, "muteUnmuteButton");
    self.resyncing = YES;
    for (ApolloDuoVideoSnapshot *snapshot in self.snapshots) {
        if ((snapshot.view != play && snapshot.view != sound) || !snapshot.images) continue;
        if (!DuoVideoOwner(snapshot.view)) continue;
        NSDictionary *images = [snapshot.images copy];
        for (NSNumber *state in images) {
            id image = images[state];
            [(UIButton *)snapshot.view setImage:image == NSNull.null ? nil : image forState:state.unsignedIntegerValue];
        }
    }
    self.resyncing = NO;
}
- (instancetype)init {
    if ((self = [super init])) {
        _snapshots = [NSMutableArray array];
        _visibleViews = [NSMutableArray array];
        _playbackPlates = [NSMutableArray array];
        _extraPlates = [NSMutableArray array];
        _extraButtons = [NSMutableArray array];
        _chromeProxy = [ApolloDuoVideoChromeProxy new];
        _chromeProxy.owner = self;
        _chromeVisible = YES;
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
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        snapshot.textColor = label.textColor;
        snapshot.font = label.font;
        snapshot.alignment = label.textAlignment;
    }
    [self.snapshots addObject:snapshot];
    if (visible) {
        DuoVideoClaimAlpha(view, self, NO);
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
    // Views without a setter hook (Texture node views) land here. Reset
    // outside any animation and drop the fade Apollo just started, otherwise
    // the two animations fight and the view flashes.
    if (view.hidden || view.alpha != 1) {
        self.settingAlpha = YES;
        [UIView performWithoutAnimation:^{
            view.hidden = NO;
            view.alpha = 1;
        }];
        self.settingAlpha = NO;
        [view.layer removeAnimationForKey:@"opacity"];
        [view.layer removeAnimationForKey:@"hidden"];
    }
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
- (void)hookChromeControl:(UIControl *)control scrubber:(BOOL)scrubber {
    if (![control isKindOfClass:UIControl.class] || objc_getAssociatedObject(control, &kDuoVideoChromeHook)) return;
    objc_setAssociatedObject(control, &kDuoVideoChromeHook, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (scrubber) {
        [control addTarget:self.chromeProxy action:@selector(scrubBegan) forControlEvents:UIControlEventTouchDown];
        [control addTarget:self.chromeProxy action:@selector(scrubEnded)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    } else {
        [control addTarget:self.chromeProxy action:@selector(chromeTouched) forControlEvents:UIControlEventTouchDown];
    }
}
- (NSArray<UIView *> *)chromePieces {
    NSMutableArray<UIView *> *pieces = [NSMutableArray array];
    for (UIView *plate in self.playbackPlates) [pieces addObject:plate];
    for (UIView *plate in self.extraPlates) [pieces addObject:plate];
    for (UIButton *button in self.extraButtons) [pieces addObject:button];
    if (self.timelinePlate) [pieces addObject:self.timelinePlate];
    if (self.soundTile) [pieces addObject:self.soundTile];
    if (self.airPlayTile) [pieces addObject:self.airPlayTile];
    const char *names[] = {
        "back15Button", "playPauseButton", "forward15Button", "muteUnmuteButton",
        "timeSlider", "currentTimeLabel", "timeRemainingLabel", "liveBroadcastLabel"
    };
    for (const char *name : names) {
        UIView *view = DuoVideoView(self.controls, name);
        if (!view) continue;
        DuoVideoClaimAlpha(view, self, YES);
        [pieces addObject:view];
    }
    return pieces;
}
- (void)applyChromeVisibility {
    if (!self.active || self.chromeAnimating) return;
    CGFloat alpha = self.chromeVisible ? 1 : 0;
    self.settingAlpha = YES;
    for (UIView *piece in [self chromePieces]) {
        if (piece.alpha != alpha) piece.alpha = alpha;
        BOOL hit = [piece isKindOfClass:UIControl.class] || piece == self.airPlayTile;
        if (hit) piece.userInteractionEnabled = self.chromeVisible;
    }
    self.settingAlpha = NO;
}
- (void)scheduleChromeHide {
    if (!self.active || !self.chromeVisible || self.scrubbing) return;
    NSUInteger token = ++self.chromeGeneration;
    __weak ApolloDuoVideoCoordinator *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloDuoVideoCoordinator *owner = weakSelf;
        if (!owner || token != owner.chromeGeneration || !owner.active || !owner.chromeVisible || owner.scrubbing) return;
        [owner setChromeVisible:NO animated:YES];
    });
}
- (void)setChromeVisible:(BOOL)visible animated:(BOOL)animated {
    if (!self.active) return;
    self.chromeVisible = visible;
    if (!visible) self.chromeGeneration++;
    self.chromeAnimating = YES;
    CGFloat alpha = visible ? 1 : 0;
    void (^changes)(void) = ^{
        self.settingAlpha = YES;
        for (UIView *piece in [self chromePieces]) piece.alpha = alpha;
        self.settingAlpha = NO;
    };
    void (^finish)(BOOL) = ^(__unused BOOL finished) {
        self.chromeAnimating = NO;
        if (!self.active) return;
        [self applyChromeVisibility];
    };
    if (animated) [UIView animateWithDuration:0.22 animations:changes completion:finish];
    else { changes(); finish(YES); }
    if (visible) [self scheduleChromeHide];
}
- (void)chromeTouched {
    if (!self.active) return;
    if (!self.chromeVisible) {
        [self setChromeVisible:YES animated:YES];
        return;
    }
    [self scheduleChromeHide];
}
- (void)toggleChrome {
    if (!self.active) return;
    [self setChromeVisible:!self.chromeVisible animated:YES];
}
- (void)scrubBegan {
    if (!self.active) return;
    self.scrubbing = YES;
    self.chromeGeneration++;
    if (!self.chromeVisible) [self setChromeVisible:YES animated:YES];
    [self refreshTimelineTrack];
}
- (void)refreshTimelineTrack {
    UISlider *slider = (UISlider *)DuoVideoView(self.controls, "timeSlider");
    if (![slider isKindOfClass:UISlider.class]) return;
    [UIView transitionWithView:slider duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ [self applyTimelineTrack:slider]; } completion:nil];
}
- (void)scrubEnded {
    if (!self.active) return;
    self.scrubbing = NO;
    [self refreshTimelineTrack];
    [self scheduleChromeHide];
}
- (void)addPlate:(ApolloDuoVideoPlateView *)plate {
    UIView *content = self.controls.contentView;
    if (!content || !plate) return;
    if (!self.glassGroup && plate.material) {
        if (@available(iOS 26.0, *)) {
            ApolloDuoVideoGlassGroup *group = [[ApolloDuoVideoGlassGroup alloc] initWithEffect:[UIGlassContainerEffect new]];
            group.frame = content.bounds;
            group.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            group.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            [content insertSubview:group atIndex:0];
            self.glassGroup = group;
        }
    }
    // The group shares the content view's bounds, so plate frames computed in
    // content coordinates hold inside it.
    if (self.glassGroup) [self.glassGroup.contentView addSubview:plate];
    else [content insertSubview:plate atIndex:0];
}
- (void)pairControl:(UIControl *)control plate:(ApolloDuoVideoPlateView *)plate {
    if (![control isKindOfClass:UIControl.class] || !plate) return;
    ApolloDuoVideoPlateBox *box = objc_getAssociatedObject(control, &kDuoVideoPlate);
    if (box.plate == plate) return;
    if (!box) {
        [control addTarget:self.chromeProxy action:@selector(pressDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [control addTarget:self.chromeProxy action:@selector(pressUp:)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel
                | UIControlEventTouchDragExit | UIControlEventMenuActionTriggered];
        box = [ApolloDuoVideoPlateBox new];
        objc_setAssociatedObject(control, &kDuoVideoPlate, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    box.plate = plate;
}
- (void)unpairControl:(UIControl *)control {
    if (![control isKindOfClass:UIControl.class] || !objc_getAssociatedObject(control, &kDuoVideoPlate)) return;
    [control removeTarget:self.chromeProxy action:@selector(pressDown:) forControlEvents:UIControlEventAllEvents];
    [control removeTarget:self.chromeProxy action:@selector(pressUp:) forControlEvents:UIControlEventAllEvents];
    objc_setAssociatedObject(control, &kDuoVideoPlate, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)resolveExtras {
    if (self.extrasResolved) return;
    UIView *content = self.controls.contentView;
    if (!content) return;
    UIMenu *menu = DuoVideoNativeMenu(self.viewer);
    if (!menu) return;
    self.extrasResolved = YES;
    NSMutableArray *titles = [NSMutableArray array];
    for (UIMenuElement *element in menu.children) if (element.title.length) [titles addObject:element.title];
    ApolloLog(@"[DuoVideo] video menu: %@", [titles componentsJoinedByString:@", "]);
    NSMutableArray *items = [NSMutableArray array];
    NSDictionary *wanted = @{
        // AVKit's playback-speed glyph; speedometer predates it (iOS 17).
        @"speed": [UIImage systemImageNamed:@"gauge.with.dots.needle.67percent"] ? @"gauge.with.dots.needle.67percent" : @"speedometer",
    };
    for (NSString *key in @[@"speed"]) {
        UIMenuElement *element = DuoVideoMenuElement(menu, key);
        if (!element) continue;
        [items addObject:@{@"key": key, @"title": element.title ?: @"", @"symbol": wanted[key]}];
        ApolloLog(@"[DuoVideo] accessory %@ (%@)", key, element.title);
    }
    self.extraItems = items;
    for (UIView *plate in self.extraPlates) [plate removeFromSuperview];
    for (UIButton *button in self.extraButtons) [button removeFromSuperview];
    [self.extraPlates removeAllObjects];
    [self.extraButtons removeAllObjects];
    for (NSDictionary *item in items) {
        ApolloDuoVideoPlateView *plate = [ApolloDuoVideoPlateView new];
        [self addPlate:plate];
        [self.extraPlates addObject:plate];
        // Custom type with white original artwork: a system button dims its
        // template image after presenting a menu (tint adjustment/highlight),
        // which left the speed glyph dull once its menu closed.
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.adjustsImageWhenHighlighted = NO;
        button.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = UIColor.clearColor;
        button.accessibilityLabel = item[@"title"];
        button.accessibilityIdentifier = item[@"key"];
        UIImage *glyph = [DuoVideoSymbol(item[@"symbol"], ApolloDuoVideoSymbolAccessory) imageWithTintColor:UIColor.whiteColor
                                                                                       renderingMode:UIImageRenderingModeAlwaysOriginal];
        [button setImage:glyph forState:UIControlStateNormal];
        [content addSubview:button];
        [self.extraButtons addObject:button];
        [self pairControl:button plate:plate];
        // Our own speed menu: Apollo's submenu is built for its long-press
        // context menu and is not reliable presented from a button.
        button.menu = [self speedMenu];
        button.showsMenuAsPrimaryAction = YES;
        [button addTarget:self.chromeProxy action:@selector(refreshSpeedMenu:) forControlEvents:UIControlEventTouchDown];
    }
}
- (void)refreshSpeedMenu:(UIButton *)button {
    if (!self.active || ![button isKindOfClass:UIButton.class]) return;
    [self chromeTouched];
}
// The viewer's Float? videoPlaybackSpeed: 4-byte value, then a flag byte that
// is 0 for .some. Apollo applies it with setRate when playback (re)starts.
- (float)playbackSpeed {
    UIViewController *viewer = self.viewer;
    Ivar ivar = viewer ? class_getInstanceVariable(object_getClass(viewer), "videoPlaybackSpeed") : NULL;
    if (!ivar) return 1;
    const uint8_t *base = (const uint8_t *)(__bridge void *)viewer + ivar_getOffset(ivar);
    if (base[4] != 0) return 1;
    float speed = 1;
    memcpy(&speed, base, sizeof(float));
    return speed > 0 ? speed : 1;
}
- (AVPlayer *)player {
    id player = ApolloObjectIvar(self.viewer, "player");
    if ([player isKindOfClass:AVPlayer.class]) return player;
    UIView *container = DuoVideoView(self.viewer, "playerLayerContainerView");
    NSMutableArray<CALayer *> *layers = container ? [NSMutableArray arrayWithObject:container.layer] : [NSMutableArray array];
    while (layers.count) {
        CALayer *layer = layers.firstObject;
        [layers removeObjectAtIndex:0];
        if ([layer isKindOfClass:AVPlayerLayer.class] && ((AVPlayerLayer *)layer).player) return ((AVPlayerLayer *)layer).player;
        [layers addObjectsFromArray:layer.sublayers ?: @[]];
    }
    return nil;
}
- (void)setPlaybackSpeed:(float)speed {
    UIViewController *viewer = self.viewer;
    Ivar ivar = viewer ? class_getInstanceVariable(object_getClass(viewer), "videoPlaybackSpeed") : NULL;
    if (!ivar) return;
    uint8_t *base = (uint8_t *)(__bridge void *)viewer + ivar_getOffset(ivar);
    memcpy(base, &speed, sizeof(float));
    base[4] = 0;
    // Like Apollo's own setter, never un-pause a paused video.
    AVPlayer *player = [self player];
    if (player.rate != 0) player.rate = speed;
    ApolloLog(@"[DuoVideo] playback speed %.2fx (player=%d)", speed, player != nil);
    for (UIButton *button in self.extraButtons) {
        if ([button.accessibilityIdentifier isEqualToString:@"speed"]) button.menu = [self speedMenu];
    }
}
- (UIMenu *)speedMenu {
    static const float speeds[] = {2, 1.5, 1.25, 1, 0.75, 0.5, 0.25};
    float current = [self playbackSpeed];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    __weak ApolloDuoVideoCoordinator *weakSelf = self;
    for (float speed : speeds) {
        NSString *title = speed == 1 ? @"Normal" : [NSString stringWithFormat:@"%g\u00D7", speed];
        UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *sender) {
            [weakSelf setPlaybackSpeed:speed];
        }];
        if (fabsf(current - speed) < 0.001f) action.state = UIMenuElementStateOn;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"Playback Speed" children:actions];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture != self.chromeTap) return YES;
    if (!self.chromeVisible) return YES;
    UIView *view = touch.view;
    while (view && view != self.controls) {
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:AVRoutePickerView.class]) return NO;
        view = view.superview;
    }
    return YES;
}
- (void)layoutUtilities:(ApolloDuoVideoControlGeometry)layout {
    UIView *content = self.controls.contentView;
    if (!self.routePicker) {
        self.soundTile = [ApolloDuoVideoPlateView new];
        self.airPlayTile = [ApolloDuoVideoPlateView new];
        // The picker lives inside its tile, so that tile has to take hits.
        // The mute tile stays behind the native button.
        self.airPlayTile.userInteractionEnabled = YES;
        for (ApolloDuoVideoPlateView *tile in @[self.soundTile, self.airPlayTile]) [self addPlate:tile];
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
        ApolloLog(@"[DuoVideo] tabletop glass transport installed");
    }
    DuoVideoFrame(self.soundTile, layout.accessories[0]);
    DuoVideoFrame(self.airPlayTile, layout.accessories[layout.accessoryCount - 1]);
    DuoVideoFrame(self.routePicker, self.airPlayTile.bounds);
    for (UIView *child in self.routePicker.subviews) {
        if ([child isKindOfClass:UIControl.class]) [self hookChromeControl:(UIControl *)child scrubber:NO];
    }
    UIButton *sound = (id)DuoVideoView(self.controls, "muteUnmuteButton");
    [self remember:sound visible:NO];
    sound.backgroundColor = UIColor.clearColor;
    sound.tintColor = UIColor.whiteColor;
    [self hookChromeControl:sound scrubber:NO];
    [self pairControl:sound plate:self.soundTile];
    if ([sound isKindOfClass:UIButton.class] && !DuoVideoOwner(sound)) {
        NSArray<NSNumber *> *states = @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateDisabled), @(UIControlStateSelected)];
        NSMutableArray *images = [NSMutableArray array];
        for (NSNumber *state in states) [images addObject:[sound imageForState:state.unsignedIntegerValue] ?: NSNull.null];
        DuoVideoSetOwner(sound, self);
        for (NSUInteger index = 0; index < states.count; index++) {
            id image = images[index];
            [sound setImage:image == NSNull.null ? nil : image forState:states[index].unsignedIntegerValue];
        }
    }
    DuoVideoPanelFrame(sound, [content convertRect:layout.accessories[0] toView:sound.superview]);

    UIView *nativeRoute = DuoVideoView(self.controls, "airPlayButton");
    [self remember:nativeRoute visible:NO];
    nativeRoute.hidden = YES;
    // Suppress only the obsolete route button while the owned picker exists.
    // Restoring clears the tag and returns its native geometry/visibility.
    DuoVideoPanelFrame(nativeRoute, CGRectZero);
}
// UIVisualEffectView hit-tests through itself and its content view. Hidden
// chrome also turns the buttons off, so a tap on the black panel never reaches
// a gesture attached to the effect view. This clear view sits behind every
// control and receives those taps.
- (void)installChromeCatcher {
    UIView *content = self.controls.contentView;
    if (!content) return;
    if (!self.chromeCatcher) {
        UIView *catcher = [[UIView alloc] initWithFrame:content.bounds];
        catcher.backgroundColor = UIColor.clearColor;
        catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [content insertSubview:catcher atIndex:0];
        self.chromeCatcher = catcher;
        self.chromeTap = [[UITapGestureRecognizer alloc] initWithTarget:self.chromeProxy action:@selector(toggleChrome)];
        self.chromeTap.delegate = self;
        [catcher addGestureRecognizer:self.chromeTap];
    }
    if (!CGRectEqualToRect(self.chromeCatcher.frame, content.bounds)) self.chromeCatcher.frame = content.bounds;
    [content sendSubviewToBack:self.chromeCatcher];
}
// Safari's scrubber: a 6pt rounded track with no resting knob, which thickens
// while it is dragged. The thumb stays a clear image so UISlider keeps its
// touch target and value mapping.
- (void)applyTimelineTrack:(UISlider *)slider {
    static UIImage *minimumTrack, *maximumTrack, *minimumActive, *maximumActive, *thumb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImage *(^capsule)(UIColor *, CGSize) = ^UIImage *(UIColor *color, CGSize size) {
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
            UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
                [color setFill];
                [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:size.height / 2.0] fill];
            }];
            CGFloat cap = floor(size.width / 2.0);
            return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, cap, 0, cap)];
        };
        UIColor *rest = [UIColor colorWithWhite:1 alpha:0.25];
        minimumTrack = capsule([UIColor colorWithWhite:1 alpha:0.9], CGSizeMake(12, 6));
        maximumTrack = capsule(rest, CGSizeMake(12, 6));
        minimumActive = capsule(UIColor.whiteColor, CGSizeMake(16, 10));
        maximumActive = capsule(rest, CGSizeMake(16, 10));
        thumb = capsule(UIColor.clearColor, CGSizeMake(14, 14));
    });
    BOOL active = self.scrubbing;
    [slider setMinimumTrackImage:active ? minimumActive : minimumTrack forState:UIControlStateNormal];
    [slider setMaximumTrackImage:active ? maximumActive : maximumTrack forState:UIControlStateNormal];
    [slider setThumbImage:thumb forState:UIControlStateNormal];
    [slider setThumbImage:thumb forState:UIControlStateHighlighted];
}
- (void)layoutControls {
    UIVisualEffectView *controls = self.controls;
    CGRect target = [self.viewer.view convertRect:self.geometry.controls toView:controls.superview];
    DuoVideoFrame(controls, target);
    [self installChromeCatcher];
    [self resolveExtras];
    ApolloDuoVideoControlGeometry layout;
    int accessories = 2 + (int)self.extraItems.count;
    if (!ApolloDuoVideoMakeControlGeometry(controls.bounds.size, accessories, &layout)) return;
    UIView *content = controls.contentView;
    if (!self.playbackPlates.count) {
        for (int i = 0; i < 3; i++) {
            ApolloDuoVideoPlateView *plate = [ApolloDuoVideoPlateView new];
            [self addPlate:plate];
            [self.playbackPlates addObject:plate];
        }
    }
    const char *buttons[] = {"back15Button", "playPauseButton", "forward15Button"};
    for (int i = 0; i < 3; i++) {
        UIButton *button = (id)DuoVideoView(controls, buttons[i]);
        [self remember:button visible:NO];
        button.backgroundColor = UIColor.clearColor;
        button.layer.cornerRadius = 0;
        button.tintColor = UIColor.whiteColor;
        [self hookChromeControl:button scrubber:NO];
        [self pairControl:button plate:self.playbackPlates[i]];
        CGRect frame = layout.playback[i];
        DuoVideoFrame(self.playbackPlates[i], frame);
        DuoVideoPanelFrame(button, [content convertRect:frame toView:button.superview]);
        if (!DuoVideoOwner(button)) {
            // Re-set the native artwork through the owned setImage hook, which
            // swaps in the shared SF Symbol. UIButton's layout resets imageView
            // transforms, and Apollo supplies explicitly sized images that
            // ignore preferredSymbolConfiguration.
            NSArray<NSNumber *> *states = @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateDisabled), @(UIControlStateSelected)];
            NSMutableArray *images = [NSMutableArray array];
            for (NSNumber *state in states) [images addObject:[button imageForState:state.unsignedIntegerValue] ?: NSNull.null];
            DuoVideoSetOwner(button, self);
            for (NSUInteger index = 0; index < states.count; index++) {
                id image = images[index];
                [button setImage:image == NSNull.null ? nil : image forState:states[index].unsignedIntegerValue];
            }
        }
    }
    if (!self.timelinePlate) {
        ApolloDuoVideoPlateView *plate = [ApolloDuoVideoPlateView new];
        plate.capsule = YES;
        [self addPlate:plate];
        self.timelinePlate = plate;
    }
    DuoVideoFrame(self.timelinePlate, layout.timeline);
    UIView *slider = DuoVideoView(controls, "timeSlider");
    UIView *elapsed = DuoVideoView(controls, "currentTimeLabel");
    UIView *remaining = DuoVideoView(controls, "timeRemainingLabel");
    UIView *live = DuoVideoView(controls, "liveBroadcastLabel");
    NSArray *views = @[slider, elapsed, remaining];
    CGRect frames[] = {layout.scrubber, layout.elapsed, layout.remaining};
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        [self remember:view visible:NO];
        if ([view isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)view;
            label.textColor = [UIColor colorWithWhite:1 alpha:0.6];
            label.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
            label.textAlignment = view == remaining ? NSTextAlignmentRight : NSTextAlignmentLeft;
        }
        DuoVideoPanelFrame(view, [content convertRect:frames[i] toView:view.superview]);
    }
    UISlider *nativeSlider = (UISlider *)slider;
    if ([nativeSlider isKindOfClass:UISlider.class]) {
        [self hookChromeControl:nativeSlider scrubber:YES];
        [self applyTimelineTrack:nativeSlider];
    }
    [self remember:live visible:NO];
    if ([live isKindOfClass:UILabel.class]) {
        ((UILabel *)live).textColor = UIColor.whiteColor;
        DuoVideoPanelFrame(live, [content convertRect:layout.scrubber toView:live.superview]);
    }
    [self layoutUtilities:layout];
    for (NSUInteger i = 0; i < self.extraButtons.count; i++) {
        NSInteger slot = (NSInteger)i + 1;
        if (slot >= layout.accessoryCount - 1) break;
        CGRect frame = layout.accessories[slot];
        DuoVideoFrame(self.extraPlates[i], frame);
        DuoVideoPanelFrame(self.extraButtons[i], [content convertRect:frame toView:self.extraButtons[i].superview]);
    }
    // Tiles are inserted at the back. Keep the catcher behind them so AirPlay
    // and the native buttons stay the hit targets while chrome is visible.
    [self installChromeCatcher];
    [self applyChromeVisibility];
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
        // The controls view stays opaque so the lower panel remains black while
        // its buttons fade. Post actions are clamped separately below.
        [self remember:controls visible:YES];
        self.nativeEffect = controls.effect;
        controls.effect = nil;
        controls.backgroundColor = UIColor.blackColor;
        controls.layer.cornerRadius = 0;
        self.active = YES;
        self.chromeVisible = YES;
        DuoVideoSetOwner(scroll, self);
        DuoVideoSetOwner(controls, self);
        [self scheduleChromeHide];
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
    self.chromeGeneration++;
    self.chromeVisible = NO;
    self.scrubbing = NO;
    self.chromeAnimating = NO;
    for (UIView *piece in [self chromePieces]) [piece.layer removeAllAnimations];
    [self.timelinePlate removeFromSuperview];
    self.timelinePlate = nil;
    const char *paired[] = {"back15Button", "playPauseButton", "forward15Button", "muteUnmuteButton"};
    for (const char *name : paired) [self unpairControl:(UIControl *)DuoVideoView(self.controls, name)];
    [self.chromeCatcher removeFromSuperview];
    self.chromeCatcher = nil;
    self.chromeTap = nil;
    for (UIView *plate in self.playbackPlates) [plate removeFromSuperview];
    [self.playbackPlates removeAllObjects];
    for (UIView *plate in self.extraPlates) [plate removeFromSuperview];
    for (UIButton *button in self.extraButtons) [button removeFromSuperview];
    [self.extraPlates removeAllObjects];
    [self.extraButtons removeAllObjects];
    self.extraItems = nil;
    self.extrasResolved = NO;
    [self.soundTile removeFromSuperview];
    [self.airPlayTile removeFromSuperview];
    self.soundTile = nil;
    self.airPlayTile = nil;
    self.routePicker = nil;
    [self.glassGroup removeFromSuperview];
    self.glassGroup = nil;
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
        objc_setAssociatedObject(view, &kDuoVideoAlpha, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.backgroundColor = snapshot.background;
        view.layer.cornerRadius = snapshot.radius;
        if ([view isKindOfClass:UISlider.class]) {
            UISlider *slider = (UISlider *)view;
            slider.minimumTrackTintColor = snapshot.minimumTrackTint;
            slider.maximumTrackTintColor = snapshot.maximumTrackTint;
            slider.thumbTintColor = snapshot.thumbTint;
            [slider setMinimumTrackImage:nil forState:UIControlStateNormal];
            [slider setMaximumTrackImage:nil forState:UIControlStateNormal];
            [slider setThumbImage:nil forState:UIControlStateNormal];
            [slider setThumbImage:nil forState:UIControlStateHighlighted];
        }
        if ([view isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)view;
            if (snapshot.textColor) label.textColor = snapshot.textColor;
            if (snapshot.font) label.font = snapshot.font;
            label.textAlignment = snapshot.alignment;
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

static void DuoVideoAlphaOverride(UIView *view, CGFloat *alpha, BOOL *hidden) {
    ApolloDuoVideoAlphaBox *box = objc_getAssociatedObject(view, &kDuoVideoAlpha);
    if (!box) return;
    ApolloDuoVideoCoordinator *owner = box.coordinator;
    if (!owner.active || owner.settingAlpha) return;
    // Transport pieces keep Apollo's hidden state (the live label, mute on a
    // silent clip); only the always-visible post actions are unhidden.
    if (hidden && !box.chrome) *hidden = NO;
    if (alpha) *alpha = box.chrome ? (owner.chromeVisible ? 1 : 0) : 1;
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
    ApolloDuoVideoCoordinator *owner = DuoVideoCoordinator((id)self, NO);
    if (owner.active) {
        // Apollo's toggle also hides Close and the Reddit row. Own the
        // playback fade so those stay put.
        [owner toggleChrome];
        return;
    }
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
- (void)setAlpha:(CGFloat)alpha {
    DuoVideoAlphaOverride((UIView *)self, &alpha, NULL);
    %orig(alpha);
}
- (void)setHidden:(BOOL)hidden {
    DuoVideoAlphaOverride((UIView *)self, NULL, &hidden);
    %orig(hidden);
}
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
- (void)setAlpha:(CGFloat)alpha {
    DuoVideoAlphaOverride((UIView *)self, &alpha, NULL);
    %orig(alpha);
}
- (void)setHidden:(BOOL)hidden {
    DuoVideoAlphaOverride((UIView *)self, NULL, &hidden);
    %orig(hidden);
}
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
- (void)setAlpha:(CGFloat)alpha {
    DuoVideoAlphaOverride((UIView *)self, &alpha, NULL);
    %orig(alpha);
}
- (void)setHidden:(BOOL)hidden {
    DuoVideoAlphaOverride((UIView *)self, NULL, &hidden);
    %orig(hidden);
}
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
- (void)setAlpha:(CGFloat)alpha {
    DuoVideoAlphaOverride((UIView *)self, &alpha, NULL);
    %orig(alpha);
}
- (void)setHidden:(BOOL)hidden {
    DuoVideoAlphaOverride((UIView *)self, NULL, &hidden);
    %orig(hidden);
}
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
        // Remember Apollo's artwork for restore, then draw the shared symbol.
        if (!owner.resyncing) [owner rememberImage:image button:(UIButton *)self state:state];
        UIImage *symbol = image ? [owner symbolForButton:(UIButton *)self] : nil;
        if (symbol) image = symbol;
        [owner scheduleSymbolResync];
    }
    %orig(image, state);
}
%end

// Apollo's Smart Rotation Lock offers "Tap to Rotate Video" from CoreMotion.
// On Duo, folding and tabletop postures read as a sideways device, so the
// offer keeps appearing over the video. Keep the button hidden on Duo only.
%hook _TtC6Apollo22RotationOfferingButton
- (void)setHidden:(BOOL)hidden {
    %orig(YES);
}
- (void)setAlpha:(CGFloat)alpha {
    %orig(0);
}
- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    view.hidden = YES;
    view.userInteractionEnabled = NO;
    view.isAccessibilityElement = NO;
}
%end

%ctor {
    if (!ApolloDeviceIsDuo()) return;
    %init;
    ApolloLog(@"[DuoVideo] tabletop video hooks installed");
}
