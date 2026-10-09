#import "ApolloTiledText.h"
#import "ApolloCommon.h"
#import "ApolloTextureDecls.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <math.h>

// How a tile is drawn
// -------------------
// For a drawRect node, Texture runs the node's will-display context block,
// +drawRect:withParameters:isCancelled:isRasterizing: and its did-display
// block into one bitmap the size of the node (Apollo's MarkdownTextNode uses
// the did-display block to paint spoiler boxes, quote bars and code
// backgrounds behind the text). A tile runs the same three steps into
// CATiledLayer's context, which is already clipped to the tile and positioned
// in the node's coordinates, so every tile matches that part of the bitmap.
//
// The text step uses the renderer Texture already laid out (cached per text
// and size) but draws only the lines that cross the tile. ASTextKitRenderer
// itself draws every glyph of the text on each call: about 40 ms per tile for
// a long post at 3x, against about 2 ms for the lines a tile shows. That path
// mirrors +[ASTextNode drawRect:withParameters:isCancelled:isRasterizing:]
// and -[ASTextKitRenderer drawInContext:bounds:] in Apollo's AsyncDisplayKit
// (whose renderer never takes its NSStringDrawing fast path), and every tile
// falls back to calling +drawRect: if one of the internals it needs is
// missing or the text is scaled to fit.
//
// Synchronous displays
// --------------------
// Tiles are drawn on CATiledLayer's own threads after the layer is on screen,
// so a brand-new tiled layer shows nothing for a frame. Texture's synchronous
// display (-recursivelyEnsureDisplaySynchronously:, which the tweak runs so a
// vote or a translation doesn't blank a cell for a frame) can't wait for
// that, and Apollo rebuilds the post body's node on every vote. When such a
// pass finds the tiles missing or stale, the part of the node that is on
// screen is drawn right away into a "bridge" layer above the tiles, which is
// removed once the tiles under it have been drawn.

typedef void (^ApolloTiledTextContextModifier)(CGContextRef context, id _Nullable drawParameters);
typedef BOOL (^ApolloTiledTextCancelledBlock)(void);

@interface ASDisplayNode (ApolloTiledText)
- (CALayer *)layer;
- (BOOL)isLayerBacked;
- (nullable ApolloTiledTextContextModifier)willDisplayNodeContentWithRenderingContext;
- (nullable ApolloTiledTextContextModifier)didDisplayNodeContentWithRenderingContext;
@end

@interface ASTextNode (ApolloTiledText)
+ (void)drawRect:(CGRect)bounds withParameters:(id)parameters isCancelled:(ApolloTiledTextCancelledBlock)isCancelled isRasterizing:(BOOL)isRasterizing;
- (id)drawParametersForAsyncLayer:(CALayer *)layer;
- (UIEdgeInsets)textContainerInset;
- (nullable NSAttributedString *)truncationAttributedText;
@end

// AsyncDisplayKit internals used by the line-limited text draw, declared as
// protocols so no private class is referenced. Each selector is checked once
// in ApolloTiledTextResolveInternals before any of them is sent.
@protocol ApolloTiledTextDrawParameter <NSObject>
- (id)rendererForBounds:(CGRect)bounds;
@end

@protocol ApolloTiledTextRenderer <NSObject>
- (id)context;
- (id)shadower;
- (BOOL)isScaled;
- (CGSize)constrainedSize;
@end

@protocol ApolloTiledTextKitContext <NSObject>
- (void)performBlockWithLockedTextKitComponents:(void (^)(NSLayoutManager *layoutManager, NSTextStorage *textStorage, NSTextContainer *textContainer))block;
@end

@protocol ApolloTiledTextShadower <NSObject>
- (CGRect)insetRectWithConstrainedRect:(CGRect)constrainedRect;
- (void)setShadowInContext:(CGContextRef)context;
@end

// Tiles are 1024 px tall (341 pt at 3x) and span the node up to 2048 px
// wide: at most 8 MB each, and CATiledLayer keeps only what is on screen.
static const CGFloat kApolloTiledTextTileHeightPixels = 1024;
static const CGFloat kApolloTiledTextMaxTileWidthPixels = 2048;

