// ApolloInlineImages.xm
//
// Renders image URLs inside Apollo's selftext / comment markdown bodies as
// actual inline images, replacing the URL text in-place. Tap opens
// MediaViewer (via Apollo's tappedLinkAttribute path); long-press shows
// Copy Link / Share / Open in Safari (UIContextMenuInteraction wins over
// Apollo's cell-level menu since it's installed on the deeper view).
//
// See plan.md for a full architecture writeup including the layout-storm
// fix (element-pointer identity caching), the gap-on-load fix (omit images
// from layout until aspect ratio is known, then call
// _u_setNeedsLayoutFromAbove), and the @"ApolloLink" attribute key
// requirement (RE'd from MarkdownNode's tap dispatch).

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MARK: - Minimal Texture forward declarations
// We don't import AsyncDisplayKit headers (the build doesn't have them on the
// include path). Just declare the methods/classes we need; the runtime resolves
// to the real Apollo-bundled implementations.

typedef NS_OPTIONS(NSUInteger, ApolloASControlNodeEvent) {
    ApolloASControlNodeEventTouchUpInside = 1 << 4,
};

typedef NS_ENUM(unsigned char, ApolloASStackLayoutDirection) {
    ApolloASStackLayoutDirectionVertical = 0,
    ApolloASStackLayoutDirectionHorizontal = 1,
};
typedef NS_ENUM(unsigned char, ApolloASStackLayoutJustifyContent) {
    ApolloASStackLayoutJustifyContentStart = 0,
    ApolloASStackLayoutJustifyContentCenter = 1,
    ApolloASStackLayoutJustifyContentEnd = 2,
    ApolloASStackLayoutJustifyContentSpaceBetween = 3,
    ApolloASStackLayoutJustifyContentSpaceAround = 4,
};
typedef NS_ENUM(unsigned char, ApolloASStackLayoutAlignItems) {
    ApolloASStackLayoutAlignItemsStart = 0,
    ApolloASStackLayoutAlignItemsEnd = 1,
    ApolloASStackLayoutAlignItemsCenter = 2,
    ApolloASStackLayoutAlignItemsStretch = 3,
};
typedef NS_ENUM(unsigned char, ApolloASStackLayoutAlignSelf) {
    ApolloASStackLayoutAlignSelfAuto = 0,
    ApolloASStackLayoutAlignSelfStart = 1,
    ApolloASStackLayoutAlignSelfEnd = 2,
    ApolloASStackLayoutAlignSelfCenter = 3,
    ApolloASStackLayoutAlignSelfStretch = 4,
};

@class ASLayoutSpec;
@class ASStackLayoutSpec;
@class ASRatioLayoutSpec;
@class ASInsetLayoutSpec;
@class ASNetworkImageNode;
@class ASTextNode;
@class ASDisplayNode;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)removeFromSupernode;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (void)invalidateCalculatedLayout;
- (id)style;
- (UIView *)view;
- (BOOL)isNodeLoaded;
- (void)onDidLoad:(void(^)(__kindof ASDisplayNode *node))body;
@property (nonatomic) BOOL userInteractionEnabled;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nullable, weak) id delegate;
@property (copy) NSArray<NSString *> *linkAttributeNames;
@property (nonatomic) BOOL passthroughNonlinkTouches;
@property (nonatomic) BOOL longPressCancelsTouches;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nullable, nonatomic, strong) UIImage *image;
@property (nullable, weak) id delegate;
@property (nonatomic) BOOL shouldRenderProgressImages;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) BOOL placeholderEnabled;
@property (nonatomic, copy) UIColor *placeholderColor;
@property (nonatomic) CGFloat placeholderFadeDuration;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) CGFloat borderWidth;
@property (nonatomic) CGColorRef borderColor;
@property (nullable) id animatedImage;
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(ApolloASControlNodeEvent)events;
@end

@interface ASLayoutSpec : NSObject
@property (nullable, nonatomic) NSArray *children;
- (id)style;
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloASStackLayoutDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloASStackLayoutJustifyContent justifyContent;
@property (nonatomic) ApolloASStackLayoutAlignItems alignItems;
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) NSUInteger alignContent;
@property (nonatomic) CGFloat lineSpacing;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloASStackLayoutDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloASStackLayoutJustifyContent)justifyContent
                                  alignItems:(ApolloASStackLayoutAlignItems)alignItems
                                    children:(NSArray *)children;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

// ASSizeRange (named CDStruct_90e057aa in Apollo's class-dumped headers).
struct CDStruct_90e057aa { CGSize min; CGSize max; };

// MARK: - Associated-object keys

static char kApolloDecompositionMapKey;        // NSDictionary<NSValue (non-retained orig text node ptr), NSArray<id leaf>>
static char kApolloCachedOrigChildrenKey;      // NSArray (held strongly so element pointers stay valid for compare)
static char kApolloImageNodesByURLKey;         // NSMutableDictionary<NSString URL, ASNetworkImageNode> per-MarkdownNode reuse cache
static char kApolloImageURLKey;                // NSURL on the imageNode AND mirrored on the imageNode's view
static char kApolloHostMarkdownNodeKey;        // weak ref (assign association) to the host MarkdownNode
static char kApolloAspectRatioKey;             // NSNumber height/width — NIL if unknown (no URL params yet, no DIDLOAD yet)
static char kApolloLongPressInstalledKey;      // NSNumber BOOL — gate for one-shot UIContextMenuInteraction install
static char kApolloVideoThumbnailKey;          // NSNumber BOOL — imageNode is our generated video thumbnail
static char kApolloPlayOverlayInstalledKey;    // NSNumber BOOL — play-button UIImageView already added to view
static char kApolloPlayOverlayViewKey;         // UIImageView play overlay on video thumbnail view
static char kApolloVideoPosterViewKey;         // UIImageView generated poster on video thumbnail view
static char kApolloPendingVideoPosterImageKey; // UIImage to apply once thumbnail view is loaded

// MARK: - Class lookups (cached)

static Class ApolloASStackLayoutSpecClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASStackLayoutSpec"); });
    return c;
}
static Class ApolloASRatioLayoutSpecClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASRatioLayoutSpec"); });
    return c;
}
static Class ApolloASInsetLayoutSpecClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASInsetLayoutSpec"); });
    return c;
}
static Class ApolloASTextNodeClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASTextNode"); });
    return c;
}
static Class ApolloASNetworkImageNodeClass(void) {
    static Class c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"ASNetworkImageNode"); });
    return c;
}

// MARK: - Image URL classification & normalization

static BOOL ApolloIsInlineRenderableImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [[url host] lowercaseString];
    if (host.length == 0) return NO;

    NSString *ext = [[[url path] pathExtension] lowercaseString];
    static NSSet *imageExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        imageExts = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", @"gif", nil];
    });
    if (![imageExts containsObject:ext]) return NO;

    // Skip Reddit's pseudo-MP4 GIFs — the path ends in .gif but the query
    // says format=mp4, so the bytes returned are MP4 video, not a GIF.
    // PINRemoteImage can't decode them as image or animated image, leaving
    // an empty grey container. Let the LinkButtonNode preview handle these.
    NSString *q = [[url query] lowercaseString];
    if ([q containsString:@"format=mp4"]) return NO;

    // Allowlist of trusted parent domains. A host matches if it equals
    // a parent domain or is a subdomain of one. Curated to cover common
    // image hosts in Reddit comments while keeping random tracker pixels
    // and arbitrary image-extensioned URLs out (privacy + bandwidth).
    static NSArray<NSString *> *allowedParentDomains;
    static dispatch_once_t hostsOnce;
    dispatch_once(&hostsOnce, ^{
        allowedParentDomains = @[
            @"redd.it",
            @"imgur.com",
            @"giphy.com",
            @"tenor.com",
            @"redgifs.com",
            @"twimg.com",
            @"discordapp.com",
            @"discordapp.net",
        ];
    });
    for (NSString *parent in allowedParentDomains) {
        if ([host isEqualToString:parent]) return YES;
        if ([host hasSuffix:[@"." stringByAppendingString:parent]]) return YES;
    }
    return NO;
}

static BOOL ApolloHostMatchesAnyParentDomain(NSString *host, NSArray<NSString *> *parentDomains) {
    if (host.length == 0) return NO;
    for (NSString *parent in parentDomains) {
        if ([host isEqualToString:parent]) return YES;
        if ([host hasSuffix:[@"." stringByAppendingString:parent]]) return YES;
    }
    return NO;
}

