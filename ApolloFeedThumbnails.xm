#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

// Minimal AsyncDisplayKit forward decl — same shape as ApolloTagFilters.xm uses.
@interface ApolloFeedThumbDisplayNode : UIResponder
@property (nonatomic, readonly, nullable) UIView *view;
@property (nonatomic, readonly) BOOL isNodeLoaded;
@property (nonatomic, getter=isHidden) BOOL hidden;
- (void)setNeedsLayout;
@end

static NSString *ApolloFeedThumbDecodeEntities(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) return string;
    NSString *decoded = [string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#x27;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    return decoded;
}

static NSURL *ApolloFeedThumbURLFromString(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) return nil;
    NSString *decoded = ApolloFeedThumbDecodeEntities(string);
    NSURL *url = [NSURL URLWithString:decoded];
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
    return url;
}

static BOOL ApolloFeedThumbURLIsUsable(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    NSString *absolute = url.absoluteString.lowercaseString;
    if (absolute.length == 0) return NO;
    static NSSet<NSString *> *placeholders;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        placeholders = [NSSet setWithArray:@[@"self", @"default", @"nsfw", @"spoiler", @"image", @""]];
    });
    return ![placeholders containsObject:absolute];
}

static NSURL *ApolloFeedThumbURLFromPreviewItem(id item) {
    if (!item) return nil;

    @try {
        if ([item respondsToSelector:@selector(URL)]) {
            NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(item, @selector(URL));
            if (ApolloFeedThumbURLIsUsable(url)) return url;
        }
    } @catch (__unused NSException *exception) {}

    if ([item isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)item;
        for (NSString *key in @[@"url", @"u"]) {
            NSURL *url = ApolloFeedThumbURLFromString(dict[key]);
            if (url) return url;
        }
    }

    return nil;
}

static NSURL *ApolloFeedThumbURLFromPreviewMedia(RDKLinkPreviewMedia *previewMedia, BOOL preferHighQuality) {
    Class previewMediaClass = objc_getClass("RDKLinkPreviewMedia");
    if (!previewMediaClass || ![(id)previewMedia isKindOfClass:previewMediaClass]) return nil;

    NSURL *sourceURL = nil;
    @try { sourceURL = previewMedia.sourceImage.URL; } @catch (__unused NSException *exception) {}
    if (ApolloFeedThumbURLIsUsable(sourceURL)) return sourceURL;

    NSArray *images = nil;
    @try { images = previewMedia.images; } @catch (__unused NSException *exception) {}
    if (![images isKindOfClass:[NSArray class]]) return nil;

    NSURL *fallbackURL = nil;
    CGFloat fallbackMetric = preferHighQuality ? 0 : CGFLOAT_MAX;
    for (id item in images) {
        NSURL *url = ApolloFeedThumbURLFromPreviewItem(item);
        if (!url) continue;
        if (!fallbackURL) fallbackURL = url;

        double width = 0;
        @try {
            if ([item respondsToSelector:@selector(width)]) {
                width = ((double (*)(id, SEL))objc_msgSend)(item, @selector(width));
            } else if ([item isKindOfClass:[NSDictionary class]] && [item[@"width"] respondsToSelector:@selector(doubleValue)]) {
                width = [item[@"width"] doubleValue];
            }
        } @catch (__unused NSException *exception) {}

        if (width > 0) {
            CGFloat metric = preferHighQuality ? width : fabs(width - 320.0);
            if ((preferHighQuality && metric > fallbackMetric) || (!preferHighQuality && metric < fallbackMetric)) {
                fallbackMetric = metric;
                fallbackURL = url;
            }
        }
    }

    return fallbackURL;
}

static NSURL *ApolloFeedThumbURLFromMediaMetadataEntry(NSDictionary *entry, BOOL preferHighQuality) {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSString *status = entry[@"status"];
    if ([status isKindOfClass:[NSString class]] && ![status isEqualToString:@"valid"]) return nil;

    NSString *kind = entry[@"e"];
    if ([kind isKindOfClass:[NSString class]] && kind.length > 0) {
        NSString *lowerKind = kind.lowercaseString;
        if (![lowerKind containsString:@"image"]) return nil;
    }

    NSDictionary *source = entry[@"s"];
    if (preferHighQuality && [source isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"u", @"gif"]) {
            NSURL *url = ApolloFeedThumbURLFromString(source[key]);
            if (url) return url;
        }
    }

    NSArray *previews = entry[@"p"];
    NSURL *fallbackURL = nil;
    CGFloat fallbackMetric = preferHighQuality ? 0 : CGFLOAT_MAX;
    if ([previews isKindOfClass:[NSArray class]]) {
        for (id preview in previews) {
            if (![preview isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *previewDict = (NSDictionary *)preview;
            NSURL *url = ApolloFeedThumbURLFromString(previewDict[@"u"]);
            if (!url) continue;
            if (!fallbackURL) fallbackURL = url;

            NSNumber *widthNumber = [previewDict[@"x"] respondsToSelector:@selector(doubleValue)] ? previewDict[@"x"] : nil;
            CGFloat metric = widthNumber ? (preferHighQuality ? widthNumber.doubleValue : fabs(widthNumber.doubleValue - 320.0)) : (preferHighQuality ? 0 : CGFLOAT_MAX);
            if ((preferHighQuality && metric > fallbackMetric) || (!preferHighQuality && metric < fallbackMetric)) {
                fallbackMetric = metric;
                fallbackURL = url;
            }
        }
    }
    if (fallbackURL) return fallbackURL;

    if ([source isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"u", @"gif"]) {
            NSURL *url = ApolloFeedThumbURLFromString(source[key]);
            if (url) return url;
        }
    }

    return nil;
}

static NSURL *ApolloFeedThumbURLFromMediaMetadata(RDKLink *link, BOOL preferHighQuality) {
    NSDictionary *metadata = nil;
    @try { metadata = link.mediaMetadata; } @catch (__unused NSException *exception) {}
    if (![metadata isKindOfClass:[NSDictionary class]] || metadata.count == 0) return nil;

    for (id key in metadata) {
        NSURL *url = ApolloFeedThumbURLFromMediaMetadataEntry(metadata[key], preferHighQuality);
        if (url) return url;
    }

    return nil;
}

static BOOL ApolloFeedThumbIsDirectImageURL(NSURL *url) {
    if (!ApolloFeedThumbURLIsUsable(url)) return NO;
    NSString *host = url.host.lowercaseString;
    NSString *extension = url.pathExtension.lowercaseString;
    static NSSet<NSString *> *imageExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];
    });

    if ([host isEqualToString:@"i.redd.it"] || [host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"i.imgur.com"]) {
        return [imageExtensions containsObject:extension];
    }
    return NO;
}

static NSString *ApolloFeedThumbYouTubeID(NSURL *url) {
    if (!ApolloFeedThumbURLIsUsable(url)) return nil;
    NSString *host = url.host.lowercaseString;
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];

    NSString *candidate = nil;
    if ([host isEqualToString:@"youtu.be"] || [host hasSuffix:@".youtu.be"]) {
        for (NSString *part in parts) {
            if (part.length > 0) {
                candidate = part;
                break;
            }
        }
    } else if ([host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"] || [host hasSuffix:@".youtube-nocookie.com"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"v"] && item.value.length > 0) {
                candidate = item.value;
                break;
            }
        }
        if (!candidate) {
            for (NSUInteger index = 0; index + 1 < parts.count; index++) {
                NSString *part = parts[index];
                if ([part isEqualToString:@"shorts"] || [part isEqualToString:@"embed"] || [part isEqualToString:@"v"]) {
                    candidate = parts[index + 1];
                    break;
                }
            }
        }
    }

    if (![candidate isKindOfClass:[NSString class]] || candidate.length < 6 || candidate.length > 32) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    return ([candidate rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound) ? candidate : nil;
}

static NSURL *ApolloFeedThumbURLFromDirectLink(RDKLink *link) {
    NSURL *linkURL = nil;
    @try { linkURL = link.URL; } @catch (__unused NSException *exception) {}
    if (ApolloFeedThumbIsDirectImageURL(linkURL)) return linkURL;

    NSString *youtubeID = ApolloFeedThumbYouTubeID(linkURL);
    if (youtubeID.length > 0) {
        return [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", youtubeID]];
    }

    return nil;
}

static NSString *ApolloFeedThumbLogKeyForLink(RDKLink *link, NSString *source) {
    NSString *fullName = nil;
    @try { fullName = link.fullName; } @catch (__unused NSException *exception) {}
    if (fullName.length == 0) fullName = [NSString stringWithFormat:@"%p", link];
    return [NSString stringWithFormat:@"%@|%@", fullName, source ?: @"none"];
}

static NSMutableSet<NSString *> *ApolloFeedThumbLoggedKeys(void) {
    static NSMutableSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSMutableSet set];
    });
    return keys;
}

static void ApolloFeedThumbLogOnce(RDKLink *link, NSString *source, NSURL *url) {
    NSString *key = ApolloFeedThumbLogKeyForLink(link, source);
    @synchronized (ApolloFeedThumbLoggedKeys()) {
        if ([ApolloFeedThumbLoggedKeys() containsObject:key]) return;
        [ApolloFeedThumbLoggedKeys() addObject:key];
    }

    NSString *subreddit = nil;
    NSString *title = nil;
    @try { subreddit = link.subreddit; } @catch (__unused NSException *exception) {}
    @try { title = link.title; } @catch (__unused NSException *exception) {}
    ApolloLog(@"[FeedThumbs] %@ fallback for r/%@ title='%@' url=%@",
              source ?: @"unknown", subreddit ?: @"?", title ?: @"?", url.absoluteString ?: @"nil");
}

static NSURL *ApolloFeedThumbCachedVRedditPreview(RDKLink *link);
static void ApolloFeedThumbKickVRedditFetch(RDKLink *link);

static NSURL *ApolloFeedThumbFallbackURLForLink(RDKLink *link, BOOL preferHighQuality, NSString **outSource) {
    Class linkClass = objc_getClass("RDKLink");
    if (!linkClass || ![(id)link isKindOfClass:linkClass]) return nil;

    // Note: NSFW/spoiler are NOT skipped here. The cell-level apply layer
    // renders a gaussian-blurred version of the loaded image for these posts,
    // mimicking Apollo's native spoiler/NSFW thumbnail blur, which Apollo
    // can't apply itself when Reddit returns an empty/placeholder thumbnail.

    RDKLinkPreviewMedia *previewMedia = nil;
    @try { previewMedia = link.previewMedia; } @catch (__unused NSException *exception) {}
    NSURL *url = ApolloFeedThumbURLFromPreviewMedia(previewMedia, preferHighQuality);
    if (url) {
        if (outSource) *outSource = preferHighQuality ? @"previewMediaHQ" : @"previewMedia";
        return url;
    }

    url = ApolloFeedThumbURLFromDirectLink(link);
    if (url) {
        if (outSource) *outSource = @"direct";
        return url;
    }

    url = ApolloFeedThumbURLFromMediaMetadata(link, preferHighQuality);
    if (url) {
        if (outSource) *outSource = preferHighQuality ? @"mediaMetadataHQ" : @"mediaMetadata";
        return url;
    }

    // Last resort: v.redd.it / crosspost-video posts whose previewMedia hasn't
    // been populated by Apollo yet. We synchronously check our async fetch cache
    // and (if missing) kick off a fetch that will post a notification on success.
    NSURL *cached = ApolloFeedThumbCachedVRedditPreview(link);
    if (cached) {
        if (outSource) *outSource = @"vredditCache";
        return cached;
    }
    ApolloFeedThumbKickVRedditFetch(link);

    return nil;
}

// MARK: - Cell-level injection
//
// Apollo's feed cells (Large/Compact PostCellNode) do NOT consume
// `-[RDKLink thumbnailURL]` — proven on-device. So we attach a UIImageView
// directly to the cell's `thumbnailNode.view` whenever Reddit gives Apollo
// an unusable native thumbnail but the link model still contains enough media
// metadata to recover a preview image.

