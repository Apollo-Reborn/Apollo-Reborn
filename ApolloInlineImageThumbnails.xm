#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

typedef struct {
    CGSize min;
    CGSize max;
} ASSizeRange;

@interface ASNetworkImageNode : ASImageNode
@property (nonatomic, strong) NSURL *URL;
@property (nonatomic, weak) id delegate;
@end

static const void *kApolloInlineThumbnailNodesKey = &kApolloInlineThumbnailNodesKey;
static const void *kApolloInlineThumbnailKeyKey = &kApolloInlineThumbnailKeyKey;
static const void *kApolloInlineThumbnailURLKey = &kApolloInlineThumbnailURLKey;
static const void *kApolloInlineCachedURLsKey = &kApolloInlineCachedURLsKey;
static const void *kApolloInlineCachedIdentityKey = &kApolloInlineCachedIdentityKey;
static const void *kApolloInlineCachedKeyKey = &kApolloInlineCachedKeyKey;
static const void *kApolloInlineThumbnailOpenURLKey = &kApolloInlineThumbnailOpenURLKey;
static const void *kApolloInlineOriginalCommentBodyKey = &kApolloInlineOriginalCommentBodyKey;
static const void *kApolloInlineOriginalCommentBodyHTMLKey = &kApolloInlineOriginalCommentBodyHTMLKey;
static const void *kApolloInlineTapGestureAttachedKey = &kApolloInlineTapGestureAttachedKey;
static const void *kApolloInlineLinkButtonSuppressedKey = &kApolloInlineLinkButtonSuppressedKey;
static const void *kApolloInlineCommentImageURLsKey = &kApolloInlineCommentImageURLsKey;
static const void *kApolloInlineLinkReplacementKeyKey = &kApolloInlineLinkReplacementKeyKey;
static const void *kApolloInlineLinkButtonMatchedURLKey = &kApolloInlineLinkButtonMatchedURLKey;
static const void *kApolloInlineLinkButtonOriginalSubnodesKey = &kApolloInlineLinkButtonOriginalSubnodesKey;
static const void *kApolloInlineLinkButtonTakeoverActiveKey = &kApolloInlineLinkButtonTakeoverActiveKey;
static const void *kApolloInlineThumbnailLinkButtonOwnerKey = &kApolloInlineThumbnailLinkButtonOwnerKey;
static const void *kApolloInlineLinkButtonAspectRatioKey = &kApolloInlineLinkButtonAspectRatioKey;
static const void *kApolloInlineHeaderHiddenLinkButtonsKey = &kApolloInlineHeaderHiddenLinkButtonsKey;
static const void *kApolloInlineCommentTextOriginalKey = &kApolloInlineCommentTextOriginalKey;

static NSRegularExpression *ApolloInlineHTMLHrefRegex;
static NSRegularExpression *ApolloInlinePlainURLRegex;
static CGFloat sApolloInlineScreenWidth = 375.0;
static __weak RDKLink *sApolloInlineVisibleCommentsLink = nil;

static void ApolloInlineCacheURLsForOwner(id ownerNode, NSArray<NSURL *> *urls, NSString *identity, NSString *reason);
static NSArray<NSURL *> *ApolloInlineCachedURLsForOwner(id ownerNode);
static void ApolloInlineInvalidateOwnerLayout(id ownerNode);
static void ApolloInlineSetPreferredSize(id node, CGSize size);
static void ApolloInlineRemoveThumbnailNodes(id ownerNode);

static id ApolloInlineIvarValueByName(id object, const char *name) {
    if (!object || !name) return nil;
    for (Class currentClass = object_getClass(object); currentClass && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        Ivar ivar = class_getInstanceVariable(currentClass, name);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;
        @try { return object_getIvar(object, ivar); }
        @catch (__unused NSException *exception) { return nil; }
    }
    return nil;
}

static RDKLink *ApolloInlineLinkFromHeaderCell(id headerCellNode) {
    Class linkClass = objc_getClass("RDKLink");
    if (!headerCellNode || !linkClass) return nil;

    static const char *candidateNames[] = { "link", "_link", "post", "_post", "rdkLink", "_rdkLink", NULL };
    for (size_t index = 0; candidateNames[index]; index++) {
        id value = ApolloInlineIvarValueByName(headerCellNode, candidateNames[index]);
        if ([value isKindOfClass:linkClass]) return (RDKLink *)value;
    }

    for (Class currentClass = [headerCellNode class]; currentClass && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(currentClass, &count);
        if (!ivars) continue;
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(headerCellNode, ivars[index]); }
            @catch (__unused NSException *exception) { continue; }
            if ([value isKindOfClass:linkClass]) {
                free(ivars);
                return (RDKLink *)value;
            }
        }
        free(ivars);
    }
    return nil;
}

static RDKLink *ApolloInlineLinkFromController(UIViewController *viewController) {
    if (!viewController) return nil;
    Class linkClass = objc_getClass("RDKLink");
    if (!linkClass) return nil;

    static const char *candidateNames[] = { "link", "post", "thing", "currentLink", "currentPost", "_link", "_post", NULL };
    for (Class currentClass = [viewController class]; currentClass && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        for (size_t index = 0; candidateNames[index]; index++) {
            Ivar ivar = class_getInstanceVariable(currentClass, candidateNames[index]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(viewController, ivar); }
            @catch (__unused NSException *exception) { continue; }
            if ([value isKindOfClass:linkClass]) return (RDKLink *)value;
        }
    }

    for (Class currentClass = [viewController class]; currentClass && currentClass != [NSObject class]; currentClass = class_getSuperclass(currentClass)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(currentClass, &count);
        if (!ivars) continue;
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(viewController, ivars[index]); }
            @catch (__unused NSException *exception) { continue; }
            if ([value isKindOfClass:linkClass]) {
                free(ivars);
                return (RDKLink *)value;
            }
        }
        free(ivars);
    }
    return nil;
}

static NSString *ApolloInlineDecodeBasicHTMLEntities(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) return string;
    NSString *decoded = [string stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#x27;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    return decoded;
}

static NSURL *ApolloInlineUnwrappedMediaURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    NSString *host = url.host.lowercaseString ?: @"";
    if (([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) && [url.path isEqualToString:@"/media"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"url"] && item.value.length > 0) {
                NSURL *decodedURL = [NSURL URLWithString:item.value];
                if (decodedURL) return decodedURL;
            }
        }
    }
    return url;
}

// v32.1: master gate covering BOTH inline-image and inline-GIF features.
// `ApolloInlineURLIsSupportedImage` does the per-host gating; this just
// determines whether the takeover/capture pipeline should run at all.
static inline BOOL ApolloInlineAnyInlineFeatureEnabled(void) {
    return sShowInlinePostImageThumbnails;
}

static BOOL ApolloInlineURLIsSupportedImage(NSURL *url) {
    NSURL *unwrappedURL = ApolloInlineUnwrappedMediaURL(url);
    if (![unwrappedURL isKindOfClass:[NSURL class]]) return NO;
    NSString *scheme = unwrappedURL.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;

    NSString *host = unwrappedURL.host.lowercaseString ?: @"";
    NSString *extension = unwrappedURL.pathExtension.lowercaseString ?: @"";
    NSSet<NSString *> *imageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];

    // v32.1: non-Giphy image hosts gated behind `sShowInlinePostImageThumbnails`.
    // Without this gate, turning Image off but leaving GIF on still tried to take
    // over i.redd.it / imgur LinkButtons, OR the master gate elsewhere shut
    // everything down because it only checked the image flag.
    if (sShowInlinePostImageThumbnails) {
        if ([host isEqualToString:@"i.redd.it"] || [host isEqualToString:@"preview.redd.it"]) {
            return extension.length > 0 && [imageExtensions containsObject:extension];
        }
        // v28: also accept bare `redd.it/<id>.<ext>` — Reddit's preview JSON
        // sometimes ships link.URL in this short form (notably r/bleach), and
        // Apollo renders the URL pill that same way. Without this our header
        // pill suppression and comment URL shortening have nothing to match.
        if ([host isEqualToString:@"redd.it"]) {
            return extension.length > 0 && [imageExtensions containsObject:extension];
        }
        if ([host isEqualToString:@"i.imgur.com"]) {
            return [imageExtensions containsObject:extension];
        }
    }
    // v29: Giphy hosts are governed by the same master inline media toggle. Three forms:
    //   - giphy.com/gifs/<id>[-slug]                    (canonicalized below)
    //   - media.giphy.com/media/<id>/giphy.gif          (.gif ext)
    //   - i.giphy.com/<id>.gif / media#.giphy.com/<id>  (.gif ext)
    if (sShowInlinePostImageThumbnails) {
        if ([host isEqualToString:@"giphy.com"] || [host isEqualToString:@"www.giphy.com"]) {
            return [unwrappedURL.path.lowercaseString hasPrefix:@"/gifs/"];
        }
        if ([host hasSuffix:@"giphy.com"]) {
            // i.giphy.com, media.giphy.com, media0/1/2/3/4.giphy.com
            return [extension isEqualToString:@"gif"];
        }
    }
    return NO;
}

static NSURL *ApolloInlineFullSizeURLForImageURL(NSURL *url) {
    NSURL *unwrappedURL = ApolloInlineUnwrappedMediaURL(url);
    if (![unwrappedURL isKindOfClass:[NSURL class]]) return url;
    NSString *host = unwrappedURL.host.lowercaseString ?: @"";
    BOOL isReddit = [host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"i.redd.it"];
    BOOL isGiphy = [host hasSuffix:@"giphy.com"];
    if (!isReddit && !isGiphy) {
        return unwrappedURL;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:unwrappedURL resolvingAgainstBaseURL:NO];
    if (!components) return unwrappedURL;
    components.query = nil;
    components.fragment = nil;
    return components.URL ?: unwrappedURL;
}

static NSURL *ApolloInlineOpenURLForImageURL(NSURL *url) {
    NSURL *unwrappedURL = ApolloInlineUnwrappedMediaURL(url);
    return [unwrappedURL isKindOfClass:[NSURL class]] ? unwrappedURL : url;
}

// v29.1: extract the Giphy ID (e.g. `nVMn04OIW05jkkpDEt`) from any Giphy
// URL form so different filename variants (giphy.gif vs 200w_s.gif vs the
// share-page slug) all compare equal. Returns nil for non-giphy URLs.
static NSString *ApolloInlineGiphyIDFromURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    NSString *host = url.host.lowercaseString ?: @"";
    if (![host hasSuffix:@"giphy.com"]) return nil;
    NSString *path = url.path ?: @"";
    NSString *candidate = nil;
    // media.giphy.com/media/<id>/<filename>  or  i.giphy.com/<id>.gif
    if ([path hasPrefix:@"/media/"]) {
        NSArray<NSString *> *parts = [[path substringFromIndex:[@"/media/" length]] componentsSeparatedByString:@"/"];
        if (parts.count > 0) candidate = parts.firstObject;
    } else if ([path hasPrefix:@"/gifs/"]) {
        NSString *afterPrefix = [path substringFromIndex:[@"/gifs/" length]];
        NSRange lastDash = [afterPrefix rangeOfString:@"-" options:NSBackwardsSearch];
        candidate = (lastDash.location == NSNotFound) ? afterPrefix : [afterPrefix substringFromIndex:lastDash.location + 1];
        NSRange slash = [candidate rangeOfString:@"/"];
        if (slash.location != NSNotFound) candidate = [candidate substringToIndex:slash.location];
    } else if (path.length > 1) {
        // i.giphy.com/<id>.gif — path is `/<id>.gif`
        NSString *firstComp = [[path substringFromIndex:1] componentsSeparatedByString:@"/"].firstObject;
        NSRange dot = [firstComp rangeOfString:@"."];
        candidate = (dot.location == NSNotFound) ? firstComp : [firstComp substringToIndex:dot.location];
    }
    candidate = candidate.lowercaseString;
    if (candidate.length == 0) return nil;
    for (NSUInteger i = 0; i < candidate.length; i++) {
        unichar c = [candidate characterAtIndex:i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return nil;
    }
    return candidate;
}

static BOOL ApolloInlineURLStringsMatch(NSURL *firstURL, NSURL *secondURL) {
    // v29.1: cross-host Giphy equivalence — `giphy.com/gifs/<slug>-<id>`,
    // `media.giphy.com/media/<id>/giphy.gif`, and `i.giphy.com/<id>.gif`
    // all refer to the same GIF and should compare equal.
    NSString *firstGiphyID = ApolloInlineGiphyIDFromURL(firstURL);
    NSString *secondGiphyID = ApolloInlineGiphyIDFromURL(secondURL);
    if (firstGiphyID && secondGiphyID) {
        return [firstGiphyID isEqualToString:secondGiphyID];
    }
    NSURL *first = ApolloInlineFullSizeURLForImageURL(firstURL);
    NSURL *second = ApolloInlineFullSizeURLForImageURL(secondURL);
    NSString *firstString = first.absoluteString;
    NSString *secondString = second.absoluteString;
    return firstString.length > 0 && secondString.length > 0 && [firstString isEqualToString:secondString];
}

static NSURL *ApolloInlineCanonicalImageURLFromString(NSString *candidate) {
    if (![candidate isKindOfClass:[NSString class]] || candidate.length == 0) return nil;
    NSString *decoded = ApolloInlineDecodeBasicHTMLEntities(candidate);
    decoded = [decoded stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([decoded hasSuffix:@")"] || [decoded hasSuffix:@"]"] || [decoded hasSuffix:@"."] || [decoded hasSuffix:@","]) {
        decoded = [decoded substringToIndex:decoded.length - 1];
    }

    NSURL *url = [NSURL URLWithString:decoded];
    if (!url && [decoded hasPrefix:@"//"]) {
        url = [NSURL URLWithString:[@"https:" stringByAppendingString:decoded]];
    }
    NSURL *unwrappedURL = ApolloInlineUnwrappedMediaURL(url);
    // Imgur canonicalization: rewrite `imgur.com/<id>.<ext>` to
    // `i.imgur.com/<id>.<ext>` so direct image links posted without the `i.`
    // host (which Imgur's web UI always serves up) match
    // `ApolloInlineURLIsSupportedImage`'s `i.imgur.com` allowlist.
    if ([unwrappedURL isKindOfClass:[NSURL class]] &&
        [unwrappedURL.host.lowercaseString isEqualToString:@"imgur.com"]) {
        NSString *ext = unwrappedURL.pathExtension.lowercaseString ?: @"";
        NSSet<NSString *> *imageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];
        if ([imageExtensions containsObject:ext]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:unwrappedURL resolvingAgainstBaseURL:NO];
            components.host = @"i.imgur.com";
            NSURL *rewritten = components.URL;
            if ([rewritten isKindOfClass:[NSURL class]]) unwrappedURL = rewritten;
        }
    }
    // v28: rewrite bare `redd.it/<id>.<ext>` to `i.redd.it/<id>.<ext>` so
    // ASNetworkImageNode can load it directly. Reddit's `redd.it` host
    // 302-redirects but Texture's loader doesn't always follow.
    if ([unwrappedURL isKindOfClass:[NSURL class]] &&
        [unwrappedURL.host.lowercaseString isEqualToString:@"redd.it"]) {
        NSString *ext = unwrappedURL.pathExtension.lowercaseString ?: @"";
        NSSet<NSString *> *imageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];
        if ([imageExtensions containsObject:ext]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:unwrappedURL resolvingAgainstBaseURL:NO];
            components.host = @"i.redd.it";
            NSURL *rewritten = components.URL;
            if ([rewritten isKindOfClass:[NSURL class]]) unwrappedURL = rewritten;
        }
    }
    // v29: rewrite Giphy share URLs `giphy.com/gifs/<id>[-slug]` to
    // `i.giphy.com/<id>.gif` (smallest direct-loadable GIF). Only when the
    // user has opted into inline GIFs, otherwise leave the URL alone so the
    // existing pill renderer keeps showing it.
    if (sShowInlinePostImageThumbnails &&
        [unwrappedURL isKindOfClass:[NSURL class]]) {
        NSString *giphyHost = unwrappedURL.host.lowercaseString ?: @"";
        if (([giphyHost isEqualToString:@"giphy.com"] || [giphyHost isEqualToString:@"www.giphy.com"]) &&
            [unwrappedURL.path.lowercaseString hasPrefix:@"/gifs/"]) {
            NSString *afterPrefix = [unwrappedURL.path substringFromIndex:[@"/gifs/" length]];
            // Slug form: `<title-words>-<id>` (Giphy puts the id LAST).
            // Bare form: `<id>`. Take the substring after the LAST `-`.
            NSRange lastDash = [afterPrefix rangeOfString:@"-" options:NSBackwardsSearch];
            NSString *idPart = (lastDash.location == NSNotFound) ? afterPrefix : [afterPrefix substringFromIndex:lastDash.location + 1];
            // Strip any trailing path component (e.g. `/`, `?`, etc.)
            NSRange slash = [idPart rangeOfString:@"/"];
            if (slash.location != NSNotFound) idPart = [idPart substringToIndex:slash.location];
            idPart = idPart.lowercaseString;
            // Giphy IDs are alphanumeric.
            BOOL valid = idPart.length > 0;
            for (NSUInteger i = 0; valid && i < idPart.length; i++) {
                unichar c = [idPart characterAtIndex:i];
                if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) valid = NO;
            }
            if (valid) {
                NSString *direct = [NSString stringWithFormat:@"https://i.giphy.com/%@.gif", idPart];
                NSURL *rewritten = [NSURL URLWithString:direct];
                if ([rewritten isKindOfClass:[NSURL class]]) unwrappedURL = rewritten;
            }
        }
    }
    return ApolloInlineURLIsSupportedImage(unwrappedURL) ? unwrappedURL : nil;
}

