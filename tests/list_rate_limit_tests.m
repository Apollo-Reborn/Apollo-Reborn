#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Exercises the shipping rate-limit decisions from ApolloListEmptyState.xm (issues #1664, #1649):
// which first page may update a list, which lists wait on Reddit's hold, and what a retry pass does
// with each one, with ApolloWebJSON's per-account hold stubbed.

static NSMutableDictionary<NSString *, NSNumber *> *sHolds;
static NSTimeInterval ApolloWebJSONOptionalReadBackoff(NSString *username) {
    return username.length > 0 ? sHolds[username.lowercaseString].doubleValue : 0;
}

#include "ListRateLimit.inc"

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { failures++; NSLog(@"FAIL: %s", msg); } } while (0)

static ApolloListLoadState *State(NSString *account) {
    ApolloListLoadState *state = [ApolloListLoadState new];
    state.kind = ApolloListKindPosts;
    state.account = account;
    return state;
}

static ApolloListLoadState *Waiting(NSString *account) {
    ApolloListLoadState *state = State(account);
    state.outcome = ApolloListOutcomeFailed;
    state.waitingForRateLimit = YES;
    return state;
}

int main(void) {
    @autoreleasepool {
        sHolds = [NSMutableDictionary dictionary];

        // Which first pages wait.
        sHolds[@"a"] = @60;
        ApolloListLoadState *s = State(@"a");
        CHECK(ApolloListRecordOutcome(s, s, ApolloListOutcomeFailed, YES) && s.waitingForRateLimit,
              "a failed first page on an empty list waits while its account is held");
        s = State(@"a");
        CHECK(ApolloListRecordOutcome(s, s, ApolloListOutcomeFailed, NO) && !s.waitingForRateLimit,
              "a list that still shows posts never waits (nothing reloads under the reader)");
        s = State(@"a");
        CHECK(ApolloListRecordOutcome(s, s, ApolloListOutcomeEmpty, YES) && !s.waitingForRateLimit,
              "an empty page isn't a rate limit");
        s = State(nil);
        CHECK(ApolloListRecordOutcome(s, s, ApolloListOutcomeFailed, YES) && !s.waitingForRateLimit,
              "an API-key account's list never waits, even while a keyless account is held");
        s = State(@"b");
        CHECK(ApolloListRecordOutcome(s, s, ApolloListOutcomeFailed, YES) && !s.waitingForRateLimit,
              "another account's hold doesn't make this account's list wait");

        // Overlapping first pages: a newer one replaces the list's state.
        ApolloListLoadState *older = State(@"a");
        ApolloListLoadState *newer = State(@"a");
        CHECK(!ApolloListRecordOutcome(newer, older, ApolloListOutcomeFailed, YES),
              "an older first page finishing after a newer one started doesn't own the list");
        CHECK(newer.outcome == ApolloListOutcomeNone && !newer.waitingForRateLimit,
              "the older page's failure doesn't mark the newer state waiting");
        CHECK(older.outcome == ApolloListOutcomeNone && !older.waitingForRateLimit,
              "the replaced state isn't updated either");
        CHECK(ApolloListRecordOutcome(newer, newer, ApolloListOutcomeFailed, YES) && newer.waitingForRateLimit,
              "the newer page settles the list");
        CHECK(!ApolloListRecordOutcome(newer, older, ApolloListOutcomeNone, NO) && newer.waitingForRateLimit &&
              newer.outcome == ApolloListOutcomeFailed,
              "an older page that succeeds late doesn't clear the newer page's wait");
        CHECK(!ApolloListRecordOutcome(nil, older, ApolloListOutcomeFailed, YES), "a list with no state isn't touched");

        // A pass, judged by each list's own account and hold.
        ApolloListLoadState *a = Waiting(@"a");
        sHolds[@"a"] = @60;
        CHECK(ApolloListRetryActionFor(a, @"a", YES) == ApolloListRetryActionWait, "waits while its account is held");
        sHolds[@"a"] = @0;
        CHECK(ApolloListRetryActionFor(a, @"a", YES) == ApolloListRetryActionReload, "reloads once its account's hold ends");
        CHECK(ApolloListRetryActionFor(a, @"a", NO) == ApolloListRetryActionLater, "waits for the app to be active");

        // Switching accounts while a list waits.
        sHolds[@"b"] = @0;
        CHECK(ApolloListRetryActionFor(a, @"b", YES) == ApolloListRetryActionDiscard,
              "after a switch to another keyless account with no hold, A's list doesn't reload as B");
        sHolds[@"a"] = @300;
        CHECK(ApolloListRetryActionFor(a, @"b", YES) == ApolloListRetryActionDiscard,
              "nor before A's own hold ends");
        CHECK(ApolloListRetryActionFor(a, nil, YES) == ApolloListRetryActionDiscard,
              "after a switch to an API-key account it stops waiting too");
        CHECK(ApolloListRetryActionFor(a, @"a", YES) == ApolloListRetryActionWait,
              "switching back to A before its hold ends keeps the wait");

        // Another account's longer hold neither holds nor postpones this one.
        sHolds[@"a"] = @0;
        sHolds[@"b"] = @500;
        CHECK(ApolloListRetryActionFor(a, @"a", YES) == ApolloListRetryActionReload,
              "B's longer hold doesn't keep A's list waiting");
        NSMutableArray *reload = [NSMutableArray array], *discard = [NSMutableArray array];
        ApolloListLoadState *b = Waiting(@"b");
        NSTimeInterval next = ApolloListPlanRetry(@[ a, b ], @"a", YES, reload, discard);
        CHECK(next < 0, "nothing still waits on a hold, so no further pass is due");
        CHECK(reload.count == 1 && reload[0] == a, "A's list reloads");
        CHECK(discard.count == 1 && discard[0] == b, "B's list, from an account no longer active, stops waiting");

        // The next pass is due at the earliest hold among the lists that wait.
        sHolds[@"a"] = @60;
        ApolloListLoadState *a2 = Waiting(@"a");
        ApolloListLoadState *notWaiting = State(@"a");
        notWaiting.outcome = ApolloListOutcomeFailed;
        [reload removeAllObjects];
        [discard removeAllObjects];
        next = ApolloListPlanRetry(@[ a, a2, notWaiting ], @"a", YES, reload, discard);
        CHECK(next == 60 + kApolloListRateLimitRetryMargin, "the next pass comes the margin after the hold ends");
        CHECK(reload.count == 0 && discard.count == 0, "lists still held neither reload nor stop waiting");

        ApolloListLoadState *emptyOutcome = Waiting(@"a");
        emptyOutcome.outcome = ApolloListOutcomeEmpty;
        CHECK(ApolloListRetryActionFor(emptyOutcome, @"a", YES) == ApolloListRetryActionNone,
              "only a failed first page waits");
        CHECK(ApolloListRetryActionFor(notWaiting, @"a", YES) == ApolloListRetryActionNone,
              "a failure that isn't waiting is left to pull to refresh");
    }
    if (failures) {
        NSLog(@"%d list rate-limit check(s) failed", failures);
        return 1;
    }
    NSLog(@"list rate-limit tests passed");
    return 0;
}
