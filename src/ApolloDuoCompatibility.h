#ifndef APOLLO_DUO_COMPATIBILITY_H
#define APOLLO_DUO_COMPATIBILITY_H

#ifdef __cplusplus
extern "C" {
#endif

#include "ApolloDeviceDisplay.h"

// Classify a Duo canvas from its window and attached displays. The native
// UIKit tab bar owns its bottom/side placement; Open/Closed are compatibility
// classifications, not instructions to install a separate rail.

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

// Classify the actual app window, not the process-wide main screen.
static inline int ApolloDuoModeFromWindow(UIWindow *window, int dualDisplay) {
    if (!window) return ApolloDuoModePhone;
    CGSize size = window.bounds.size;
    return ApolloDuoModeFromBounds(dualDisplay, size.width, size.height);
}
#endif

#endif
