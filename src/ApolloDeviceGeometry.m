#import "ApolloDeviceGeometry.h"
#import "ApolloDeviceChromeInsets.h"
#import "ApolloDeviceDisplay.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

// Apollo's ThemeableWindow lays out DI chrome for iPhone 14 Pro:
//   sub_10030afa0: FauxCutOutView y=11.5, w=125, h=37
//   sub_10030c880: PixelPalView y=-2.0
//   sub_10030d6c4: tap overlay y=11.0, w=125, h=37, cornerRadius=18.5
// Those constants stay here because they are Apollo's, not ours — we only
// compute the delta to the live cutout. Do not use them as a stand-in for
// "this device's island."

static const CGFloat kApolloFauxCutOutY = 11.5;
static const CGFloat kApolloFauxCutOutHeight = 37.0;

UIWindowScene *ApolloDevicePreferredWindowScene(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (!application) return nil;

    UIWindowScene *firstActive = nil;
    UIWindowScene *largestActive = nil;
    UIWindowScene *fallback = nil;
    UIWindowScene *largestAny = nil;
    CGFloat largestActiveArea = -1.0;
    CGFloat largestAnyArea = -1.0;
    CGFloat screenSizes[8][2];
    unsigned screenCount = 0;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        CGSize size = windowScene.screen.bounds.size;
        CGFloat area = (CGFloat)ApolloDisplayArea(size.width, size.height);
        if (!fallback) fallback = windowScene;
        if (area > largestAnyArea) {
            largestAnyArea = area;
            largestAny = windowScene;
        }
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            if (!firstActive) firstActive = windowScene;
            if (area > largestActiveArea) {
                largestActiveArea = area;
                largestActive = windowScene;
            }
        }
        if (size.width > 0.0 && size.height > 0.0 && screenCount < 8) {
            unsigned i;
            int seen = 0;
            for (i = 0; i < screenCount; i++) {
                if (fabs(screenSizes[i][0] - size.width) < 1.0
                    && fabs(screenSizes[i][1] - size.height) < 1.0) {
                    seen = 1;
                    break;
                }
            }
            if (!seen) {
                screenSizes[screenCount][0] = size.width;
                screenSizes[screenCount][1] = size.height;
                screenCount++;
            }
        }
    }

    int dual = 0;
    if (screenCount >= 2) {
        dual = ApolloDisplayScreensAreDual(screenSizes[0][0], screenSizes[0][1],
                                           screenSizes[1][0], screenSizes[1][1]);
    }
    if (ApolloDisplayShouldPreferLargestScene((int)screenCount, dual)) {
        return largestActive ?: largestAny ?: firstActive ?: fallback;
    }
    return firstActive ?: fallback;
}

UIScreen *ApolloDevicePreferredScreen(void) {
    UIWindowScene *scene = ApolloDevicePreferredWindowScene();
    if (scene.screen) return scene.screen;
    return [UIScreen mainScreen];
}

UIEdgeInsets ApolloDeviceChromeInsetsForView(UIView *view) {
    if (!view) return UIEdgeInsetsZero;
    UIEdgeInsets safe = view.safeAreaInsets;
    UIEdgeInsets margins = view.layoutMargins;
    return UIEdgeInsetsMake(ApolloDeviceChromeInset(safe.top, margins.top),
                            ApolloDeviceChromeInset(safe.left, margins.left),
                            ApolloDeviceChromeInset(safe.bottom, margins.bottom),
                            ApolloDeviceChromeInset(safe.right, margins.right));
}

UIScreen *ApolloDeviceScreenForWindow(UIWindow *window) {
    if (window.windowScene.screen) return window.windowScene.screen;
    return ApolloDevicePreferredScreen();
}

