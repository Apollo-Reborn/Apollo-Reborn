#import <Foundation/Foundation.h>
#import "ApolloWebJSONRoutes.h"
#define ApolloLog(...) do {} while (0)
#define os_log_debug(...) do {} while (0)
static BOOL sWebJSONEnabled = YES;
@interface ApolloWebSessionEntry : NSObject
@property(copy) NSString *cookieHeader;
@property(copy) NSString *modhash;
@end
@implementation ApolloWebSessionEntry
@end
static NSMutableDictionary *sessions;
static NSMutableDictionary *bearers;
static NSString *active;
static ApolloWebSessionEntry *ApolloWebSessionFor(NSString *username) { return sessions[username]; }
static NSString *ApolloActiveWebSessionUsername(void) { return active; }
static ApolloWebSessionEntry *ApolloActiveWebSession(void) { return sessions[active]; }
static NSString *ApolloWebJSONReadyWebBearer(NSString *username) { return bearers[username]; }
static NSString *ApolloWebJSONBrowserUserAgent(void) { return @"browser"; }
// Non-search classifications/writes are unchanged; use inert stubs to isolate
// the actual transport, account attribution, markers and bearer request below.
typedef NS_ENUM(NSInteger, ApolloWebJSONPathKind) {
    ApolloWebJSONPathUnsupported, ApolloWebJSONPathListing, ApolloWebJSONPathAPI
};
static ApolloWebJSONPathKind ApolloWebJSONClassifyReadPath(NSString *path) { (void)path; return ApolloWebJSONPathListing; }
static BOOL ApolloWebJSONWritePathIsRoutable(NSString *path) { (void)path; return NO; }
static NSString *ApolloWebJSONModeratorsPathSubreddit(NSString *path) { (void)path; return nil; }
static NSString *ApolloWebJSONSubredditWriteAPIPath(NSString *path, NSString **sub) { (void)path; (void)sub; return nil; }
static NSData *ApolloWebJSONFormBodyAddingSubreddit(NSURLRequest *request, NSString *sub) { (void)request; (void)sub; return nil; }
static void ApolloWebJSONNoteRoute(NSString *method, NSString *path, ApolloWebJSONRoute route, NSString *sentPath) {
    (void)method; (void)path; (void)route; (void)sentPath;
}
// PRODUCTION_SEARCH_TRANSPORT
static void Check(BOOL valid, NSString *message) { if (!valid) { NSLog(@"FAIL: %@", message); abort(); } }
static NSMutableURLRequest *Request(NSString *path, NSString *token) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://oauth.reddit.com" stringByAppendingString:path]]];
    [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"stale-cookie" forHTTPHeaderField:@"Cookie"];
    [r setValue:@"custom-oauth-agent" forHTTPHeaderField:@"User-Agent"];
    return r;
}
int main(void) { @autoreleasepool {
    sessions = [NSMutableDictionary dictionary]; bearers = [NSMutableDictionary dictionary]; active = @"alice";
    for (NSString *name in @[@"alice", @"bob"]) {
        ApolloWebSessionEntry *entry = [ApolloWebSessionEntry new]; entry.cookieHeader = [@"session=" stringByAppendingString:name];
        sessions[name] = entry; bearers[name] = [@"web-token-" stringByAppendingString:name];
    }
    ApolloWebJSONRegisterAccountBearer(@"alice", @"restored-real-token");
    ApolloWebJSONRegisterAccountBearer(@"oauth-user", @"real-oauth-token");
    NSArray *paths = @[@"/search", @"/search.json", @"/search/.json", @"/subreddits/search.json",
        @"/r/iOS/search.json", @"/r/ios+apple/search/", @"/user/Alice/m/dev/search.json", @"/u/Bob/m/search/search.json"];
    for (NSString *path in paths) {
        Check(ApolloWebJSONRequestNeedsWebBearer(@"GET", path), path);
        Check(ApolloWebJSONRequestNeedsWebBearer(@"get", [path substringFromIndex:1]), @"relative, lowercase method");
        for (NSString *method in @[@"POST", @"PUT", @"DELETE", @"HEAD"]) {
            Check(!ApolloWebJSONRequestNeedsWebBearer(method, path), @"search writes must not use web bearer");
        }
        NSString *query = @"?q=apollo%20%26%20ios&restrict_sr=on&sort=new&t=week&after=t3_next&count=5&raw_json=1";
        for (NSString *name in @[@"alice", @"bob"]) {
            NSMutableURLRequest *original = Request([path stringByAppendingString:query], ApolloWebJSONSyntheticBearerTokenForUsername(name));
            NSURLRequest *sent = ApolloWebJSONRewriteRequest(original);
            Check([sent.URL.host isEqual:@"oauth.reddit.com"], @"search never uses Old Reddit");
            Check([sent.URL.path isEqual:original.URL.path] && [sent.URL.query isEqual:original.URL.query], @"scope, query, filters and pagination preserved");
            Check([[sent valueForHTTPHeaderField:@"Authorization"] isEqual:[@"Bearer web-token-" stringByAppendingString:name]], @"request account owns bearer, regardless of active account");
            Check([ApolloWebJSONAccountFromURL(sent.URL) isEqual:name], @"response account marker retained");
            Check(![sent valueForHTTPHeaderField:@"Cookie"] && !sent.HTTPShouldHandleCookies, @"cookie not mixed into bearer request");
            Check([[sent valueForHTTPHeaderField:@"User-Agent"] isEqual:@"browser"], @"web client identity");
            Check([[original valueForHTTPHeaderField:@"Cookie"] isEqual:@"stale-cookie"], @"original request unchanged");
        }
    }
    for (NSString *path in @[@"/searching", @"/search/extra", @"/r/ios/hot", @"/r/ios/search/extra",
        @"/user/alice/search", @"/api/search_reddit_names", @"/subreddits/mine/subscriber", @"/comments/abc", @"/"]) {
        Check(!ApolloWebJSONRequestNeedsWebBearer(@"GET", path), @"nearby reads keep existing transport");
    }
    for (NSString *path in @[@"/api/mod/conversations", @"api/v1/ios/removal_reasons", @"r/ios/api/friend"]) {
        Check(ApolloWebJSONRequestNeedsWebBearer(@"POST", path), @"existing moderator routing preserved");
    }
    Check(ApolloWebJSONRewriteRequest(Request(@"/search.json?q=apollo", @"real-oauth-token")) == nil, @"API-key accounts untouched");
    NSURLRequest *restored = ApolloWebJSONRewriteRequest(Request(@"/search.json?q=apollo", @"restored-real-token"));
    Check([[restored valueForHTTPHeaderField:@"Authorization"] isEqual:@"Bearer web-token-alice"], @"restored keyless account gets own web bearer");
    [bearers removeObjectForKey:@"bob"];
    NSURLRequest *noBearer = ApolloWebJSONRewriteRequest(Request(@"/search.json?q=apollo", ApolloWebJSONSyntheticBearerTokenForUsername(@"bob")));
    Check([noBearer.URL.host isEqual:@"www.reddit.com"], @"failed/held mint never falls back to Old Reddit or loops on placeholder OAuth token");
    Check(![noBearer valueForHTTPHeaderField:@"Authorization"] && [[noBearer valueForHTTPHeaderField:@"Cookie"] isEqual:@"session=bob"], @"failed mint stays attributed to same account");
    sWebJSONEnabled = NO;
    Check(ApolloWebJSONRewriteRequest(Request(@"/search.json", ApolloWebJSONSyntheticBearerTokenForUsername(@"alice"))) == nil, @"disabled transport unchanged");
    puts("web json search transport tests passed");
} }
