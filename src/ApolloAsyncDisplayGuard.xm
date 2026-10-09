// Keeps AsyncDisplayKit's background display pass from taking the process down
// when a node's bitmap cannot be created (#1097), and draws text too large for
// one bitmap in tiles instead of leaving it blank (#1354).
//
// Every drawRect-based node (ASTextNode, Apollo's own nodes) and every
// ASImageNode renders through ASGraphicsCreateImage, which in Apollo's Texture
// build still goes through the legacy UIGraphicsBeginImageContextWithOptions.
// When CGBitmapContextCreate fails in there, UIKit's reaction depends on the
// SDK the executable was linked against (UIGraphics.m:410, gated on
// dyld_program_sdk_at_least): older link targets get no context and a blank
// node, newer ones hit an NSAssert that raises NSInternalInconsistencyException
// ("UIGraphicsBeginImageContext() failed to allocate CGBitampContext: size=...
// Use UIGraphicsImageRenderer to avoid this assert."). The Liquid Glass IPA
// relinks Apollo against the iOS 26 SDK, so on glass builds that assert fires,
// on a display-queue thread where nothing catches it, and the process is
// terminated.
//
// The tweak already catches this for ASImageNode contents
// (+[ASImageNode createContentsForkey:...] in ApolloMedia.xm). This module
// extends the same protection to the display block every other node kind runs,
// and additionally refuses to start a display whose bitmap would be absurdly
// large. #1097 (3.6.0 glass, iOS 26.6.1) died with the assert on one display
// thread while the main thread aborted inside CA::Render::Encoder::grow while
// encoding a layer's image contents: both are what a node whose bounds have
// blown up to a gigabyte-class bitmap looks like, and a bitmap that size can
// never be shown anyway. Skipping it costs one blank node instead of the app.
//
// Real text gets there too, though. A post body is one MarkdownTextNode, and
// at Apollo's largest text sizes a 20,000-character post passes the budget on
// a phone (#1354: 400 x 18,119 pt at 3x is 65 MP), so the guard blanked the
// body. Below the budget, a long body's bitmap can still fail to allocate once
// the app has been open a while. Text nodes over the budget, and text nodes
// whose bitmap failed, are drawn by ApolloTiledText instead: a tiled sublayer
// that only ever draws what is on screen.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

#import "ApolloAsyncDisplayGuard.h"
#import "ApolloCommon.h"
#import "ApolloTextureDecls.h"
#import "ApolloTiledText.h"

@interface ASDisplayNode (ApolloAsyncDisplayGuard)
- (CGRect)bounds;
- (CGFloat)contentsScaleForDisplay;
- (CALayer *)layer;
@end

// 64 million pixels is about 256 MB of RGBA: an 8000 x 8000 px square, or on
// a 3x phone a 400 pt column about 17,800 pt tall. Only text gets that tall
// (a 40,000-character selftext at the largest text size is near twice that),
// and text over the budget is tiled rather than skipped.
static const double kApolloDisplayGuardDefaultMaxPixels = 64.0 * 1000.0 * 1000.0;
static double sApolloDisplayGuardMaxPixels = kApolloDisplayGuardDefaultMaxPixels;

double ApolloAsyncDisplayGuardMaxPixels(void) {
    return sApolloDisplayGuardMaxPixels;
}

void ApolloAsyncDisplayGuardSetMaxPixelsForTesting(double maxPixels) {
    sApolloDisplayGuardMaxPixels = maxPixels > 0 ? maxPixels : kApolloDisplayGuardDefaultMaxPixels;
    ApolloLog(@"[AsyncDisplayGuard] max pixels now %.0f", sApolloDisplayGuardMaxPixels);
}

typedef id (^ApolloAsyncDisplayBlock)(void);

// Texture's synchronous display, -recursivelyEnsureDisplaySynchronously:YES
// (Apollo's cells never show placeholders, so every cell runs it as it comes
// on screen; the tweak runs it after a vote, a translation or a new comment),
// still starts each node's display pass with asynchronous YES and then blocks
// until it lands. Nesting depth, so the tiled path knows it is being waited
// on. Main thread only, like Texture's display passes.
static NSUInteger sApolloDisplayGuardSynchronousDepth = 0;

// One log line per node class and reason per launch: a runaway layout re-runs
// display for the same node on every frame, and the display queue is hot.
static BOOL ApolloDisplayGuardShouldLog(NSString *key) {
    static NSMutableSet<NSString *> *logged;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logged = [NSMutableSet set]; });
    @synchronized (logged) {
        if ([logged containsObject:key]) return NO;
        [logged addObject:key];
        return YES;
    }
}

