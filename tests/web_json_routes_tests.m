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

int main(void) {
    @autoreleasepool {
        TestTableEndpoints();
        TestEverythingElseStaysOnWww();
        TestRouteTransforms();
        TestBlockPage();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("web json routes tests passed\n");
    return 0;
}
