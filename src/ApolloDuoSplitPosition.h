#ifndef APOLLO_DUO_SPLIT_POSITION_H
#define APOLLO_DUO_SPLIT_POSITION_H

#ifdef __cplusplus
extern "C" {
#endif

#include <CoreGraphics/CGBase.h>
#include <math.h>
#include <objc/NSObjCRuntime.h>
#include <stdbool.h>

// Where the Posts split divider rests on Duo's unfolded landscape display: any
// x between a left and a right limit, remembered as a share of the canvas.
// Half (a stored 0) sits at the fold when the hinge reports one, otherwise
// mid-canvas, so it follows the fold wherever the fold is.
typedef struct {
    bool hasShare;       // DuoSplitFeedShare was stored
    double share;        // the divider x over the canvas width; 0 is Half
    NSInteger legacyStop; // the retired DuoSplitStop: 1 was 25%, 3 the widest feed
} ApolloDuoSplitStored;

// What letting go of a drag does: land at `divider`, close the thread, or
// cover the feed with the thread (full width, for this thread only). `share`
// is what to remember for a landing: 0 for Half, else divider over canvas.
// The uncover drag (the divider dragged back from the screen's edge, the post
// over the feed) releases through the same decision: its divider is where
// the picture's edge is let go.
typedef struct {
    CGFloat divider;
    double share;
    bool closesThread;
    bool coversFeed;
} ApolloDuoSplitRelease;

// The feed's cover lasts for the thread it was pulled over, in the unfolded
// landscape split with the setting on. It is never remembered.
typedef struct {
    bool adjustable;  // Adjustable Split on, and the device unfolded
    bool landscape;   // the Posts split has landscape columns
    bool sameThread;  // the thread right above the backstop is the one dragged over the feed
} ApolloDuoSplitCoverFacts;

// Why the cover ends now, or NULL while it holds.
static inline const char *ApolloDuoSplitCoverEndReason(ApolloDuoSplitCoverFacts facts) {
    if (!facts.adjustable) return "the setting is off or the device folded";
    if (!facts.landscape) return "the columns are portrait";
    if (!facts.sameThread) return "the thread closed or another took its place";
    return NULL;
}

enum {
    // Rightward (or leftward) speed that counts as a flick on release.
    ApolloDuoSplitFlickVelocity = 500,
};

// A drag closes or covers the feed once it has covered this share of the
// distance from its limit to the screen edge.
#define APOLLO_DUO_SPLIT_EDGE_COMMIT 0.35

// The feed's least share (its rows are already tight there) and the most the
// thread can give up.
#define APOLLO_DUO_SPLIT_LEFT_SHARE 0.25
#define APOLLO_DUO_SPLIT_RIGHT_SHARE 0.75

// A landing this close to Half is Half. Without it nobody could get back to
// an exact 50/50 on the hinge.
#define APOLLO_DUO_SPLIT_HALF_MAGNET 16.0

static inline CGFloat ApolloDuoSplitHalfDivider(CGFloat canvasWidth, CGFloat foldX) {
    return foldX > 0 ? foldX : canvasWidth * 0.5;
}

static inline CGFloat ApolloDuoSplitLeftLimit(CGFloat canvasWidth) {
    return canvasWidth * APOLLO_DUO_SPLIT_LEFT_SHARE;
}

// Leaves the thread `wideThread` beside the trailing inset (the Duo's rail),
// up to three quarters of the canvas, and never sits left of Half.
// `wideThread` is the width the post's action bar needs, which is more than
// UIKit's own minimum for tiling the thread.
static inline CGFloat ApolloDuoSplitRightLimit(CGFloat canvasWidth, CGFloat foldX,
                                               CGFloat trailingInset, CGFloat wideThread) {
    CGFloat right = canvasWidth * APOLLO_DUO_SPLIT_RIGHT_SHARE;
    CGFloat roomy = canvasWidth - trailingInset - wideThread;
    if (roomy < right) right = roomy;
    CGFloat half = ApolloDuoSplitHalfDivider(canvasWidth, foldX);
    return right > half ? right : half;
}

// Whether there is anywhere but Half to put the divider.
static inline bool ApolloDuoSplitHasRange(CGFloat canvasWidth, CGFloat foldX,
                                          CGFloat trailingInset, CGFloat wideThread) {
    return ApolloDuoSplitRightLimit(canvasWidth, foldX, trailingInset, wideThread)
        > ApolloDuoSplitLeftLimit(canvasWidth);
}

static inline CGFloat ApolloDuoSplitClampedDivider(CGFloat dividerX, CGFloat canvasWidth, CGFloat foldX,
                                                   CGFloat trailingInset, CGFloat wideThread) {
    if (!ApolloDuoSplitHasRange(canvasWidth, foldX, trailingInset, wideThread))
        return ApolloDuoSplitHalfDivider(canvasWidth, foldX);
    CGFloat left = ApolloDuoSplitLeftLimit(canvasWidth);
    CGFloat right = ApolloDuoSplitRightLimit(canvasWidth, foldX, trailingInset, wideThread);
    return dividerX < left ? left : (dividerX > right ? right : dividerX);
}

// The divider x for a stored position, re-clamped on this canvas every time
// so rotation, fold and inset changes stay valid. A share out of range is
// Half; with no stored share the retired stop is read, never written.
static inline CGFloat ApolloDuoSplitDividerForStored(ApolloDuoSplitStored stored, CGFloat canvasWidth,
                                                     CGFloat foldX, CGFloat trailingInset,
                                                     CGFloat wideThread) {
    CGFloat half = ApolloDuoSplitHalfDivider(canvasWidth, foldX);
    if (!ApolloDuoSplitHasRange(canvasWidth, foldX, trailingInset, wideThread)) return half;
    CGFloat divider = half;
    if (stored.hasShare) {
        if (isfinite(stored.share) && stored.share > 0 && stored.share < 1) {
            divider = (CGFloat)stored.share * canvasWidth;
        }
    } else if (stored.legacyStop == 1) {
        divider = ApolloDuoSplitLeftLimit(canvasWidth);
    } else if (stored.legacyStop == 3) {
        divider = ApolloDuoSplitRightLimit(canvasWidth, foldX, trailingInset, wideThread);
    }
    return ApolloDuoSplitClampedDivider(divider, canvasWidth, foldX, trailingInset, wideThread);
}

// The Posts feed column's width in the landscape split. With the setting off
// it is half the canvas, as before the setting existed, whatever was stored.
static inline CGFloat ApolloDuoPostsPrimaryWidth(bool adjustable,
                                                 ApolloDuoSplitStored stored,
                                                 CGFloat canvasWidth,
                                                 CGFloat foldX,
                                                 CGFloat trailingInset,
                                                 CGFloat wideThread) {
    if (!adjustable) return canvasWidth * 0.5;
    return ApolloDuoSplitDividerForStored(stored, canvasWidth, foldX, trailingInset, wideThread);
}

// UIKit tiles the thread beside the feed only while the thread, less its
// trailing safe area (the Duo's rail), keeps the split's minimum secondary
// width. Narrower, it lays the thread out under the feed instead (measured on
// the Duo: a 627 pt feed tiles beside the 84 pt rail inset, 627.67 does not).
static inline bool ApolloDuoSplitDividerFits(CGFloat dividerX, CGFloat canvasWidth,
                                             CGFloat trailingInset, CGFloat minimumThread) {
    return canvasWidth - dividerX - trailingInset >= minimumThread;
}

// The feed width the split can honor: the remembered position, or Half when
// that would leave the thread too narrow to tile (`minimumThread`, UIKit's
// own minimum). A safety net: the right limit leaves the thread more than
// that for the same inset, so this trips only when the inset changes after
// the position was placed, or when nothing fits.
static inline CGFloat ApolloDuoPostsFittedPrimaryWidth(bool adjustable,
                                                       ApolloDuoSplitStored stored,
                                                       CGFloat canvasWidth,
                                                       CGFloat foldX,
                                                       CGFloat trailingInset,
                                                       CGFloat wideThread,
                                                       CGFloat minimumThread) {
    CGFloat width = ApolloDuoPostsPrimaryWidth(adjustable, stored, canvasWidth, foldX,
                                               trailingInset, wideThread);
    if (!adjustable || ApolloDuoSplitDividerFits(width, canvasWidth, trailingInset, minimumThread)) return width;
    return ApolloDuoSplitHalfDivider(canvasWidth, foldX);
}

static inline ApolloDuoSplitRelease ApolloDuoSplitReleaseFor(CGFloat dividerX,
                                                             CGFloat velocityX,
                                                             CGFloat canvasWidth,
                                                             CGFloat foldX,
                                                             CGFloat trailingInset,
                                                             CGFloat wideThread) {
    ApolloDuoSplitRelease release = { 0, 0, false, false };
    // No canvas to speak of, or a position that is not a number: Half, no commit.
    if (!(canvasWidth > 0) || !isfinite(dividerX)) {
        release.divider = ApolloDuoSplitHalfDivider(canvasWidth > 0 ? canvasWidth : 0, foldX);
        return release;
    }
    CGFloat left = ApolloDuoSplitLeftLimit(canvasWidth);
    CGFloat right = ApolloDuoSplitRightLimit(canvasWidth, foldX, trailingInset, wideThread);
    CGFloat half = ApolloDuoSplitHalfDivider(canvasWidth, foldX);
    CGFloat closeAt = right + (canvasWidth - right) * APOLLO_DUO_SPLIT_EDGE_COMMIT;
    CGFloat coverAt = left - left * APOLLO_DUO_SPLIT_EDGE_COMMIT;

    if (dividerX >= closeAt ||
        (velocityX >= ApolloDuoSplitFlickVelocity && dividerX >= right)) {
        release.divider = right;
        release.closesThread = true;
    } else if (dividerX <= coverAt ||
               (velocityX <= -ApolloDuoSplitFlickVelocity && dividerX <= left)) {
        release.divider = left;
        release.coversFeed = true;
    } else {
        CGFloat landed = ApolloDuoSplitClampedDivider(dividerX, canvasWidth, foldX,
                                                      trailingInset, wideThread);
        if (fabs(landed - half) <= APOLLO_DUO_SPLIT_HALF_MAGNET) landed = half;
        release.divider = landed;
        release.share = landed == half ? 0 : landed / canvasWidth;
        return release;
    }
    release.share = canvasWidth > 0 ? release.divider / canvasWidth : 0;
    return release;
}

// Whether a divider dragged to `dividerX` would be let go at Half: the same
// release the finger's lift runs, so the guide at Half lights exactly when
// the magnet would take the divider there. Never with no range to move in.
static inline bool ApolloDuoSplitDividerAtHalf(CGFloat dividerX, CGFloat canvasWidth, CGFloat foldX,
                                               CGFloat trailingInset, CGFloat wideThread) {
    if (!(canvasWidth > 0) || !isfinite(dividerX)) return false;
    if (!ApolloDuoSplitHasRange(canvasWidth, foldX, trailingInset, wideThread)) return false;
    ApolloDuoSplitRelease release = ApolloDuoSplitReleaseFor(dividerX, 0, canvasWidth, foldX,
                                                             trailingInset, wideThread);
    return !release.closesThread && !release.coversFeed && release.share == 0;
}

// The guide at Half lights when the drag is aiming for it, not on a pass
// through: inside the magnet (`inZone`, ApolloDuoSplitDividerAtHalf) and slower
// than this, or in it for this long.
#define APOLLO_DUO_SPLIT_GUIDE_SLOW 150.0
#define APOLLO_DUO_SPLIT_GUIDE_DWELL 0.08

// `speed` is the divider's, pt/s either way; `dwell` the seconds it has been
// inside the magnet. Once lit it stays lit until the divider leaves the
// magnet, so a changing speed inside never toggles it.
static inline bool ApolloDuoSplitGuideLit(bool inZone, CGFloat speed, double dwell, bool wasLit) {
    if (!inZone) return false;
    return wasLit || fabs(speed) < APOLLO_DUO_SPLIT_GUIDE_SLOW || dwell >= APOLLO_DUO_SPLIT_GUIDE_DWELL;
}

#ifdef __cplusplus
}
#endif

#endif
