#import "ApolloWebJSONRoutes.h"

NSString *ApolloWebJSONRouteName(ApolloWebJSONRoute route) {
    switch (route) {
        case ApolloWebJSONRouteWwwDotJSON: return @"www-dotjson";
        case ApolloWebJSONRouteOld: return @"old";
        case ApolloWebJSONRouteApi: return @"api";
        case ApolloWebJSONRouteWww:
        default: return @"www";
    }
}

NSString *ApolloWebJSONRouteHost(ApolloWebJSONRoute route) {
    switch (route) {
        case ApolloWebJSONRouteOld: return @"old.reddit.com";
        case ApolloWebJSONRouteApi: return @"api.reddit.com";
        case ApolloWebJSONRouteWww:
        case ApolloWebJSONRouteWwwDotJSON:
        default: return @"www.reddit.com";
    }
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
static NSDictionary *ApolloWebJSONRouteEntry(NSString *method, NSString *path) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *fallbacks = @[ @(ApolloWebJSONRouteWwwDotJSON), @(ApolloWebJSONRouteOld) ];
        table = @[
            @{ @"endpoint": @"/api/info", @"methods": @[ @"GET" ], @"routes": fallbacks },
            @{ @"endpoint": @"/api/morechildren", @"methods": @[ @"GET", @"POST" ], @"routes": fallbacks },
        ];
    });
    if (![method isKindOfClass:[NSString class]] || ![path isKindOfClass:[NSString class]]) return nil;
    NSString *key = ApolloWebJSONRouteEndpointKey(path);
    NSString *upper = method.uppercaseString;
    for (NSDictionary *row in table) {
        if ([row[@"endpoint"] isEqualToString:key] && [row[@"methods"] containsObject:upper]) return row;
    }
    return nil;
}

static NSArray<NSNumber *> *ApolloWebJSONRemoteRoutes(NSString *method, NSString *path);

NSArray<NSNumber *> *ApolloWebJSONRoutesForRequest(NSString *method, NSString *path) {
    return ApolloWebJSONRemoteRoutes(method, path) ?: ApolloWebJSONRouteEntry(method, path)[@"routes"] ?: @[ @(ApolloWebJSONRouteWww) ];
}

// Every built-in entry is a read (see above), and the remote table can only add
// GETs (ApolloWebJSONRouteTableParse), so a request with more than one route
// may try them in turn. Anything else, writes included, has only www and is
// never resent.
BOOL ApolloWebJSONRouteRequestMayRetry(NSString *method, NSString *path) {
    return ApolloWebJSONRoutesForRequest(method, path).count > 1;
}

NSString *ApolloWebJSONRoutePath(ApolloWebJSONRoute route, NSString *path) {
    if (route != ApolloWebJSONRouteWwwDotJSON) return path;
    return [ApolloWebJSONRouteEndpointKey(path) stringByAppendingString:@"/.json"];
}

BOOL ApolloWebJSONRouteResponseIsBlockPage(NSHTTPURLResponse *response) {
    if (![response isKindOfClass:[NSHTTPURLResponse class]] || response.statusCode != 403) return NO;
    NSString *contentType = [[response valueForHTTPHeaderField:@"Content-Type"] lowercaseString] ?: @"";
    return [contentType containsString:@"text/html"];
}

#pragma mark - Remote route table (keyless-routes.json)

static NSUInteger const kApolloWebJSONRouteTableMaxBytes = 16 * 1024;
static NSUInteger const kApolloWebJSONRouteTableMaxEndpoints = 32;
static NSUInteger const kApolloWebJSONRouteTableMaxRoutes = 4;

static NSObject *ApolloWebJSONRemoteTableLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Guarded by ApolloWebJSONRemoteTableLock.
static NSDictionary<NSString *, NSArray<NSNumber *> *> *sApolloWebJSONRemoteTable;

static NSString *ApolloWebJSONRemoteTableKey(NSString *method, NSString *path) {
    return [NSString stringWithFormat:@"%@ %@", method.uppercaseString, ApolloWebJSONRouteEndpointKey(path)];
}

