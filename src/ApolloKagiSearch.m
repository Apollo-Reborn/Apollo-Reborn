#import "ApolloKagiSearch.h"

#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <os/lock.h>

#import "ApolloCommon.h"
#import "ApolloKagiSearchParsing.h"
#import "ApolloWebTextDecoding.h"

NSString *const ApolloKagiSessionTokenDidChangeNotification = @"ApolloKagiSessionTokenDidChangeNotification";
NSString *const ApolloKagiSessionKeychainService = @"com.christianselig.Apollo.kagi";
NSString *const ApolloKagiSessionKeychainAccount = @"sessionToken";

// One results page is ~175 KB of server-rendered HTML and usually arrives in
// well under a second; the rest is headroom for slow networks. The clock
// covers the page and the Reddit read that follows it.
static const NSTimeInterval kApolloKagiSearchTimeout = 25.0;
static const NSUInteger kApolloKagiMaximumPageBytes = 3 * 1024 * 1024;
// An empty Kagi snippet is filled from the post's own text, up to this long
// (the card shows three lines of it).
static const NSUInteger kApolloKagiSnippetFromBodyLength = 320;

static NSError *ApolloKagiSearchError(ApolloGoogleSearchErrorCode code, NSString *description) {
    return [NSError errorWithDomain:ApolloGoogleSearchErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @""}];
}

#pragma mark - Session token (Keychain)

static os_unfair_lock sApolloKagiTokenLock = OS_UNFAIR_LOCK_INIT;
static NSString *sApolloKagiToken;
static BOOL sApolloKagiTokenLoaded;

static NSString *ApolloKagiKeychainRead(OSStatus *outStatus) {
    CFDictionaryRef query = ApolloCreateGenericPasswordDataQuery((__bridge CFStringRef)ApolloKagiSessionKeychainService,
                                                                 (__bridge CFStringRef)ApolloKagiSessionKeychainAccount);
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching(query, &result);
    CFRelease(query);
    if (outStatus) *outStatus = status;
    if (status != errSecSuccess || !result) {
        if (result) CFRelease(result);
        return nil;
    }
    if (CFGetTypeID(result) != CFDataGetTypeID()) {
        CFRelease(result);
        return nil;
    }
    NSData *data = CFBridgingRelease(result);
    NSString *token = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return token.length ? token : nil;
}

NSString *ApolloKagiSessionToken(void) {
    os_unfair_lock_lock(&sApolloKagiTokenLock);
    if (!sApolloKagiTokenLoaded) {
        OSStatus status = errSecSuccess;
        sApolloKagiToken = ApolloKagiKeychainRead(&status);
        // Only a definite answer is cached: a read that failed because the
        // device hasn't been unlocked since boot (or any other transient
        // error) is tried again next time.
        sApolloKagiTokenLoaded = status == errSecSuccess || status == errSecItemNotFound;
        if (!sApolloKagiTokenLoaded) ApolloLog(@"[KagiSearch] Session Link read failed (OSStatus %d)", (int)status);
    }
    NSString *token = sApolloKagiToken;
    os_unfair_lock_unlock(&sApolloKagiTokenLock);
    return token;
}

BOOL ApolloKagiHasSessionToken(void) {
    return ApolloKagiSessionToken().length > 0;
}

