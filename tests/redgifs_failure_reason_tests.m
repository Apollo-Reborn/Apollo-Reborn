#import <Foundation/Foundation.h>

#import "ApolloRedgifsFailureReason.h"

// Host-side tests for ApolloRedgifsFailureReason.m: the API answers and media
// errors below are the shapes recorded from api.redgifs.com and from
// AVFoundation in the simulator (see the header).

static int sFailures = 0;

static void Expect(BOOL condition, NSString *label) {
    if (!condition) {
        sFailures++;
        fprintf(stderr, "FAIL: %s\n", label.UTF8String);
    }
}

static void ExpectFailure(ApolloRedgifsFailure failure, ApolloRedgifsFailureKind kind, NSInteger status, NSString *label) {
    BOOL ok = failure.kind == kind && failure.httpStatus == status;
    if (!ok) {
        sFailures++;
        fprintf(stderr, "FAIL: %s (got kind %ld status %ld, want kind %ld status %ld)\n", label.UTF8String,
                (long)failure.kind, (long)failure.httpStatus, (long)kind, (long)status);
    }
}

static NSHTTPURLResponse *Response(NSInteger status) {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://api.redgifs.com/v2/gifs/abc"]
                                       statusCode:status
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:@{@"Content-Type": @"application/json"}];
}

static NSData *JSON(NSString *string) {
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}

static NSError *URLError(NSInteger code, NSError *underlying) {
    NSDictionary *info = underlying ? @{NSUnderlyingErrorKey: underlying} : @{};
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:info];
}

static void TestAPIResults(void) {
    ExpectFailure(ApolloRedgifsFailureForAPIResult(JSON(@"{\"error\":{\"code\":\"GifDeleted\",\"description\":\"The requested gif was deleted and cannot be accessed.\"}}"), Response(410), nil),
                  ApolloRedgifsFailureKindDeleted, 410, @"410 GifDeleted");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(JSON(@"{\"error\":{\"code\":\"GifNotFound\",\"description\":\"Gif not found.\"}}"), Response(404), nil),
                  ApolloRedgifsFailureKindNotFound, 404, @"404 GifNotFound");
    // The body's code wins over the status.
    ExpectFailure(ApolloRedgifsFailureForAPIResult(JSON(@"{\"error\":{\"code\":\"GifDeleted\"}}"), Response(404), nil),
                  ApolloRedgifsFailureKindDeleted, 404, @"GifDeleted code on a 404");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(JSON(@"<html>gone</html>"), Response(410), nil),
                  ApolloRedgifsFailureKindDeleted, 410, @"410 without a JSON body");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(nil, Response(451), nil),
                  ApolloRedgifsFailureKindRegion, 451, @"451");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(JSON(@"{\"error\":{\"code\":\"Unauthorized\",\"description\":\"Could not authenticate your request.\"}}"), Response(401), nil),
                  ApolloRedgifsFailureKindHTTPStatus, 401, @"401");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(nil, Response(503), nil),
                  ApolloRedgifsFailureKindHTTPStatus, 503, @"503");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(JSON(@"{\"gif\":{\"type\":1,\"duration\":21.9,\"hasAudio\":false}}"), Response(200), nil),
                  ApolloRedgifsFailureKindNone, 200, @"200 video");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(JSON(@"{\"gif\":{\"type\":2,\"duration\":null,\"hasAudio\":false}}"), Response(200), nil),
                  ApolloRedgifsFailureKindImage, 200, @"200 image record");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(JSON(@"{\"token\":\"abc\"}"), Response(200), nil),
                  ApolloRedgifsFailureKindNone, 200, @"200 token");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(nil, nil, URLError(NSURLErrorCannotFindHost, nil)),
                  ApolloRedgifsFailureKindUnreachable, 0, @"DNS failure");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(nil, nil, URLError(NSURLErrorServerCertificateUntrusted, nil)),
                  ApolloRedgifsFailureKindUnreachable, 0, @"TLS interception");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(nil, nil, URLError(NSURLErrorCancelled, nil)),
                  ApolloRedgifsFailureKindNone, 0, @"cancelled");
    ExpectFailure(ApolloRedgifsFailureForAPIResult(nil, nil, nil),
                  ApolloRedgifsFailureKindNone, 0, @"no response, no error");
}