static const void *kFeedThumbImageViewKey   = &kFeedThumbImageViewKey;   // UIImageView *
static const void *kFeedThumbBlurViewKey    = &kFeedThumbBlurViewKey;    // UIVisualEffectView * (legacy, no longer used)
static const void *kFeedThumbPlayBadgeKey   = &kFeedThumbPlayBadgeKey;   // UIImageView * (play.fill SF Symbol)
static const void *kFeedThumbObscuredOverlayKey = &kFeedThumbObscuredOverlayKey; // UIView * (native-style spoiler/NSFW label)
static const void *kFeedThumbCurrentURLKey  = &kFeedThumbCurrentURLKey;  // NSURL *
static const void *kFeedThumbCurrentTaskKey = &kFeedThumbCurrentTaskKey; // NSURLSessionDataTask *
static const void *kFeedThumbCurrentLinkIDKey = &kFeedThumbCurrentLinkIDKey; // NSString *
static const void *kFeedThumbLoadedImageSizeKey = &kFeedThumbLoadedImageSizeKey; // NSValue(CGSize)
static const void *kFeedThumbHeaderImageViewKey = &kFeedThumbHeaderImageViewKey; // UIImageView *
static const void *kFeedThumbHeaderPlayBadgeKey = &kFeedThumbHeaderPlayBadgeKey; // UIImageView *
static const void *kFeedThumbHeaderCurrentURLKey = &kFeedThumbHeaderCurrentURLKey; // NSURL *
static const void *kFeedThumbHeaderCurrentTaskKey = &kFeedThumbHeaderCurrentTaskKey; // NSURLSessionDataTask *
static const void *kFeedThumbHeaderCurrentLinkIDKey = &kFeedThumbHeaderCurrentLinkIDKey; // NSString *
static const void *kFeedThumbHeaderRetryScheduledKey = &kFeedThumbHeaderRetryScheduledKey; // NSNumber(BOOL)
static const void *kFeedThumbLastAppliedLinkPtrKey = &kFeedThumbLastAppliedLinkPtrKey; // NSValue *
static const void *kFeedThumbLastAppliedSizeKey = &kFeedThumbLastAppliedSizeKey; // NSValue(CGSize)
static const void *kFeedThumbMountedOnPillKey = &kFeedThumbMountedOnPillKey; // NSNumber(BOOL)
static const void *kFeedThumbPillHiddenSiblingsKey = &kFeedThumbPillHiddenSiblingsKey; // NSArray<UIView *> *
static const void *kFeedThumbCommentsTopResetKey = &kFeedThumbCommentsTopResetKey; // NSNumber(BOOL)
static const void *kFeedThumbCommentsInitialOffsetKey = &kFeedThumbCommentsInitialOffsetKey; // NSNumber(CGFloat)
// Stretch state: the target size we've forced onto richMediaNode (via
// Texture's preferredSize style) so the pill slot grows to a proper
// large-mode image card size instead of a ~60pt link pill. Stored on
// the *richMediaNode* (not the cell) since style.preferredSize is a
// per-node attribute and the cell may reuse the same richMediaNode.
static const void *kFeedThumbStretchTargetKey = &kFeedThumbStretchTargetKey; // NSValue(CGSize) on richMediaNode

NSString *const ApolloFeedThumbsLinkUpdatedNotification = @"ApolloFeedThumbsLinkUpdatedNotification";
static NSString *const kApolloFeedThumbsLinkPointerKey = @"linkPointer";

// Forward decls for pill-stretch helpers (defined after ApolloFeedThumbClearImageOnCell).
static void ApolloFeedThumbSetPillStretchTarget(id richMediaNode, CGSize targetSize, id cell);
static CGSize ApolloFeedThumbPillStretchTargetGet(id richMediaNode);
static void ApolloFeedThumbApplyCommentsHeaderPoster(id headerCell);

// MARK: - v.redd.it preview-image fetch
//
// Reddit's listing JSON for v.redd.it posts includes a still preview image
// (preview.images[0].source.url), but Apollo doesn't populate
// `RDKLink.previewMedia` for these posts until the user enters the post
// detail view. We bridge that gap by issuing one authenticated /api/info
// request per post (using the bearer token captured by ApolloImageUploadHost),
// caching the resolved URL by fullName, and posting the standard
// "link updated" notification so the cell-apply observer reapplies.

static NSCache<NSString *, NSURL *> *ApolloFeedThumbVRedditCache(void) {
    static NSCache<NSString *, NSURL *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 512;
    });
    return cache;
}

static NSMutableSet<NSString *> *ApolloFeedThumbVRedditInFlight(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static NSMutableSet<NSString *> *ApolloFeedThumbVRedditFailed(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL ApolloFeedThumbLinkLooksLikeRedditVideo(RDKLink *link) {
    if (!link) return NO;
    NSURL *url = nil;
    @try { url = link.URL; } @catch (__unused id e) {}
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"v.redd.it"]) return YES;
    // Crossposts and reddit.com/.../comments/ links fall through to detailed
    // fetch via thumbnailURL/previewMedia normally; only chase v.redd.it here.
    return NO;
}

static NSURL *ApolloFeedThumbCachedVRedditPreview(RDKLink *link) {
    NSString *fullName = nil;
    @try { fullName = link.fullName; } @catch (__unused id e) {}
    if (fullName.length == 0) return nil;
    return [ApolloFeedThumbVRedditCache() objectForKey:fullName];
}

static NSURLSession *ApolloFeedThumbSharedSession(void);  // forward decl

static void ApolloFeedThumbKickVRedditFetch(RDKLink *link) {
    if (!ApolloFeedThumbLinkLooksLikeRedditVideo(link)) return;

    NSString *fullName = nil;
    @try { fullName = link.fullName; } @catch (__unused id e) {}
    if (fullName.length == 0) return;

    NSString *bearer = sLatestRedditBearerToken;
    if (bearer.length == 0) return;  // No token yet — Apollo will likely populate previewMedia on its own once it talks to Reddit.

    NSCache *cache = ApolloFeedThumbVRedditCache();
    if ([cache objectForKey:fullName]) return;

    NSMutableSet *inflight = ApolloFeedThumbVRedditInFlight();
    NSMutableSet *failed   = ApolloFeedThumbVRedditFailed();
    @synchronized (inflight) {
        if ([inflight containsObject:fullName]) return;
        if ([failed containsObject:fullName]) return;  // Don't retry forever.
        [inflight addObject:fullName];
    }

    // Strongly capture the link so the pointer remains valid for the duration
    // of the request — the cell observer keys off the pointer to find which
    // cells to reapply.
    __strong RDKLink *strongLink = link;
    NSString *urlStr = [NSString stringWithFormat:@"https://oauth.reddit.com/api/info?id=%@&raw_json=1", fullName];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"ApolloImprovedCustomApi/1.0" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 10.0;

    NSURLSessionDataTask *task = [ApolloFeedThumbSharedSession() dataTaskWithRequest:req
                                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        @synchronized (inflight) { [inflight removeObject:fullName]; }
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (error || data.length == 0 || (http && http.statusCode >= 400)) {
            @synchronized (inflight) { [failed addObject:fullName]; }
            return;
        }
        NSError *jerr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
        if (![json isKindOfClass:[NSDictionary class]]) {
            @synchronized (inflight) { [failed addObject:fullName]; }
            return;
        }
        NSDictionary *root = json;
        NSDictionary *dataD = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
        NSArray *children = [dataD[@"children"] isKindOfClass:[NSArray class]] ? dataD[@"children"] : nil;
        if (children.count == 0) {
            @synchronized (inflight) { [failed addObject:fullName]; }
            return;
        }
        NSDictionary *child = [children.firstObject isKindOfClass:[NSDictionary class]] ? children.firstObject : nil;
        NSDictionary *cd = [child[@"data"] isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
        NSDictionary *preview = [cd[@"preview"] isKindOfClass:[NSDictionary class]] ? cd[@"preview"] : nil;
        NSArray *images = [preview[@"images"] isKindOfClass:[NSArray class]] ? preview[@"images"] : nil;
        NSDictionary *first = [images.firstObject isKindOfClass:[NSDictionary class]] ? images.firstObject : nil;
        NSDictionary *src = [first[@"source"] isKindOfClass:[NSDictionary class]] ? first[@"source"] : nil;
        NSString *u = [src[@"url"] isKindOfClass:[NSString class]] ? src[@"url"] : nil;
        NSURL *previewURL = ApolloFeedThumbURLFromString(u);
        if (!previewURL) {
            @synchronized (inflight) { [failed addObject:fullName]; }
            return;
        }
        [cache setObject:previewURL forKey:fullName];
        ApolloLog(@"[FeedThumbs] vredditFetched url=%@ fullName=%@", previewURL.absoluteString, fullName);

        // Notify the cell observer to reapply.
        const void *linkPtr = (__bridge const void *)strongLink;
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)strongLink; // keep alive on main until notification
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloFeedThumbsLinkUpdatedNotification
                                                                object:nil
                                                              userInfo:@{kApolloFeedThumbsLinkPointerKey: [NSValue valueWithPointer:linkPtr]}];
        });
    }];
    [task resume];
}

// Weak registry of all live cells we've hooked, so the link-updated
// notification can find which cell currently displays a given mutated link
// (e.g. when v.redd.it's previewMedia is populated lazily after the cell
// already laid out with no fallback URL).
static NSHashTable<id> *ApolloFeedThumbTrackedCells(void) {
    static NSHashTable<id> *cells;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cells = [NSHashTable weakObjectsHashTable]; });
    return cells;
}

static void ApolloFeedThumbTrackCell(id cell) {
    if (!cell) return;
    @synchronized (ApolloFeedThumbTrackedCells()) {
        [ApolloFeedThumbTrackedCells() addObject:cell];
    }
}

static NSHashTable<id> *ApolloFeedThumbTrackedHeaders(void) {
    static NSHashTable<id> *headers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ headers = [NSHashTable weakObjectsHashTable]; });
    return headers;
}

static void ApolloFeedThumbTrackHeader(id headerCell) {
    if (!headerCell) return;
    @synchronized (ApolloFeedThumbTrackedHeaders()) {
        [ApolloFeedThumbTrackedHeaders() addObject:headerCell];
    }
}

