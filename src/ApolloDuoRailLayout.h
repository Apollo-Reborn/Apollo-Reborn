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
// Open-inner rail hugs the trailing edge (tiny 4pt gutter only). Top is
// at least MinTopClearance (104) so Subs cannot climb into the time/Wi-Fi
// band when the status-bar probe is short or missing. Live pill maxY +
// gap wins when it is taller than that floor.

enum {
    ApolloDuoRailWidth = 64,
    ApolloDuoRailEdgeGutter = 4, /* hug the trailing edge */
    ApolloDuoRailStatusGap = 4,  /* just under the time/Wi-Fi pill */
    ApolloDuoRailMinTopClearance = 104, /* always fully under the status band */
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

// Tiny hug only. Do not add window safe.right — that created the
// floating white gutter to the right of the rail.
static inline double ApolloDuoRailTrailingChrome(void) {
    return (double)ApolloDuoRailEdgeGutter;
}

static inline double ApolloDuoRailContentRightInset(void) {
    return (double)ApolloDuoRailWidth + (double)ApolloDuoRailEdgeGutter;
}

// Usable width left of the rail. Stock nav letterboxes to a phone
// column on the wide inner canvas; fill targets this width.
static inline double ApolloDuoRailContentFillWidth(double containerWidth) {
    if (containerWidth <= 0.0) return 0.0;
    double fill = containerWidth - ApolloDuoRailContentRightInset();
    return fill > 0.0 ? fill : 0.0;
}

static inline int ApolloDuoRailContentIsLetterboxed(double contentWidth,
                                                    double containerWidth) {
    return contentWidth + (double)ApolloDuoRailLetterboxGap
        < ApolloDuoRailContentFillWidth(containerWidth);
}

// y is the larger of MinTopClearance, safe.top+gap, and pillMaxY+gap.
// The 104pt floor keeps the rail fully under the status band when the
// live probe is 0 or only the short pill height.
static inline double ApolloDuoRailTopInset(double safeTop, double pillMaxY) {
    if (safeTop < 0.0) safeTop = 0.0;
    double top = (double)ApolloDuoRailMinTopClearance;
    double fromSafe = safeTop + (double)ApolloDuoRailStatusGap;
    if (fromSafe > top) top = fromSafe;
    if (pillMaxY > 0.5) {
        double fromPill = pillMaxY + (double)ApolloDuoRailStatusGap;
        if (fromPill > top) top = fromPill;
    }
    return top;
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