static void TestMediaErrors(void) {
    // media.redgifs.com unreachable (DNS): NSURLErrorDomain all the way down.
    NSError *dns = URLError(NSURLErrorCannotFindHost, URLError(NSURLErrorCannotFindHost,
        [NSError errorWithDomain:@"kCFErrorDomainCFNetwork" code:-72000 userInfo:nil]));
    ExpectFailure(ApolloRedgifsFailureForMediaError(dns), ApolloRedgifsFailureKindUnreachable, 0, @"media DNS failure");

    NSError *cm404 = [NSError errorWithDomain:@"CoreMediaErrorDomain" code:-12938
        userInfo:@{@"NSDescription": @"HTTP 404: File Not Found"}];
    ExpectFailure(ApolloRedgifsFailureForMediaError(URLError(NSURLErrorFileDoesNotExist, cm404)),
                  ApolloRedgifsFailureKindNotFound, 404, @"media 404");

    NSError *cm410 = [NSError errorWithDomain:@"CoreMediaErrorDomain" code:-12668
        userInfo:@{@"NSDescription": @"HTTP 410: Gone"}];
    ExpectFailure(ApolloRedgifsFailureForMediaError(URLError(NSURLErrorResourceUnavailable, cm410)),
                  ApolloRedgifsFailureKindDeleted, 410, @"media 410");

    NSError *cm451 = [NSError errorWithDomain:@"CoreMediaErrorDomain" code:-16845
        userInfo:@{@"NSDescription": @"HTTP 451: (unhandled)"}];
    ExpectFailure(ApolloRedgifsFailureForMediaError(URLError(NSURLErrorResourceUnavailable, cm451)),
                  ApolloRedgifsFailureKindRegion, 451, @"media 451");

    NSError *cm500 = [NSError errorWithDomain:@"CoreMediaErrorDomain" code:-16847
        userInfo:@{@"NSDescription": @"HTTP 500: Internal Server Error"}];
    ExpectFailure(ApolloRedgifsFailureForMediaError(URLError(NSURLErrorResourceUnavailable, cm500)),
                  ApolloRedgifsFailureKindHTTPStatus, 500, @"media 500");

    // 403 comes as a bare OSStatus with no text.
    NSError *os403 = [NSError errorWithDomain:NSOSStatusErrorDomain code:-12660 userInfo:nil];
    ExpectFailure(ApolloRedgifsFailureForMediaError(URLError(NSURLErrorNoPermissionsToReadFile, os403)),
                  ApolloRedgifsFailureKindHTTPStatus, 403, @"media 403");

    // Foundation's reading of the status alone.
    ExpectFailure(ApolloRedgifsFailureForMediaError(URLError(NSURLErrorFileDoesNotExist, nil)),
                  ApolloRedgifsFailureKindNotFound, 404, @"media FileDoesNotExist alone");

    // A decode failure says nothing about RedGIFs.
    NSError *decode = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11828 userInfo:nil];
    ExpectFailure(ApolloRedgifsFailureForMediaError(decode), ApolloRedgifsFailureKindNone, 0, @"media decode failure");
    ExpectFailure(ApolloRedgifsFailureForMediaError(nil), ApolloRedgifsFailureKindNone, 0, @"no media error");

    // "HTTP" text outside CoreMedia isn't read as a status.
    NSError *other = [NSError errorWithDomain:@"SomeDomain" code:1 userInfo:@{@"NSDescription": @"HTTP 404"}];
    ExpectFailure(ApolloRedgifsFailureForMediaError(other), ApolloRedgifsFailureKindNone, 0, @"HTTP text in another domain");
}

static void TestTitles(void) {
    ApolloRedgifsFailure deleted = { ApolloRedgifsFailureKindDeleted, 410 };
    Expect([ApolloRedgifsCardTitleForFailure(deleted) isEqualToString:@"Removed from RedGIFs"], @"deleted title");
    ApolloRedgifsFailure notFound = { ApolloRedgifsFailureKindNotFound, 404 };
    Expect([ApolloRedgifsCardTitleForFailure(notFound) isEqualToString:@"Not found on RedGIFs"], @"not found title");
    ApolloRedgifsFailure region = { ApolloRedgifsFailureKindRegion, 451 };
    Expect([ApolloRedgifsCardTitleForFailure(region) isEqualToString:@"RedGIFs isn't available in your region"], @"region title");
    ApolloRedgifsFailure unreachable = { ApolloRedgifsFailureKindUnreachable, 0 };
    Expect([ApolloRedgifsCardTitleForFailure(unreachable) isEqualToString:@"Can't reach RedGIFs"], @"unreachable title");
    ApolloRedgifsFailure image = { ApolloRedgifsFailureKindImage, 200 };
    Expect([ApolloRedgifsCardTitleForFailure(image) isEqualToString:@"Can't show RedGIFs images"], @"image title");
    ApolloRedgifsFailure status = { ApolloRedgifsFailureKindHTTPStatus, 503 };
    Expect([ApolloRedgifsCardTitleForFailure(status) isEqualToString:@"RedGIFs error (HTTP 503)"], @"status title");
    ApolloRedgifsFailure none = { ApolloRedgifsFailureKindNone, 200 };
    Expect(ApolloRedgifsCardTitleForFailure(none) == nil, @"no title for None");
}

