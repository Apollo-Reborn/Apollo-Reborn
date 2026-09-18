#ifndef APOLLO_FEED_SPLIT_LAYOUT_H
#define APOLLO_FEED_SPLIT_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

// Size-class two-pane layout for Regular-width iPhone (Plus/Max
// landscape, Duo inner). Primary reading pair is feed | comments
// (concept mock). A lone feed/list on a Duo-wide canvas stays in the
// leading half — never a full-bleed column across the hinge.
// list | feed is the My Subreddits picker.
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

// Leading pane for a lone feed/list, or either column of a Duo-wide tile.
// ~50% minus gutter so feed-only, list|feed, and feed|comments share width.
static inline double ApolloFeedSplitLeadingColumnWidth(double usableWidth) {
    double gutter = (double)ApolloFeedSplitGutterWidth;
    double half = (usableWidth - gutter) * 0.5;
    if (half < (double)ApolloFeedSplitFeedMinWidth) {
        half = usableWidth * 0.5;
    }
    if (half < 0.0) half = 0.0;
    if (half > usableWidth) half = usableWidth;
    return half;
}

static inline ApolloFeedSplitTileStyle ApolloFeedSplitTileStyleForPair(int readingPair,
                                                                       double usableWidth) {
    (void)readingPair;
    if (ApolloFeedSplitUsableIsDuoWide(usableWidth)) {
        return ApolloFeedSplitTileBalanced;
    }
    return ApolloFeedSplitTileMaster;
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
    if (mode == ApolloFeedSplitModeStacked || usable <= 0.0) {
        return frames;
    }

    if (mode == ApolloFeedSplitModeCentered) {
        double feedWidth = usable;
        int duoLeading = pinLeading || ApolloFeedSplitUsableIsDuoWide(usable);
        if (duoLeading) {
            feedWidth = ApolloFeedSplitLeadingColumnWidth(usable);
            if (rightToLeft) {
                frames.feed.x = containerWidth - extraRight - feedWidth;
            } else {
                frames.feed.x = extraLeft;
            }
        } else {
            if (feedWidth > (double)ApolloFeedSplitCenteredMaxWidth) {
                feedWidth = (double)ApolloFeedSplitCenteredMaxWidth;
            }
            frames.feed.x = extraLeft + (usable - feedWidth) * 0.5;
        }
        frames.feed.width = feedWidth;
        frames.feed.height = containerHeight;
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
    return frames;
}

#ifdef __cplusplus
}
#endif

#if defined(__OBJC__)
#import <UIKit/UIKit.h>

__BEGIN_DECLS
/// Instant list|feed (or list-only leading) for the Subs rail. No UIKit
/// push animation and a single FeedSplit apply — avoids hinge width thrash.
void ApolloFeedSplitShowSubredditPicker(UINavigationController *nav);
__END_DECLS
#endif

#endif
