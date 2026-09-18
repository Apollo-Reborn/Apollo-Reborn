#ifndef APOLLO_DEVICE_RESERVED_REGIONS_H
#define APOLLO_DEVICE_RESERVED_REGIONS_H

#ifdef __cplusplus
extern "C" {
#endif

// C-only reserved-region geometry so host tests can compile without UIKit.
// Runtime callers pass an empty list (UIKit reservedRegions SIGSEGVs on
// Duo even with window+scene during first commit). Hinge gutters come
// from layoutMargins / chrome instead. These helpers stay so a future
// safe API can feed the same gap/edge math.

typedef struct {
    double x;
    double y;
    double width;
    double height;
} ApolloReservedRect;

typedef struct {
    double left;
    double top;
    double right;
    double bottom;
} ApolloReservedInsets;

typedef struct {
    ApolloReservedInsets edge;
    double gapX;
    double gapWidth;
    double gapY;
    double gapHeight;
    int hasVerticalGap;
    int hasHorizontalGap;
} ApolloReservedAvoidance;

enum {
    ApolloReservedEdgeSlop = 1,          /* points: flush-to-edge test */
    ApolloReservedStripSpanNum = 1,
    ApolloReservedStripSpanDen = 2,      /* span >= half the opposite side */
    ApolloReservedStripThickNum = 7,
    ApolloReservedStripThickDen = 25,    /* thickness < 28% of that side */
};

static inline double ApolloReservedMax(double a, double b) {
    return a > b ? a : b;
}

static inline double ApolloReservedMin(double a, double b) {
    return a < b ? a : b;
}

static inline int ApolloReservedRectsIntersect(ApolloReservedRect a, ApolloReservedRect b) {
    return a.width > 0.0 && a.height > 0.0 && b.width > 0.0 && b.height > 0.0
        && a.x < b.x + b.width && b.x < a.x + a.width
        && a.y < b.y + b.height && b.y < a.y + a.height;
}

static inline ApolloReservedInsets ApolloReservedInsetsUnion(ApolloReservedInsets a,
                                                             ApolloReservedInsets b) {
    ApolloReservedInsets out;
    out.left = ApolloReservedMax(a.left, b.left);
    out.top = ApolloReservedMax(a.top, b.top);
    out.right = ApolloReservedMax(a.right, b.right);
    out.bottom = ApolloReservedMax(a.bottom, b.bottom);
    return out;
}

// Edge extras are distances from the container edge past any reserved rect
// that is flush to that edge. A center hinge is reported as a vertical gap
// instead of fake left+right insets (which would collapse the whole view).
static inline ApolloReservedAvoidance ApolloReservedAvoidanceMake(double width,
                                                                  double height,
                                                                  const ApolloReservedRect *rects,
                                                                  unsigned count) {
    ApolloReservedAvoidance out;
    out.edge.left = 0.0;
    out.edge.top = 0.0;
    out.edge.right = 0.0;
    out.edge.bottom = 0.0;
    out.gapX = 0.0;
    out.gapWidth = 0.0;
    out.gapY = 0.0;
    out.gapHeight = 0.0;
    out.hasVerticalGap = 0;
    out.hasHorizontalGap = 0;
    if (width <= 0.0 || height <= 0.0 || !rects || count == 0) {
        return out;
    }

    const double slop = (double)ApolloReservedEdgeSlop;
    const double minSpanW = width * (double)ApolloReservedStripSpanNum
        / (double)ApolloReservedStripSpanDen;
    const double minSpanH = height * (double)ApolloReservedStripSpanNum
        / (double)ApolloReservedStripSpanDen;
    const double maxThickW = width * (double)ApolloReservedStripThickNum
        / (double)ApolloReservedStripThickDen;
    const double maxThickH = height * (double)ApolloReservedStripThickNum
        / (double)ApolloReservedStripThickDen;

    unsigned i;
    for (i = 0; i < count; i++) {
        ApolloReservedRect r = rects[i];
        if (r.width < 0.0 || r.height < 0.0) continue;
        if (r.width <= 0.0 && r.height <= 0.0) continue;
        double minX = r.x;
        double minY = r.y;
        double maxX = r.x + r.width;
        double maxY = r.y + r.height;

        if (minX <= slop) {
            out.edge.left = ApolloReservedMax(out.edge.left, maxX);
        }
        if (minY <= slop) {
            out.edge.top = ApolloReservedMax(out.edge.top, maxY);
        }
        if (maxX >= width - slop) {
            out.edge.right = ApolloReservedMax(out.edge.right, width - minX);
        }
        if (maxY >= height - slop) {
            out.edge.bottom = ApolloReservedMax(out.edge.bottom, height - minY);
        }

        int flushLeft = minX <= slop;
        int flushRight = maxX >= width - slop;
        int flushTop = minY <= slop;
        int flushBottom = maxY >= height - slop;
        if (r.height >= minSpanH && r.width <= maxThickW && !flushLeft && !flushRight) {
            if (!out.hasVerticalGap || r.width > out.gapWidth) {
                out.hasVerticalGap = 1;
                out.gapX = minX;
                out.gapWidth = r.width;
            }
        }
        if (r.width >= minSpanW && r.height <= maxThickH && !flushTop && !flushBottom) {
            if (!out.hasHorizontalGap || r.height > out.gapHeight) {
                out.hasHorizontalGap = 1;
                out.gapY = minY;
                out.gapHeight = r.height;
            }
        }
    }
    return out;
}

// Chrome already includes the safe area. Take the max so an island occlusion
// that is already inside safe.top is not double-counted.
static inline ApolloReservedInsets ApolloMediaInsetsUnion(ApolloReservedInsets chrome,
                                                          ApolloReservedAvoidance avoid) {
    return ApolloReservedInsetsUnion(chrome, avoid.edge);
}

// Place a horizontal chrome bar so it does not sit on a vertical hinge strip.
static inline void ApolloReservedPlaceHorizontalBar(double containerWidth,
                                                    double chromeLeft,
                                                    double chromeRight,
                                                    const ApolloReservedAvoidance *avoid,
                                                    double *outX,
                                                    double *outWidth) {
    double x = chromeLeft;
    double width = containerWidth - chromeLeft - chromeRight;
    if (width < 0.0) width = 0.0;
    if (avoid && avoid->hasVerticalGap && avoid->gapWidth > 0.0) {
        double leftWidth = avoid->gapX - chromeLeft;
        double rightStart = avoid->gapX + avoid->gapWidth;
        double rightWidth = (containerWidth - chromeRight) - rightStart;
        const double kMinBar = 80.0;
        if (rightWidth > leftWidth && rightWidth >= kMinBar) {
            x = rightStart;
            width = rightWidth;
        } else if (leftWidth >= kMinBar) {
            x = chromeLeft;
            width = leftWidth;
        }
    }
    if (outX) *outX = x;
    if (outWidth) *outWidth = width > 0.0 ? width : 0.0;
}

// Push `frame` the shortest legal distance so it no longer intersects any
// reserved rect, then clamp it inside the container.
static inline ApolloReservedRect ApolloReservedShiftRect(ApolloReservedRect frame,
                                                         double boundsW,
                                                         double boundsH,
                                                         const ApolloReservedRect *rects,
                                                         unsigned count) {
    if (frame.width <= 0.0 || frame.height <= 0.0 || boundsW <= 0.0 || boundsH <= 0.0) {
        return frame;
    }
    unsigned i;
    for (i = 0; i < count; i++) {
        ApolloReservedRect obstacle = rects[i];
        if (!ApolloReservedRectsIntersect(frame, obstacle)) continue;
        double pushLeft = (frame.x + frame.width) - obstacle.x;
        double pushRight = (obstacle.x + obstacle.width) - frame.x;
        double pushUp = (frame.y + frame.height) - obstacle.y;
        double pushDown = (obstacle.y + obstacle.height) - frame.y;
        if (pushLeft < 0.0) pushLeft = 0.0;
        if (pushRight < 0.0) pushRight = 0.0;
        if (pushUp < 0.0) pushUp = 0.0;
        if (pushDown < 0.0) pushDown = 0.0;

        double best = boundsW + boundsH;
        double dx = 0.0;
        double dy = 0.0;
        if (pushLeft > 0.0 && pushLeft <= best && frame.x - pushLeft >= 0.0) {
            best = pushLeft;
            dx = -pushLeft;
            dy = 0.0;
        }
        if (pushRight > 0.0 && pushRight <= best
            && frame.x + pushRight + frame.width <= boundsW) {
            best = pushRight;
            dx = pushRight;
            dy = 0.0;
        }
        if (pushUp > 0.0 && pushUp <= best && frame.y - pushUp >= 0.0) {
            best = pushUp;
            dx = 0.0;
            dy = -pushUp;
        }
        if (pushDown > 0.0 && pushDown <= best
            && frame.y + pushDown + frame.height <= boundsH) {
            dx = 0.0;
            dy = pushDown;
            (void)best;
        }
        frame.x += dx;
        frame.y += dy;
    }
    if (frame.x < 0.0) frame.x = 0.0;
    if (frame.y < 0.0) frame.y = 0.0;
    if (frame.x + frame.width > boundsW) frame.x = boundsW - frame.width;
    if (frame.y + frame.height > boundsH) frame.y = boundsH - frame.height;
    if (frame.x < 0.0) frame.x = 0.0;
    if (frame.y < 0.0) frame.y = 0.0;
    return frame;
}

// Prefer an even column count when a (possibly inactive) division exists so
// waterfall tiles do not straddle the fold. Never drops below `minCount`.
static inline int ApolloReservedEvenColumnCount(int columns, int minCount, int maxCount,
                                                int hasDivision) {
    if (columns < minCount) columns = minCount;
    if (columns > maxCount) columns = maxCount;
    if (!hasDivision || (columns % 2) == 0) return columns;
    if (columns + 1 <= maxCount) return columns + 1;
    if (columns - 1 >= minCount) return columns - 1;
    return columns;
}

#ifdef __cplusplus
}
#endif

