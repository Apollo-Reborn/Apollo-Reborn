#import <Foundation/Foundation.h>
#import "ApolloWebJSONBudget.h"

// Exercises src/ApolloWebJSONBudget.m as shipped: which answers count as a report of Reddit's
// request budget, how reports combine inside a ten-minute window and across windows, and when
// Reduce Rate Limiting's "Pause Extras At" stop holds optional lookups back. The header values
// are the shapes Reddit sent on 2026-11-22 ("14" / "86.0" / "289").

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { failures++; NSLog(@"FAIL: %s", msg); } } while (0)

static const NSTimeInterval kStart = 1795305600.0 + 48900.0;   // 2026-11-22 13:35:00 UTC, 300 s into a window

static NSHTTPURLResponse *Answer(NSInteger status, NSDictionary *headers) {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://www.reddit.com/best.json"]
                                       statusCode:status HTTPVersion:@"HTTP/2" headerFields:headers];
}
static NSHTTPURLResponse *Report(NSString *used, NSString *remaining, NSString *reset) {
    return Answer(200, @{ @"x-ratelimit-used": used, @"x-ratelimit-remaining": remaining, @"x-ratelimit-reset": reset,
                          @"Content-Type": @"application/json; charset=UTF-8" });
}
static void At(NSTimeInterval secondsIntoTest) { ApolloWebJSONBudgetSetNowForTesting(kStart + secondsIntoTest); }

