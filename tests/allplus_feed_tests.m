// Host-side checks for the All+ r/all feed rewrite (src/ApolloAllPlusNSFW.xm):
// the production source is inserted below with doubles only at its account,
// setting, log and NSURLSession boundaries, so the buffer / cursor / owner /
// generation bookkeeping under test is the shipping code. Each scenario runs
// in its own process (the state is static), see run_allplus_feed_tests.sh.
#import <Foundation/Foundation.h>
#import <math.h>
#import "ApolloAllPlusMerge.h"

static int sFailures;

#define CHECK(condition, ...) do { \
    if (!(condition)) { \
        sFailures++; \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); \
    } \
} while (0)

// Doubles for the globals and account helpers the rewrite reads
// (ApolloState.h / ApolloAccountCredentials.h are stripped from the insert).
static BOOL sAllPlusNSFWEnabled = YES;
static double sAllPlusNSFWBoost = 0.0;
static NSString *sUserAgent = nil;
static NSString *sFixtureUsername = nil;   // what ApolloActiveAccountUsername() answers
static NSString *sFixtureBearer = nil;     // what ApolloActiveAccountRedditBearerToken() answers (nil = API-Key-Free)
static NSString *ApolloActiveAccountUsername(void) { return sFixtureUsername; }
static NSString *ApolloActiveAccountRedditBearerToken(void) { return sFixtureBearer; }
static void ApolloLog(NSString *format, ...) { (void)format; }

// NSURLSession double: every resumed task is recorded, nothing completes until
// a scenario completes it by hand, and cancel just flags the task.
typedef void (^FixtureResponse)(NSData *, NSURLResponse *, NSError *);
@interface FixtureDataTask : NSObject
@property (strong) NSURLRequest *request;
@property (copy) FixtureResponse completion;
@property BOOL cancelled;
- (void)resume;
- (void)cancel;
@end
static NSMutableArray<FixtureDataTask *> *sRequests;
@implementation FixtureDataTask
- (void)resume { [sRequests addObject:self]; }
- (void)cancel { self.cancelled = YES; }
@end
@interface FixtureSession : NSObject
+ (instancetype)sharedSession;
- (FixtureDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(FixtureResponse)completion;
@end
@implementation FixtureSession
+ (instancetype)sharedSession { return [self new]; }
- (FixtureDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(FixtureResponse)completion {
    FixtureDataTask *task = [FixtureDataTask new]; task.request = request; task.completion = completion; return task;
}
@end

#define NSURLSession FixtureSession
#define NSURLSessionDataTask FixtureDataTask
// INSERT_PRODUCTION_FEED
#undef NSURLSession
#undef NSURLSessionDataTask

#pragma mark - helpers

static const double kNow = 1700000000;   // created_utc of a "current" post

static NSDictionary *Child(NSString *name, double score, double created) {
    return @{ @"kind": @"t3", @"data": @{ @"name": name, @"score": @(score),
              @"created_utc": @(created), @"over_18": @YES } };
}

static NSData *ListingData(NSArray *children, NSString *after) {
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObject:children forKey:@"children"];
    data[@"after"] = after ?: [NSNull null];
    return [NSJSONSerialization dataWithJSONObject:@{ @"kind": @"Listing", @"data": data } options:0 error:NULL];
}

// Run the production rewrite on an r/all page and hand back the merged child
// names (nil when the page was left stock).
static NSArray<NSString *> *Rewrite(NSString *urlString, NSArray *children) {
    NSURL *url = [NSURL URLWithString:urlString];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    NSData *out = ApolloAllPlusRewriteData(response, ListingData(children, @"t3_nextpage"));
    if (!out) return nil;
    NSDictionary *listing = [NSJSONSerialization JSONObjectWithData:out options:0 error:NULL];
    CHECK([listing[@"data"][@"after"] isEqual:@"t3_nextpage"], @"the page's own after cursor must survive the rewrite");
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *child in listing[@"data"][@"children"]) [names addObject:child[@"data"][@"name"]];
    return names;
}

// Everything the rewrite does off the page thread lands on APQueue(); wait for it.
static void Drain(void) { dispatch_sync(APQueue(), ^{}); }

// Answer a recorded search with a listing page (children + cursor).
static void Complete(FixtureDataTask *task, NSArray *children, NSString *after) {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    task.completion(ListingData(children, after), response, nil);
    Drain();
}

static NSString *Query(FixtureDataTask *task, NSString *name) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:task.request.URL resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *q in c.queryItems) { if ([q.name isEqualToString:name]) return q.value; }
    return nil;
}

