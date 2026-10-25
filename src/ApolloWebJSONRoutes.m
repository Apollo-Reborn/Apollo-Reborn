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