// Bounds past these are a runaway layout, not text (Reddit's longest post at
// the largest text size is about 35,000 pt tall on a phone), and stay with the
// display guard, which leaves them blank.
static const CGFloat kApolloTiledTextMaxWidth = 20000;
static const CGFloat kApolloTiledTextMaxHeight = 1000000;

// The bridge is checked every frame or so; it goes one check after the tiles
// under it were drawn (so they have reached the screen), or after 2 s.
static const NSTimeInterval kApolloTiledTextBridgeCheckInterval = 0.02;
static const NSUInteger kApolloTiledTextBridgeMaxChecks = 100;

static const void *kApolloTiledTextLayerKey = &kApolloTiledTextLayerKey;
static const void *kApolloTiledTextBitmapFailedKey = &kApolloTiledTextBitmapFailedKey;

// Live tiled layers (any thread: Texture can free nodes off the main thread)
// and whether any node's bitmap has failed (main thread only). With neither,
// a text node that fits one bitmap leaves ApolloTiledTextTakeOverDisplay
// without an associated-object lookup.
static atomic_long sApolloTiledTextLiveLayers;
static BOOL sApolloTiledTextAnyBitmapFailed = NO;

// One log line per node class and reason per launch, like the display guard.
static BOOL ApolloTiledTextShouldLog(NSString *key) {
    static NSMutableSet<NSString *> *logged;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logged = [NSMutableSet set]; });
    @synchronized (logged) {
        if ([logged containsObject:key]) return NO;
        [logged addObject:key];
        return YES;
    }
}

static Class ApolloTiledTextNodeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("ASTextNode"); });
    return cls;
}

#pragma mark - Line-limited text draw

static BOOL sApolloTiledTextInternalsResolved = NO;
static Class sApolloTiledTextDrawParameterClass = Nil;
static Ivar sApolloTiledTextBackgroundColorIvar = NULL;
static ptrdiff_t sApolloTiledTextInsetsOffset = 0;

// Once per launch: the first takeover (main thread) resolves these before any
// tiled layer exists; tile draws call it again for the memory ordering.
static void ApolloTiledTextResolveInternals(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class parameterClass = objc_getClass("ASTextNodeDrawParameter");
        Class rendererClass = objc_getClass("ASTextKitRenderer");
        Class contextClass = objc_getClass("ASTextKitContext");
        Class shadowerClass = objc_getClass("ASTextKitShadower");
        Ivar background = parameterClass ? class_getInstanceVariable(parameterClass, "_backgroundColor") : NULL;
        Ivar insets = parameterClass ? class_getInstanceVariable(parameterClass, "_textContainerInsets") : NULL;
        const char *backgroundType = background ? ivar_getTypeEncoding(background) : NULL;
        const char *insetsType = insets ? ivar_getTypeEncoding(insets) : NULL;
        NSString *missing = nil;
        if (!parameterClass || !rendererClass || !contextClass || !shadowerClass) {
            missing = @"class";
        } else if (!backgroundType || backgroundType[0] != '@' || !insetsType || strncmp(insetsType, "{UIEdgeInsets=", 14) != 0) {
            missing = @"draw parameter ivar";
        } else if (![parameterClass instancesRespondToSelector:@selector(rendererForBounds:)]
                   || ![rendererClass instancesRespondToSelector:@selector(context)]
                   || ![rendererClass instancesRespondToSelector:@selector(shadower)]
                   || ![rendererClass instancesRespondToSelector:@selector(isScaled)]
                   || ![rendererClass instancesRespondToSelector:@selector(constrainedSize)]
                   || ![contextClass instancesRespondToSelector:@selector(performBlockWithLockedTextKitComponents:)]
                   || ![shadowerClass instancesRespondToSelector:@selector(insetRectWithConstrainedRect:)]
                   || ![shadowerClass instancesRespondToSelector:@selector(setShadowInContext:)]) {
            missing = @"selector";
        }
        if (missing) {
            ApolloLog(@"[TiledText] AsyncDisplayKit text internals not found (%@): tiles draw through +drawRect:, which is slower", missing);
            return;
        }
        sApolloTiledTextDrawParameterClass = parameterClass;
        sApolloTiledTextBackgroundColorIvar = background;
        sApolloTiledTextInsetsOffset = ivar_getOffset(insets);
        sApolloTiledTextInternalsResolved = YES;
    });
}

