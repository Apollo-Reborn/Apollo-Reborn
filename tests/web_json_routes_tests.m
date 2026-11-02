#import <Foundation/Foundation.h>
#import "ApolloWebJSONRoutes.h"

static int sFailures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static void BlockTimes(NSString *account, NSString *path, ApolloWebJSONRoute route, int times, NSTimeInterval at);

static NSArray<NSNumber *> *Fallbacks(void) {
    return @[ @(ApolloWebJSONRouteWwwDotJSON), @(ApolloWebJSONRouteOld) ];
}

static void TestTableEndpoints(void) {
    for (NSString *path in @[ @"api/info.json", @"/api/info.json", @"/api/info", @"/api/info/", @"/api/info/.json",
                              @"/API/Info.json", @"/api/info.json?id=t1_a" ]) {
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", path) isEqualToArray:Fallbacks()], @"GET %@ falls back", path);
        CHECK(ApolloWebJSONRouteRequestMayRetry(@"GET", path), @"GET %@ may retry", path);
    }
    CHECK([ApolloWebJSONRoutesForRequest(@"get", @"/api/info.json") isEqualToArray:Fallbacks()], @"method is case-insensitive");
    for (NSString *method in @[ @"GET", @"POST" ]) {
        for (NSString *path in @[ @"api/morechildren.json", @"/api/morechildren", @"/api/morechildren/.json" ]) {
            CHECK([ApolloWebJSONRoutesForRequest(method, path) isEqualToArray:Fallbacks()], @"%@ %@ falls back", method, path);
            CHECK(ApolloWebJSONRouteRequestMayRetry(method, path), @"%@ %@ may retry", method, path);
        }
    }
}

static NSArray<NSString *> *SearchPaths(void) {
    return @[ @"/search", @"search.json", @"/search/.json", @"/search.json?q=apollo&sort=new", @"/subreddits/search.json",
              @"/r/iOS/search.json", @"/r/ios+apple/search/", @"/R/Apple/Search",
              @"/r/apollosideloaded+ApolloReborn+ApolloAppBeta+apolloapp/search.json" ];
}

static void TestSearchEndpoints(void) {
    NSArray *search = @[ @(ApolloWebJSONRouteOAuth), @(ApolloWebJSONRouteOld) ];
    for (NSString *path in SearchPaths()) {
        CHECK(ApolloWebJSONRequestIsSearchRead(@"GET", path), @"GET %@ is search", path);
        CHECK(ApolloWebJSONRequestIsSearchRead(@"get", path), @"method is case-insensitive for %@", path);
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", path) isEqualToArray:search], @"GET %@: oauth, then old", path);
        CHECK(ApolloWebJSONRouteRequestMayRetry(@"GET", path), @"GET %@ may retry", path);
        for (NSString *method in @[ @"POST", @"PUT", @"DELETE", @"HEAD" ]) {
            CHECK(!ApolloWebJSONRequestIsSearchRead(method, path), @"%@ %@ isn't a search read", method, path);
            CHECK([ApolloWebJSONRoutesForRequest(method, path) isEqualToArray:@[ @(ApolloWebJSONRouteWww) ]], @"%@ %@ stays on www", method, path);
        }
    }
    for (NSString *path in @[ @"/searching", @"/search/extra", @"/r/ios/search/extra", @"/user/alice/search",
                              @"/user/Alice/m/dev/search.json", @"/u/Bob/m/search/search.json",
                              @"/api/search_reddit_names", @"/subreddits/mine/subscriber", @"/r/ios/hot", @"/" ]) {
        CHECK(!ApolloWebJSONRequestIsSearchRead(@"GET", path), @"%@ isn't search", path);
    }
    CHECK(!ApolloWebJSONRequestIsSearchRead((NSString *)(id)[NSNull null], @"/search"), @"bad method");
    CHECK(!ApolloWebJSONRequestIsSearchRead(@"GET", (NSString *)(id)@42), @"bad path");
    CHECK([ApolloWebJSONRoutePathPattern(@"/r/iOS/search.json") isEqualToString:@"/r/*/search"], @"community searches group");
    ApolloWebJSONRouteHealthReset();
    BlockTimes(@"alice", @"/r/apple/search.json", ApolloWebJSONRouteOAuth, 3, 0);
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"/r/iOS/search.json", 0, 1) == ApolloWebJSONRouteOld,
          @"oauth cooling for community search: old");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"/search.json", 0, 1) == ApolloWebJSONRouteOAuth,
          @"global search has its own health");
    ApolloWebJSONRouteHealthReset();
}

static void TestEverythingElseStaysOnWww(void) {
    NSArray *www = @[ @(ApolloWebJSONRouteWww) ];
    NSArray<NSArray<NSString *> *> *requests = @[
        @[ @"POST", @"/api/info.json" ],          // /api/info is a GET-only entry
        @[ @"DELETE", @"/api/morechildren.json" ],
        @[ @"POST", @"/api/comment" ],            // writes
        @[ @"POST", @"/api/vote" ],
        @[ @"POST", @"/api/editusertext" ],
        @[ @"GET", @"/api/information" ],         // near misses
        @[ @"GET", @"/api/info/extra" ],
        @[ @"GET", @"/r/all/api/info.json" ],
        @[ @"GET", @"/r/popular/hot.json" ],      // listings
        @[ @"GET", @"/comments/abc123.json" ],
        @[ @"GET", @"" ],
        @[ @"GET", @"/" ],
    ];
    for (NSArray<NSString *> *r in requests) {
        CHECK([ApolloWebJSONRoutesForRequest(r[0], r[1]) isEqualToArray:www], @"%@ %@ stays on www", r[0], r[1]);
        CHECK(!ApolloWebJSONRouteRequestMayRetry(r[0], r[1]), @"%@ %@ is never resent", r[0], r[1]);
    }
    CHECK([ApolloWebJSONRoutesForRequest((NSString *)(id)[NSNull null], @"/api/info") isEqualToArray:www], @"bad method");
    CHECK([ApolloWebJSONRoutesForRequest(@"GET", (NSString *)(id)@42) isEqualToArray:www], @"bad path");
}

static void TestRouteTransforms(void) {
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteWwwDotJSON, @"/api/info.json") isEqualToString:@"/api/info/.json"], @"dotjson info");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteWwwDotJSON, @"api/morechildren") isEqualToString:@"/api/morechildren/.json"], @"dotjson morechildren");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteOld, @"/api/info.json") isEqualToString:@"/api/info.json"], @"old keeps the path");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteWww, @"/api/info.json") isEqualToString:@"/api/info.json"], @"www keeps the path");
    CHECK([ApolloWebJSONRouteHost(ApolloWebJSONRouteWww) isEqualToString:@"www.reddit.com"], @"www host");
    CHECK([ApolloWebJSONRouteHost(ApolloWebJSONRouteWwwDotJSON) isEqualToString:@"www.reddit.com"], @"dotjson host");
    CHECK([ApolloWebJSONRouteHost(ApolloWebJSONRouteOld) isEqualToString:@"old.reddit.com"], @"old host");
    CHECK([ApolloWebJSONRouteHost(ApolloWebJSONRouteApi) isEqualToString:@"api.reddit.com"], @"api host");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteApi, @"/api/info.json") isEqualToString:@"/api/info.json"], @"api keeps the path");
    CHECK([ApolloWebJSONRouteName(ApolloWebJSONRouteApi) isEqualToString:@"api"], @"api name");
    CHECK([ApolloWebJSONRouteHost(ApolloWebJSONRouteOAuth) isEqualToString:@"oauth.reddit.com"], @"oauth host");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteOAuth, @"/r/ios/search.json") isEqualToString:@"/r/ios/search.json"], @"oauth keeps the path");
    CHECK([ApolloWebJSONRouteName(ApolloWebJSONRouteOAuth) isEqualToString:@"oauth"], @"oauth name");
    CHECK(ApolloWebJSONRouteApi == 3 && ApolloWebJSONRouteOAuth == 4, @"route numbers in URL markers stay put");
    CHECK(ApolloWebJSONRouteOAuthBearer == 5 && ApolloWebJSONRouteWwwRAll == 6 && ApolloWebJSONRouteLast == 14,
          @"routes after the first five keep their numbers too");
    for (NSArray<NSString *> *builtIn in @[ @[ @"GET", @"/api/info" ], @[ @"GET", @"/api/morechildren" ], @[ @"POST", @"/api/morechildren" ] ]) {
        CHECK(![ApolloWebJSONRoutesForRequest(builtIn[0], builtIn[1]) containsObject:@(ApolloWebJSONRouteApi)],
              @"api isn't in the built-in table for %@ %@", builtIn[0], builtIn[1]);
    }
    CHECK([ApolloWebJSONRouteName(ApolloWebJSONRouteWwwDotJSON) isEqualToString:@"www-dotjson"], @"name");
}

