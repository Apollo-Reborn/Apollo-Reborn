#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// The ways an API-Key-Free (cookie) request can reach Reddit. www.reddit.com
// refuses some reads at their usual path with its 403 HTML block page, so an
// endpoint can list other routes to try in order. Every route is a reddit.com
// host that already gets the session cookie; nothing here can point a request
// anywhere else. Foundation-only: tests/run_web_json_routes_tests.sh.
typedef NS_ENUM(NSInteger, ApolloWebJSONRoute) {
    ApolloWebJSONRouteWww = 0,      // www.reddit.com, path unchanged
    ApolloWebJSONRouteWwwDotJSON,   // www.reddit.com, /api/<endpoint>/.json
    ApolloWebJSONRouteOld,          // old.reddit.com, path unchanged
};

// "www", "www-dotjson" or "old", for logs.
NSString *ApolloWebJSONRouteName(ApolloWebJSONRoute route);
NSString *ApolloWebJSONRouteHost(ApolloWebJSONRoute route);

// The routes to try for a request, in order; always at least one. Endpoints
// not in the table get @[www]. `path` may be RedditKit's relative form
// ("api/info.json") or a URL path, with or without .json, a trailing slash or
// a query.
NSArray<NSNumber *> *ApolloWebJSONRoutesForRequest(NSString *method, NSString *path);

// YES when a block page on one route may be answered by sending the same
// request on the next one: reads only (GETs, and POSTs that only read, like
// /api/morechildren). Writes are never resent.
BOOL ApolloWebJSONRouteRequestMayRetry(NSString *method, NSString *path);

// `path` as `route` sends it.
NSString *ApolloWebJSONRoutePath(ApolloWebJSONRoute route, NSString *path);

// Reddit's 403 HTML block page, as opposed to a 403 with a JSON error body.
BOOL ApolloWebJSONRouteResponseIsBlockPage(NSHTTPURLResponse *_Nullable response);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
