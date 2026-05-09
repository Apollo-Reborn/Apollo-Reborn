// ApolloInlineImages.xm
//
// Renders image URLs that appear inside Apollo's selftext / comment markdown
// bodies as actual inline images, replacing the URL text in-place. Tapping the
// inline image dispatches through Apollo's existing tappedLinkAttribute path
// (opens MediaViewer). Long-pressing presents a UIContextMenuInteraction with
// Copy Link / Share / Open in Safari — the deeper interaction wins over
// Apollo's cell-level upvote/save/reply menu.
//
// Hook: -[_TtC6Apollo12MarkdownNode layoutSpecThatFits:]
//
// Strategy ("text-split, in-place"):
//   1. Call %orig to let Apollo build its natural ASStackLayoutSpec.
//   2. Walk the orig spec's children. For each ASTextNode child whose
//      attributedText contains image URL link attributes, split it into
//      [preText, image, postText, ...] sub-children. New text nodes are
//      instantiated as the same Swift subclass (e.g. _TtC6Apollo16Markdown-
//      TextNode) and configured via the same property sequence Apollo's
//      markdown parser uses (longPressCancelsTouches, userInteractionEnabled,
//      delegate, passthroughNonlinkTouches, linkAttributeNames,
//      maximumNumberOfLines, attributedText) so non-image links continue
//      to dispatch through Apollo's normal tap path.
//   3. Return a new ASStackLayoutSpec mirroring orig's params with the
//      augmented children.
//
// Aspect-ratio handling: imageNodes start with ratio = nil (unknown) unless
// the URL carries width=&height= query params. ApolloWrapImageNodeForLayout
// returns nil for unknown-ratio images, causing them to be OMITTED from the
// initial layout pass entirely. When ASNetworkImageNode's didLoadImage:
// fires, we record the natural ratio and call _u_setNeedsLayoutFromAbove on
// the imageNode — Texture's internal "intrinsic size changed" hook that
// walks up to the root signaling the table/collection to re-measure the
// row. The next layout pass includes the image at the correct clamped
// container size. This avoids the wrong-ratio-then-correct race that
// previously caused gaps above/below the image when the cell measurement
// captured an in-flight wrong-ratio value.
//
// Caching: the decomposition (text segments + image leaves) is cached on
// the MarkdownNode by element-pointer identity of the orig children. Apollo
// bridges its Swift `[ASDisplayNode]` to a fresh NSArray on each
// layoutSpecThatFits: call, so the wrapping array pointer differs every
// call but the element pointers are reused while content is unchanged.
// Image nodes are additionally reused by URL within a MarkdownNode's
// lifetime (NSMutableDictionary<URL, ASNetworkImageNode>) so that rapid
// rebuilds during cell collapse/uncollapse don't recreate-and-orphan
// imageNodes.

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
        imageExts = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", nil];
    });
    if (![imageExts containsObject:ext]) return NO;

    if ([host isEqualToString:@"i.redd.it"]) return YES;
    if ([host isEqualToString:@"preview.redd.it"]) return YES;
    if ([host isEqualToString:@"i.imgur.com"]) return YES;
    return YES;
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
    CGFloat ratio = (CGFloat)(hv / wv);
    if (ratio < 0.1) ratio = 0.1;
    if (ratio > 4.0) ratio = 4.0;
    return ratio;
}

// MARK: - Tap dispatcher + UIContextMenuInteraction delegate (singleton)

@interface ApolloInlineImageDispatcher : NSObject <UIContextMenuInteractionDelegate>
+ (instancetype)shared;
- (void)imageNodeTapped:(id)sender;
- (void)imageNode:(id)imageNode didLoadImage:(UIImage *)image;
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

    // Apollo's MarkdownNode handler (sub_10042ddf8) checks the attr argument
    // against TWO swift_once-initialized Swift String constants: @"ApolloLink"
    // (routes to delegate → URL dispatcher → MediaViewer) and @"Spoiler"
    // (inline spoiler reveal). Any other key (including NSLinkAttributeName)
    // is silently ignored. @"ApolloLink" is what we want.
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
    if (!image || image.size.width <= 0 || image.size.height <= 0) return;
    CGFloat newRatio = image.size.height / image.size.width;
    NSNumber *cur = objc_getAssociatedObject(imageNode, &kApolloAspectRatioKey);
    if (cur && fabs(newRatio - [cur doubleValue]) < 0.01) return;
    objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(newRatio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Trigger an upward re-measurement so the surrounding cell picks up the
    // new image-included content height. _u_setNeedsLayoutFromAbove is
    // Texture's internal hook for "this node's intrinsic size changed,
    // please re-layout from a higher level" — it walks up calling
    // setNeedsLayout on each supernode until reaching the root, signaling
    // the table/collection to re-measure.
    SEL sel = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
    if (![imageNode respondsToSelector:sel]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL))objc_msgSend)(imageNode, sel);
    });
}

