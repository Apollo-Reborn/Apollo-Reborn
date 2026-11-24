#import "ApolloGQLPlan.h"
#import "ApolloGQLLegacy.h"

NSString *const ApolloGQLOperationPostsByIds = @"PostsByIds";
NSString *const ApolloGQLOperationSubredditFeed = @"SubredditFeedSdui";

// 30 in one call was answered in full (2026-11-24); more wasn't tried.
const NSUInteger ApolloGQLPostsByIdsBatch = 30;

// Operation name -> persisted-query hash. These are the ids Reddit's Android
// app (2026.42.0) sends; gql-fed.reddit.com ran each of them for the desktop
// web client's token on 2026-11-23 and 2026-11-24. A hash Reddit retires
// answers "persisted query not found", which sends the request to its other
// routes (ApolloGQLRoute.m).
static NSDictionary<NSString *, NSString *> *ApolloGQLOperationHashes(void) {
    static NSDictionary<NSString *, NSString *> *hashes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hashes = @{
            ApolloGQLOperationPostsByIds: @"29a8d4c6e135fffb95fc4cd303c57ad926c6c5ff582f4c4577c8a69b7f322d91",
            ApolloGQLOperationSubredditFeed: @"fcc9854f03d7829810b2b6f607bae27407d2bbb576b09d8ee59869f80b13ca10",
        };
    });
    return hashes;
}

NSString *ApolloGQLOperationHash(NSString *name) {
    return [name isKindOfClass:[NSString class]] ? ApolloGQLOperationHashes()[name] : nil;
}

NSData *ApolloGQLOperationBody(NSString *name, NSDictionary *variables) {
    NSString *hash = ApolloGQLOperationHash(name);
    if (!hash || ![variables isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *body = @{ @"operationName": name, @"variables": variables,
                            @"extensions": @{ @"persistedQuery": @{ @"version": @1, @"sha256Hash": hash } } };
    return [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
}

NSDictionary *ApolloGQLPostsByIdsVariables(NSArray<NSString *> *fullnames) {
    return @{ @"ids": fullnames ?: @[], @"includeExtendedVideoAsset": @YES, @"includePlaybackMp4s": @YES };
}

NSDictionary *ApolloGQLSubredditFeedVariables(ApolloGQLRequest *request, NSString *after) {
    NSMutableDictionary *variables = [NSMutableDictionary dictionary];
    variables[@"subredditName"] = request.subreddit ?: @"";
    variables[@"sort"] = request.sort ?: @"HOT";
    if (request.timeRange.length > 0) variables[@"time"] = request.timeRange;
    NSString *cursor = ApolloGQLFeedCursorForFullname(after);
    if (cursor.length > 0) variables[@"after"] = cursor;
    return variables;
}

#pragma mark - Requests

@interface ApolloGQLRequest ()
@property (nonatomic, readwrite) ApolloGQLRequestKind kind;
@property (nonatomic, copy, readwrite, nullable) NSArray<NSString *> *fullnames;
@property (nonatomic, copy, readwrite, nullable) NSString *subreddit;
@property (nonatomic, copy, readwrite, nullable) NSString *sort;
@property (nonatomic, copy, readwrite, nullable) NSString *timeRange;
@property (nonatomic, copy, readwrite, nullable) NSString *after;
@property (nonatomic, readwrite) NSInteger limit;
@property (nonatomic, readwrite) BOOL rawJSON;
@end

@implementation ApolloGQLRequest
@end

// The path's segments, lowercased, without a query, ".json" or empty segments.
// The subreddit keeps its case in `original`, in step with the lowercased list.
static NSArray<NSString *> *ApolloGQLPathSegments(NSString *path, NSArray<NSString *> **original) {
    NSString *bare = [path componentsSeparatedByString:@"?"].firstObject ?: @"";
    NSMutableArray<NSString *> *segments = [NSMutableArray array], *kept = [NSMutableArray array];
    for (NSString *segment in [bare componentsSeparatedByString:@"/"]) {
        if (segment.length == 0) continue;
        [kept addObject:segment];
        [segments addObject:segment.lowercaseString];
    }
    NSString *last = segments.lastObject;
    if ([last isEqualToString:@".json"]) {
        [segments removeLastObject];
        [kept removeLastObject];
    } else if ([last hasSuffix:@".json"]) {
        segments[segments.count - 1] = [last substringToIndex:last.length - 5];
        NSString *keptLast = kept.lastObject;
        kept[kept.count - 1] = [keptLast substringToIndex:keptLast.length - 5];
    }
    if (original) *original = kept;
    return segments;
}

// RedditKit's parameters, with any query the path itself carries; values as
// strings.
static NSDictionary<NSString *, NSString *> *ApolloGQLRequestParameters(NSString *path, id parameters) {
    NSMutableDictionary<NSString *, NSString *> *merged = [NSMutableDictionary dictionary];
    NSRange query = [path rangeOfString:@"?"];
    if (query.location != NSNotFound) {
        NSURLComponents *components = [NSURLComponents new];
        components.percentEncodedQuery = [path substringFromIndex:query.location + 1];
        for (NSURLQueryItem *item in components.queryItems) {
            if (item.value) merged[item.name] = item.value;
        }
    }
    if ([parameters isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)parameters) {
            id value = ((NSDictionary *)parameters)[key];
            if (![key isKindOfClass:[NSString class]]) continue;
            if ([value isKindOfClass:[NSString class]]) merged[key] = value;
            else if ([value isKindOfClass:[NSNumber class]]) merged[key] = [value stringValue];
        }
    }
    return merged;
}

static NSDictionary<NSString *, NSString *> *ApolloGQLFeedSorts(void) {
    return @{ @"hot": @"HOT", @"new": @"NEW", @"rising": @"RISING", @"top": @"TOP",
              @"controversial": @"CONTROVERSIAL", @"best": @"BEST" };
}

// A subreddit GraphQL's subreddit feed serves: one real community. Not the
// feeds that only look like one (r/all, r/popular, …), a "+" or "-" list, or a
// user's profile ("u_<name>").
static BOOL ApolloGQLSubredditIsPlain(NSString *lowercasedName) {
    static NSRegularExpression *name;
    static NSSet<NSString *> *special;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        name = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9][a-z0-9_]{1,20}$" options:0 error:NULL];
        special = [NSSet setWithArray:@[ @"all", @"popular", @"mod", @"friends", @"random", @"randnsfw", @"myrandom", @"home", @"best" ]];
    });
    if (lowercasedName.length == 0 || [special containsObject:lowercasedName] || [lowercasedName hasPrefix:@"u_"]) return NO;
    return [name firstMatchInString:lowercasedName options:0 range:NSMakeRange(0, lowercasedName.length)] != nil;
}

