// ApolloInlineLinkPreviews.xm
//
// Replaces Apollo's basic LinkButtonNode cards with richer metadata cards when
// the target page exposes useful Open Graph / Twitter Card / first-party API
// metadata. Falls back to Apollo's native card when metadata is missing.

#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloLinkPreviewFetcher.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

#import <Foundation/Foundation.h>
#import <math.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackDirection) {
    ApolloLinkPreviewStackDirectionVertical = 0,
    ApolloLinkPreviewStackDirectionHorizontal = 1,
};
typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackJustifyContent) {
    ApolloLinkPreviewStackJustifyContentStart = 0,
};
typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackAlignItems) {
    ApolloLinkPreviewStackAlignItemsStart = 0,
    ApolloLinkPreviewStackAlignItemsCenter = 2,
    ApolloLinkPreviewStackAlignItemsStretch = 3,
};

@class ASLayoutSpec;
@class ASStackLayoutSpec;
@class ASInsetLayoutSpec;
@class ASRatioLayoutSpec;
@class ASBackgroundLayoutSpec;
@class ASDisplayNode;
@class ASNetworkImageNode;
@class ASTextNode;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (ASDisplayNode *)supernode;
- (NSArray *)subnodes;
- (id)style;
- (UIView *)view;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic, readonly) CALayer *layer;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@property (nonatomic) NSLineBreakMode truncationMode;
@property (nonatomic) BOOL userInteractionEnabled;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL placeholderEnabled;
@property (nonatomic, copy) UIColor *placeholderColor;
@end

@interface ASLayoutSpec : NSObject
@property (nullable, nonatomic) NSArray *children;
- (id)style;
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloLinkPreviewStackDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloLinkPreviewStackJustifyContent justifyContent;
@property (nonatomic) ApolloLinkPreviewStackAlignItems alignItems;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloLinkPreviewStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloLinkPreviewStackJustifyContent)justifyContent
                                  alignItems:(ApolloLinkPreviewStackAlignItems)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

@interface ASBackgroundLayoutSpec : ASLayoutSpec
+ (instancetype)backgroundLayoutSpecWithChild:(id)child background:(id)background;
@end

struct CDStruct_90e057aa { CGSize min; CGSize max; };

static char kApolloLinkPreviewNodesKey;
static char kApolloLinkPreviewFetchInFlightKey;
static char kApolloLinkPreviewOriginalHostShellKey;
static char kApolloLinkPreviewRenderedPlaceholderKey;
static char kApolloLinkPreviewBackgroundColorPresetKey;

static NSHashTable<id> *sApolloLPRegisteredLinkNodes = nil;
static dispatch_queue_t sApolloLPRegisteredLinkNodesQueue = NULL;

typedef struct {
    NSUInteger nodes;
    NSUInteger recolored;
} ApolloLPRegisteredRecolorResult;

static void ApolloLPLogOncePerHost(NSString *host, NSString *event);
static void ApolloLPTriggerRelayoutForHost(ASDisplayNode *node, NSString *host);

static Class ApolloLPClass(NSString *name) {
    return NSClassFromString(name);
}

static NSString *ApolloLPHost(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    return host;
}

static BOOL ApolloLPHostHasSuffix(NSURL *url, NSString *suffix) {
    NSString *host = ApolloLPHost(url);
    return [host isEqualToString:suffix] || [host hasSuffix:[@"." stringByAppendingString:suffix]];
}

static BOOL ApolloLPTrustedInlineImageHost(NSURL *url) {
    NSArray<NSString *> *suffixes = @[
        @"redd.it", @"imgur.com", @"giphy.com", @"tenor.com", @"redgifs.com",
        @"twimg.com", @"discordapp.com", @"discordapp.net"
    ];
    for (NSString *suffix in suffixes) {
        if (ApolloLPHostHasSuffix(url, suffix)) return YES;
    }
    return NO;
}

