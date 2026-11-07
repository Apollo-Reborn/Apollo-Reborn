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

        // Thread safety: setters on other threads while pages are delivered on this one.
        dispatch_group_t group = dispatch_group_create();
        __block NSUInteger keptElsewhere = 0;
        NSObject *countLock = [NSObject new];
        for (int i = 0; i < 8; i++) {
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                for (int j = 0; j < 2000; j++) {
                    if (ApolloSubscriptionRefreshDecideList(@"dave", seventyEight, @[]) == ApolloSubscriptionListDecisionKeep) {
                        @synchronized (countLock) { keptElsewhere++; }
                    }
                }
            });
        }
        for (int j = 0; j < 2000; j++) {
            ApolloSubscriptionRefreshDeliverFailedPage(@"erin", ^{
                (void)ApolloSubscriptionRefreshDecideList(@"erin", seventyEight, @[]);
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        Check(keptElsewhere == 0, @"an account with no failed page is never refused, from any thread");
        Check(ApolloSubscriptionRefreshDecideList(@"erin", seventyEight, @[]) == ApolloSubscriptionListDecisionApply,
              @"every scope was removed");

        NSLog(@"subscription refresh guard: %lu checks passed", (unsigned long)sChecks);
    }
    return 0;
}
