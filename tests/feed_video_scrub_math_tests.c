#include "ApolloFeedVideoScrubMath.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;

static void Check(int condition, const char *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static int Near(double actual, double expected) {
    return fabs(actual - expected) < 0.000001;
}

int main(void) {
    Check(Near(ApolloFeedVideoScrubStartingFraction(30.0, 120.0), 0.25),
          "playhead becomes the starting fraction");
    Check(Near(ApolloFeedVideoScrubStartingFraction(150.0, 120.0), 1.0),
          "starting playhead clamps after the end");
    Check(Near(ApolloFeedVideoScrubStartingFraction(-1.0, 120.0), 0.0),
          "negative playhead starts at zero");
    Check(Near(ApolloFeedVideoScrubStartingFraction(30.0, 0.0), 0.0),
          "unknown duration starts at zero");

    Check(Near(ApolloFeedVideoScrubTargetFraction(0.25, 20.0, 20.0, 100.0), 0.25),
          "touch-down away from the thumb does not jump the playhead");
    Check(Near(ApolloFeedVideoScrubTargetFraction(0.25, 80.0, 90.0, 100.0), 0.35),
          "right drag advances relative to the existing playhead");
    Check(Near(ApolloFeedVideoScrubTargetFraction(0.75, 80.0, 30.0, 100.0), 0.25),
          "left drag rewinds relative to the existing playhead");
    Check(Near(ApolloFeedVideoScrubTargetFraction(0.95, 40.0, 140.0, 100.0), 1.0),
          "drag past the right edge clamps at the end");
    Check(Near(ApolloFeedVideoScrubTargetFraction(0.05, 80.0, -20.0, 100.0), 0.0),
          "drag past the left edge clamps at the beginning");
    Check(Near(ApolloFeedVideoScrubTargetFraction(0.4, 20.0, 80.0, 0.0), 0.4),
          "zero-width track preserves the starting playhead");
    Check(Near(ApolloFeedVideoScrubTargetFraction(0.4, 20.0, NAN, 100.0), 0.4),
          "invalid gesture coordinates preserve the starting playhead");

    printf("OK: %u checks\n", checks);
    return 0;
}
