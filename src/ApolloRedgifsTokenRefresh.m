// ApolloRedgifsTokenRefresh.m — see ApolloRedgifsTokenRefresh.h.

#import "ApolloRedgifsTokenRefresh.h"
#import "ApolloCommon.h"
#import <os/lock.h>

static NSString *const kApolloRedgifsTokenURL = @"https://api.redgifs.com/v2/auth/temporary";
static const NSUInteger kApolloRedgifsIssuedTokenCap = 8;

// Everything below is touched from Texture's node-allocation threads (Apollo
// creates RedGIFs requests from cell node blocks) and from the RedGIFs
// session's delegate queue (completions), so it all sits behind one lock.
// Nothing is called out to while it is held.
static os_unfair_lock sRGLock = OS_UNFAIR_LOCK_INIT;
// Tokens the /v2/oauth/client rewrite has handed Apollo, newest last. A cold
// feed makes Apollo start one token request per RedGIFs cell at once, so the
// token it ends up keeping isn't necessarily the last one seen here.
static NSMutableOrderedSet<NSString *> *sRGIssuedTokens;
// Minted here after RedGIFs rejected Apollo's token; sent in place of it until
// Apollo mints a new token itself. nil until the first rejection.
static NSString *sRGRefreshedToken;
// Callbacks waiting on the one refresh mint in flight; nil when none is.
static NSMutableArray<void (^)(NSString *)> *sRGMintWaiters;
// Logs the first request sent with a refreshed token, once per refresh.
static BOOL sRGLoggedSwap;

static NSInteger ApolloRedgifsHTTPStatus(NSURLResponse *response) {
    return [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
}

static NSString *ApolloRedgifsBearerToken(NSURLRequest *request) {
    NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
    if (![authorization hasPrefix:@"Bearer "]) return nil;
    NSString *token = [authorization substringFromIndex:7];
    return token.length > 0 ? token : nil;
}

static NSURLRequest *ApolloRedgifsRequestWithToken(NSURLRequest *request, NSString *token) {
    NSMutableURLRequest *copy = [request mutableCopy];
    [copy setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    return copy;
}

void ApolloRedgifsNoteTokenIssuedToApollo(NSString *token) {
    if (![token isKindOfClass:[NSString class]] || token.length == 0) return;
    os_unfair_lock_lock(&sRGLock);
    if (!sRGIssuedTokens) sRGIssuedTokens = [NSMutableOrderedSet orderedSet];
    [sRGIssuedTokens removeObject:token];
    [sRGIssuedTokens addObject:[token copy]];
    while (sRGIssuedTokens.count > kApolloRedgifsIssuedTokenCap) [sRGIssuedTokens removeObjectAtIndex:0];
    // Apollo just minted this from the current address, so it no longer needs
    // an earlier refresh swapped in.
    sRGRefreshedToken = nil;
    os_unfair_lock_unlock(&sRGLock);
}

static void ApolloRedgifsFinishMint(NSString *token) {
    os_unfair_lock_lock(&sRGLock);
    if (token.length > 0) {
        sRGRefreshedToken = [token copy];
        sRGLoggedSwap = NO;
    }
    NSArray<void (^)(NSString *)> *waiters = sRGMintWaiters;
    sRGMintWaiters = nil;
    os_unfair_lock_unlock(&sRGLock);

    for (void (^waiter)(NSString *) in waiters) waiter(token);
}

// Calls `completion` with a token to retry with after RedGIFs rejected
// `rejectedToken`, or nil when no fresh one could be minted. Requests rejected
// at the same time share one mint.
static void ApolloRedgifsFreshToken(NSString *rejectedToken,
                                    NSString *userAgent,
                                    ApolloRedgifsTaskFactory factory,
                                    void (^completion)(NSString *token)) {
    os_unfair_lock_lock(&sRGLock);
    // A refresh already landed while this request was in flight.
    if (sRGRefreshedToken.length > 0 && ![sRGRefreshedToken isEqualToString:rejectedToken]) {
        NSString *token = sRGRefreshedToken;
        os_unfair_lock_unlock(&sRGLock);
        completion(token);
        return;
    }
    BOOL mintInFlight = sRGMintWaiters != nil;
    if (!mintInFlight) sRGMintWaiters = [NSMutableArray array];
    [sRGMintWaiters addObject:[completion copy]];
    os_unfair_lock_unlock(&sRGLock);
    if (mintInFlight) return;

    ApolloLog(@"[RedgifsToken] RedGIFs rejected the cached token (HTTP 401), likely after an IP address change; minting a fresh one");

    // Same endpoint and method as the /v2/oauth/client rewrite. The token is
    // bound to the User-Agent as well as the address: copy Apollo's header when
    // it set one, otherwise the session's own default applies to both calls.
    NSMutableURLRequest *mint = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kApolloRedgifsTokenURL]
                                                        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                    timeoutInterval:15.0];
    [mint setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (userAgent.length > 0) [mint setValue:userAgent forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = factory(mint, ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = ApolloRedgifsHTTPStatus(response);
        NSString *token = nil;
        if (!error && status == 200 && data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            id value = [json isKindOfClass:[NSDictionary class]] ? json[@"token"] : nil;
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) token = value;
        }
        if (token) {
            ApolloLog(@"[RedgifsToken] Minted a fresh token; retrying the rejected request(s)");
        } else {
            ApolloLog(@"[RedgifsToken] Could not mint a fresh token (HTTP %ld, error %ld); passing the 401 through",
                      (long)status, (long)error.code);
        }
        ApolloRedgifsFinishMint(token);
    });
    if (!task) {
        ApolloRedgifsFinishMint(nil);
        return;
    }
    [task resume];
}