BOOL ApolloKagiSetSessionToken(NSString *token) {
    OSStatus status;
    if (token.length) {
        NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
        status = ApolloUpsertGenericPasswordData((__bridge CFStringRef)ApolloKagiSessionKeychainService,
                                                 (__bridge CFStringRef)ApolloKagiSessionKeychainAccount,
                                                 data, kSecAttrAccessibleAfterFirstUnlock);
    } else {
        CFDictionaryRef identity = ApolloCreateGenericPasswordIdentity((__bridge CFStringRef)ApolloKagiSessionKeychainService,
                                                                        (__bridge CFStringRef)ApolloKagiSessionKeychainAccount);
        status = SecItemDelete(identity);
        CFRelease(identity);
        if (status == errSecItemNotFound) status = errSecSuccess;
    }
    if (status != errSecSuccess) {
        ApolloLog(@"[KagiSearch] Session Link %@ failed (OSStatus %d)", token.length ? @"save" : @"removal", (int)status);
        return NO;
    }
    os_unfair_lock_lock(&sApolloKagiTokenLock);
    sApolloKagiToken = token.length ? [token copy] : nil;
    sApolloKagiTokenLoaded = YES;
    os_unfair_lock_unlock(&sApolloKagiTokenLock);
    ApolloLog(@"[KagiSearch] Session Link %@", token.length ? [NSString stringWithFormat:@"saved (%lu chars)", (unsigned long)token.length] : @"removed");
    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:ApolloKagiSessionTokenDidChangeNotification object:nil];
    };
    if (NSThread.isMainThread) post();
    else dispatch_async(dispatch_get_main_queue(), post);
    return YES;
}

#pragma mark - Requests

// Kagi serves the same markup to every browser; an ordinary iPhone Safari
// identity keeps the request looking like the subscriber's own browser.
static NSString *ApolloKagiUserAgent(void) {
    NSArray<NSString *> *parts = [UIDevice.currentDevice.systemVersion componentsSeparatedByString:@"."];
    NSString *major = parts.count > 0 ? parts[0] : @"18";
    NSString *minor = parts.count > 1 ? parts[1] : @"0";
    return [NSString stringWithFormat:@"Mozilla/5.0 (iPhone; CPU iPhone OS %@_%@ like Mac OS X) AppleWebKit/605.1.15 "
            "(KHTML, like Gecko) Version/%@.%@ Mobile/15E148 Safari/604.1", major, minor, major, minor];
}

// The session rides in the kagi_session cookie, set by hand: the request
// never touches (or fills) the app's shared cookie jar.
static NSMutableURLRequest *ApolloKagiRequest(NSURL *url, NSString *token, NSTimeInterval timeout) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:timeout];
    request.HTTPShouldHandleCookies = NO;
    [request setValue:[@"kagi_session=" stringByAppendingString:token] forHTTPHeaderField:@"Cookie"];
    [request setValue:ApolloKagiUserAgent() forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"text/html,application/xhtml+xml" forHTTPHeaderField:@"Accept"];
    return request;
}

// Kagi answers a request without a valid session by redirecting it to its
// landing page (kagi.com/welcome), its Cloudflare Turnstile check
// (kagi.com/turnstile) or to sign-in (kagi.com/signin → account.kagi.com).
// Which one depends on the client (seen both from different networks).
// Redirects are followed, so the final URL tells.
static BOOL ApolloKagiResponseIsSignedOut(NSHTTPURLResponse *response) {
    if (response.statusCode == 401 || response.statusCode == 403) return YES;
    NSString *host = response.URL.host.lowercaseString ?: @"";
    NSString *path = response.URL.path.lowercaseString ?: @"";
    if ([host isEqualToString:@"account.kagi.com"]) return YES;
    return [path hasPrefix:@"/welcome"] || [path hasPrefix:@"/turnstile"] || [path hasPrefix:@"/signin"] ||
           [path hasPrefix:@"/loginname"];
}