// The search request shape every scenario expects: Reddit's site-wide nsfw:1
// hot search, no time window, at the host the account's auth mode calls for.
static void CheckSearchRequest(FixtureDataTask *task, NSString *host, NSString *bearer, NSString *after) {
    CHECK([task.request.URL.host isEqualToString:host], @"search host %@, expected %@", task.request.URL.host, host);
    CHECK([task.request.URL.path isEqualToString:@"/search"], @"search path %@", task.request.URL.path);
    CHECK([Query(task, @"q") isEqualToString:@"nsfw:1"], @"search q=%@", Query(task, @"q"));
    CHECK([Query(task, @"sort") isEqualToString:@"hot"], @"search sort=%@", Query(task, @"sort"));
    CHECK(Query(task, @"t") == nil, @"search must not carry a time window");
    CHECK([Query(task, @"include_over_18") isEqualToString:@"on"], @"search must ask for over-18 results");
    NSString *authorization = [task.request valueForHTTPHeaderField:@"Authorization"];
    if (bearer) {
        CHECK([authorization isEqualToString:[@"Bearer " stringByAppendingString:bearer]], @"Authorization %@, expected bearer %@", authorization, bearer);
    } else {
        CHECK(authorization == nil, @"API-Key-Free search must go bearer-less, got %@", authorization);
    }
    CHECK([[task.request valueForHTTPHeaderField:@"User-Agent"] isEqualToString:sUserAgent], @"search must use Apollo's User-Agent");
    if (after) {
        CHECK([Query(task, @"after") isEqualToString:after], @"search after=%@, expected %@", Query(task, @"after"), after);
    } else {
        CHECK(Query(task, @"after") == nil, @"first search must not carry a cursor, got %@", Query(task, @"after"));
    }
}

static NSString *const kHotPage1 = @"https://oauth.reddit.com/r/all/hot.json?limit=25&raw_json=1";
static NSString *const kHotPage2 = @"https://oauth.reddit.com/r/all/hot.json?limit=25&raw_json=1&after=t3_nextpage";

static void SignIn(NSString *username, NSString *bearer) {
    sFixtureUsername = username;
    sFixtureBearer = bearer;
}

#pragma mark - scenarios

// (f) Cold start: page 1 stays stock while the first search runs; once it has
// answered, page 2 merges the candidate that outranks the weakest native, and
// the one that doesn't stays buffered.
static void TestColdStart(void) {
    SignIn(@"alice", @"tokA");
    NSArray *page1 = @[ Child(@"t3_n1", 1000, kNow), Child(@"t3_n2", 500, kNow) ];
    CHECK(Rewrite(kHotPage1, page1) == nil, @"cold page 1 must be left stock");
    CHECK(sRequests.count == 1, @"page 1 starts exactly one search, got %lu", (unsigned long)sRequests.count);
    CheckSearchRequest(sRequests[0], @"oauth.reddit.com", @"tokA", nil);

    Complete(sRequests[0], @[ Child(@"t3_hot", 100000, kNow), Child(@"t3_cold", 1, kNow) ], @"t3_cursor1");
    CHECK(sAPBuffer.count == 2, @"both candidates buffered, got %lu", (unsigned long)sAPBuffer.count);
    CHECK(sRequests.count == 2, @"the buffer is below target, so a second page is asked for");
    CheckSearchRequest(sRequests[1], @"oauth.reddit.com", @"tokA", @"t3_cursor1");

    NSArray *page2 = @[ Child(@"t3_n3", 800, kNow), Child(@"t3_n4", 400, kNow) ];
    NSArray *names = Rewrite(kHotPage2, page2);
    CHECK([names isEqual:(@[ @"t3_hot", @"t3_n3", @"t3_n4" ])], @"page 2 should lead with the hot candidate, got %@", names);
    CHECK(sAPBuffer.count == 1, @"the candidate below the floor stays buffered");
    CHECK(sRequests.count == 2, @"a refill is already in flight; no extra search");
}

