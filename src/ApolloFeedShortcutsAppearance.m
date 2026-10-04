#import "ApolloFeedShortcutsAppearance.h"

#include <math.h>
#include <stdlib.h>

#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
#import "palhome/ApolloPalHomeStore.h"

// Index 4 is Pal Home (Reborn's own; no native row).
static const NSInteger kApolloFeedShortcutCount = 5;
static NSString * const kApolloFeedShortcutShortTitles[] = {
    @"Home", @"Popular", @"All", @"Moderator", @"Pals" // one word, like its neighbours
};
static NSString * const kApolloFeedShortcutRowTitles[] = {
    @"Home", @"Popular Posts", @"All Posts", @"Moderator Posts", @"Pal Home"
};
static NSString * const kApolloFeedShortcutDetails[] = {
    @"Posts from subscriptions",
    @"Most popular across Reddit",
    @"Posts across all subreddits",
    @"Posts from moderated subreddits",
    @"Your Pals' cosy home"
};

static BOOL ApolloFeedShortcutIsFiveUpGrid(ApolloSubredditFeedLayout layout, NSUInteger itemCount);

NSArray<UIView *> *ApolloFeedShortcutInstallLayout(UIView *hostView,
                                                    NSArray<UIView *> *items,
                                                    NSArray<UIView *> *contentViews,
                                                    NSArray<NSLayoutConstraint *> *contentCenterXConstraints,
                                                    ApolloSubredditFeedLayout layout,
                                                    UIColor *separatorColor,
                                                    CGFloat stackHorizontalOffset) {
    // Five side by side won't fit a phone: two lines (3 + 2), each laid out
    // like its own strip in half the height.
    if (ApolloFeedShortcutSplitsOntoTwoLines(layout, items.count)) {
        NSUInteger topCount = (items.count + 1) / 2;
        UIView *top = [UIView new], *bottom = [UIView new];
        NSMutableArray<UIView *> *separators = [NSMutableArray array];
        for (UIView *line in @[top, bottom]) {
            line.translatesAutoresizingMaskIntoConstraints = NO;
            [hostView addSubview:line];
            [NSLayoutConstraint activateConstraints:@[
                [line.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
                [line.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
                [line.heightAnchor constraintEqualToAnchor:hostView.heightAnchor multiplier:0.5]
            ]];
        }
        [top.topAnchor constraintEqualToAnchor:hostView.topAnchor].active = YES;
        [bottom.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor].active = YES;
        NSRange ranges[2] = {NSMakeRange(0, topCount), NSMakeRange(topCount, items.count - topCount)};
        UIView *lines[2] = {top, bottom};
        for (int i = 0; i < 2; i++) {
            [separators addObjectsFromArray:ApolloFeedShortcutInstallLayout(lines[i],
                [items subarrayWithRange:ranges[i]], [contentViews subarrayWithRange:ranges[i]],
                [contentCenterXConstraints subarrayWithRange:ranges[i]], layout, separatorColor, stackHorizontalOffset)];
        }
        return separators;
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:items];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 0.0;
    [hostView addSubview:stack];
    BOOL fiveUpGrid = ApolloFeedShortcutIsFiveUpGrid(layout, items.count);
    CGFloat horizontalInset = layout == ApolloSubredditFeedLayoutIconDock ? 28.0 : fiveUpGrid ? 4.0 : 14.0;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor
                                             constant:horizontalInset + stackHorizontalOffset],
        [stack.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor
                                              constant:-horizontalInset + stackHorizontalOffset],
        [stack.topAnchor constraintEqualToAnchor:hostView.topAnchor constant:8.0],
        [stack.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor constant:-8.0]
    ]];

    if (layout == ApolloSubredditFeedLayoutIconDock || fiveUpGrid) {
        return @[];
    }

    BOOL sideBySide = layout == ApolloSubredditFeedLayoutSideBySide;
    BOOL flexibleSideBySide = sideBySide && items.count >= 3;
    NSMutableArray<UIView *> *separators =
        [NSMutableArray arrayWithCapacity:items.count > 0 ? items.count - 1 : 0];
    for (NSUInteger index = 0; index + 1 < items.count; index++) {
        UIView *separator = [UIView new];
        separator.translatesAutoresizingMaskIntoConstraints = NO;
        separator.userInteractionEnabled = NO;
        separator.backgroundColor = separatorColor;
        [hostView addSubview:separator];
        NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
            [separator.widthAnchor constraintEqualToConstant:2.0 / UIScreen.mainScreen.scale],
            [separator.topAnchor constraintEqualToAnchor:hostView.topAnchor constant:sideBySide ? 14.0 : 22.0],
            [separator.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor constant:sideBySide ? -14.0 : -22.0]
        ]];
        if (flexibleSideBySide) {
            UILayoutGuide *gapGuide = [UILayoutGuide new];
            [hostView addLayoutGuide:gapGuide];
            [constraints addObjectsFromArray:@[
                [gapGuide.leadingAnchor constraintEqualToAnchor:contentViews[index].trailingAnchor],
                [gapGuide.trailingAnchor constraintEqualToAnchor:contentViews[index + 1].leadingAnchor],
                [separator.centerXAnchor constraintEqualToAnchor:gapGuide.centerXAnchor]
            ]];
        } else {
            [constraints addObject:[separator.centerXAnchor constraintEqualToAnchor:items[index].trailingAnchor]];
        }
        [NSLayoutConstraint activateConstraints:constraints];
        [separators addObject:separator];
    }

    if (flexibleSideBySide) {
        for (NSUInteger index = 1; index + 1 < items.count; index++) {
            contentCenterXConstraints[index].active = NO;
            UILayoutGuide *regionGuide = [UILayoutGuide new];
            [hostView addLayoutGuide:regionGuide];
            [NSLayoutConstraint activateConstraints:@[
                [regionGuide.leadingAnchor constraintEqualToAnchor:separators[index - 1].centerXAnchor],
                [regionGuide.trailingAnchor constraintEqualToAnchor:separators[index].centerXAnchor],
                [contentViews[index].centerXAnchor constraintEqualToAnchor:regionGuide.centerXAnchor]
            ]];
        }
    }
    return separators;
}

