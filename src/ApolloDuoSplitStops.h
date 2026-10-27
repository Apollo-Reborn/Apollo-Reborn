#ifndef APOLLO_DUO_SPLIT_STOPS_H
#define APOLLO_DUO_SPLIT_STOPS_H

#ifdef __cplusplus
extern "C" {
#endif

#include <CoreGraphics/CGBase.h>
#include <objc/NSObjCRuntime.h>
#include <stdbool.h>

// Where the Posts split divider can rest on Duo's unfolded landscape display.
// Quarter and Half are the feed's share of the canvas; Wide is the widest
// feed that keeps the thread tiled beside it and its post actions visible,
// at most three quarters. Stored
// as an integer (3 was the old three quarters stop, so nothing migrates).
typedef enum {
    ApolloDuoSplitStopFeedQuarter = 1,
    ApolloDuoSplitStopHalf = 2,
    ApolloDuoSplitStopFeedWide = 3,
} ApolloDuoSplitStop;

// What letting go of a drag does: land on a stop, close the thread, or give
// the thread the whole screen.
typedef struct {
    ApolloDuoSplitStop stop;
    bool closesThread;
    bool fullScreen;
} ApolloDuoSplitRelease;

enum {
    // Rightward (or leftward) speed that counts as a flick on release.
    ApolloDuoSplitFlickVelocity = 500,
};

// A drag closes or expands once it has covered this share of the distance
// from the outer stop to the screen edge.
#define APOLLO_DUO_SPLIT_EDGE_COMMIT 0.35

static inline ApolloDuoSplitStop ApolloDuoSplitStopSanitized(NSInteger stored) {
    if (stored == ApolloDuoSplitStopFeedQuarter ||
        stored == ApolloDuoSplitStopFeedWide) {
        return (ApolloDuoSplitStop)stored;
    }
    return ApolloDuoSplitStopHalf;
}

// Half sits at the fold when the hinge reports one, otherwise mid-canvas.
// Wide leaves the thread `wideThread` beside the trailing inset (the Duo's
// rail), up to three quarters of the canvas, and never sits left of Half.
// `wideThread` is the width the post's action bar needs, which is more than
// UIKit's own minimum for tiling the thread.
static inline CGFloat ApolloDuoSplitStopDivider(ApolloDuoSplitStop stop,
                                                CGFloat canvasWidth,
                                                CGFloat foldX,
                                                CGFloat trailingInset,
                                                CGFloat wideThread) {
    CGFloat half = foldX > 0 ? foldX : canvasWidth * 0.5;
    switch (ApolloDuoSplitStopSanitized(stop)) {
        case ApolloDuoSplitStopFeedQuarter: return canvasWidth * 0.25;
        case ApolloDuoSplitStopFeedWide: {
            CGFloat wide = canvasWidth * 0.75;
            CGFloat roomy = canvasWidth - trailingInset - wideThread;
            if (roomy < wide) wide = roomy;
            return wide > half ? wide : half;
        }
        default: return half;
    }
}

// The Posts feed column's width in the landscape split. With the setting off
// it is half the canvas, as before the setting existed, whatever the stop.
static inline CGFloat ApolloDuoPostsPrimaryWidth(bool adjustable,
                                                 ApolloDuoSplitStop stop,
                                                 CGFloat canvasWidth,
                                                 CGFloat foldX,
                                                 CGFloat trailingInset,
                                                 CGFloat wideThread) {
    if (!adjustable) return canvasWidth * 0.5;
    return ApolloDuoSplitStopDivider(stop, canvasWidth, foldX, trailingInset, wideThread);
}

// UIKit tiles the thread beside the feed only while the thread, less its
// trailing safe area (the Duo's rail), keeps the split's minimum secondary
// width. Narrower, it lays the thread out under the feed instead (measured on
// the Duo: a 627 pt feed tiles beside the 84 pt rail inset, 627.67 does not).
static inline bool ApolloDuoSplitStopFits(CGFloat dividerX, CGFloat canvasWidth,
                                          CGFloat trailingInset, CGFloat minimumThread) {
    return canvasWidth - dividerX - trailingInset >= minimumThread;
}

// The feed width the split can honor: the remembered stop, or Half when that
// stop would leave the thread too narrow to tile (`minimumThread`, UIKit's
// own minimum). A safety net: Wide leaves the thread more than that for the
// same inset, so this trips only when the inset changes after the stop was
// placed, or when no stop fits.
static inline CGFloat ApolloDuoPostsFittedPrimaryWidth(bool adjustable,
                                                       ApolloDuoSplitStop stop,
                                                       CGFloat canvasWidth,
                                                       CGFloat foldX,
                                                       CGFloat trailingInset,
                                                       CGFloat wideThread,
                                                       CGFloat minimumThread) {
    CGFloat width = ApolloDuoPostsPrimaryWidth(adjustable, stop, canvasWidth, foldX,
                                               trailingInset, wideThread);
    if (!adjustable || ApolloDuoSplitStopFits(width, canvasWidth, trailingInset, minimumThread)) return width;
    return ApolloDuoSplitStopDivider(ApolloDuoSplitStopHalf, canvasWidth, foldX,
                                     trailingInset, wideThread);
}

static inline ApolloDuoSplitStop ApolloDuoSplitStopNearest(CGFloat dividerX,
                                                           CGFloat canvasWidth,
                                                           CGFloat foldX,
                                                           CGFloat trailingInset,
                                                           CGFloat wideThread) {
    ApolloDuoSplitStop best = ApolloDuoSplitStopHalf;
    CGFloat bestDistance = -1;
    for (int stop = ApolloDuoSplitStopFeedQuarter;
         stop <= ApolloDuoSplitStopFeedWide; stop++) {
        CGFloat distance = ApolloDuoSplitStopDivider((ApolloDuoSplitStop)stop, canvasWidth, foldX,
                                                      trailingInset, wideThread) - dividerX;
        if (distance < 0) distance = -distance;
        if (bestDistance < 0 || distance < bestDistance) {
            bestDistance = distance;
            best = (ApolloDuoSplitStop)stop;
        }
    }
    return best;
}

static inline ApolloDuoSplitRelease ApolloDuoSplitReleaseFor(CGFloat dividerX,
                                                             CGFloat velocityX,
                                                             CGFloat canvasWidth,
                                                             CGFloat foldX,
                                                             CGFloat trailingInset,
                                                             CGFloat wideThread) {
    ApolloDuoSplitRelease release = { ApolloDuoSplitStopHalf, false, false };
    CGFloat rightStop = ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedWide, canvasWidth, foldX,
                                                  trailingInset, wideThread);
    CGFloat leftStop = ApolloDuoSplitStopDivider(ApolloDuoSplitStopFeedQuarter, canvasWidth, foldX,
                                                 trailingInset, wideThread);
    CGFloat closeAt = rightStop + (canvasWidth - rightStop) * APOLLO_DUO_SPLIT_EDGE_COMMIT;
    CGFloat fullScreenAt = leftStop - leftStop * APOLLO_DUO_SPLIT_EDGE_COMMIT;

    if (dividerX >= closeAt ||
        (velocityX >= ApolloDuoSplitFlickVelocity && dividerX >= rightStop)) {
        release.stop = ApolloDuoSplitStopFeedWide;
        release.closesThread = true;
    } else if (dividerX <= fullScreenAt ||
               (velocityX <= -ApolloDuoSplitFlickVelocity && dividerX <= leftStop)) {
        release.stop = ApolloDuoSplitStopFeedQuarter;
        release.fullScreen = true;
    } else {
        release.stop = ApolloDuoSplitStopNearest(dividerX, canvasWidth, foldX,
                                                  trailingInset, wideThread);
    }
    return release;
}

#ifdef __cplusplus
}
#endif

#endif
