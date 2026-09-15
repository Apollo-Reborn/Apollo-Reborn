#pragma once
#include <math.h>
#include <stdbool.h>

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

// Two useful columns need 340pt for the list and 420pt for detail. The height
// floor keeps a conventional landscape phone in its single browsing path.
static inline bool ApolloPanePhoneHasRoomForColumns(double width, double height) {
    return isfinite(width) && isfinite(height) && width >= 760.0 && height >= 500.0;
}
