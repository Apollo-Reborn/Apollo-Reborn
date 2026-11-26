#import "ApolloGQLPlan.h"
#import "ApolloGQLLegacy.h"

NSString *const ApolloGQLOperationPostsByIds = @"PostsByIds";
NSString *const ApolloGQLOperationSubredditFeed = @"SubredditFeedSdui";
NSString *const ApolloGQLOperationHomeFeed = @"HomeFeedSdui";
NSString *const ApolloGQLOperationPopularFeed = @"PopularFeedSdui";
NSString *const ApolloGQLOperationUserPosts = @"SubmittedPostsFeedSdui";
NSString *const ApolloGQLOperationSearchPosts = @"SearchPosts";
NSString *const ApolloGQLOperationSubredditInfo = @"SubredditInfoByName";
NSString *const ApolloGQLOperationPostComments = @"PostComments";
NSString *const ApolloGQLOperationUserComments = @"SubmittedComments";
NSString *const ApolloGQLOperationCommentsByIds = @"LiveCommentsByIds";
static NSString *const ApolloGQLOperationUpvotedPosts = @"UpvotedPosts";
static NSString *const ApolloGQLOperationDownvotedPosts = @"DownvotedPosts";
static NSString *const ApolloGQLOperationHiddenPosts = @"HiddenPosts";

// 60 in one call were answered in full (2026-11-24). 50 covers a feed's first
// page (7 + 25 posts) and two later ones in a single call.
const NSUInteger ApolloGQLPostsByIdsBatch = 50;

// PostComments gives at most this many comments when told how many (a `count`
// of 500 answered the same 200), and its own, larger page when not told (265 on
// the same thread, 2026-11-24).
static const NSInteger kApolloGQLCommentsCountMax = 200;

// Operation name -> persisted-query hash. These are ids Reddit's own apps send
// (most are its Android app's, 2026.42.0); gql-fed.reddit.com ran each of them
// for the desktop web client's token on 2026-11-23 and 2026-11-24. A hash Reddit retires answers "persisted query
// not found", which sends the request to its other routes (ApolloGQLRoute.m).
static NSDictionary<NSString *, NSString *> *ApolloGQLOperationHashes(void) {
    static NSDictionary<NSString *, NSString *> *hashes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hashes = @{
            ApolloGQLOperationPostsByIds: @"29a8d4c6e135fffb95fc4cd303c57ad926c6c5ff582f4c4577c8a69b7f322d91",
            ApolloGQLOperationSubredditFeed: @"fcc9854f03d7829810b2b6f607bae27407d2bbb576b09d8ee59869f80b13ca10",
            ApolloGQLOperationPostComments: @"314f29c2494fd78c7844ef2c6b09acb4bef5b37ab50b4ddc01691d6d5c8433f8",
            ApolloGQLOperationHomeFeed: @"03d0ec0f2674005fe6c9777f952bd063ea2236527794344d4579fec8a669bea0",
            ApolloGQLOperationPopularFeed: @"5abe205dd071054dec10310876ca8ca1034f5a09a344659cc7e641ced2e799c2",
            ApolloGQLOperationUserPosts: @"8bcd9296341ba003625abe814251e57437c42f0272d88b166c499f8bebc4cadb",
            ApolloGQLOperationSearchPosts: @"08c50e2f9868ea1b8c4411cca57cd58353c729b4fa714cef66448600f76b0922",
            ApolloGQLOperationSubredditInfo: @"8c1815b07b762aee3c086cc84306f14b3907018e9ee152046c8e4d08ad4c7b88",
            // Run for the desktop web client's token on 2026-11-25.
            ApolloGQLOperationUpvotedPosts: @"4997de5649516763ab57f3f70eeba4c7638978c8613fc81c3212b1b5dbd0497e",
            ApolloGQLOperationDownvotedPosts: @"8e0d27e0f698b8718928bc8ebb0c5b5690b51bceb862db7ce4c7da6c4deef0f5",
            ApolloGQLOperationHiddenPosts: @"7548e75ad724b6888e7901b3a757d5111008c02624af20b0141b40fdca6276d2",
            ApolloGQLOperationUserComments: @"e1b37f521fb40af2120946b70e7fbf6a3d924db2abaf28ff2164d4cfacca28db",
            ApolloGQLOperationCommentsByIds: @"f6ea957fbe5df4386492b6f153c90e8f0f3d2d3556e908e4e4eb9c5afdb1ffa1",
        };
    });
    return hashes;
}

