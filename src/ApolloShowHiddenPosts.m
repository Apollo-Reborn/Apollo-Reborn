#import "ApolloShowHiddenPosts.h"

NSString *ApolloShowHiddenSubredditForListingPath(NSString *path) {
    NSString *trimmed = [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSMutableArray<NSString *> *parts = [[trimmed componentsSeparatedByString:@"/"] mutableCopy];
    if (parts.count < 2 || parts.count > 3 || ![parts[0] isEqualToString:@"r"] || [parts containsObject:@""]) return nil;

    // The extension sits on the last component: "r/name.json" or "r/name/hot.json".
    NSString *last = parts.lastObject;
    if (last.pathExtension.length > 0) {
        if (![last.pathExtension isEqualToString:@"json"]) return nil;
        parts[parts.count - 1] = last.stringByDeletingPathExtension;
    }

    if (parts.count == 3) {
        static NSString *const sorts[] = { @"hot", @"new", @"rising", @"top", @"controversial", @"best", @"gilded" };
        NSString *sort = parts[2].lowercaseString;
        BOOL known = NO;
        for (size_t i = 0; i < sizeof(sorts) / sizeof(sorts[0]) && !known; i++) known = [sort isEqualToString:sorts[i]];
        if (!known) return nil;
    }

    NSString *name = parts[1].lowercaseString;
    if (name.length == 0 || [name containsString:@"+"]) return nil;
    // Feeds that span many communities; "all-a-b" is r/all with subreddits
    // filtered out. A Random feed moves to a new community on every refresh.
    if ([name isEqualToString:@"all"] || [name hasPrefix:@"all-"] || [name isEqualToString:@"popular"] ||
        [name isEqualToString:@"mod"] || [name isEqualToString:@"friends"] ||
        [name isEqualToString:@"random"] || [name isEqualToString:@"randnsfw"]) {
        return nil;
    }
    return name;
}

NSDictionary *ApolloShowHiddenListingParameters(NSDictionary *parameters) {
    NSMutableDictionary *result = [parameters isKindOfClass:[NSDictionary class]] ? [parameters mutableCopy] : [NSMutableDictionary dictionary];
    result[@"show"] = @"all";
    return result;
}
