#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <ImageIO/ImageIO.h>
#import <CoreFoundation/CoreFoundation.h>

#import "ApolloCommon.h"
#import "ApolloRedditMediaUpload.h"
#import "ApolloImageUploadHost.h"
#import "ApolloState.h"
#import "Defaults.h"
#import "fishhook.h"

// MARK: - Private state

extern NSString *sUserAgent;

static NSMutableDictionary<NSString *, NSString *> *sRedditUploadAssetIDByURL = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *sRedditUploadInfoByAssetID = nil;
static NSMutableSet<NSString *> *sRedditResponseTransformerInstalledClasses = nil;
static char kApolloRedditCommentResponseDataKey;
static char kApolloRedditSubmitResponseDataKey;

static NSObject *ApolloRedditUploadAssetMapLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

// User-perceived wait cap for permalink resolution. Past this, we deliver Reddit's
// original response and let Apollo handle whatever it returned.
static NSTimeInterval const kApolloSubmitWebsocketTimeout = 8.0;
static NSTimeInterval const kApolloSubmitListingMaxWait = 12.0;
static NSTimeInterval const kApolloSubmitListingPollDelays[] = { 2.0, 4.0, 7.0, 11.0 };
static NSUInteger const kApolloSubmitListingPollCount = sizeof(kApolloSubmitListingPollDelays) / sizeof(kApolloSubmitListingPollDelays[0]);

static NSTimeInterval const kApolloCommentHydrationPollDelays[] = { 0.4, 1.0, 1.8, 3.0 };
static NSUInteger const kApolloCommentHydrationPollCount = sizeof(kApolloCommentHydrationPollDelays) / sizeof(kApolloCommentHydrationPollDelays[0]);

// MARK: - Bearer token capture

BOOL ApolloIsAuthorizationHeader(NSString *field) {
    return [field isKindOfClass:[NSString class]] && [field caseInsensitiveCompare:@"Authorization"] == NSOrderedSame;
}

void ApolloRedditCaptureBearerTokenFromAuthorization(NSString *authorization, NSString *source) {
    if (![authorization isKindOfClass:[NSString class]]) return;

    NSRange bearerRange = [authorization rangeOfString:@"Bearer " options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (bearerRange.location == NSNotFound) return;

    NSString *token = [[authorization substringFromIndex:NSMaxRange(bearerRange)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (token.length == 0 || [token isEqualToString:sLatestRedditBearerToken]) return;

    sLatestRedditBearerToken = [token copy];
    ApolloLog(@"[RedditUpload] Captured Reddit bearer token from %@", source ?: @"unknown source");
}

void ApolloRedditCaptureBearerTokenFromHeaderDictionary(NSDictionary *headers, NSString *source) {
    if (![headers isKindOfClass:[NSDictionary class]]) return;

    for (id key in headers) {
        if (![key isKindOfClass:[NSString class]] || !ApolloIsAuthorizationHeader((NSString *)key)) continue;
        id value = headers[key];
        if ([value isKindOfClass:[NSString class]]) {
            ApolloRedditCaptureBearerTokenFromAuthorization((NSString *)value, source);
        }
        return;
    }
}

void ApolloRedditCaptureBearerTokenFromRequest(NSURLRequest *request, NSString *source) {
    if (![request isKindOfClass:[NSURLRequest class]]) return;
    ApolloRedditCaptureBearerTokenFromAuthorization([request valueForHTTPHeaderField:@"Authorization"], source);
}

// MARK: - Asset map

static void ApolloRecordRedditUploadedMediaAssetID(NSURL *imageURL, NSString *assetID) {
    NSString *urlString = imageURL.absoluteString;
    if (urlString.length == 0 || assetID.length == 0) return;

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditUploadAssetIDByURL) sRedditUploadAssetIDByURL = [NSMutableDictionary new];
        sRedditUploadAssetIDByURL[urlString] = assetID;
    }
}

static NSString *ApolloAssetIDForRedditUploadedMediaURL(NSString *urlString) {
    if (urlString.length == 0) return nil;
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        return sRedditUploadAssetIDByURL[urlString];
    }
}

static NSString *ApolloRedditUploadExtensionForMIMEType(NSString *mimeType) {
    if ([mimeType isEqualToString:@"image/png"]) return @"png";
    if ([mimeType isEqualToString:@"image/gif"]) return @"gif";
    if ([mimeType isEqualToString:@"image/webp"]) return @"webp";
    if ([mimeType isEqualToString:@"image/heic"]) return @"heic";
    if ([mimeType isEqualToString:@"image/heif"]) return @"heif";
    return @"jpeg";
}

static void ApolloRecordRedditUploadedMediaInfo(NSURL *imageURL, NSString *assetID, NSString *mimeType) {
    if (assetID.length == 0) return;

    NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(nil, mimeType);
    NSString *extension = ApolloRedditUploadExtensionForMIMEType(resolvedMIMEType);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"assetID"] = assetID;
    info[@"mimeType"] = resolvedMIMEType ?: @"image/jpeg";
    info[@"extension"] = extension ?: @"jpeg";
    if (imageURL.absoluteString.length > 0) info[@"stagedURL"] = imageURL.absoluteString;

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditUploadInfoByAssetID) sRedditUploadInfoByAssetID = [NSMutableDictionary new];
        sRedditUploadInfoByAssetID[assetID] = info;
    }
}

// MARK: - URL helpers

static BOOL ApolloStringContainsRedditUploadedMedia(NSString *text) {
    return [text isKindOfClass:[NSString class]] && [text containsString:@"reddit-uploaded-media.s3-accelerate.amazonaws.com"];
}

static BOOL ApolloStringIsRedditDisplayMediaURL(NSString *text) {
    return [text isKindOfClass:[NSString class]] &&
           ([text hasPrefix:@"https://preview.redd.it/"] || [text hasPrefix:@"https://i.redd.it/"]);
}

static NSString *ApolloDecodedRedditMediaURLString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return nil;
    NSString *decoded = [urlString stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    return decoded;
}

static NSString *ApolloHostForRedditMediaURL(NSString *urlString) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(urlString);
    if (decoded.length == 0) return nil;
    return [NSURLComponents componentsWithString:decoded].host.lowercaseString;
}

static NSString *ApolloRedditMediaURLByStrippingQuery(NSString *urlString) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(urlString);
    if (decoded.length == 0) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:decoded];
    NSString *host = components.host;
    if (([host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"i.redd.it"]) && components.path.length > 0) {
        components.query = nil;
        components.fragment = nil;
        return components.URL.absoluteString ?: decoded;
    }
    return decoded;
}

static NSString *ApolloHTMLEscapedString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) return @"";
    NSString *escaped = [string stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"&#39;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return escaped;
}

static NSString *ApolloRedditUploadFallbackURLForAssetID(NSString *assetID) {
    if (assetID.length == 0) return nil;
    NSString *extension = nil;
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        NSDictionary *info = sRedditUploadInfoByAssetID[assetID];
        extension = [info[@"extension"] isKindOfClass:[NSString class]] ? info[@"extension"] : nil;
    }
    return [NSString stringWithFormat:@"https://i.redd.it/%@.%@", assetID, extension.length > 0 ? extension : @"jpeg"];
}

