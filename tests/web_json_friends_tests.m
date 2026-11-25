// Host-side checks for src/ApolloWebJSONFriends.m: the POST /api/friend and
// /api/unfriend form an API-Key-Free account sends for Add / Remove Friend
// (issue #1787), and how Reddit's answer is read as applied or refused.
#import <Foundation/Foundation.h>
#import "ApolloWebJSONFriends.h"

static int sFailures = 0;
static int sChecks = 0;

#define CHECK(cond, ...) do { \
    sChecks++; \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static id JSON(NSString *text) {
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

static void TestPaths(void) {
    // The same relative paths Apollo's own -friendTaskWithContainer:... and
    // -unfriendTaskWithContainer:... send (strings in the 1.15.11 binary).
    CHECK([ApolloWebJSONFriendAddPath isEqualToString:@"api/friend"], @"add path %@", ApolloWebJSONFriendAddPath);
    CHECK([ApolloWebJSONFriendRemovePath isEqualToString:@"api/unfriend"], @"remove path %@", ApolloWebJSONFriendRemovePath);
}

static void TestParameters(void) {
    // The request checked live on 2026-11-25.
    NSDictionary *p = ApolloWebJSONFriendWriteParameters(@"reddit", @"t2_2rllqbo0vx");
    NSDictionary *expected = @{ @"api_type": @"json", @"type": @"friend", @"name": @"reddit", @"container": @"t2_2rllqbo0vx" };
    CHECK([p isEqualToDictionary:expected], @"form %@", p);

    // Short ids and mixed-case usernames pass through as they are.
    p = ApolloWebJSONFriendWriteParameters(@"Some_User-1", @"t2_1qwk");
    CHECK([p[@"name"] isEqualToString:@"Some_User-1"] && [p[@"container"] isEqualToString:@"t2_1qwk"], @"form %@", p);

    // No username: nothing to send.
    CHECK(ApolloWebJSONFriendWriteParameters(nil, @"t2_abc") == nil, @"nil username built a form");
    CHECK(ApolloWebJSONFriendWriteParameters(@"", @"t2_abc") == nil, @"empty username built a form");
    CHECK(ApolloWebJSONFriendWriteParameters((NSString *)(id)@42, @"t2_abc") == nil, @"non-string username built a form");

    // Without the account's own t2_ id Reddit says ok and friends nobody, so
    // anything that isn't one must not build a form.
    NSArray *badContainers = @[ @"", @"t2_", @"t2_(null)", @"t3_abc123", @"T2_abc", @"abc123", @"t2_abc 1",
                                @"t2_ABC", @"t2_abc/def", @" t2_abc" ];
    for (NSString *container in badContainers) {
        CHECK(ApolloWebJSONFriendWriteParameters(@"reddit", container) == nil, @"container '%@' built a form", container);
    }
    CHECK(ApolloWebJSONFriendWriteParameters(@"reddit", nil) == nil, @"nil container built a form");
    CHECK(ApolloWebJSONFriendWriteParameters(@"reddit", (NSString *)(id)@[]) == nil, @"non-string container built a form");
}

static void TestAccountFullNameFromMe(void) {
    // The shape www's /api/me.json sends a cookie account (trimmed, 2026-11-25).
    id me = JSON(@"{\"kind\": \"t2\", \"data\": {\"id\": \"2rllqbo0vx\", \"name\": \"ChoiceOfSteinsGate00\", \"is_suspended\": false}}");
    NSString *f = ApolloWebJSONFriendAccountFullNameFromMe(me, @"ChoiceOfSteinsGate00");
    CHECK([f isEqualToString:@"t2_2rllqbo0vx"], @"me -> %@", f);
    // The session store keeps usernames lowercased.
    f = ApolloWebJSONFriendAccountFullNameFromMe(me, @"choiceofsteinsgate00");
    CHECK([f isEqualToString:@"t2_2rllqbo0vx"], @"case-insensitive name -> %@", f);
    // The bare data object, and an id that's already a fullname.
    f = ApolloWebJSONFriendAccountFullNameFromMe(@{ @"id": @"1qwk", @"name": @"reddit" }, @"reddit");
    CHECK([f isEqualToString:@"t2_1qwk"], @"bare data -> %@", f);
    f = ApolloWebJSONFriendAccountFullNameFromMe(@{ @"data": @{ @"id": @"t2_1qwk", @"name": @"reddit" } }, @"reddit");
    CHECK([f isEqualToString:@"t2_1qwk"], @"prefixed id -> %@", f);

    // Another account's answer (a cookie that belongs to someone else) is never used.
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(me, @"SomeoneElse") == nil, @"other account's id accepted");
    // A logged-out answer, a missing or odd id, or no expected name: nothing.
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(JSON(@"{}"), @"reddit") == nil, @"empty me accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(@{ @"data": @{ @"name": @"reddit" } }, @"reddit") == nil, @"no id accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(@{ @"data": @{ @"id": @"", @"name": @"reddit" } }, @"reddit") == nil, @"empty id accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(@{ @"data": @{ @"id": @12, @"name": @"reddit" } }, @"reddit") == nil, @"numeric id accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(@{ @"data": @{ @"id": @"ab cd", @"name": @"reddit" } }, @"reddit") == nil, @"bad id accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(@{ @"data": @{ @"id": @"t3_abc", @"name": @"reddit" } }, @"reddit") == nil, @"t3 id accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(me, nil) == nil, @"nil expected name accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(me, @"") == nil, @"empty expected name accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(@"t2_abc", @"reddit") == nil, @"string object accepted");
    CHECK(ApolloWebJSONFriendAccountFullNameFromMe(nil, @"reddit") == nil, @"nil object accepted");
}