static void TestIDs(void) {
    NSDictionary<NSString *, id> *posts = @{
        @"https://www.redgifs.com/watch/alivegrotesquemoa": @"alivegrotesquemoa",
        @"https://redgifs.com/watch/AdventurousChartreuseTarantula": @"adventurouschartreusetarantula",
        @"https://v3.redgifs.com/watch/alarmedamplealbatross-some-title": @"alarmedamplealbatross",
        @"https://www.redgifs.com/ifr/alivegrotesquemoa": @"alivegrotesquemoa",
        @"https://www.redgifs.com/gifs/detail/alivegrotesquemoa": @"alivegrotesquemoa",
        @"https://www.redgifs.com/en/alivegrotesquemoa": @"alivegrotesquemoa",
        @"https://www.redgifs.com/alivegrotesquemoa": @"alivegrotesquemoa",
        @"https://www.redgifs.com/watch/alivegrotesquemoa?utm=1": @"alivegrotesquemoa",
        @"https://redgifs.com.evil.example/watch/abc": [NSNull null],
        @"https://notredgifs.com/watch/abc": [NSNull null],
        @"https://streamable.com/abc": [NSNull null],
        @"ftp://www.redgifs.com/watch/abc": [NSNull null],
        @"https://www.redgifs.com/": [NSNull null],
    };
    [posts enumerateKeysAndObjectsUsingBlock:^(NSString *url, id want, __unused BOOL *stop) {
        NSString *got = ApolloRedgifsIDFromPostURL([NSURL URLWithString:url]);
        BOOL ok = [want isKindOfClass:[NSNull class]] ? got == nil : [got isEqualToString:want];
        Expect(ok, [NSString stringWithFormat:@"post id for %@ (got %@)", url, got]);
    }];

    NSDictionary<NSString *, id> *lookups = @{
        @"https://api.redgifs.com/v2/gifs/AliveGrotesqueMoa": @"alivegrotesquemoa",
        @"https://api.redgifs.com/v2/gifs/search?search_text=x": [NSNull null],
        @"https://api.redgifs.com/v2/gifs/abc/files": [NSNull null],
        @"https://api.redgifs.com/v2/auth/temporary": [NSNull null],
        @"https://media.redgifs.com/v2/gifs/abc": [NSNull null],
    };
    [lookups enumerateKeysAndObjectsUsingBlock:^(NSString *url, id want, __unused BOOL *stop) {
        NSString *got = ApolloRedgifsIDFromLookupURL([NSURL URLWithString:url]);
        BOOL ok = [want isKindOfClass:[NSNull class]] ? got == nil : [got isEqualToString:want];
        Expect(ok, [NSString stringWithFormat:@"lookup id for %@ (got %@)", url, got]);
    }];
}

static void TestRedditCopies(void) {
    NSDictionary<NSString *, NSNumber *> *urls = @{
        @"https://v.redd.it/abc123/DASH_720.mp4": @YES,
        @"https://preview.redd.it/abc.gif?format=mp4": @YES,
        @"https://external-preview.redd.it/abc.gif?format=mp4": @YES,
        @"https://i.redd.it/abc.gif": @YES,
        @"https://www.reddit.com/video/abc": @YES,
        @"https://reddit.com/x": @YES,
        @"https://g.redditmedia.com/abc.gif": @YES,
        @"https://media.redgifs.com/AliveGrotesqueMoa.mp4": @NO,
        @"https://thumbs4.redgifs.com/AliveGrotesqueMoa-mobile.mp4": @NO,
        @"http://127.0.0.1:18731/s/404/AliveGrotesqueMoa.mp4": @NO,
        @"https://notredd.it/abc.mp4": @NO,
        @"https://redd.it.example.com/abc.mp4": @NO,
    };
    [urls enumerateKeysAndObjectsUsingBlock:^(NSString *url, NSNumber *want, __unused BOOL *stop) {
        BOOL got = ApolloRedgifsMediaURLIsRedditCopy([NSURL URLWithString:url]);
        Expect(got == want.boolValue, [NSString stringWithFormat:@"Reddit copy for %@ (got %d)", url, got]);
    }];
    Expect(!ApolloRedgifsMediaURLIsRedditCopy(nil), @"Reddit copy for nil");
}

int main(void) {
    @autoreleasepool {
        TestAPIResults();
        TestMediaErrors();
        TestTitles();
        TestIDs();
        TestRedditCopies();
    }
    if (sFailures) {
        fprintf(stderr, "%d RedGIFs failure-reason check(s) failed\n", sFailures);
        return 1;
    }
    printf("RedGIFs failure-reason tests passed\n");
    return 0;
}
