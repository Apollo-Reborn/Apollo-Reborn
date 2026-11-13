// ApolloTabBarStyle — Tint Tab Bar Icons: unselected tab icons in a muted
// shade of the theme accent.
//
// The tab bar appearances' normal-state iconColor carries the shade; selected
// icons, titles, and the profile avatar icon are untouched, and turning it off
// clears the color.
//   - Classic: Apollo supplies its tab icons pre-colored (AlwaysOriginal:
//     gray unselected, accent selected), so UIKit's tint never reaches them.
//     Unselected images are templated while the tint is on and restored
//     when it is turned off.
//   - Liquid Glass: ApolloLiquidGlass.xm already templates the images and
//     keeps the appearance adaptive, so it leaves this color alone. The
//     floating bar then draws unselected icons through a "monochromatic
//     treatment" that ignores the tint, so tinted icons keep it suppressed
//     (as the avatar icon does) and are re-clamped after a tab button's
//     layout, since rebuilds re-apply it without the hooked setters. The
//     Duo side rail hosts the same tab buttons in a SwiftUI toolbar and
//     follows along.

#import "ApolloTabBarStyle.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

#define TabBarStyleLog(fmt, ...) ApolloLog(@"[TabBarStyle] " fmt, ##__VA_ARGS__)

static NSString *const kApolloThemeChangedNotification = @"com.christianselig.ApolloSpecificThemeChanged";

static void ApolloTabBarCollectViews(UIView *view, Class cls, NSMutableArray *result) {
    if ([view isKindOfClass:cls]) {
        [result addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) ApolloTabBarCollectViews(subview, cls, result);
}

static NSArray<UITabBar *> *ApolloTabBarAllTabBars(void) {
    NSMutableArray<UITabBar *> *tabBars = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) ApolloTabBarCollectViews(window, UITabBar.class, tabBars);
    return tabBars;
}

#pragma mark - Inactive icon tint

