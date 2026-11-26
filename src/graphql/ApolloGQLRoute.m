#import "ApolloGQLRoute.h"
#import "ApolloGQLLegacy.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Defaults.h"
#import "ApolloUserProfileCache.h"
#import "ApolloWebJSON.h"
#import "ApolloWebJSONRoutes.h"
#import "ApolloWebSessionStore.h"
#import "UserDefaultConstants.h"
#import <stdatomic.h>

static NSString *const kApolloGQLEndpoint = @"https://gql-fed.reddit.com/";
// A feed page is at most this many id calls. GraphQL pages aren't the size
// Apollo asks for: a subreddit's first page gives 6 posts and every later one
// 24 (Home: 7 and 25). So a page is done once it has three quarters of what
// was asked (one call for a later page of 25, two for a first page), rather
// than paying a whole extra call for the one post a page of 24 is short. Home
// can need the rest: the posts Reddit suggests from subreddits the account
// hasn't joined are left out of each page it gives.
static const NSUInteger kApolloGQLFeedCallsPerPage = 4;
static const NSTimeInterval kApolloGQLCallTimeout = 20.0;

typedef NS_ENUM(NSInteger, ApolloGQLCallOutcome) {
    ApolloGQLCallAnswered = 0,
    ApolloGQLCallRefused,      // Reddit turned the route down
    ApolloGQLCallRateLimited,  // HTTP 429
    ApolloGQLCallFailed,       // network error, timeout, unreadable answer
};

#if APOLLO_SIM_BUILD
static _Atomic BOOL sApolloGQLSimBlocked = NO;

void ApolloGQLRouteSimSetBlocked(BOOL blocked) {
    atomic_store(&sApolloGQLSimBlocked, blocked);
    ApolloLog(@"[GraphQL] Sim: calls are %@", blocked ? @"sent with an unknown hash" : @"sent normally");
}
#endif

#pragma mark - Rate limit hold

// After a 429, the account's requests keep to their other routes until
// GraphQL's window resets. Lowercased username -> reference-date seconds.
static NSMutableDictionary<NSString *, NSNumber *> *sApolloGQLHeldUntil;

static NSObject *ApolloGQLHoldLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static void ApolloGQLHoldAccount(NSString *account, NSTimeInterval seconds) {
    NSString *key = account.lowercaseString;
    if (key.length == 0) return;
    @synchronized (ApolloGQLHoldLock()) {
        if (!sApolloGQLHeldUntil) sApolloGQLHeldUntil = [NSMutableDictionary dictionary];
        sApolloGQLHeldUntil[key] = @([NSDate timeIntervalSinceReferenceDate] + seconds);
    }
}

static BOOL ApolloGQLAccountHeld(NSString *account) {
    NSString *key = account.lowercaseString;
    @synchronized (ApolloGQLHoldLock()) {
        return [sApolloGQLHeldUntil[key] doubleValue] > [NSDate timeIntervalSinceReferenceDate];
    }
}

// Seconds until `account` is back on GraphQL after a 429, or 0.
static NSTimeInterval ApolloGQLAccountHoldRemaining(NSString *account) {
    NSString *key = account.lowercaseString;
    @synchronized (ApolloGQLHoldLock()) {
        return MAX(0, [sApolloGQLHeldUntil[key] doubleValue] - [NSDate timeIntervalSinceReferenceDate]);
    }
}

void ApolloGQLRouteSetEnabled(BOOL enabled) {
    sWebJSONGraphQLEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UDKeyWebJSONGraphQLEnabled];
    ApolloLog(@"[GraphQL] Route turned %@ in Settings", enabled ? @"on" : @"off");
}