static BOOL ApolloLPIsImgurAlbumOrShareURL(NSURL *url) {
    if (!ApolloLPHostHasSuffix(url, @"imgur.com")) return NO;
    if (url.pathExtension.length > 0) return NO;
    NSString *path = url.path ?: @"";
    if ([path hasPrefix:@"/a/"] || [path hasPrefix:@"/gallery/"]) return YES;

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count != 1) return NO;
    NSCharacterSet *disallowed = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    return [clean.firstObject rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

static BOOL ApolloLPShouldDeferToInlineMedia(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *extension = url.pathExtension.lowercaseString ?: @"";
    NSSet<NSString *> *imageExtensions = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", @"gif", nil];

    if (ApolloLPIsImgurAlbumOrShareURL(url)) return YES;
    if ([imageExtensions containsObject:extension] && ApolloLPTrustedInlineImageHost(url)) return YES;

    NSString *host = ApolloLPHost(url);
    NSString *query = url.query.lowercaseString ?: @"";
    if (([host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"external-preview.redd.it"] || ApolloLPHostHasSuffix(url, @"redd.it"))
        && [extension isEqualToString:@"gif"]
        && [query containsString:@"format=mp4"]) {
        return YES;
    }

    NSString *absolute = url.absoluteString.lowercaseString ?: @"";
    if ([absolute containsString:@"reddit.com/"] && [absolute containsString:@"/video/"] && [absolute containsString:@"/player"]) {
        return YES;
    }
    return NO;
}

static UIColor *ApolloLPResolvedColor(UIColor *color, UITraitCollection *traitCollection) {
    if (!color) return nil;
    if (@available(iOS 13.0, *)) {
        return [color resolvedColorWithTraitCollection:traitCollection ?: UIScreen.mainScreen.traitCollection];
    }
    return color;
}

static UIView *ApolloLPViewForNode(ASDisplayNode *node) {
    if (!node || ![node respondsToSelector:@selector(view)]) return nil;
    @try {
        UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(node, @selector(view));
        return [view isKindOfClass:[UIView class]] ? view : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIColor *ApolloLPBlendColor(UIColor *foreground, UIColor *background, CGFloat foregroundAlpha, UITraitCollection *traitCollection) {
    UIColor *resolvedForeground = ApolloLPResolvedColor(foreground, traitCollection);
    UIColor *resolvedBackground = ApolloLPResolvedColor(background, traitCollection);

    CGFloat fr = 0.0, fg = 0.0, fb = 0.0, fa = 1.0;
    CGFloat br = 0.0, bg = 0.0, bb = 0.0, ba = 1.0;
    if (![resolvedForeground getRed:&fr green:&fg blue:&fb alpha:&fa]) return background;
    if (![resolvedBackground getRed:&br green:&bg blue:&bb alpha:&ba]) return background;

    CGFloat alpha = MIN(MAX(foregroundAlpha * fa, 0.0), 1.0);
    return [UIColor colorWithRed:(fr * alpha) + (br * (1.0 - alpha))
                           green:(fg * alpha) + (bg * (1.0 - alpha))
                            blue:(fb * alpha) + (bb * (1.0 - alpha))
                           alpha:1.0];
}

static UIColor *ApolloLPColorForCardPreset(NSInteger preset) {
    switch (preset) {
        case ApolloLinkPreviewCardColorGray:     return [UIColor colorWithWhite:0.56 alpha:1.0];
        case ApolloLinkPreviewCardColorRed:      return [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0];
        case ApolloLinkPreviewCardColorOrange:   return [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorYellow:   return [UIColor colorWithRed:1.00 green:0.80 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorGreen:    return [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        case ApolloLinkPreviewCardColorMint:     return [UIColor colorWithRed:0.00 green:0.78 blue:0.75 alpha:1.0];
        case ApolloLinkPreviewCardColorTeal:     return [UIColor colorWithRed:0.19 green:0.69 blue:0.78 alpha:1.0];
        case ApolloLinkPreviewCardColorCyan:     return [UIColor colorWithRed:0.20 green:0.68 blue:0.90 alpha:1.0];
        case ApolloLinkPreviewCardColorBlue:     return [UIColor colorWithRed:0.00 green:0.48 blue:1.00 alpha:1.0];
        case ApolloLinkPreviewCardColorIndigo:   return [UIColor colorWithRed:0.35 green:0.34 blue:0.84 alpha:1.0];
        case ApolloLinkPreviewCardColorPurple:   return [UIColor colorWithRed:0.69 green:0.32 blue:0.87 alpha:1.0];
        case ApolloLinkPreviewCardColorPink:     return [UIColor colorWithRed:1.00 green:0.18 blue:0.33 alpha:1.0];
        case ApolloLinkPreviewCardColorBrown:    return [UIColor colorWithRed:0.64 green:0.52 blue:0.37 alpha:1.0];
        case ApolloLinkPreviewCardColorCoral:    return [UIColor colorWithRed:1.00 green:0.50 blue:0.31 alpha:1.0];
        case ApolloLinkPreviewCardColorLime:     return [UIColor colorWithRed:0.60 green:0.80 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorOlive:    return [UIColor colorWithRed:0.50 green:0.60 blue:0.20 alpha:1.0];
        case ApolloLinkPreviewCardColorLavender: return [UIColor colorWithRed:0.56 green:0.45 blue:0.90 alpha:1.0];
        case ApolloLinkPreviewCardColorSlate:    return [UIColor colorWithRed:0.35 green:0.43 blue:0.50 alpha:1.0];
        case ApolloLinkPreviewCardColorNeutral:
        default:                                 return [UIColor colorWithWhite:0.72 alpha:1.0];
    }
}

static UIColor *ApolloLPCardBackgroundColorForNode(ASDisplayNode *hostNode, NSURL *url) {
    UIColor *tintColor = ApolloLPColorForCardPreset(sLinkPreviewCardColor);
    ApolloLPLogOncePerHost(ApolloLPHost(url), @"V13-card-color-preset-resolved");

    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traitCollection) {
            BOOL dark = traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
            UIColor *base = dark ? [UIColor secondarySystemBackgroundColor] : [UIColor systemBackgroundColor];
            return ApolloLPBlendColor(tintColor, base, dark ? 0.14 : 0.08, traitCollection);
        }];
    }

    return ApolloLPBlendColor(tintColor, [UIColor secondarySystemBackgroundColor], 0.12, UIScreen.mainScreen.traitCollection);
}

static void ApolloLPRegisterLinkPreviewNode(ASDisplayNode *node) {
    if (!node || !sApolloLPRegisteredLinkNodes || !sApolloLPRegisteredLinkNodesQueue) return;
    dispatch_async(sApolloLPRegisteredLinkNodesQueue, ^{
        [sApolloLPRegisteredLinkNodes addObject:node];
    });
}

static NSArray *ApolloLPRegisteredLinkPreviewNodesSnapshot(void) {
    if (!sApolloLPRegisteredLinkNodes || !sApolloLPRegisteredLinkNodesQueue) return @[];
    __block NSArray *snapshot = nil;
    dispatch_sync(sApolloLPRegisteredLinkNodesQueue, ^{
        snapshot = sApolloLPRegisteredLinkNodes.allObjects ?: @[];
    });
    return snapshot ?: @[];
}

static void ApolloLPMarkNodeForColorRefresh(ASDisplayNode *node) {
    if (!node) return;
    @try {
        if ([node respondsToSelector:@selector(setNeedsDisplay)]) {
            [(id)node setNeedsDisplay];
        }
        if ([node respondsToSelector:@selector(setNeedsLayout)]) {
            [(id)node setNeedsLayout];
        }
        if ([node respondsToSelector:@selector(invalidateCalculatedLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(node, @selector(invalidateCalculatedLayout));
        }
    } @catch (__unused NSException *exception) {
    }
}

static BOOL ApolloLPApplyCardBackgroundColor(ASDisplayNode *hostNode, ASDisplayNode *backgroundNode, NSURL *url, BOOL force) {
    if (!backgroundNode || ![backgroundNode respondsToSelector:@selector(setBackgroundColor:)]) return NO;

    NSNumber *lastPresetNumber = objc_getAssociatedObject(backgroundNode, &kApolloLinkPreviewBackgroundColorPresetKey);
    BOOL presetChanged = ![lastPresetNumber isKindOfClass:[NSNumber class]] || lastPresetNumber.integerValue != sLinkPreviewCardColor;
    if (!force && !presetChanged) return NO;

    backgroundNode.backgroundColor = ApolloLPCardBackgroundColorForNode(hostNode, url);
    objc_setAssociatedObject(backgroundNode, &kApolloLinkPreviewBackgroundColorPresetKey, @(sLinkPreviewCardColor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLPMarkNodeForColorRefresh(backgroundNode);
    ApolloLPMarkNodeForColorRefresh(hostNode);
    return YES;
}

static NSString *ApolloLPBundleKey(NSURL *url, NSString *variant) {
    return [NSString stringWithFormat:@"%@|%@", url.absoluteString ?: @"", variant ?: @"default"];
}

static NSDictionary *ApolloLPNodeBundleForHost(ASDisplayNode *hostNode, NSURL *url, NSString *variant) {
    ApolloLPRegisterLinkPreviewNode(hostNode);

    NSMutableDictionary<NSString *, NSDictionary *> *bundles = objc_getAssociatedObject(hostNode, &kApolloLinkPreviewNodesKey);
    if (!bundles) {
        bundles = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostNode, &kApolloLinkPreviewNodesKey, bundles, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *key = ApolloLPBundleKey(url, variant);
    NSDictionary *bundle = bundles[key];
    if (bundle) return bundle;

    Class imageNodeClass = ApolloLPClass(@"ASNetworkImageNode");
    Class textNodeClass = ApolloLPClass(@"ASTextNode");
    Class displayNodeClass = ApolloLPClass(@"ASDisplayNode");
    if (!imageNodeClass || !textNodeClass || !displayNodeClass) return nil;

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.clipsToBounds = YES;
    imageNode.cornerRadius = 8.0;
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderColor = [UIColor tertiarySystemFillColor];

    ASNetworkImageNode *avatarNode = [[imageNodeClass alloc] init];
    avatarNode.contentMode = UIViewContentModeScaleAspectFill;
    avatarNode.clipsToBounds = YES;
    avatarNode.cornerRadius = 18.0;
    avatarNode.placeholderEnabled = YES;
    avatarNode.placeholderColor = [UIColor tertiarySystemFillColor];

    ASTextNode *siteNode = [[textNodeClass alloc] init];
    ASTextNode *titleNode = [[textNodeClass alloc] init];
    ASTextNode *descriptionNode = [[textNodeClass alloc] init];
    siteNode.maximumNumberOfLines = 1;
    titleNode.maximumNumberOfLines = 3;
    descriptionNode.maximumNumberOfLines = 4;
    siteNode.truncationMode = NSLineBreakByTruncatingTail;
    titleNode.truncationMode = NSLineBreakByTruncatingTail;
    descriptionNode.truncationMode = NSLineBreakByTruncatingTail;
    siteNode.userInteractionEnabled = NO;
    titleNode.userInteractionEnabled = NO;
    descriptionNode.userInteractionEnabled = NO;

    ASDisplayNode *backgroundNode = [[displayNodeClass alloc] init];
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, YES);
    backgroundNode.cornerRadius = 12.0;
    backgroundNode.clipsToBounds = YES;

    [hostNode addSubnode:backgroundNode];
    [hostNode addSubnode:imageNode];
    [hostNode addSubnode:avatarNode];
    [hostNode addSubnode:siteNode];
    [hostNode addSubnode:titleNode];
    [hostNode addSubnode:descriptionNode];

    bundle = @{
        @"image": imageNode,
        @"avatar": avatarNode,
        @"site": siteNode,
        @"title": titleNode,
        @"description": descriptionNode,
        @"background": backgroundNode,
        @"url": url,
    };
    bundles[key] = bundle;
    return bundle;
}

static NSAttributedString *ApolloLPAttributedString(NSString *string, UIFont *font, UIColor *color) {
    if (string.length == 0) return nil;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByWordWrapping;
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: style,
    };
    return [[NSAttributedString alloc] initWithString:string attributes:attrs];
}

static void ApolloLPApplyStyleSize(id style, CGSize size) {
    if (!style) return;
    @try {
        [style setValue:[NSValue valueWithCGSize:size] forKey:@"preferredSize"];
    } @catch (__unused NSException *exception) {
    }
}

static void ApolloLPClearStyleSize(id style) {
    if (!style) return;
    @try {
        [style setValue:nil forKey:@"preferredSize"];
    } @catch (__unused NSException *exception) {
        ApolloLPApplyStyleSize(style, CGSizeZero);
    }
}

static void ApolloLPResetStyle(id style) {
    if (!style) return;
    ApolloLPClearStyleSize(style);
    @try {
        [style setValue:@0.0 forKey:@"flexGrow"];
        [style setValue:@0.0 forKey:@"flexShrink"];
    } @catch (__unused NSException *exception) {
    }
}

static void ApolloLPResetTextNode(ASTextNode *textNode, NSUInteger maximumLines) {
    if (!textNode) return;
    textNode.maximumNumberOfLines = maximumLines;
    textNode.truncationMode = NSLineBreakByTruncatingTail;
    textNode.userInteractionEnabled = NO;
    textNode.backgroundColor = [UIColor clearColor];
    textNode.clipsToBounds = NO;
}

static void ApolloLPClearHostShell(ASDisplayNode *node) {
    if (!node) return;

    NSDictionary *original = objc_getAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey);
    if (!original) {
        original = @{
            @"background": node.backgroundColor ?: [NSNull null],
            @"cornerRadius": @(node.cornerRadius),
            @"clipsToBounds": @(node.clipsToBounds),
            @"borderWidth": @(node.layer.borderWidth),
            @"borderColor": node.layer.borderColor ? (__bridge id)node.layer.borderColor : [NSNull null],
            @"shadowOpacity": @(node.layer.shadowOpacity),
            @"shadowRadius": @(node.layer.shadowRadius),
        };
        objc_setAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    node.backgroundColor = [UIColor clearColor];
    node.cornerRadius = 0.0;
    node.clipsToBounds = NO;
    node.layer.borderWidth = 0.0;
    node.layer.borderColor = nil;
    node.layer.shadowOpacity = 0.0;
    node.layer.shadowRadius = 0.0;
}

static void ApolloLPRestoreHostShell(ASDisplayNode *node) {
    if (!node) return;
    NSDictionary *original = objc_getAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey);
    if (!original) return;

    id background = original[@"background"];
    node.backgroundColor = [background isKindOfClass:[NSNull class]] ? nil : background;
    node.cornerRadius = [original[@"cornerRadius"] doubleValue];
    node.clipsToBounds = [original[@"clipsToBounds"] boolValue];
    node.layer.borderWidth = [original[@"borderWidth"] doubleValue];
    id borderColor = original[@"borderColor"];
    node.layer.borderColor = [borderColor isKindOfClass:[NSNull class]] ? nil : (__bridge CGColorRef)borderColor;
    node.layer.shadowOpacity = [original[@"shadowOpacity"] floatValue];
    node.layer.shadowRadius = [original[@"shadowRadius"] doubleValue];
}

typedef NS_ENUM(NSUInteger, ApolloLPContext) {
    ApolloLPContextCompact = 0,
    ApolloLPContextSelfText = 1,
};

typedef NS_ENUM(NSUInteger, ApolloLPArea) {
    ApolloLPAreaBody = 0,
    ApolloLPAreaComments = 1,
};

static BOOL ApolloLPIsYouTubeURL(NSURL *url);

static NSString * const ApolloLinkPreviewDidCacheNotification = @"ApolloLinkPreviewDidCacheNotification";

static NSInteger ApolloLPModeForArea(ApolloLPArea area) {
    return (area == ApolloLPAreaComments) ? sLinkPreviewCommentsMode : sLinkPreviewBodyMode;
}

static ApolloLPContext ApolloLPContextForMode(NSInteger mode, ApolloLinkPreview *preview) {
    if (mode == ApolloLinkPreviewModeCompact) return ApolloLPContextCompact;
    if (preview.imageIsFallbackIcon) return ApolloLPContextCompact;
    if (preview.imageURL.absoluteString.length == 0) return ApolloLPContextCompact;
    return ApolloLPContextSelfText;
}

static NSMutableSet<NSString *> *ApolloLPCompactPlaceholderHosts(void) {
    static NSMutableSet<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = [NSMutableSet setWithArray:@[
            @"amctheatres.com",
            @"doi.org",
            @"journals.sagepub.com",
            @"nature.com",
            @"news18.com",
            @"nuvioapp.space",
            @"piie.com",
            @"zerozero.pt"
        ]];
    });
    return hosts;
}

static BOOL ApolloLPShouldUseCompactPlaceholder(NSURL *url) {
    NSString *host = ApolloLPHost(url);
    if (host.length == 0) return NO;

    @synchronized (ApolloLPCompactPlaceholderHosts()) {
        if ([ApolloLPCompactPlaceholderHosts() containsObject:host]) return YES;
        for (NSString *knownHost in ApolloLPCompactPlaceholderHosts()) {
            if ([host hasSuffix:[@"." stringByAppendingString:knownHost]]) return YES;
        }
    }
    return NO;
}

static void ApolloLPRememberCompactPlaceholderHost(NSURL *url) {
    NSString *host = ApolloLPHost(url);
    if (host.length == 0) return;

    @synchronized (ApolloLPCompactPlaceholderHosts()) {
        [ApolloLPCompactPlaceholderHosts() addObject:host];
    }
}

static NSString *ApolloLPContextLogName(ApolloLPContext context) {
    return context == ApolloLPContextSelfText ? @"hero" : @"compact";
}

static id ApolloLPModelFromNodeIvar(ASDisplayNode *node, const char *ivarName) {
    if (!node || !ivarName) return nil;
    Ivar ivar = class_getInstanceVariable([node class], ivarName);
    if (!ivar) return nil;

    id model = nil;
    @try {
        model = object_getIvar(node, ivar);
    } @catch (NSException *exception) {
        ApolloLog(@"[LinkPreviews] ivar read failed node=%@ ivar=%s err=%@",
                  NSStringFromClass([node class]), ivarName, exception.reason ?: exception.name);
    }
    return model;
}

static ApolloLPArea ApolloLPAreaForLinkButton(ASDisplayNode *linkButtonNode) {
    for (ASDisplayNode *node = linkButtonNode; node; node = node.supernode) {
        id comment = ApolloLPModelFromNodeIvar(node, "comment");
        if (comment) return ApolloLPAreaComments;
    }
    return ApolloLPAreaBody;
}

static BOOL ApolloLPIsYouTubeURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if ([host hasPrefix:@"m."]) host = [host substringFromIndex:2];
    static NSArray<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = @[@"youtube.com", @"youtu.be", @"music.youtube.com"];
    });
    for (NSString *match in hosts) {
        if ([host isEqualToString:match] || [host hasSuffix:[@"." stringByAppendingString:match]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL ApolloLPIsPosterPreviewURL(NSURL *url, ApolloLinkPreview *preview) {
    if (!url || !preview) return NO;

    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if ([host hasPrefix:@"m."]) host = [host substringFromIndex:2];

    static NSArray<NSString *> *posterHosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        posterHosts = @[
            @"anidb.net",
            @"anilist.co",
            @"anime-planet.com",
            @"boxofficemojo.com",
            @"fandango.com",
            @"imdb.com",
            @"justwatch.com",
            @"kitsu.app",
            @"letterboxd.com",
            @"livechart.me",
            @"metacritic.com",
            @"movieinsider.com",
            @"myanimelist.net",
            @"rottentomatoes.com",
            @"shikimori.one",
            @"the-numbers.com",
            @"themoviedb.org",
            @"trakt.tv"
        ];
    });

    BOOL knownPosterHost = NO;
    for (NSString *posterHost in posterHosts) {
        if ([host isEqualToString:posterHost] || [host hasSuffix:[@"." stringByAppendingString:posterHost]]) {
            knownPosterHost = YES;
            break;
        }
    }
    if (!knownPosterHost) return NO;

    CGSize imageSize = preview.imageSize;
    if (imageSize.width <= 1.0 || imageSize.height <= 1.0) return NO;
    return (imageSize.height / imageSize.width) >= 1.15;
}

static NSString *ApolloLPPlaceholderLines(NSUInteger lineCount, BOOL title) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:lineCount];
    NSString *longLine = title ? @"MMMMMMMMMMMMMMMMMMMM" : @"MMMMMMMMMMMMMMMMMMMMMMMM";
    NSString *shortLine = title ? @"MMMMMMMMMMMM" : @"MMMMMMMMMMMMMMMM";
    for (NSUInteger index = 0; index < lineCount; index++) {
        [lines addObject:index + 1 == lineCount ? shortLine : longLine];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSDictionary *ApolloLPPreparedNodeBundle(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPNodeBundleForHost(hostNode, url, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    ApolloLPResetStyle([imageNode style]);
    ApolloLPResetStyle([avatarNode style]);
    ApolloLPResetStyle([backgroundNode style]);
    ApolloLPResetTextNode(siteNode, 1);
    ApolloLPResetTextNode(titleNode, 3);
    ApolloLPResetTextNode(descriptionNode, 4);
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    NSString *siteName = preview.siteName.length > 0 ? preview.siteName : ApolloLPHost(url);
    imageNode.URL = preview.imageURL;
    imageNode.backgroundColor = preview.imageURL.absoluteString.length > 0 ? nil : [UIColor tertiarySystemFillColor];
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.clipsToBounds = YES;
    avatarNode.URL = nil;
    avatarNode.backgroundColor = [UIColor tertiarySystemFillColor];
    avatarNode.contentMode = UIViewContentModeScaleAspectFill;
    avatarNode.clipsToBounds = YES;
    avatarNode.cornerRadius = 18.0;
    siteNode.attributedText = ApolloLPAttributedString([siteName uppercaseString], [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold], [UIColor secondaryLabelColor]);
    titleNode.attributedText = ApolloLPAttributedString(preview.title, [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], [UIColor labelColor]);
    descriptionNode.attributedText = ApolloLPAttributedString(preview.desc, [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]);
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);

    return bundle;
}

static id ApolloLPBackgroundWrappedSpec(id contentSpec, ASDisplayNode *backgroundNode, Class backgroundClass) {
    if (backgroundClass && [backgroundClass respondsToSelector:@selector(backgroundLayoutSpecWithChild:background:)]) {
        return [backgroundClass backgroundLayoutSpecWithChild:contentSpec background:backgroundNode];
    }
    return contentSpec;
}

static id ApolloLPMeasuredWrapper(id cardSpec, Class insetClass) {
    if (insetClass && [insetClass respondsToSelector:@selector(insetLayoutSpecWithInsets:child:)]) {
        return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsZero child:cardSpec];
    }
    return cardSpec;
}

static NSUInteger ApolloLPCompactDescriptionLineCount(ApolloLinkPreview *preview) {
    NSUInteger titleLength = preview.title.length;
    if (titleLength >= 110) return 0;
    if (titleLength >= 70) return 1;
    return 2;
}

static id ApolloLPBuildCompactCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    imageNode.cornerRadius = 8.0;
    NSUInteger descriptionLineCount = ApolloLPCompactDescriptionLineCount(preview);
    titleNode.maximumNumberOfLines = 2;
    descriptionNode.maximumNumberOfLines = descriptionLineCount;
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    NSMutableArray *textChildren = [NSMutableArray array];
    if (siteNode.attributedText.length > 0) [textChildren addObject:siteNode];
    if (titleNode.attributedText.length > 0) [textChildren addObject:titleNode];
    if (descriptionLineCount > 0 && descriptionNode.attributedText.length > 0) [textChildren addObject:descriptionNode];
    if (textChildren.count == 0) return nil;

    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:3.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:textChildren];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];

    NSMutableArray *rowChildren = [NSMutableArray array];
    if (preview.imageURL.absoluteString.length > 0) {
        imageNode.contentMode = UIViewContentModeScaleAspectFill;
        imageNode.cornerRadius = 8.0;
        ApolloLPApplyStyleSize([imageNode style], CGSizeMake(84.0, 84.0));
        [rowChildren addObject:imageNode];
    }
    [rowChildren addObject:textStack];

    ASStackLayoutSpec *row = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                              spacing:10.0
                                                       justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                           alignItems:ApolloLinkPreviewStackAlignItemsStart
                                                             children:rowChildren];
    ASInsetLayoutSpec *contentInset = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) child:row];
    id card = ApolloLPBackgroundWrappedSpec(contentInset, backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static NSUInteger ApolloLPHeroDescriptionLineCount(ApolloLinkPreview *preview) {
    NSUInteger titleLength = preview.title.length;
    if (titleLength >= 120) return 0;
    return 1;
}

static id ApolloLPBuildHeroCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class ratioClass = ApolloLPClass(@"ASRatioLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    imageNode.cornerRadius = 10.0;
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    BOOL isYouTube = ApolloLPIsYouTubeURL(url);
    BOOL isPosterPreview = ApolloLPIsPosterPreviewURL(url, preview);
    NSUInteger descriptionLineCount = ApolloLPHeroDescriptionLineCount(preview);
    titleNode.maximumNumberOfLines = 2;
    descriptionNode.maximumNumberOfLines = descriptionLineCount;
    titleNode.attributedText = ApolloLPAttributedString(preview.title, [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold], [UIColor labelColor]);
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    NSMutableArray *textChildren = [NSMutableArray array];
    if (siteNode.attributedText.length > 0) [textChildren addObject:siteNode];
    if (titleNode.attributedText.length > 0) [textChildren addObject:titleNode];
    if (descriptionLineCount > 0 && descriptionNode.attributedText.length > 0) [textChildren addObject:descriptionNode];
    if (textChildren.count == 0) return nil;

    NSMutableArray *cardChildren = [NSMutableArray array];
    if (preview.imageURL.absoluteString.length > 0 && ratioClass) {
        // Cap the hero image at a 0.6 (5:3) ratio rather than the previous
        // 1.0 (square) cap. Square / portrait preview images (page
        // screenshots from archive.is, vertical news hero shots, etc.) were
        // producing ~360pt-tall image blocks at feed width which made the
        // whole card balloon and run off the screen. Wide images (16:9,
        // 4:3, 3:2) are untouched because the MIN keeps their natural
        // ratio; only tall ones are clamped down here. The card width is
        // already bounded by the enclosing cell, so this is sufficient to
        // bound total card height without needing a separate maxHeight on
        // ASLayoutElementStyle (which takes an ASDimension struct and
        // therefore can't be set via simple KVC).
        CGFloat ratio = 9.0 / 16.0;
        CGSize imageSize = preview.imageSize;
        if (!isYouTube && imageSize.width > 1.0 && imageSize.height > 1.0) {
            CGFloat naturalRatio = imageSize.height / imageSize.width;
            if (isPosterPreview) {
                imageNode.contentMode = UIViewContentModeScaleAspectFit;
                ratio = MAX(MIN(naturalRatio, 1.1), 0.6);
                ApolloLPLogOncePerHost(ApolloLPHost(url), [NSString stringWithFormat:@"V12-poster-hero-image ratio=%.2f", ratio]);
            } else {
                ratio = MAX(MIN(naturalRatio, 0.6), 0.45);
            }
        }

        [cardChildren addObject:[ratioClass ratioLayoutSpecWithRatio:ratio child:imageNode]];
    }

    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:4.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:textChildren];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];
    UIEdgeInsets textInsets = isYouTube ? UIEdgeInsetsMake(8.0, 12.0, 10.0, 12.0) : UIEdgeInsetsMake(9.0, 12.0, 11.0, 12.0);
    ASInsetLayoutSpec *paddedText = [insetClass insetLayoutSpecWithInsets:textInsets child:textStack];
    [cardChildren addObject:paddedText];

    ASStackLayoutSpec *cardStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:0.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:cardChildren];
    id card = ApolloLPBackgroundWrappedSpec(cardStack, backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static BOOL ApolloLPIsBlueskyPostURL(NSURL *url) {
    if (!ApolloLPHostHasSuffix(url, @"bsky.app")) return NO;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part.lowercaseString];
    }
    return parts.count >= 4
        && [parts[0] isEqualToString:@"profile"]
        && [parts[2] isEqualToString:@"post"];
}

