#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// The ways an API-Key-Free (cookie) request can reach Reddit. www.reddit.com
// refuses some reads at their usual path with its 403 HTML block page, so an
// endpoint can list other routes to try in order. A route is a host, a path
// form and an auth method, each from a list compiled in here; every host is a
// reddit.com host, and nothing here can point a request anywhere else.
// Foundation-only: tests/run_web_json_routes_tests.sh.
//
// The values are fixed: they ride in URL fragment markers and in bitmasks of
// tried routes (a bit per route), so a new route gets the next number and none
// is ever renumbered. The first five are the routes before route parts.
typedef NS_ENUM(NSInteger, ApolloWebJSONRoute) {
    ApolloWebJSONRouteWww = 0,          // www.reddit.com, path unchanged
    ApolloWebJSONRouteWwwDotJSON,       // www.reddit.com, /api/<endpoint>/.json
    ApolloWebJSONRouteOld,              // old.reddit.com, path unchanged
    // api.reddit.com, path unchanged. r/all's listings go here after oauth.
    // Not in the /api/ entries: it refused both of them for the cookie as of
    // 2026-10-24, and keyless-routes.json can use it for them again without a
    // release.
    ApolloWebJSONRouteApi,
    // oauth.reddit.com, path unchanged, with the cookie and no bearer. www
    // refuses post search for the cookie, and oauth refuses it for the desktop
    // web client's token (token_v2), but oauth serves it signed in to the
    // cookie alone.
    ApolloWebJSONRouteOAuth,
    // oauth.reddit.com with a bearer minted for Reddit's mobile client and no
    // cookie (ApolloWebJSONRouteAuthBearer). Not in the built-in table.
    ApolloWebJSONRouteOAuthBearer,
    // www.reddit.com/r/all/api/<endpoint>: for /api/ endpoints only.
    ApolloWebJSONRouteWwwRAll,
    ApolloWebJSONRouteOldDotJSON,
    ApolloWebJSONRouteOldRAll,
    ApolloWebJSONRouteApiDotJSON,
    ApolloWebJSONRouteApiRAll,
    ApolloWebJSONRouteOAuthDotJSON,
    ApolloWebJSONRouteOAuthRAll,
    ApolloWebJSONRouteOAuthDotJSONBearer,
    ApolloWebJSONRouteOAuthRAllBearer,
    ApolloWebJSONRouteLast = ApolloWebJSONRouteOAuthRAllBearer,
};

// How a route changes the path: not at all, /api/<endpoint>/.json ("dotjson"),
// or with /r/all in front ("r-all", /api/ endpoints only).
typedef NS_ENUM(NSInteger, ApolloWebJSONRoutePathForm) {
    ApolloWebJSONRoutePathSame = 0,
    ApolloWebJSONRoutePathDotJSON,
    ApolloWebJSONRoutePathRAll,
};

// The session cookie, or a bearer minted for Reddit's mobile client from the
// cookie (never the token_v2 cookie, which is the desktop web client's token).
// Bearer auth is only offered on oauth.reddit.com, the one host that reads it.
typedef NS_ENUM(NSInteger, ApolloWebJSONRouteAuth) {
    ApolloWebJSONRouteAuthCookie = 0,
    ApolloWebJSONRouteAuthBearer,
};

// The route's name, for logs and keyless-routes.json: the host ("www", "old",
// "api", "oauth"), then "-dotjson" or "-r-all" for a path form, then
// "+bearer" for bearer auth ("www-dotjson", "oauth+bearer").
NSString *ApolloWebJSONRouteName(ApolloWebJSONRoute route);
NSString *ApolloWebJSONRouteHost(ApolloWebJSONRoute route);
ApolloWebJSONRoutePathForm ApolloWebJSONRouteGetPathForm(ApolloWebJSONRoute route);
ApolloWebJSONRouteAuth ApolloWebJSONRouteGetAuth(ApolloWebJSONRoute route);

// GET search reads: global (/search), subreddit discovery
// (/subreddits/search), and community (/r/<sub>/search), which also covers
// Apollo's multireddit search (/r/<a>+<b>+<c>/search). Their built-in routes
// are oauth, then old.
BOOL ApolloWebJSONRequestIsSearchRead(NSString *method, NSString *path);

