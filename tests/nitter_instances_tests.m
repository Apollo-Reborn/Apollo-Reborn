#import <Foundation/Foundation.h>
#import "ApolloNitterInstances.h"

static NSUInteger checks;
static NSUInteger failures;

static void Check(BOOL ok, NSString *label) {
    checks++;
    if (!ok) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", label.UTF8String);
    }
}

static void CheckRewrite(NSString *input, NSString *expected) {
    NSURL *result = ApolloNitterURLForTwitterURL([NSURL URLWithString:input], @"nitter.example.org");
    NSString *actual = result.absoluteString;
    BOOL ok = expected ? [actual isEqualToString:expected] : actual == nil;
    Check(ok, [NSString stringWithFormat:@"rewrite %@ -> %@ (got %@)", input, expected ?: @"nil", actual ?: @"nil"]);
}

static void CheckHost(NSString *input, NSString *expected) {
    NSString *actual = ApolloNitterNormalizeHost(input);
    BOOL ok = expected ? [actual isEqualToString:expected] : actual == nil;
    Check(ok, [NSString stringWithFormat:@"normalize '%@' -> %@ (got %@)", input, expected ?: @"nil", actual ?: @"nil"]);
}

int main(void) {
    @autoreleasepool {
        // Posts and profiles on every web front door; tracking params dropped.
        CheckRewrite(@"https://x.com/jack/status/20?s=20&t=abc", @"https://nitter.example.org/jack/status/20");
        CheckRewrite(@"https://twitter.com/jack", @"https://nitter.example.org/jack");
        CheckRewrite(@"https://mobile.twitter.com/jack/status/20", @"https://nitter.example.org/jack/status/20");
        CheckRewrite(@"https://www.x.com/jack/status/20/photo/1", @"https://nitter.example.org/jack/status/20/photo/1");
        CheckRewrite(@"http://X.com/Jack/status/20#frag", @"https://nitter.example.org/Jack/status/20");
        CheckRewrite(@"https://x.com", @"https://nitter.example.org/");
        CheckRewrite(@"https://x.com/hashtag/apollo?src=hashtag_click", @"https://nitter.example.org/hashtag/apollo");

        // Supported /i/ routes pass through; others keep normal routing.
        CheckRewrite(@"https://x.com/i/status/20", @"https://nitter.example.org/i/status/20");
        CheckRewrite(@"https://x.com/i/web/status/20", @"https://nitter.example.org/i/web/status/20");
        CheckRewrite(@"https://x.com/i/spaces/1abc", @"https://nitter.example.org/i/spaces/1abc");
        CheckRewrite(@"https://x.com/i/lists/123", @"https://nitter.example.org/i/lists/123");
        CheckRewrite(@"https://x.com/i/bookmarks", nil);
        CheckRewrite(@"https://x.com/i", nil);

        // X app pages and non-front-door hosts are left alone.
        CheckRewrite(@"https://x.com/home", nil);
        CheckRewrite(@"https://x.com/explore", nil);
        CheckRewrite(@"https://x.com/messages", nil);
        CheckRewrite(@"https://x.com/intent/post?text=hi", nil);
        CheckRewrite(@"https://help.x.com/en/rules", nil);
        CheckRewrite(@"https://api.x.com/graphql", nil);
        CheckRewrite(@"https://t.co/abc", nil);
        CheckRewrite(@"https://example.com/jack/status/20", nil);
        CheckRewrite(@"twitter://status?id=20", nil);

        // Search keeps its query text and maps the people tab.
        CheckRewrite(@"https://x.com/search?q=apollo%20app&src=typed_query", @"https://nitter.example.org/search?f=tweets&q=apollo%20app");
        CheckRewrite(@"https://x.com/search?q=apollo&f=user", @"https://nitter.example.org/search?f=users&q=apollo");
        CheckRewrite(@"https://x.com/search", @"https://nitter.example.org/search");

        // Instance ports carry over.
        NSURL *ported = ApolloNitterURLForTwitterURL([NSURL URLWithString:@"https://x.com/jack"], @"nitter.example.org:8443");
        Check([ported.absoluteString isEqualToString:@"https://nitter.example.org:8443/jack"], @"rewrite keeps instance port");
        Check(ApolloNitterURLForTwitterURL([NSURL URLWithString:@"https://x.com/jack"], @"") == nil, @"empty instance -> nil");

        // A plain-http instance (self-hosted, no TLS) is opened over http, not upgraded.
        NSURL *plain = ApolloNitterURLForTwitterURL([NSURL URLWithString:@"https://x.com/jack/status/20?s=20"], @"http://192.168.1.5:8080");
        Check([plain.absoluteString isEqualToString:@"http://192.168.1.5:8080/jack/status/20"], @"rewrite keeps plain-http instance scheme and port");
        NSURL *plainNoPort = ApolloNitterURLForTwitterURL([NSURL URLWithString:@"https://x.com/jack"], @"http://nitter.lan.example");
        Check([plainNoPort.absoluteString isEqualToString:@"http://nitter.lan.example/jack"], @"rewrite keeps plain-http instance scheme");

        // Host normalization.
        CheckHost(@"nitter.example.org", @"nitter.example.org");
        CheckHost(@"  Nitter.Example.ORG  ", @"nitter.example.org");
        CheckHost(@"https://nitter.example.org/foo?bar=1", @"nitter.example.org");
        CheckHost(@"http://nitter.example.org", @"http://nitter.example.org");
        CheckHost(@"HTTP://192.168.1.5:8080/", @"http://192.168.1.5:8080");
        CheckHost(@"http://nitter.example.org:80", @"http://nitter.example.org");
        CheckHost(@"http://nitter.example.org:443", @"http://nitter.example.org:443");
        CheckHost(@"https://nitter.example.org:80", @"nitter.example.org:80");
        CheckHost(@"http://x.com", nil);
        CheckHost(@"nitter.example.org:8443", @"nitter.example.org:8443");
        CheckHost(@"https://nitter.example.org:443", @"nitter.example.org");
        CheckHost(@"x.com", nil);
        CheckHost(@"https://mobile.twitter.com", nil);
        CheckHost(@"not a host", nil);
        CheckHost(@"localhost", nil);
        CheckHost(@"-bad.example.org", nil);
        CheckHost(@"ftp://nitter.example.org", nil);
        CheckHost(@"user:pass@nitter.example.org", nil);
        CheckHost(@"", nil);
        CheckHost(nil, nil);

        // Tracker parsing: healthy only, sorted by points, malformed skipped.
        NSString *payload = @"{\"hosts\":["
            "{\"domain\":\"slow.example.org\",\"healthy\":true,\"points\":38,\"ping_avg\":3969},"
            "{\"domain\":\"down.example.org\",\"healthy\":false,\"points\":0,\"ping_avg\":null},"
            "{\"domain\":\"best.example.org\",\"healthy\":true,\"points\":78,\"ping_avg\":866},"
            "{\"domain\":\"BEST.example.org\",\"healthy\":true,\"points\":10},"
            "{\"domain\":42,\"healthy\":true},"
            "\"junk\","
            "{\"domain\":\"x.com\",\"healthy\":true,\"points\":99},"
            "{\"domain\":\"http://plain.example.org\",\"healthy\":true,\"points\":90}"
            "],\"last_update\":\"2026-10-01T18:11:47Z\"}";
        NSArray<ApolloNitterInstance *> *parsed = ApolloNitterParseInstanceList([payload dataUsingEncoding:NSUTF8StringEncoding]);
        Check(parsed.count == 2, [NSString stringWithFormat:@"parse keeps 2 healthy hosts (got %lu)", (unsigned long)parsed.count]);
        Check([parsed.firstObject.host isEqualToString:@"best.example.org"] && parsed.firstObject.points == 78 &&
              parsed.firstObject.averagePingMilliseconds == 866, @"parse sorts by points and reads fields");
        Check([parsed.lastObject.host isEqualToString:@"slow.example.org"], @"parse keeps lower-scored host last");
        Check(ApolloNitterParseInstanceList([@"[]" dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"parse rejects non-object");
        Check(ApolloNitterParseInstanceList([@"<html>429</html>" dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"parse rejects HTML");
        Check([ApolloNitterParseInstanceList([@"{\"hosts\":[]}" dataUsingEncoding:NSUTF8StringEncoding]) count] == 0, @"parse accepts empty list");
    }

    if (failures > 0) {
        fprintf(stderr, "nitter_instances_tests: %lu of %lu checks failed\n", (unsigned long)failures, (unsigned long)checks);
        return 1;
    }
    printf("nitter_instances_tests: all %lu checks passed\n", (unsigned long)checks);
    return 0;
}