static BOOL ApolloLPIsBlueskyPostPreview(NSURL *url, ApolloLinkPreview *preview) {
    return ApolloLPIsBlueskyPostURL(url)
        && [preview.previewKind isEqualToString:@"bluesky-post-v2"]
        && (preview.postText.length > 0 || preview.authorDisplayName.length > 0 || preview.authorHandle.length > 0);
}

static NSString *ApolloLPBlueskyHandleText(ApolloLinkPreview *preview) {
    NSString *handle = preview.authorHandle;
    if (handle.length == 0) return @"Bluesky";
    return [handle hasPrefix:@"@"] ? handle : [@"@" stringByAppendingString:handle];
}

static id ApolloLPBuildBlueskyPostCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class ratioClass = ApolloLPClass(@"ASRatioLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    NSString *displayName = preview.authorDisplayName.length > 0 ? preview.authorDisplayName : (preview.title.length > 0 ? preview.title : @"Bluesky");
    NSString *handleText = ApolloLPBlueskyHandleText(preview);
    NSString *postText = preview.postText.length > 0 ? preview.postText : preview.desc;
    BOOL imageIsAvatar = preview.avatarURL.absoluteString.length > 0
        && [preview.imageURL.absoluteString isEqualToString:preview.avatarURL.absoluteString];
    BOOL hasPostImage = preview.imageURL.absoluteString.length > 0 && !imageIsAvatar && !preview.imageIsFallbackIcon;

    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    imageNode.URL = hasPostImage ? preview.imageURL : nil;
    imageNode.backgroundColor = hasPostImage ? nil : [UIColor clearColor];
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.cornerRadius = 10.0;
    imageNode.clipsToBounds = YES;

    avatarNode.URL = preview.avatarURL;
    avatarNode.backgroundColor = preview.avatarURL.absoluteString.length > 0 ? nil : [UIColor tertiarySystemFillColor];
    avatarNode.cornerRadius = 18.0;
    avatarNode.clipsToBounds = YES;
    ApolloLPApplyStyleSize([avatarNode style], CGSizeMake(36.0, 36.0));

    titleNode.maximumNumberOfLines = 1;
    siteNode.maximumNumberOfLines = 1;
    descriptionNode.maximumNumberOfLines = 10;
    titleNode.attributedText = ApolloLPAttributedString(displayName, [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], [UIColor labelColor]);
    siteNode.attributedText = ApolloLPAttributedString(handleText, [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]);
    descriptionNode.attributedText = ApolloLPAttributedString(postText, [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular], [UIColor labelColor]);

    ASStackLayoutSpec *authorTextStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                          spacing:1.0
                                                                   justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                       alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                         children:@[titleNode, siteNode]];
    [[authorTextStack style] setValue:@1.0 forKey:@"flexShrink"];

    ASStackLayoutSpec *authorRow = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                                    spacing:9.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsCenter
                                                                   children:@[avatarNode, authorTextStack]];
    [[authorRow style] setValue:@1.0 forKey:@"flexShrink"];

    NSMutableArray *contentChildren = [NSMutableArray arrayWithObject:authorRow];
    if (descriptionNode.attributedText.length > 0) {
        [contentChildren addObject:descriptionNode];
    }

    ASStackLayoutSpec *contentStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                       spacing:9.0
                                                                justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                    alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                      children:contentChildren];
    [[contentStack style] setValue:@1.0 forKey:@"flexShrink"];

    NSMutableArray *cardChildren = [NSMutableArray array];
    if (hasPostImage && ratioClass) {
        CGFloat ratio = 9.0 / 16.0;
        CGSize imageSize = preview.imageSize;
        if (imageSize.width > 1.0 && imageSize.height > 1.0) {
            ratio = MAX(MIN(imageSize.height / imageSize.width, 0.75), 0.45);
        }
        [cardChildren addObject:[ratioClass ratioLayoutSpecWithRatio:ratio child:imageNode]];
    }
    [cardChildren addObject:[insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(11.0, 12.0, 12.0, 12.0) child:contentStack]];

    ASStackLayoutSpec *cardStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:0.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:cardChildren];
    id card = ApolloLPBackgroundWrappedSpec(cardStack, backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static id ApolloLPBuildPlaceholderSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLPContext context, NSString *variant) {
    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    preview.siteName = ApolloLPHost(url);
    preview.title = @" ";
    preview.desc = context == ApolloLPContextSelfText ? @" " : nil;

    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class ratioClass = ApolloLPClass(@"ASRatioLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    UIColor *placeholder = [UIColor tertiarySystemFillColor];
    imageNode.URL = nil;
    imageNode.backgroundColor = placeholder;
    imageNode.cornerRadius = context == ApolloLPContextSelfText ? 10.0 : 8.0;
    siteNode.attributedText = ApolloLPAttributedString([preview.siteName uppercaseString], [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold], [UIColor secondaryLabelColor]);
    NSUInteger titleLines = context == ApolloLPContextSelfText ? 2 : 1;
    NSUInteger descriptionLines = context == ApolloLPContextSelfText ? 1 : 2;
    titleNode.maximumNumberOfLines = titleLines;
    descriptionNode.maximumNumberOfLines = context == ApolloLPContextSelfText ? descriptionLines : 1;
    titleNode.attributedText = ApolloLPAttributedString(ApolloLPPlaceholderLines(titleLines, YES), context == ApolloLPContextSelfText ? [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], placeholder);
    descriptionNode.attributedText = ApolloLPAttributedString(ApolloLPPlaceholderLines(descriptionLines, NO), [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], placeholder);

    if (context == ApolloLPContextSelfText && ratioClass) {
        NSMutableArray *children = [NSMutableArray array];
        [children addObject:[ratioClass ratioLayoutSpecWithRatio:9.0 / 16.0 child:imageNode]];

        ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                        spacing:4.0
                                                                 justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                     alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                       children:@[siteNode, titleNode, descriptionNode]];
        [[textStack style] setValue:@1.0 forKey:@"flexShrink"];
        [children addObject:[insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(8.0, 12.0, 10.0, 12.0) child:textStack]];

        ASStackLayoutSpec *cardStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                        spacing:0.0
                                                                 justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                     alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                       children:children];
        ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
        backgroundNode.cornerRadius = 10.0;
        backgroundNode.clipsToBounds = YES;
        id card = ApolloLPBackgroundWrappedSpec(cardStack, backgroundNode, backgroundClass);
        return ApolloLPMeasuredWrapper(card, insetClass);
    }

    ApolloLPApplyStyleSize([imageNode style], CGSizeMake(84.0, 84.0));
    titleNode.maximumNumberOfLines = 1;
    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:3.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:@[siteNode, titleNode]];
    [[textStack style] setValue:@1.0 forKey:@"flexGrow"];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];
    ASStackLayoutSpec *row = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                              spacing:10.0
                                                       justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                           alignItems:ApolloLinkPreviewStackAlignItemsStart
                                                             children:@[imageNode, textStack]];
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;
    id card = ApolloLPBackgroundWrappedSpec([insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) child:row], backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static void ApolloLPInvokeTransitionLayoutIfPossible(id node) {
    if (!node) return;
    SEL transitionSel = NSSelectorFromString(@"transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:");
    if (![node respondsToSelector:transitionSel]) return;

    NSMethodSignature *signature = [node methodSignatureForSelector:transitionSel];
    if (!signature) return;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = node;
    invocation.selector = transitionSel;
    BOOL animated = NO;
    BOOL async = NO;
    void (^completion)(void) = nil;
    [invocation setArgument:&animated atIndex:2];
    [invocation setArgument:&async atIndex:3];
    [invocation setArgument:&completion atIndex:4];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
    }
}