static NSHTTPURLResponse *Response(NSInteger status, NSString *contentType) {
    NSDictionary *headers = contentType ? @{ @"Content-Type": contentType } : @{};
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://www.reddit.com/api/info.json"]
                                       statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
}

static void TestBlockPage(void) {
    CHECK(ApolloWebJSONRouteResponseIsBlockPage(Response(403, @"text/html")), @"403 html");
    CHECK(ApolloWebJSONRouteResponseIsBlockPage(Response(403, @"text/html; charset=utf-8")), @"403 html charset");
    CHECK(!ApolloWebJSONRouteResponseIsBlockPage(Response(403, @"application/json; charset=UTF-8")), @"403 json is a content error");
    CHECK(!ApolloWebJSONRouteResponseIsBlockPage(Response(429, @"text/html")), @"429 is a rate limit");
    CHECK(!ApolloWebJSONRouteResponseIsBlockPage(Response(200, @"text/html")), @"200");
    CHECK(!ApolloWebJSONRouteResponseIsBlockPage(Response(403, nil)), @"403 without a type");
    CHECK(!ApolloWebJSONRouteResponseIsBlockPage(nil), @"nil");
}

static NSHTTPURLResponse *ResponseAt(NSString *url, NSInteger status, NSString *contentType) {
    NSDictionary *headers = contentType ? @{ @"Content-Type": contentType } : @{};
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:url]
                                       statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
}

static void TestSignInGate(void) {
    // What old.reddit.com answers an account it won't serve (2026-10-27).
    NSString *gate = @"https://old.reddit.com/login/?reason=lor2&dest=https%3A%2F%2Fold.reddit.com%2Fapi%2Finfo.json%3Fid%3Dt3_1#apollo-webjson-account=alice;route=2";
    CHECK(ApolloWebJSONRouteResponseIsSignInGate(ResponseAt(gate, 200, @"text/html; charset=utf-8")), @"old gate");
    CHECK(ApolloWebJSONRouteResponseIsRefusal(ResponseAt(gate, 200, @"text/html; charset=utf-8")), @"old gate is a refusal");
    CHECK(ApolloWebJSONRouteResponseIsSignInGate(ResponseAt(@"https://www.reddit.com/login", 200, @"text/html")), @"www login");
    CHECK(!ApolloWebJSONRouteResponseIsSignInGate(ResponseAt(@"https://old.reddit.com/api/info.json?id=t3_1", 200,
                                                             @"application/json; charset=UTF-8")), @"old answered");
    CHECK(!ApolloWebJSONRouteResponseIsSignInGate(ResponseAt(@"https://old.reddit.com/login.json", 200, @"application/json")),
          @"not the /login page");
    CHECK(!ApolloWebJSONRouteResponseIsSignInGate(ResponseAt(@"https://old.reddit.com/loginhelp", 200, @"text/html")),
          @"another path");
    CHECK(!ApolloWebJSONRouteResponseIsSignInGate(ResponseAt(@"https://example.com/login/", 200, @"text/html")), @"not Reddit");
    CHECK(!ApolloWebJSONRouteResponseIsSignInGate(ResponseAt(@"https://notreddit.com/login/", 200, @"text/html")), @"lookalike");
    CHECK(!ApolloWebJSONRouteResponseIsSignInGate(nil), @"nil");
    CHECK(ApolloWebJSONRouteResponseIsRefusal(Response(403, @"text/html")), @"block page is a refusal");
    CHECK(!ApolloWebJSONRouteResponseIsRefusal(Response(200, @"application/json")), @"an answer");
    CHECK(!ApolloWebJSONRouteResponseIsRefusal(Response(429, @"text/html")), @"429 is a rate limit");
}

static NSString *const kInfo = @"/api/info.json";
static NSTimeInterval const kHour = 3600.0;

static void BlockTimes(NSString *account, NSString *path, ApolloWebJSONRoute route, int times, NSTimeInterval at) {
    for (int i = 0; i < times; i++) ApolloWebJSONRouteHealthNoteBlockPage(account, @"GET", path, route, at);
}

static void TestCooldownStartsAfterThreeBlocks(void) {
    ApolloWebJSONRouteHealthReset();
    CHECK(!ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 0), @"1st block");
    CHECK(!ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 1), @"2nd block");
    CHECK(ApolloWebJSONRoutePathPattern(kInfo).length > 0, @"pattern");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 2) == 0, @"no cooldown after two");
    CHECK(ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 2), @"3rd block starts a cooldown");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 2) == kHour, @"an hour");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", @"/api/info/.json", ApolloWebJSONRouteWwwDotJSON, 2) == kHour,
          @"the path the route sent groups with the one asked for");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"ALICE", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 2) == kHour, @"account is case-insensitive");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"bob", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 2) == 0, @"per account");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", kInfo, ApolloWebJSONRouteOld, 2) == 0, @"per route");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", @"/api/morechildren", ApolloWebJSONRouteWwwDotJSON, 2) == 0, @"per path");
    CHECK(!ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 3),
          @"a block during the cooldown (sent before it began) doesn't extend it");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, 3) == kHour - 1, @"unchanged");
}

static void TestCooldownDoublesAndClears(void) {
    ApolloWebJSONRouteHealthReset();
    BlockTimes(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 3, 0);
    NSTimeInterval t = kHour;
    CHECK(ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, t),
          @"the first block after a cooldown starts the next one");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, t) == 2 * kHour, @"doubled");
    for (int i = 0; i < 5; i++) {
        t += ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, t);
        ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, t);
    }
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, t) == 8 * kHour, @"capped at 8h");
    ApolloWebJSONRouteHealthNoteSuccess(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, t);
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, t) == 0, @"a success clears it");
    CHECK(!ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", kInfo, ApolloWebJSONRouteWwwDotJSON, t + 1),
          @"after a success, one block isn't enough again");
}

static void TestChoose(void) {
    ApolloWebJSONRouteHealthReset();
    NSInteger dot = ApolloWebJSONRouteWwwDotJSON, old = ApolloWebJSONRouteOld;
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", kInfo, 0, 0) == dot, @"healthy: first route");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", kInfo, 1u << dot, 0) == old, @"resend: next route");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", kInfo, (1u << dot) | (1u << old), 0) == -1, @"all tried: none");
    BlockTimes(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 3, 0);
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", kInfo, 0, 1) == old, @"skips a cooling route");
    CHECK(ApolloWebJSONRouteChoose(@"bob", @"GET", kInfo, 0, 1) == dot, @"another account isn't affected");
    BlockTimes(@"alice", kInfo, ApolloWebJSONRouteOld, 3, 0);
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", kInfo, 0, 1) == dot, @"all cooling, first send: first route anyway");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", kInfo, 1u << dot, 1) == -1, @"all cooling, resend: none");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", kInfo, 0, kHour + 1) == dot, @"cooldown over: first route again");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"POST", @"/api/comment", 0, 1) == ApolloWebJSONRouteWww, @"writes: www");
    ApolloWebJSONRouteHealthReset();
    BlockTimes(@"alice", @"/api/comment", ApolloWebJSONRouteWww, 5, 0);
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"POST", @"/api/comment", 0, 1) == ApolloWebJSONRouteWww,
          @"a single-route path is only counted, never skipped");
}