// The routes to try for a request, in order; always at least one. Requests no
// entry matches get @[www]. `path` may be RedditKit's relative form
// ("api/info.json") or a URL path, with or without .json, a trailing slash or
// a query.
//
// Entries are keyed by a method and a path pattern. Each segment of a pattern
// is a literal, "*" for one name, or "+" for two or more names joined with "+"
// (a multireddit: "/r/+/hot" matches /r/apple+ios/hot, never /r/apple/hot). A
// pattern only matches paths with as many segments. When several match, the
// most specific wins: comparing segments left to right, the first where one
// has a literal and the other a wildcard decides, so /r/all/* beats
// /r/*/search for /r/all/search. A keyless-routes.json entry beats a built-in
// one with the same pattern.
NSArray<NSNumber *> *ApolloWebJSONRoutesForRequest(NSString *method, NSString *path);

// The pattern of the entry a request matches ("/r/all/*" for /r/All/best.json),
// or ApolloWebJSONRoutePathPattern for a request no entry matches. Route health
// is kept per group, so a route blocked for /r/all/best isn't cleared by a
// success on /r/apple/best.
NSString *ApolloWebJSONRouteHealthGroup(NSString *method, NSString *path);

// YES when a block page on one route may be answered by sending the same
// request on the next one: reads only (GETs, and POSTs that only read, like
// /api/morechildren). Writes are never resent.
BOOL ApolloWebJSONRouteRequestMayRetry(NSString *method, NSString *path);

// `path` as `route` sends it.
NSString *ApolloWebJSONRoutePath(ApolloWebJSONRoute route, NSString *path);

// The path asked for, from the path `route` sent: "/r/all/api/info.json" by an
// r-all route is "/api/info.json". Other path forms already group with the
// path asked for, so they're returned unchanged.
NSString *ApolloWebJSONRouteRequestedPath(ApolloWebJSONRoute route, NSString *sentPath);

// Reddit's 403 HTML block page, as opposed to a 403 with a JSON error body.
BOOL ApolloWebJSONRouteResponseIsBlockPage(NSHTTPURLResponse *_Nullable response);

// A read Reddit redirected to its HTML sign-in page. Old Reddit's gate does
// this for anyone signed out and for accounts without recent Old Reddit use:
// old.reddit.com/api/info.json goes to old.reddit.com/login/?reason=lor2&dest=…,
// a 200 text/html page (checked 2026-10-27). `response` is the final one, after
// redirects.
BOOL ApolloWebJSONRouteResponseIsSignInGate(NSHTTPURLResponse *_Nullable response);

// The route refused the read: the block page or the sign-in gate. Either one
// counts toward its cooldown and lets the read try the next route.
BOOL ApolloWebJSONRouteResponseIsRefusal(NSHTTPURLResponse *_Nullable response);

// Whether `account` has a bearer ready for ApolloWebJSONRouteAuthBearer routes,
// asked by ApolloWebJSONRouteChoose. ApolloWebJSON.m sets it; without one,
// bearer routes are always skipped. The handler must not block (it may start a
// mint in the background for a later request).
void ApolloWebJSONRouteSetBearerReadyHandler(BOOL (^_Nullable handler)(NSString *account));

// YES while an entry in effect (built-in or from keyless-routes.json) lists a
// route with bearer auth, so a bearer is worth minting ahead of time.
BOOL ApolloWebJSONRouteTableUsesBearerAuth(void);

#pragma mark - Remote route table (keyless-routes.json)

// Maintainers can change routes without a release through keyless-routes.json
// in the repository (docs/keyless-routes.md). The file can only pick among the
// route parts above, never name a host or URL:
// - an entry is "GET <pattern>" for any read (the grammar above). A POST is
//   only accepted for a built-in read-only POST (/api/morechildren);
// - patterns that match every subreddit or every path at the top level
//   ("/*", "/r/*", "/r/*/*") are refused, so one entry can't move all browsing;
// - writes can't be added, and nothing the file says makes a write retry.
// Which route an endpoint uses, Old Reddit included, is left to review of the
// file's pull requests.
// Anything else is rejected entry by entry; an unreadable file or an unknown
// "version" is rejected whole. Returns the validated overrides, keyed
// "<METHOD> <pattern>" ("GET /r/all/*"), or nil when the whole file is
// rejected. `rejections`, when given, gets one line per thing left out.
NSDictionary<NSString *, NSArray<NSNumber *> *> *_Nullable ApolloWebJSONRouteTableParse(
    NSData *_Nullable data, NSArray<NSString *> *_Nullable *_Nullable rejections);