NSDictionary<NSString *, id> *ApolloGQLRouteStatus(NSString *account) {
    NSString *state = @"On";
    NSTimeInterval held = account.length > 0 ? ApolloGQLAccountHoldRemaining(account) : 0;
    if (!sWebJSONGraphQLEnabled) {
        state = @"Off";
    } else if (ApolloWebJSONRouteRemoteGraphQLOff()) {
        state = @"Switched off by keyless-routes.json";
    } else if (held > 0) {
        state = [NSString stringWithFormat:@"Paused for %.0f more min (Reddit's rate limit)", ceil(held / 60.0)];
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (account.length > 0) {
        for (NSDictionary *row in ApolloWebJSONRouteHealthSnapshot(account, [NSDate timeIntervalSinceReferenceDate])) {
            if ([row[@"route"] integerValue] != ApolloWebJSONRouteGraphQL) continue;
            NSTimeInterval cooling = [row[@"cooldownRemaining"] doubleValue];
            [lines addObject:[NSString stringWithFormat:@"%@: %@ ok, %@ refused%@", row[@"pattern"], row[@"ok"], row[@"blocked"],
                              cooling > 0 ? [NSString stringWithFormat:@", skipped for %.0f more min", ceil(cooling / 60.0)] : @""]];
        }
    }
    return @{ @"state": state, @"lines": lines };
}

BOOL ApolloGQLRouteAvailable(NSString *account) {
    if (!sWebJSONEnabled || !sWebJSONGraphQLEnabled || account.length == 0) return NO;
    if (ApolloWebSessionFor(account).cookieHeader.length == 0) return NO;
    return !ApolloGQLAccountHeld(account);
}

// The route table asks this for every request it lists routes for.
__attribute__((constructor)) static void ApolloGQLRouteRegister(void) {
    ApolloWebJSONRouteSetGraphQLHandler(^BOOL(NSString *account, NSString *method, NSString *path) {
        if (!sWebJSONEnabled || !sWebJSONGraphQLEnabled) return NO;
        if (!ApolloGQLCanAnswerPath(method, path)) return NO;
        return account == nil || ApolloGQLRouteAvailable(account);
    });
}

#pragma mark - One call

// Every post and comment in an answer comes with its author's picture. Handing
// those to the avatar cache here means a feed or thread this route loaded asks
// Reddit for no avatars afterwards. Those lookups (one request per 100 comment
// authors, and one per feed author without Reduce Rate Limiting) go out on the
// cookie's budget, the one this route exists to stay off.
static void ApolloGQLRouteNoteAuthors(NSDictionary *answer) {
    if (!sShowUserAvatars) return;
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *authors = ApolloGQLLegacyAuthorRecords(answer);
    if (authors.count > 0) [[ApolloUserProfileCache sharedCache] ingestGraphQLAuthorRecords:authors];
}

// Sends one operation and waits for its answer. Background queues only.
static NSDictionary *ApolloGQLRouteCall(NSString *account, NSString *operation, NSDictionary *variables,
                                        ApolloGQLCallOutcome *outcome, NSString **detail) {
    *outcome = ApolloGQLCallFailed;
    NSData *body = ApolloGQLOperationBody(operation, variables);
    if (!body) { *detail = [NSString stringWithFormat:@"%@ isn't a known operation", operation]; return nil; }
#if APOLLO_SIM_BUILD
    if (atomic_load(&sApolloGQLSimBlocked)) {
        NSDictionary *blocked = @{ @"operationName": operation, @"variables": variables,
                                   @"extensions": @{ @"persistedQuery": @{ @"version": @1,
                                       @"sha256Hash": [@"" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0] } } };
        body = [NSJSONSerialization dataWithJSONObject:blocked options:0 error:NULL];
    }
#endif
    NSString *bearer = ApolloWebJSONDesktopWebBearer(account);
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        if (bearer.length == 0) { *detail = @"no web token for the account"; return nil; }
        // The probe mark keeps the transport hooks off this request (no
        // rewrite, no bearer capture); it never reaches the wire.
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ApolloWebJSONProbeURL([NSURL URLWithString:kApolloGQLEndpoint])];
        request.HTTPMethod = @"POST";
        request.HTTPBody = body;
        request.timeoutInterval = kApolloGQLCallTimeout;
        request.HTTPShouldHandleCookies = NO;
        [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [request setValue:defaultUserAgent forHTTPHeaderField:@"User-Agent"];

        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSData *data = nil;
        __block NSHTTPURLResponse *http = nil;
        __block NSError *error = nil;
        [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                         completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *responseError) {
            data = responseData;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) http = (NSHTTPURLResponse *)response;
            error = responseError;
            dispatch_semaphore_signal(done);
        }] resume];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kApolloGQLCallTimeout + 5.0) * NSEC_PER_SEC))) != 0) {
            *detail = [operation stringByAppendingString:@" timed out"];
            return nil;
        }
        if (error || !http) {
            *detail = [NSString stringWithFormat:@"%@ failed (%@ %ld)", operation, error.domain ?: @"no response", (long)error.code];
            return nil;
        }
        NSInteger status = http.statusCode;
        NSString *contentType = [[http valueForHTTPHeaderField:@"Content-Type"] lowercaseString] ?: @"";
        os_log_debug(ApolloFixLog(), "[ApolloFix] [GraphQL] %{public}@ -> HTTP %ld, %lu bytes, budget used %{public}@ left %{public}@ reset %{public}@s",
                     operation, (long)status, (unsigned long)data.length,
                     [http valueForHTTPHeaderField:@"x-ratelimit-used"] ?: @"-",
                     [http valueForHTTPHeaderField:@"x-ratelimit-remaining"] ?: @"-",
                     [http valueForHTTPHeaderField:@"x-ratelimit-reset"] ?: @"-");
        if (status == 429) {
            double reset = [[http valueForHTTPHeaderField:@"x-ratelimit-reset"] doubleValue];
            NSTimeInterval hold = reset > 0 ? MIN(reset, 600.0) : 60.0;
            ApolloGQLHoldAccount(account, hold);
            *outcome = ApolloGQLCallRateLimited;
            *detail = [NSString stringWithFormat:@"%@ was rate-limited (HTTP 429); GraphQL is off for u/%@ for %.0f s", operation, account, hold];
            return nil;
        }
        BOOL blockPage = status == 403 && [contentType containsString:@"text/html"];
        if (status == 401 || (status == 403 && !blockPage)) {
            // The token: drop it and try once more with a fresh one.
            ApolloWebJSONInvalidateDesktopWebBearer(account, bearer);
            if (attempt == 0) {
                bearer = ApolloWebJSONDesktopWebBearer(account);
                continue;
            }
            *outcome = ApolloGQLCallRefused;
            *detail = [NSString stringWithFormat:@"%@ refused the account's web token twice (HTTP %ld)", operation, (long)status];
            return nil;
        }
        if (blockPage) {
            *outcome = ApolloGQLCallRefused;
            *detail = [operation stringByAppendingString:@" got Reddit's block page"];
            return nil;
        }
        if (status < 200 || status >= 300) {
            *detail = [NSString stringWithFormat:@"%@ answered HTTP %ld", operation, (long)status];
            return nil;
        }
        id answer = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![answer isKindOfClass:[NSDictionary class]]) {
            *detail = [operation stringByAppendingString:@" answered something that isn't JSON"];
            return nil;
        }
        NSString *message = ApolloGQLAnswerErrorMessage(answer);
        id payload = ((NSDictionary *)answer)[@"data"];
        if (message && ![payload isKindOfClass:[NSDictionary class]]) {
            // "persisted query not found" for a hash Reddit retired, and the like.
            *outcome = ApolloGQLCallRefused;
            *detail = [NSString stringWithFormat:@"%@ answered an error: %@", operation, message];
            return nil;
        }
        *outcome = ApolloGQLCallAnswered;
        ApolloGQLRouteNoteAuthors(answer);
        return answer;
    }
    return nil;
}