static id ApolloFeedThumbIvarByName(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class cls = object_getClass(obj);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(obj, ivar);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static RDKLink *ApolloFeedThumbLinkFromCell(id cell) {
    if (!cell) return nil;
    id v = ApolloFeedThumbIvarByName(cell, "link");
    if ([v isKindOfClass:objc_getClass("RDKLink")]) return (RDKLink *)v;
    return nil;
}

static UIView *ApolloFeedThumbViewForNode(id node) {
    if (!node) return nil;
    if (![node respondsToSelector:@selector(view)]) return nil;
    @try {
        ApolloFeedThumbDisplayNode *n = (ApolloFeedThumbDisplayNode *)node;
        if (![n respondsToSelector:@selector(isNodeLoaded)] || !n.isNodeLoaded) return nil;
        return n.view;
    } @catch (__unused id e) {}
    return nil;
}

static UIView *ApolloFeedThumbThumbnailViewFromCell(id cell) {
    id node = ApolloFeedThumbIvarByName(cell, "thumbnailNode");
    UIView *v = ApolloFeedThumbViewForNode(node);
    if (v && v.bounds.size.width > 4 && v.bounds.size.height > 4) return v;
    return nil;
}

// MARK: - Pill node (large-mode "stuck pill") mount target
//
// In LARGE feed mode, Apollo decides at cell-construction time whether to
// build a `richMediaNode` (rich media area) or a `linkButtonNode` (the redd.it
// pill) based on the link's *initial* thumbnailURL/previewMedia. When the
// initial value is empty/placeholder, Apollo locks in the pill — and never
// rebuilds the cell even after our `setPreviewMedia:` notification later
// supplies a real URL. So a subset of large-mode posts that we CAN recover
// URLs for still show a useless pill (e.g. r/Bleach direct image posts whose
// `thumbnail` came back as "image"/"").
//
// To fix this, `ApolloFeedThumbApplyToCell` falls back to mounting our
// UIImageView on the pill node's view when no thumbnailNode is present and we
// have a Reddit-hosted recovered URL.

// In LARGE feed mode, the LargePostCellNode does NOT carry the link pill as
// a top-level ivar. The pill IS rendered inside `richMediaNode` \u2014 Apollo
// uses the same `richMediaNode` slot for both real media (image/video card)
// and the link-button pill, choosing one or the other based on the link's
// initial thumbnailURL/previewMedia. So we look for the pill BOTH on the
// cell's top-level ivars (for any cell variant that does expose it
// directly) AND inside richMediaNode + crosspostNode.richMediaNode.
//
// Critically: when richMediaNode is rendering a real image/video card we
// MUST NOT cover it. The signal is `videoNode` ivar presence \u2014 if
// richMediaNode has a non-nil `videoNode` (or a `mediaImageNode` / similar),
// it's rendering real media. Otherwise it's in pill mode and we can mount
// our recovered thumbnail on top.

static BOOL ApolloFeedThumbRichMediaIsRealMedia(id richMediaNode) {
    if (!richMediaNode) return NO;
    // Real media slots populate one of these ivars; pill state leaves them nil.
    static const char *const kMediaIvars[] = {
        "videoNode",        // v.redd.it / Streamable / GIF
        "mediaImageNode",   // direct image render
        "imageNode",        // alternate image ivar
        "galleryNode",      // multi-image gallery
        "playerNode",       // alternate video ivar
    };
    for (size_t i = 0; i < sizeof(kMediaIvars)/sizeof(kMediaIvars[0]); i++) {
        if (ApolloFeedThumbIvarByName(richMediaNode, kMediaIvars[i])) return YES;
    }
    return NO;
}

// Probe a parent (cell OR richMediaNode) for a link-pill subnode by ivar name.
static id ApolloFeedThumbProbeLinkPillNode(id parent) {
    if (!parent) return nil;
    static const char *const kNames[] = {
        "linkButtonNode", "linkNode", "linkPreviewNode", "linkBubbleNode",
        "linkButton", "linkPillNode",
    };
    for (size_t i = 0; i < sizeof(kNames)/sizeof(kNames[0]); i++) {
        id node = ApolloFeedThumbIvarByName(parent, kNames[i]);
        if (node) return node;
    }
    return nil;
}

static id ApolloFeedThumbPillNodeFromCell(id cell) {
    if (!cell) return nil;
    // 1. Top-level ivar on the cell (rare; works for any cell variant that
    //    exposes the pill directly).
    id node = ApolloFeedThumbProbeLinkPillNode(cell);
    if (node) return node;

    // 2. Inside richMediaNode \u2014 the LargePostCellNode pattern. Apollo's
    //    richMediaNode is the parent media slot that contains BOTH a
    //    `linkButtonNode` (the small redd.it pill) AND a `thumbnailNode`
    //    sibling. We mount on richMediaNode itself (the larger card area)
    //    rather than on the small linkButtonNode child, otherwise the image
    //    is squished into pill height (~60pt). The linkButtonNode child
    //    will be hidden separately by ApolloFeedThumbHidePillSiblings so
    //    the pill text/icon doesn't show through.
    //    Only mount when richMediaNode is NOT in real-media mode, otherwise
    //    we'd cover a working video/image card.
    id richMedia = ApolloFeedThumbIvarByName(cell, "richMediaNode");
    if (richMedia && !ApolloFeedThumbRichMediaIsRealMedia(richMedia)) {
        return richMedia;
    }

    // 3. Inside crosspostNode.richMediaNode \u2014 same pattern for crossposts.
    id crosspost = ApolloFeedThumbIvarByName(cell, "crosspostNode");
    id crossRichMedia = crosspost ? ApolloFeedThumbIvarByName(crosspost, "richMediaNode") : nil;
    if (crossRichMedia && !ApolloFeedThumbRichMediaIsRealMedia(crossRichMedia)) {
        return crossRichMedia;
    }

    return nil;
}

static UIView *ApolloFeedThumbPillViewFromCell(id cell) {
    id node = ApolloFeedThumbPillNodeFromCell(cell);
    UIView *v = ApolloFeedThumbViewForNode(node);
    // Pills (and richMediaNode in pill mode) are wide and short; require
    // minimum width AND height to avoid mounting on a degenerate/zero-sized
    // layout pass. richMediaNode in image-card mode is taller \u2014 still
    // accept it (we already filtered out real-media mode above).
    if (v && v.bounds.size.width > 40 && v.bounds.size.height > 20) return v;
    return nil;
}

// Only mount on the pill when our recovered URL points at a host whose
// thumbnail represents the actual post content — i.e. Reddit-hosted images,
// imgur/ytimg posters. Skip arbitrary external link previews where the pill
// IS the legitimate UI (e.g. note.com, news articles), since Apollo already
// renders an image card above those pills via native previewMedia handling.
static BOOL ApolloFeedThumbURLIsPillCoverable(NSURL *url) {
    if (!ApolloFeedThumbURLIsUsable(url)) return NO;
    NSString *host = url.host.lowercaseString;
    if (!host) return NO;
    if ([host isEqualToString:@"i.redd.it"]) return YES;
    if ([host isEqualToString:@"preview.redd.it"]) return YES;
    if ([host hasSuffix:@"redditmedia.com"]) return YES;
    if ([host hasSuffix:@"external-preview.redd.it"]) return YES;
    if ([host hasPrefix:@"external-preview"]) return YES;
    if ([host isEqualToString:@"i.imgur.com"]) return YES;
    if ([host hasSuffix:@"ytimg.com"]) return YES;
    return NO;
}

// When mounted on the pill, hide the pill's existing subviews (icon + URL
// text) so they don't peek through during the brief image load. Cache the
// list on the cell so we can restore visibility when we unmount.
static void ApolloFeedThumbHidePillSiblings(id cell, UIView *pillView, UIImageView *ourIV, UIImageView *ourBadge) {
    if (!pillView) return;
    NSMutableArray<UIView *> *hiddenNow = [NSMutableArray array];
    for (UIView *sub in pillView.subviews) {
        if (sub == ourIV || sub == ourBadge) continue;
        if (sub.hidden) continue;
        sub.hidden = YES;
        [hiddenNow addObject:sub];
    }
    NSArray<UIView *> *prior = objc_getAssociatedObject(cell, kFeedThumbPillHiddenSiblingsKey);
    NSMutableArray<UIView *> *combined = prior ? [prior mutableCopy] : [NSMutableArray array];
    for (UIView *v in hiddenNow) {
        if (![combined containsObject:v]) [combined addObject:v];
    }
    objc_setAssociatedObject(cell, kFeedThumbPillHiddenSiblingsKey, combined, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloFeedThumbRestorePillSiblings(id cell) {
    NSArray<UIView *> *prior = objc_getAssociatedObject(cell, kFeedThumbPillHiddenSiblingsKey);
    for (UIView *sub in prior) {
        if ([sub isKindOfClass:[UIView class]]) sub.hidden = NO;
    }
    objc_setAssociatedObject(cell, kFeedThumbPillHiddenSiblingsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSURLSession *ApolloFeedThumbSharedSession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 15.0;
        config.HTTPMaximumConnectionsPerHost = 6;
        // Reuse Foundation's default URL cache so re-displayed thumbnails don't refetch.
        config.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
        config.URLCache = [NSURLCache sharedURLCache];
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

static NSMutableSet<NSString *> *ApolloFeedThumbAppliedCellLogKeys(void) {
    static NSMutableSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ keys = [NSMutableSet set]; });
    return keys;
}

static void ApolloFeedThumbLogAppliedOnce(id cell, RDKLink *link, NSString *source) {
    NSString *fullName = nil;
    @try { fullName = link.fullName; } @catch (__unused id e) {}
    if (fullName.length == 0) fullName = [NSString stringWithFormat:@"%p", link];
    NSString *key = [NSString stringWithFormat:@"%p|%@", cell, fullName];
    @synchronized (ApolloFeedThumbAppliedCellLogKeys()) {
        if ([ApolloFeedThumbAppliedCellLogKeys() containsObject:key]) return;
        [ApolloFeedThumbAppliedCellLogKeys() addObject:key];
    }
    NSString *sub = nil; NSString *title = nil;
    @try { sub = link.subreddit; } @catch (__unused id e) {}
    @try { title = link.title; } @catch (__unused id e) {}
    ApolloLog(@"[FeedThumbs] applied to cell (%@) for r/%@ title='%@'",
              source ?: @"?", sub ?: @"?", title ?: @"?");
}

static void ApolloFeedThumbClearImageOnCell(id cell) {
    UIImageView *iv = objc_getAssociatedObject(cell, kFeedThumbImageViewKey);
    if (iv) {
        iv.image = nil;
        iv.hidden = YES;
        iv.layer.contentsRect = CGRectMake(0, 0, 1, 1);
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.backgroundColor = [UIColor clearColor];
    }
    UIVisualEffectView *blur = objc_getAssociatedObject(cell, kFeedThumbBlurViewKey);
    if (blur) blur.hidden = YES;
    UIImageView *badge = objc_getAssociatedObject(cell, kFeedThumbPlayBadgeKey);
    if (badge) badge.hidden = YES;
    UIView *obscuredOverlay = objc_getAssociatedObject(cell, kFeedThumbObscuredOverlayKey);
    if (obscuredOverlay) {
        [obscuredOverlay removeFromSuperview];
        objc_setAssociatedObject(cell, kFeedThumbObscuredOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSURLSessionDataTask *task = objc_getAssociatedObject(cell, kFeedThumbCurrentTaskKey);
    [task cancel];
    objc_setAssociatedObject(cell, kFeedThumbCurrentTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kFeedThumbCurrentURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kFeedThumbCurrentLinkIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kFeedThumbLoadedImageSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Restore pill text/icon if we had hidden them while mounted on the pill.
    ApolloFeedThumbRestorePillSiblings(cell);
    objc_setAssociatedObject(cell, kFeedThumbMountedOnPillKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // If we had stretched the cell's richMediaNode for a pill image card,
    // collapse it back so other cell-reuse paths (text post, real media)
    // get the correct intrinsic size.
    id richMediaForReset = ApolloFeedThumbIvarByName(cell, "richMediaNode");
    if (richMediaForReset) ApolloFeedThumbSetPillStretchTarget(richMediaForReset, CGSizeZero, cell);
    id crossForReset = ApolloFeedThumbIvarByName(cell, "crosspostNode");
    id crossRichForReset = crossForReset ? ApolloFeedThumbIvarByName(crossForReset, "richMediaNode") : nil;
    if (crossRichForReset) ApolloFeedThumbSetPillStretchTarget(crossRichForReset, CGSizeZero, cell);
}

// MARK: - Pill stretch
//
// When we mount a recovered preview image inside richMediaNode's pill slot
// (large-mode "stuck pill" cells), the slot itself is laid out at ~60pt
// because Apollo's intrinsic size for the pill is just text + icon. Texture
// nodes expose `style.preferredSize` as the standard way to override their
// intrinsic measurement — the parent stack spec will then allocate the
// requested space and the cell as a whole grows correspondingly.
//
// We:
//   1. Set richMediaNode.style.preferredSize = (targetWidth, targetHeight).
//      Passing width 0 is unsafe in Texture: it can be interpreted as a
//      literal zero-width layout, which makes the image disappear.
//   2. Invalidate richMediaNode's calculated layout.
//   3. Trigger ASCellNode re-measurement via
//      transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:
//      so the collection picks up the new cell height.
//
// Reset (passing CGSizeZero) restores CGSizeZero (auto) so cell reuse with
// real media or text-only posts gets back the natural layout.

static CGSize ApolloFeedThumbPillStretchTargetGet(id richMediaNode) {
    if (!richMediaNode) return CGSizeZero;
    NSValue *v = objc_getAssociatedObject(richMediaNode, kFeedThumbStretchTargetKey);
    return [v isKindOfClass:[NSValue class]] ? v.CGSizeValue : CGSizeZero;
}

static BOOL ApolloFeedThumbSizeNearlyEqual(CGSize a, CGSize b) {
    return fabs(a.width - b.width) < 0.5 && fabs(a.height - b.height) < 0.5;
}

static BOOL ApolloFeedThumbShouldLogStretchProbe(void) {
    static NSUInteger logged = 0;
    static dispatch_semaphore_t lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = dispatch_semaphore_create(1); });
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    BOOL shouldLog = logged < 24;
    if (shouldLog) logged++;
    dispatch_semaphore_signal(lock);
    return shouldLog;
}

// Apply preferredSize on richMediaNode and trigger a relayout on the cell.
// `cell` may be nil for the reset path (we still need to clear the style).
static void ApolloFeedThumbSetPillStretchTarget(id richMediaNode, CGSize targetSize, id cell) {
    if (!richMediaNode) return;
    BOOL enabled = targetSize.width > 1.0 && targetSize.height > 1.0;
    CGSize normalizedTarget = enabled ? targetSize : CGSizeZero;
    CGSize current = ApolloFeedThumbPillStretchTargetGet(richMediaNode);
    if (ApolloFeedThumbSizeNearlyEqual(current, normalizedTarget)) return; // no-op

    objc_setAssociatedObject(richMediaNode, kFeedThumbStretchTargetKey,
                             enabled ? [NSValue valueWithCGSize:normalizedTarget] : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 1. Override intrinsic size via style.preferredSize.
    @try {
        if ([(id)richMediaNode respondsToSelector:@selector(style)]) {
            id style = ((id (*)(id, SEL))objc_msgSend)(richMediaNode, @selector(style));
            if (style && [style respondsToSelector:@selector(setPreferredSize:)]) {
                ((void (*)(id, SEL, CGSize))objc_msgSend)(style, @selector(setPreferredSize:), normalizedTarget);
            }
        }
    } @catch (__unused id e) {}

    BOOL logBefore = enabled && ApolloFeedThumbShouldLogStretchProbe();
    if (logBefore) {
        UIView *rmView = nil;
        UIView *cellView = nil;
        @try {
            if ([(id)richMediaNode respondsToSelector:@selector(view)]) {
                rmView = ((UIView *(*)(id, SEL))objc_msgSend)(richMediaNode, @selector(view));
            }
            if (cell && [(id)cell respondsToSelector:@selector(view)]) {
                cellView = ((UIView *(*)(id, SEL))objc_msgSend)(cell, @selector(view));
            }
        } @catch (__unused id e) {}
        ApolloLog(@"[FeedThumbs] stretch set target=%@ cellBounds=%@ rmFrame=%@ rmBounds=%@",
                  NSStringFromCGSize(normalizedTarget),
                  cellView ? NSStringFromCGRect(cellView.bounds) : @"nil",
                  rmView ? NSStringFromCGRect(rmView.frame) : @"nil",
                  rmView ? NSStringFromCGRect(rmView.bounds) : @"nil");
    }

    // 2. Invalidate the node's cached layout so it re-measures.
    @try {
        if ([(id)richMediaNode respondsToSelector:@selector(invalidateCalculatedLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(richMediaNode, @selector(invalidateCalculatedLayout));
        }
        if ([(id)richMediaNode respondsToSelector:@selector(setNeedsLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(richMediaNode, @selector(setNeedsLayout));
        }
    } @catch (__unused id e) {}

    // 3. Trigger ASCellNode re-measurement so the collection picks up the
    //    new cell size. Dispatched async so we never call this from inside
    //    a layout pass (Texture asserts on re-entrant transitions).
    if (cell) {
        __weak id weakCell = cell;
        __weak id weakRichMedia = richMediaNode;
        BOOL logAfter = logBefore;
        dispatch_async(dispatch_get_main_queue(), ^{
            id strongCell = weakCell;
            if (!strongCell) return;
            @try {
                SEL transitionSel = @selector(transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:);
                if ([strongCell respondsToSelector:transitionSel]) {
                    ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(strongCell, transitionSel, NO, NO, nil);
                } else if ([strongCell respondsToSelector:@selector(setNeedsLayout)]) {
                    ((void (*)(id, SEL))objc_msgSend)(strongCell, @selector(setNeedsLayout));
                }
            } @catch (__unused id e) {}
            if (logAfter) {
                id strongRichMedia = weakRichMedia;
                UIView *rmView = nil;
                UIView *cellView = nil;
                UIImageView *iv = objc_getAssociatedObject(strongCell, kFeedThumbImageViewKey);
                @try {
                    if (strongRichMedia && [(id)strongRichMedia respondsToSelector:@selector(view)]) {
                        rmView = ((UIView *(*)(id, SEL))objc_msgSend)(strongRichMedia, @selector(view));
                    }
                    if ([(id)strongCell respondsToSelector:@selector(view)]) {
                        cellView = ((UIView *(*)(id, SEL))objc_msgSend)(strongCell, @selector(view));
                    }
                } @catch (__unused id e) {}
                ApolloLog(@"[FeedThumbs] stretch after transition cellFrame=%@ cellBounds=%@ rmFrame=%@ rmBounds=%@ ivFrame=%@ ivHidden=%@ superBounds=%@",
                          cellView ? NSStringFromCGRect(cellView.frame) : @"nil",
                          cellView ? NSStringFromCGRect(cellView.bounds) : @"nil",
                          rmView ? NSStringFromCGRect(rmView.frame) : @"nil",
                          rmView ? NSStringFromCGRect(rmView.bounds) : @"nil",
                          iv ? NSStringFromCGRect(iv.frame) : @"nil",
                          iv ? (iv.hidden ? @"YES" : @"NO") : @"nil",
                          iv.superview ? NSStringFromCGRect(iv.superview.bounds) : @"nil");
            }
        });
    }

    static dispatch_once_t logToken;
    dispatch_once(&logToken, ^{
        ApolloLog(@"[FeedThumbs] pill stretch wired: preferredSize→(width,height) + transitionLayoutWithAnimation");
    });
}

// MARK: - Spoiler/NSFW gaussian blur
//
// We render the spoiler effect by gaussian-blurring the loaded image itself
// (frosted-glass look that still hints at colors/silhouette) instead of
// stacking a UIVisualEffectView dark material over a black background
// (which collapses to a flat grey square when there's no underlying view
// content to vibrancy-mix with).

static CIContext *ApolloFeedThumbCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ ctx = [CIContext contextWithOptions:nil]; });
    return ctx;
}

static NSCache<NSString *, UIImage *> *ApolloFeedThumbBlurCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 128;  // ~few MB cap; small thumbnails.
    });
    return cache;
}

static UIImage *ApolloFeedThumbBlurImage(UIImage *src, NSString *cacheKey) {
    if (!src) return nil;
    if (cacheKey.length > 0) {
        UIImage *hit = [ApolloFeedThumbBlurCache() objectForKey:cacheKey];
        if (hit) return hit;
    }
    CGImageRef cg = src.CGImage;
    if (!cg) return nil;
    CIImage *input = [CIImage imageWithCGImage:cg];
    if (!input) return nil;

    CIFilter *clamp = [CIFilter filterWithName:@"CIAffineClamp"];  // avoids translucent edges
    [clamp setValue:input forKey:kCIInputImageKey];
    [clamp setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformIdentity] forKey:@"inputTransform"];

    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:[clamp outputImage] forKey:kCIInputImageKey];
    [blur setValue:@(130.0) forKey:kCIInputRadiusKey];

    CIImage *output = [blur outputImage];
    if (!output) return nil;
    CGImageRef outCG = [ApolloFeedThumbCIContext() createCGImage:output fromRect:input.extent];
    if (!outCG) return nil;
    UIImage *result = [UIImage imageWithCGImage:outCG scale:src.scale orientation:src.imageOrientation];
    CGImageRelease(outCG);
    if (cacheKey.length > 0 && result) {
        [ApolloFeedThumbBlurCache() setObject:result forKey:cacheKey];
    }
    return result;
}

// MARK: - Play badge
//
// Apollo's own video play indicator is part of the thumbnailNode tree, which
// gets visually covered by our injected UIImageView (we have to render on
// top to hide the missing-thumbnail placeholder). Re-add a play.fill badge
// for video posts so users can tell the post is a video at a glance.

static BOOL ApolloFeedThumbLinkIsVideoPost(RDKLink *link, NSString *source) {
    if ([source isEqualToString:@"vredditCache"]) return YES;
    NSURL *url = nil;
    @try { url = link.URL; } @catch (__unused id e) {}
    NSString *host = url.host.lowercaseString;
    if (!host) return NO;
    if ([host isEqualToString:@"v.redd.it"]) return YES;
    if ([host isEqualToString:@"youtu.be"]) return YES;
    if ([host hasSuffix:@"youtube.com"]) return YES;
    if ([host hasSuffix:@"ytimg.com"]) return YES;  // direct hqdefault.jpg fallback for youtube
    if ([host hasSuffix:@"streamable.com"]) return YES;
    if ([host hasSuffix:@"gfycat.com"]) return YES;
    if ([host hasSuffix:@"redgifs.com"]) return YES;
    return NO;
}

static BOOL ApolloFeedThumbLinkIsStaticPosterVideo(RDKLink *link, NSString *source) {
    NSURL *url = nil;
    @try { url = link.URL; } @catch (__unused id e) {}
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"youtu.be"]) return YES;
    if ([host hasSuffix:@"youtube.com"]) return YES;
    if ([host hasSuffix:@"youtube-nocookie.com"]) return YES;
    if ([host hasSuffix:@"ytimg.com"]) return YES;
    return [source isEqualToString:@"direct"] && [ApolloFeedThumbURLFromDirectLink(link).host.lowercaseString hasSuffix:@"ytimg.com"];
}

