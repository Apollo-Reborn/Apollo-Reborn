#ifndef APOLLO_DUO_COMPATIBILITY_H
#define APOLLO_DUO_COMPATIBILITY_H

#ifdef __cplusplus
extern "C" {
#endif

#include "ApolloDeviceDisplay.h"

// Duo chrome is keyed off the *window* the user can see, never
// UIScreen.mainScreen.bounds. A leftover phone-column window
// (narrow portrait panel on the inner canvas) must be expanded
// before any rail / list work, or every UI change stays trapped
// in that center strip.
//
// Layout mode uses the same window bounds:
//   Phone  — regular iPhone (not Duo): stock tab bar
//   Closed — portrait-sized Duo window: right rail
//   Open   — wide landscape-sized Duo window: left rail
// Dual-display (cover+inner) or a wide window is what marks Duo so
// a normal phone portrait is not treated as Closed.

enum {
    ApolloDuoWideWindowThreshold = 1000, /* points; MAX(w,h) must be greater */
    ApolloDuoModePhone = 0,
    ApolloDuoModeClosed = 1,
    ApolloDuoModeOpen = 2,
};

static inline int ApolloDuoIsWideBounds(double width, double height) {
    double max = width > height ? width : height;
    return max > (double)ApolloDuoWideWindowThreshold;
}

static inline int ApolloDuoIsLandscapeSized(double width, double height) {
    return width > height + 0.5;
}

// dualDisplay is cover+inner (area ratio), not UIDevice orientation.
// wide is MAX(window w,h) > 1000. Neither reads UIScreen.mainScreen.
static inline int ApolloDuoModeFromBounds(int dualDisplay,
                                          double width,
                                          double height) {
    int wide = ApolloDuoIsWideBounds(width, height);
    int landscape = ApolloDuoIsLandscapeSized(width, height);
    int duo = dualDisplay || wide;
    if (!duo) return ApolloDuoModePhone;
    if (wide && landscape) return ApolloDuoModeOpen;
    if (!landscape) return ApolloDuoModeClosed;
    return ApolloDuoModePhone;
}

static inline int ApolloDuoModeIsLeading(int mode) {
    return mode == ApolloDuoModeOpen;
}

// Expand when the window is letterboxed *or* still phone-narrow on a
// Duo-wide canvas. Origin / scene assignment is the caller's job.
static inline int ApolloDuoNeedsCanvasFill(double windowWidth,
                                           double windowHeight,
                                           double canvasWidth,
                                           double canvasHeight) {
    if (canvasWidth <= 0.0 || canvasHeight <= 0.0) return 0;
    if (ApolloDisplayIsLetterboxed(windowWidth, windowHeight,
                                   canvasWidth, canvasHeight)) {
        return 1;
    }
    return !ApolloDuoIsWideBounds(windowWidth, windowHeight)
        && ApolloDuoIsWideBounds(canvasWidth, canvasHeight);
}

#ifdef __cplusplus
}
#endif

#if defined(__OBJC__) && !defined(APOLLO_DUO_COMPATIBILITY_C_ONLY)
#import <UIKit/UIKit.h>

// Inspect the actual UIWindow bounds — not [UIScreen mainScreen].bounds.
static inline BOOL ApolloDuoIsWideWindow(UIWindow *window) {
    if (!window) return NO;
    CGSize size = window.bounds.size;
    return MAX(size.width, size.height) > 1000.0;
}

static inline int ApolloDuoModeFromWindow(UIWindow *window, int dualDisplay) {
    if (!window) return ApolloDuoModePhone;
    CGSize size = window.bounds.size;
    return ApolloDuoModeFromBounds(dualDisplay, size.width, size.height);
}

__BEGIN_DECLS
/// Re-apply scene/window canvas fill, then Duo rail sync, on the next
/// main-queue turn. Safe from layoutSubviews (async; fill is re-entrant).
void ApolloDuoCompatibilityFillSoon(void);
__END_DECLS
#endif

#endif