static void ApolloInlineAddURLString(NSString *candidate, NSMutableArray<NSURL *> *orderedURLs, NSMutableSet<NSString *> *seenURLs) {
    NSURL *url = ApolloInlineCanonicalImageURLFromString(candidate);
    if (!url) return;
    NSString *key = url.absoluteString;
    if (key.length == 0 || [seenURLs containsObject:key]) return;
    [seenURLs addObject:key];
    [orderedURLs addObject:url];
}

static void ApolloInlineAddURL(NSURL *candidateURL, NSMutableArray<NSURL *> *orderedURLs, NSMutableSet<NSString *> *seenURLs) {
    NSURL *url = ApolloInlineUnwrappedMediaURL(candidateURL);
    if (!ApolloInlineURLIsSupportedImage(url)) return;
    NSString *key = url.absoluteString;
    if (key.length == 0 || [seenURLs containsObject:key]) return;
    [seenURLs addObject:key];
    [orderedURLs addObject:url];
}

static void ApolloInlineAddURLWithReason(NSURL *candidateURL, NSMutableArray<NSURL *> *orderedURLs, NSMutableSet<NSString *> *seenURLs, NSString *reason) {
    NSUInteger previousCount = orderedURLs.count;
    ApolloInlineAddURL(candidateURL, orderedURLs, seenURLs);
    if (orderedURLs.count > previousCount && reason.length > 0) {
        NSURL *url = orderedURLs.lastObject;
        ApolloLog(@"[InlineThumbs] retained %@ image=%@", reason, url.absoluteString ?: @"(nil)");
    }
}

static NSString *ApolloInlineOriginalCommentBody(RDKComment *comment) {
    NSString *original = objc_getAssociatedObject(comment, kApolloInlineOriginalCommentBodyKey);
    return [original isKindOfClass:[NSString class]] ? original : comment.body;
}

static NSString *ApolloInlineOriginalCommentBodyHTML(RDKComment *comment) {
    NSString *original = objc_getAssociatedObject(comment, kApolloInlineOriginalCommentBodyHTMLKey);
    return [original isKindOfClass:[NSString class]] ? original : comment.bodyHTML;
}

static NSArray<NSURL *> *ApolloInlineImageURLsFromText(NSString *text, BOOL html, NSUInteger limit) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || limit == 0) return @[];
    NSMutableArray<NSURL *> *orderedURLs = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];

    NSRegularExpression *regex = html ? ApolloInlineHTMLHrefRegex : ApolloInlinePlainURLRegex;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in matches) {
        NSRange candidateRange = NSMakeRange(NSNotFound, 0);
        if (html) {
            NSRange firstRange = [match rangeAtIndex:1];
            NSRange secondRange = [match rangeAtIndex:2];
            candidateRange = firstRange.location != NSNotFound ? firstRange : secondRange;
        } else {
            candidateRange = match.range;
        }
        if (candidateRange.location == NSNotFound || candidateRange.length == 0) continue;
        NSString *candidate = [text substringWithRange:candidateRange];
        ApolloInlineAddURLString(candidate, orderedURLs, seenURLs);
        if (orderedURLs.count >= limit) break;
    }
    return [orderedURLs copy];
}

static NSArray<NSURL *> *ApolloInlineImageURLsFromLink(RDKLink *link) {
    if (!link) return @[];
    const NSUInteger limit = 6;
    NSMutableArray<NSURL *> *orderedURLs = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];

    NSURL *primaryURL = ApolloInlineUnwrappedMediaURL(link.URL);
    NSURL *previewURL = ApolloInlineUnwrappedMediaURL(link.previewMedia.sourceImage.URL);
    BOOL primaryIsNativeMedia = !link.isSelfPost && ApolloInlineURLIsSupportedImage(primaryURL);
    BOOL previewDuplicatesPrimary = primaryIsNativeMedia && ApolloInlineURLStringsMatch(primaryURL, previewURL);
    BOOL hasNativeMediaMetadata = [link.mediaMetadata isKindOfClass:[NSDictionary class]] && link.mediaMetadata.count > 0;

    if (primaryIsNativeMedia || previewDuplicatesPrimary || hasNativeMediaMetadata) {
        ApolloLog(@"[InlineThumbs] skipping native post media title=%@ primary=%@ preview=%@ mediaMetadata=%@", link.title ?: @"(nil)", primaryURL.absoluteString ?: @"(nil)", previewURL.absoluteString ?: @"(nil)", hasNativeMediaMetadata ? @"yes" : @"no");
    } else {
        ApolloInlineAddURLWithReason(primaryURL, orderedURLs, seenURLs, @"post URL");

        if (orderedURLs.count < limit && previewURL) {
            ApolloInlineAddURLWithReason(previewURL, orderedURLs, seenURLs, @"post preview");
        }
    }

    NSArray<NSURL *> *htmlURLs = ApolloInlineImageURLsFromText(link.selfTextHTML, YES, limit);
    for (NSURL *url in htmlURLs) {
        if (url.absoluteString.length == 0 || [seenURLs containsObject:url.absoluteString]) continue;
        [seenURLs addObject:url.absoluteString];
        [orderedURLs addObject:url];
        ApolloLog(@"[InlineThumbs] retained body html image=%@", url.absoluteString);
    }

    if (orderedURLs.count < limit) {
        NSArray<NSURL *> *plainURLs = ApolloInlineImageURLsFromText(link.selfText, NO, limit - orderedURLs.count);
        for (NSURL *url in plainURLs) {
            if (url.absoluteString.length == 0 || [seenURLs containsObject:url.absoluteString]) continue;
            [seenURLs addObject:url.absoluteString];
            [orderedURLs addObject:url];
            ApolloLog(@"[InlineThumbs] retained body text image=%@", url.absoluteString);
            if (orderedURLs.count >= limit) break;
        }
    }
    return [orderedURLs copy];
}

static RDKComment *ApolloInlineCommentFromCell(id commentCellNode) {
    Class commentClass = objc_getClass("RDKComment");
    if (!commentCellNode || !commentClass) return nil;
    id value = ApolloInlineIvarValueByName(commentCellNode, "comment");
    return [value isKindOfClass:commentClass] ? (RDKComment *)value : nil;
}