typedef NS_ENUM(NSInteger, ApolloFeedThumbPlayBadgeStyle) {
    ApolloFeedThumbPlayBadgeStyleNone = 0,
    ApolloFeedThumbPlayBadgeStyleCompactCorner,
    ApolloFeedThumbPlayBadgeStyleLargeCenter,
};

static void ApolloFeedThumbConfigurePlayBadgeImage(UIImageView *badge, ApolloFeedThumbPlayBadgeStyle style) {
    if (!badge) return;
    if (style == ApolloFeedThumbPlayBadgeStyleLargeCenter) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightSemibold];
        badge.image = [UIImage systemImageNamed:@"play.fill" withConfiguration:cfg];
        badge.tintColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        badge.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.82];
        badge.layer.cornerRadius = 31.0;
        badge.layer.shadowOpacity = 0.35;
        badge.layer.shadowRadius = 8.0;
        badge.layer.shadowOffset = CGSizeMake(0, 2);
    } else {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        badge.image = [UIImage systemImageNamed:@"play.circle.fill" withConfiguration:cfg];
        badge.tintColor = [UIColor whiteColor];
        badge.backgroundColor = [UIColor clearColor];
        badge.layer.cornerRadius = 0;
        badge.layer.shadowOpacity = 0.6;
        badge.layer.shadowRadius = 2.5;
        badge.layer.shadowOffset = CGSizeMake(0, 1);
    }
}

