// ApolloInlineImages.xm
//
// Renders image URLs inside Apollo's selftext / comment markdown bodies as
// actual inline images, replacing the URL text in-place. Tap opens
// MediaViewer (via Apollo's tappedLinkAttribute path); long-press shows
// Copy Link / Share / Open in Safari (UIContextMenuInteraction wins over
// Apollo's cell-level menu since it's installed on the deeper view).
//

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
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
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
static char kApolloImageCacheKey;              // NSString stable cache key (set even before deferred image URLs resolve)
static char kApolloImageURLKey;                // NSURL on the imageNode AND mirrored on the imageNode's view
static char kApolloOriginalImageURLKey;        // NSURL for tap/long-press when different from the loaded URL (e.g. album URL)
static char kApolloHostMarkdownNodeKey;        // weak ref (assign association) to the host MarkdownNode
static char kApolloAspectRatioKey;             // NSNumber height/width — NIL if unknown (no URL params yet, no DIDLOAD yet)
static char kApolloLongPressInstalledKey;      // NSNumber BOOL — gate for one-shot UIContextMenuInteraction install
static char kApolloPlayOverlayViewKey;         // UIView play overlay container, also used as install gate
static char kApolloStackedCardSyncerKey;       // ApolloStackedCardSyncer — keeps the multi-image card peeking behind imageNode

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

// YES for bare Imgur share URLs (imgur.com/<id>) — a single alphanumeric
// path component with no extension. Excludes albums, galleries, tags.
static BOOL ApolloIsImgurShareURL(NSURL *url) {
    NSString *host = [[url host] lowercaseString];
    if (![host isEqualToString:@"imgur.com"] && ![host isEqualToString:@"www.imgur.com"]) return NO;
    if (url.pathExtension.length > 0) return NO;
    NSString *path = url.path ?: @"";
    if ([path hasPrefix:@"/a/"] || [path hasPrefix:@"/gallery/"] || [path hasPrefix:@"/t/"]) return NO;
    NSString *imgurID = path.length > 1 ? [path substringFromIndex:1] : @"";
    if (imgurID.length == 0) return NO;
    if ([imgurID rangeOfString:@"/"].location != NSNotFound) return NO;
    NSCharacterSet *disallowed = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    return [imgurID rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

// Imgur albums (imgur.com/a/<id>) and galleries (imgur.com/gallery/<id>)
// require an API roundtrip to resolve to a renderable image URL. We
// classify them as inline-renderable so they hit the inline pipeline,
// then defer URL assignment until the API resolution completes.
static NSString *ApolloImgurPathID(NSURL *url, NSString *prefix) {
    NSString *host = [[url host] lowercaseString];
    if (![host isEqualToString:@"imgur.com"] && ![host isEqualToString:@"www.imgur.com"]) return nil;
    if (url.pathExtension.length > 0) return nil;
    NSString *path = [url.path stringByRemovingPercentEncoding] ?: @"";
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count != 2 || ![[clean[0] lowercaseString] isEqualToString:prefix]) return nil;
    NSString *imgurID = clean[1];
    NSCharacterSet *disallowed = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    return [imgurID rangeOfCharacterFromSet:disallowed].location == NSNotFound ? imgurID : nil;
}
static NSString *ApolloImgurAlbumID(NSURL *url) { return ApolloImgurPathID(url, @"a"); }
static NSString *ApolloImgurGalleryID(NSURL *url) { return ApolloImgurPathID(url, @"gallery"); }
static BOOL ApolloIsImgurAlbumOrGalleryURL(NSURL *url) {
    return ApolloImgurAlbumID(url).length > 0 || ApolloImgurGalleryID(url).length > 0;
}

static NSString *ApolloImgurResolutionCacheKey(NSURL *url) {
    NSString *albumID = ApolloImgurAlbumID(url);
    if (albumID.length > 0) return [@"album:" stringByAppendingString:albumID];
    NSString *galleryID = ApolloImgurGalleryID(url);
    if (galleryID.length > 0) return [@"gallery:" stringByAppendingString:galleryID];
    return nil;
}

static NSObject *ApolloImgurResolverLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSMutableDictionary<NSString *, id> *ApolloImgurResolverCache(void) {
    static NSMutableDictionary<NSString *, id> *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}
static NSMutableDictionary<NSString *, NSMutableArray *> *ApolloImgurResolverPending(void) {
    static NSMutableDictionary<NSString *, NSMutableArray *> *pending; static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableDictionary dictionary]; });
    return pending;
}