#pragma mark - Requests

// The posts for `fullnames` as t3 things, in order, or nil when a call failed.
static NSArray<NSDictionary *> *ApolloGQLRoutePosts(NSString *account, NSArray<NSString *> *fullnames, BOOL rawJSON,
                                                    NSUInteger *calls, ApolloGQLCallOutcome *outcome, NSString **detail) {
    NSMutableArray<NSDictionary *> *things = [NSMutableArray array];
    for (NSUInteger start = 0; start < fullnames.count; start += ApolloGQLPostsByIdsBatch) {
        NSArray<NSString *> *batch = [fullnames subarrayWithRange:NSMakeRange(start, MIN(ApolloGQLPostsByIdsBatch, fullnames.count - start))];
        (*calls)++;
        NSDictionary *answer = ApolloGQLRouteCall(account, ApolloGQLOperationPostsByIds, ApolloGQLPostsByIdsVariables(batch), outcome, detail);
        if (!answer) return nil;
        NSArray<NSDictionary *> *page = ApolloGQLLegacyLinksFromPostsByIds(answer, batch, rawJSON);
        if (!page) {
            *outcome = ApolloGQLCallFailed;
            *detail = @"PostsByIds answered without its posts";
            return nil;
        }
        [things addObjectsFromArray:page];
    }
    return things;
}