// Draws what +[ASTextNode drawRect:withParameters:isCancelled:isRasterizing:]
// draws (isRasterizing NO), limited to the lines that cross the context's
// clip plus `margin` points either side (glyphs can reach past their line:
// tall marks, emoji). NO, having drawn nothing, when it can't: the caller then
// uses +drawRect: itself.
static BOOL ApolloTiledTextDrawLinesInClip(CGContextRef context, id parameters, CGRect bounds, CGFloat margin) {
    ApolloTiledTextResolveInternals();
    if (!sApolloTiledTextInternalsResolved || ![parameters isKindOfClass:sApolloTiledTextDrawParameterClass]) return NO;
    id<ApolloTiledTextRenderer> renderer = [(id<ApolloTiledTextDrawParameter>)parameters rendererForBounds:bounds];
    // Scaled text swaps in a resized copy of the text storage while it draws.
    if (!renderer || [renderer isScaled]) return NO;
    id<ApolloTiledTextKitContext> textKitContext = [renderer context];
    if (!textKitContext) return NO;
    id<ApolloTiledTextShadower> shadower = [renderer shadower];
    UIColor *backgroundColor = object_getIvar(parameters, sApolloTiledTextBackgroundColorIvar);
    UIEdgeInsets insets = *(const UIEdgeInsets *)((const uint8_t *)(__bridge const void *)parameters + sApolloTiledTextInsetsOffset);
    CGSize constrainedSize = [renderer constrainedSize];

    // +[ASTextNode drawRect:...]
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, insets.left, insets.top);
    if (backgroundColor) {
        [backgroundColor setFill];
        UIRectFillUsingBlendMode(CGContextGetClipBoundingBox(context), kCGBlendModeCopy);
    }

    // -[ASTextKitRenderer drawInContext:bounds:]
    CGRect textBounds = CGRectIntersection(bounds, (CGRect){CGPointZero, constrainedSize});
    CGPoint origin = (shadower ? [shadower insetRectWithConstrainedRect:textBounds] : textBounds).origin;
    CGContextSaveGState(context);
    [shadower setShadowInContext:context];
    CGRect clip = CGContextGetClipBoundingBox(context);
    [textKitContext performBlockWithLockedTextKitComponents:^(NSLayoutManager *layoutManager, NSTextStorage *textStorage, NSTextContainer *textContainer) {
        // In text container coordinates.
        CGRect rect = CGRectInset(CGRectOffset(clip, -origin.x, -origin.y), 0, -margin);
        rect = CGRectIntersection(rect, (CGRect){CGPointZero, textContainer.size});
        if (CGRectIsEmpty(rect)) return;
        NSRange glyphs = [layoutManager glyphRangeForBoundingRect:rect inTextContainer:textContainer];
        [layoutManager drawBackgroundForGlyphRange:glyphs atPoint:origin];
        [layoutManager drawGlyphsForGlyphRange:glyphs atPoint:origin];
    }];
    CGContextRestoreGState(context);
    CGContextRestoreGState(context);
    return YES;
}

#pragma mark - Snapshot

// What the tiles of one display pass draw from. Immutable: a display pass
// swaps in a new one, and a tile reads whichever is current when it starts.
@interface ApolloTiledTextSnapshot : NSObject
@property (nonatomic, readonly) Class drawClass;
@property (nonatomic, readonly) id drawParameters;
@property (nonatomic, readonly, nullable) ApolloTiledTextContextModifier willDisplay;
@property (nonatomic, readonly, nullable) ApolloTiledTextContextModifier didDisplay;
// Texture draws a node's bitmap with the node's traits as the current ones, so
// dynamic colors resolve for its light or dark appearance; tiles do the same.
@property (nonatomic, readonly, nullable) UITraitCollection *traitCollection;
@property (nonatomic, readonly) CGRect bounds;
@property (nonatomic, readonly) CGFloat scale;
// Compared to tell whether tiles drawn from the previous snapshot are stale.
// Texture redraws a node many times while a thread opens (layout passes,
// flushes); redrawing every tile for each of those passes is wasted work.
@property (nonatomic, readonly, nullable) NSAttributedString *text;
@property (nonatomic, readonly, nullable) NSAttributedString *truncationText;
@property (nonatomic, readonly) NSUInteger maximumNumberOfLines;
@property (nonatomic, readonly) UIEdgeInsets textContainerInset;
@property (nonatomic, readonly, nullable) UIColor *backgroundColor;
@end