static NSURL *ApolloKagiSearchURL(NSString *rawQuery, ApolloGoogleSearchOptions *options, NSUInteger page) {
    // Kagi reads the same operators Google does: site:, site:reddit.com/r/x,
    // (… OR …), "quotes", -word.
    NSString *query = ApolloGoogleSearchComposeQuery(rawQuery);
    if (query.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://kagi.com/html/search"];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"q" value:query]];
    NSString *range = nil;
    switch (options.timeRange) {
        case ApolloGoogleSearchTimeRangeDay: range = @"1"; break;
        case ApolloGoogleSearchTimeRangeWeek: range = @"2"; break;
        case ApolloGoogleSearchTimeRangeMonth: range = @"3"; break;
        case ApolloGoogleSearchTimeRangeYear: range = @"4"; break;
        case ApolloGoogleSearchTimeRangeAny: default: break;
    }
    if (range) [items addObject:[NSURLQueryItem queryItemWithName:@"dr" value:range]];
    if (options.exactWords) [items addObject:[NSURLQueryItem queryItemWithName:@"verbatim" value:@"1"]];
    // Page N is Kagi's "More Results" batch N+1.
    if (page > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"batch"
                                                     value:[NSString stringWithFormat:@"%lu", (unsigned long)(page + 1)]]];
    }
    components.queryItems = items;
    // NSURLComponents leaves '+' alone in query values, which would read as a
    // space ("c++" → "c  "). Encode it explicitly.
    components.percentEncodedQuery =
        [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return components.URL;
}

void ApolloKagiCheckSessionToken(NSString *token, void (^completion)(ApolloKagiSessionCheck result, NSError *error)) {
    // An account page, not a search: it answers "signed in?" without using up
    // a search on the subscriber's plan.
    NSURL *url = [NSURL URLWithString:@"https://kagi.com/settings/user_details"];
    NSMutableURLRequest *request = ApolloKagiRequest(url, token ?: @"", 15.0);
    ApolloStartBoundedDataRequest(request, kApolloKagiMaximumPageBytes, nil, dispatch_get_main_queue(),
                                  ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        ApolloKagiSessionCheck result;
        if (response && ApolloKagiResponseIsSignedOut(response)) result = ApolloKagiSessionCheckRejected;
        else if (!error && response.statusCode >= 200 && response.statusCode < 300) result = ApolloKagiSessionCheckValid;
        else result = ApolloKagiSessionCheckUnreachable;
        ApolloLog(@"[KagiSearch] Session Link check: status=%ld result=%ld%@", (long)response.statusCode, (long)result,
                  error ? [@" error=" stringByAppendingString:error.localizedDescription] : @"");
        completion(result, result == ApolloKagiSessionCheckUnreachable ? error : nil);
    });
}

#pragma mark - Sim debug knobs

#if APOLLO_SIM_BUILD
static NSString *sApolloKagiDebugFixturePath;   // a saved results page instead of the network
static NSString *sApolloKagiDebugExpiredPath;   // answer every search as signed out, sent to this kagi.com path
static BOOL sApolloKagiDebugFailNext;
static BOOL sApolloKagiDebugSkipRedditInfo;

// The raw page, for fixing the parser: the session token is scrubbed first
// (Kagi echoes it in the page head's OpenSearch link).
static void ApolloKagiDebugDumpPage(NSString *html, NSString *token) {
    NSString *scrubbed = token.length ? [html stringByReplacingOccurrencesOfString:token withString:@"REDACTED"] : html;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"apollo-ksearch-last.html"];
    [scrubbed writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ApolloLog(@"[KagiSearch][debug] page HTML (%lu chars) → %@", (unsigned long)scrubbed.length, path);
}
#endif

#pragma mark - Session

@implementation ApolloKagiSearchSession {
    NSUInteger _generation;
    BOOL _loading;
    ApolloGoogleSearchCompletion _completion;
    NSUInteger _page;
    NSURLSessionDataTask *_pageTask;
    NSURLSessionDataTask *_infoTask;
}

- (void)dealloc {
    [_pageTask cancel];
    [_infoTask cancel];
}

- (BOOL)isLoading {
    return _loading;
}

