#import "ApolloWebJSONRoutes.h"

#pragma mark - Routes

// Every route, by its ApolloWebJSONRoute value. Bearer auth is only listed
// for oauth.reddit.com: www, old and api read the cookie and ignore a bearer.
typedef struct {
    const char *host;
    ApolloWebJSONRoutePathForm path;
    ApolloWebJSONRouteAuth auth;
} ApolloWebJSONRouteParts;

static const ApolloWebJSONRouteParts kApolloWebJSONRouteCatalog[] = {
    [ApolloWebJSONRouteWww]                 = { "www",   ApolloWebJSONRoutePathSame,    ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteWwwDotJSON]          = { "www",   ApolloWebJSONRoutePathDotJSON, ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteOld]                 = { "old",   ApolloWebJSONRoutePathSame,    ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteApi]                 = { "api",   ApolloWebJSONRoutePathSame,    ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteOAuth]               = { "oauth", ApolloWebJSONRoutePathSame,    ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteOAuthBearer]         = { "oauth", ApolloWebJSONRoutePathSame,    ApolloWebJSONRouteAuthBearer },
    [ApolloWebJSONRouteWwwRAll]             = { "www",   ApolloWebJSONRoutePathRAll,    ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteOldDotJSON]          = { "old",   ApolloWebJSONRoutePathDotJSON, ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteOldRAll]             = { "old",   ApolloWebJSONRoutePathRAll,    ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteApiDotJSON]          = { "api",   ApolloWebJSONRoutePathDotJSON, ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteApiRAll]             = { "api",   ApolloWebJSONRoutePathRAll,    ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteOAuthDotJSON]        = { "oauth", ApolloWebJSONRoutePathDotJSON, ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteOAuthRAll]           = { "oauth", ApolloWebJSONRoutePathRAll,    ApolloWebJSONRouteAuthCookie },
    [ApolloWebJSONRouteOAuthDotJSONBearer]  = { "oauth", ApolloWebJSONRoutePathDotJSON, ApolloWebJSONRouteAuthBearer },
    [ApolloWebJSONRouteOAuthRAllBearer]     = { "oauth", ApolloWebJSONRoutePathRAll,    ApolloWebJSONRouteAuthBearer },
};
_Static_assert(sizeof(kApolloWebJSONRouteCatalog) / sizeof(kApolloWebJSONRouteCatalog[0]) == ApolloWebJSONRouteLast + 1,
               "every route has its parts");

// The parts keyless-routes.json may name, in the order of their enums.
static NSArray<NSString *> *ApolloWebJSONRouteHostNames(void) { return @[ @"www", @"old", @"api", @"oauth" ]; }
static NSArray<NSString *> *ApolloWebJSONRoutePathFormNames(void) { return @[ @"same", @"dotjson", @"r-all" ]; }
static NSArray<NSString *> *ApolloWebJSONRouteAuthNames(void) { return @[ @"cookie", @"bearer" ]; }

static ApolloWebJSONRouteParts ApolloWebJSONRoutePartsFor(ApolloWebJSONRoute route) {
    if (route < ApolloWebJSONRouteWww || route > ApolloWebJSONRouteLast) route = ApolloWebJSONRouteWww;
    return kApolloWebJSONRouteCatalog[route];
}

NSString *ApolloWebJSONRouteName(ApolloWebJSONRoute route) {
    ApolloWebJSONRouteParts parts = ApolloWebJSONRoutePartsFor(route);
    NSMutableString *name = [NSMutableString stringWithUTF8String:parts.host];
    if (parts.path != ApolloWebJSONRoutePathSame) [name appendFormat:@"-%@", ApolloWebJSONRoutePathFormNames()[parts.path]];
    if (parts.auth == ApolloWebJSONRouteAuthBearer) [name appendString:@"+bearer"];
    return name;
}

NSString *ApolloWebJSONRouteHost(ApolloWebJSONRoute route) {
    return [NSString stringWithFormat:@"%s.reddit.com", ApolloWebJSONRoutePartsFor(route).host];
}

ApolloWebJSONRoutePathForm ApolloWebJSONRouteGetPathForm(ApolloWebJSONRoute route) {
    return ApolloWebJSONRoutePartsFor(route).path;
}

ApolloWebJSONRouteAuth ApolloWebJSONRouteGetAuth(ApolloWebJSONRoute route) {
    return ApolloWebJSONRoutePartsFor(route).auth;
}

// The route with these parts, or -1 when there's none (bearer auth off oauth).
static NSInteger ApolloWebJSONRouteWithParts(NSString *host, ApolloWebJSONRoutePathForm path, ApolloWebJSONRouteAuth auth) {
    for (NSInteger r = ApolloWebJSONRouteWww; r <= ApolloWebJSONRouteLast; r++) {
        ApolloWebJSONRouteParts parts = kApolloWebJSONRouteCatalog[r];
        if ([host isEqualToString:@(parts.host)] && parts.path == path && parts.auth == auth) return r;
    }
    return -1;
}