static void ApolloFeedThumbApplyPlayBadge(id cell, UIView *parent, ApolloFeedThumbPlayBadgeStyle style) {
    UIImageView *badge = objc_getAssociatedObject(cell, kFeedThumbPlayBadgeKey);
    if (style == ApolloFeedThumbPlayBadgeStyleNone) {
        if (badge) badge.hidden = YES;
        return;
    }
    if (!badge) {
        badge = [[UIImageView alloc] initWithFrame:CGRectZero];
        badge.userInteractionEnabled = NO;
        badge.contentMode = UIViewContentModeCenter;
        // Subtle drop shadow so the icon stays readable on bright thumbnails.
        badge.layer.shadowColor = [UIColor blackColor].CGColor;
        objc_setAssociatedObject(cell, kFeedThumbPlayBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloFeedThumbConfigurePlayBadgeImage(badge, style);
    if (badge.superview != parent) {
        [badge removeFromSuperview];
        [parent addSubview:badge];
    } else {
        [parent bringSubviewToFront:badge];
    }
    badge.hidden = NO;
    CGSize parentSize = parent.bounds.size;
    if (style == ApolloFeedThumbPlayBadgeStyleLargeCenter) {
        CGFloat side = MIN(68.0, MAX(54.0, parentSize.height * 0.24));
        badge.layer.cornerRadius = side / 2.0;
        badge.frame = CGRectMake((parentSize.width - side) / 2.0,
                                 (parentSize.height - side) / 2.0,
                                 side, side);
    } else {
        // Compact mode keeps the existing small bottom-right badge.
        CGSize badgeSize = CGSizeMake(22, 22);
        CGFloat margin = 5.0;
        badge.frame = CGRectMake(parentSize.width  - badgeSize.width  - margin,
                                 parentSize.height - badgeSize.height - margin,
                                 badgeSize.width, badgeSize.height);
    }
}

static UIImageView *ApolloFeedThumbEnsureImageView(id cell, UIView *parent) {
    UIImageView *iv = objc_getAssociatedObject(cell, kFeedThumbImageViewKey);
    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:parent.bounds];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        iv.backgroundColor = [UIColor clearColor];
        // Match Apollo's native thumbnail corner rounding (compact + large feed cells).
        iv.layer.cornerRadius = 6.0;
        iv.layer.masksToBounds = YES;
        objc_setAssociatedObject(cell, kFeedThumbImageViewKey, iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (iv.superview != parent) {
        [iv removeFromSuperview];
        // Add on top so we cover the native thumbnailNode's placeholder layer
        // (which otherwise paints a grey image-icon square over us). Play
        // badges / gallery indicators live on sibling nodes, not on
        // thumbnailNode's subview tree, so they remain visible.
        [parent addSubview:iv];
    } else {
        // Make sure we stay above any subviews added later by the node.
        [parent bringSubviewToFront:iv];
    }
    iv.frame = parent.bounds;
    return iv;
}

static CGFloat ApolloFeedThumbClamp(CGFloat value, CGFloat minValue, CGFloat maxValue) {
    return MIN(maxValue, MAX(minValue, value));
}

static id ApolloFeedThumbRichMediaNodeForPillView(id cell, UIView *pillView) {
    if (!cell || !pillView) return nil;
    id rm = ApolloFeedThumbIvarByName(cell, "richMediaNode");
    if (rm) {
        @try {
            UIView *rmView = [(id)rm respondsToSelector:@selector(view)]
                             ? ((UIView *(*)(id, SEL))objc_msgSend)(rm, @selector(view)) : nil;
            if (rmView == pillView) return rm;
        } @catch (__unused id e) {}
    }
    id cross = ApolloFeedThumbIvarByName(cell, "crosspostNode");
    id rmx = cross ? ApolloFeedThumbIvarByName(cross, "richMediaNode") : nil;
    if (rmx) {
        @try {
            UIView *rmxView = [(id)rmx respondsToSelector:@selector(view)]
                              ? ((UIView *(*)(id, SEL))objc_msgSend)(rmx, @selector(view)) : nil;
            if (rmxView == pillView) return rmx;
        } @catch (__unused id e) {}
    }
    return nil;
}

static CGFloat ApolloFeedThumbRecoveredTargetWidth(id cell, UIView *pillView) {
    CGFloat cellW = 0;
    @try {
        if ([(id)cell respondsToSelector:@selector(view)]) {
            UIView *cv = ((UIView *(*)(id, SEL))objc_msgSend)(cell, @selector(view));
            cellW = cv.bounds.size.width;
        }
    } @catch (__unused id e) {}
    CGFloat targetW = pillView.bounds.size.width;
    if (targetW < 200) targetW = cellW;
    if (targetW < 200) targetW = 390;
    return targetW;
}

static CGFloat ApolloFeedThumbRecoveredTargetHeight(CGFloat targetW, UIImage *image, BOOL isStaticPosterVideo) {
    if (targetW < 1) targetW = 390;
    if (isStaticPosterVideo || !image || image.size.width <= 0 || image.size.height <= 0) {
        return ApolloFeedThumbClamp(targetW * 9.0 / 16.0, 180.0, 320.0);
    }

    CGFloat aspect = image.size.width / image.size.height;
    if (aspect <= 0) return ApolloFeedThumbClamp(targetW * 9.0 / 16.0, 180.0, 320.0);
    CGFloat naturalH = targetW / aspect;

    if (aspect >= 1.45) return ApolloFeedThumbClamp(naturalH, 180.0, 320.0);
    if (aspect >= 1.10) return ApolloFeedThumbClamp(naturalH, 220.0, 380.0);
    if (aspect >= 0.85) return ApolloFeedThumbClamp(naturalH, 300.0, 460.0);
    return ApolloFeedThumbClamp(naturalH, 360.0, 640.0);
}

static BOOL ApolloFeedThumbRecoveredShouldAspectFit(UIImage *image, BOOL isStaticPosterVideo) {
    if (isStaticPosterVideo || !image || image.size.width <= 0 || image.size.height <= 0) return NO;
    CGFloat aspect = image.size.width / image.size.height;
    return aspect < 0.92;
}

static void ApolloFeedThumbRemoveObscuredOverlay(id cell) {
    UIView *overlay = objc_getAssociatedObject(cell, kFeedThumbObscuredOverlayKey);
    if (overlay) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(cell, kFeedThumbObscuredOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloFeedThumbApplyObscuredOverlay(id cell, UIView *parent, RDKLink *link, BOOL enabled) {
    if (!enabled || !parent) {
        ApolloFeedThumbRemoveObscuredOverlay(cell);
        return;
    }

    BOOL isNSFW = NO;
    BOOL isSpoiler = NO;
    @try {
        if ([(id)link respondsToSelector:@selector(isNSFW)]) isNSFW = link.isNSFW;
        if ([(id)link respondsToSelector:@selector(isSpoiler)]) isSpoiler = link.isSpoiler;
    } @catch (__unused id e) {}
    if (!isNSFW && !isSpoiler) {
        ApolloFeedThumbRemoveObscuredOverlay(cell);
        return;
    }

    UIView *overlay = objc_getAssociatedObject(cell, kFeedThumbObscuredOverlayKey);
    if (!overlay) {
        overlay = [[UIView alloc] initWithFrame:parent.bounds];
        overlay.userInteractionEnabled = NO;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.10];
        overlay.layer.cornerRadius = 6.0;
        overlay.layer.masksToBounds = YES;

        UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
        stack.tag = 426901;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 8.0;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        icon.tag = 426902;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.tintColor = [UIColor whiteColor];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:icon];
        [icon.widthAnchor constraintEqualToConstant:56.0].active = YES;
        [icon.heightAnchor constraintEqualToConstant:56.0].active = YES;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
        title.tag = 426903;
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
        title.textAlignment = NSTextAlignmentCenter;
        [stack addArrangedSubview:title];

        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
        subtitle.tag = 426904;
        subtitle.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.80];
        subtitle.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
        subtitle.textAlignment = NSTextAlignmentCenter;
        subtitle.numberOfLines = 2;
        [stack addArrangedSubview:subtitle];

        [overlay addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:24.0],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-24.0],
        ]];
        objc_setAssociatedObject(cell, kFeedThumbObscuredOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    overlay.frame = parent.bounds;
    if (overlay.superview != parent) {
        [overlay removeFromSuperview];
        [parent addSubview:overlay];
    } else {
        [parent bringSubviewToFront:overlay];
    }

    UIImageView *icon = (UIImageView *)[overlay viewWithTag:426902];
    UILabel *title = (UILabel *)[overlay viewWithTag:426903];
    UILabel *subtitle = (UILabel *)[overlay viewWithTag:426904];
    NSString *symbolName = isNSFW ? @"exclamationmark.triangle.fill" : @"eye.slash.fill";
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:46.0 weight:UIImageSymbolWeightSemibold];
    icon.image = [UIImage systemImageNamed:symbolName withConfiguration:cfg] ?: [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:cfg];
    title.text = isNSFW ? @"NSFW" : @"Spoiler";
    subtitle.text = isNSFW ? @"Sensitive content - tap to view" : @"Contains spoiler - tap to view";
    overlay.hidden = NO;
}

static void ApolloFeedThumbApplyRecoveredLargePresentation(id cell,
                                                           RDKLink *link,
                                                           UIImageView *iv,
                                                           UIImage *image,
                                                           BOOL mountedOnPill,
                                                           BOOL isStaticPosterVideo,
                                                           BOOL needsObscuredOverlay,
                                                           ApolloFeedThumbPlayBadgeStyle playStyle) {
    if (!iv) return;
    iv.layer.contentsRect = CGRectMake(0, 0, 1, 1);
    if (!mountedOnPill) {
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.backgroundColor = [UIColor clearColor];
        ApolloFeedThumbRemoveObscuredOverlay(cell);
        return;
    }

    UIView *parent = iv.superview;
    if (!parent) return;
    CGFloat targetW = ApolloFeedThumbRecoveredTargetWidth(cell, parent);
    CGFloat targetH = ApolloFeedThumbRecoveredTargetHeight(targetW, image, isStaticPosterVideo);
    id richMedia = ApolloFeedThumbRichMediaNodeForPillView(cell, parent);
    if (richMedia) {
        ApolloFeedThumbSetPillStretchTarget(richMedia, CGSizeMake(targetW, targetH), cell);
    }

    BOOL aspectFit = ApolloFeedThumbRecoveredShouldAspectFit(image, isStaticPosterVideo);
    iv.contentMode = aspectFit ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleAspectFill;
    iv.backgroundColor = aspectFit ? [UIColor colorWithWhite:0.05 alpha:1.0] : [UIColor clearColor];
    iv.frame = parent.bounds;
    ApolloFeedThumbApplyPlayBadge(cell, parent, needsObscuredOverlay ? ApolloFeedThumbPlayBadgeStyleNone : playStyle);
    ApolloFeedThumbApplyObscuredOverlay(cell, parent, link, needsObscuredOverlay);

    if (ApolloFeedThumbShouldLogStretchProbe()) {
        ApolloLog(@"[FeedThumbs] recovered presentation image=%@ target=%@ mode=%@ obscured=%@",
                  image ? NSStringFromCGSize(image.size) : @"nil",
                  NSStringFromCGSize(CGSizeMake(targetW, targetH)),
                  aspectFit ? @"fit" : @"fill",
                  needsObscuredOverlay ? @"YES" : @"NO");
    }

    __weak UIImageView *weakIV = iv;
    __weak id weakCell = cell;
    __weak RDKLink *weakLink = link;
    ApolloFeedThumbPlayBadgeStyle capturedPlayStyle = playStyle;
    BOOL capturedNeedsOverlay = needsObscuredOverlay;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImageView *strongIV = weakIV;
        id strongCell = weakCell;
        RDKLink *strongLink = weakLink;
        UIView *strongParent = strongIV.superview;
        if (!strongIV || !strongCell || !strongParent) return;
        strongIV.frame = strongParent.bounds;
        ApolloFeedThumbApplyPlayBadge(strongCell, strongParent, capturedNeedsOverlay ? ApolloFeedThumbPlayBadgeStyleNone : capturedPlayStyle);
        ApolloFeedThumbApplyObscuredOverlay(strongCell, strongParent, strongLink, capturedNeedsOverlay);
    });
}