static NSString *ApolloFormDecodeComponent(NSString *component) {
    NSString *plusDecoded = [component stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return plusDecoded.stringByRemovingPercentEncoding ?: plusDecoded;
}

static NSString *ApolloFormEncodeComponent(NSString *component) {
    static NSCharacterSet *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet alphanumericCharacterSet];
        [set addCharactersInString:@"-._~"];
        allowed = [set copy];
    });
    return [component stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSRegularExpression *ApolloRedditUploadedMediaURLRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [[NSRegularExpression alloc]
                 initWithPattern:@"https://reddit-uploaded-media\\.s3-accelerate\\.amazonaws\\.com/[^\\s\\])<>]+"
                         options:0
                           error:nil];
    });
    return regex;
}

static NSString *ApolloFirstRedditUploadedMediaURLInString(NSString *text) {
    if (!ApolloStringContainsRedditUploadedMedia(text)) return nil;
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:match.range] : nil;
}

static NSData *ApolloRedditRichTextJSONDataForText(NSString *text);

// MARK: - Request identification

// Matches /api/comment (new comments) and /api/editusertext (edits to existing
// comments and self-text post bodies). Both accept the same form fields and return
// the same envelope.
static BOOL ApolloIsRedditCommentRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSURL *url = request.URL;
    if (![url.host isEqualToString:@"oauth.reddit.com"]) return NO;
    NSString *path = url.path;
    return [path isEqualToString:@"/api/comment"]
        || [path isEqualToString:@"/api/editusertext"]
        || [path isEqualToString:@"/api/editusertext/"];
}

static BOOL ApolloIsRedditSubmitRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return NO;
    NSURL *url = request.URL;
    return [url.host isEqualToString:@"oauth.reddit.com"] && [url.path isEqualToString:@"/api/submit"];
}

BOOL ApolloRedditIsCommentTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) return NO;
    return ApolloIsRedditCommentRequest(task.originalRequest) || ApolloIsRedditCommentRequest(task.currentRequest);
}

BOOL ApolloRedditIsSubmitTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) return NO;
    return ApolloIsRedditSubmitRequest(task.originalRequest) || ApolloIsRedditSubmitRequest(task.currentRequest);
}

// MARK: - Submit context extraction

// Extracts subreddit/title/asset ID from a /api/submit body that contains a staged
// upload URL.
static NSDictionary *ApolloRedditMediaSubmitContextFromRequest(NSURLRequest *request) {
    if (!ApolloIsRedditSubmitRequest(request)) return nil;
    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) return nil;
    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    if (!ApolloStringContainsRedditUploadedMedia(body)) return nil;

    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    for (NSString *pair in [body componentsSeparatedByString:@"&"]) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);

        if ([key isEqualToString:@"sr"] && value.length > 0) context[@"subreddit"] = value;
        else if ([key isEqualToString:@"title"] && value.length > 0) context[@"title"] = value;
        else if (([key isEqualToString:@"url"] || [key isEqualToString:@"text"]) && ApolloStringContainsRedditUploadedMedia(value)) {
            NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(value) ?: value;
            context[@"stagedURL"] = stagedURL;
            NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
            if (assetID.length > 0) context[@"assetID"] = assetID;
        }
    }
    return context.count > 0 ? context : nil;
}

// MARK: - Request rewriting (submit)

NSURLRequest *ApolloRedditMaybeRewriteSubmitRequest(NSURLRequest *request) {
    if (sImageUploadProvider != ImageUploadProviderReddit || !ApolloIsRedditSubmitRequest(request)) return nil;

    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) return nil;
    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    if (!ApolloStringContainsRedditUploadedMedia(body)) return nil;

    NSArray<NSString *> *pairs = [body componentsSeparatedByString:@"&"];
    BOOL hasUploadedURLField = NO;
    BOOL hasUploadedTextField = NO;
    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);
        if ([key isEqualToString:@"url"] && ApolloFirstRedditUploadedMediaURLInString(value).length > 0) hasUploadedURLField = YES;
        if ([key isEqualToString:@"text"] && ApolloFirstRedditUploadedMediaURLInString(value).length > 0) hasUploadedTextField = YES;
    }
    if (!hasUploadedURLField && !hasUploadedTextField) return nil;

    NSMutableArray<NSString *> *rewrittenPairs = [NSMutableArray arrayWithCapacity:pairs.count + 2];
    BOOL changed = NO;
    BOOL rewriteAsSelfText = hasUploadedTextField && !hasUploadedURLField;
    BOOL wroteKind = NO, wroteAPIType = NO, wroteValidateOnSubmit = NO, wroteReturnRichTextJSON = NO;
    NSString *richTextJSONString = nil;
    NSString *assetID = nil;

    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);

        if ([key isEqualToString:@"text"] && rewriteAsSelfText) {
            NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(value);
            assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
            NSData *richTextJSONData = ApolloRedditRichTextJSONDataForText(value);
            if (richTextJSONData.length > 0) {
                richTextJSONString = [[NSString alloc] initWithData:richTextJSONData encoding:NSUTF8StringEncoding];
                if (richTextJSONString.length > 0) {
                    changed = YES;
                    continue;
                }
            }
        } else if ([key isEqualToString:@"url"] && ApolloStringContainsRedditUploadedMedia(value)) {
            NSString *stagedURL = ApolloFirstRedditUploadedMediaURLInString(value) ?: value;
            assetID = ApolloAssetIDForRedditUploadedMediaURL(stagedURL);
        } else if ([key isEqualToString:@"kind"]) {
            wroteKind = YES;
            NSString *newKind = rewriteAsSelfText ? @"self" : @"image";
            if (![value isEqualToString:newKind]) { value = newKind; changed = YES; }
        } else if ([key isEqualToString:@"api_type"]) {
            wroteAPIType = YES;
            if (![value isEqualToString:@"json"]) { value = @"json"; changed = YES; }
        } else if ([key isEqualToString:@"validate_on_submit"]) {
            wroteValidateOnSubmit = YES;
            if (![value isEqualToString:@"false"] && ![value isEqualToString:@"False"] && ![value isEqualToString:@"0"]) { value = @"false"; changed = YES; }
        } else if ([key isEqualToString:@"return_rtjson"]) {
            wroteReturnRichTextJSON = YES;
            if (rewriteAsSelfText && ![value isEqualToString:@"true"]) { value = @"true"; changed = YES; }
        }

        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)]];
    }

    if (!wroteKind) { [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"kind"), ApolloFormEncodeComponent(rewriteAsSelfText ? @"self" : @"image")]]; changed = YES; }
    if (!wroteValidateOnSubmit) { [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"validate_on_submit"), ApolloFormEncodeComponent(@"false")]]; changed = YES; }
    if (!wroteAPIType) { [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"api_type"), ApolloFormEncodeComponent(@"json")]]; changed = YES; }
    if (richTextJSONString.length > 0) {
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"richtext_json"), ApolloFormEncodeComponent(richTextJSONString)]];
        if (!wroteReturnRichTextJSON) {
            [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"return_rtjson"), ApolloFormEncodeComponent(@"true")]];
        }
    }

    if (!changed) return nil;

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    NSData *newBody = [[rewrittenPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [modifiedRequest setHTTPBody:newBody];
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
    ApolloLog(@"[RedditUpload] Rewrote /api/submit to %@ (assetID=%@, %lu bytes)", rewriteAsSelfText ? @"rich text self post" : @"image post", assetID ?: @"(missing)", (unsigned long)newBody.length);
    return modifiedRequest;
}

// MARK: - Request rewriting (comment)

static NSDictionary *ApolloRedditRichTextParagraphBlock(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    return @{ @"e": @"par", @"c": @[ @{ @"e": @"text", @"t": trimmed } ] };
}

static NSData *ApolloRedditRichTextJSONDataForText(NSString *text) {
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    NSArray<NSTextCheckingResult *> *matches = regex ? [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    if (matches.count == 0) return nil;

    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.range.location > cursor) {
            NSDictionary *paragraph = ApolloRedditRichTextParagraphBlock([text substringWithRange:NSMakeRange(cursor, match.range.location - cursor)]);
            if (paragraph) [blocks addObject:paragraph];
        }
        NSString *mediaURL = [text substringWithRange:match.range];
        NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(mediaURL);
        if (assetID.length == 0) {
            ApolloLog(@"[RedditUpload] No asset ID recorded for uploaded media URL; falling back to markdown rewrite");
            return nil;
        }
        [blocks addObject:@{ @"e": @"img", @"id": assetID, @"c": @"" }];
        cursor = NSMaxRange(match.range);
    }
    if (cursor < text.length) {
        NSDictionary *paragraph = ApolloRedditRichTextParagraphBlock([text substringFromIndex:cursor]);
        if (paragraph) [blocks addObject:paragraph];
    }
    if (blocks.count == 0) return nil;
    return [NSJSONSerialization dataWithJSONObject:@{ @"document": blocks } options:0 error:nil];
}

