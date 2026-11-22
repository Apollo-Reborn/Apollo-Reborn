// Host tests for src/ApolloOfflineLibrary.m and src/ApolloOfflineDownloader.m
// (tests/run_offline_library_tests.sh). All Reddit JSON here is synthetic,
// shaped like real listing/comments responses with made-up ids and URLs.
#import <Foundation/Foundation.h>
#import "ApolloOfflineLibrary.h"
#import "ApolloOfflineDownloader.h"

static int sFailures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static NSString *Key(NSString *url) {
    return ApolloOfflineKeyForURL([NSURL URLWithString:url]);
}

static void TestFeedKeys(void) {
    CHECK([ApolloOfflineFeedKeyForPath(@"") isEqualToString:@"home"], "empty path");
    CHECK([ApolloOfflineFeedKeyForPath(@"/") isEqualToString:@"home"], "root");
    CHECK([ApolloOfflineFeedKeyForPath(@"/best") isEqualToString:@"home"], "best");
    CHECK([ApolloOfflineFeedKeyForPath(@"/hot.json") isEqualToString:@"home"], "hot.json");
    CHECK([ApolloOfflineFeedKeyForPath(@"/r/Pics") isEqualToString:@"r/pics"], "sub lowercased");
    CHECK([ApolloOfflineFeedKeyForPath(@"/r/pics/top/") isEqualToString:@"r/pics"], "sub sort");
    CHECK([ApolloOfflineFeedKeyForPath(@"/r/popular/hot.json") isEqualToString:@"r/popular"], "popular");
    CHECK([ApolloOfflineFeedKeyForPath(@"/user/Bob/m/Cats/new") isEqualToString:@"m/bob/cats"], "multi");
    CHECK(ApolloOfflineFeedKeyForPath(@"/r/pics/about") == nil, "about isn't a feed");
    CHECK(ApolloOfflineFeedKeyForPath(@"/api/v1/me") == nil, "api isn't a feed");
    CHECK(ApolloOfflineFeedKeyForPath(@"/user/bob/submitted") == nil, "profile isn't a feed");
}

static void TestURLKeys(void) {
    // Apollo's own request and the downloader's land on the same key whatever
    // the host, sort, limit or raw_json.
    CHECK([Key(@"https://oauth.reddit.com/hot?limit=25&raw_json=1") isEqualToString:@"feed:home|"], "%s", Key(@"https://oauth.reddit.com/hot?limit=25").UTF8String);
    CHECK([Key(@"https://www.reddit.com/best.json?limit=50&raw_json=1") isEqualToString:@"feed:home|"], "www json");
    CHECK([Key(@"https://oauth.reddit.com/r/Pics/new?after=t3_ABC&count=25") isEqualToString:@"feed:r/pics|t3_abc"], "after");
    CHECK([Key(@"https://oauth.reddit.com/comments/abc12?sort=top&limit=200") isEqualToString:@"comments:abc12"], "comments");
    CHECK([Key(@"https://www.reddit.com/r/pics/comments/abc12/a_title/.json") isEqualToString:@"comments:abc12"], "sub comments");
    CHECK(Key(@"https://oauth.reddit.com/r/pics/comments") == nil, "comment stream isn't a post");
    CHECK([Key(@"https://oauth.reddit.com/api/v1/me") isEqualToString:@"api:api/v1/me|"], "account read");
    CHECK([Key(@"https://www.reddit.com/message/inbox.json?limit=25&after=t1_AB") isEqualToString:@"api:message/inbox|t1_ab"], "inbox page");
    CHECK([Key(@"https://www.reddit.com/subreddits/mine/subscriber.json?limit=100") isEqualToString:@"api:subreddits/mine/subscriber|"], "subscriptions");
    CHECK([Key(@"https://www.reddit.com/r/News/about.json") isEqualToString:@"about:news"], "subreddit about");
    CHECK(Key(@"https://oauth.reddit.com/api/info.json?id=t3_x") == nil, "lookups by id aren't saved");
    CHECK(Key(@"https://oauth.reddit.com/api/mod/conversations") == nil, "mod tools aren't saved");
    CHECK([Key(@"https://www.google.com/s2/favicons?sz=64&domain=www.BBC.com") isEqualToString:@"favicon:bbc.com"], "favicon by domain");
    CHECK([Key(@"https://www.google.com/s2/favicons?domain_url=https://bbc.com/news") isEqualToString:@"favicon:bbc.com"], "favicon by url");
    CHECK([Key(@"https://preview.redd.it/xyz98.jpg?width=640&format=pjpg&s=1") isEqualToString:@"reddimg:xyz98"], "preview");
    CHECK([Key(@"https://i.redd.it/xyz98.jpeg") isEqualToString:@"reddimg:xyz98"], "same image direct");
    CHECK([Key(@"https://external-preview.redd.it/Ab-Cd.png?auto=webp&s=2") isEqualToString:@"extimg:Ab-Cd"], "external preview");
    CHECK([Key(@"https://i.imgur.com/qwe.jpg?1") isEqualToString:@"url:i.imgur.com/qwe.jpg"], "imgur");
    CHECK(Key(@"video-player://v.redd.it/x") == nil, "custom scheme");
}

static void TestPolicy(void) {
    CHECK(ApolloOfflineShouldServe(ApolloOfflineUseModeAutomatic, NO, YES, NO), "auto offline");
    CHECK(!ApolloOfflineShouldServe(ApolloOfflineUseModeAutomatic, YES, YES, NO), "auto online");
    CHECK(ApolloOfflineShouldServe(ApolloOfflineUseModeAlways, YES, YES, NO), "always");
    CHECK(!ApolloOfflineShouldServe(ApolloOfflineUseModeNever, NO, YES, NO), "never");
    CHECK(!ApolloOfflineShouldServe(ApolloOfflineUseModeAlways, NO, NO, NO), "no library");
    CHECK(!ApolloOfflineShouldServe(ApolloOfflineUseModeAlways, NO, YES, YES), "paused while downloading");
}

static NSDictionary *PostData(NSString *postID) {
    return @{
        @"id": postID,
        @"name": [@"t3_" stringByAppendingString:postID],
        @"url": [NSString stringWithFormat:@"https://i.redd.it/%@.jpg", postID],
        @"thumbnail": [NSString stringWithFormat:@"https://b.thumbs.redditmedia.com/%@.jpg", postID],
        @"preview": @{ @"images": @[ @{
            @"source": @{ @"url": [NSString stringWithFormat:@"https://preview.redd.it/%@.jpg?width=3000&amp;s=src", postID], @"width": @3000 },
            @"resolutions": @[
                @{ @"url": [NSString stringWithFormat:@"https://preview.redd.it/%@.jpg?width=640&s=a", postID], @"width": @640 },
                @{ @"url": [NSString stringWithFormat:@"https://preview.redd.it/%@.jpg?width=1080&s=b", postID], @"width": @1080 },
                @{ @"url": [NSString stringWithFormat:@"https://preview.redd.it/%@.jpg?width=2160&s=c", postID], @"width": @2160 },
            ],
        } ] },
    };
}

static void TestImageURLs(void) {
    NSArray<NSURL *> *urls = ApolloOfflineImageURLsForPost(PostData(@"p1"), 1080);
    CHECK(urls.count == 2, "preview + thumbnail, direct link deduped: %lu", (unsigned long)urls.count);
    CHECK([urls.firstObject.absoluteString containsString:@"width=1080"], "largest within limit: %s", urls.firstObject.absoluteString.UTF8String);

    NSDictionary *small = PostData(@"p2");
    urls = ApolloOfflineImageURLsForPost(small, 320);
    CHECK([urls.firstObject.absoluteString containsString:@"width=3000"] && ![urls.firstObject.absoluteString containsString:@"&amp;"],
          "falls back to unescaped source: %s", urls.firstObject.absoluteString.UTF8String);

    NSDictionary *gallery = @{
        @"id": @"g1",
        @"thumbnail": @"self",
        @"gallery_data": @{ @"items": @[ @{ @"media_id": @"m2" }, @{ @"media_id": @"m1" } ] },
        @"media_metadata": @{
            @"m1": @{ @"status": @"valid", @"e": @"Image", @"s": @{ @"u": @"https://preview.redd.it/m1.jpg?width=2000" },
                      @"p": @[ @{ @"u": @"https://preview.redd.it/m1.jpg?width=960", @"x": @960 } ] },
            @"m2": @{ @"status": @"valid", @"e": @"Image", @"s": @{ @"u": @"https://preview.redd.it/m2.jpg?width=900" } },
            @"m3": @{ @"status": @"failed" },
        },
    };
    urls = ApolloOfflineImageURLsForPost(gallery, 1080);
    CHECK(urls.count == 2, "two valid gallery images, 'self' thumbnail skipped: %lu", (unsigned long)urls.count);
    CHECK([urls[0].absoluteString containsString:@"m2"] && [urls[1].absoluteString containsString:@"width=960"], "gallery order and resolution");

    NSDictionary *crosspost = @{ @"id": @"x1", @"crosspost_parent_list": @[ PostData(@"p9") ] };
    CHECK(ApolloOfflineImageURLsForPost(crosspost, 1080).count == 2, "crosspost parent images");
}

