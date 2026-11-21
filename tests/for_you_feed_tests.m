// Host tests for src/ApolloForYouFeedModel.m (tests/run_for_you_feed_tests.sh).
// The HTML below is synthetic: it copies the attribute layout of Reddit's
// interest-home-feed fragment (captured 2026-11-01) with made-up values.
#import <Foundation/Foundation.h>
#import "ApolloForYouFeedModel.h"

static int sFailures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static NSString *Post(NSString *fullname, NSString *extra) {
    return [NSString stringWithFormat:
        @"<article><shreddit-post data-ks-item=\"\" class=\"block relative\" permalink=\"/r/x/comments/%@/t/\" "
        @"content-href=\"https://i.redd.it/a.jpeg\" comment-count=\"5\" user-id=\"t2_viewer\" "
        @"created-timestamp=\"2026-11-01T20:19:28.635000+0000\" domain=\"i.redd.it\" id=\"%@\" "
        @"post-title=\"A &gt; B\" post-type=\"image\" subreddit-id=\"t5_sub\" author-id=\"t2_author\" user-logged-in=\"\" %@>"
        @"<shreddit-post-flair></shreddit-post-flair><shreddit-post-overflow-menu></shreddit-post-overflow-menu>"
        @"</shreddit-post></article>",
        [fullname substringFromIndex:3], fullname, extra ?: @""];
}

static void TestParse(void) {
    NSMutableString *html = [NSMutableString string];
    [html appendString:Post(@"t3_aaa111", nil)];
    [html appendString:@"<shreddit-ad-post id=\"t3_adpost1\" promoted></shreddit-ad-post>"];
    [html appendString:Post(@"t3_bbb222", @"recommendation-source=\"comments_on_subreddits\"")];
    [html appendString:Post(@"t3_aaa111", nil)]; // duplicate
    [html appendString:Post(@"t3_ccc333", @"promoted")];
    [html appendString:Post(@"t3_ddd444", @"is-subscribed")];
    [html appendString:@"<shreddit-player post-id=\"t3_zzz999\"></shreddit-player>"];
    [html appendString:@"<faceplate-partial src=\"/svc/shreddit/feeds/interest-home-feed?after=dDNfZGRkNDQ0&amp;feed=for-you\"></faceplate-partial>"];

    NSArray *ids = ApolloForYouFeedParsePostIDs(html);
    NSArray *expected = @[ @"t3_aaa111", @"t3_bbb222", @"t3_ddd444" ];
    CHECK([ids isEqualToArray:expected], "parsed %s", ids.description.UTF8String);
    CHECK(ApolloForYouFeedHTMLHasNextPage(html), "next page link not found");
    CHECK(!ApolloForYouFeedHTMLHasNextPage(Post(@"t3_aaa111", nil)), "next page found where none");
    CHECK(ApolloForYouFeedParsePostIDs(nil).count == 0, "nil html");
    CHECK(ApolloForYouFeedHTMLIsSignedIn(html), "signed-in render");
    NSString *signedOut = [Post(@"t3_eee555", nil) stringByReplacingOccurrencesOfString:@" user-logged-in=\"\"" withString:@""];
    CHECK(!ApolloForYouFeedHTMLIsSignedIn(signedOut), "signed-out render");
    CHECK(ApolloForYouFeedHTMLIsSignedIn(@"<div></div>"), "no posts");
    CHECK(ApolloForYouFeedParsePostIDs(@"<html>login</html>").count == 0, "login page");
}

static void TestURL(void) {
    NSURL *first = ApolloForYouFeedPageURL(@"for-you", nil);
    CHECK([first.absoluteString isEqualToString:
           @"https://www.reddit.com/svc/shreddit/feeds/interest-home-feed?feed=for-you&render-mode=partial"],
          "first %s", first.absoluteString.UTF8String);
    // base64("t3_1xka3ey") = "dDNfMXhrYTNleQ==" — the value the website sent.
    NSURL *next = ApolloForYouFeedPageURL(@"for-you", @"t3_1xka3ey");
    CHECK([next.absoluteString isEqualToString:
           @"https://www.reddit.com/svc/shreddit/feeds/interest-home-feed?after=dDNfMXhrYTNleQ%3D%3D&feed=for-you&render-mode=partial"],
          "next %s", next.absoluteString.UTF8String);
    CHECK(ApolloForYouFeedPageURL(@"", nil) == nil, "empty feed");
}