static NSString *ApolloCommentTextByWrappingRedditUploadedMediaURLs(NSString *text) {
    if (!ApolloStringContainsRedditUploadedMedia(text)) return text;
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    if (!regex) return text;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return text;

    NSMutableString *rewritten = [text mutableCopy];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSRange range = match.range;
        if (range.location >= 2 && [[text substringWithRange:NSMakeRange(range.location - 2, 2)] isEqualToString:@"]("]) continue;
        NSString *url = [text substringWithRange:range];
        [rewritten replaceCharactersInRange:range withString:[NSString stringWithFormat:@"[image](%@)", url]];
    }
    return rewritten;
}

NSURLRequest *ApolloRedditMaybeRewriteCommentRequest(NSURLRequest *request) {
    if (sImageUploadProvider != ImageUploadProviderReddit || !ApolloIsRedditCommentRequest(request)) return nil;

    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) return nil;
    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    if (!ApolloStringContainsRedditUploadedMedia(body)) return nil;

    NSArray<NSString *> *pairs = [body componentsSeparatedByString:@"&"];
    NSMutableArray<NSString *> *rewrittenPairs = [NSMutableArray arrayWithCapacity:pairs.count + 2];
    BOOL changed = NO;
    BOOL wroteReturnRichTextJSON = NO;
    NSString *richTextJSONString = nil;

    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *key = ApolloFormDecodeComponent(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
        NSString *value = ApolloFormDecodeComponent(equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1]);

        if ([key isEqualToString:@"text"] && ApolloStringContainsRedditUploadedMedia(value)) {
            NSData *richTextJSONData = ApolloRedditRichTextJSONDataForText(value);
            if (richTextJSONData.length > 0) {
                richTextJSONString = [[NSString alloc] initWithData:richTextJSONData encoding:NSUTF8StringEncoding];
                if (richTextJSONString.length > 0) {
                    ApolloLog(@"[RedditUpload] Rewriting %@ text to richtext_json", request.URL.path);
                    changed = YES;
                    continue;
                }
            }

            NSString *rewrittenValue = ApolloCommentTextByWrappingRedditUploadedMediaURLs(value);
            if (![rewrittenValue isEqualToString:value]) {
                ApolloLog(@"[RedditUpload] Rewriting %@ text to markdown-link fallback", request.URL.path);
                value = rewrittenValue;
                changed = YES;
            }
        }

        if ([key isEqualToString:@"return_rtjson"]) { value = @"true"; wroteReturnRichTextJSON = YES; }

        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)]];
    }

    if (richTextJSONString.length > 0) {
        [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"richtext_json"), ApolloFormEncodeComponent(richTextJSONString)]];
        if (!wroteReturnRichTextJSON) {
            [rewrittenPairs addObject:[NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"return_rtjson"), ApolloFormEncodeComponent(@"true")]];
        }
    }

    if (!changed) return nil;

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    NSData *newBody = [[rewrittenPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [modifiedRequest setHTTPBody:newBody];
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
    return modifiedRequest;
}

// MARK: - LinkID resolution (websocket + listing)

// Reddit's image-submit websocket sends {"type":"success","payload":{"redirect":URL}}
// where URL contains the new post's linkID. Returns nil if no linkID found.
static NSString *ApolloRedditExtractLinkIDFromPostURL(NSString *urlString) {
    if (urlString.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *host = components.host.lowercaseString;
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;
    NSArray<NSString *> *parts = components.path.pathComponents;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        if ([parts[i] isEqualToString:@"comments"]) {
            NSString *id_ = parts[i + 1];
            return id_.length > 0 ? id_ : nil;
        }
    }
    return nil;
}

static NSString *ApolloRedditExtractLinkIDFromWebsocketJSON(id json) {
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)json;
        for (NSString *key in @[@"redirect", @"redirect_url", @"target_permalink", @"permalink", @"url", @"location"]) {
            id value = dict[key];
            if ([value isKindOfClass:[NSString class]]) {
                NSString *linkID = ApolloRedditExtractLinkIDFromPostURL((NSString *)value);
                if (linkID) return linkID;
            }
        }
        for (id value in dict.objectEnumerator) {
            NSString *linkID = ApolloRedditExtractLinkIDFromWebsocketJSON(value);
            if (linkID) return linkID;
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)json) {
            NSString *linkID = ApolloRedditExtractLinkIDFromWebsocketJSON(item);
            if (linkID) return linkID;
        }
    }
    return nil;
}

// Resolution result: {linkID: NSString, postURL: NSString} or nil
typedef void (^ApolloRedditLinkIDResolution)(NSString *linkID, NSString *postURL);

