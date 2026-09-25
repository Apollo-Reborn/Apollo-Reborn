#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#define ApolloLog(...) do { if (NO) NSLog(__VA_ARGS__); } while (0)
// PRODUCTION_HELPERS

typedef void (^Completion)(NSHTTPURLResponse *, id, NSError *);
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
        nextObject = @"ok";
        [client taskWithMethod:@"POST" path:@"subreddits/mine/moderator.json" parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
            (void)response; Check(object == nextObject && error == nil, @"writes untouched");
        }]; checks++;
        nextObject = nil;
        [client taskWithMethod:@"GET" path:@"subreddits/mine/moderator.json" parameters:nil completion:^(NSHTTPURLResponse *response, id object, NSError *error) {
            (void)response; Check(object == nil && error == nil, @"nil unchanged");
        }]; checks++;
        Check([[client taskWithMethod:@"GET" path:@"subreddits/mine/moderator.json" parameters:nil completion:nil] isEqual:@"task"], @"nil completion forwarded");
        NSLog(@"PASS: %lu listing response cases plus nil completion", (unsigned long)checks);
    }
}