static NSInteger ApolloWebJSONRouteFromName(id name) {
    if (![name isKindOfClass:[NSString class]]) return -1;
    for (NSInteger r = ApolloWebJSONRouteWww; r <= ApolloWebJSONRouteLast; r++) {
        if ([ApolloWebJSONRouteName((ApolloWebJSONRoute)r) isEqualToString:name]) return r;
    }
    return -1;
}

// "/api/info" for "api/info.json", "/api/info/.json?id=…", "/API/info/" and so
// on: lowercased, one leading slash, no query, .json or trailing slashes.
static NSString *ApolloWebJSONRouteEndpointKey(NSString *path) {
    NSString *p = [path.lowercaseString componentsSeparatedByString:@"?"].firstObject ?: @"";
    while ([p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
    if ([p hasSuffix:@".json"]) p = [p substringToIndex:p.length - 5];
    while ([p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
    while ([p hasPrefix:@"/"]) p = [p substringFromIndex:1];
    return [@"/" stringByAppendingString:p];
}

// The segments of an endpoint key or pattern; none for "/".
static NSArray<NSString *> *ApolloWebJSONRouteSegments(NSString *key) {
    return key.length > 1 ? [[key substringFromIndex:1] componentsSeparatedByString:@"/"] : @[];
}

#pragma mark - Entries and matching

static BOOL ApolloWebJSONRouteSegmentIsWildcard(NSString *segment) {
    return [segment isEqualToString:@"*"] || [segment isEqualToString:@"+"];
}

// Two or more non-empty names joined with "+". A lone "+" counts too, so a
// pattern used as a path ("/r/+/search") matches its own entry.
static BOOL ApolloWebJSONRouteSegmentIsJoinedList(NSString *segment) {
    if ([segment isEqualToString:@"+"]) return YES;
    NSArray<NSString *> *names = [segment componentsSeparatedByString:@"+"];
    if (names.count < 2) return NO;
    for (NSString *name in names) if (name.length == 0) return NO;
    return YES;
}

static BOOL ApolloWebJSONRoutePatternMatches(NSArray<NSString *> *pattern, NSArray<NSString *> *segments) {
    if (pattern.count != segments.count) return NO;
    for (NSUInteger i = 0; i < pattern.count; i++) {
        NSString *want = pattern[i], *have = segments[i];
        if ([want isEqualToString:@"*"]) {
            if (have.length == 0 || [have containsString:@"+"]) return NO;
        } else if ([want isEqualToString:@"+"]) {
            if (!ApolloWebJSONRouteSegmentIsJoinedList(have)) return NO;
        } else if (![want isEqualToString:have]) {
            return NO;
        }
    }
    return YES;
}

// YES when `a` is more specific than `b` (same length, both matching one path):
// the first segment where one has a literal and the other a wildcard decides.
static BOOL ApolloWebJSONRoutePatternIsMoreSpecific(NSArray<NSString *> *a, NSArray<NSString *> *b) {
    for (NSUInteger i = 0; i < a.count && i < b.count; i++) {
        BOOL aLiteral = !ApolloWebJSONRouteSegmentIsWildcard(a[i]), bLiteral = !ApolloWebJSONRouteSegmentIsWildcard(b[i]);
        if (aLiteral != bLiteral) return aLiteral;
    }
    return NO;
}

// An entry: "method", "pattern", "segments", "routes" and "remote" (NSNumber).
static NSDictionary *ApolloWebJSONRouteMakeEntry(NSString *method, NSString *pattern, NSArray<NSNumber *> *routes, BOOL remote) {
    return @{ @"method": method, @"pattern": pattern, @"segments": ApolloWebJSONRouteSegments(pattern),
              @"routes": routes, @"remote": @(remote) };
}

// The search endpoints, as ApolloWebJSONRoutePathPattern names them. Apollo
// searches a multireddit as its subreddits joined with "+" under /r/, never
// by Reddit's /user/<name>/m/<multi>/search.
static NSArray<NSString *> *ApolloWebJSONRouteSearchEndpoints(void) {
    return @[ @"/search", @"/subreddits/search", @"/r/*/search", @"/r/+/search" ];
}

BOOL ApolloWebJSONRequestIsSearchRead(NSString *method, NSString *path) {
    if (![method isKindOfClass:[NSString class]] || ![path isKindOfClass:[NSString class]]) return NO;
    return [method.uppercaseString isEqualToString:@"GET"] &&
           [ApolloWebJSONRouteSearchEndpoints() containsObject:ApolloWebJSONRoutePathPattern(path)];
}

// Endpoints www.reddit.com refuses for the cookie at their usual path, with the
// routes that still served them (each checked live 2026-10-24 from the app with
// an API-Key-Free session; api.reddit.com and oauth.reddit.com with the web
// bearer 403 both):
// - GET /api/info: RDKClient's thingsByFullNames:completion:. The Inbox's
//   Notifications list waits on it for its replies' parents (completion at
//   0x10019dde8).
// - /api/morechildren: the "more replies" rows in a thread (issue #1456).
//   Apollo POSTs it, but it only reads.
// www-dotjson gets past www's block rather than being a documented route, and
// Reddit is limiting old.reddit.com to accounts with recent Old Reddit use, so
// either can stop working; old comes second.
// Search (ApolloWebJSONRequestIsSearchRead): www refuses post search for the
// cookie, and oauth.reddit.com refuses it for tokens from Reddit's desktop web
// client (cid 0R-WAMhuoo-MyQ), which is what the session's token_v2 cookie is.
// It accepts tokens minted for the mobile client. oauth.reddit.com and
// old.reddit.com both serve search signed in to the cookie with no token at
// all (checked 2026-10-27, one account), so search needs no bearer. oauth comes
// first for the same reason old comes second above.
// /r/all: www answers every path under /r/all with the block page, for the
// cookie and signed out alike (since 2026-10-27), while /r/popular, single
// subreddits (r/allergies too) and "+" lists still load there. Apollo's front
// page sends /r/All/best.json, and its filter forms match these entries too
// (ApolloWebJSONRouteMatchSegments). oauth, api and old all served /r/all
// listings signed in to the cookie (checked 2026-10-27 and 2026-10-28: the
// account's saved posts and votes came back), and api's carry the same image
// fields www's feeds have. oauth comes first for the same reason as in search.
static NSArray<NSDictionary *> *ApolloWebJSONRouteBuiltInTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *fallbacks = @[ @(ApolloWebJSONRouteWwwDotJSON), @(ApolloWebJSONRouteOld) ];
        NSArray *cookieOAuth = @[ @(ApolloWebJSONRouteOAuth), @(ApolloWebJSONRouteOld) ];
        NSArray *rAll = @[ @(ApolloWebJSONRouteOAuth), @(ApolloWebJSONRouteApi), @(ApolloWebJSONRouteOld) ];
        NSMutableArray<NSDictionary *> *rows = [@[
            ApolloWebJSONRouteMakeEntry(@"GET", @"/api/info", fallbacks, NO),
            ApolloWebJSONRouteMakeEntry(@"GET", @"/api/morechildren", fallbacks, NO),
            ApolloWebJSONRouteMakeEntry(@"POST", @"/api/morechildren", fallbacks, NO),
            ApolloWebJSONRouteMakeEntry(@"GET", @"/r/all", rAll, NO),
            ApolloWebJSONRouteMakeEntry(@"GET", @"/r/all/*", rAll, NO),
        ] mutableCopy];
        for (NSString *endpoint in ApolloWebJSONRouteSearchEndpoints()) {
            [rows addObject:ApolloWebJSONRouteMakeEntry(@"GET", endpoint, cookieOAuth, NO)];
        }
        table = [rows copy];
    });
    return table;
}

static NSObject *ApolloWebJSONRemoteTableLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Guarded by ApolloWebJSONRemoteTableLock: the overrides as parsed, and as
// entries.
static NSDictionary<NSString *, NSArray<NSNumber *> *> *sApolloWebJSONRemoteTable;
static NSArray<NSDictionary *> *sApolloWebJSONRemoteEntries;

static NSArray<NSDictionary *> *ApolloWebJSONRemoteEntries(void) {
    @synchronized (ApolloWebJSONRemoteTableLock()) {
        return sApolloWebJSONRemoteEntries ?: @[];
    }
}

// The segments a path is matched by. r/all's filter forms count as r/all, so
// the /r/all entries cover them: r/all-<sub>-<sub> is r/all without those
// subreddits (All Posts' Exclude Subscriptions builds it from the account's
// subscriptions, at 0x1005a46c0), and www blocks r/all+<sub> as it does r/all.
// Subreddit names can't contain "-", and r/all is the only feed Reddit filters
// this way: it answers r/popular-<sub> as a subreddit it can't find, and
// Popular's Exclude Subscriptions filters the loaded posts without a request.
static NSArray<NSString *> *ApolloWebJSONRouteMatchSegments(NSString *path) {
    NSArray<NSString *> *segments = ApolloWebJSONRouteSegments(ApolloWebJSONRouteEndpointKey(path));
    if (segments.count < 2 || ![segments[0] isEqualToString:@"r"]) return segments;
    if (![segments[1] hasPrefix:@"all-"] && ![segments[1] hasPrefix:@"all+"]) return segments;
    NSMutableArray<NSString *> *all = [segments mutableCopy];
    all[1] = @"all";
    return all;
}

// The entry `method` and `path` match: the most specific, a remote one ahead of
// a built-in one with the same pattern. nil when none does.
static NSDictionary *ApolloWebJSONRouteMatchIn(NSArray<NSArray<NSDictionary *> *> *tables, NSString *method, NSString *path) {
    if (![method isKindOfClass:[NSString class]] || ![path isKindOfClass:[NSString class]]) return nil;
    NSString *upper = method.uppercaseString;
    NSArray<NSString *> *segments = ApolloWebJSONRouteMatchSegments(path);
    NSDictionary *best = nil;
    for (NSArray<NSDictionary *> *table in tables) {
        for (NSDictionary *entry in table) {
            if (![entry[@"method"] isEqualToString:upper] || !ApolloWebJSONRoutePatternMatches(entry[@"segments"], segments)) continue;
            if (!best || ApolloWebJSONRoutePatternIsMoreSpecific(entry[@"segments"], best[@"segments"])) best = entry;
        }
    }
    return best;
}

static NSDictionary *ApolloWebJSONRouteMatch(NSString *method, NSString *path) {
    return ApolloWebJSONRouteMatchIn(@[ ApolloWebJSONRemoteEntries(), ApolloWebJSONRouteBuiltInTable() ], method, path);
}

static NSDictionary *ApolloWebJSONRouteBuiltInMatch(NSString *method, NSString *path) {
    return ApolloWebJSONRouteMatchIn(@[ ApolloWebJSONRouteBuiltInTable() ], method, path);
}

NSArray<NSNumber *> *ApolloWebJSONRoutesForRequest(NSString *method, NSString *path) {
    return ApolloWebJSONRouteMatch(method, path)[@"routes"] ?: @[ @(ApolloWebJSONRouteWww) ];
}

NSString *ApolloWebJSONRouteHealthGroup(NSString *method, NSString *path) {
    return ApolloWebJSONRouteMatch(method, path)[@"pattern"] ?: ApolloWebJSONRoutePathPattern(path);
}

// Every built-in entry is a read (see above), and the remote table can only add
// GETs (ApolloWebJSONRouteTableParse), so a request with more than one route
// may try them in turn. Anything else, writes included, has only www and is
// never resent.
BOOL ApolloWebJSONRouteRequestMayRetry(NSString *method, NSString *path) {
    return ApolloWebJSONRoutesForRequest(method, path).count > 1;
}

NSString *ApolloWebJSONRoutePath(ApolloWebJSONRoute route, NSString *path) {
    switch (ApolloWebJSONRouteGetPathForm(route)) {
        case ApolloWebJSONRoutePathDotJSON:
            return [ApolloWebJSONRouteEndpointKey(path) stringByAppendingString:@"/.json"];
        case ApolloWebJSONRoutePathRAll:
            return [@"/r/all" stringByAppendingString:[path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path]];
        case ApolloWebJSONRoutePathSame:
        default:
            return path;
    }
}

NSString *ApolloWebJSONRouteRequestedPath(ApolloWebJSONRoute route, NSString *sentPath) {
    if (ApolloWebJSONRouteGetPathForm(route) != ApolloWebJSONRoutePathRAll || ![sentPath hasPrefix:@"/r/all/"]) return sentPath;
    return [sentPath substringFromIndex:@"/r/all".length];
}

BOOL ApolloWebJSONRouteResponseIsBlockPage(NSHTTPURLResponse *response) {
    if (![response isKindOfClass:[NSHTTPURLResponse class]] || response.statusCode != 403) return NO;
    NSString *contentType = [[response valueForHTTPHeaderField:@"Content-Type"] lowercaseString] ?: @"";
    return [contentType containsString:@"text/html"];
}

// What the fallback to old (the table above) gets for an account Old Reddit
// won't serve. It counts as a refusal, like the block page.
BOOL ApolloWebJSONRouteResponseIsSignInGate(NSHTTPURLResponse *response) {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return NO;
    NSString *host = response.URL.host.lowercaseString ?: @"";
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return NO;
    // No read asks for /login itself, so ending up there means a redirect.
    NSString *path = response.URL.path.lowercaseString ?: @"";
    if (![path isEqualToString:@"/login"] && ![path hasPrefix:@"/login/"]) return NO;
    NSString *contentType = [[response valueForHTTPHeaderField:@"Content-Type"] lowercaseString] ?: @"";
    return [contentType containsString:@"text/html"];
}

BOOL ApolloWebJSONRouteResponseIsRefusal(NSHTTPURLResponse *response) {
    return ApolloWebJSONRouteResponseIsBlockPage(response) || ApolloWebJSONRouteResponseIsSignInGate(response);
}

static NSObject *ApolloWebJSONBearerHandlerLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Guarded by ApolloWebJSONBearerHandlerLock.
static BOOL (^sApolloWebJSONBearerReady)(NSString *account);

void ApolloWebJSONRouteSetBearerReadyHandler(BOOL (^handler)(NSString *account)) {
    @synchronized (ApolloWebJSONBearerHandlerLock()) {
        sApolloWebJSONBearerReady = [handler copy];
    }
}

static BOOL ApolloWebJSONRouteBearerReady(NSString *account) {
    BOOL (^handler)(NSString *);
    @synchronized (ApolloWebJSONBearerHandlerLock()) {
        handler = sApolloWebJSONBearerReady;
    }
    return handler && account.length > 0 && handler(account);
}

BOOL ApolloWebJSONRouteTableUsesBearerAuth(void) {
    for (NSArray<NSDictionary *> *table in @[ ApolloWebJSONRemoteEntries(), ApolloWebJSONRouteBuiltInTable() ]) {
        for (NSDictionary *entry in table) {
            for (NSNumber *route in entry[@"routes"]) {
                if (ApolloWebJSONRouteGetAuth((ApolloWebJSONRoute)route.integerValue) == ApolloWebJSONRouteAuthBearer) return YES;
            }
        }
    }
    return NO;
}

#pragma mark - Remote route table (keyless-routes.json)

static NSUInteger const kApolloWebJSONRouteTableMaxBytes = 16 * 1024;
static NSUInteger const kApolloWebJSONRouteTableMaxEndpoints = 32;
static NSUInteger const kApolloWebJSONRouteTableMaxRoutes = 5;

void ApolloWebJSONRouteSetRemoteTable(NSDictionary<NSString *, NSArray<NSNumber *> *> *overrides) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *key in overrides) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@" "];
        if (parts.count != 2) continue;
        [entries addObject:ApolloWebJSONRouteMakeEntry(parts[0], parts[1], overrides[key], YES)];
    }
    @synchronized (ApolloWebJSONRemoteTableLock()) {
        sApolloWebJSONRemoteTable = [overrides copy];
        sApolloWebJSONRemoteEntries = [entries copy];
    }
}