static NSData *JSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

static NSData *ListingData(NSArray<NSString *> *ids, NSString *after) {
    NSMutableArray *children = [NSMutableArray array];
    for (NSString *postID in ids) [children addObject:@{ @"kind": @"t3", @"data": PostData(postID) }];
    return JSON(@{ @"kind": @"Listing", @"data": @{ @"after": after ?: [NSNull null], @"dist": @(ids.count), @"children": children } });
}

static void TestTruncate(void) {
    NSData *truncated = ApolloOfflineTruncatedListing(ListingData(@[ @"a", @"b", @"c" ], @"t3_c"), 2, YES);
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:truncated options:0 error:nil];
    CHECK([root[@"data"][@"children"] count] == 2, "kept two");
    CHECK(root[@"data"][@"after"] == [NSNull null], "after cleared");
    CHECK(ApolloOfflineTruncatedListing(JSON(@[ @1 ]), 1, YES) == nil, "not a listing");
}

static NSURL *TempDirectory(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"apollo-offline-tests-%@", NSUUID.UUID.UUIDString]];
    return [[NSURL fileURLWithPath:path isDirectory:YES] URLByAppendingPathComponent:@"OfflineLibrary" isDirectory:YES];
}

static void TestWriterAndLibrary(void) {
    NSURL *dir = TempDirectory();
    ApolloOfflineLibraryWriter *writer = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:dir error:nil];
    CHECK([writer storeData:[@"one" dataUsingEncoding:NSUTF8StringEncoding] contentType:@"text/plain" forKey:@"k1"], "store");
    CHECK([writer storeData:[@"twotwo" dataUsingEncoding:NSUTF8StringEncoding] contentType:@"text/plain" forKey:@"k1"], "replace");
    CHECK(writer.bytesWritten == 6, "replace doesn't double count: %llu", writer.bytesWritten);
    [writer noteFeedTitle:@"Home" posts:3];
    [writer noteFeedTitle:@"r/empty" posts:0];
    CHECK([writer commit:nil], "commit");

    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSString *type = nil;
    NSData *data = [library dataForKey:@"k1" contentType:&type];
    CHECK([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] isEqualToString:@"twotwo"] && [type isEqualToString:@"text/plain"], "read back");
    CHECK(library.postCount == 3 && [library.feedTitles isEqualToArray:@[ @"Home" ]] && library.downloadedAt, "index metadata");

    // A second batch replaces the first atomically; a discarded one changes nothing.
    ApolloOfflineLibraryWriter *second = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:dir error:nil];
    [second storeData:[@"x" dataUsingEncoding:NSUTF8StringEncoding] contentType:nil forKey:@"k2"];
    [second discard];
    [library reload];
    CHECK([library hasEntryForKey:@"k1"] && ![library hasEntryForKey:@"k2"], "discard keeps old batch");
    ApolloOfflineLibraryWriter *third = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:dir error:nil];
    [third storeData:[@"x" dataUsingEncoding:NSUTF8StringEncoding] contentType:nil forKey:@"k2"];
    [third noteFeedTitle:@"Home" posts:1];
    CHECK([third commit:nil], "second commit");
    [library reload];
    CHECK(![library hasEntryForKey:@"k1"] && [library hasEntryForKey:@"k2"], "commit swaps batch");
    CHECK([library removeAll:nil] && !library.hasContent, "remove");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

// MARK: - Downloader against a fake Reddit

typedef struct {
    BOOL done;
    BOOL committed;
    NSUInteger posts;
} RunResult;

// Set by a test to give the downloader a (fake) remuxer.
static ApolloOfflineVideoMuxer sTestMuxer = nil;
static ApolloOfflinePageSaver sTestPageSaver = nil;
// Concurrency and pacing tests: a delay for every fake reply, a count of
// comment reads in flight, rate-limit headers for the first API reply, the
// time of each API read, and a cancel after N comment reads.
static double sTestDelay = 0;
static NSInteger sCommentsInFlight = 0, sMaxCommentsInFlight = 0;
static NSDictionary<NSString *, NSString *> *sFirstAPIHeaders = nil;
static NSMutableArray<NSDate *> *sAPITimes = nil;
static NSUInteger sCancelAfterComments = 0;