// The account's own lists by the last part of their path, and the operation
// that answers each.
static NSDictionary<NSString *, NSString *> *ApolloGQLOwnLists(void) {
    static NSDictionary<NSString *, NSString *> *lists;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lists = @{ @"upvoted": ApolloGQLOperationUpvotedPosts, @"downvoted": ApolloGQLOperationDownvotedPosts,
                   @"hidden": ApolloGQLOperationHiddenPosts };
    });
    return lists;
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

NSString *ApolloGQLFeedOperation(ApolloGQLRequest *request) {
    if (request.kind == ApolloGQLRequestKindHomeFeed) return ApolloGQLOperationHomeFeed;
    if (request.kind == ApolloGQLRequestKindPopularFeed) return ApolloGQLOperationPopularFeed;
    if (request.kind == ApolloGQLRequestKindUserPosts) return ApolloGQLOperationUserPosts;
    return ApolloGQLOperationSubredditFeed;
}

NSDictionary *ApolloGQLFeedVariables(ApolloGQLRequest *request, NSString *after) {
    NSMutableDictionary *variables = [NSMutableDictionary dictionary];
    if (request.kind == ApolloGQLRequestKindSubredditFeed) variables[@"subredditName"] = request.subreddit ?: @"";
    if (request.kind == ApolloGQLRequestKindUserPosts) variables[@"username"] = request.username ?: @"";
    variables[@"sort"] = request.sort ?: @"HOT";
    if (request.timeRange.length > 0) variables[@"time"] = request.timeRange;
    NSString *cursor = ApolloGQLFeedCursorForFullname(after);
    if (cursor.length > 0) variables[@"after"] = cursor;
    return variables;
}

NSDictionary *ApolloGQLSubredditInfoVariables(ApolloGQLRequest *request) {
    return @{ @"subredditName": request.subreddit ?: @"", @"includeRecapFields": @NO, @"includeDevvitData": @NO };
}

NSDictionary *ApolloGQLSearchPostsVariables(ApolloGQLRequest *request) {
    NSMutableDictionary *variables = [NSMutableDictionary dictionary];
    variables[@"query"] = request.searchQuery ?: @"";
    variables[@"productSurface"] = @"SEARCH";
    variables[@"sort"] = request.searchSort ?: @"RELEVANCE";
    NSMutableArray<NSDictionary *> *filters = [NSMutableArray array];
    if (request.searchIncludesNSFW) [filters addObject:@{ @"key": @"nsfw", @"value": @"1" }];
    if (request.searchRange.length > 0) [filters addObject:@{ @"key": @"time_range", @"value": request.searchRange }];
    variables[@"filters"] = filters;
    if (request.searchCursor.length > 0) variables[@"afterCursor"] = request.searchCursor;
    return variables;
}

NSDictionary *ApolloGQLPostCommentsVariables(ApolloGQLRequest *request) {
    NSMutableDictionary *variables = [NSMutableDictionary dictionary];
    variables[@"id"] = request.linkFullname ?: @"";
    variables[@"sortType"] = request.commentSort ?: @"CONFIDENCE";
    variables[@"includePremiumAvatarTreatment"] = @NO;
    variables[@"includeConsistencyToken"] = @NO;
    if (request.kind == ApolloGQLRequestKindMoreComments) {
        variables[@"after"] = request.moreCursor ?: @"";
        variables[@"count"] = @(kApolloGQLCommentsCountMax);
    } else if (request.limit > 0 && request.limit < kApolloGQLCommentsCountMax) {
        variables[@"count"] = @(request.limit);
    }
    return variables;
}

BOOL ApolloGQLRequestIsForAccount(ApolloGQLRequest *request, NSString *account) {
    if (request.kind != ApolloGQLRequestKindOwnPosts) return YES;
    return request.username.length > 0 && account.length > 0 && [request.username caseInsensitiveCompare:account] == NSOrderedSame;
}

NSString *ApolloGQLOwnPostsOperation(ApolloGQLRequest *request) {
    return ApolloGQLOwnLists()[request.ownList ?: @""] ?: ApolloGQLOperationUpvotedPosts;
}

NSDictionary *ApolloGQLOwnPostsVariables(ApolloGQLRequest *request) {
    NSString *cursor = ApolloGQLFeedCursorForFullname(request.after);
    return cursor.length > 0 ? @{ @"after": cursor } : @{};
}

