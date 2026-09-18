#ifndef APOLLO_DUO_RAIL_LAYOUT_H
#define APOLLO_DUO_RAIL_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

// Slim leading rail on open Duo / very wide Regular. Compact and ordinary
// Plus landscape keep Apollo's stock tab bar. C-only so host tests compile
// without UIKit.

enum {
    ApolloDuoRailWidth = 64,
    ApolloDuoRailMinRegularWidth = 652, /* same two-column floor as FeedSplit */
    ApolloDuoRailWideSingleScreen = 800, /* inner canvas without a cover */
};

// Show the rail when Regular and wide enough, and either two screens look
// like inner+cover or the single canvas is clearly larger than Plus
// landscape (~736pt). Compact always returns 0.
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