static RunResult RunDownload(NSURL *dir, ApolloOfflineDownloadOptions *options, NSDictionary<NSString *, NSData *> *responses,
                             NSMutableArray<NSString *> *requested) {
    __block __weak ApolloOfflineDownloader *weakDownloader = nil;
    __block NSUInteger commentReads = 0;
    __block BOOL sentHeaders = NO;
    ApolloOfflineFetcher fetcher = ^(NSURLRequest *request, ApolloOfflineFetchCompletion completion) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        NSString *after = nil;
        for (NSURLQueryItem *item in c.queryItems) if ([item.name isEqualToString:@"after"]) after = item.value;
        NSString *lookup = after ? [NSString stringWithFormat:@"%@?after=%@", c.path, after] : (c.path ?: @"");
        if ([request.URL.host isEqualToString:@"v.redd.it"]) lookup = [request.URL.host stringByAppendingString:request.URL.path];
        else if ([request.URL.host hasSuffix:@"redd.it"] || [request.URL.host hasSuffix:@"redditmedia.com"]) lookup = request.URL.host;
        else if (![request.URL.host isEqualToString:@"oauth.reddit.com"]) lookup = [request.URL.host stringByAppendingString:request.URL.path];
        NSString *auth = [request valueForHTTPHeaderField:@"Authorization"];
        if ([request.URL.host isEqualToString:@"api.redgifs.com"] && [request.URL.path hasPrefix:@"/v2/gifs/"] && ![auth isEqualToString:@"Bearer tok123"]) {
            lookup = @"(unauthorized)";
        }
        @synchronized (requested) { [requested addObject:lookup]; }
        NSData *body = responses[lookup];
        BOOL api = [request.URL.host isEqualToString:@"oauth.reddit.com"];
        BOOL comments = [lookup hasPrefix:@"/comments/"];
        NSMutableDictionary *headers = [@{ @"Content-Type": [lookup hasPrefix:@"/"] ? @"application/json" : @"image/jpeg" } mutableCopy];
        @synchronized (requested) {
            if (api && sAPITimes) [sAPITimes addObject:[NSDate date]];
            if (api && sFirstAPIHeaders && !sentHeaders) {
                sentHeaders = YES;
                [headers addEntriesFromDictionary:sFirstAPIHeaders];
            }
            if (comments) {
                sCommentsInFlight++;
                sMaxCommentsInFlight = MAX(sMaxCommentsInFlight, sCommentsInFlight);
                commentReads++;
                if (sCancelAfterComments > 0 && commentReads == sCancelAfterComments) [weakDownloader cancel];
            }
        }
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:body ? 200 : 404 HTTPVersion:@"HTTP/1.1"
            headerFields:headers];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sTestDelay * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
            if (comments) @synchronized (requested) { sCommentsInFlight--; }
            completion(body, response, nil);
        });
    };
    ApolloOfflineRequestBuilder builder = ^NSURLRequest *(NSString *path, NSArray<NSURLQueryItem *> *query) {
        NSURLComponents *c = [NSURLComponents componentsWithString:[@"https://oauth.reddit.com" stringByAppendingString:path]];
        c.queryItems = query;
        return [NSURLRequest requestWithURL:c.URL];
    };
    ApolloOfflineDownloader *downloader = [[ApolloOfflineDownloader alloc] initWithLibraryDirectory:dir fetcher:fetcher requestBuilder:builder];
    weakDownloader = downloader;
    downloader.videoMuxer = sTestMuxer;
    downloader.pageSaver = sTestPageSaver;
    __block RunResult result = { NO, NO, 0 };
    [downloader startWithOptions:options progress:nil completion:^(BOOL committed, NSUInteger posts, __unused unsigned long long bytes, __unused NSError *error) {
        result.done = YES;
        result.committed = committed;
        result.posts = posts;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!result.done && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    CHECK(result.done, "download finished");
    return result;
}

static NSDictionary *ResponsesForTwoPages(void) {
    NSMutableDictionary *responses = [NSMutableDictionary dictionary];
    responses[@"/best"] = ListingData(@[ @"a1", @"a2", @"a3" ], @"t3_a3");
    responses[@"/best?after=t3_a3"] = ListingData(@[ @"b1", @"b2", @"b3" ], nil);
    for (NSString *postID in @[ @"a1", @"a2", @"a3", @"b1", @"b2", @"b3" ]) {
        responses[[@"/comments/" stringByAppendingString:postID]] = JSON(@[ @{ @"kind": @"Listing" }, @{ @"kind": @"Listing" } ]);
    }
    responses[@"preview.redd.it"] = [NSMutableData dataWithLength:1000];
    responses[@"b.thumbs.redditmedia.com"] = [NSMutableData dataWithLength:100];
    return responses;
}

static ApolloOfflineDownloadOptions *Options(unsigned long long budget) {
    ApolloOfflineDownloadOptions *options = [ApolloOfflineDownloadOptions new];
    options.sources = @[ [ApolloOfflineFeedSource sourceWithPath:@"/best" title:@"Home"] ];
    options.byteBudget = budget;
    options.apiSpacing = 0;
    return options;
}

static void TestDownloaderWholeFeed(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    RunResult result = RunDownload(dir, Options(100ull * 1024 * 1024), ResponsesForTwoPages(), requested);
    CHECK(result.committed && result.posts == 6, "all six posts: committed=%d posts=%lu", result.committed, (unsigned long)result.posts);

    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    // Apollo's own requests (other host, sort and params) resolve to what was saved.
    CHECK([library hasEntryForKey:Key(@"https://oauth.reddit.com/hot?limit=25&raw_json=1")], "page one");
    CHECK([library hasEntryForKey:Key(@"https://www.reddit.com/new.json?after=t3_a3")], "page two via after");
    CHECK([library hasEntryForKey:Key(@"https://oauth.reddit.com/r/x/comments/b3/slug")], "comments");
    CHECK([library hasEntryForKey:Key(@"https://i.redd.it/b2.jpg")], "image by stem");
    NSArray *saved = [library.savedPostIDs sortedArrayUsingSelector:@selector(compare:)];
    CHECK([saved isEqualToArray:(@[ @"a1", @"a2", @"a3", @"b1", @"b2", @"b3" ])], "saved post ids: %s", saved.description.UTF8String);
    NSDictionary *last = [NSJSONSerialization JSONObjectWithData:[library dataForKey:@"feed:home|t3_a3" contentType:nil] options:0 error:nil];
    CHECK(last[@"data"][@"after"] == [NSNull null] && [last[@"data"][@"children"] count] == 3, "last page ends the feed");

    // Apollo loaded page one online with a smaller page size, so its cursor is
    // a post in the middle of a saved page: serve the rest of that page.
    NSString *midKey = Key(@"https://oauth.reddit.com/best?after=t3_a1&count=1");
    CHECK([library hasEntryForKey:midKey], "mid-page cursor resolves");
    NSDictionary *rest = [NSJSONSerialization JSONObjectWithData:[library dataForKey:midKey contentType:nil] options:0 error:nil];
    NSArray *restNames = [rest[@"data"][@"children"] valueForKeyPath:@"data.name"];
    CHECK([restNames isEqualToArray:(@[ @"t3_a2", @"t3_a3" ])] && [rest[@"data"][@"after"] isEqual:@"t3_a3"],
          "rest of page keeps the chain: %s", restNames.description.UTF8String);
    // The cursor is the last post of the final page: an empty, final page.
    NSDictionary *end = [NSJSONSerialization JSONObjectWithData:[library dataForKey:@"feed:home|t3_b3" contentType:nil] options:0 error:nil];
    CHECK([end[@"data"][@"children"] count] == 0 && end[@"data"][@"after"] == [NSNull null], "end of feed");
    CHECK(![library hasEntryForKey:@"feed:r/pics|t3_a1"], "cursors are per feed");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestDownloaderBudget(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    // Each post costs ~1.1 KB of images plus its comments; the post that
    // crosses 2.5 KB is still kept, then the feed stops.
    RunResult result = RunDownload(dir, Options(2500), ResponsesForTwoPages(), requested);
    CHECK(result.committed && result.posts == 3, "budget stops after crossing: posts=%lu", (unsigned long)result.posts);
    CHECK(![requested containsObject:@"/best?after=t3_a3"], "no second page fetched");
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSDictionary *page = [NSJSONSerialization JSONObjectWithData:[library dataForKey:@"feed:home|" contentType:nil] options:0 error:nil];
    CHECK([page[@"data"][@"children"] count] == result.posts && page[@"data"][@"after"] == [NSNull null], "page cut to saved posts");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestDownloaderFailureKeepsOldLibrary(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    RunDownload(dir, Options(100ull * 1024 * 1024), ResponsesForTwoPages(), requested);
    RunResult failed = RunDownload(dir, Options(100ull * 1024 * 1024), @{}, requested);
    CHECK(!failed.committed, "nothing downloaded isn't committed");
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK(library.postCount == 6, "old library survives a failed refresh: %lu", (unsigned long)library.postCount);
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestAPISpacing(void) {
    CHECK(ApolloOfflineAPISpacing(-1, -1, -1, 0.2, 0.25, 0.75) == 0.75, "no headers: the fixed gap");
    CHECK(ApolloOfflineAPISpacing(900, 100, 400, 0.2, 0.25, 0.75) == 0.25, "plenty left: as fast as allowed");
    CHECK(ApolloOfflineAPISpacing(90, 10, 50, 0.2, 0.25, 0.75) == 0.25, "same rule on a 100-call window");
    // Into the reserve (150 of 1000 left): half of it over the 300 s still to go.
    CHECK(fabs(ApolloOfflineAPISpacing(150, 850, 300, 0.2, 0.25, 0.75) - 4.0) < 0.001, "into the reserve: 300 s / 75 calls");
    CHECK(ApolloOfflineAPISpacing(150, 850, 300, 0.4, 0.5, 1.5) > 0.5, "Keep Fresh keeps a bigger reserve");
    CHECK(ApolloOfflineAPISpacing(0, 1000, 42, 0.2, 0.25, 0.75) == 43, "spent: wait out the window");
    CHECK(ApolloOfflineAPISpacing(1, 999, 5000, 0.2, 0.25, 0.75) == 600, "never more than 10 minutes");
}

static void ResetConcurrencyProbes(void) {
    sTestDelay = 0;
    sCommentsInFlight = 0;
    sMaxCommentsInFlight = 0;
    sFirstAPIHeaders = nil;
    sAPITimes = nil;
    sCancelAfterComments = 0;
}

static void TestDownloaderRunsPostsTogether(void) {
    // Every reply takes 0.15 s. One post at a time is ~2 s for these six posts;
    // four at a time is well under half that, with the same library.
    NSURL *serialDir = TempDirectory(), *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    ResetConcurrencyProbes();
    sTestDelay = 0.15;
    ApolloOfflineDownloadOptions *serial = Options(100ull * 1024 * 1024);
    serial.postConcurrency = 1;
    NSDate *start = [NSDate date];
    RunResult one = RunDownload(serialDir, serial, ResponsesForTwoPages(), requested);
    NSTimeInterval serialTime = -start.timeIntervalSinceNow;
    CHECK(one.committed && one.posts == 6 && sMaxCommentsInFlight == 1, "one at a time: posts=%lu inFlight=%ld",
          (unsigned long)one.posts, (long)sMaxCommentsInFlight);

    sMaxCommentsInFlight = 0;
    start = [NSDate date];
    RunResult together = RunDownload(dir, Options(100ull * 1024 * 1024), ResponsesForTwoPages(), requested);
    NSTimeInterval togetherTime = -start.timeIntervalSinceNow;
    CHECK(together.committed && together.posts == 6, "together: all six posts (%lu)", (unsigned long)together.posts);
    CHECK(sMaxCommentsInFlight >= 3, "posts overlap: %ld comment reads at once", (long)sMaxCommentsInFlight);
    CHECK(togetherTime < serialTime * 0.6, "faster: %.2f s vs %.2f s one at a time", togetherTime, serialTime);
    printf("posts side by side: %.2f s, one at a time: %.2f s\n", togetherTime, serialTime);

    ApolloOfflineLibrary *a = [[ApolloOfflineLibrary alloc] initWithDirectory:serialDir];
    ApolloOfflineLibrary *b = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSArray *idsA = [a.savedPostIDs sortedArrayUsingSelector:@selector(compare:)], *idsB = [b.savedPostIDs sortedArrayUsingSelector:@selector(compare:)];
    CHECK([idsA isEqualToArray:idsB], "same posts either way");
    for (NSString *key in @[ @"feed:home|", @"feed:home|t3_a3" ]) {
        NSDictionary *pa = [NSJSONSerialization JSONObjectWithData:[a dataForKey:key contentType:nil] options:0 error:nil];
        NSDictionary *pb = [NSJSONSerialization JSONObjectWithData:[b dataForKey:key contentType:nil] options:0 error:nil];
        CHECK([[pa[@"data"][@"children"] valueForKeyPath:@"data.id"] isEqualToArray:[pb[@"data"][@"children"] valueForKeyPath:@"data.id"]],
              "page %s saved in feed order", key.UTF8String);
    }
    CHECK([b hasEntryForKey:Key(@"https://oauth.reddit.com/r/x/comments/b3/slug")], "comments saved");
    ResetConcurrencyProbes();
    [NSFileManager.defaultManager removeItemAtURL:serialDir.URLByDeletingLastPathComponent error:nil];
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestDownloaderCancelWithPostsInFlight(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    ResetConcurrencyProbes();
    RunDownload(dir, Options(100ull * 1024 * 1024), ResponsesForTwoPages(), requested);
    sTestDelay = 0.2;
    sCancelAfterComments = 2;
    NSDate *start = [NSDate date];
    RunResult cancelled = RunDownload(dir, Options(100ull * 1024 * 1024), ResponsesForTwoPages(), requested);
    CHECK(!cancelled.committed, "cancelled run isn't committed");
    CHECK(-start.timeIntervalSinceNow < 1.5, "cancel stops promptly (%.2f s)", -start.timeIntervalSinceNow);
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK(library.postCount == 6, "old library kept after a cancel: %lu", (unsigned long)library.postCount);
    ResetConcurrencyProbes();
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestDownloaderHonorsRateLimitHeaders(void) {
    // Reddit says 1 call is left and the window is about to reset: the next
    // read waits for it (reset + 1 s) instead of spending the last call.
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    ResetConcurrencyProbes();
    sFirstAPIHeaders = @{ @"x-ratelimit-remaining": @"1.0", @"x-ratelimit-used": @"999", @"x-ratelimit-reset": @"0" };
    sAPITimes = [NSMutableArray array];
    ApolloOfflineDownloadOptions *options = Options(100ull * 1024 * 1024);
    options.apiMinSpacing = 0;
    RunResult result = RunDownload(dir, options, ResponsesForTwoPages(), requested);
    CHECK(result.committed && result.posts == 6, "finishes after the wait");
    NSTimeInterval gap = sAPITimes.count >= 2 ? [sAPITimes[1] timeIntervalSinceDate:sAPITimes[0]] : 0;
    CHECK(gap >= 0.9, "second read waited for the window: %.2f s", gap);
    ResetConcurrencyProbes();
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static NSDictionary *FakeComment(NSString *author, NSArray *replies) {
    NSMutableDictionary *data = [@{ @"author_fullname": author, @"body": @"x" } mutableCopy];
    data[@"replies"] = replies.count > 0 ? @{ @"kind": @"Listing", @"data": @{ @"children": replies } } : @"";
    return @{ @"kind": @"t1", @"data": data };
}

static NSData *CommentsData(NSArray *topLevel) {
    return JSON(@[ @{ @"kind": @"Listing", @"data": @{ @"children": @[] } },
                   @{ @"kind": @"Listing", @"data": @{ @"children": topLevel } } ]);
}

static void TestUserDataHelpers(void) {
    NSArray *ids = ApolloOfflineUserDataIDsForURL([NSURL URLWithString:@"https://oauth.reddit.com/api/user_data_by_account_ids.json?ids=t2_AA,%20t2_bb,junk,&raw_json=1"]);
    CHECK([ids isEqualToArray:(@[ @"t2_aa", @"t2_bb" ])], "ids parsed: %s", ids.description.UTF8String);
    CHECK(ApolloOfflineUserDataIDsForURL([NSURL URLWithString:@"https://www.reddit.com/api/user_data_by_account_ids?ids=t2_x"]).count == 1, "www, no .json");
    CHECK(ApolloOfflineUserDataIDsForURL([NSURL URLWithString:@"https://oauth.reddit.com/api/me"]) == nil, "other API paths aren't it");
    CHECK(ApolloOfflineUserDataIDsForURL([NSURL URLWithString:@"https://example.com/api/user_data_by_account_ids?ids=t2_x"]) == nil, "Reddit only");

    // Reading order: a1, its reply a2 (and a2's reply a3), then b1; the post's author first.
    NSData *comments = CommentsData(@[ FakeComment(@"t2_a1", @[ FakeComment(@"t2_a2", @[ FakeComment(@"t2_a3", nil) ]) ]),
                                       FakeComment(@"t2_b1", nil), FakeComment(@"t2_a1", nil) ]);
    NSArray *authors = ApolloOfflineAuthorFullNames(@{ @"author_fullname": @"t2_op" }, comments, 10);
    CHECK([authors isEqualToArray:(@[ @"t2_op", @"t2_a1", @"t2_a2", @"t2_a3", @"t2_b1" ])], "authors in reading order: %s", authors.description.UTF8String);
    authors = ApolloOfflineAuthorFullNames(@{ @"author_fullname": @"t2_op" }, comments, 2);
    CHECK([authors isEqualToArray:(@[ @"t2_op", @"t2_a1", @"t2_a2" ])], "first two commenters: %s", authors.description.UTF8String);
    CHECK(ApolloOfflineAuthorFullNames(@{}, nil, 5).count == 0, "nothing to look up");

    // Saved records answer any mix of ids; unknown ids are left out.
    NSURL *dir = TempDirectory();
    ApolloOfflineLibraryWriter *writer = [[ApolloOfflineLibraryWriter alloc] initWithLibraryDirectory:dir error:nil];
    [writer storeData:JSON(@{ @"t2_aa": @{ @"name": @"alice", @"profile_img": @"https://styles.redditmedia.com/a.png" },
                             @"t2_bb": @{ @"name": @"bob", @"profile_img": @"https://www.redditstatic.com/avatars/b.png" } })
          contentType:@"application/json" forKey:@"users:0"];
    [writer storeData:JSON(@{ @"t2_cc": @{ @"name": @"carol", @"profile_img": @"https://styles.redditmedia.com/c.png" } })
          contentType:@"application/json" forKey:@"users:1"];
    [writer storeData:[NSMutableData dataWithLength:10] contentType:@"text/plain" forKey:@"comments:x"];
    [writer noteFeedTitle:@"Home" posts:1];
    CHECK([writer commit:nil], "committed");
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSURL *ask = [NSURL URLWithString:@"https://oauth.reddit.com/api/user_data_by_account_ids.json?ids=t2_cc,t2_zz,t2_aa&raw_json=1"];
    CHECK([library hasUserDataForURL:ask], "has some of them");
    NSDictionary *answer = [NSJSONSerialization JSONObjectWithData:[library userDataResponseForURL:ask] options:0 error:nil];
    CHECK(answer.count == 2 && [answer[@"t2_cc"][@"name"] isEqual:@"carol"] && [answer[@"t2_aa"][@"name"] isEqual:@"alice"] && !answer[@"t2_zz"],
          "answers the saved ones: %s", answer.description.UTF8String);
    CHECK(![library hasUserDataForURL:[NSURL URLWithString:@"https://oauth.reddit.com/api/user_data_by_account_ids?ids=t2_zz"]], "none saved: not ours");

    // Reborn's per-user avatar lookup gets a small profile from the same records.
    CHECK([ApolloOfflineProfileUsernameForURL([NSURL URLWithString:@"https://www.reddit.com/user/Alice/about.json?raw_json=1"]) isEqual:@"alice"], "profile URL");
    CHECK([ApolloOfflineProfileUsernameForURL([NSURL URLWithString:@"https://oauth.reddit.com/u/bob/about"]) isEqual:@"bob"], "u/ form");
    CHECK(ApolloOfflineProfileUsernameForURL([NSURL URLWithString:@"https://oauth.reddit.com/user/bob/submitted"]) == nil, "only about");
    CHECK(ApolloOfflineProfileUsernameForURL([NSURL URLWithString:@"https://oauth.reddit.com/r/bob/about"]) == nil, "not a subreddit");
    NSURL *aliceURL = [NSURL URLWithString:@"https://www.reddit.com/user/ALICE/about.json?raw_json=1"];
    CHECK([library hasProfileForURL:aliceURL], "alice saved");
    NSDictionary *profile = [NSJSONSerialization JSONObjectWithData:[library profileResponseForURL:aliceURL] options:0 error:nil];
    CHECK([profile[@"kind"] isEqual:@"t2"] && [profile[@"data"][@"name"] isEqual:@"alice"] &&
          [profile[@"data"][@"icon_img"] isEqual:@"https://styles.redditmedia.com/a.png"] && [profile[@"data"][@"apollo_offline_lightweight"] boolValue],
          "small profile: %s", profile.description.UTF8String);
    CHECK(![library hasProfileForURL:[NSURL URLWithString:@"https://www.reddit.com/user/zed/about.json"]], "unknown user");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestDownloaderAvatars(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    NSMutableDictionary *responses = [NSMutableDictionary dictionary];
    NSMutableDictionary *p1 = [PostData(@"p1") mutableCopy], *p2 = [PostData(@"p2") mutableCopy];
    p1[@"author_fullname"] = @"t2_op1";
    p2[@"author_fullname"] = @"t2_op2";
    responses[@"/best"] = JSON(@{ @"kind": @"Listing", @"data": @{ @"after": [NSNull null], @"dist": @2, @"children": @[
        @{ @"kind": @"t3", @"data": p1 }, @{ @"kind": @"t3", @"data": p2 } ] } });
    responses[@"/comments/p1"] = CommentsData(@[ FakeComment(@"t2_c1", @[ FakeComment(@"t2_c2", nil) ]), FakeComment(@"t2_c3", nil) ]);
    responses[@"/comments/p2"] = CommentsData(@[ FakeComment(@"t2_c1", nil) ]);
    responses[@"preview.redd.it"] = [NSMutableData dataWithLength:1000];
    responses[@"b.thumbs.redditmedia.com"] = [NSMutableData dataWithLength:100];
    NSMutableDictionary *records = [NSMutableDictionary dictionary];
    for (NSString *fn in @[ @"t2_op1", @"t2_op2", @"t2_c1", @"t2_c2", @"t2_c3" ]) {
        // Everyone but c3 has a custom picture; c3 has the shared default one.
        NSString *picture = [fn isEqualToString:@"t2_c3"] ? @"https://www.redditstatic.com/avatars/defaults/v2/avatar_default_3.png"
                                                          : [NSString stringWithFormat:@"https://styles.redditmedia.com/t5_%@/styles/profileIcon_x.png?width=256&s=sig", fn];
        records[fn] = @{ @"name": [fn substringFromIndex:3], @"profile_img": picture };
    }
    responses[@"/api/user_data_by_account_ids"] = JSON(records);
    responses[@"styles.redditmedia.com"] = [NSMutableData dataWithLength:300];
    responses[@"www.redditstatic.com/avatars/defaults/v2/avatar_default_3.png"] = [NSMutableData dataWithLength:200];

    ApolloOfflineDownloadOptions *options = Options(100ull * 1024 * 1024);
    options.avatarAuthorsPerPost = 2; // p1: op1, c1, c2 (c3 is the third commenter)
    RunResult result = RunDownload(dir, options, responses, requested);
    CHECK(result.committed && result.posts == 2, "posts saved");
    NSUInteger lookups = 0;
    for (NSString *r in requested) if ([r isEqualToString:@"/api/user_data_by_account_ids"]) lookups++;
    CHECK(lookups == 1, "one lookup for every author: %lu", (unsigned long)lookups);

    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSURL *ask = [NSURL URLWithString:@"https://oauth.reddit.com/api/user_data_by_account_ids.json?ids=t2_c1,t2_op2&raw_json=1"];
    NSDictionary *answer = [NSJSONSerialization JSONObjectWithData:[library userDataResponseForURL:ask] ?: [NSData data] options:0 error:nil];
    CHECK(answer.count == 2, "offline answer for two authors: %s", answer.description.UTF8String);
    CHECK([library hasEntryForKey:Key(@"https://styles.redditmedia.com/t5_t2_c1/styles/profileIcon_x.png?width=256&s=other")], "picture saved, any size asked");
    CHECK(![library hasEntryForKey:Key(@"https://www.redditstatic.com/avatars/defaults/v2/avatar_default_3.png")],
          "beyond the per-post limit: c3 not looked up");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];

    // No picture allowance left: every author is still looked up, the shared
    // default avatar is still kept (one file covers everyone who has it), and
    // custom pictures are skipped.
    NSURL *dir3 = TempDirectory();
    [requested removeAllObjects];
    options = Options(100ull * 1024 * 1024);
    options.avatarAuthorsPerPost = 5;
    options.maxAvatarBytes = 0;
    RunDownload(dir3, options, responses, requested);
    library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir3];
    NSURL *everyone = [NSURL URLWithString:@"https://oauth.reddit.com/api/user_data_by_account_ids?ids=t2_op1,t2_op2,t2_c1,t2_c2,t2_c3"];
    answer = [NSJSONSerialization JSONObjectWithData:[library userDataResponseForURL:everyone] ?: [NSData data] options:0 error:nil];
    CHECK(answer.count == 5, "all five authors looked up past the allowance: %lu", (unsigned long)answer.count);
    CHECK([library hasEntryForKey:Key(@"https://www.redditstatic.com/avatars/defaults/v2/avatar_default_3.png")], "shared default avatar kept");
    CHECK(![library hasEntryForKey:Key(@"https://styles.redditmedia.com/t5_t2_c1/styles/profileIcon_x.png")], "custom pictures skipped");
    [NSFileManager.defaultManager removeItemAtURL:dir3.URLByDeletingLastPathComponent error:nil];

    // Images off: no lookups at all.
    NSURL *dir2 = TempDirectory();
    [requested removeAllObjects];
    options = Options(100ull * 1024 * 1024);
    options.includeImages = NO;
    RunDownload(dir2, options, responses, requested);
    CHECK(![requested containsObject:@"/api/user_data_by_account_ids"], "no avatar lookups without Images");
    [NSFileManager.defaultManager removeItemAtURL:dir2.URLByDeletingLastPathComponent error:nil];
}

static void TestRemovingReadPosts(void) {
    NSUInteger removed = 0;
    NSData *filtered = ApolloOfflineListingRemovingPosts(ListingData(@[ @"a", @"b", @"c" ], @"t3_c"), [NSSet setWithArray:@[ @"b", @"zz" ]], &removed);
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:filtered options:0 error:nil];
    CHECK(removed == 1, "one removed: %lu", (unsigned long)removed);
    CHECK([[root[@"data"][@"children"] valueForKeyPath:@"data.id"] isEqualToArray:(@[ @"a", @"c" ])], "kept order");
    CHECK([root[@"data"][@"after"] isEqual:@"t3_c"] && [root[@"data"][@"dist"] integerValue] == 2, "after kept, dist updated");
    CHECK(ApolloOfflineListingRemovingPosts(JSON(@[ @1 ]), [NSSet setWithObject:@"a"], NULL) == nil, "not a listing");
}

static void TestAutoRefreshPolicy(void) {
    ApolloOfflineAutoRefreshState s = {
        .enabled = YES, .hasLibrary = YES, .libraryAge = 61 * 60, .readFraction = 0, .networkAvailable = YES, .onWiFi = YES,
        .lowPowerMode = NO, .serving = NO, .downloading = NO, .sinceLastAttempt = 3600,
    };
    CHECK(ApolloOfflineShouldAutoRefresh(s), "stale batch on Wi-Fi refreshes");
    ApolloOfflineAutoRefreshState t = s; t.enabled = NO;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "setting off");
    t = s; t.hasLibrary = NO;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "never before a first manual download");
    t = s; t.onWiFi = NO;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "not on cellular by default");
    t.allowCellular = YES;
    CHECK(ApolloOfflineShouldAutoRefresh(t), "on cellular once Use Cellular Data is on");
    t.lowDataMode = YES;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "never in Low Data Mode, even with cellular allowed");
    t = s; t.lowDataMode = YES;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "never on a Low Data Mode Wi-Fi network");
    t = s; t.networkAvailable = NO; t.onWiFi = NO; t.allowCellular = YES;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "cellular allowed but no connection");
    t = s; t.lowPowerMode = YES;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "never in Low Power Mode");
    t = s; t.serving = YES;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "not while the batch is being browsed");
    t = s; t.libraryAge = 30 * 60;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "half-hour-old, mostly unread batch kept");
    t.readFraction = 0.6;
    CHECK(ApolloOfflineShouldAutoRefresh(t), "mostly read batch topped up before the hour");
    t.libraryAge = 5 * 60;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "but not one that was just downloaded");
    t = s; t.sinceLastAttempt = 10 * 60;
    CHECK(!ApolloOfflineShouldAutoRefresh(t), "a failed try waits 15 minutes");
}

