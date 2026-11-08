#include <assert.h>
#include <stdio.h>
#include "ApolloDuoDividerGeometry.h"
int main(void) {
    assert(ApolloDuoDividerClamp(1, 951, 84) == 320);
    assert(ApolloDuoDividerClamp(900, 951, 84) == 547);
    assert(ApolloDuoDividerClamp(NAN, 951, 84) == 475.5);
    assert(ApolloDuoDividerClamp(100, 500, 84) == 250);
    assert(ApolloDuoDividerSnap(470, 951, 84) == 475.5);
    assert(ApolloDuoDividerSnap(365, 951, 84) == 365);
    assert(ApolloDuoDividerSnap(951 * .39, 951, 84) == 951 * .39);
    assert(ApolloDuoDividerSnap(951 * .6, 951, 84) == 547);
    assert(ApolloDuoDividerTick(.41, 20) == 20);
    assert(ApolloDuoDividerTick(.414, 20) == 21);
    assert(ApolloDuoDividerTick(.41, 21) == 21);
    assert(ApolloDuoDividerTick(.406, 21) == 20);
    assert(ApolloDuoDividerLimit(320, 951, 84, 0) == -1);
    assert(ApolloDuoDividerLimit(323, 951, 84, -1) == -1);
    assert(ApolloDuoDividerLimit(327, 951, 84, -1) == 0);
    assert(ApolloDuoDividerLimit(547, 951, 84, 0) == 1);
    assert(ApolloDuoDividerLimit(544, 951, 84, 1) == 1);
    assert(ApolloDuoDividerLimit(540, 951, 84, 1) == 0);
    assert(ApolloDuoDividerLimit(250, 500, 84, 0) == 0);
    // Every release remains legal, including unreachable landmarks near the rail.
    for (int w = 700; w <= 1400; w += 7)
        for (int x = -100; x <= w + 100; ++x) {
            double snapped = ApolloDuoDividerSnap(x, w, 84);
            assert(snapped == ApolloDuoDividerClamp(snapped, w, 84));
        }
    puts("PASS: divider bounds, snapping, free positioning and tick hysteresis");
}
