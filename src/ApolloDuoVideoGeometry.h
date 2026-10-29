#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <math.h>

// Pure geometry: the division comes from UIKit, never an estimated hinge angle.
typedef struct {
    CGRect video;
    CGRect controls;
} ApolloDuoVideoGeometry;

typedef struct {
    CGRect playback[3];
    CGRect timeline;
    CGRect scrubber;
    CGRect elapsed;
    CGRect remaining;
    CGRect utilities[2];
} ApolloDuoVideoControlGeometry;

// All playback controls fit together as one balanced panel, including the two
// utility tiles. Keep this independent of UIKit for narrow/short-panel tests.
static inline bool ApolloDuoVideoMakeControlGeometry(CGSize size, ApolloDuoVideoControlGeometry *out) {
    if (!out || !isfinite(size.width) || !isfinite(size.height)
        || size.width < 320 || size.height < 240) return false;
    CGFloat gap = 10;
    CGFloat width = (size.width - 2 * gap) / 3;
    CGFloat height = fmin(154, fmax(120, fmin(size.height - 120, size.height * 0.5)));
    CGFloat start = (size.height - height - 120) * 0.5;
    CGFloat timelineY = start;
    CGFloat playbackY = timelineY + 60;
    for (int i = 0; i < 3; i++) out->playback[i] = CGRectMake(i * (width + gap), playbackY, width, height);
    out->timeline = CGRectMake(0, timelineY, size.width, 52);
    // Both time labels belong to the same track row, never loose beneath it.
    CGFloat timeWidth = fmin(76, fmax(58, size.width * 0.1));
    CGFloat sliderInset = 14 + timeWidth + 10;
    out->scrubber = CGRectMake(sliderInset, timelineY + 4, size.width - 2 * sliderInset, 44);
    out->elapsed = CGRectMake(14, timelineY + 14, timeWidth, 24);
    out->remaining = CGRectMake(size.width - 14 - timeWidth, timelineY + 14, timeWidth, 24);
    CGFloat utilityWidth = (size.width - gap) * 0.5;
    for (int i = 0; i < 2; i++) out->utilities[i] = CGRectMake(i * (utilityWidth + gap), playbackY + height + 8, utilityWidth, 52);
    return true;
}

static inline bool ApolloDuoVideoFiniteRect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y)
        && isfinite(r.size.width) && isfinite(r.size.height)
        && r.size.width >= 0 && r.size.height >= 0;
}

static inline bool ApolloDuoVideoMakeGeometry(CGRect bounds, CGRect division,
                                              CGFloat top, CGFloat left,
                                              CGFloat bottom, CGFloat right,
                                              bool eligible,
                                              ApolloDuoVideoGeometry *out) {
    if (!eligible || !out || !ApolloDuoVideoFiniteRect(bounds)
        || !ApolloDuoVideoFiniteRect(division) || bounds.size.height <= bounds.size.width
        || bounds.size.width < 600 || division.size.width <= division.size.height
        || !isfinite(top) || !isfinite(left) || !isfinite(bottom) || !isfinite(right)
        || top < 0 || left < 0 || bottom < 0 || right < 0) return false;
    // A division must span this fullscreen viewport and separate two usable
    // panels. Do not mistake a region on another display/window for our fold.
    if (CGRectGetMinX(division) > CGRectGetMinX(bounds) + 1
        || CGRectGetMaxX(division) < CGRectGetMaxX(bounds) - 1) return false;
    CGFloat x = CGRectGetMinX(bounds) + left + 16;
    CGFloat width = bounds.size.width - left - right - 32;
    CGFloat upperY = CGRectGetMinY(bounds) + top;
    CGFloat upperEnd = CGRectGetMinY(division) - 12;
    CGFloat lowerY = CGRectGetMaxY(division) + 20;
    CGFloat lowerEnd = CGRectGetMaxY(bounds) - bottom - 80; // native post actions
    if (width < 320 || upperEnd - upperY < 160 || lowerEnd - lowerY < 240) return false;
    out->video = CGRectMake(x, upperY, width, upperEnd - upperY);
    out->controls = CGRectMake(x, lowerY, width, lowerEnd - lowerY);
    return true;
}