// The kind of request a method and path are, or 0.
static ApolloGQLRequestKind ApolloGQLKindForPath(NSString *method, NSString *path, NSArray<NSString *> **segmentsOut,
                                                 NSArray<NSString *> **originalOut) {
    if (![method isKindOfClass:[NSString class]] || ![path isKindOfClass:[NSString class]]) return 0;
    if (![method.uppercaseString isEqualToString:@"GET"]) return 0;
    NSArray<NSString *> *original = nil;
    NSArray<NSString *> *segments = ApolloGQLPathSegments(path, &original);
    if (segmentsOut) *segmentsOut = segments;
    if (originalOut) *originalOut = original;
    if (segments.count == 2 && [segments[0] isEqualToString:@"api"] && [segments[1] isEqualToString:@"info"]) {
        return ApolloGQLRequestKindPostsInfo;
    }
    if ((segments.count == 2 || segments.count == 3) && [segments[0] isEqualToString:@"r"] && ApolloGQLSubredditIsPlain(segments[1])) {
        if (segments.count == 2 || ApolloGQLFeedSorts()[segments[2]]) return ApolloGQLRequestKindSubredditFeed;
    }
    return 0;
}

BOOL ApolloGQLCanAnswerPath(NSString *method, NSString *path) {
    return ApolloGQLKindForPath(method, path, NULL, NULL) != 0;
}

ApolloGQLRequest *ApolloGQLRequestForLegacy(NSString *method, NSString *path, id parameters) {
    NSArray<NSString *> *segments = nil, *original = nil;
    ApolloGQLRequestKind kind = ApolloGQLKindForPath(method, path, &segments, &original);
    if (kind == 0) return nil;
    NSDictionary<NSString *, NSString *> *query = ApolloGQLRequestParameters(path, parameters);
    ApolloGQLRequest *request = [ApolloGQLRequest new];
    request.kind = kind;
    request.rawJSON = [query[@"raw_json"] boolValue];

    if (kind == ApolloGQLRequestKindPostsInfo) {
        // Only a lookup by fullname, and only of posts: comments and
        // subreddits come from other queries.
        if (query[@"url"] || query[@"sr_name"]) return nil;
        NSMutableArray<NSString *> *fullnames = [NSMutableArray array];
        for (NSString *part in [query[@"id"] componentsSeparatedByString:@","]) {
            NSString *fullname = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (fullname.length == 0) continue;
            if (![fullname hasPrefix:@"t3_"] || fullname.length <= 3) return nil;
            if (![fullnames containsObject:fullname]) [fullnames addObject:fullname];
        }
        if (fullnames.count == 0 || fullnames.count > 100) return nil;
        request.fullnames = fullnames;
        return request;
    }

    // A feed page asked for backwards has no GraphQL form.
    if (query[@"before"].length > 0) return nil;
    NSString *after = query[@"after"];
    if (after.length > 0 && ![after hasPrefix:@"t3_"]) return nil;
    request.after = after.length > 0 ? after : nil;
    request.subreddit = original.count > 1 ? original[1] : segments[1];
    NSString *sort = segments.count == 3 ? ApolloGQLFeedSorts()[segments[2]] : @"HOT";
    request.sort = sort;
    if ([sort isEqualToString:@"TOP"] || [sort isEqualToString:@"CONTROVERSIAL"]) {
        static NSSet<NSString *> *ranges;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            ranges = [NSSet setWithArray:@[ @"hour", @"day", @"week", @"month", @"year", @"all" ]];
        });
        NSString *range = query[@"t"].lowercaseString;
        // Reddit's own default for these sorts is the last day.
        request.timeRange = [ranges containsObject:range] ? range.uppercaseString : @"DAY";
    }
    NSInteger limit = query[@"limit"].integerValue;
    request.limit = limit > 0 ? MIN(limit, 100) : 25;
    return request;
}