static void TestDownloaderSkipsReadPosts(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    // Page one is entirely read: its saved stand-in is page two, under page one's key.
    ApolloOfflineDownloadOptions *options = Options(100ull * 1024 * 1024);
    options.skipPostIDs = [NSSet setWithArray:@[ @"a1", @"a2", @"a3", @"b2" ]];
    RunResult result = RunDownload(dir, options, ResponsesForTwoPages(), requested);
    CHECK(result.committed && result.posts == 2, "two unread posts: %lu", (unsigned long)result.posts);
    CHECK(![requested containsObject:@"/comments/a1"] && ![requested containsObject:@"/comments/b2"], "read posts not downloaded");
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSDictionary *first = [NSJSONSerialization JSONObjectWithData:[library dataForKey:Key(@"https://oauth.reddit.com/hot") contentType:nil] options:0 error:nil];
    CHECK([[first[@"data"][@"children"] valueForKeyPath:@"data.id"] isEqualToArray:(@[ @"b1", @"b3" ])], "page one shows the next unread posts");
    CHECK(first[@"data"][@"after"] == [NSNull null], "and ends the feed");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

// MARK: - Video and Saved

static NSData *Manifest(void) {
    NSString *mpd = @"<?xml version=\"1.0\"?><MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\"><Period>"
        "<AdaptationSet contentType=\"video\">"
        "<Representation id=\"1\" bandwidth=\"300000\" height=\"240\"><BaseURL>CMAF_240.mp4</BaseURL><SegmentBase indexRange=\"0-9\"/></Representation>"
        "<Representation id=\"2\" bandwidth=\"900000\" height=\"480\"><BaseURL>CMAF_480.mp4</BaseURL></Representation>"
        "<Representation id=\"3\" bandwidth=\"1800000\" height=\"720\"><BaseURL>CMAF_720.mp4</BaseURL></Representation>"
        "<Representation id=\"4\" bandwidth=\"4000000\" height=\"1080\"><BaseURL>CMAF_1080.mp4</BaseURL></Representation>"
        "<Representation id=\"5\" bandwidth=\"9000000\" height=\"1440\"><SegmentTemplate media=\"seg_$Number$.m4s\"/></Representation>"
        "</AdaptationSet>"
        "<AdaptationSet mimeType=\"audio/mp4\">"
        "<Representation id=\"6\" bandwidth=\"64000\"><BaseURL>CMAF_AUDIO_64.mp4</BaseURL></Representation>"
        "<Representation id=\"7\" bandwidth=\"128000\"><BaseURL>CMAF_AUDIO_128.mp4</BaseURL></Representation>"
        "</AdaptationSet></Period></MPD>";
    return [mpd dataUsingEncoding:NSUTF8StringEncoding];
}

static NSDictionary *VideoPost(NSString *postID, NSString *videoID, BOOL hasAudio) {
    NSMutableDictionary *post = [PostData(postID) mutableCopy];
    post[@"is_video"] = @YES;
    post[@"secure_media"] = @{ @"reddit_video": @{
        @"fallback_url": [NSString stringWithFormat:@"https://v.redd.it/%@/CMAF_720.mp4?source=fallback", videoID],
        @"dash_url": [NSString stringWithFormat:@"https://v.redd.it/%@/DASHPlaylist.mpd?a=1&amp;v=1&amp;f=sd", videoID],
        @"hls_url": [NSString stringWithFormat:@"https://v.redd.it/%@/HLSPlaylist.m3u8?a=1&amp;v=1&amp;f=sd", videoID],
        @"duration": @12,
        @"has_audio": @(hasAudio),
    } };
    return post;
}

static void TestVideoKeys(void) {
    CHECK([ApolloOfflineRedditVideoIDForURL([NSURL URLWithString:@"https://v.redd.it/AbC123xy/HLSPlaylist.m3u8?a=1"]) isEqualToString:@"abc123xy"], "master");
    CHECK([ApolloOfflineRedditVideoIDForURL([NSURL URLWithString:@"video-player://v.redd.it/abc123xy/HLSPlaylist.m3u8"]) isEqualToString:@"abc123xy"], "player scheme");
    CHECK([ApolloOfflineRedditVideoIDForURL([NSURL URLWithString:@"https://v.redd.it/abc123xy/CMAF_720.mp4"]) isEqualToString:@"abc123xy"], "media file");
    CHECK(ApolloOfflineRedditVideoIDForURL([NSURL URLWithString:@"https://i.redd.it/abc123xy.gif"]) == nil, "image host");
    CHECK(ApolloOfflineRedditVideoIDForURL(nil) == nil, "nil");
    CHECK([ApolloOfflineVideoKey(@"ABC123xy") isEqualToString:@"video:abc123xy"], "video key");
    CHECK([Key(@"https://v.redd.it/abc123xy/HLSPlaylist.m3u8?a=9&f=sd") isEqualToString:@"url:v.redd.it/abc123xy/HLSPlaylist.m3u8"], "master key drops query");

    CHECK([ApolloOfflineFeedKeyForPath(@"/user/Bob/saved") isEqualToString:@"saved/bob"], "saved feed");
    CHECK([Key(@"https://oauth.reddit.com/user/bob/saved?type=links&after=t3_X1") isEqualToString:@"feed:saved/bob|t3_x1"], "saved page key");
    CHECK(ApolloOfflineFeedKeyForPath(@"/user/bob/saved/extra") == nil, "not the saved list");
}

static void TestVideoForPost(void) {
    NSDictionary *video = ApolloOfflineRedditVideoForPost(VideoPost(@"p1", @"vid111", YES));
    CHECK([video[@"id"] isEqualToString:@"vid111"] && [video[@"duration"] doubleValue] == 12 && [video[@"hasAudio"] boolValue], "own video");
    CHECK([[video[@"dash"] absoluteString] isEqualToString:@"https://v.redd.it/vid111/DASHPlaylist.mpd?a=1&v=1&f=sd"], "dash unescaped: %s", [[video[@"dash"] absoluteString] UTF8String]);
    NSDictionary *crosspost = @{ @"id": @"p2", @"crosspost_parent_list": @[ VideoPost(@"p0", @"vid222", NO) ] };
    NSDictionary *parent = ApolloOfflineRedditVideoForPost(crosspost);
    CHECK([parent[@"id"] isEqualToString:@"vid222"] && ![parent[@"hasAudio"] boolValue], "crosspost parent's video");
    CHECK(ApolloOfflineRedditVideoForPost(PostData(@"p3")) == nil, "image post has none");
}

static void TestRenditions(void) {
    NSURL *manifestURL = [NSURL URLWithString:@"https://v.redd.it/vid111/DASHPlaylist.mpd?a=1&f=sd"];
    NSDictionary *r = ApolloOfflineRedditVideoRenditions(Manifest(), manifestURL, 720);
    CHECK([[r[@"video"] absoluteString] isEqualToString:@"https://v.redd.it/vid111/CMAF_720.mp4"], "720 cap: %s", [[r[@"video"] absoluteString] UTF8String]);
    CHECK([[r[@"audio"] absoluteString] isEqualToString:@"https://v.redd.it/vid111/CMAF_AUDIO_128.mp4"], "best audio");
    CHECK([r[@"videoBandwidth"] longLongValue] == 1800000 && [r[@"audioBandwidth"] longLongValue] == 128000, "bandwidths");
    NSDictionary *tiny = ApolloOfflineRedditVideoRenditions(Manifest(), manifestURL, 100);
    CHECK([[tiny[@"video"] lastPathComponent] isEqualToString:@"CMAF_240.mp4"], "nothing fits: shortest");
    NSDictionary *huge = ApolloOfflineRedditVideoRenditions(Manifest(), manifestURL, 4000);
    CHECK([[huge[@"video"] lastPathComponent] isEqualToString:@"CMAF_1080.mp4"], "segmented 1440 skipped");
    CHECK(ApolloOfflineRedditVideoRenditions([@"not xml" dataUsingEncoding:NSUTF8StringEncoding], manifestURL, 720) == nil, "garbage");
    CHECK(ApolloOfflineEstimatedBrowseTime(10, 30) == 150, "browse time");
}

static NSMutableDictionary *VideoResponses(void) {
    NSMutableDictionary *responses = [NSMutableDictionary dictionary];
    NSDictionary *listing = @{ @"kind": @"Listing", @"data": @{ @"after": [NSNull null], @"children": @[
        @{ @"kind": @"t3", @"data": VideoPost(@"v1", @"vid111", YES) },
        @{ @"kind": @"t3", @"data": PostData(@"i1") },
    ] } };
    responses[@"/best"] = JSON(listing);
    for (NSString *postID in @[ @"v1", @"i1" ]) {
        responses[[@"/comments/" stringByAppendingString:postID]] = JSON(@[ @{ @"kind": @"Listing" }, @{ @"kind": @"Listing" } ]);
    }
    responses[@"preview.redd.it"] = [NSMutableData dataWithLength:1000];
    responses[@"b.thumbs.redditmedia.com"] = [NSMutableData dataWithLength:100];
    responses[@"v.redd.it/vid111/DASHPlaylist.mpd"] = Manifest();
    responses[@"v.redd.it/vid111/CMAF_720.mp4"] = [NSMutableData dataWithLength:5000];
    responses[@"v.redd.it/vid111/CMAF_AUDIO_128.mp4"] = [NSMutableData dataWithLength:700];
    responses[@"v.redd.it/vid111/HLSPlaylist.m3u8"] = [@"#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO\n" dataUsingEncoding:NSUTF8StringEncoding];
    return responses;
}

static void TestDownloaderVideo(void) {
    __block NSUInteger muxCalls = 0;
    __block BOOL sawAudio = NO;
    sTestMuxer = ^(NSURL *video, NSURL *audio, NSURL *output, void (^done)(BOOL, NSTimeInterval)) {
        muxCalls++;
        sawAudio = audio != nil;
        NSMutableData *joined = [NSMutableData dataWithContentsOfURL:video];
        if (audio) [joined appendData:[NSData dataWithContentsOfURL:audio]];
        BOOL ok = [joined writeToURL:output atomically:NO];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ done(ok, 11.5); });
    };
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    RunResult result = RunDownload(dir, Options(100ull * 1000 * 1000), VideoResponses(), requested);
    CHECK(result.committed && result.posts == 2, "both posts: %lu", (unsigned long)result.posts);
    CHECK(muxCalls == 1 && sawAudio, "one remux with audio (%lu)", (unsigned long)muxCalls);
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    NSURL *file = [library fileURLForKey:@"video:vid111"];
    NSDictionary *attributes = file ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
    CHECK([file.pathExtension isEqualToString:@"mp4"] && attributes.fileSize == 5700, "saved mp4 with sound: %s %llu",
          file.path.UTF8String, attributes.fileSize);
    CHECK(library.videoCount == 1 && library.videoSeconds == 11.5, "video stats %lu %.1f", (unsigned long)library.videoCount, library.videoSeconds);
    CHECK([library hasEntryForKey:Key(@"https://v.redd.it/vid111/HLSPlaylist.m3u8?a=2")], "master saved for Apollo's sound check");
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:[dir.path stringByAppendingPathComponent:@"scratch"]], "no scratch left behind");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];

    // Without a remuxer, or with Videos off, the post still saves; the video doesn't.
    dir = TempDirectory();
    ApolloOfflineDownloadOptions *options = Options(100ull * 1000 * 1000);
    options.includeVideos = NO;
    muxCalls = 0;
    result = RunDownload(dir, options, VideoResponses(), requested);
    library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK(result.posts == 2 && muxCalls == 0 && ![library hasEntryForKey:@"video:vid111"], "videos off");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];

    // A video bigger than what's left of the limit is skipped, the post kept.
    dir = TempDirectory();
    [requested removeAllObjects];
    result = RunDownload(dir, Options(20000), VideoResponses(), requested);
    library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK(result.posts >= 1 && ![library hasEntryForKey:@"video:vid111"] && ![requested containsObject:@"v.redd.it/vid111/CMAF_720.mp4"],
          "over the limit: skipped before downloading");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
    sTestMuxer = nil;
}