%hook ASDisplayNode

// Called on the main thread once per display pass; the returned block runs on
// a display-queue thread (or inline for synchronous display).
- (id)_displayBlockWithAsynchronous:(BOOL)asynchronous isCancelledBlock:(id)isCancelledBlock rasterizing:(BOOL)rasterizing {
    ApolloAsyncDisplayBlock block = %orig;
    if (!block) {
        // Nothing to draw (a text node does this only at an empty size): tiles
        // left from an earlier pass would otherwise stay on screen.
        ApolloTiledTextDropTiles(self);
        return nil;
    }

    // The same bounds and scale ASDK just captured for the block.
    CGRect bounds = [self bounds];
    CGFloat scale = [self respondsToSelector:@selector(contentsScaleForDisplay)] ? [self contentsScaleForDisplay] : 0;
    // Fallback: the scale of the layer being displayed (this method runs on the
    // main thread for a node whose layer is already loaded, since the layer is what
    // asked for display). Never the node's view/traitCollection: layer-backed
    // nodes have no view. A layer reporting no usable scale leaves pixels at 0,
    // which simply lets the display through unguarded.
    if (!(scale > 0) || !isfinite(scale)) scale = [self layer].contentsScale;
    double width = bounds.size.width;
    double height = bounds.size.height;
    double pixels = width * scale * height * scale;
    BOOL finite = isfinite(width) && isfinite(height) && isfinite(pixels);
    Class nodeClass = [self class];

    // Text over the budget, or whose bitmap failed on an earlier pass, is
    // drawn by its tiled sublayer (ApolloTiledText): this pass then has no
    // bitmap of its own to make. Every other node continues as before.
    BOOL synchronous = !asynchronous || sApolloDisplayGuardSynchronousDepth > 0;
    if (ApolloTiledTextTakeOverDisplay(self, bounds, scale, finite && pixels > sApolloDisplayGuardMaxPixels, rasterizing, synchronous)) {
        return ^id{ return nil; };
    }

    if (!finite || pixels > sApolloDisplayGuardMaxPixels) {
        NSString *className = NSStringFromClass(nodeClass) ?: @"(unknown)";
        if (ApolloDisplayGuardShouldLog([@"skip:" stringByAppendingString:className])) {
            ApolloLog(@"[AsyncDisplayGuard] skipped display of %@ bounds=%@ scale=%.1f (%.0f MP%@)",
                      className, NSStringFromCGRect(bounds), scale, pixels / 1e6,
                      finite ? @"" : @", non-finite");
        }
        return ^id{ return nil; };
    }

    // ASDK's block holds the node while it runs, so this weak copy is still
    // set when the block raises.
    __weak id weakNode = self;
    BOOL (^isCancelled)(void) = isCancelledBlock;
    return ^id{
        @try {
            id image = block();
            // Without the Liquid Glass relink UIKit doesn't raise when the
            // bitmap can't be allocated; the block just comes back empty.
            // Empty and not cancelled (a superseded pass also returns nil)
            // is that failure, and a text node is redrawn in tiles too.
            if (!image && isCancelled && !isCancelled()) ApolloTiledTextNoteBitmapFailure(weakNode);
            return image;
        } @catch (NSException *exception) {
            NSString *className = NSStringFromClass(nodeClass) ?: @"(unknown)";
            if (ApolloDisplayGuardShouldLog([@"throw:" stringByAppendingString:className])) {
                ApolloLog(@"[AsyncDisplayGuard] display of %@ raised %@: %@ (node left blank)",
                          className, exception.name ?: @"(nil)", exception.reason ?: @"(nil)");
            }
            // A text node doesn't stay blank: it is redrawn in tiles.
            ApolloTiledTextNoteBitmapFailure(weakNode);
            return nil;
        }
    };
}

- (void)recursivelyEnsureDisplaySynchronously:(BOOL)synchronously {
    if (!synchronously) {
        %orig;
        return;
    }
    sApolloDisplayGuardSynchronousDepth++;
    @try {
        %orig;
    } @finally {
        sApolloDisplayGuardSynchronousDepth--;
    }
}

%end

%ctor {
    %init;
    ApolloLog(@"[AsyncDisplayGuard] module loaded (max %.0f MP, text over it drawn in tiles)", sApolloDisplayGuardMaxPixels / 1e6);
}