static void TestHeaders(void) {
    NSDictionary *headers = @{ @"X-Ratelimit-Remaining": @"1978.0", @"x-ratelimit-reset": @"353" };
    CHECK(ApolloForYouFeedRateLimitRemaining(headers) == 1978.0, "remaining");
    CHECK(ApolloForYouFeedRateLimitReset(headers) == 353.0, "reset");
    CHECK(ApolloForYouFeedRateLimitRemaining(@{}) == -1, "missing");
    CHECK(ApolloForYouFeedRateLimitRemaining(@{ @"x-ratelimit-remaining": @"" }) == -1, "empty");
}

static NSDictionary *Child(NSString *name, BOOL hidden) {
    return @{ @"kind": @"t3", @"data": @{ @"name": name, @"hidden": @(hidden), @"title": name } };
}

static void TestChildren(void) {
    NSDictionary *response = @{ @"kind": @"Listing", @"data": @{ @"children": @[
        Child(@"t3_c", NO), Child(@"t3_a", NO), Child(@"t3_b", YES),
        @{ @"kind": @"t1", @"data": @{ @"name": @"t1_x" } },
    ] } };
    NSArray *ordered = ApolloForYouFeedOrderedChildren(response, @[ @"t3_a", @"t3_b", @"t3_missing", @"t3_c" ]);
    NSArray *names = [ordered valueForKeyPath:@"data.name"];
    CHECK([names isEqualToArray:(@[ @"t3_a", @"t3_c" ])], "ordered %s", names.description.UTF8String);
    NSArray *fromArray = ApolloForYouFeedOrderedChildren(@[ @{}, response ], @[ @"t3_c" ]);
    CHECK(fromArray.count == 1, "array-wrapped response");
    CHECK(ApolloForYouFeedOrderedChildren(@"junk", @[ @"t3_a" ]).count == 0, "junk response");

    NSDictionary *listing = ApolloForYouFeedListing(ordered, @"foryou:s:2");
    CHECK([listing[@"data"][@"after"] isEqual:@"foryou:s:2"], "after");
    CHECK([ApolloForYouFeedListing(@[], nil)[@"data"][@"after"] isEqual:[NSNull null]], "no after");
}

static void TestTokens(void) {
    NSString *token = ApolloForYouFeedToken(@"ABC-123", 50);
    NSString *session = nil;
    NSUInteger index = 0;
    CHECK(ApolloForYouFeedParseToken(token, &session, &index), "parse");
    CHECK([session isEqualToString:@"ABC-123"] && index == 50, "round trip %s %lu", session.UTF8String, (unsigned long)index);
    CHECK(!ApolloForYouFeedParseToken(@"t3_abc", NULL, NULL), "reddit cursor");
    CHECK(!ApolloForYouFeedParseToken(@"foryou:abc", NULL, NULL), "no index");
    CHECK(!ApolloForYouFeedParseToken(@"foryou:abc:1x", NULL, NULL), "bad index");
    CHECK(!ApolloForYouFeedParseToken(nil, NULL, NULL), "nil");
}

static void TestHomePaths(void) {
    for (NSString *path in @[ @"best.json", @"hot.json", @"/new.json", @"TOP.json", @"controversial.json", @"rising.json" ]) {
        CHECK(ApolloForYouFeedIsHomeListingPath(path), "home %s", path.UTF8String);
    }
    for (NSString *path in @[ @"r/all/best.json", @"r/All/hot.json", @"user/x/submitted.json", @"api/info.json", @"best", @"" ]) {
        CHECK(!ApolloForYouFeedIsHomeListingPath(path), "not home %s", path.UTF8String);
    }
}

int main(void) {
    @autoreleasepool {
        TestParse();
        TestURL();
        TestHeaders();
        TestChildren();
        TestTokens();
        TestHomePaths();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("for_you_feed_tests: all passed\n");
    return 0;
}
