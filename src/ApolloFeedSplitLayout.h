#ifndef APOLLO_FEED_SPLIT_LAYOUT_H
#define APOLLO_FEED_SPLIT_LAYOUT_H

#ifdef __cplusplus
extern "C" {
#endif

// Size-class feed | comments layout for Regular-width iPhone (Plus/Max
// landscape, Duo inner). C-only so host tests can compile this header
// without UIKit. Values match UIUserInterfaceSizeClass.

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

// Two min-width columns (320+320) plus the gutter, so Regular-but-narrow
// poses (some folds, small Plus widths) stay a single column.
enum {
    ApolloFeedSplitFeedMinWidth = 320,
    ApolloFeedSplitFeedPreferredWidth = 390,
    ApolloFeedSplitFeedMaxWidth = 428,
    ApolloFeedSplitGutterWidth = 12,
    ApolloFeedSplitCenteredMaxWidth = 700,
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

static inline ApolloFeedSplitFrames ApolloFeedSplitFramesMake(double containerWidth,
                                                              double containerHeight,
                                                              double extraLeft,
                                                              double extraRight,
                                                              ApolloFeedSplitMode mode,
                                                              int rightToLeft) {
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
        if (feedWidth > (double)ApolloFeedSplitCenteredMaxWidth) {
            feedWidth = (double)ApolloFeedSplitCenteredMaxWidth;
        }
        frames.feed.x = extraLeft + (usable - feedWidth) * 0.5;
        frames.feed.width = feedWidth;
        frames.feed.height = containerHeight;
        return frames;
    }

    double gutter = (double)ApolloFeedSplitGutterWidth;
    if (gutter > usable) gutter = 0.0;
    double feedWidth = (double)ApolloFeedSplitFeedPreferredWidth;
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
    double detailWidth = usable - feedWidth - gutter;
    if (detailWidth < 0.0) detailWidth = 0.0;

    frames.showsDetail = 1;
    frames.feed.width = feedWidth;
    frames.feed.height = containerHeight;
    frames.detail.width = detailWidth;
    frames.detail.height = containerHeight;
    if (rightToLeft) {
        frames.feed.x = containerWidth - extraRight - feedWidth;
        frames.detail.x = extraLeft;
    } else {
        frames.feed.x = extraLeft;
        frames.detail.x = extraLeft + feedWidth + gutter;
    }
    return frames;
}

#ifdef __cplusplus
}
#endif

#endif
