#import <Foundation/Foundation.h>
#define ApolloLog(...) do { if (NO) NSLog(__VA_ARGS__); } while (0)
static BOOL sWebJSONEnabled = YES;
static NSString *const kApolloWebJSONProbeMarker = @"probe";
static NSString *const ApolloWebJSONSessionExpiredNotification = @"Expired";
@interface Entry : NSObject
@property(copy) NSString *cookieHeader;
@end
@implementation Entry
@end
static NSMutableDictionary *entries;
static Entry *ApolloWebSessionFor(NSString *username) { return entries[username]; }
static NSURL *ApolloWebJSONURLWithFragment(NSURL *url, NSString *fragment) { (void)fragment; return url; }
static NSString *ApolloWebJSONBrowserUserAgent(void) { return @"test"; }
static NSMutableArray *pending;
static NSMutableArray *silent;
static NSMutableArray *delayed;
static void testDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    (void)when; (void)queue; [delayed addObject:[block copy]];
}
static NSUInteger probes;
static NSUInteger merges;
static BOOL ApolloWebJSONURLIsProbe(NSURL *url) { (void)url; return NO; }
static NSString *ApolloWebJSONAccountFromURL(NSURL *url) { (void)url; return @"alice"; }
@interface TestTask : NSObject
@property(copy) void (^completion)(NSData *, NSURLResponse *, NSError *);
- (void)resume;
@end
@implementation TestTask
- (void)resume { [pending addObject:self]; }
@end
@interface TestSession : NSObject
+ (instancetype)sessionWithConfiguration:(id)configuration;
- (TestTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
- (void)finishTasksAndInvalidate;
@end
@implementation TestSession
+ (instancetype)sessionWithConfiguration:(id)configuration { (void)configuration; return [self new]; }
- (TestTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    NSCAssert([request valueForHTTPHeaderField:@"Cookie"].length > 0, @"probe uses account cookie");
    probes++; TestTask *task = [TestTask new]; task.completion = completion; return task;
}
- (void)finishTasksAndInvalidate {}
@end
@interface ApolloWebSessionLoginViewController : NSObject
+ (void)attemptSilentReharvestForUsername:(NSString *)username completion:(void (^)(BOOL))completion;
@end
@implementation ApolloWebSessionLoginViewController
+ (void)attemptSilentReharvestForUsername:(NSString *)username completion:(void (^)(BOOL))completion {
    (void)username; [silent addObject:[completion copy]];
}
@end
#define dispatch_after testDispatchAfter
#define NSURLSession TestSession
#define NSURLSessionDataTask TestTask
// PRODUCTION_EXPIRY
#undef dispatch_after
#undef NSURLSession
#undef NSURLSessionDataTask
static void ApolloWebJSONMergeSetCookiesFromResponse(NSString *username, NSHTTPURLResponse *response) { (void)username; (void)response; merges++; }
static void require(BOOL okay) { if (!okay) { NSLog(@"FAIL"); abort(); } }
static NSHTTPURLResponse *response(NSInteger status, NSString *mime) {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://www.reddit.com/api/me.json"] statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":mime}];
}
static NSData *body(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static void answer(NSString *json) {
    TestTask *t = pending.firstObject; require(t != nil); [pending removeObjectAtIndex:0];
    t.completion(body(json), response(200,@"application/json"), nil);
}
static void finishSilent(BOOL success) {
    void (^block)(BOOL) = silent.firstObject; require(block != nil); [silent removeObjectAtIndex:0]; block(success);
}
static void setCookie(NSString *name, NSString *cookie) { Entry *e=[Entry new];e.cookieHeader=cookie;entries[name]=e; }
int main(void) { @autoreleasepool {
    entries=[NSMutableDictionary new];pending=[NSMutableArray new];silent=[NSMutableArray new];delayed=[NSMutableArray new];
    for (NSString *name in @[@"alice",@"bob"]) setCookie(name, [name stringByAppendingString:@"=old"]);
    require(ApolloWebJSONIdentityVerdict(@"alice", body(@"{}"), response(200,@"application/json"), nil)==ApolloWebJSONProbeDead);
    require(ApolloWebJSONIdentityVerdict(@"alice", body(@"{\"data\":{\"name\":\"ALICE\"}}"), response(200,@"application/json"), nil)==ApolloWebJSONProbeAlive);
    require(ApolloWebJSONIdentityVerdict(@"alice", body(@"{\"data\":{\"name\":\"bob\"}}"), response(200,@"application/json"), nil)==ApolloWebJSONProbeDead);
    for (NSString *json in @[@"<html>challenge</html>", @"[]", @"{\"error\":429}", @"{\"data\":\"wrong\"}"]) {
        require(ApolloWebJSONIdentityVerdict(@"alice",body(json),response(200,@"application/json"),nil)==ApolloWebJSONProbeInconclusive);
    }
    for (NSNumber *status in @[@429,@500,@503]) require(ApolloWebJSONIdentityVerdict(@"alice",body(@"{}"),response(status.integerValue,@"application/json"),nil)==ApolloWebJSONProbeInconclusive);
    require(ApolloWebJSONIdentityVerdict(@"alice",body(@"{}"),response(200,@"application/json"),[NSError errorWithDomain:NSURLErrorDomain code:-1009 userInfo:nil])==ApolloWebJSONProbeInconclusive);
    require(ApolloWebJSONIdentityVerdict(@"alice",nil,response(401,@"application/json"),nil)==ApolloWebJSONProbeDead);
    require(ApolloWebJSONIdentityVerdict(@"alice",nil,response(403,@"text/html"),nil)==ApolloWebJSONProbeDead);
    // First account request probes even without any 403 streak. Parallel
    // requests share a single check. Public success cannot suppress it.
    NSMutableURLRequest *publicRequest=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.reddit.com/r/all.json"]];
    [publicRequest setValue:@"alice=old" forHTTPHeaderField:@"Cookie"];
    ApolloWebJSONNoteResponse(publicRequest,response(200,@"application/json"));require(merges==0);
    ApolloWebJSONNoteResponse(publicRequest,response(302,@"text/html"));require(merges==0);
    ApolloWebJSONCheckAccountSession(@"alice");ApolloWebJSONCheckAccountSession(@"alice");require(probes==1);
    answer(@"{}"); require(silent.count==1);
    ApolloWebJSONVerifySessionThenAnnounce(@"alice");require(probes==1); // in-flight through reharvest
    __block NSString *promptAccount=nil;
    id observer=[[NSNotificationCenter defaultCenter] addObserverForName:ApolloWebJSONSessionExpiredNotification object:nil queue:nil usingBlock:^(NSNotification *note) { promptAccount=note.userInfo[@"username"]; }];
    finishSilent(NO);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    require([promptAccount isEqualToString:@"alice"]);
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    require([sSessionExpiredAnnouncedUsers containsObject:@"alice"]);
    require(ApolloWebJSONAccountSessionError(@"alice").code==NSURLErrorUserAuthenticationRequired);
    require(ApolloWebJSONAccountSessionError(@"bob")==nil);
    // Deferring sign-in must not mark a dead session healthy.
    ApolloWebJSONNoteSessionReauthenticationDeferred(@"alice");require(ApolloWebJSONAccountSessionError(@"alice")!=nil);
    // A new login immediately clears the invalid state and probe cooldown.
    setCookie(@"alice",@"alice=new");ApolloWebJSONNoteSessionReauthenticated(@"alice");require(ApolloWebJSONAccountSessionError(@"alice")==nil);
    // A late failure from an old snapshot must not invalidate a new login.
    ApolloWebJSONCheckAccountSession(@"bob");setCookie(@"bob",@"bob=new");answer(@"{}");require(silent.count==0);require(ApolloWebJSONAccountSessionError(@"bob")==nil);
    // Same protection when login changes while silent reharvest is pending.
    ApolloWebJSONVerifySessionThenAnnounce(@"bob");answer(@"{}");setCookie(@"bob",@"bob=newer");finishSilent(NO);require(ApolloWebJSONAccountSessionError(@"bob")==nil);
    // Matching identity leaves the account usable.
    ApolloWebJSONVerifySessionThenAnnounce(@"bob");answer(@"{\"data\":{\"name\":\"bob\"}}");require(ApolloWebJSONAccountSessionError(@"bob")==nil);
    // Production log sequence: identity HTTP 200 is inconclusive, then
    // malformed account listings arrive. Public successes must not cancel
    // the pending retry, and that retry must reach browser recovery/prompt.
    setCookie(@"charlie",@"charlie=old");
    ApolloWebJSONCheckAccountSession(@"charlie");answer(@"<html>not an identity</html>");
    require(delayed.count > 0 && silent.count == 0);
    NSUInteger before=probes;
    ApolloWebJSONNoteMalformedAccountResponse(@"charlie",@"r/all.json");require(probes==before);
    dispatch_block_t retry=delayed.lastObject; [delayed removeLastObject];
    ApolloWebJSONResetBlockStreak(@"charlie");retry();require(probes==before+1);
    ApolloWebJSONNoteMalformedAccountResponse(@"charlie",@"prefs/blocked.json"); // coalesces with in-flight probe
    // Bearer rotation during the probe must recheck the new snapshot rather
    // than lose the only recovery trigger (also observed in the device log).
    setCookie(@"charlie",@"charlie=rotated");answer(@"<html>not an identity</html>");
    require(pending.count==1);answer(@"<html>not an identity</html>");require(silent.count==1);
    __block NSString *retryPrompt=nil;
    id retryObserver=[[NSNotificationCenter defaultCenter] addObserverForName:ApolloWebJSONSessionExpiredNotification object:nil queue:nil usingBlock:^(NSNotification *note) { retryPrompt=note.userInfo[@"username"]; }];
    finishSilent(NO);require(ApolloWebJSONAccountSessionError(@"charlie")!=nil);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    require([retryPrompt isEqualToString:@"charlie"]);
    [[NSNotificationCenter defaultCenter] removeObserver:retryObserver];
    require(ApolloWebJSONAccountSessionError(@"alice")==nil);
    NSLog(@"PASS: identity verdicts, cooldown, expiry, account isolation, deferred/replaced sessions and recovery");
} }