// How many comments a list of comment things holds, replies included.
static NSUInteger ApolloGQLRouteCommentCount(NSArray *things) {
    NSUInteger count = 0;
    for (id thing in things) {
        if (![thing isKindOfClass:[NSDictionary class]] || ![thing[@"kind"] isEqual:@"t1"]) continue;
        count++;
        id replies = thing[@"data"][@"replies"];
        if ([replies isKindOfClass:[NSDictionary class]]) count += ApolloGQLRouteCommentCount(replies[@"data"][@"children"]);
    }
    return count;
}

// The body of /comments/<id>.json: the thread from PostComments and the post
// from PostsByIds (PostComments only names the post), asked for side by side.
static id ApolloGQLRouteCommentsPage(NSString *account, ApolloGQLRequest *request, NSUInteger *calls,
                                     ApolloGQLCallOutcome *outcome, NSString **detail, NSString **summary) {
    __block NSDictionary *thread = nil;
    __block NSArray<NSDictionary *> *posts = nil;
    __block ApolloGQLCallOutcome threadOutcome = ApolloGQLCallFailed, postOutcome = ApolloGQLCallFailed;
    __block NSString *threadDetail = nil, *postDetail = nil;
    __block NSUInteger postCalls = 0;
    dispatch_group_t both = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_async(both, queue, ^{
        thread = ApolloGQLRouteCall(account, ApolloGQLOperationPostComments, ApolloGQLPostCommentsVariables(request),
                                    &threadOutcome, &threadDetail);
    });
    dispatch_group_async(both, queue, ^{
        posts = ApolloGQLRoutePosts(account, @[ request.linkFullname ], request.rawJSON, &postCalls, &postOutcome, &postDetail);
    });
    dispatch_group_wait(both, DISPATCH_TIME_FOREVER);  // each call has its own timeout
    *calls += 1 + postCalls;
    if (!thread) { *outcome = threadOutcome; *detail = threadDetail; return nil; }
    if (!posts) { *outcome = postOutcome; *detail = postDetail; return nil; }
    // No post, or no comment list, is how GraphQL reports a thread it won't
    // show (removed subreddit, private, missing). The legacy route has the
    // error Apollo knows how to present.
    NSArray *page = posts.count == 1 ? ApolloGQLLegacyCommentsPage(thread, posts[0], request.rawJSON) : nil;
    if (!page) {
        *outcome = ApolloGQLCallFailed;
        *detail = posts.count == 1 ? @"PostComments answered without a thread" : @"PostsByIds didn't have the thread's post";
        return nil;
    }
    *summary = [NSString stringWithFormat:@"a thread of %lu comments",
                (unsigned long)ApolloGQLRouteCommentCount(page[1][@"data"][@"children"])];
    return page;
}

// The body of /api/morechildren for one of this route's "load more" rows.
static id ApolloGQLRouteMoreComments(NSString *account, ApolloGQLRequest *request, NSUInteger *calls,
                                     ApolloGQLCallOutcome *outcome, NSString **detail, NSString **summary) {
    (*calls)++;
    NSDictionary *answer = ApolloGQLRouteCall(account, ApolloGQLOperationPostComments, ApolloGQLPostCommentsVariables(request),
                                              outcome, detail);
    if (!answer) return nil;
    NSDictionary *body = ApolloGQLLegacyMoreChildren(answer, request.moreDepth, request.rawJSON);
    if (!body) {
        *outcome = ApolloGQLCallFailed;
        *detail = @"PostComments answered without the replies";
        return nil;
    }
    *summary = [NSString stringWithFormat:@"%lu more comments",
                (unsigned long)ApolloGQLRouteCommentCount(body[@"json"][@"data"][@"things"])];
    return body;
}