static void ApolloFeedThumbApplyToCell(id cell) {
    if (!cell) return;
    RDKLink *link = ApolloFeedThumbLinkFromCell(cell);
    if (!link) {
        ApolloFeedThumbClearImageOnCell(cell);
        return;
    }

    // Determine mount target up front. If the cell has a real `thumbnailNode`
    // (compact mode, or large-mode with a small icon slot), Apollo's native
    // path renders into that slot, so we only inject when its thumbnailURL is
    // unusable. If the cell has NO thumbnailNode but DOES have a `linkButtonNode`
    // pill (large-mode "stuck pill" case), Apollo locked in the pill at cell
    // construction and won't reconsider \u2014 even if `link.thumbnailURL` later
    // becomes usable, Apollo still shows the pill. So when we're on the pill
    // path, we render unconditionally as long as we can produce ANY usable URL
    // (preferring the native thumbnailURL, falling back to our recovery
    // helper).
    UIView *thumbView = ApolloFeedThumbThumbnailViewFromCell(cell);
    BOOL mountedOnPill = NO;
    UIView *pillView = nil;
    if (!thumbView) {
        pillView = ApolloFeedThumbPillViewFromCell(cell);
        // Diagnostic: per-cell-class one-shot, log when we can't find either
        // mount target so we can see if ivar names need to change for new
        // Apollo builds. Only logs once per Class to avoid log spam.
        if (!pillView) {
            static NSMutableSet<NSString *> *loggedClasses;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{ loggedClasses = [NSMutableSet set]; });
            NSString *clsName = NSStringFromClass(object_getClass(cell));
            BOOL shouldLog = NO;
            @synchronized (loggedClasses) {
                if (![loggedClasses containsObject:clsName]) {
                    [loggedClasses addObject:clsName];
                    shouldLog = YES;
                }
            }
            if (shouldLog) {
                NSMutableArray<NSString *> *ivarNames = [NSMutableArray array];
                Class probe = object_getClass(cell);
                while (probe && [NSStringFromClass(probe) containsString:@"Apollo"]) {
                    unsigned int count = 0;
                    Ivar *ivars = class_copyIvarList(probe, &count);
                    for (unsigned int i = 0; i < count; i++) {
                        const char *n = ivar_getName(ivars[i]);
                        if (n) [ivarNames addObject:[NSString stringWithUTF8String:n]];
                    }
                    if (ivars) free(ivars);
                    probe = class_getSuperclass(probe);
                }
                ApolloLog(@"[FeedThumbs] no mount target on %@ (no thumbnailNode, no pill). ivars=%@",
                          clsName, [ivarNames componentsJoinedByString:@","]);
                // Also dump richMediaNode ivars + class so we can see what
                // child node carries the link pill (and verify our real-media
                // detection isn't tripping for actual pill cells).
                id richMedia = ApolloFeedThumbIvarByName(cell, "richMediaNode");
                if (richMedia) {
                    NSMutableArray<NSString *> *rmIvars = [NSMutableArray array];
                    Class rmProbe = object_getClass(richMedia);
                    NSString *rmCls = NSStringFromClass(rmProbe);
                    while (rmProbe && [NSStringFromClass(rmProbe) containsString:@"Apollo"]) {
                        unsigned int rmc = 0;
                        Ivar *rms = class_copyIvarList(rmProbe, &rmc);
                        for (unsigned int i = 0; i < rmc; i++) {
                            const char *n = ivar_getName(rms[i]);
                            if (n) [rmIvars addObject:[NSString stringWithUTF8String:n]];
                        }
                        if (rms) free(rms);
                        rmProbe = class_getSuperclass(rmProbe);
                    }
                    BOOL realMedia = ApolloFeedThumbRichMediaIsRealMedia(richMedia);
                    ApolloLog(@"[FeedThumbs]   richMediaNode class=%@ realMedia=%@ ivars=%@",
                              rmCls, realMedia ? @"YES" : @"NO",
                              [rmIvars componentsJoinedByString:@","]);
                }
            }
        }
    }

    NSURL *nativeURL = nil;
    @try {
        if ([(id)link respondsToSelector:@selector(thumbnailURL)]) {
            nativeURL = ((NSURL *(*)(id, SEL))objc_msgSend)((id)link, @selector(thumbnailURL));
        }
    } @catch (__unused id e) {}
    BOOL nativeUsable = ApolloFeedThumbURLIsUsable(nativeURL);

    // Compact / thumbnailNode path: defer to Apollo when it has a usable URL.
    if (thumbView && nativeUsable) {
        ApolloFeedThumbClearImageOnCell(cell);
        return;
    }

    BOOL preferHighQualityFallback = (pillView != nil);
    NSString *source = nil;
    NSURL *fallbackURL = ApolloFeedThumbFallbackURLForLink(link, preferHighQualityFallback, &source);

    // Pill path: prefer the native thumbnailURL when usable (Apollo just
    // isn't rendering it); otherwise use the recovered URL. Only mount on
    // the pill when the URL points at a host whose image represents the
    // post content (Reddit/imgur/ytimg). External link previews keep their
    // native pill so we don't paint over legitimate external link cards.
    NSURL *renderURL = nil;
    if (pillView) {
        NSURL *candidate = fallbackURL ?: (nativeUsable ? nativeURL : nil);
        if (ApolloFeedThumbURLIsPillCoverable(candidate)) {
            thumbView = pillView;
            renderURL = candidate;
            mountedOnPill = YES;
            if (!source) source = nativeUsable ? @"pillThumbnailURL" : @"pillFallback";
            ApolloLog(@"[FeedThumbs] pill mount candidate r/%@ url=%@ src=%@",
                      ({ NSString *_s = nil; @try { _s = link.subreddit; } @catch (__unused id e) {} _s ?: @"?"; }),
                      candidate.absoluteString ?: @"nil", source);
        } else if (candidate) {
            ApolloLog(@"[FeedThumbs] pill skipped (host not coverable) r/%@ url=%@",
                      ({ NSString *_s = nil; @try { _s = link.subreddit; } @catch (__unused id e) {} _s ?: @"?"; }),
                      candidate.absoluteString ?: @"nil");
        }
    } else {
        renderURL = fallbackURL;
    }

    if (!renderURL) {
        ApolloFeedThumbClearImageOnCell(cell);
        return;
    }
    if (!thumbView) {
        // Cell doesn't render a thumbnail slot we can mount on (text/discussion
        // post, or large-mode external pill we shouldn't cover). Clear any
        // stale state in case this cell was previously reused with media.
        ApolloFeedThumbClearImageOnCell(cell);
        return;
    }
    // Downstream code (cell-reuse cache key, image-load completion handler)
    // uses `fallbackURL` as the canonical URL identifier. Repoint it at the
    // chosen render URL so the cache key reflects what we actually loaded.
    fallbackURL = renderURL;

    // If we previously mounted on the pill but this cell now has a real
    // thumbnailNode (cell reuse / reconfiguration), restore the pill's
    // hidden subviews on the OLD pill view first.
    NSNumber *wasMountedOnPillNumber = objc_getAssociatedObject(cell, kFeedThumbMountedOnPillKey);
    BOOL wasMountedOnPill = wasMountedOnPillNumber.boolValue;
    if (wasMountedOnPill && !mountedOnPill) {
        ApolloFeedThumbRestorePillSiblings(cell);
    }
    objc_setAssociatedObject(cell, kFeedThumbMountedOnPillKey,
                             mountedOnPill ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Pill stretch: when mounted on richMediaNode's pill slot, force it to
    // a proper image-card height (~16:9 of the available cell width). When
    // not in pill mode, ensure stretch is cleared in case this richMediaNode
    // was previously stretched on a reused cell. The actual relayout call is
    // dispatched async inside the helper to avoid re-entrant transitions.
    {
        id richMediaForStretch = nil;
        if (mountedOnPill) {
            // pillView is richMediaNode.view (or crosspost richMedia.view).
            // Re-derive the node by checking both candidates.
            id rm = ApolloFeedThumbIvarByName(cell, "richMediaNode");
            if (rm) {
                @try {
                    UIView *rmView = [(id)rm respondsToSelector:@selector(view)]
                                     ? ((UIView *(*)(id, SEL))objc_msgSend)(rm, @selector(view)) : nil;
                    if (rmView == pillView) richMediaForStretch = rm;
                } @catch (__unused id e) {}
            }
            if (!richMediaForStretch) {
                id cross = ApolloFeedThumbIvarByName(cell, "crosspostNode");
                id rmx = cross ? ApolloFeedThumbIvarByName(cross, "richMediaNode") : nil;
                if (rmx) {
                    @try {
                        UIView *rmxView = [(id)rmx respondsToSelector:@selector(view)]
                                          ? ((UIView *(*)(id, SEL))objc_msgSend)(rmx, @selector(view)) : nil;
                        if (rmxView == pillView) richMediaForStretch = rmx;
                    } @catch (__unused id e) {}
                }
            }
        }
        if (richMediaForStretch) {
            CGFloat targetW = ApolloFeedThumbRecoveredTargetWidth(cell, pillView);
            CGFloat targetH = ApolloFeedThumbRecoveredTargetHeight(targetW, nil, NO);
            ApolloFeedThumbSetPillStretchTarget(richMediaForStretch, CGSizeMake(targetW, targetH), cell);
        } else {
            // Not on pill — clear stretch on both candidates if previously set.
            id rm = ApolloFeedThumbIvarByName(cell, "richMediaNode");
            if (rm && !CGSizeEqualToSize(ApolloFeedThumbPillStretchTargetGet(rm), CGSizeZero)) {
                ApolloFeedThumbSetPillStretchTarget(rm, CGSizeZero, cell);
            }
            id cross = ApolloFeedThumbIvarByName(cell, "crosspostNode");
            id rmx = cross ? ApolloFeedThumbIvarByName(cross, "richMediaNode") : nil;
            if (rmx && !CGSizeEqualToSize(ApolloFeedThumbPillStretchTargetGet(rmx), CGSizeZero)) {
                ApolloFeedThumbSetPillStretchTarget(rmx, CGSizeZero, cell);
            }
        }
    }

    // Cell reuse / link change detection.
    NSString *linkID = nil;
    @try { linkID = link.fullName; } @catch (__unused id e) {}
    if (linkID.length == 0) linkID = [NSString stringWithFormat:@"%p", link];

    NSString *currentLinkID = objc_getAssociatedObject(cell, kFeedThumbCurrentLinkIDKey);
    NSURL *currentURL = objc_getAssociatedObject(cell, kFeedThumbCurrentURLKey);

    UIImageView *iv = ApolloFeedThumbEnsureImageView(cell, thumbView);

    // Spoiler / NSFW: render with a heavy gaussian blur of the actual image
    // so the spoiler retains color/silhouette hints (frosted-glass look)
    // instead of a flat grey box. The legacy UIVisualEffectView path is
    // hidden if it was previously installed.
    BOOL needsBlur = NO;
    @try {
        if ([(id)link respondsToSelector:@selector(isSpoiler)] && link.isSpoiler) needsBlur = YES;
        if ([(id)link respondsToSelector:@selector(isNSFW)] && link.isNSFW) needsBlur = YES;
    } @catch (__unused id e) {}
    UIVisualEffectView *legacyBlur = objc_getAssociatedObject(cell, kFeedThumbBlurViewKey);
    if (legacyBlur) legacyBlur.hidden = YES;

    BOOL isVideo = ApolloFeedThumbLinkIsVideoPost(link, source);
    BOOL isStaticPosterVideo = ApolloFeedThumbLinkIsStaticPosterVideo(link, source);
    ApolloFeedThumbPlayBadgeStyle playStyle = ApolloFeedThumbPlayBadgeStyleNone;
    if (isVideo) {
        playStyle = (mountedOnPill && isStaticPosterVideo)
                    ? ApolloFeedThumbPlayBadgeStyleLargeCenter
                    : ApolloFeedThumbPlayBadgeStyleCompactCorner;
    }
    ApolloFeedThumbApplyPlayBadge(cell, thumbView, (mountedOnPill && needsBlur) ? ApolloFeedThumbPlayBadgeStyleNone : playStyle);

    // When mounted on the pill, hide the pill's text + leading icon so they
    // don't peek through during the brief image load. Tracked on the cell so
    // ApolloFeedThumbClearImageOnCell can restore them on unmount/cell reuse.
    if (mountedOnPill) {
        UIImageView *badge = objc_getAssociatedObject(cell, kFeedThumbPlayBadgeKey);
        ApolloFeedThumbHidePillSiblings(cell, thumbView, iv, badge);
    }

    if ([currentLinkID isEqualToString:linkID] && [currentURL isEqual:fallbackURL] && iv.image) {
        // Same link, same URL, image already loaded — just resync visibility.
        ApolloFeedThumbApplyRecoveredLargePresentation(cell, link, iv, iv.image,
                                                       mountedOnPill, isStaticPosterVideo,
                                                       mountedOnPill && needsBlur, playStyle);
        iv.hidden = NO;
        return;
    }

    // New link or new URL — cancel any in-flight load and reset.
    NSURLSessionDataTask *oldTask = objc_getAssociatedObject(cell, kFeedThumbCurrentTaskKey);
    [oldTask cancel];
    iv.image = nil;
    iv.layer.contentsRect = CGRectMake(0, 0, 1, 1);
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.backgroundColor = [UIColor clearColor];
    ApolloFeedThumbRemoveObscuredOverlay(cell);
    // Pill mount: keep the imageView hidden until the image actually loads,
    // otherwise we'd briefly show an empty rounded rect over the pill. The
    // pill siblings are also hidden, so the cell shows the cell's background
    // color (matches Apollo's empty-thumbnail loading state).
    iv.hidden = mountedOnPill ? YES : NO;

    objc_setAssociatedObject(cell, kFeedThumbCurrentLinkIDKey, linkID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell, kFeedThumbCurrentURLKey, fallbackURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, kFeedThumbLoadedImageSizeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloFeedThumbLogOnce(link, source, fallbackURL);
    ApolloFeedThumbLogAppliedOnce(cell, link, source);

    __weak UIImageView *weakIV = iv;
    __weak id weakCell = cell;
    NSString *expectedLinkID = linkID;
    NSURL *expectedURL = fallbackURL;
    BOOL captureNeedsBlur = needsBlur;
    BOOL captureMountedOnPill = mountedOnPill;
    BOOL captureIsStaticPosterVideo = isStaticPosterVideo;
    ApolloFeedThumbPlayBadgeStyle capturePlayStyle = playStyle;

    NSURLSessionDataTask *task = [ApolloFeedThumbSharedSession() dataTaskWithURL:fallbackURL completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error || data.length == 0) return;
        UIImage *image = [UIImage imageWithData:data];
        if (!image) return;
        UIImage *finalImage = image;
        if (captureNeedsBlur) {
            UIImage *blurred = ApolloFeedThumbBlurImage(image, expectedURL.absoluteString);
            if (blurred) finalImage = blurred;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImageView *strongIV = weakIV;
            id strongCell = weakCell;
            if (!strongIV || !strongCell) return;
            // Verify the cell still wants this image (no later reuse).
            NSString *nowLinkID = objc_getAssociatedObject(strongCell, kFeedThumbCurrentLinkIDKey);
            NSURL *nowURL = objc_getAssociatedObject(strongCell, kFeedThumbCurrentURLKey);
            if (![nowLinkID isEqualToString:expectedLinkID]) return;
            if (![nowURL isEqual:expectedURL]) return;
            strongIV.image = finalImage;
            objc_setAssociatedObject(strongCell, kFeedThumbLoadedImageSizeKey,
                                     [NSValue valueWithCGSize:image.size],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            RDKLink *currentLink = ApolloFeedThumbLinkFromCell(strongCell);
            ApolloFeedThumbApplyRecoveredLargePresentation(strongCell, currentLink, strongIV, image,
                                                           captureMountedOnPill, captureIsStaticPosterVideo,
                                                           captureMountedOnPill && captureNeedsBlur,
                                                           capturePlayStyle);
            strongIV.hidden = NO;
            if (captureMountedOnPill && ApolloFeedThumbShouldLogStretchProbe()) {
                UIView *parent = strongIV.superview;
                ApolloLog(@"[FeedThumbs] pill image loaded imageSize=%@ ivFrame=%@ ivHidden=%@ superBounds=%@ url=%@",
                          NSStringFromCGSize(finalImage.size),
                          NSStringFromCGRect(strongIV.frame),
                          strongIV.hidden ? @"YES" : @"NO",
                          parent ? NSStringFromCGRect(parent.bounds) : @"nil",
                          expectedURL.absoluteString ?: @"nil");
            }
        });
    }];
    objc_setAssociatedObject(cell, kFeedThumbCurrentTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];
}