NSArray<NSNumber *> *ApolloFeedShortcutVisibleIndexes(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray arrayWithObject:@0];
    if (![defaults boolForKey:UDKeyHideRPopularRedditList]) [indexes addObject:@1];
    if (![defaults boolForKey:UDKeyHideRAllRedditList]) [indexes addObject:@2];
    if (![defaults boolForKey:UDKeyHideModeratorRedditList]) [indexes addObject:@3];
    return indexes;
}

BOOL ApolloFeedShortcutShowsPalHome(void) {
    return ApolloPalHomeStore.isPalHomeEnabled &&
           ![NSUserDefaults.standardUserDefaults boolForKey:UDKeyHidePalHomeShortcut];
}

NSArray<NSNumber *> *ApolloFeedShortcutDisplayIndexes(void) {
    NSArray<NSNumber *> *native = ApolloFeedShortcutVisibleIndexes();
    return ApolloFeedShortcutShowsPalHome() ? [native arrayByAddingObject:@(ApolloFeedShortcutPalHomeIndex)] : native;
}

CGFloat ApolloFeedShortcutCompactTitlePointSize(ApolloSubredditFeedLayout layout, NSUInteger itemCount) {
    if (layout == ApolloSubredditFeedLayoutGrid) return itemCount >= 5 ? 14.0 : 15.0;
    return 16.0;
}

// Five across in Grid: no dividers and tighter insets, so every label
// (even "Moderator") fits at its real size instead of auto-shrinking.
static BOOL ApolloFeedShortcutIsFiveUpGrid(ApolloSubredditFeedLayout layout, NSUInteger itemCount) {
    return layout == ApolloSubredditFeedLayoutGrid && itemCount >= 5;
}

BOOL ApolloFeedShortcutSplitsOntoTwoLines(ApolloSubredditFeedLayout layout, NSUInteger itemCount) {
    return layout == ApolloSubredditFeedLayoutSideBySide && itemCount > 4;
}

BOOL ApolloFeedShortcutUsesCompactLayout(ApolloSubredditFeedLayout layout, NSUInteger itemCount,
                                         CGFloat availableWidth, CGFloat widthLimit) {
    if (layout == ApolloSubredditFeedLayoutGrid) {
        // Five across is always tight; four only on narrow phones.
        return itemCount >= 5 || (itemCount == 4 && availableWidth <= widthLimit);
    }
    if (layout == ApolloSubredditFeedLayoutSideBySide) {
        return itemCount == 4 && availableWidth <= widthLimit; // five splits onto two lines instead
    }
    return NO;
}

NSString *ApolloFeedShortcutShortTitle(NSInteger index) {
    return index >= 0 && index < kApolloFeedShortcutCount ? kApolloFeedShortcutShortTitles[index] : @"";
}