// The body of /user/<name>/saved.json: the list's ids from SavedPostsFeedSdui
// (posts and comments together), the comments from LiveCommentsByIds, then
// every post involved from PostsByIds: the saved ones, and the ones the saved
// comments are on, which is where a comment's post title comes from.
static id ApolloGQLRouteSavedPage(NSString *account, ApolloGQLRequest *request, NSUInteger *calls,
                                  ApolloGQLCallOutcome *outcome, NSString **detail, NSString **summary) {
    NSMutableArray<NSString *> *fullnames = [NSMutableArray array];
    NSString *after = request.after;
    BOOL more = NO;
    for (NSUInteger page = 0; page < kApolloGQLFeedCallsPerPage; page++) {
        (*calls)++;
        NSDictionary *answer = ApolloGQLRouteCall(account, ApolloGQLOperationSaved, ApolloGQLSavedVariables(after), outcome, detail);
        if (!answer) return nil;
        NSArray<NSString *> *ids = ApolloGQLSavedFullnames(answer, &more);
        if (!ids) {
            // No list (GraphQL's own error for it), or rows that aren't posts
            // or comments by their ids: the legacy route has the list.
            *outcome = ApolloGQLCallFailed;
            *detail = @"SavedPostsFeedSdui answered without a list this route reads";
            return nil;
        }
        NSUInteger had = fullnames.count;
        for (NSString *fullname in ids) {
            if (![fullnames containsObject:fullname]) [fullnames addObject:fullname];
        }
        // A page that brought nothing new has nothing to page on from.
        if (fullnames.count == had) more = NO;
        if (!more || (NSInteger)fullnames.count >= request.limit) break;
        after = fullnames.lastObject;
    }
    // The page Apollo asked for, no longer: the next one starts after its last
    // row, whichever page of GraphQL's that row came on.
    if ((NSInteger)fullnames.count > request.limit) {
        [fullnames removeObjectsInRange:NSMakeRange(request.limit, fullnames.count - request.limit)];
        more = YES;
    }

    NSMutableArray<NSString *> *postIDs = [NSMutableArray array], *commentIDs = [NSMutableArray array];
    for (NSString *fullname in fullnames) [[fullname hasPrefix:@"t1_"] ? commentIDs : postIDs addObject:fullname];
    NSMutableArray<NSDictionary *> *commentAnswers = [NSMutableArray array], *postAnswers = [NSMutableArray array];
    for (NSUInteger start = 0; start < commentIDs.count; start += ApolloGQLCommentsByIdsBatch) {
        NSArray<NSString *> *batch = [commentIDs subarrayWithRange:NSMakeRange(start, MIN(ApolloGQLCommentsByIdsBatch, commentIDs.count - start))];
        (*calls)++;
        NSDictionary *answer = ApolloGQLRouteCall(account, ApolloGQLOperationCommentsByIds, ApolloGQLCommentsByIdsVariables(batch), outcome, detail);
        if (!answer) return nil;
        [commentAnswers addObject:answer];
    }
    for (NSString *fullname in ApolloGQLCommentPostFullnames(commentAnswers)) {
        if (![postIDs containsObject:fullname]) [postIDs addObject:fullname];
    }
    for (NSUInteger start = 0; start < postIDs.count; start += ApolloGQLPostsByIdsBatch) {
        NSArray<NSString *> *batch = [postIDs subarrayWithRange:NSMakeRange(start, MIN(ApolloGQLPostsByIdsBatch, postIDs.count - start))];
        (*calls)++;
        NSDictionary *answer = ApolloGQLRouteCall(account, ApolloGQLOperationPostsByIds, ApolloGQLPostsByIdsVariables(batch), outcome, detail);
        if (!answer) return nil;
        [postAnswers addObject:answer];
    }
    NSDictionary *listing = ApolloGQLLegacySavedListing(fullnames, postAnswers, commentAnswers, more ? fullnames.lastObject : nil,
                                                        request.rawJSON);
    // A saved post or comment the lookups came back without (Reddit's legacy
    // list still shows one that was deleted since): the legacy route has the
    // whole page, where this one would have a row missing.
    if (!listing) {
        *outcome = ApolloGQLCallFailed;
        *detail = @"the lookups didn't have every saved post and comment";
        return nil;
    }
    NSUInteger shown = [listing[@"data"][@"children"] count];
    *summary = [NSString stringWithFormat:@"%lu saved posts and comments%@", (unsigned long)shown, more ? @", more after them" : @""];
    return listing;
}