// MARK: - Cell hooks

%hook _TtC6Apollo17LargePostCellNode

- (void)didLoad {
    %orig;
    ApolloFeedThumbTrackCell(self);
    ApolloFeedThumbApplyToCell(self);
}

- (void)layout {
    %orig;
    // Layout fast-path: skip work when neither the bound link nor the
    // mount-target size has changed since our last successful apply.
    // ApolloFeedThumbApplyToCell still has its own (URL, image-loaded)
    // early-out, but doing the cheap pointer compare here avoids the ivar
    // walks for `link` / `thumbnailNode` / `richMediaNode` on every layout
    // pass during scrolling. Use whichever target ApolloFeedThumbApplyToCell
    // would actually mount on (thumbnailNode in compact, richMediaNode in
    // large pill mode) so pill cells aren't incorrectly skipped because
    // their thumbnailNode is zero-sized.
    RDKLink *link = ApolloFeedThumbLinkFromCell(self);
    UIView *thumbView = ApolloFeedThumbThumbnailViewFromCell(self);
    if (!thumbView) thumbView = ApolloFeedThumbPillViewFromCell(self);
    CGSize thumbSize = thumbView ? thumbView.bounds.size : CGSizeZero;
    NSValue *lastPtr = objc_getAssociatedObject(self, kFeedThumbLastAppliedLinkPtrKey);
    NSValue *lastSize = objc_getAssociatedObject(self, kFeedThumbLastAppliedSizeKey);
    if (link && lastPtr && [lastPtr pointerValue] == (__bridge void *)link &&
        lastSize && CGSizeEqualToSize([lastSize CGSizeValue], thumbSize)) {
        return;
    }
    ApolloFeedThumbApplyToCell(self);
    if (link) {
        objc_setAssociatedObject(self, kFeedThumbLastAppliedLinkPtrKey,
                                 [NSValue valueWithPointer:(__bridge void *)link],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kFeedThumbLastAppliedSizeKey,
                                 [NSValue valueWithCGSize:thumbSize],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

%hook _TtC6Apollo19CompactPostCellNode

- (void)didLoad {
    %orig;
    ApolloFeedThumbTrackCell(self);
    ApolloFeedThumbApplyToCell(self);
}

- (void)layout {
    %orig;
    RDKLink *link = ApolloFeedThumbLinkFromCell(self);
    UIView *thumbView = ApolloFeedThumbThumbnailViewFromCell(self);
    CGSize thumbSize = thumbView ? thumbView.bounds.size : CGSizeZero;
    NSValue *lastPtr = objc_getAssociatedObject(self, kFeedThumbLastAppliedLinkPtrKey);
    NSValue *lastSize = objc_getAssociatedObject(self, kFeedThumbLastAppliedSizeKey);
    if (link && lastPtr && [lastPtr pointerValue] == (__bridge void *)link &&
        lastSize && CGSizeEqualToSize([lastSize CGSizeValue], thumbSize)) {
        return;
    }
    ApolloFeedThumbApplyToCell(self);
    if (link) {
        objc_setAssociatedObject(self, kFeedThumbLastAppliedLinkPtrKey,
                                 [NSValue valueWithPointer:(__bridge void *)link],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kFeedThumbLastAppliedSizeKey,
                                 [NSValue valueWithCGSize:thumbSize],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

// MARK: - Lazy population (v.redd.it, etc.)
//
// Apollo populates `previewMedia` and `mediaMetadata` AFTER the feed initially
// loads for some media types — most notably v.redd.it, where the cell first
// renders with nil previewMedia (so we can't compute a fallback URL), and only
// after the post details are fetched (e.g. after the user opens the post and
// returns) does previewMedia get set. Hook those setters to broadcast a
// notification; the cell observer reapplies if the mutated link matches.

%hook RDKLink

- (void)setPreviewMedia:(id)previewMedia {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloFeedThumbsLinkUpdatedNotification
                                                        object:nil
                                                      userInfo:@{kApolloFeedThumbsLinkPointerKey: [NSValue valueWithPointer:(__bridge const void *)self]}];
}

- (void)setMediaMetadata:(id)mediaMetadata {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloFeedThumbsLinkUpdatedNotification
                                                        object:nil
                                                      userInfo:@{kApolloFeedThumbsLinkPointerKey: [NSValue valueWithPointer:(__bridge const void *)self]}];
}

%end

// MARK: - Comments header preview-pill suppression
//
// When Reddit returns an empty `thumbnail` for direct image posts, Apollo
// doesn't recognize the post as inline media and renders a generic
// LinkButtonNode pill ("redd.it/<id>.jpeg ›") below the post title in the
// comments view. This is baseline Apollo behavior for any post whose native
// thumbnail handling fails, but those posts are still normal image posts that
// should be shown inline.
//
// Hide that pill when the link's URL is a direct redd.it image, since the
// comments header already renders the actual image inline elsewhere (or, for
// spoiler/NSFW, the native blur tap-to-reveal area).

static BOOL ApolloFeedThumbURLIsDirectRedditImage(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = url.host.lowercaseString;
    NSString *ext = url.pathExtension.lowercaseString;
    if (![host isEqualToString:@"i.redd.it"] && ![host isEqualToString:@"preview.redd.it"]) return NO;
    static NSSet<NSString *> *exts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exts = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];
    });
    return [exts containsObject:ext];
}

static void ApolloFeedThumbHideLinkPillIfRedundant(id headerCell) {
    if (!headerCell) return;
    RDKLink *link = ApolloFeedThumbLinkFromCell(headerCell);
    if (!link) return;
    NSURL *url = nil;
    @try { url = link.URL; } @catch (__unused id e) {}
    if (!ApolloFeedThumbURLIsDirectRedditImage(url)) return;

    // Resolve the link-button ivar exactly once per process. We cache the Ivar
    // pointer so subsequent layouts only do an O(1) `object_getIvar` call
    // instead of walking the superclass chain for each candidate name.
    static Ivar gPillIvar = NULL;
    static dispatch_once_t gPillOnce = 0;
    dispatch_once(&gPillOnce, ^{
        Class cls = object_getClass(headerCell);
        static const char *const kNames[] = {"linkButtonNode", "linkNode", "linkPreviewNode", "linkBubbleNode"};
        Class probe = cls;
        while (probe && !gPillIvar) {
            for (size_t i = 0; i < sizeof(kNames)/sizeof(kNames[0]); i++) {
                Ivar iv = class_getInstanceVariable(probe, kNames[i]);
                if (iv) { gPillIvar = iv; break; }
            }
            probe = class_getSuperclass(probe);
        }
    });
    if (!gPillIvar) return;

    id node = object_getIvar(headerCell, gPillIvar);
    if (!node) return;
    UIView *v = ApolloFeedThumbViewForNode(node);
    if (v && !v.hidden) v.hidden = YES;
    if ([node respondsToSelector:@selector(setHidden:)]) {
        @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setHidden:), YES); } @catch (__unused id e) {}
    }
}