static NSString *ApolloWebJSONRouteNames(NSArray<NSNumber *> *routes) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:routes.count];
    for (NSNumber *route in routes) [names addObject:ApolloWebJSONRouteName((ApolloWebJSONRoute)route.integerValue)];
    return [names componentsJoinedByString:@", "];
}

// Why `path` can't be a key's pattern, or nil when it can: "/" then segments
// that are each a lowercase literal, "*" or "+", without .json, a query or a
// trailing slash, and narrower than every subreddit or every top-level path.
static NSString *ApolloWebJSONRoutePatternProblem(NSString *path) {
    static NSRegularExpression *literal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        literal = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9_-]+$" options:0 error:NULL];
    });
    if (![path hasPrefix:@"/"]) return @"path doesn't start with /";
    NSArray<NSString *> *segments = ApolloWebJSONRouteSegments(path);
    BOOL allWildcards = segments.count > 0, subredditWildcards = segments.count > 1 && [segments[0] isEqualToString:@"r"];
    for (NSUInteger i = 0; i < segments.count; i++) {
        NSString *segment = segments[i];
        BOOL wildcard = ApolloWebJSONRouteSegmentIsWildcard(segment);
        if (!wildcard && ![literal firstMatchInString:segment options:0 range:NSMakeRange(0, segment.length)]) {
            return [NSString stringWithFormat:@"segment \"%@\" isn't a lowercase name, * or +", segment];
        }
        if (!wildcard) allWildcards = NO;
        if (i > 0 && ![segment isEqualToString:@"*"]) subredditWildcards = NO;
    }
    if (allWildcards || subredditWildcards) return @"pattern would match every subreddit or every path";
    // r/all's filter forms match as /r/all (ApolloWebJSONRouteMatchSegments).
    if (segments.count > 1 && [segments[0] isEqualToString:@"r"] && [segments[1] hasPrefix:@"all-"]) {
        return @"r/all-<sub> can't be matched apart from r/all; use /r/all";
    }
    return nil;
}