static BOOL ApolloIsInlineRenderableVideoURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [[url host] lowercaseString];
    if (host.length == 0) return NO;

    static NSArray<NSString *> *allowedParentDomains;
    static NSSet<NSString *> *videoExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowedParentDomains = @[
            @"redd.it",
            @"reddit.com",
            @"redgifs.com",
            @"streamable.com",
            @"gfycat.com",
        ];
        videoExts = [NSSet setWithObjects:@"mp4", @"webm", @"mov", @"gifv", nil];
    });

    if (!ApolloHostMatchesAnyParentDomain(host, allowedParentDomains)) return NO;

    NSString *path = [[url path] lowercaseString] ?: @"";
    NSString *ext = [[url path] pathExtension].lowercaseString ?: @"";
    NSString *q = [[url query] lowercaseString] ?: @"";

    if ([host isEqualToString:@"v.redd.it"] && path.length > 1) return YES;
    if ([videoExts containsObject:ext]) return YES;

    // Reddit exposes some hosted videos inside selftext as
    // https://reddit.com/link/<post>/video/<asset>/player. Apollo already
    // knows how to play that link; we just replace the bare text with a
    // playable-looking thumbnail that dispatches the same ApolloLink tap.
    if (ApolloHostMatchesAnyParentDomain(host, @[@"reddit.com"]) &&
        [path hasPrefix:@"/link/"] &&
        [path containsString:@"/video/"] &&
        [path hasSuffix:@"/player"]) {
        return YES;
    }

    // Reddit's pseudo-GIF links can be .gif paths whose query returns MP4.
    // The image renderer intentionally skips these; the video thumbnail path
    // can still hand the URL to Apollo's native player.
    if (([host isEqualToString:@"i.redd.it"] || [host hasSuffix:@".redd.it"]) &&
        [ext isEqualToString:@"gif"] &&
        [q containsString:@"format=mp4"]) {
        return YES;
    }

    return NO;
}

static NSURL *ApolloNormalizeInlineImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return url;
    NSString *s = [url absoluteString];
    if (![s containsString:@"&amp;"]) return url;
    NSString *decoded = [s stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    NSURL *out = [NSURL URLWithString:decoded];
    return out ?: url;
}

// YES if the rendered text for a URL range looks like a bare URL (text
// contains the URL path, no whitespace) vs markdown link text. Bare-URL
// ranges are deleted from the trailing text since the inline image
// stands in for them; markdown-link ranges are preserved.
static BOOL ApolloRangeTextLooksLikeBareURL(NSAttributedString *attr, NSRange range, NSURL *url) {
    if (range.location + range.length > attr.string.length) return NO;
    NSString *text = [[attr.string substringWithRange:range]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *path = url.path;
    if (text.length == 0 || path.length == 0) return NO;
    if ([text rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) return NO;
    return [text rangeOfString:path].location != NSNotFound;
}

static CGFloat ApolloAspectRatioFromURL(NSURL *url) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *w = nil, *h = nil;
    for (NSURLQueryItem *q in c.queryItems) {
        NSString *name = [q.name lowercaseString];
        if ([name isEqualToString:@"width"] || [name isEqualToString:@"w"]) w = q.value;
        else if ([name isEqualToString:@"height"] || [name isEqualToString:@"h"]) h = q.value;
    }
    if (w.length == 0 || h.length == 0) return 0;
    double wv = [w doubleValue], hv = [h doubleValue];
    if (wv <= 0 || hv <= 0) return 0;
    // No clamping here — the layout-time wrapper applies the real bounds
    // (kApolloMin/MaxContainerRatio). Returning the raw ratio also lets
    // the wrapper detect "letterboxed" correctly for the border toggle.
    return (CGFloat)(hv / wv);
}

// MARK: - Tap dispatcher + UIContextMenuInteraction delegate (singleton)

@interface ApolloInlineImageDispatcher : NSObject <UIContextMenuInteractionDelegate>
+ (instancetype)shared;
- (void)imageNodeTapped:(id)sender;
- (void)imageNode:(id)imageNode didLoadImage:(UIImage *)image;
- (void)updateAspectRatioForImageNode:(id)imageNode imageSize:(CGSize)size;
@end

@implementation ApolloInlineImageDispatcher

+ (instancetype)shared {
    static ApolloInlineImageDispatcher *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ApolloInlineImageDispatcher alloc] init]; });
    return s;
}

// Walk supernodes from `imageNode` searching for an object responding to
// `sel`. Returns the first match or nil.
static id ApolloFindResponderForSelector(SEL sel, id imageNode) {
    id cursor = imageNode;
    for (int hops = 0; cursor && hops < 24; hops++) {
        if ([cursor respondsToSelector:sel]) return cursor;
        if (![cursor respondsToSelector:@selector(supernode)]) break;
        cursor = [cursor performSelector:@selector(supernode)];
    }
    return nil;
}

- (void)imageNodeTapped:(id)imageNode {
    NSURL *url = objc_getAssociatedObject(imageNode, &kApolloImageURLKey);
    if (![url isKindOfClass:[NSURL class]]) return;

    ASDisplayNode *host = objc_getAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey);
    SEL sel = @selector(textNode:tappedLinkAttribute:value:atPoint:textRange:);
    id target = ApolloFindResponderForSelector(sel, imageNode) ?: ([host respondsToSelector:sel] ? host : nil);
    if (!target) {
        ApolloLog(@"[InlineImages] tap: no responder for %@", url);
        return;
    }

    // Apollo's MarkdownNode tap handler (sub_10042ddf8) only routes URLs to
    // MediaViewer when attr is the swift_once-initialized "ApolloLink"
    // string; NSLinkAttributeName etc. are silently ignored.
    id textArg = host ?: target;
    void (*msgSend)(id, SEL, id, id, id, CGPoint, NSRange) =
        (void (*)(id, SEL, id, id, id, CGPoint, NSRange))objc_msgSend;
    msgSend(target, sel, textArg, @"ApolloLink", url,
            CGPointZero, NSMakeRange(NSNotFound, 0));
}

#pragma mark - UIContextMenuInteractionDelegate

// Find the topmost presented view controller from a view in the hierarchy.
static UIViewController *ApolloTopVCFromView(UIView *v) {
    UIWindow *window = v.window;
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                       configurationForMenuAtLocation:(CGPoint)location {
    UIView *v = interaction.view;
    if (!v) return nil;
    NSURL *url = objc_getAssociatedObject(v, &kApolloImageURLKey);
    if (![url isKindOfClass:[NSURL class]]) return nil;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        __weak UIView *weakView = v;
        UIAction *copy = [UIAction actionWithTitle:@"Copy Link"
                                              image:[UIImage systemImageNamed:@"doc.on.doc"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            UIPasteboard.generalPasteboard.URL = url;
        }];
        UIAction *share = [UIAction actionWithTitle:@"Share…"
                                               image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                           identifier:nil
                                             handler:^(__kindof UIAction *a) {
            UIView *vv = weakView;
            UIActivityViewController *avc = [[UIActivityViewController alloc]
                initWithActivityItems:@[url] applicationActivities:nil];
            UIViewController *top = ApolloTopVCFromView(vv);
            if (top) {
                avc.popoverPresentationController.sourceView = vv;
                avc.popoverPresentationController.sourceRect = vv.bounds;
                [top presentViewController:avc animated:YES completion:nil];
            }
        }];
        UIAction *open = [UIAction actionWithTitle:@"Open in Safari"
                                              image:[UIImage systemImageNamed:@"safari"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }];
        return [UIMenu menuWithTitle:@"" children:@[copy, share, open]];
    }];
}

- (void)imageNode:(id)imageNode didLoadImage:(UIImage *)image {
    ApolloLog(@"[InlineImages] DIDLOAD imageNode=%p hasImage=%d size=%@ url=%@",
              imageNode, image != nil, image ? NSStringFromCGSize(image.size) : @"nil",
              [imageNode respondsToSelector:@selector(URL)] ? [(ASNetworkImageNode *)imageNode URL] : nil);
    if (!image || image.size.width <= 0 || image.size.height <= 0) return;
    [self updateAspectRatioForImageNode:imageNode imageSize:image.size];
}

// Update cached aspect ratio + trigger layout-from-above if it changed.
// Called from didLoadImage: (static images) and from our _locked_setAnimatedImage:
// hook below (GIFs / animated images, where didLoadImage: doesn't fire).
- (void)updateAspectRatioForImageNode:(id)imageNode imageSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    CGFloat newRatio = size.height / size.width;
    NSNumber *cur = objc_getAssociatedObject(imageNode, &kApolloAspectRatioKey);
    if (cur && fabs(newRatio - [cur doubleValue]) < 0.01) return;
    objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(newRatio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[InlineImages] ratio set imageNode=%p ratio=%.3f size=%@",
              imageNode, newRatio, NSStringFromCGSize(size));

    // Texture's internal "intrinsic size changed" hook; walks up to the
    // root signaling the table/collection to re-measure the row.
    SEL sel = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
    if (![imageNode respondsToSelector:sel]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL))objc_msgSend)(imageNode, sel);
    });
}