static void ApolloRedditResolveSubmittedLinkIDViaWebsocket(NSString *webSocketURLString, ApolloRedditLinkIDResolution completion) {
    if (webSocketURLString.length == 0) { completion(nil, nil); return; }
    NSURL *webSocketURL = [NSURL URLWithString:webSocketURLString];
    if (!webSocketURL) { completion(nil, nil); return; }
    if (@available(iOS 13.0, *)) {
        NSURLSessionWebSocketTask *task = [[NSURLSession sharedSession] webSocketTaskWithURL:webSocketURL];
        __block BOOL finished = NO;
        [task resume];
        [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
            if (finished) return;
            finished = YES;

            NSString *messageString = message.type == NSURLSessionWebSocketMessageTypeString
                ? message.string
                : [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
            [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];

            if (error || messageString.length == 0) {
                ApolloLog(@"[RedditUpload] Websocket linkID resolve failed: %@", error.localizedDescription ?: @"empty message");
                completion(nil, nil);
                return;
            }

            NSString *linkID = nil, *postURL = nil;
            NSData *messageData = [messageString dataUsingEncoding:NSUTF8StringEncoding];
            id json = messageData.length > 0 ? [NSJSONSerialization JSONObjectWithData:messageData options:0 error:nil] : nil;
            if (json) linkID = ApolloRedditExtractLinkIDFromWebsocketJSON(json);
            if (!linkID) linkID = ApolloRedditExtractLinkIDFromPostURL(messageString);

            if (linkID && [json isKindOfClass:[NSDictionary class]]) {
                id payload = ((NSDictionary *)json)[@"payload"];
                if ([payload isKindOfClass:[NSDictionary class]]) {
                    id redirect = ((NSDictionary *)payload)[@"redirect"];
                    if ([redirect isKindOfClass:[NSString class]]) postURL = redirect;
                }
            }
            completion(linkID, postURL);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSubmitWebsocketTimeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!finished) {
                finished = YES;
                [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
                ApolloLog(@"[RedditUpload] Websocket linkID resolve timed out");
                completion(nil, nil);
            }
        });
    } else {
        completion(nil, nil);
    }
}

static NSString *ApolloUsernameFromSubmittedPage(NSString *userSubmittedPage) {
    if (userSubmittedPage.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:userSubmittedPage];
    NSArray<NSString *> *parts = components.path.pathComponents;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        if ([parts[i] isEqualToString:@"user"] || [parts[i] isEqualToString:@"u"]) {
            NSString *u = parts[i + 1];
            return [u isEqualToString:@"/"] ? nil : u;
        }
    }
    return nil;
}

static BOOL ApolloListingPostMatchesContext(NSDictionary *postData, NSDictionary *context) {
    if (![postData isKindOfClass:[NSDictionary class]]) return NO;
    NSString *title = [context[@"title"] isKindOfClass:[NSString class]] ? context[@"title"] : nil;
    NSString *postTitle = [postData[@"title"] isKindOfClass:[NSString class]] ? postData[@"title"] : nil;
    if (title.length == 0 || ![postTitle isEqualToString:title]) return NO;

    NSString *expectedAuthor = ApolloUsernameFromSubmittedPage(context[@"userSubmittedPage"]);
    NSString *postAuthor = [postData[@"author"] isKindOfClass:[NSString class]] ? postData[@"author"] : nil;
    return expectedAuthor.length == 0 || [postAuthor caseInsensitiveCompare:expectedAuthor] == NSOrderedSame;
}

static void ApolloRedditPollListingForLinkID(NSDictionary *context, NSUInteger attempt, ApolloRedditLinkIDResolution completion) {
    NSString *subreddit = [context[@"subreddit"] isKindOfClass:[NSString class]] ? context[@"subreddit"] : nil;
    if (subreddit.length == 0 || sLatestRedditBearerToken.length == 0) { completion(nil, nil); return; }

    NSString *escaped = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/new.json", escaped]];
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"limit" value:@"25"], [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"] ];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : defaultUserAgent;
    if (userAgent.length > 0) [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || status < 200 || status >= 300 || data.length == 0) {
            ApolloLog(@"[RedditUpload] Listing poll attempt %lu failed status=%ld error=%@", (unsigned long)attempt, (long)status, error.localizedDescription ?: @"(none)");
            completion(nil, nil);
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *listingData = [json isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)json)[@"data"] : nil;
        NSArray *children = [listingData isKindOfClass:[NSDictionary class]] ? listingData[@"children"] : nil;
        for (id child in children) {
            NSDictionary *childDict = [child isKindOfClass:[NSDictionary class]] ? child : nil;
            NSDictionary *postData = [childDict[@"data"] isKindOfClass:[NSDictionary class]] ? childDict[@"data"] : nil;
            if (!ApolloListingPostMatchesContext(postData, context)) continue;

            NSString *name = [postData[@"name"] isKindOfClass:[NSString class]] ? postData[@"name"] : nil;
            NSString *id_ = [postData[@"id"] isKindOfClass:[NSString class]] ? postData[@"id"] : nil;
            if (id_.length == 0 && [name hasPrefix:@"t3_"]) id_ = [name substringFromIndex:3];
            NSString *permalink = [postData[@"permalink"] isKindOfClass:[NSString class]] ? postData[@"permalink"] : nil;
            NSString *postURL = permalink.length > 0 ? [@"https://reddit.com" stringByAppendingString:permalink] : nil;
            if (id_.length > 0) {
                completion(id_, postURL);
                return;
            }
        }
        completion(nil, nil);
    }] resume];
}

// Race websocket against listing-poll. First non-nil linkID wins.
static void ApolloRedditResolveSubmittedLinkID(NSString *webSocketURL, NSDictionary *context, ApolloRedditLinkIDResolution completion) {
    __block BOOL completed = NO;
    void (^deliver)(NSString *, NSString *) = ^(NSString *linkID, NSString *postURL) {
        @synchronized(ApolloRedditUploadAssetMapLock()) {
            if (completed) return;
            if (linkID.length == 0) return;
            completed = YES;
        }
        completion(linkID, postURL);
    };

    ApolloRedditResolveSubmittedLinkIDViaWebsocket(webSocketURL, ^(NSString *linkID, NSString *postURL) {
        deliver(linkID, postURL);
    });

    for (NSUInteger i = 0; i < kApolloSubmitListingPollCount; i++) {
        NSTimeInterval delay = kApolloSubmitListingPollDelays[i];
        NSUInteger attempt = i + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @synchronized(ApolloRedditUploadAssetMapLock()) { if (completed) return; }
            ApolloRedditPollListingForLinkID(context, attempt, ^(NSString *linkID, NSString *postURL) { deliver(linkID, postURL); });
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSubmitListingMaxWait * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL fireFailure = NO;
        @synchronized(ApolloRedditUploadAssetMapLock()) {
            if (!completed) { completed = YES; fireFailure = YES; }
        }
        if (fireFailure) {
            ApolloLog(@"[RedditUpload] LinkID resolution timed out");
            completion(nil, nil);
        }
    });
}

// MARK: - Submit response synthesis

