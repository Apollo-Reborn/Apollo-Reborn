#import "ApolloSearchRecents.h"
#import "ApolloSearchLandingPreferences.h"

NSString *const ApolloSearchRecentsDidChangeNotification = @"ApolloSearchRecentsDidChangeNotification";

static NSMutableArray<NSString *> *sApolloSearchRecents;

static void ApolloSearchPrepareRecents(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sApolloSearchRecents = [NSMutableArray array];
        // Apollo uses both names for native account changes. Deliver on main
        // so snapshots, visits, and clearing all share one ordering.
        for (NSString *name in @[@"com.christianselig.RedditCurrentAccountChanged",
                                  @"com.christianselig.RedditAccountChanged"]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                    if (sApolloSearchRecents.count == 0) return;
                    [sApolloSearchRecents removeAllObjects];
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:ApolloSearchRecentsDidChangeNotification object:nil];
                }];
        }
    });
}

NSArray<NSString *> *ApolloSearchRecentSubreddits(void) {
    if (!NSThread.isMainThread) return @[];
    ApolloSearchPrepareRecents();
    NSUInteger count = MIN(sApolloSearchRecents.count, (NSUInteger)ApolloSearchLandingRecentlyVisitedLimit());
    return [sApolloSearchRecents subarrayWithRange:NSMakeRange(0, count)];
}

void ApolloSearchRecordVisit(NSString *subredditName) {
    if (!NSThread.isMainThread || ![subredditName isKindOfClass:NSString.class]) return;
    ApolloSearchPrepareRecents();

    NSString *name = [subredditName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0) return;
    NSString *identity = name.lowercaseString;
    // The caller uses Apollo's PostsType resolver. Also reject pseudo-feeds
    // and unresolved random titles at this storage boundary.
    if ([@[@"home", @"all", @"popular", @"mod", @"friends", @"search", @"profile",
           @"settings", @"inbox", @"random", @"randnsfw"] containsObject:identity]) return;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    if ([name rangeOfCharacterFromSet:invalid].location != NSNotFound) return;

    NSUInteger previous = [sApolloSearchRecents indexOfObjectPassingTest:
        ^BOOL(NSString *candidate, __unused NSUInteger index, __unused BOOL *stop) {
            return [candidate caseInsensitiveCompare:name] == NSOrderedSame;
        }];
    if (previous == 0) return;
    if (previous != NSNotFound) [sApolloSearchRecents removeObjectAtIndex:previous];
    [sApolloSearchRecents insertObject:[name copy] atIndex:0];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloSearchRecentsDidChangeNotification object:nil];
}