// A route given as a name ("old") or as parts ({"host": "oauth", "auth":
// "bearer"}; "path" defaults to "same" and "auth" to "cookie"). Sets `problem`
// and returns -1 when it isn't one of the routes.
static NSInteger ApolloWebJSONRouteFromSpec(id spec, NSString **problem) {
    if ([spec isKindOfClass:[NSString class]]) {
        NSInteger route = ApolloWebJSONRouteFromName(spec);
        if (route < 0) *problem = [NSString stringWithFormat:@"unknown route %@", spec];
        return route;
    }
    if (![spec isKindOfClass:[NSDictionary class]]) { *problem = @"a route isn't a name or an object"; return -1; }
    NSDictionary *parts = spec;
    for (id key in parts) {
        if (![@[ @"host", @"path", @"auth" ] containsObject:key]) { *problem = [NSString stringWithFormat:@"unknown route part %@", key]; return -1; }
    }
    id host = parts[@"host"], path = parts[@"path"] ?: @"same", auth = parts[@"auth"] ?: @"cookie";
    if (![ApolloWebJSONRouteHostNames() containsObject:host]) { *problem = [NSString stringWithFormat:@"unknown host %@", host]; return -1; }
    NSUInteger pathForm = [path isKindOfClass:[NSString class]] ? [ApolloWebJSONRoutePathFormNames() indexOfObject:path] : NSNotFound;
    if (pathForm == NSNotFound) { *problem = [NSString stringWithFormat:@"unknown path form %@", path]; return -1; }
    NSUInteger authMethod = [auth isKindOfClass:[NSString class]] ? [ApolloWebJSONRouteAuthNames() indexOfObject:auth] : NSNotFound;
    if (authMethod == NSNotFound) { *problem = [NSString stringWithFormat:@"unknown auth %@", auth]; return -1; }
    NSInteger route = ApolloWebJSONRouteWithParts(host, (ApolloWebJSONRoutePathForm)pathForm, (ApolloWebJSONRouteAuth)authMethod);
    if (route < 0) *problem = [NSString stringWithFormat:@"%@ auth only works on oauth", auth];
    return route;
}