// Build a renderable i.imgur.com URL from an Imgur API image dict.
// Rewrites .gifv/.mp4 to .gif so PINRemoteImage's image pipeline can
// decode it as an animated GIF rather than getting MP4 bytes.
static NSURL *ApolloImgurDisplayURLFromImageDictionary(NSDictionary *image) {
    NSString *link = [image[@"link"] isKindOfClass:[NSString class]] ? image[@"link"] : nil;
    NSString *imageID = [image[@"id"] isKindOfClass:[NSString class]] ? image[@"id"] : nil;
    BOOL animated = [image[@"animated"] respondsToSelector:@selector(boolValue)] && [image[@"animated"] boolValue];
    NSString *type = [image[@"type"] isKindOfClass:[NSString class]] ? [image[@"type"] lowercaseString] : @"";

    if (link.length == 0 && imageID.length > 0) {
        NSString *ext = animated || [type containsString:@"gif"] ? @"gif" : ([type containsString:@"png"] ? @"png" : @"jpg");
        link = [NSString stringWithFormat:@"https://i.imgur.com/%@.%@", imageID, ext];
    }
    if (link.length == 0) return nil;

    NSString *lowerLink = [link lowercaseString];
    if ([lowerLink hasSuffix:@".gifv"] || [lowerLink hasSuffix:@".mp4"]) {
        link = [[link stringByDeletingPathExtension] stringByAppendingPathExtension:@"gif"];
    }
    link = [link stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return [NSURL URLWithString:link];
}

static NSDictionary *ApolloImgurResultFromImageDictionary(NSDictionary *image) {
    if (![image isKindOfClass:[NSDictionary class]]) return nil;
    NSURL *displayURL = ApolloImgurDisplayURLFromImageDictionary(image);
    if (![displayURL isKindOfClass:[NSURL class]]) return nil;

    NSMutableDictionary *result = [@{ @"url": displayURL } mutableCopy];
    NSNumber *width = [image[@"width"] respondsToSelector:@selector(doubleValue)] ? image[@"width"] : nil;
    NSNumber *height = [image[@"height"] respondsToSelector:@selector(doubleValue)] ? image[@"height"] : nil;
    if (width.doubleValue > 0 && height.doubleValue > 0) {
        result[@"width"] = width;
        result[@"height"] = height;
    }
    return result;
}

// Extract a display image from an Imgur API response payload (data field).
// Handles three shapes: bare image dict, album/gallery dict with images[],
// and image-array directly. For albums, prefers the cover image.
static NSDictionary *ApolloImgurResultFromAPIData(id data) {
    if ([data isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)data) {
            NSDictionary *result = ApolloImgurResultFromImageDictionary(item);
            if (result) return result;
        }
        return nil;
    }
    if (![data isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *dict = (NSDictionary *)data;
    NSArray *images = [dict[@"images"] isKindOfClass:[NSArray class]] ? dict[@"images"] : nil;
    if (images.count > 0) {
        NSDictionary *picked = nil;
        NSString *coverID = [dict[@"cover"] isKindOfClass:[NSString class]] ? dict[@"cover"] : nil;
        if (coverID.length > 0) {
            for (id item in images) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *imageID = [item[@"id"] isKindOfClass:[NSString class]] ? item[@"id"] : nil;
                if ([imageID isEqualToString:coverID]) {
                    picked = ApolloImgurResultFromImageDictionary(item);
                    if (picked) break;
                }
            }
        }
        if (!picked) {
            for (id item in images) {
                picked = ApolloImgurResultFromImageDictionary(item);
                if (picked) break;
            }
        }
        if (!picked) return nil;
        NSMutableDictionary *out = [picked mutableCopy];
        out[@"count"] = @(images.count);
        return out;
    }
    return ApolloImgurResultFromImageDictionary(dict);
}

// Galleries can be albums, single images, or "topic" wrappers — try each
// shape until one parses. Albums have a fixed endpoint.
static NSArray<NSURL *> *ApolloImgurAPIEndpointsForURL(NSURL *url) {
    NSString *albumID = ApolloImgurAlbumID(url);
    if (albumID.length > 0) {
        return @[[NSURL URLWithString:[@"https://api.imgur.com/3/album/" stringByAppendingString:albumID]]];
    }
    NSString *galleryID = ApolloImgurGalleryID(url);
    if (galleryID.length > 0) {
        return @[
            [NSURL URLWithString:[@"https://api.imgur.com/3/gallery/album/" stringByAppendingString:galleryID]],
            [NSURL URLWithString:[@"https://api.imgur.com/3/gallery/image/" stringByAppendingString:galleryID]],
            [NSURL URLWithString:[@"https://api.imgur.com/3/gallery/" stringByAppendingString:galleryID]],
            [NSURL URLWithString:[@"https://api.imgur.com/3/album/" stringByAppendingString:galleryID]],
        ];
    }
    return @[];
}

static void ApolloDeliverImgurResolution(NSString *cacheKey, NSDictionary *result) {
    NSArray *callbacks = nil;
    @synchronized (ApolloImgurResolverLock()) {
        ApolloImgurResolverCache()[cacheKey] = result ?: (id)[NSNull null];
        callbacks = [ApolloImgurResolverPending()[cacheKey] copy];
        [ApolloImgurResolverPending() removeObjectForKey:cacheKey];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^callback)(NSDictionary *) in callbacks) callback(result);
    });
}

static void ApolloFetchImgurEndpointAtIndex(NSArray<NSURL *> *endpoints, NSUInteger index, NSString *cacheKey) {
    if (index >= endpoints.count) {
        ApolloLog(@"[InlineImages] Imgur resolve FAIL key=%@", cacheKey);
        ApolloDeliverImgurResolution(cacheKey, nil);
        return;
    }
    NSURL *endpoint = endpoints[index];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:8.0];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (sImgurClientId.length > 0) {
        [request setValue:[@"Client-ID " stringByAppendingString:sImgurClientId] forHTTPHeaderField:@"Authorization"];
    }
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status < 200 || status >= 300 || data.length == 0) {
            ApolloLog(@"[InlineImages] Imgur endpoint FAIL key=%@ index=%lu status=%ld err=%@",
                      cacheKey, (unsigned long)index, (long)status, error.localizedDescription ?: @"nil");
            ApolloFetchImgurEndpointAtIndex(endpoints, index + 1, cacheKey);
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id payload = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        NSDictionary *result = ApolloImgurResultFromAPIData(payload);
        if (!result) {
            ApolloFetchImgurEndpointAtIndex(endpoints, index + 1, cacheKey);
            return;
        }
        ApolloLog(@"[InlineImages] Imgur resolved key=%@ url=%@ size=%@x%@",
                  cacheKey, result[@"url"], result[@"width"] ?: @"?", result[@"height"] ?: @"?");
        ApolloDeliverImgurResolution(cacheKey, result);
    }];
    [task resume];
}

static NSDictionary *ApolloCachedImgurResolution(NSURL *url) {
    NSString *cacheKey = ApolloImgurResolutionCacheKey(url);
    if (cacheKey.length == 0) return nil;
    @synchronized (ApolloImgurResolverLock()) {
        id cached = ApolloImgurResolverCache()[cacheKey];
        return [cached isKindOfClass:[NSDictionary class]] ? cached : nil;
    }
}

// Resolve an Imgur album/gallery URL to a renderable image. Coalesces
// concurrent calls for the same album/gallery ID. Negative results are
// cached (NSNull) so failed lookups don't retry per-cell.
static void ApolloResolveImgurURL(NSURL *url, void (^completion)(NSDictionary *result)) {
    NSString *cacheKey = ApolloImgurResolutionCacheKey(url);
    NSArray<NSURL *> *endpoints = ApolloImgurAPIEndpointsForURL(url);
    if (cacheKey.length == 0 || endpoints.count == 0) {
        if (completion) completion(nil);
        return;
    }
    void (^callback)(NSDictionary *) = [completion copy];
    BOOL shouldStartFetch = NO;
    NSDictionary *cachedResult = nil;
    BOOL hasCachedFailure = NO;

    @synchronized (ApolloImgurResolverLock()) {
        id cached = ApolloImgurResolverCache()[cacheKey];
        if ([cached isKindOfClass:[NSDictionary class]]) {
            cachedResult = cached;
        } else if (cached == [NSNull null]) {
            hasCachedFailure = YES;
        } else {
            NSMutableArray *pending = ApolloImgurResolverPending()[cacheKey];
            if (pending) {
                if (callback) [pending addObject:callback];
            } else {
                ApolloImgurResolverPending()[cacheKey] = callback ? [NSMutableArray arrayWithObject:callback] : [NSMutableArray array];
                shouldStartFetch = YES;
            }
        }
    }
    if (cachedResult || hasCachedFailure) {
        if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(cachedResult); });
        return;
    }
    if (shouldStartFetch) {
        ApolloLog(@"[InlineImages] Imgur resolve START key=%@ endpoints=%lu", cacheKey, (unsigned long)endpoints.count);
        ApolloFetchImgurEndpointAtIndex(endpoints, 0, cacheKey);
    }
}

static BOOL ApolloIsInlineRenderableImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [[url host] lowercaseString];
    if (host.length == 0) return NO;

    // Imgur share URLs (imgur.com/<id>) — extensionless; normalizer
    // canonicalizes to i.imgur.com/<id>.jpeg.
    // Imgur album/gallery URLs (imgur.com/a/<id>, imgur.com/gallery/<id>) —
    // resolved asynchronously via Imgur API; URL is deferred until
    // resolution completes.
    if (ApolloIsImgurShareURL(url) || ApolloIsImgurAlbumOrGalleryURL(url)) return YES;

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

static BOOL ApolloIsInlineRenderableVideoURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [[url host] lowercaseString];
    if (host.length == 0) return NO;

    // Two URL forms we know how to derive a poster for:
    //   1. Reddit pseudo-MP4 GIFs (preview.redd.it/*.gif?format=mp4) →
    //      poster from mediaMetadata[id].p[] signed thumbnail.
    //   2. Reddit hosted video permalinks
    //      (reddit.com/link/<post>/video/<asset>/player) → poster from
    //      DASH manifest + AVAssetImageGenerator frame extraction.
    NSString *ext = [[url path] pathExtension].lowercaseString ?: @"";
    NSString *q = [[url query] lowercaseString] ?: @"";
    BOOL isRedditPreview = [host isEqualToString:@"preview.redd.it"]
                          || [host isEqualToString:@"external-preview.redd.it"]
                          || [host hasSuffix:@".redd.it"];
    if (isRedditPreview && [ext isEqualToString:@"gif"] && [q containsString:@"format=mp4"]) return YES;

    NSString *path = [[url path] lowercaseString] ?: @"";
    BOOL isReddit = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    if (isReddit && [path hasPrefix:@"/link/"] && [path containsString:@"/video/"]
        && [path hasSuffix:@"/player"]) return YES;

    return NO;
}

// Returns the mediaMetadata key for a given video URL — either the image
// id (pseudo-MP4 GIFs) or the asset id (player URLs). Both forms key the
// metadata dict by id.
static NSString *ApolloMediaMetadataIDFromVideoURL(NSURL *videoURL) {
    NSString *host = [[videoURL host] lowercaseString] ?: @"";
    NSString *path = [videoURL path] ?: @"";
    if ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) {
        // /link/<post>/video/<asset>/player → asset
        NSArray<NSString *> *comps = [path componentsSeparatedByString:@"/"];
        if (comps.count >= 6 && [comps[1] isEqualToString:@"link"]
            && [comps[3] isEqualToString:@"video"]) {
            return comps[4];
        }
        return nil;
    }
    // preview.redd.it/<id>.gif → id
    return [[videoURL lastPathComponent] stringByDeletingPathExtension];
}

// Find mediaMetadata for the hosting comment/post by walking up the
// supernode chain looking for a node with a `comment` or `link` ivar.
// Apollo's CommentCellNode holds the RDKComment; CommentsHeaderCellNode
// holds the RDKLink. Both models carry mediaMetadata for native uploads.
static NSDictionary *ApolloMediaMetadataForHost(ASDisplayNode *hostMarkdownNode) {
    for (ASDisplayNode *n = hostMarkdownNode; n; n = n.supernode) {
        for (const char *ivarName : (const char *[]){"comment", "link"}) {
            Ivar ivar = class_getInstanceVariable([n class], ivarName);
            if (!ivar) continue;
            id model = nil;
            @try { model = object_getIvar(n, ivar); } @catch (__unused NSException *e) {}
            if (!model || ![model respondsToSelector:@selector(mediaMetadata)]) continue;
            id md = [model performSelector:@selector(mediaMetadata)];
            if ([md isKindOfClass:[NSDictionary class]]) return md;
        }
    }
    return nil;
}

