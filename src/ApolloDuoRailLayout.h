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
// 8 only — ignore the trailing time/Wi-Fi status pill. Content starts
// at rail width + 16pt so vote chevrons / thumbnails clear the rail
// hairline (64+16=80). A–Z stays stock. Compact and any portrait /
// vertical canvas hide the rail.

enum {
    ApolloDuoRailWidth = 64,
    ApolloDuoRailEdgeGutter = 4,   /* rail hug from the leading edge */
    ApolloDuoRailContentGutter = 16, /* content gap after the rail + hairline */
    ApolloDuoRailStatusGap = 8,  /* safe.top padding; ignore trailing pill */
    ApolloDuoRailMinRegularWidth = 652,
    ApolloDuoRailWideSingleScreen = 800,
    ApolloDuoRailLetterboxGap = 40, /* phone-width column vs usable fill */
    /* Kept for host tests only — do NOT apply at runtime. The wide-row
       title+star cluster ran only on landscape cells ≥480 and dragged
       FAVORITES titles mid-pane. Portrait (stock RedditList) is the look. */
    ApolloDuoRailRowMaxContentWidth = 480,
    ApolloDuoRailRowStarGap = 28,
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
    return (double)ApolloDuoRailWidth + (double)ApolloDuoRailContentGutter;
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

// Table/content frame that starts after the leading rail. Headers in a
// full-bleed table ignore additionalSafeAreaInsets and draw under Subs.
static inline ApolloDuoRailRect ApolloDuoRailContentFrameInBounds(double boundsWidth,
                                                                 double boundsHeight) {
    ApolloDuoRailRect rect;
    rect.x = ApolloDuoRailContentLeftInset();
    rect.y = 0.0;
    rect.width = ApolloDuoRailContentFillWidth(boundsWidth);
    rect.height = boundsHeight > 0.0 ? boundsHeight : 0.0;
    if (rect.width < 0.0) rect.width = 0.0;
    return rect;
}

static inline int ApolloDuoRailContentNeedsLeadingClearance(double contentX,
                                                           double contentWidth,
                                                           double containerWidth) {
    if (containerWidth <= 0.0) return 0;
    if (contentX + 0.5 < ApolloDuoRailContentLeftInset()) return 1;
    return ApolloDuoRailContentIsLetterboxed(contentWidth, containerWidth);
}

// Extra x to add to a *title* that is still under the rail. 0 when the
// title's window minX is already at/after the content inset. Positive
// only — 92ea260 used this as the whole policy and left Image 1
// (mid-pane have≈400) untouched. Runtime lead-align uses
// ApolloDuoRailRowLeadDelta (signed) instead.
static inline double ApolloDuoRailRowTitleBump(double titleWindowX) {
    if (titleWindowX + 0.5 >= ApolloDuoRailContentLeftInset()) return 0.0;
    return ApolloDuoRailContentLeftInset() - titleWindowX;
}

// Unused at runtime (wide-row cluster is off). Kept so host tests still
// lock the old 480pt math. Do not apply this as a leading or trailing
// margin — that is the mid-pane FAVORITES indent on landscape Duo.
static inline double ApolloDuoRailRowTrailingExtra(double cellWidth) {
    if (cellWidth <= (double)ApolloDuoRailRowMaxContentWidth) return 0.0;
    return cellWidth - (double)ApolloDuoRailRowMaxContentWidth;
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

// Modern RedditList headers are painted at a hardcoded stockTitleX
// (18pt). When the header still sits under the leading rail in window
// space, shift the title by the overlap so "FAVORITES" is not clipped
// to "ES". A header that already starts at x >= ContentLeftInset is left alone.
static inline double ApolloDuoRailHeaderTitleMinX(double headerWindowX,
                                                  double stockTitleX) {
    if (stockTitleX < 0.0) stockTitleX = 0.0;
    double overlap = ApolloDuoRailContentLeftInset() - headerWindowX;
    if (overlap < 0.0) overlap = 0.0;
    return stockTitleX + overlap;
}

// Target title minX *inside a full-bleed RedditList cell* — same number
// StyleHeaderView uses for FAVORITES / MODERATOR / A. stockTitleX is
// Apollo's 18pt leading. A cell that already starts past the rail
// (window x >= 80) keeps stock 18 so we do not stack another inset.
static inline double ApolloDuoRailRowTitleMinX(double cellWindowX,
                                               double stockTitleX) {
    return ApolloDuoRailHeaderTitleMinX(cellWindowX, stockTitleX);
}

// Visual text minX inside a label. Center/right alignment on a stretchy
// wide label is how "Apple" can sit mid-pane while label.minX is still 18.
enum {
    ApolloDuoRailTextAlignLeft = 0,
    ApolloDuoRailTextAlignCenter = 1,
    ApolloDuoRailTextAlignRight = 2,
};

static inline double ApolloDuoRailLabelTextMinX(double labelMinX,
                                                double labelWidth,
                                                double textWidth,
                                                int align) {
    if (textWidth < 0.0) textWidth = 0.0;
    if (labelWidth < textWidth) labelWidth = textWidth;
    if (align == ApolloDuoRailTextAlignCenter) {
        return labelMinX + (labelWidth - textWidth) * 0.5;
    }
    if (align == ApolloDuoRailTextAlignRight) {
        return labelMinX + (labelWidth - textWidth);
    }
    return labelMinX;
}

// Signed delta that puts visual text at wantX. Positive = still under the
// rail (push right, capped at ContentLeftInset so we cannot stack a
// second 80pt). Negative = mid-pane / readable-centered (pull left).
// 92ea260 only applied the positive arm, so Image 1 (have≈400, want=98)
// was left untouched.
static inline double ApolloDuoRailRowLeadDelta(double haveTextMinX,
                                               double wantX) {
    double delta = wantX - haveTextMinX;
    double maxRight = ApolloDuoRailContentLeftInset();
    if (delta > maxRight) delta = maxRight;
    return delta;
}

// Star sits after the drawn text, not at RowMaxContentWidth (452) and
// not on the first letter (titleMinX).
static inline double ApolloDuoRailRowStarMinX(double titleMinX,
                                              double textWidth,
                                              double gap) {
    if (textWidth < 0.0) textWidth = 0.0;
    if (gap < 0.0) gap = 0.0;
    return titleMinX + textWidth + gap;
}

// Extra leading a centered readable column adds on a wide cell. Portrait
// phone width (≤ readableMax) is 0 — titles stay stock. Landscape Duo
// (~900pt) is tens to hundreds of points, which is the mid-pane gap.
static inline double ApolloDuoRailReadableLeading(double cellWidth,
                                                  double readableMax) {
    if (readableMax <= 0.0 || cellWidth <= readableMax) return 0.0;
    return (cellWidth - readableMax) * 0.5;
}

// Show the rail when Regular *and landscape*, wide enough, and either
// two screens look like inner+cover or the single canvas is clearly
// larger than Plus landscape (~736pt). Compact (cover/front, phone
// column) and any portrait / vertical canvas always return 0 so the
// stock tab bar comes back and no 68pt leading strip is left behind.
static inline int ApolloDuoRailShouldShow(int regularSizeClass,
                                          int dualDisplay,
                                          double usableWidth,
                                          double usableHeight) {
    if (!regularSizeClass) return 0;
    if (usableHeight > usableWidth + 0.5) return 0;
    if (usableWidth + 0.5 < (double)ApolloDuoRailMinRegularWidth) return 0;
    return dualDisplay || (usableWidth + 0.5 >= (double)ApolloDuoRailWideSingleScreen);
}

#ifdef __cplusplus
}
#endif

#endif
