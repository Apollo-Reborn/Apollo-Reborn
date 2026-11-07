#import "ApolloSubscriptionRefreshGuard.h"

// Lowercased usernames whose failed refresh page is being delivered right now,
// innermost last. Pushed and popped on the thread that delivers the page (RedditKit
// calls taskWithMethod completions on the main queue); read from whichever thread
// sets a list (Mantle also sets it while decoding a stored account), so every
// access is under the lock.
static NSMutableArray<NSString *> *sApolloSubscriptionRefreshFailing;

static NSObject *ApolloSubscriptionRefreshLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

void ApolloSubscriptionRefreshDeliverFailedPage(NSString *username, void (NS_NOESCAPE ^deliver)(void)) {
    NSString *user = username.lowercaseString;
    if (user.length == 0) {
        deliver();
        return;
    }
    @synchronized (ApolloSubscriptionRefreshLock()) {
        if (!sApolloSubscriptionRefreshFailing) sApolloSubscriptionRefreshFailing = [NSMutableArray array];
        [sApolloSubscriptionRefreshFailing addObject:user];
    }
    @try {
        deliver();
    } @finally {
        @synchronized (ApolloSubscriptionRefreshLock()) {
            NSUInteger index = [sApolloSubscriptionRefreshFailing indexOfObjectWithOptions:NSEnumerationReverse
                                                                               passingTest:^BOOL(NSString *entry, __unused NSUInteger idx, __unused BOOL *stop) {
                return [entry isEqualToString:user];
            }];
            if (index != NSNotFound) [sApolloSubscriptionRefreshFailing removeObjectAtIndex:index];
        }
    }
}

ApolloSubscriptionListDecision ApolloSubscriptionRefreshDecideList(NSString *username, NSArray *current, NSArray *incoming) {
    NSString *user = username.lowercaseString;
    if (user.length == 0) return ApolloSubscriptionListDecisionApply;
    BOOL failing = NO;
    @synchronized (ApolloSubscriptionRefreshLock()) {
        failing = [sApolloSubscriptionRefreshFailing containsObject:user];
    }
    if (!failing) return ApolloSubscriptionListDecisionApply;
    if (![current isKindOfClass:[NSArray class]] || current.count == 0) return ApolloSubscriptionListDecisionApplyNothingToKeep;
    if ([incoming isKindOfClass:[NSArray class]] && incoming.count >= current.count) return ApolloSubscriptionListDecisionApplyNotShorter;
    return ApolloSubscriptionListDecisionKeep;
}
