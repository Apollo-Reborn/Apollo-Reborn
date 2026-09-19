#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

// Slim trailing rail on the *open inner* Duo canvas / very wide Regular.
// Duo's cover/front already owns a vertical system pill on the far right
// (back, feed, messages, profile, search, settings) — do not install a
// second Apollo rail there. Compact and ordinary Plus landscape keep
// Apollo's stock tab bar. C-only so host tests compile without UIKit.
//
// Open-inner rail hugs the trailing edge (tiny 4pt gutter only). A
// safe.right inset floated it in a white strip. Top is the live status
// pill's maxY plus a small gap — not a 120pt floor.

enum {
    ApolloDuoRailWidth = 64,
    ApolloDuoRailEdgeGutter = 4, /* hug the trailing edge */
    ApolloDuoRailStatusGap = 4,  /* just under the time/Wi-Fi pill */
    ApolloDuoRailMinRegularWidth = 652,
    ApolloDuoRailWideSingleScreen = 800,
    ApolloDuoCoverPillWidth = 56,  /* cover system pill; Compact only */
    ApolloDuoCoverPillBottom = 48, /* lift FABs above the cover gear */
};

typedef struct {
    double x;
    double y;
    double width;
    double height;
} ApolloDuoRailRect;

static inline double ApolloDuoRailMax(double a, double b) {
    return a > b ? a : b;
}

// Tiny hug only. Do not add window safe.right — that created the
// floating white gutter to the right of the rail.
static inline double ApolloDuoRailTrailingChrome(void) {
    return (double)ApolloDuoRailEdgeGutter;
}

static inline double ApolloDuoRailContentRightInset(void) {
    return (double)ApolloDuoRailWidth + (double)ApolloDuoRailEdgeGutter;
}

// y = pillMaxY + gap when the status cluster is known; otherwise
// safe.top + modest padding. No arbitrary 120pt floor.
static inline double ApolloDuoRailTopInset(double safeTop, double pillMaxY) {
    if (pillMaxY > 0.5) {
        return pillMaxY + (double)ApolloDuoRailStatusGap;
    }
    if (safeTop < 0.0) safeTop = 0.0;
    return safeTop + (double)ApolloDuoRailStatusGap;
}

// A–Z sits on the list, immediately leading the rail. Do not add
// window safe.right or it becomes a third column in a gutter.
static inline double ApolloDuoRailSectionIndexTrailing(void) {
    return ApolloDuoRailContentRightInset();
}

// Cover / Compact + dual screens: extra trailing/bottom so FABs clear
// Duo's system pill. Regular (open inner) never uses this — the Apollo
// rail is the chrome there. Ordinary single-screen Compact is 0.
static inline int ApolloDuoCoverChromeShouldApply(int regularSizeClass,
                                                 int dualDisplay) {
    return !regularSizeClass && dualDisplay;
}

static inline ApolloDuoRailRect ApolloDuoRailFrameInBounds(double boundsWidth,
                                                          double boundsHeight,
                                                          double safeTop,
                                                          double safeBottom,
                                                          double pillMaxY) {
    ApolloDuoRailRect rect;
    rect.x = 0.0;
    rect.y = 0.0;
    rect.width = 0.0;
    rect.height = 0.0;
    if (boundsWidth <= 0.0 || boundsHeight <= 0.0) {
        return rect;
    }
    if (safeBottom < 0.0) safeBottom = 0.0;
    double top = ApolloDuoRailTopInset(safeTop, pillMaxY);
    double trailing = ApolloDuoRailTrailingChrome();
    rect.width = (double)ApolloDuoRailWidth;
    rect.height = boundsHeight - top - safeBottom;
    if (rect.height < 0.0) rect.height = 0.0;
    rect.x = boundsWidth - rect.width - trailing;
    if (rect.x < 0.0) rect.x = 0.0;
    rect.y = top;
    return rect;
}

// Show the rail when Regular and wide enough, and either two screens look
// like inner+cover or the single canvas is clearly larger than Plus
// landscape (~736pt). Compact (cover/front, phone column) always returns 0
// so Duo's own cover pill is not doubled.
static inline int ApolloDuoRailShouldShow(int regularSizeClass,
                                          int dualDisplay,
                                          double usableWidth) {
    if (!regularSizeClass) return 0;
    if (usableWidth + 0.5 < (double)ApolloDuoRailMinRegularWidth) return 0;
    return dualDisplay || (usableWidth + 0.5 >= (double)ApolloDuoRailWideSingleScreen);
}

#ifdef __cplusplus
}
#endif

#endif
