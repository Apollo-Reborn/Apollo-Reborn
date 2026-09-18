#ifndef APOLLO_FEED_SPLIT_LAYOUT_H
#define APOLLO_FEED_SPLIT_LAYOUT_H

#include "ApolloDuoRailLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

// Historical two-pane *math* for host tests. Runtime tiling is disabled
// (`ApolloFeedSplitEnabled` is NO): open Duo uses the slim rail + stock
// navigation. Do not call these frames from viewDidLayout to pin columns.
// C-only so host tests can compile this header without UIKit.

enum {
    ApolloFeedSplitSizeClassUnspecified = 0,
    ApolloFeedSplitSizeClassCompact = 1,
    ApolloFeedSplitSizeClassRegular = 2,
};

typedef enum {
    ApolloFeedSplitModeStacked = 0,
    ApolloFeedSplitModeCentered = 1,
    ApolloFeedSplitModeTiled = 2,
} ApolloFeedSplitMode;

// Master = phone-width leading column (list | feed). Balanced = the
// mock's book split (feed | comments) on a wide inner canvas.
typedef enum {
    ApolloFeedSplitTileMaster = 0,
    ApolloFeedSplitTileBalanced = 1,
} ApolloFeedSplitTileStyle;

// Two min-width columns (320+320) plus the gutter, so Regular-but-narrow
// poses (some folds, small Plus widths) stay a single column.
enum {
    ApolloFeedSplitFeedMinWidth = 320,
    ApolloFeedSplitFeedPreferredWidth = 390,
    ApolloFeedSplitFeedMaxWidth = 428,
    ApolloFeedSplitGutterWidth = 12,
    ApolloFeedSplitCenteredMaxWidth = 700,
    ApolloFeedSplitBalancedMinWidth = 800, /* mock 50/50; feed-only pins leading */
    ApolloFeedSplitMinRegularWidth =
        ApolloFeedSplitFeedMinWidth + ApolloFeedSplitGutterWidth + ApolloFeedSplitFeedMinWidth,
};

typedef struct {
    double x;
    double y;
    double width;
    double height;
} ApolloFeedSplitRect;

typedef struct {
    ApolloFeedSplitRect feed;
    ApolloFeedSplitRect detail;
    int showsDetail;
} ApolloFeedSplitFrames;

static inline double ApolloFeedSplitUsableWidth(double containerWidth,
                                                double extraLeft,
                                                double extraRight) {
    if (extraLeft < 0.0) extraLeft = 0.0;
    if (extraRight < 0.0) extraRight = 0.0;
    double usable = containerWidth - extraLeft - extraRight;
    return usable > 0.0 ? usable : 0.0;
}

static inline ApolloFeedSplitMode ApolloFeedSplitModeForTraits(int horizontalSizeClass,
                                                               double usableWidth,
                                                               int hasDetail) {
    if (horizontalSizeClass != ApolloFeedSplitSizeClassRegular) {
        return ApolloFeedSplitModeStacked;
    }
    if (usableWidth + 0.5 < (double)ApolloFeedSplitMinRegularWidth) {
        return ApolloFeedSplitModeStacked;
    }
    return hasDetail ? ApolloFeedSplitModeTiled : ApolloFeedSplitModeCentered;
}

static inline int ApolloFeedSplitUsableIsDuoWide(double usableWidth) {
    return usableWidth + 0.5 >= (double)ApolloFeedSplitBalancedMinWidth;
}

// Geometric hinge: mid of the *container*, not mid of already-shrunk usable.
static inline double ApolloFeedSplitContainerMidX(double containerWidth) {
    return containerWidth * 0.5;
}

// extraLeft is chrome only. The slim Duo rail sits on the *trailing*
// edge (system controls are hardcoded there), so rail width belongs
// in extraRight via TrailingExtra — never under the left pane.
static inline double ApolloFeedSplitLeadingExtra(double chromeExtra, int railActive) {
    (void)railActive;
    if (chromeExtra < 0.0) chromeExtra = 0.0;
    return chromeExtra;
}

static inline double ApolloFeedSplitTrailingExtra(double chromeExtra, int railActive) {
    if (chromeExtra < 0.0) chromeExtra = 0.0;
    double rail = railActive ? (double)ApolloDuoRailWidth : 0.0;
    return chromeExtra > rail ? chromeExtra : rail;
}