// (e) Happy path through the first-batch cache: a pull-to-refresh within ten
// minutes seeds page 1 from the first search page (same account), cancelling
// the refill that belonged to the previous load.
static void TestRefreshFromCache(void) {
    SignIn(@"alice", @"tokA");
    NSArray *page1 = @[ Child(@"t3_n1", 1000, kNow), Child(@"t3_n2", 500, kNow) ];
    CHECK(Rewrite(kHotPage1, page1) == nil, @"cold page 1 must be left stock");
    Complete(sRequests[0], @[ Child(@"t3_hot", 100000, kNow) ], @"t3_cursor1");
    CHECK(sRequests.count == 2, @"refill for the cursor is in flight");

    NSArray *names = Rewrite(kHotPage1, page1);   // pull-to-refresh
    CHECK([names isEqual:(@[ @"t3_hot", @"t3_n1", @"t3_n2" ])], @"refreshed page 1 merges from the cached first batch, got %@", names);
    CHECK(sRequests[1].cancelled, @"the previous load's refill is cancelled");
    CHECK(sRequests.count == 3, @"the fresh load continues from the cached cursor, got %lu requests", (unsigned long)sRequests.count);
    CheckSearchRequest(sRequests[2], @"oauth.reddit.com", @"tokA", @"t3_cursor1");

    // The cancelled refill answering late must not publish.
    Complete(sRequests[1], @[ Child(@"t3_late", 100000, kNow) ], @"t3_cursor2");
    CHECK(sAPBuffer.count == 0, @"a cancelled refill's candidates are dropped, buffer has %lu", (unsigned long)sAPBuffer.count);
    CHECK(sRequests.count == 3, @"a dropped completion starts no search");
}

// (a) Account switch within the cache window: B's fresh page gets none of A's
// cached candidates, A's in-flight search is cancelled, and A's late completion
// is dropped without starting another search.
static void TestAccountSwitch(void) {
    SignIn(@"alice", @"tokA");
    NSArray *page1 = @[ Child(@"t3_n1", 1000, kNow), Child(@"t3_n2", 500, kNow) ];
    CHECK(Rewrite(kHotPage1, page1) == nil, @"alice's cold page 1 must be left stock");
    Complete(sRequests[0], @[ Child(@"t3_aliceHot", 100000, kNow) ], @"t3_aliceCursor");
    CHECK(sAPBuffer.count == 1 && sAPFirstBatch.count == 1, @"alice's candidate is buffered and cached");
    CHECK(sRequests.count == 2, @"alice's refill is in flight");

    SignIn(@"bob", @"tokB");
    CHECK(Rewrite(kHotPage1, page1) == nil, @"bob's fresh page 1 must not carry alice's candidates");
    CHECK(sAPBuffer.count == 0 && sAPFirstBatch == nil && sAPNsfwAfter == nil, @"alice's buffer, cache and cursor are dropped");
    CHECK(sRequests[1].cancelled, @"alice's in-flight refill is cancelled");
    CHECK(sRequests.count == 3, @"bob starts his own search, got %lu requests", (unsigned long)sRequests.count);
    CheckSearchRequest(sRequests[2], @"oauth.reddit.com", @"tokB", nil);

    // alice's refill answering after the switch: dropped, starts nothing.
    Complete(sRequests[1], @[ Child(@"t3_aliceLate", 100000, kNow) ], @"t3_aliceCursor2");
    CHECK(sAPBuffer.count == 0, @"alice's late candidates must not land in bob's buffer");
    CHECK(sRequests.count == 3, @"alice's late completion must not start a search");
    CHECK(sAPNsfwAfter == nil, @"alice's cursor must not become bob's");

    NSArray *page2 = @[ Child(@"t3_n3", 800, kNow) ];
    CHECK(Rewrite(kHotPage2, page2) == nil, @"bob's page 2 stays stock until his own search answers");

    Complete(sRequests[2], @[ Child(@"t3_bobHot", 100000, kNow) ], nil);
    NSArray *names = Rewrite(kHotPage2, page2);
    CHECK([names isEqual:(@[ @"t3_bobHot", @"t3_n3" ])], @"bob's page merges only bob's candidate, got %@", names);
}

// alice's search answers after the switch to bob but before any bob page has
// loaded (so nothing has adopted the new owner yet): still dropped, and it
// must not ask again with alice's token.
static void TestAccountSwitchBeforeLoad(void) {
    SignIn(@"alice", @"tokA");
    NSArray *page1 = @[ Child(@"t3_n1", 1000, kNow), Child(@"t3_n2", 500, kNow) ];
    CHECK(Rewrite(kHotPage1, page1) == nil, @"alice's cold page 1 must be left stock");
    CHECK(sRequests.count == 1, @"alice's search is in flight");

    SignIn(@"bob", @"tokB");
    Complete(sRequests[0], @[ Child(@"t3_aliceHot", 100000, kNow) ], @"t3_aliceCursor");
    CHECK(sAPBuffer.count == 0, @"alice's answer must not publish after the switch");
    CHECK(sRequests.count == 1, @"alice's answer must not start another search with her token");

    CHECK(Rewrite(kHotPage1, page1) == nil, @"bob's fresh page 1 is stock while his search runs");
    CHECK(sRequests.count == 2, @"bob starts his own search, got %lu requests", (unsigned long)sRequests.count);
    CheckSearchRequest(sRequests[1], @"oauth.reddit.com", @"tokB", nil);
}