static void TestPathPatterns(void) {
    NSDictionary<NSString *, NSString *> *cases = @{
        @"/r/apple/comments/abc123/some_slug.json": @"/r/*/comments/*/*",
        @"/r/apple/hot.json": @"/r/*/hot",
        @"/r/user/new": @"/r/*/new",
        @"/user/Someone/comments.json": @"/user/*/comments",
        @"/user/someone/m/multi": @"/user/*/m/*",
        @"/comments/abc123.json": @"/comments/*",
        @"/api/info/.json": @"/api/info",
        @"/api/morechildren.json": @"/api/morechildren",
        @"/message/inbox.json": @"/message/inbox",
        @"/r/apple+ios/hot.json": @"/r/+/hot",
        @"/r/a+b+c/search": @"/r/+/search",
        @"/r/All/best.json": @"/r/*/best",
        @"/r/a+/hot": @"/r/*/hot",
        @"/": @"/",
    };
    for (NSString *path in cases) {
        NSString *pattern = ApolloWebJSONRoutePathPattern(path);
        CHECK([pattern isEqualToString:cases[path]], @"%@ -> %@ (got %@)", path, cases[path], pattern);
    }
}

static void TestDescription(void) {
    ApolloWebJSONRouteHealthReset();
    CHECK([ApolloWebJSONRouteHealthDescription(0) containsString:@"no keyless responses"], @"empty");
    BlockTimes(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 3, 0);
    ApolloWebJSONRouteHealthNoteSuccess(@"alice", @"GET", kInfo, ApolloWebJSONRouteOld, 0);
    NSString *text = ApolloWebJSONRouteHealthDescription(60);
    CHECK([text containsString:@"alice|/api/info|www-dotjson: 0 ok, 3 blocked, cooling down 59 min more"], @"%@", text);
    CHECK([text containsString:@"alice|/api/info|old: 1 ok, 0 blocked"], @"%@", text);
}

static NSDictionary *ParseJSON(NSString *json, NSArray<NSString *> **rejections) {
    return ApolloWebJSONRouteTableParse([json dataUsingEncoding:NSUTF8StringEncoding], rejections);
}

static void TestTableParseValid(void) {
    NSArray<NSString *> *rejections = nil;
    NSDictionary *table = ParseJSON(@"{\"version\":1,\"endpoints\":{"
        "\"GET /api/info\":{\"routes\":[\"old\",\"www-dotjson\"]},"
        "\"POST /api/morechildren\":{\"routes\":[\"www-dotjson\"]},"
        "\"GET /api/morechildren\":{\"routes\":[\"www\",\"old\"]},"
        "\"GET /api/foo\":{\"routes\":[\"www-dotjson\",\"www\"]},"
        "\"GET /api/bar\":{\"routes\":[\"old\"]},"
        "\"GET /api/baz\":{\"routes\":[\"www-dotjson\",\"old\",\"api\",\"oauth\",\"www\"]},"
        "\"GET /r/*/search\":{\"routes\":[\"old\",\"oauth\"]},"
        "\"GET /search\":{\"routes\":[\"oauth\"]},"
        "\"GET /subreddits/search\":{\"routes\":[\"old\"]},"
        "\"GET /r/all/*\":{\"routes\":[\"old\",{\"host\":\"oauth\",\"auth\":\"bearer\"}]},"
        "\"GET /r/+/*\":{\"routes\":[\"oauth+bearer\",\"www\"]},"
        "\"GET /r/apple/*\":{\"routes\":[{\"host\":\"old\",\"path\":\"dotjson\",\"auth\":\"cookie\"}]},"
        "\"GET /user/*/submitted\":{\"routes\":[{\"host\":\"www\"}]},"
        "\"GET /comments/*\":{\"routes\":[\"old\",\"www\"]},"
        "\"GET /message/inbox\":{\"routes\":[\"oauth\"]},"
        "\"GET /api/v1/me\":{\"routes\":[\"www-r-all\",{\"host\":\"oauth\",\"path\":\"r-all\",\"auth\":\"bearer\"}]},"
        "\"GET /api/*\":{\"routes\":[\"www-dotjson\"]},"
        "\"GET /r/all\":{\"routes\":[\"oauth\"]},"
        "\"GET /\":{\"routes\":[\"old\"]}}}", &rejections);
    CHECK(table.count == 19, @"19 entries (got %@, rejected %@)", table, rejections);
    CHECK(rejections.count == 0, @"nothing rejected: %@", rejections);
    CHECK([table[@"GET /api/info"] isEqualToArray:(@[ @(ApolloWebJSONRouteOld), @(ApolloWebJSONRouteWwwDotJSON) ])], @"reorder");
    CHECK([table[@"POST /api/morechildren"] isEqualToArray:@[ @(ApolloWebJSONRouteWwwDotJSON) ]], @"subset");
    CHECK([table[@"GET /api/foo"] isEqualToArray:(@[ @(ApolloWebJSONRouteWwwDotJSON), @(ApolloWebJSONRouteWww) ])], @"added GET");
    CHECK([table[@"GET /api/bar"] isEqualToArray:@[ @(ApolloWebJSONRouteOld) ]], @"added GET may use old");
    CHECK([table[@"GET /api/baz"] isEqualToArray:(@[ @(ApolloWebJSONRouteWwwDotJSON), @(ApolloWebJSONRouteOld),
                                                     @(ApolloWebJSONRouteApi), @(ApolloWebJSONRouteOAuth), @(ApolloWebJSONRouteWww) ])],
          @"all five routes, api and oauth included");
    CHECK([table[@"GET /r/*/search"] isEqualToArray:(@[ @(ApolloWebJSONRouteOld), @(ApolloWebJSONRouteOAuth) ])], @"search reorder");
    CHECK([table[@"GET /search"] isEqualToArray:@[ @(ApolloWebJSONRouteOAuth) ]], @"search subset");
    CHECK([table[@"GET /subreddits/search"] isEqualToArray:@[ @(ApolloWebJSONRouteOld) ]], @"subreddit discovery");
    CHECK([table[@"GET /r/all/*"] isEqualToArray:(@[ @(ApolloWebJSONRouteOld), @(ApolloWebJSONRouteOAuthBearer) ])], @"route parts");
    CHECK([table[@"GET /r/+/*"] isEqualToArray:(@[ @(ApolloWebJSONRouteOAuthBearer), @(ApolloWebJSONRouteWww) ])], @"bearer by name");
    CHECK([table[@"GET /r/apple/*"] isEqualToArray:@[ @(ApolloWebJSONRouteOldDotJSON) ]], @"every part given");
    CHECK([table[@"GET /user/*/submitted"] isEqualToArray:@[ @(ApolloWebJSONRouteWww) ]], @"host alone is www");
    CHECK([table[@"GET /api/v1/me"] isEqualToArray:(@[ @(ApolloWebJSONRouteWwwRAll), @(ApolloWebJSONRouteOAuthRAllBearer) ])],
          @"r-all on an /api/ path, by name and by parts");
    CHECK(table[@"GET /comments/*"] && table[@"GET /message/inbox"] && table[@"GET /api/*"] && table[@"GET /r/all"] && table[@"GET /"],
          @"any GET read pattern");

    CHECK([ParseJSON(@"{\"version\":1,\"endpoints\":{}}", NULL) count] == 0, @"empty endpoints: no overrides");
    CHECK(ParseJSON(@"{\"version\":1}", NULL) != nil, @"missing endpoints: no overrides, not rejected");
}