static BOOL ApolloLPInvokeRelayoutItemsIfPossible(id node) {
    if (!node) return NO;

    SEL relayoutItems = NSSelectorFromString(@"relayoutItems");
    if (![node respondsToSelector:relayoutItems]) return NO;

    @try {
        ((void (*)(id, SEL))objc_msgSend)(node, relayoutItems);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static ASDisplayNode *ApolloLPFindOwningCellNode(ASDisplayNode *node) {
    NSUInteger depth = 0;
    for (ASDisplayNode *current = node; current && depth < 32; current = current.supernode, depth++) {
        if ([NSStringFromClass([current class]) containsString:@"CellNode"]) {
            return current;
        }
    }
    return nil;
}

static BOOL ApolloLPInvokeScrollViewHeightRefresh(ASDisplayNode *node) {
    UIView *view = ApolloLPViewForNode(node);
    for (UIView *current = view; current; current = current.superview) {
        if ([current isKindOfClass:[UITableView class]]) {
            UITableView *tableView = (UITableView *)current;
            [tableView beginUpdates];
            [tableView endUpdates];
            return YES;
        }

        if ([current isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)current;
            [collectionView performBatchUpdates:nil completion:nil];
            return YES;
        }
    }

    return NO;
}

static id ApolloLPTextureNodeForScrollView(UIView *scrollView) {
    if (!scrollView) return nil;

    SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
    for (NSUInteger index = 0; index < sizeof(nodeSelectors) / sizeof(SEL); index++) {
        SEL selector = nodeSelectors[index];
        if (![scrollView respondsToSelector:selector]) continue;
        @try {
            id node = ((id (*)(id, SEL))objc_msgSend)(scrollView, selector);
            if ([node respondsToSelector:NSSelectorFromString(@"relayoutItems")]) return node;
        } @catch (__unused NSException *exception) {
        }
    }

    @try {
        id node = [scrollView valueForKey:@"asyncdisplaykit_node"];
        if ([node respondsToSelector:NSSelectorFromString(@"relayoutItems")]) return node;
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

static BOOL ApolloLPInvokeTextureScrollRelayoutIfPossible(UIView *scrollView, NSString *host, NSString *kind) {
    id node = ApolloLPTextureNodeForScrollView(scrollView);
    if (!node) return NO;

    if (!ApolloLPInvokeRelayoutItemsIfPossible(node)) return NO;
    ApolloLPLogOncePerHost(host, [NSString stringWithFormat:@"V12-texture-scroll-relayout kind=%@", kind ?: @"unknown"]);
    return YES;
}

static BOOL ApolloLPInvokeRowReloadIfPossible(ASDisplayNode *startNode, NSString *host) {
    UIView *cellView = ApolloLPViewForNode(startNode);
    if (!cellView) {
        ApolloLPLogOncePerHost(host, @"V12-row-reload-miss no-view");
        return NO;
    }

    UITableViewCell *tableCell = nil;
    UICollectionViewCell *collectionCell = nil;
    for (UIView *current = cellView; current; current = current.superview) {
        if (!tableCell && [current isKindOfClass:[UITableViewCell class]]) {
            tableCell = (UITableViewCell *)current;
        }
        if (!collectionCell && [current isKindOfClass:[UICollectionViewCell class]]) {
            collectionCell = (UICollectionViewCell *)current;
        }

        if (tableCell && [current isKindOfClass:[UITableView class]]) {
            UITableView *tableView = (UITableView *)current;
            NSIndexPath *indexPath = [tableView indexPathForCell:tableCell];
            if (!indexPath) return NO;

            NSString *hostCopy = [host copy];
            NSIndexPath *indexPathCopy = [indexPath copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (![[tableView indexPathsForVisibleRows] containsObject:indexPathCopy]) return;
                    ApolloLPInvokeTextureScrollRelayoutIfPossible(tableView, hostCopy, @"table");
                    [tableView reloadRowsAtIndexPaths:@[indexPathCopy] withRowAnimation:UITableViewRowAnimationNone];
                    ApolloLPLogOncePerHost(hostCopy, [NSString stringWithFormat:@"V12-row-reload kind=table row=%ld", (long)indexPathCopy.row]);
                } @catch (__unused NSException *exception) {
                }
            });
            return YES;
        }

        if (collectionCell && [current isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)current;
            NSIndexPath *indexPath = [collectionView indexPathForCell:collectionCell];
            if (!indexPath) return NO;

            NSString *hostCopy = [host copy];
            NSIndexPath *indexPathCopy = [indexPath copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (![[collectionView indexPathsForVisibleItems] containsObject:indexPathCopy]) return;
                    ApolloLPInvokeTextureScrollRelayoutIfPossible(collectionView, hostCopy, @"collection");
                    [collectionView performBatchUpdates:^{
                        [collectionView reloadItemsAtIndexPaths:@[indexPathCopy]];
                    } completion:nil];
                    ApolloLPLogOncePerHost(hostCopy, [NSString stringWithFormat:@"V12-row-reload kind=collection row=%ld", (long)indexPathCopy.item]);
                } @catch (__unused NSException *exception) {
                }
            });
            return YES;
        }
    }

    ApolloLPLogOncePerHost(host, @"V12-row-reload-miss no-scroll-cell");
    return NO;
}

