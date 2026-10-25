#import "ApolloWebJSONRoutes.h"

NSString *ApolloWebJSONRouteName(ApolloWebJSONRoute route) {
    switch (route) {
        case ApolloWebJSONRouteWwwDotJSON: return @"www-dotjson";
        case ApolloWebJSONRouteOld: return @"old";
        case ApolloWebJSONRouteWww:
        default: return @"www";
    }
}

NSString *ApolloWebJSONRouteHost(ApolloWebJSONRoute route) {
    return route == ApolloWebJSONRouteOld ? @"old.reddit.com" : @"www.reddit.com";
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

NSArray<NSNumber *> *ApolloWebJSONRoutesForRequest(NSString *method, NSString *path) {
    return ApolloWebJSONRouteEntry(method, path)[@"routes"] ?: @[ @(ApolloWebJSONRouteWww) ];
}

// Every table entry is a read (see above), so its fallback routes may be tried
// in turn. Anything else, writes included, has only www and is never resent.
BOOL ApolloWebJSONRouteRequestMayRetry(NSString *method, NSString *path) {
    return [ApolloWebJSONRouteEntry(method, path)[@"routes"] count] > 1;
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