static void TestTableParseRejectsEntries(void) {
    NSDictionary<NSString *, NSString *> *bad = @{
        @"\"POST /api/foo\":{\"routes\":[\"www-dotjson\"]}": @"POST for an added endpoint",
        @"\"POST /api/comment\":{\"routes\":[\"www-dotjson\"]}": @"a write",
        @"\"DELETE /api/info\":{\"routes\":[\"www\"]}": @"another method",
        @"\"POST /api/info\":{\"routes\":[\"www-dotjson\"]}": @"a method the built-in endpoint doesn't have",
        @"\"GET /api/info.json\":{\"routes\":[\"www\"]}": @"a .json path",
        @"\"GET /api/foo?x=1\":{\"routes\":[\"www\"]}": @"a query",
        @"\"GET  /api/foo\":{\"routes\":[\"www\"]}": @"a malformed key",
        @"\"GET /api/info\":{\"routes\":[\"https://evil.example\"]}": @"a URL as a route",
        @"\"GET /api/info\":{\"routes\":[\"bearer\"]}": @"an unknown route",
        @"\"POST /search\":{\"routes\":[\"old\"]}": @"a search write",
        @"\"GET /search.json\":{\"routes\":[\"old\"]}": @"a .json search path",
        @"\"GET /r/*/search/\":{\"routes\":[\"old\"]}": @"a trailing slash",
        @"\"GET /api/info\":{\"routes\":[]}": @"no routes",
        @"\"GET /api/info\":{\"routes\":[\"www\",\"www\"]}": @"a duplicate",
        @"\"GET /api/info\":{\"routes\":[\"www\",\"old\",\"www-dotjson\",\"api\",\"oauth\",\"www\"]}": @"more than 5",
        @"\"GET /api/info\":{\"routes\":\"old\"}": @"routes not a list",
        @"\"GET /api/info\":[\"old\"]": @"entry not an object",
        @"\"GET /*\":{\"routes\":[\"old\"]}": @"every top-level path",
        @"\"GET /*/*\":{\"routes\":[\"old\"]}": @"every two-segment path",
        @"\"GET /+\":{\"routes\":[\"old\"]}": @"only wildcards",
        @"\"GET /r/*\":{\"routes\":[\"old\"]}": @"every subreddit's front page",
        @"\"GET /r/*/*\":{\"routes\":[\"old\"]}": @"every subreddit feed",
        @"\"GET /r/*/*/*\":{\"routes\":[\"old\"]}": @"every subreddit, deeper",
        @"\"GET /R/all/*\":{\"routes\":[\"old\"]}": @"an uppercase literal",
        @"\"GET /r/all/best.json\":{\"routes\":[\"old\"]}": @"a .json listing",
        @"\"GET /r//best\":{\"routes\":[\"old\"]}": @"an empty segment",
        @"\"GET /r/a*/best\":{\"routes\":[\"old\"]}": @"a partial wildcard",
        @"\"GET /r/a+b/best\":{\"routes\":[\"old\"]}": @"a literal joined list",
        @"\"GET r/all/*\":{\"routes\":[\"old\"]}": @"no leading slash",
        @"\"POST /r/all/*\":{\"routes\":[\"old\"]}": @"a POST that isn't built in",
        @"\"GET /api/info\":{\"routes\":[{\"host\":\"www\",\"auth\":\"bearer\"}]}": @"bearer off oauth",
        @"\"GET /api/info\":{\"routes\":[\"www+bearer\"]}": @"bearer off oauth, by name",
        @"\"GET /api/info\":{\"routes\":[{\"host\":\"evil.example\"}]}": @"an unknown host",
        @"\"GET /api/info\":{\"routes\":[{\"host\":\"www.reddit.com\"}]}": @"a host name instead of a part",
        @"\"GET /api/info\":{\"routes\":[{\"path\":\"dotjson\"}]}": @"no host",
        @"\"GET /api/info\":{\"routes\":[{\"host\":\"oauth\",\"path\":\"/x\"}]}": @"an unknown path form",
        @"\"GET /api/info\":{\"routes\":[{\"host\":\"oauth\",\"auth\":\"token_v2\"}]}": @"an unknown auth",
        @"\"GET /api/info\":{\"routes\":[{\"host\":\"oauth\",\"url\":\"https://evil.example\"}]}": @"an unknown part",
        @"\"GET /api/info\":{\"routes\":[{\"host\":\"oauth\",\"auth\":1}]}": @"a part that isn't a string",
        @"\"GET /api/info\":{\"routes\":[4]}": @"a route number",
        @"\"GET /r/all/*\":{\"routes\":[{\"host\":\"www\",\"path\":\"r-all\"}]}": @"r-all off /api/",
        @"\"GET /api/info\":{\"routes\":[\"oauth+bearer\",{\"host\":\"oauth\",\"auth\":\"bearer\"}]}": @"a duplicate, by name and parts",
    };
    for (NSString *entry in bad) {
        NSArray<NSString *> *rejections = nil;
        NSDictionary *table = ParseJSON([NSString stringWithFormat:@"{\"version\":1,\"endpoints\":{%@,"
                                         "\"GET /api/ok\":{\"routes\":[\"www-dotjson\"]}}}", entry], &rejections);
        CHECK(table.count == 1 && table[@"GET /api/ok"], @"%@: only that entry left out (got %@)", bad[entry], table);
        CHECK(rejections.count == 1, @"%@: one rejection logged (got %@)", bad[entry], rejections);
    }
}

static void TestTableParseRejectsFile(void) {
    NSArray<NSString *> *rejections = nil;
    CHECK(ParseJSON(@"not json", &rejections) == nil && rejections.count == 1, @"not JSON");
    CHECK(ParseJSON(@"[1]", NULL) == nil, @"not an object");
    CHECK(ParseJSON(@"{\"version\":2,\"endpoints\":{}}", NULL) == nil, @"unknown version");
    CHECK(ParseJSON(@"{\"endpoints\":{}}", NULL) == nil, @"no version");
    CHECK(ParseJSON(@"{\"version\":\"1\",\"endpoints\":{}}", NULL) == nil, @"version as a string");
    CHECK(ParseJSON(@"{\"version\":1,\"endpoints\":[]}", NULL) == nil, @"endpoints not an object");
    CHECK(ApolloWebJSONRouteTableParse(nil, NULL) == nil, @"nil");
    CHECK(ApolloWebJSONRouteTableParse([NSData data], NULL) == nil, @"empty");
    NSMutableString *many = [NSMutableString stringWithString:@"{\"version\":1,\"endpoints\":{"];
    for (int i = 0; i < 33; i++) [many appendFormat:@"%@\"GET /api/e%d\":{\"routes\":[\"www\"]}", i ? @"," : @"", i];
    [many appendString:@"}}"];
    CHECK(ParseJSON(many, NULL) == nil, @"more than 32 endpoints");
    NSMutableString *big = [NSMutableString stringWithString:@"{\"version\":1,\"pad\":\""];
    while (big.length < 17 * 1024) [big appendString:@"xxxxxxxxxxxxxxxx"];
    [big appendString:@"\",\"endpoints\":{}}"];
    CHECK(ParseJSON(big, NULL) == nil, @"larger than 16 KB");
}

