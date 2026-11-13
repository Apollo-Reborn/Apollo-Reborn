// Host-side tests for ApolloSubscriptionRefreshGuard (#1635, #1409): a list
// stored while a failed subscription-refresh page is being delivered for the same
// account is refused when it would shorten the account's list, and nothing else is.
#import <Foundation/Foundation.h>
#import "ApolloSubscriptionRefreshGuard.h"

static NSUInteger sChecks;
static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

static NSArray<NSString *> *Subs(NSUInteger count) {
    NSMutableArray *subs = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) [subs addObject:[NSString stringWithFormat:@"sub%lu", (unsigned long)i]];
    return subs;
}

int main(void) {
    @autoreleasepool {
        NSArray *seventyEight = Subs(78);

        // Outside a failed page nothing is held back: refreshes, unsubscribes, a real empty list.
        Check(ApolloSubscriptionRefreshDecideList(@"alice", seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
              @"no failed page: an empty list is stored");
        Check(ApolloSubscriptionRefreshDecideList(@"alice", seventyEight, Subs(77)) == ApolloSubscriptionListDecisionApply,
              @"no failed page: an unsubscribe is stored");

        // #1635: the timer refresh's first page fails, its closure stores no subscriptions.
        __block BOOL ran = NO;
        ApolloSubscriptionRefreshDeliverFailedPage(@"Alice", ^{
            ran = YES;
            Check(ApolloSubscriptionRefreshDecideList(@"alice", seventyEight, @[]) == ApolloSubscriptionListDecisionKeep,
                  @"failed first page: the empty list is refused");
            Check(ApolloSubscriptionRefreshDecideList(@"ALICE", seventyEight, nil) == ApolloSubscriptionListDecisionKeep,
                  @"usernames compare case-insensitively; a nil list is refused too");
            // #1409: a later page fails, the pages it had are shorter than the account's list.
            Check(ApolloSubscriptionRefreshDecideList(@"alice", seventyEight, Subs(40)) == ApolloSubscriptionListDecisionKeep,
                  @"cut-short walk: the partial list is refused");
            Check(ApolloSubscriptionRefreshDecideList(@"alice", Subs(40), seventyEight) == ApolloSubscriptionListDecisionApplyNotShorter,
                  @"a list that isn't shorter is stored");
            Check(ApolloSubscriptionRefreshDecideList(@"alice", @[], Subs(10)) == ApolloSubscriptionListDecisionApplyNothingToKeep,
                  @"an account with no list yet takes what arrived");
            Check(ApolloSubscriptionRefreshDecideList(@"alice", nil, Subs(10)) == ApolloSubscriptionListDecisionApplyNothingToKeep,
                  @"an account with no list (nil) takes what arrived");
            // Two accounts: the timer refreshes every account; another account's store is untouched.
            Check(ApolloSubscriptionRefreshDecideList(@"bob", seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
                  @"another account is not affected by alice's failed page");
            Check(ApolloSubscriptionRefreshDecideList(nil, seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
                  @"a user without a username is not matched");
            // Nested: bob's failed page delivered while alice's is still on the stack.
            ApolloSubscriptionRefreshDeliverFailedPage(@"bob", ^{
                Check(ApolloSubscriptionRefreshDecideList(@"bob", seventyEight, @[]) == ApolloSubscriptionListDecisionKeep,
                      @"nested failed page for bob is guarded");
                Check(ApolloSubscriptionRefreshDecideList(@"alice", seventyEight, @[]) == ApolloSubscriptionListDecisionKeep,
                      @"alice stays guarded inside the nested delivery");
            });
            Check(ApolloSubscriptionRefreshDecideList(@"bob", seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
                  @"bob's scope ends with its delivery");
        });
        Check(ran, @"the page is delivered");

        // The scope ends with the delivery: a later unsubscribe is never held back.
        Check(ApolloSubscriptionRefreshDecideList(@"alice", seventyEight, Subs(77)) == ApolloSubscriptionListDecisionApply,
              @"after the failed page an unsubscribe is stored");
        Check(ApolloSubscriptionRefreshDecideList(@"alice", seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
              @"after the failed page a real empty list is stored");

        // An empty username delivers unguarded.
        __block BOOL ranEmpty = NO;
        ApolloSubscriptionRefreshDeliverFailedPage(@"", ^{
            ranEmpty = YES;
            Check(ApolloSubscriptionRefreshDecideList(@"", seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
                  @"an empty username is never guarded");
        });
        Check(ranEmpty, @"an empty username still delivers");

        // The scope is removed even if the completion throws.
        @try {
            ApolloSubscriptionRefreshDeliverFailedPage(@"carol", ^{
                [NSException raise:NSInternalInconsistencyException format:@"completion threw"];
            });
        } @catch (__unused NSException *e) {
        }
        Check(ApolloSubscriptionRefreshDecideList(@"carol", seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
              @"a throwing completion does not leave carol guarded");

        // Same account, another queue (review on PR #1674): while frank's failed page is being
        // delivered on one thread, a legitimate two-to-one change for frank made on another queue
        // is a separate write and goes through. Only the delivering thread's own store is refused.
        NSArray *two = Subs(2), *one = Subs(1);
        dispatch_semaphore_t entered = dispatch_semaphore_create(0);
        dispatch_semaphore_t release = dispatch_semaphore_create(0);
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block ApolloSubscriptionListDecision onDeliveringThread = ApolloSubscriptionListDecisionApply;
        dispatch_async(dispatch_queue_create("failed-delivery", DISPATCH_QUEUE_SERIAL), ^{
            ApolloSubscriptionRefreshDeliverFailedPage(@"frank", ^{
                dispatch_semaphore_signal(entered);
                dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
                onDeliveringThread = ApolloSubscriptionRefreshDecideList(@"frank", two, one);
            });
            dispatch_semaphore_signal(finished);
        });
        dispatch_semaphore_wait(entered, DISPATCH_TIME_FOREVER);
        Check(ApolloSubscriptionRefreshDecideList(@"frank", two, one) == ApolloSubscriptionListDecisionApply,
              @"same account, this thread, during another thread's failed delivery: the unsubscribe is stored");
        __block ApolloSubscriptionListDecision onOtherQueue = ApolloSubscriptionListDecisionKeep;
        dispatch_sync(dispatch_queue_create("unsubscribe", DISPATCH_QUEUE_SERIAL), ^{
            onOtherQueue = ApolloSubscriptionRefreshDecideList(@"FRANK", two, one);
        });
        Check(onOtherQueue == ApolloSubscriptionListDecisionApply,
              @"same account, a third queue, during the failed delivery: the unsubscribe is stored");
        dispatch_semaphore_signal(release);
        dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
        Check(onDeliveringThread == ApolloSubscriptionListDecisionKeep,
              @"the delivering thread's own shorter list is still refused");

        // The same under load: setters for the SAME account on other threads while its failed
        // pages are delivered over and over on this one are never refused, and every delivery
        // still refuses its own shorter list.
        dispatch_group_t group = dispatch_group_create();
        __block NSUInteger keptElsewhere = 0;
        __block NSUInteger keptHere = 0;
        NSObject *countLock = [NSObject new];
        for (int i = 0; i < 8; i++) {
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                for (int j = 0; j < 2000; j++) {
                    if (ApolloSubscriptionRefreshDecideList(@"erin", seventyEight, @[]) == ApolloSubscriptionListDecisionKeep) {
                        @synchronized (countLock) { keptElsewhere++; }
                    }
                }
            });
        }
        for (int j = 0; j < 2000; j++) {
            ApolloSubscriptionRefreshDeliverFailedPage(@"erin", ^{
                if (ApolloSubscriptionRefreshDecideList(@"erin", seventyEight, @[]) == ApolloSubscriptionListDecisionKeep) keptHere++;
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        Check(keptElsewhere == 0, @"the same account on other threads is never refused during this thread's failed deliveries");
        Check(keptHere == 2000, @"every failed delivery refuses its own shorter list");
        Check(ApolloSubscriptionRefreshDecideList(@"erin", seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
              @"every scope was removed");

        NSLog(@"subscription refresh guard: %lu checks passed", (unsigned long)sChecks);
    }
    return 0;
}
