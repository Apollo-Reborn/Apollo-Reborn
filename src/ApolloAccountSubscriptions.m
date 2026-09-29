#import "ApolloAccountSubscriptions.h"
#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import <objc/message.h>

NSString *const ApolloSubscribedSubredditsUpdatedNotification =
    @"com.christianselig.SubscribedSubredditsUpdatedForAccount";

// "r/AskReddit", "/r/AskReddit/", " AskReddit " -> "AskReddit"; nil for
// anything unusable. Case is kept: the list stores names as Reddit spells them.
static NSString *ApolloAccountSubscriptionsDisplayName(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *name = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([name hasPrefix:@"/"]) name = [name substringFromIndex:1];
    if ([name.lowercaseString hasPrefix:@"r/"]) name = [name substringFromIndex:2];
    while ([name hasSuffix:@"/"]) name = [name substringToIndex:name.length - 1];
    return name.length > 0 ? name : nil;
}

static id ApolloAccountSubscriptionsUser(id client) {
    if (![client respondsToSelector:@selector(currentUser)]) return nil;
    id user = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
    if (![user respondsToSelector:@selector(subscribedSubreddits)] ||
        ![user respondsToSelector:@selector(setSubscribedSubreddits:)]) {
        return nil;
    }
    return user;
}

// Apollo keeps plain name strings here (profiles as "u/<name>"), and bridges
// the array to a Swift [String] in its observers: anything else in it is a
// crash in Apollo's own code, so this module only ever stores strings.
static NSArray *ApolloAccountSubscriptionsList(id user) {
    id list = user ? ((id (*)(id, SEL))objc_msgSend)(user, @selector(subscribedSubreddits)) : nil;
    return [list isKindOfClass:[NSArray class]] ? list : nil;
}

static NSIndexSet *ApolloAccountSubscriptionsIndexes(NSArray *list, NSString *displayName) {
    return [list indexesOfObjectsPassingTest:^BOOL(id entry, __unused NSUInteger idx, __unused BOOL *stop) {
        NSString *entryName = ApolloAccountSubscriptionsDisplayName(entry);
        return entryName && [entryName caseInsensitiveCompare:displayName] == NSOrderedSame;
    }];
}

BOOL ApolloAccountSubscriptionListState(NSString *subredditName, BOOL *outSubscribed) {
    NSString *name = ApolloAccountSubscriptionsDisplayName(subredditName);
    if (!name) return NO;
    NSArray *list = ApolloAccountSubscriptionsList(ApolloAccountSubscriptionsUser(ApolloActiveAccountClient()));
    if (!list) return NO;
    if (outSubscribed) *outSubscribed = ApolloAccountSubscriptionsIndexes(list, name).count > 0;
    return YES;
}

void ApolloAccountApplySubscriptionChange(NSString *subredditName, BOOL subscribed) {
    NSString *name = ApolloAccountSubscriptionsDisplayName(subredditName);
    id user = ApolloAccountSubscriptionsUser(ApolloActiveAccountClient());
    NSArray *list = ApolloAccountSubscriptionsList(user);
    if (!name || !list) return;

    NSIndexSet *matches = ApolloAccountSubscriptionsIndexes(list, name);
    NSMutableArray *updated = [list mutableCopy];
    if (subscribed) {
        if (matches.count > 0) return;
        [updated addObject:name];
    } else {
        if (matches.count == 0) return;
        [updated removeObjectsAtIndexes:matches];
    }
    // Same two steps as Apollo's native completion handlers: set the new list,
    // then announce it with the user's id as the object. Apollo passes an
    // empty string for an account without one (API-Key-Free sessions), never
    // nil, so do the same for any observer that casts it to a String.
    ((void (*)(id, SEL, id))objc_msgSend)(user, @selector(setSubscribedSubreddits:), [updated copy]);
    id identifier = [user respondsToSelector:@selector(identifier)]
        ? ((id (*)(id, SEL))objc_msgSend)(user, @selector(identifier)) : nil;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloSubscribedSubredditsUpdatedNotification
                      object:[identifier isKindOfClass:[NSString class]] ? identifier : @""];
    ApolloLog(@"[AccountSubscriptions] %@ r/%@ %@ Apollo's subscription list (%lu -> %lu)",
              subscribed ? @"added" : @"removed", name, subscribed ? @"to" : @"from",
              (unsigned long)list.count, (unsigned long)updated.count);
}
