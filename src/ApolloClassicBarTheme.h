#ifndef APOLLO_CLASSIC_BAR_THEME_H
#define APOLLO_CLASSIC_BAR_THEME_H

#include <stdbool.h>
#include <stdint.h>

// Foundation/UIKit-free policy for classic custom-theme bar fills. Keeping the
// decision primitive lets the runtime pass decoded UIColor state in while host
// tests exercise every fail-closed gate without mocking UIKit.
static inline bool ApolloClassicBarShouldRouteRaisedToBars(
    bool runtimeActive,
    bool liquidGlass,
    bool colorComponentsAvailable,
    double alpha,
    uint32_t rgb,
    uint32_t raisedLightRGB,
    uint32_t raisedDarkRGB
) {
    if (!runtimeActive || liquidGlass || !colorComponentsAvailable || alpha < 0.99) return false;
    return rgb == raisedLightRGB || rgb == raisedDarkRGB;
}

#endif