static void TestFailureMessage(void) {
    // Applied: the empty error list Reddit sends for a friend it added or removed.
    CHECK(ApolloWebJSONFriendWriteFailureMessage(200, JSON(@"{\"json\": {\"errors\": []}}")) == nil, @"empty errors read as a failure");
    // No json envelope, or nothing parsed: not judged here (RedditKit already
    // fails a body it can't parse).
    CHECK(ApolloWebJSONFriendWriteFailureMessage(200, nil) == nil, @"nil object read as a failure");
    CHECK(ApolloWebJSONFriendWriteFailureMessage(200, @{}) == nil, @"empty dict read as a failure");
    CHECK(ApolloWebJSONFriendWriteFailureMessage(200, @[]) == nil, @"array read as a failure");
    CHECK(ApolloWebJSONFriendWriteFailureMessage(200, @{ @"json": @{} }) == nil, @"no errors key read as a failure");
    CHECK(ApolloWebJSONFriendWriteFailureMessage(0, @{ @"json": @{ @"errors": @[] } }) == nil, @"status 0 + empty errors read as a failure");

    // Refused with an HTTP status (the 403 block page RedditKit passes on as success).
    NSString *m = ApolloWebJSONFriendWriteFailureMessage(403, nil);
    CHECK([m isEqualToString:@"Reddit refused the request (HTTP 403)"], @"403 -> %@", m);
    m = ApolloWebJSONFriendWriteFailureMessage(400, JSON(@"{\"json\": {\"errors\": []}}"));
    CHECK([m containsString:@"HTTP 400"], @"400 -> %@", m);
    CHECK(ApolloWebJSONFriendWriteFailureMessage(399, nil) == nil, @"399 read as a failure");

    // Refused with Reddit's own error: the message, else the code.
    m = ApolloWebJSONFriendWriteFailureMessage(200, JSON(@"{\"json\": {\"errors\": [[\"USER_DOESNT_EXIST\", \"that user doesn't exist\", \"name\"]]}}"));
    CHECK([m isEqualToString:@"that user doesn't exist"], @"message -> %@", m);
    m = ApolloWebJSONFriendWriteFailureMessage(200, JSON(@"{\"json\": {\"errors\": [[\"RATELIMIT\"]]}}"));
    CHECK([m isEqualToString:@"RATELIMIT"], @"code only -> %@", m);
    m = ApolloWebJSONFriendWriteFailureMessage(200, JSON(@"{\"json\": {\"errors\": [[\"RATELIMIT\", \"\"]]}}"));
    CHECK([m isEqualToString:@"RATELIMIT"], @"empty message -> %@", m);
    m = ApolloWebJSONFriendWriteFailureMessage(200, JSON(@"{\"json\": {\"errors\": [\"BAD_THING\"]}}"));
    CHECK([m isEqualToString:@"BAD_THING"], @"string entry -> %@", m);
    // An entry with nothing readable is still a refusal.
    m = ApolloWebJSONFriendWriteFailureMessage(200, JSON(@"{\"json\": {\"errors\": [[]]}}"));
    CHECK(m.length > 0, @"unreadable entry read as applied");
    m = ApolloWebJSONFriendWriteFailureMessage(200, JSON(@"{\"json\": {\"errors\": [42]}}"));
    CHECK(m.length > 0, @"numeric entry read as applied");
}

int main(void) {
    @autoreleasepool {
        TestPaths();
        TestParameters();
        TestAccountFullNameFromMe();
        TestFailureMessage();
    }
    if (sFailures) {
        fprintf(stderr, "web_json_friends_tests: %d of %d checks failed\n", sFailures, sChecks);
        return 1;
    }
    printf("web_json_friends_tests: all %d checks passed\n", sChecks);
    return 0;
}