static NSArray<NSNumber *> *ApolloWebJSONRemoteRoutes(NSString *method, NSString *path) {
    if (![method isKindOfClass:[NSString class]] || ![path isKindOfClass:[NSString class]]) return nil;
    @synchronized (ApolloWebJSONRemoteTableLock()) {
        if (sApolloWebJSONRemoteTable.count == 0) return nil;
        return sApolloWebJSONRemoteTable[ApolloWebJSONRemoteTableKey(method, path)];
    }
}

void ApolloWebJSONRouteSetRemoteTable(NSDictionary<NSString *, NSArray<NSNumber *> *> *overrides) {
    @synchronized (ApolloWebJSONRemoteTableLock()) {
        sApolloWebJSONRemoteTable = [overrides copy];
    }
}

static NSInteger ApolloWebJSONRouteFromName(id name) {
    if (![name isKindOfClass:[NSString class]]) return -1;
    for (NSInteger r = ApolloWebJSONRouteWww; r <= ApolloWebJSONRouteLast; r++) {
        if ([ApolloWebJSONRouteName((ApolloWebJSONRoute)r) isEqualToString:name]) return r;
    }
    return -1;
}

static NSString *ApolloWebJSONRouteNames(NSArray<NSNumber *> *routes) {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:routes.count];
    for (NSNumber *route in routes) [names addObject:ApolloWebJSONRouteName((ApolloWebJSONRoute)route.integerValue)];
    return [names componentsJoinedByString:@", "];
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
            // Exactly /api/<name>: no wildcards, query, listings or other segments.
            static NSRegularExpression *apiPath;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                apiPath = [NSRegularExpression regularExpressionWithPattern:@"^/api/[a-z0-9_]+$" options:0 error:NULL];
            });
            if (![apiPath firstMatchInString:path options:0 range:NSMakeRange(0, path.length)]) {
                [rejected addObject:[label stringByAppendingString:@": path isn't /api/<name>"]]; continue;
            }
            BOOL builtIn = ApolloWebJSONRouteEntry(method, path) != nil;
            if (!builtIn && ![method isEqualToString:@"GET"]) {
                [rejected addObject:[label stringByAppendingString:@": only GETs can be added"]]; continue;
            }
            id entry = endpoints[key];
            id names = [entry isKindOfClass:[NSDictionary class]] ? entry[@"routes"] : nil;
            if (![names isKindOfClass:[NSArray class]] || [names count] == 0 || [names count] > kApolloWebJSONRouteTableMaxRoutes) {
                [rejected addObject:[label stringByAppendingString:@": routes isn't a list of 1 to 4 names"]]; continue;
            }
            NSMutableArray<NSNumber *> *routes = [NSMutableArray array];
            NSString *problem = nil;
            for (id name in names) {
                NSInteger route = ApolloWebJSONRouteFromName(name);
                if (route < 0) { problem = [NSString stringWithFormat:@": unknown route %@", name]; break; }
                if ([routes containsObject:@(route)]) { problem = [NSString stringWithFormat:@": route %@ listed twice", name]; break; }
                [routes addObject:@(route)];
            }
            if (problem) { [rejected addObject:[label stringByAppendingString:problem]]; continue; }
            overrides[ApolloWebJSONRemoteTableKey(method, path)] = [routes copy];
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
        NSArray<NSNumber *> *builtIn = ApolloWebJSONRouteEntry(parts.firstObject, parts.lastObject)[@"routes"];
        [lines addObject:[NSString stringWithFormat:@"%@: %@ (built-in: %@)", key, ApolloWebJSONRouteNames(table[key]),
                          builtIn ? ApolloWebJSONRouteNames(builtIn) : @"www"]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

#pragma mark - Route health

static NSInteger const kApolloWebJSONRouteBlocksBeforeCooldown = 3;
static NSTimeInterval const kApolloWebJSONRouteFirstCooldown = 60.0 * 60.0;
static NSTimeInterval const kApolloWebJSONRouteLongestCooldown = 8.0 * 60.0 * 60.0;
// Every keyless path is counted, so bound the store: paths group by pattern,
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

// Guarded by ApolloWebJSONRouteHealthLock. "<account>|<pattern>|<route>".
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
        BOOL afterName = i > 0 && [variableAfter containsObject:segments[i - 1]] && ![pattern.lastObject isEqualToString:@"*"];
        BOOL slug = i > 1 && [segments[i - 2] isEqualToString:@"comments"];
        [pattern addObject:afterName || slug ? @"*" : segments[i]];
    }
    return [@"/" stringByAppendingString:[pattern componentsJoinedByString:@"/"]];
}