NSDictionary<NSString *, NSArray<NSNumber *> *> *ApolloWebJSONRouteTableParse(NSData *data, NSArray<NSString *> **rejections) {
    NSMutableArray<NSString *> *rejected = [NSMutableArray array];
    NSDictionary *result = nil;
    do {
        if (![data isKindOfClass:[NSData class]] || data.length == 0) { [rejected addObject:@"file: empty"]; break; }
        if (data.length > kApolloWebJSONRouteTableMaxBytes) { [rejected addObject:@"file: larger than 16 KB"]; break; }
        id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![root isKindOfClass:[NSDictionary class]]) { [rejected addObject:@"file: not a JSON object"]; break; }
        id version = root[@"version"];
        if (![version isKindOfClass:[NSNumber class]] || [version integerValue] != 1) { [rejected addObject:@"file: version isn't 1"]; break; }
        id endpoints = root[@"endpoints"] ?: @{};
        if (![endpoints isKindOfClass:[NSDictionary class]]) { [rejected addObject:@"file: endpoints isn't an object"]; break; }
        if ([endpoints count] > kApolloWebJSONRouteTableMaxEndpoints) { [rejected addObject:@"file: more than 32 endpoints"]; break; }

        NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *overrides = [NSMutableDictionary dictionary];
        for (id key in [[endpoints allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *label = [key isKindOfClass:[NSString class]] ? key : @"(non-string key)";
            NSArray<NSString *> *parts = [key isKindOfClass:[NSString class]] ? [key componentsSeparatedByString:@" "] : nil;
            if (parts.count != 2) { [rejected addObject:[label stringByAppendingString:@": not \"<METHOD> <path>\""]]; continue; }
            NSString *method = parts[0];
            NSString *path = parts[1];
            if (![method isEqualToString:@"GET"] && ![method isEqualToString:@"POST"]) {
                [rejected addObject:[label stringByAppendingString:@": method isn't GET or POST"]]; continue;
            }
            NSString *patternProblem = ApolloWebJSONRoutePatternProblem(path);
            if (patternProblem) { [rejected addObject:[NSString stringWithFormat:@"%@: %@", label, patternProblem]]; continue; }
            // A POST only where a built-in entry has exactly this POST: the
            // read-only /api/morechildren.
            BOOL builtInPOST = NO;
            for (NSDictionary *entry in ApolloWebJSONRouteBuiltInTable()) {
                if ([entry[@"method"] isEqualToString:method] && [entry[@"pattern"] isEqualToString:path]) builtInPOST = YES;
            }
            if (![method isEqualToString:@"GET"] && !builtInPOST) {
                [rejected addObject:[label stringByAppendingString:@": only GETs can be added"]]; continue;
            }
            id entry = endpoints[key];
            id specs = [entry isKindOfClass:[NSDictionary class]] ? entry[@"routes"] : nil;
            if (![specs isKindOfClass:[NSArray class]] || [specs count] == 0 || [specs count] > kApolloWebJSONRouteTableMaxRoutes) {
                [rejected addObject:[label stringByAppendingString:@": routes isn't a list of 1 to 5 routes"]]; continue;
            }
            NSMutableArray<NSNumber *> *routes = [NSMutableArray array];
            NSString *problem = nil;
            for (id spec in specs) {
                NSInteger route = ApolloWebJSONRouteFromSpec(spec, &problem);
                if (route < 0) break;
                if ([routes containsObject:@(route)]) {
                    problem = [NSString stringWithFormat:@"route %@ listed twice", ApolloWebJSONRouteName((ApolloWebJSONRoute)route)]; break;
                }
                // /r/all/api/<endpoint> is a path Reddit serves; /r/all in front
                // of anything else isn't the same read.
                if (ApolloWebJSONRouteGetPathForm((ApolloWebJSONRoute)route) == ApolloWebJSONRoutePathRAll && ![path hasPrefix:@"/api/"]) {
                    problem = [NSString stringWithFormat:@"route %@ is for /api/ paths only", ApolloWebJSONRouteName((ApolloWebJSONRoute)route)]; break;
                }
                [routes addObject:@(route)];
            }
            if (problem) { [rejected addObject:[NSString stringWithFormat:@"%@: %@", label, problem]]; continue; }
            overrides[[NSString stringWithFormat:@"%@ %@", method, path]] = [routes copy];
        }
        result = [overrides copy];
    } while (0);
    if (rejections) *rejections = [rejected copy];
    return result;
}

NSString *ApolloWebJSONRouteRemoteTableDescription(void) {
    NSDictionary<NSString *, NSArray<NSNumber *> *> *table;
    @synchronized (ApolloWebJSONRemoteTableLock()) {
        table = sApolloWebJSONRemoteTable;
    }
    if (table.count == 0) return @"(built-in routes only)";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *key in [table.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@" "];
        NSArray<NSNumber *> *builtIn = ApolloWebJSONRouteBuiltInMatch(parts.firstObject, parts.lastObject)[@"routes"];
        [lines addObject:[NSString stringWithFormat:@"%@: %@ (built-in: %@)", key, ApolloWebJSONRouteNames(table[key]),
                          builtIn ? ApolloWebJSONRouteNames(builtIn) : @"www"]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Route health

static NSInteger const kApolloWebJSONRouteBlocksBeforeCooldown = 3;
static NSTimeInterval const kApolloWebJSONRouteFirstCooldown = 60.0 * 60.0;
static NSTimeInterval const kApolloWebJSONRouteLongestCooldown = 8.0 * 60.0 * 60.0;
// Every keyless path is counted, so bound the store: paths group by entry or
// pattern,
// and an account's health starts over if it ever grows past this.
static NSUInteger const kApolloWebJSONRouteHealthMaxEntries = 512;

@interface ApolloWebJSONRouteHealthEntry : NSObject
@property (nonatomic) NSInteger consecutiveBlocks;
@property (nonatomic) NSTimeInterval cooldownUntil;
@property (nonatomic) NSTimeInterval cooldownLength; // 0 after a success
@property (nonatomic) NSUInteger blocks;
@property (nonatomic) NSUInteger successes;
@property (nonatomic) NSTimeInterval lastBlockAt;
@property (nonatomic) NSTimeInterval lastSuccessAt;
@end
@implementation ApolloWebJSONRouteHealthEntry
@end

static NSObject *ApolloWebJSONRouteHealthLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Guarded by ApolloWebJSONRouteHealthLock. "<account>|<group>|<route>".
static NSMutableDictionary<NSString *, ApolloWebJSONRouteHealthEntry *> *sApolloWebJSONRouteHealth;

NSString *ApolloWebJSONRoutePathPattern(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return @"/";
    NSArray<NSString *> *segments = [[ApolloWebJSONRouteEndpointKey(path) substringFromIndex:1] componentsSeparatedByString:@"/"];
    static NSSet<NSString *> *variableAfter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        variableAfter = [NSSet setWithArray:@[ @"r", @"u", @"user", @"comments", @"duplicates", @"by_id", @"m" ]];
    });
    NSMutableArray<NSString *> *pattern = [NSMutableArray arrayWithCapacity:segments.count];
    for (NSUInteger i = 0; i < segments.count; i++) {
        // The segment after one of those names, unless that name was itself a
        // value ("/r/user/…"), and a comment link's slug ("/comments/<id>/<slug>").
        // Names joined with "+" (a multireddit) are "+", so they group apart
        // from single subreddits.
        BOOL afterName = i > 0 && [variableAfter containsObject:segments[i - 1]] &&
                         !ApolloWebJSONRouteSegmentIsWildcard(pattern.lastObject);
        BOOL slug = i > 1 && [segments[i - 2] isEqualToString:@"comments"];
        if (afterName || slug) {
            [pattern addObject:ApolloWebJSONRouteSegmentIsJoinedList(segments[i]) ? @"+" : @"*"];
        } else {
            [pattern addObject:segments[i]];
        }
    }
    return [@"/" stringByAppendingString:[pattern componentsJoinedByString:@"/"]];
}

static NSString *ApolloWebJSONRouteHealthKey(NSString *account, NSString *method, NSString *path, ApolloWebJSONRoute route) {
    return [NSString stringWithFormat:@"%@|%@|%@", account.lowercaseString ?: @"", ApolloWebJSONRouteHealthGroup(method, path),
            ApolloWebJSONRouteName(route)];
}

// Under the lock.
static ApolloWebJSONRouteHealthEntry *ApolloWebJSONRouteHealthEntryFor(NSString *key, BOOL create) {
    if (!sApolloWebJSONRouteHealth) sApolloWebJSONRouteHealth = [NSMutableDictionary dictionary];
    ApolloWebJSONRouteHealthEntry *entry = sApolloWebJSONRouteHealth[key];
    if (!entry && create) {
        if (sApolloWebJSONRouteHealth.count >= kApolloWebJSONRouteHealthMaxEntries) [sApolloWebJSONRouteHealth removeAllObjects];
        entry = [ApolloWebJSONRouteHealthEntry new];
        sApolloWebJSONRouteHealth[key] = entry;
    }
    return entry;
}

BOOL ApolloWebJSONRouteHealthNoteBlockPage(NSString *account, NSString *method, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now) {
    if (account.length == 0) return NO;
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        ApolloWebJSONRouteHealthEntry *entry = ApolloWebJSONRouteHealthEntryFor(ApolloWebJSONRouteHealthKey(account, method, path, route), YES);
        entry.blocks++;
        entry.lastBlockAt = now;
        if (now < entry.cooldownUntil) return NO; // a request sent before the cooldown began
        entry.consecutiveBlocks++;
        // Straight back on a longer cooldown when the first try after one fails.
        BOOL wasCooling = entry.cooldownLength > 0;
        if (!wasCooling && entry.consecutiveBlocks < kApolloWebJSONRouteBlocksBeforeCooldown) return NO;
        entry.cooldownLength = wasCooling ? MIN(entry.cooldownLength * 2.0, kApolloWebJSONRouteLongestCooldown)
                                          : kApolloWebJSONRouteFirstCooldown;
        entry.cooldownUntil = now + entry.cooldownLength;
        entry.consecutiveBlocks = 0;
        return YES;
    }
}