NSURLSessionDataTask *ApolloRedgifsDataTaskWithTokenRefresh(NSURLRequest *request,
                                                           ApolloRedgifsTaskCompletion completion,
                                                           ApolloRedgifsTaskFactory factory) {
    if (!completion || !factory) return nil;
    NSString *requestToken = ApolloRedgifsBearerToken(request);
    if (!requestToken) return nil;

    os_unfair_lock_lock(&sRGLock);
    BOOL isApolloToken = [sRGIssuedTokens containsObject:requestToken];
    NSString *refreshedToken = isApolloToken ? sRGRefreshedToken : nil;
    BOOL logSwap = refreshedToken.length > 0 && !sRGLoggedSwap;
    if (logSwap) sRGLoggedSwap = YES;
    os_unfair_lock_unlock(&sRGLock);
    // Not a token Apollo's RedGIFsClient got from the rewrite (e.g.
    // ApolloHostedVideo's own): leave the request alone.
    if (!isApolloToken) return nil;

    NSString *sendToken = requestToken;
    NSURLRequest *outgoing = request;
    if (refreshedToken.length > 0) {
        sendToken = refreshedToken;
        outgoing = ApolloRedgifsRequestWithToken(request, refreshedToken);
        if (logSwap) ApolloLog(@"[RedgifsToken] Sending the refreshed token in place of Apollo's cached one");
    }
    NSString *userAgent = [request valueForHTTPHeaderField:@"User-Agent"];

    ApolloRedgifsTaskCompletion wrapped = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (ApolloRedgifsHTTPStatus(response) != 401) {
            completion(data, response, error);
            return;
        }
        ApolloRedgifsFreshToken(sendToken, userAgent, factory, ^(NSString *freshToken) {
            if (freshToken.length == 0) {
                completion(data, response, error);
                return;
            }
            // One retry only: its result goes straight back to Apollo, 401 or not.
            NSURLSessionDataTask *retryTask = factory(ApolloRedgifsRequestWithToken(outgoing, freshToken),
                ^(NSData *retryData, NSURLResponse *retryResponse, NSError *retryError) {
                    ApolloLog(@"[RedgifsToken] Retry with the fresh token finished: HTTP %ld",
                              (long)ApolloRedgifsHTTPStatus(retryResponse));
                    completion(retryData, retryResponse, retryError);
                });
            if (!retryTask) {
                completion(data, response, error);
                return;
            }
            [retryTask resume];
        });
    };
    return factory(outgoing, wrapped);
}

__attribute__((constructor)) static void ApolloRedgifsTokenRefreshInit(void) {
    ApolloLog(@"[RedgifsToken] ctor: RedGIFs 401 token refresh armed (runs from the NSURLSession hook in Tweak.xm)");
}