static void ApolloLPInvokeContainerRelayoutIfPossible(ASDisplayNode *node, ASDisplayNode *cellNode, NSString *host) {
    ASDisplayNode *containerNode = nil;
    NSUInteger depth = 0;
    for (ASDisplayNode *current = cellNode ?: node; current && depth < 48; current = current.supernode, depth++) {
        NSString *className = NSStringFromClass([current class]);
        if ([className containsString:@"TableNode"] || [className containsString:@"CollectionNode"]) {
            containerNode = current;
            break;
        }
    }

    if (containerNode && ApolloLPInvokeRelayoutItemsIfPossible(containerNode)) {
        ApolloLPLogOncePerHost(host, @"V12-table-relayout-items");
        return;
    }

    if (ApolloLPInvokeScrollViewHeightRefresh(cellNode ?: node)) {
        ApolloLPLogOncePerHost(host, @"V12-scrollview-height-refresh");
    }
}

static void ApolloLPTriggerRelayoutInternal(ASDisplayNode *node, BOOL scheduleDelayed, NSString *host) {
    ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(node);
    NSUInteger depth = 0;
    for (ASDisplayNode *current = node; current && depth < 32; current = current.supernode, depth++) {
        SEL invalidate = @selector(invalidateCalculatedLayout);
        if ([current respondsToSelector:invalidate]) {
            ((void (*)(id, SEL))objc_msgSend)(current, invalidate);
        }

        SEL relayout = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
        if ([current respondsToSelector:relayout]) {
            ((void (*)(id, SEL))objc_msgSend)(current, relayout);
        }

        SEL setNeedsLayout = @selector(setNeedsLayout);
        if ([current respondsToSelector:setNeedsLayout]) {
            ((void (*)(id, SEL))objc_msgSend)(current, setNeedsLayout);
        }
    }

    if (cellNode) {
        ApolloLPInvokeTransitionLayoutIfPossible(cellNode);
    }

    if (!scheduleDelayed) {
        ApolloLPInvokeContainerRelayoutIfPossible(node, cellNode, host);
    }

    if (scheduleDelayed) {
        __weak ASDisplayNode *weakNode = node;
        NSString *hostCopy = [host copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            ASDisplayNode *strongNode = weakNode;
            if (strongNode) ApolloLPTriggerRelayoutInternal(strongNode, NO, hostCopy);
        });
    }
}

