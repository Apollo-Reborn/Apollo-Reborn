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

// 0 Off, 1 Dark Only, 2 Light Only, 3 Always.
static BOOL TrueBlackKeyboardAppliesTo(UIUserInterfaceStyle style) {
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

static void ApplyTrueBlack(UIVisualEffectView *backdrop) {
    BOOL applies = TrueBlackKeyboardAppliesTo(AppInterfaceStyle());
    UpdateEdgeFill(backdrop, applies);
    if (!applies) return;
    if (backdrop.effect) backdrop.effect = nil;
    backdrop.backgroundColor = UIColor.blackColor;
    backdrop.contentView.backgroundColor = UIColor.blackColor;
    for (UIView *sub in backdrop.subviews) {
        // Any private glass/blur layer view UIKit adds beside the content view.
        if (sub != backdrop.contentView) sub.hidden = YES;
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