// (b) Mixed setup: alice has an API key (bearer on oauth.reddit.com); bob is
// API-Key-Free (bearer-less on www.reddit.com). Switching alice herself from
// API key to API-Key-Free is an owner change too.
static void TestMixedAuth(void) {
    NSArray *page1 = @[ Child(@"t3_n1", 1000, kNow), Child(@"t3_n2", 500, kNow) ];
    SignIn(@"alice", @"tokA");
    CHECK(Rewrite(kHotPage1, page1) == nil, @"alice's cold page 1 must be left stock");
    CheckSearchRequest(sRequests[0], @"oauth.reddit.com", @"tokA", nil);
    Complete(sRequests[0], @[ Child(@"t3_aliceHot", 100000, kNow) ], nil);
    CHECK(sAPBuffer.count == 1, @"alice's candidate is buffered");

    SignIn(@"bob", nil);
    CHECK(Rewrite(@"https://www.reddit.com/r/all/hot.json?limit=25&raw_json=1", page1) == nil, @"bob's fresh page 1 must not carry alice's candidates");
    CHECK(sAPBuffer.count == 0, @"alice's buffer is dropped for bob");
    CHECK(sRequests.count == 2, @"bob starts his own search, got %lu requests", (unsigned long)sRequests.count);
    CheckSearchRequest(sRequests[1], @"www.reddit.com", nil, nil);
    Complete(sRequests[1], @[ Child(@"t3_bobHot", 100000, kNow) ], nil);
    CHECK(sAPBuffer.count == 1, @"bob's candidate is buffered");

    // Same username, auth mode flips (API key removed): not the same owner.
    SignIn(@"bob", @"tokB");
    CHECK(Rewrite(kHotPage1, page1) == nil, @"bob's page after an auth change starts clean");
    CHECK(sAPBuffer.count == 0, @"an auth mode change drops the buffer");
    CHECK(sRequests.count == 3, @"and starts a fresh search for the new mode");
    CheckSearchRequest(sRequests[2], @"oauth.reddit.com", @"tokB", nil);
}

// (c) Sort restriction: a buffered (old) candidate never reaches Top / Past
// Hour, New or Controversial, and those pages touch no state -- not even a
// fresh-load reset.
static void TestSortRestricted(void) {
    SignIn(@"alice", @"tokA");
    NSArray *page1 = @[ Child(@"t3_n1", 1000, kNow), Child(@"t3_n2", 500, kNow) ];
    CHECK(Rewrite(kHotPage1, page1) == nil, @"cold page 1 must be left stock");
    Complete(sRequests[0], @[ Child(@"t3_old", 100000, kNow - 3 * 86400) ], @"t3_cursor1");
    CHECK(sAPBuffer.count == 1, @"the old candidate is buffered");
    NSUInteger requests = sRequests.count;
    NSUInteger generation = sAPGeneration;

    NSArray *hourPage = @[ Child(@"t3_h1", 100, kNow), Child(@"t3_h2", 50, kNow) ];
    CHECK(Rewrite(@"https://oauth.reddit.com/r/all/top.json?t=hour&limit=25&after=t3_nextpage", hourPage) == nil, @"top/past hour page 2 must be left stock");
    CHECK(Rewrite(@"https://oauth.reddit.com/r/all/top.json?t=hour&limit=25", hourPage) == nil, @"top/past hour page 1 must be left stock");
    CHECK(Rewrite(@"https://oauth.reddit.com/r/all/new.json?limit=25", hourPage) == nil, @"new must be left stock");
    CHECK(Rewrite(@"https://oauth.reddit.com/r/all/controversial.json?t=day&limit=25", hourPage) == nil, @"controversial must be left stock");
    CHECK(sAPBuffer.count == 1 && [ChildName(sAPBuffer[0]) isEqualToString:@"t3_old"], @"other sorts leave the buffer alone");
    CHECK(sRequests.count == requests, @"other sorts start no search");
    CHECK(sAPGeneration == generation, @"other sorts don't count as a fresh load");

    // Back on hot, page 2: the buffered candidate is still there and merges
    // once hot rank lets it (it is three days old, so against natives of its
    // own age -- fresh ones outrank it, which is the point of hot).
    NSArray *oldPage = @[ Child(@"t3_o1", 100, kNow - 3 * 86400), Child(@"t3_o2", 50, kNow - 3 * 86400) ];
    NSArray *names = Rewrite(kHotPage2, oldPage);
    CHECK([names isEqual:(@[ @"t3_old", @"t3_o1", @"t3_o2" ])], @"hot page 2 merges the buffered candidate, got %@", names);
}