@end

// MARK: - %hook ASImageNode (animated image — GIF support)
//
// ASNetworkImageNode bypasses the public setAnimatedImage: setter and calls
// _locked_setAnimatedImage: directly (Texture/Source/ASNetworkImageNode.mm
// lines 769, 822). Hooking the public setter never fires for GIFs. We hook
// the private locked setter, then defer our state mutation to the main
// queue so we don't touch ratio/layout while Texture holds the node lock.

%hook ASImageNode

- (void)_locked_setAnimatedImage:(id)animatedImage {
    %orig;
    if (!animatedImage) return;
    // Only act on imageNodes we created — Apollo's own GIFs (e.g. in the
    // MediaViewer) lack the host association and pass through unchanged.
    if (!objc_getAssociatedObject(self, &kApolloHostMarkdownNodeKey)) return;

    __weak ASImageNode *weakSelf = self;
    __weak id weakAnim = animatedImage;
    dispatch_async(dispatch_get_main_queue(), ^{
        ASImageNode *strong = weakSelf;
        id anim = weakAnim;
        if (!strong || !anim) return;

        UIImage *cover = nil;
        BOOL ready = YES;
        if ([anim respondsToSelector:@selector(coverImageReady)]) {
            ready = [[anim valueForKey:@"coverImageReady"] boolValue];
        }
        if (ready && [anim respondsToSelector:@selector(coverImage)]) {
            cover = [anim valueForKey:@"coverImage"];
        }
        ApolloLog(@"[InlineImages] _locked_setAnimatedImage imageNode=%p ready=%d coverSize=%@",
                  strong, ready, cover ? NSStringFromCGSize(cover.size) : @"nil");

        if (cover && cover.size.width > 0 && cover.size.height > 0) {
            [[ApolloInlineImageDispatcher shared] updateAspectRatioForImageNode:strong imageSize:cover.size];
            return;
        }
        // Cover not ready yet — install the protocol's ready callback.
        if ([anim respondsToSelector:@selector(setCoverImageReadyCallback:)]) {
            void (^cb)(UIImage *) = ^(UIImage *coverImage) {
                ApolloLog(@"[InlineImages] coverImageReadyCallback imageNode=%p coverSize=%@",
                          weakSelf, coverImage ? NSStringFromCGSize(coverImage.size) : @"nil");
                ASImageNode *s = weakSelf;
                if (!s || !coverImage || coverImage.size.width <= 0) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[ApolloInlineImageDispatcher shared] updateAspectRatioForImageNode:s imageSize:coverImage.size];
                });
            };
            [anim performSelector:@selector(setCoverImageReadyCallback:) withObject:cb];
        }
    });
}

%end

// MARK: - Image-node construction

// Forward decl: defined further down (after layout helpers). Used by
// ApolloBuildLeavesForTextNode below to look up or create the imageNode for
// a given URL via the per-MarkdownNode reuse cache.
static ASNetworkImageNode *ApolloImageNodeForURL(NSURL *normalizedURL,
                                                   ASDisplayNode *hostMarkdownNode);
static ASNetworkImageNode *ApolloVideoThumbnailNodeForURL(NSURL *normalizedURL,
                                                           ASDisplayNode *hostMarkdownNode);

static UIImage *ApolloVideoPlaceholderImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize size = CGSizeMake(640, 360);
        UIGraphicsBeginImageContextWithOptions(size, YES, 0.0);
        [[UIColor colorWithWhite:0.12 alpha:1.0] setFill];
        UIRectFill((CGRect){CGPointZero, size});
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return image;
}

// Standalone play-circle glyph (transparent background) drawn into a
// UIImageView placed over the poster so the play button stays visible no
// matter what the network image node renders underneath.
static UIImage *ApolloPlayOverlayImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGFloat side = 88.0;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGPoint center = CGPointMake(side * 0.5, side * 0.5);
        CGRect circleRect = CGRectInset(CGRectMake(0, 0, side, side), 4.0, 4.0);

        // Soft dark backing so the glyph reads on bright posters.
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 6.0, [UIColor colorWithWhite:0.0 alpha:0.55].CGColor);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.45].CGColor);
        CGContextFillEllipseInRect(ctx, circleRect);
        CGContextRestoreGState(ctx);

        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.85].CGColor);
        CGContextSetLineWidth(ctx, 2.5);
        CGContextStrokeEllipseInRect(ctx, CGRectInset(circleRect, 1.0, 1.0));

        UIBezierPath *triangle = [UIBezierPath bezierPath];
        [triangle moveToPoint:CGPointMake(center.x - 12.0, center.y - 21.0)];
        [triangle addLineToPoint:CGPointMake(center.x - 12.0, center.y + 21.0)];
        [triangle addLineToPoint:CGPointMake(center.x + 24.0, center.y)];
        [triangle closePath];
        [[UIColor whiteColor] setFill];
        [triangle fill];

        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return image;
}

// MARK: - Reddit JSON poster lookup

// Extracts the post id from a /link/<postid>/video/<asset>/player URL, the
// only Reddit video form we have a stable poster source for. Returns nil
// for v.redd.it/<id> direct URLs (no post context to look up).
static NSString *ApolloRedditPostIDFromVideoURL(NSURL *url) {
    NSString *host = [[url host] lowercaseString] ?: @"";
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;
    NSString *path = [url path] ?: @"";
    NSArray<NSString *> *comps = [path componentsSeparatedByString:@"/"];
    // Expect: ["", "link", "<postid>", "video", "<asset>", "player"]
    if (comps.count >= 5 &&
        [comps[1] isEqualToString:@"link"] &&
        comps[2].length > 0 &&
        [comps[3] isEqualToString:@"video"]) {
        return comps[2];
    }
    return nil;
}

// Asset id is the 5th path component when present.
static NSString *ApolloRedditAssetIDFromVideoURL(NSURL *url) {
    NSString *path = [url path] ?: @"";
    NSArray<NSString *> *comps = [path componentsSeparatedByString:@"/"];
    if (comps.count >= 5 &&
        [comps[1] isEqualToString:@"link"] &&
        [comps[3] isEqualToString:@"video"]) {
        return comps[4];
    }
    return nil;
}

// Cache & request coalescing: the resolved value can be either a UIImage
// (for video posters generated via AVAssetImageGenerator) or an NSURL (for
// image-type media_metadata entries, where the network image node can fetch
// it itself). NSNull means "we tried and failed".
static NSMutableDictionary *sApolloPosterCacheByKey;        // cacheKey -> UIImage | NSURL | NSNull
static NSMutableDictionary *sApolloPosterPendingByKey;      // cacheKey -> NSMutableArray<void(^)(id)>
static dispatch_queue_t sApolloPosterQueue;

static void ApolloPosterCacheInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sApolloPosterCacheByKey = [NSMutableDictionary dictionary];
        sApolloPosterPendingByKey = [NSMutableDictionary dictionary];
        sApolloPosterQueue = dispatch_queue_create("ca.jeffrey.apollo.inlineposter", DISPATCH_QUEUE_SERIAL);
    });
}

static void ApolloDeliverPosterResult(NSString *cacheKey, id result) {
    dispatch_async(sApolloPosterQueue, ^{
        sApolloPosterCacheByKey[cacheKey] = result ?: (id)[NSNull null];
        NSArray *cbs = [sApolloPosterPendingByKey[cacheKey] copy];
        [sApolloPosterPendingByKey removeObjectForKey:cacheKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^c)(id) in cbs) c(result);
        });
    });
}