void ApolloWebJSONRouteHealthNoteSuccess(NSString *account, NSString *method, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now) {
    if (account.length == 0) return;
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        ApolloWebJSONRouteHealthEntry *entry = ApolloWebJSONRouteHealthEntryFor(ApolloWebJSONRouteHealthKey(account, method, path, route), YES);
        entry.successes++;
        entry.lastSuccessAt = now;
        entry.consecutiveBlocks = 0;
        entry.cooldownLength = 0;
        entry.cooldownUntil = 0;
    }
}

NSTimeInterval ApolloWebJSONRouteCooldownRemaining(NSString *account, NSString *method, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now) {
    if (account.length == 0) return 0;
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        ApolloWebJSONRouteHealthEntry *entry = ApolloWebJSONRouteHealthEntryFor(ApolloWebJSONRouteHealthKey(account, method, path, route), NO);
        return entry ? MAX(0, entry.cooldownUntil - now) : 0;
    }
}

NSInteger ApolloWebJSONRouteChoose(NSString *account, NSString *method, NSString *path, NSUInteger triedMask, NSTimeInterval now) {
    NSArray<NSNumber *> *routes = ApolloWebJSONRoutesForRequest(method, path);
    NSInteger firstUntried = -1;
    for (NSNumber *number in routes) {
        ApolloWebJSONRoute route = (ApolloWebJSONRoute)number.integerValue;
        if (triedMask & (1u << route)) continue;
        // A bearer route without a bearer on hand can't be sent at all; the
        // handler may start a mint for a later request.
        if (ApolloWebJSONRouteGetAuth(route) == ApolloWebJSONRouteAuthBearer && !ApolloWebJSONRouteBearerReady(account)) continue;
        if (firstUntried < 0) firstUntried = route;
        if (ApolloWebJSONRouteCooldownRemaining(account, method, path, route, now) <= 0) return route;
    }
    return triedMask == 0 ? firstUntried : -1;
}

