#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Exercises the shipping rate-limit decisions from ApolloListEmptyState.xm (issues #1664, #1649):
// which lists wait on Reddit's hold, what a retry pass does with each one, and when the next pass
// is scheduled, with ApolloWebJSON's per-account hold, the wall clock and dispatch stubbed.

static NSMutableDictionary<NSString *, NSNumber *> *sHolds;
static NSTimeInterval ApolloWebJSONOptionalReadBackoff(NSString *username) {
    return username.length > 0 ? sHolds[username.lowercaseString].doubleValue : 0;
}

#include "ListRateLimit.inc"

// The block's clock, dispatch and pass, recorded instead of run.
static NSTimeInterval sNow;
static NSMutableArray<NSArray *> *sDispatched; // @[ fire time, block ]
static int sPasses;
static NSTimeInterval ApolloListWallClockNow(void) { return sNow; }
static void ApolloListAfterWallClock(NSTimeInterval delay, dispatch_block_t block) {
    [sDispatched addObject:@[ @(sNow + delay), [block copy] ]];
}
static void ApolloListRetryRateLimitedLists(void) { sPasses++; }

// Runs the pending dispatch due at `at` (advancing the clock to it).
static BOOL Fire(NSTimeInterval at) {
    for (NSArray *entry in [sDispatched copy]) {
        if ([entry[0] doubleValue] != at) continue;
        [sDispatched removeObject:entry];
        sNow = at;
        ((dispatch_block_t)entry[1])();
        return YES;
    }
    return NO;
}

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
        ApolloListRecordOutcome(s, ApolloListOutcomeFailed, YES);
        CHECK(s.waitingForRateLimit, "a failed first page on an empty list waits while its account is held");
        s = State(@"a");
        ApolloListRecordOutcome(s, ApolloListOutcomeFailed, NO);
        CHECK(!s.waitingForRateLimit, "a list that still shows posts never waits (nothing reloads under the reader)");
        s = State(@"a");
        ApolloListRecordOutcome(s, ApolloListOutcomeEmpty, YES);
        CHECK(!s.waitingForRateLimit, "an empty page isn't a rate limit");
        s = State(nil);
        ApolloListRecordOutcome(s, ApolloListOutcomeFailed, YES);
        CHECK(!s.waitingForRateLimit, "an API-key account's list never waits, even while a keyless account is held");
        s = State(@"b");
        ApolloListRecordOutcome(s, ApolloListOutcomeFailed, YES);
        CHECK(!s.waitingForRateLimit, "another account's hold doesn't make this account's list wait");
        ApolloListRecordOutcome(nil, ApolloListOutcomeFailed, YES); // a list with no state: no crash

        // Overlapping first pages: Apollo shows the one that arrives last, and the wait follows it.
        s = State(@"a");
        ApolloListRecordOutcome(s, ApolloListOutcomeFailed, YES);
        ApolloListRecordOutcome(s, ApolloListOutcomeNone, NO);
        CHECK(s.outcome == ApolloListOutcomeNone && !s.waitingForRateLimit,
              "a late page that brought posts clears the wait (the list shows them)");
        ApolloListRecordOutcome(s, ApolloListOutcomeFailed, NO);
        CHECK(s.outcome == ApolloListOutcomeFailed && !s.waitingForRateLimit,
              "a late failure while the list still shows posts doesn't start a wait");
        ApolloListRecordOutcome(s, ApolloListOutcomeFailed, YES);
        CHECK(s.waitingForRateLimit, "a late failure on an empty list waits like any other");

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

        // Scheduling (review case): A held for 600 s schedules its pass at 605; after a switch to B,
        // B's 30 s hold must move the next pass to 35, not wait behind A's.
        sDispatched = [NSMutableArray array];
        sNow = 0;
        sPasses = 0;
        sListRateLimitRetryAt = 0;
        ApolloListScheduleRateLimitRetry(600 + kApolloListRateLimitRetryMargin);
        CHECK(sDispatched.count == 1 && [sDispatched[0][0] doubleValue] == 605, "A's pass is due at 605");
        ApolloListScheduleRateLimitRetry(30 + kApolloListRateLimitRetryMargin);
        CHECK(sDispatched.count == 2 && [sDispatched[1][0] doubleValue] == 35, "B's shorter hold schedules a pass at 35");
        CHECK(sListRateLimitRetryAt == 35, "the earliest pending pass is B's");
        ApolloListScheduleRateLimitRetry(300);
        CHECK(sDispatched.count == 2, "a later deadline doesn't add a pass while an earlier one is pending");
        ApolloListScheduleRateLimitRetry(35.5);
        CHECK(sDispatched.count == 2, "nor one within a second of it");
        CHECK(Fire(35) && sPasses == 1 && sListRateLimitRetryAt == 0, "B's pass runs at 35 and clears the pending time");
        // At 35 B's own hold has ended: its list reloads, judged by B's hold, while A's longer one still runs.
        sHolds[@"a"] = @570;
        sHolds[@"b"] = @0;
        ApolloListLoadState *bWaiting = Waiting(@"b");
        [reload removeAllObjects];
        [discard removeAllObjects];
        CHECK(ApolloListPlanRetry(@[ bWaiting ], @"b", YES, reload, discard) < 0 && reload.count == 1,
              "B's list reloads on B's own hold, not A's");
        ApolloListScheduleRateLimitRetry(570 + kApolloListRateLimitRetryMargin);
        CHECK(sDispatched.count == 2 && [sDispatched[1][0] doubleValue] == 610, "a new deadline after the pass schedules again");
        CHECK(Fire(605) && sPasses == 2 && sListRateLimitRetryAt == 610,
              "the stale 605 pass still runs (finding nothing new) and leaves the 610 one pending");
        CHECK(Fire(610) && sPasses == 3 && sListRateLimitRetryAt == 0, "the 610 pass runs");
    }
    if (failures) {
        NSLog(@"%d list rate-limit check(s) failed", failures);
        return 1;
    }
    NSLog(@"list rate-limit tests passed");
    return 0;
}