// The overrides ApolloWebJSONRoutesForRequest uses ahead of the built-in table
// (from ApolloWebJSONRouteTableParse), or nil for the built-in table alone.
void ApolloWebJSONRouteSetRemoteTable(NSDictionary<NSString *, NSArray<NSNumber *> *> *_Nullable overrides);

// One line per override in effect with the built-in order it replaces, for logs.
NSString *ApolloWebJSONRouteRemoteTableDescription(void);

#pragma mark - Route health

// Per account, group (ApolloWebJSONRouteHealthGroup) and route, in memory for
// the launch: Old Reddit access differs per account, and a stale cooldown
// shouldn't outlive a relaunch. Fed with every keyless response
// (ApolloWebJSONNoteResponse), for every keyless path; only requests with more
// than one route are affected by a cooldown, the rest are only counted. `now`
// is a timeIntervalSinceReferenceDate, so tests can drive the clock. Any
// thread.

// Three block pages in a row put a route on cooldown for an hour. Another block
// page when that ends (no success since) puts it back for twice as long, up to
// eight hours. A success clears it. Returns YES when this call started a
// cooldown, for logging.
BOOL ApolloWebJSONRouteHealthNoteBlockPage(NSString *account, NSString *method, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now);
void ApolloWebJSONRouteHealthNoteSuccess(NSString *account, NSString *method, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now);

// Seconds left on a route's cooldown for `account` and the request's group, or 0.
NSTimeInterval ApolloWebJSONRouteCooldownRemaining(NSString *account, NSString *method, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now);

// The route to send a request by: the first in ApolloWebJSONRoutesForRequest's
// order that isn't in `triedMask` (a bit per ApolloWebJSONRoute), isn't on
// cooldown and, for bearer auth, has a bearer ready. When every such route is
// on cooldown and none has been tried, the first of them anyway, so a route
// that recovers is noticed. -1 when there's no route left to send by.
NSInteger ApolloWebJSONRouteChoose(NSString *account, NSString *method, NSString *path, NSUInteger triedMask, NSTimeInterval now);

// `path` with its variable segments (subreddit, user, post and comment ids)
// replaced by "*", or "+" for names joined with "+", so the counts group by
// endpoint: "/r/*/comments/*", "/r/+/hot".
NSString *ApolloWebJSONRoutePathPattern(NSString *path);

// One line per tracked account, path and route, for logs.
NSString *ApolloWebJSONRouteHealthDescription(NSTimeInterval now);

// The health of `account`'s routes (all accounts when nil), one dictionary per
// group and route, sorted by group then route: "account", "pattern" (NSString,
// the group), "route" (NSNumber, an ApolloWebJSONRoute), "ok" and "blocked"
// (NSNumber counts), "lastOkAt" and "lastBlockedAt" (NSNumber reference-date
// seconds, 0 when never), "cooldownRemaining" (NSNumber seconds).
NSArray<NSDictionary<NSString *, id> *> *ApolloWebJSONRouteHealthSnapshot(NSString *_Nullable account, NSTimeInterval now);

// The entries that have more than one route, built-in and added by the remote
// table, as "<METHOD> <pattern>" keys ("GET /api/info"), sorted. A key's
// pattern works as a path: ApolloWebJSONRoutesForRequest and the health calls
// resolve it to that entry.
NSArray<NSString *> *ApolloWebJSONRouteFallbackEndpoints(void);

// YES when the remote table sets the routes for `method` and `path`.
BOOL ApolloWebJSONRouteIsFromRemoteTable(NSString *method, NSString *path);

// Forgets everything (tests and the sim debug bridge).
void ApolloWebJSONRouteHealthReset(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
