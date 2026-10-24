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

// The subreddit drawer settles with a critically damped spring (UIKit's
// no-bounce default) so it starts moving immediately instead of easing in.
static inline double ApolloDuoDrawerSpringOmega(void) {
    return 2.0 * 3.14159265358979323846 / 0.35;
}

// CASpringAnimation takes initial velocity in travel fractions per second.
// A release away from the target starts at rest; one faster than omega would
// carry a critically damped spring past the target, so it is capped there.
static inline double ApolloDuoDrawerSpringInitialVelocity(double from,
                                                          double to,
                                                          double velocity) {
    double travel = to - from;
    if (travel > -1.0 && travel < 1.0) return 0;
    double fraction = velocity / travel;
    if (fraction <= 0) return 0;
    double omega = ApolloDuoDrawerSpringOmega();
    return fraction < omega ? fraction : omega;
}

// Keeps a feed row's anchored point (a fraction of its height) at the same
// distance from the table's top edge after the column resizes and rows rewrap.
static inline double ApolloDuoAnchoredOffset(double rowMinY, double rowHeight, double fraction,
                                             double screenY, double minimum, double maximum) {
    double offset = rowMinY + rowHeight * fraction - screenY;
    if (offset > maximum) offset = maximum;
    if (offset < minimum) offset = minimum;
    return offset;
}

// A feed resting at its top (the offset at -adjustedContentInset.top) keeps
// its top instead of a row: anchoring would scroll the first post under the
// search bar, and UIKit collapses a bar the list has scrolled into.
static inline int ApolloDuoFeedRestsAtTop(double offset, double minimum) {
    return offset <= minimum + 1.0;
}

#ifdef __cplusplus
}
#endif

#endif