NSDictionary *ApolloGQLUserCommentsVariables(ApolloGQLRequest *request) {
    NSMutableDictionary *variables = [NSMutableDictionary dictionary];
    variables[@"name"] = request.username ?: @"";
    variables[@"sort"] = request.sort ?: @"NEW";
    if (request.timeRange.length > 0) variables[@"range"] = request.timeRange;
    NSString *cursor = ApolloGQLFeedCursorForFullname(request.after);
    if (cursor.length > 0) variables[@"after"] = cursor;
    return variables;
}

NSDictionary *ApolloGQLCommentsByIdsVariables(NSArray<NSString *> *fullnames) {
    return @{ @"ids": fullnames ?: @[], @"includePremiumAvatarTreatment": @NO, @"includeCommentsHtmlField": @YES };
}

#pragma mark - Requests

@interface ApolloGQLRequest ()
@property (nonatomic, readwrite) ApolloGQLRequestKind kind;
@property (nonatomic, copy, readwrite, nullable) NSArray<NSString *> *fullnames;
@property (nonatomic, copy, readwrite, nullable) NSString *subreddit;
@property (nonatomic, copy, readwrite, nullable) NSString *username;
@property (nonatomic, copy, readwrite, nullable) NSString *searchQuery;
@property (nonatomic, copy, readwrite, nullable) NSString *searchSort;
@property (nonatomic, copy, readwrite, nullable) NSString *searchRange;
@property (nonatomic, readwrite) BOOL searchIncludesNSFW;
@property (nonatomic, copy, readwrite, nullable) NSString *searchCursor;
@property (nonatomic, copy, readwrite, nullable) NSString *sort;
@property (nonatomic, copy, readwrite, nullable) NSString *timeRange;
@property (nonatomic, copy, readwrite, nullable) NSString *after;
@property (nonatomic, readwrite) NSInteger limit;
@property (nonatomic, copy, readwrite, nullable) NSString *linkFullname;
@property (nonatomic, copy, readwrite, nullable) NSString *commentSort;
@property (nonatomic, copy, readwrite, nullable) NSString *moreCursor;
@property (nonatomic, readwrite) NSInteger moreDepth;
@property (nonatomic, readwrite) BOOL rawJSON;
@property (nonatomic, copy, readwrite, nullable) NSString *ownList;
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

// GraphQL's comment sorts by the legacy API's names. The legacy API has more
// ("hot", "random", "live"); PostComments answers those "Invalid input".
static NSDictionary<NSString *, NSString *> *ApolloGQLCommentSorts(void) {
    return @{ @"confidence": @"CONFIDENCE", @"best": @"CONFIDENCE", @"top": @"TOP", @"new": @"NEW", @"old": @"OLD",
              @"controversial": @"CONTROVERSIAL", @"qa": @"QA" };
}

// A post's id as the legacy API writes it in a path: base 36, no "t3_".
static BOOL ApolloGQLIsID36(NSString *text) {
    if (text.length == 0 || text.length > 13) return NO;
    NSCharacterSet *other = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyz"] invertedSet];
    return [text rangeOfCharacterFromSet:other].location == NSNotFound;
}

// The post id of a thread's path, "comments/<id>" or "r/<sub>/comments/<id>",
// each with an optional slug after it. nil for anything else, a thread opened
// at one comment ("comments/<id>/<slug>/<comment id>") included: PostComments
// has no way to ask for a comment and its context.
static NSString *ApolloGQLThreadID(NSArray<NSString *> *segments) {
    NSUInteger start = segments.count >= 2 && [segments[0] isEqualToString:@"r"] ? 2 : 0;
    if (segments.count < start + 2 || segments.count > start + 3) return nil;
    if (![segments[start] isEqualToString:@"comments"] || !ApolloGQLIsID36(segments[start + 1])) return nil;
    return segments[start + 1];
}

// Home's sorts, all but "best". GraphQL's Home "Hot" is the legacy /hot post for
// post (the first 25 matched in order, 2026-11-24), and the other sorts hold
// only joined subreddits too. Its "Best" is another feed: of 103 rows over five
// pages, 6 were from joined subreddits and the rest suggestions, and those 6
// weren't the legacy /best's top posts. So /best keeps its other routes.
static BOOL ApolloGQLHomeSortIsAnswered(NSString *lowercasedSort) {
    return ApolloGQLFeedSorts()[lowercasedSort] != nil && ![lowercasedSort isEqualToString:@"best"];
}