static NSArray<NSURL *> *ApolloInlineImageURLsFromComment(RDKComment *comment) {
    if (!comment) return @[];
    NSArray *cachedURLs = objc_getAssociatedObject(comment, kApolloInlineCommentImageURLsKey);
    if ([cachedURLs isKindOfClass:[NSArray class]] && cachedURLs.count > 0) return cachedURLs;

    const NSUInteger limit = 2;
    NSMutableArray<NSURL *> *orderedURLs = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];

    // v29.1: Reddit comments with Giphy attach metadata under
    // `comment.mediaMetadata` keyed `giphy|<id>` — the body itself contains
    // no http URL (just markdown like `![gif](giphy|<id>)`), so the regex
    // scan below would miss it. Synthesize the canonical Giphy URL Apollo's
    // LinkButton actually displays (`media.giphy.com/media/<id>/giphy.gif`)
    // so the LinkButton-matching code can find it. Gated on the master inline
    // image/GIF toggle.
    if (sShowInlinePostImageThumbnails && [(id)comment respondsToSelector:@selector(mediaMetadata)]) {
        NSDictionary *meta = comment.mediaMetadata;
        if ([meta isKindOfClass:[NSDictionary class]]) {
            for (NSString *key in meta) {
                if (orderedURLs.count >= limit) break;
                if (![key isKindOfClass:[NSString class]] || ![key hasPrefix:@"giphy|"]) continue;
                NSString *giphyID = [key substringFromIndex:[@"giphy|" length]];
                NSRange pipe = [giphyID rangeOfString:@"|"];
                if (pipe.location != NSNotFound) giphyID = [giphyID substringToIndex:pipe.location];
                if (giphyID.length == 0) continue;
                NSString *direct = [NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.gif", giphyID];
                NSURL *url = [NSURL URLWithString:direct];
                if (![url isKindOfClass:[NSURL class]]) continue;
                if ([seenURLs containsObject:url.absoluteString]) continue;
                [seenURLs addObject:url.absoluteString];
                [orderedURLs addObject:url];
                ApolloLog(@"[InlineThumbs] giphy from mediaMetadata id=%@ url=%@", giphyID, url.absoluteString);
            }
        }
    }

    NSArray<NSURL *> *htmlURLs = ApolloInlineImageURLsFromText(ApolloInlineOriginalCommentBodyHTML(comment), YES, limit);
    for (NSURL *url in htmlURLs) {
        if (url.absoluteString.length == 0 || [seenURLs containsObject:url.absoluteString]) continue;
        [seenURLs addObject:url.absoluteString];
        [orderedURLs addObject:url];
    }

    if (orderedURLs.count < limit) {
        NSArray<NSURL *> *plainURLs = ApolloInlineImageURLsFromText(ApolloInlineOriginalCommentBody(comment), NO, limit - orderedURLs.count);
        for (NSURL *url in plainURLs) {
            if (url.absoluteString.length == 0 || [seenURLs containsObject:url.absoluteString]) continue;
            [seenURLs addObject:url.absoluteString];
            [orderedURLs addObject:url];
            if (orderedURLs.count >= limit) break;
        }
    }
    NSArray<NSURL *> *finalURLs = [orderedURLs copy];
    if (finalURLs.count > 0) {
        objc_setAssociatedObject(comment, kApolloInlineCommentImageURLsKey, finalURLs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return finalURLs;
}

static BOOL ApolloInlineURLArrayContainsURL(NSArray<NSURL *> *urls, NSURL *candidateURL) {
    for (NSURL *url in urls) {
        if (ApolloInlineURLStringsMatch(url, candidateURL)) return YES;
    }
    return NO;
}

static BOOL ApolloInlineStringContainsImageURL(NSString *text, NSArray<NSURL *> *imageURLs) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || imageURLs.count == 0) return NO;
    NSString *decodedText = ApolloInlineDecodeBasicHTMLEntities(text);
    for (NSURL *url in imageURLs) {
        NSString *absoluteString = url.absoluteString;
        NSString *fullSizeString = ApolloInlineFullSizeURLForImageURL(url).absoluteString;
        if (absoluteString.length > 0 && [decodedText rangeOfString:absoluteString options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if (fullSizeString.length > 0 && [decodedText rangeOfString:fullSizeString options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL ApolloInlineHTMLHasVisibleText(NSString *html) {
    if (![html isKindOfClass:[NSString class]] || html.length == 0) return NO;
    NSRegularExpression *tagRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSString *text = [tagRegex stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0, html.length) withTemplate:@""];
    text = ApolloInlineDecodeBasicHTMLEntities(text);
    text = [[text stringByReplacingOccurrencesOfString:@"\u00a0" withString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return text.length > 0;
}

__attribute__((unused)) static NSString *ApolloInlineStringByRemovingImageURLs(NSString *text, BOOL html, NSArray<NSURL *> *imageURLs) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || imageURLs.count == 0) return text ?: @"";
    NSMutableString *result = [text mutableCopy];

    if (html) {
        NSArray<NSTextCheckingResult *> *matches = [ApolloInlineHTMLHrefRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
        for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
            NSRange candidateRange = NSMakeRange(NSNotFound, 0);
            NSRange firstRange = [match rangeAtIndex:1];
            NSRange secondRange = [match rangeAtIndex:2];
            candidateRange = firstRange.location != NSNotFound ? firstRange : secondRange;
            if (candidateRange.location == NSNotFound || candidateRange.length == 0) continue;
            NSString *candidate = [text substringWithRange:candidateRange];
            NSURL *url = ApolloInlineCanonicalImageURLFromString(candidate);
            if (!url || !ApolloInlineURLArrayContainsURL(imageURLs, url)) continue;

            NSRange removeRange = match.range;
            NSRange searchBeforeRange = NSMakeRange(0, match.range.location);
            NSRange anchorStartRange = [text rangeOfString:@"<a" options:NSBackwardsSearch | NSCaseInsensitiveSearch range:searchBeforeRange];
            if (anchorStartRange.location != NSNotFound) {
                NSRange searchAfterRange = NSMakeRange(NSMaxRange(match.range), text.length - NSMaxRange(match.range));
                NSRange anchorEndRange = [text rangeOfString:@"</a>" options:NSCaseInsensitiveSearch range:searchAfterRange];
                if (anchorEndRange.location != NSNotFound) {
                    removeRange = NSMakeRange(anchorStartRange.location, NSMaxRange(anchorEndRange) - anchorStartRange.location);
                }
            }
            if (NSMaxRange(removeRange) <= result.length) {
                [result replaceCharactersInRange:removeRange withString:@""];
            }
        }
    } else {
        NSArray<NSTextCheckingResult *> *matches = [ApolloInlinePlainURLRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
        for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
            NSString *candidate = [text substringWithRange:match.range];
            NSURL *url = ApolloInlineCanonicalImageURLFromString(candidate);
            if (!url || !ApolloInlineURLArrayContainsURL(imageURLs, url)) continue;
            if (NSMaxRange(match.range) <= result.length) {
                [result replaceCharactersInRange:match.range withString:@""];
            }
        }
    }

    NSString *sanitized = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (html) {
        sanitized = [sanitized stringByReplacingOccurrencesOfString:@"<p></p>" withString:@""];
        sanitized = [sanitized stringByReplacingOccurrencesOfString:@"<p> </p>" withString:@""];
        sanitized = [sanitized stringByReplacingOccurrencesOfString:@"<p>\n</p>" withString:@""];
        sanitized = [sanitized stringByReplacingOccurrencesOfString:@"<div class=\"md\"></div>" withString:@""];
        sanitized = [sanitized stringByReplacingOccurrencesOfString:@"<div class=\"md\">\n</div>" withString:@""];
        sanitized = [sanitized stringByReplacingOccurrencesOfString:@"<div class=\"md\"><p></p></div>" withString:@""];
        sanitized = [sanitized stringByReplacingOccurrencesOfString:@"<div class=\"md\"><p> </p></div>" withString:@""];
        sanitized = [sanitized stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!ApolloInlineHTMLHasVisibleText(sanitized)) return @"";
    }
    return sanitized ?: @"";
}

static NSArray<NSURL *> *ApolloInlinePrepareCommentForInlineImages(id ownerNode, RDKComment *comment, NSString *reason) {
    if (!comment) return @[];
    NSString *originalBody = ApolloInlineOriginalCommentBody(comment);
    NSString *originalBodyHTML = ApolloInlineOriginalCommentBodyHTML(comment);

    if (![objc_getAssociatedObject(comment, kApolloInlineOriginalCommentBodyKey) isKindOfClass:[NSString class]]) {
        objc_setAssociatedObject(comment, kApolloInlineOriginalCommentBodyKey, originalBody ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if (![objc_getAssociatedObject(comment, kApolloInlineOriginalCommentBodyHTMLKey) isKindOfClass:[NSString class]]) {
        objc_setAssociatedObject(comment, kApolloInlineOriginalCommentBodyHTMLKey, originalBodyHTML ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    NSArray<NSURL *> *urls = ApolloInlineImageURLsFromComment(comment);
    if (urls.count == 0) return @[];
    objc_setAssociatedObject(comment, kApolloInlineCommentImageURLsKey, urls, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloLog(@"[InlineThumbs] cached non-mutating comment %@ urls=%lu bodyLen=%lu htmlLen=%lu", reason ?: @"comment", (unsigned long)urls.count, (unsigned long)originalBody.length, (unsigned long)originalBodyHTML.length);
    ApolloInlineCacheURLsForOwner(ownerNode, urls, [NSString stringWithFormat:@"comment|%p|%@", comment, comment.author ?: @""], reason ?: @"comment cached");
    return urls;
}

static BOOL ApolloInlineRestoreOriginalCommentIfNeeded(RDKComment *comment, NSString *reason) {
    if (!comment) return NO;
    NSString *originalBody = objc_getAssociatedObject(comment, kApolloInlineOriginalCommentBodyKey);
    NSString *originalBodyHTML = objc_getAssociatedObject(comment, kApolloInlineOriginalCommentBodyHTMLKey);
    BOOL restored = NO;

    if ([originalBody isKindOfClass:[NSString class]] && ![(comment.body ?: @"") isEqualToString:originalBody]) {
        comment.body = originalBody;
        restored = YES;
    }
    if ([originalBodyHTML isKindOfClass:[NSString class]] && ![(comment.bodyHTML ?: @"") isEqualToString:originalBodyHTML]) {
        comment.bodyHTML = originalBodyHTML;
        restored = YES;
    }
    if (restored) {
        ApolloLog(@"[InlineThumbs] restored original comment bodies reason=%@ author=%@", reason ?: @"feature off", comment.author ?: @"(nil)");
    }
    return restored;
}

static NSString *ApolloInlineURLStringFromPossibleNode(id node) {
    if (!node) return nil;
    SEL selectors[] = { NSSelectorFromString(@"URL"), NSSelectorFromString(@"url"), NSSelectorFromString(@"thumbnailURL"), NSSelectorFromString(@"linkURL"), NSSelectorFromString(@"linkUrl"), NSSelectorFromString(@"destinationURL") };
    for (NSUInteger index = 0; index < sizeof(selectors) / sizeof(SEL); index++) {
        SEL selector = selectors[index];
        if (![node respondsToSelector:selector]) continue;
        id value = nil;
        @try { value = ((id (*)(id, SEL))objc_msgSend)(node, selector); }
        @catch (__unused NSException *exception) { value = nil; }
        if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
        if ([value isKindOfClass:[NSString class]]) return value;
    }
    id value = ApolloInlineIvarValueByName(node, "url") ?: ApolloInlineIvarValueByName(node, "_url") ?: ApolloInlineIvarValueByName(node, "URL") ?: ApolloInlineIvarValueByName(node, "_URL") ?: ApolloInlineIvarValueByName(node, "thumbnailURL") ?: ApolloInlineIvarValueByName(node, "_thumbnailURL");
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    if ([value isKindOfClass:[NSString class]]) return value;
    return nil;
}

static NSString *ApolloInlineTextFromPossibleTextNode(id node) {
    if (!node) return nil;
    SEL selectors[] = { NSSelectorFromString(@"attributedText"), NSSelectorFromString(@"text") };
    for (NSUInteger index = 0; index < sizeof(selectors) / sizeof(SEL); index++) {
        SEL selector = selectors[index];
        if (![node respondsToSelector:selector]) continue;
        id value = nil;
        @try { value = ((id (*)(id, SEL))objc_msgSend)(node, selector); }
        @catch (__unused NSException *exception) { value = nil; }
        if ([value isKindOfClass:[NSAttributedString class]]) return [(NSAttributedString *)value string];
        if ([value isKindOfClass:[NSString class]]) return value;
    }
    return nil;
}

// v30: Pull EVERY URL-shaped property/ivar a `_TtC6Apollo14LinkButtonNode`
// might expose, so the takeover matcher can try each one. For Giphy
// previews, Apollo's `url` is often the giphy.com SHARE link
// (`giphy.com/gifs/<id>`) while the actual playable GIF lives on the
// `thumbnailURL` property (`media.giphy.com/media/<id>/...`). Earlier code
// only checked `url`, so giphy LinkButtons silently failed to match the
// cached comment URLs.
static NSArray<NSString *> *ApolloInlineCandidateURLStringsFromLinkButtonNode(id linkButtonNode) {
    if (!linkButtonNode) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    SEL selectors[] = {
        NSSelectorFromString(@"url"),
        NSSelectorFromString(@"URL"),
        NSSelectorFromString(@"thumbnailURL"),
        NSSelectorFromString(@"linkURL"),
        NSSelectorFromString(@"linkUrl"),
        NSSelectorFromString(@"destinationURL")
    };
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(SEL); i++) {
        SEL sel = selectors[i];
        if (![linkButtonNode respondsToSelector:sel]) continue;
        id value = nil;
        @try { value = ((id (*)(id, SEL))objc_msgSend)(linkButtonNode, sel); }
        @catch (__unused NSException *exception) { value = nil; }
        NSString *candidate = nil;
        if ([value isKindOfClass:[NSURL class]]) candidate = [(NSURL *)value absoluteString];
        else if ([value isKindOfClass:[NSString class]]) candidate = (NSString *)value;
        if (candidate.length > 0 && ![seen containsObject:candidate]) {
            [seen addObject:candidate];
            [out addObject:candidate];
        }
    }

    static const char *ivarNames[] = {
        "url", "_url", "URL", "_URL",
        "thumbnailURL", "_thumbnailURL",
        "linkURL", "_linkURL", "linkUrl", "_linkUrl",
        "destinationURL", "_destinationURL",
        "originalURL", "_originalURL", NULL
    };
    for (size_t index = 0; ivarNames[index]; index++) {
        id value = ApolloInlineIvarValueByName(linkButtonNode, ivarNames[index]);
        NSString *candidate = nil;
        if ([value isKindOfClass:[NSURL class]]) candidate = [(NSURL *)value absoluteString];
        else if ([value isKindOfClass:[NSString class]]) candidate = (NSString *)value;
        if (candidate.length > 0 && ![seen containsObject:candidate]) {
            [seen addObject:candidate];
            [out addObject:candidate];
        }
    }
    return [out copy];
}

static NSString *ApolloInlineURLStringFromLinkButtonNode(id linkButtonNode) {
    // Prefer the model URL (getter or ivar). The text-node fallback can be
    // unreliable: Apollo abbreviates the displayed URL ("preview.redd.it/9zcn1k…"
    // in the screenshots), and earlier code also cleared the urlTextNode while
    // the LinkButton was being replaced. The model URL is the source of truth.
    NSString *urlString = ApolloInlineURLStringFromPossibleNode(linkButtonNode);
    if (urlString.length > 0) return urlString;

    static const char *ivarNames[] = {
        "url", "_url", "URL", "_URL", "thumbnailURL", "_thumbnailURL", "linkURL", "_linkURL",
        "linkUrl", "_linkUrl", "destinationURL", "_destinationURL",
        "originalURL", "_originalURL", "link", "_link", NULL
    };
    for (size_t index = 0; ivarNames[index]; index++) {
        id value = ApolloInlineIvarValueByName(linkButtonNode, ivarNames[index]);
        if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
        if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length > 0) return value;
    }

    @try {
        id urlTextNode = ApolloInlineIvarValueByName(linkButtonNode, "urlTextNode") ?: ApolloInlineIvarValueByName(linkButtonNode, "_urlTextNode");
        NSString *text = ApolloInlineTextFromPossibleTextNode(urlTextNode);
        if (text.length > 0) {
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            // Apollo truncates the displayed URL with an ellipsis. Don't trust truncated text as a real URL.
            if ([text rangeOfString:@"…"].location != NSNotFound || [text rangeOfString:@"..."].location != NSNotFound) {
                text = nil;
            }
            if (text.length > 0) {
                if (![text hasPrefix:@"http://"] && ![text hasPrefix:@"https://"]) {
                    text = [@"https://" stringByAppendingString:text];
                }
                return text;
            }
        }
    } @catch (__unused NSException *exception) {
    }

    NSArray *subnodes = nil;
    if ([linkButtonNode respondsToSelector:@selector(subnodes)]) {
        @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(linkButtonNode, @selector(subnodes)); }
        @catch (__unused NSException *exception) { subnodes = nil; }
    }
    for (id subnode in subnodes) {
        NSString *text = ApolloInlineTextFromPossibleTextNode(subnode);
        if (text.length == 0) continue;
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([text rangeOfString:@"…"].location != NSNotFound || [text rangeOfString:@"..."].location != NSNotFound) continue;
        if ([text rangeOfString:@"redd.it" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [text rangeOfString:@"imgur.com" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            continue;
        }
        if (![text hasPrefix:@"http://"] && ![text hasPrefix:@"https://"]) {
            text = [@"https://" stringByAppendingString:text];
        }
        return text;
    }

    return nil;
}

static id ApolloInlineSupernode(id node) {
    if (!node || ![node respondsToSelector:@selector(supernode)]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(node, @selector(supernode)); }
    @catch (__unused NSException *exception) { return nil; }
}

// v31: Walk every descendant text node of `root` and concatenate their text.
// Used to recover URL information from Giphy LinkButtons whose `url` /
// `thumbnailURL` / `URL` getters/ivars all return nil (Apollo only stores
// the URL inside the urlTextNode's attributedText), and whose displayed
// text is truncated with an ellipsis ("media.giphy.com/media/WcYMoQgU…").
static void ApolloInlineCollectDescendantText(id root, NSMutableArray<NSString *> *out, NSUInteger depth) {
    if (!root || depth > 8 || !out) return;
    NSString *text = ApolloInlineTextFromPossibleTextNode(root);
    if (text.length > 0) [out addObject:text];
    NSArray *subnodes = nil;
    if ([root respondsToSelector:@selector(subnodes)]) {
        @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(root, @selector(subnodes)); }
        @catch (__unused NSException *exception) { subnodes = nil; }
    }
    for (id sub in subnodes) {
        ApolloInlineCollectDescendantText(sub, out, depth + 1);
    }
    // Also check NSLinkAttributeName values inside any attributed text — Apollo
    // sometimes stores the canonical URL there even when the visible text is
    // truncated/abbreviated.
    if ([root respondsToSelector:@selector(attributedText)]) {
        NSAttributedString *attr = nil;
        @try { attr = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(root, @selector(attributedText)); }
        @catch (__unused NSException *exception) { attr = nil; }
        if ([attr isKindOfClass:[NSAttributedString class]] && attr.length > 0) {
            [attr enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, attr.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
                if ([value isKindOfClass:[NSURL class]]) {
                    NSString *s = [(NSURL *)value absoluteString];
                    if (s.length > 0) [out addObject:s];
                } else if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length > 0) {
                    [out addObject:(NSString *)value];
                }
            }];
        }
    }
}

// v31: Extract a Giphy ID from any text fragment (truncated or not) of the
// form `media.giphy.com/media/<id>` or `giphy.com/gifs/[slug-]<id>`. Returns
// lowercase alphanumeric id or nil.
static NSString *ApolloInlineGiphyIDFromText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    NSString *lower = text.lowercaseString;
    NSRange media = [lower rangeOfString:@"giphy.com/media/"];
    if (media.location != NSNotFound) {
        NSString *rest = [lower substringFromIndex:NSMaxRange(media)];
        NSMutableString *id_ = [NSMutableString string];
        for (NSUInteger i = 0; i < rest.length; i++) {
            unichar c = [rest characterAtIndex:i];
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
                [id_ appendFormat:@"%C", c];
            } else {
                break;
            }
        }
        if (id_.length >= 5) return [id_ copy];
    }
    NSRange gifs = [lower rangeOfString:@"giphy.com/gifs/"];
    if (gifs.location != NSNotFound) {
        NSString *rest = [lower substringFromIndex:NSMaxRange(gifs)];
        NSRange slash = [rest rangeOfString:@"/"];
        if (slash.location != NSNotFound) rest = [rest substringToIndex:slash.location];
        // After a `-`, last component is the id; before any non-alnum stop.
        NSRange dash = [rest rangeOfString:@"-" options:NSBackwardsSearch];
        NSString *idPart = (dash.location == NSNotFound) ? rest : [rest substringFromIndex:dash.location + 1];
        NSMutableString *id_ = [NSMutableString string];
        for (NSUInteger i = 0; i < idPart.length; i++) {
            unichar c = [idPart characterAtIndex:i];
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
                [id_ appendFormat:@"%C", c];
            } else {
                break;
            }
        }
        if (id_.length >= 5) return [id_ copy];
    }
    return nil;
}

static BOOL ApolloInlineTextLooksTruncated(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    return [text rangeOfString:@"…"].location != NSNotFound || [text rangeOfString:@"..."].location != NSNotFound;
}

static NSURL *ApolloInlineCachedGiphyURLMatchingFragments(NSArray<NSString *> *fragments, NSArray<NSURL *> *cachedURLs, NSString **outMatchedID, NSString **outFragment) {
    if (fragments.count == 0 || cachedURLs.count == 0) return nil;
    for (NSString *fragment in fragments) {
        NSString *fragmentID = ApolloInlineGiphyIDFromText(fragment);
        if (fragmentID.length == 0) continue;
        BOOL truncated = ApolloInlineTextLooksTruncated(fragment);
        for (NSURL *cachedURL in cachedURLs) {
            NSString *cachedID = ApolloInlineGiphyIDFromURL(cachedURL);
            if (cachedID.length == 0) continue;
            BOOL exact = [cachedID isEqualToString:fragmentID];
            BOOL prefix = truncated && fragmentID.length >= 5 && [cachedID hasPrefix:fragmentID];
            if (exact || prefix) {
                if (outMatchedID) *outMatchedID = cachedID;
                if (outFragment) *outFragment = fragment;
                return cachedURL;
            }
        }
    }
    return nil;
}

static NSURL *ApolloInlineSyntheticGiphyURLFromCompleteFragments(NSArray<NSString *> *fragments, NSString **outMatchedID, NSString **outFragment) {
    if (!sShowInlinePostImageThumbnails || fragments.count == 0) return nil;
    for (NSString *fragment in fragments) {
        if (ApolloInlineTextLooksTruncated(fragment)) continue;
        NSString *giphyID = ApolloInlineGiphyIDFromText(fragment);
        if (giphyID.length == 0) continue;
        NSString *direct = [NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.gif", giphyID];
        NSURL *url = [NSURL URLWithString:direct];
        if (!ApolloInlineURLIsSupportedImage(url)) continue;
        if (outMatchedID) *outMatchedID = giphyID;
        if (outFragment) *outFragment = fragment;
        return url;
    }
    return nil;
}

// Walk supernodes looking for a CommentCellNode ancestor. Used to scope
// LinkButton takeover to comment-cell descendants only — without this the
// takeover fires on post-list LinkButtons (gray-placeholder bug in r/bleach
// feed) and on the comments-header URL pill underneath the post image.
static BOOL ApolloInlineNodeHasCommentCellAncestor(id node) {
    id current = node;
    for (NSUInteger depth = 0; current && depth < 32; depth++) {
        NSString *cls = NSStringFromClass([current class]);
        if ([cls rangeOfString:@"CommentCellNode"].location != NSNotFound &&
            [cls rangeOfString:@"HeaderCellNode"].location == NSNotFound) {
            return YES;
        }
        current = ApolloInlineSupernode(current);
    }
    return NO;
}

static id ApolloInlineOwnerWithCachedImageURLsForNode(id node, NSArray<NSURL *> **outURLs) {
    id current = node;
    for (NSUInteger depth = 0; current && depth < 16; depth++) {
        NSArray<NSURL *> *urls = ApolloInlineCachedURLsForOwner(current);
        if (urls.count > 0) {
            if (outURLs) *outURLs = urls;
            return current;
        }
        current = ApolloInlineSupernode(current);
    }
    if (outURLs) *outURLs = nil;
    return nil;
}

static BOOL ApolloInlineLinkButtonMatchesCachedImageURL(id linkButtonNode, NSArray<NSURL *> *imageURLs, NSURL **outURL) {
    // v30: try every candidate URL exposed by the LinkButton. Giphy preview
    // cards expose their playable image on `thumbnailURL` while `url` is the
    // share link, so checking only `url` would silently miss them.
    NSArray<NSString *> *candidates = ApolloInlineCandidateURLStringsFromLinkButtonNode(linkButtonNode);
    if (candidates.count == 0) {
        NSString *fallback = ApolloInlineURLStringFromLinkButtonNode(linkButtonNode);
        if (fallback.length > 0) candidates = @[fallback];
    }
    for (NSString *candidate in candidates) {
        NSURL *url = ApolloInlineCanonicalImageURLFromString(candidate);
        if (!url) {
            NSURL *rawURL = [NSURL URLWithString:candidate];
            if (ApolloInlineURLIsSupportedImage(rawURL)) url = rawURL;
        }
        if (url && ApolloInlineURLArrayContainsURL(imageURLs, url)) {
            if (outURL) *outURL = url;
            return YES;
        }
    }
    if (outURL) *outURL = nil;
    return NO;
}

__attribute__((unused)) static void ApolloInlineCollapseDisplayNode(id node) {
    if (!node) return;
    if ([node respondsToSelector:NSSelectorFromString(@"setHidden:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(node, NSSelectorFromString(@"setHidden:"), YES);
    }
    if ([node respondsToSelector:NSSelectorFromString(@"setAlpha:")]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(node, NSSelectorFromString(@"setAlpha:"), 0.0);
    }
    ApolloInlineSetPreferredSize(node, CGSizeZero);
    if ([node respondsToSelector:@selector(style)]) {
        id style = ((id (*)(id, SEL))objc_msgSend)(node, @selector(style));
        if ([style respondsToSelector:@selector(setMinSize:)]) {
            ((void (*)(id, SEL, CGSize))objc_msgSend)(style, @selector(setMinSize:), CGSizeZero);
        }
        if ([style respondsToSelector:@selector(setMaxSize:)]) {
            ((void (*)(id, SEL, CGSize))objc_msgSend)(style, @selector(setMaxSize:), CGSizeZero);
        }
        if ([style respondsToSelector:@selector(setFlexGrow:)]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(style, @selector(setFlexGrow:), 0.0);
        }
    }
}

__attribute__((unused)) static BOOL ApolloInlineSuppressLinkButtonIfReplacedImage(id linkButtonNode, NSString *reason) {
    if (!linkButtonNode || [objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonSuppressedKey) boolValue]) return NO;
    NSArray<NSURL *> *imageURLs = nil;
    id owner = ApolloInlineOwnerWithCachedImageURLsForNode(linkButtonNode, &imageURLs);
    NSURL *matchedURL = nil;
    if (!owner || !ApolloInlineLinkButtonMatchesCachedImageURL(linkButtonNode, imageURLs, &matchedURL)) return NO;

    objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonSuppressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloInlineInvalidateOwnerLayout(linkButtonNode);
    ApolloInlineInvalidateOwnerLayout(owner);
    ApolloLog(@"[InlineThumbs] scheduled image LinkButton replacement reason=%@ owner=%@ url=%@", reason ?: @"link button", NSStringFromClass([owner class]), matchedURL.absoluteString ?: @"(nil)");
    return YES;
}

__attribute__((unused)) static void ApolloInlineScheduleLinkButtonSuppression(id linkButtonNode, NSString *reason) {
    if (!linkButtonNode) return;
    ApolloInlineSuppressLinkButtonIfReplacedImage(linkButtonNode, reason);
    __weak id weakNode = linkButtonNode;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongNode = weakNode;
        if (strongNode) ApolloInlineSuppressLinkButtonIfReplacedImage(strongNode, [NSString stringWithFormat:@"%@ async", reason ?: @"link button"]);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongNode = weakNode;
        if (strongNode) ApolloInlineSuppressLinkButtonIfReplacedImage(strongNode, [NSString stringWithFormat:@"%@ retry", reason ?: @"link button"]);
    });
}

__attribute__((unused)) static NSUInteger ApolloInlineSuppressNativeImageLinkNodes(id node, NSArray<NSURL *> *imageURLs) {
    if (!node || imageURLs.count == 0) return 0;
    NSUInteger suppressedCount = 0;
    NSString *className = NSStringFromClass([node class]);
    NSString *nodeURLString = ApolloInlineURLStringFromPossibleNode(node);
    NSString *nodeText = ApolloInlineTextFromPossibleTextNode(node);
    BOOL matchesImageURL = ApolloInlineStringContainsImageURL(nodeURLString, imageURLs) || ApolloInlineStringContainsImageURL(nodeText, imageURLs);

    if (matchesImageURL && [className rangeOfString:@"LinkButtonNode"].location != NSNotFound) {
        return 0;
    }

    if (matchesImageURL && ([node respondsToSelector:NSSelectorFromString(@"setAttributedText:")] || [className rangeOfString:@"TextNode"].location != NSNotFound)) {
        if ([node respondsToSelector:NSSelectorFromString(@"setAttributedText:")]) {
            NSAttributedString *emptyText = [[NSAttributedString alloc] initWithString:@""];
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(node, NSSelectorFromString(@"setAttributedText:"), emptyText);
            suppressedCount++;
            ApolloLog(@"[InlineThumbs] cleared native image URL text node=%@", className);
        }
    }

    NSArray *subnodes = nil;
    if ([node respondsToSelector:@selector(subnodes)]) {
        @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(node, @selector(subnodes)); }
        @catch (__unused NSException *exception) { subnodes = nil; }
    }
    for (id subnode in [subnodes copy]) {
        suppressedCount += ApolloInlineSuppressNativeImageLinkNodes(subnode, imageURLs);
    }
    return suppressedCount;
}

static NSString *ApolloInlineURLListKey(NSArray<NSURL *> *urls) {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        if (url.absoluteString.length > 0) [parts addObject:url.absoluteString];
    }
    return [parts componentsJoinedByString:@"|"];
}

static void ApolloInlineInvalidateOwnerLayout(id ownerNode) {
    if (!ownerNode) return;
    if ([ownerNode respondsToSelector:@selector(invalidateCalculatedLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(ownerNode, @selector(invalidateCalculatedLayout));
    }
    if ([ownerNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(ownerNode, @selector(setNeedsLayout));
    }
}

static void ApolloInlineCacheURLsForOwner(id ownerNode, NSArray<NSURL *> *urls, NSString *identity, NSString *reason) {
    if (!ownerNode) return;
    NSString *urlKey = ApolloInlineURLListKey(urls ?: @[]);
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", identity ?: @"", urlKey ?: @""];
    NSString *previousKey = objc_getAssociatedObject(ownerNode, kApolloInlineCachedKeyKey);
    if ([previousKey isEqualToString:cacheKey]) return;

    if (urls.count > 0) {
        objc_setAssociatedObject(ownerNode, kApolloInlineCachedURLsKey, [urls copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(ownerNode, kApolloInlineCachedIdentityKey, identity ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(ownerNode, kApolloInlineCachedKeyKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloLog(@"[InlineThumbs] cached %@ owner=%@ urls=%lu identity=%@", reason ?: @"urls", NSStringFromClass([ownerNode class]), (unsigned long)urls.count, identity ?: @"(nil)");
        for (NSURL *url in urls) ApolloLog(@"[InlineThumbs] cached image=%@", url.absoluteString);
    } else {
        objc_setAssociatedObject(ownerNode, kApolloInlineCachedURLsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(ownerNode, kApolloInlineCachedIdentityKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(ownerNode, kApolloInlineCachedKeyKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    if ([reason rangeOfString:@"layout" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        ApolloInlineInvalidateOwnerLayout(ownerNode);
    }
}

static NSArray<NSURL *> *ApolloInlineCachedURLsForOwner(id ownerNode) {
    NSArray *urls = objc_getAssociatedObject(ownerNode, kApolloInlineCachedURLsKey);
    return [urls isKindOfClass:[NSArray class]] ? urls : nil;
}

static NSString *ApolloInlineCachedIdentityForOwner(id ownerNode) {
    NSString *identity = objc_getAssociatedObject(ownerNode, kApolloInlineCachedIdentityKey);
    return [identity isKindOfClass:[NSString class]] ? identity : nil;
}

static void ApolloInlineCaptureHeaderLink(id headerNode, RDKLink *link, NSString *reason) {
    if (!link) link = sApolloInlineVisibleCommentsLink;
    if (!headerNode || !link) return;
    if (!sShowInlinePostImageThumbnails) {
        ApolloInlineRemoveThumbnailNodes(headerNode);
        ApolloInlineCacheURLsForOwner(headerNode, @[], @"header", reason ?: @"header feature off");
        return;
    }
    NSArray<NSURL *> *urls = ApolloInlineImageURLsFromLink(link);
    NSString *identity = link.fullName.length > 0 ? link.fullName : (link.title ?: @"header");
    ApolloInlineCacheURLsForOwner(headerNode, urls, identity, reason ?: @"header");
}

// Recursively collect every LinkButtonNode descendant of `root` whose
// extracted URL matches one of `imageURLs`. Used to hide the redundant
// `redd.it/<id>.<ext>` URL pill inside the comments header when the post
// itself IS the image (Bleach Soifon / Chad screenshots).
static void ApolloInlineCollectMatchingLinkButtons(id root, NSArray<NSURL *> *imageURLs, NSMutableArray *out) {
    if (!root || imageURLs.count == 0 || !out) return;
    NSArray *subnodes = nil;
    if ([root respondsToSelector:@selector(subnodes)]) {
        @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(root, @selector(subnodes)); }
        @catch (__unused NSException *exception) { subnodes = nil; }
    }
    for (id child in subnodes) {
        NSString *cls = NSStringFromClass([child class]);
        if ([cls rangeOfString:@"LinkButtonNode"].location != NSNotFound) {
            NSURL *matched = nil;
            if (ApolloInlineLinkButtonMatchesCachedImageURL(child, imageURLs, &matched) && matched) {
                [out addObject:child];
                continue; // don't descend further into a matched LinkButton.
            }
        }
        ApolloInlineCollectMatchingLinkButtons(child, imageURLs, out);
    }
}

static void ApolloInlineSuppressHeaderImagePillIfNeeded(id headerNode) {
    if (!headerNode || !sShowInlinePostImageThumbnails) return;
    // Build a suppression URL list that ALWAYS includes the post's primary
    // URL when it's a supported image — `ApolloInlineImageURLsFromLink`
    // intentionally drops it (since the image renders natively at the top)
    // but we still need to MATCH it when hiding the redundant URL pill that
    // Apollo paints under the image.
    NSMutableArray<NSURL *> *suppressionURLs = [NSMutableArray array];
    RDKLink *link = ApolloInlineLinkFromHeaderCell(headerNode) ?: sApolloInlineVisibleCommentsLink;
    if (link) {
        NSURL *primaryURL = ApolloInlineUnwrappedMediaURL(link.URL);
        if (ApolloInlineURLIsSupportedImage(primaryURL)) [suppressionURLs addObject:primaryURL];
        NSURL *previewURL = ApolloInlineUnwrappedMediaURL(link.previewMedia.sourceImage.URL);
        if (ApolloInlineURLIsSupportedImage(previewURL)) [suppressionURLs addObject:previewURL];
    }
    NSArray<NSURL *> *cachedURLs = ApolloInlineCachedURLsForOwner(headerNode);
    for (NSURL *url in cachedURLs) {
        if ([url isKindOfClass:[NSURL class]]) [suppressionURLs addObject:url];
    }
    if (suppressionURLs.count == 0) return;

    NSMutableArray *matching = [NSMutableArray array];
    ApolloInlineCollectMatchingLinkButtons(headerNode, suppressionURLs, matching);
    if (matching.count == 0) return;

    NSHashTable *hidden = objc_getAssociatedObject(headerNode, kApolloInlineHeaderHiddenLinkButtonsKey);
    if (!hidden) {
        hidden = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(headerNode, kApolloInlineHeaderHiddenLinkButtonsKey, hidden, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (id linkButton in matching) {
        if ([hidden containsObject:linkButton]) continue;
        if ([linkButton respondsToSelector:@selector(setHidden:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(linkButton, @selector(setHidden:), YES);
        }
        // Also collapse layout space so the row doesn't reserve room for it.
        if ([linkButton respondsToSelector:@selector(style)]) {
            id style = ((id (*)(id, SEL))objc_msgSend)(linkButton, @selector(style));
            if ([style respondsToSelector:@selector(setPreferredSize:)]) {
                ((void (*)(id, SEL, CGSize))objc_msgSend)(style, @selector(setPreferredSize:), CGSizeZero);
            }
        }
        [hidden addObject:linkButton];
        ApolloLog(@"[InlineThumbs] Header pill hidden cls=%@", NSStringFromClass([linkButton class]));
    }
}

static void ApolloInlineRestoreHeaderImagePills(id headerNode) {
    NSHashTable *hidden = objc_getAssociatedObject(headerNode, kApolloInlineHeaderHiddenLinkButtonsKey);
    if (!hidden) return;
    for (id linkButton in [hidden allObjects]) {
        if ([linkButton respondsToSelector:@selector(setHidden:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(linkButton, @selector(setHidden:), NO);
        }
    }
    objc_setAssociatedObject(headerNode, kApolloInlineHeaderHiddenLinkButtonsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloInlineCaptureComment(id commentNode, RDKComment *comment, NSString *reason) {
    if (!commentNode || !comment) return;
    if (!ApolloInlineAnyInlineFeatureEnabled()) {
        BOOL restored = ApolloInlineRestoreOriginalCommentIfNeeded(comment, reason ?: @"feature off");
        ApolloInlineRemoveThumbnailNodes(commentNode);
        NSString *identity = [NSString stringWithFormat:@"comment|%p|%@", comment, comment.author ?: @""];
        ApolloInlineCacheURLsForOwner(commentNode, @[], identity, reason ?: @"comment feature off");
        if (restored) ApolloInlineInvalidateOwnerLayout(commentNode);
        return;
    }
    NSArray<NSURL *> *urls = ApolloInlinePrepareCommentForInlineImages(commentNode, comment, reason ?: @"comment");
    if (urls.count == 0) {
        NSString *identity = [NSString stringWithFormat:@"comment|%p|%@", comment, comment.author ?: @""];
        ApolloInlineCacheURLsForOwner(commentNode, urls, identity, reason ?: @"comment");
    }
}

static void ApolloInlineSetPreferredSize(id node, CGSize size) {
    if (!node || ![node respondsToSelector:@selector(style)]) return;
    id style = ((id (*)(id, SEL))objc_msgSend)(node, @selector(style));
    if ([style respondsToSelector:@selector(setPreferredSize:)]) {
        ((void (*)(id, SEL, CGSize))objc_msgSend)(style, @selector(setPreferredSize:), size);
    }
    if ([style respondsToSelector:@selector(setFlexShrink:)]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(style, @selector(setFlexShrink:), 0.0);
    }
}

static id ApolloInlineStackSpecWithAlignItems(NSArray *children, CGFloat spacing, NSInteger alignItems) {
    if (children.count == 0) return nil;
    Class stackClass = objc_getClass("ASStackLayoutSpec");
    if (!stackClass) return nil;

    SEL factorySelector = NSSelectorFromString(@"stackLayoutSpecWithDirection:spacing:justifyContent:alignItems:children:");
    if ([stackClass respondsToSelector:factorySelector]) {
        return ((id (*)(id, SEL, NSInteger, CGFloat, NSInteger, NSInteger, NSArray *))objc_msgSend)(stackClass, factorySelector, 1, spacing, 0, alignItems, children);
    }

    SEL verticalSelector = NSSelectorFromString(@"verticalStackLayoutSpec");
    id stack = [stackClass respondsToSelector:verticalSelector] ? ((id (*)(id, SEL))objc_msgSend)(stackClass, verticalSelector) : [[stackClass alloc] init];
    if ([stack respondsToSelector:@selector(setSpacing:)]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(stack, @selector(setSpacing:), spacing);
    }
    if ([stack respondsToSelector:@selector(setChildren:)]) {
        ((void (*)(id, SEL, NSArray *))objc_msgSend)(stack, @selector(setChildren:), children);
    }
    if ([stack respondsToSelector:@selector(setAlignItems:)]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(stack, @selector(setAlignItems:), alignItems);
    }
    return stack;
}

static id ApolloInlineStackSpec(NSArray *children, CGFloat spacing) {
    return ApolloInlineStackSpecWithAlignItems(children, spacing, 0);
}

static id ApolloInlineInsetSpec(UIEdgeInsets insets, id child) {
    if (!child) return nil;
    Class insetClass = objc_getClass("ASInsetLayoutSpec");
    SEL selector = NSSelectorFromString(@"insetLayoutSpecWithInsets:child:");
    if (insetClass && [insetClass respondsToSelector:selector]) {
        return ((id (*)(id, SEL, UIEdgeInsets, id))objc_msgSend)(insetClass, selector, insets, child);
    }
    return child;
}

static NSString *ApolloInlineThumbnailKeyForIdentity(NSString *identity, NSArray<NSURL *> *urls, CGFloat width) {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        if (url.absoluteString.length > 0) [parts addObject:url.absoluteString];
    }
    return [NSString stringWithFormat:@"%@|%.0f|%@", identity ?: @"", width, [parts componentsJoinedByString:@"|"]];
}

static CGSize ApolloInlineThumbnailSizeForOwner(id ownerNode, CGFloat availableWidth) {
    BOOL isComment = [NSStringFromClass([ownerNode class]) rangeOfString:@"CommentCellNode"].location != NSNotFound;
    CGFloat maxWidth = isComment ? 220.0 : 300.0;
    CGFloat minWidth = isComment ? 168.0 : 200.0;
    CGFloat width = floor(MIN(MAX(minWidth, availableWidth * 0.72), MIN(maxWidth, availableWidth)));
    CGFloat height = floor(width * (isComment ? 0.70 : 0.66));
    height = MIN(isComment ? 168.0 : 210.0, MAX(isComment ? 118.0 : 132.0, height));
    return CGSizeMake(width, height);
}

static BOOL ApolloInlineOwnerIsCommentCell(id ownerNode) {
    return [NSStringFromClass([ownerNode class]) rangeOfString:@"CommentCellNode"].location != NSNotFound;
}

static id ApolloInlineBuildThumbnailNode(id ownerNode, NSURL *url, CGSize size) {
    Class networkImageClass = objc_getClass("ASNetworkImageNode");
    if (!networkImageClass) return nil;
    id node = [[networkImageClass alloc] init];
    if (!node) return nil;

    // v29: wire the delegate BEFORE `setURL:`. PINRemoteImage delivers cached
    // images SYNCHRONOUSLY from inside `setURL:`, which means if we set the
    // URL first, the `imageNode:didLoadImage:` callback fires against a
    // delegate-less node and the loaded `image.size` (used to compute the
    // real aspect ratio) is silently dropped — leaving the slot stuck at the
    // 0.625 placeholder until some other layout pass triggers a re-measure
    // (the user-visible "tiny image in oversized gray box until I scroll
    // away and back" bug).
    if (ownerNode && [NSStringFromClass([ownerNode class]) rangeOfString:@"LinkButtonNode"].location != NSNotFound) {
        if ([node respondsToSelector:@selector(setDelegate:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(node, @selector(setDelegate:), ownerNode);
        }
        objc_setAssociatedObject(node, kApolloInlineThumbnailLinkButtonOwnerKey, ownerNode, OBJC_ASSOCIATION_ASSIGN);
    }

    if ([node respondsToSelector:@selector(setURL:)]) {
        ((void (*)(id, SEL, NSURL *))objc_msgSend)(node, @selector(setURL:), url);
    }
    // v29: enable animated GIF playback when the URL is a .gif. PINRemoteImage
    // (which ASNetworkImageNode delegates to) decodes animated GIFs into a
    // multi-frame source; Texture exposes `setAnimatedImagePaused:` and
    // `setShouldAnimate:` to control playback. We probe for both — if neither
    // is present (older Texture build) the node still renders the first frame
    // statically, which is still better than the URL pill.
    if ([url.pathExtension.lowercaseString isEqualToString:@"gif"]) {
        SEL animPausedSel = NSSelectorFromString(@"setAnimatedImagePaused:");
        if ([node respondsToSelector:animPausedSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(node, animPausedSel, NO);
        }
        SEL shouldAnimateSel = NSSelectorFromString(@"setShouldAnimate:");
        if ([node respondsToSelector:shouldAnimateSel]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(node, shouldAnimateSel, YES);
        }
        SEL playOnLoadSel = NSSelectorFromString(@"setAnimatedImageRunLoopMode:");
        if ([node respondsToSelector:playOnLoadSel]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(node, playOnLoadSel, NSRunLoopCommonModes);
        }
    }
    // AspectFit shows the full image scaled down — matches the official Reddit
    // app inline comment image behavior (full image visible, just smaller).
    // AspectFill, which we used in v23/v24/v25, cropped the image to the slot.
    if ([node respondsToSelector:@selector(setContentMode:)]) {
        ((void (*)(id, SEL, UIViewContentMode))objc_msgSend)(node, @selector(setContentMode:), UIViewContentModeScaleAspectFit);
    }
    if ([node respondsToSelector:@selector(setClipsToBounds:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setClipsToBounds:), YES);
    }
    if ([node respondsToSelector:@selector(setBackgroundColor:)]) {
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(node, @selector(setBackgroundColor:), [UIColor secondarySystemBackgroundColor]);
    }
    if ([node respondsToSelector:@selector(layer)]) {
        CALayer *layer = ((CALayer *(*)(id, SEL))objc_msgSend)(node, @selector(layer));
        layer.cornerRadius = 8.0;
        layer.masksToBounds = YES;
    }
    // Wire ASNetworkImageNode delegate to the LinkButton owner so we can
    // resize the slot once the real image dimensions are known.
    // (Delegate is set above, BEFORE setURL:, to catch synchronous
    // cache-hit deliveries — see v29 comment in this function.)
    ApolloInlineSetPreferredSize(node, size);
    objc_setAssociatedObject(node, kApolloInlineThumbnailURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSURL *openURL = ApolloInlineOpenURLForImageURL(url);
    objc_setAssociatedObject(node, kApolloInlineThumbnailOpenURLKey, openURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[InlineThumbs] thumbnail URL image=%@ open=%@", url.absoluteString ?: @"(nil)", openURL.absoluteString ?: @"(nil)");
    return node;
}

static void ApolloInlineAttachTapGestureToThumbnail(id ownerNode, id node) {
    if (!ownerNode || !node || ![node respondsToSelector:@selector(view)]) return;
    if ([objc_getAssociatedObject(node, kApolloInlineTapGestureAttachedKey) boolValue]) return;
    UIView *view = nil;
    @try { view = ((UIView *(*)(id, SEL))objc_msgSend)(node, @selector(view)); }
    @catch (__unused NSException *exception) { view = nil; }
    if (![view isKindOfClass:[UIView class]]) return;
    view.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:ownerNode action:@selector(apollo_inlineImageTapped:)];
    [view addGestureRecognizer:tap];
    objc_setAssociatedObject(view, kApolloInlineThumbnailOpenURLKey, objc_getAssociatedObject(node, kApolloInlineThumbnailOpenURLKey), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, kApolloInlineThumbnailURLKey, objc_getAssociatedObject(node, kApolloInlineThumbnailURLKey), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, kApolloInlineTapGestureAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[InlineThumbs] attached tap gesture node=%@", NSStringFromClass([node class]));
}

static void ApolloInlineRemoveThumbnailNodes(id ownerNode) {
    NSArray *previousNodes = objc_getAssociatedObject(ownerNode, kApolloInlineThumbnailNodesKey);
    for (id node in previousNodes) {
        if ([node respondsToSelector:@selector(removeFromSupernode)]) {
            ((void (*)(id, SEL))objc_msgSend)(node, @selector(removeFromSupernode));
        }
        ApolloInlineSetPreferredSize(node, CGSizeZero);
        objc_setAssociatedObject(node, kApolloInlineThumbnailURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(node, kApolloInlineThumbnailOpenURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(node, kApolloInlineTapGestureAttachedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (previousNodes.count > 0) {
        ApolloLog(@"[InlineThumbs] removed thumbnail nodes owner=%@ count=%lu", NSStringFromClass([ownerNode class]), (unsigned long)previousNodes.count);
    }
    objc_setAssociatedObject(ownerNode, kApolloInlineThumbnailNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ownerNode, kApolloInlineThumbnailKeyKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(ownerNode, kApolloInlineLinkReplacementKeyKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void ApolloInlineShowThumbnailNode(id node, CGSize size) {
    if (!node) return;
    if ([node respondsToSelector:NSSelectorFromString(@"setHidden:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(node, NSSelectorFromString(@"setHidden:"), NO);
    }
    if ([node respondsToSelector:NSSelectorFromString(@"setAlpha:")]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(node, NSSelectorFromString(@"setAlpha:"), 1.0);
    }
    ApolloInlineSetPreferredSize(node, size);
}

static void ApolloInlineEnsureThumbnailSubnodes(id ownerNode, NSArray *nodes) {
    if (!ownerNode || nodes.count == 0 || ![ownerNode respondsToSelector:@selector(addSubnode:)]) return;

    NSArray *subnodes = nil;
    if ([ownerNode respondsToSelector:@selector(subnodes)]) {
        subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(ownerNode, @selector(subnodes));
    }
    NSUInteger beforeCount = subnodes.count;
    NSUInteger addedCount = 0;
    for (id node in nodes) {
        if (!node) continue;
        if (subnodes && [subnodes containsObject:node]) continue;
        ((void (*)(id, SEL, id))objc_msgSend)(ownerNode, @selector(addSubnode:), node);
        ApolloInlineAttachTapGestureToThumbnail(ownerNode, node);
        addedCount++;
    }
    if (addedCount > 0) {
        NSArray *afterSubnodes = [ownerNode respondsToSelector:@selector(subnodes)] ? ((NSArray *(*)(id, SEL))objc_msgSend)(ownerNode, @selector(subnodes)) : nil;
        ApolloLog(@"[InlineThumbs] addSubnode owner=%@ before=%lu added=%lu after=%lu", NSStringFromClass([ownerNode class]), (unsigned long)beforeCount, (unsigned long)addedCount, (unsigned long)afterSubnodes.count);
    }
}

static NSArray *ApolloInlineThumbnailNodesForOwner(id ownerNode, NSString *identity, NSArray<NSURL *> *urls, CGFloat width) {
    if (!ownerNode || urls.count == 0 || width <= 0) return @[];
    BOOL rebuildEveryLayout = NO;
    NSString *key = ApolloInlineThumbnailKeyForIdentity(identity, urls, width);
    NSString *previousKey = objc_getAssociatedObject(ownerNode, kApolloInlineThumbnailKeyKey);
    NSArray *previousNodes = objc_getAssociatedObject(ownerNode, kApolloInlineThumbnailNodesKey);
    CGSize thumbnailSize = ApolloInlineThumbnailSizeForOwner(ownerNode, width);

    if (!rebuildEveryLayout && [previousKey isEqualToString:key] && previousNodes.count == urls.count) {
        for (id node in previousNodes) ApolloInlineShowThumbnailNode(node, thumbnailSize);
        ApolloInlineEnsureThumbnailSubnodes(ownerNode, previousNodes);
        return previousNodes;
    }

    if (previousNodes.count > 0) {
        ApolloLog(@"[InlineThumbs] rebuilding thumbnails owner=%@ count=%lu fresh=%@", NSStringFromClass([ownerNode class]), (unsigned long)previousNodes.count, rebuildEveryLayout ? @"yes" : @"no");
        ApolloInlineRemoveThumbnailNodes(ownerNode);
    }

    NSMutableArray *nodes = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        id node = ApolloInlineBuildThumbnailNode(ownerNode, url, thumbnailSize);
        if (node) [nodes addObject:node];
    }

    NSArray *finalNodes = [nodes copy];
    objc_setAssociatedObject(ownerNode, kApolloInlineThumbnailKeyKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(ownerNode, kApolloInlineThumbnailNodesKey, finalNodes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[InlineThumbs] thumbnail size owner=%@ width=%.0f height=%.0f count=%lu", NSStringFromClass([ownerNode class]), thumbnailSize.width, thumbnailSize.height, (unsigned long)finalNodes.count);
    ApolloInlineEnsureThumbnailSubnodes(ownerNode, finalNodes);
    return finalNodes;
}

static CGFloat ApolloInlineThumbnailWidthForRange(ASSizeRange constrainedSize) {
    CGFloat constrainedWidth = constrainedSize.max.width;
    if (!isfinite(constrainedWidth) || constrainedWidth <= 0 || constrainedWidth > sApolloInlineScreenWidth * 2.0) {
        constrainedWidth = sApolloInlineScreenWidth;
    }
    return floor(MAX(160.0, constrainedWidth - 32.0));
}

static id ApolloInlineCombinedSpec(id ownerNode, id originalSpec, NSArray<NSURL *> *imageURLs, NSString *identity, ASSizeRange constrainedSize) {
    if (!originalSpec || imageURLs.count == 0) {
        ApolloInlineRemoveThumbnailNodes(ownerNode);
        return originalSpec;
    }

    BOOL isComment = ApolloInlineOwnerIsCommentCell(ownerNode);
    if (isComment) return originalSpec;
    UIEdgeInsets thumbnailInsets = isComment ? UIEdgeInsetsMake(8.0, 16.0, 4.0, 16.0) : UIEdgeInsetsMake(8.0, 16.0, 4.0, 16.0);
    CGFloat thumbnailWidth = ApolloInlineThumbnailWidthForRange(constrainedSize) - thumbnailInsets.left - thumbnailInsets.right;
    thumbnailWidth = floor(MAX(160.0, thumbnailWidth));
    NSArray *thumbnailNodes = ApolloInlineThumbnailNodesForOwner(ownerNode, identity, imageURLs, thumbnailWidth);
    if (thumbnailNodes.count == 0) return originalSpec;

    id thumbnailStack = ApolloInlineStackSpecWithAlignItems(thumbnailNodes, 8.0, 1);
    if (!thumbnailStack) return originalSpec;

    if (isComment) {
        ApolloLog(@"[InlineThumbs] comment thumbnail layout width=%.0f inset={%.0f,%.0f,%.0f,%.0f}", thumbnailWidth, thumbnailInsets.top, thumbnailInsets.left, thumbnailInsets.bottom, thumbnailInsets.right);
    }
    id insetThumbnails = ApolloInlineInsetSpec(thumbnailInsets, thumbnailStack);
    id combinedStack = ApolloInlineStackSpec(@[originalSpec, insetThumbnails ?: thumbnailStack], 0.0);
    return combinedStack ?: originalSpec;
}

static NSURL *ApolloInlineMatchedImageURLForLinkButton(id linkButtonNode, id *outOwner) {
    if (!ApolloInlineAnyInlineFeatureEnabled() || !linkButtonNode) return nil;

    // First: trust the cached match. This survives even when Apollo briefly
    // clears or re-resolves the LinkButton's URL/text during display state
    // transitions (e.g. collapse/reopen, scroll-back-into-view).
    NSURL *cachedURL = objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey);
    if ([cachedURL isKindOfClass:[NSURL class]] && ApolloInlineURLIsSupportedImage(cachedURL)) {
        if (outOwner) {
            NSArray<NSURL *> *ownerURLs = nil;
            *outOwner = ApolloInlineOwnerWithCachedImageURLsForNode(linkButtonNode, &ownerURLs);
        }
        return cachedURL;
    }

    NSArray<NSURL *> *imageURLs = nil;
    id owner = ApolloInlineOwnerWithCachedImageURLsForNode(linkButtonNode, &imageURLs);
    NSURL *matchedURL = nil;
    if (owner && ApolloInlineLinkButtonMatchesCachedImageURL(linkButtonNode, imageURLs, &matchedURL)) {
        objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey, matchedURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (outOwner) *outOwner = owner;
        return matchedURL;
    }

    // v31: Giphy LinkButton fallback. Apollo's Giphy preview cards expose
    // NO URL via getter/ivar (count=0 in our diagnostic) AND the displayed
    // urlTextNode is truncated with an ellipsis. So scan every descendant
    // text/link attribute, recover any Giphy id we can find, and match it
    // against the comment cell's cached Giphy URLs (which were synthesized
    // from `comment.mediaMetadata`).
    if (owner && imageURLs.count > 0) {
        NSMutableArray<NSString *> *fragments = [NSMutableArray array];
        ApolloInlineCollectDescendantText(linkButtonNode, fragments, 0);
        NSString *matchedID = nil;
        NSString *matchedFragment = nil;
        NSURL *cachedGiphyURL = ApolloInlineCachedGiphyURLMatchingFragments(fragments, imageURLs, &matchedID, &matchedFragment);
        if (cachedGiphyURL) {
            objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey, cachedGiphyURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (outOwner) *outOwner = owner;
            ApolloLog(@"[InlineThumbs] LinkButton matched via giphy text id=%@ url=%@ frag=%@", matchedID, cachedGiphyURL.absoluteString, matchedFragment);
            return cachedGiphyURL;
        }
    }

    NSString *urlString = ApolloInlineURLStringFromLinkButtonNode(linkButtonNode);
    NSURL *directURL = ApolloInlineCanonicalImageURLFromString(urlString);
    // v30: also try thumbnailURL etc. when the primary URL isn't a supported
    // image — Giphy preview cards rely on this fallback.
    if (!directURL) {
        for (NSString *candidate in ApolloInlineCandidateURLStringsFromLinkButtonNode(linkButtonNode)) {
            directURL = ApolloInlineCanonicalImageURLFromString(candidate);
            if (directURL) break;
        }
    }
    if (!directURL) {
        // v31 last-resort: even without a comment owner, try the descendant
        // text scan and synthesize a Giphy URL, but only from a complete
        // fragment. Visible urlTextNode strings can be ellipsized mid-ID, so
        // truncated fragments must be matched against cached metadata above.
        NSMutableArray<NSString *> *fragments = [NSMutableArray array];
        ApolloInlineCollectDescendantText(linkButtonNode, fragments, 0);
        NSString *matchedID = nil;
        NSString *matchedFragment = nil;
        directURL = ApolloInlineSyntheticGiphyURLFromCompleteFragments(fragments, &matchedID, &matchedFragment);
        if (directURL) {
            ApolloLog(@"[InlineThumbs] LinkButton synthesized giphy url id=%@ frag=%@", matchedID, matchedFragment);
        }
        if (!directURL && owner && imageURLs.count == 1 && urlString.length == 0 && ApolloInlineCandidateURLStringsFromLinkButtonNode(linkButtonNode).count == 0) {
            directURL = imageURLs.firstObject;
            ApolloLog(@"[InlineThumbs] LinkButton using single owner URL fallback url=%@", directURL.absoluteString ?: @"(nil)");
        }
        if (!directURL) return nil;
    }

    id currentNode = linkButtonNode;
    for (NSUInteger depth = 0; currentNode && depth < 16; depth++) {
        NSString *className = NSStringFromClass([currentNode class]);
        if ([className rangeOfString:@"CommentCellNode"].location != NSNotFound || [className rangeOfString:@"CommentsHeaderCellNode"].location != NSNotFound) {
            objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey, directURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (outOwner) *outOwner = currentNode;
            return directURL;
        }
        currentNode = ApolloInlineSupernode(currentNode);
    }

    // Even without finding an explicit owner cell, if the LinkButton itself
    // points at a supported image URL we can still take over. This is what
    // saves us when ASDK creates a fresh LinkButton on collapse/reopen
    // before the comment cell re-runs its capture pass.
    objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey, directURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return directURL;
}

static CGFloat ApolloInlineConstrainedWidthForLinkButton(ASSizeRange constrainedSize) {
    CGFloat constrainedWidth = constrainedSize.max.width;
    if (!isfinite(constrainedWidth) || constrainedWidth <= 0 || constrainedWidth > sApolloInlineScreenWidth * 2.0) {
        constrainedWidth = sApolloInlineScreenWidth - 96.0;
    }
    return floor(MAX(160.0, constrainedWidth));
}

static CGSize ApolloInlineLinkButtonThumbnailSize(id linkButtonNode, CGFloat constrainedWidth) {
    // Match the official Reddit app's inline comment image: full image visible
    // (AspectFit), width = the cell's available width, height = real aspect
    // ratio of the loaded image. Before the image loads we use a 16:10
    // placeholder so the slot is reasonable, then the ASNetworkImageNode
    // delegate (`imageNode:didLoadImage:`) re-runs layout with the real ratio.
    CGFloat width = floor(MAX(160.0, constrainedWidth));
    CGFloat aspect = 0.0;
    if (linkButtonNode) {
        NSNumber *cached = objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonAspectRatioKey);
        if ([cached isKindOfClass:[NSNumber class]]) aspect = cached.doubleValue;
    }
    if (aspect <= 0.0) aspect = 0.625; // 16:10 placeholder until the image loads.
    // Cap super-tall portraits so they don't dominate the thread, but allow
    // up to ~1.6x width (slightly taller than square) to keep the full image
    // visible without forcing a tap-to-expand for normal screenshots.
    CGFloat maxHeight = floor(width * 1.6);
    CGFloat minHeight = 100.0;
    CGFloat height = floor(MIN(maxHeight, MAX(minHeight, width * aspect)));
    return CGSizeMake(width, height);
}

// Snapshot the LinkButton's original subnodes once so we can hide them while
// the takeover is active and restore them on toggle-off / no-match.
static void ApolloInlineCaptureLinkButtonOriginalSubnodes(id linkButtonNode) {
    if (!linkButtonNode) return;
    if (objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonOriginalSubnodesKey)) return;
    NSArray *subnodes = nil;
    if ([linkButtonNode respondsToSelector:@selector(subnodes)]) {
        @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(linkButtonNode, @selector(subnodes)); }
        @catch (__unused NSException *exception) { subnodes = nil; }
    }
    NSArray *snapshot = [subnodes copy] ?: @[];
    objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonOriginalSubnodesKey, snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[InlineThumbs] LinkButton snapshotted %lu native subnodes", (unsigned long)snapshot.count);
}

static void ApolloInlineHideLinkButtonOriginalSubnodes(id linkButtonNode, id thumbnailNode) {
    NSArray *originals = objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonOriginalSubnodesKey);
    NSUInteger hidden = 0;
    for (id node in originals) {
        if (node == thumbnailNode) continue;
        if ([node respondsToSelector:NSSelectorFromString(@"setHidden:")]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(node, NSSelectorFromString(@"setHidden:"), YES);
        }
        if ([node respondsToSelector:NSSelectorFromString(@"setAlpha:")]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(node, NSSelectorFromString(@"setAlpha:"), 0.0);
        }
        ApolloInlineSetPreferredSize(node, CGSizeZero);
        if ([node respondsToSelector:@selector(style)]) {
            id style = ((id (*)(id, SEL))objc_msgSend)(node, @selector(style));
            if ([style respondsToSelector:@selector(setMinSize:)]) {
                ((void (*)(id, SEL, CGSize))objc_msgSend)(style, @selector(setMinSize:), CGSizeZero);
            }
            if ([style respondsToSelector:@selector(setMaxSize:)]) {
                ((void (*)(id, SEL, CGSize))objc_msgSend)(style, @selector(setMaxSize:), CGSizeZero);
            }
        }
        hidden++;
    }
    if (hidden > 0) {
        ApolloLog(@"[InlineThumbs] LinkButton hid %lu native subnodes", (unsigned long)hidden);
    }
}

static void ApolloInlineRestoreLinkButtonOriginalSubnodes(id linkButtonNode) {
    if (!linkButtonNode) return;
    if (![objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonTakeoverActiveKey) boolValue]) return;

    NSArray *originals = objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonOriginalSubnodesKey);
    for (id node in originals) {
        if ([node respondsToSelector:NSSelectorFromString(@"setHidden:")]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(node, NSSelectorFromString(@"setHidden:"), NO);
        }
        if ([node respondsToSelector:NSSelectorFromString(@"setAlpha:")]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(node, NSSelectorFromString(@"setAlpha:"), 1.0);
        }
        // Don't try to restore preferredSize/min/max — Apollo recomputes them
        // from layoutSpecThatFits: when we return %orig.
    }
    ApolloInlineRemoveThumbnailNodes(linkButtonNode);
    objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonTakeoverActiveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloInlineInvalidateOwnerLayout(linkButtonNode);
    ApolloLog(@"[InlineThumbs] LinkButton takeover RESTORED count=%lu", (unsigned long)originals.count);
}

static id ApolloInlineReplacementThumbnailSpecForLinkButton(id linkButtonNode, id ownerNode, NSURL *url, ASSizeRange constrainedSize) {
    if (!linkButtonNode || !url) return nil;

    CGFloat availableWidth = ApolloInlineConstrainedWidthForLinkButton(constrainedSize);
    CGSize thumbnailSize = ApolloInlineLinkButtonThumbnailSize(linkButtonNode, availableWidth);

    // Snapshot the LinkButton's original subnodes BEFORE we ever add our
    // thumbnail, so the snapshot doesn't include our own node.
    ApolloInlineCaptureLinkButtonOriginalSubnodes(linkButtonNode);

    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f", url.absoluteString ?: @"", thumbnailSize.width, thumbnailSize.height];
    NSString *previousKey = objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkReplacementKeyKey);
    NSArray *previousNodes = objc_getAssociatedObject(linkButtonNode, kApolloInlineThumbnailNodesKey);
    id thumbnailNode = previousNodes.count == 1 ? previousNodes.firstObject : nil;

    if (!thumbnailNode || ![previousKey isEqualToString:key]) {
        // Drop only our previous thumbnail (if any), not the LinkButton's
        // native children. ApolloInlineRemoveThumbnailNodes only walks our
        // associated thumbnail array, not subnodes blindly.
        ApolloInlineRemoveThumbnailNodes(linkButtonNode);
        thumbnailNode = ApolloInlineBuildThumbnailNode(linkButtonNode, url, thumbnailSize);
        if (!thumbnailNode) {
            ApolloLog(@"[InlineThumbs] takeover SKIPPED reason=ASNetworkImageNode missing url=%@", url.absoluteString ?: @"(nil)");
            return nil;
        }
        objc_setAssociatedObject(linkButtonNode, kApolloInlineThumbnailNodesKey, @[thumbnailNode], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkReplacementKeyKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloLog(@"[InlineThumbs] takeover BUILT owner=%@ size=%.0fx%.0f url=%@", NSStringFromClass([ownerNode class]), thumbnailSize.width, thumbnailSize.height, url.absoluteString ?: @"(nil)");
    } else {
        ApolloInlineShowThumbnailNode(thumbnailNode, thumbnailSize);
    }

    ApolloInlineEnsureThumbnailSubnodes(linkButtonNode, @[thumbnailNode]);
    // Hide every other (native) subnode under the LinkButton so its
    // background/preview-image/url-text/chevron don't paint over or around
    // our thumbnail with default frames (the v24 "giant zoomed fragment" bug).
    ApolloInlineHideLinkButtonOriginalSubnodes(linkButtonNode, thumbnailNode);
    objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonTakeoverActiveKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloLog(@"[InlineThumbs] takeover SPEC owner=%@ size=%.0fx%.0f url=%@", NSStringFromClass([ownerNode class]), thumbnailSize.width, thumbnailSize.height, url.absoluteString ?: @"(nil)");
    return ApolloInlineInsetSpec(UIEdgeInsetsZero, thumbnailNode) ?: thumbnailNode;
}

static void ApolloInlineHandleImageTap(id sender) {
    id target = sender;
    if ([sender isKindOfClass:[UITapGestureRecognizer class]]) {
        target = [(UITapGestureRecognizer *)sender view];
    }
    NSURL *url = objc_getAssociatedObject(target, kApolloInlineThumbnailOpenURLKey) ?: objc_getAssociatedObject(target, kApolloInlineThumbnailURLKey);
    if (![url isKindOfClass:[NSURL class]]) return;
    ApolloLog(@"[InlineThumbs] Tap url=%@", url.absoluteString);
    if (ApolloRouteResolvedURLViaApolloScheme(url)) {
        ApolloLog(@"[InlineThumbs] Routed tap through Apollo url=%@", url.absoluteString);
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

static void ApolloInlineCompileRegexes(void) {
    ApolloInlineHTMLHrefRegex = [NSRegularExpression regularExpressionWithPattern:@"href\\s*=\\s*(?:\\\"([^\\\"]+)\\\"|'([^']+)')"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    ApolloInlinePlainURLRegex = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\\)\\]\\\"'<>]+"
                                                                            options:NSRegularExpressionCaseInsensitive
                                                                              error:nil];
}

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    ApolloInlineCaptureHeaderLink(self, link, @"header didLoad");
    ApolloInlineSuppressHeaderImagePillIfNeeded(self);
}

- (void)didEnterDisplayState {
    %orig;
    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    ApolloInlineCaptureHeaderLink(self, link, @"header display");
    ApolloInlineSuppressHeaderImagePillIfNeeded(self);
}

- (void)cellNodeVisibilityEvent:(NSInteger)event {
    %orig(event);
    if (event != 0) return;
    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    ApolloInlineCaptureHeaderLink(self, link, @"header visibility");
    ApolloInlineSuppressHeaderImagePillIfNeeded(self);
}

- (id)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    id originalSpec = %orig(constrainedSize);
    if (!sShowInlinePostImageThumbnails || !originalSpec) {
        ApolloInlineRemoveThumbnailNodes(self);
        ApolloInlineRestoreHeaderImagePills(self);
        return originalSpec;
    }

    NSArray<NSURL *> *imageURLs = ApolloInlineCachedURLsForOwner(self);
    NSString *identity = ApolloInlineCachedIdentityForOwner(self) ?: @"header";
    if (imageURLs.count == 0) {
        RDKLink *link = ApolloInlineLinkFromHeaderCell(self) ?: sApolloInlineVisibleCommentsLink;
        imageURLs = ApolloInlineImageURLsFromLink(link);
        identity = link.fullName.length > 0 ? link.fullName : (link.title ?: identity);
    }
    ApolloInlineSuppressHeaderImagePillIfNeeded(self);
    return ApolloInlineCombinedSpec(self, originalSpec, imageURLs, identity, constrainedSize);
}

%new
- (void)apollo_inlineImageTapped:(id)sender {
    id target = sender;
    if ([sender isKindOfClass:[UITapGestureRecognizer class]]) {
        target = [(UITapGestureRecognizer *)sender view];
    }
    NSURL *url = objc_getAssociatedObject(target, kApolloInlineThumbnailOpenURLKey) ?: objc_getAssociatedObject(target, kApolloInlineThumbnailURLKey);
    if (![url isKindOfClass:[NSURL class]]) return;
    ApolloLog(@"[InlineThumbs] Tap url=%@", url.absoluteString);
    if (ApolloRouteResolvedURLViaApolloScheme(url)) {
        ApolloLog(@"[InlineThumbs] Routed tap through Apollo url=%@", url.absoluteString);
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

%end

// Build the short display form of a Reddit image URL: `https://i.redd.it/<id>.<ext>`.
// Returns nil for hosts we don't want to shorten.
static NSString *ApolloInlineShortRedditDisplayString(NSURL *url) {
    NSURL *unwrappedURL = ApolloInlineUnwrappedMediaURL(url);
    if (![unwrappedURL isKindOfClass:[NSURL class]]) return nil;
    NSString *host = unwrappedURL.host.lowercaseString ?: @"";
    if (![host isEqualToString:@"preview.redd.it"] &&
        ![host isEqualToString:@"i.redd.it"] &&
        ![host isEqualToString:@"redd.it"]) return nil;
    NSString *last = unwrappedURL.lastPathComponent;
    if (last.length == 0 || [last isEqualToString:@"/"]) return nil;
    NSString *extension = last.pathExtension.lowercaseString ?: @"";
    NSSet<NSString *> *imageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"webp", @"gif"]];
    if (![imageExtensions containsObject:extension]) return nil;
    return [@"https://i.redd.it/" stringByAppendingString:last];
}

// v32.2: Hide tappable image URLs from the comment body entirely. Earlier
// versions shortened them to `redd.it/<id>.<ext>`; users found that ugly
// next to the inline thumbnail. We now delete the matching link run AND
// any adjacent whitespace/newlines so the body collapses cleanly. The
// original attributedText is stashed for restore on toggle-off.
static void ApolloInlineExpandRangeOverWhitespace(NSMutableAttributedString *str, NSRange *range) {
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *plain = str.string;
    NSUInteger start = range->location;
    NSUInteger end = NSMaxRange(*range);
    while (start > 0) {
        unichar c = [plain characterAtIndex:start - 1];
        if (![ws characterIsMember:c]) break;
        start--;
    }
    while (end < plain.length) {
        unichar c = [plain characterAtIndex:end];
        if (![ws characterIsMember:c]) break;
        end++;
    }
    *range = NSMakeRange(start, end - start);
}

static void ApolloInlineShortenLongImageURLsUnderNode(id root, NSArray<NSURL *> *imageURLs) {
    if (!root || imageURLs.count == 0) return;

    NSArray *subnodes = nil;
    if ([root respondsToSelector:@selector(subnodes)]) {
        @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(root, @selector(subnodes)); }
        @catch (__unused NSException *exception) { subnodes = nil; }
    }
    for (id child in subnodes) {
        NSString *cls = NSStringFromClass([child class]);
        // ASTextNode (or ASEditableTextNode) is what renders comment body text.
        BOOL isText = [cls rangeOfString:@"TextNode"].location != NSNotFound &&
                      [cls rangeOfString:@"LinkButton"].location == NSNotFound;
        if (isText && [child respondsToSelector:@selector(attributedText)]) {
            NSAttributedString *current = nil;
            @try { current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(child, @selector(attributedText)); }
            @catch (__unused NSException *exception) { current = nil; }
            if ([current isKindOfClass:[NSAttributedString class]] && current.length > 0) {
                NSAttributedString *original = objc_getAssociatedObject(child, kApolloInlineCommentTextOriginalKey);
                NSAttributedString *baseline = ([original isKindOfClass:[NSAttributedString class]]) ? original : current;

                NSMutableAttributedString *rebuilt = [baseline mutableCopy];
                __block BOOL changed = NO;
                NSRange fullRange = NSMakeRange(0, rebuilt.length);

                // Pass 1: collect ranges whose NSLinkAttribute value matches one of
                // our image URLs, then mutate after enumeration. Mutating during
                // `enumerateAttribute:` is undefined behavior and was the source
                // of intermittent crashes when toggling the feature mid-render.
                NSMutableArray<NSValue *> *rangesToDelete = [NSMutableArray array];
                [rebuilt enumerateAttribute:NSLinkAttributeName inRange:fullRange options:0 usingBlock:^(id linkValue, NSRange range, BOOL *stop) {
                    NSURL *linkURL = nil;
                    if ([linkValue isKindOfClass:[NSURL class]]) linkURL = (NSURL *)linkValue;
                    else if ([linkValue isKindOfClass:[NSString class]]) linkURL = [NSURL URLWithString:(NSString *)linkValue];
                    if (!linkURL) return;
                    for (NSURL *imgURL in imageURLs) {
                        if (!ApolloInlineURLStringsMatch(linkURL, imgURL)) continue;
                        [rangesToDelete addObject:[NSValue valueWithRange:range]];
                        return;
                    }
                }];
                // Sort descending so each deletion doesn't shift the positions of pending ranges.
                [rangesToDelete sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
                    NSUInteger la = a.rangeValue.location;
                    NSUInteger lb = b.rangeValue.location;
                    if (la == lb) return NSOrderedSame;
                    return la > lb ? NSOrderedAscending : NSOrderedDescending;
                }];
                for (NSValue *value in rangesToDelete) {
                    NSRange deleteRange = value.rangeValue;
                    if (deleteRange.length == 0 || NSMaxRange(deleteRange) > rebuilt.length) continue;
                    ApolloInlineExpandRangeOverWhitespace(rebuilt, &deleteRange);
                    if (deleteRange.length == 0 || NSMaxRange(deleteRange) > rebuilt.length) continue;
                    [rebuilt deleteCharactersInRange:deleteRange];
                    changed = YES;
                }

                // Pass 2: substring fallback (some Apollo text paths plain-text the URL).
                NSString *plain = rebuilt.string;
                for (NSURL *imgURL in imageURLs) {
                    NSString *target = imgURL.absoluteString ?: @"";
                    if (target.length == 0) continue;
                    NSRange searchRange = NSMakeRange(0, plain.length);
                    while (searchRange.location < plain.length) {
                        NSRange found = [plain rangeOfString:target options:NSCaseInsensitiveSearch range:searchRange];
                        if (found.location == NSNotFound) break;
                        NSRange deleteRange = found;
                        ApolloInlineExpandRangeOverWhitespace(rebuilt, &deleteRange);
                        if (deleteRange.length == 0 || NSMaxRange(deleteRange) > rebuilt.length) break;
                        [rebuilt deleteCharactersInRange:deleteRange];
                        changed = YES;
                        plain = rebuilt.string;
                        searchRange = NSMakeRange(deleteRange.location, plain.length - deleteRange.location);
                    }
                }

                if (changed) {
                    if (!objc_getAssociatedObject(child, kApolloInlineCommentTextOriginalKey)) {
                        objc_setAssociatedObject(child, kApolloInlineCommentTextOriginalKey, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    if ([child respondsToSelector:@selector(setAttributedText:)]) {
                        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(child, @selector(setAttributedText:), [rebuilt copy]);
                    }
                }
            }
        }
        // Recurse into all subnodes (including LinkButton — its hidden urlTextNode
        // children are no-op since the attribute pass requires an NSLinkAttributeName,
        // and our hidden takeover children rarely have those anyway).
        ApolloInlineShortenLongImageURLsUnderNode(child, imageURLs);
    }
}

static NSURL *ApolloInlineURLFromLinkValue(id linkValue) {
    if ([linkValue isKindOfClass:[NSURL class]]) return (NSURL *)linkValue;
    if ([linkValue isKindOfClass:[NSString class]]) return [NSURL URLWithString:(NSString *)linkValue];
    return nil;
}

static void ApolloInlineShortenLongRedditURLsForDisplayUnderNode(id root) {
    if (!root) return;

    NSArray *subnodes = nil;
    if ([root respondsToSelector:@selector(subnodes)]) {
        @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(root, @selector(subnodes)); }
        @catch (__unused NSException *exception) { subnodes = nil; }
    }
    for (id child in subnodes) {
        NSString *cls = NSStringFromClass([child class]);
        BOOL isText = [cls rangeOfString:@"TextNode"].location != NSNotFound &&
                      [cls rangeOfString:@"LinkButton"].location == NSNotFound;
        if (isText && [child respondsToSelector:@selector(attributedText)]) {
            NSAttributedString *current = nil;
            @try { current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(child, @selector(attributedText)); }
            @catch (__unused NSException *exception) { current = nil; }
            if ([current isKindOfClass:[NSAttributedString class]] && current.length > 0) {
                NSAttributedString *original = objc_getAssociatedObject(child, kApolloInlineCommentTextOriginalKey);
                NSAttributedString *baseline = ([original isKindOfClass:[NSAttributedString class]]) ? original : current;
                NSMutableAttributedString *rebuilt = [baseline mutableCopy];
                NSMutableArray<NSDictionary *> *replacements = [NSMutableArray array];
                NSRange fullRange = NSMakeRange(0, rebuilt.length);

                [rebuilt enumerateAttribute:NSLinkAttributeName inRange:fullRange options:0 usingBlock:^(id linkValue, NSRange range, BOOL *stop) {
                    NSURL *linkURL = ApolloInlineURLFromLinkValue(linkValue);
                    NSString *shortString = ApolloInlineShortRedditDisplayString(linkURL);
                    if (shortString.length == 0) return;
                    NSString *existing = [rebuilt.string substringWithRange:range];
                    if ([existing isEqualToString:shortString]) return;
                    [replacements addObject:@{@"range": [NSValue valueWithRange:range], @"text": shortString}];
                }];

                [replacements sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    NSUInteger la = [a[@"range"] rangeValue].location;
                    NSUInteger lb = [b[@"range"] rangeValue].location;
                    if (la == lb) return NSOrderedSame;
                    return la > lb ? NSOrderedAscending : NSOrderedDescending;
                }];

                BOOL changed = NO;
                for (NSDictionary *replacementInfo in replacements) {
                    NSRange range = [replacementInfo[@"range"] rangeValue];
                    NSString *shortString = replacementInfo[@"text"];
                    if (range.length == 0 || NSMaxRange(range) > rebuilt.length || shortString.length == 0) continue;
                    NSMutableDictionary *attrs = [[rebuilt attributesAtIndex:range.location effectiveRange:nil] mutableCopy] ?: [NSMutableDictionary dictionary];
                    NSURL *shortURL = [NSURL URLWithString:shortString];
                    if (shortURL) attrs[NSLinkAttributeName] = shortURL;
                    NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:shortString attributes:attrs];
                    [rebuilt replaceCharactersInRange:range withAttributedString:replacement];
                    changed = YES;
                }

                NSString *plain = rebuilt.string;
                NSArray<NSTextCheckingResult *> *matches = [ApolloInlinePlainURLRegex matchesInString:plain options:0 range:NSMakeRange(0, plain.length)];
                for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
                    if (match.range.location == NSNotFound || match.range.length == 0 || NSMaxRange(match.range) > rebuilt.length) continue;
                    NSString *candidate = [plain substringWithRange:match.range];
                    NSString *shortString = ApolloInlineShortRedditDisplayString([NSURL URLWithString:candidate]);
                    if (shortString.length == 0 || [candidate isEqualToString:shortString]) continue;
                    NSMutableDictionary *attrs = [[rebuilt attributesAtIndex:match.range.location effectiveRange:nil] mutableCopy] ?: [NSMutableDictionary dictionary];
                    NSURL *shortURL = [NSURL URLWithString:shortString];
                    if (shortURL) attrs[NSLinkAttributeName] = shortURL;
                    NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:shortString attributes:attrs];
                    [rebuilt replaceCharactersInRange:match.range withAttributedString:replacement];
                    changed = YES;
                }

                if (changed) {
                    if (!objc_getAssociatedObject(child, kApolloInlineCommentTextOriginalKey)) {
                        objc_setAssociatedObject(child, kApolloInlineCommentTextOriginalKey, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    if ([child respondsToSelector:@selector(setAttributedText:)]) {
                        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(child, @selector(setAttributedText:), [rebuilt copy]);
                    }
                }
            }
        }
        ApolloInlineShortenLongRedditURLsForDisplayUnderNode(child);
    }
}

static void ApolloInlineRestoreShortenedURLsUnderNode(id root) {
    if (!root) return;
    NSArray *subnodes = nil;
    if ([root respondsToSelector:@selector(subnodes)]) {
        @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(root, @selector(subnodes)); }
        @catch (__unused NSException *exception) { subnodes = nil; }
    }
    for (id child in subnodes) {
        NSAttributedString *original = objc_getAssociatedObject(child, kApolloInlineCommentTextOriginalKey);
        if ([original isKindOfClass:[NSAttributedString class]] && [child respondsToSelector:@selector(setAttributedText:)]) {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(child, @selector(setAttributedText:), original);
            objc_setAssociatedObject(child, kApolloInlineCommentTextOriginalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ApolloInlineRestoreShortenedURLsUnderNode(child);
    }
}

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    RDKComment *comment = MSHookIvar<RDKComment *>(self, "comment");
    if (ApolloInlineAnyInlineFeatureEnabled()) ApolloInlineCaptureComment(self, comment, @"comment didLoad pre-orig");
    %orig;
    ApolloInlineCaptureComment(self, comment, @"comment didLoad post-orig");
}

- (void)didEnterPreloadState {
    RDKComment *comment = MSHookIvar<RDKComment *>(self, "comment");
    %orig;
    ApolloInlineCaptureComment(self, comment, @"comment preload");
}

- (void)didEnterDisplayState {
    RDKComment *comment = MSHookIvar<RDKComment *>(self, "comment");
    %orig;
    ApolloInlineCaptureComment(self, comment, @"comment display");
    if (ApolloInlineAnyInlineFeatureEnabled() && !comment.collapsed) {
        NSArray<NSURL *> *imageURLs = ApolloInlineCachedURLsForOwner(self);
        if (imageURLs.count == 0) imageURLs = ApolloInlineImageURLsFromComment(comment);
        if (imageURLs.count > 0) ApolloInlineShortenLongImageURLsUnderNode(self, imageURLs);
    } else if (!comment.collapsed) {
        ApolloInlineShortenLongRedditURLsForDisplayUnderNode(self);
    }
}

- (void)cellNodeVisibilityEvent:(NSInteger)event {
    RDKComment *comment = MSHookIvar<RDKComment *>(self, "comment");
    %orig(event);
    if (event == 0) {
        ApolloInlineCaptureComment(self, comment, @"comment visibility");
    }
}

- (id)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    RDKComment *comment = ApolloInlineCommentFromCell(self);
    ApolloInlineCaptureComment(self, comment, @"comment layout");
    id originalSpec = %orig(constrainedSize);
    if (!ApolloInlineAnyInlineFeatureEnabled() || !originalSpec) {
        ApolloInlineRemoveThumbnailNodes(self);
        ApolloInlineRestoreShortenedURLsUnderNode(self);
        if (originalSpec && !comment.collapsed) ApolloInlineShortenLongRedditURLsForDisplayUnderNode(self);
        return originalSpec;
    }
    if (comment.collapsed) {
        ApolloLog(@"[InlineThumbs] skipped collapsed comment thumbnails author=%@", comment.author ?: @"(nil)");
        ApolloInlineRemoveThumbnailNodes(self);
        return originalSpec;
    }

    NSArray<NSURL *> *imageURLs = ApolloInlineCachedURLsForOwner(self);
    if (imageURLs.count == 0) {
        imageURLs = ApolloInlineImageURLsFromComment(comment);
    }
    // v25: do NOT walk the comment cell tree clearing URL text nodes here.
    // Earlier versions cleared `urlTextNode` inside the LinkButtonNode itself,
    // which destroyed the only signal the LinkButton hook used to detect that
    // it was rendering an image link, causing it to fall back to %orig and
    // re-render Apollo's native link card. The LinkButton takeover hook
    // (below) replaces the entire native card visually, so there is no
    // duplicate URL UI to clean up at the comment level.
    if (imageURLs.count > 0) {
        // v27: shorten the long preview.redd.it URL displayed above/inside
        // the comment body to the post-style `redd.it/<id>.<ext>` form. The
        // link remains tappable.
        ApolloInlineShortenLongImageURLsUnderNode(self, imageURLs);
    }
    return originalSpec;
}

%new
- (void)apollo_inlineImageTapped:(id)sender {
    ApolloInlineHandleImageTap(sender);
}

%end

%hook _TtC6Apollo14LinkButtonNode

static void ApolloInlinePrimeLinkButtonForTakeover(id linkButtonNode, NSString *reason) {
    if (!linkButtonNode || !ApolloInlineAnyInlineFeatureEnabled()) return;

    // Scope guard: only prime LinkButtons that are descendants of a
    // CommentCellNode. Post-list and post-header LinkButtons are left alone.
    if (!ApolloInlineNodeHasCommentCellAncestor(linkButtonNode)) {
        // If this LinkButton was previously primed (e.g. node-recycled into
        // a feed cell), clear the marker so a stale takeover doesn't fire.
        if (objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey)) {
            objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloInlineRestoreLinkButtonOriginalSubnodes(linkButtonNode);
        }
        return;
    }

    // v30: pull EVERY URL-shaped property the LinkButton exposes (url,
    // thumbnailURL, etc.) and use the first one that canonicalizes to a
    // supported image URL. Giphy preview cards expose their playable image
    // on `thumbnailURL` while `url` is the share link, so the older
    // single-source check would silently miss them.
    NSArray<NSString *> *candidateStrings = ApolloInlineCandidateURLStringsFromLinkButtonNode(linkButtonNode);
    if (candidateStrings.count == 0) {
        NSString *fallback = ApolloInlineURLStringFromLinkButtonNode(linkButtonNode);
        if (fallback.length > 0) candidateStrings = @[fallback];
    }

    // v30 diagnostic: log the candidate URL list once per node (and only on
    // the comment-cell-scoped path) so we can see exactly what Apollo
    // exposes for previews that aren't being taken over (e.g. Giphy).
    // v31: also log descendant text fragments when the URL list is empty,
    // and re-log when the URL transitions from empty to populated so a
    // single screenshot's logs cover both initial and post-resolve states.
    static const void *kApolloInlineCandidateLoggedKey = &kApolloInlineCandidateLoggedKey;
    NSNumber *prevCount = objc_getAssociatedObject(linkButtonNode, kApolloInlineCandidateLoggedKey);
    if (!prevCount || (prevCount.unsignedIntegerValue == 0 && candidateStrings.count > 0)) {
        objc_setAssociatedObject(linkButtonNode, kApolloInlineCandidateLoggedKey, @(candidateStrings.count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *joined = [candidateStrings componentsJoinedByString:@" || "];
        NSMutableArray<NSString *> *fragments = [NSMutableArray array];
        ApolloInlineCollectDescendantText(linkButtonNode, fragments, 0);
        NSString *fragJoined = [fragments componentsJoinedByString:@" / "];
        ApolloLog(@"[InlineThumbs] LinkButton seen reason=%@ count=%lu urls=%@ text=%@", reason ?: @"prime", (unsigned long)candidateStrings.count, joined.length > 0 ? joined : @"(none)", fragJoined.length > 0 ? fragJoined : @"(none)");
    }

    NSURL *candidate = nil;
    for (NSString *candidateString in candidateStrings) {
        candidate = ApolloInlineCanonicalImageURLFromString(candidateString);
        if (candidate) break;
        NSURL *raw = [NSURL URLWithString:candidateString];
        if (ApolloInlineURLIsSupportedImage(raw)) { candidate = raw; break; }
    }

    // v31: Giphy fallback — recover the GIF id from any descendant text node
    // (the urlTextNode is truncated with an ellipsis, but `media.giphy.com/
    // media/<id>` is always visible before the cut). Cross-check against the
    // comment cell's cached URLs when possible to avoid false positives.
    if (!candidate && sShowInlinePostImageThumbnails) {
        NSMutableArray<NSString *> *fragments = [NSMutableArray array];
        ApolloInlineCollectDescendantText(linkButtonNode, fragments, 0);
        NSArray<NSURL *> *ownerURLs = nil;
        (void)ApolloInlineOwnerWithCachedImageURLsForNode(linkButtonNode, &ownerURLs);
        NSString *matchedID = nil;
        NSString *matchedFragment = nil;
        candidate = ApolloInlineCachedGiphyURLMatchingFragments(fragments, ownerURLs, &matchedID, &matchedFragment);
        if (!candidate) {
            candidate = ApolloInlineSyntheticGiphyURLFromCompleteFragments(fragments, &matchedID, &matchedFragment);
        }
        if (candidate) {
            ApolloLog(@"[InlineThumbs] LinkButton primed via giphy text id=%@ url=%@ frag=%@", matchedID, candidate.absoluteString, matchedFragment);
        }
    }
    if (!candidate) return;

    NSURL *previous = objc_getAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey);
    if (![previous isKindOfClass:[NSURL class]] || !ApolloInlineURLStringsMatch(previous, candidate)) {
        objc_setAssociatedObject(linkButtonNode, kApolloInlineLinkButtonMatchedURLKey, candidate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[InlineThumbs] LinkButton primed reason=%@ url=%@", reason ?: @"prime", candidate.absoluteString);
    }
    ApolloInlineInvalidateOwnerLayout(linkButtonNode);
}

- (void)didLoad {
    %orig;
    ApolloInlinePrimeLinkButtonForTakeover(self, @"link didLoad");
}

- (void)didEnterPreloadState {
    %orig;
    ApolloInlinePrimeLinkButtonForTakeover(self, @"link preload");
}

- (void)didEnterDisplayState {
    %orig;
    ApolloInlinePrimeLinkButtonForTakeover(self, @"link display");
    // Collapse/reopen path: a brand-new LinkButton may not have its bounds yet
    // when display state arrives. Re-invalidate after the first run loop and
    // again at 200ms so the takeover spec gets a chance to land.
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strong = weakSelf;
        if (strong) ApolloInlineInvalidateOwnerLayout(strong);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strong = weakSelf;
        if (strong) ApolloInlineInvalidateOwnerLayout(strong);
    });
}

- (id)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    if (!ApolloInlineAnyInlineFeatureEnabled()) {
        ApolloInlineRestoreLinkButtonOriginalSubnodes(self);
        return %orig(constrainedSize);
    }

    // Scope guard: only take over LinkButtons inside CommentCellNode.
    // This is the durable fix for r/bleach feed gray placeholders and the
    // post-header URL pill regressions.
    if (!ApolloInlineNodeHasCommentCellAncestor(self)) {
        ApolloInlineRestoreLinkButtonOriginalSubnodes(self);
        return %orig(constrainedSize);
    }

    id ownerNode = nil;
    NSURL *matchedURL = ApolloInlineMatchedImageURLForLinkButton(self, &ownerNode);
    if (!matchedURL) {
        ApolloInlineRestoreLinkButtonOriginalSubnodes(self);
        return %orig(constrainedSize);
    }

    id replacementSpec = ApolloInlineReplacementThumbnailSpecForLinkButton(self, ownerNode, matchedURL, constrainedSize);
    if (replacementSpec) return replacementSpec;

    ApolloLog(@"[InlineThumbs] takeover SKIPPED reason=spec build failed url=%@", matchedURL.absoluteString);
    ApolloInlineRestoreLinkButtonOriginalSubnodes(self);
    return %orig(constrainedSize);
}

%new
- (void)apollo_inlineImageTapped:(id)sender {
    ApolloInlineHandleImageTap(sender);
}

// ASNetworkImageNodeDelegate callback. Fires once the real image bytes are
// decoded — `image.size` is the intrinsic image size. We use it to recompute
// the thumbnail slot height = width * (h/w), then invalidate this LinkButton
// AND walk up to the CommentCellNode so the table row re-measures.
%new
- (void)imageNode:(id)imageNode didLoadImage:(UIImage *)image {
    if (![image isKindOfClass:[UIImage class]]) return;
    CGSize imgSize = image.size;
    if (imgSize.width <= 0.5 || imgSize.height <= 0.5) return;

    CGFloat aspect = imgSize.height / imgSize.width;
    // v29: do NOT early-return on prev≈aspect. The intermittent "tiny image
    // in oversized gray slot" bug occurs when the cached aspect ivar was set
    // by a previous build but the LinkButton's slot view never actually got
    // laid out at that aspect. Always invalidate so the row re-measures.
    objc_setAssociatedObject(self, kApolloInlineLinkButtonAspectRatioKey, @(aspect), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[InlineThumbs] image loaded intrinsic=%.0fx%.0f aspect=%.3f", imgSize.width, imgSize.height, aspect);

    void (^invalidateChain)(void) = ^{
        ApolloInlineInvalidateOwnerLayout(self);
        id sup = ApolloInlineSupernode(self);
        for (NSUInteger i = 0; sup && i < 16; i++) {
            ApolloInlineInvalidateOwnerLayout(sup);
            NSString *cls = NSStringFromClass([sup class]);
            if ([cls rangeOfString:@"CommentCellNode"].location != NSNotFound ||
                [cls rangeOfString:@"CommentsHeaderCellNode"].location != NSNotFound) {
                break;
            }
            sup = ApolloInlineSupernode(sup);
        }
    };

    dispatch_async(dispatch_get_main_queue(), invalidateChain);
    // v29 safety net: if a concurrent table layout swallowed the first
    // invalidation, the slot can still end up at the placeholder height.
    // Re-check after 400ms and re-invalidate if the actual height doesn't
    // match width*aspect within 2pt. Cheap one-shot insurance.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        CGSize calc = CGSizeZero;
        if ([strongSelf respondsToSelector:@selector(calculatedSize)]) {
            calc = ((CGSize (*)(id, SEL))objc_msgSend)(strongSelf, @selector(calculatedSize));
        }
        if (calc.width <= 0.5) return;
        CGFloat expectedH = calc.width * aspect;
        if (fabs(calc.height - expectedH) > 2.0) {
            ApolloLog(@"[InlineThumbs] safety-net re-invalidate calc=%.0fx%.0f expectedH=%.0f aspect=%.3f", calc.width, calc.height, expectedH, aspect);
            invalidateChain();
        }
    });
}

%end

// v33.1: Toggle change handler. CustomAPIViewController calls this when the
// user flips Inline Image / GIF Thumbnails so already-onscreen comments re-evaluate against the new gating instead of
// staying stuck in their previous takeover state. Walks the view hierarchy
// of every visible window, finds AS-backed views, and for each:
//   - LinkButtonNode: clears matched-URL cache, restores any hidden native
//     subnodes (so previous takeovers come back as preview pills when GIF
//     gets turned off, etc.), invalidates layout.
//   - CommentCellNode / CommentsHeaderCellNode: clears the cached image-URL
//     identity/key, restores shortened URL text nodes, invalidates layout.
// The next ASDK layout pass then re-runs `layoutSpecThatFits:` with the new
// `ApolloInlineURLIsSupportedImage` per-host gating in effect.
static void ApolloInlineNodeFromView(UIView *view, void (^block)(id node)) {
    if (!view) return;
    Class viewClass = object_getClass(view);
    Ivar nodeIvar = class_getInstanceVariable(viewClass, "_node");
    if (nodeIvar) {
        id node = nil;
        @try { node = object_getIvar(view, nodeIvar); }
        @catch (__unused NSException *exception) { node = nil; }
        if (node) block(node);
    }
    for (UIView *sub in view.subviews) ApolloInlineNodeFromView(sub, block);
}

static void ApolloInlineForceContainerRelayout(id node) {
    if (!node) return;
    SEL relayoutItems = NSSelectorFromString(@"relayoutItems");
    if ([node respondsToSelector:relayoutItems]) {
        ((void (*)(id, SEL))objc_msgSend)(node, relayoutItems);
    }
    ApolloInlineInvalidateOwnerLayout(node);
}

extern "C" void ApolloInlineHandleToggleChanged(void) {
    ApolloLog(@"[InlineThumbs] toggle changed inlineMedia=%d", sShowInlinePostImageThumbnails);
    void (^work)(void) = ^{
        NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows;
        NSMutableSet *layoutContainers = [NSMutableSet set];
        for (UIWindow *window in windows) {
            ApolloInlineNodeFromView(window, ^(id node) {
                if (!node) return;
                NSString *cls = NSStringFromClass([node class]);
                if ([cls rangeOfString:@"TableNode"].location != NSNotFound || [cls rangeOfString:@"CollectionNode"].location != NSNotFound) {
                    [layoutContainers addObject:node];
                }
                BOOL isLinkButton = [cls rangeOfString:@"LinkButtonNode"].location != NSNotFound;
                BOOL isCommentCell = [cls rangeOfString:@"CommentCellNode"].location != NSNotFound &&
                                     [cls rangeOfString:@"HeaderCellNode"].location == NSNotFound;
                BOOL isCommentsHeader = [cls rangeOfString:@"CommentsHeaderCellNode"].location != NSNotFound;
                if (isLinkButton) {
                    objc_setAssociatedObject(node, kApolloInlineLinkButtonMatchedURLKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    ApolloInlineRestoreLinkButtonOriginalSubnodes(node);
                    ApolloInlineInvalidateOwnerLayout(node);
                } else if (isCommentCell || isCommentsHeader) {
                    objc_setAssociatedObject(node, kApolloInlineCachedURLsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    objc_setAssociatedObject(node, kApolloInlineCachedIdentityKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
                    objc_setAssociatedObject(node, kApolloInlineCachedKeyKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
                    ApolloInlineRestoreShortenedURLsUnderNode(node);
                    if (!sShowInlinePostImageThumbnails && isCommentCell) ApolloInlineShortenLongRedditURLsForDisplayUnderNode(node);
                    if (isCommentsHeader) ApolloInlineRestoreHeaderImagePills(node);
                    ApolloInlineInvalidateOwnerLayout(node);
                }
            });
        }
        NSArray *containers = layoutContainers.allObjects;
        void (^relayoutContainers)(void) = ^{
            for (id node in containers) ApolloInlineForceContainerRelayout(node);
        };
        relayoutContainers();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), relayoutContainers);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), relayoutContainers);
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    sApolloInlineVisibleCommentsLink = ApolloInlineLinkFromController((UIViewController *)self);
    if (!sShowInlinePostImageThumbnails) return;
    RDKLink *link = sApolloInlineVisibleCommentsLink;
    NSArray<NSURL *> *urls = ApolloInlineImageURLsFromLink(link);
    ApolloLog(@"[InlineThumbs] CommentsVC willAppear link=%@ url=%@ urls=%lu", link.title ?: @"(nil)", link.URL.absoluteString ?: @"(nil)", (unsigned long)urls.count);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    sApolloInlineVisibleCommentsLink = ApolloInlineLinkFromController((UIViewController *)self);
    if (!sShowInlinePostImageThumbnails) return;
    RDKLink *link = sApolloInlineVisibleCommentsLink;
    NSArray<NSURL *> *urls = ApolloInlineImageURLsFromLink(link);
    ApolloLog(@"[InlineThumbs] CommentsVC didAppear link=%@ url=%@ urls=%lu", link.title ?: @"(nil)", link.URL.absoluteString ?: @"(nil)", (unsigned long)urls.count);
}

%end

%ctor {
    ApolloInlineCompileRegexes();
    sApolloInlineScreenWidth = UIScreen.mainScreen.bounds.size.width;
    Class headerClass = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode");
    Class commentClass = objc_getClass("_TtC6Apollo15CommentCellNode");
    Class commentsVCClass = objc_getClass("_TtC6Apollo22CommentsViewController");
        Class linkButtonClass = objc_getClass("_TtC6Apollo14LinkButtonNode");
        ApolloLog(@"[InlineThumbs] ctor header=%p comment=%p commentsVC=%p linkButton=%p ASNetworkImageNode=%p ASStackLayoutSpec=%p ASInsetLayoutSpec=%p screenWidth=%.1f", headerClass, commentClass, commentsVCClass, linkButtonClass, objc_getClass("ASNetworkImageNode"), objc_getClass("ASStackLayoutSpec"), objc_getClass("ASInsetLayoutSpec"), sApolloInlineScreenWidth);
    %init(_TtC6Apollo22CommentsHeaderCellNode = headerClass,
            _TtC6Apollo15CommentCellNode = commentClass,
            _TtC6Apollo14LinkButtonNode = linkButtonClass,
            _TtC6Apollo22CommentsViewController = commentsVCClass);
}
