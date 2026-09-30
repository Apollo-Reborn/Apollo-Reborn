// True Black Keyboard: paints the system keyboard's backdrop pure black for OLED.
//
// The keyboard is drawn in-process by UIKitCore, so it can be restyled from here. The backdrop
// (UIKBBackdropView) loses its blur/glass effect and gets a black fill; under a light-mode app
// the dark render config is used so keycaps and glyphs match the dark keyboard. Hooks fail soft:
// if UIKitCore renames a class the keyboard just looks stock.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

// The dark-config swap below hooks +configForAppearance:inputMode:traitEnvironment:, which UIKit
// added in iOS 15. iOS 14 only has +configForAppearance:inputMode:, so the hook never installs
// there and a light app would get light keycaps on black; keep the stock keyboard in that case.
static BOOL DarkConfigSwapAvailable(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        available = class_getClassMethod(objc_getClass("UIKBRenderConfig"),
            NSSelectorFromString(@"configForAppearance:inputMode:traitEnvironment:")) != NULL;
    });
    return available;
}

// 0 Off, 1 Dark Only, 2 Light Only, 3 Always.
static BOOL TrueBlackKeyboardAppliesTo(UIUserInterfaceStyle style) {
    if (style != UIUserInterfaceStyleDark && !DarkConfigSwapAvailable()) return NO;
    switch ([[NSUserDefaults standardUserDefaults] integerForKey:UDKeyTrueBlackKeyboardMode]) {
        case 1: return style == UIUserInterfaceStyleDark;
        case 2: return style != UIUserInterfaceStyleDark;
        case 3: return YES;
        default: return NO;
    }
}

// The app's appearance (Apollo may override it per window), from its first normal-level window.
static UIUserInterfaceStyle AppInterfaceStyle(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.windowLevel == UIWindowLevelNormal) return window.traitCollection.userInterfaceStyle;
    }
    return UIUserInterfaceStyleUnspecified;
}

static const void *kEdgeFillKey = &kEdgeFillKey;
// Uncovered height at the top, keeping the top corners rounded.
static const CGFloat kTopCornerClearance = 44;

// The backdrop's edges are a hair tighter than the screen's, so slivers of the app can show at
// the sides and bottom corners. A black strip behind it, a few points wider than the backdrop
// (the screen clips the excess), fills that; it starts below the top corners so they stay round.
// Uses constraints rather than frame writes so it can't loop during layout.
static void UpdateEdgeFill(UIVisualEffectView *backdrop, BOOL show) {
    UIView *fill = objc_getAssociatedObject(backdrop, kEdgeFillKey);
    if (!show) {
        fill.hidden = YES;
        return;
    }
    UIView *host = backdrop.superview;
    if (!host) return;
    if (!fill || fill.superview != host) {
        [fill removeFromSuperview];
        fill = [[UIView alloc] init];
        fill.backgroundColor = UIColor.blackColor;
        fill.userInteractionEnabled = NO;
        fill.translatesAutoresizingMaskIntoConstraints = NO;
        [host insertSubview:fill belowSubview:backdrop];
        [NSLayoutConstraint activateConstraints:@[
            [fill.leadingAnchor constraintEqualToAnchor:backdrop.leadingAnchor constant:-4],
            [fill.trailingAnchor constraintEqualToAnchor:backdrop.trailingAnchor constant:4],
            [fill.bottomAnchor constraintEqualToAnchor:backdrop.bottomAnchor constant:4],
            [fill.topAnchor constraintEqualToAnchor:backdrop.topAnchor constant:kTopCornerClearance],
        ]];
        objc_setAssociatedObject(backdrop, kEdgeFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    fill.hidden = NO;
}

// What the tweak overwrote on a backdrop, so it can be put back when the mode stops applying.
@interface ApolloTrueBlackBackdropState : NSObject
@property (nonatomic, strong) UIVisualEffect *effect;
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, strong) UIColor *contentBackgroundColor;
@property (nonatomic, strong) NSHashTable<UIView *> *hiddenSubviews;
@end
@implementation ApolloTrueBlackBackdropState
@end

static const void *kBackdropStateKey = &kBackdropStateKey;

static void ApplyTrueBlack(UIVisualEffectView *backdrop) {
    BOOL applies = TrueBlackKeyboardAppliesTo(AppInterfaceStyle());
    UpdateEdgeFill(backdrop, applies);
    ApolloTrueBlackBackdropState *state = objc_getAssociatedObject(backdrop, kBackdropStateKey);

    if (!applies) {
        if (!state) return;
        // Put back exactly what was changed; the retained backdrop outlives the setting.
        backdrop.effect = state.effect;
        backdrop.backgroundColor = state.backgroundColor;
        backdrop.contentView.backgroundColor = state.contentBackgroundColor;
        for (UIView *sub in state.hiddenSubviews) sub.hidden = NO;
        objc_setAssociatedObject(backdrop, kBackdropStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (!state) {
        state = [[ApolloTrueBlackBackdropState alloc] init];
        state.backgroundColor = backdrop.backgroundColor;
        state.contentBackgroundColor = backdrop.contentView.backgroundColor;
        state.hiddenSubviews = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(backdrop, kBackdropStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // UIKit may install a fresh effect while applied; remember the latest one.
    if (backdrop.effect) {
        state.effect = backdrop.effect;
        backdrop.effect = nil;
    }
    backdrop.backgroundColor = UIColor.blackColor;
    backdrop.contentView.backgroundColor = UIColor.blackColor;
    for (UIView *sub in backdrop.subviews) {
        // Any private glass/blur layer view UIKit adds beside the content view.
        if (sub != backdrop.contentView && !sub.hidden) {
            sub.hidden = YES;
            [state.hiddenSubviews addObject:sub];
        }
    }
}

// Black backdrop under a light-mode app: the light keycaps/glyphs (emoji, mic, return key)
// would look wrong or vanish on black, so build the dark keyboard config instead.
%hook UIKBRenderConfig

+ (id)configForAppearance:(long long)appearance inputMode:(id)inputMode traitEnvironment:(id)traitEnvironment {
    if (appearance != UIKeyboardAppearanceDark &&
        TrueBlackKeyboardAppliesTo(AppInterfaceStyle()) && AppInterfaceStyle() != UIUserInterfaceStyleDark) {
        return %orig(UIKeyboardAppearanceDark, inputMode, traitEnvironment);
    }
    return %orig;
}

%end

%hook UIKBBackdropView

- (void)didMoveToWindow {
    %orig;
    ApplyTrueBlack((UIVisualEffectView *)self);
}

- (void)layoutSubviews {
    %orig;
    // Idempotent color/effect writes only, no geometry.
    ApplyTrueBlack((UIVisualEffectView *)self);
}

- (void)_setRenderConfig:(id)config {
    %orig;
    ApplyTrueBlack((UIVisualEffectView *)self);
}

%end