- (void)searchQuery:(NSString *)query
            options:(ApolloGoogleSearchOptions *)options
               page:(NSUInteger)page
         completion:(ApolloGoogleSearchCompletion)completion {
    [self cancel];

    NSURL *url = ApolloKagiSearchURL(query, options, page);
    NSString *token = ApolloKagiSessionToken();
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(@[], NO, nil);
        });
        return;
    }
    if (!token.length) {
        NSError *error = ApolloKagiSearchError(ApolloGoogleSearchErrorSessionExpired, @"No Kagi Session Link is saved.");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(@[], NO, error);
        });
        return;
    }

    NSUInteger generation = ++_generation;
    _completion = [completion copy];
    _page = page;
    _loading = YES;
    // The query goes to the log like Google mode's does; the token never does
    // (it's a cookie, not part of the URL).
    ApolloLog(@"[KagiSearch] search page %lu: %@", (unsigned long)page, url.absoluteString);
    [self armDeadline:generation];

#if APOLLO_SIM_BUILD
    if (sApolloKagiDebugFailNext) {
        sApolloKagiDebugFailNext = NO;
        NSError *error = ApolloKagiSearchError(ApolloGoogleSearchErrorNetwork, @"The Internet connection appears to be offline.");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation == self->_generation && self->_loading) [self finishWithResults:nil mayHaveMore:NO error:error];
        });
        return;
    }
    if (sApolloKagiDebugExpiredPath.length || sApolloKagiDebugFixturePath.length) {
        NSString *fixture = sApolloKagiDebugFixturePath.length
            ? [NSString stringWithContentsOfFile:sApolloKagiDebugFixturePath encoding:NSUTF8StringEncoding error:nil] : nil;
        NSURL *finalURL = sApolloKagiDebugExpiredPath.length
            ? [NSURL URLWithString:[@"https://kagi.com" stringByAppendingString:sApolloKagiDebugExpiredPath]] : url;
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:finalURL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Content-Type": @"text/html; charset=utf-8"}];
        ApolloLog(@"[KagiSearch][debug] %@", sApolloKagiDebugExpiredPath.length ? @"answering as signed out"
                  : [NSString stringWithFormat:@"loading fixture page (%lu chars)", (unsigned long)fixture.length]);
        NSData *data = [fixture ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self handlePage:data response:response error:nil token:token generation:generation];
        });
        return;
    }
#endif

    NSMutableURLRequest *request = ApolloKagiRequest(url, token, kApolloKagiSearchTimeout);
    __weak typeof(self) weakSelf = self;
    _pageTask = ApolloStartBoundedDataRequest(request, kApolloKagiMaximumPageBytes, nil, dispatch_get_main_queue(),
                                              ^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        [weakSelf handlePage:data response:response error:error token:token generation:generation];
    });
}

- (void)cancel {
    _generation++;
    _completion = nil;
    _loading = NO;
    [_pageTask cancel];
    _pageTask = nil;
    [_infoTask cancel];
    _infoTask = nil;
}

// A deadline on its own timer, covering the page and the Reddit read, so a
// search always ends (with Try Again) even if a request never answers.
- (void)armDeadline:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kApolloKagiSearchTimeout + 0.5) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_generation || !strongSelf->_loading) return;
        ApolloLog(@"[KagiSearch] timed out");
        [strongSelf finishWithResults:nil mayHaveMore:NO
                                error:ApolloKagiSearchError(ApolloGoogleSearchErrorTimedOut, @"Kagi took too long to respond.")];
    });
}

