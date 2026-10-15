#import <Foundation/Foundation.h>
#import "ApolloLogRedaction.h"

static NSUInteger checks;
static NSUInteger failures;

static void Check(BOOL ok, NSString *label) {
    checks++;
    if (!ok) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", label.UTF8String);
    }
}

static NSArray<NSString *> *kOwn(void) { return @[ @"Kurisu_Main", @"kurisu_alt" ]; }
static NSString *const kHome = @"/var/mobile/Containers/Data/Application/11111111-2222-3333-4444-555555555555";

static NSString *Scrub(NSString *input) {
    return ApolloRedactLogExportWithSalt(input, kOwn(), kHome, @"fixed-salt");
}

// Exact output.
static void CheckScrub(NSString *input, NSString *expected) {
    NSString *actual = Scrub(input);
    Check([actual isEqualToString:expected],
          [NSString stringWithFormat:@"scrub\n   in:  %@\n   want: %@\n   got:  %@", input, expected, actual]);
}

// Output must not contain `secret` (and, when given, must contain `kept`).
static void CheckGone(NSString *input, NSString *secret, NSString *kept) {
    NSString *actual = Scrub(input);
    BOOL ok = [actual rangeOfString:secret options:NSCaseInsensitiveSearch].location == NSNotFound &&
              (!kept || [actual containsString:kept]);
    Check(ok, [NSString stringWithFormat:@"'%@' must go%@\n   in:  %@\n   got: %@", secret,
               kept ? [NSString stringWithFormat:@" and '%@' stay", kept] : @"", input, actual]);
}

static void CheckUnchanged(NSString *input) {
    CheckScrub(input, input);
}