NSString *ApolloWebJSONRouteHealthDescription(NSTimeInterval now) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        for (NSString *key in [sApolloWebJSONRouteHealth.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            ApolloWebJSONRouteHealthEntry *entry = sApolloWebJSONRouteHealth[key];
            NSString *cooldown = entry.cooldownUntil > now
                ? [NSString stringWithFormat:@", cooling down %.0f min more", ceil((entry.cooldownUntil - now) / 60.0)] : @"";
            [lines addObject:[NSString stringWithFormat:@"%@: %lu ok, %lu blocked%@", key,
                              (unsigned long)entry.successes, (unsigned long)entry.blocks, cooldown]];
        }
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"(no keyless responses yet)";
}

void ApolloWebJSONRouteHealthReset(void) {
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        [sApolloWebJSONRouteHealth removeAllObjects];
    }
}

NSArray<NSDictionary<NSString *, id> *> *ApolloWebJSONRouteHealthSnapshot(NSString *account, NSTimeInterval now) {
    NSString *wanted = account.lowercaseString;
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        for (NSString *key in sApolloWebJSONRouteHealth) {
            NSArray<NSString *> *parts = [key componentsSeparatedByString:@"|"];
            if (parts.count != 3) continue;
            if (wanted.length && ![parts[0] isEqualToString:wanted]) continue;
            NSInteger route = ApolloWebJSONRouteFromName(parts[2]);
            if (route < 0) continue;
            ApolloWebJSONRouteHealthEntry *entry = sApolloWebJSONRouteHealth[key];
            [rows addObject:@{
                @"account": parts[0], @"pattern": parts[1], @"route": @(route),
                @"ok": @(entry.successes), @"blocked": @(entry.blocks),
                @"lastOkAt": @(entry.lastSuccessAt), @"lastBlockedAt": @(entry.lastBlockAt),
                @"cooldownRemaining": @(MAX(0, entry.cooldownUntil - now)),
            }];
        }
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult byAccount = [a[@"account"] compare:b[@"account"]];
        if (byAccount != NSOrderedSame) return byAccount;
        NSComparisonResult byPattern = [a[@"pattern"] compare:b[@"pattern"]];
        return byPattern != NSOrderedSame ? byPattern : [a[@"route"] compare:b[@"route"]];
    }];
    return rows;
}

NSArray<NSString *> *ApolloWebJSONRouteFallbackEndpoints(void) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (NSArray<NSDictionary *> *table in @[ ApolloWebJSONRouteBuiltInTable(), ApolloWebJSONRemoteEntries() ]) {
        for (NSDictionary *entry in table) {
            // A built-in entry the remote table overrides with one route has
            // no fallback any more.
            if (ApolloWebJSONRoutesForRequest(entry[@"method"], entry[@"pattern"]).count > 1) {
                [keys addObject:[NSString stringWithFormat:@"%@ %@", entry[@"method"], entry[@"pattern"]]];
            }
        }
    }
    return [keys.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

BOOL ApolloWebJSONRouteIsFromRemoteTable(NSString *method, NSString *path) {
    return [ApolloWebJSONRouteMatch(method, path)[@"remote"] boolValue];
}
