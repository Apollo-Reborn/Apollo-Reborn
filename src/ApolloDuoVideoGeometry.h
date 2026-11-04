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
    // Mute and AirPlay bookend this row. Playback Speed sits between them
    // when the viewer's menu offers it (Share and Download already live in
    // the post actions row below the panel).
    CGRect accessories[6];
    int accessoryCount;
} ApolloDuoVideoControlGeometry;

// Netflix-style transport for the lower panel. The timeline is a slim
// Safari-style capsule (34pt, times at each end) above the wide skip/play tiles, and a shorter accessory row sits under
// them. `accessories` is the number of tiles in that row (2...6). Independent
// of UIKit for host tests. The same frames are used for Liquid Glass and
// classic builds.
static inline bool ApolloDuoVideoMakeControlGeometry(CGSize size, int accessories, ApolloDuoVideoControlGeometry *out) {
    if (!out || accessories < 2 || accessories > 6
        || !isfinite(size.width) || !isfinite(size.height)
        || size.width < 320 || size.height < 240) return false;
    const CGFloat side = 16, gap = 12, bottom = 8, topMin = 12, timelineH = 34, extraH = 56;
    CGFloat maxTransport = size.height - topMin - bottom - timelineH - extraH - gap * 2;
    if (maxTransport < 88) return false;
    CGFloat transportH = fmin(148, maxTransport);
    CGFloat clusterH = timelineH + gap + transportH + gap + extraH;
    CGFloat clusterTop = (size.height - bottom - clusterH) * 0.5;
    if (clusterTop < topMin) clusterTop = topMin;
    CGFloat timelineY = clusterTop;
    CGFloat transportY = timelineY + timelineH + gap;
    CGFloat extraY = transportY + transportH + gap;
    CGFloat inner = size.width - side * 2 - gap * 2;
    if (inner < 180) return false;
    // Play is the wide center tile. The two skip tiles split the rest.
    CGFloat skipW = inner / 3.55;
    CGFloat playW = inner - skipW * 2;
    CGFloat x = side;
    out->playback[0] = CGRectMake(x, transportY, skipW, transportH);
    out->playback[1] = CGRectMake(x + skipW + gap, transportY, playW, transportH);
    out->playback[2] = CGRectMake(x + skipW + gap + playW + gap, transportY, skipW, transportH);
    out->timeline = CGRectMake(side, timelineY, size.width - side * 2, timelineH);
    CGFloat timeWidth = fmin(64, fmax(58, out->timeline.size.width * 0.1));
    const CGFloat labelPad = 14, trackGap = 10, labelH = 16;
    CGFloat labelY = timelineY + (timelineH - labelH) * 0.5;
    out->elapsed = CGRectMake(CGRectGetMinX(out->timeline) + labelPad, labelY, timeWidth, labelH);
    out->remaining = CGRectMake(CGRectGetMaxX(out->timeline) - labelPad - timeWidth, labelY, timeWidth, labelH);
    CGFloat trackX = CGRectGetMaxX(out->elapsed) + trackGap;
    CGFloat trackW = CGRectGetMinX(out->remaining) - trackGap - trackX;
    if (trackW < 48) return false;
    out->scrubber = CGRectMake(trackX, timelineY, trackW, timelineH);
    const CGFloat accGap = 10;
    CGFloat accInner = size.width - side * 2 - accGap * (accessories - 1);
    CGFloat accW = accInner / accessories;
    if (accW < 44) return false;
    out->accessoryCount = accessories;
    for (int i = 0; i < 6; i++) out->accessories[i] = CGRectZero;
    for (int i = 0; i < accessories; i++) {
        out->accessories[i] = CGRectMake(side + i * (accW + accGap), extraY, accW, extraH);
    }
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
