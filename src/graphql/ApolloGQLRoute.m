#import "ApolloGQLRoute.h"
#import "ApolloGQLLegacy.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Defaults.h"
#import "ApolloWebJSON.h"
#import "ApolloWebJSONRoutes.h"
#import "ApolloWebSessionStore.h"
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

        if (request.kind == ApolloGQLRequestKindComments) {
            body = ApolloGQLRouteCommentsPage(account, request, &calls, &outcome, &detail, &summary);
        } else if (request.kind == ApolloGQLRequestKindMoreComments) {
            body = ApolloGQLRouteMoreComments(account, request, &calls, &outcome, &detail, &summary);
        } else if (request.kind == ApolloGQLRequestKindPostsInfo) {
            things = ApolloGQLRoutePosts(account, request.fullnames, request.rawJSON, &calls, &outcome, &detail);
        } else if (request.kind == ApolloGQLRequestKindSubredditFeed || request.kind == ApolloGQLRequestKindHomeFeed) {
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