static CGFloat ApolloTabBarLinearComponent(CGFloat value) {
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static CGFloat ApolloTabBarLuminance(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return 0;
    return 0.2126 * ApolloTabBarLinearComponent(r)
         + 0.7152 * ApolloTabBarLinearComponent(g)
         + 0.0722 * ApolloTabBarLinearComponent(b);
}

// A muted shade of the accent: its hue shifted 10 degrees, saturation cut to
// 30% (20% around green), at a luminance tied to the accent's. Returns nil
// for an achromatic accent (Monochromatic, Fisher King, Chumbus): there is no
// hue to mute, and the formula would land on the selected color itself.
static UIColor *ApolloInactiveTabIconColor(UITraitCollection *traits) {
    UIColor *accent = [ApolloThemeAccentColor() resolvedColorWithTraitCollection:traits];
    CGFloat r = 0, g = 0, b = 0, alpha = 0;
    if (!accent || ![accent getRed:&r green:&g blue:&b alpha:&alpha]) return nil;
    if (MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < 0.08) return nil;

    CGFloat hue = 0, saturation = 0, brightness = 0;
    [accent getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];

    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    CGFloat target = ApolloTabBarLuminance(accent) * (0.287441 / 0.248283) * (dark ? 0.85 : 1.20);
    // On a light bar, stay at least 2.5:1 against white so pale accents
    // (Skies on Skies, Mint) don't fade out.
    target = MIN(target, dark ? 1.0 : 0.37);

    CGFloat greenDistance = fabs(hue - 120.0 / 360.0);
    greenDistance = MIN(greenDistance, 1.0 - greenDistance);
    CGFloat greenWeight = MAX(0.0, 1.0 - greenDistance / (60.0 / 360.0));
    greenWeight = greenWeight * greenWeight * (3.0 - 2.0 * greenWeight);

    CGFloat mutedSaturation = saturation * (0.30 - 0.10 * greenWeight);
    CGFloat mutedHue = fmod(hue - 10.0 / 360.0 + 1.0, 1.0);

    CGFloat low = 0.0, high = 1.0;
    for (NSInteger i = 0; i < 16; i++) {
        CGFloat mid = (low + high) / 2.0;
        UIColor *candidate = [UIColor colorWithHue:mutedHue saturation:mutedSaturation brightness:mid alpha:alpha];
        if (ApolloTabBarLuminance(candidate) < target) low = mid;
        else high = mid;
    }
    return [UIColor colorWithHue:mutedHue saturation:mutedSaturation brightness:(low + high) / 2.0 alpha:alpha];
}

static char kApolloTabBarIconTintOwnedKey;
static char kApolloTabBarOriginalIconKey;
static UIColor *sApolloTabBarIconTint;

static BOOL ApolloTabBarIsOurs(id object) {
    return object && [objc_getAssociatedObject(object, &kApolloTabBarIconTintOwnedKey) boolValue];
}

static void ApolloTabBarMarkOurs(id object) {
    objc_setAssociatedObject(object, &kApolloTabBarIconTintOwnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// nil when the tint is off or the accent is achromatic in both appearances.
static UIColor *ApolloTabBarCurrentIconTint(void) {
    if (!sTintInactiveTabIcons) return nil;
    if (sApolloTabBarIconTint) return sApolloTabBarIconTint;

    UITraitCollection *light = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
    UITraitCollection *dark = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
    if (!ApolloInactiveTabIconColor(light) && !ApolloInactiveTabIconColor(dark)) return nil;

    UIColor *tint = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return ApolloInactiveTabIconColor(traits) ?: [UIColor.systemGrayColor resolvedColorWithTraitCollection:traits];
    }];
    ApolloTabBarMarkOurs(tint);
    sApolloTabBarIconTint = tint;
    return tint;
}

// The profile avatar icon keeps its own colors (ApolloUserAvatars.xm).
static BOOL ApolloTabBarItemShowsAvatar(UITabBarItem *item) {
    return [objc_getAssociatedObject(item, @selector(apollo_profileTabAvatarIconActive)) boolValue];
}

// The image to install for an item: a template of Apollo's image while the
// tint is on (remembering the original), otherwise the image as given.
static UIImage *ApolloTabBarIconImage(UITabBarItem *item, UIImage *image) {
    if (ApolloTabBarIsOurs(image)) return image;
    objc_setAssociatedObject(item, &kApolloTabBarOriginalIconKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!image || !ApolloTabBarCurrentIconTint() || ApolloTabBarItemShowsAvatar(item) ||
        image.renderingMode == UIImageRenderingModeAlwaysTemplate) {
        return image;
    }
    UIImage *templated = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    ApolloTabBarMarkOurs(templated);
    return templated;
}

static NSArray<UITabBarItemAppearance *> *ApolloTabBarItemAppearances(UITabBarAppearance *appearance) {
    return @[ appearance.stackedLayoutAppearance,
              appearance.inlineLayoutAppearance,
              appearance.compactInlineLayoutAppearance ];
}

// Returns the appearance unchanged when it already matches, so re-assigning
// it from our own refresh is a no-op.
static UITabBarAppearance *ApolloTabBarAppearanceWithIconTint(UITabBarAppearance *appearance) {
    if (!appearance) return appearance;

    UIColor *tint = ApolloTabBarCurrentIconTint();
    BOOL stale = NO;
    for (UITabBarItemAppearance *item in ApolloTabBarItemAppearances(appearance)) {
        UIColor *current = item.normal.iconColor;
        if (tint ? current != tint : ApolloTabBarIsOurs(current)) { stale = YES; break; }
    }
    if (!stale) return appearance;

    UITabBarAppearance *updated = [appearance copy];
    for (UITabBarItemAppearance *item in ApolloTabBarItemAppearances(updated)) {
        if (tint) item.normal.iconColor = tint;
        else if (ApolloTabBarIsOurs(item.normal.iconColor)) item.normal.iconColor = nil;
    }
    return updated;
}

static void ApolloTabBarApplyIconTint(UITabBar *tabBar) {
    UIColor *tint = ApolloTabBarCurrentIconTint();
    // Liquid Glass already templates its tab images (ApolloLiquidGlass.xm).
    for (UITabBarItem *item in IsLiquidGlass() ? @[] : tabBar.items) {
        UIImage *current = item.image;
        UIImage *original = objc_getAssociatedObject(item, &kApolloTabBarOriginalIconKey);
        if (tint && !ApolloTabBarIsOurs(current)) item.image = current;   // templated by the hook
        else if (!tint && ApolloTabBarIsOurs(current) && original) item.image = original;
    }

    UITabBarAppearance *standard = tabBar.standardAppearance;
    UITabBarAppearance *tintedStandard = ApolloTabBarAppearanceWithIconTint(standard);
    if (tintedStandard != standard) tabBar.standardAppearance = tintedStandard;
    if (@available(iOS 15.0, *)) {
        UITabBarAppearance *scrollEdge = tabBar.scrollEdgeAppearance;
        UITabBarAppearance *tintedScrollEdge = ApolloTabBarAppearanceWithIconTint(scrollEdge);
        if (tintedScrollEdge != scrollEdge) tabBar.scrollEdgeAppearance = tintedScrollEdge;
    }
    // Tab buttons only re-read their appearance data on layout.
    [tabBar setNeedsLayout];
}

// Liquid Glass renders unselected icons through a "monochromatic treatment"
// that replaces the image view's tint with black/white, so the appearance's
// iconColor reaches the icons but never shows. While an icon carries our
// tint, the treatment is kept off (the avatar icon does the same in
// ApolloUserAvatars.xm); turning the tint off lets UIKit put it back.
static BOOL sApolloTabBarClampingTreatment;

static BOOL ApolloTabBarIconViewIsTinted(UIImageView *imageView) {
    return sTintInactiveTabIcons && IsLiquidGlass() && ApolloTabBarIsOurs(imageView.tintColor);
}

static char kApolloTabBarIconClampedKey;

// UIKit derives the treatment from inputs (a preferred treatment and a
// suppress flag) whenever the host's tint changes, so the suppress input is
// what sticks; the two output setters cover builds without it. Only icons
// clamped here are ever released: UIKit's accent copy of the selected tab
// carries the treatment UIKit chose for it, and forcing that back on turns
// the selected icon black (seen after Control Center).
static void ApolloTabBarSetGlassTreatment(UIImageView *imageView, BOOL tinted) {
    SEL suppressSel = @selector(_setSuppressMonochromaticTreatment:);
    SEL enableSel = @selector(_setEnableMonochromaticTreatment:);
    SEL modeSel = @selector(_setMonochromaticTreatment:);
    if (![imageView respondsToSelector:modeSel]) return;
    objc_setAssociatedObject(imageView, &kApolloTabBarIconClampedKey, tinted ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sApolloTabBarClampingTreatment = YES;
    if ([imageView respondsToSelector:suppressSel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(imageView, suppressSel, tinted);
    // 2 is the treatment UIKit applies to unselected tab icons.
    ((void (*)(id, SEL, int64_t))objc_msgSend)(imageView, modeSel, tinted ? 0 : 2);
    if ([imageView respondsToSelector:enableSel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(imageView, enableSel, !tinted);
    sApolloTabBarClampingTreatment = NO;
}

static void ApolloTabBarClampGlassTreatment(UIImageView *imageView) {
    ApolloTabBarSetGlassTreatment(imageView, YES);
}

// Hands an icon this file clamped back to UIKit's unselected treatment.
static void ApolloTabBarReleaseGlassTreatment(UIImageView *imageView) {
    if (![objc_getAssociatedObject(imageView, &kApolloTabBarIconClampedKey) boolValue]) return;
    ApolloTabBarSetGlassTreatment(imageView, NO);
}

// Keeps a tab button's tinted icons clear of the treatment; icons UIKit
// colors itself (the selected copy, the avatar) are left as they are.
static void ApolloTabBarClampTintedButtonIcons(UIView *button) {
    for (UIView *subview in button.subviews) {
        if (![subview isKindOfClass:UIImageView.class]) continue;
        UIImageView *icon = (UIImageView *)subview;
        if (icon.image.renderingMode == UIImageRenderingModeAlwaysTemplate && ApolloTabBarIconViewIsTinted(icon)) {
            ApolloTabBarClampGlassTreatment(icon);
        }
    }
}

static void ApolloTabBarRefreshGlassTreatment(void) {
    if (!IsLiquidGlass() || !ApolloClassUITabButton) return;
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) ApolloTabBarCollectViews(window, ApolloClassUITabButton, buttons);
    for (UIView *button in buttons) {
        NSMutableArray<UIImageView *> *icons = [NSMutableArray array];
        ApolloTabBarCollectViews(button, UIImageView.class, icons);
        for (UIImageView *icon in icons) {
            if (icon.image.renderingMode != UIImageRenderingModeAlwaysTemplate) continue;   // avatar
            if (ApolloTabBarIconViewIsTinted(icon)) ApolloTabBarClampGlassTreatment(icon);
            else ApolloTabBarReleaseGlassTreatment(icon);
        }
    }
}

// The Duo side rail's tab platter sits outside UITabBar, so the bar's own
// layout never reaches it; its buttons only take a changed appearance color
// on a layout of the platter itself, so give it one right away.
static void ApolloTabBarLayOutGlassPlatters(void) {
    if (!IsLiquidGlass() || !ApolloClassUITabBarItemPlatterView) return;
    NSMutableArray<UIView *> *platters = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) ApolloTabBarCollectViews(window, ApolloClassUITabBarItemPlatterView, platters);
    for (UIView *platter in platters) {
        NSMutableArray<UIView *> *buttons = [NSMutableArray array];
        if (ApolloClassUITabButton) ApolloTabBarCollectViews(platter, ApolloClassUITabButton, buttons);
        for (UIView *button in buttons) [button setNeedsLayout];
        [platter setNeedsLayout];
        [platter layoutIfNeeded];
    }
}

static void ApolloTabBarRefreshIconTint(void) {
    NSArray<UITabBar *> *tabBars = ApolloTabBarAllTabBars();
    for (UITabBar *tabBar in tabBars) ApolloTabBarApplyIconTint(tabBar);
    ApolloTabBarLayOutGlassPlatters();
    // The tab buttons pick the appearance color up on the layout just asked for.
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloTabBarRefreshGlassTreatment(); });
    TabBarStyleLog(@"icon tint %@ on %lu tab bar(s)",
                   ApolloTabBarCurrentIconTint() ? @"applied" : @"cleared", (unsigned long)tabBars.count);
}

BOOL ApolloTabBarIconTintOwnsColor(UIColor *color) {
    return ApolloTabBarIsOurs(color);
}

void ApolloTabBarIconTintSetEnabled(BOOL enabled) {
    if (sTintInactiveTabIcons == enabled) return;
    sTintInactiveTabIcons = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:UDKeyTintInactiveTabIcons];
    ApolloTabBarRefreshIconTint();
}

%group ApolloTabBarIconTemplatesClassic

%hook UITabBarItem

- (void)setImage:(UIImage *)image {
    %orig(ApolloTabBarIconImage((UITabBarItem *)self, image));
}

%end

%end

%group ApolloTabBarIconTintGlass

%hook UITabBar

// An appearance change re-applies the treatment without the setters below.
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    if (sTintInactiveTabIcons) dispatch_async(dispatch_get_main_queue(), ^{ ApolloTabBarRefreshGlassTreatment(); });
}