// Find the mediaMetadata entry for a given video URL. Tries direct id
// lookup first; falls back to scanning s.gif/s.mp4 URLs for a match
// (giphy entries have keys like "giphy|<id>" that don't match the
// preview.redd.it filename in the video URL).
static NSDictionary *ApolloMediaMetadataEntryForVideoURL(NSDictionary *mediaMetadata, NSURL *videoURL) {
    NSString *imageID = ApolloMediaMetadataIDFromVideoURL(videoURL);
    if (imageID.length > 0) {
        NSDictionary *entry = mediaMetadata[imageID];
        if ([entry isKindOfClass:[NSDictionary class]]) return entry;
    }
    NSString *absStr = videoURL.absoluteString;
    NSString *path = videoURL.path;
    for (NSString *key in mediaMetadata) {
        NSDictionary *entry = mediaMetadata[key];
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *s = entry[@"s"];
        if (![s isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *k in @[@"mp4", @"gif", @"u"]) {
            NSString *candidate = s[k];
            if (![candidate isKindOfClass:[NSString class]]) continue;
            NSString *decoded = [candidate stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            if ([decoded isEqualToString:absStr]) return entry;
            // Path-only match for sig/query mismatches across renderings.
            NSURL *cu = [NSURL URLWithString:decoded];
            if (path.length > 0 && [cu.path isEqualToString:path]) return entry;
        }
    }
    return nil;
}

// Pick the largest signed preview thumbnail from a mediaMetadata entry.
// Entries look like: { p: [{u, x, y}, ...sorted ascending], s: {u, gif, mp4}, ... }
// The last p[] entry is the highest-resolution still thumbnail (PNG/WEBP)
// with a valid signature. Returns nil for RedditVideo entries (no p[]).
static NSURL *ApolloPosterURLFromMediaMetadata(NSDictionary *mediaMetadata, NSURL *videoURL) {
    NSDictionary *entry = ApolloMediaMetadataEntryForVideoURL(mediaMetadata, videoURL);
    if (!entry) return nil;

    NSArray *previews = entry[@"p"];
    if ([previews isKindOfClass:[NSArray class]] && previews.count > 0) {
        id last = previews.lastObject;
        NSString *u = [last isKindOfClass:[NSDictionary class]] ? last[@"u"] : nil;
        if ([u isKindOfClass:[NSString class]] && u.length > 0) {
            NSString *decoded = [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            NSURL *out = [NSURL URLWithString:decoded];
            if (out) return out;
        }
    }
    // For giphy/animated entries with no p[], use s.gif directly — it's
    // a small signed animated GIF that renders inline as the thumbnail.
    NSDictionary *s = entry[@"s"];
    if ([s isKindOfClass:[NSDictionary class]]) {
        NSString *gif = s[@"gif"];
        if ([gif isKindOfClass:[NSString class]] && gif.length > 0) {
            NSString *decoded = [gif stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
            NSURL *out = [NSURL URLWithString:decoded];
            if (out) return out;
        }
    }
    return nil;
}

// Returns the DASH manifest URL for a RedditVideo mediaMetadata entry,
// or nil if the entry isn't a video (or has no dashUrl). Used by the
// poster-frame-extraction path below.
static NSURL *ApolloDashURLFromMediaMetadata(NSDictionary *mediaMetadata, NSURL *videoURL) {
    NSDictionary *entry = ApolloMediaMetadataEntryForVideoURL(mediaMetadata, videoURL);
    if (!entry) return nil;
    NSString *u = entry[@"dashUrl"];
    if (![u isKindOfClass:[NSString class]] || u.length == 0) return nil;
    NSString *decoded = [u stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    return [NSURL URLWithString:decoded];
}

// MARK: - DASH poster extraction (for Reddit hosted video permalinks)

// Cache: assetID → UIImage (success) | NSNull (failed, don't retry)
// Pending callbacks coalesce concurrent fetches for the same asset.
static NSMutableDictionary *sApolloDashPosterCache;
static NSMutableDictionary<NSString *, NSMutableArray *> *sApolloDashPosterPending;
static dispatch_queue_t sApolloDashPosterQueue;
static void ApolloDashPosterInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sApolloDashPosterCache = [NSMutableDictionary dictionary];
        sApolloDashPosterPending = [NSMutableDictionary dictionary];
        sApolloDashPosterQueue = dispatch_queue_create("ca.jeffrey.apollo.dashposter", DISPATCH_QUEUE_SERIAL);
    });
}

// Find the lowest-bitrate video MP4 Representation in a DASH MPD. Reddit
// orders Representations ascending by bitrate, so the first BaseURL after
// the video AdaptationSet header is the smallest.
static NSURL *ApolloLowestDashMP4URL(NSData *mpdData, NSURL *mpdURL) {
    if (mpdData.length == 0 || !mpdURL) return nil;
    NSString *xml = [[NSString alloc] initWithData:mpdData encoding:NSUTF8StringEncoding];
    if (xml.length == 0) return nil;

    NSRange searchRange = NSMakeRange(0, xml.length);
    NSRange videoSet = [xml rangeOfString:@"contentType=\"video\""];
    if (videoSet.location != NSNotFound) {
        searchRange = NSMakeRange(videoSet.location, xml.length - videoSet.location);
    }

    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"<BaseURL>([^<]+\\.mp4)</BaseURL>"
                             options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:searchRange];
    if (!m || m.numberOfRanges < 2) return nil;
    NSString *relative = [xml substringWithRange:[m rangeAtIndex:1]];
    return [NSURL URLWithString:relative relativeToURL:mpdURL].absoluteURL;
}

// Avg luminance check on a tiny downsample. Reddit videos often open
// with logo intros on black; we reject these as poster candidates.
static BOOL ApolloImageIsMostlyBlack(UIImage *img) {
    if (!img) return YES;
    size_t w = 32, h = 32;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    uint8_t *buf = (uint8_t *)calloc(w * h * 4, 1);
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img.CGImage);
    uint64_t sum = 0;
    for (size_t i = 0; i < w * h; i++) {
        sum += (buf[i*4] * 299 + buf[i*4+1] * 587 + buf[i*4+2] * 114) / 1000;
    }
    free(buf);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return ((double)sum / (double)(w * h)) < 12.0; // ~5% luma
}

// Download the DASH MPD, find the smallest video MP4, decode multiple
// candidate frames and pick the first non-black one. Reddit videos often
// fade in from a logo/black intro, so frame at t=0 is usually black.
// Calls back on main queue with the UIImage (or nil on failure).
// Coalesces concurrent calls for the same assetID.
static void ApolloFetchDashPoster(NSString *assetID, NSURL *dashURL,
                                   void (^completion)(UIImage *poster)) {
    if (!assetID.length || !dashURL || !completion) {
        if (completion) completion(nil);
        return;
    }
    ApolloDashPosterInit();
    void (^cb)(UIImage *) = [completion copy];

    dispatch_async(sApolloDashPosterQueue, ^{
        id cached = sApolloDashPosterCache[assetID];
        if (cached) {
            UIImage *out = (cached == [NSNull null]) ? nil : (UIImage *)cached;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(out); });
            return;
        }
        NSMutableArray *pending = sApolloDashPosterPending[assetID];
        if (pending) { [pending addObject:cb]; return; }
        sApolloDashPosterPending[assetID] = [NSMutableArray arrayWithObject:cb];

        void (^deliver)(UIImage *) = ^(UIImage *result) {
            dispatch_async(sApolloDashPosterQueue, ^{
                sApolloDashPosterCache[assetID] = result ?: (id)[NSNull null];
                NSArray *cbs = [sApolloDashPosterPending[assetID] copy];
                [sApolloDashPosterPending removeObjectForKey:assetID];
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (void (^c)(UIImage *) in cbs) c(result);
                });
            });
        };

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:dashURL
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:8.0];
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (error || status < 200 || status >= 300 || data.length == 0) {
                ApolloLog(@"[InlineImages] DASH MPD fetch FAIL asset=%@ status=%ld err=%@",
                          assetID, (long)status, error.localizedDescription ?: @"nil");
                deliver(nil);
                return;
            }
            NSURL *mp4URL = ApolloLowestDashMP4URL(data, dashURL);
            if (!mp4URL) {
                ApolloLog(@"[InlineImages] DASH parse FAIL asset=%@", assetID);
                deliver(nil);
                return;
            }
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mp4URL options:nil];
            [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
                if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
                    ApolloLog(@"[InlineImages] DASH asset load FAIL asset=%@", assetID);
                    deliver(nil);
                    return;
                }
                AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
                gen.appliesPreferredTrackTransform = YES;
                gen.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(0.5, 600);
                gen.requestedTimeToleranceAfter = CMTimeMakeWithSeconds(0.5, 600);

                Float64 durSec = CMTIME_IS_NUMERIC(asset.duration)
                    ? CMTimeGetSeconds(asset.duration) : 0;
                NSMutableArray<NSValue *> *times = [NSMutableArray array];
                for (NSNumber *t in @[@3.0, @5.0, @1.5, @0.5, @0.0]) {
                    Float64 v = t.doubleValue;
                    if (durSec <= 0 || v < durSec) {
                        [times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(v, 600)]];
                    }
                }
                if (times.count == 0) [times addObject:[NSValue valueWithCMTime:kCMTimeZero]];

                __block BOOL delivered = NO;
                __block UIImage *darkFallback = nil;
                __block NSInteger remaining = (NSInteger)times.count;
                __block AVAssetImageGenerator *retainedGen = gen;

                [gen generateCGImagesAsynchronouslyForTimes:times
                    completionHandler:^(CMTime requested, CGImageRef cgImage,
                                        CMTime actualT, AVAssetImageGeneratorResult res,
                                        NSError *genError) {
                    @synchronized (retainedGen ?: (id)@"x") {
                        if (delivered) return;
                        remaining--;
                        if (res == AVAssetImageGeneratorSucceeded && cgImage) {
                            UIImage *ui = [UIImage imageWithCGImage:cgImage];
                            BOOL dark = ApolloImageIsMostlyBlack(ui);
                            if (!dark) {
                                delivered = YES;
                                retainedGen = nil;
                                deliver(ui);
                                return;
                            }
                            if (!darkFallback) darkFallback = ui;
                        }
                        if (remaining <= 0 && !delivered) {
                            delivered = YES;
                            retainedGen = nil;
                            deliver(darkFallback);
                        }
                    }
                }];
            }];
        }];
        [task resume];
    });
}

static NSURL *ApolloNormalizeInlineImageURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return url;

    // Imgur share URL → i.imgur.com/<id>.jpeg. The CDN serves the
    // underlying media (incl. animated GIFs) regardless of requested ext.
    if (ApolloIsImgurShareURL(url)) {
        NSString *imgurID = [url.path substringFromIndex:1];
        NSURL *canonical = [NSURL URLWithString:
            [NSString stringWithFormat:@"https://i.imgur.com/%@.jpeg", imgurID]];
        if (canonical) return canonical;
    }

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
    // Prefer the original album/gallery/share URL when present so taps
    // route to Apollo's full multi-image album viewer (for albums) or
    // the user-posted URL (for normalized share links); otherwise use
    // the single-image loaded URL.
    NSURL *url = objc_getAssociatedObject(imageNode, &kApolloOriginalImageURLKey)
              ?: objc_getAssociatedObject(imageNode, &kApolloImageURLKey);
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
    NSURL *url = objc_getAssociatedObject(v, &kApolloOriginalImageURLKey)
              ?: objc_getAssociatedObject(v, &kApolloImageURLKey);
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
static void ApolloInstallStackedCardForImageNode(ASNetworkImageNode *imageNode);

// Mirror the imageNode's tap/long-press URL associations onto its
// backing view once it's loaded — UIContextMenuInteraction reads from
// the view, not the node.
static void ApolloMirrorImageURLsToLoadedView(ASNetworkImageNode *imageNode) {
    if (![imageNode respondsToSelector:@selector(isNodeLoaded)] || ![imageNode isNodeLoaded]) return;
    UIView *view = [imageNode view];
    if (!view) return;
    NSURL *tapURL = objc_getAssociatedObject(imageNode, &kApolloImageURLKey) ?: imageNode.URL;
    NSURL *originalURL = objc_getAssociatedObject(imageNode, &kApolloOriginalImageURLKey);
    if (tapURL) objc_setAssociatedObject(view, &kApolloImageURLKey, tapURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (originalURL) objc_setAssociatedObject(view, &kApolloOriginalImageURLKey, originalURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Record the URL the user actually posted (different from the loaded
// CDN URL after normalization, or different from the resolved image
// URL after Imgur album lookup). Used for tap routing + Copy Link.
static void ApolloSetOriginalImageURL(ASNetworkImageNode *imageNode, NSURL *originalURL) {
    if (![originalURL isKindOfClass:[NSURL class]]) return;
    objc_setAssociatedObject(imageNode, &kApolloOriginalImageURLKey, originalURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloMirrorImageURLsToLoadedView(imageNode);
}

// Apply an Imgur API resolution result to an imageNode. Sets the load
// URL, captures aspect ratio if available, and triggers cell relayout.
// Preserves kApolloOriginalImageURLKey (album URL) so tap still routes
// to Apollo's multi-image album viewer instead of opening just the
// resolved cover image.
static void ApolloApplyResolvedImgurImage(ASNetworkImageNode *imageNode, NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) return;
    NSURL *imageURL = [result[@"url"] isKindOfClass:[NSURL class]] ? result[@"url"] : nil;
    if (![imageURL isKindOfClass:[NSURL class]]) return;

    imageNode.URL = imageURL;
    // Set kApolloImageURLKey only if there's no album/gallery original
    // URL — otherwise tap should route to the album URL.
    if (!objc_getAssociatedObject(imageNode, &kApolloOriginalImageURLKey)) {
        objc_setAssociatedObject(imageNode, &kApolloImageURLKey, imageURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloMirrorImageURLsToLoadedView(imageNode);

    NSNumber *width = [result[@"width"] respondsToSelector:@selector(doubleValue)] ? result[@"width"] : nil;
    NSNumber *height = [result[@"height"] respondsToSelector:@selector(doubleValue)] ? result[@"height"] : nil;
    if (width.doubleValue > 0 && height.doubleValue > 0) {
        CGFloat ratio = height.doubleValue / width.doubleValue;
        objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(1.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Walk up to the enclosing CellNode and trigger relayout. The host
    // MarkdownNode may not be attached to its supernodes yet (Profile
    // pre-builds cells off-screen before mounting), so we also defer a
    // relayout to onDidLoad which fires when the node is added to its
    // parent view hierarchy.
    ASDisplayNode *host = objc_getAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey);
    void (^doRelayout)(void) = ^{
        ASDisplayNode *n = host;
        ASDisplayNode *cellNode = nil;
        while (n) {
            NSString *cls = NSStringFromClass([n class]);
            if ([n respondsToSelector:@selector(invalidateCalculatedLayout)]) {
                [n invalidateCalculatedLayout];
            }
            if ([n respondsToSelector:@selector(setNeedsLayout)]) {
                [n setNeedsLayout];
            }
            if ([cls containsString:@"CellNode"]) cellNode = n;
            n = n.supernode;
        }
        SEL relayoutSel = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
        id target = cellNode ?: host;
        if ([target respondsToSelector:relayoutSel]) {
            ((void (*)(id, SEL))objc_msgSend)(target, relayoutSel);
        }
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        doRelayout();
        BOOL hostMounted = [host respondsToSelector:@selector(isNodeLoaded)]
                          && [host isNodeLoaded] && host.supernode != nil;
        if (!hostMounted && [host respondsToSelector:@selector(onDidLoad:)]) {
            [host onDidLoad:^(__kindof ASDisplayNode *node) {
                dispatch_async(dispatch_get_main_queue(), doRelayout);
            }];
        }
    });

    // Multi-image albums get a "stacked card" peeking out bottom-right to
    // signal "more than one image". Installed on imageNode's view's
    // superview after relayout. Defer to onDidLoad if the imageNode
    // isn't view-loaded yet.
    NSNumber *count = [result[@"count"] respondsToSelector:@selector(integerValue)] ? result[@"count"] : nil;
    if (count.integerValue > 1) {
        __weak ASNetworkImageNode *weakImage = imageNode;
        void (^installCard)(void) = ^{
            ASNetworkImageNode *strong = weakImage;
            if (strong) ApolloInstallStackedCardForImageNode(strong);
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            ASNetworkImageNode *strong = weakImage;
            if (!strong) return;
            if ([strong respondsToSelector:@selector(isNodeLoaded)] && [strong isNodeLoaded]) {
                installCard();
            } else if ([strong respondsToSelector:@selector(onDidLoad:)]) {
                [strong onDidLoad:^(__kindof ASDisplayNode *node) {
                    dispatch_async(dispatch_get_main_queue(), installCard);
                }];
            }
        });
    }
}

// Standalone play-circle glyph (transparent background) drawn into a
// UIImageView placed over the imageNode so the play button stays visible
// no matter what the network image node renders underneath.
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


// A UIView that centers its single subview in layoutSubviews, AND on
// every observed bounds change of its host layer. Texture sets layer
// frames directly without going through UIView's setBounds:, so neither
// autoresizingMask nor layoutSubviews fire on resize. KVO on the host
// layer's bounds is the only reliable signal.
@interface ApolloPlayOverlayContainer : UIView
@property (nonatomic, weak) CALayer *observedLayer;
@end
@implementation ApolloPlayOverlayContainer
- (void)layoutSubviews {
    [super layoutSubviews];
    [self recenter];
}
- (void)recenter {
    for (UIView *sub in self.subviews) {
        CGSize s = sub.bounds.size;
        sub.center = CGPointMake(self.bounds.size.width * 0.5,
                                  self.bounds.size.height * 0.5);
        sub.bounds = (CGRect){CGPointZero, s};
    }
}
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (object == self.observedLayer) {
        CGRect b = self.observedLayer.bounds;
        self.frame = b;
        [self recenter];
    }
}
- (void)dealloc {
    [_observedLayer removeObserver:self forKeyPath:@"bounds"];
}
@end

// Idempotently add the play-circle overlay centered on the imageNode.
// Uses KVO on the imageNode's layer bounds since Texture mutates
// layer.frame directly (UIView setBounds: / layoutSubviews don't fire).
static void ApolloInstallPlayOverlayOnView(UIView *v, ASDisplayNode *node) {
    if (!v || !node) return;
    if (objc_getAssociatedObject(node, &kApolloPlayOverlayViewKey)) return;

    ApolloPlayOverlayContainer *container = [[ApolloPlayOverlayContainer alloc] initWithFrame:v.bounds];
    container.userInteractionEnabled = NO;
    container.backgroundColor = [UIColor clearColor];

    UIImageView *icon = [[UIImageView alloc] initWithImage:ApolloPlayOverlayImage()];
    icon.userInteractionEnabled = NO;
    icon.frame = CGRectMake(0, 0, 72, 72);
    [container addSubview:icon];

    [v addSubview:container];
    [v bringSubviewToFront:container];

    // Observe the host layer's bounds — fires whenever Texture re-lays out
    // the node, including the initial size assignment.
    container.observedLayer = v.layer;
    [v.layer addObserver:container forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:NULL];
    [container recenter];

    objc_setAssociatedObject(node, &kApolloPlayOverlayViewKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// "Stacked card" view shown behind a multi-image album thumbnail. Peeks
// out from the top-right of the imageNode (same size, offset +8pt right
// / -8pt up), in systemGray3Color for contrast against any cell
// background in both light and dark themes. Gives a visual cue that the
// album has more than one image without loading any additional images.
//
// Sibling to imageNode.view in the parent (MarkdownNode's view) rather
// than a subview — imageNode.clipsToBounds=YES would clip the peek.
// KVO on imageNode.layer.bounds/position keeps the card frame in sync
// across Texture layout passes (which mutate layer.frame directly).
static const CGFloat kApolloStackedCardOffset = 8.0;

@interface ApolloStackedCardSyncer : NSObject
@property (nonatomic, weak) UIView *card;
@property (nonatomic, weak) UIView *anchor;
@end
@implementation ApolloStackedCardSyncer
- (void)syncFrame {
    UIView *anchor = self.anchor;
    UIView *card = self.card;
    if (!anchor || !card) return;
    CGRect a = anchor.frame;
    if (CGRectIsEmpty(a)) return;
    card.frame = CGRectMake(a.origin.x + kApolloStackedCardOffset,
                             a.origin.y - kApolloStackedCardOffset,
                             a.size.width,
                             a.size.height);
    // Texture may re-add the imageNode's view to the parent during
    // layout passes, which can flip z-order. Re-assert "card below
    // image" on every sync.
    UIView *parent = anchor.superview;
    if (parent == card.superview) {
        [parent insertSubview:card belowSubview:anchor];
    }
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    [self syncFrame];
}
- (void)dealloc {
    UIView *anchor = _anchor;
    if (anchor) {
        @try { [anchor.layer removeObserver:self forKeyPath:@"bounds"]; } @catch (__unused NSException *e) {}
        @try { [anchor.layer removeObserver:self forKeyPath:@"position"]; } @catch (__unused NSException *e) {}
    }
}
@end

static void ApolloInstallStackedCardForImageNode(ASNetworkImageNode *imageNode) {
    if (objc_getAssociatedObject(imageNode, &kApolloStackedCardSyncerKey)) return;
    if (![imageNode respondsToSelector:@selector(isNodeLoaded)] || ![imageNode isNodeLoaded]) return;
    UIView *imgView = [imageNode view];
    UIView *parent = imgView.superview;
    if (!imgView || !parent) return;

    UIView *card = [[UIView alloc] init];
    card.userInteractionEnabled = NO;
    card.backgroundColor = [UIColor systemGray3Color];
    card.layer.cornerRadius = 8.0;
    [parent insertSubview:card belowSubview:imgView];

    ApolloStackedCardSyncer *syncer = [ApolloStackedCardSyncer new];
    syncer.card = card;
    syncer.anchor = imgView;
    [syncer syncFrame];
    [imgView.layer addObserver:syncer forKeyPath:@"bounds" options:0 context:NULL];
    [imgView.layer addObserver:syncer forKeyPath:@"position" options:0 context:NULL];
    objc_setAssociatedObject(imageNode, &kApolloStackedCardSyncerKey, syncer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Builds a video thumbnail with a 16:9 placeholder ratio so it's included
// in layout immediately, then resolves the real poster URL + ratio
// asynchronously in didLoad (after Texture connects the supernode chain).
static ASNetworkImageNode *ApolloMakeInlineVideoThumbnailNode(NSURL *videoURL,
                                                               ASDisplayNode *hostMarkdownNode) {
    Class imageNodeClass = ApolloASNetworkImageNodeClass();
    if (!imageNodeClass) return nil;

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    imageNode.shouldRenderProgressImages = YES;
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.placeholderColor = [UIColor tertiarySystemFillColor];
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderFadeDuration = 0.2;
    imageNode.cornerRadius = 8.0;
    imageNode.clipsToBounds = YES;
    imageNode.borderWidth = 0.0;
    imageNode.delegate = [ApolloInlineImageDispatcher shared];

    [imageNode addTarget:[ApolloInlineImageDispatcher shared]
                  action:@selector(imageNodeTapped:)
        forControlEvents:ApolloASControlNodeEventTouchUpInside];

    [[imageNode style] setValue:@(ApolloASStackLayoutAlignSelfStretch) forKey:@"alignSelf"];

    // Tap routes to the MP4 URL (MediaViewer plays video). Default 16:9
    // ratio so the layout reserves space immediately; DIDLOAD refines it
    // once the real poster loads.
    objc_setAssociatedObject(imageNode, &kApolloImageURLKey, videoURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(9.0 / 16.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak ASNetworkImageNode *weakImage = imageNode;
    [imageNode onDidLoad:^(__kindof ASDisplayNode *node) {
        ASNetworkImageNode *img = weakImage;
        if (!img) return;
        UIView *v = [img view];

        // Resolve the poster now that the supernode chain is connected
        // (MarkdownNode → ... → CommentCellNode/CommentsHeaderCellNode).
        // Try the cheap signed-thumbnail URL first; if not available
        // (RedditVideo entries have no p[]), fall back to DASH manifest
        // + AVAssetImageGenerator to extract a frame at t=0.
        if (!img.URL && !img.image) {
            ASDisplayNode *host = objc_getAssociatedObject(img, &kApolloHostMarkdownNodeKey);
            NSDictionary *mm = ApolloMediaMetadataForHost(host);
            NSURL *posterURL = mm ? ApolloPosterURLFromMediaMetadata(mm, videoURL) : nil;
            if (posterURL) {
                img.URL = posterURL;
            } else {
                NSURL *dashURL = mm ? ApolloDashURLFromMediaMetadata(mm, videoURL) : nil;
                NSString *assetID = ApolloMediaMetadataIDFromVideoURL(videoURL);
                if (dashURL && assetID.length) {
                    ApolloFetchDashPoster(assetID, dashURL, ^(UIImage *poster) {
                        ASNetworkImageNode *strong = weakImage;
                        if (!strong) return;
                        if (poster) {
                            strong.image = poster;
                            if (poster.size.width > 0 && poster.size.height > 0) {
                                [[ApolloInlineImageDispatcher shared]
                                    updateAspectRatioForImageNode:strong imageSize:poster.size];
                            }
                        } else if (!strong.image && !strong.URL) {
                            strong.backgroundColor = [UIColor tertiarySystemFillColor];
                        }
                    });
                } else {
                    ApolloLog(@"[InlineImages] video poster NOT FOUND node=%p video=%@", img, videoURL);
                    img.backgroundColor = [UIColor tertiarySystemFillColor];
                }
            }
        }

        if (v) ApolloInstallPlayOverlayOnView(v, img);
        if (v && ![objc_getAssociatedObject(img, &kApolloLongPressInstalledKey) boolValue]) {
            NSURL *u = objc_getAssociatedObject(img, &kApolloImageURLKey);
            objc_setAssociatedObject(v, &kApolloImageURLKey, u, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIContextMenuInteraction *menu = [[UIContextMenuInteraction alloc]
                initWithDelegate:[ApolloInlineImageDispatcher shared]];
            [v addInteraction:menu];
            objc_setAssociatedObject(img, &kApolloLongPressInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }];

    return imageNode;
}

static ASNetworkImageNode *ApolloMakeInlineImageNode(NSURL *normalizedURL,
                                                      ASDisplayNode *hostMarkdownNode) {
    Class imageNodeClass = ApolloASNetworkImageNodeClass();
    if (!imageNodeClass) return nil;

    // Imgur album/gallery URLs need an API roundtrip to resolve to a
    // renderable image. Defer setting imageNode.URL until resolution
    // completes — otherwise PINRemoteImage tries to fetch the album
    // page HTML as an image.
    BOOL deferredImgur = ApolloIsImgurAlbumOrGalleryURL(normalizedURL);

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    if (!deferredImgur) {
        imageNode.URL = normalizedURL;
    }
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

    // Stable cache key — the per-MarkdownNode reuse cache and the GC
    // both key on this. For Imgur albums the loaded URL changes when
    // resolution completes, so we can't use imageNode.URL.
    objc_setAssociatedObject(imageNode, &kApolloImageCacheKey, normalizedURL.absoluteString, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!deferredImgur) {
        objc_setAssociatedObject(imageNode, &kApolloImageURLKey, normalizedURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        // For Imgur albums/galleries, record the album URL as "original"
        // so taps route to Apollo's multi-image viewer even after we
        // resolve and load a single cover image into imageNode.URL.
        objc_setAssociatedObject(imageNode, &kApolloOriginalImageURLKey, normalizedURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(imageNode, &kApolloHostMarkdownNodeKey, hostMarkdownNode, OBJC_ASSOCIATION_ASSIGN);
    if (ratio > 0) {
        objc_setAssociatedObject(imageNode, &kApolloAspectRatioKey, @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Kick off Imgur album/gallery resolution. Result is applied
    // asynchronously via ApolloApplyResolvedImgurImage, which sets the
    // load URL, captures aspect ratio, and triggers cell relayout.
    __weak ASNetworkImageNode *weakImage = imageNode;
    if (deferredImgur) {
        ApolloResolveImgurURL(normalizedURL, ^(NSDictionary *result) {
            ASNetworkImageNode *strong = weakImage;
            if (!strong || !result) return;
            ApolloApplyResolvedImgurImage(strong, result);
        });
    }

    // Long-press: install a UIContextMenuInteraction once the imageNode's
    // backing view exists. Native iOS routes context menus to the deepest
    // interaction-bearing view, so this wins over Apollo's cell-level
    // upvote/save/reply menu when the touch is inside the image bounds.
    [imageNode onDidLoad:^(__kindof ASDisplayNode *node) {
        ASNetworkImageNode *img = weakImage;
        if (!img) return;
        if ([objc_getAssociatedObject(img, &kApolloLongPressInstalledKey) boolValue]) return;
        UIView *v = [img view];
        if (!v) return;
        ApolloMirrorImageURLsToLoadedView(img);
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
    // Pre-normalize URLs, used for the bare-URL text check — the
    // displayed text matches the original form, not the normalized one.
    NSMutableArray<NSURL *> *originalURLs = [NSMutableArray array];
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
            [originalURLs addObject:url];
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
            if (img) {
                // Route tap/long-press to the original posted URL when
                // it differs from the loaded URL — Copy Link returns
                // what the user shared, and album taps route to the
                // album viewer instead of just the cover image.
                NSURL *original = originalURLs[leafIndex];
                if (original && ![original.absoluteString isEqualToString:urls[leafIndex].absoluteString]) {
                    ApolloSetOriginalImageURL(img, original);
                }
                [leaves addObject:img];
            }
        }

        NSMutableAttributedString *remaining = [[attr attributedSubstringFromRange:pRange] mutableCopy];
        // Reverse-order deletion of bare-URL ranges (paragraph-relative).
        for (NSInteger n = (NSInteger)pIdx.count - 1; n >= 0; n--) {
            NSUInteger ri = [pIdx[n] unsignedIntegerValue];
            NSRange r = [ranges[ri] rangeValue];
            if (ApolloRangeTextLooksLikeBareURL(attr, r, originalURLs[ri])) {
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
        // If this is a cached album/gallery node whose resolution never
        // completed (e.g. previous host was deallocated mid-fetch), kick
        // off another resolve attempt — the resolver dedupes on cacheKey.
        if (ApolloIsImgurAlbumOrGalleryURL(normalizedURL) && !objc_getAssociatedObject(existing, &kApolloImageURLKey)) {
            __weak ASNetworkImageNode *weakImage = existing;
            ApolloResolveImgurURL(normalizedURL, ^(NSDictionary *result) {
                ASNetworkImageNode *strong = weakImage;
                if (!strong || !result) return;
                ApolloApplyResolvedImgurImage(strong, result);
            });
        }
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
                        // Use kApolloImageCacheKey (matches cache key) —
                        // imageNode.URL changes after Imgur album resolution
                        // and kApolloImageURLKey can be the original share
                        // URL for tap routing; either would mis-GC here.
                        NSString *abs = objc_getAssociatedObject(leaf, &kApolloImageCacheKey)
                                     ?: [((ASNetworkImageNode *)leaf).URL absoluteString];
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

// Hides Apollo's link-card preview when the URL has been inlined as an
// image elsewhere in the same cell. Returns a zero-size empty spec so
// the LinkButtonNode reserves no visible space. For link posts (no
// selftext / no MarkdownNode body), there is no inline replacement, so
// the preview is preserved.

%hook _TtC6Apollo14LinkButtonNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    if (!sEnableInlineImages) return %orig;

    NSString *urlString = ApolloGetLinkButtonNodeURLString(self);
    if (!urlString) return %orig;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!ApolloIsInlineRenderableImageURL(url) && !ApolloIsInlineRenderableVideoURL(url)) return %orig;

    // For Imgur albums/galleries the inline rendering depends on an
    // async API resolution. Until that succeeds, keep Apollo's native
    // LinkButtonNode preview so private/deleted/bad albums don't turn
    // into a blank gap.
    if (ApolloIsImgurAlbumOrGalleryURL(url) && !ApolloCachedImgurResolution(url)) return %orig;

    // Only hide if there's a MarkdownNode body that would carry the
    // inline replacement. Walk supernodes for an RDKLink with selftext,
    // or an RDKComment (comments always have a body).
    BOOL haveInlineReplacement = NO;
    for (ASDisplayNode *n = (ASDisplayNode *)self; n; n = n.supernode) {
        for (const char *ivarName : (const char *[]){"link", "comment"}) {
            Ivar ivar = class_getInstanceVariable([n class], ivarName);
            if (!ivar) continue;
            id model = nil;
            @try { model = object_getIvar(n, ivar); } @catch (__unused NSException *e) {}
            if (!model) continue;
            if (strcmp(ivarName, "comment") == 0) { haveInlineReplacement = YES; break; }
            if ([model respondsToSelector:@selector(isSelfPostWithSelfText)]
                && ((BOOL (*)(id, SEL))objc_msgSend)(model, @selector(isSelfPostWithSelfText))) {
                haveInlineReplacement = YES; break;
            }
        }
        if (haveInlineReplacement) break;
    }
    if (!haveInlineReplacement) return %orig;

    Class layoutSpecCls = NSClassFromString(@"ASLayoutSpec");
    if (!layoutSpecCls) return %orig;
    ASLayoutSpec *empty = [[layoutSpecCls alloc] init];
    [[empty style] setValue:[NSValue valueWithCGSize:CGSizeZero] forKey:@"preferredSize"];
    return empty;
}

%end