// Rail / chrome start for the left pane. A fat margin that already
// *is* the leading half is not stacked again. A slim left chrome
// inset must still shift content, even on Plus widths where
// extraLeft + minColumn > mid.
static inline double ApolloFeedSplitBookStart(double containerWidth, double extraLeft) {
    if (extraLeft < 0.0) extraLeft = 0.0;
    double mid = ApolloFeedSplitContainerMidX(containerWidth);
    if (extraLeft + (double)ApolloFeedSplitFeedMinWidth > mid) {
        if (extraLeft + 0.5 < (double)ApolloFeedSplitFeedMinWidth && extraLeft < mid) {
            return extraLeft;
        }
        return 0.0;
    }
    return extraLeft;
}

// Trailing book edge. Same slim-rail exception as BookStart: extraRight
// of 64 on a 736pt canvas would otherwise collapse (64+320 > mid).
static inline double ApolloFeedSplitBookEnd(double containerWidth, double extraRight) {
    if (extraRight < 0.0) extraRight = 0.0;
    double mid = ApolloFeedSplitContainerMidX(containerWidth);
    if (extraRight + (double)ApolloFeedSplitFeedMinWidth > mid) {
        if (extraRight + 0.5 < (double)ApolloFeedSplitFeedMinWidth && extraRight < mid) {
            return containerWidth - extraRight;
        }
        return containerWidth;
    }
    return containerWidth - extraRight;
}

// Left physical pane: book start → container mid − half gutter.
static inline double ApolloFeedSplitLeadingColumnWidth(double containerWidth, double extraLeft) {
    double start = ApolloFeedSplitBookStart(containerWidth, extraLeft);
    double mid = ApolloFeedSplitContainerMidX(containerWidth);
    double gutter = (double)ApolloFeedSplitGutterWidth * 0.5;
    double width = mid - start - gutter;
    if (width < 0.0) width = 0.0;
    return width;
}

static inline ApolloFeedSplitTileStyle ApolloFeedSplitTileStyleForPair(int readingPair,
                                                                       double usableWidth) {
    (void)readingPair;
    if (ApolloFeedSplitUsableIsDuoWide(usableWidth)) {
        return ApolloFeedSplitTileBalanced;
    }
    return ApolloFeedSplitTileMaster;
}

// True if rect crosses the container mid (hinge). Used to refuse full-bleed.
static inline int ApolloFeedSplitRectSpansMidX(ApolloFeedSplitRect rect, double midX) {
    if (rect.width <= 0.0) return 0;
    double maxX = rect.x + rect.width;
    return rect.x + 0.5 < midX && maxX > midX + 0.5;
}

// Clamp a column into the leading half (maxX <= mid) or trailing half (minX >= mid).
static inline ApolloFeedSplitRect ApolloFeedSplitClampRectToHalf(ApolloFeedSplitRect rect,
                                                                double containerWidth,
                                                                double containerHeight,
                                                                int trailing) {
    double mid = ApolloFeedSplitContainerMidX(containerWidth);
    double halfGutter = (double)ApolloFeedSplitGutterWidth * 0.5;
    ApolloFeedSplitRect out = rect;
    out.y = 0.0;
    out.height = containerHeight > 0.0 ? containerHeight : 0.0;
    if (trailing) {
        double minX = mid + halfGutter;
        if (out.x < minX) {
            out.width -= (minX - out.x);
            out.x = minX;
        }
        if (out.x + out.width > containerWidth) {
            out.width = containerWidth - out.x;
        }
    } else {
        double maxX = mid - halfGutter;
        if (out.x < 0.0) {
            out.width += out.x;
            out.x = 0.0;
        }
        if (out.x + out.width > maxX) {
            out.width = maxX - out.x;
        }
    }
    if (out.width < 0.0) out.width = 0.0;
    return out;
}

// Same half clamp, then honor book start/end so a trailing rail is not
// covered when a full-bleed column is forced into the right pane.
static inline ApolloFeedSplitRect ApolloFeedSplitClampRectToHalfInsets(ApolloFeedSplitRect rect,
                                                                      double containerWidth,
                                                                      double containerHeight,
                                                                      int trailing,
                                                                      double extraLeft,
                                                                      double extraRight) {
    ApolloFeedSplitRect out = ApolloFeedSplitClampRectToHalf(rect, containerWidth,
                                                            containerHeight, trailing);
    if (trailing) {
        double maxX = ApolloFeedSplitBookEnd(containerWidth, extraRight);
        if (out.x + out.width > maxX) {
            out.width = maxX - out.x;
        }
    } else {
        double minX = ApolloFeedSplitBookStart(containerWidth, extraLeft);
        if (out.x < minX) {
            out.width -= (minX - out.x);
            out.x = minX;
        }
    }
    if (out.width < 0.0) out.width = 0.0;
    return out;
}