// (d) Switched off with a search in flight: its answer (a candidate plus a
// continuation cursor) is neither published nor followed by another search.
static void TestDisableInFlight(void) {
    SignIn(@"alice", @"tokA");
    NSArray *page1 = @[ Child(@"t3_n1", 1000, kNow), Child(@"t3_n2", 500, kNow) ];
    CHECK(Rewrite(kHotPage1, page1) == nil, @"cold page 1 must be left stock");
    CHECK(sRequests.count == 1, @"one search in flight");

    sAllPlusNSFWEnabled = NO;   // what the settings toggle does...
    ApolloAllPlusInvalidate();  // ...followed by this
    Drain();
    CHECK(sRequests[0].cancelled, @"turning All+ off cancels the in-flight search");

    Complete(sRequests[0], @[ Child(@"t3_hot", 100000, kNow) ], @"t3_cursor1");
    CHECK(sAPBuffer.count == 0, @"nothing is published after disable, buffer has %lu", (unsigned long)sAPBuffer.count);
    CHECK(sAPFirstBatch == nil, @"the first-batch cache is not filled after disable");
    CHECK(sRequests.count == 1, @"no second search after disable, got %lu", (unsigned long)sRequests.count);
    CHECK(Rewrite(kHotPage2, page1) == nil, @"pages are left stock while off");
    CHECK(sRequests.count == 1, @"pages start no search while off");

    // Back on: a clean start, not a resume of whatever was buffered.
    sAllPlusNSFWEnabled = YES;
    ApolloAllPlusInvalidate();
    Drain();
    CHECK(Rewrite(kHotPage2, page1) == nil, @"the first page after re-enable has nothing to merge");
    CHECK(sRequests.count == 2, @"re-enabling asks again, got %lu requests", (unsigned long)sRequests.count);
    CheckSearchRequest(sRequests[1], @"oauth.reddit.com", @"tokA", nil);
}

// The completion guards the flag on its own too: even without the invalidate
// call, a search answering after All+ was switched off publishes nothing and
// asks for nothing.
static void TestDisableFlagOnly(void) {
    SignIn(@"alice", @"tokA");
    NSArray *page1 = @[ Child(@"t3_n1", 1000, kNow), Child(@"t3_n2", 500, kNow) ];
    CHECK(Rewrite(kHotPage1, page1) == nil, @"cold page 1 must be left stock");
    sAllPlusNSFWEnabled = NO;
    Complete(sRequests[0], @[ Child(@"t3_hot", 100000, kNow) ], @"t3_cursor1");
    CHECK(sAPBuffer.count == 0, @"nothing is published once the flag is off, buffer has %lu", (unsigned long)sAPBuffer.count);
    CHECK(sRequests.count == 1, @"no second search once the flag is off, got %lu", (unsigned long)sRequests.count);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        sRequests = [NSMutableArray array];
        sUserAgent = @"Apollo/1.15.11 fixture";
        NSDictionary<NSString *, dispatch_block_t> *scenarios = @{
            @"cold-start": ^{ TestColdStart(); },
            @"refresh-cache": ^{ TestRefreshFromCache(); },
            @"account-switch": ^{ TestAccountSwitch(); },
            @"account-switch-before-load": ^{ TestAccountSwitchBeforeLoad(); },
            @"mixed-auth": ^{ TestMixedAuth(); },
            @"sort-restricted": ^{ TestSortRestricted(); },
            @"disable-in-flight": ^{ TestDisableInFlight(); },
            @"disable-flag-only": ^{ TestDisableFlagOnly(); },
        };
        dispatch_block_t test = scenarios[@(argv[1])];
        if (!test) return 2;
        test();
        printf("allplus feed %s: %s\n", argv[1], sFailures ? "FAILED" : "passed");
    }
    return sFailures ? 1 : 0;
}
