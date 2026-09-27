#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

#include "ApolloDuoCompatibility.h"

// Fallback dimensions for chrome before UIKit publishes its native frames.
// Column and tab-bar placement are owned by UIKit, not these helpers.
enum {
    ApolloDuoRailWidthClosed = 72,
    ApolloDuoCoverPillWidth = 80,
    ApolloDuoCoverPillBottom = 120,
    ApolloDuoSubsChromeCornerGutter = 20,
    ApolloDuoSubsChromeFABSize = 56,
    ApolloDuoSubsChromeFABMargin = 16,
};

typedef struct {
    double x;
    double y;
    double width;
    double height;
} ApolloDuoRailRect;

static inline int ApolloDuoCoverChromeShouldApply(int regularSizeClass,
                                                 int dualDisplay) {
    return !regularSizeClass && dualDisplay;
}

// Subs nav chrome (centered title, Edit, floating +) on Duo only.
// Regular iPhone stays stock Apollo. Does not show or hide the rail.
static inline int ApolloDuoSubsChromeShouldApply(int mode) {
    return mode == ApolloDuoModeOpen || mode == ApolloDuoModeClosed;
}

// Inline (not large) title so Liquid Glass / UIKit can center it.
// Closed Compact keeps Apollo's stock large title.
static inline int ApolloDuoSubsChromeShouldForceInlineTitle(int mode,
                                                            int regularWidth) {
    if (!ApolloDuoSubsChromeShouldApply(mode)) return 0;
    if (mode == ApolloDuoModeOpen) return 1;
    return regularWidth ? 1 : 0;
}

// The native split already supplies each column's safe area. Do not add
// the retired custom rail's 120pt reservation to wide landscape titles.
static inline double ApolloDuoSubsChromeTitleLeading(int mode, double chromeLeft) {
    (void)mode;
    return chromeLeft > 0.0 ? chromeLeft : 0.0;
}

// Title / Edit trailing inset. Honors hinge-sized chrome extras and
// a minimum corner gutter so the control clears rounded corners.
static inline double ApolloDuoSubsChromeTitleTrailing(double chromeRight) {
    if (chromeRight < (double)ApolloDuoSubsChromeCornerGutter) {
        return (double)ApolloDuoSubsChromeCornerGutter;
    }
    return chromeRight;
}

// Center and fit the title inside its visible navigation band.
static inline double ApolloDuoSubsChromeTitleCenterBetween(double leftEdge,
                                                           double rightEdge) {
    return (leftEdge + rightEdge) * 0.5;
}

static inline double ApolloDuoSubsChromeTitleMaxWidth(double leftEdge,
                                                      double rightEdge,
                                                      double padding) {
    if (padding < 0.0) padding = 0.0;
    double width = rightEdge - leftEdge - 2.0 * padding;
    return width > 0.0 ? width : 0.0;
}

// FAB origin in the RedditList container. Trailing/bottom are chrome
// + corner gutter (+ optional cover-pill lift). Size stays square.
static inline ApolloDuoRailRect ApolloDuoSubsChromeFABFrame(double containerWidth,
                                                            double containerHeight,
                                                            double chromeRight,
                                                            double chromeBottom,
                                                            double buttonWidth,
                                                            double buttonHeight) {
    ApolloDuoRailRect rect;
    rect.x = 0.0;
    rect.y = 0.0;
    rect.width = 0.0;
    rect.height = 0.0;
    if (containerWidth <= 0.0 || containerHeight <= 0.0) return rect;
    if (buttonWidth < 1.0) buttonWidth = (double)ApolloDuoSubsChromeFABSize;
    if (buttonHeight < 1.0) buttonHeight = (double)ApolloDuoSubsChromeFABSize;
    double trail = chromeRight;
    if (trail < (double)ApolloDuoSubsChromeCornerGutter) {
        trail = (double)ApolloDuoSubsChromeCornerGutter;
    }
    trail += (double)ApolloDuoSubsChromeFABMargin;
    double bottom = chromeBottom;
    if (bottom < (double)ApolloDuoSubsChromeCornerGutter) {
        bottom = (double)ApolloDuoSubsChromeCornerGutter;
    }
    bottom += (double)ApolloDuoSubsChromeFABMargin;
    rect.width = buttonWidth;
    rect.height = buttonHeight;
    rect.x = containerWidth - trail - buttonWidth;
    rect.y = containerHeight - bottom - buttonHeight;
    if (rect.x < 0.0) rect.x = 0.0;
    if (rect.y < 0.0) rect.y = 0.0;
    return rect;
}

// Skip subpixel differences so repeated layout passes stay idempotent.
static inline int ApolloDuoSubsChromeShouldNudgeFrame(double haveX,
                                                      double haveY,
                                                      double wantX,
                                                      double wantY) {
    double dx = haveX - wantX;
    double dy = haveY - wantY;
    if (dx < 0.0) dx = -dx;
    if (dy < 0.0) dy = -dy;
    return dx > 0.5 || dy > 0.5;
}

#ifdef __cplusplus
}
#endif

#endif
