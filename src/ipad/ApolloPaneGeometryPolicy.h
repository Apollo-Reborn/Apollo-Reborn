#pragma once
#include <math.h>
#include <stdbool.h>

// Navigation uses the assigned window, not device model or orientation.
// Below 760pt, a 340pt list and 420pt reader cannot coexist. A destinations
// sidebar needs additional room without taking that minimum from the reader.
static inline bool ApolloPaneHasRoomForColumns(double width) {
    return isfinite(width) && width >= 760.0;
}

static inline bool ApolloPaneHasRoomForSidebar(double width) {
    return isfinite(width) && width >= 1180.0;
}

// Pure policy: preferences survive constrained windows; resolved requests do
// not consume the reader's minimum useful width. UIKit owns final geometry.
static inline double ApolloPanePreferredWidth(double width) {
    return fmin(480.0, fmax(340.0, isfinite(width) ? width : 420.0));
}

static inline double ApolloPaneResolvedWidth(double preferred, double available) {
    double width = ApolloPanePreferredWidth(preferred);
    if (!isfinite(available) || available <= 0.0) return width;
    return fmin(width, fmax(340.0, available - 420.0));
}

static inline bool ApolloPanePrimaryIsPhysicallyLeft(bool leading, bool rightToLeft) {
    return leading != rightToLeft;
}