@implementation ApolloTiledTextSnapshot

- (instancetype)initWithNode:(ASTextNode *)node parameters:(id)parameters bounds:(CGRect)bounds scale:(CGFloat)scale traitCollection:(UITraitCollection *)traitCollection {
    if ((self = [super init])) {
        _drawClass = [node class];
        _drawParameters = parameters;
        _willDisplay = [node willDisplayNodeContentWithRenderingContext];
        _didDisplay = [node didDisplayNodeContentWithRenderingContext];
        _traitCollection = traitCollection;
        _bounds = bounds;
        _scale = scale;
        _text = node.attributedText;
        _truncationText = [node truncationAttributedText];
        _maximumNumberOfLines = node.maximumNumberOfLines;
        _textContainerInset = [node textContainerInset];
        _backgroundColor = node.backgroundColor;
    }
    return self;
}

static BOOL ApolloTiledTextObjectsEqual(id a, id b) {
    return a == b || [a isEqual:b];
}

- (BOOL)drawsSameAsSnapshot:(ApolloTiledTextSnapshot *)other {
    return other
        && _drawClass == other.drawClass
        && _willDisplay == other.willDisplay
        && _didDisplay == other.didDisplay
        && CGRectEqualToRect(_bounds, other.bounds)
        && _scale == other.scale
        && _maximumNumberOfLines == other.maximumNumberOfLines
        && UIEdgeInsetsEqualToEdgeInsets(_textContainerInset, other.textContainerInset)
        && ApolloTiledTextObjectsEqual(_backgroundColor, other.backgroundColor)
        && ApolloTiledTextObjectsEqual(_traitCollection, other.traitCollection)
        && ApolloTiledTextObjectsEqual(_truncationText, other.truncationText)
        && ApolloTiledTextObjectsEqual(_text, other.text);
}

@end

// Draws the snapshot's content inside the context's clip, the way Texture
// draws the node into its bitmap. Any thread.
static void ApolloTiledTextDrawSnapshot(CGContextRef context, ApolloTiledTextSnapshot *snapshot) {
    // A tile's height of extra lines either side of the clip.
    CGFloat margin = kApolloTiledTextTileHeightPixels / snapshot.scale;
    void (^draw)(void) = ^{
        UIGraphicsPushContext(context);
        @try {
            if (snapshot.willDisplay) snapshot.willDisplay(context, snapshot.drawParameters);
            if (!ApolloTiledTextDrawLinesInClip(context, snapshot.drawParameters, snapshot.bounds, margin)) {
                [snapshot.drawClass drawRect:snapshot.bounds withParameters:snapshot.drawParameters isCancelled:^BOOL{ return NO; } isRasterizing:NO];
            }
            if (snapshot.didDisplay) snapshot.didDisplay(context, snapshot.drawParameters);
        } @catch (NSException *exception) {
            // Nothing catches on CA's tile threads: a tile that can't be drawn
            // stays empty instead, as a failed bitmap leaves its node.
            NSString *className = NSStringFromClass(snapshot.drawClass) ?: @"(unknown)";
            if (ApolloTiledTextShouldLog([@"throw:" stringByAppendingString:className])) {
                ApolloLog(@"[TiledText] drawing %@ raised %@: %@ (left empty)",
                          className, exception.name ?: @"(nil)", exception.reason ?: @"(nil)");
            }
        }
        UIGraphicsPopContext();
    };
    if (snapshot.traitCollection) {
        [snapshot.traitCollection performAsCurrentTraitCollection:draw];
    } else {
        draw();
    }
}

#pragma mark - Tiled layer

