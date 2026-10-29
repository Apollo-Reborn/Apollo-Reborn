#ifndef ApolloHighlightsCarouselGesturePolicy_h
#define ApolloHighlightsCarouselGesturePolicy_h

#include <math.h>
#include <stdbool.h>

// ApolloNavigationController's gestureRecognizerShouldBegin: (sub_10015d644)
// begins its Back pan for vx > 0 and its Forward pan for vx < 0, once
// |vx / vy| >= 1.65 and the touch is within 70pt of the left edge (Back) or
// 40pt of the right edge (Forward). DisableLeftSwipeGestureActions (Back) and
// DisableRightSwipeGestureActions (Forward) drop the edge zone, making it
// swipe-anywhere. Constants read from the binary.
static const double kApolloHLNavigationPanMinimumRatio = 1.65;
static const double kApolloHLNavigationBackEdgeWidth = 70.0;
static const double kApolloHLNavigationForwardEdgeWidth = 40.0;

// Apollo's rule applied to the carousel pan's own reading, which is current
// when the carousel decides (Apollo's pan often has not processed the move
// yet). Physical directions: Apollo's pans do not mirror for right-to-left.
static inline bool ApolloHLNavigationPanRuleAllows(bool forward,
                                                   double velocityX,
                                                   double velocityY,
                                                   double touchX,
                                                   double viewWidth,
                                                   bool swipeAnywhere) {
    if (forward ? velocityX >= 0.0 : velocityX <= 0.0) return false;
    if (fabs(velocityX) < kApolloHLNavigationPanMinimumRatio * fabs(velocityY)) return false;
    if (swipeAnywhere) return true;
    return forward ? touchX >= viewWidth - kApolloHLNavigationForwardEdgeWidth
                   : touchX <= kApolloHLNavigationBackEdgeWidth;
}

// An end counts once that end's card is fully in view: within `slack` (the
// carousel's side padding) of the offset limit, not just within a point of it.
// A free scroll often comes to rest a few points short. Overscroll counts.
static inline bool ApolloHLCarouselAtStart(double offset, double minOffset, double slack) {
    return offset <= minOffset + slack + 0.5;
}

static inline bool ApolloHLCarouselAtEnd(double offset, double minOffset, double maxOffset, double slack) {
    return offset >= fmax(minOffset, maxOffset) - slack - 0.5;
}

#endif
