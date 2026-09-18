#ifndef APOLLO_DEVICE_DISPLAY_H
#define APOLLO_DEVICE_DISPLAY_H

#ifdef __cplusplus
extern "C" {
#endif

// C-only canvas / multi-display helpers so host tests compile without UIKit.
// iPhone Duo letterboxes a guest whose LC_BUILD_VERSION SDK is older than
// 27.1 (phone column on the left of the inner panel). After the glass
// binary advertises 27.1, the scene should already be full-bleed; these
// helpers still detect a leftover phone-sized window and pick the inner
// (largest) screen when two displays differ.

enum {
    ApolloDisplayLetterboxMinGap = 40,   /* points: window vs screen */
    ApolloDisplayDualScreenNum = 5,
    ApolloDisplayDualScreenDen = 4,      /* area ratio >= 1.25 */
};

static inline double ApolloDisplayArea(double width, double height) {
    if (width < 0.0) width = 0.0;
    if (height < 0.0) height = 0.0;
    return width * height;
}

static inline int ApolloDisplayIsLetterboxed(double windowWidth,
                                             double windowHeight,
                                             double screenWidth,
                                             double screenHeight) {
    if (screenWidth <= 0.0 || screenHeight <= 0.0) return 0;
    if (windowWidth <= 0.0 || windowHeight <= 0.0) return 1;
    const double gap = (double)ApolloDisplayLetterboxMinGap;
    return (screenWidth - windowWidth) >= gap || (screenHeight - windowHeight) >= gap;
}

// Two attached screens whose areas differ by >= 25% — Duo inner vs cover,
// not iPad Stage Manager tiles on one screen.
static inline int ApolloDisplayScreensAreDual(double aWidth, double aHeight,
                                              double bWidth, double bHeight) {
    double a = ApolloDisplayArea(aWidth, aHeight);
    double b = ApolloDisplayArea(bWidth, bHeight);
    if (a <= 0.0 || b <= 0.0) return 0;
    double larger = a > b ? a : b;
    double smaller = a > b ? b : a;
    return larger * (double)ApolloDisplayDualScreenDen
        >= smaller * (double)ApolloDisplayDualScreenNum;
}

// When two screens look like inner+cover, prefer the larger (inner) scene
// among the foreground-active ones. Single-screen iPhone / iPad keep the
// first-active behavior.
static inline int ApolloDisplayShouldPreferLargestScene(int distinctScreens,
                                                        int dualDisplay) {
    return distinctScreens >= 2 && dualDisplay;
}

#ifdef __cplusplus
}
#endif

#if defined(__OBJC__) && !defined(APOLLO_DEVICE_DISPLAY_C_ONLY)
#import <UIKit/UIKit.h>

__BEGIN_DECLS

/// Apollo's `ThemeableWindow` when one exists, else the first normal-level
/// app window with a root view controller.
UIWindow *ApolloDeviceAppWindow(void);

/// Raise `sizeRestrictions` and request a geometry update so a letterboxed
/// scene can grow to its screen. No-op when the selectors are missing.
void ApolloDeviceExpandSceneToScreen(UIWindowScene *scene);

/// Move `window` onto the preferred (inner) scene if needed, then size it
/// to the scene/screen canvas. Safe on iOS 14 (missing APIs are skipped).
void ApolloDeviceFillWindowToActiveCanvas(UIWindow *window);

/// Fill the app window. Call from scene connect / activation / become-key.
void ApolloDeviceFillAppWindowToActiveCanvas(void);

__END_DECLS
#endif

#endif
