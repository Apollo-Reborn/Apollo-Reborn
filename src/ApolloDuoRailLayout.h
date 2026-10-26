#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

#include <string.h>

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

// Apollo stores CommentJumpButtonPosition as a string raw value ("top-left"
// ... "bottom-right", or "center"); unset means bottom right.
enum {
    ApolloDuoJumpButtonRight = 0,
    ApolloDuoJumpButtonCenter = 1,
    ApolloDuoJumpButtonLeft = 2,
};

// Gap between the jump button and a split pane's edges, and between the
// button and the trailing rail (the gap Duo settings rows and profile cards
// use).
enum {
    ApolloDuoJumpButtonPaneMargin = 16,
    ApolloDuoJumpButtonRailGap = 15,
};

static inline int ApolloDuoJumpButtonPositionKind(const char *position) {
    if (!position) return ApolloDuoJumpButtonRight;
    if (strcmp(position, "center") == 0) return ApolloDuoJumpButtonCenter;
    size_t length = strlen(position);
    if (length >= 5 && strcmp(position + length - 5, "-left") == 0) return ApolloDuoJumpButtonLeft;
    return ApolloDuoJumpButtonRight;
}

// Rightmost edge a jump button may reach in a split pane: the pane's
// trailing margin, pulled in to clear a visible trailing rail.
static inline double ApolloDuoJumpButtonPaneTrailingLimit(double paneMinX, double paneWidth,
                                                          int rail, double railMinX) {
    double limit = paneMinX + paneWidth - (double)ApolloDuoJumpButtonPaneMargin;
    if (rail && railMinX - (double)ApolloDuoJumpButtonRailGap < limit) {
        limit = railMinX - (double)ApolloDuoJumpButtonRailGap;
    }
    return limit;
}

// Where a split pane's usable part begins in book posture: a fold whose
// division region covers the pane's leading edge (the divider resting at or
// inside the fold) moves it past the fold, so no position lands on the hinge.
// A fold elsewhere, or none, leaves the pane alone.
static inline double ApolloDuoJumpButtonPaneAfterFold(double paneMinX, double paneWidth,
                                                      int fold, double foldMinX, double foldMaxX) {
    if (!fold || foldMaxX <= paneMinX || foldMinX > paneMinX + 1.0) return paneMinX;
    double end = paneMinX + paneWidth;
    return foldMaxX < end ? foldMaxX : paneMinX;
}

// Apollo places the jump button against geometry that a split pane does not
// match: the full-screen comments table for left and center, which extends
// beneath the posts column, and a narrower width for right. In a split pane,
// place every position from the pane itself: left at the pane's leading
// margin, center on the pane's column, right at its trailing limit. The x is
// computed rather than offset, so repeated layout passes are stable.
// Unsplit layouts keep Apollo's x.
static inline double ApolloDuoJumpButtonPaneX(int kind, int split,
                                              double paneMinX, double paneWidth,
                                              int rail, double railMinX,
                                              double buttonWidth, double currentX) {
    if (!split || paneWidth <= 0.0 || buttonWidth <= 0.0) return currentX;
    double limit = ApolloDuoJumpButtonPaneTrailingLimit(paneMinX, paneWidth, rail, railMinX);
    double x;
    if (kind == ApolloDuoJumpButtonCenter) {
        x = paneMinX + (paneWidth - buttonWidth) / 2.0;
    } else if (kind == ApolloDuoJumpButtonLeft) {
        x = paneMinX + (double)ApolloDuoJumpButtonPaneMargin;
    } else {
        x = limit - buttonWidth;
    }
    if (x + buttonWidth > limit) x = limit - buttonWidth;
    return x < paneMinX ? paneMinX : x;
}

#ifdef __cplusplus
}
#endif

#endif
