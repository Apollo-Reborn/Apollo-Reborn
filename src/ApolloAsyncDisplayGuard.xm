// Keeps AsyncDisplayKit's background display pass from taking the process down
// when a node's bitmap cannot be created (#1097).
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

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

#import "ApolloAsyncDisplayGuard.h"
#import "ApolloCommon.h"
#import "ApolloTextureDecls.h"

@interface ASDisplayNode (ApolloAsyncDisplayGuard)
- (CGRect)bounds;
- (CGFloat)contentsScaleForDisplay;
@end

// 64 million pixels is about 256 MB of RGBA: an 8000 x 8000 px square, or on
// a 3x phone a column about 17,000 pt tall (Reddit's 40,000 character selftext
// limit lays out to roughly 10,000 pt). Nothing Apollo shows comes close.
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
    if (!block) return nil;

    // The same bounds and scale ASDK just captured for the block.
    CGRect bounds = [self bounds];
    CGFloat scale = [self respondsToSelector:@selector(contentsScaleForDisplay)] ? [self contentsScaleForDisplay] : 0;
    if (!(scale > 0) || !isfinite(scale)) scale = UIScreen.mainScreen.scale;
    double width = bounds.size.width;
    double height = bounds.size.height;
    double pixels = width * scale * height * scale;
    BOOL finite = isfinite(width) && isfinite(height) && isfinite(pixels);
    Class nodeClass = [self class];

    if (!finite || pixels > sApolloDisplayGuardMaxPixels) {
        NSString *className = NSStringFromClass(nodeClass) ?: @"(unknown)";
        if (ApolloDisplayGuardShouldLog([@"skip:" stringByAppendingString:className])) {
            ApolloLog(@"[AsyncDisplayGuard] skipped display of %@ bounds=%@ scale=%.1f (%.0f MP%@)",
                      className, NSStringFromCGRect(bounds), scale, pixels / 1e6,
                      finite ? @"" : @", non-finite");
        }
        return ^id{ return nil; };
    }

    return ^id{
        @try {
            return block();
        } @catch (NSException *exception) {
            NSString *className = NSStringFromClass(nodeClass) ?: @"(unknown)";
            if (ApolloDisplayGuardShouldLog([@"throw:" stringByAppendingString:className])) {
                ApolloLog(@"[AsyncDisplayGuard] display of %@ raised %@: %@ (node left blank)",
                          className, exception.name ?: @"(nil)", exception.reason ?: @"(nil)");
            }
            return nil;
        }
    };
}

%end

%ctor {
    %init;
    ApolloLog(@"[AsyncDisplayGuard] module loaded (max %.0f MP)", sApolloDisplayGuardMaxPixels / 1e6);
}