static void TestRemoteTableMerge(void) {
    ApolloWebJSONRouteHealthReset();
    NSArray *builtIn = @[ @(ApolloWebJSONRouteWwwDotJSON), @(ApolloWebJSONRouteOld) ];
    ApolloWebJSONRouteSetRemoteTable(ParseJSON(@"{\"version\":1,\"endpoints\":{"
        "\"GET /api/info\":{\"routes\":[\"old\"]},"
        "\"GET /api/foo\":{\"routes\":[\"www-dotjson\",\"www\"]},"
        "\"GET /r/*/search\":{\"routes\":[\"old\"]}}}", NULL));
    CHECK([ApolloWebJSONRoutesForRequest(@"GET", @"api/info.json") isEqualToArray:@[ @(ApolloWebJSONRouteOld) ]], @"override applies");
    CHECK([ApolloWebJSONRoutesForRequest(@"GET", @"/r/iOS/search.json?q=x") isEqualToArray:@[ @(ApolloWebJSONRouteOld) ]],
          @"search override applies to every community");
    CHECK(ApolloWebJSONRouteIsFromRemoteTable(@"GET", @"r/apple/search"), @"search override is remote");
    CHECK([ApolloWebJSONRoutesForRequest(@"GET", @"/r/ios+apple/search.json") isEqualToArray:(@[ @(ApolloWebJSONRouteOAuth), @(ApolloWebJSONRouteOld) ])],
          @"multireddit search has its own key, /r/+/search");
    CHECK([ApolloWebJSONRoutesForRequest(@"GET", @"/search.json") isEqualToArray:(@[ @(ApolloWebJSONRouteOAuth), @(ApolloWebJSONRouteOld) ])],
          @"other search endpoints keep built-in");
    CHECK([ApolloWebJSONRouteRemoteTableDescription() containsString:@"GET /r/*/search: old (built-in: oauth, old)"],
          @"%@", ApolloWebJSONRouteRemoteTableDescription());
    CHECK(!ApolloWebJSONRouteRequestMayRetry(@"GET", @"/api/info.json"), @"one route: nothing to retry on");
    CHECK([ApolloWebJSONRoutesForRequest(@"POST", @"/api/morechildren.json") isEqualToArray:builtIn], @"other entries keep built-in");
    CHECK(ApolloWebJSONRouteRequestMayRetry(@"GET", @"/api/foo"), @"added GET with two routes may retry");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteWwwDotJSON, @"/api/foo.json") isEqualToString:@"/api/foo/.json"], @"added path");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"/api/foo", 0, 0) == ApolloWebJSONRouteWwwDotJSON, @"choose uses it");
    CHECK([ApolloWebJSONRouteRemoteTableDescription() containsString:@"GET /api/info: old (built-in: www-dotjson, old)"],
          @"%@", ApolloWebJSONRouteRemoteTableDescription());
    CHECK([ApolloWebJSONRouteRemoteTableDescription() containsString:@"GET /api/foo: www-dotjson, www (built-in: www)"],
          @"%@", ApolloWebJSONRouteRemoteTableDescription());
    ApolloWebJSONRouteSetRemoteTable(nil);
    CHECK([ApolloWebJSONRoutesForRequest(@"GET", @"/api/info") isEqualToArray:builtIn], @"cleared: built-in again");
    CHECK([ApolloWebJSONRoutesForRequest(@"GET", @"/api/foo") isEqualToArray:@[ @(ApolloWebJSONRouteWww) ]], @"cleared: www");
    CHECK([ApolloWebJSONRouteRemoteTableDescription() containsString:@"built-in"], @"empty description");
}

static void TestHealthSnapshot(void) {
    ApolloWebJSONRouteHealthReset();
    BlockTimes(@"Alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 3, 100);
    ApolloWebJSONRouteHealthNoteSuccess(@"alice", @"GET", kInfo, ApolloWebJSONRouteOld, 120);
    ApolloWebJSONRouteHealthNoteSuccess(@"bob", @"GET", @"/r/apple/hot.json", ApolloWebJSONRouteWww, 130);

    NSArray<NSDictionary *> *alice = ApolloWebJSONRouteHealthSnapshot(@"ALICE", 160);
    CHECK(alice.count == 2, @"alice's two routes (got %@)", alice);
    NSDictionary *dot = alice.firstObject, *old = alice.lastObject;
    CHECK([dot[@"route"] integerValue] == ApolloWebJSONRouteWwwDotJSON, @"sorted by route");
    CHECK([dot[@"pattern"] isEqualToString:@"/api/info"] && [dot[@"blocked"] integerValue] == 3 && [dot[@"ok"] integerValue] == 0,
          @"dotjson counts %@", dot);
    CHECK([dot[@"lastBlockedAt"] doubleValue] == 100 && [dot[@"cooldownRemaining"] doubleValue] == 3600 - 60, @"times %@", dot);
    CHECK([old[@"ok"] integerValue] == 1 && [old[@"lastOkAt"] doubleValue] == 120 && [old[@"cooldownRemaining"] doubleValue] == 0,
          @"old %@", old);
    CHECK(ApolloWebJSONRouteHealthSnapshot(nil, 160).count == 3, @"every account when nil");
    CHECK([[ApolloWebJSONRouteHealthSnapshot(@"bob", 160).firstObject objectForKey:@"pattern"] isEqualToString:@"/r/*/hot"], @"bob");
    CHECK(ApolloWebJSONRouteHealthSnapshot(@"carol", 160).count == 0, @"unknown account");
}

static void TestFallbackEndpoints(void) {
    ApolloWebJSONRouteSetRemoteTable(nil);
    NSArray *builtIn = @[ @"GET /api/info", @"GET /api/morechildren", @"GET /r/*/search", @"GET /r/+/search", @"GET /r/all",
                          @"GET /r/all/*", @"GET /search", @"GET /subreddits/search", @"POST /api/morechildren" ];
    CHECK([ApolloWebJSONRouteFallbackEndpoints() isEqualToArray:builtIn], @"built-in (got %@)", ApolloWebJSONRouteFallbackEndpoints());
    CHECK(!ApolloWebJSONRouteIsFromRemoteTable(@"GET", @"/api/info.json"), @"not remote");

    ApolloWebJSONRouteSetRemoteTable(ParseJSON(@"{\"version\":1,\"endpoints\":{"
        "\"GET /api/info\":{\"routes\":[\"old\"]},"
        "\"GET /api/foo\":{\"routes\":[\"www-dotjson\",\"old\"]},"
        "\"GET /api/bar\":{\"routes\":[\"www-dotjson\"]}}}", NULL));
    NSArray *expected = @[ @"GET /api/foo", @"GET /api/morechildren", @"GET /r/*/search", @"GET /r/+/search", @"GET /r/all",
                           @"GET /r/all/*", @"GET /search", @"GET /subreddits/search", @"POST /api/morechildren" ];
    CHECK([ApolloWebJSONRouteFallbackEndpoints() isEqualToArray:expected],
          @"one route has no fallback; added ones with two do (got %@)", ApolloWebJSONRouteFallbackEndpoints());
    CHECK(ApolloWebJSONRouteIsFromRemoteTable(@"GET", @"/api/info.json"), @"remote");
    CHECK(ApolloWebJSONRouteIsFromRemoteTable(@"GET", @"api/foo"), @"remote added");
    ApolloWebJSONRouteSetRemoteTable(nil);
}


static NSArray *R(ApolloWebJSONRoute a) { return @[ @(a) ]; }
static NSArray *R2(ApolloWebJSONRoute a, ApolloWebJSONRoute b) { return @[ @(a), @(b) ]; }
static NSArray *RAll(void) { return @[ @(ApolloWebJSONRouteOAuth), @(ApolloWebJSONRouteApi), @(ApolloWebJSONRouteOld) ]; }

// Apollo's front page: GET https://www.reddit.com/r/All/best.json?api_type=json&limit=12&raw_json=1
// (capital A, and the best sort).
static NSString *const kApolloAllURL = @"https://www.reddit.com/r/All/best.json?api_type=json&limit=12&raw_json=1";

static void TestRAllBuiltIn(void) {
    ApolloWebJSONRouteSetRemoteTable(nil);
    ApolloWebJSONRouteHealthReset();
    NSArray *all = RAll();
    NSURL *url = [NSURL URLWithString:kApolloAllURL];
    for (NSString *path in @[ url.path, [url.path stringByAppendingFormat:@"?%@", url.query], @"r/All/best.json" ]) {
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", path) isEqualToArray:all], @"Apollo's /r/all request %@: oauth, api, then old", path);
        CHECK(ApolloWebJSONRouteRequestMayRetry(@"GET", path), @"%@ may retry", path);
        CHECK([ApolloWebJSONRouteHealthGroup(@"GET", path) isEqualToString:@"/r/all/*"], @"%@ groups under /r/all/*", path);
    }
    for (NSString *sort in @[ @"best", @"hot", @"new", @"top", @"rising", @"controversial", @"gilded" ]) {
        NSString *path = [NSString stringWithFormat:@"/r/all/%@.json?t=week&after=t3_x", sort];
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", path) isEqualToArray:all], @"/r/all/%@", sort);
    }
    for (NSString *path in @[ @"/r/all", @"/r/All.json", @"/r/all/", @"/R/ALL/.json?limit=25" ]) {
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", path) isEqualToArray:all], @"bare %@", path);
        CHECK([ApolloWebJSONRouteHealthGroup(@"GET", path) isEqualToString:@"/r/all"], @"bare %@ has its own group", path);
    }
    for (NSString *path in @[ @"/r/popular/best.json", @"/r/popular", @"/r/apple/best.json", @"/r/apple+ios/best.json",
                              @"/r/allx/best", @"/r/all/comments/abc/slug", @"/best.json" ]) {
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", path) isEqualToArray:R(ApolloWebJSONRouteWww)], @"%@ stays on www", path);
    }
    for (NSString *method in @[ @"POST", @"PUT", @"DELETE" ]) {
        CHECK([ApolloWebJSONRoutesForRequest(method, url.path) isEqualToArray:R(ApolloWebJSONRouteWww)], @"%@ /r/all stays on www", method);
        CHECK(!ApolloWebJSONRouteRequestMayRetry(method, url.path), @"%@ /r/all is never resent", method);
    }
    CHECK(!ApolloWebJSONRequestIsSearchRead(@"GET", url.path), @"/r/all isn't search");
    // /r/all/search matches both /r/all/* and /r/*/search; the literal "all"
    // comes first, so /r/all/* wins. Both list the same routes.
    CHECK([ApolloWebJSONRouteHealthGroup(@"GET", @"/r/all/search.json") isEqualToString:@"/r/all/*"], @"left to right");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", url.path, 0, 0) == ApolloWebJSONRouteOAuth, @"first: oauth");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", url.path, 1u << ApolloWebJSONRouteOAuth, 0) == ApolloWebJSONRouteApi,
          @"resend after oauth's block page: api");
}

