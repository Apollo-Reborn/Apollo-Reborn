#import "ApolloDuoSearchRecents.h"

NSString *const ApolloDuoSearchRecentsDidChangeNotification = @"ApolloDuoSearchRecentsDidChangeNotification";

static NSMutableArray<NSString *> *sApolloDuoSearchRecents;
static const NSUInteger kApolloDuoSearchRecentsLimit = 6;

static void ApolloDuoSearchPrepareRecents(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sApolloDuoSearchRecents = [NSMutableArray array];
        // Apollo uses both names for native account changes. Deliver on main
        // so snapshots, visits, and clearing all share one ordering.
        for (NSString *name in @[@"com.christianselig.RedditCurrentAccountChanged",
                                  @"com.christianselig.RedditAccountChanged"]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                    if (sApolloDuoSearchRecents.count == 0) return;
                    [sApolloDuoSearchRecents removeAllObjects];
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:ApolloDuoSearchRecentsDidChangeNotification object:nil];
                }];
        }
    });
}

NSArray<NSString *> *ApolloDuoSearchRecentSubreddits(void) {
    if (!NSThread.isMainThread) return @[];
    ApolloDuoSearchPrepareRecents();
    return [sApolloDuoSearchRecents copy];
}

void ApolloDuoSearchRecordVisit(NSString *subredditName) {
    if (!NSThread.isMainThread || ![subredditName isKindOfClass:NSString.class]) return;
    ApolloDuoSearchPrepareRecents();

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

    NSUInteger previous = [sApolloDuoSearchRecents indexOfObjectPassingTest:
        ^BOOL(NSString *candidate, __unused NSUInteger index, __unused BOOL *stop) {
            return [candidate caseInsensitiveCompare:name] == NSOrderedSame;
        }];
    if (previous == 0) return;
    if (previous != NSNotFound) [sApolloDuoSearchRecents removeObjectAtIndex:previous];
    [sApolloDuoSearchRecents insertObject:[name copy] atIndex:0];
    if (sApolloDuoSearchRecents.count > kApolloDuoSearchRecentsLimit)
        [sApolloDuoSearchRecents removeLastObject];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloDuoSearchRecentsDidChangeNotification object:nil];
}