// Parse the smallest video representation's BaseURL from a Reddit DASH MPD.
// MPD's Representations list BaseURLs like "DASH_220.mp4" relative to the MPD.
// Returns the absolute URL to the lowest-bitrate MP4 (preserving the signed
// query string from the MPD URL, which Reddit requires).
static NSURL *ApolloLowestDashMP4URLFromMPD(NSData *mpdData, NSURL *mpdURL) {
    if (!mpdData.length || !mpdURL) return nil;
    NSString *xml = [[NSString alloc] initWithData:mpdData encoding:NSUTF8StringEncoding];
    if (!xml.length) return nil;

    // Find the first BaseURL in a video Representation. Reddit lists video reps
    // in ascending bitrate order, so the first BaseURL after a video AdaptationSet
    // header is the smallest. Audio reps live in a separate AdaptationSet that comes
    // later, so this is safe.
    NSRange videoSet = [xml rangeOfString:@"contentType=\"video\""];
    if (videoSet.location == NSNotFound) {
        // Fallback: any BaseURL ending in .mp4
        videoSet = NSMakeRange(0, xml.length);
    } else {
        videoSet = NSMakeRange(videoSet.location, xml.length - videoSet.location);
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<BaseURL>([^<]+\\.mp4)</BaseURL>"
                                                                       options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:videoSet];
    if (!m || m.numberOfRanges < 2) return nil;
    NSString *segName = [xml substringWithRange:[m rangeAtIndex:1]];
    if (!segName.length) return nil;

    // Build sibling URL: same path-dir as the MPD, same query string.
    NSURLComponents *comps = [NSURLComponents componentsWithURL:mpdURL resolvingAgainstBaseURL:NO];
    NSString *path = comps.path ?: @"";
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (dir.length == 0 || ![dir hasSuffix:@"/"]) dir = [dir stringByAppendingString:@"/"];
    comps.path = [dir stringByAppendingString:segName];
    return comps.URL;
}

// Generate a still frame for a Reddit video by:
//   1. Fetching the DASH MPD to discover the lowest-bitrate MP4 segment URL.
//   2. Pointing AVAssetImageGenerator at that MP4 (HTTP byte-range works
//      reliably for MP4, unlike HLS which requires a full player session).
static void ApolloGenerateVideoPosterImage(NSURL *dashMPDURL, NSString *cacheKey) {
    NSMutableURLRequest *mpdReq = [NSMutableURLRequest requestWithURL:dashMPDURL
                                                          cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                      timeoutInterval:8.0];
    [mpdReq setValue:@"ApolloImprovedCustomApi/inline-video-thumbnail" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *mpdTask = [[NSURLSession sharedSession] dataTaskWithRequest:mpdReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status < 200 || status >= 300 || !data.length) {
            ApolloLog(@"[InlineImages] poster gen: MPD fetch FAIL status=%ld err=%@",
                      (long)status, error.localizedDescription ?: @"nil");
            ApolloDeliverPosterResult(cacheKey, nil);
            return;
        }
        NSURL *mp4URL = ApolloLowestDashMP4URLFromMPD(data, dashMPDURL);
        if (!mp4URL) {
            ApolloLog(@"[InlineImages] poster gen: no BaseURL in MPD");
            ApolloDeliverPosterResult(cacheKey, nil);
            return;
        }
        ApolloLog(@"[InlineImages] poster gen: using mp4=%@", mp4URL);

        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mp4URL options:nil];
        [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
            NSError *err = nil;
            AVKeyValueStatus tracksStatus = [asset statusOfValueForKey:@"tracks" error:&err];
            if (tracksStatus != AVKeyValueStatusLoaded) {
                ApolloLog(@"[InlineImages] poster gen: asset load FAIL status=%ld err=%@",
                          (long)tracksStatus, err.localizedDescription ?: @"nil");
                ApolloDeliverPosterResult(cacheKey, nil);
                return;
            }
            AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
            gen.appliesPreferredTrackTransform = YES;
            // Tight tolerance so we land near the requested time. Reddit videos
            // often have ~2s of black/fade-in at the head (e.g. logo intros);
            // grab progressively later frames and pick the first non-mostly-black
            // one.
            gen.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(0.5, 600);
            gen.requestedTimeToleranceAfter  = CMTimeMakeWithSeconds(0.5, 600);

            CMTime duration = asset.duration;
            Float64 durSec = CMTIME_IS_NUMERIC(duration) ? CMTimeGetSeconds(duration) : 0;
            // Candidate times: 3s, 5s, 1.5s, 0.5s, 0s. Skip any past duration.
            NSMutableArray<NSValue *> *times = [NSMutableArray array];
            for (NSNumber *t in @[@3.0, @5.0, @1.5, @0.5, @0.0]) {
                Float64 v = t.doubleValue;
                if (durSec <= 0 || v < durSec) {
                    [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(v, 600)]];
                }
            }
            if (times.count == 0) {
                [times addObject:[NSValue valueWithCMTime:kCMTimeZero]];
            }

            __block BOOL delivered = NO;
            __block UIImage *bestFallback = nil;     // any successful frame, even if dark
            __block NSInteger remaining = (NSInteger)times.count;
            // Retain generator until callback completes.
            __block AVAssetImageGenerator *retainedGen = gen;

            // Quick darkness check on a tiny downsample (32x32 -> avg luminance).
            // If the frame is essentially black we keep looking; if all candidates
            // are dark we still deliver the latest one we got.
            BOOL (^isMostlyBlack)(UIImage *) = ^BOOL(UIImage *img) {
                if (!img) return YES;
                CGSize sz = CGSizeMake(32, 32);
                UIGraphicsBeginImageContextWithOptions(sz, YES, 1);
                [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
                UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                CGImageRef cg = small.CGImage;
                if (!cg) return NO;
                size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                uint8_t *buf = (uint8_t *)calloc(w * h * 4, 1);
                CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                    kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
                CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
                uint64_t sum = 0;
                for (size_t i = 0; i < w * h; i++) {
                    uint8_t r = buf[i*4], g = buf[i*4+1], b = buf[i*4+2];
                    sum += (r * 299 + g * 587 + b * 114) / 1000;
                }
                free(buf);
                CGContextRelease(ctx);
                CGColorSpaceRelease(cs);
                double avg = (double)sum / (double)(w * h);
                return avg < 12.0; // ~5% luma
            };

            [gen generateCGImagesAsynchronouslyForTimes:times
                completionHandler:^(CMTime requestedTime, CGImageRef image,
                                    CMTime actualTime, AVAssetImageGeneratorResult result, NSError *genErr) {
                @synchronized (retainedGen ?: (id)@"x") {
                    if (delivered) return;
                    remaining--;
                    if (result == AVAssetImageGeneratorSucceeded && image) {
                        UIImage *ui = [UIImage imageWithCGImage:image];
                        BOOL dark = isMostlyBlack(ui);
                        ApolloLog(@"[InlineImages] poster gen: frame at req=%.2fs actual=%.2fs size=%@ dark=%d",
                                  CMTimeGetSeconds(requestedTime), CMTimeGetSeconds(actualTime),
                                  NSStringFromCGSize(ui.size), dark);
                        if (!dark) {
                            delivered = YES;
                            retainedGen = nil;
                            ApolloDeliverPosterResult(cacheKey, ui);
                            return;
                        }
                        // remember as fallback if everything ends up dark
                        if (!bestFallback) bestFallback = ui;
                    } else if (result == AVAssetImageGeneratorFailed) {
                        ApolloLog(@"[InlineImages] poster gen: failed at %.2fs err=%@",
                                  CMTimeGetSeconds(requestedTime), genErr.localizedDescription ?: @"nil");
                    }
                    if (remaining <= 0 && !delivered) {
                        delivered = YES;
                        retainedGen = nil;
                        ApolloLog(@"[InlineImages] poster gen: all candidates exhausted, fallback=%@",
                                  bestFallback ? @"dark frame" : @"none");
                        ApolloDeliverPosterResult(cacheKey, bestFallback);
                    }
                }
            }];
        }];
    }];
    [mpdTask resume];
}

