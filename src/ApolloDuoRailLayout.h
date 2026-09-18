#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

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

enum {
    ApolloDuoRailWidth = 64,
    ApolloDuoRailMinRegularWidth = 652, /* same two-column floor as FeedSplit */
    ApolloDuoRailWideSingleScreen = 800, /* inner canvas without a cover */
};

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