@end

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
    // aspectFit so the entire image is always visible — when the container
    // ratio doesn't match the image's natural ratio (clamped, or before we
    // know the natural ratio because preview.redd.it URLs don't include
    // height=), the image is centered with letterbox bars rather than
    // cropping. When the ratios match, aspectFit and aspectFill render
    // identically.
    imageNode.contentMode = UIViewContentModeScaleAspectFit;
    imageNode.placeholderColor = [UIColor colorWithWhite:0.5 alpha:0.12];
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderFadeDuration = 0.2;
    imageNode.cornerRadius = 8.0;
    imageNode.clipsToBounds = YES;
    // Border is conditionally applied per-layout in ApolloWrapImageNodeForLayout
    // based on whether the image is clamped (= letterboxed inside its
    // container). When natural ratio fits within bounds, the image fills
    // the container with no letterbox space, so we don't render a border
    // (avoiding the visual overlap with the image content). Initialize to
    // off here; the wrapper toggles per layout pass.
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
    // Note: we set kApolloAspectRatioKey only when we have real ratio info
    // (from URL query params). If we don't, kApolloAspectRatioKey stays nil
    // and ApolloWrapImageNodeForLayout returns nil → image is OMITTED from
    // the layout. Once DIDLOAD fires, the key is populated and the image is
    // included in the next layout pass at the correct ratio. This avoids
    // the wrong-ratio-then-correct flicker / cell-measurement race.

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
// preserves natural proportions and prevents extremely tall images from
// making cells span multiple screens.
static const CGFloat kApolloMaxContainerRatio = 1.5;  // tallest container: ~3:4.5 portrait
static const CGFloat kApolloMinContainerRatio = 0.3;  // shortest container: ~10:3 landscape

// For very tall images (container clamped at the max ratio), inset the
// container horizontally by this much per side so taps in the left/right
// margins fall through to the cell (which collapses on tap). Without this,
// a tall image fills the full cell width and there's no way to tap the cell
// to collapse without hitting the image. Wide / normal-aspect images are
// NOT inset — they render full-width.
static const CGFloat kApolloTallImageHorizontalInset = 48.0;

static ASLayoutSpec *ApolloWrapImageNodeForLayout(ASNetworkImageNode *imageNode) {
    NSNumber *ratioNum = objc_getAssociatedObject(imageNode, &kApolloAspectRatioKey);
    if (!ratioNum) {
        // Ratio is genuinely unknown: no URL params and DIDLOAD hasn't fired.
        // Omit the image from this layout pass entirely. Including it with a
        // guessed ratio would cause the cell to measure with the wrong size,
        // then race with DIDLOAD's relayout-from-above. DIDLOAD will trigger
        // _u_setNeedsLayoutFromAbove once the natural ratio is known, and
        // the next layout pass will include the image at the correct size.
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
    // Use the SAME class as the template (e.g. _TtC6Apollo16MarkdownTextNode)
    // so Apollo's subclass conventions apply. Mirror the property setup
    // sequence Apollo's markdown parser performs on the original (per RE of
    // sub_1004280f8): longPressCancelsTouches, userInteractionEnabled,
    // delegate, passthroughNonlinkTouches, linkAttributeNames,
    // maximumNumberOfLines, attributedText. Crucially, userInteractionEnabled
    // must be YES — without it, taps fall straight through to the cell.
    ASTextNode *tn = [[[templateTextNode class] alloc] init];
    tn.longPressCancelsTouches = YES;
    tn.userInteractionEnabled = YES;
    tn.delegate = templateTextNode.delegate;
    tn.passthroughNonlinkTouches = templateTextNode.passthroughNonlinkTouches;

    // Apollo's link key is a swift_once-initialized 4-element array of Swift
    // String constants — copy from the template so link detection picks up
    // the right keys (NSLinkAttributeName isn't one of them).
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

// Look up an imageNode for `normalizedURL` from the host MarkdownNode's
// per-instance URL cache. Reuses an existing imageNode if present (preserves
// its asynchronous display lifecycle, cached aspect ratio, and any installed
// gestures); otherwise creates a fresh one and registers it. This is the
// load-bearing fix for the gap-on-rapid-rebuild issue: when Apollo rebuilds
// `displayNodes` repeatedly during cell collapse/uncollapse, we'd otherwise
// create-then-remove imageNodes faster than Texture's display pipeline can
// settle, leaving stale frames or partially-displayed bitmaps visible.
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
// Compare two children arrays by element-pointer identity. Apollo's Swift
// MarkdownNode.layoutSpecThatFits: builds a NEW NSArray each call but the
// underlying ASDisplayNode element pointers are reused across passes when the
// content hasn't changed. So pointer-equality of elements is the right cache
// invariant, even though the wrapping array identity differs.
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
        // Content changed — rebuild the decomposition map. Each text node
        // child with image URLs maps to its [textSegment, imageNode, ...] leaves.
        //
        // Note we deliberately do NOT removeFromSupernode the imageNodes from
        // the previous decomp here — ApolloImageNodeForURL reuses them by
        // URL. Recreating-and-removing on every rebuild caused visible flicker
        // / vertical gaps because new ASNetworkImageNode instances start with
        // no cached image, no aspect ratio, and a separate display pipeline
        // that races with the previous instance's removal. Reusing avoids
        // both. Text segments are still recreated (they're cheap and have
        // varying attributedText that's fragile to retro-fit).
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

    // Build augmented children: replace each decomposed text node with its
    // leaves (wrapping each image node in a fresh ratio+inset spec so updated
    // aspect ratios are picked up on every layout pass). Image nodes whose
    // ratio is still unknown (no URL params + no DIDLOAD yet) get omitted
    // entirely from this pass; DIDLOAD will trigger a layout-from-above and
    // they'll appear at the correct size on the next pass.
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
                                                                               // Override Apollo's justifyContent (spaceBetween, fine for a
                                                                               // single child but spreads our multi-child augmented layout
                                                                               // apart when the stack has extra vertical space, leaving gaps
                                                                               // around inline images).
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

// Hides the inline link-card preview that Apollo renders below the comment
// text when the URL has been inlined as an image elsewhere. Returns an empty
// zero-size layout spec so the LinkButtonNode reserves no vertical space.
//
// We only hide nodes whose URL would be inline-rendered (image URLs on
// Reddit / Imgur hosts) AND only when the inline-images feature is on.
// Non-image LinkButtonNodes (tweets, articles, etc.) are unaffected.

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
