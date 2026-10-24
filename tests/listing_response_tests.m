#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#define ApolloLog(...) do { if (NO) NSLog(__VA_ARGS__); } while (0)
// PRODUCTION_HELPERS

typedef void (^Completion)(NSHTTPURLResponse *, id, NSError *);
// Duplicate-read sharing only acts for API-Key-Free accounts; these clients
// have none, so every request goes out with its own completion.
typedef Completion ApolloWebJSONTaskCompletion;
static ApolloWebJSONTaskCompletion ApolloWebJSONShareAccountRead(NSString *username, NSString *method, NSString *path,
                                                                id parameters, ApolloWebJSONTaskCompletion completion) {
    (void)username; (void)method; (void)path; (void)parameters;
    return completion;
}
static id ApolloWebJSONSharedReadPlaceholderTask(void) { return nil; }
// The API-Key-Free subscription-walk helpers (page size, cut-short-walk
// guard) only act for web-session accounts; these clients have none.
static id ApolloWebJSONParametersForAccountRead(NSString *username, NSString *method, NSString *path, id parameters) {
    (void)username; (void)method; (void)path;
    return parameters;
}
static BOOL ApolloWebJSONRequestIsSubscriptionWalk(NSString *method, NSString *path) { (void)method; (void)path; return NO; }
static void ApolloWebJSONNoteSubscriptionWalkFailed(NSString *username, NSHTTPURLResponse *response, NSError *error) {
    (void)username; (void)response; (void)error;
}
static id nextObject;
static NSError *nextError;
static NSHTTPURLResponse *nextResponse;
@interface RDKClient : NSObject
- (id)taskWithMethod:(NSString *)method path:(NSString *)path parameters:(id)parameters completion:(Completion)completion;
@end
@implementation RDKClient
- (id)taskWithMethod:(NSString *)method path:(NSString *)path parameters:(id)parameters completion:(Completion)completion {
    (void)method; (void)path; (void)parameters;
    if (completion) completion(nextResponse, nextObject, nextError);
    return @"task";
}
@end
// These tests isolate response-shape handling. Session-state behavior is
// covered separately in session_expiry_tests.m.
static BOOL ApolloWebJSONShouldActForClient(RDKClient *client) { (void)client; return NO; }
static NSString *ApolloWebJSONClientUsername(RDKClient *client) { (void)client; return nil; }
static void ApolloWebJSONNoteMalformedAccountResponse(NSString *username, NSString *path) { (void)username; (void)path; }
static void ApolloWebJSONCheckAccountSession(NSString *username) { (void)username; }
static NSError *ApolloWebJSONAccountSessionError(NSString *username) { (void)username; return nil; }
// PRODUCTION_HOOK

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); abort(); }
}
int main(void) {
    @autoreleasepool {
        RDKClient *client = [RDKClient new];
        NSUInteger checks = 0;
        // Reproduce the native callback, which indexes non-nil objects before
        // checking the error. Both moderated-subreddits and blocked-users native
        // callbacks have this behavior (0x100040084 and 0x10003f6ec). Include
        // redirects outside the Reddit host/path.
        for (NSString *destination in @[@"https://www.reddit.com/subreddits/mine/moderator.json",
                                         @"https://www.reddit.com/login", @"https://example.com/error"]) {
            nextResponse = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:destination]
                statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
            for (id bad in @[@"{}", @[], @42, [NSNull null]]) {
                for (NSString *path in @[@"subreddits/mine/moderator.json", @"/subreddits/mine/moderator.json?limit=100",
                                         @"prefs/blocked.json", @"/prefs/blocked.json?raw_json=1",
                                         @"prefs/blocked", @"prefs/blocked/"] ) {
                    for (NSNumber *hasError in @[@NO, @YES]) {
                        nextObject = bad;
                        nextError = hasError.boolValue ? [NSError errorWithDomain:NSURLErrorDomain code:-1009 userInfo:nil] : nil;
                        NSError *original = nextError;
                        __block BOOL called = NO;
                        id task = [client taskWithMethod:@"GET" path:path parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
                            called = YES;
                            (void)response;
                            if (object) (void)object[@"data"];
                            Check(object == nil && error != nil, @"bad listing must fail without indexing");
                            if (original) Check(error == original, @"preserve original error");
                        }];
                        Check(called && [task isEqual:@"task"], @"forward completion and task");
                        checks++;
                    }
                }
            }
        }
        // Endpoints with valid array/scalar roots must keep their actual value.
        nextError = nil;
        for (NSString *path in @[@"comments/abc.json", @"r/test/comments/abc.json", @"duplicates/abc.json",
                                 @"r/test/duplicates/abc.json", @"prefs/friends.json", @"api/multi/mine.json",
                                 @"prefs/unknown.json", @"prefs/blocked/unknown.json"]) {
            nextObject = @[@"sentinel"];
            [client taskWithMethod:@"GET" path:path parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
                (void)response; Check(object == nextObject && error == nil, @"valid array root untouched");
            }]; checks++;
        }
        for (NSString *path in @[@"subreddits/mine/moderator.json", @"prefs/blocked.json"]) {
            for (id good in @[@{}, @{@"data": @{@"children": @[]}}]) {
                nextObject = good;
                [client taskWithMethod:@"GET" path:path parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
                    (void)response; Check(object == good && error == nil, @"dictionary untouched");
                    // Match both native completions: data then children.
                    Check(object[@"data"][@"children"] == good[@"data"][@"children"], @"native listing extraction unchanged");
                }]; checks++;
            }
        }
        // #1420: RDKResponseSerializer turns a reply that isn't application/json
        // (Reddit's HTML 429 and 403 block pages, an empty 429, an HTML 5xx) into
        // no object AND no error, and RedditKit maps no error for a JSON 429. A
        // listing must report that as a failed load, not read it as a last page.
        NSHTTPURLResponse *okResponse = nextResponse;
        for (NSString *path in @[@"r/popular/best.json", @"/r/all/hot.json?after=t3_abc&limit=25", @"best.json",
                                 @"user/someone/submitted.json", @"subreddits/mine/subscriber.json", @"message/inbox.json"]) {
            for (NSNumber *status in @[@429, @403, @503, @200]) {
                for (id body in @[[NSNull null], @{@"message": @"Too Many Requests", @"error": @429}]) {
                    BOOL json = ![body isEqual:[NSNull null]];
                    if (json && status.integerValue == 200) continue; // a 200 dictionary is a real answer
                    nextResponse = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://www.reddit.com/r/popular/best.json"]
                        statusCode:status.integerValue HTTPVersion:@"HTTP/1.1" headerFields:@{}];
                    nextObject = json ? body : nil;
                    nextError = nil;
                    __block BOOL called = NO;
                    [client taskWithMethod:@"GET" path:path parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
                        called = YES;
                        (void)response;
                        if (object) (void)object[@"data"];
                        Check(object == nil && [error.domain isEqualToString:@"ApolloReborn.WebJSON.Response"] && error.code == 1420,
                              @"a refused listing must fail, not read as an empty page");
                    }];
                    Check(called, @"forward completion");
                    checks++;
                }
            }
        }
        // An error RedditKit or the transport already reported passes through,
        // with whatever object came with it.
        NSError *transportError = [NSError errorWithDomain:NSURLErrorDomain code:-1009 userInfo:nil];
        for (id body in @[[NSNull null], @{@"error": @429}]) {
            nextObject = [body isEqual:[NSNull null]] ? nil : body;
            nextError = transportError;
            [client taskWithMethod:@"GET" path:@"r/popular/best.json" parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
                (void)response; Check(error == transportError && object == nextObject, @"reported errors untouched");
            }]; checks++;
        }
        // Endpoints that aren't listing dictionaries keep their nil answer.
        nextObject = nil;
        nextError = nil;
        for (NSString *path in @[@"api/multi/mine.json", @"api/v1/me.json", @"comments/abc.json"]) {
            [client taskWithMethod:@"GET" path:path parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
                (void)response; Check(object == nil && error == nil, @"non-listing nil untouched");
            }]; checks++;
        }
        nextResponse = okResponse;
        nextObject = @"ok";
        [client taskWithMethod:@"POST" path:@"subreddits/mine/moderator.json" parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
            (void)response; Check(object == nextObject && error == nil, @"writes untouched");
        }]; checks++;
        nextObject = nil;
        [client taskWithMethod:@"GET" path:@"subreddits/mine/moderator.json" parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
            (void)response; Check(object == nil && error.code == 1420, @"nil without an error reports a failed load");
        }]; checks++;
        Check([[client taskWithMethod:@"GET" path:@"subreddits/mine/moderator.json" parameters:nil completion:nil] isEqual:@"task"], @"nil completion forwarded");
        NSLog(@"PASS: %lu listing response cases plus nil completion", (unsigned long)checks);
    }
}
