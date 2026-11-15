#import "ApolloSubredditName.h"

BOOL ApolloSubredditNameIsSpecialFeed(NSString *lowercaseName) {
    // Special feeds that aren't really single subreddits. "random"/"randnsfw"
    // are the titles Apollo gives a random feed until its listing names the
    // subreddit it landed on.
    static NSSet<NSString *> *blocked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blocked = [NSSet setWithObjects:@"home", @"popular", @"all", @"search", @"profile",
                                        @"settings", @"inbox", @"friends", @"mod",
                                        @"random", @"randnsfw", nil];
    });
    return lowercaseName && [blocked containsObject:lowercaseName];
}

NSString *ApolloNormalizedSubredditName(NSString *subredditName) {
    if (![subredditName isKindOfClass:[NSString class]]) return nil;
    // Built once: the random feed normalizes every entry of a list of
    // thousands, so per-call character-set construction dominated.
    static NSCharacterSet *whitespace;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        // Must look like a subreddit slug: letters/digits/underscores.
        invalid = [[NSCharacterSet characterSetWithCharactersInString:
                    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    });
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:whitespace];
    if ([clean hasPrefix:@"/r/"] || [clean hasPrefix:@"/R/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"] || [clean hasPrefix:@"R/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    if ([clean rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    // After the character check: only ASCII is left, so lowercasing is exact.
    if (ApolloSubredditNameIsSpecialFeed(clean.lowercaseString)) return nil;
    return clean;
}