// Synthesize the success JSON Apollo's submit-completion path expects.
static NSData *ApolloRedditSynthesizeSubmitSuccessResponseData(NSString *linkID, NSString *postURL, NSDictionary *context) {
    if (linkID.length == 0) return nil;
    NSString *fullName = [linkID hasPrefix:@"t3_"] ? linkID : [@"t3_" stringByAppendingString:linkID];
    NSString *bareID = [linkID hasPrefix:@"t3_"] ? [linkID substringFromIndex:3] : linkID;
    NSString *url = postURL.length > 0 ? postURL : ApolloRedditUploadFallbackURLForAssetID(context[@"assetID"]);

    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    data[@"id"] = bareID;
    data[@"name"] = fullName;
    if (url.length > 0) data[@"url"] = url;
    data[@"drafts_count"] = @0;

    NSDictionary *root = @{ @"json": @{ @"errors": @[], @"data": data } };
    return [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
}

// Pulls the websocket URL and user-submitted-page out of Reddit's image-submit response.
static NSDictionary *ApolloRedditParseSubmitResponseLinks(NSData *data) {
    if (data.length == 0) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    NSDictionary *jsonDict = [root[@"json"] isKindOfClass:[NSDictionary class]] ? root[@"json"] : nil;
    NSArray *errors = [jsonDict[@"errors"] isKindOfClass:[NSArray class]] ? jsonDict[@"errors"] : nil;
    if (errors.count > 0) return nil;
    NSDictionary *dataDict = [jsonDict[@"data"] isKindOfClass:[NSDictionary class]] ? jsonDict[@"data"] : nil;
    NSString *url = [dataDict[@"url"] isKindOfClass:[NSString class]] ? dataDict[@"url"] : nil;
    if (url.length > 0) return nil; // Reddit returned a real link-style success; nothing to do.

    NSString *webSocketURL = [dataDict[@"websocket_url"] isKindOfClass:[NSString class]] ? dataDict[@"websocket_url"] : nil;
    NSString *userSubmittedPage = [dataDict[@"user_submitted_page"] isKindOfClass:[NSString class]] ? dataDict[@"user_submitted_page"] : nil;
    if (webSocketURL.length == 0 && userSubmittedPage.length == 0) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (webSocketURL.length > 0) out[@"webSocketURL"] = webSocketURL;
    if (userSubmittedPage.length > 0) out[@"userSubmittedPage"] = userSubmittedPage;
    return out.count > 0 ? out : nil;
}

void ApolloRedditTransformSubmitResponseAsync(NSData *originalData, NSURLRequest *originalRequest, ApolloRedditResponseDataCompletion completion) {
    NSDictionary *context = ApolloRedditMediaSubmitContextFromRequest(originalRequest);
    if (!context) { completion(originalData); return; }

    NSDictionary *links = ApolloRedditParseSubmitResponseLinks(originalData);
    if (!links) { completion(originalData); return; }

    NSMutableDictionary *resolutionContext = [context mutableCopy];
    if (links[@"userSubmittedPage"]) resolutionContext[@"userSubmittedPage"] = links[@"userSubmittedPage"];

    ApolloLog(@"[RedditUpload] Resolving linkID for /api/submit (assetID=%@, sr=%@)", context[@"assetID"] ?: @"(missing)", context[@"subreddit"] ?: @"(missing)");

    ApolloRedditResolveSubmittedLinkID(links[@"webSocketURL"], resolutionContext, ^(NSString *linkID, NSString *postURL) {
        if (linkID.length == 0) {
            ApolloLog(@"[RedditUpload] Could not resolve linkID; delivering Reddit's original response (Apollo will show its native error)");
            completion(originalData);
            return;
        }
        NSData *synth = ApolloRedditSynthesizeSubmitSuccessResponseData(linkID, postURL, resolutionContext);
        if (synth.length == 0) { completion(originalData); return; }
        ApolloLog(@"[RedditUpload] Delivering synthesized /api/submit success response (linkID=%@, %lu bytes)", linkID, (unsigned long)synth.length);
        completion(synth);
    });
}

// MARK: - Comment response transform

static NSString *ApolloMediaURLFromRedditMediaMetadata(NSDictionary *mediaMetadata, NSString *assetID, BOOL requireValid, NSString **outStatus) {
    if (outStatus) *outStatus = nil;
    if (![mediaMetadata isKindOfClass:[NSDictionary class]] || assetID.length == 0) return nil;
    NSDictionary *entry = [mediaMetadata[assetID] isKindOfClass:[NSDictionary class]] ? mediaMetadata[assetID] : nil;
    if (!entry) return nil;

    NSString *status = [entry[@"status"] isKindOfClass:[NSString class]] ? entry[@"status"] : nil;
    if (outStatus) *outStatus = status;
    if (requireValid && ![status isEqualToString:@"valid"]) return nil;

    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    NSString *urlString = nil;
    if (source) {
        urlString = [source[@"u"] isKindOfClass:[NSString class]] ? source[@"u"] : nil;
        if (!urlString) urlString = [source[@"gif"] isKindOfClass:[NSString class]] ? source[@"gif"] : nil;
        if (!urlString) urlString = [source[@"mp4"] isKindOfClass:[NSString class]] ? source[@"mp4"] : nil;
    }
    NSArray *previews = [entry[@"p"] isKindOfClass:[NSArray class]] ? entry[@"p"] : nil;
    if (!urlString && previews.count > 0) {
        NSDictionary *preview = [previews.lastObject isKindOfClass:[NSDictionary class]] ? previews.lastObject : nil;
        urlString = [preview[@"u"] isKindOfClass:[NSString class]] ? preview[@"u"] : nil;
    }
    return ApolloDecodedRedditMediaURLString(urlString);
}

static NSString *ApolloMediaAssetIDFromComment(NSDictionary *comment) {
    NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
    NSString *assetID = [mediaMetadata.allKeys.firstObject isKindOfClass:[NSString class]] ? mediaMetadata.allKeys.firstObject : nil;
    return assetID;
}

static NSString *ApolloBestDisplayURLForRedditComment(NSDictionary *comment, BOOL allowFallback, NSString **outAssetID, NSString **outStatus) {
    if (outAssetID) *outAssetID = nil;
    if (outStatus) *outStatus = nil;

    NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
    NSString *assetID = ApolloMediaAssetIDFromComment(comment);
    if (outAssetID) *outAssetID = assetID;

    NSString *status = nil;
    NSString *mediaURL = ApolloMediaURLFromRedditMediaMetadata(mediaMetadata, assetID, YES, &status);
    if (outStatus) *outStatus = status;
    if (mediaURL.length > 0) return mediaURL;

    NSString *body = [comment[@"body"] isKindOfClass:[NSString class]] ? comment[@"body"] : nil;
    if (ApolloStringIsRedditDisplayMediaURL(body)) return ApolloDecodedRedditMediaURLString(body);
    return allowFallback ? ApolloRedditUploadFallbackURLForAssetID(assetID) : nil;
}

static NSString *ApolloCanonicalDisplayURLForRedditMedia(NSString *assetID, NSString *authoritativeURL, NSString *mediaStatus) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(authoritativeURL);
    NSString *authoritativeHost = ApolloHostForRedditMediaURL(decoded);
    if ([mediaStatus isEqualToString:@"valid"] && [authoritativeHost isEqualToString:@"i.redd.it"] && decoded.length > 0) {
        return ApolloRedditMediaURLByStrippingQuery(decoded);
    }
    NSString *fallbackURL = ApolloRedditUploadFallbackURLForAssetID(assetID);
    if (fallbackURL.length > 0) return fallbackURL;
    return ApolloRedditMediaURLByStrippingQuery(decoded);
}

