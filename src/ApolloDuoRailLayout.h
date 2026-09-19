#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

#include "ApolloDuoCompatibility.h"

// One Duo chrome path. Open Duo (wide landscape UIWindow) is a
// reserved leading 112pt sidebar (content starts at 120); the bottom
// tab bar is hidden. Closed Duo (portrait-sized Duo window) is
// Phone-like chrome: stock bottom UITabBar, no Apollo side rail, no
// reserved or overlayed trailing column. Regular iPhone is Phone —
// stock tab bar, no rail. C-only so host tests compile without UIKit.
//
// Top is safe.top + 8 only. Open content inset is rail + 8pt
// (112+8=120) on the leading side.

enum {
    ApolloDuoRailWidth = 112,      /* Open reserved sidebar, 100–120pt */
    ApolloDuoRailWidthClosed = 72, /* Closed overlay only — not a reserved column */
    ApolloDuoRailClosedIndexWidth = 16, /* typical UITableViewIndex; sits beside the rail */
    ApolloDuoRailEdgeGutter = 0,   /* flush leading sidebar */
    ApolloDuoRailContentGutter = 8, /* content gap after the Open rail hairline */
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
    /* Subs nav chrome (title / Edit / floating +). Insets only the
       controls — never the list — so Open stays full-width past the
       rail and Closed stays uncrushed. Corner gutter keeps glyphs off
       Duo's inner rounded corners without guessing a hinge rect. */
    ApolloDuoSubsChromeCornerGutter = 20,
    ApolloDuoSubsChromeFABSize = 56,
    ApolloDuoSubsChromeFABMargin = 16,
    /* UITableView's default leading. RedditList headers paint at 18;
       shortcut ApolloSubtitleTableViewCell icons sit at safe-area + 16
       after the 80pt rail inset (window ≈96). Favorite titles key off
       this, not the header 18→98 column. */
    ApolloDuoRailRowStockLead = 16,
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

static inline double ApolloDuoRailChromeLeftForMode(int mode) {
    return mode == ApolloDuoModeOpen ? ApolloDuoRailContentLeftInset() : 0.0;
}

// Closed overlays the rail — never reserve ~120pt trailing. That
// reservation crushed the portrait list by ~20–25% (Image 1).
static inline double ApolloDuoRailChromeRightForMode(int mode) {
    (void)mode;
    return 0.0;
}

static inline double ApolloDuoRailWidthForMode(int mode) {
    return mode == ApolloDuoModeClosed ? (double)ApolloDuoRailWidthClosed
                                       : (double)ApolloDuoRailWidth;
}

static inline double ApolloDuoRailWidthOnSide(int leading) {
    return leading ? (double)ApolloDuoRailWidth : (double)ApolloDuoRailWidthClosed;
}

// Usable width after reserved chrome only. Open subtracts the leading
// 120pt column. Closed is full-bleed (overlay rail).
static inline double ApolloDuoRailContentFillWidthForMode(double containerWidth,
                                                         int mode) {
    if (containerWidth <= 0.0) return 0.0;
    double fill = containerWidth
        - ApolloDuoRailChromeLeftForMode(mode)
        - ApolloDuoRailChromeRightForMode(mode);
    return fill > 0.0 ? fill : 0.0;
}

// Usable width right of the leading rail. Stock nav letterboxes to a
// phone column on the wide inner canvas; fill targets this width.
static inline double ApolloDuoRailContentFillWidth(double containerWidth) {
    return ApolloDuoRailContentFillWidthForMode(containerWidth, ApolloDuoModeOpen);
}

// Portrait Closed list is crushed when a reserved column eats ~20%+.
// Overlay + full-bleed content must fail this (acceptance test).
static inline int ApolloDuoRailClosedContentIsCrushed(double contentWidth,
                                                     double containerWidth) {
    if (containerWidth <= 0.0) return 0;
    return contentWidth + containerWidth * 0.20 < containerWidth;
}

static inline int ApolloDuoRailContentIsLetterboxed(double contentWidth,
                                                    double containerWidth) {
    return contentWidth + (double)ApolloDuoRailLetterboxGap
        < ApolloDuoRailContentFillWidth(containerWidth);
}

// Table/content frame that starts after the leading rail. Headers in a
// full-bleed table ignore additionalSafeAreaInsets and draw under Subs.
static inline ApolloDuoRailRect ApolloDuoRailContentFrameInBoundsForMode(double boundsWidth,
                                                                        double boundsHeight,
                                                                        int mode) {
    ApolloDuoRailRect rect;
    rect.x = ApolloDuoRailChromeLeftForMode(mode);
    rect.y = 0.0;
    rect.width = ApolloDuoRailContentFillWidthForMode(boundsWidth, mode);
    rect.height = boundsHeight > 0.0 ? boundsHeight : 0.0;
    if (rect.width < 0.0) rect.width = 0.0;
    return rect;
}

static inline ApolloDuoRailRect ApolloDuoRailContentFrameInBounds(double boundsWidth,
                                                                 double boundsHeight) {
    return ApolloDuoRailContentFrameInBoundsForMode(boundsWidth, boundsHeight,
                                                    ApolloDuoModeOpen);
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

// Open: stock A–Z on the list trailing edge (0 extra). Closed: pin
// the index immediately left of the overlay rail.
static inline double ApolloDuoRailSectionIndexTrailingForMode(int mode) {
    return mode == ApolloDuoModeClosed ? (double)ApolloDuoRailWidthClosed : 0.0;
}

static inline double ApolloDuoRailSectionIndexTrailing(void) {
    return ApolloDuoRailSectionIndexTrailingForMode(ApolloDuoModeOpen);
}

// Visible trailing chrome on a full-bleed Closed row: overlay rail +
// the A–Z that sits beside it. Stars / header lines stop here.
static inline double ApolloDuoRailClosedOverlayClearance(void) {
    return (double)ApolloDuoRailWidthClosed + (double)ApolloDuoRailClosedIndexWidth;
}

static inline double ApolloDuoRailClosedStarMaxX(double cellWidth) {
    if (cellWidth <= 0.0) return 0.0;
    double maxX = cellWidth - ApolloDuoRailClosedOverlayClearance();
    return maxX > 0.0 ? maxX : 0.0;
}

static inline double ApolloDuoRailClosedStarMinX(double cellWidth, double starWidth) {
    if (starWidth < 0.0) starWidth = 0.0;
    double minX = ApolloDuoRailClosedStarMaxX(cellWidth) - starWidth;
    return minX > 0.0 ? minX : 0.0;
}

static inline int ApolloDuoRailClosedShouldNudgeStar(double starMaxX, double wantMaxX) {
    double gap = wantMaxX - starMaxX;
    if (gap < 0.0) gap = -gap;
    return gap > 0.5;
}

// Cover / Compact + dual screens: extra trailing/bottom so FABs clear
// Duo's system pill. Regular (open inner) never uses this — the Apollo
// rail is the chrome there. Ordinary single-screen Compact is 0.
static inline int ApolloDuoCoverChromeShouldApply(int regularSizeClass,
                                                 int dualDisplay) {
    return !regularSizeClass && dualDisplay;
}

static inline ApolloDuoRailRect ApolloDuoRailFrameInBoundsOnSide(double boundsWidth,
                                                                double boundsHeight,
                                                                double safeTop,
                                                                double safeBottom,
                                                                double pillMaxY,
                                                                int leading) {
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
    rect.width = ApolloDuoRailWidthOnSide(leading);
    rect.height = boundsHeight - top - safeBottom;
    if (rect.height < 0.0) rect.height = 0.0;
    rect.x = leading ? ApolloDuoRailLeadingChrome()
                     : boundsWidth - rect.width;
    if (rect.x < 0.0) rect.x = 0.0;
    rect.y = top;
    return rect;
}

static inline ApolloDuoRailRect ApolloDuoRailFrameInBounds(double boundsWidth,
                                                          double boundsHeight,
                                                          double safeTop,
                                                          double safeBottom,
                                                          double pillMaxY) {
    return ApolloDuoRailFrameInBoundsOnSide(boundsWidth, boundsHeight,
                                            safeTop, safeBottom, pillMaxY, 1);
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
// Runtime favorite-row align uses ApolloDuoRailShortcutLeadMinX (16)
// instead — 2eba156 keyed titles to this 18→98 header column, then
// stacked a stale remainder on top and parked them at ~178.
static inline double ApolloDuoRailRowTitleMinX(double cellWindowX,
                                               double stockTitleX) {
    return ApolloDuoRailHeaderTitleMinX(cellWindowX, stockTitleX);
}

// Fallback wantX for a favorite / A–Z title: shortcut-row leading
// (safe-area + UITableView's 16pt), not the header's 18pt. Full-bleed
// cell → 96. A cell already past the rail keeps stock 16.
static inline double ApolloDuoRailShortcutLeadMinX(double cellWindowX) {
    return ApolloDuoRailHeaderTitleMinX(cellWindowX,
                                        (double)ApolloDuoRailRowStockLead);
}

// Favorite rows have no icon. Portrait organization lines their
// titles up with Home / Popular *text*, not the shortcut icon.
// 4a76cd3 preferred the icon (96) and then Auto Layout snapped the
// stack back, so the painted column stayed at ~178. Runtime wantX
// is a live textLabel; fallback is last.
static inline double ApolloDuoRailFavoriteTitleWantX(double iconMinX,
                                                     double textMinX,
                                                     double fallback) {
    if (textMinX > 0.5) return textMinX;
    if (iconMinX > 0.5) return iconMinX;
    return fallback;
}

// Horizontal constraint disable is one-shot. Re-toggling every
// layoutSubviews is the 25f8a7b hang. 0 when already claimed.
static inline int ApolloDuoRailRowShouldClaimLeading(int alreadyClaimed) {
    return alreadyClaimed ? 0 : 1;
}

// After a real stack origin change, convertRect can still report the
// pre-move title minX. 2eba156 applied that stale LeadDelta again
// (stack +80, then title.frame +80) and parked names at ~178 while
// headers stayed at 98. Remainder is only for a no-op stack write
// (full-bleed stack at x=0 with a mid-stack title).
static inline int ApolloDuoRailRowShouldApplyTitleRemainder(int stackMoved,
                                                            double remain) {
    if (stackMoved) return 0;
    if (remain < 0.0) remain = -remain;
    return remain > 0.5;
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
// Runtime must NOT keep that extra: landscape uses the same stock
// leading as portrait, plus rail safe-area only.
static inline double ApolloDuoRailReadableLeading(double cellWidth,
                                                  double readableMax) {
    if (readableMax <= 0.0 || cellWidth <= readableMax) return 0.0;
    return (cellWidth - readableMax) * 0.5;
}

// Portrait organization: content leading is safe-area + stock 16.
// Full-bleed cell under the rail → 80+16=96. A contentView already
// inset by the table's safe-area has safeLeft=0 → 16. Never add the
// readable-column half-gap on top of that.
static inline double ApolloDuoRailRowStockMarginLeft(double safeLeft) {
    if (safeLeft < 0.0) safeLeft = 0.0;
    return safeLeft + (double)ApolloDuoRailRowStockLead;
}

// Same leading line as Home / Popular (a few points). A second
// indented column (Image 1 ~178, or 18+readable 124) fails this.
static inline int ApolloDuoRailRowIsPortraitOrganized(double titleMinX,
                                                      double shortcutLead) {
    double gap = titleMinX - shortcutLead;
    if (gap < 0.0) gap = -gap;
    return gap <= 4.0;
}

static inline double ApolloDuoRailRowWastedLeading(double titleMinX,
                                                   double shortcutLead) {
    double gap = titleMinX - shortcutLead;
    return gap > 0.0 ? gap : 0.0;
}

// Frame-only stack nudge. 0 when already on the shortcut lead so
// layoutSubviews is a no-op. Constraint / margin writes are not a
// tool here — they re-entered layout on 25f8a7b and hung the sim.
static inline int ApolloDuoRailRowShouldNudgeStack(double titleMinX,
                                                   double shortcutLead) {
    return !ApolloDuoRailRowIsPortraitOrganized(titleMinX, shortcutLead);
}

// Rail only for Open (wide landscape). Closed portrait Duo and
// regular iPhone keep the stock bottom UITabBar — Aaron does not
// want Posts/Subs/Home/… moved to a side rail in portrait.
static inline int ApolloDuoRailShouldShow(int regularSizeClass,
                                          int dualDisplay,
                                          double usableWidth,
                                          double usableHeight) {
    (void)regularSizeClass;
    return ApolloDuoModeFromBounds(dualDisplay, usableWidth, usableHeight)
        == ApolloDuoModeOpen;
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

// Title leading edge in bar space. Open: at least the rail content
// inset so "Subreddits" cannot sit under Posts/Subs. Closed: chrome
// only (no rail).
static inline double ApolloDuoSubsChromeTitleLeading(int mode,
                                                     double chromeLeft) {
    if (chromeLeft < 0.0) chromeLeft = 0.0;
    if (mode == ApolloDuoModeOpen
        && chromeLeft < ApolloDuoRailContentLeftInset()) {
        return ApolloDuoRailContentLeftInset();
    }
    return chromeLeft;
}

// Title / Edit trailing inset. Honors hinge-sized chrome extras and
// a minimum corner gutter so the control clears rounded corners.
static inline double ApolloDuoSubsChromeTitleTrailing(double chromeRight) {
    if (chromeRight < (double)ApolloDuoSubsChromeCornerGutter) {
        return (double)ApolloDuoSubsChromeCornerGutter;
    }
    return chromeRight;
}

// Midpoint of the usable title band. Open looks centered over the
// list (right of the rail), not the full window (which includes the
// sidebar). Phone callers should not use this to move stock titles.
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

// Frame write guard. 0 when already on the target so viewDidLayout
// is a no-op (same hang class as 25f8a7b constraint re-toggles).
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