static void TestPatternGrammar(void) {
    ApolloWebJSONRouteHealthReset();
    ApolloWebJSONRouteSetRemoteTable(ParseJSON(@"{\"version\":1,\"endpoints\":{"
        "\"GET /r/all/best\":{\"routes\":[\"www-dotjson\",\"old\"]},"
        "\"GET /r/apple/*\":{\"routes\":[\"old\"]},"
        "\"GET /r/+/*\":{\"routes\":[\"oauth\"]},"
        "\"GET /user/*/submitted\":{\"routes\":[\"old\",\"www\"]},"
        "\"GET /comments/*\":{\"routes\":[\"old\",\"www\"]},"
        "\"GET /message/inbox\":{\"routes\":[\"old\"]},"
        "\"GET /api/v1/me\":{\"routes\":[\"www-r-all\",\"www\"]}}}", NULL));
    NSArray *www = R(ApolloWebJSONRouteWww), *old = R(ApolloWebJSONRouteOld);
    NSDictionary<NSString *, NSArray *> *cases = @{
        kApolloAllURL: R2(ApolloWebJSONRouteWwwDotJSON, ApolloWebJSONRouteOld),   // a literal beats built-in /r/all/*
        @"/r/all/top.json": RAll(),                                               // built-in /r/all/*
        @"/r/all-askreddit/best.json": R2(ApolloWebJSONRouteWwwDotJSON, ApolloWebJSONRouteOld),   // filter form is r/all
        @"/r/all": RAll(),                                                        // built-in /r/all
        @"/r/apple/hot.json": old,
        @"/r/Apple/new": old,
        @"/r/apple/search.json": old,             // /r/apple/* beats /r/*/search: "apple" is a literal
        @"/r/apple+ios/hot.json": R(ApolloWebJSONRouteOAuth),    // "+" is a joined list, not /r/apple/*
        @"/r/apple+ios+mac/top": R(ApolloWebJSONRouteOAuth),
        @"/r/apple+ios/search": R2(ApolloWebJSONRouteOAuth, ApolloWebJSONRouteOld),   // /r/+/search beats /r/+/*
        @"/r/a+/hot": www,                        // not a list of two names
        @"/r/+b/hot": www,
        @"/r/a++b/hot": www,
        @"/r/ios/hot": www,
        @"/r/popular/best": www,
        @"/user/Bob/submitted.json": R2(ApolloWebJSONRouteOld, ApolloWebJSONRouteWww),
        @"/user/bob/comments": www,
        @"/user/bob/submitted/extra": www,        // segment count must match
        @"/comments/abc123.json": R2(ApolloWebJSONRouteOld, ApolloWebJSONRouteWww),
        @"/comments/abc123/slug": www,
        @"/message/inbox.json?mark=true": old,
        @"/message/unread": www,
        @"api/v1/me.json": R2(ApolloWebJSONRouteWwwRAll, ApolloWebJSONRouteWww),
    };
    for (NSString *path in cases) {
        NSString *p = [path hasPrefix:@"https:"] ? [NSURL URLWithString:path].path : path;
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", p) isEqualToArray:cases[path]], @"GET %@ -> %@ (got %@)", p, cases[path],
              ApolloWebJSONRoutesForRequest(@"GET", p));
    }
    NSDictionary<NSString *, NSString *> *groups = @{
        @"/r/All/best.json": @"/r/all/best",
        @"/r/all/hot": @"/r/all/*",
        @"/r/apple/hot": @"/r/apple/*",
        @"/r/apple+ios/hot": @"/r/+/*",
        @"/r/ios/hot": @"/r/*/hot",               // no entry: the path pattern
        @"/r/ios+mac/new": @"/r/+/*",
        @"/user/bob/comments": @"/user/*/comments",
        @"/user/Bob/submitted": @"/user/*/submitted",
    };
    for (NSString *path in groups) {
        CHECK([ApolloWebJSONRouteHealthGroup(@"GET", path) isEqualToString:groups[path]], @"group of %@: %@ (got %@)", path, groups[path],
              ApolloWebJSONRouteHealthGroup(@"GET", path));
    }
    CHECK([ApolloWebJSONRoutesForRequest(@"POST", @"/r/apple/hot") isEqualToArray:www], @"entries are per method");
    CHECK(ApolloWebJSONRouteIsFromRemoteTable(@"GET", @"/r/apple+ios/hot"), @"remote");
    CHECK(!ApolloWebJSONRouteIsFromRemoteTable(@"GET", @"/r/all/hot"), @"built-in");
    CHECK([ApolloWebJSONRouteRemoteTableDescription() containsString:@"GET /r/all/best: www-dotjson, old (built-in: oauth, api, old)"],
          @"%@", ApolloWebJSONRouteRemoteTableDescription());
    CHECK([ApolloWebJSONRouteRemoteTableDescription() containsString:@"GET /r/apple/*: old (built-in: www)"],
          @"%@", ApolloWebJSONRouteRemoteTableDescription());
    // A fallback key resolves to its own entry when used as a path.
    for (NSString *key in ApolloWebJSONRouteFallbackEndpoints()) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@" "];
        CHECK([ApolloWebJSONRouteHealthGroup(parts[0], parts[1]) isEqualToString:parts[1]], @"%@ resolves to itself", key);
    }
    ApolloWebJSONRouteSetRemoteTable(nil);
}

