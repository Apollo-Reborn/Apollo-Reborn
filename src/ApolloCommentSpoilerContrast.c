#include "ApolloCommentSpoilerContrast.h"

#include <math.h>

// This is Apollo's existing visible dark spoiler grey. Reusing it keeps the
// fix inside the app's native palette instead of introducing a new theme role.
static const uint32_t kApolloVisibleDarkSpoilerRGB = 0x505257;
static const uint8_t kApolloPureBlackMaximumChannel = 8;
// Keep this narrowly below Apollo's #282C34 dark code-block background
// (roughly 1.5:1 over black). The broken spoiler cover is the page background
// itself (roughly 1:1); only that collapsed contrast needs substitution.
static const double kApolloMinimumVisibleCoverContrast = 1.2;

static double ApolloLinearChannel(uint8_t component) {
    double value = (double)component / 255.0;
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static double ApolloRelativeLuminance(uint32_t rgb) {
    return 0.2126 * ApolloLinearChannel((uint8_t)(rgb >> 16))
        + 0.7152 * ApolloLinearChannel((uint8_t)(rgb >> 8))
        + 0.0722 * ApolloLinearChannel((uint8_t)rgb);
}

double ApolloCommentSpoilerContrastRatio(uint32_t firstRGB,
                                         uint32_t secondRGB) {
    double first = ApolloRelativeLuminance(firstRGB);
    double second = ApolloRelativeLuminance(secondRGB);
    double lighter = first > second ? first : second;
    double darker = first > second ? second : first;
    return (lighter + 0.05) / (darker + 0.05);
}

static bool ApolloIsPureBlackSurface(uint32_t rgb) {
    return ((rgb >> 16) & 0xff) <= kApolloPureBlackMaximumChannel
        && ((rgb >> 8) & 0xff) <= kApolloPureBlackMaximumChannel
        && (rgb & 0xff) <= kApolloPureBlackMaximumChannel;
}

bool ApolloCommentSpoilerFillNeedsContrast(uint32_t fillRGB,
                                           uint32_t surfaceRGB,
                                           bool darkAppearance,
                                           bool pureBlackEnabled) {
    if (!darkAppearance || !pureBlackEnabled || !ApolloIsPureBlackSurface(surfaceRGB)) {
        return false;
    }
    return ApolloCommentSpoilerContrastRatio(fillRGB, surfaceRGB)
        < kApolloMinimumVisibleCoverContrast;
}

uint32_t ApolloCommentSpoilerAdjustedFillRGB(uint32_t fillRGB,
                                             uint32_t surfaceRGB,
                                             bool darkAppearance,
                                             bool pureBlackEnabled) {
    return ApolloCommentSpoilerFillNeedsContrast(fillRGB, surfaceRGB,
                                                 darkAppearance, pureBlackEnabled)
        ? kApolloVisibleDarkSpoilerRGB : fillRGB;
}