@interface ApolloTiledTextLayer : CATiledLayer
// Held for each tile draw, as Texture's display block holds the node: the
// did-display block asks the node for text rects. Set once, on the main
// thread, before the layer is attached.
@property (nonatomic, weak) id apollo_node;
// Main thread: what a synchronous display put on screen until the tiles under
// it are drawn (a sibling above this layer on the node's layer).
@property (nonatomic, nullable) CALayer *apollo_bridgeLayer;
// Main thread. Sets what tiles draw from. YES when the drawing changed, so
// tiles drawn so far are stale.
- (BOOL)apollo_setSnapshot:(nullable ApolloTiledTextSnapshot *)snapshot;
// Main thread: whether full-resolution tiles of the current snapshot have
// been drawn over all of `rect` (node coordinates).
- (BOOL)apollo_tilesDrawnOverRect:(CGRect)rect;
@end

// Columns of tiles across a snapshot's node (one unless the node is wider than
// a tile), for numbering tiles row by row.
static NSUInteger ApolloTiledTextColumns(ApolloTiledTextSnapshot *snapshot) {
    CGFloat width = CGRectGetWidth(snapshot.bounds) * snapshot.scale;
    return (NSUInteger)MAX(1.0, ceil(width / MIN(ceil(width), kApolloTiledTextMaxTileWidthPixels)));
}

@implementation ApolloTiledTextLayer {
    os_unfair_lock _snapshotLock;
    ApolloTiledTextSnapshot *_snapshot;
    // Full-resolution tiles drawn from _snapshot, numbered row by row.
    NSMutableIndexSet *_drawnTiles;
}

// Tiles appear as soon as they are drawn, like the bitmap they replace.
+ (CFTimeInterval)fadeDuration {
    return 0;
}

- (instancetype)init {
    if ((self = [super init])) {
        _snapshotLock = OS_UNFAIR_LOCK_INIT;
        _drawnTiles = [NSMutableIndexSet indexSet];
        self.opaque = NO;
        atomic_fetch_add(&sApolloTiledTextLiveLayers, 1);
    }
    return self;
}

// Core Animation's presentation copies come through here, not -init; they
// draw nothing (no snapshot) but are counted so -dealloc stays balanced.
- (instancetype)initWithLayer:(id)layer {
    if ((self = [super initWithLayer:layer])) {
        _snapshotLock = OS_UNFAIR_LOCK_INIT;
        _drawnTiles = [NSMutableIndexSet indexSet];
        atomic_fetch_add(&sApolloTiledTextLiveLayers, 1);
    }
    return self;
}

- (void)dealloc {
    atomic_fetch_sub(&sApolloTiledTextLiveLayers, 1);
}

// Frame, scale and tile size follow the node without animating.
- (id<CAAction>)actionForKey:(NSString *)event {
    return nil;
}

- (BOOL)apollo_setSnapshot:(ApolloTiledTextSnapshot *)snapshot {
    os_unfair_lock_lock(&_snapshotLock);
    BOOL changed = !snapshot || ![snapshot drawsSameAsSnapshot:_snapshot];
    _snapshot = snapshot;
    if (changed) [_drawnTiles removeAllIndexes];
    os_unfair_lock_unlock(&_snapshotLock);
    return changed;
}

- (BOOL)apollo_tilesDrawnOverRect:(CGRect)rect {
    os_unfair_lock_lock(&_snapshotLock);
    BOOL drawn = NO;
    CGFloat scale = _snapshot.scale;
    if (_snapshot && scale > 0 && CGRectGetWidth(rect) > 0 && CGRectGetHeight(rect) > 0) {
        NSUInteger columns = ApolloTiledTextColumns(_snapshot);
        CGFloat tileWidth = MIN(ceil(CGRectGetWidth(_snapshot.bounds) * scale), kApolloTiledTextMaxTileWidthPixels);
        NSUInteger firstRow = (NSUInteger)floor(MAX(CGRectGetMinY(rect), 0) * scale / kApolloTiledTextTileHeightPixels);
        NSUInteger lastRow = (NSUInteger)floor((CGRectGetMaxY(rect) * scale - 1) / kApolloTiledTextTileHeightPixels);
        NSUInteger firstColumn = (NSUInteger)floor(MAX(CGRectGetMinX(rect), 0) * scale / tileWidth);
        NSUInteger lastColumn = MIN((NSUInteger)floor((CGRectGetMaxX(rect) * scale - 1) / tileWidth), columns - 1);
        drawn = lastRow >= firstRow && lastColumn >= firstColumn;
        for (NSUInteger row = firstRow; drawn && row <= lastRow; row++) {
            drawn = [_drawnTiles containsIndexesInRange:NSMakeRange(row * columns + firstColumn, lastColumn - firstColumn + 1)];
        }
    }
    os_unfair_lock_unlock(&_snapshotLock);
    return drawn;
}

