#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

#include "ApolloHighlightsCarouselGesturePolicy.h"

static const double kWidth = 402.0;

static bool back(double vx, double vy, double x, bool anywhere) {
    return ApolloHLNavigationPanRuleAllows(false, vx, vy, x, kWidth, anywhere);
}

static bool forward(double vx, double vy, double x, bool anywhere) {
    return ApolloHLNavigationPanRuleAllows(true, vx, vy, x, kWidth, anywhere);
}

int main(void) {
    // Swipe-anywhere Back: any rightward, horizontal enough swipe.
    assert(back(160.0, 0.0, 150.0, true));
    assert(back(100.0, 20.0, 300.0, true));
    assert(!back(-160.0, 0.0, 150.0, true));
    assert(!back(0.0, 0.0, 150.0, true));
    // Apollo's 1.65 horizontal ratio, inclusive.
    assert(back(165.0, 100.0, 150.0, true));
    assert(!back(164.0, 100.0, 150.0, true));
    assert(!back(160.0, -120.0, 150.0, true));

    // Edge-only Back: within 70pt of the left edge, inclusive.
    assert(back(300.0, 0.0, 14.0, false));
    assert(back(300.0, 0.0, 70.0, false));
    assert(!back(300.0, 0.0, 71.0, false));
    assert(!back(300.0, 0.0, 140.0, false));

    // Forward mirrors it: leftward, and within 40pt of the right edge unless
    // swipe-anywhere.
    assert(forward(-300.0, 0.0, 200.0, true));
    assert(!forward(300.0, 0.0, 200.0, true));
    assert(forward(-300.0, 0.0, 362.0, false));
    assert(!forward(-300.0, 0.0, 361.0, false));
    assert(!forward(-300.0, 250.0, 380.0, false));

    // Ends: the end card fully in view (16pt side padding), overscroll counts.
    assert(ApolloHLCarouselAtStart(0.0, 0.0, 16.0));
    assert(ApolloHLCarouselAtStart(-30.0, 0.0, 16.0));
    assert(ApolloHLCarouselAtStart(16.0, 0.0, 16.0));
    assert(!ApolloHLCarouselAtStart(17.0, 0.0, 16.0));
    assert(!ApolloHLCarouselAtStart(65.0, 0.0, 16.0));
    assert(ApolloHLCarouselAtEnd(130.0, 0.0, 130.0, 16.0));
    assert(ApolloHLCarouselAtEnd(150.0, 0.0, 130.0, 16.0));
    assert(ApolloHLCarouselAtEnd(114.0, 0.0, 130.0, 16.0));
    assert(!ApolloHLCarouselAtEnd(113.0, 0.0, 130.0, 16.0));
    assert(!ApolloHLCarouselAtEnd(65.0, 0.0, 130.0, 16.0));
    // Content inset: the start is the negative minimum offset.
    assert(ApolloHLCarouselAtStart(-59.0, -59.0, 16.0));
    assert(!ApolloHLCarouselAtStart(0.0, -59.0, 16.0));
    // All cards fit: both ends at once, even when the computed maximum is
    // below the minimum.
    assert(ApolloHLCarouselAtStart(0.0, 0.0, 16.0));
    assert(ApolloHLCarouselAtEnd(0.0, 0.0, -140.0, 16.0));

    puts("highlights_carousel_gesture_policy_tests passed");
    return 0;
}