int main(void) {
    @autoreleasepool {
        // --- The reported case: social links. Hosts survive, handles don't.
        CheckGone(@"[SocialLinks] found 2 link(s): (https://twitter.com/janedoe, https://instagram.com/jane.doe?igsh=abc)",
                  @"jane", @"https://twitter.com/…");
        CheckScrub(@"links (https://twitter.com/janedoe, https://instagram.com/jane.doe?igsh=abc)",
                   @"links (https://twitter.com/…, https://instagram.com/…?…)");

        // --- URLs: non-Reddit keep the host (+ a known media extension), Reddit
        // keeps its route minus the title slug; queries/fragments always go.
        CheckScrub(@"GET https://i.imgur.com/AbC123.gifv", @"GET https://i.imgur.com/….gifv");
        // Reddit's own media keeps its path (a media ID says no more than a
        // post ID), minus the signed query; snoovatars are a person, so they don't.
        CheckScrub(@"https://v.redd.it/abc/DASH_720.mp4?source=fallback", @"https://v.redd.it/abc/DASH_720.mp4?…");
        CheckScrub(@"https://i.redd.it/xyz987.jpg", @"https://i.redd.it/xyz987.jpg");
        CheckScrub(@"https://preview.redd.it/abc123.png?width=640&format=png&s=9f2a1b",
                   @"https://preview.redd.it/abc123.png?…");
        CheckScrub(@"https://i.redd.it/snoovatar/avatars/nftv2_bmZ0X2VpcDE1.png", @"https://i.redd.it/….png");
        // redditmedia.com style paths carry a profile-subreddit ID: host only.
        CheckScrub(@"https://styles.redditmedia.com/t5_3k30p/styles/profileIcon_uj01.png", @"https://styles.redditmedia.com/….png");
        CheckScrub(@"opened https://www.reddit.com/r/pics/comments/1abcd2/my_cats_first_birthday/hk3j2/ ok",
                   @"opened https://www.reddit.com/r/pics/comments/1abcd2/…/hk3j2/ ok");
        CheckScrub(@"https://oauth.reddit.com/api/v1/me?raw_json=1", @"https://oauth.reddit.com/api/v1/me?…");
        CheckScrub(@"https://www.google.com/search?q=embarrassing+question&start=10", @"https://www.google.com/…?…");
        CheckScrub(@"https://example.com/", @"https://example.com/");
        CheckScrub(@"https://example.com", @"https://example.com");
        // user:password@ never survives; the port does.
        CheckScrub(@"-> https://bob:hunter2@push.example.org:8443/v1/device/abc",
                   @"-> https://push.example.org:8443/…");
        // Any scheme, including a custom OAuth redirect carrying the code.
        CheckScrub(@"callback: apollo://reddit-oauth?state=XYZ&code=abc123", @"callback: apollo://reddit-oauth?…");
        CheckGone(@"callback: myapp://cb?code=SECRETCODE", @"SECRETCODE", @"myapp://cb?…");
        // Surrounding punctuation from NSError / NSDictionary descriptions stays intact.
        CheckScrub(@"UserInfo={NSErrorFailingURLStringKey=https://oauth.reddit.com/api/v1/me?foo=bar, NSErrorFailingURLKey=https://oauth.reddit.com/api/v1/me?foo=bar}",
                   @"UserInfo={NSErrorFailingURLStringKey=https://oauth.reddit.com/api/v1/me?…, NSErrorFailingURLKey=https://oauth.reddit.com/api/v1/me?…}");
        // A comma inside a query stays in the URL (signed Reddit image URLs).
        CheckScrub(@"icon=https://styles.redditmedia.com/t5_3k30p/styles/profileIcon_uj01.png?width=256&crop=256:256,smart&s=aa819b09 banner=nil",
                   @"icon=https://styles.redditmedia.com/….png?… banner=nil");
        // Mixed-case key names still reach the key=value pass.
        CheckScrub(@"Loid=abc123 EdgeBucket=xyz789 PassWord: hunter2", @"Loid=[redacted] EdgeBucket=[redacted] PassWord: [redacted]");
        // A dot in a handle is not a file extension.
        CheckScrub(@"https://instagram.com/real.name", @"https://instagram.com/…");
        // The account-marker fragment carried a username.
        CheckGone(@"https://www.reddit.com/r/x/new.json?after=t3_a#apollo-webjson-account=kurisu_main",
                  @"kurisu", @"/r/x/new.json?…#…");

        // --- Usernames.
        NSString *other = Scrub(@"u/SomeOtherGuy");
        Check([other hasPrefix:@"u/[user-"] && other.length == @"u/[user-0000]".length,
              [NSString stringWithFormat:@"other user tag shape (got %@)", other]);
        // Same person, same tag, any case and any spelling (u/, /user/, u_).
        NSString *many = Scrub(@"u/SomeOtherGuy /user/someotherguy r/u_SOMEOTHERGUY");
        NSString *tag = [other substringFromIndex:2];
        Check([many isEqualToString:[NSString stringWithFormat:@"u/%@ /user/%@ r/u_%@", tag, tag, tag]],
              [NSString stringWithFormat:@"one tag per person (got %@)", many]);
        // Different people, different tags.
        Check(![Scrub(@"u/alice_one") isEqualToString:Scrub(@"u/bobby_two")], @"distinct people get distinct tags");
        // The tag changes with the salt (per export), so it can't be looked up.
        Check(![ApolloRedactLogExportWithSalt(@"u/alice_one", nil, nil, @"a") isEqualToString:
                 ApolloRedactLogExportWithSalt(@"u/alice_one", nil, nil, @"b")], @"salt changes the tag");
        // Signed-in accounts become [me]/[me2], prefixed or bare, any case.
        CheckScrub(@"u/Kurisu_Main signed in; active account kurisu_main switched from KURISU_ALT",
                   @"u/[me] signed in; active account [me] switched from [me2]");
        CheckScrub(@"web sessions: (kurisu_main, \"kurisu_alt\") count=2", @"web sessions: ([me], \"[me2]\") count=2");
        CheckScrub(@"GET https://www.reddit.com/user/Kurisu_Main/about.json", @"GET https://www.reddit.com/user/[me]/about.json");
        CheckScrub(@"PUT api/multi/user/kurisu_main/m/cats", @"PUT api/multi/user/[me]/m/cats");
        // The longer own name wins over a prefix of it.
        CheckScrub(@"kurisu_alt", @"[me2]");
        // Keychain account names of web sessions, even for accounts no longer signed in.
        CheckScrub(@"account=websession:kurisu_alt:cookie", @"account=websession:[me2]:cookie");
        CheckGone(@"account=websession:removed_user:modhash", @"removed_user", @"websession:[user-");
        // Account IDs and chat routes.
        CheckGone(@"upsert /account/t2_9xyz12 ok", @"9xyz12", @"t2_[id-");
        CheckScrub(@"route /chat/room/!abcDEF:reddit.com -> /chat/user/t2_9xyz12",
                   @"route /chat/room/[id] -> /chat/user/[id]");
        // Words that merely contain u/ or user/ stay.
        CheckUnchanged(@"menu/settings lieu/x [ApolloFix] [UserAvatars] avatar=YES");

        // --- Credentials.
        CheckScrub(@"Authorization: Bearer abcdefghijklmnop123", @"Authorization: [redacted] [token]");
        CheckScrub(@"reddit_session=29348234%2C2026; token_v2=abcd.efgh; loid=000000x",
                   @"reddit_session=[redacted]; token_v2=[redacted]; loid=[redacted]");
        CheckScrub(@"signed in with clientId=AbCdEf123456GhIjKl7890", @"signed in with clientId=[redacted]");
        CheckScrub(@"{\"access_token\": \"abc123def\", \"expires_in\": 3600}",
                   @"{\"access_token\": \"[redacted]\", \"expires_in\": 3600}");
        // States and lengths are the point of these lines; keep them.
        CheckUnchanged(@"clientId=<empty> cookie=yes modhash=absent password: none token_v2=0");
        CheckGone(@"jwt eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1c2VyMTIzIn0.c2lnbmF0dXJlMTIz", @"eyJ", @"[token]");
        CheckScrub(@"Incorrect API key provided: sk-proj-abcdefghijklmnopqrstuvwxyz123456", @"Incorrect API key provided: [key]");
        CheckGone(@"key AIzaSyA1234567890abcdefghijklmnopqrstuv", @"AIzaSy", @"[key]");
        CheckScrub(@"/v1/device/0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0/accounts",
                   @"/v1/device/[hex-token]/accounts");
        CheckGone([@"live activity token " stringByAppendingString:[@"" stringByPaddingToLength:160 withString:@"ab12" startingAtIndex:0]],
                  @"ab12ab12", @"[hex-token]");
        CheckUnchanged(@"commit 5dda34675dda34675dda34675dda34675dda3467 uuid 11111111-2222-3333-4444-555555555555");

        // --- Emails, paths.
        CheckScrub(@"mail me at jane.doe@gmail.com", @"mail me at [email]");
        CheckUnchanged(@"loaded icon@2x.png and badge@3x.png");
        CheckScrub([kHome stringByAppendingString:@"/Library/ApolloKeychainMirror.plist"], @"~/Library/ApolloKeychainMirror.plist");
        CheckScrub(@"/private/var/containers/Bundle/Application/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/Apollo.app",
                   @"<container>/Apollo.app");
        CheckScrub(@"/Users/someone/Library/Developer/x.dylib", @"/Users/[mac-user]/Library/Developer/x.dylib");

        // --- What must stay readable (user decision: subreddits + post IDs).
        CheckUnchanged(@"[SubredditHeaders] r/AskReddit banner loaded for t3_1abcd2 t1_hk3j2 status=429");
        CheckUnchanged(@"err code=-1009 Error Domain=NSURLErrorDomain Code=-1001 (InlineImages) 12.5s 340KB");
        CheckUnchanged(@"ApolloFix Logs — Oct 14, 2026 at 9:00 PM (1234 entries)");

        // --- Re-scrubbing an export changes nothing.
        NSString *sample = @"u/SomeOtherGuy https://x.com/a?b=c reddit_session=abc kurisu_main jane@x.io";
        Check([Scrub(Scrub(sample)) isEqualToString:Scrub(sample)], @"scrub is idempotent");
        // Empty / nil-safe.
        Check([ApolloRedactLogExportWithSalt(@"", nil, nil, @"s") isEqualToString:@""], @"empty log");
        Check([ApolloRedactLogExportWithSalt(@"u/ab", @[ @"ab" ], nil, @"s") isEqualToString:@"u/ab"],
              @"names under 3 chars are not own-name masked");

        // --- Call-site helpers.
        Check([ApolloLogURL([NSURL URLWithString:@"apollo://reddit-oauth?state=XYZ&code=abc&state=dup"]) isEqualToString:@"apollo://reddit-oauth?{state,code}"],
              @"ApolloLogURL keeps key names only");
        Check([ApolloLogURL([NSURL URLWithString:@"https://bob:pw@www.reddit.com:443/api/v1/authorize?client_id=X#f"]) isEqualToString:@"https://www.reddit.com:443/api/v1/authorize?{client_id}"],
              @"ApolloLogURL drops userinfo and fragment");
        Check([ApolloLogURL(nil) isEqualToString:@"nil"], @"ApolloLogURL nil");
        Check([ApolloLogFingerprint(@"AbCdEf123456GhIjKl7890") isEqualToString:ApolloLogFingerprint(@"AbCdEf123456GhIjKl7890")] &&
              ApolloLogFingerprint(@"AbCdEf123456GhIjKl7890").length == 4, @"fingerprint is stable 4-hex");
        Check(![ApolloLogFingerprint(@"key-one-aaaaaaaa") isEqualToString:ApolloLogFingerprint(@"key-two-bbbbbbbb")], @"fingerprints differ");
        Check([ApolloLogFingerprint(@"") isEqualToString:@"none"] && [ApolloLogFingerprint(nil) isEqualToString:@"none"], @"fingerprint of empty");
        Check([ApolloLogOwnThing(@"t1_hk3j2") hasPrefix:@"t1_#"] && ![ApolloLogOwnThing(@"t1_hk3j2") containsString:@"hk3j2"], @"own thing keeps kind only");
        Check([ApolloLogOwnThing(@"hk3j2") hasPrefix:@"#"], @"own thing without prefix");
        Check([ApolloLogPageTitleKind(@"u/janedoe (Jane Doe) - Reddit") isEqualToString:@"reddit(29 chars)"], @"title kind reddit");
        Check([ApolloLogPageTitleKind(@"Just a moment...") isEqualToString:@"challenge"], @"title kind challenge");
        Check([ApolloLogPageTitleKind(nil) isEqualToString:@"empty"] && [ApolloLogPageTitleKind(@42) isEqualToString:@"empty"], @"title kind non-string");

        // --- Cost on a big export (the bug-report form caps at 5 MB). Mostly
        // plain lines, like a real log, with a match on every fifth.
        NSMutableString *big = [NSMutableString stringWithCapacity:5 * 1024 * 1024 + 512];
        NSUInteger i = 0;
        while (big.length < 5 * 1024 * 1024) {
            if (i % 5 == 0) {
                [big appendFormat:@"[12:00:%02lu.000] [ApolloFix] [WebJSON] u/user_%lu GET https://www.reddit.com/r/sub%lu/comments/abc/slug/?raw_json=1 -> 200 for kurisu_main\n", i % 60, i % 997, i % 50];
            } else {
                [big appendFormat:@"[12:00:%02lu.000] [ApolloFix] [ListLayout] inset top=%lu bottom=34 state=settled cell=%lu reason=scroll\n", i % 60, i % 400, i];
            }
            i++;
        }
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSString *bigOut = ApolloRedactLogExport(big, kOwn(), kHome);
        CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;
        Check(![bigOut containsString:@"kurisu_main"] && ![bigOut containsString:@"u/user_1 "], @"big export scrubbed");
        printf("5 MB export scrubbed in %.2fs on this host (%lu -> %lu chars)\n", elapsed,
               (unsigned long)big.length, (unsigned long)bigOut.length);
        Check(elapsed < 10.0, [NSString stringWithFormat:@"5 MB scrub took %.2fs", elapsed]);

        if (failures > 0) {
            fprintf(stderr, "log_redaction_tests: %lu of %lu checks failed\n", (unsigned long)failures, (unsigned long)checks);
            return 1;
        }
        printf("log_redaction_tests: %lu checks passed\n", (unsigned long)checks);
        return 0;
    }
}