// CATiledLayer's tile threads.
- (void)drawInContext:(CGContextRef)context {
    os_unfair_lock_lock(&_snapshotLock);
    ApolloTiledTextSnapshot *snapshot = _snapshot;
    os_unfair_lock_unlock(&_snapshotLock);
    __attribute__((objc_precise_lifetime)) id node = self.apollo_node;
    if (!snapshot || !node) return;

    CGRect tile = CGContextGetClipBoundingBox(context);
    ApolloTiledTextDrawSnapshot(context, snapshot);

    // Full resolution only: the scaled-down levels don't stand in for the
    // tiles a bridge waits on.
    if (fabs(fabs(CGContextGetCTM(context).a) - snapshot.scale) > 0.01) return;
    CGFloat tileWidth = MIN(ceil(CGRectGetWidth(snapshot.bounds) * snapshot.scale), kApolloTiledTextMaxTileWidthPixels);
    NSUInteger row = (NSUInteger)llround(CGRectGetMinY(tile) * snapshot.scale / kApolloTiledTextTileHeightPixels);
    NSUInteger column = (NSUInteger)llround(CGRectGetMinX(tile) * snapshot.scale / tileWidth);
    os_unfair_lock_lock(&_snapshotLock);
    if (_snapshot == snapshot) [_drawnTiles addIndex:row * ApolloTiledTextColumns(snapshot) + column];
    os_unfair_lock_unlock(&_snapshotLock);
}

@end

#pragma mark - Bridge

static void ApolloTiledTextRemoveBridge(ApolloTiledTextLayer *tiledLayer) {
    CALayer *bridge = tiledLayer.apollo_bridgeLayer;
    if (!bridge) return;
    tiledLayer.apollo_bridgeLayer = nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [bridge removeFromSuperlayer];
    [CATransaction commit];
}

static void ApolloTiledTextScheduleBridgeCheck(ApolloTiledTextLayer *tiledLayer, CALayer *bridge, NSUInteger check, BOOL tilesWereDrawn) {
    __weak ApolloTiledTextLayer *weakTiledLayer = tiledLayer;
    __weak CALayer *weakBridge = bridge;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloTiledTextBridgeCheckInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloTiledTextLayer *strongTiledLayer = weakTiledLayer;
        CALayer *strongBridge = weakBridge;
        // Replaced by a newer bridge, or the tiles went away.
        if (!strongTiledLayer || !strongBridge || strongTiledLayer.apollo_bridgeLayer != strongBridge) return;
        if (tilesWereDrawn || check >= kApolloTiledTextBridgeMaxChecks) {
            ApolloTiledTextRemoveBridge(strongTiledLayer);
            return;
        }
        ApolloTiledTextScheduleBridgeCheck(strongTiledLayer, strongBridge, check + 1,
                                           [strongTiledLayer apollo_tilesDrawnOverRect:strongBridge.frame]);
    });
}

// Main thread, inside the takeover's transaction. Draws the part of the node
// inside its window now into the bridge layer.
static void ApolloTiledTextShowBridge(ApolloTiledTextLayer *tiledLayer, CALayer *nodeLayer, ApolloTiledTextSnapshot *snapshot, UIWindow *window) {
    if (!window) return;
    CGRect visible = CGRectIntersection(nodeLayer.bounds, [window.layer convertRect:window.bounds toLayer:nodeLayer]);
    if (CGRectIsEmpty(visible)) return;
    visible = CGRectIntegral(visible);

    // 8-bit sRGB like Texture's bitmaps and the tiles, so the swap is seamless
    // on wide-color screens too.
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = snapshot.scale;
    format.opaque = NO;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:visible.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        CGContextTranslateCTM(context, -CGRectGetMinX(visible), -CGRectGetMinY(visible));
        CGContextClipToRect(context, visible);
        ApolloTiledTextDrawSnapshot(context, snapshot);
    }];
    if (!image.CGImage) return;

    CALayer *bridge = tiledLayer.apollo_bridgeLayer ?: [CALayer layer];
    bridge.contents = (__bridge id)image.CGImage;
    bridge.contentsScale = image.scale;
    bridge.frame = visible;
    if (bridge.superlayer != nodeLayer) [nodeLayer insertSublayer:bridge above:tiledLayer];
    tiledLayer.apollo_bridgeLayer = bridge;
    ApolloTiledTextScheduleBridgeCheck(tiledLayer, bridge, 0, NO);
}