static void TestMatchedEntryHealth(void) {
    ApolloWebJSONRouteHealthReset();
    // The case path grouping got wrong: /r/all/best and /r/apple/best both
    // grouped as /r/*/best, so www working for one subreddit cleared the
    // cooldown /r/all had earned.
    ApolloWebJSONRouteSetRemoteTable(ParseJSON(@"{\"version\":1,\"endpoints\":{"
        "\"GET /r/all/*\":{\"routes\":[\"www\",\"old\"]}}}", NULL));
    NSString *all = [NSURL URLWithString:kApolloAllURL].path;
    BlockTimes(@"alice", all, ApolloWebJSONRouteWww, 3, 0);
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", @"/r/all/hot", ApolloWebJSONRouteWww, 1) > 0, @"/r/all/* cooling");
    ApolloWebJSONRouteHealthNoteSuccess(@"alice", @"GET", @"/r/apple/best.json", ApolloWebJSONRouteWww, 2);
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", @"/r/all/hot", ApolloWebJSONRouteWww, 3) > 0,
          @"a www success on /r/apple/best doesn't clear /r/all/*'s cooldown");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"/r/All/new.json", 0, 3) == ApolloWebJSONRouteOld, @"/r/all keeps using old");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", @"/r/all", ApolloWebJSONRouteWww, 3) == 0, @"bare /r/all is its own entry");
    NSArray<NSDictionary *> *rows = ApolloWebJSONRouteHealthSnapshot(@"alice", 3);
    NSMutableSet *patterns = [NSMutableSet set];
    for (NSDictionary *row in rows) [patterns addObject:row[@"pattern"]];
    CHECK([patterns isEqualToSet:([NSSet setWithArray:@[ @"/r/all/*", @"/r/*/best" ]])], @"groups %@", patterns);
    ApolloWebJSONRouteHealthNoteSuccess(@"alice", @"GET", @"/r/all/rising", ApolloWebJSONRouteWww, 4);
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"GET", all, ApolloWebJSONRouteWww, 4) == 0, @"a success in the group clears it");
    // An r-all route's sent path counts under the path asked for.
    CHECK([ApolloWebJSONRouteRequestedPath(ApolloWebJSONRouteWwwRAll, @"/r/all/api/info.json") isEqualToString:@"/api/info.json"], @"r-all");
    CHECK([ApolloWebJSONRouteHealthGroup(@"GET", ApolloWebJSONRouteRequestedPath(ApolloWebJSONRouteWwwRAll, @"/r/all/api/info.json"))
           isEqualToString:@"/api/info"], @"r-all groups with /api/info");
    CHECK([ApolloWebJSONRouteRequestedPath(ApolloWebJSONRouteOld, @"/r/all/hot") isEqualToString:@"/r/all/hot"], @"other routes unchanged");
    ApolloWebJSONRouteSetRemoteTable(nil);
    ApolloWebJSONRouteHealthReset();
}

static void TestRouteParts(void) {
    NSArray<NSString *> *names = @[ @"www", @"www-dotjson", @"old", @"api", @"oauth", @"oauth+bearer", @"www-r-all", @"old-dotjson",
                                    @"old-r-all", @"api-dotjson", @"api-r-all", @"oauth-dotjson", @"oauth-r-all",
                                    @"oauth-dotjson+bearer", @"oauth-r-all+bearer" ];
    CHECK(names.count == ApolloWebJSONRouteLast + 1, @"every route named");
    for (NSInteger r = ApolloWebJSONRouteWww; r <= ApolloWebJSONRouteLast; r++) {
        CHECK([ApolloWebJSONRouteName((ApolloWebJSONRoute)r) isEqualToString:names[r]], @"route %ld is %@ (got %@)", (long)r, names[r],
              ApolloWebJSONRouteName((ApolloWebJSONRoute)r));
        NSDictionary *table = ParseJSON([NSString stringWithFormat:@"{\"version\":1,\"endpoints\":{\"GET /api/x\":{\"routes\":[\"%@\"]}}}",
                                         names[r]], NULL);
        CHECK([table[@"GET /api/x"] isEqualToArray:@[ @(r) ]], @"%@ parses back", names[r]);
        BOOL bearer = [names[r] hasSuffix:@"+bearer"];
        CHECK((ApolloWebJSONRouteGetAuth((ApolloWebJSONRoute)r) == ApolloWebJSONRouteAuthBearer) == bearer, @"%@ auth", names[r]);
        CHECK(!bearer || [ApolloWebJSONRouteHost((ApolloWebJSONRoute)r) isEqualToString:@"oauth.reddit.com"], @"%@: bearer only on oauth", names[r]);
    }
    CHECK([ApolloWebJSONRouteHost(ApolloWebJSONRouteOldRAll) isEqualToString:@"old.reddit.com"], @"old r-all host");
    CHECK([ApolloWebJSONRouteHost(ApolloWebJSONRouteOAuthBearer) isEqualToString:@"oauth.reddit.com"], @"bearer host");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteWwwRAll, @"/api/info.json") isEqualToString:@"/r/all/api/info.json"], @"r-all path");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteWwwRAll, @"api/info.json") isEqualToString:@"/r/all/api/info.json"], @"r-all relative");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteOldDotJSON, @"/api/info.json") isEqualToString:@"/api/info/.json"], @"old dotjson");
    CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteOAuthBearer, @"/r/all/best.json") isEqualToString:@"/r/all/best.json"], @"bearer same path");
    CHECK(ApolloWebJSONRouteGetPathForm(ApolloWebJSONRouteOAuthDotJSONBearer) == ApolloWebJSONRoutePathDotJSON, @"parts");
}

static void TestBearerRoutes(void) {
    ApolloWebJSONRouteHealthReset();
    ApolloWebJSONRouteSetRemoteTable(nil);
    ApolloWebJSONRouteSetBearerReadyHandler(nil);
    CHECK(!ApolloWebJSONRouteTableUsesBearerAuth(), @"no bearer routes by default");
    ApolloWebJSONRouteSetRemoteTable(ParseJSON(@"{\"version\":1,\"endpoints\":{"
        "\"GET /r/all/*\":{\"routes\":[\"oauth+bearer\",\"old\"]},"
        "\"GET /message/inbox\":{\"routes\":[\"oauth+bearer\"]}}}", NULL));
    CHECK(ApolloWebJSONRouteTableUsesBearerAuth(), @"the file adds one");
    NSString *all = [NSURL URLWithString:kApolloAllURL].path;
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", all, 0, 0) == ApolloWebJSONRouteOld, @"no handler: bearer route skipped");
    __block NSMutableArray<NSString *> *asked = [NSMutableArray array];
    __block BOOL ready = NO;
    ApolloWebJSONRouteSetBearerReadyHandler(^BOOL(NSString *account) { [asked addObject:account]; return ready; });
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", all, 0, 0) == ApolloWebJSONRouteOld, @"no bearer yet: next route");
    CHECK([asked containsObject:@"alice"], @"the handler is asked for the request's account (so it can mint)");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"/message/inbox", 0, 0) == -1, @"only a bearer route and no bearer: none");
    ready = YES;
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", all, 0, 0) == ApolloWebJSONRouteOAuthBearer, @"bearer ready: bearer route");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", all, 1u << ApolloWebJSONRouteOAuthBearer, 0) == ApolloWebJSONRouteOld, @"resend");
    BlockTimes(@"alice", all, ApolloWebJSONRouteOAuthBearer, 3, 0);
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", all, 0, 1) == ApolloWebJSONRouteOld, @"bearer route cooling");
    [asked removeAllObjects];
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"/r/popular/best", 0, 0) == ApolloWebJSONRouteWww && asked.count == 0,
          @"requests without a bearer route never ask");
    ApolloWebJSONRouteSetRemoteTable(nil);
    CHECK(!ApolloWebJSONRouteTableUsesBearerAuth(), @"cleared");
    ApolloWebJSONRouteSetBearerReadyHandler(nil);
    ApolloWebJSONRouteHealthReset();
}

