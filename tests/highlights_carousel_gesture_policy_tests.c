#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

#include "ApolloHighlightsCarouselGesturePolicy.h"

static bool yieldsWithTranslation(double offset, double vx, double vy, double tx, double ty,
                                  bool rtl, bool back, bool forward) {
    return ApolloHLCarouselShouldYieldToNavigation(offset, 0.0, 480.0, vx, vy, tx, ty, rtl, back, forward);
}

static bool yields(double offset, double vx, double vy, bool rtl, bool back, bool forward) {
    return yieldsWithTranslation(offset, vx, vy, 0.0, 0.0, rtl, back, forward);
}

int main(void) {
    // Leading end, rightward: needs Back.
    assert(yields(0.0, 400.0, 20.0, false, true, false));
    assert(yields(0.4, 400.0, 20.0, false, true, false));
    assert(!yields(0.0, 400.0, 20.0, false, false, true));
    // Mid-carousel never yields, either direction, any availability.
    assert(!yields(200.0, 400.0, 20.0, false, true, true));
    assert(!yields(200.0, -400.0, 20.0, false, true, true));
    assert(!yields(12.0, 400.0, 20.0, false, true, true));
    assert(!yields(468.0, -400.0, 20.0, false, true, true));
    // A carousel resting a few points off an edge still counts as at that end.
    assert(yields(4.3, 400.0, 20.0, false, true, false));
    assert(yields(475.7, -400.0, 20.0, false, false, true));
    assert(yields(8.0, 400.0, 20.0, false, true, false));
    // Trailing end, leftward: needs Forward.
    assert(yields(480.0, -400.0, 20.0, false, false, true));
    assert(!yields(480.0, -400.0, 20.0, false, true, false));
    // Inward pans at an end keep scrolling.
    assert(!yields(0.0, -400.0, 20.0, false, true, true));
    assert(!yields(480.0, 400.0, 20.0, false, true, true));
    // Vertical-dominant or stationary pans never yield.
    assert(!yields(0.0, 100.0, 400.0, false, true, true));
    assert(!yields(480.0, -100.0, 400.0, false, true, true));
    assert(!yields(0.0, 0.0, 0.0, false, true, true));
    assert(!yieldsWithTranslation(0.0, 0.0, 0.0, 0.0, 0.0, false, true, true));
    // Near-zero velocity at begin: translation decides direction and dominance.
    assert(yieldsWithTranslation(0.0, 0.0, 0.0, 12.0, 1.0, false, true, false));
    assert(yieldsWithTranslation(0.0, 4.0, -3.0, 12.0, 1.0, false, true, false));
    assert(yieldsWithTranslation(480.0, 0.0, 0.0, -12.0, 1.0, false, false, true));
    assert(!yieldsWithTranslation(0.0, 0.0, 0.0, -12.0, 1.0, false, true, true));
    assert(!yieldsWithTranslation(0.0, 0.0, 0.0, 3.0, 12.0, false, true, true));
    assert(!yieldsWithTranslation(200.0, 0.0, 0.0, 12.0, 1.0, false, true, true));
    // A real velocity wins over a translation that points the other way.
    assert(!yieldsWithTranslation(0.0, -400.0, 20.0, 12.0, 1.0, false, true, true));
    // RTL mirrors navigation: rightward at the start goes Forward, leftward at
    // the end goes Back.
    assert(yields(0.0, 400.0, 20.0, true, false, true));
    assert(!yields(0.0, 400.0, 20.0, true, true, false));
    assert(yields(480.0, -400.0, 20.0, true, true, false));
    assert(!yields(480.0, -400.0, 20.0, true, false, true));
    // Non-zero content inset: the leading end is the (negative) minimum offset.
    assert(ApolloHLCarouselShouldYieldToNavigation(-16.0, -16.0, 480.0, 400.0, 20.0, 0.0, 0.0, false, true, false));
    assert(!ApolloHLCarouselShouldYieldToNavigation(0.0, -16.0, 480.0, 400.0, 20.0, 0.0, 0.0, false, true, false));

    puts("highlights_carousel_gesture_policy_tests passed");
    return 0;
}
