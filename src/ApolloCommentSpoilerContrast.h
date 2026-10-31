#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Apollo's native Markdown renderer paints a hidden spoiler with the current
// page-background colour. In Pure Black that makes the cover disappear into
// the comment surface. Keep the policy portable so the exact contrast rule is
// covered by a host-side regression test.
bool ApolloCommentSpoilerFillNeedsContrast(uint32_t fillRGB,
                                           uint32_t surfaceRGB,
                                           bool darkAppearance,
                                           bool pureBlackEnabled);

uint32_t ApolloCommentSpoilerAdjustedFillRGB(uint32_t fillRGB,
                                             uint32_t surfaceRGB,
                                             bool darkAppearance,
                                             bool pureBlackEnabled);

double ApolloCommentSpoilerContrastRatio(uint32_t firstRGB,
                                         uint32_t secondRGB);

#ifdef __cplusplus
}
#endif