static inline ApolloFeedSplitFrames ApolloFeedSplitFramesMake(double containerWidth,
                                                              double containerHeight,
                                                              double extraLeft,
                                                              double extraRight,
                                                              ApolloFeedSplitMode mode,
                                                              int rightToLeft,
                                                              ApolloFeedSplitTileStyle tileStyle,
                                                              double hingeGapX,
                                                              double hingeGapWidth,
                                                              int pinLeading) {
    ApolloFeedSplitFrames frames;
    frames.feed.x = 0.0;
    frames.feed.y = 0.0;
    frames.feed.width = containerWidth > 0.0 ? containerWidth : 0.0;
    frames.feed.height = containerHeight > 0.0 ? containerHeight : 0.0;
    frames.detail.x = 0.0;
    frames.detail.y = 0.0;
    frames.detail.width = 0.0;
    frames.detail.height = 0.0;
    frames.showsDetail = 0;

    if (containerWidth <= 0.0 || containerHeight <= 0.0) {
        return frames;
    }
    if (extraLeft < 0.0) extraLeft = 0.0;
    if (extraRight < 0.0) extraRight = 0.0;

    double usable = ApolloFeedSplitUsableWidth(containerWidth, extraLeft, extraRight);
    // pinLeading (Duo rail / force latch): never honor Stacked full-bleed —
    // treat it as Centered so a lone feed/list stays in the leading half.
    if (pinLeading && mode == ApolloFeedSplitModeStacked) {
        mode = ApolloFeedSplitModeCentered;
    }
    if (mode == ApolloFeedSplitModeStacked || usable <= 0.0) {
        return frames;
    }

    int bookSplit = pinLeading || ApolloFeedSplitUsableIsDuoWide(usable);
    double mid = ApolloFeedSplitContainerMidX(containerWidth);
    double halfGutter = (double)ApolloFeedSplitGutterWidth * 0.5;
    double bookStart = ApolloFeedSplitBookStart(containerWidth, extraLeft);
    double bookEnd = ApolloFeedSplitBookEnd(containerWidth, extraRight);

    if (mode == ApolloFeedSplitModeCentered) {
        double feedWidth = usable;
        if (bookSplit) {
            feedWidth = ApolloFeedSplitLeadingColumnWidth(containerWidth, extraLeft);
            if (rightToLeft) {
                frames.feed.x = mid + halfGutter;
                frames.feed.width = bookEnd - frames.feed.x;
            } else {
                frames.feed.x = bookStart;
                frames.feed.width = feedWidth;
            }
            if (frames.feed.width < 0.0) frames.feed.width = 0.0;
        } else {
            if (feedWidth > (double)ApolloFeedSplitCenteredMaxWidth) {
                feedWidth = (double)ApolloFeedSplitCenteredMaxWidth;
            }
            frames.feed.x = extraLeft + (usable - feedWidth) * 0.5;
            frames.feed.width = feedWidth;
        }
        frames.feed.height = containerHeight;
        if (pinLeading || bookSplit) {
            frames.feed = ApolloFeedSplitClampRectToHalf(frames.feed, containerWidth,
                                                        containerHeight, rightToLeft ? 1 : 0);
        }
        return frames;
    }

    double gutter = (double)ApolloFeedSplitGutterWidth;
    double feedWidth = 0.0;
    double detailWidth = 0.0;

    if (hingeGapWidth > 0.0
        && hingeGapX > extraLeft
        && hingeGapX + hingeGapWidth < containerWidth - extraRight) {
        gutter = hingeGapWidth;
        feedWidth = hingeGapX - extraLeft;
        detailWidth = (containerWidth - extraRight) - (hingeGapX + hingeGapWidth);
        if (feedWidth < (double)ApolloFeedSplitFeedMinWidth
            || detailWidth < (double)ApolloFeedSplitFeedMinWidth) {
            hingeGapWidth = 0.0;
        }
    }

    if (hingeGapWidth <= 0.0 && (pinLeading || tileStyle == ApolloFeedSplitTileBalanced)) {
        frames.showsDetail = 1;
        frames.feed.height = containerHeight;
        frames.detail.height = containerHeight;
        if (rightToLeft) {
            frames.feed.x = mid + halfGutter;
            frames.feed.width = bookEnd - frames.feed.x;
            frames.detail.x = bookStart;
            frames.detail.width = mid - halfGutter - bookStart;
        } else {
            frames.feed.x = bookStart;
            frames.feed.width = mid - halfGutter - bookStart;
            frames.detail.x = mid + halfGutter;
            frames.detail.width = bookEnd - frames.detail.x;
        }
        if (frames.feed.width < 0.0) frames.feed.width = 0.0;
        if (frames.detail.width < 0.0) frames.detail.width = 0.0;
        if (pinLeading || bookSplit) {
            frames.feed = ApolloFeedSplitClampRectToHalf(frames.feed, containerWidth,
                                                        containerHeight, rightToLeft ? 1 : 0);
            frames.detail = ApolloFeedSplitClampRectToHalf(frames.detail, containerWidth,
                                                          containerHeight, rightToLeft ? 0 : 1);
        }
        return frames;
    }

    if (hingeGapWidth <= 0.0) {
        if (gutter > usable) gutter = 0.0;
        if (tileStyle == ApolloFeedSplitTileBalanced) {
            feedWidth = (usable - gutter) * 0.5;
            if (feedWidth < 0.0) feedWidth = 0.0;
        } else {
            feedWidth = (double)ApolloFeedSplitFeedPreferredWidth;
            if (feedWidth > (double)ApolloFeedSplitFeedMaxWidth) {
                feedWidth = (double)ApolloFeedSplitFeedMaxWidth;
            }
            if (feedWidth < (double)ApolloFeedSplitFeedMinWidth) {
                feedWidth = (double)ApolloFeedSplitFeedMinWidth;
            }
            double maxFeed = usable - gutter - (double)ApolloFeedSplitFeedMinWidth;
            if (maxFeed < (double)ApolloFeedSplitFeedMinWidth) {
                feedWidth = (usable - gutter) * 0.5;
                if (feedWidth < 0.0) feedWidth = 0.0;
            } else if (feedWidth > maxFeed) {
                feedWidth = maxFeed;
            }
        }
        detailWidth = usable - feedWidth - gutter;
        if (detailWidth < 0.0) detailWidth = 0.0;
    }

    frames.showsDetail = 1;
    frames.feed.width = feedWidth;
    frames.feed.height = containerHeight;
    frames.detail.width = detailWidth;
    frames.detail.height = containerHeight;
    if (rightToLeft) {
        frames.feed.x = containerWidth - extraRight - feedWidth;
        frames.detail.x = extraLeft;
    } else if (hingeGapWidth > 0.0) {
        frames.feed.x = extraLeft;
        frames.detail.x = hingeGapX + hingeGapWidth;
    } else {
        frames.feed.x = extraLeft;
        frames.detail.x = extraLeft + feedWidth + gutter;
    }

    // Duo / rail: refuse any column that still spans the hinge.
    if (pinLeading || ApolloFeedSplitUsableIsDuoWide(usable)) {
        double mid = ApolloFeedSplitContainerMidX(containerWidth);
        if (ApolloFeedSplitRectSpansMidX(frames.feed, mid)) {
            frames.feed = ApolloFeedSplitClampRectToHalf(frames.feed, containerWidth,
                                                        containerHeight, rightToLeft ? 1 : 0);
        }
        if (frames.showsDetail && ApolloFeedSplitRectSpansMidX(frames.detail, mid)) {
            frames.detail = ApolloFeedSplitClampRectToHalf(frames.detail, containerWidth,
                                                          containerHeight, rightToLeft ? 0 : 1);
        }
        // Lone centered feed must stay leading (LTR) / trailing (RTL).
        if (!frames.showsDetail && mode == ApolloFeedSplitModeCentered) {
            frames.feed = ApolloFeedSplitClampRectToHalf(frames.feed, containerWidth,
                                                        containerHeight, rightToLeft ? 1 : 0);
        }
    }
    return frames;
}

#ifdef __cplusplus
}
#endif

#if defined(__OBJC__)
#import <UIKit/UIKit.h>

__BEGIN_DECLS
/// Runtime column tiling. Always NO after the architecture reset.
BOOL ApolloFeedSplitEnabled(void);

/// Subs rail: stock popToRoot onto RedditList. Does not tile list|feed.
void ApolloFeedSplitShowSubredditPicker(UINavigationController *nav);

/// No-ops. Kept so older media/rail call sites compile.
void ApolloFeedSplitReapplyVisible(void);
void ApolloFeedSplitForceTiledForSeconds(NSTimeInterval seconds);
BOOL ApolloFeedSplitForceTiledActive(void);
void ApolloFeedSplitReapplySoon(void);
__END_DECLS
#endif

#endif