static void ApolloPopulateRedditCommentDisplayBody(NSMutableDictionary *comment, NSString *mediaURL) {
    if (mediaURL.length == 0) return;

    NSString *body = [comment[@"body"] isKindOfClass:[NSString class]] ? comment[@"body"] : nil;
    BOOL replaceBody = body.length == 0 || [body containsString:@"Processing img "] || ApolloStringContainsRedditUploadedMedia(body) || ApolloStringIsRedditDisplayMediaURL(body);
    if (replaceBody) comment[@"body"] = mediaURL;

    NSString *bodyHTML = [comment[@"body_html"] isKindOfClass:[NSString class]] ? comment[@"body_html"] : nil;
    if (bodyHTML.length == 0 || [bodyHTML containsString:@"Processing img "] || ApolloStringContainsRedditUploadedMedia(bodyHTML)
        || ApolloStringIsRedditDisplayMediaURL(bodyHTML) || [bodyHTML containsString:@"preview.redd.it/"] || [bodyHTML containsString:@"i.redd.it/"]) {
        NSString *escaped = ApolloHTMLEscapedString(mediaURL);
        NSString *visible = ApolloDecodedRedditMediaURLString(mediaURL);
        visible = [visible stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
        visible = [visible stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
        comment[@"body_html"] = [NSString stringWithFormat:@"<div class=\"md\"><p><a href=\"%@\">%@</a></p>\n</div>", escaped, visible.length > 0 ? visible : escaped];
    }
}

// Async fetch the latest copy of a comment via /api/info.
typedef void (^ApolloRedditCommentFetchCompletion)(NSMutableDictionary *fetchedComment);
static void ApolloRedditFetchCommentByFullName(NSString *fullName, ApolloRedditCommentFetchCompletion completion) {
    if (fullName.length == 0 || sLatestRedditBearerToken.length == 0) { completion(nil); return; }

    NSString *encoded = [fullName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: fullName;
    NSURL *url = [NSURL URLWithString:[@"https://oauth.reddit.com/api/info?id=" stringByAppendingString:encoded]];
    if (!url) { completion(nil); return; }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2.0];
    [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : defaultUserAgent;
    if (userAgent.length > 0) [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || status < 200 || status >= 300 || data.length == 0) { completion(nil); return; }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *listingData = [json isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)json)[@"data"] : nil;
        NSArray *children = [listingData isKindOfClass:[NSDictionary class]] ? listingData[@"children"] : nil;
        for (id child in children) {
            NSDictionary *childDict = [child isKindOfClass:[NSDictionary class]] ? child : nil;
            NSDictionary *fetched = [childDict[@"data"] isKindOfClass:[NSDictionary class]] ? childDict[@"data"] : nil;
            if ([[fetched[@"name"] isKindOfClass:[NSString class]] ? fetched[@"name"] : @"" isEqualToString:fullName]) {
                completion([fetched mutableCopy]);
                return;
            }
        }
        completion(nil);
    }] resume];
}

// Wraps a comment dict in Reddit's standard /api/comment success envelope.
static NSData *ApolloRedditWrapCommentForApollo(NSMutableDictionary *comment) {
    if (![comment[@"body"] isKindOfClass:[NSString class]]) {
        NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
        NSString *mediaID = mediaMetadata.allKeys.firstObject;
        comment[@"body"] = mediaID.length > 0 ? [NSString stringWithFormat:@"*Processing img %@...*", mediaID] : @"";
    }
    if (![comment[@"body_html"] isKindOfClass:[NSString class]]) comment[@"body_html"] = @"";

    NSDictionary *wrapped = @{ @"json": @{ @"errors": @[], @"data": @{ @"things": @[ @{ @"kind": @"t1", @"data": comment } ] } } };
    return [NSJSONSerialization dataWithJSONObject:wrapped options:0 error:nil];
}

static void ApolloRedditPopulateAndDeliverComment(NSMutableDictionary *comment, ApolloRedditResponseDataCompletion completion) {
    NSString *assetID = nil, *mediaStatus = nil;
    NSString *mediaURL = ApolloBestDisplayURLForRedditComment(comment, YES, &assetID, &mediaStatus);
    if (mediaURL.length > 0) {
        NSString *cardURL = ApolloCanonicalDisplayURLForRedditMedia(assetID, mediaURL, mediaStatus);
        ApolloPopulateRedditCommentDisplayBody(comment, cardURL ?: mediaURL);
    }
    NSData *wrapped = ApolloRedditWrapCommentForApollo(comment);
    completion(wrapped.length > 0 ? wrapped : nil);
}

// Async-poll /api/info up to N times, then deliver the hydrated comment (or the
// original with a fallback URL). Never blocks the caller. Worst case ~6.2s.
static void ApolloRedditHydrateAndDeliverComment(NSMutableDictionary *comment, NSUInteger attemptIndex, ApolloRedditResponseDataCompletion completion) {
    NSString *fullName = [comment[@"name"] isKindOfClass:[NSString class]] ? comment[@"name"] : nil;
    NSString *currentMediaURL = ApolloBestDisplayURLForRedditComment(comment, NO, NULL, NULL);

    if (currentMediaURL.length > 0 || ![fullName hasPrefix:@"t1_"] || sLatestRedditBearerToken.length == 0
        || attemptIndex >= kApolloCommentHydrationPollCount) {
        ApolloRedditPopulateAndDeliverComment(comment, completion);
        return;
    }

    NSTimeInterval delay = kApolloCommentHydrationPollDelays[attemptIndex];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ApolloRedditFetchCommentByFullName(fullName, ^(NSMutableDictionary *fetched) {
            if (fetched) {
                NSString *fetchedURL = ApolloBestDisplayURLForRedditComment(fetched, NO, NULL, NULL);
                if (fetchedURL.length > 0) {
                    ApolloLog(@"[RedditUpload] Hydrated /api/comment media URL on attempt %lu", (unsigned long)(attemptIndex + 1));
                    ApolloRedditPopulateAndDeliverComment(fetched, completion);
                    return;
                }
            }
            ApolloRedditHydrateAndDeliverComment(comment, attemptIndex + 1, completion);
        });
    });
}

void ApolloRedditTransformCommentResponseAsync(NSData *originalData, ApolloRedditResponseDataCompletion completion) {
    if (originalData.length == 0) { completion(originalData); return; }

    id json = [NSJSONSerialization JSONObjectWithData:originalData options:NSJSONReadingMutableContainers error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) { completion(originalData); return; }
    NSMutableDictionary *comment = [(NSDictionary *)json mutableCopy];
    if ([comment[@"json"] isKindOfClass:[NSDictionary class]]) { completion(originalData); return; } // Already wrapped.
    if (![[comment[@"name"] isKindOfClass:[NSString class]] ? comment[@"name"] : @"" hasPrefix:@"t1_"]) {
        completion(originalData);
        return;
    }

    // Wrap completion so it fires at most once.
    __block BOOL fired = NO;
    ApolloRedditResponseDataCompletion onceCompletion = ^(NSData *data) {
        @synchronized(ApolloRedditUploadAssetMapLock()) {
            if (fired) return;
            fired = YES;
        }
        completion(data ?: originalData);
    };

    ApolloRedditHydrateAndDeliverComment(comment, 0, onceCompletion);
}