NSString *ApolloFeedShortcutRowTitle(NSInteger index) {
    return index >= 0 && index < kApolloFeedShortcutCount ? kApolloFeedShortcutRowTitles[index] : @"";
}

NSString *ApolloFeedShortcutDetail(NSInteger index) {
    return index >= 0 && index < kApolloFeedShortcutCount ? kApolloFeedShortcutDetails[index] : @"";
}

UIColor *ApolloFeedShortcutColor(NSInteger index) {
    switch (index) {
        case 0: return [UIColor colorWithRed:254.0 / 255.0 green:0.0 blue:98.0 / 255.0 alpha:1.0];
        case 1: return [UIColor colorWithRed:0.0 green:143.0 / 255.0 blue:253.0 / 255.0 alpha:1.0];
        case 2: return [UIColor colorWithRed:1.0 / 255.0 green:214.0 / 255.0 blue:51.0 / 255.0 alpha:1.0];
        case 4: return [UIColor colorWithRed:247.0 / 255.0 green:150.0 / 255.0 blue:46.0 / 255.0 alpha:1.0]; // Pal Home: warm orange
        default: return [UIColor colorWithWhite:0.46 alpha:1.0];
    }
}

static UIImage *ApolloFeedShortcutBundledGlyph(NSString *resourceName, BOOL brighten) {
    NSString *path = ApolloBundledResourcePath(resourceName, @"png");
    UIImage *source = path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
    if (!source) return nil;
    if (!brighten) return [source imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = source.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:source.size format:format];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [source drawAtPoint:CGPointZero];
        [source drawAtPoint:CGPointZero];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *ApolloFeedShortcutGlyph(NSInteger index) {
    static NSArray<UIImage *> *bundledGlyphs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIImage *home = ApolloFeedShortcutBundledGlyph(@"meta-feed-home", NO) ?: [UIImage new];
        UIImage *popular = ApolloFeedShortcutBundledGlyph(@"meta-feed-popular", YES) ?: [UIImage new];
        bundledGlyphs = @[ home, popular ];
    });
    if (index >= 0 && index < 2) return bundledGlyphs[(NSUInteger)index];

    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:17.5 weight:UIImageSymbolWeightSemibold];
    NSString *symbolName = index == 2 ? @"square.stack.3d.up"
        : index == ApolloFeedShortcutPalHomeIndex ? @"pawprint.fill" : @"checkmark.shield.fill";
    // pawprint arrived in SF Symbols 3 (iOS 15); iOS 14 gets a house.
    UIImage *symbol = [UIImage systemImageNamed:symbolName withConfiguration:configuration]
        ?: [UIImage systemImageNamed:@"house.fill" withConfiguration:configuration];
    return [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static CGFloat ApolloFeedShortcutOpaqueMaxDimension(UIImage *image) {
    CGImageRef imageRef = image.CGImage;
    if (!imageRef) return MAX(image.size.width, image.size.height);

    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    size_t bytesPerRow = width;
    uint8_t *alpha = calloc(height, bytesPerRow);
    if (!alpha) return MAX(image.size.width, image.size.height);

    CGContextRef context = CGBitmapContextCreate(alpha,
                                                  width,
                                                  height,
                                                  8,
                                                  bytesPerRow,
                                                  NULL,
                                                  (CGBitmapInfo)kCGImageAlphaOnly);
    if (!context) {
        free(alpha);
        return MAX(image.size.width, image.size.height);
    }
    CGContextDrawImage(context, CGRectMake(0.0, 0.0, width, height), imageRef);

    size_t minX = width;
    size_t minY = height;
    size_t maxX = 0;
    size_t maxY = 0;
    BOOL foundOpaquePixel = NO;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (alpha[y * bytesPerRow + x] == 0) continue;
            foundOpaquePixel = YES;
            minX = MIN(minX, x);
            minY = MIN(minY, y);
            maxX = MAX(maxX, x);
            maxY = MAX(maxY, y);
        }
    }
    CGContextRelease(context);
    free(alpha);
    if (!foundOpaquePixel) return MAX(image.size.width, image.size.height);

    CGFloat opaqueWidth = (CGFloat)(maxX - minX + 1) / image.scale;
    CGFloat opaqueHeight = (CGFloat)(maxY - minY + 1) / image.scale;
    return MAX(opaqueWidth, opaqueHeight);
}

