#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

#include "ApolloDeviceChromeInsets.h"

#ifdef __cplusplus
extern "C" {
#endif

// Slim trailing rail on the *open inner* Duo canvas / very wide Regular.
// Duo's cover/front already owns a vertical system pill on the far right
// (back, feed, messages, profile, search, settings) — do not install a
// second Apollo rail there. That pill is the design cue for the *open*
// layout edge only: our Subs/Home/Popular/All/Profile/Settings rail sits
// on the same trailing side of the inner display. Compact and ordinary
// Plus landscape keep Apollo's stock tab bar. C-only so host tests
// compile without UIKit.
//
// The rail frame is inset by the *window/scene* safe area (plus any
// hinge-sized layout-margin extra). Flush-to-bounds painting sits under
// Duo's top-right time/Wi-Fi pill and clips the selected Subs button.

enum {
    ApolloDuoRailWidth = 64,
    ApolloDuoRailEdgeGutter = 8, /* min gap from display edge / chrome */
    ApolloDuoRailMinRegularWidth = 652, /* same two-column floor as FeedSplit */
    ApolloDuoRailWideSingleScreen = 800, /* inner canvas without a cover */
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

// How far the rail's trailing edge sits in from bounds.maxX.
// max(safe.right + hinge extra, gutter) so a 0-inset first layout
// still leaves a sliver, and the status pill's right inset wins.
static inline double ApolloDuoRailTrailingChrome(double safeRight, double marginRight) {
    if (safeRight < 0.0) safeRight = 0.0;
    double extra = ApolloDeviceChromeExtra(safeRight, marginRight);
    return ApolloDuoRailMax(safeRight + extra, (double)ApolloDuoRailEdgeGutter);
}

// additionalSafeAreaInsets.right for tab children. System safe.right is
// already applied by UIKit — only add the rail strip + a small gap.
static inline double ApolloDuoRailContentRightInset(void) {
    return (double)ApolloDuoRailWidth + (double)ApolloDuoRailEdgeGutter;
}

static inline ApolloDuoRailRect ApolloDuoRailFrameInBounds(double boundsWidth,
                                                          double boundsHeight,
                                                          double safeTop,
                                                          double safeRight,
                                                          double safeBottom,
                                                          double marginRight) {
    ApolloDuoRailRect rect;
    rect.x = 0.0;
    rect.y = 0.0;
    rect.width = 0.0;
    rect.height = 0.0;
    if (boundsWidth <= 0.0 || boundsHeight <= 0.0) {
        return rect;
    }
    if (safeTop < 0.0) safeTop = 0.0;
    if (safeBottom < 0.0) safeBottom = 0.0;
    double trailing = ApolloDuoRailTrailingChrome(safeRight, marginRight);
    rect.width = (double)ApolloDuoRailWidth;
    rect.height = boundsHeight - safeTop - safeBottom;
    if (rect.height < 0.0) rect.height = 0.0;
    rect.x = boundsWidth - rect.width - trailing;
    if (rect.x < 0.0) rect.x = 0.0;
    rect.y = safeTop;
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