static NSString *ApolloWebJSONRouteHealthKey(NSString *account, NSString *path, ApolloWebJSONRoute route) {
    return [NSString stringWithFormat:@"%@|%@|%@", account.lowercaseString ?: @"", ApolloWebJSONRoutePathPattern(path),
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

BOOL ApolloWebJSONRouteHealthNoteBlockPage(NSString *account, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now) {
    if (account.length == 0) return NO;
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        ApolloWebJSONRouteHealthEntry *entry = ApolloWebJSONRouteHealthEntryFor(ApolloWebJSONRouteHealthKey(account, path, route), YES);
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

void ApolloWebJSONRouteHealthNoteSuccess(NSString *account, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now) {
    if (account.length == 0) return;
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        ApolloWebJSONRouteHealthEntry *entry = ApolloWebJSONRouteHealthEntryFor(ApolloWebJSONRouteHealthKey(account, path, route), YES);
        entry.successes++;
        entry.lastSuccessAt = now;
        entry.consecutiveBlocks = 0;
        entry.cooldownLength = 0;
        entry.cooldownUntil = 0;
    }
}

NSTimeInterval ApolloWebJSONRouteCooldownRemaining(NSString *account, NSString *path, ApolloWebJSONRoute route, NSTimeInterval now) {
    if (account.length == 0) return 0;
    @synchronized (ApolloWebJSONRouteHealthLock()) {
        ApolloWebJSONRouteHealthEntry *entry = ApolloWebJSONRouteHealthEntryFor(ApolloWebJSONRouteHealthKey(account, path, route), NO);
        return entry ? MAX(0, entry.cooldownUntil - now) : 0;
    }
}

NSInteger ApolloWebJSONRouteChoose(NSString *account, NSString *method, NSString *path, NSUInteger triedMask, NSTimeInterval now) {
    NSArray<NSNumber *> *routes = ApolloWebJSONRoutesForRequest(method, path);
    NSInteger firstUntried = -1;
    for (NSNumber *number in routes) {
        ApolloWebJSONRoute route = (ApolloWebJSONRoute)number.integerValue;
        if (triedMask & (1u << route)) continue;
        if (firstUntried < 0) firstUntried = route;
        if (ApolloWebJSONRouteCooldownRemaining(account, path, route, now) <= 0) return route;
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
    for (NSArray<NSString *> *builtIn in @[ @[ @"GET", @"/api/info" ], @[ @"GET", @"/api/morechildren" ],
                                           @[ @"POST", @"/api/morechildren" ] ]) {
        if (ApolloWebJSONRoutesForRequest(builtIn[0], builtIn[1]).count > 1) {
            [keys addObject:ApolloWebJSONRemoteTableKey(builtIn[0], builtIn[1])];
        }
    }
    @synchronized (ApolloWebJSONRemoteTableLock()) {
        [sApolloWebJSONRemoteTable enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray<NSNumber *> *routes, __unused BOOL *stop) {
            if (routes.count > 1) [keys addObject:key];
        }];
    }
    return [keys.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

BOOL ApolloWebJSONRouteIsFromRemoteTable(NSString *method, NSString *path) {
    return ApolloWebJSONRemoteRoutes(method, path) != nil;
}
