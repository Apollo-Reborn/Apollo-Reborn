#pragma once
#include <math.h>

// Canvas coordinates, including the rail. Keep both titles/actions usable.
static inline double ApolloDuoDividerClamp(double x, double width, double trailingInset) {
    double low = fmax(320.0, width / 3.0);
    double high = fmin(width * 0.65, width - trailingInset - 320.0);
    if (!isfinite(x)) x = width * 0.5;
    if (high < low) return width * 0.5;
    return fmax(low, fmin(high, x));
}
static inline double ApolloDuoDividerSnap(double x, double width, double trailingInset) {
    x = ApolloDuoDividerClamp(x, width, trailingInset);
    const double stops[] = { 1.0 / 3.0, 0.4, 0.5, 0.6 };
    for (unsigned i = 0; i < sizeof(stops) / sizeof(stops[0]); ++i) {
        double target = width * stops[i];
        if (fabs(target - ApolloDuoDividerClamp(target, width, trailingInset)) < 0.000001 && fabs(x - target) <= 6.0)
            return ApolloDuoDividerClamp(target, width, trailingInset);
    }
    return x;
}
enum { ApolloDuoDividerTicksPerWhole = 50 }; // 2 percentage points

// Keep a reached edge latched until the finger moves clearly back into the
// range, so small movements against the stop don't repeat its haptic.
static inline int ApolloDuoDividerLimit(double x, double width, double inset, int previous) {
    double low = ApolloDuoDividerClamp(0, width, inset);
    double high = ApolloDuoDividerClamp(width, width, inset);
    if (high - low < 0.01) return 0;
    if (x <= low + 0.01) return -1;
    if (x >= high - 0.01) return 1;
    if (previous == -1 && x < low + 6) return -1;
    if (previous == 1 && x > high - 6) return 1;
    return 0;
}

// Keep the old tick until the finger moves beyond a small hysteresis band.
static inline int ApolloDuoDividerTick(double share, int previous) {
    double position = share * ApolloDuoDividerTicksPerWhole;
    return fabs(position - previous) > 0.65 ? (int)round(position) : previous;
}