// MARK: - URLSession delegate response transformer (one-time class swizzle)

static void ApolloAppendRedditCommentResponseData(NSURLSessionTask *task, NSData *data) {
    if (!ApolloRedditIsCommentTask(task) || data.length == 0) return;
    NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditCommentResponseDataKey);
    if (!responseData) {
        responseData = [NSMutableData data];
        objc_setAssociatedObject(task, &kApolloRedditCommentResponseDataKey, responseData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [responseData appendData:data];
}

static void ApolloAppendRedditSubmitResponseData(NSURLSessionTask *task, NSData *data) {
    if (!ApolloRedditIsSubmitTask(task) || data.length == 0) return;
    NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditSubmitResponseDataKey);
    if (!responseData) {
        responseData = [NSMutableData data];
        objc_setAssociatedObject(task, &kApolloRedditSubmitResponseDataKey, responseData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [responseData appendData:data];
}

void ApolloRedditInstallResponseTransformerForDelegate(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!cls) return;
    NSString *classKey = NSStringFromClass(cls);

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditResponseTransformerInstalledClasses) sRedditResponseTransformerInstalledClasses = [NSMutableSet new];
        if ([sRedditResponseTransformerInstalledClasses containsObject:classKey]) return;
        [sRedditResponseTransformerInstalledClasses addObject:classKey];
    }

    SEL didReceiveDataSelector = @selector(URLSession:dataTask:didReceiveData:);
    Method didReceiveDataMethod = class_getInstanceMethod(cls, didReceiveDataSelector);
    IMP originalDidReceiveDataIMP = didReceiveDataMethod ? method_getImplementation(didReceiveDataMethod) : NULL;
    const char *didReceiveDataTypes = didReceiveDataMethod ? method_getTypeEncoding(didReceiveDataMethod) : "v@:@@@";
    IMP didReceiveDataIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data) {
        if (ApolloRedditIsCommentTask(dataTask)) { ApolloAppendRedditCommentResponseData(dataTask, data); return; }
        if (ApolloRedditIsSubmitTask(dataTask))  { ApolloAppendRedditSubmitResponseData(dataTask, data); return; }
        if (originalDidReceiveDataIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, dataTask, data);
        }
    });
    class_replaceMethod(cls, didReceiveDataSelector, didReceiveDataIMP, didReceiveDataTypes);

    SEL didCompleteSelector = @selector(URLSession:task:didCompleteWithError:);
    Method didCompleteMethod = class_getInstanceMethod(cls, didCompleteSelector);
    IMP originalDidCompleteIMP = didCompleteMethod ? method_getImplementation(didCompleteMethod) : NULL;
    const char *didCompleteTypes = didCompleteMethod ? method_getTypeEncoding(didCompleteMethod) : "v@:@@@";

    // Re-deliver on the session's delegateQueue to preserve queue affinity for
    // Apollo's delegate callbacks.
    void (^dispatchOriginalDelivery)(NSURLSession *, NSURLSessionTask *, NSData *, NSError *, id) = ^(NSURLSession *session, NSURLSessionTask *task, NSData *data, NSError *error, id selfObject) {
        void (^run)(void) = ^{
            if (data.length > 0 && originalDidReceiveDataIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, (NSURLSessionDataTask *)task, data);
            }
            if (originalDidCompleteIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
            }
        };
        NSOperationQueue *delegateQueue = session.delegateQueue;
        if (delegateQueue) {
            [delegateQueue addOperationWithBlock:run];
        } else {
            run();
        }
    };

    IMP didCompleteIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
        if (ApolloRedditIsCommentTask(task)) {
            NSMutableData *buffered = objc_getAssociatedObject(task, &kApolloRedditCommentResponseDataKey);
            objc_setAssociatedObject(task, &kApolloRedditCommentResponseDataKey, nil, OBJC_ASSOCIATION_ASSIGN);
            ApolloRedditTransformCommentResponseAsync(buffered, ^(NSData *transformed) {
                dispatchOriginalDelivery(session, task, transformed.length > 0 ? transformed : buffered, error, selfObject);
            });
            return;
        }

        if (ApolloRedditIsSubmitTask(task)) {
            NSMutableData *buffered = objc_getAssociatedObject(task, &kApolloRedditSubmitResponseDataKey);
            objc_setAssociatedObject(task, &kApolloRedditSubmitResponseDataKey, nil, OBJC_ASSOCIATION_ASSIGN);
            NSURLRequest *submitRequest = task.originalRequest ?: task.currentRequest;
            ApolloRedditTransformSubmitResponseAsync(buffered, submitRequest, ^(NSData *transformed) {
                dispatchOriginalDelivery(session, task, transformed.length > 0 ? transformed : buffered, error, selfObject);
            });
            return;
        }

        if (originalDidCompleteIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
        }
    });
    class_replaceMethod(cls, didCompleteSelector, didCompleteIMP, didCompleteTypes);

    ApolloLog(@"[RedditUpload] Installed Reddit response transformer on delegate class %@", classKey);
}

// MARK: - Imgur upload interception (redirect to Reddit native upload)

static NSURLRequest *ApolloRedditUploadFastFailRequest(void) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:1/apollo-reddit-upload"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 1.0;
    return request;
}

static NSHTTPURLResponse *ApolloSyntheticImgurHTTPResponse(NSURL *url) {
    return [[NSHTTPURLResponse alloc] initWithURL:url
                                       statusCode:200
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:@{@"Content-Type": @"application/json"}];
}

static void ApolloCompleteRedditNativeImageUpload(NSData *imageData, NSString *filename, NSString *mimeType,
                                                  NSURL *originalURL, void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *userAgent = sUserAgent.length > 0 ? sUserAgent : defaultUserAgent;

    ApolloUploadImageDataToReddit(imageData, filename, mimeType, token, userAgent, ^(NSURL *imageURL, NSString *assetID, NSString *webSocketURL, NSError *error) {
        if (error || !imageURL || assetID.length == 0) {
            ApolloLog(@"[RedditUpload] Upload failed: %@", error.localizedDescription);
            completionHandler(nil, nil, error ?: [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:50
                userInfo:@{NSLocalizedDescriptionKey: @"Reddit media upload did not return a URL and asset ID"}]);
            return;
        }

        NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(filename, mimeType);
        ApolloRecordRedditUploadedMediaAssetID(imageURL, assetID);
        ApolloRecordRedditUploadedMediaInfo(imageURL, assetID, resolvedMIMEType);

        NSData *jsonData = ApolloSyntheticImgurUploadResponseData(imageURL, resolvedMIMEType);
        NSHTTPURLResponse *response = ApolloSyntheticImgurHTTPResponse(originalURL ?: imageURL);
        completionHandler(jsonData, response, nil);
    });
}