static UIImage *ApolloFeedShortcutRenderedBareGlyph(UIImage *glyph,
                                                     UIColor *color,
                                                     CGFloat canvasSize,
                                                     CGFloat glyphSize) {
    static const CGFloat referenceSize = 64.0;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIImage *coloredGlyph = [glyph imageWithTintColor:color
                                         renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *referenceRenderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(referenceSize, referenceSize)
        format:format];
    UIImage *referenceImage = [referenceRenderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [coloredGlyph drawInRect:CGRectMake(0.0, 0.0, referenceSize, referenceSize)];
    }];
    CGFloat opaqueMaxDimension = ApolloFeedShortcutOpaqueMaxDimension(referenceImage);
    CGFloat drawScale = opaqueMaxDimension > 0.0 ? glyphSize / opaqueMaxDimension : 1.0;
    CGFloat drawSize = referenceSize * drawScale;

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(canvasSize, canvasSize)
        format:format];
    UIImage *icon = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGRect drawRect = CGRectMake((canvasSize - drawSize) / 2.0,
                                     (canvasSize - drawSize) / 2.0,
                                     drawSize,
                                     drawSize);
        [referenceImage drawInRect:drawRect];
    }];
    return [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static NSNumber *ApolloFeedShortcutIconCacheKey(NSInteger index,
                                                ApolloSubredditFeedIconStyle style,
                                                CGFloat canvasSize,
                                                CGFloat glyphMetric) {
    static const NSInteger kBucketStride = 128;
    static const NSInteger kFeedCount = kApolloFeedShortcutCount;
    NSInteger canvasBucket = (NSInteger)lround(canvasSize * 2.0);
    NSInteger glyphBucket = (NSInteger)lround(glyphMetric * 2.0);
    NSInteger key = ((((NSInteger)style * kBucketStride + canvasBucket) * kBucketStride + glyphBucket) *
                     kFeedCount) + index;
    return @(key);
}

UIImage *ApolloFeedShortcutIconImage(NSInteger index,
                                     ApolloSubredditFeedIconStyle style,
                                     ApolloSubredditFeedLayout layout,
                                     NSUInteger itemCount) {
    // Apollo has no classic orb for Pal Home; it wears the circle style instead.
    if (style == ApolloSubredditFeedIconStyleClassic && index == ApolloFeedShortcutPalHomeIndex) {
        style = ApolloSubredditFeedIconStyleCircle;
    }
    if (style == ApolloSubredditFeedIconStyleClassic) {
        return [ApolloSubredditClassicMetaFeedIcon(index) imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }

    BOOL tinted = style == ApolloSubredditFeedIconStyleTinted;
    CGFloat canvasSize = tinted
        ? ApolloFeedShortcutDisplayIconSize(style, layout, itemCount)
        : (layout == ApolloSubredditFeedLayoutRows ? 34.0 : 40.0);
    CGFloat glyphMetric = tinted
        ? canvasSize - (layout == ApolloSubredditFeedLayoutGrid ? 6.0 : 4.0)
        : (layout == ApolloSubredditFeedLayoutRows ? 6.0 : 7.0);
    static NSMutableDictionary<NSNumber *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSNumber *cacheKey = ApolloFeedShortcutIconCacheKey(index, style, canvasSize, glyphMetric);
    UIImage *cached = cache[cacheKey];
    if (cached) return cached;

    UIImage *glyph = ApolloFeedShortcutGlyph(index);
    if (!glyph) return nil;
    UIColor *color = ApolloFeedShortcutColor(index);
    if (tinted) {
        UIImage *icon = ApolloFeedShortcutRenderedBareGlyph(glyph, color, canvasSize, glyphMetric);
        cache[cacheKey] = icon;
        return icon;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(canvasSize, canvasSize)
        format:format];
    UIImage *icon = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGRect bounds = CGRectMake(0.0, 0.0, canvasSize, canvasSize);
        BOOL usesCircle = style == ApolloSubredditFeedIconStyleCircle;
        BOOL softTile = style == ApolloSubredditFeedIconStyleSoftTile;
        BOOL usesTile = softTile || style == ApolloSubredditFeedIconStyleSolidTile;
        if (usesCircle || usesTile) {
            UIBezierPath *path = usesTile
                ? [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:canvasSize * 0.25]
                : [UIBezierPath bezierPathWithOvalInRect:bounds];
            UIColor *fillColor = softTile ? [color colorWithAlphaComponent:0.14] : color;
            [fillColor setFill];
            [path fill];
        }
        UIColor *glyphColor = softTile ? color : UIColor.whiteColor;
        UIImage *coloredGlyph = [glyph imageWithTintColor:glyphColor
                                             renderingMode:UIImageRenderingModeAlwaysOriginal];
        [coloredGlyph drawInRect:CGRectInset(bounds, glyphMetric, glyphMetric)];
    }];
    icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    cache[cacheKey] = icon;
    return icon;
}

