#include "../../src/ipad/ApolloPaneGeometryPolicy.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(ApolloPanePreferredWidth(NAN) == 420);
    assert(ApolloPanePreferredWidth(INFINITY) == 420);
    assert(ApolloPanePreferredWidth(-1) == 340);
    assert(ApolloPanePreferredWidth(1000) == 480);
    for (double preferred = 340; preferred <= 480; preferred += 1) {
        for (double available = 760; available <= 1800; available += 1) {
            double resolved = ApolloPaneResolvedWidth(preferred, available);
            assert(isfinite(resolved) && resolved >= 340 && resolved <= preferred);
            assert(available - resolved >= 420);
            assert(ApolloPaneResolvedWidth(resolved, available) == resolved);
            // Narrowing and widening must never overwrite the user's intent.
            assert(ApolloPaneResolvedWidth(preferred, 1800) == preferred);
        }
    }
    assert(ApolloPanePrimaryIsPhysicallyLeft(true, false));
    assert(!ApolloPanePrimaryIsPhysicallyLeft(true, true));
    assert(!ApolloPanePrimaryIsPhysicallyLeft(false, false));
    assert(ApolloPanePrimaryIsPhysicallyLeft(false, true));
    puts("Pane geometry: 146,781 width/capacity combinations and RTL cases passed");
}
