#import "ApolloShowHiddenPosts.h"
#import "UserDefaultConstants.h"

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

// This launch's choices. Listings start on background queues, so every access
// to it, and every read-modify-write of the saved choices, holds the lock.
static NSMutableDictionary<NSString *, NSNumber *> *ApolloShowHiddenSessionChoices(void) {
    static NSMutableDictionary *choices;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ choices = [NSMutableDictionary dictionary]; });
    return choices;
}

static NSDictionary<NSString *, NSNumber *> *ApolloShowHiddenSavedChoices(NSUserDefaults *defaults) {
    NSDictionary *saved = [defaults dictionaryForKey:UDKeyShowHiddenPostsSubredditChoices];
    return [saved isKindOfClass:[NSDictionary class]] ? saved : @{};
}

NSNumber *ApolloShowHiddenChoiceForSubreddit(NSString *subreddit, BOOL useSaved, NSUserDefaults *defaults) {
    if (subreddit.length == 0) return nil;
    NSString *key = subreddit.lowercaseString;
    NSMutableDictionary *session = ApolloShowHiddenSessionChoices();
    @synchronized (session) {
        NSNumber *choice = session[key];
        if (choice) return choice;
    }
    if (!useSaved) return nil;
    id saved = ApolloShowHiddenSavedChoices(defaults)[key];
    return [saved isKindOfClass:[NSNumber class]] ? saved : nil;
}

// Caller holds the session lock.
static void ApolloShowHiddenSaveChoices(NSDictionary<NSString *, NSNumber *> *choices, NSUserDefaults *defaults) {
    NSMutableDictionary *saved = [ApolloShowHiddenSavedChoices(defaults) mutableCopy];
    [saved addEntriesFromDictionary:choices];
    [defaults setObject:saved forKey:UDKeyShowHiddenPostsSubredditChoices];
}

void ApolloShowHiddenSetChoiceForSubreddit(NSString *subreddit, BOOL show, BOOL remember, NSUserDefaults *defaults) {
    if (subreddit.length == 0) return;
    NSString *key = subreddit.lowercaseString;
    NSMutableDictionary *session = ApolloShowHiddenSessionChoices();
    @synchronized (session) {
        session[key] = @(show);
        // Without remember, a saved choice is left as it is: it doesn't apply
        // while remembering is off, and comes back if it's turned on again.
        if (remember) ApolloShowHiddenSaveChoices(@{ key: @(show) }, defaults);
    }
}

void ApolloShowHiddenSaveSessionChoices(NSUserDefaults *defaults) {
    NSMutableDictionary *session = ApolloShowHiddenSessionChoices();
    @synchronized (session) {
        if (session.count > 0) ApolloShowHiddenSaveChoices(session, defaults);
    }
}

NSUInteger ApolloShowHiddenSavedChoiceCount(NSUserDefaults *defaults) {
    return ApolloShowHiddenSavedChoices(defaults).count;
}

void ApolloShowHiddenClearChoices(NSUserDefaults *defaults) {
    NSMutableDictionary *session = ApolloShowHiddenSessionChoices();
    @synchronized (session) {
        [session removeAllObjects];
        [defaults removeObjectForKey:UDKeyShowHiddenPostsSubredditChoices];
    }
}