#if defined(__OBJC__) && !defined(APOLLO_DEVICE_RESERVED_REGIONS_C_ONLY)
#import <UIKit/UIKit.h>

__BEGIN_DECLS

/// Active reserved-region rects in `view` coordinates. Always empty:
/// UIKit reservedRegions SIGSEGVs on Duo even with window+scene during
/// first commit. `includeInactive` is kept for the public signature.
NSUInteger ApolloDeviceCopyReservedRectsForView(UIView *view,
                                                CGRect *outRects,
                                                NSUInteger maxCount,
                                                BOOL includeInactive);

/// YES when a division region exists (active or not). Used to keep gallery
/// columns even so tiles do not sit under a known fold.
BOOL ApolloDeviceHasDivisionRegionInView(UIView *view);

/// Safe-area + hinge-sized layout-margin extra. Equals
/// `ApolloDeviceChromeInsetsForView` while reservedRegions is unused.
UIEdgeInsets ApolloDeviceMediaInsetsForView(UIView *view);

/// Avoidance derived from active reserved rects (gaps + edge extras).
/// Zeroed while reservedRegions is unused; chrome/layoutMargins own gutters.
ApolloReservedAvoidance ApolloDeviceReservedAvoidanceForView(UIView *view);

/// Shift `frame` off any active reserved rect in `container`. Returns
/// `frame` unchanged while reservedRegions is unused.
CGRect ApolloDeviceShiftRectOffReservedInView(UIView *container, CGRect frame);

/// Shift `view.frame` off any active reserved rect in its superview.
/// No-op while reservedRegions is unused or the frame is already clear.
void ApolloDeviceAvoidReservedRegionsForView(UIView *view);

/// Place a full-width chrome bar so it does not cover a vertical hinge.
void ApolloDevicePlaceHorizontalBarInView(UIView *view,
                                          CGFloat chromeLeft,
                                          CGFloat chromeRight,
                                          CGFloat *outX,
                                          CGFloat *outWidth);

__END_DECLS
#endif

#endif