// The kind of request a method and path are, or 0. `patterns` also takes the
// route table's endpoint patterns, where "*" stands for one subreddit, post or
// account ("/r/*/hot", "/comments/*"): the Routes screen lists each endpoint's
// routes by its pattern. A request never has one.
static ApolloGQLRequestKind ApolloGQLKindForPath(NSString *method, NSString *path, BOOL patterns, NSArray<NSString *> **segmentsOut,
                                                 NSArray<NSString *> **originalOut) {
    if (![method isKindOfClass:[NSString class]] || ![path isKindOfClass:[NSString class]]) return 0;
    NSArray<NSString *> *original = nil;
    NSArray<NSString *> *segments = ApolloGQLPathSegments(path, &original);
    if (segmentsOut) *segmentsOut = segments;
    if (originalOut) *originalOut = original;
    if ([segments containsObject:@"*"]) {
        if (!patterns) return 0;
        // The pattern as a request for a subreddit, post and account that
        // would pass the checks below.
        NSMutableArray<NSString *> *sample = [segments mutableCopy];
        for (NSUInteger i = 0; i < sample.count; i++) {
            if ([sample[i] isEqualToString:@"*"]) sample[i] = i > 0 && [sample[i - 1] isEqualToString:@"comments"] ? @"abc123" : @"example";
        }
        segments = sample;
    }
    BOOL get = [method.uppercaseString isEqualToString:@"GET"];
    // RedditKit asks for "load more" replies with a POST; it only reads.
    if (segments.count == 2 && [segments[0] isEqualToString:@"api"] && [segments[1] isEqualToString:@"morechildren"]) {
        return get || [method.uppercaseString isEqualToString:@"POST"] ? ApolloGQLRequestKindMoreComments : 0;
    }
    if (!get) return 0;
    if (ApolloGQLThreadID(segments)) return ApolloGQLRequestKindComments;
    if (segments.count == 2 && [segments[0] isEqualToString:@"api"] && [segments[1] isEqualToString:@"info"]) {
        return ApolloGQLRequestKindPostsInfo;
    }
    if ((segments.count == 2 || segments.count == 3) && [segments[0] isEqualToString:@"r"] && ApolloGQLSubredditIsPlain(segments[1])) {
        if (segments.count == 2 || ApolloGQLFeedSorts()[segments[2]]) return ApolloGQLRequestKindSubredditFeed;
        if ([segments[2] isEqualToString:@"about"]) return ApolloGQLRequestKindSubredditAbout;
    }
    // Popular has a feed query of its own. Its Hot and Rising gave the legacy
    // /r/popular's posts in the same order (2026-11-24).
    if ((segments.count == 2 || segments.count == 3) && [segments[0] isEqualToString:@"r"] && [segments[1] isEqualToString:@"popular"]) {
        if (segments.count == 2 || ApolloGQLFeedSorts()[segments[2]]) return ApolloGQLRequestKindPopularFeed;
    }
    // A search for posts, everywhere or in one subreddit.
    if (segments.count == 1 && [segments[0] isEqualToString:@"search"]) return ApolloGQLRequestKindSearchPosts;
    if (segments.count == 3 && [segments[0] isEqualToString:@"r"] && [segments[2] isEqualToString:@"search"] && ApolloGQLSubredditIsPlain(segments[1])) {
        return ApolloGQLRequestKindSearchPosts;
    }
    // The lists of a profile. A username is 3 to 20 letters, digits, "_" or
    // "-"; the sort is a parameter here, not part of the path.
    if (segments.count == 3 && [segments[0] isEqualToString:@"user"]) {
        NSCharacterSet *other = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet];
        if (segments[1].length >= 3 && segments[1].length <= 20 && [segments[1] rangeOfCharacterFromSet:other].location == NSNotFound) {
            if ([segments[2] isEqualToString:@"submitted"]) return ApolloGQLRequestKindUserPosts;
            if ([segments[2] isEqualToString:@"comments"]) return ApolloGQLRequestKindUserComments;
            if (ApolloGQLOwnLists()[segments[2]]) return ApolloGQLRequestKindOwnPosts;
        }
    }
    // Home is a sort on its own ("hot.json"); Apollo names one every time.
    if (segments.count == 1 && ApolloGQLHomeSortIsAnswered(segments[0])) return ApolloGQLRequestKindHomeFeed;
    return 0;
}

