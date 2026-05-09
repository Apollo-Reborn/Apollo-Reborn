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

    // Allowlist: only inline known image hosts. Other hosts may have a
    // matching extension by coincidence (e.g. tracking redirectors) but
    // serve non-image bytes.
    static NSSet *allowedHosts;
    static dispatch_once_t hostsOnce;
    dispatch_once(&hostsOnce, ^{
        allowedHosts = [NSSet setWithObjects:
                        @"i.redd.it",
                        @"preview.redd.it",
                        @"external-preview.redd.it",
                        @"i.imgur.com",
                        @"media.giphy.com",
                        nil];
    });
    return [allowedHosts containsObject:host];
}

static NSURL *ApolloNormalizeInlineImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return url;
    NSString *s = [url absoluteString];
    if (![s containsString:@"&amp;"]) return url;
    NSString *decoded = [s stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    NSURL *out = [NSURL URLWithString:decoded];
    return out ?: url;
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
        objc_setAssociatedObject(v, &kApolloImageURLKey, img.URL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIContextMenuInteraction *menu = [[UIContextMenuInteraction alloc]
            initWithDelegate:[ApolloInlineImageDispatcher shared]];
        [v addInteraction:menu];
        objc_setAssociatedObject(img, &kApolloLongPressInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];

    return imageNode;
}

// MARK: - Layout-spec wrapping (ratio + inset)

// Bounds for the container's aspect ratio (height / width). Images outside
// these bounds get a clamped container with the image aspect-fit inside —
// preserves natural proportions and avoids degenerate sizes (extremely
// tall cells spanning multiple screens; near-zero-height slivers).
static const CGFloat kApolloMaxContainerRatio = 1.65;  // tallest: ~3:5 portrait
static const CGFloat kApolloMinContainerRatio = 0.15;  // shortest: ~6.7:1 landscape

// For very tall images (clamped at the max ratio), inset horizontally so
// taps in the left/right margins fall through to the cell (which collapses
// on tap). Wide / normal-aspect images are NOT inset — they render
// full-width.
static const CGFloat kApolloTallImageHorizontalInset = 48.0;

static ASLayoutSpec *ApolloWrapImageNodeForLayout(ASNetworkImageNode *imageNode) {
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
    BOOL isVeryTall = NO;
    BOOL isLetterboxed = NO;
    if (containerRatio > kApolloMaxContainerRatio) {
        containerRatio = kApolloMaxContainerRatio;
        isVeryTall = YES;
        isLetterboxed = YES;
    } else if (containerRatio < kApolloMinContainerRatio) {
        containerRatio = kApolloMinContainerRatio;
        isLetterboxed = YES;
        // Wide images stay full-width; no inset.
    }

    // Border only when the image is letterboxed inside its container
    // (i.e. natural ratio doesn't match container ratio due to clamping).
    // When natural fits within bounds, the image fills the container on all
    // four sides and a border would overlap the image content — drop it.
    if (isLetterboxed) {
        imageNode.borderWidth = 0.75;
        imageNode.borderColor = [UIColor separatorColor].CGColor;
    } else {
        imageNode.borderWidth = 0.0;
    }

    ASRatioLayoutSpec *ratioSpec = [ApolloASRatioLayoutSpecClass() ratioLayoutSpecWithRatio:containerRatio child:imageNode];
    [[ratioSpec style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];

    // Vertical breathing room always; horizontal inset only for very tall
    // images so the cell-collapse tap zone has somewhere to land.
    UIEdgeInsets insets = UIEdgeInsetsMake(8,
                                            isVeryTall ? kApolloTallImageHorizontalInset : 0,
                                            8,
                                            isVeryTall ? kApolloTallImageHorizontalInset : 0);
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
// original text node. Returns nil if the text node has no image URLs.
// Side effects: each new leaf is added as a subnode of `hostMarkdownNode`.
static NSArray *ApolloBuildLeavesForTextNode(ASTextNode *textNode,
                                              ASDisplayNode *hostMarkdownNode) {
    NSAttributedString *attr = textNode.attributedText;
    if (attr.length == 0) return nil;

    // Collect (range, url) pairs for image URLs, deduping by URL string.
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableSet<NSString *> *seenAbs = [NSMutableSet set];

    [attr enumerateAttributesInRange:NSMakeRange(0, attr.length)
                             options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, BOOL *stop) {
        for (id val in attrs.objectEnumerator) {
            if (![val isKindOfClass:[NSURL class]]) continue;
            NSURL *url = (NSURL *)val;
            if (!ApolloIsInlineRenderableImageURL(url)) continue;
            NSURL *normalized = ApolloNormalizeInlineImageURL(url);
            NSString *abs = normalized.absoluteString;
            if (!abs.length || [seenAbs containsObject:abs]) continue;
            [seenAbs addObject:abs];
            [ranges addObject:[NSValue valueWithRange:range]];
            [urls addObject:normalized];
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
    NSUInteger cursor = 0;

    void (^appendTextSegment)(NSRange) = ^(NSRange r) {
        if (r.length == 0) return;
        NSAttributedString *seg = ApolloTrimAttributedString([attr attributedSubstringFromRange:r]);
        if (seg.length == 0) return;
        ASTextNode *tn = ApolloMakeTextSegmentNode(textNode, seg);
        if (!tn) return;
        [leaves addObject:tn];
        [hostMarkdownNode addSubnode:tn];
    };

    for (NSNumber *iNum in idx) {
        NSRange r = [ranges[iNum.unsignedIntegerValue] rangeValue];
        appendTextSegment(NSMakeRange(cursor, (r.location > cursor ? r.location - cursor : 0)));

        // Reuse imageNode by URL to avoid recreate-on-every-rebuild flicker.
        // ApolloImageNodeForURL handles addSubnode + cache registration.
        ASNetworkImageNode *img = ApolloImageNodeForURL(urls[iNum.unsignedIntegerValue], hostMarkdownNode);
        if (img) {
            [leaves addObject:img];
        }

        cursor = NSMaxRange(r);
    }

    appendTextSegment(NSMakeRange(cursor, (cursor < attr.length ? attr.length - cursor : 0)));

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
                        NSString *abs = [((ASNetworkImageNode *)leaf).URL absoluteString];
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
    for (id child in origChildren) {
        NSArray *leaves = decomp[[NSValue valueWithNonretainedObject:child]];
        if (!leaves) {
            [augmented addObject:child];
            continue;
        }
        for (id leaf in leaves) {
            if ([leaf isKindOfClass:imageNodeCls]) {
                ASLayoutSpec *wrapped = ApolloWrapImageNodeForLayout((ASNetworkImageNode *)leaf);
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
    if (!ApolloIsInlineRenderableImageURL(url)) return %orig;

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