ApolloSubredditFeedLayout ApolloFeedShortcutEffectiveLayout(ApolloSubredditFeedLayout preferredLayout,
                                                             NSUInteger itemCount,
                                                             UITraitCollection *traitCollection) {
    if (preferredLayout != ApolloSubredditFeedLayoutSideBySide || itemCount < 2) {
        return preferredLayout;
    }

    UIContentSizeCategory category = traitCollection.preferredContentSizeCategory;
    if (UIContentSizeCategoryIsAccessibilityCategory(category)) {
        return ApolloSubredditFeedLayoutRows;
    }
    return preferredLayout;
}

ApolloFeedShortcutItemGeometry ApolloFeedShortcutItemGeometryForLayout(ApolloSubredditFeedLayout layout,
                                                                        NSUInteger itemCount,
                                                                        NSInteger feedIndex) {
    BOOL sideBySide = layout == ApolloSubredditFeedLayoutSideBySide;
    return (ApolloFeedShortcutItemGeometry){
        .usesFlexibleSideBySideLayout = sideBySide && itemCount >= 3,
        .centerXOffset = sideBySide && itemCount == 3 && feedIndex == 3 ? 6.0 : 0.0,
        .horizontalMargin = sideBySide ? 6.0 : 4.0,
    };
}

CGFloat ApolloFeedShortcutLayoutHeight(ApolloSubredditFeedLayout layout,
                                       UITraitCollection *traitCollection) {
    if (layout == ApolloSubredditFeedLayoutIconDock) return 64.0;
    if (layout == ApolloSubredditFeedLayoutRows) return 0.0;

    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
                              compatibleWithTraitCollection:traitCollection];
    if (layout == ApolloSubredditFeedLayoutSideBySide) {
        return MAX(68.0, ceil(font.lineHeight) + 16.0);
    }
    if (layout == ApolloSubredditFeedLayoutGrid) {
        CGFloat contentHeight = 46.0 + 4.0 + ceil(font.lineHeight) + 16.0;
        return MAX(104.0, contentHeight);
    }
    return 0.0;
}

CGFloat ApolloFeedShortcutLayoutHeightForCount(ApolloSubredditFeedLayout layout,
                                               UITraitCollection *traitCollection,
                                               NSUInteger itemCount) {
    CGFloat height = ApolloFeedShortcutLayoutHeight(layout, traitCollection);
    // Two lines: each a little tighter than a lone strip.
    return ApolloFeedShortcutSplitsOntoTwoLines(layout, itemCount) ? ceil(height * 1.75) : height;
}

CGFloat ApolloFeedShortcutRowHeight(UITraitCollection *traitCollection) {
    UIFont *titleFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
                                compatibleWithTraitCollection:traitCollection];
    UIFont *detailFont = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote
                                 compatibleWithTraitCollection:traitCollection];
    return MAX(60.0, ceil(titleFont.lineHeight) + ceil(detailFont.lineHeight) + 18.0);
}

CGFloat ApolloFeedShortcutPreviewRowItemHeight(UITraitCollection *traitCollection) {
    return ApolloFeedShortcutRowHeight(traitCollection) - 8.0;
}

CGFloat ApolloFeedShortcutDisplayIconSize(ApolloSubredditFeedIconStyle style,
                                          ApolloSubredditFeedLayout layout,
                                          NSUInteger itemCount) {
    if (layout == ApolloSubredditFeedLayoutRows) {
        return style == ApolloSubredditFeedIconStyleTinted ? 30.0 : 34.0;
    }
    if (layout == ApolloSubredditFeedLayoutGrid) {
        if (itemCount >= 5) return style == ApolloSubredditFeedIconStyleTinted ? 38.0 : 42.0;
        return style == ApolloSubredditFeedIconStyleTinted ? 40.0 : 46.0;
    }
    if (layout == ApolloSubredditFeedLayoutIconDock) return 34.0;
    if (style == ApolloSubredditFeedIconStyleTinted) return itemCount == 4 ? 28.0 : 30.0;
    return itemCount == 4 ? 30.0 : 32.0;
}

CGFloat ApolloFeedShortcutContentSpacing(ApolloSubredditFeedLayout layout, NSUInteger itemCount) {
    if (layout == ApolloSubredditFeedLayoutSideBySide) return itemCount == 4 ? 3.5 : 7.0;
    if (layout == ApolloSubredditFeedLayoutIconDock) return 0.0;
    return 4.0;
}
