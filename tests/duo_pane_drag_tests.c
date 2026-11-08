#include <stdio.h>
#include <stdlib.h>
#include "ApolloDuoPaneDrag.h"

static unsigned checks;
static void check(bool valid, const char *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

int main(void) {
    // Routing: earlier rows win.
    check(ApolloDuoBackRouteFor(false, true, true, true) == ApolloDuoBackRouteNone, "no Back, no drag");
    check(ApolloDuoBackRouteFor(true, true, true, true) == ApolloDuoBackRouteNative, "a real page pop is Apollo's own Back");
    check(ApolloDuoBackRouteFor(true, false, true, true) == ApolloDuoBackRouteDrawer, "feed root pulls in the list");
    check(ApolloDuoBackRouteFor(true, false, false, true) == ApolloDuoBackRouteCloseThread, "thread above backstop closes by drag");
    check(ApolloDuoBackRouteFor(true, false, false, false) == ApolloDuoBackRoutePop, "anything else runs the split's own Back");

    // Direction from the whole motion so far.
    check(ApolloDuoDragIsRightward(20, 5, 0, 0), "a rightward drag begins");
    check(!ApolloDuoDragIsRightward(20, 20, 800, 0), "a diagonal drag does not");
    check(!ApolloDuoDragIsRightward(5, 40, 0, 900), "a vertical scroll that drifts right does not");
    check(!ApolloDuoDragIsRightward(-20, 0, -500, 0), "a leftward drag does not");
    check(ApolloDuoDragIsRightward(1, 0, 600, 50), "a fast flick that has barely moved does");
    check(!ApolloDuoDragIsRightward(1, 10, 600, 50), "unless it already moved vertically");
    check(ApolloDuoDragIsLeftward(-20, 3, -100, 0) && !ApolloDuoDragIsLeftward(20, 3, 100, 0), "leftward mirrors rightward");

    // Release.
    check(ApolloDuoDragCommits(180, 500, 0), "a held release past 35% completes");
    check(!ApolloDuoDragCommits(170, 500, 0), "a held release short of 35% springs back");
    check(ApolloDuoDragCommits(20, 500, 800), "a flick toward completion completes from anywhere");
    check(!ApolloDuoDragCommits(400, 500, -400), "a flick back cancels at any distance");
    check(!ApolloDuoDragCommits(0, 500, 900), "a flick that never moved does nothing");
    check(!ApolloDuoDragCommits(100, 0, 0), "no travel, no commit");

    // Clamp.
    check(ApolloDuoDragClamp(-10, 300) == 0 && ApolloDuoDragClamp(350, 300) == 300
          && ApolloDuoDragClamp(120, 300) == 120 && ApolloDuoDragClamp(50, 0) == 0, "offsets stay within the travel");
    printf("OK: %u checks\n", checks);
    return 0;
}
