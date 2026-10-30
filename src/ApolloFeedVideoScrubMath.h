#ifndef APOLLO_FEED_VIDEO_SCRUB_MATH_H
#define APOLLO_FEED_VIDEO_SCRUB_MATH_H

#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

// C-only scrub-position helpers so the gesture math can be host-tested
// without UIKit or AVFoundation.

static inline double ApolloFeedVideoScrubClampFraction(double fraction) {
    if (!isfinite(fraction)) return 0.0;
    if (fraction < 0.0) return 0.0;
    if (fraction > 1.0) return 1.0;
    return fraction;
}

static inline double ApolloFeedVideoScrubStartingFraction(double playhead,
                                                          double duration) {
    if (!isfinite(playhead) || playhead < 0.0 || !isfinite(duration) || duration <= 0.0) {
        return 0.0;
    }
    return ApolloFeedVideoScrubClampFraction(playhead / duration);
}

static inline double ApolloFeedVideoScrubTargetFraction(double startingFraction,
                                                        double touchStartX,
                                                        double currentX,
                                                        double trackWidth) {
    double start = ApolloFeedVideoScrubClampFraction(startingFraction);
    if (!isfinite(touchStartX) || !isfinite(currentX)
        || !isfinite(trackWidth) || trackWidth <= 0.0) {
        return start;
    }
    return ApolloFeedVideoScrubClampFraction(start + (currentX - touchStartX) / trackWidth);
}

#ifdef __cplusplus
}
#endif

#endif
