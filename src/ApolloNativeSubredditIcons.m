#import "ApolloNativeSubredditIcons.h"

static NSString *const ApolloNativeSubredditIconDataKey = @"SubredditIconData";
static NSString *const ApolloNativeSubredditIconPendingKey = @"ApolloNativeSubredditIconPendingURLs";
static NSString *const ApolloNativeSubredditIconRefreshedAtKey = @"ApolloNativeSubredditIconRefreshedAt";
// Matches the subreddit info cache TTL; one lookup costs a request per 100 subreddits.
static NSTimeInterval const ApolloNativeSubredditIconRefreshInterval = 7.0 * 24.0 * 60.0 * 60.0;

static NSArray *ApolloNativeSubredditIconEntries(NSData *blob) {
    if (blob.length == 0) return nil;
    NSSet *classes = [NSSet setWithObjects:NSArray.class, NSString.class, NSURL.class, NSNull.class, nil];
    id root = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:blob error:NULL];
    return [root isKindOfClass:NSArray.class] ? root : nil;
}

// An entry is [name, url, ...]; anything else is passed through untouched.
static NSString *ApolloNativeSubredditIconEntryName(id entry) {
    if (![entry isKindOfClass:NSArray.class] || [entry count] < 2) return nil;
    id name = entry[0];
    if (![name isKindOfClass:NSString.class] || ![entry[1] isKindOfClass:NSURL.class]) return nil;
    return [name length] > 0 ? name : nil;
}

NSArray<NSString *> *ApolloNativeSubredditIconNames(NSData *blob) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id entry in ApolloNativeSubredditIconEntries(blob)) {
        NSString *name = ApolloNativeSubredditIconEntryName(entry);
        if (name) [names addObject:name];
    }
    return names;
}

static NSString *ApolloNativeSubredditIconURLString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *string = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURL *url = [NSURL URLWithString:string];
    return [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length > 0 ? string : nil;
}

NSDictionary<NSString *, NSString *> *ApolloNativeSubredditIconURLsFromInfoResponse(NSData *data) {
    NSMutableDictionary<NSString *, NSString *> *urls = [NSMutableDictionary dictionary];
    if (data.length == 0) return urls;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    id listing = [root isKindOfClass:NSDictionary.class] ? root[@"data"] : nil;
    id children = [listing isKindOfClass:NSDictionary.class] ? listing[@"children"] : nil;
    if (![children isKindOfClass:NSArray.class]) return urls;

    for (id child in children) {
        id fields = [child isKindOfClass:NSDictionary.class] ? child[@"data"] : nil;
        if (![fields isKindOfClass:NSDictionary.class]) continue;
        id name = fields[@"display_name"];
        if (![name isKindOfClass:NSString.class] || [name length] == 0) continue;
        // Same priority as the info cache: icon_img can keep the old artwork.
        NSString *url = ApolloNativeSubredditIconURLString(fields[@"community_icon"]) ?:
            ApolloNativeSubredditIconURLString(fields[@"icon_img"]);
        if (url) urls[[name lowercaseString]] = url;
    }
    return urls;
}

NSData *ApolloNativeSubredditIconDataApplyingURLs(NSData *blob, NSDictionary<NSString *, NSString *> *iconURLs, NSUInteger *changedCount) {
    if (changedCount) *changedCount = 0;
    NSArray *entries = ApolloNativeSubredditIconEntries(blob);
    if (!entries || iconURLs.count == 0) return nil;

    NSUInteger changed = 0;
    NSMutableArray *updated = [NSMutableArray arrayWithCapacity:entries.count];
    for (id entry in entries) {
        NSString *name = ApolloNativeSubredditIconEntryName(entry);
        NSURL *current = name ? entry[1] : nil;
        NSString *replacement = name ? iconURLs[name.lowercaseString] : nil;
        NSURL *replacementURL = replacement ? [NSURL URLWithString:replacement] : nil;
        if (!replacementURL || [replacementURL.absoluteString isEqualToString:current.absoluteString]) {
            [updated addObject:entry];
            continue;
        }
        // Keep the key color and any other fields Apollo stores after the URL.
        NSMutableArray *copy = [entry mutableCopy];
        copy[1] = replacementURL;
        [updated addObject:[copy copy]];
        changed++;
    }
    if (changed == 0) return nil;

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:updated requiringSecureCoding:YES error:NULL];
    if (data && changedCount) *changedCount = changed;
    return data;
}

BOOL ApolloNativeSubredditIconRefreshIsDue(NSUserDefaults *defaults, NSDate *now) {
    id last = [defaults objectForKey:ApolloNativeSubredditIconRefreshedAtKey];
    if (![last isKindOfClass:NSDate.class]) return YES;
    // A date in the future (clock change) also counts as due.
    NSTimeInterval age = [now timeIntervalSinceDate:last];
    return age < 0 || age >= ApolloNativeSubredditIconRefreshInterval;
}

void ApolloNativeSubredditIconRecordRefresh(NSUserDefaults *defaults, NSDictionary<NSString *, NSString *> *iconURLs, BOOL complete, NSDate *now) {
    if (iconURLs.count > 0) {
        NSMutableDictionary *pending = [NSMutableDictionary dictionary];
        id existing = [defaults objectForKey:ApolloNativeSubredditIconPendingKey];
        if ([existing isKindOfClass:NSDictionary.class]) [pending addEntriesFromDictionary:existing];
        [pending addEntriesFromDictionary:iconURLs];
        [defaults setObject:pending forKey:ApolloNativeSubredditIconPendingKey];
    }
    if (complete) [defaults setObject:now forKey:ApolloNativeSubredditIconRefreshedAtKey];
}

NSUInteger ApolloNativeSubredditIconApplyPendingRefresh(NSUserDefaults *defaults) {
    id pending = [defaults objectForKey:ApolloNativeSubredditIconPendingKey];
    if (!pending) return 0;
    [defaults removeObjectForKey:ApolloNativeSubredditIconPendingKey];
    if (![pending isKindOfClass:NSDictionary.class]) return 0;

    NSMutableDictionary<NSString *, NSString *> *iconURLs = [NSMutableDictionary dictionary];
    [(NSDictionary *)pending enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        NSString *url = ApolloNativeSubredditIconURLString(value);
        if ([key isKindOfClass:NSString.class] && url) iconURLs[[key lowercaseString]] = url;
    }];

    NSData *blob = [defaults objectForKey:ApolloNativeSubredditIconDataKey];
    if (![blob isKindOfClass:NSData.class]) return 0;
    NSUInteger changed = 0;
    NSData *updated = ApolloNativeSubredditIconDataApplyingURLs(blob, iconURLs, &changed);
    if (updated) [defaults setObject:updated forKey:ApolloNativeSubredditIconDataKey];
    return updated ? changed : 0;
}
