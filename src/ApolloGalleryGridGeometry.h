// Shared, UI-independent geometry for gallery layout and thumbnail preparation.
#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

static CGFloat const kApolloGalleryTileWidths[] = {90.0, 128.0, 185.0, 260.0, 360.0};
static NSString *const kApolloGalleryTileSizeKey = @"ApolloGalleryTileSizeV2";
static NSString *const kApolloGalleryLegacyTileSizeKey = @"ApolloGalleryTileSize";
static NSInteger const kApolloGalleryMinColumns = 1;
enum { kApolloGalleryMaxColumns = 12, kApolloGalleryTileSizeCount = 5 };
static CGFloat const kApolloGalleryTileSpacing = 3.0;
static CGFloat const kApolloGalleryMinAspect = 0.5;
static CGFloat const kApolloGalleryMaxAspect = 2.2;
static CGFloat const kApolloGalleryDefaultAspect = 1.25;

typedef CGSize (^ApolloGalleryGridPixelSizeProvider)(NSUInteger index);

static inline NSInteger ApolloGalleryGridSavedTileSizeIndex(NSUserDefaults *defaults) {
    id saved = [defaults objectForKey:kApolloGalleryTileSizeKey];
    NSInteger index = 2;
    if ([saved isKindOfClass:NSNumber.class]) {
        index = [saved integerValue];
    } else {
        id legacy = [defaults objectForKey:kApolloGalleryLegacyTileSizeKey];
        if ([legacy isKindOfClass:NSNumber.class]) index = MAX(0, MIN(3, [legacy integerValue])) + 1;
    }
    return MAX(0, MIN(kApolloGalleryTileSizeCount - 1, index));
}

static inline NSInteger ApolloGalleryGridColumnCount(CGFloat width, NSInteger tileSizeIndex) {
    if (!isfinite(width) || width <= 0.0) return kApolloGalleryMinColumns;
    NSInteger index = MAX(0, MIN(kApolloGalleryTileSizeCount - 1, tileSizeIndex));
    CGFloat columns = floor((width + kApolloGalleryTileSpacing) /
        (kApolloGalleryTileWidths[index] + kApolloGalleryTileSpacing));
    NSInteger minimum = index > 0 && index < 3 &&
        width >= 2 * kApolloGalleryTileWidths[1] + kApolloGalleryTileSpacing ? 2 : kApolloGalleryMinColumns;
    return MAX(minimum, (NSInteger)MIN(kApolloGalleryMaxColumns, columns));
}

static inline CGFloat ApolloGalleryGridTileWidth(CGFloat width, NSInteger columns) {
    if (!isfinite(width) || width <= 0.0) return 0.0;
    columns = MAX(1, MIN(kApolloGalleryMaxColumns, columns));
    return MAX(0.0, floor((width - kApolloGalleryTileSpacing * (columns - 1)) / columns));
}

static inline CGFloat ApolloGalleryGridAspectForPixelSize(CGSize size) {
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0.0 || size.height <= 0.0) {
        return kApolloGalleryDefaultAspect;
    }
    CGFloat aspect = size.height / size.width;
    return MAX(kApolloGalleryMinAspect, MIN(kApolloGalleryMaxAspect, aspect));
}

typedef struct {
    NSUInteger count;
    CGFloat shortestColumnBottom;
} ApolloGalleryGridMeasurement;

// The same shortest-column choice, tie tolerance, pixel rounding and trailing
// gap as the collection layout. A positive target stops once EVERY column
// covers it; the tallest column alone can conceal large gaps in its neighbors.
static inline ApolloGalleryGridMeasurement ApolloGalleryGridMeasure(NSUInteger itemCount, CGFloat width,
    NSInteger columns, ApolloGalleryGridPixelSizeProvider pixelSizeAtIndex, CGFloat targetHeight) {
    ApolloGalleryGridMeasurement result = {0, 0.0};
    columns = MAX(1, MIN(kApolloGalleryMaxColumns, columns));
    CGFloat tileWidth = ApolloGalleryGridTileWidth(width, columns);
    if (tileWidth <= 0.0) return result;
    CGFloat heights[kApolloGalleryMaxColumns] = {0};
    for (NSUInteger item = 0; item < itemCount; item++) {
        NSInteger shortest = 0;
        for (NSInteger column = 1; column < columns; column++) {
            if (heights[column] < heights[shortest] - 0.5) shortest = column;
        }
        CGSize pixels = pixelSizeAtIndex ? pixelSizeAtIndex(item) : CGSizeZero;
        heights[shortest] += round(tileWidth * ApolloGalleryGridAspectForPixelSize(pixels)) + kApolloGalleryTileSpacing;
        CGFloat bottom = heights[0];
        for (NSInteger column = 1; column < columns; column++) bottom = MIN(bottom, heights[column]);
        result.count = item + 1;
        result.shortestColumnBottom = MAX(0.0, bottom - kApolloGalleryTileSpacing);
        if (targetHeight > 0.0 && result.shortestColumnBottom >= targetHeight) break;
    }
    return result;
}

static inline CGFloat ApolloGalleryGridCoverage(NSUInteger itemCount, CGFloat width, NSInteger columns,
    ApolloGalleryGridPixelSizeProvider pixelSizeAtIndex) {
    return ApolloGalleryGridMeasure(itemCount, width, columns, pixelSizeAtIndex, 0.0).shortestColumnBottom;
}

static inline NSUInteger ApolloGalleryGridWarmPrefixCount(NSUInteger itemCount, CGFloat width,
    CGFloat viewportHeight, NSInteger tileSizeIndex, NSUInteger maximumCount,
    ApolloGalleryGridPixelSizeProvider pixelSizeAtIndex) {
    if (!isfinite(viewportHeight) || viewportHeight <= 0.0) return 0;
    NSInteger columns = ApolloGalleryGridColumnCount(width, tileSizeIndex);
    CGFloat target = viewportHeight + ApolloGalleryGridTileWidth(width, columns);
    return ApolloGalleryGridMeasure(MIN(itemCount, maximumCount), width, columns,
        pixelSizeAtIndex, target).count;
}