BOOL ApolloGQLCanAnswerPath(NSString *method, NSString *path) {
    return ApolloGQLKindForPath(method, path, YES, NULL, NULL) != 0;
}

ApolloGQLRequest *ApolloGQLRequestForLegacy(NSString *method, NSString *path, id parameters) {
    NSArray<NSString *> *segments = nil, *original = nil;
    ApolloGQLRequestKind kind = ApolloGQLKindForPath(method, path, NO, &segments, &original);
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

    if (kind == ApolloGQLRequestKindSearchPosts) {
        static NSDictionary<NSString *, NSString *> *sorts;
        static NSSet<NSString *> *ranges, *yes;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sorts = @{ @"relevance": @"RELEVANCE", @"hot": @"HOT", @"top": @"TOP", @"new": @"NEW", @"comments": @"COMMENTS" };
            ranges = [NSSet setWithArray:@[ @"hour", @"day", @"week", @"month", @"year" ]];
            yes = [NSSet setWithArray:@[ @"1", @"true", @"on", @"yes" ]];
        });
        // Posts only: the legacy search also finds subreddits and people
        // (type=sr, type=user), which are other queries.
        NSString *type = query[@"type"].lowercaseString;
        if (type.length > 0 && ![type isEqualToString:@"link"]) return nil;
        NSString *text = [query[@"q"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *sort = query[@"sort"].length > 0 ? sorts[query[@"sort"].lowercaseString] : @"RELEVANCE";
        if (text.length == 0 || !sort || query[@"before"].length > 0) return nil;
        // A later page is ours only when the page before it was: its `after`
        // is then the cursor GraphQL gave, not a post's fullname.
        NSString *after = query[@"after"];
        NSString *cursor = after.length > 0 ? ApolloGQLSearchAfterCursor(after) : nil;
        if (after.length > 0 && !cursor) return nil;
        // /r/<sub>/search looks through that subreddit when restrict_sr says
        // so; without it, it's a search of everything started from there.
        if (segments.count == 3 && [yes containsObject:query[@"restrict_sr"].lowercaseString ?: @""]) {
            text = [text stringByAppendingFormat:@" subreddit:%@", original.count > 1 ? original[1] : segments[1]];
        }
        NSString *range = query[@"t"].lowercaseString;
        request.searchQuery = text;
        request.searchSort = sort;
        request.searchRange = [ranges containsObject:range] ? range : nil;
        request.searchIncludesNSFW = [yes containsObject:query[@"include_over_18"].lowercaseString ?: @""];
        request.searchCursor = cursor;
        return request;
    }

    if (kind == ApolloGQLRequestKindSubredditAbout) {
        request.subreddit = original.count > 1 ? original[1] : segments[1];
        return request;
    }

    if (kind == ApolloGQLRequestKindOwnPosts) {
        // Newest first, the only order GraphQL has for these.
        NSString *sort = query[@"sort"].lowercaseString;
        NSString *after = query[@"after"];
        if (query[@"before"].length > 0 || (sort.length > 0 && ![sort isEqualToString:@"new"])) return nil;
        if (after.length > 0 && ![after hasPrefix:@"t3_"]) return nil;
        request.username = original.count > 1 ? original[1] : segments[1];
        request.ownList = segments[2];
        request.after = after.length > 0 ? after : nil;
        NSInteger limit = query[@"limit"].integerValue;
        request.limit = limit > 0 ? MIN(limit, 100) : 25;
        return request;
    }

    if (kind == ApolloGQLRequestKindUserComments) {
        static NSDictionary<NSString *, NSString *> *sorts;
        static NSSet<NSString *> *ranges;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sorts = @{ @"new": @"NEW", @"hot": @"HOT", @"top": @"TOP", @"controversial": @"CONTROVERSIAL" };
            ranges = [NSSet setWithArray:@[ @"hour", @"day", @"week", @"month", @"year", @"all" ]];
        });
        NSString *sort = query[@"sort"].length > 0 ? sorts[query[@"sort"].lowercaseString] : @"NEW";
        NSString *after = query[@"after"];
        if (!sort || query[@"before"].length > 0) return nil;
        if (after.length > 0 && ![after hasPrefix:@"t1_"]) return nil;
        request.username = original.count > 1 ? original[1] : segments[1];
        request.sort = sort;
        if ([sort isEqualToString:@"TOP"] || [sort isEqualToString:@"CONTROVERSIAL"]) {
            // All time is Reddit's own default on a profile.
            NSString *range = query[@"t"].lowercaseString;
            request.timeRange = [ranges containsObject:range] ? range.uppercaseString : @"ALL";
        }
        request.after = after.length > 0 ? after : nil;
        NSInteger limit = query[@"limit"].integerValue;
        request.limit = limit > 0 ? MIN(limit, 100) : 25;
        return request;
    }

    if (kind == ApolloGQLRequestKindComments) {
        // A thread opened at one comment (?comment=, ?context=) is the legacy
        // API's to answer, and so is a sort GraphQL doesn't have.
        if (query[@"comment"].length > 0 || query[@"context"].length > 0) return nil;
        NSString *sort = query[@"sort"].length > 0 ? ApolloGQLCommentSorts()[query[@"sort"].lowercaseString] : @"CONFIDENCE";
        if (!sort) return nil;
        request.linkFullname = [@"t3_" stringByAppendingString:ApolloGQLThreadID(segments)];
        request.commentSort = sort;
        request.limit = MAX(0, query[@"limit"].integerValue);
        return request;
    }

    if (kind == ApolloGQLRequestKindMoreComments) {
        // Only a row this route made: its one child id carries the cursor. A
        // thread the legacy API sent has real comment ids there.
        NSInteger depth = 0;
        NSString *cursor = ApolloGQLMoreTokenCursor(query[@"children"], &depth);
        NSString *link = query[@"link_id"];
        NSString *sort = query[@"sort"].length > 0 ? ApolloGQLCommentSorts()[query[@"sort"].lowercaseString] : @"CONFIDENCE";
        if (!cursor || !sort || ![link hasPrefix:@"t3_"] || !ApolloGQLIsID36([link substringFromIndex:3])) return nil;
        request.linkFullname = link;
        request.commentSort = sort;
        request.moreCursor = cursor;
        request.moreDepth = depth;
        return request;
    }

    // A feed page asked for backwards has no GraphQL form.
    if (query[@"before"].length > 0) return nil;
    NSString *after = query[@"after"];
    if (after.length > 0 && ![after hasPrefix:@"t3_"]) return nil;
    request.after = after.length > 0 ? after : nil;
    NSString *sort = nil;
    if (kind == ApolloGQLRequestKindUserPosts) {
        // Reddit's default for a profile is newest first. A profile has no
        // "best" or "rising".
        static NSDictionary<NSString *, NSString *> *sorts;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            sorts = @{ @"new": @"NEW", @"hot": @"HOT", @"top": @"TOP", @"controversial": @"CONTROVERSIAL" };
        });
        sort = query[@"sort"].length > 0 ? sorts[query[@"sort"].lowercaseString] : @"NEW";
        if (!sort) return nil;
        request.username = original.count > 1 ? original[1] : segments[1];
    } else if (kind == ApolloGQLRequestKindHomeFeed) {
        sort = ApolloGQLFeedSorts()[segments[0]];
    } else if (kind == ApolloGQLRequestKindPopularFeed) {
        // Popular for one country is the legacy API's to answer.
        NSString *region = query[@"geo_filter"].uppercaseString;
        if (region.length > 0 && ![region isEqualToString:@"GLOBAL"]) return nil;
        sort = segments.count == 3 ? ApolloGQLFeedSorts()[segments[2]] : @"HOT";
    } else {
        request.subreddit = original.count > 1 ? original[1] : segments[1];
        sort = segments.count == 3 ? ApolloGQLFeedSorts()[segments[2]] : @"HOT";
    }
    request.sort = sort;
    if ([sort isEqualToString:@"TOP"] || [sort isEqualToString:@"CONTROVERSIAL"]) {
        static NSSet<NSString *> *ranges;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            ranges = [NSSet setWithArray:@[ @"hour", @"day", @"week", @"month", @"year", @"all" ]];
        });
        NSString *range = query[@"t"].lowercaseString;
        // Reddit's own default for these sorts is the last day, and all time
        // on a profile.
        NSString *fallback = kind == ApolloGQLRequestKindUserPosts ? @"ALL" : @"DAY";
        request.timeRange = [ranges containsObject:range] ? range.uppercaseString : fallback;
    }
    NSInteger limit = query[@"limit"].integerValue;
    request.limit = limit > 0 ? MIN(limit, 100) : 25;
    return request;
}