%end

// A rebuilt tab button (Icon-Only toggles, item changes) re-applies the
// treatment to its icons without the setters below, so clamp after its layout.
%hook _UITabButton

- (void)layoutSubviews {
    %orig;
    if (sTintInactiveTabIcons) ApolloTabBarClampTintedButtonIcons((UIView *)self);
}

%end

%hook UIImageView

// A rebuilt tab icon can get its treatment before its tint, and nothing lays
// it out again until the next tab switch; clamp once the tint becomes ours.
- (void)tintColorDidChange {
    %orig;
    if (sTintInactiveTabIcons && !sApolloTabBarClampingTreatment && ApolloClassUITabButton &&
        [self.superview isKindOfClass:ApolloClassUITabButton] &&
        self.image.renderingMode == UIImageRenderingModeAlwaysTemplate &&
        ApolloTabBarIconViewIsTinted(self)) {
        ApolloTabBarClampGlassTreatment(self);
    }
}

// The re-derivation UIKit runs when a tab button's tint changes.
- (void)_applyMonochromaticInputsWithPreferredTreatment:(int64_t)treatment suppressTreatment:(BOOL)suppress {
    if (!sApolloTabBarClampingTreatment && ApolloTabBarIconViewIsTinted(self)) suppress = YES;
    %orig(treatment, suppress);
}