static void ApolloLPTriggerRelayoutForHost(ASDisplayNode *node, NSString *host) {
    ApolloLPTriggerRelayoutInternal(node, YES, host);
}

static void ApolloLPTriggerPlaceholderContextRelayout(ASDisplayNode *node, NSString *host, ApolloLPContext fromContext, ApolloLPContext toContext) {
    if (!node) return;

    ApolloLog(@"[LinkPreviews] V12-placeholder-context-shrink-refresh host=%@ from=%@ to=%@",
              host ?: @"(nohost)", ApolloLPContextLogName(fromContext), ApolloLPContextLogName(toContext));
    ApolloLPTriggerRelayoutInternal(node, NO, host);
    ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(node);
    ApolloLPInvokeRowReloadIfPossible(cellNode ?: node, host);

    __weak ASDisplayNode *weakNode = node;
    NSString *hostCopy = [host copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        ASDisplayNode *strongNode = weakNode;
        if (!strongNode) return;
        ASDisplayNode *strongCellNode = ApolloLPFindOwningCellNode(strongNode);
        ApolloLPInvokeRowReloadIfPossible(strongCellNode ?: strongNode, hostCopy);
    });
}

static ASDisplayNode *ApolloLPNodeForViewIfPossible(UIView *view) {
    if (!view) return nil;
    SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
    for (NSUInteger index = 0; index < sizeof(nodeSelectors) / sizeof(SEL); index++) {
        SEL selector = nodeSelectors[index];
        if (![view respondsToSelector:selector]) continue;
        @try {
            id node = ((id (*)(id, SEL))objc_msgSend)(view, selector);
            if ([node respondsToSelector:@selector(supernode)] || [node respondsToSelector:@selector(subnodes)]) return node;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static NSUInteger ApolloLPRecolorLinkPreviewBackgroundsForNode(ASDisplayNode *node) {
    if (!node) return 0;

    NSUInteger recolored = 0;
    NSDictionary<NSString *, NSDictionary *> *bundles = objc_getAssociatedObject(node, &kApolloLinkPreviewNodesKey);
    if ([bundles isKindOfClass:[NSDictionary class]]) {
        for (NSDictionary *bundle in bundles.allValues) {
            if (![bundle isKindOfClass:[NSDictionary class]]) continue;
            ASDisplayNode *backgroundNode = bundle[@"background"];
            NSURL *url = bundle[@"url"];
            if (![url isKindOfClass:[NSURL class]]) continue;
            if (ApolloLPApplyCardBackgroundColor(node, backgroundNode, url, YES)) {
                recolored++;
            }
        }
    }

    if (recolored > 0) {
        ApolloLPTriggerRelayoutForHost(node, @"card-color-refresh");
    }
    return recolored;
}

static ApolloLPRegisteredRecolorResult ApolloLPRecolorRegisteredLinkPreviewBackgrounds(void) {
    ApolloLPRegisteredRecolorResult result = {0, 0};
    NSArray *nodes = ApolloLPRegisteredLinkPreviewNodesSnapshot();
    result.nodes = nodes.count;

    for (id object in nodes) {
        if (![object respondsToSelector:@selector(supernode)] && ![object respondsToSelector:@selector(subnodes)]) continue;
        result.recolored += ApolloLPRecolorLinkPreviewBackgroundsForNode((ASDisplayNode *)object);
    }

    return result;
}

static NSUInteger ApolloLPRecolorLinkPreviewBackgroundsInTree(id object, NSUInteger depth, NSHashTable *visitedObjects) {
    if (!object || depth == 0) return 0;
    if ([visitedObjects containsObject:object]) return 0;
    [visitedObjects addObject:object];

    NSUInteger recolored = 0;
    if ([object isKindOfClass:[UIView class]]) {
        ASDisplayNode *node = ApolloLPNodeForViewIfPossible((UIView *)object);
        if (node) {
            recolored += ApolloLPRecolorLinkPreviewBackgroundsInTree(node, depth - 1, visitedObjects);
        }
        for (UIView *subview in ((UIView *)object).subviews) {
            recolored += ApolloLPRecolorLinkPreviewBackgroundsInTree(subview, depth - 1, visitedObjects);
        }
        return recolored;
    }

    if ([object respondsToSelector:@selector(supernode)] || [object respondsToSelector:@selector(subnodes)]) {
        ASDisplayNode *node = (ASDisplayNode *)object;
        recolored += ApolloLPRecolorLinkPreviewBackgroundsForNode(node);

        if ([node respondsToSelector:@selector(subnodes)]) {
            @try {
                NSArray *subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
                if ([subnodes isKindOfClass:[NSArray class]]) {
                    for (id subnode in subnodes) {
                        recolored += ApolloLPRecolorLinkPreviewBackgroundsInTree(subnode, depth - 1, visitedObjects);
                    }
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }

    return recolored;
}

static NSUInteger ApolloLPInvalidateLinkButtonNodesInTree(id object, NSUInteger depth, NSHashTable *visitedObjects) {
    if (!object || depth == 0) return 0;
    if ([visitedObjects containsObject:object]) return 0;
    [visitedObjects addObject:object];

    NSUInteger invalidated = 0;
    if ([object isKindOfClass:[UIView class]]) {
        ASDisplayNode *node = ApolloLPNodeForViewIfPossible((UIView *)object);
        if (node) {
            invalidated += ApolloLPInvalidateLinkButtonNodesInTree(node, depth - 1, visitedObjects);
        }
        for (UIView *subview in ((UIView *)object).subviews) {
            invalidated += ApolloLPInvalidateLinkButtonNodesInTree(subview, depth - 1, visitedObjects);
        }
        return invalidated;
    }

    if ([object respondsToSelector:@selector(supernode)] || [object respondsToSelector:@selector(subnodes)]) {
        ASDisplayNode *node = (ASDisplayNode *)object;
        NSString *className = NSStringFromClass([object class]);
        if ([className containsString:@"LinkButtonNode"]) {
            ApolloLPTriggerRelayoutForHost(node, @"mode-change-node");
            invalidated++;
        }

        if ([node respondsToSelector:@selector(subnodes)]) {
            @try {
                NSArray *subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
                if ([subnodes isKindOfClass:[NSArray class]]) {
                    for (id subnode in subnodes) {
                        invalidated += ApolloLPInvalidateLinkButtonNodesInTree(subnode, depth - 1, visitedObjects);
                    }
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }

    return invalidated;
}

static NSUInteger ApolloLPRefreshLinkPreviewScrollViewsInView(UIView *view, NSHashTable<UIView *> *visitedViews) {
    if (!view || view.hidden || view.alpha < 0.01) return 0;
    if ([visitedViews containsObject:view]) return 0;
    [visitedViews addObject:view];

    NSUInteger refreshCount = 0;
    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)view;
        @try {
            [tableView beginUpdates];
            [tableView endUpdates];
            [tableView setNeedsLayout];
            [tableView layoutIfNeeded];
            refreshCount++;
        } @catch (__unused NSException *exception) {
        }
    } else if ([view isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collectionView = (UICollectionView *)view;
        @try {
            [collectionView performBatchUpdates:nil completion:nil];
            [collectionView setNeedsLayout];
            [collectionView layoutIfNeeded];
            refreshCount++;
        } @catch (__unused NSException *exception) {
        }
    }

    for (UIView *subview in view.subviews) {
        refreshCount += ApolloLPRefreshLinkPreviewScrollViewsInView(subview, visitedViews);
    }
    return refreshCount;
}

static void ApolloLPRefreshVisibleLayoutsForModeChange(NSString *areaName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL cardColorRefresh = [areaName isEqualToString:@"card-color"];
        ApolloLPRegisteredRecolorResult registeredResult = {0, 0};
        if (cardColorRefresh) {
            registeredResult = ApolloLPRecolorRegisteredLinkPreviewBackgrounds();
        }

        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow && !window.hidden && window.alpha > 0.01) {
                        [windows addObject:window];
                    }
                }
            }
        }

        if (windows.count == 0) {
            UIWindow *keyWindow = nil;
            SEL keyWindowSel = NSSelectorFromString(@"keyWindow");
            if ([UIApplication.sharedApplication respondsToSelector:keyWindowSel]) {
                keyWindow = ((UIWindow *(*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, keyWindowSel);
            }
            if (keyWindow && !keyWindow.hidden && keyWindow.alpha > 0.01) {
                [windows addObject:keyWindow];
            }
        }

        NSUInteger visibleRecolored = 0;
        NSHashTable *visitedRecolorObjects = [NSHashTable weakObjectsHashTable];
        NSHashTable *visitedLayoutObjects = [NSHashTable weakObjectsHashTable];
        NSUInteger invalidatedNodes = 0;
        for (UIWindow *window in windows) {
            if (cardColorRefresh) {
                visibleRecolored += ApolloLPRecolorLinkPreviewBackgroundsInTree(window, 24, visitedRecolorObjects);
            }
            invalidatedNodes += ApolloLPInvalidateLinkButtonNodesInTree(window, 24, visitedLayoutObjects);
        }

        NSHashTable<UIView *> *visitedViews = [NSHashTable weakObjectsHashTable];
        NSUInteger refreshCount = 0;
        for (UIWindow *window in windows) {
            refreshCount += ApolloLPRefreshLinkPreviewScrollViewsInView(window, visitedViews);
        }

        if (cardColorRefresh) {
            ApolloLog(@"[LinkPreviews] V14-card-color-global-refresh area=%@ scrollViews=%lu linkNodes=%lu registeredNodes=%lu registeredRecolored=%lu visibleRecolored=%lu",
                      areaName ?: @"unknown",
                      (unsigned long)refreshCount,
                      (unsigned long)invalidatedNodes,
                      (unsigned long)registeredResult.nodes,
                      (unsigned long)registeredResult.recolored,
                      (unsigned long)visibleRecolored);
        } else {
            ApolloLog(@"[LinkPreviews] V12-mode-change-layout-refresh area=%@ scrollViews=%lu linkNodes=%lu",
                      areaName ?: @"unknown", (unsigned long)refreshCount, (unsigned long)invalidatedNodes);
        }
    });
}

static void ApolloLPScheduleCacheLayoutRefresh(NSString *host) {
    static BOOL refreshPending = NO;
    if (refreshPending) return;

    refreshPending = YES;
    NSString *hostCopy = [host copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        refreshPending = NO;
        ApolloLog(@"[LinkPreviews] V12-cache-layout-refresh host=%@", hostCopy ?: @"(nohost)");
        ApolloLPRefreshVisibleLayoutsForModeChange(@"cache-update");
    });
}

// Round 4 diagnostic flag: throttles the per-call logging so a feed scroll
// doesn't spam OSLog with the same host hundreds of times. We still want one
// entry per unique host per session so we can correlate hook activity with
// the user's screenshots.
static NSMutableSet<NSString *> *ApolloLPLoggedHosts(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void ApolloLPLogOncePerHost(NSString *host, NSString *event) {
    if (host.length == 0) host = @"(nohost)";
    NSString *key = [NSString stringWithFormat:@"%@|%@", host, event];
    @synchronized (ApolloLPLoggedHosts()) {
        if ([ApolloLPLoggedHosts() containsObject:key]) return;
        [ApolloLPLoggedHosts() addObject:key];
    }
    ApolloLog(@"[LinkPreviews] %@ host=%@", event, host);
}

static void ApolloLPLogMetadataOnce(NSString *host, ApolloLinkPreview *preview, ApolloLPArea area, NSInteger mode, ApolloLPContext context) {
    if (host.length == 0) host = @"(nohost)";
    NSString *key = [NSString stringWithFormat:@"%@|metadata-v10", host];
    @synchronized (ApolloLPLoggedHosts()) {
        if ([ApolloLPLoggedHosts() containsObject:key]) return;
        [ApolloLPLoggedHosts() addObject:key];
    }

    NSString *areaName = (area == ApolloLPAreaComments) ? @"comments" : @"body";
    NSString *cardName = (context == ApolloLPContextSelfText) ? @"hero" : @"compact";
    ApolloLog(@"[LinkPreviews] V12 metadata host=%@ area=%@ mode=%ld card=%@ site=%d title=%d desc=%d image=%d fallbackIcon=%d titleLen=%lu descLen=%lu",
              host,
              areaName,
              (long)mode,
              cardName,
              preview.siteName.length > 0,
              preview.title.length > 0,
              preview.desc.length > 0,
              preview.imageURL.absoluteString.length > 0,
              preview.imageIsFallbackIcon,
              (unsigned long)preview.title.length,
              (unsigned long)preview.desc.length);
}

static NSString *ApolloLPVariant(ApolloLPArea area, NSInteger mode, ApolloLPContext context, BOOL placeholder) {
    NSString *areaName = (area == ApolloLPAreaComments) ? @"comments" : @"body";
    NSString *contextName = (context == ApolloLPContextSelfText) ? @"hero" : @"compact";
    return [NSString stringWithFormat:@"%@-%@-mode%ld-%@", placeholder ? @"placeholder" : @"final", areaName, (long)mode, contextName];
}

%hook _TtC6Apollo14LinkButtonNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    NSString *urlString = ApolloGetLinkButtonNodeURLString(self);
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (!url) {
        ApolloLPLogOncePerHost(NSStringFromClass([(id)self class]), @"no-url");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    NSString *host = ApolloLPHost(url);
    ApolloLPArea area = ApolloLPAreaForLinkButton((ASDisplayNode *)self);
    NSInteger selectedMode = ApolloLPModeForArea(area);
    if (selectedMode == ApolloLinkPreviewModeOff) {
        ApolloLPLogOncePerHost(host, area == ApolloLPAreaComments ? @"comments-disabled" : @"body-disabled");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    if (ApolloLPShouldDeferToInlineMedia(url)) {
        ApolloLPLogOncePerHost(host, @"defer-inline-media");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }
    if ([ApolloLinkPreviewFetcher isTwitterURL:url]) {
        ApolloLPLogOncePerHost(host, @"defer-twitter");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    ApolloLinkPreview *cached = [[ApolloLinkPreviewCache sharedCache] cachedPreviewForURL:url];
    if (cached && ApolloLPIsBlueskyPostURL(url) && !ApolloLPIsBlueskyPostPreview(url, cached)) {
        ApolloLPLogOncePerHost(host, @"stale-bluesky-inline-refetch");
        cached = nil;
    }
    if (!cached) {
        BOOL compactPlaceholder = selectedMode == ApolloLinkPreviewModeCompact || ApolloLPShouldUseCompactPlaceholder(url);
        ApolloLPContext placeholderContext = compactPlaceholder ? ApolloLPContextCompact : ApolloLPContextSelfText;
        NSNumber *inFlight = objc_getAssociatedObject(self, &kApolloLinkPreviewFetchInFlightKey);
        if (![inFlight boolValue]) {
            ApolloLPLogOncePerHost(host, @"cache-miss-fetch");
            objc_setAssociatedObject(self, &kApolloLinkPreviewFetchInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak ASDisplayNode *weakSelf = (ASDisplayNode *)self;
            [ApolloLinkPreviewFetcher requestPreviewForURL:url completion:^(__unused ApolloLinkPreview *preview) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (preview) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloLinkPreviewDidCacheNotification
                                                                            object:nil
                                                                          userInfo:@{@"url": url}];
                    }
                    ASDisplayNode *strongSelf = weakSelf;
                    if (!strongSelf) return;
                    objc_setAssociatedObject(strongSelf, &kApolloLinkPreviewFetchInFlightKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    ApolloLPTriggerRelayoutForHost(strongSelf, host);
                    ApolloLPScheduleCacheLayoutRefresh(host);
                });
            }];
        }
        id placeholder = ApolloLPBuildPlaceholderSpec((ASDisplayNode *)self, url, placeholderContext, ApolloLPVariant(area, selectedMode, placeholderContext, YES));
        if (placeholder) {
            objc_setAssociatedObject(self, &kApolloLinkPreviewRenderedPlaceholderKey, @(placeholderContext), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLPClearHostShell((ASDisplayNode *)self);
            ApolloLPLogOncePerHost(host, area == ApolloLPAreaComments ? @"area-comments-placeholder" : @"area-body-placeholder");
            ApolloLPLogOncePerHost(host, placeholderContext == ApolloLPContextSelfText ? @"mode-full-placeholder" : @"mode-compact-placeholder");
            ApolloLPLogOncePerHost(host, placeholderContext == ApolloLPContextSelfText ? @"render-hero-placeholder" : @"render-compact-placeholder");
            return placeholder;
        }
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    if (![cached hasUsefulMetadata]) {
        ApolloLPLogOncePerHost(host, @"cache-hit-empty");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    BOOL isBlueskyPost = ApolloLPIsBlueskyPostPreview(url, cached);
    ApolloLPContext context = isBlueskyPost ? ApolloLPContextSelfText : ApolloLPContextForMode(selectedMode, cached);
    ApolloLPLogMetadataOnce(host, cached, area, selectedMode, context);
    if (!isBlueskyPost && cached.imageIsFallbackIcon) {
        ApolloLPRememberCompactPlaceholderHost(url);
        ApolloLPLogOncePerHost(host, @"fallback-icon-compact");
    } else if (!isBlueskyPost && selectedMode == ApolloLinkPreviewModeFull && context == ApolloLPContextCompact) {
        ApolloLPRememberCompactPlaceholderHost(url);
        ApolloLPLogOncePerHost(host, @"full-fallback-compact");
    }
    id richSpec = isBlueskyPost
        ? ApolloLPBuildBlueskyPostCardSpec((ASDisplayNode *)self, url, cached, ApolloLPVariant(area, selectedMode, context, NO))
        : (context == ApolloLPContextSelfText)
        ? ApolloLPBuildHeroCardSpec((ASDisplayNode *)self, url, cached, ApolloLPVariant(area, selectedMode, context, NO))
        : ApolloLPBuildCompactCardSpec((ASDisplayNode *)self, url, cached, ApolloLPVariant(area, selectedMode, context, NO));
    if (richSpec) {
        NSNumber *renderedPlaceholder = objc_getAssociatedObject(self, &kApolloLinkPreviewRenderedPlaceholderKey);
        if (renderedPlaceholder) {
            objc_setAssociatedObject(self, &kApolloLinkPreviewRenderedPlaceholderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak ASDisplayNode *weakSelf = (ASDisplayNode *)self;
            NSString *hostCopy = [host copy];
            ApolloLPContext placeholderContext = (ApolloLPContext)[renderedPlaceholder unsignedIntegerValue];
            BOOL placeholderShrankToCompact = placeholderContext == ApolloLPContextSelfText && context == ApolloLPContextCompact;
            dispatch_async(dispatch_get_main_queue(), ^{
                ASDisplayNode *strongSelf = weakSelf;
                if (!strongSelf) return;
                ApolloLPLogOncePerHost(hostCopy, @"V12-post-final-height-refresh");
                if (placeholderShrankToCompact) {
                    ApolloLPTriggerPlaceholderContextRelayout(strongSelf, hostCopy, placeholderContext, context);
                } else {
                    ApolloLPTriggerRelayoutForHost(strongSelf, hostCopy);
                }
            });
        }
        ApolloLPClearHostShell((ASDisplayNode *)self);
        ApolloLPLogOncePerHost(host, area == ApolloLPAreaComments ? @"area-comments" : @"area-body");
        ApolloLPLogOncePerHost(host, isBlueskyPost ? @"mode-bluesky-post" : (context == ApolloLPContextSelfText ? @"mode-full" : @"mode-compact"));
        ApolloLPLogOncePerHost(host, isBlueskyPost ? @"render-bluesky-post" : (context == ApolloLPContextSelfText ? @"render-hero" : @"render-compact"));
        return richSpec;
    }
    ApolloLPLogOncePerHost(host, @"build-failed");
    ApolloLPRestoreHostShell((ASDisplayNode *)self);
    return %orig;
}

%end

%ctor {
    sApolloLPRegisteredLinkNodes = [NSHashTable weakObjectsHashTable];
    sApolloLPRegisteredLinkNodesQueue = dispatch_queue_create("com.apollo.linkpreviews.nodes", DISPATCH_QUEUE_SERIAL);

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloLinkPreviewModeDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        NSString *areaName = [notification.userInfo[@"area"] isKindOfClass:[NSString class]] ? notification.userInfo[@"area"] : @"unknown";
        ApolloLPRefreshVisibleLayoutsForModeChange(areaName);
    }];

    ApolloLog(@"[LinkPreviews] ctor: hook installed for _TtC6Apollo14LinkButtonNode bodyMode=%ld commentsMode=%ld cardColor=%ld", (long)sLinkPreviewBodyMode, (long)sLinkPreviewCommentsMode, (long)sLinkPreviewCardColor);
    ApolloLog(@"[LinkPreviews] V5 polish active");
    ApolloLog(@"[LinkPreviews] V6 image-kind polish active");
    ApolloLog(@"[LinkPreviews] V7 display modes and placeholders active");
    ApolloLog(@"[LinkPreviews] V8 borderless cards active");
    ApolloLog(@"[LinkPreviews] V9 split body/comment modes active");
    ApolloLog(@"[LinkPreviews] V10 preview text restore active");
    ApolloLog(@"[LinkPreviews] V11 hero-card stability and naked-URL hiding active");
    ApolloLog(@"[LinkPreviews] V13 preset card colors and instant color refresh active");
    ApolloLog(@"[LinkPreviews] V12 cleanup hero sizing active");
    ApolloLog(@"[LinkPreviews] V12 hero image ratio cap 0.6 + nature/client-challenge bypass active");
}
