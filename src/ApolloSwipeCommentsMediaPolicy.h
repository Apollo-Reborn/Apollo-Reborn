#ifndef APOLLO_SWIPE_COMMENTS_MEDIA_POLICY_H
#define APOLLO_SWIPE_COMMENTS_MEDIA_POLICY_H

#include <math.h>
#include <stdbool.h>

// Pure policy shared by the runtime integration and its host-side tests.
// Protection is intentionally page-specific: once the fullscreen pager moves
// to another item, the old player/layer must be free to follow Apollo's normal
// gallery, dismissal, and PiP ownership rules.
static inline bool ApolloSwipeCommentsMediaShouldProtect(bool sessionActive,
                                                         bool capturedViewerIsCurrent,
                                                         bool pipOwnsPlayer) {
    return sessionActive && capturedViewerIsCurrent && !pipOwnsPlayer;
}

// Capture the effective or intended playback rate. While AVPlayer is waiting,
// `rate` can be zero even though playback will resume; prefer Apollo's selected
// fullscreen speed, then AVPlayer.defaultRate, then normal speed. A genuinely
// paused player remains zero and must never be restarted by the pane.
static inline float ApolloSwipeCommentsMediaCapturedRate(float currentRate,
                                                         bool waitingToPlay,
                                                         bool hasApolloRate,
                                                         float apolloRate,
                                                         bool hasDefaultRate,
                                                         float defaultRate) {
    if (isfinite(currentRate) && currentRate > 0.0f) return currentRate;
    if (!waitingToPlay) return 0.0f;
    if (hasApolloRate && isfinite(apolloRate) && apolloRate > 0.0f) return apolloRate;
    if (hasDefaultRate && isfinite(defaultRate) && defaultRate > 0.0f) return defaultRate;
    return 1.0f;
}

// Zero means no write. Restore both a pane-paused player and a player that a
// competing media path restarted at the wrong speed.
static inline float ApolloSwipeCommentsMediaRateToRestore(bool shouldProtect,
                                                          float capturedRate,
                                                          float currentRate) {
    if (!shouldProtect || !isfinite(capturedRate) || capturedRate <= 0.0f) return 0.0f;
    if (isfinite(currentRate) && fabsf(currentRate - capturedRate) < 0.001f) return 0.0f;
    return capturedRate;
}

static inline bool ApolloSwipeCommentsMediaShouldRestoreLayer(bool shouldProtect,
                                                              bool capturedLayerExists,
                                                              bool layerStillInCapturedHost) {
    return shouldProtect && capturedLayerExists && !layerStillInCapturedHost;
}

// The collapsed comments header tears down while the sheet is animating out.
// Keep the fullscreen player's protection through that animation and release
// it only from the dismissal completion (or the adaptive-dismiss callback).
static inline bool ApolloSwipeCommentsMediaShouldInvalidateAfterDismissal(
    bool dismissalCompleted) {
    return dismissalCompleted;
}

#endif
