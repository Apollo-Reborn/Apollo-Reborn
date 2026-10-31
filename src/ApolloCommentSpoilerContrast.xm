#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

#import "ApolloCommentSpoilerContrast.h"
#import "ApolloThemeRuntime.h"

typedef void (^ApolloMarkdownRenderingBlock)(CGContextRef context, id drawParameters);

@interface _TtC6Apollo16MarkdownTextNode : NSObject
@property (nonatomic, readonly) UITraitCollection *traitCollection;
- (void)setDidDisplayNodeContentWithRenderingContext:(id)block;
@end

typedef struct {
    BOOL active;
    uint32_t surfaceRGB;
} ApolloSpoilerFillContext;

static __thread ApolloSpoilerFillContext sApolloSpoilerFillContext;
static const void *kApolloSpoilerWrappedBlockKey = &kApolloSpoilerWrappedBlockKey;
static const void *kApolloSpoilerWrappedBlockMarker = &kApolloSpoilerWrappedBlockMarker;

static NSUserDefaults *ApolloSpoilerGroupDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"];
    });
    return defaults;
}

static UITraitCollection *ApolloSpoilerDarkTraits(void) {
    static UITraitCollection *traits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        traits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
    });
    return traits;
}

static BOOL ApolloSpoilerRGB(UIColor *color, UITraitCollection *traits, uint32_t *outRGB) {
    if (!color || !outRGB) return NO;
    UIColor *resolved = [color resolvedColorWithTraitCollection:traits];
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![resolved getRed:&red green:&green blue:&blue alpha:&alpha] || alpha < 0.99) return NO;
    uint32_t r = (uint32_t)lround(fmax(0.0, fmin(1.0, red)) * 255.0);
    uint32_t g = (uint32_t)lround(fmax(0.0, fmin(1.0, green)) * 255.0);
    uint32_t b = (uint32_t)lround(fmax(0.0, fmin(1.0, blue)) * 255.0);
    *outRGB = (r << 16) | (g << 8) | b;
    return YES;
}

static ApolloSpoilerFillContext ApolloSpoilerContextForNode(id node) {
    ApolloSpoilerFillContext context = { NO, 0 };
    UITraitCollection *traits = [node respondsToSelector:@selector(traitCollection)]
        ? [node traitCollection] : UITraitCollection.currentTraitCollection;
    if (traits.userInterfaceStyle != UIUserInterfaceStyleDark
        || ApolloThemeRuntimeIsActive()
        || ![ApolloSpoilerGroupDefaults() boolForKey:@"UsePureBlackDarkMode"]) {
        return context;
    }

    UIColor *surface = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    uint32_t surfaceRGB = 0;
    if (!ApolloSpoilerRGB(surface, traits, &surfaceRGB)) return context;
    context.active = YES;
    context.surfaceRGB = surfaceRGB;
    return context;
}

%hook _TtC6Apollo16MarkdownTextNode

- (void)setDidDisplayNodeContentWithRenderingContext:(id)block {
    if (!block) {
        objc_setAssociatedObject(self, kApolloSpoilerWrappedBlockKey, nil,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        %orig(nil);
        return;
    }

    // Find in Comments restores the rendering block that preceded its match
    // highlight. Recognise any wrapper created here, not just the currently
    // installed one, so repeated search sessions cannot accumulate wrappers.
    if ([objc_getAssociatedObject(block, kApolloSpoilerWrappedBlockMarker) boolValue]) {
        objc_setAssociatedObject(self, kApolloSpoilerWrappedBlockKey, block,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        %orig(block);
        return;
    }

    // MarkdownTextNode retains this block. Keep the node weak so composing
    // with Apollo's native renderer (and Find in Comments' replacements) does
    // not add a node -> block -> node cycle.
    __weak id weakNode = self;
    ApolloMarkdownRenderingBlock original = [block copy];
    ApolloMarkdownRenderingBlock wrapper = ^(CGContextRef context, id drawParameters) {
        id node = weakNode;
        ApolloSpoilerFillContext previous = sApolloSpoilerFillContext;
        sApolloSpoilerFillContext = ApolloSpoilerContextForNode(node);
        @try {
            original(context, drawParameters);
        } @finally {
            sApolloSpoilerFillContext = previous;
        }
    };
    objc_setAssociatedObject(wrapper, kApolloSpoilerWrappedBlockMarker, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kApolloSpoilerWrappedBlockKey, wrapper,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    %orig(wrapper);
}

%end

%hook UIColor

- (void)setFill {
    ApolloSpoilerFillContext context = sApolloSpoilerFillContext;
    if (context.active) {
        uint32_t fillRGB = 0;
        UITraitCollection *traits = ApolloSpoilerDarkTraits();
        if (ApolloSpoilerRGB(self, traits, &fillRGB)) {
            uint32_t adjusted = ApolloCommentSpoilerAdjustedFillRGB(
                fillRGB, context.surfaceRGB, true, true);
            if (adjusted != fillRGB) {
                UIColor *replacement = [UIColor colorWithRed:((adjusted >> 16) & 0xff) / 255.0
                                                       green:((adjusted >> 8) & 0xff) / 255.0
                                                        blue:(adjusted & 0xff) / 255.0
                                                       alpha:1.0];
                sApolloSpoilerFillContext.active = NO;
                [replacement setFill];
                sApolloSpoilerFillContext = context;
                return;
            }
        }
    }
    %orig;
}

%end