#pragma mark - Display takeover

// The nearest view in the node's supernode chain: Texture hands its traits
// down to the layer-backed nodes under it, so they are the traits the node's
// bitmap would be drawn with, and its window is the node's. Main thread.
static UIView *ApolloTiledTextHostView(ASDisplayNode *node) {
    for (ASDisplayNode *current = node; current; current = [current supernode]) {
        if ([current isNodeLoaded] && ![current isLayerBacked]) return [current view];
    }
    return nil;
}

static void ApolloTiledTextRemove(ASDisplayNode *node, ApolloTiledTextLayer *tiledLayer) {
    [tiledLayer apollo_setSnapshot:nil];
    ApolloTiledTextRemoveBridge(tiledLayer);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [tiledLayer removeFromSuperlayer];
    [CATransaction commit];
    objc_setAssociatedObject(node, kApolloTiledTextLayerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL ApolloTiledTextTakeOverDisplay(id node, CGRect bounds, CGFloat scale, BOOL overBudget, BOOL rasterizing, BOOL synchronous) {
    Class textNodeClass = ApolloTiledTextNodeClass();
    if (!textNodeClass || ![node isKindOfClass:textNodeClass]) return NO;
    // A text node that fits one bitmap, with no tiled layer or failed bitmap
    // anywhere: the usual case, decided without touching the node.
    if (!overBudget && atomic_load(&sApolloTiledTextLiveLayers) == 0 && !sApolloTiledTextAnyBitmapFailed) return NO;

    ASTextNode *textNode = node;
    ApolloTiledTextLayer *tiledLayer = objc_getAssociatedObject(textNode, kApolloTiledTextLayerKey);
    BOOL bitmapFailed = sApolloTiledTextAnyBitmapFailed && objc_getAssociatedObject(textNode, kApolloTiledTextBitmapFailedKey) != nil;
    // Only a node that draws its own layer, at a usable scale and a text-like
    // size, without corner rounding or a border (Texture draws those into the
    // bitmap around the content; tiles don't).
    BOOL wanted = (overBudget || bitmapFailed)
        && !rasterizing
        && scale > 0 && isfinite(scale)
        && CGRectGetWidth(bounds) > 0 && CGRectGetWidth(bounds) <= kApolloTiledTextMaxWidth
        && CGRectGetHeight(bounds) > 0 && CGRectGetHeight(bounds) <= kApolloTiledTextMaxHeight
        && textNode.cornerRadius <= 0 && textNode.borderWidth <= 0
        && [[textNode class] respondsToSelector:@selector(drawRect:withParameters:isCancelled:isRasterizing:)];
    CALayer *layer = wanted ? [textNode layer] : nil;
    id parameters = layer ? [textNode drawParametersForAsyncLayer:layer] : nil;
    if (!parameters) {
        // Back to one bitmap (the text got shorter, or can't be tiled):
        // drop the tiles so they don't cover it.
        if (tiledLayer) ApolloTiledTextRemove(textNode, tiledLayer);
        return NO;
    }

    ApolloTiledTextResolveInternals();
    UIView *hostView = ApolloTiledTextHostView(textNode);
    ApolloTiledTextSnapshot *snapshot = [[ApolloTiledTextSnapshot alloc] initWithNode:textNode
                                                                           parameters:parameters
                                                                               bounds:bounds
                                                                                scale:scale
                                                                      traitCollection:hostView.traitCollection];
    if (!tiledLayer) {
        tiledLayer = [ApolloTiledTextLayer layer];
        tiledLayer.apollo_node = textNode;
        objc_setAssociatedObject(textNode, kApolloTiledTextLayerKey, tiledLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *className = NSStringFromClass([textNode class]) ?: @"(unknown)";
        NSString *reason = overBudget ? @"over the bitmap budget" : @"its bitmap failed";
        if (ApolloTiledTextShouldLog([NSString stringWithFormat:@"%@:%@", reason, className])) {
            ApolloLog(@"[TiledText] drawing %@ in tiles, %@: bounds=%@ scale=%.1f (%.0f MP)",
                      className, reason, NSStringFromCGRect(bounds), scale,
                      CGRectGetWidth(bounds) * scale * CGRectGetHeight(bounds) * scale / 1e6);
        }
    }
    BOOL changed = [tiledLayer apollo_setSnapshot:snapshot];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // Below anything else on the node's layer (link highlight overlays).
    if (tiledLayer.superlayer != layer) [layer insertSublayer:tiledLayer atIndex:0];
    if (!CGRectEqualToRect(tiledLayer.frame, bounds)) tiledLayer.frame = bounds;
    if (tiledLayer.contentsScale != scale) tiledLayer.contentsScale = scale;
    CGSize tileSize = CGSizeMake(MIN(ceil(CGRectGetWidth(bounds) * scale), kApolloTiledTextMaxTileWidthPixels),
                                 kApolloTiledTextTileHeightPixels);
    if (!CGSizeEqualToSize(tiledLayer.tileSize, tileSize)) tiledLayer.tileSize = tileSize;
    // Half-resolution levels down to about two tiles for the whole node, for
    // when it is shown scaled down (the long-press preview fits the whole post
    // on screen). With only full resolution, that preview drew every tile of a
    // 65 MP body (+126 MB) instead of a few small ones.
    size_t levels = 1;
    for (CGFloat height = CGRectGetHeight(bounds) * scale; height > 2 * kApolloTiledTextTileHeightPixels && levels < 8; height /= 2) {
        levels++;
    }
    if (tiledLayer.levelsOfDetail != levels) tiledLayer.levelsOfDetail = levels;
    if (changed) {
        [tiledLayer setNeedsDisplay];
        // CATiledLayer keeps showing stale tiles until it redraws them, but a
        // new layer has none, and a synchronous display must not show the
        // old content either: bridge the visible part until the tiles land.
        if (synchronous) {
            ApolloTiledTextShowBridge(tiledLayer, layer, snapshot, hostView.window);
        } else if (tiledLayer.apollo_bridgeLayer) {
            // Content changed again under a bridge: don't leave older text on top.
            ApolloTiledTextRemoveBridge(tiledLayer);
        }
    }
    [CATransaction commit];
    return YES;
}

void ApolloTiledTextDropTiles(id node) {
    if (atomic_load(&sApolloTiledTextLiveLayers) == 0 || !node) return;
    ApolloTiledTextLayer *tiledLayer = objc_getAssociatedObject(node, kApolloTiledTextLayerKey);
    if (tiledLayer) ApolloTiledTextRemove(node, tiledLayer);
}

void ApolloTiledTextNoteBitmapFailure(id node) {
    Class textNodeClass = ApolloTiledTextNodeClass();
    if (!node || !textNodeClass || ![node isKindOfClass:textNodeClass]) return;
    __weak id weakNode = node;
    dispatch_async(dispatch_get_main_queue(), ^{
        ASTextNode *textNode = weakNode;
        if (!textNode || objc_getAssociatedObject(textNode, kApolloTiledTextBitmapFailedKey)) return;
        sApolloTiledTextAnyBitmapFailed = YES;
        objc_setAssociatedObject(textNode, kApolloTiledTextBitmapFailedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *className = NSStringFromClass([textNode class]) ?: @"(unknown)";
        if (ApolloTiledTextShouldLog([@"failed:" stringByAppendingString:className])) {
            ApolloLog(@"[TiledText] %@ bitmap failed, redrawing it in tiles", className);
        }
        [textNode setNeedsDisplay];
    });
}

BOOL ApolloTiledTextNodeIsTiled(id node) {
    return node && objc_getAssociatedObject(node, kApolloTiledTextLayerKey) != nil;
}
