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
    // api.reddit.com, path unchanged. Not in the built-in table: it refused
    // both built-in endpoints for the cookie as of 2026-10-24, and is here so
    // keyless-routes.json can use it again without a release.
    ApolloWebJSONRouteApi,
    ApolloWebJSONRouteLast = ApolloWebJSONRouteApi,
};

// "www", "www-dotjson", "old" or "api", for logs.
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

#pragma mark - Remote route table (keyless-routes.json)

// Maintainers can change the order of routes without a release through
// keyless-routes.json in the repository (docs/keyless-routes.md). The file can
// only pick among the routes above, never name a host or URL:
// - an endpoint gets any order or subset of www, www-dotjson, old and api: a
//   built-in one (above) for one of its own methods, another only as a GET on
//   /api/<name>, so feeds and threads can't be moved to another route;
// - writes can't be added, and nothing the file says makes a write retry.
// Which route an endpoint uses, Old Reddit included, is left to review of the
// file's pull requests.
// Anything else is rejected entry by entry; an unreadable file or an unknown
// "version" is rejected whole. Returns the validated overrides, keyed
// "<METHOD> <endpoint>" ("GET /api/info"), or nil when the whole file is
// rejected. `rejections`, when given, gets one line per thing left out.
NSDictionary<NSString *, NSArray<NSNumber *> *> *_Nullable ApolloWebJSONRouteTableParse(
    NSData *_Nullable data, NSArray<NSString *> *_Nullable *_Nullable rejections);

// The overrides ApolloWebJSONRoutesForRequest uses ahead of the built-in table
// (from ApolloWebJSONRouteTableParse), or nil for the built-in table alone.
void ApolloWebJSONRouteSetRemoteTable(NSDictionary<NSString *, NSArray<NSNumber *> *> *_Nullable overrides);

// One line per override in effect with the built-in order it replaces, for logs.
NSString *ApolloWebJSONRouteRemoteTableDescription(void);

#pragma mark - Route health

// Per account, path and route, in memory for the launch: Old Reddit access
// differs per account, and a stale cooldown shouldn't outlive a relaunch. Fed
// with every cookie response (ApolloWebJSONNoteResponse), for every keyless
// path; only paths with more than one route are affected by a cooldown, the
// rest are only counted. `now` is a timeIntervalSinceReferenceDate, so tests can
// drive the clock. Any thread.

// Three block pages in a row put a route on cooldown for an hour. Another block
// page when that ends (no success since) puts it back for twice as long, up to
// eight hours. A success clears it. Returns YES when this call started a
// cooldown, for logging.
BOOL ApolloWebJSONRouteHealthNoteBlockPage(NSString *account, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now);
void ApolloWebJSONRouteHealthNoteSuccess(NSString *account, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now);

// Seconds left on a route's cooldown for `account` and `path`, or 0.
NSTimeInterval ApolloWebJSONRouteCooldownRemaining(NSString *account, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now);

// The route to send a request by: the first in ApolloWebJSONRoutesForRequest's
// order that isn't in `triedMask` (a bit per ApolloWebJSONRoute) and isn't on
// cooldown. When every route is on cooldown and none has been tried, the first
// route anyway, so a route that recovers is noticed. -1 when a resend has no
// route left.
NSInteger ApolloWebJSONRouteChoose(NSString *account, NSString *method, NSString *path, NSUInteger triedMask, NSTimeInterval now);

// `path` with its variable segments (subreddit, user, post and comment ids)
// replaced by "*", so the counts group by endpoint: "/r/*/comments/*".
NSString *ApolloWebJSONRoutePathPattern(NSString *path);

// One line per tracked account, path and route, for logs.
NSString *ApolloWebJSONRouteHealthDescription(NSTimeInterval now);

// The health of `account`'s routes (all accounts when nil), one dictionary per
// path pattern and route, sorted by pattern then route: "account", "pattern"
// (NSString), "route" (NSNumber, an ApolloWebJSONRoute), "ok" and "blocked"
// (NSNumber counts), "lastOkAt" and "lastBlockedAt" (NSNumber reference-date
// seconds, 0 when never), "cooldownRemaining" (NSNumber seconds).
NSArray<NSDictionary<NSString *, id> *> *ApolloWebJSONRouteHealthSnapshot(NSString *_Nullable account, NSTimeInterval now);

// The endpoints that have more than one route, built-in and added by the
// remote table, as "<METHOD> <endpoint>" keys ("GET /api/info"), sorted.
NSArray<NSString *> *ApolloWebJSONRouteFallbackEndpoints(void);

// YES when the remote table sets the routes for `method` and `path`.
BOOL ApolloWebJSONRouteIsFromRemoteTable(NSString *method, NSString *path);

// Forgets everything (tests and the sim debug bridge).
void ApolloWebJSONRouteHealthReset(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