static void ApolloFeedThumbClearCommentsHeaderPoster(id headerCell) {
    UIImageView *iv = objc_getAssociatedObject(headerCell, kFeedThumbHeaderImageViewKey);
    if (iv) {
        iv.image = nil;
        iv.hidden = YES;
        [iv removeFromSuperview];
    }
    UIImageView *badge = objc_getAssociatedObject(headerCell, kFeedThumbHeaderPlayBadgeKey);
    if (badge) {
        badge.hidden = YES;
        [badge removeFromSuperview];
    }
    NSURLSessionDataTask *task = objc_getAssociatedObject(headerCell, kFeedThumbHeaderCurrentTaskKey);
    [task cancel];
    objc_setAssociatedObject(headerCell, kFeedThumbHeaderCurrentTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(headerCell, kFeedThumbHeaderCurrentURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(headerCell, kFeedThumbHeaderCurrentLinkIDKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *ApolloFeedThumbCommentsHeaderPosterTarget(id headerCell) {
    id richMedia = ApolloFeedThumbIvarByName(headerCell, "richMediaNode");
    if (!richMedia) {
        id crosspost = ApolloFeedThumbIvarByName(headerCell, "crosspostNode");
        richMedia = crosspost ? ApolloFeedThumbIvarByName(crosspost, "richMediaNode") : nil;
    }
    if (!richMedia) return nil;

    id thumbnailNode = ApolloFeedThumbIvarByName(richMedia, "thumbnailNode");
    UIView *target = ApolloFeedThumbViewForNode(thumbnailNode);
    if (!target || target.bounds.size.width < 40 || target.bounds.size.height < 40) {
        target = ApolloFeedThumbViewForNode(richMedia);
    }
    if (target.bounds.size.width < 40 || target.bounds.size.height < 40) return nil;
    return target;
}

static UIImageView *ApolloFeedThumbEnsureCommentsHeaderImageView(id headerCell, UIView *parent) {
    UIImageView *iv = objc_getAssociatedObject(headerCell, kFeedThumbHeaderImageViewKey);
    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:parent.bounds];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        iv.backgroundColor = [UIColor clearColor];
        objc_setAssociatedObject(headerCell, kFeedThumbHeaderImageViewKey, iv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (iv.superview != parent) {
        [iv removeFromSuperview];
        [parent addSubview:iv];
    } else {
        [parent bringSubviewToFront:iv];
    }
    iv.frame = parent.bounds;
    return iv;
}

static void ApolloFeedThumbApplyCommentsHeaderPlayBadge(id headerCell, UIView *parent) {
    UIImageView *badge = objc_getAssociatedObject(headerCell, kFeedThumbHeaderPlayBadgeKey);
    if (!badge) {
        badge = [[UIImageView alloc] initWithFrame:CGRectZero];
        badge.userInteractionEnabled = NO;
        badge.contentMode = UIViewContentModeCenter;
        badge.layer.shadowColor = [UIColor blackColor].CGColor;
        objc_setAssociatedObject(headerCell, kFeedThumbHeaderPlayBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloFeedThumbConfigurePlayBadgeImage(badge, ApolloFeedThumbPlayBadgeStyleLargeCenter);
    if (badge.superview != parent) {
        [badge removeFromSuperview];
        [parent addSubview:badge];
    } else {
        [parent bringSubviewToFront:badge];
    }
    CGSize parentSize = parent.bounds.size;
    CGFloat side = MIN(72.0, MAX(58.0, parentSize.height * 0.22));
    badge.layer.cornerRadius = side / 2.0;
    badge.frame = CGRectMake((parentSize.width - side) / 2.0,
                             (parentSize.height - side) / 2.0,
                             side, side);
    badge.hidden = NO;
}

static void ApolloFeedThumbApplyCommentsHeaderPoster(id headerCell) {
    if (!headerCell) return;
    RDKLink *link = ApolloFeedThumbLinkFromCell(headerCell);
    NSURL *linkURL = nil;
    @try { linkURL = link.URL; } @catch (__unused id e) {}
    if (ApolloFeedThumbYouTubeID(linkURL).length == 0) {
        ApolloFeedThumbClearCommentsHeaderPoster(headerCell);
        return;
    }

    NSURL *posterURL = ApolloFeedThumbURLFromDirectLink(link);
    if (!ApolloFeedThumbURLIsUsable(posterURL)) return;
    UIView *target = ApolloFeedThumbCommentsHeaderPosterTarget(headerCell);
    if (!target) return;

    NSString *linkID = nil;
    @try { linkID = link.fullName; } @catch (__unused id e) {}
    if (linkID.length == 0) linkID = [NSString stringWithFormat:@"%p", link];
    NSString *currentLinkID = objc_getAssociatedObject(headerCell, kFeedThumbHeaderCurrentLinkIDKey);
    NSURL *currentURL = objc_getAssociatedObject(headerCell, kFeedThumbHeaderCurrentURLKey);

    UIImageView *iv = ApolloFeedThumbEnsureCommentsHeaderImageView(headerCell, target);
    ApolloFeedThumbApplyCommentsHeaderPlayBadge(headerCell, target);

    if ([currentLinkID isEqualToString:linkID] && [currentURL isEqual:posterURL] && iv.image) {
        iv.hidden = NO;
        return;
    }

    NSURLSessionDataTask *oldTask = objc_getAssociatedObject(headerCell, kFeedThumbHeaderCurrentTaskKey);
    [oldTask cancel];
    iv.image = nil;
    iv.hidden = YES;
    objc_setAssociatedObject(headerCell, kFeedThumbHeaderCurrentLinkIDKey, linkID, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(headerCell, kFeedThumbHeaderCurrentURLKey, posterURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloFeedThumbLogOnce(link, @"commentsHeaderYouTube", posterURL);

    __weak id weakHeader = headerCell;
    __weak UIImageView *weakIV = iv;
    NSString *expectedLinkID = linkID;
    NSURL *expectedURL = posterURL;
    NSURLSessionDataTask *task = [ApolloFeedThumbSharedSession() dataTaskWithURL:posterURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || data.length == 0) return;
        UIImage *image = [UIImage imageWithData:data];
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            id strongHeader = weakHeader;
            UIImageView *strongIV = weakIV;
            if (!strongHeader || !strongIV) return;
            NSString *nowLinkID = objc_getAssociatedObject(strongHeader, kFeedThumbHeaderCurrentLinkIDKey);
            NSURL *nowURL = objc_getAssociatedObject(strongHeader, kFeedThumbHeaderCurrentURLKey);
            if (![nowLinkID isEqualToString:expectedLinkID]) return;
            if (![nowURL isEqual:expectedURL]) return;
            strongIV.image = image;
            strongIV.hidden = NO;
            UIView *parent = strongIV.superview;
            if (parent) ApolloFeedThumbApplyCommentsHeaderPlayBadge(strongHeader, parent);
        });
    }];
    objc_setAssociatedObject(headerCell, kFeedThumbHeaderCurrentTaskKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];
}

static void ApolloFeedThumbScheduleCommentsHeaderPosterRetries(id headerCell) {
    if (!headerCell) return;
    if (objc_getAssociatedObject(headerCell, kFeedThumbHeaderRetryScheduledKey)) return;
    objc_setAssociatedObject(headerCell, kFeedThumbHeaderRetryScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakHeader = headerCell;
    NSTimeInterval delays[] = {0.15, 0.5, 1.0};
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id strongHeader = weakHeader;
            if (strongHeader) ApolloFeedThumbApplyCommentsHeaderPoster(strongHeader);
        });
    }
}

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    ApolloFeedThumbTrackHeader(self);
    ApolloFeedThumbHideLinkPillIfRedundant(self);
    ApolloFeedThumbApplyCommentsHeaderPoster(self);
    ApolloFeedThumbScheduleCommentsHeaderPosterRetries(self);
}

- (void)layout {
    %orig;
    ApolloFeedThumbHideLinkPillIfRedundant(self);
    ApolloFeedThumbApplyCommentsHeaderPoster(self);
}

%end

// MARK: - Comments fresh-open offset guard

static BOOL ApolloFeedThumbShouldLogCommentsOffset(void) {
    static NSUInteger logged = 0;
    static dispatch_semaphore_t lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = dispatch_semaphore_create(1); });
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    BOOL shouldLog = logged < 30;
    if (shouldLog) logged++;
    dispatch_semaphore_signal(lock);
    return shouldLog;
}

static UIScrollView *ApolloFeedThumbFindScrollViewInView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UIScrollView class]]) return (UIScrollView *)view;
    for (UIView *subview in view.subviews) {
        UIScrollView *found = ApolloFeedThumbFindScrollViewInView(subview);
        if (found) return found;
    }
    return nil;
}

static UIScrollView *ApolloFeedThumbScrollViewFromObject(id object) {
    if (!object) return nil;
    if ([object isKindOfClass:[UIScrollView class]]) return (UIScrollView *)object;
    @try {
        if ([object respondsToSelector:@selector(view)]) {
            UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(object, @selector(view));
            UIScrollView *scrollView = ApolloFeedThumbFindScrollViewInView(view);
            if (scrollView) return scrollView;
        }
    } @catch (__unused id e) {}
    if ([object isKindOfClass:[UIView class]]) return ApolloFeedThumbFindScrollViewInView((UIView *)object);
    return nil;
}

static UIScrollView *ApolloFeedThumbCommentsScrollView(id commentsVC) {
    static const char *const kNames[] = {
        "tableView", "collectionView", "scrollView", "tableNode", "collectionNode",
        "commentsTableView", "commentsCollectionView", "node"
    };
    for (size_t i = 0; i < sizeof(kNames) / sizeof(kNames[0]); i++) {
        UIScrollView *scrollView = ApolloFeedThumbScrollViewFromObject(ApolloFeedThumbIvarByName(commentsVC, kNames[i]));
        if (scrollView) return scrollView;
    }
    return ApolloFeedThumbScrollViewFromObject(commentsVC);
}

static BOOL ApolloFeedThumbCommentsVCProbablyHasAnchor(id commentsVC) {
    static const char *const kAnchorNames[] = {
        "comment", "commentID", "commentFullname", "commentFullName", "commentNode",
        "startingComment", "highlightedComment", "scrollToComment", "contextComment",
        "commentPermalink", "initialComment", "focusedComment", "selectedComment"
    };
    for (size_t i = 0; i < sizeof(kAnchorNames) / sizeof(kAnchorNames[0]); i++) {
        id value = ApolloFeedThumbIvarByName(commentsVC, kAnchorNames[i]);
        if (value) return YES;
    }
    return NO;
}

static CGFloat ApolloFeedThumbScrollViewTopY(UIScrollView *scrollView) {
    if (!scrollView) return 0;
    if (@available(iOS 11.0, *)) {
        return -scrollView.adjustedContentInset.top;
    }
    return -scrollView.contentInset.top;
}

static void ApolloFeedThumbLogCommentsOffset(id commentsVC, NSString *phase, UIScrollView *scrollView, BOOL anchored) {
    if (!ApolloFeedThumbShouldLogCommentsOffset()) return;
    RDKLink *link = ApolloFeedThumbLinkFromCell(commentsVC);
    NSString *title = nil;
    NSString *fullName = nil;
    @try { title = link.title; } @catch (__unused id e) {}
    @try { fullName = link.fullName; } @catch (__unused id e) {}
    ApolloLog(@"[FeedThumbs] comments offset %@ y=%.1f top=%.1f inset=%@ adjusted=%@ anchored=%@ title='%@' fullName=%@",
              phase ?: @"?",
              scrollView ? scrollView.contentOffset.y : 0,
              scrollView ? ApolloFeedThumbScrollViewTopY(scrollView) : 0,
              scrollView ? NSStringFromUIEdgeInsets(scrollView.contentInset) : @"nil",
              scrollView ? NSStringFromUIEdgeInsets(scrollView.adjustedContentInset) : @"nil",
              anchored ? @"YES" : @"NO",
              title ?: @"?",
              fullName ?: @"?");
}

static void ApolloFeedThumbScheduleCommentsTopResetIfNeeded(id commentsVC) {
    if (!commentsVC) return;
    if (objc_getAssociatedObject(commentsVC, kFeedThumbCommentsTopResetKey)) return;
    UIScrollView *scrollView = ApolloFeedThumbCommentsScrollView(commentsVC);
    if (!scrollView) return;
    BOOL anchored = ApolloFeedThumbCommentsVCProbablyHasAnchor(commentsVC);
    ApolloFeedThumbLogCommentsOffset(commentsVC, @"viewDidAppear", scrollView, anchored);
    objc_setAssociatedObject(commentsVC, kFeedThumbCommentsInitialOffsetKey, @(scrollView.contentOffset.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(commentsVC, kFeedThumbCommentsTopResetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (anchored) return;

    __weak id weakVC = commentsVC;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongVC = weakVC;
        if (!strongVC) return;
        UIScrollView *strongScroll = ApolloFeedThumbCommentsScrollView(strongVC);
        if (!strongScroll) return;
        if (ApolloFeedThumbCommentsVCProbablyHasAnchor(strongVC)) return;
        NSNumber *initialNumber = objc_getAssociatedObject(strongVC, kFeedThumbCommentsInitialOffsetKey);
        CGFloat initialY = [initialNumber isKindOfClass:[NSNumber class]] ? initialNumber.doubleValue : strongScroll.contentOffset.y;
        CGFloat currentY = strongScroll.contentOffset.y;
        CGFloat topY = ApolloFeedThumbScrollViewTopY(strongScroll);
        ApolloFeedThumbLogCommentsOffset(strongVC, @"delayed", strongScroll, NO);
        if (currentY > topY + 140.0 && fabs(currentY - initialY) < 2.0) {
            [strongScroll setContentOffset:CGPointMake(strongScroll.contentOffset.x, topY) animated:NO];
            ApolloLog(@"[FeedThumbs] comments offset reset to top (from %.1f to %.1f)", currentY, topY);
        }
    });
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIScrollView *scrollView = ApolloFeedThumbCommentsScrollView(self);
    ApolloFeedThumbLogCommentsOffset(self, @"viewWillAppear", scrollView, ApolloFeedThumbCommentsVCProbablyHasAnchor(self));
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloFeedThumbScheduleCommentsTopResetIfNeeded(self);
}

%end

%ctor {
    %init(_TtC6Apollo17LargePostCellNode = objc_getClass("_TtC6Apollo17LargePostCellNode"),
          _TtC6Apollo19CompactPostCellNode = objc_getClass("_TtC6Apollo19CompactPostCellNode"),
          _TtC6Apollo22CommentsHeaderCellNode = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode"),
          _TtC6Apollo22CommentsViewController = objc_getClass("_TtC6Apollo22CommentsViewController"));

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloFeedThumbsLinkUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSValue *ptrValue = note.userInfo[kApolloFeedThumbsLinkPointerKey];
        if (![ptrValue isKindOfClass:[NSValue class]]) return;
        const void *mutatedLinkPtr = [ptrValue pointerValue];
        if (!mutatedLinkPtr) return;

        NSArray *cells = nil;
        @synchronized (ApolloFeedThumbTrackedCells()) {
            cells = [[ApolloFeedThumbTrackedCells() allObjects] copy];
        }
        for (id cell in cells) {
            RDKLink *cellLink = ApolloFeedThumbLinkFromCell(cell);
            if ((__bridge const void *)cellLink == mutatedLinkPtr) {
                ApolloFeedThumbApplyToCell(cell);
            }
        }

        NSArray *headers = nil;
        @synchronized (ApolloFeedThumbTrackedHeaders()) {
            headers = [[ApolloFeedThumbTrackedHeaders() allObjects] copy];
        }
        for (id header in headers) {
            RDKLink *headerLink = ApolloFeedThumbLinkFromCell(header);
            if ((__bridge const void *)headerLink == mutatedLinkPtr) {
                ApolloFeedThumbHideLinkPillIfRedundant(header);
                ApolloFeedThumbApplyCommentsHeaderPoster(header);
            }
        }
    }];
}