- (void)handlePage:(NSData *)data
          response:(NSHTTPURLResponse *)response
             error:(NSError *)error
             token:(NSString *)token
        generation:(NSUInteger)generation {
    if (generation != _generation || !_loading) return;
    _pageTask = nil;

    if (response && ApolloKagiResponseIsSignedOut(response)) {
        ApolloLog(@"[KagiSearch] Kagi didn't accept the Session Link (status %ld, sent to %@%@)",
                  (long)response.statusCode, response.URL.host, response.URL.path);
        [self finishWithResults:nil mayHaveMore:NO
                          error:ApolloKagiSearchError(ApolloGoogleSearchErrorSessionExpired,
                                                      @"Kagi didn't accept the saved Session Link.")];
        return;
    }
    if (error || !data) {
        BOOL timedOut = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorTimedOut;
        NSString *description = error.localizedDescription ?: @"Couldn't reach Kagi.";
        if (response.statusCode >= 400) {
            description = [NSString stringWithFormat:@"Kagi returned an error (HTTP %ld).", (long)response.statusCode];
        }
        ApolloLogError(@"[KagiSearch] request failed: status=%ld %@ %ld", (long)response.statusCode,
                  error.domain, (long)error.code);
        [self finishWithResults:nil mayHaveMore:NO
                          error:ApolloKagiSearchError(timedOut ? ApolloGoogleSearchErrorTimedOut : ApolloGoogleSearchErrorNetwork,
                                                      timedOut ? @"Kagi took too long to respond." : description)];
        return;
    }

    // ~175 KB of HTML: parse off the main thread.
    NSUInteger page = _page;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *html = ApolloWebTextFromData(data, response, NULL) ?: @"";
        ApolloKagiParsedPage *parsed = ApolloKagiParseResultsHTML(html);
        NSMutableArray<ApolloGoogleSearchResult *> *results = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSUInteger skipped = 0;
        for (ApolloKagiParsedResult *raw in parsed.results) {
            NSURL *url = [NSURL URLWithString:raw.URLString];
            ApolloGoogleSearchResult *result = url ? ApolloGoogleSearchResultForURL(url) : nil;
            if (!result) {
                skipped++;   // not Reddit, or a Reddit page Apollo can't show (home page, /domain/, ...)
                continue;
            }
            NSString *key = result.dedupeKey;
            if (key.length && [seen containsObject:key]) continue;
            if (key.length) [seen addObject:key];
            result.title = ApolloGoogleSearchCleanTitle(raw.title);
            result.snippet = raw.snippet;
            result.engineMeta = raw.dateText;
            [results addObject:result];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_generation || !strongSelf->_loading) return;
#if APOLLO_SIM_BUILD
            ApolloKagiDebugDumpPage(html, token);
#endif
            switch (parsed.kind) {
                case ApolloKagiPageKindSignedOut:
                    ApolloLog(@"[KagiSearch] results page is Kagi's signed-out page");
                    [strongSelf finishWithResults:nil mayHaveMore:NO
                                            error:ApolloKagiSearchError(ApolloGoogleSearchErrorSessionExpired,
                                                                        @"Kagi didn't accept the saved Session Link.")];
                    return;
                case ApolloKagiPageKindUnreadable:
                    ApolloLog(@"[KagiSearch] results page (%lu chars) has no readable results; the parser needs updating",
                              (unsigned long)html.length);
                    [strongSelf finishWithResults:nil mayHaveMore:NO
                                            error:ApolloKagiSearchError(ApolloGoogleSearchErrorUnreadable,
                                                                        @"Kagi's results page couldn't be read.")];
                    return;
                case ApolloKagiPageKindResults:
                    break;
            }
            ApolloLog(@"[KagiSearch] page %lu: %lu result(s) → %lu Reddit result(s) (%lu skipped), more=%d",
                      (unsigned long)page, (unsigned long)parsed.results.count, (unsigned long)results.count,
                      (unsigned long)skipped, parsed.hasMore);
            [strongSelf enrichThenFinish:results mayHaveMore:parsed.hasMore generation:generation];
        });
    });
}

