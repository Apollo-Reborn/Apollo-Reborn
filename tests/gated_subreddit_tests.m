#import <Foundation/Foundation.h>
#import "ApolloGatedSubreddit.h"

static int sFailures;

#define CHECK(condition, ...) do { \
    if (!(condition)) { \
        sFailures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); \
    } \
} while (0)

static id ParseJSON(NSString *json) {
    return [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

// The form on old.reddit.com/gated as Reddit served it on 2026-11-26, with the
// markup around it cut down and the modhash replaced. A sign-out form with the
// same modhash comes first on the real page.
static NSString *WarningPage(NSString *subreddit, NSString *action) {
    return [NSString stringWithFormat:
        @"<html><head><title>reddit.com: gated</title></head><body>"
        "<form method=\"post\" action=\"https://old.reddit.com/logout\" class=\"logout hover\" >"
        "<input type=\"hidden\" name=\"uh\" value=\"modhash123\"/><input type=\"hidden\" name=\"top\" value=\"off\"/>"
        "<input type=\"hidden\" name=\"dest\" value=\"/gated?dest=https%%3A%%2F%%2Fold.reddit.com%%2Fr%%2F%@%%2F\"/>"
        "<a href=\"javascript:void(0)\">logout</a></form>"
        "<div class=\"interstitial\"><h3>Are you sure you want to view this community?</h3>"
        "<div class=\"interstitial-message md-container\"><p>Content Advisory: caution.</p></div>"
        "<form class=\"pretty-form\" onsubmit=\"\" action=\"%@\" method=\"post\" >"
        "<input type=\"hidden\" name=\"uh\" value=\"modhash123\"><input type=\"hidden\" name=\"sr_name\" value=\"%@\" />"
        "<input type=\"hidden\" name=\"dest\" value=\"https://old.reddit.com/r/%@/?a=1&amp;b=2\" />"
        "<div class=\"buttons\"><button class=\"c-btn c-btn-primary\" type=\"submit\" name=\"accept\" value=\"no\">no thank you</button>"
        "<button class=\"c-btn c-btn-primary\" type=\"submit\" name=\"accept\" value=\"yes\">continue</button></div></form></div>"
        "</body></html>", subreddit, action, subreddit, subreddit];
}

static NSData *Page(NSString *html) {
    return [html dataUsingEncoding:NSUTF8StringEncoding];
}

static void TestWarning(void) {
    // The answer /r/Drugs/hot.json gave on 2026-11-26.
    NSDictionary *gated = ParseJSON(@"{\"interstitial_warning_message_html\": \"<!-- SC_OFF --><div class=\\\"md\\\"><p>Content Advisory</p></div>\","
        " \"reason\": \"gated\", \"interstitial_warning_message\": \"Content Advisory: This community may contain discussions.\\n\","
        " \"message\": \"Forbidden\", \"error\": 403}");
    CHECK([ApolloGatedWarningFromResponseObject(gated) isEqualToString:@"Content Advisory: This community may contain discussions."],
          @"Reddit's warning, trimmed (%@)", ApolloGatedWarningFromResponseObject(gated));
    CHECK(ApolloGatedWarningFromResponseObject(ParseJSON(@"{\"reason\": \"gated\", \"error\": 403}")).length > 0, @"a gated answer without text still says what it is");
    CHECK(ApolloGatedWarningFromResponseObject(ParseJSON(@"{\"reason\": \"private\", \"message\": \"Forbidden\", \"error\": 403}")) == nil &&
          ApolloGatedWarningFromResponseObject(ParseJSON(@"{\"reason\": \"quarantined\", \"quarantine_message\": \"x\", \"error\": 403}")) == nil &&
          ApolloGatedWarningFromResponseObject(ParseJSON(@"{\"message\": \"Forbidden\", \"error\": 403}")) == nil &&
          ApolloGatedWarningFromResponseObject(ParseJSON(@"{\"reason\": 7}")) == nil &&
          ApolloGatedWarningFromResponseObject(ParseJSON(@"{\"kind\": \"Listing\", \"data\": {\"children\": []}}")) == nil &&
          ApolloGatedWarningFromResponseObject(@[ @"gated" ]) == nil && ApolloGatedWarningFromResponseObject(nil) == nil,
          @"the reasons RedditKit knows, and everything else, are left as they are");

    NSError *plain = [NSError errorWithDomain:@"RDKClientErrorDomain" code:403 userInfo:@{ NSLocalizedDescriptionKey: @"Forbidden" }];
    NSError *marked = ApolloGatedErrorWithWarning(plain, @"Careful.");
    CHECK([marked.domain isEqualToString:@"RDKClientErrorDomain"] && marked.code == 403 &&
          [marked.userInfo[NSLocalizedDescriptionKey] isEqualToString:@"Forbidden"] &&
          [marked.userInfo[ApolloGatedSubredditWarningKey] isEqualToString:@"Careful."], @"RedditKit's error, with the warning added (%@)", marked);
    NSError *made = ApolloGatedErrorWithWarning(nil, @"Careful.");
    CHECK(made.code == 403 && [made.userInfo[ApolloGatedSubredditWarningKey] isEqualToString:@"Careful."], @"an error where RedditKit made none (%@)", made);
}

static void TestSubredditFromPath(void) {
    CHECK([ApolloGatedSubredditFromListingPath(@"r/Drugs/best.json") isEqualToString:@"Drugs"], @"Apollo's listing path");
    CHECK([ApolloGatedSubredditFromListingPath(@"/r/MorbidReality/top.json?t=week") isEqualToString:@"MorbidReality"], @"a URL path with a query");
    CHECK([ApolloGatedSubredditFromListingPath(@"r/Drugs.json") isEqualToString:@"Drugs"] &&
          [ApolloGatedSubredditFromListingPath(@"r/Drugs") isEqualToString:@"Drugs"], @"the default sort");
    for (NSString *path in @[ @"best.json", @"r/apple+iphone/hot.json", @"r/a/hot.json", @"user/someone/submitted.json",
                              @"user/someone/m/multi/hot.json", @"r/_x/hot.json", @"r/has.dot/hot.json", @"", @"r" ]) {
        CHECK(ApolloGatedSubredditFromListingPath(path) == nil, @"%@ isn't one subreddit's listing", path);
    }
    CHECK(ApolloGatedSubredditFromListingPath(nil) == nil, @"no path");
}

static void TestPageURL(void) {
    CHECK([ApolloGatedPageURL(@"Drugs").absoluteString isEqualToString:@"https://old.reddit.com/gated?dest=https%3A%2F%2Fold.reddit.com%2Fr%2FDrugs%2F"],
          @"the address old Reddit sends a gated subreddit to (%@)", ApolloGatedPageURL(@"Drugs"));
    CHECK(ApolloGatedPageURL(@"a+b") == nil && ApolloGatedPageURL(@"x/../y") == nil && ApolloGatedPageURL(@"") == nil, @"only a subreddit's name");
}

static void TestAcceptRequest(void) {
    NSURL *pageURL = ApolloGatedPageURL(@"Drugs");
    NSURLRequest *request = ApolloGatedAcceptRequest(Page(WarningPage(@"Drugs", @"")), pageURL, @"drugs");
    NSString *body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
    CHECK([request.HTTPMethod isEqualToString:@"POST"] && [request.URL isEqual:pageURL], @"posted back to the page (%@ %@)", request.HTTPMethod, request.URL);
    CHECK([body isEqualToString:@"uh=modhash123&sr_name=Drugs&dest=https%3A%2F%2Fold.reddit.com%2Fr%2FDrugs%2F%3Fa%3D1%26b%3D2&accept=yes"],
          @"the warning form's own fields and the accepting button, not the sign-out form's (%@)", body);
    CHECK([[request valueForHTTPHeaderField:@"Content-Type"] isEqualToString:@"application/x-www-form-urlencoded"], @"as a form");
    CHECK([request valueForHTTPHeaderField:@"Cookie"] == nil, @"the cookie is the caller's to add");

    CHECK([ApolloGatedAcceptRequest(Page(WarningPage(@"Drugs", @"/gated?dest=x")), pageURL, @"Drugs").URL.absoluteString
           isEqualToString:@"https://old.reddit.com/gated?dest=x"], @"an action on the same host");
    CHECK(ApolloGatedAcceptRequest(Page(WarningPage(@"Drugs", @"https://example.com/gated")), pageURL, @"Drugs") == nil &&
          ApolloGatedAcceptRequest(Page(WarningPage(@"Drugs", @"http://old.reddit.com/gated")), pageURL, @"Drugs") == nil,
          @"a form that posts somewhere else isn't sent");
    CHECK(ApolloGatedAcceptRequest(Page(WarningPage(@"Other", @"")), pageURL, @"Drugs") == nil, @"a warning for another subreddit");
    NSString *noButton = [WarningPage(@"Drugs", @"") stringByReplacingOccurrencesOfString:@"value=\"yes\"" withString:@"value=\"maybe\""];
    CHECK(ApolloGatedAcceptRequest(Page(noButton), pageURL, @"Drugs") == nil, @"a form with no button that accepts");
    CHECK(ApolloGatedAcceptRequest(Page(@"<html><form method=\"post\" action=\"/post/login\"><input type=\"hidden\" name=\"op\" value=\"login\">"
                                         "<input name=\"user\"></form></html>"), pageURL, @"Drugs") == nil, @"a sign-in page");
    CHECK(ApolloGatedAcceptRequest(Page(@"{\"kind\": \"Listing\"}"), pageURL, @"Drugs") == nil &&
          ApolloGatedAcceptRequest(nil, pageURL, @"Drugs") == nil && ApolloGatedAcceptRequest([NSData data], pageURL, @"Drugs") == nil,
          @"anything that isn't the page");
}

int main(void) {
    @autoreleasepool {
        TestWarning();
        TestSubredditFromPath();
        TestPageURL();
        TestAcceptRequest();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("gated subreddit tests passed\n");
    return 0;
}
