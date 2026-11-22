#import <Foundation/Foundation.h>
#import "ApolloAccountSuspension.h"

// Exercises src/ApolloAccountSuspension.m as shipped: which Reddit answers count as the account's
// own description, what they change, when a suspension runs out, and what survives a relaunch.
// The two account objects are the fields Reddit returned for two suspended accounts on 2026-11-22.

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { failures++; NSLog(@"FAIL: %s", msg); } } while (0)

static const NSTimeInterval kNow = 1795305600.0 + 62400.0;   // 2026-11-22 17:20 UTC
static const NSTimeInterval kEnd = 1795937507.0;             // Reddit's suspension_expiration_utc

static NSDictionary *User(NSString *name, id suspended, id expiration) {
    NSMutableDictionary *user = [@{ @"name": name, @"has_verified_email": @YES } mutableCopy];
    if (suspended) user[@"is_suspended"] = suspended;
    if (expiration) user[@"suspension_expiration_utc"] = expiration;
    return user;
}

static void Reset(void) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"AccountSuspensions"];
    ApolloAccountSuspensionReloadForTesting();
    ApolloAccountSuspensionSetNowForTesting(kNow);
}

int main(void) {
    @autoreleasepool {
        Reset();
        // API-key account: GET api/v1/me is the account object itself.
        CHECK(!ApolloAccountIsSuspended(@"Rem"), "nothing stored: not suspended");
        CHECK(ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"api/v1/me", User(@"Rem", @YES, @(kEnd))), "api/v1/me suspended is a change");
        CHECK(ApolloAccountIsSuspended(@"REM"), "suspended, any casing");
        CHECK([ApolloAccountSuspensionEnd(@"rem") timeIntervalSince1970] == kEnd, "end date kept");
        CHECK([ApolloAccountSuspensionTimeLeftText(@"rem") isEqualToString:@"7 days left"], "6 days 7 hours rounds up to 7 days, like Reddit's bar");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"api/v1/me", User(@"Rem", @YES, @(kEnd))), "same answer again is no change");

        // Answers that don't say.
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"api/v1/me", User(@"Rem", nil, nil)), "no is_suspended field changes nothing");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"api/v1/me", @{ @"features": @{} }), "the web session's features-only api/v1/me changes nothing");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"api/v1/me", User(@"Rem", [NSNull null], nil)), "null is_suspended changes nothing");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"api/v1/me", @[ @"not", @"a", @"dictionary" ]), "a non-dictionary body changes nothing");
        CHECK(ApolloAccountIsSuspended(@"rem"), "still suspended after answers that don't say");

        // Reads that aren't the account's own description.
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"user/other/about.json", @{ @"data": User(@"other", @YES, nil) }), "another user's about.json isn't ours");
        CHECK(!ApolloAccountIsSuspended(@"other"), "another user's suspension isn't stored");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"user/rem/about", @{ @"data": User(@"other", @NO, nil) }), "an object naming someone else is ignored");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"api/v1/me", User(@"ichop", @YES, nil)), "a me answer for a different account than the client's is ignored");
        CHECK(!ApolloAccountIsSuspended(@"ichop"), "and stores nothing for that account");
        CHECK(!ApolloAccountSuspensionNoteResponse(nil, @"GET", @"user/gone/about", @{ @"data": User(@"gone", @YES, nil) }), "about.json with no known client is ignored");
        CHECK(!ApolloAccountIsSuspended(@"gone"), "and stores nothing");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"POST", @"api/v1/me", User(@"Rem", @NO, nil)), "only reads");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"api/v1/me/prefs", User(@"Rem", @NO, nil)), "api/v1/me/prefs is not the account object");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"user/rem/about/extra", @{ @"data": User(@"rem", @NO, nil) }), "longer user paths are not about.json");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", @"r/rem/about", @{ @"data": User(@"rem", @NO, nil) }), "a subreddit's about is not the account object");
        CHECK(ApolloAccountIsSuspended(@"rem"), "still suspended after reads that aren't ours");

        // The API-Key-Free forms: api/me.json and the account's own about.json wrap it in "data".
        CHECK(ApolloAccountSuspensionNoteResponse(nil, @"GET", @"/api/me.json", @{ @"kind": @"t2", @"data": User(@"iChop", @YES, @(kEnd)) }), "api/me.json before the client knows its user");
        CHECK(ApolloAccountIsSuspended(@"ichop"), "second account suspended on its own");
        CHECK(ApolloAccountSuspensionNoteResponse(@"ichop", @"GET", @"user/iChop/about.json?raw_json=1", @{ @"data": User(@"iChop", @YES, nil) }), "own about.json: end date gone is a change");
        CHECK(ApolloAccountSuspensionEnd(@"ichop") == nil, "no end date");
        CHECK(ApolloAccountSuspensionTimeLeftText(@"ichop") == nil, "no end date: no time-left text");
        CHECK(ApolloAccountIsSuspended(@"ichop"), "no end date is still suspended");

        // Survives a relaunch.
        ApolloAccountSuspensionReloadForTesting();
        CHECK(ApolloAccountIsSuspended(@"rem") && ApolloAccountIsSuspended(@"ichop"), "both stored across a relaunch");
        CHECK([ApolloAccountSuspensionEnd(@"rem") timeIntervalSince1970] == kEnd, "end date stored across a relaunch");

        // Time left, rounded up.
        ApolloAccountSuspensionSetNowForTesting(kEnd - 86400.0 - 1.0);
        CHECK([ApolloAccountSuspensionTimeLeftText(@"rem") isEqualToString:@"2 days left"], "a day and a second: 2 days");
        ApolloAccountSuspensionSetNowForTesting(kEnd - 86400.0);
        CHECK([ApolloAccountSuspensionTimeLeftText(@"rem") isEqualToString:@"1 day left"], "exactly a day");
        ApolloAccountSuspensionSetNowForTesting(kEnd - 86399.0);
        CHECK([ApolloAccountSuspensionTimeLeftText(@"rem") isEqualToString:@"1 day left"], "23:59:59 reads as a day, not 24 hours");
        ApolloAccountSuspensionSetNowForTesting(kEnd - 5.0 * 3600.0 + 60.0);
        CHECK([ApolloAccountSuspensionTimeLeftText(@"rem") isEqualToString:@"5 hours left"], "hours");
        ApolloAccountSuspensionSetNowForTesting(kEnd - 3600.0);
        CHECK([ApolloAccountSuspensionTimeLeftText(@"rem") isEqualToString:@"1 hour left"], "one hour");
        ApolloAccountSuspensionSetNowForTesting(kEnd - 600.0);
        CHECK([ApolloAccountSuspensionTimeLeftText(@"rem") isEqualToString:@"Less than an hour left"], "under an hour");

        // The end date passing ends it with no answer from Reddit, and that is stored too.
        ApolloAccountSuspensionSetNowForTesting(kEnd);
        CHECK(!ApolloAccountIsSuspended(@"rem"), "over at its end date");
        CHECK(ApolloAccountSuspensionTimeLeftText(@"rem") == nil && ApolloAccountSuspensionEnd(@"rem") == nil, "nothing left to say once over");
        ApolloAccountSuspensionSetNowForTesting(kNow);
        ApolloAccountSuspensionReloadForTesting();
        CHECK(!ApolloAccountIsSuspended(@"rem"), "an expired entry doesn't come back with an earlier clock");
        CHECK(ApolloAccountIsSuspended(@"ichop"), "the other account is untouched");

        // Reddit saying it's over.
        CHECK(ApolloAccountSuspensionNoteUserData(@"ichop", User(@"iChop", @NO, nil)), "is_suspended false is a change");
        CHECK(!ApolloAccountIsSuspended(@"ichop"), "lifted");
        CHECK(!ApolloAccountSuspensionNoteUserData(@"ichop", User(@"iChop", @NO, nil)), "false again is no change");
        CHECK([[NSUserDefaults standardUserDefaults] objectForKey:@"AccountSuspensions"] == nil, "nothing left stored");

        // Removed accounts.
        ApolloAccountSuspensionNoteUserData(@"rem", User(@"Rem", @YES, @(kEnd)));
        ApolloAccountSuspensionNoteUserData(@"gone", User(@"gone", @YES, nil));
        ApolloAccountSuspensionKeepOnly([NSSet setWithArray:@[ @"Rem", @"someoneelse" ]]);
        CHECK(ApolloAccountIsSuspended(@"rem") && !ApolloAccountIsSuspended(@"gone"), "only signed-in accounts are kept");

        // Bad input.
        CHECK(!ApolloAccountIsSuspended(nil) && !ApolloAccountIsSuspended(@"  "), "no username: not suspended");
        CHECK(!ApolloAccountSuspensionNoteUserData(@"", User(@"x", @YES, nil)), "empty username stores nothing");
        CHECK(!ApolloAccountSuspensionNoteResponse(@"rem", @"GET", nil, User(@"Rem", @NO, nil)), "no path changes nothing");
        Reset();
        ApolloAccountSuspensionSetNowForTesting(0);
    }
    if (failures) { NSLog(@"%d check(s) failed", failures); return 1; }
    NSLog(@"account suspension tests passed");
    return 0;
}
