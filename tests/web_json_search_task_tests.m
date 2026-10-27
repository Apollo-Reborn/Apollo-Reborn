#import <Foundation/Foundation.h>
#define ApolloLog(...) do { if (NO) NSLog(__VA_ARGS__); } while (0)
typedef void (^Completion)(NSHTTPURLResponse *, id, NSError *);
static NSMutableArray *work;
static BOOL sWebJSONEnabled = YES, needsMint = YES;
static NSUInteger sends, mints, calls;
static NSError *lastError;
static id lastObject;
static NSString *mintOwner;
@interface MockTask : NSObject
@property NSUInteger cancels;
@property NSUInteger resumes;
@property(copy) Completion completion;
- (void)cancel;
- (void)resume;
- (NSURLSessionTaskState)state;
- (NSUInteger)taskIdentifier;
@end
@implementation MockTask
- (void)cancel { self.cancels++; }
- (void)resume { self.resumes++; }
- (NSURLSessionTaskState)state { return NSURLSessionTaskStateRunning; }
- (NSUInteger)taskIdentifier { return 42; }
@end
static MockTask *placeholder;
static MockTask *sent;
static id ApolloWebJSONSharedReadPlaceholderTask(void) { placeholder = [MockTask new]; return placeholder; }
// PRODUCTION_DEFERRED_TASK
@interface RDKClient : NSObject
@property(copy) NSString *owner;
@property(copy) NSString *lastPath;
@property(strong) id lastParameters;
- (id)taskWithMethod:(NSString *)method path:(NSString *)path parameters:(id)parameters completion:(Completion)completion;
- (id)authorizationCredential;
- (id)currentUser;
@end
@implementation RDKClient
- (id)authorizationCredential { return nil; }
- (id)currentUser { return @{@"username": self.owner}; }
- (id)taskWithMethod:(NSString *)method path:(NSString *)path parameters:(id)parameters completion:(Completion)completion {
    (void)method; NSCAssert(sApolloWebJSONResendingAfterWebBearerMint, @"one mint per call");
    sends++; self.lastPath = path; self.lastParameters = parameters;
    sent = [MockTask new]; sent.completion = completion; return sent;
}
@end
static BOOL ApolloWebJSONPathNeedsWebBearer(NSString *path) { return [path hasPrefix:@"api/mod/"]; }
static BOOL ApolloWebJSONRequestNeedsWebBearer(NSString *method, NSString *path) { return [method isEqual:@"GET"] && [path containsString:@"search"]; }
static id ApolloWebSessionFor(NSString *owner) { return [@[@"alice", @"bob"] containsObject:owner] ? @YES : nil; }
static NSString *ApolloWebJSONCredentialTokenString(id credential) { (void)credential; return nil; }
static NSString *ApolloWebJSONWebSessionUsernameForBearer(NSString *token) { (void)token; return @"alice"; }
// PRODUCTION_ACCOUNT_RESOLUTION
static BOOL ApolloWebJSONWebBearerNeedsMint(NSString *username) { return username.length > 0 && needsMint; }
static NSString *ApolloWebJSONKeylessOAuthBearer(NSString *username) { mints++; mintOwner = username; return @"web-token"; }
static void TestAsync(dispatch_queue_t queue, dispatch_block_t block) { (void)queue; [work addObject:[block copy]]; }
#define dispatch_async TestAsync
static id Begin(RDKClient *self, NSString *method, NSString *path, id parameters, Completion completion) {
// PRODUCTION_MINT_BRANCH
    return @"already-ready";
}
#undef dispatch_async
static void Check(BOOL okay, NSString *why) { if (!okay) { NSLog(@"FAIL: %@", why); abort(); } }
static void Drain(void) { while (work.count) { dispatch_block_t b=work.firstObject; [work removeObjectAtIndex:0]; b(); } }
int main(void) { @autoreleasepool {
    work = [NSMutableArray array]; RDKClient *client = [RDKClient new]; client.owner = @"bob";
    Completion completion = ^(NSHTTPURLResponse *response, id object, NSError *error) { (void)response; calls++; lastObject=object; lastError=error; };
    NSDictionary *params = @{@"q":@"apollo", @"after":@"t3_next", @"sort":@"new"};
    for (NSUInteger cancelStage=0; cancelStage<3; cancelStage++) {
        calls=0; sends=0; lastError=nil; lastObject=nil;
        id pending = Begin(client,@"GET",@"r/ios/search.json",params,completion);
        Check(pending != nil && sends==0, @"cancellable handle before async mint");
        [(NSURLSessionTask *)pending resume]; Check(placeholder.resumes==0, @"placeholder must never send");
        if (cancelStage==0) [pending cancel];
        if (cancelStage==1) { dispatch_block_t b=work.firstObject; [work removeObjectAtIndex:0]; b(); [pending cancel]; }
        Drain();
        if (cancelStage==2) {
            Check(sends==1, @"native request starts once"); [pending cancel];
            Check(sent.cancels==1, @"cancellation reaches attached task"); sent.completion(nil,@{@"data":@{}},nil);
            sent.completion(nil,@{@"data":@{}},nil);
        } else Check(sends==0, @"cancelled pending search never sends");
        Check(calls==1 && lastObject==nil && lastError.code==NSURLErrorCancelled, @"cancellation delivered once without stale result");
        Check([(NSURLSessionTask *)pending state]==NSURLSessionTaskStateCompleted, @"cancelled request completes");
    }
    calls=0; sends=0; lastError=nil; lastObject=nil;
    id pending=Begin(client,@"GET",@"search.json",params,completion); Drain();
    Check(sends==1 && [mintOwner isEqual:@"bob"] && [client.lastPath isEqual:@"search.json"] && client.lastParameters==params, @"owning account, query and pagination retained");
    Check([(NSURLSessionTask *)pending taskIdentifier]==42, @"task interface forwards after attachment");
    sent.completion(nil,@{@"data":@{}},nil); Check(calls==1 && lastObject && !lastError, @"ordinary response delivered");
    [pending cancel]; Check(sent.cancels==0, @"cancel after completion has no effect");
    ApolloWebJSONDeferredTask *race=[[ApolloWebJSONDeferredTask alloc] init]; [race cancel];
    MockTask *late=[MockTask new]; [race attachTask:(NSURLSessionTask *)late]; Check(late.cancels==1, @"cancellation transfers across attachment race");
    calls=0;
    NSMutableDictionary *changing=[@{@"q":@"original"} mutableCopy];
    Begin(client,@"GET",@"search.json",changing,completion); changing[@"q"]=@"new query"; Drain();
    Check([client.lastParameters[@"q"] isEqual:@"original"], @"parameters snapshotted before asynchronous mint");
    sent.completion(nil,nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil]);
    Check(calls==1 && lastError.code==NSURLErrorCannotConnectToHost, @"request failure delivered unchanged");
    RDKClient *oauth=[RDKClient new]; oauth.owner=@"oauth-user";
    Check([Begin(oauth,@"GET",@"search.json",params,completion) isEqual:@"already-ready"], @"named API-key client never borrows active web session");
    needsMint=NO; Check([Begin(client,@"GET",@"search.json",params,completion) isEqual:@"already-ready"], @"warm bearer bypasses deferral");
    Check(mints==5, @"one mint per deferred request");
    puts("web json search task tests passed");
} }
