#import <Foundation/Foundation.h>
#import "ApolloUpdateManifestCache.h"

static int sFailures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static NSURL *ManifestURL(void) {
    return [NSURL URLWithString:@"https://example.com/release-manifest.json"];
}

static NSData *Manifest(NSString *version, NSString *filename) {
    NSDictionary *json = @{
        @"release": @{@"tweakVersion": version, @"url": @"https://example.com/release"},
        @"variants": @{
            @"standard": @{@"sourceURL": @"https://example.com/apps.json",
                           @"directDownloadURL": [@"https://example.com/" stringByAppendingString:filename]},
            @"glass": @{@"sourceURL": @"https://example.com/glass.json",
                        @"directDownloadURL": @"https://example.com/glass.ipa"},
        },
    };
    return [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
}

static NSHTTPURLResponse *Response(NSURL *url, NSInteger status, NSString *etag) {
    return [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1"
                                    headerFields:etag ? @{@"ETag": etag} : @{}];
}

static ApolloUpdateInfo *Apply(ApolloUpdateManifestCache *cache, NSURLRequest *request, NSInteger status,
                              NSData *data, NSString *etag, NSString *variant) {
    return [cache infoForResponse:Response(request.URL, status, etag) data:data request:request variantKey:variant];
}

static void TestPersistentPair(NSURL *fileURL) {
    NSURL *url = ManifestURL();
    ApolloUpdateManifestCache *cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    NSURLRequest *first = [cache requestForURL:url variantKey:@"standard"];
    CHECK([first.URL isEqual:url], @"request preserves the exact manifest URL");
    CHECK(first.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData, @"OS cache cannot interfere with our validator");
    CHECK(!first.HTTPShouldHandleCookies, @"no request cookies");
    CHECK([first valueForHTTPHeaderField:@"If-None-Match"] == nil, @"first request is unconditional");
    CHECK([Apply(cache, first, 200, Manifest(@"3.9.0", @"standard.ipa"), @"\"first\"", @"standard").version isEqual:@"3.9.0"], @"200 parses");

    // Relaunch: the validator must have its body available, and variant links
    // must be resolved for this build instead of persisting the last parsed info.
    cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    NSURLRequest *next = [cache requestForURL:url variantKey:@"glass"];
    CHECK([[next valueForHTTPHeaderField:@"If-None-Match"] isEqual:@"\"first\""], @"ETag survives relaunch with its payload");
    ApolloUpdateInfo *unchanged = Apply(cache, next, 304, nil, @"\"first\"", @"glass");
    CHECK([unchanged.version isEqual:@"3.9.0"] && [unchanged.downloadURL.lastPathComponent isEqual:@"glass.ipa"], @"304 parses cached body for current variant");
    ApolloUpdateInfo *missing = [cache cachedInfoForURL:url variantKey:@"missing"];
    CHECK(missing != nil && missing.sourceURL == nil && missing.downloadURL == nil, @"missing variant preserves parser behavior and cannot reuse another variant's URLs");
    CHECK([missing.notesSourceURL.lastPathComponent isEqual:@"apps.json"], @"missing variant may still use standard release notes");
    CHECK([cache cachedInfoForURL:url variantKey:nil].downloadURL == nil, @"unstamped build gets no variant-specific download");

    // A new body may change URLs without changing the release number. It replaces
    // the entire pair; no validator means an unconditional next request.
    ApolloUpdateInfo *changed = Apply(cache, next, 200, Manifest(@"3.9.0", @"replacement.ipa"), nil, @"standard");
    CHECK([changed.downloadURL.lastPathComponent isEqual:@"replacement.ipa"], @"changed body takes effect even at same version");
    CHECK([[cache requestForURL:url variantKey:@"standard"] valueForHTTPHeaderField:@"If-None-Match"] == nil, @"200 without ETag clears old validator");
    cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    CHECK([[cache cachedInfoForURL:url variantKey:@"standard"].downloadURL.lastPathComponent isEqual:@"replacement.ipa"], @"replacement body persists");
    CHECK([[cache requestForURL:url variantKey:@"standard"] valueForHTTPHeaderField:@"If-None-Match"] == nil, @"cleared validator stays cleared after relaunch");
}

static void TestFailurePreservesGoodPair(NSURL *fileURL) {
    NSURL *url = ManifestURL();
    ApolloUpdateManifestCache *cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    NSURLRequest *request = [cache requestForURL:url variantKey:@"standard"];
    Apply(cache, request, 200, Manifest(@"4.0.0", @"good.ipa"), @"W/\"good\"", @"standard");
    request = [cache requestForURL:url variantKey:@"standard"];
    CHECK([[request valueForHTTPHeaderField:@"If-None-Match"] isEqual:@"W/\"good\""], @"weak validators round-trip unchanged");
    NSData *malformed = [@"{broken" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK(Apply(cache, request, 200, malformed, @"\"bad\"", @"standard") == nil, @"malformed 200 fails");
    CHECK(Apply(cache, request, 200, [@"[]" dataUsingEncoding:NSUTF8StringEncoding], @"\"bad\"", @"standard") == nil, @"non-manifest JSON fails");
    CHECK(Apply(cache, request, 200, Manifest(@"latest", @"bad.ipa"), @"\"bad\"", @"standard") == nil, @"unusable manifest fails");
    CHECK(Apply(cache, request, 500, Manifest(@"9.0.0", @"bad.ipa"), @"\"bad\"", @"standard") == nil, @"HTTP error cannot cache a body");
    CHECK(Apply(cache, request, 200, nil, @"\"bad\"", @"standard") == nil, @"empty 200 fails");
    cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    NSURLRequest *retry = [cache requestForURL:url variantKey:@"standard"];
    CHECK([[retry valueForHTTPHeaderField:@"If-None-Match"] isEqual:@"W/\"good\""], @"errors preserve old validator");
    CHECK([Apply(cache, retry, 304, nil, nil, @"standard").version isEqual:@"4.0.0"], @"errors preserve usable old body");
}

static void TestURLIsolationAndInvalid304(NSURL *fileURL) {
    NSURL *url = ManifestURL();
    NSURL *other = [NSURL URLWithString:@"https://other.example/release-manifest.json"];
    ApolloUpdateManifestCache *cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    NSURLRequest *request = [cache requestForURL:url variantKey:@"standard"];
    CHECK(Apply(cache, request, 304, nil, nil, @"standard") == nil, @"304 without a body is not success");
    Apply(cache, request, 200, Manifest(@"4.0.0", @"first.ipa"), @"\"first\"", @"standard");
    NSURLRequest *otherRequest = [cache requestForURL:other variantKey:@"standard"];
    CHECK([otherRequest valueForHTTPHeaderField:@"If-None-Match"] == nil, @"different URL never receives first URL's validator");
    CHECK([cache cachedInfoForURL:other variantKey:@"standard"] == nil, @"different URL never receives first URL's body");
    CHECK(Apply(cache, otherRequest, 304, nil, nil, @"standard") == nil, @"different URL's 304 cannot reuse cache");
    Apply(cache, otherRequest, 200, Manifest(@"5.0.0", @"other.ipa"), @"\"other\"", @"standard");
    CHECK([[cache requestForURL:url variantKey:@"standard"] valueForHTTPHeaderField:@"If-None-Match"] == nil, @"switching URL replaces the pair");
    CHECK([cache cachedInfoForURL:url variantKey:@"standard"] == nil, @"switching URL discards first body");

    // Even with a stored body, an unconditional/mismatched 304 is not evidence
    // that it is current. Drop the validator so a retry asks for a full body.
    CHECK(Apply(cache, otherRequest, 304, nil, nil, @"standard") == nil, @"unsolicited 304 fails");
    CHECK([[cache requestForURL:other variantKey:@"standard"] valueForHTTPHeaderField:@"If-None-Match"] == nil, @"next request after invalid 304 is unconditional");
    cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    CHECK([[cache requestForURL:other variantKey:@"standard"] valueForHTTPHeaderField:@"If-None-Match"] == nil, @"invalid validator stays cleared across relaunch");
    CHECK([[cache cachedInfoForURL:other variantKey:@"standard"].version isEqual:@"5.0.0"], @"invalid 304 preserves last valid body");
}

static void TestFileOverride(NSURL *fileURL) {
    NSURL *url = ManifestURL();
    NSURL *local = [NSURL fileURLWithPath:@"/tmp/apollo-test-manifest.json"];
    ApolloUpdateManifestCache *cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    Apply(cache, [cache requestForURL:url variantKey:@"standard"], 200, Manifest(@"4.0.0", @"remote.ipa"), @"\"remote\"", @"standard");
    NSURLRequest *request = [cache requestForURL:local variantKey:@"standard"];
    CHECK([request valueForHTTPHeaderField:@"If-None-Match"] == nil, @"file override sends no validator");
    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:local MIMEType:@"application/json" expectedContentLength:0 textEncodingName:nil];
    ApolloUpdateInfo *info = [cache infoForResponse:response data:Manifest(@"99.0.0", @"local.ipa") request:request variantKey:@"standard"];
    CHECK([info.version isEqual:@"99.0.0"], @"file override parses without HTTP status");
    CHECK([cache cachedInfoForURL:local variantKey:@"standard"] == nil, @"file override cannot leave a stale persisted test result");
    cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    CHECK([[cache cachedInfoForURL:url variantKey:@"standard"].version isEqual:@"4.0.0"], @"file override preserves remote pair");
}

static void TestCorruptStorage(NSURL *fileURL) {
    NSURL *url = ManifestURL();
    NSArray *invalidEntries = @[
        @{@"url": url.absoluteString, @"etag": @"\"orphan\""},
        @{@"url": url.absoluteString, @"etag": @"\"orphan\"", @"manifest": @"wrong type"},
        @{@"url": url.absoluteString, @"etag": @"\"orphan\"", @"manifest": [@"{}" dataUsingEncoding:NSUTF8StringEncoding]},
        @[@"wrong root type"],
    ];
    for (id entry in invalidEntries) {
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:entry format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        [data writeToURL:fileURL atomically:YES];
        ApolloUpdateManifestCache *cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
        CHECK([cache cachedInfoForURL:url variantKey:@"standard"] == nil, @"corrupt cache has no usable body");
        CHECK([[cache requestForURL:url variantKey:@"standard"] valueForHTTPHeaderField:@"If-None-Match"] == nil, @"orphan validator never sent");
    }
    NSDictionary *badHeader = @{@"url": url.absoluteString, @"etag": @"bad\r\nheader", @"manifest": Manifest(@"4.0.0", @"good.ipa")};
    [[NSPropertyListSerialization dataWithPropertyList:badHeader format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL] writeToURL:fileURL atomically:YES];
    ApolloUpdateManifestCache *cache = [[ApolloUpdateManifestCache alloc] initWithFileURL:fileURL];
    CHECK([[cache cachedInfoForURL:url variantKey:@"standard"].version isEqual:@"4.0.0"], @"bad header needn't discard valid body");
    CHECK([[cache requestForURL:url variantKey:@"standard"] valueForHTTPHeaderField:@"If-None-Match"] == nil, @"bad persisted header is not replayed");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSURL *directory = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        TestPersistentPair([directory URLByAppendingPathComponent:@"pair.plist"]);
        TestFailurePreservesGoodPair([directory URLByAppendingPathComponent:@"failure.plist"]);
        TestURLIsolationAndInvalid304([directory URLByAppendingPathComponent:@"urls.plist"]);
        TestFileOverride([directory URLByAppendingPathComponent:@"file.plist"]);
        TestCorruptStorage([directory URLByAppendingPathComponent:@"corrupt.plist"]);
    }
    if (sFailures) {
        fprintf(stderr, "update_manifest_cache_tests: %d check(s) failed\n", sFailures);
        return 1;
    }
    printf("update_manifest_cache_tests: all checks passed\n");
    return 0;
}