static void TestRepositoryFile(const char *repoRoot) {
    NSString *path = [@(repoRoot) stringByAppendingPathComponent:@"keyless-routes.json"];
    NSArray<NSString *> *rejections = nil;
    NSDictionary *table = ApolloWebJSONRouteTableParse([NSData dataWithContentsOfFile:path], &rejections);
    CHECK(table != nil && rejections.count == 0, @"keyless-routes.json parses cleanly (rejected %@)", rejections);
}

static void TestAllListings(void) {
    ApolloWebJSONRouteSetRemoteTable(nil);
    NSArray *allRoutes = RAll();
    // Every sort and filter form, written the ways RedditKit and the rewrite do.
    // Exclude Subscriptions sends r/all-<sub>-<sub>; www blocks r/all+<sub> too.
    for (NSString *path in @[ @"r/All/best.json", @"/r/all", @"/r/all.json", @"/r/all/", @"/r/All/hot.json?after=t3_abc&count=25",
                              @"/r/ALL/top.json?t=week", @"/r/all/new", @"/r/all/rising.json", @"/r/all/controversial.json?t=day",
                              @"/r/all-askreddit/hot.json", @"/r/all-askreddit-pics/best", @"/r/All-AskReddit/best.json",
                              @"/r/all+pics/hot.json", @"/r/all-askreddit", @"/r/all/about.json", @"/r/all/gilded.json" ]) {
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", path) isEqualToArray:allRoutes], @"GET %@: oauth, api, then old", path);
        CHECK(ApolloWebJSONRouteRequestMayRetry(@"GET", path), @"GET %@ may retry", path);
        CHECK([ApolloWebJSONRouteHealthGroup(@"GET", path) hasPrefix:@"/r/all"], @"%@ groups under r/all (got %@)", path,
              ApolloWebJSONRouteHealthGroup(@"GET", path));
        CHECK([ApolloWebJSONRoutePath(ApolloWebJSONRouteApi, path) isEqualToString:path], @"api keeps %@", path);
    }
    CHECK([ApolloWebJSONRoutesForRequest(@"get", @"/r/all/hot.json") isEqualToArray:allRoutes], @"method is case-insensitive");
    CHECK([ApolloWebJSONRouteHealthGroup(@"GET", @"/r/all-askreddit/best.json") isEqualToString:@"/r/all/*"], @"filter form, sorted");
    CHECK([ApolloWebJSONRouteHealthGroup(@"GET", @"/r/all-askreddit") isEqualToString:@"/r/all"], @"filter form, bare");

    // Other subreddits, r/popular (its Exclude Subscriptions filters on device,
    // and Reddit reads r/popular-<sub> as a subreddit name), and paths under
    // r/all with more segments.
    NSArray *www = R(ApolloWebJSONRouteWww);
    for (NSString *path in @[ @"/r/allergies/hot.json", @"/r/AllThingsTerran/best.json", @"/r/pics+all/hot.json",
                              @"/r/popular/best.json", @"/r/popular-pics/best.json", @"/r/allx-foo/hot.json",
                              @"/r/all/comments/abc123.json", @"/r/all/hot/extra", @"/user/all/submitted.json", @"/all/hot.json" ]) {
        CHECK([ApolloWebJSONRoutesForRequest(@"GET", path) isEqualToArray:www], @"GET %@ stays on www", path);
        CHECK(![ApolloWebJSONRouteHealthGroup(@"GET", path) hasPrefix:@"/r/all"], @"%@ isn't r/all", path);
    }
    // Search under r/all goes by r/all's entry, which also starts with oauth.
    CHECK([ApolloWebJSONRoutesForRequest(@"GET", @"/r/all/search.json") isEqualToArray:allRoutes], @"r/all search");
    for (NSString *method in @[ @"POST", @"PUT", @"DELETE" ]) {
        CHECK([ApolloWebJSONRoutesForRequest(method, @"/r/all/hot.json") isEqualToArray:www], @"%@ stays on www", method);
        CHECK(!ApolloWebJSONRouteRequestMayRetry(method, @"/r/all/hot.json"), @"%@ is never resent", method);
    }

    // The sorts and filter forms share their health: three block pages on any
    // of them send all of them past oauth for the hour.
    ApolloWebJSONRouteHealthReset();
    NSInteger oauth = ApolloWebJSONRouteOAuth, api = ApolloWebJSONRouteApi, old = ApolloWebJSONRouteOld;
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"r/All/best.json", 0, 0) == oauth, @"healthy: oauth");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"r/All/best.json", 1u << oauth, 0) == api, @"resend: api");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"r/All/best.json", (1u << oauth) | (1u << api), 0) == old, @"then old");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"r/All/best.json", (1u << oauth) | (1u << api) | (1u << old), 0) == -1,
          @"all tried");
    ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", @"/r/all/hot.json", ApolloWebJSONRouteOAuth, 0);
    ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", @"/r/All/new.json", ApolloWebJSONRouteOAuth, 0);
    CHECK(ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"GET", @"/r/all-askreddit/top.json", ApolloWebJSONRouteOAuth, 0),
          @"3rd block");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"r/All/best.json", 0, 1) == api, @"another sort skips oauth too");
    CHECK(ApolloWebJSONRouteChoose(@"bob", @"GET", @"r/All/best.json", 0, 1) == oauth, @"per account");
    CHECK(ApolloWebJSONRouteChoose(@"alice", @"GET", @"/r/popular/best.json", 0, 1) == ApolloWebJSONRouteWww, @"r/popular");
    ApolloWebJSONRouteHealthReset();

    // keyless-routes.json can reorder r/all, but not split off its filter form.
    NSArray<NSString *> *rejections = nil;
    NSDictionary *table = ParseJSON(@"{\"version\":1,\"endpoints\":{\"GET /r/all\":{\"routes\":[\"old\",\"oauth\"]},"
        "\"GET /r/all-askreddit/*\":{\"routes\":[\"old\"]},\"GET /r/all+pics/*\":{\"routes\":[\"old\"]}}}", &rejections);
    CHECK([table[@"GET /r/all"] isEqualToArray:R2(ApolloWebJSONRouteOld, ApolloWebJSONRouteOAuth)] && table.count == 1 &&
          rejections.count == 2, @"GET /r/all is a key, its filter forms aren't (got %@, rejected %@)", table, rejections);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TestTableParseValid();
        TestTableParseRejectsEntries();
        TestTableParseRejectsFile();
        TestRemoteTableMerge();
        TestHealthSnapshot();
        TestFallbackEndpoints();
        if (argc > 1) TestRepositoryFile(argv[1]);
        TestTableEndpoints();
        TestSearchEndpoints();
        TestEverythingElseStaysOnWww();
        TestRouteTransforms();
        TestBlockPage();
        TestSignInGate();
        TestCooldownStartsAfterThreeBlocks();
        TestCooldownDoublesAndClears();
        TestChoose();
        TestPathPatterns();
        TestAllListings();
        TestDescription();
        TestRAllBuiltIn();
        TestPatternGrammar();
        TestMatchedEntryHealth();
        TestRouteParts();
        TestBearerRoutes();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("web json routes tests passed\n");
    return 0;
}
