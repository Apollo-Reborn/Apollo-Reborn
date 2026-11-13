#import "ApolloSubscriptionRefreshGuard.h"

// Lowercased usernames whose failed refresh page is being delivered on THIS
// thread, innermost last, kept in the thread's own dictionary. RedditKit calls a
// page's completion on the main queue and the walker and AccountManager's closure
// store the list synchronously from it, on the same thread. So a list set on any
// other thread meanwhile is a separate write (Mantle decoding a stored account,
// an unsubscribe on another queue) and must never see this delivery's mark, even
// for the same account. Per-thread storage also means no lock.
static NSString *const kApolloSubscriptionRefreshFailingKey = @"ApolloSubscriptionRefreshFailing";

static NSMutableArray<NSString *> *ApolloSubscriptionRefreshFailingOnThisThread(BOOL create) {
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    NSMutableArray<NSString *> *stack = threadDictionary[kApolloSubscriptionRefreshFailingKey];
    if (!stack && create) {
        stack = [NSMutableArray array];
        threadDictionary[kApolloSubscriptionRefreshFailingKey] = stack;
    }
    return stack;
}

void ApolloSubscriptionRefreshDeliverFailedPage(NSString *username, void (NS_NOESCAPE ^deliver)(void)) {
    NSString *user = username.lowercaseString;
    if (user.length == 0) {
        deliver();
        return;
    }
    NSMutableArray<NSString *> *stack = ApolloSubscriptionRefreshFailingOnThisThread(YES);
    [stack addObject:user];
    @try {
        deliver();
    } @finally {
        NSUInteger index = [stack indexOfObjectWithOptions:NSEnumerationReverse
                                               passingTest:^BOOL(NSString *entry, __unused NSUInteger idx, __unused BOOL *stop) {
            return [entry isEqualToString:user];
        }];
        if (index != NSNotFound) [stack removeObjectAtIndex:index];
        if (stack.count == 0) [NSThread.currentThread.threadDictionary removeObjectForKey:kApolloSubscriptionRefreshFailingKey];
    }
}

ApolloSubscriptionListDecision ApolloSubscriptionRefreshDecideList(NSString *username, NSArray *current, NSArray *incoming) {
    NSString *user = username.lowercaseString;
    if (user.length == 0) return ApolloSubscriptionListDecisionApply;
    if (![ApolloSubscriptionRefreshFailingOnThisThread(NO) containsObject:user]) return ApolloSubscriptionListDecisionApply;
    if (![current isKindOfClass:[NSArray class]] || current.count == 0) return ApolloSubscriptionListDecisionApplyNothingToKeep;
    if ([incoming isKindOfClass:[NSArray class]] && incoming.count >= current.count) return ApolloSubscriptionListDecisionApplyNotShorter;
    return ApolloSubscriptionListDecisionKeep;
}