BOOL ApolloDynamicIslandRectForScreen(UIScreen *screen, CGRect *outRect) {
    if (!screen || !outRect) return NO;
    SEL exclusionSel = NSSelectorFromString(@"_exclusionArea");
    if (![screen respondsToSelector:exclusionSel]) return NO;
    id area = ((id (*)(id, SEL))objc_msgSend)(screen, exclusionSel);
    SEL rectSel = NSSelectorFromString(@"rect");
    if (!area || ![area respondsToSelector:rectSel]) return NO;
    CGRect rect = ((CGRect (*)(id, SEL))objc_msgSend)(area, rectSel);
    // Mirror -[_UIStatusBarVisualProvider_DynamicSplit sensorAreaRect]'s
    // conversion into the current (Display Zoom) coordinate space.
    CGFloat nativeScale = screen.nativeScale;
    CGFloat scale = screen.scale;
    if (nativeScale > 0 && scale > 0 && nativeScale != scale) {
        CGFloat zoom = nativeScale / scale;
        rect.origin.x *= zoom;
        rect.origin.y *= zoom;
        rect.size.width *= zoom;
        rect.size.height *= zoom;
    }
    // Pill near the top of *this* screen. Bounds are looser than the old
    // 14 Pro-era 40/60pt caps so a taller status region or a slightly
    // wider island on a compact outer foldable panel still counts, but
    // a hinge / reserved-region bar (tall or full-width) does not.
    CGFloat screenWidth = CGRectGetWidth(screen.bounds);
    if (CGRectIsEmpty(rect) ||
        rect.origin.y < 0.0 || rect.origin.y > 80.0 ||
        rect.size.height < 16.0 || rect.size.height > 80.0 ||
        rect.size.width < 40.0 ||
        (screenWidth > 0.0 && rect.size.width > screenWidth * 0.75)) {
        return NO;
    }
    *outRect = rect;
    return YES;
}

BOOL ApolloDynamicIslandRectForWindow(UIWindow *window, CGRect *outRect) {
    return ApolloDynamicIslandRectForScreen(ApolloDeviceScreenForWindow(window), outRect);
}

CGFloat ApolloPixelPalShiftForWindow(UIWindow *window) {
    UIScreen *screen = ApolloDeviceScreenForWindow(window);
    CGFloat nativeScale = screen.nativeScale;
    CGFloat halfPx = 0.5 / (nativeScale > 0 ? nativeScale : 3.0);

    CGRect island;
    if (!ApolloDynamicIslandRectForScreen(screen, &island)) {
        // No live cutout — do not invent a 14 Pro (safeTop=59) proportional
        // shift. That model over-moved pals on iPhone Air / iOS 27 (#826)
        // and would be worse on a foldable whose safe area and island
        // (or hinge) move independently.
        return 0.0;
    }

    // Center Apollo's 37pt faux pill on the real cutout; floor to the
    // nearest half-pixel to match the baseline's sub-pixel alignment.
    CGFloat correctY = floor((CGRectGetMidY(island) - kApolloFauxCutOutHeight / 2.0) / halfPx) * halfPx;
    CGFloat shift = correctY - kApolloFauxCutOutY;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        ApolloLog(@"[PixelPals] island cutout {%.2f, %.2f, %.2f, %.2f} safeTop=%.1f → shift %.3f",
                  island.origin.x, island.origin.y, island.size.width, island.size.height,
                  window.safeAreaInsets.top, shift);
    });
    // Baseline devices land within a half-point of Apollo's own 11.5;
    // leave them untouched.
    return fabs(shift) < 0.75 ? 0.0 : shift;
}

BOOL ApolloShouldShowDynamicIslandChromeInWindow(UIWindow *window) {
    UIScreen *screen = ApolloDeviceScreenForWindow(window);
    if (!screen) return YES;
    SEL exclusionSel = NSSelectorFromString(@"_exclusionArea");
    if (![screen respondsToSelector:exclusionSel]) return YES;
    CGRect island;
    return ApolloDynamicIslandRectForScreen(screen, &island);
}