- (void)_setEnableMonochromaticTreatment:(BOOL)enable {
    if (enable && !sApolloTabBarClampingTreatment && ApolloTabBarIconViewIsTinted(self)) {
        %orig(NO);
        return;
    }
    %orig(enable);
}

- (void)_setMonochromaticTreatment:(int64_t)treatment {
    if (treatment != 0 && !sApolloTabBarClampingTreatment && ApolloTabBarIconViewIsTinted(self)) {
        %orig(0);
        return;
    }
    %orig(treatment);
}

%end

%end

%group ApolloTabBarIconTint

%hook UITabBar

- (void)setStandardAppearance:(UITabBarAppearance *)appearance {
    %orig(ApolloTabBarAppearanceWithIconTint(appearance));
}

- (void)setScrollEdgeAppearance:(UITabBarAppearance *)appearance {
    %orig(ApolloTabBarAppearanceWithIconTint(appearance));
}

- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window && sTintInactiveTabIcons) ApolloTabBarApplyIconTint((UITabBar *)self);
}

%end

%end

#pragma mark - Setup

%ctor {
    %init(ApolloTabBarIconTint);
    if (!IsLiquidGlass()) {
        %init(ApolloTabBarIconTemplatesClassic);
    } else if (ApolloClassUITabButton &&
               class_getInstanceMethod(UIImageView.class, @selector(_setMonochromaticTreatment:)) &&
               class_getInstanceMethod(UIImageView.class, @selector(_setEnableMonochromaticTreatment:)) &&
               class_getInstanceMethod(UIImageView.class, @selector(_applyMonochromaticInputsWithPreferredTreatment:suppressTreatment:))) {
        %init(ApolloTabBarIconTintGlass);
    } else {
        TabBarStyleLog(@"glass icon tint unavailable: UIKit's monochromatic treatment hooks are missing");
    }

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:kApolloThemeChangedNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        // Apollo finishes applying the theme after posting; rebuild on the next turn.
        dispatch_async(dispatch_get_main_queue(), ^{
            sApolloTabBarIconTint = nil;
            if (sTintInactiveTabIcons) ApolloTabBarRefreshIconTint();
        });
    }];
    if (IsLiquidGlass()) {
        // Control Center and Notification Center take the scene inactive and
        // back without a layout; the glass bar re-derives its treatment on the
        // way, so re-clamp once the app is active again.
        for (NSNotificationName name in @[ UIApplicationDidBecomeActiveNotification, UISceneDidActivateNotification ]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(__unused NSNotification *note) {
                if (sTintInactiveTabIcons) dispatch_async(dispatch_get_main_queue(), ^{ ApolloTabBarRefreshGlassTreatment(); });
            }];
        }
    }
    TabBarStyleLog(@"module loaded (%@)", IsLiquidGlass() ? @"Liquid Glass" : @"classic");
}
