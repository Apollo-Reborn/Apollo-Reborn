#include "ApolloDeviceDisplay.h"

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

int main(void) {
    Check(ApolloDisplayArea(0.0, 800.0) == 0.0, "zero width has no area");
    Check(ApolloDisplayArea(390.0, 844.0) == 390.0 * 844.0, "phone area");
    Check(ApolloDisplayArea(700.0, 900.0) > ApolloDisplayArea(390.0, 844.0),
          "inner Duo area is larger than a phone column");

    Check(!ApolloDisplayIsLetterboxed(390.0, 844.0, 390.0, 844.0),
          "matching phone window is not letterboxed");
    Check(!ApolloDisplayIsLetterboxed(700.0, 900.0, 700.0, 900.0),
          "matching inner canvas is not letterboxed");
    Check(ApolloDisplayIsLetterboxed(390.0, 844.0, 700.0, 900.0),
          "phone column on inner Duo is letterboxed");
    Check(ApolloDisplayIsLetterboxed(390.0, 844.0, 430.0, 844.0),
          "40pt width gap is letterboxed");
    Check(!ApolloDisplayIsLetterboxed(390.0, 844.0, 420.0, 844.0),
          "sub-40pt width gap is not letterboxed");
    Check(!ApolloDisplayIsLetterboxed(390.0, 844.0, 0.0, 844.0),
          "unknown screen is not treated as letterboxed");
    Check(ApolloDisplayIsLetterboxed(0.0, 0.0, 700.0, 900.0),
          "empty window on a real screen is letterboxed");

    Check(!ApolloDisplayScreensAreDual(390.0, 844.0, 390.0, 844.0),
          "two identical phones are not dual-display");
    Check(ApolloDisplayScreensAreDual(390.0, 844.0, 700.0, 900.0),
          "cover vs inner is dual-display");
    Check(!ApolloDisplayScreensAreDual(700.0, 500.0, 680.0, 500.0),
          "near-equal Stage Manager tiles are not dual-display");
    Check(!ApolloDisplayScreensAreDual(0.0, 844.0, 700.0, 900.0),
          "zero-area screen is not dual-display");

    Check(!ApolloDisplayShouldPreferLargestScene(1, 0),
          "single screen keeps first-active scene");
    Check(!ApolloDisplayShouldPreferLargestScene(2, 0),
          "two same-size scenes keep first-active");
    Check(ApolloDisplayShouldPreferLargestScene(2, 1),
          "dual-display prefers the largest scene");

    printf("OK: %u checks\n", checks);
    return 0;
}