// MARK: - Hooks (token capture + upload interception)

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (ApolloIsAuthorizationHeader(field)) {
        ApolloRedditCaptureBearerTokenFromAuthorization(value, @"NSMutableURLRequest setValue:forHTTPHeaderField:");
    }
    %orig;
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (ApolloIsAuthorizationHeader(field)) {
        ApolloRedditCaptureBearerTokenFromAuthorization(value, @"NSMutableURLRequest addValue:forHTTPHeaderField:");
    }
    %orig;
}

%end

%hook NSURLSessionConfiguration

- (void)setHTTPAdditionalHeaders:(NSDictionary *)HTTPAdditionalHeaders {
    ApolloRedditCaptureBearerTokenFromHeaderDictionary(HTTPAdditionalHeaders, @"NSURLSessionConfiguration HTTPAdditionalHeaders");
    %orig;
}

%end

%hook NSURLSession

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession uploadTaskWithRequest:fromData:");

    if (sImageUploadProvider != ImageUploadProviderReddit || !completionHandler || !ApolloIsImgurImageUploadRequest(request)) return %orig;
    if (sLatestRedditBearerToken.length == 0) {
        ApolloLog(@"[RedditUpload] No captured Reddit bearer token yet; using Imgur upload");
        return %orig;
    }

    NSString *mimeType = ApolloMediaMIMETypeForFilename(nil, [request valueForHTTPHeaderField:@"Content-Type"]);
    NSString *extension = ApolloRedditUploadExtensionForMIMEType(mimeType);
    NSString *filename = [@"apollo-upload" stringByAppendingPathExtension:extension];

    ApolloLog(@"[RedditUpload] Intercepting Imgur data upload (%lu bytes)", (unsigned long)bodyData.length);

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        ApolloCompleteRedditNativeImageUpload(bodyData, filename, mimeType, request.URL, completionHandler);
    };
    return %orig(ApolloRedditUploadFastFailRequest(), bodyData ?: [NSData data], wrapped);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    ApolloRedditCaptureBearerTokenFromRequest(request, @"NSURLSession uploadTaskWithRequest:fromFile:");

    if (sImageUploadProvider != ImageUploadProviderReddit || !completionHandler || !ApolloIsImgurImageUploadRequest(request)) return %orig;
    if (sLatestRedditBearerToken.length == 0) {
        ApolloLog(@"[RedditUpload] No captured Reddit bearer token yet; using Imgur upload");
        return %orig;
    }

    NSString *filename = fileURL.lastPathComponent.length > 0 ? fileURL.lastPathComponent : @"apollo-upload.jpg";
    NSString *mimeType = ApolloMediaMIMETypeForFilename(filename, [request valueForHTTPHeaderField:@"Content-Type"]);

    ApolloLog(@"[RedditUpload] Intercepting Imgur file upload: %@", filename);

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        NSError *readError = nil;
        NSData *imageData = [NSData dataWithContentsOfURL:fileURL options:0 error:&readError];
        if (readError || imageData.length == 0) {
            completionHandler(nil, nil, readError ?: [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:51
                userInfo:@{NSLocalizedDescriptionKey: @"Upload file was empty"}]);
            return;
        }
        ApolloCompleteRedditNativeImageUpload(imageData, filename, mimeType, request.URL, completionHandler);
    };
    return %orig(ApolloRedditUploadFastFailRequest(), fileURL, wrapped);
}

%end

// MARK: - Bypass Apollo's pre-upload image downscale (full-resolution uploads)
//
// Apollo conservatively caps uploads at 2000 px max dimension and 0.75 JPEG quality.
// These limits are anachronistic — Imgur now accepts 50 MB and Reddit native ~20 MB.
// We rebind the two ImageIO C functions Apollo uses for upload prep and rewrite their
// options dicts so the resulting CGImage is full-resolution and the JPEG is full
// quality. The hooks only mutate dicts that already opted into the constrained
// behavior, so non-upload ImageIO callers (which don't pass these keys) are untouched.
// EXIF orientation handling is preserved.

static CGImageRef (*orig_CGImageSourceCreateThumbnailAtIndex)(CGImageSourceRef, size_t, CFDictionaryRef) = NULL;
static bool (*orig_CGImageDestinationAddImage)(CGImageDestinationRef, CGImageRef, CFDictionaryRef) = NULL;

static CFDictionaryRef ApolloCopyOptionsWithReplacement(CFDictionaryRef options, CFStringRef key, CFTypeRef newValue) {
    if (!options || !key || !newValue) return options ? (CFDictionaryRef)CFRetain(options) : NULL;
    CFMutableDictionaryRef mutableCopy = CFDictionaryCreateMutableCopy(NULL, 0, options);
    CFDictionarySetValue(mutableCopy, key, newValue);
    return mutableCopy;
}

static CGImageRef hooked_CGImageSourceCreateThumbnailAtIndex(CGImageSourceRef isrc, size_t index, CFDictionaryRef options) {
    if (!options || !CFDictionaryContainsKey(options, kCGImageSourceThumbnailMaxPixelSize)) {
        return orig_CGImageSourceCreateThumbnailAtIndex(isrc, index, options);
    }

    int largeMax = 32768;
    CFNumberRef largeMaxRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &largeMax);
    CFDictionaryRef newOptions = ApolloCopyOptionsWithReplacement(options, kCGImageSourceThumbnailMaxPixelSize, largeMaxRef);
    CFRelease(largeMaxRef);

    ApolloLog(@"[ImageUploadHost] Bypassing Apollo's 2000px image-prep cap for full-resolution upload");
    CGImageRef result = orig_CGImageSourceCreateThumbnailAtIndex(isrc, index, newOptions);
    if (newOptions) CFRelease(newOptions);
    return result;
}

static bool hooked_CGImageDestinationAddImage(CGImageDestinationRef destination, CGImageRef image, CFDictionaryRef properties) {
    if (!properties || !CFDictionaryContainsKey(properties, kCGImageDestinationLossyCompressionQuality)) {
        return orig_CGImageDestinationAddImage(destination, image, properties);
    }

    double full = 1.0;
    CFNumberRef fullRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &full);
    CFDictionaryRef newProperties = ApolloCopyOptionsWithReplacement(properties, kCGImageDestinationLossyCompressionQuality, fullRef);
    CFRelease(fullRef);

    ApolloLog(@"[ImageUploadHost] Bumping Apollo's image-prep JPEG quality from 0.75 to 1.0 for full-fidelity upload");
    bool result = orig_CGImageDestinationAddImage(destination, image, newProperties);
    if (newProperties) CFRelease(newProperties);
    return result;
}

__attribute__((constructor))
static void ApolloImageUploadHostInstallImageIOHooks(void) {
    rebind_symbols((struct rebinding[2]) {
        {"CGImageSourceCreateThumbnailAtIndex",
            (void *)hooked_CGImageSourceCreateThumbnailAtIndex,
            (void **)&orig_CGImageSourceCreateThumbnailAtIndex},
        {"CGImageDestinationAddImage",
            (void *)hooked_CGImageDestinationAddImage,
            (void **)&orig_CGImageDestinationAddImage},
    }, 2);
}