void ApolloGQLRouteAnswer(NSString *account, ApolloGQLRequest *request, ApolloGQLRouteCompletion completion) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ApolloGQLCallOutcome outcome = ApolloGQLCallFailed;
        NSString *detail = nil;
        NSUInteger calls = 0;
        NSArray<NSDictionary *> *things = nil;
        NSString *nextAfter = nil;
        // The legacy body for the kinds that aren't a Listing of posts.
        id body = nil;
        NSString *summary = nil;

        if (request.kind == ApolloGQLRequestKindSearchPosts) {
            calls++;
            NSDictionary *answer = ApolloGQLRouteCall(account, ApolloGQLOperationSearchPosts, ApolloGQLSearchPostsVariables(request),
                                                      &outcome, &detail);
            body = answer ? ApolloGQLLegacySearchListing(answer, request.rawJSON) : nil;
            if (answer && !body) { outcome = ApolloGQLCallFailed; detail = @"SearchPosts answered without results"; }
            summary = [NSString stringWithFormat:@"%lu search results", (unsigned long)[body[@"data"][@"children"] count]];
        } else if (request.kind == ApolloGQLRequestKindSubredditAbout) {
            calls++;
            NSDictionary *answer = ApolloGQLRouteCall(account, ApolloGQLOperationSubredditInfo, ApolloGQLSubredditInfoVariables(request),
                                                      &outcome, &detail);
            body = answer ? ApolloGQLLegacySubredditAbout(answer, request.rawJSON) : nil;
            // No subreddit in the answer is how GraphQL reports one it won't
            // show (missing, banned, private). The legacy route has the error
            // Apollo knows how to present.
            if (answer && !body) { outcome = ApolloGQLCallFailed; detail = @"SubredditInfoByName answered without a subreddit"; }
            summary = [NSString stringWithFormat:@"r/%@'s details", request.subreddit];
        } else if (request.kind == ApolloGQLRequestKindOwnPosts) {
            // GraphQL has these lists for the account that asks and nobody
            // else's; the legacy route answers for another account (usually
            // that the list is private).
            if (!ApolloGQLRequestIsForAccount(request, account)) {
                detail = [NSString stringWithFormat:@"the %@ list isn't the account's own", request.ownList];
            } else {
                calls++;
                NSString *operation = ApolloGQLOwnPostsOperation(request);
                NSDictionary *answer = ApolloGQLRouteCall(account, operation, ApolloGQLOwnPostsVariables(request), &outcome, &detail);
                body = answer ? ApolloGQLLegacyOwnPostsListing(answer, request.ownList, request.rawJSON) : nil;
                if (answer && !body) { outcome = ApolloGQLCallFailed; detail = [operation stringByAppendingString:@" answered without a list"]; }
                summary = [NSString stringWithFormat:@"%lu %@ posts", (unsigned long)[body[@"data"][@"children"] count], request.ownList];
            }
        } else if (request.kind == ApolloGQLRequestKindOwnSaved) {
            // As above: the list is the asking account's and nobody else's.
            if (!ApolloGQLRequestIsForAccount(request, account)) {
                detail = @"the saved list isn't the account's own";
            } else {
                body = ApolloGQLRouteSavedPage(account, request, &calls, &outcome, &detail, &summary);
            }
        } else if (request.kind == ApolloGQLRequestKindUserComments) {
            calls++;
            NSDictionary *list = ApolloGQLRouteCall(account, ApolloGQLOperationUserComments, ApolloGQLUserCommentsVariables(request),
                                                    &outcome, &detail);
            NSArray<NSString *> *fullnames = list ? ApolloGQLUserCommentFullnames(list, NULL) : nil;
            if (list && !fullnames) {
                // No comment list is how GraphQL reports an account it won't
                // show (missing, suspended). The legacy route has the error
                // Apollo knows how to present.
                outcome = ApolloGQLCallFailed;
                detail = @"SubmittedComments answered without a comment list";
            } else if (fullnames.count == 0) {
                // Nothing on the page (the account hides its history, or the
                // list has ended): there's nothing to ask LiveCommentsByIds for.
                if (list) body = ApolloGQLLegacyUserCommentsListing(list, @{}, request.rawJSON);
            } else {
                calls++;
                NSDictionary *comments = ApolloGQLRouteCall(account, ApolloGQLOperationCommentsByIds,
                                                            ApolloGQLCommentsByIdsVariables(fullnames), &outcome, &detail);
                body = comments ? ApolloGQLLegacyUserCommentsListing(list, comments, request.rawJSON) : nil;
                // Ids without a single comment behind them isn't a page to show.
                if (comments && [body[@"data"][@"children"] count] == 0) {
                    body = nil;
                    outcome = ApolloGQLCallFailed;
                    detail = @"LiveCommentsByIds had none of the profile's comments";
                }
            }
            summary = [NSString stringWithFormat:@"%lu comments", (unsigned long)[body[@"data"][@"children"] count]];
        } else if (request.kind == ApolloGQLRequestKindComments) {
            body = ApolloGQLRouteCommentsPage(account, request, &calls, &outcome, &detail, &summary);
        } else if (request.kind == ApolloGQLRequestKindMoreComments) {
            body = ApolloGQLRouteMoreComments(account, request, &calls, &outcome, &detail, &summary);
        } else if (request.kind == ApolloGQLRequestKindPostsInfo) {
            things = ApolloGQLRoutePosts(account, request.fullnames, request.rawJSON, &calls, &outcome, &detail);
        } else if (request.kind == ApolloGQLRequestKindSubredditFeed || request.kind == ApolloGQLRequestKindHomeFeed ||
                   request.kind == ApolloGQLRequestKindPopularFeed || request.kind == ApolloGQLRequestKindUserPosts) {
            BOOL home = request.kind == ApolloGQLRequestKindHomeFeed;
            NSString *operation = ApolloGQLFeedOperation(request);
            NSMutableArray<NSString *> *fullnames = [NSMutableArray array];
            NSString *after = request.after;
            BOOL failed = NO;
            for (NSUInteger page = 0; page < kApolloGQLFeedCallsPerPage; page++) {
                calls++;
                NSDictionary *answer = ApolloGQLRouteCall(account, operation, ApolloGQLFeedVariables(request, after), &outcome, &detail);
                NSString *next = nil;
                NSArray<NSString *> *ids = answer ? ApolloGQLFeedPostFullnames(answer, home, &next) : nil;
                if (!ids) {
                    // No feed in the answer is how GraphQL reports a subreddit
                    // it won't show (private, banned, missing). The legacy
                    // route has the error Apollo knows how to present.
                    if (answer) { outcome = ApolloGQLCallFailed; detail = [operation stringByAppendingString:@" answered without a feed"]; }
                    failed = YES;
                    break;
                }
                for (NSString *fullname in ids) {
                    if (![fullnames containsObject:fullname]) [fullnames addObject:fullname];
                }
                nextAfter = next;
                if (!next || (NSInteger)fullnames.count * 4 >= request.limit * 3) break;
                after = next;
            }
            // Pages of nothing but suggested posts, with more behind them: the
            // legacy Home has the joined subreddits' posts without the search.
            if (!failed && home && fullnames.count == 0 && nextAfter) {
                failed = YES;
                outcome = ApolloGQLCallFailed;
                detail = [NSString stringWithFormat:@"Home had only suggested posts in %lu pages", (unsigned long)calls];
            }
            if (!failed) {
                things = fullnames.count > 0
                    ? ApolloGQLRoutePosts(account, fullnames, request.rawJSON, &calls, &outcome, &detail) : @[];
                // Ids without a single post behind them isn't a page to show.
                if (things && fullnames.count > 0 && things.count == 0) {
                    things = nil;
                    outcome = ApolloGQLCallFailed;
                    detail = @"PostsByIds had none of the feed's posts";
                }
            }
        }

        if (things) {
            body = ApolloGQLLegacyListing(things, nextAfter);
            summary = [NSString stringWithFormat:@"%lu posts", (unsigned long)things.count];
        }
        NSData *json = nil;
        if (body) {
            json = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
            if (!json) detail = @"the answer couldn't be written as JSON";
        }
        if (json) {
            completion(json, NO, [NSString stringWithFormat:@"%@ in %lu GraphQL call%@",
                                  summary, (unsigned long)calls, calls == 1 ? @"" : @"s"]);
        } else {
            completion(nil, outcome == ApolloGQLCallRefused, detail ?: @"no answer");
        }
    });
}