static void TestSavedSourceKeepsReadPosts(void) {
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    NSMutableDictionary *responses = [ResponsesForTwoPages() mutableCopy];
    responses[@"/user/bob/saved"] = responses[@"/best"];
    responses[@"/user/bob/saved?after=t3_a3"] = responses[@"/best?after=t3_a3"];
    ApolloOfflineDownloadOptions *options = Options(100ull * 1024 * 1024);
    ApolloOfflineFeedSource *saved = [ApolloOfflineFeedSource sourceWithPath:@"/user/bob/saved" title:@"Saved"];
    saved.keepsReadPosts = YES;
    saved.queryItems = @[ [NSURLQueryItem queryItemWithName:@"type" value:@"links"] ];
    options.sources = @[ saved ];
    options.skipPostIDs = [NSSet setWithArray:@[ @"a1", @"a2" ]];
    RunResult result = RunDownload(dir, options, responses, requested);
    CHECK(result.committed && result.posts == 6, "saved keeps read posts: %lu", (unsigned long)result.posts);
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK([library hasEntryForKey:Key(@"https://oauth.reddit.com/user/bob/saved?raw_json=1")], "Apollo's Saved list resolves");
    CHECK([library.feedTitles isEqualToArray:@[ @"Saved" ]], "titled Saved");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static NSMutableDictionary *LinkPost(NSString *postID, NSString *link) {
    NSMutableDictionary *post = [PostData(postID) mutableCopy];
    post[@"url"] = link;
    post[@"post_hint"] = @"link";
    post[@"title"] = [@"Title of " stringByAppendingString:postID];
    return post;
}

static void TestHostedAndArticles(void) {
    NSDictionary *imgur = ApolloOfflineHostedVideoForPost(LinkPost(@"h1", @"https://i.imgur.com/AbC12dE.gifv"));
    CHECK([imgur[@"host"] isEqualToString:@"imgur"] && [imgur[@"id"] isEqualToString:@"AbC12dE"], "imgur gifv");
    CHECK(ApolloOfflineHostedVideoForPost(LinkPost(@"h2", @"https://i.imgur.com/AbC12dE.jpg")) == nil, "imgur image isn't video");
    CHECK([ApolloOfflineHostedVideoForPost(LinkPost(@"h3", @"https://streamable.com/xyz98"))[@"id"] isEqualToString:@"xyz98"], "streamable");
    NSDictionary *red = ApolloOfflineHostedVideoForPost(LinkPost(@"h4", @"https://www.redgifs.com/watch/SomeFunnyName"));
    CHECK([red[@"host"] isEqualToString:@"redgifs"] && [red[@"id"] isEqualToString:@"somefunnyname"], "redgifs watch");
    CHECK([ApolloOfflineHostedVideoForPost(@{ @"crosspost_parent_list": @[ LinkPost(@"h5", @"https://streamable.com/e/qq11") ] })[@"id"] isEqualToString:@"qq11"], "crosspost");

    CHECK([[ApolloOfflineArticleURLForPost(LinkPost(@"a1", @"https://www.example.com/news/story-1?ref=rss")) host] isEqualToString:@"www.example.com"], "article");
    CHECK(ApolloOfflineArticleURLForPost(LinkPost(@"a2", @"https://www.youtube.com/watch?v=abc")) == nil, "youtube isn't an article");
    CHECK(ApolloOfflineArticleURLForPost(LinkPost(@"a3", @"https://i.redd.it/x.jpg")) == nil, "image isn't an article");
    NSMutableDictionary *selfPost = LinkPost(@"a4", @"https://www.reddit.com/r/x/comments/a4/t/");
    selfPost[@"is_self"] = @YES;
    CHECK(ApolloOfflineArticleURLForPost(selfPost) == nil, "self post");
    CHECK(ApolloOfflineArticleURLForPost(LinkPost(@"a5", @"https://example.com/report.pdf")) == nil, "pdf skipped");

    CHECK([ApolloOfflinePageKey([NSURL URLWithString:@"https://WWW.Example.com/news/story-1/?ref=rss#top"]) isEqualToString:@"page:example.com/news/story-1?ref=rss"], "page key: %s",
          ApolloOfflinePageKey([NSURL URLWithString:@"https://WWW.Example.com/news/story-1/?ref=rss#top"]).UTF8String);
    CHECK([ApolloOfflinePageKey([NSURL URLWithString:@"https://example.com"]) isEqualToString:@"page:example.com/"], "bare host");
}

static NSData *Bytes(NSUInteger n) { return [NSMutableData dataWithLength:n]; }

// A web archive like WebKit's: the page HTML (with a share image) as the main resource.
static NSData *Archive(NSURL *url) {
    NSMutableString *html = [NSMutableString stringWithString:@"<html><head><title>Story</title>"
        "<meta property=\"og:image\" content=\"https://cdn.example.com/share.jpg?w=1200&amp;h=630\"></head><body>"];
    while (html.length < 20000) [html appendString:@"<p>Paragraph of the story.</p>"];
    [html appendString:@"</body></html>"];
    NSDictionary *plist = @{ @"WebMainResource": @{
        @"WebResourceData": [html dataUsingEncoding:NSUTF8StringEncoding], @"WebResourceMIMEType": @"text/html",
        @"WebResourceTextEncodingName": @"UTF-8", @"WebResourceURL": url.absoluteString } };
    return [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

static void TestWebArchiveHelpers(void) {
    NSURL *page = [NSURL URLWithString:@"https://www.example.com/news/story-1"];
    NSData *archive = Archive(page);
    NSString *mime = nil;
    NSData *html = ApolloOfflineWebArchiveMainResource(archive, &mime, NULL);
    CHECK(html.length > 20000 && [mime isEqualToString:@"text/html"], "main resource");
    CHECK([[ApolloOfflineWebArchiveShareImageURL(archive, page) absoluteString] isEqualToString:@"https://cdn.example.com/share.jpg?w=1200&h=630"], "og:image");
    CHECK(ApolloOfflineWebArchiveMainResource([@"junk" dataUsingEncoding:NSUTF8StringEncoding], NULL, NULL) == nil, "not an archive");
    CHECK([Key(ApolloOfflineFaviconURL(page).absoluteString) isEqualToString:@"favicon:example.com"], "favicon key");
}

static void TestDownloaderAccountReads(void) {
    NSMutableDictionary *responses = [ResponsesForTwoPages() mutableCopy];
    responses[@"/message/inbox"] = JSON(@{ @"kind": @"Listing", @"data": @{ @"after": @"t1_x", @"children": @[] } });
    responses[@"/message/inbox?after=t1_x"] = JSON(@{ @"kind": @"Listing", @"data": @{ @"after": [NSNull null], @"children": @[] } });
    responses[@"/r/pics/about"] = JSON(@{ @"kind": @"t5", @"data": @{ @"display_name": @"pics",
        @"community_icon": @"https://styles.redditmedia.com/t5_1/styles/communityIcon_x.png?width=256&amp;s=1" } });
    responses[@"styles.redditmedia.com"] = Bytes(800);
    ApolloOfflineDownloadOptions *options = Options(100ull * 1024 * 1024);
    options.accountPaths = @[ @"/message/inbox", @"/r/pics/about", @"/prefs/blocked" ];
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    RunResult result = RunDownload(dir, options, responses, requested);
    CHECK(result.committed && result.posts == 6, "feed still saved");
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];
    CHECK([library hasEntryForKey:Key(@"https://www.reddit.com/message/inbox.json?limit=25")], "inbox page one");
    CHECK([library hasEntryForKey:Key(@"https://www.reddit.com/message/inbox.json?after=t1_x")], "inbox page two");
    CHECK([library hasEntryForKey:Key(@"https://oauth.reddit.com/r/Pics/about")], "subreddit about");
    CHECK([library hasEntryForKey:Key(@"https://styles.redditmedia.com/t5_1/styles/communityIcon_x.png?width=64")], "subreddit icon");
    CHECK(![library hasEntryForKey:Key(@"https://oauth.reddit.com/prefs/blocked")], "a failed read is just skipped");
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
}

static void TestDownloaderHostedAndPages(void) {
    NSMutableDictionary *responses = [NSMutableDictionary dictionary];
    NSDictionary *listing = @{ @"kind": @"Listing", @"data": @{ @"after": [NSNull null], @"children": @[
        @{ @"kind": @"t3", @"data": LinkPost(@"p1", @"https://i.imgur.com/AbC12dE.gifv") },
        @{ @"kind": @"t3", @"data": LinkPost(@"p2", @"https://streamable.com/xyz98") },
        @{ @"kind": @"t3", @"data": LinkPost(@"p3", @"https://www.redgifs.com/watch/somefunnyname") },
        @{ @"kind": @"t3", @"data": LinkPost(@"p4", @"https://www.example.com/news/story-1") },
    ] } };
    responses[@"/best"] = JSON(listing);
    for (NSString *postID in @[ @"p1", @"p2", @"p3", @"p4" ]) {
        responses[[@"/comments/" stringByAppendingString:postID]] = JSON(@[ @{ @"kind": @"Listing" }, @{ @"kind": @"Listing" } ]);
    }
    responses[@"preview.redd.it"] = Bytes(1000);
    responses[@"b.thumbs.redditmedia.com"] = Bytes(100);
    responses[@"i.imgur.com/AbC12dE.mp4"] = Bytes(3000);
    responses[@"api.streamable.com/videos/xyz98"] = JSON(@{ @"files": @{
        @"mp4": @{ @"url": @"//cdn.streamable.com/video/mp4/xyz98.mp4?token=a", @"height": @1080, @"duration": @9 },
        @"mp4-mobile": @{ @"url": @"https://cdn.streamable.com/video/mp4-mobile/xyz98.mp4?token=b", @"height": @480, @"duration": @9 },
    } });
    responses[@"cdn.streamable.com/video/mp4-mobile/xyz98.mp4"] = Bytes(2000);
    responses[@"api.redgifs.com/v2/auth/temporary"] = JSON(@{ @"token": @"tok123" });
    responses[@"api.redgifs.com/v2/gifs/somefunnyname"] = JSON(@{ @"gif": @{ @"duration": @6, @"urls": @{
        @"hd": @"https://media.redgifs.com/SomeFunnyName.mp4", @"sd": @"https://media.redgifs.com/SomeFunnyName-mobile.mp4" } } });
    responses[@"media.redgifs.com/SomeFunnyName-mobile.mp4"] = Bytes(1500);
    responses[@"cdn.example.com/share.jpg"] = Bytes(700);
    responses[@"www.google.com/s2/favicons"] = Bytes(300);

    __block NSMutableArray<NSURL *> *pagesAsked = [NSMutableArray array];
    sTestPageSaver = ^(NSURL *url, void (^done)(NSData *)) {
        @synchronized (pagesAsked) { [pagesAsked addObject:url]; }
        // A real page's archive; a few hundred bytes would be a bot wall.
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ done(Archive(url)); });
    };
    NSURL *dir = TempDirectory();
    NSMutableArray *requested = [NSMutableArray array];
    RunResult result = RunDownload(dir, Options(100ull * 1000 * 1000), responses, requested);
    CHECK(result.committed && result.posts == 4, "four posts: %lu", (unsigned long)result.posts);
    ApolloOfflineLibrary *library = [[ApolloOfflineLibrary alloc] initWithDirectory:dir];

    // What Apollo's player will ask for resolves to the saved files.
    NSURL *(^video)(NSString *) = ^NSURL *(NSString *u) { return [library videoFileURLForURL:[NSURL URLWithString:u]]; };
    CHECK(video(@"https://i.imgur.com/AbC12dE.mp4") != nil, "imgur mp4");
    CHECK([video(@"https://i.imgur.com/AbC12dE.gifv") isEqual:video(@"https://i.imgur.com/AbC12dE.mp4")], "imgur gifv alias");
    CHECK(video(@"https://cdn.streamable.com/video/mp4-mobile/xyz98.mp4?token=zz") != nil, "streamable mobile");
    CHECK([video(@"https://cdn.streamable.com/video/mp4/xyz98.mp4?token=a") isEqual:video(@"https://cdn.streamable.com/video/mp4-mobile/xyz98.mp4")],
          "streamable full URL is an alias (1080p over the cap)");
    CHECK(![requested containsObject:@"cdn.streamable.com/video/mp4/xyz98.mp4"], "1080p never fetched");
    CHECK(video(@"https://media.redgifs.com/SomeFunnyName.mp4") != nil && video(@"https://media.redgifs.com/SomeFunnyName-mobile.mp4") != nil, "redgifs hd + sd");
    CHECK(video(@"https://example.com/other.mp4") == nil, "unsaved");
    // And the API answers Apollo asks for first.
    CHECK([library hasEntryForKey:Key(@"https://api.streamable.com/videos/xyz98")], "streamable info");
    CHECK([library hasEntryForKey:Key(@"https://api.redgifs.com/v2/auth/temporary")], "redgifs token");
    CHECK([library hasEntryForKey:Key(@"https://api.redgifs.com/v2/gifs/somefunnyname")], "redgifs gif info");
    CHECK(library.videoCount == 3, "three outside videos: %lu", (unsigned long)library.videoCount);

    CHECK(pagesAsked.count == 1 && [pagesAsked.firstObject.host isEqualToString:@"www.example.com"], "only the article page: %lu", (unsigned long)pagesAsked.count);
    CHECK([library pageArchiveForURL:[NSURL URLWithString:@"https://www.example.com/news/story-1/"]] != nil, "page saved");
    CHECK(library.pageCount == 1, "page count");
    // Apollo's own GET of the article (no www.) gets the page HTML for its link card.
    NSString *type = nil;
    NSData *document = [library pageDocumentForURL:[NSURL URLWithString:@"https://example.com/news/story-1"] contentType:&type];
    CHECK(document.length > 20000 && [type hasPrefix:@"text/html"], "article HTML for the link card: %s", type.UTF8String);
    CHECK([library hasEntryForKey:Key(@"https://cdn.example.com/share.jpg?w=600")], "share image saved");
    CHECK([library hasEntryForKey:@"favicon:example.com"], "favicon saved");
    // Each file counted once: 3000 + 2000 + 1500 of video, aliases add nothing.
    NSUInteger videoBytes = 0;
    for (NSString *u in @[ @"https://i.imgur.com/AbC12dE.mp4", @"https://cdn.streamable.com/video/mp4-mobile/xyz98.mp4", @"https://media.redgifs.com/SomeFunnyName-mobile.mp4" ]) {
        videoBytes += (NSUInteger)[[NSFileManager.defaultManager attributesOfItemAtPath:video(u).path error:nil] fileSize];
    }
    CHECK(videoBytes == 6500, "video bytes %lu", (unsigned long)videoBytes);

    // Pages off: nothing asked.
    [pagesAsked removeAllObjects];
    NSURL *dir2 = TempDirectory();
    ApolloOfflineDownloadOptions *options = Options(100ull * 1000 * 1000);
    options.includePages = NO;
    RunDownload(dir2, options, responses, requested);
    CHECK(pagesAsked.count == 0, "pages off");
    // ...but the link card still gets a stand-in page and the site icon.
    ApolloOfflineLibrary *noPages = [[ApolloOfflineLibrary alloc] initWithDirectory:dir2];
    NSURL *article = [NSURL URLWithString:@"https://www.example.com/news/story-1"];
    NSString *cardType = nil;
    NSString *card = [[NSString alloc] initWithData:[noPages pageDocumentForURL:article contentType:&cardType] encoding:NSUTF8StringEncoding];
    CHECK([card containsString:@"og:image"] && [card containsString:@"preview.redd.it/p4.jpg"] && [card containsString:@"<title>"],
          "stand-in card: %s", card.UTF8String);
    CHECK([noPages pageArchiveForURL:article] == nil && noPages.pageCount == 0, "no reader page without an archive");
    CHECK([noPages hasEntryForKey:@"favicon:example.com"], "favicon saved without the page");

    // An archive whose page HTML is empty (just images) isn't kept.
    NSURL *dir3 = TempDirectory();
    sTestPageSaver = ^(NSURL *url, void (^done)(NSData *)) {
        NSDictionary *plist = @{ @"WebMainResource": @{ @"WebResourceData": [@"<!DOCTYPE html>" dataUsingEncoding:NSUTF8StringEncoding],
                                                        @"WebResourceMIMEType": @"text/html", @"WebResourceURL": url.absoluteString },
                                 @"WebSubresources": @[ @{ @"WebResourceData": Bytes(50000), @"WebResourceURL": @"https://x/y.jpg" } ] };
        done([NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]);
    };
    RunDownload(dir3, Options(100ull * 1000 * 1000), responses, requested);
    CHECK([[ApolloOfflineLibrary alloc] initWithDirectory:dir3].pageCount == 0, "empty page rejected");
    [NSFileManager.defaultManager removeItemAtURL:dir3.URLByDeletingLastPathComponent error:nil];
    sTestPageSaver = nil;
    [NSFileManager.defaultManager removeItemAtURL:dir.URLByDeletingLastPathComponent error:nil];
    [NSFileManager.defaultManager removeItemAtURL:dir2.URLByDeletingLastPathComponent error:nil];
}

int main(void) {
    @autoreleasepool {
        TestFeedKeys();
        TestURLKeys();
        TestPolicy();
        TestImageURLs();
        TestTruncate();
        TestWriterAndLibrary();
        TestDownloaderWholeFeed();
        TestDownloaderBudget();
        TestDownloaderFailureKeepsOldLibrary();
        TestRemovingReadPosts();
        TestAPISpacing();
        TestUserDataHelpers();
        TestDownloaderAvatars();
        TestDownloaderRunsPostsTogether();
        TestDownloaderCancelWithPostsInFlight();
        TestDownloaderHonorsRateLimitHeaders();
        TestAutoRefreshPolicy();
        TestDownloaderSkipsReadPosts();
        TestVideoKeys();
        TestVideoForPost();
        TestRenditions();
        TestDownloaderVideo();
        TestSavedSourceKeepsReadPosts();
        TestHostedAndArticles();
        TestDownloaderHostedAndPages();
        TestWebArchiveHelpers();
        TestDownloaderAccountReads();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("offline library tests passed\n");
    return 0;
}
