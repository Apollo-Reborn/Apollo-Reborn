#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import <math.h>
#import <objc/runtime.h>

static CGFloat ApolloTabIconLinearComponent(CGFloat value) {
    return value <= 0.04045
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4);
}

static CGFloat ApolloTabIconLuminance(UIColor *color) {
    CGFloat red, green, blue, alpha;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha])
        return 0.0;

    return 0.2126 * ApolloTabIconLinearComponent(red)
         + 0.7152 * ApolloTabIconLinearComponent(green)
         + 0.0722 * ApolloTabIconLinearComponent(blue);
}

static UIColor *ApolloInactiveTabIconColor(UITraitCollection *traits) {
    UIColor *accent = ApolloThemeAccentColor();
    if (!accent) return nil;
    if (traits) accent = [accent resolvedColorWithTraitCollection:traits];

    CGFloat hue, saturation, brightness, alpha;
    if (![accent getHue:&hue
              saturation:&saturation
              brightness:&brightness
                   alpha:&alpha]) {
        return accent;
    }

    // Preserve a consistent luminance relationship with the selected accent.
    const CGFloat targetRatio = 0.287441 / 0.248283;
    BOOL darkMode = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    CGFloat target = MIN(ApolloTabIconLuminance(accent) * targetRatio * (darkMode ? 0.85 : 1.20), 1.0);
    // Apply extra desaturation around green, fading smoothly towards other hues.
    CGFloat greenDistance = fabs(hue - 120.0 / 360.0);
    greenDistance = MIN(greenDistance, 1.0 - greenDistance);
    CGFloat greenWeight = MAX(0.0, 1.0 - greenDistance / (60.0 / 360.0));
    greenWeight = greenWeight * greenWeight * (3.0 - 2.0 * greenWeight);

    CGFloat saturationFactor = 0.30 - 0.10 * greenWeight;
    CGFloat mutedSaturation = saturation * saturationFactor;
    CGFloat mutedHue = fmod(hue - 10.0 / 360.0 + 1.0, 1.0);

    CGFloat low = 0.0;
    CGFloat high = 1.0;

    for (NSInteger i = 0; i < 16; i++) {
        CGFloat mid = (low + high) / 2.0;
        UIColor *candidate = [UIColor colorWithHue:mutedHue
                                        saturation:mutedSaturation
                                        brightness:mid
                                             alpha:alpha];

        if (ApolloTabIconLuminance(candidate) < target)
            low = mid;
        else
            high = mid;
    }

    return [UIColor colorWithHue:mutedHue
                     saturation:mutedSaturation
                     brightness:(low + high) / 2.0
                          alpha:alpha];
}


// Default preserves UIKit's original icon rendering and vibrancy.
static NSString * const kApolloTintedTabIconsKey = @"ApolloTintedTabIcons";

static char kOriginalTabImageKey;
static char kOriginalTabEffectKey;
static char kLastTabTintKey;
static char kInternalImageChangeKey;

static BOOL ApolloTabIconsTinted(void) {
    return !IsLiquidGlass() &&
        [[NSUserDefaults standardUserDefaults] boolForKey:kApolloTintedTabIconsKey];
}

static UIView *ApolloTabButtonForIcon(UIView *icon) {
    for (UIView *view = icon.superview; view; view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"UITabBarButton"])
            return view;
    }
    return nil;
}