// Every Kagi result links straight to Reddit, so the whole page is read from
// Reddit in one batch before it's shown: the cards open with Reddit's own
// score, comment count and age. A failed read just leaves Kagi's data.
- (void)enrichThenFinish:(NSArray<ApolloGoogleSearchResult *> *)results
             mayHaveMore:(BOOL)more
              generation:(NSUInteger)generation {
    BOOL skip = results.count == 0;
#if APOLLO_SIM_BUILD
    skip = skip || sApolloKagiDebugSkipRedditInfo;
#endif
    if (skip) {
        [self finishWithResults:results mayHaveMore:more error:nil];
        return;
    }
    __weak typeof(self) weakSelf = self;
    _infoTask = ApolloGoogleSearchFetchRedditInfo(results, ^(NSUInteger applied, NSInteger status, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_generation || !strongSelf->_loading) return;
        strongSelf->_infoTask = nil;
        ApolloLog(@"[KagiSearch] Reddit info: status=%ld applied=%lu/%lu%@", (long)status,
                  (unsigned long)applied, (unsigned long)results.count,
                  error ? [@" error=" stringByAppendingString:error.localizedDescription] : @"");
        for (ApolloGoogleSearchResult *result in results) [ApolloKagiSearchSession fillSnippetFromBody:result];
        [strongSelf finishWithResults:results mayHaveMore:more error:nil];
    });
}

// Kagi sometimes has no snippet for a Reddit page (and titles it "Link to
// reddit.com"); Reddit's title and the post's opening lines stand in.
+ (void)fillSnippetFromBody:(ApolloGoogleSearchResult *)result {
    if (result.snippet.length || !result.bodyText.length) return;
    NSString *plain = ApolloGoogleSearchPlainTextFromMarkdown(result.bodyText);
    NSArray<NSString *> *words = [plain componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableString *snippet = [NSMutableString string];
    for (NSString *word in words) {
        if (!word.length) continue;
        if (snippet.length + word.length + 1 > kApolloKagiSnippetFromBodyLength) break;
        if (snippet.length) [snippet appendString:@" "];
        [snippet appendString:word];
    }
    result.snippet = snippet;
}

- (void)resolveResult:(ApolloGoogleSearchResult *)result
       withRedditInfo:(BOOL)withRedditInfo
           completion:(void (^)(NSError *error))completion {
    void (^finish)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    };
    // Kagi results always carry their Reddit URL; there's no link to follow.
    if (!result.URL) {
        finish(ApolloKagiSearchError(ApolloGoogleSearchErrorUnreadable, @"This result has no link."));
        return;
    }
    BOOL skip = !withRedditInfo || result.hasRedditInfo || !result.postID;
#if APOLLO_SIM_BUILD
    skip = skip || sApolloKagiDebugSkipRedditInfo;
#endif
    if (skip) {
        finish(nil);
        return;
    }
    ApolloGoogleSearchFetchRedditInfo(@[result], ^(NSUInteger applied, NSInteger status, NSError *error) {
        ApolloLog(@"[KagiSearch] Reddit info for one result: status=%ld applied=%lu", (long)status, (unsigned long)applied);
        [ApolloKagiSearchSession fillSnippetFromBody:result];
        finish(nil);
    });
}

- (void)finishWithResults:(NSArray<ApolloGoogleSearchResult *> *)results
              mayHaveMore:(BOOL)more
                    error:(NSError *)error {
    ApolloGoogleSearchCompletion completion = _completion;
    _completion = nil;
    _loading = NO;
    _generation++;
    [_pageTask cancel];
    _pageTask = nil;
    [_infoTask cancel];
    _infoTask = nil;
    if (error) ApolloLogError(@"[KagiSearch] failed: %@", error.localizedDescription);
    if (completion) completion(results ?: @[], error ? NO : more, error);
}

@end

#pragma mark - Sim debug bridge

#if APOLLO_SIM_BUILD
static ApolloKagiSearchSession *sApolloKagiDebugSession;

