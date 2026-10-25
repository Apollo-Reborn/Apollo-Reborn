#ifndef ApolloHighlightsCarouselGesturePolicy_h
#define ApolloHighlightsCarouselGesturePolicy_h

#include <math.h>
#include <stdbool.h>

// A carousel can come to rest a few points short of its edge after a
// scroll-back and still look fully at that end, so treat anything within this
// distance of the minimum or maximum offset as being at the end.
static const double ApolloHLCarouselEdgeTolerance = 8.0;

// UIKit can report a near-zero velocity when a pan begins. Below this speed on
// both axes the velocity carries no usable direction, so use the pan's
// translation instead.
static const double ApolloHLCarouselMinimumVelocity = 10.0;

// The Community Highlights carousel normally claims every horizontal pan. At
// an end of its content that only rubber-bands, so a Back or Forward swipe that
// starts on the carousel never navigates. Yield only a horizontal-dominant pan
// that points outward at a boundary AND has a navigation target in that
// direction; everything else keeps scrolling the carousel. RTL mirrors
// navigation semantics, not the carousel's left-to-right content layout.
static inline bool ApolloHLCarouselShouldYieldToNavigation(double offsetX,
                                                           double minOffsetX,
                                                           double maxOffsetX,
                                                           double velocityX,
                                                           double velocityY,
                                                           double translationX,
                                                           double translationY,
                                                           bool rightToLeft,
                                                           bool canGoBack,
                                                           bool canGoForward) {
    double dx = velocityX;
    double dy = velocityY;
    if (fabs(dx) < ApolloHLCarouselMinimumVelocity && fabs(dy) < ApolloHLCarouselMinimumVelocity) {
        dx = translationX;
        dy = translationY;
    }
    if (fabs(dx) <= fabs(dy) || dx == 0.0) return false;
    bool atLeadingEnd = offsetX <= minOffsetX + ApolloHLCarouselEdgeTolerance;
    bool atTrailingEnd = offsetX >= maxOffsetX - ApolloHLCarouselEdgeTolerance;
    bool rightward = dx > 0.0;
    if (rightward && atLeadingEnd) return rightToLeft ? canGoForward : canGoBack;
    if (!rightward && atTrailingEnd) return rightToLeft ? canGoBack : canGoForward;
    return false;
}

#endif
