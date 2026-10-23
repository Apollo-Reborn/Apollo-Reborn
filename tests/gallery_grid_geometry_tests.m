#import <Foundation/Foundation.h>
#import "ApolloGalleryGridGeometry.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        for (NSNumber *width in @[@375, @390, @402, @430]) {
            Check(ApolloGalleryGridColumnCount(width.doubleValue, 0) == 4,
                  @"smallest preset has four columns on common phone widths");
        }
        Check(ApolloGalleryGridColumnCount(402, 1) == 3 &&
              ApolloGalleryGridColumnCount(402, 2) == 2 &&
              ApolloGalleryGridColumnCount(402, 3) == 1, @"existing phone presets retain their columns");
        Check(ApolloGalleryGridColumnCount(320, 2) == 2, @"narrow phones preserve the two-column default");
        Check(ApolloGalleryGridColumnCount(100000, 0) == 12, @"column count remains bounded");
        Check(ApolloGalleryGridColumnCount(0, 0) == 1 && ApolloGalleryGridColumnCount(NAN, 0) == 1,
              @"unlaid-out viewport has a safe column fallback");
        Check(ApolloGalleryGridTileWidth(402, 4) == 98 && ApolloGalleryGridTileWidth(402, 2) == 199,
              @"tile widths include gaps and floor to the exact layout geometry");
        Check(ApolloGalleryGridAspectForPixelSize(CGSizeZero) == 1.25 &&
              ApolloGalleryGridAspectForPixelSize(CGSizeMake(NAN, 1)) == 1.25,
              @"missing or invalid dimensions use the layout default");
        Check(ApolloGalleryGridAspectForPixelSize(CGSizeMake(1000, 1)) == .5 &&
              ApolloGalleryGridAspectForPixelSize(CGSizeMake(1, 1000)) == 2.2,
              @"extreme aspect ratios share the layout clamps");

        ApolloGalleryGridPixelSizeProvider landscape = ^CGSize(NSUInteger index) {
            (void)index; return CGSizeMake(1000, 500);
        };
        ApolloGalleryGridPixelSizeProvider square = ^CGSize(NSUInteger index) {
            (void)index; return CGSizeMake(100, 100);
        };
        Check(ApolloGalleryGridCoverage(24, 402, 4, landscape) == 309,
              @"24 landscape tiles only cover 309 points, reproducing the half-screen gap");
        Check(ApolloGalleryGridCoverage(3, 402, 4, landscape) == 0,
              @"one uncovered column prevents reporting a filled viewport");
        Check(ApolloGalleryGridCoverage(24, 402, 4, square) == 603,
              @"coverage excludes the last trailing gap");
        NSUInteger widePrefix = ApolloGalleryGridWarmPrefixCount(120, 402, 700, 0, 96, landscape);
        Check(widePrefix == 64, @"four-column landscape warming covers the viewport plus a row");
        Check(ApolloGalleryGridCoverage(widePrefix, 402, 4, landscape) >= 798 &&
              ApolloGalleryGridCoverage(widePrefix - 1, 402, 4, landscape) < 798,
              @"warming stops at the first prefix that covers every column");
        Check(ApolloGalleryGridWarmPrefixCount(120, 402, 700, 0, 96, square) == 32,
              @"square thumbnails require a smaller measured prefix");
        Check(ApolloGalleryGridWarmPrefixCount(120, 402, 700, 0, 96, nil) == 28,
              @"unknown sizes use the same default aspect as the grid");
        Check(ApolloGalleryGridWarmPrefixCount(120, 402, 700, 2, 96, nil) == 8,
              @"two-column warming avoids an unnecessary 24-image batch");
        Check(ApolloGalleryGridWarmPrefixCount(12, 402, 700, 0, 96, landscape) == 12,
              @"short source listings warm all available items without inventing coverage");
        Check(ApolloGalleryGridWarmPrefixCount(1000, 402, 2000, 0, 96, landscape) == 96,
              @"large viewports still honor the speculative-work cap");
        Check(ApolloGalleryGridWarmPrefixCount(120, 0, 700, 0, 96, landscape) == 0 &&
              ApolloGalleryGridWarmPrefixCount(120, 402, 0, 0, 96, landscape) == 0,
              @"unlaid-out views do not start speculative loads");
        __block NSUInteger calls = 0;
        ApolloGalleryGridMeasurement early = ApolloGalleryGridMeasure(10000, 402, 4, ^CGSize(NSUInteger index) {
            calls++; return landscape(index);
        }, 700);
        Check(early.count == 56 && calls == 56 && early.shortestColumnBottom == 725,
              @"viewport coverage stops scanning a long feed once the target is reached");
        CGFloat ratios[] = {2, .5, 1, .5, 1};
        CGFloat *ratioValues = ratios;
        Check(ApolloGalleryGridCoverage(5, 402, 2, ^CGSize(NSUInteger index) {
            return CGSizeMake(100, 100 * ratioValues[index]);
        }) == 405, @"mixed aspect ratios use shortest-column placement rather than average rows");

        NSString *suite = [@"ApolloGalleryGeometryTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Check(ApolloGalleryGridSavedTileSizeIndex(defaults) == 2, @"unset size retains the two-column default");
        for (NSInteger old = 0; old < 4; old++) {
            [defaults setInteger:old forKey:kApolloGalleryLegacyTileSizeKey];
            Check(ApolloGalleryGridSavedTileSizeIndex(defaults) == old + 1,
                  @"legacy size migration preserves the selected width");
        }
        [defaults setInteger:0 forKey:kApolloGalleryTileSizeKey];
        Check(ApolloGalleryGridSavedTileSizeIndex(defaults) == 0, @"new preference takes precedence over legacy value");
        [defaults setInteger:99 forKey:kApolloGalleryTileSizeKey];
        Check(ApolloGalleryGridSavedTileSizeIndex(defaults) == 4, @"invalid saved indices are clamped");
        [defaults removePersistentDomainForName:suite];
        printf("gallery_grid_geometry_tests: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