int main(void) {
    @autoreleasepool {
        ApolloWebJSONBudgetResetForTesting();
        At(0);
        CHECK(!ApolloWebJSONBudgetCurrent(@"new").known, "nothing reported: unknown");
        CHECK(ApolloWebJSONBudgetPause(@"new", 70) == 0, "nothing reported: no pause");
        CHECK(ApolloWebJSONBudgetStatusText(@"new") == nil, "nothing reported: no status text");

        // A normal account: one unit per request, 100 a window.
        CHECK(ApolloWebJSONBudgetNoteResponse(@"New", Report(@"14", @"86.0", @"300")), "first report is a change");
        ApolloWebJSONBudgetState s = ApolloWebJSONBudgetCurrent(@"NEW");
        CHECK(s.known && s.used == 14 && s.limit == 100 && s.resetsIn == 300, "report read, any username casing");
        CHECK([ApolloWebJSONBudgetStatusText(@"new") isEqualToString:@"14 of 100 used, resets in 5 min"], "status text");
        CHECK(ApolloWebJSONBudgetPause(@"new", 70) == 0, "14 of 100 is under a 70 stop");
        CHECK(ApolloWebJSONBudgetPause(@"new", 30) == 0, "and under a 30 stop");

        // Answers that say nothing change nothing.
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Answer(200, @{ @"Content-Type": @"application/json" })), "no headers: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Answer(200, @{ @"x-ratelimit-used": @"99", @"x-ratelimit-remaining": @"1.0" })), "no reset: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"abc", @"1.0", @"200")), "not a number: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"99x", @"1.0", @"200")), "a number with something after it: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"0", @"0", @"200")), "a zero limit: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"-3", @"103", @"200")), "negative: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"99", @"1.0", @"86400")), "a reset a day out: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"99", @"1.0", @"601")), "a reset a second past one window: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"99", @"1.0", @"0")), "a zero reset: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(nil, Report(@"99", @"1.0", @"200")), "no username: no change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", nil), "no response: no change");
        CHECK(ApolloWebJSONBudgetCurrent(@"new").used == 14, "still 14 after answers that say nothing");

        // Inside a window the count only climbs: requests overlap, so answers arrive out of order.
        At(5);
        CHECK(ApolloWebJSONBudgetNoteResponse(@"new", Report(@"31", @"69.0", @"295")), "a higher count is a change");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"29", @"71.0", @"296")), "a lower count from the same window is not");
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"new", Report(@"31", @"69.0", @"295")), "nor is the same count again");
        CHECK(ApolloWebJSONBudgetCurrent(@"new").used == 31, "kept the higher count");
        CHECK(ApolloWebJSONBudgetPause(@"new", 30) == 295, "31 of 100 passes a 30 stop: paused for the rest of the window");
        // Reddit's reset is whole seconds and answers take a moment, so a later answer's window
        // end lands a second or two off. The window's first end is the one kept.
        CHECK(ApolloWebJSONBudgetNoteResponse(@"new", Report(@"33", @"67.0", @"297")), "a later answer whose end is 2 s off");
        CHECK(ApolloWebJSONBudgetPause(@"new", 30) == 295, "still ends where the window's first answer said");
        CHECK(ApolloWebJSONBudgetPause(@"new", 35) == 0, "but not a 35 stop");
        CHECK(ApolloWebJSONBudgetPause(@"new", 100) == 0, "a stop of 100 doesn't pause while anything is left");
        CHECK(ApolloWebJSONBudgetPause(@"new", 0) == 0 && ApolloWebJSONBudgetPause(@"new", -5) == 0, "no stop: no pause");

        // The pause runs to the window's end and counts down with the clock.
        At(100);
        CHECK(ApolloWebJSONBudgetNoteResponse(@"new", Report(@"70", @"30.0", @"200")), "70 used");
        CHECK(ApolloWebJSONBudgetPause(@"new", 70) == 200, "exactly at the stop pauses");
        CHECK(ApolloWebJSONBudgetPause(@"new", 75) == 0, "the next stop up doesn't");
        At(250);
        CHECK(ApolloWebJSONBudgetPause(@"new", 70) == 50, "the pause counts down");
        CHECK([ApolloWebJSONBudgetStatusText(@"new") isEqualToString:@"70 of 100 used, resets in under a minute"], "status near the end");

        // The window ending ends the pause with no answer from Reddit.
        At(300);
        CHECK(ApolloWebJSONBudgetPause(@"new", 70) == 0, "nothing paused once the window is over");
        CHECK(!ApolloWebJSONBudgetCurrent(@"new").known, "and the old count is gone");

        // A new window replaces the old count even though it's lower.
        At(0);
        ApolloWebJSONBudgetNoteResponse(@"new", Report(@"95", @"5.0", @"300"));
        At(302);
        CHECK(ApolloWebJSONBudgetNoteResponse(@"new", Report(@"2", @"98.0", @"598")), "the next window's first report is a change");
        CHECK(ApolloWebJSONBudgetCurrent(@"new").used == 2, "new window, new count");
        CHECK(ApolloWebJSONBudgetPause(@"new", 30) == 0, "and no pause");

        // A suspended account: four units per request against the same 100.
        At(0);
        CHECK(ApolloWebJSONBudgetNoteResponse(@"rem", Report(@"28", @"72.0", @"589")), "second account");
        CHECK(ApolloWebJSONBudgetNoteResponse(@"rem", Report(@"72", @"28.0", @"586")), "climbs four at a time");
        CHECK(ApolloWebJSONBudgetPause(@"rem", 70) > 580, "its own stop, reached after 18 requests");
        At(302);
        CHECK(ApolloWebJSONBudgetPause(@"new", 70) == 0, "one account's pause isn't the other's");

        // Reddit's 429 carries the same headers with nothing left.
        CHECK(ApolloWebJSONBudgetNoteResponse(@"rem", Answer(429, @{ @"x-ratelimit-used": @"100", @"x-ratelimit-remaining": @"0.0", @"x-ratelimit-reset": @"280" })), "a 429's report counts");
        CHECK([ApolloWebJSONBudgetStatusText(@"rem") hasPrefix:@"100 of 100 used"], "all used");
        // (287, not the 429's 280: this window's first answer put its end at 589 s, and it's 302 s now.)
        CHECK(ApolloWebJSONBudgetPause(@"rem", 100) == 287, "a stop of 100 pauses once nothing is left");
        CHECK(ApolloWebJSONBudgetPause(@"rem", 250) == 287, "and anything above 100 is 100");

        // The stop is a share of whatever limit Reddit reports, not of a fixed 100.
        ApolloWebJSONBudgetResetForTesting();
        At(0);
        ApolloWebJSONBudgetNoteResponse(@"web", Report(@"450", @"150.0", @"100"));
        CHECK(ApolloWebJSONBudgetCurrent(@"web").limit == 600, "limit is used plus remaining");
        CHECK(ApolloWebJSONBudgetPause(@"web", 70) == 100 && ApolloWebJSONBudgetPause(@"web", 80) == 0, "the stop is a share of the limit");

        // Reddit keeps roomier counts for other kinds of request (600 for its own pages, 10000 for
        // an API key). Inside one window the tightest count seen is the one that's kept, whichever
        // order the answers come in and whatever their counts.
        ApolloWebJSONBudgetResetForTesting();
        At(0);
        ApolloWebJSONBudgetNoteResponse(@"mix", Report(@"40", @"60.0", @"300"));
        CHECK(!ApolloWebJSONBudgetNoteResponse(@"mix", Report(@"452", @"148.0", @"300")), "a roomier count in the same window is left out");
        s = ApolloWebJSONBudgetCurrent(@"mix");
        CHECK(s.used == 40 && s.limit == 100, "the 100 count stays");
        ApolloWebJSONBudgetNoteResponse(@"mix2", Report(@"452", @"148.0", @"300"));
        CHECK(ApolloWebJSONBudgetNoteResponse(@"mix2", Report(@"40", @"60.0", @"299")), "a tighter count replaces a roomier one, though its number is lower");
        s = ApolloWebJSONBudgetCurrent(@"mix2");
        CHECK(s.used == 40 && s.limit == 100, "the 100 count took over");
        CHECK(ApolloWebJSONBudgetPause(@"mix2", 70) == 0, "40 of 100, not 452 of 600");
        // A fresh window starts over with whatever comes first.
        At(301);
        CHECK(ApolloWebJSONBudgetNoteResponse(@"mix", Report(@"4", @"596.0", @"599")), "next window: the roomier count is all there is");
        CHECK(ApolloWebJSONBudgetCurrent(@"mix").limit == 600, "so it's kept until a tighter one arrives");

        ApolloWebJSONBudgetResetForTesting();
        ApolloWebJSONBudgetSetNowForTesting(0);
    }
    if (failures) { NSLog(@"%d check(s) failed", failures); return 1; }
    NSLog(@"web JSON budget tests passed");
    return 0;
}