// Our image assignments must not be mistaken for new images from UIKit.
static void ApolloSetTabIconImage(UIImageView *icon, UIImage *image) {
    objc_setAssociatedObject(icon, &kInternalImageChangeKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    icon.image = image;
    objc_setAssociatedObject(icon, &kInternalImageChangeKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


static UITabBarItem *ApolloTabItemForIcon(UIImageView *icon,
                                         UITabBar **outBar) {
    UIView *button = ApolloTabButtonForIcon(icon);
    if (!button) return nil;

    UITabBar *bar = nil;
    for (UIView *view = button.superview; view; view = view.superview) {
        if ([view isKindOfClass:UITabBar.class]) {
            bar = (UITabBar *)view;
            break;
        }
    }

    if (!bar) return nil;
    if (outBar) *outBar = bar;

    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *view in bar.subviews) {
        if ([NSStringFromClass(view.class)
                isEqualToString:@"UITabBarButton"]) {
            [buttons addObject:view];
        }
    }

    BOOL rightToLeft =
        bar.effectiveUserInterfaceLayoutDirection ==
        UIUserInterfaceLayoutDirectionRightToLeft;

    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat x = CGRectGetMidX(a.frame);
        CGFloat y = CGRectGetMidX(b.frame);

        if (x == y) return NSOrderedSame;

        if (rightToLeft)
            return x > y ? NSOrderedAscending : NSOrderedDescending;

        return x < y ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSUInteger index = [buttons indexOfObject:button];
    return index < bar.items.count ? bar.items[index] : nil;
}

static void ApolloRestoreTabIcon(UIImageView *icon) {
    UIImage *original =
        objc_getAssociatedObject(icon, &kOriginalTabImageKey);

    if (original) {
        ApolloSetTabIconImage(icon, original);
        objc_setAssociatedObject(icon, &kOriginalTabImageKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(icon, &kLastTabTintKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


static void ApolloUpdateTabIcon(UIImageView *icon, BOOL tinted) {
    UIView *button = ApolloTabButtonForIcon(icon);
    if (!button) return;

    UITabBar *bar = nil;
    UITabBarItem *item = ApolloTabItemForIcon(icon, &bar);
    BOOL selected = item && bar.selectedItem == item;
    BOOL applyTint = tinted && !selected;

    for (UIView *view = icon.superview; view && view != button;
         view = view.superview) {
        if (![view isKindOfClass:UIVisualEffectView.class]) continue;

        UIVisualEffectView *effectView = (UIVisualEffectView *)view;
        UIVisualEffect *original =
            objc_getAssociatedObject(effectView, &kOriginalTabEffectKey);

        if (applyTint) {
            if (!original && effectView.effect) {
                objc_setAssociatedObject(effectView, &kOriginalTabEffectKey,
                                         effectView.effect,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            effectView.effect = nil;
        } else if (original) {
            effectView.effect = original;
            objc_setAssociatedObject(effectView, &kOriginalTabEffectKey,
                                     nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        break;
    }

    if (!applyTint) {
        ApolloRestoreTabIcon(icon);

        // Restore the image UIKit actually assigned to this image view.
        // Do not substitute an image from a position-matched tab bar item.
        return;
    }

    UIImage *original =
        objc_getAssociatedObject(icon, &kOriginalTabImageKey);
    if (!original) original = icon.image;
    if (!original) return;

    UIColor *color = ApolloInactiveTabIconColor(icon.traitCollection);
    if (!color) return;

    UIColor *previous =
        objc_getAssociatedObject(icon, &kLastTabTintKey);

    if (objc_getAssociatedObject(icon, &kOriginalTabImageKey) &&
        [previous isEqual:color]) {
        return;
    }

    objc_setAssociatedObject(icon, &kOriginalTabImageKey, original,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(icon, &kLastTabTintKey, color,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImage *coloured =
        [original imageWithTintColor:color
                      renderingMode:UIImageRenderingModeAlwaysOriginal];

    ApolloSetTabIconImage(icon, coloured);
}

static void ApolloUpdateTabButton(UIView *button, BOOL tinted) {
    NSMutableArray<UIView *> *pending =
        [NSMutableArray arrayWithObject:button];

    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];

        if ([NSStringFromClass(view.class)
                containsString:@"UITabBarSwappableImageView"]) {
            ApolloUpdateTabIcon((UIImageView *)view, tinted);
        }

        [pending addObjectsFromArray:view.subviews];
    }
}

static void ApolloRefreshTabIconsInView(UIView *view, BOOL tinted) {
    if ([view isKindOfClass:UITabBar.class]) {
        for (UIView *subview in view.subviews) {
            if ([NSStringFromClass(subview.class)
                    isEqualToString:@"UITabBarButton"]) {
                ApolloUpdateTabButton(subview, tinted);
            }
        }
    }

    for (UIView *subview in view.subviews)
        ApolloRefreshTabIconsInView(subview, tinted);
}

extern "C" void ApolloInactiveTabIconsRefresh(void) {
    void (^refresh)(void) = ^{
        BOOL tinted = ApolloTabIconsTinted();
        for (UIWindow *window in UIApplication.sharedApplication.windows)
            ApolloRefreshTabIconsInView(window, tinted);
    };

    if (NSThread.isMainThread) refresh();
    else dispatch_async(dispatch_get_main_queue(), refresh);
}

%hook UITabBarButton

- (void)_updateToMatchCurrentState {
    %orig;

    UITabBar *bar = nil;
    for (UIView *ancestor = (UIView *)self; ancestor;
         ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UITabBar.class]) {
            bar = (UITabBar *)ancestor;
            break;
        }
    }

    if (bar)
        ApolloUpdateTabButton((UIView *)self, ApolloTabIconsTinted());
}

%end

%hook UITabBarSwappableImageView

- (void)layoutSubviews {
    %orig;
    ApolloUpdateTabIcon((UIImageView *)self, ApolloTabIconsTinted());
}

- (void)setImage:(UIImage *)image {
    // This is an image assignment made by our own implementation.
    // It must not replace the original image saved from UIKit.
    if ([objc_getAssociatedObject(self, &kInternalImageChangeKey) boolValue]) {
        %orig;
        return;
    }

    // UIKit is supplying a new authoritative image. Any previously
    // saved original belongs to the old image and must be discarded.
    objc_setAssociatedObject(self, &kOriginalTabImageKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kLastTabTintKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *button = ApolloTabButtonForIcon((UIView *)self);
    UITabBar *bar = nil;
    UITabBarItem *item =
        ApolloTabItemForIcon((UIImageView *)self, &bar);
    BOOL selected = item && bar.selectedItem == item;

    if (!ApolloTabIconsTinted() || !button || selected || !image) {
        %orig;
        return;
    }

    UIColor *color =
        ApolloInactiveTabIconColor(((UIView *)self).traitCollection);

    if (!color) {
        %orig;
        return;
    }

    objc_setAssociatedObject(self, &kOriginalTabImageKey, image,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kLastTabTintKey, color,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImage *coloured =
        [image imageWithTintColor:color
                   renderingMode:UIImageRenderingModeAlwaysOriginal];

    %orig(coloured);
}

%end
