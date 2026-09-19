#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

// Slim *leading* rail on the open inner Duo canvas / very wide Regular.
// Duo's cover/front already owns a vertical system pill on the far right
// (back, feed, messages, profile, search, settings) — do not install a
// second Apollo rail there. Compact and ordinary Plus landscape keep
// Apollo's stock tab bar. C-only so host tests compile without UIKit.
//
// Open-inner rail hugs the leading edge (4pt gutter). Top is safe.top +
// 8 only — ignore the trailing time/Wi-Fi status pill. Content inset is
// leading 68 / trailing 0. A–Z stays stock (no extra trailing pin).

enum {
    ApolloDuoRailWidth = 64,
    ApolloDuoRailEdgeGutter = 4, /* hug the leading edge */
    ApolloDuoRailStatusGap = 8,  /* safe.top padding; ignore trailing pill */
    ApolloDuoRailMinRegularWidth = 652,
    ApolloDuoRailWideSingleScreen = 800,
    ApolloDuoRailLetterboxGap = 40, /* phone-width column vs usable fill */
    ApolloDuoCoverPillWidth = 80,   /* cover system pill; Compact only */
    ApolloDuoCoverPillBottom = 120, /* lift FABs above the cover gear */
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

static inline double ApolloDuoRailLeadingChrome(void) {
    return (double)ApolloDuoRailEdgeGutter;
}

static inline double ApolloDuoRailContentLeftInset(void) {
    return (double)ApolloDuoRailWidth + (double)ApolloDuoRailEdgeGutter;
}

static inline double ApolloDuoRailContentRightInset(void) {
    return 0.0;
}

// Usable width right of the leading rail. Stock nav letterboxes to a
// phone column on the wide inner canvas; fill targets this width.
static inline double ApolloDuoRailContentFillWidth(double containerWidth) {
    if (containerWidth <= 0.0) return 0.0;
    double fill = containerWidth - ApolloDuoRailContentLeftInset();
    return fill > 0.0 ? fill : 0.0;
}

static inline int ApolloDuoRailContentIsLetterboxed(double contentWidth,
                                                    double containerWidth) {
    return contentWidth + (double)ApolloDuoRailLetterboxGap
        < ApolloDuoRailContentFillWidth(containerWidth);
}

// Leading rail is away from Duo's trailing status pill. Only safe.top
// plus a modest pad — do not honor pillMaxY.
static inline double ApolloDuoRailTopInset(double safeTop, double pillMaxY) {
    (void)pillMaxY;
    if (safeTop < 0.0) safeTop = 0.0;
    return safeTop + (double)ApolloDuoRailStatusGap;
}

// Rail is leading; stock A–Z stays on the list trailing edge.
static inline double ApolloDuoRailSectionIndexTrailing(void) {
    return 0.0;
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
    rect.width = (double)ApolloDuoRailWidth;
    rect.height = boundsHeight - top - safeBottom;
    if (rect.height < 0.0) rect.height = 0.0;
    rect.x = ApolloDuoRailLeadingChrome();
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
