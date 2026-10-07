#import <Foundation/Foundation.h>

#import "ApolloKagiSearchParsing.h"

// Host-side checks for the Search tab's Kagi mode parser. The fixtures under
// tests/fixtures/kagi are trimmed real kagi.com responses (see each file's
// header comment); the synthetic pages below cover what a live search can't be
// relied on to produce (an empty page, markup drift, a grouped result).

static NSUInteger sChecks;

static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static NSString *Fixture(NSString *directory, NSString *name) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSString *html = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    Check(html.length > 0, [@"fixture readable: " stringByAppendingString:name]);
    return html;
}

static void CheckResultsPage(NSString *html, NSString *name, NSUInteger minimum, BOOL hasMore) {
    ApolloKagiParsedPage *page = ApolloKagiParseResultsHTML(html);
    Check(page.kind == ApolloKagiPageKindResults, [name stringByAppendingString:@": is a results page"]);
    Check(page.results.count >= minimum,
          [NSString stringWithFormat:@"%@: at least %lu results (got %lu)", name,
           (unsigned long)minimum, (unsigned long)page.results.count]);
    Check(page.hasMore == hasMore, [name stringByAppendingString:@": More Results link"]);
    NSUInteger dated = 0;
    for (ApolloKagiParsedResult *result in page.results) {
        NSURL *url = [NSURL URLWithString:result.URLString];
        Check([url.scheme isEqualToString:@"https"] && url.host.length,
              [NSString stringWithFormat:@"%@: absolute result URL %@", name, result.URLString]);
        Check([url.host rangeOfString:@"kagi.com"].location == NSNotFound,
              [NSString stringWithFormat:@"%@: result links straight to the destination, not Kagi (%@)", name, result.URLString]);
        Check(result.title.length > 0, [name stringByAppendingString:@": every result has a title"]);
        Check([result.title rangeOfString:@"<"].location == NSNotFound &&
              [result.title rangeOfString:@"&#"].location == NSNotFound,
              [NSString stringWithFormat:@"%@: title is plain text (%@)", name, result.title]);
        Check([result.snippet rangeOfString:@"Summarize"].location == NSNotFound,
              [NSString stringWithFormat:@"%@: Kagi's Summarize link is not snippet text (%@)", name, result.snippet]);
        Check([result.snippet rangeOfString:@"<"].location == NSNotFound &&
              [result.snippet rangeOfString:@"&amp;"].location == NSNotFound &&
              [result.snippet rangeOfString:@"&#39;"].location == NSNotFound,
              [NSString stringWithFormat:@"%@: snippet is plain text (%@)", name, result.snippet]);
        Check(![result.snippet hasPrefix:@" "] && ![result.snippet hasSuffix:@" "] &&
              [result.snippet rangeOfString:@"  "].location == NSNotFound,
              [name stringByAppendingString:@": snippet whitespace is collapsed"]);
        if (result.dateText) {
            dated++;
            Check([result.snippet rangeOfString:result.dateText].location == NSNotFound,
                  [NSString stringWithFormat:@"%@: date %@ isn't repeated in the snippet", name, result.dateText]);
        }
    }
    Check(dated > 0, [name stringByAppendingString:@": some results carry Kagi's date"]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *fixtures = argc > 1 ? @(argv[1]) : @"tests/fixtures/kagi";

        // Real first page: 12 blocks (one of them wrapped in a result group),
        // ends in "More Results".
        NSString *page1HTML = Fixture(fixtures, @"results_page1.html");
        CheckResultsPage(page1HTML, @"page 1", 10, YES);
        ApolloKagiParsedPage *page1 = ApolloKagiParseResultsHTML(page1HTML);
        ApolloKagiParsedResult *cheatSheet = nil;
        for (ApolloKagiParsedResult *result in page1.results) {
            if ([result.URLString containsString:@"/r/PTCGL/comments/1bqqph1/"]) cheatSheet = result;
        }
        Check(cheatSheet != nil, @"page 1: the grouped r/PTCGL result is read");
        Check([cheatSheet.title isEqualToString:@"Here’s a cheat sheet if you’re wondering what deck to play"],
              [@"page 1: title with curly apostrophes: " stringByAppendingString:cheatSheet.title ?: @"nil"]);
        Check([cheatSheet.snippet hasPrefix:@"Most decks in the current format"],
              [@"page 1: snippet text: " stringByAppendingString:cheatSheet.snippet ?: @"nil"]);
        Check([cheatSheet.snippet rangeOfString:@"If you're playing"].location != NSNotFound,
              @"page 1: &#39; decodes to an apostrophe");

        // Real batch 2 (the page "More Results" loads): no further page.
        CheckResultsPage(Fixture(fixtures, @"results_batch2.html"), @"batch 2", 15, NO);

        // Real signed-out responses: the Turnstile interstitial kagi.com serves
        // a request without a valid session, and the account sign-in page.
        for (NSString *name in @[@"signed_out_turnstile.html", @"signed_out_signin.html"]) {
            ApolloKagiParsedPage *page = ApolloKagiParseResultsHTML(Fixture(fixtures, name));
            Check(page.kind == ApolloKagiPageKindSignedOut, [name stringByAppendingString:@": signed out"]);
            Check(page.results.count == 0, [name stringByAppendingString:@": no results"]);
        }

        // A results page with nothing in it: empty, not signed out or unreadable.
        ApolloKagiParsedPage *empty = ApolloKagiParseResultsHTML(
            @"<html><body><main><div class=\"_0_main-search-results\"></div>"
            @"<div class=\"related-searches\"><a href=\"/html/search?q=x\">x</a></div></main></body></html>");
        Check(empty.kind == ApolloKagiPageKindResults && empty.results.count == 0 && !empty.hasMore, @"empty page");

        // Markup drift: result-looking links, but none of Kagi's result blocks.
        NSMutableString *drift = [NSMutableString stringWithString:@"<html><body><main>"];
        for (int i = 0; i < 8; i++) {
            [drift appendFormat:@"<div class=\"r-%d\"><a href=\"https://www.reddit.com/r/x/comments/abc%d/t/\">T%d</a></div>", i, i, i];
        }
        [drift appendString:@"</main></body></html>"];
        Check(ApolloKagiParseResultsHTML(drift).kind == ApolloKagiPageKindUnreadable, @"markup drift is unreadable");
        Check(ApolloKagiParseResultsHTML(@"").kind == ApolloKagiPageKindUnreadable, @"no body is unreadable");

        // Real signed-in page with nothing in it (an OR query, Past Year,
        // batch 2). Its meta description carries Kagi's marketing line, the
        // one kagi-cli reads as "signed out": it's on every page.
        ApolloKagiParsedPage *none = ApolloKagiParseResultsHTML(Fixture(fixtures, @"results_none.html"));
        Check(none.kind == ApolloKagiPageKindResults, @"no-results page is a results page, not signed out");
        Check(none.results.count == 0 && !none.hasMore, @"no-results page: nothing, no next page");
        ApolloKagiParsedPage *welcome = ApolloKagiParseResultsHTML(
            @"<meta name=\"description\" content=\"Welcome to Kagi, a paid search engine that gives power back to the user.\">"
            @"<main><div class=\"_0_main-search-results\"></div></main>");
        Check(welcome.kind == ApolloKagiPageKindResults, @"Kagi's marketing line isn't a sign-out");

        // The older grouped sub-result markup (kagi-cli's .sr-group .__srgi).
        ApolloKagiParsedPage *grouped = ApolloKagiParseResultsHTML(
            @"<div class=\"sr-group\"><div class=\"__srgi\"><div class=\"__srgi-title\">"
            @"<a href=\"https://www.reddit.com/r/a/comments/1abcd/x/\">Grouped &amp; titled</a></div>"
            @"<div class=\"__sri-desc\"><div>One <b>two</b>&nbsp;three</div></div></div></div>");
        Check(grouped.results.count == 1, @"grouped sub-result read");
        Check([grouped.results.firstObject.title isEqualToString:@"Grouped & titled"], @"grouped title decoded");
        Check([grouped.results.firstObject.snippet isEqualToString:@"One two three"], @"grouped snippet flattened");

        // Nested blocks: a group whose own block holds child results reads
        // each child once, and the parent's title only.
        ApolloKagiParsedPage *nested = ApolloKagiParseResultsHTML(
            @"<div class=\"_0_SRI search-result\"><h3><a class=\"__sri_title_link\" href=\"https://www.reddit.com/r/a/\">Parent</a></h3>"
            @"<div class=\"__sri-desc\"><div>Parent text</div></div>"
            @"<div class=\"_0_SRI search-result\"><h3><a class=\"__sri_title_link\" href=\"https://www.reddit.com/r/a/comments/2abc/c/\">Child</a></h3>"
            @"<div class=\"__sri-desc\"><div><span class=\"__sri-time \"> Jan 2, 2026 </span> Child text <a class=\"summarize-link\" href=\"/summarizer\">Summarize</a></div></div></div></div>"
            @"<a id=\"load_more_results\" href=\"/html/search?q=a&amp;batch=2\">More Results</a>");
        Check(nested.results.count == 2, @"nested: two results");
        Check([nested.results[0].title isEqualToString:@"Parent"] && [nested.results[0].snippet isEqualToString:@"Parent text"],
              @"nested: parent keeps its own text");
        Check([nested.results[1].snippet isEqualToString:@"Child text"] && [nested.results[1].dateText isEqualToString:@"Jan 2, 2026"],
              @"nested: child date and snippet");
        Check(nested.hasMore, @"nested: More Results");

        // Entities.
        Check([ApolloKagiDecodeHTMLEntities(@"a &amp; b &lt;c&gt; &#8217; &#x1F600; &bogus; &") isEqualToString:
               @"a & b <c> ’ \U0001F600 &bogus; &"], @"entity decoding");

        // Session links and tokens.
        NSString *token = @"AbCdEfGhIjKlMnOp_qrs-TUV.wxyz0123456789";
        Check([ApolloKagiNormalizeSessionToken(token) isEqualToString:token], @"bare token");
        Check([ApolloKagiNormalizeSessionToken([NSString stringWithFormat:@"  https://kagi.com/search?token=%@\n", token])
               isEqualToString:token], @"full session link, whitespace trimmed");
        Check([ApolloKagiNormalizeSessionToken([NSString stringWithFormat:@"kagi.com/search?q=hi&token=%@", token])
               isEqualToString:token], @"link without a scheme, other query items");
        Check(ApolloKagiNormalizeSessionToken(@"https://kagi.com/search?q=hi") == nil, @"link without a token");
        Check(ApolloKagiNormalizeSessionToken(@"short") == nil, @"too short");
        Check(ApolloKagiNormalizeSessionToken(@"has spaces in it which is not a token") == nil, @"spaces");
        Check(ApolloKagiNormalizeSessionToken(@"") == nil && ApolloKagiNormalizeSessionToken(nil) == nil, @"empty");
    }
    printf("kagi_search_parsing_tests: %lu checks passed\n", (unsigned long)sChecks);
    return 0;
}