#pragma mark - The tweak's own reads

// The GraphQL request that answers `request`, and the account it's for; nil
// when the request goes the usual way.
static ApolloGQLRequest *ApolloGQLRoutePlanForRequest(NSURLRequest *request, NSString **accountOut) {
    if (!sWebJSONEnabled || !sWebJSONGraphQLEnabled) return nil;
    NSURL *url = request.URL;
    NSString *host = url.host.lowercaseString;
    if (![host isEqualToString:@"oauth.reddit.com"] && ![host isEqualToString:@"www.reddit.com"]) return nil;
    if (request.HTTPMethod.length > 0 && ![request.HTTPMethod.uppercaseString isEqualToString:@"GET"]) return nil;
    // Whose read it is, by the rule the request rewrite goes by
    // (ApolloWebJSONWebSessionUsernameForBearer): an API key's token keeps the
    // read on oauth.reddit.com with that key.
    NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
    NSString *bearer = nil;
    NSRange prefix = authorization ? [authorization rangeOfString:@"Bearer " options:NSCaseInsensitiveSearch | NSAnchoredSearch]
                                   : NSMakeRange(NSNotFound, 0);
    if (prefix.location != NSNotFound) {
        bearer = [[authorization substringFromIndex:NSMaxRange(prefix)]
                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSString *account = ApolloWebJSONWebSessionUsernameForBearer(bearer);
    if (account.length == 0) return nil;
    NSString *path = url.path.length > 0 ? url.path : @"/";
    // The route table decides, as it does for Apollo's requests: GraphQL is
    // passed by while it's on cooldown for this kind of read, held after a
    // rate limit, or switched off by keyless-routes.json.
    if (ApolloWebJSONRouteChoose(account, @"GET", path, 0, [NSDate timeIntervalSinceReferenceDate]) != ApolloWebJSONRouteGraphQL) return nil;
    NSString *query = url.query;
    ApolloGQLRequest *planned = ApolloGQLRequestForLegacy(@"GET", query.length > 0 ? [NSString stringWithFormat:@"%@?%@", path, query] : path, nil);
    if (planned && !ApolloGQLRequestIsForAccount(planned, account)) planned = nil;
    if (planned && accountOut) *accountOut = account;
    return planned;
}

BOOL ApolloGQLRouteAnswersRequest(NSURLRequest *request) {
    return ApolloGQLRoutePlanForRequest(request, NULL) != nil;
}

void ApolloGQLRouteSendRead(NSURLRequest *request, NSURLSession *session,
                            void (^completion)(NSData *data, NSURLResponse *response, NSError *error)) {
    NSString *account = nil;
    ApolloGQLRequest *planned = ApolloGQLRoutePlanForRequest(request, &account);
    if (!planned) {
        [[session dataTaskWithRequest:request completionHandler:completion] resume];
        return;
    }
    NSString *path = request.URL.path.length > 0 ? request.URL.path : @"/";
    NSDate *started = [NSDate date];
    ApolloGQLRouteAnswer(account, planned, ^(NSData *legacyJSON, BOOL refused, NSString *summary) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (legacyJSON) {
            ApolloWebJSONRouteHealthNoteSuccess(account, @"GET", path, ApolloWebJSONRouteGraphQL, now);
            os_log_debug(ApolloFixLog(), "[ApolloFix] [GraphQL] The tweak's GET %{public}@ answered by GraphQL: %{public}@, %.0f ms",
                         path, summary, -[started timeIntervalSinceNow] * 1000.0);
            completion(legacyJSON,
                       [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                 headerFields:@{ @"Content-Type": @"application/json; charset=UTF-8" }],
                       nil);
            return;
        }
        if (refused && ApolloWebJSONRouteHealthNoteBlockPage(account, @"GET", path, ApolloWebJSONRouteGraphQL, now)) {
            ApolloLog(@"[GraphQL] Route graphql is on cooldown for GET %@", ApolloWebJSONRouteHealthGroup(@"GET", path));
        }
        // The usual way is the cookie's, and while Reddit is refusing the
        // account there (HTTP 429 until its window resets) one more request
        // only gets one more refusal.
        if (ApolloWebJSONOptionalReadBackoff(account) > 0) {
            completion(nil, nil, [NSError errorWithDomain:@"ApolloGQLRoute" code:429 userInfo:@{
                NSLocalizedDescriptionKey: @"GraphQL had no answer and Reddit is rate-limiting the account's other routes" }]);
            return;
        }
        ApolloLog(@"[GraphQL] The tweak's GET %@ goes by its other routes: %@", ApolloWebJSONRouteHealthGroup(@"GET", path), summary);
        [[session dataTaskWithRequest:request completionHandler:completion] resume];
    });
}
