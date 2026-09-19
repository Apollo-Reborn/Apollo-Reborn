#include "ApolloDeviceReservedRegions.h"

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
    return fabs(actual - expected) < 0.51;
}

int main(void) {
    ApolloReservedAvoidance empty = ApolloReservedAvoidanceMake(800.0, 400.0, NULL, 0);
    Check(!empty.hasVerticalGap && empty.edge.left == 0.0 && empty.edge.top == 0.0,
          "no rects produce empty avoidance");

    ApolloReservedRect leftFlush = { 0.0, 0.0, 48.0, 400.0 };
    ApolloReservedAvoidance left = ApolloReservedAvoidanceMake(800.0, 400.0, &leftFlush, 1);
    Check(Near(left.edge.left, 48.0) && !left.hasVerticalGap,
          "edge-flush strip becomes a left extra, not a center gap");

    ApolloReservedRect topCam = { 360.0, 0.0, 80.0, 37.0 };
    ApolloReservedAvoidance top = ApolloReservedAvoidanceMake(800.0, 400.0, &topCam, 1);
    Check(Near(top.edge.top, 37.0) && !top.hasVerticalGap,
          "top camera occlusion insets the top edge only");

    ApolloReservedRect hinge = { 390.0, 0.0, 20.0, 400.0 };
    ApolloReservedAvoidance mid = ApolloReservedAvoidanceMake(800.0, 400.0, &hinge, 1);
    Check(mid.hasVerticalGap && Near(mid.gapX, 390.0) && Near(mid.gapWidth, 20.0),
          "center hinge is a vertical gap");
    Check(mid.edge.left == 0.0 && mid.edge.right == 0.0,
          "center hinge does not fake left+right edge insets");

    ApolloReservedRect flatHinge = { 400.0, 0.0, 0.0, 400.0 };
    ApolloReservedAvoidance flat = ApolloReservedAvoidanceMake(800.0, 400.0, &flatHinge, 1);
    Check(flat.hasVerticalGap,
          "inactive zero-width fold still counts as a division for column math");

    ApolloReservedInsets chrome = { .left = 47.0, .top = 59.0, .right = 47.0, .bottom = 21.0 };
    ApolloReservedInsets media = ApolloMediaInsetsUnion(chrome, top);
    Check(Near(media.top, 59.0),
          "island occlusion already inside safe.top is not double-counted");
    ApolloReservedAvoidance leftAvoid = left;
    ApolloReservedInsets mediaLeft = ApolloMediaInsetsUnion(chrome, leftAvoid);
    Check(Near(mediaLeft.left, 48.0),
          "edge-flush reserved extra wins when it exceeds chrome");

    double barX = 0.0;
    double barW = 0.0;
    ApolloReservedPlaceHorizontalBar(800.0, 16.0, 16.0, &mid, &barX, &barW);
    Check(Near(barX, 16.0) && Near(barW, 374.0),
          "a centered hinge (equal sides) keeps the leading bar span");
    ApolloReservedRect offCenter = { 300.0, 0.0, 20.0, 400.0 };
    ApolloReservedAvoidance rightBias = ApolloReservedAvoidanceMake(800.0, 400.0, &offCenter, 1);
    ApolloReservedPlaceHorizontalBar(800.0, 16.0, 16.0, &rightBias, &barX, &barW);
    Check(Near(barX, 320.0) && Near(barW, 464.0),
          "horizontal bar sits on the larger side of an off-center hinge");

    ApolloReservedAvoidance noGap = empty;
    ApolloReservedPlaceHorizontalBar(800.0, 16.0, 16.0, &noGap, &barX, &barW);
    Check(Near(barX, 16.0) && Near(barW, 768.0),
          "without a gap the bar keeps the chrome-inset span");

    Check(ApolloReservedEvenColumnCount(3, 2, 5, 1) == 4,
          "odd column count bumps up when a division exists");
    Check(ApolloReservedEvenColumnCount(5, 2, 5, 1) == 4,
          "odd count at the max drops down to stay even");
    Check(ApolloReservedEvenColumnCount(3, 2, 5, 0) == 3,
          "no division leaves an odd count alone");
    Check(ApolloReservedEvenColumnCount(2, 2, 5, 1) == 2,
          "already-even count is unchanged");

    ApolloReservedRect card = { 380.0, 100.0, 80.0, 50.0 };
    ApolloReservedRect shifted = ApolloReservedShiftRect(card, 800.0, 400.0, &hinge, 1);
    Check(!ApolloReservedRectsIntersect(shifted, hinge),
          "shifted chrome no longer intersects the hinge");
    Check(shifted.x + shifted.width <= 390.0 + 0.51
              || shifted.x + 0.51 >= 410.0,
          "shifted chrome is entirely left or right of the hinge");

    ApolloReservedRect clear = { 20.0, 20.0, 40.0, 40.0 };
    ApolloReservedRect still = ApolloReservedShiftRect(clear, 800.0, 400.0, &hinge, 1);
    Check(Near(still.x, 20.0) && Near(still.y, 20.0),
          "a rect that already misses the hinge is not moved");

    printf("OK: %u checks\n", checks);
    return 0;
}
