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
        @"/r/iOS/search.json", @"/r/ios+apple/search/", @"/r/apollosideloaded+ApolloReborn+ApolloAppBeta+apolloapp/search.json"];
    for (NSString *path in paths) {
        Check(ApolloWebJSONRequestIsSearchRead(@"GET", path), path);
        Check(ApolloWebJSONRequestIsSearchRead(@"get", [path substringFromIndex:1]), @"relative, lowercase method");
        Check(!ApolloWebJSONPathNeedsWebBearer(path), @"search never uses the web bearer");
        for (NSString *method in @[@"POST", @"PUT", @"DELETE", @"HEAD"]) {
            Check(!ApolloWebJSONRequestIsSearchRead(method, path), @"search writes aren't search reads");
        }
        NSString *query = @"?q=apollo%20%26%20ios&restrict_sr=on&sort=new&t=week&after=t3_next&count=5&raw_json=1";
        for (NSString *name in @[@"alice", @"bob"]) {
            NSMutableURLRequest *original = Request([path stringByAppendingString:query], ApolloWebJSONSyntheticBearerTokenForUsername(name));
            NSURLRequest *sent = ApolloWebJSONRewriteRequest(original);
            NSString *expectedPath = original.URL.path;
            if (![expectedPath hasSuffix:@".json"]) {
                while ([expectedPath hasSuffix:@"/"] && expectedPath.length > 1) expectedPath = [expectedPath substringToIndex:expectedPath.length - 1];
                expectedPath = [expectedPath stringByAppendingString:@".json"];
            }
            Check([sent.URL.host isEqual:@"oauth.reddit.com"], @"search goes by its oauth route");
            Check([sent.URL.path isEqual:expectedPath], @"scope preserved, .json added");
            Check([sent.URL.query isEqual:original.URL.query], @"query, filters and pagination preserved");
            Check(![sent valueForHTTPHeaderField:@"Authorization"], @"no bearer: search uses the cookie alone");
            Check([[sent valueForHTTPHeaderField:@"Cookie"] isEqual:[@"session=" stringByAppendingString:name]], @"request account's cookie, regardless of active account");
            Check(!sent.HTTPShouldHandleCookies, @"cookie jar not consulted");
            Check([ApolloWebJSONAccountFromURL(sent.URL) isEqual:name], @"response account marker retained");
            Check(ApolloWebJSONRouteFromURL(sent.URL) == ApolloWebJSONRouteOAuth, @"oauth route marker, for route health and resends");
            Check([[sent valueForHTTPHeaderField:@"User-Agent"] isEqual:@"browser"], @"web client identity");
            Check([[original valueForHTTPHeaderField:@"Cookie"] isEqual:@"stale-cookie"], @"original request unchanged");
        }
    }
    for (NSString *path in @[@"/searching", @"/search/extra", @"/r/ios/hot", @"/r/ios/search/extra", @"/user/Alice/m/dev/search.json",
        @"/user/alice/search", @"/api/search_reddit_names", @"/subreddits/mine/subscriber", @"/comments/abc", @"/"]) {
        Check(!ApolloWebJSONRequestIsSearchRead(@"GET", path), @"nearby reads aren't search");
        NSURLRequest *sent = ApolloWebJSONRewriteRequest(Request(path, ApolloWebJSONSyntheticBearerTokenForUsername(@"alice")));
        Check([sent.URL.host isEqual:@"www.reddit.com"], @"nearby reads keep the www cookie route");
    }
    for (NSString *method in @[@"POST", @"PUT", @"DELETE"]) {
        NSMutableURLRequest *write = Request(@"/search.json", ApolloWebJSONSyntheticBearerTokenForUsername(@"alice"));
        write.HTTPMethod = method;
        Check(ApolloWebJSONRewriteRequest(write) == nil, @"writes to search paths aren't rewritten as search");
    }
    for (NSString *path in @[@"/api/mod/conversations", @"api/v1/ios/removal_reasons", @"r/ios/api/friend"]) {
        Check(ApolloWebJSONPathNeedsWebBearer(path), @"existing moderator routing preserved");
        Check(!ApolloWebJSONRequestIsSearchRead(@"GET", path), @"moderator endpoints aren't search");
    }
    NSURLRequest *mod = ApolloWebJSONRewriteRequest(Request(@"/api/mod/conversations", ApolloWebJSONSyntheticBearerTokenForUsername(@"alice")));
    Check([mod.URL.host isEqual:@"oauth.reddit.com"] && [[mod valueForHTTPHeaderField:@"Authorization"] isEqual:@"Bearer web-token-alice"]
          && ![mod valueForHTTPHeaderField:@"Cookie"], @"moderator endpoints still get the ready web bearer");
    Check(ApolloWebJSONRewriteRequest(Request(@"/search.json?q=apollo", @"real-oauth-token")) == nil, @"API-key accounts untouched");
    NSURLRequest *restored = ApolloWebJSONRewriteRequest(Request(@"/search.json?q=apollo", @"restored-real-token"));
    Check([restored.URL.host isEqual:@"oauth.reddit.com"] && ![restored valueForHTTPHeaderField:@"Authorization"]
          && [[restored valueForHTTPHeaderField:@"Cookie"] isEqual:@"session=alice"], @"restored keyless account searches with its own cookie");
    NSURLRequest *placeholder = ApolloWebJSONRewriteRequest(Request(@"/search.json?q=apollo", ApolloWebJSONSyntheticBearerToken));
    Check(placeholder && ![placeholder valueForHTTPHeaderField:@"Authorization"], @"placeholder bearer is stripped from search");
    [bearers removeAllObjects];
    NSURLRequest *noBearer = ApolloWebJSONRewriteRequest(Request(@"/search.json?q=apollo", ApolloWebJSONSyntheticBearerTokenForUsername(@"bob")));
    Check([noBearer.URL.host isEqual:@"oauth.reddit.com"] && [[noBearer valueForHTTPHeaderField:@"Cookie"] isEqual:@"session=bob"],
          @"search doesn't depend on a web bearer");
    ApolloWebJSONRouteHealthReset();
    for (int i = 0; i < 3; i++) ApolloWebJSONRouteHealthNoteBlockPage(@"alice", @"/r/apple/search.json", ApolloWebJSONRouteOAuth, [NSDate timeIntervalSinceReferenceDate]);
    NSURLRequest *fallback = ApolloWebJSONRewriteRequest(Request(@"/r/iOS/search?q=apollo&restrict_sr=on", ApolloWebJSONSyntheticBearerTokenForUsername(@"alice")));
    Check([fallback.URL.host isEqual:@"old.reddit.com"] && [fallback.URL.path isEqual:@"/r/iOS/search.json"]
          && [fallback.URL.query isEqual:@"q=apollo&restrict_sr=on"], @"oauth cooling: search goes by old");
    Check(ApolloWebJSONRouteFromURL(fallback.URL) == ApolloWebJSONRouteOld && ![fallback valueForHTTPHeaderField:@"Authorization"]
          && [[fallback valueForHTTPHeaderField:@"Cookie"] isEqual:@"session=alice"], @"old route marker, cookie, no bearer");
    NSURLRequest *global = ApolloWebJSONRewriteRequest(Request(@"/search?q=apollo", ApolloWebJSONSyntheticBearerTokenForUsername(@"alice")));
    Check([global.URL.host isEqual:@"oauth.reddit.com"], @"global search keeps oauth");
    ApolloWebJSONRouteHealthReset();
    sWebJSONEnabled = NO;
    Check(ApolloWebJSONRewriteRequest(Request(@"/search.json", ApolloWebJSONSyntheticBearerTokenForUsername(@"alice"))) == nil, @"disabled transport unchanged");
    puts("web json search transport tests passed");
} }
