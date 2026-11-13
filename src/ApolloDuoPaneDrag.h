// Pure rules behind the Duo pane Back drag (ApolloDuoNavigationGestures.m):
// which Back a rightward drag in a pane runs, when it begins, and whether a
// release completes it. No UIKit, so tests/run_duo_pane_drag_tests.sh can
// check them on the host.
#pragma once

#include <stdbool.h>

typedef enum {
    // Nothing to go back to; the drag never begins.
    ApolloDuoBackRouteNone = 0,
    // A pop onto a real page of the same pane: Apollo's own interactive Back
    // owns it and follows the finger. The pane drag stands down.
    ApolloDuoBackRouteNative,
    // The feed root: the subreddit list slides in with the finger.
    ApolloDuoBackRouteDrawer,
    // The thread right above the Posts backstop: the thread pane slides out
    // with the finger, and a completed drag closes its column.
    ApolloDuoBackRouteCloseThread,
    // A Back only the split can lay out (Account's Overview, a pushed feed
    // beside an open thread): runs the split's own animated Back once the
    // drag clearly begins.
    ApolloDuoBackRoutePop,
} ApolloDuoBackRoute;

// Earlier rows win. `nativeOwns` is checked before the drawer and the thread
// close so a deeper page above either one always pops natively first.
static inline ApolloDuoBackRoute ApolloDuoBackRouteFor(bool canNavigate, bool nativeOwns,
                                                       bool drawer, bool closeThread) {
    if (!canNavigate) return ApolloDuoBackRouteNone;
    if (nativeOwns) return ApolloDuoBackRouteNative;
    if (drawer) return ApolloDuoBackRouteDrawer;
    if (closeThread) return ApolloDuoBackRouteCloseThread;
    return ApolloDuoBackRoutePop;
}

// A drag begins only on a clearly rightward motion, judged from the whole
// motion since touch-down, so a vertical scroll that drifts right never
// starts Back. Velocity breaks the tie for a fast flick that has barely moved.
static inline bool ApolloDuoDragIsRightward(double dx, double dy, double vx, double vy) {
    double ady = dy < 0 ? -dy : dy;
    if (dx > 0.0 && dx > ady * 1.2) return true;
    double avy = vy < 0 ? -vy : vy;
    return dx >= 0.0 && ady < 4.0 && vx > 0.0 && vx > avy * 1.5;
}

// Same rule for a leftward drag (closing the subreddit list).
static inline bool ApolloDuoDragIsLeftward(double dx, double dy, double vx, double vy) {
    return ApolloDuoDragIsRightward(-dx, dy, -vx, vy);
}

// A release completes the drag when it moved past 35% of its travel, or on a
// flick toward completion. A flick back cancels at any distance. `distance`
// and `velocity` are measured toward completion (points, points/second).
static inline bool ApolloDuoDragCommits(double distance, double travel, double velocity) {
    if (velocity <= -300.0) return false;
    if (velocity >= 500.0 && distance > 0.0) return true;
    return travel > 0.0 && distance >= travel * 0.35;
}

// The tracked offset, held to [0, travel] so neither surface overshoots.
static inline double ApolloDuoDragClamp(double offset, double travel) {
    if (offset < 0.0 || travel <= 0.0) return 0.0;
    return offset > travel ? travel : offset;
}