static NSURL *ApolloExtractImageURLFromMediaMetadataEntry(NSDictionary *entry) {
    NSString *kind = [entry[@"e"] isKindOfClass:[NSString class]] ? entry[@"e"] : nil;
    if (![kind isEqualToString:@"Image"]) return nil;
    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    NSString *u = [source[@"u"] isKindOfClass:[NSString class]] ? source[@"u"] : nil;
    if (!u.length) return nil;
    NSString *decoded = [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return [NSURL URLWithString:decoded];
}

static NSURL *ApolloExtractDashURLFromMediaMetadataEntry(NSDictionary *entry) {
    NSString *kind = [entry[@"e"] isKindOfClass:[NSString class]] ? entry[@"e"] : nil;
    if (![kind isEqualToString:@"RedditVideo"]) return nil;
    NSString *dash = [entry[@"dashUrl"] isKindOfClass:[NSString class]] ? entry[@"dashUrl"] : nil;
    if (!dash.length) return nil;
    NSString *decoded = [dash stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return [NSURL URLWithString:decoded];
}

// Resolve the poster for a /link/<postid>/video/<asset>/player URL. Calls back
// on the main queue with either a UIImage (video frame), an NSURL (image
// hosted by reddit), or nil (no poster available).
static void ApolloFetchRedditPoster(NSString *postID, NSString *assetID,
                                     void (^completion)(id posterURLOrImage)) {
    if (!postID.length || !completion) return;
    ApolloPosterCacheInit();
    NSString *cacheKey = [NSString stringWithFormat:@"%@/%@", postID, assetID ?: @""];
    void (^cb)(id) = [completion copy];

    dispatch_async(sApolloPosterQueue, ^{
        id cached = sApolloPosterCacheByKey[cacheKey];
        if (cached) {
            id out = (cached == [NSNull null]) ? nil : cached;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(out); });
            return;
        }
        NSMutableArray *pending = sApolloPosterPendingByKey[cacheKey];
        if (pending) { [pending addObject:cb]; return; }
        sApolloPosterPendingByKey[cacheKey] = [NSMutableArray arrayWithObject:cb];

        NSString *jsonStr = [NSString stringWithFormat:@"https://www.reddit.com/comments/%@.json?raw_json=1&limit=1", postID];
        NSURL *jsonURL = [NSURL URLWithString:jsonStr];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:jsonURL
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:8.0];
        [req setValue:@"ApolloImprovedCustomApi/inline-video-thumbnail"
   forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;

            if (error || status < 200 || status >= 300 || !data.length) {
                ApolloLog(@"[InlineImages] poster JSON fetch postID=%@ FAIL status=%ld err=%@",
                          postID, (long)status, error.localizedDescription ?: @"nil");
                ApolloDeliverPosterResult(cacheKey, nil);
                return;
            }

            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *listings = [json isKindOfClass:[NSArray class]] ? (NSArray *)json : nil;
            NSDictionary *post = nil;
            if (listings.count) {
                NSDictionary *l0 = [listings[0] isKindOfClass:[NSDictionary class]] ? listings[0] : nil;
                NSDictionary *ld = [l0[@"data"] isKindOfClass:[NSDictionary class]] ? l0[@"data"] : nil;
                NSArray *children = [ld[@"children"] isKindOfClass:[NSArray class]] ? ld[@"children"] : nil;
                if (children.count) {
                    NSDictionary *wrap = [children[0] isKindOfClass:[NSDictionary class]] ? children[0] : nil;
                    post = [wrap[@"data"] isKindOfClass:[NSDictionary class]] ? wrap[@"data"] : nil;
                }
            }
            if (!post) {
                ApolloLog(@"[InlineImages] poster JSON: no post");
                ApolloDeliverPosterResult(cacheKey, nil);
                return;
            }

            NSDictionary *mm = [post[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? post[@"media_metadata"] : nil;
            NSDictionary *entry = (assetID.length && [mm[assetID] isKindOfClass:[NSDictionary class]]) ? mm[assetID] : nil;

            if (entry) {
                NSURL *imageURL = ApolloExtractImageURLFromMediaMetadataEntry(entry);
                if (imageURL) {
                    ApolloLog(@"[InlineImages] poster JSON: image media_metadata url=%@", imageURL);
                    ApolloDeliverPosterResult(cacheKey, imageURL);
                    return;
                }
                NSURL *dashURL = ApolloExtractDashURLFromMediaMetadataEntry(entry);
                if (dashURL) {
                    ApolloLog(@"[InlineImages] poster JSON: video media_metadata, generating frame from DASH=%@", dashURL);
                    ApolloGenerateVideoPosterImage(dashURL, cacheKey);
                    return;
                }
            }

            // Fallback: post-level preview (link posts where the post itself is the video)
            NSDictionary *preview = [post[@"preview"] isKindOfClass:[NSDictionary class]] ? post[@"preview"] : nil;
            NSArray *images = [preview[@"images"] isKindOfClass:[NSArray class]] ? preview[@"images"] : nil;
            if (images.count) {
                NSDictionary *first = [images[0] isKindOfClass:[NSDictionary class]] ? images[0] : nil;
                NSDictionary *src = [first[@"source"] isKindOfClass:[NSDictionary class]] ? first[@"source"] : nil;
                NSString *u = [src[@"url"] isKindOfClass:[NSString class]] ? src[@"url"] : nil;
                if (u.length) {
                    NSString *decoded = [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
                    NSURL *out = [NSURL URLWithString:decoded];
                    ApolloLog(@"[InlineImages] poster JSON: post preview url=%@", out);
                    ApolloDeliverPosterResult(cacheKey, out);
                    return;
                }
            }

            ApolloLog(@"[InlineImages] poster JSON: no usable poster for postID=%@ asset=%@", postID, assetID);
            ApolloDeliverPosterResult(cacheKey, nil);
        }];
        [task resume];
    });
}

// Idempotently add the play-circle UIImageView centered on the imageNode's
// backing view.
static void ApolloInstallPlayOverlayOnView(UIView *v, ASDisplayNode *node) {
    if (!v || !node) return;
    UIImageView *overlay = objc_getAssociatedObject(node, &kApolloPlayOverlayViewKey);
    if (overlay) {
        [v bringSubviewToFront:overlay];
        return;
    }

    overlay = [[UIImageView alloc] initWithImage:ApolloPlayOverlayImage()];
    overlay.contentMode = UIViewContentModeScaleAspectFit;
    overlay.userInteractionEnabled = NO;
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [overlay.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
        [overlay.widthAnchor constraintEqualToConstant:72.0],
        [overlay.heightAnchor constraintEqualToConstant:72.0],
    ]];
    [v bringSubviewToFront:overlay];
    objc_setAssociatedObject(node, &kApolloPlayOverlayViewKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, &kApolloPlayOverlayInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloInstallOrUpdateVideoPosterOnView(UIView *v, ASDisplayNode *node, UIImage *poster) {
    if (!v || !node || !poster) return;

    v.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    v.clipsToBounds = YES;
    v.layer.cornerRadius = 8.0;

    UIImageView *posterView = objc_getAssociatedObject(node, &kApolloVideoPosterViewKey);
    if (!posterView) {
        posterView = [[UIImageView alloc] initWithImage:poster];
        posterView.contentMode = UIViewContentModeScaleAspectFill;
        posterView.clipsToBounds = YES;
        posterView.userInteractionEnabled = NO;
        posterView.translatesAutoresizingMaskIntoConstraints = NO;
        [v insertSubview:posterView atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [posterView.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
            [posterView.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
            [posterView.topAnchor constraintEqualToAnchor:v.topAnchor],
            [posterView.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
        ]];
        objc_setAssociatedObject(node, &kApolloVideoPosterViewKey, posterView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[InlineImages] poster view installed node=%p imageSize=%@ subviews=%lu",
                  node, NSStringFromCGSize(poster.size), (unsigned long)v.subviews.count);
    } else {
        posterView.image = poster;
        ApolloLog(@"[InlineImages] poster view updated node=%p imageSize=%@",
                  node, NSStringFromCGSize(poster.size));
    }

    ApolloInstallPlayOverlayOnView(v, node);
}

static ASNetworkImageNode *ApolloMakeInlineImageNode(NSURL *normalizedURL,
                                                      ASDisplayNode *hostMarkdownNode) {
    Class imageNodeClass = ApolloASNetworkImageNodeClass();
    if (!imageNodeClass) return nil;

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    imageNode.URL = normalizedURL;
    imageNode.shouldRenderProgressImages = YES;
    // aspectFit always: container ratio may be clamped (very tall/wide
    // images) or guessed when ratio is unknown — fit avoids cropping in
    // both cases. When ratios match, fit and fill render identically.
    imageNode.contentMode = UIViewContentModeScaleAspectFit;
    imageNode.placeholderColor = [UIColor colorWithWhite:0.5 alpha:0.12];
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderFadeDuration = 0.2;
    imageNode.cornerRadius = 8.0;
    imageNode.clipsToBounds = YES;
    // Border is set per-layout in ApolloWrapImageNodeForLayout (only when
    // letterboxed). Initialize off; the wrapper toggles per pass.
    imageNode.borderWidth = 0.0;
    imageNode.delegate = [ApolloInlineImageDispatcher shared];

    // Tap → ASControlNode TouchUpInside. ASNetworkImageNode IS-A ASControlNode
    // and is view-backed by default, so this fires correctly. (The byline/
    // meta-row layer-backed addTarget no-op gotcha in AGENTS.md applies to
    // PostInfoNode children, not to MarkdownNode subnodes.)
    [imageNode addTarget:[ApolloInlineImageDispatcher shared]
                  action:@selector(imageNodeTapped:)
        forControlEvents:ApolloASControlNodeEventTouchUpInside];

    [[imageNode style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];

    CGFloat ratio = ApolloAspectRatioFromURL(normalizedURL);
    // kApolloAspectRatioKey is only set when we have real ratio info (URL
    // query params now, or didLoadImage later). Nil means "unknown" → the
    // wrapper omits the image from layout to avoid wrong-ratio races.

    objc_setAssociatedObject(imageNode, &kApolloImageURLKey, normalizedURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
    if (ratio > 0) {
        objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Long-press: install a UIContextMenuInteraction once the imageNode's
    // backing view exists. Native iOS routes context menus to the deepest
    // interaction-bearing view, so this wins over Apollo's cell-level
    // upvote/save/reply menu when the touch is inside the image bounds.
    __weak ASNetworkImageNode *weakImage = imageNode;
    [imageNode onDidLoad:^(__kindof ASDisplayNode *node) {
        ASNetworkImageNode *img = weakImage;
        if (!img) return;
        if ([objc_getAssociatedObject(img, &kApolloLongPressInstalledKey) boolValue]) return;
        UIView *v = [img view];
        if (!v) return;
        NSURL *url = objc_getAssociatedObject(img, &kApolloImageURLKey) ?: img.URL;
        objc_setAssociatedObject(v, &kApolloImageURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIContextMenuInteraction *menu = [[UIContextMenuInteraction alloc]
            initWithDelegate:[ApolloInlineImageDispatcher shared]];
        [v addInteraction:menu];
        objc_setAssociatedObject(img, &kApolloLongPressInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];

    return imageNode;
}

static ASNetworkImageNode *ApolloMakeInlineVideoThumbnailNode(NSURL *normalizedURL,
                                                               ASDisplayNode *hostMarkdownNode) {
    Class imageNodeClass = ApolloASNetworkImageNodeClass();
    if (!imageNodeClass) return nil;

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    // Solid dark placeholder until the real poster (if any) loads. The play
    // button sits on top via a separate UIImageView so it stays visible
    // regardless of poster state.
    imageNode.image = ApolloVideoPlaceholderImage();
    imageNode.shouldRenderProgressImages = YES;
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.placeholderColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderFadeDuration = 0.2;
    imageNode.cornerRadius = 8.0;
    imageNode.clipsToBounds = YES;
    imageNode.borderWidth = 0.0;

    [imageNode addTarget:[ApolloInlineImageDispatcher shared]
                  action:@selector(imageNodeTapped:)
        forControlEvents:ApolloASControlNodeEventTouchUpInside];

    [[imageNode style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];

    CGFloat ratio = ApolloAspectRatioFromURL(normalizedURL);
    if (ratio <= 0) ratio = 9.0 / 16.0;

    objc_setAssociatedObject(imageNode, &kApolloImageURLKey, normalizedURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(imageNode, &kApolloVideoThumbnailKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak ASNetworkImageNode *weakImage = imageNode;
    [imageNode onDidLoad:^(__kindof ASDisplayNode *node) {
        ASNetworkImageNode *img = weakImage;
        if (!img) return;
        UIView *v = [img view];
        if (!v) return;
        v.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        UIImage *pendingPoster = objc_getAssociatedObject(img, &kApolloPendingVideoPosterImageKey);
        if (pendingPoster) {
            ApolloLog(@"[InlineImages] applying pending poster on load node=%p", img);
            ApolloInstallOrUpdateVideoPosterOnView(v, img, pendingPoster);
            objc_setAssociatedObject(img, &kApolloPendingVideoPosterImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ApolloInstallPlayOverlayOnView(v, img);
        if (![objc_getAssociatedObject(img, &kApolloLongPressInstalledKey) boolValue]) {
            NSURL *url = objc_getAssociatedObject(img, &kApolloImageURLKey);
            objc_setAssociatedObject(v, &kApolloImageURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIContextMenuInteraction *menu = [[UIContextMenuInteraction alloc]
                initWithDelegate:[ApolloInlineImageDispatcher shared]];
            [v addInteraction:menu];
            objc_setAssociatedObject(img, &kApolloLongPressInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }];

    // Fetch the real poster image for /link/<postid>/video/.../player URLs
    // and swap it onto the imageNode once available. Negative results are
    // cached so failed lookups don't retry per-cell.
    NSString *postID = ApolloRedditPostIDFromVideoURL(normalizedURL);
    NSString *assetID = ApolloRedditAssetIDFromVideoURL(normalizedURL);
    if (postID.length) {
        ApolloFetchRedditPoster(postID, assetID, ^(id posterURLOrImage) {
            ASNetworkImageNode *img = weakImage;
            if (!img || !posterURLOrImage) return;
            if ([posterURLOrImage isKindOfClass:[UIImage class]]) {
                UIImage *ui = (UIImage *)posterURLOrImage;
                UIView *v = [img view];
                if (v) {
                    ApolloLog(@"[InlineImages] applying poster IMAGE via view node=%p", img);
                    ApolloInstallOrUpdateVideoPosterOnView(v, img, ui);
                } else {
                    ApolloLog(@"[InlineImages] poster callback before view loaded; storing pending poster node=%p", img);
                    objc_setAssociatedObject(img, &kApolloPendingVideoPosterImageKey, ui, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            } else if ([posterURLOrImage isKindOfClass:[NSURL class]]) {
                NSURL *posterURL = (NSURL *)posterURLOrImage;
                ApolloLog(@"[InlineImages] applying poster URL=%@ -> node=%p", posterURL, img);
                img.URL = posterURL;
                UIView *v = [img view];
                if (v) ApolloInstallPlayOverlayOnView(v, img);
            }
        });
    }

    ApolloLog(@"[InlineImages] video thumbnail node=%p url=%@", imageNode, normalizedURL);
    return imageNode;
}

// MARK: - Layout-spec wrapping (ratio + inset)

// Bounds for the container's aspect ratio (height / width). Images outside
// these bounds get a clamped container with the image aspect-fit inside —
// preserves natural proportions and avoids degenerate sizes (extremely
// tall cells spanning multiple screens; near-zero-height slivers).
static const CGFloat kApolloMaxContainerRatio = 1.0;   // tallest: square (height ≤ width)
static const CGFloat kApolloMinContainerRatio = 0.18; // shortest: ~5.5:1 landscape

// Floor for the container width when shrinking tall images to image-tight
// width. ~2 thumb widths — keeps super-narrow images from collapsing into
// a sliver. Below this, the image letterboxes inside a min-width container.
static const CGFloat kApolloMinTallImageWidth = 85.0;

// Secondary height cap as a fraction of the current screen height. Keeps
// inline images from filling the entire viewport in landscape, where the
// row is wide but vertical space is scarce. In portrait this rarely
// binds (screen × 0.6 > row × 1.0 on phones and tablets), so portrait
// sizing stays unchanged.
static const CGFloat kApolloMaxScreenHeightFraction = 0.6;

static ASLayoutSpec *ApolloWrapImageNodeForLayout(ASNetworkImageNode *imageNode,
                                                   CGFloat rowMaxWidth) {
    NSNumber *ratioNum = objc_getAssociatedObject(imageNode, &kApolloAspectRatioKey);
    if (!ratioNum) {
        // Unknown ratio → omit from layout. Including with a guessed ratio
        // would cause cell measurement to capture the wrong size and race
        // with the post-load relayout-from-above.
        return nil;
    }
    CGFloat naturalRatio = [ratioNum doubleValue];
    if (naturalRatio <= 0) naturalRatio = 1.0;

    CGFloat containerRatio = naturalRatio;
    CGFloat containerWidth = rowMaxWidth;  // default: span full row
    BOOL isLetterboxed = NO;

    if (naturalRatio > kApolloMaxContainerRatio) {
        // Tall image. Cap height at min(row × maxContainerRatio,
        // screen × maxScreenHeightFraction). The screen term protects
        // landscape, where the row term alone produces images taller
        // than the viewport. Within that cap, shrink container width
        // to image-tight (no letterbox) unless that would make the
        // container too narrow, in which case pin to a min width and
        // letterbox inside (still height-capped).
        CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
        CGFloat maxContainerHeight = MIN(rowMaxWidth * kApolloMaxContainerRatio,
                                          screenHeight * kApolloMaxScreenHeightFraction);
        CGFloat tightWidth = maxContainerHeight / naturalRatio;
        if (tightWidth >= kApolloMinTallImageWidth) {
            containerWidth = tightWidth;
            containerRatio = naturalRatio;
        } else {
            containerWidth = kApolloMinTallImageWidth;
            // Container ratio derived so height equals maxContainerHeight.
            containerRatio = maxContainerHeight / kApolloMinTallImageWidth;
            isLetterboxed = YES;
        }
    } else if (naturalRatio < kApolloMinContainerRatio) {
        // Wide image: keep full row width, letterbox inside a clamped
        // min-ratio container.
        containerWidth = rowMaxWidth;
        containerRatio = kApolloMinContainerRatio;
        isLetterboxed = YES;
    } else {
        // Normal aspect. Tight-wrap, but enforce the screen height cap
        // so a landscape-wide normal image (e.g. 16:9 at full row width)
        // doesn't dominate the viewport.
        CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
        CGFloat heightCap = screenHeight * kApolloMaxScreenHeightFraction;
        CGFloat naturalHeight = rowMaxWidth * naturalRatio;
        if (naturalHeight > heightCap) {
            containerWidth = heightCap / naturalRatio;
            containerRatio = naturalRatio;
        }
    }

    // Border only when letterboxed (natural ratio doesn't match container
    // ratio). Tightly-wrapped tall images have the image at the container
    // edge — a border there would overlap image content.
    if (isLetterboxed) {
        imageNode.borderWidth = 0.75;
        imageNode.borderColor = [UIColor separatorColor].CGColor;
    } else {
        imageNode.borderWidth = 0.0;
    }

    ASRatioLayoutSpec *ratioSpec = [ApolloASRatioLayoutSpecClass() ratioLayoutSpecWithRatio:containerRatio child:imageNode];
    [[ratioSpec style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];

    // Center the (possibly narrower) container horizontally.
    CGFloat horizontalInset = MAX(0.0, (rowMaxWidth - containerWidth) * 0.5);
    UIEdgeInsets insets = UIEdgeInsetsMake(4, horizontalInset, 4, horizontalInset);
    ASInsetLayoutSpec *insetSpec = [ApolloASInsetLayoutSpecClass() insetLayoutSpecWithInsets:insets child:ratioSpec];
    [[insetSpec style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];
    return insetSpec;
}

// MARK: - Text-splitting

// Trim leading/trailing newlines + spaces from an attributed substring so we
// don't have stranded blank lines after removing the URL text.
static NSAttributedString *ApolloTrimAttributedString(NSAttributedString *s) {
    if (s.length == 0) return s;
    NSCharacterSet *trim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *str = s.string;
    NSUInteger start = 0;
    while (start < str.length && [trim characterIsMember:[str characterAtIndex:start]]) start++;
    NSUInteger end = str.length;
    while (end > start && [trim characterIsMember:[str characterAtIndex:end - 1]]) end--;
    if (start == 0 && end == str.length) return s;
    if (end <= start) return [[NSAttributedString alloc] initWithString:@""];
    return [s attributedSubstringFromRange:NSMakeRange(start, end - start)];
}

static ASTextNode *ApolloMakeTextSegmentNode(ASTextNode *templateTextNode, NSAttributedString *segment) {
    // Use the template's class (e.g. _TtC6Apollo16MarkdownTextNode) and
    // mirror Apollo's markdown-parser property setup (per RE of
    // sub_1004280f8). userInteractionEnabled=YES is required — without it,
    // taps fall straight through to the cell.
    ASTextNode *tn = [[[templateTextNode class] alloc] init];
    tn.longPressCancelsTouches = YES;
    tn.userInteractionEnabled = YES;
    tn.delegate = templateTextNode.delegate;
    tn.passthroughNonlinkTouches = templateTextNode.passthroughNonlinkTouches;

    // Apollo's link key isn't NSLinkAttributeName — copy from the template.
    NSArray *names = templateTextNode.linkAttributeNames;
    if (names.count > 0) tn.linkAttributeNames = names;

    tn.maximumNumberOfLines = templateTextNode.maximumNumberOfLines;
    tn.attributedText = segment;
    [[tn style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];
    return tn;
}

// Returns an array of leaf nodes (ASTextNode + ASNetworkImageNode instances)
// in the order they should appear in the augmented stack, replacing the
// original text node. Returns nil if the text node has no inline media URLs.
// Side effects: each new leaf is added as a subnode of `hostMarkdownNode`.
static NSArray *ApolloBuildLeavesForTextNode(ASTextNode *textNode,
                                              ASDisplayNode *hostMarkdownNode) {
    NSAttributedString *attr = textNode.attributedText;
    if (attr.length == 0) return nil;

    // Collect (range, url, kind) tuples for inline media URLs, deduping by URL string.
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableArray<NSNumber *> *isVideoURL = [NSMutableArray array];
    NSMutableSet<NSString *> *seenAbs = [NSMutableSet set];

    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length)
                             options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, BOOL *stop) {
        for (NSAttributedStringKey k in attrs) {
            id val = attrs[k];
            if (![val isKindOfClass:[NSURL class]]) continue;
            NSURL *url = (NSURL *)val;
            BOOL isImage = ApolloIsInlineRenderableImageURL(url);
            BOOL isVideo = !isImage && ApolloIsInlineRenderableVideoURL(url);
            if (!isImage && !isVideo) continue;
            // Expand to the URL's longest effective range so a markdown
            // link with mixed formatting ("[**Bold** plain](url)") gets
            // captured as one span instead of two.
            NSRange fullRange = range;
            (void)[attr attribute:k atIndex:range.location longestEffectiveRange:&fullRange
                          inRange:NSMakeRange(0, attr.length)];
            NSURL *normalized = ApolloNormalizeInlineImageURL(url);
            NSString *abs = normalized.absoluteString;
            if (!abs.length || [seenAbs containsObject:abs]) continue;
            [seenAbs addObject:abs];
            [ranges addObject:[NSValue valueWithRange:fullRange]];
            [urls addObject:normalized];
            [isVideoURL addObject:@(isVideo)];
        }
    }];

    if (ranges.count == 0) return nil;

    // Sort by range.location ascending.
    NSMutableArray<NSNumber *> *idx = [NSMutableArray arrayWithCapacity:ranges.count];
    for (NSUInteger i = 0; i < ranges.count; i++) [idx addObject:@(i)];
    [idx sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSUInteger la = [ranges[a.unsignedIntegerValue] rangeValue].location;
        NSUInteger lb = [ranges[b.unsignedIntegerValue] rangeValue].location;
        return (la < lb) ? NSOrderedAscending : (la > lb) ? NSOrderedDescending : NSOrderedSame;
    }];

    NSMutableArray *leaves = [NSMutableArray array];

    // Process per-paragraph (\n-delimited spans). Within each paragraph,
    // images stack at the top and the remaining text follows. Across
    // paragraphs, source order is preserved — so "Plain text\nhttps://gif"
    // renders as text then image, while "[a](url1) and [b](url2)" (single
    // line) renders as image1, image2, then "a and b".
    NSString *str = attr.string;

    void (^processParagraph)(NSUInteger, NSUInteger) = ^(NSUInteger pStart, NSUInteger pEnd) {
        if (pEnd <= pStart) return;
        NSRange pRange = NSMakeRange(pStart, pEnd - pStart);

        // Indices (into ranges/urls) for URLs falling inside this paragraph.
        NSMutableArray<NSNumber *> *pIdx = [NSMutableArray array];
        for (NSNumber *iNum in idx) {
            NSRange r = [ranges[iNum.unsignedIntegerValue] rangeValue];
            if (r.location >= pStart && NSMaxRange(r) <= pEnd) [pIdx addObject:iNum];
        }

        for (NSNumber *iNum in pIdx) {
            NSUInteger leafIndex = iNum.unsignedIntegerValue;
            ASNetworkImageNode *img = [isVideoURL[leafIndex] boolValue]
                ? ApolloVideoThumbnailNodeForURL(urls[leafIndex], hostMarkdownNode)
                : ApolloImageNodeForURL(urls[leafIndex], hostMarkdownNode);
            if (img) [leaves addObject:img];
        }

        NSMutableAttributedString *remaining = [[attr attributedSubstringFromRange:pRange] mutableCopy];
        // Reverse-order deletion of bare-URL ranges (paragraph-relative).
        for (NSInteger n = (NSInteger)pIdx.count - 1; n >= 0; n--) {
            NSUInteger ri = [pIdx[n] unsignedIntegerValue];
            NSRange r = [ranges[ri] rangeValue];
            if (ApolloRangeTextLooksLikeBareURL(attr, r, urls[ri])) {
                [remaining deleteCharactersInRange:NSMakeRange(r.location - pStart, r.length)];
            }
        }

        NSAttributedString *trimmed = ApolloTrimAttributedString(remaining);
        if (trimmed.length > 0) {
            ASTextNode *tn = ApolloMakeTextSegmentNode(textNode, trimmed);
            if (tn) {
                [leaves addObject:tn];
                [hostMarkdownNode addSubnode:tn];
            }
        }
    };

    NSUInteger pStart = 0;
    for (NSUInteger i = 0; i < str.length; i++) {
        if ([str characterAtIndex:i] == '\n') {
            processParagraph(pStart, i);
            pStart = i + 1;
        }
    }
    processParagraph(pStart, str.length);

    return leaves.count > 0 ? [leaves copy] : nil;
}

// Reuses an existing imageNode by URL if present, else creates and
// registers one. Avoids recreate-then-remove churn during rapid Apollo
// MarkdownNode rebuilds (cell collapse/uncollapse).
static ASNetworkImageNode *ApolloImageNodeForURL(NSURL *normalizedURL,
                                                   ASDisplayNode *hostMarkdownNode) {
    NSMutableDictionary *cache = objc_getAssociatedObject(hostMarkdownNode, &kApolloImageNodesByURLKey);
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostMarkdownNode, &kApolloImageNodesByURLKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *key = [normalizedURL absoluteString];
    ASNetworkImageNode *existing = key ? cache[key] : nil;
    if (existing) {
        // Reuse: ensure the host association is still up to date in case
        // (somehow) it pointed elsewhere previously.
        objc_setAssociatedObject(existing, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
        return existing;
    }

    ASNetworkImageNode *imageNode = ApolloMakeInlineImageNode(normalizedURL, hostMarkdownNode);
    if (!imageNode) return nil;
    [hostMarkdownNode addSubnode:imageNode];
    if (key) cache[key] = imageNode;
    return imageNode;
}

static ASNetworkImageNode *ApolloVideoThumbnailNodeForURL(NSURL *normalizedURL,
                                                           ASDisplayNode *hostMarkdownNode) {
    NSMutableDictionary *cache = objc_getAssociatedObject(hostMarkdownNode, &kApolloImageNodesByURLKey);
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostMarkdownNode, &kApolloImageNodesByURLKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *key = [normalizedURL absoluteString];
    ASNetworkImageNode *existing = key ? cache[key] : nil;
    if (existing) {
        objc_setAssociatedObject(existing, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
        return existing;
    }

    ASNetworkImageNode *videoNode = ApolloMakeInlineVideoThumbnailNode(normalizedURL, hostMarkdownNode);
    if (!videoNode) return nil;
    [hostMarkdownNode addSubnode:videoNode];
    if (key) cache[key] = videoNode;
    return videoNode;
}
// Compare two children arrays by element-pointer identity. Apollo bridges
// its Swift `[ASDisplayNode]` to a fresh NSArray each layoutSpecThatFits:
// call, so the wrapping pointer differs every time but the element pointers
// are reused — that's the right cache invariant.
static BOOL ApolloChildrenIdentityMatches(NSArray *a, NSArray *b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        if (a[i] != b[i]) return NO;
    }
    return YES;
}

// MARK: - %hook _TtC6Apollo12MarkdownNode

%hook _TtC6Apollo12MarkdownNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    id origSpec = %orig;
    if (!sEnableInlineImages) return origSpec;
    if (![origSpec isKindOfClass:ApolloASStackLayoutSpecClass()]) return origSpec;

    ASStackLayoutSpec *stack = (ASStackLayoutSpec *)origSpec;
    NSArray *origChildren = stack.children;
    if (origChildren.count == 0) return origSpec;

    NSArray *cachedOrigChildren = objc_getAssociatedObject(self, &kApolloCachedOrigChildrenKey);
    NSDictionary *decomp = objc_getAssociatedObject(self, &kApolloDecompositionMapKey);

    if (!ApolloChildrenIdentityMatches(cachedOrigChildren, origChildren)) {
        // Rebuild decomposition. We do NOT removeFromSupernode the previous
        // imageNodes here — ApolloImageNodeForURL reuses them by URL. Text
        // segments ARE recreated each time (cheap, attributedText varies).
        NSMutableDictionary *newDecomp = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *referencedURLs = [NSMutableSet set];
        Class textNodeCls = ApolloASTextNodeClass();
        Class imageNodeCls = ApolloASNetworkImageNodeClass();
        for (id child in origChildren) {
            if (![child isKindOfClass:textNodeCls]) continue;
            NSArray *leaves = ApolloBuildLeavesForTextNode((ASTextNode *)child, (ASDisplayNode *)self);
            if (leaves.count > 0) {
                NSValue *k = [NSValue valueWithNonretainedObject:child];
                newDecomp[k] = leaves;
                for (id leaf in leaves) {
                    if ([leaf isKindOfClass:imageNodeCls]) {
                        NSURL *url = objc_getAssociatedObject(leaf, &kApolloImageURLKey) ?: ((ASNetworkImageNode *)leaf).URL;
                        NSString *abs = [url absoluteString];
                        if (abs) [referencedURLs addObject:abs];
                    }
                }
            }
        }

        // Garbage-collect imageNodes whose URL no longer appears in the new
        // decomposition (e.g., the comment was edited and the URL removed).
        NSMutableDictionary *imageCache = objc_getAssociatedObject(self, &kApolloImageNodesByURLKey);
        if (imageCache.count > 0) {
            NSArray *cachedURLs = [imageCache.allKeys copy];
            for (NSString *cachedURL in cachedURLs) {
                if (![referencedURLs containsObject:cachedURL]) {
                    [imageCache[cachedURL] removeFromSupernode];
                    [imageCache removeObjectForKey:cachedURL];
                }
            }
        }

        // Always save the orig children (even when no decomposition needed) so
        // we can short-circuit subsequent calls that match this content.
        objc_setAssociatedObject(self, &kApolloCachedOrigChildrenKey, origChildren, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kApolloDecompositionMapKey, newDecomp.count > 0 ? newDecomp : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        decomp = newDecomp.count > 0 ? newDecomp : nil;
    }

    if (decomp.count == 0) return origSpec;

    // Replace each decomposed text node with its leaves. Image nodes whose
    // ratio is still unknown are omitted — DIDLOAD will trigger a layout-
    // from-above and they'll appear on the next pass.
    NSMutableArray *augmented = [NSMutableArray arrayWithCapacity:origChildren.count];
    Class imageNodeCls = ApolloASNetworkImageNodeClass();
    CGFloat rowMaxWidth = constrainedSize.max.width;
    for (id child in origChildren) {
        NSArray *leaves = decomp[[NSValue valueWithNonretainedObject:child]];
        if (!leaves) {
            [augmented addObject:child];
            continue;
        }
        for (id leaf in leaves) {
            if ([leaf isKindOfClass:imageNodeCls]) {
                ASLayoutSpec *wrapped = ApolloWrapImageNodeForLayout((ASNetworkImageNode *)leaf, rowMaxWidth);
                if (wrapped) [augmented addObject:wrapped];
            } else {
                [augmented addObject:leaf];
            }
        }
    }

    ASStackLayoutSpec *newSpec = [ApolloASStackLayoutSpecClass() stackLayoutSpecWithDirection:stack.direction
                                                                                      spacing:stack.spacing
                                                                               // Override Apollo's spaceBetween — it spreads our
                                                                               // multi-child augmented layout when slack is available.
                                                                               justifyContent:ApolloASStackLayoutJustifyContentStart
                                                                                   alignItems:stack.alignItems
                                                                                     children:augmented];
    newSpec.flexWrap = stack.flexWrap;
    newSpec.alignContent = stack.alignContent;
    newSpec.lineSpacing = stack.lineSpacing;
    return newSpec;
}

%end

// MARK: - %hook _TtC6Apollo14LinkButtonNode

// Hides Apollo's link-card preview at the bottom of the comment when the
// URL has been inlined as an image elsewhere. Returns a zero-size empty
// spec so the LinkButtonNode reserves no visible space. Non-image
// LinkButtonNodes (tweets, articles, etc.) are unaffected.

%hook _TtC6Apollo14LinkButtonNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    if (!sEnableInlineImages) return %orig;

    NSString *urlString = ApolloGetLinkButtonNodeURLString(self);
    if (!urlString) return %orig;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!ApolloIsInlineRenderableImageURL(url) && !ApolloIsInlineRenderableVideoURL(url)) return %orig;

    // Empty layout spec with zero preferredSize. The LinkButtonNode itself
    // remains in the cell's subnode tree (we don't want to fight Apollo's
    // ownership), but contributes no visible content or vertical space.
    Class layoutSpecCls = NSClassFromString(@"ASLayoutSpec");
    if (!layoutSpecCls) return %orig;
    ASLayoutSpec *empty = [[layoutSpecCls alloc] init];
    [[empty style] setValue:[NSValue valueWithCGSize:CGSizeZero] forKey:@"preferredSize"];
    return empty;
}

%end