void ApolloKagiSearchDebugRun(NSString *query) {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSUInteger page = 0;
    ApolloGoogleSearchOptions *options = [[ApolloGoogleSearchOptions alloc] init];
    // Optional "p=N t=w x=1 |" prefix before a '|' for page / time / exact.
    NSRange bar = [trimmed rangeOfString:@"|"];
    if (bar.location != NSNotFound) {
        for (NSString *token in [[trimmed substringToIndex:bar.location] componentsSeparatedByString:@" "]) {
            if ([token hasPrefix:@"p="]) page = (NSUInteger)[token substringFromIndex:2].integerValue;
            if ([token isEqualToString:@"t=d"]) options.timeRange = ApolloGoogleSearchTimeRangeDay;
            if ([token isEqualToString:@"t=w"]) options.timeRange = ApolloGoogleSearchTimeRangeWeek;
            if ([token isEqualToString:@"t=m"]) options.timeRange = ApolloGoogleSearchTimeRangeMonth;
            if ([token isEqualToString:@"t=y"]) options.timeRange = ApolloGoogleSearchTimeRangeYear;
            if ([token isEqualToString:@"x=1"]) options.exactWords = YES;
        }
        trimmed = [[trimmed substringFromIndex:bar.location + 1]
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (!sApolloKagiDebugSession) sApolloKagiDebugSession = [[ApolloKagiSearchSession alloc] init];
    ApolloLog(@"[KagiSearch][debug] composed query: %@ (Session Link saved: %d)",
              ApolloGoogleSearchComposeQuery(trimmed), ApolloKagiHasSessionToken());
    [sApolloKagiDebugSession searchQuery:trimmed options:options page:page
                              completion:^(NSArray<ApolloGoogleSearchResult *> *results, BOOL more, NSError *error) {
        ApolloLog(@"[KagiSearch][debug] done: %lu result(s), more=%d, error=%@",
                  (unsigned long)results.count, more, error.localizedDescription ?: @"none");
        for (ApolloGoogleSearchResult *result in results) {
            ApolloLog(@"[KagiSearch][debug] %@ | %@ | reddit=%d score=%ld comments=%ld created=%@ author=%@ meta=%@ | snippet=%@",
                      result.URL.absoluteString, result.redditTitle ?: result.title, result.hasRedditInfo,
                      (long)result.score, (long)result.commentCount, result.created, result.author,
                      result.engineMeta, result.snippet);
        }
    }];
}

void ApolloKagiSearchDebugConfigure(NSString *arguments) {
    for (NSString *token in [arguments componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if ([token hasPrefix:@"fixture="]) {
            NSString *path = [token substringFromIndex:8];
            sApolloKagiDebugFixturePath = [path isEqualToString:@"off"] ? nil : path;
        } else if ([token hasPrefix:@"expired="]) {
            // "1" is the Turnstile check, "welcome" the landing page (Kagi
            // picks one per network, so both need covering).
            NSString *value = [token substringFromIndex:8];
            sApolloKagiDebugExpiredPath = [value isEqualToString:@"1"]         ? @"/turnstile?r=/html/search"
                                        : [value isEqualToString:@"welcome"] ? @"/welcome"
                                                                             : nil;
        } else if ([token isEqualToString:@"fail"]) {
            sApolloKagiDebugFailNext = YES;
        } else if ([token hasPrefix:@"info="]) {
            sApolloKagiDebugSkipRedditInfo = [[token substringFromIndex:5] isEqualToString:@"0"];
        } else if ([token hasPrefix:@"token="]) {
            // Seeds (or with "token=off" removes) the Session Link without the
            // sheet, for driving the sim without taps. Never logged.
            NSString *value = [token substringFromIndex:6];
            NSString *normalized = [value isEqualToString:@"off"] ? nil : ApolloKagiNormalizeSessionToken(value);
            if ([value isEqualToString:@"off"] || normalized) ApolloKagiSetSessionToken(normalized);
            else ApolloLog(@"[KagiSearch][debug] token= isn't a Session Link");
        }
    }
    ApolloLog(@"[KagiSearch][debug] fixture=%@ expired=%@ failNext=%d redditInfo=%d",
              sApolloKagiDebugFixturePath ?: @"off", sApolloKagiDebugExpiredPath ?: @"off", sApolloKagiDebugFailNext,
              !sApolloKagiDebugSkipRedditInfo);
}
#endif
