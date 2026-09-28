#ifndef ApolloFeedGalleryGesturePolicy_h
#define ApolloFeedGalleryGesturePolicy_h

#include <math.h>
#include <stdbool.h>

typedef enum ApolloFeedGalleryPanDisposition {
    ApolloFeedGalleryPanDispositionConsume = 0,
    ApolloFeedGalleryPanDispositionYield = 1,
} ApolloFeedGalleryPanDisposition;

// UIScrollView asks whether its pan should begin only after UIKit's pan
// hysteresis has been crossed. Reject only a clearly horizontal gesture:
// rejecting on a low or vertically-dominant velocity permanently gives away
// a touch that may still have been intended to scroll the feed.
static const double kApolloFeedGalleryPanMinimumVelocity = 150.0;
static const double kApolloFeedGalleryScreenEdgeWidth = 24.0;

// gestureRecognizerShouldBegin: runs after UIKit's pan hysteresis. Recover the
// touch origin from the current centroid and accumulated translation so a real
// edge gesture does not stop counting merely because it moved before recognition.
static inline double ApolloFeedGalleryGestureOriginX(double currentX, double translationX) {
    return currentX - translationX;
}

static inline ApolloFeedGalleryPanDisposition
ApolloFeedGalleryPanDispositionForGesture(double contentOffsetX,
                                          double maximumOffsetX,
                                          double velocityX,
                                          double velocityY,
                                          double touchX,
                                          double viewWidth,
                                          bool rightToLeft,
                                          bool canGoBack,
                                          bool canGoForward) {
    if (maximumOffsetX <= 0.5 ||
        fabs(velocityX) < kApolloFeedGalleryPanMinimumVelocity ||
        fabs(velocityX) <= fabs(velocityY)) {
        return ApolloFeedGalleryPanDispositionConsume;
    }

    bool atFirstPage = contentOffsetX <= 0.5;
    bool atLastPage = contentOffsetX >= maximumOffsetX - 0.5;
    bool pullingPastFirstPage = atFirstPage && velocityX > 0.0;
    bool pullingPastLastPage = atLastPage && velocityX < 0.0;

    // The carousel has no content to show in either of these directions.
    // Yield regardless of which Apollo gesture is available. The feed's
    // vote/action pans and navigation pans can then arbitrate natively.
    if (pullingPastFirstPage || pullingPastLastPage) {
        return ApolloFeedGalleryPanDispositionYield;
    }

    // A pan beginning at a physical screen edge is an explicit navigation
    // signal even in the middle of a gallery. Only yield when navigation can
    // actually act, otherwise preserve ordinary gallery paging at the root or
    // when there is no forward history. RTL mirrors navigation semantics, not
    // the carousel's left-to-right page layout.
    bool pullingInFromLeftEdge = touchX <= kApolloFeedGalleryScreenEdgeWidth && velocityX > 0.0;
    bool pullingInFromRightEdge = viewWidth > 0.0 &&
        touchX >= viewWidth - kApolloFeedGalleryScreenEdgeWidth && velocityX < 0.0;
    bool wantsBack = rightToLeft ? pullingInFromRightEdge : pullingInFromLeftEdge;
    bool wantsForward = rightToLeft ? pullingInFromLeftEdge : pullingInFromRightEdge;
    return (wantsBack && canGoBack) || (wantsForward && canGoForward)
        ? ApolloFeedGalleryPanDispositionYield
        : ApolloFeedGalleryPanDispositionConsume;
}

#endif
