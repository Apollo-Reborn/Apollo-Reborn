#import <Foundation/Foundation.h>
#import "ApolloWebJSONRoutes.h"

static int sFailures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

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

static NSString *const kInfo = @"/api/info.json";
static NSTimeInterval const kHour = 3600.0;

static void BlockTimes(NSString *account, NSString *path, ApolloWebJSONRoute route, int times, NSTimeInterval at) {
    for (int i = 0; i < times; i++) ApolloWebJSONRouteHealthNoteBlockPage(account, path, route, at);
}

static void TestCooldownStartsAfterThreeBlocks(void) {
    ApolloWebJSONRouteHealthReset();
    CHECK(!ApolloWebJSONRouteHealthNoteBlockPage(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 0), @"1st block");
    CHECK(!ApolloWebJSONRouteHealthNoteBlockPage(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 1), @"2nd block");
    CHECK(ApolloWebJSONRoutePathPattern(kInfo).length > 0, @"pattern");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 2) == 0, @"no cooldown after two");
    CHECK(ApolloWebJSONRouteHealthNoteBlockPage(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 2), @"3rd block starts a cooldown");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 2) == kHour, @"an hour");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"/api/info/.json", ApolloWebJSONRouteWwwDotJSON, 2) == kHour,
          @"the path the route sent groups with the one asked for");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"ALICE", kInfo, ApolloWebJSONRouteWwwDotJSON, 2) == kHour, @"account is case-insensitive");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"bob", kInfo, ApolloWebJSONRouteWwwDotJSON, 2) == 0, @"per account");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", kInfo, ApolloWebJSONRouteOld, 2) == 0, @"per route");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", @"/api/morechildren", ApolloWebJSONRouteWwwDotJSON, 2) == 0, @"per path");
    CHECK(!ApolloWebJSONRouteHealthNoteBlockPage(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 3),
          @"a block during the cooldown (sent before it began) doesn't extend it");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 3) == kHour - 1, @"unchanged");
}

static void TestCooldownDoublesAndClears(void) {
    ApolloWebJSONRouteHealthReset();
    BlockTimes(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, 3, 0);
    NSTimeInterval t = kHour;
    CHECK(ApolloWebJSONRouteHealthNoteBlockPage(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, t),
          @"the first block after a cooldown starts the next one");
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, t) == 2 * kHour, @"doubled");
    for (int i = 0; i < 5; i++) {
        t += ApolloWebJSONRouteCooldownRemaining(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, t);
        ApolloWebJSONRouteHealthNoteBlockPage(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, t);
    }
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, t) == 8 * kHour, @"capped at 8h");
    ApolloWebJSONRouteHealthNoteSuccess(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, t);
    CHECK(ApolloWebJSONRouteCooldownRemaining(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, t) == 0, @"a success clears it");
    CHECK(!ApolloWebJSONRouteHealthNoteBlockPage(@"alice", kInfo, ApolloWebJSONRouteWwwDotJSON, t + 1),
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
    ApolloWebJSONRouteHealthNoteSuccess(@"alice", kInfo, ApolloWebJSONRouteOld, 0);
    NSString *text = ApolloWebJSONRouteHealthDescription(60);
    CHECK([text containsString:@"alice|/api/info|www-dotjson: 0 ok, 3 blocked, cooling down 59 min more"], @"%@", text);
    CHECK([text containsString:@"alice|/api/info|old: 1 ok, 0 blocked"], @"%@", text);
}

int main(void) {
    @autoreleasepool {
        TestTableEndpoints();
        TestEverythingElseStaysOnWww();
        TestRouteTransforms();
        TestBlockPage();
        TestCooldownStartsAfterThreeBlocks();
        TestCooldownDoublesAndClears();
        TestChoose();
        TestPathPatterns();
        TestDescription();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("web json routes tests passed\n");
    return 0;
}
