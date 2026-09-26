#import <Foundation/Foundation.h>

// Only known Reddit profile-banner crop URLs are candidates for the original.
// Unknown parameters may carry authorization/versioning; keep those URLs intact.
// The supplied URL must remain available as a fallback if the candidate fails.
static inline NSURL *ApolloProfileBannerOriginalCandidate(NSURL *url) {
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        ![url.host.lowercaseString isEqualToString:@"styles.redditmedia.com"] ||
        ![url.path hasPrefix:@"/t5_"] ||
        ![url.lastPathComponent hasPrefix:@"profileBanner_"]) return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components.user || components.password || components.port || !components.query.length) return url;
    NSSet *cropKeys = [NSSet setWithArray:@[@"width", @"height", @"crop", @"auto", @"format", @"s"]];
    BOOL sized = NO;
    for (NSURLQueryItem *item in components.queryItems) {
        if (![cropKeys containsObject:item.name]) return url;
        if ([item.name isEqualToString:@"width"] || [item.name isEqualToString:@"height"] ||
            [item.name isEqualToString:@"crop"]) sized = YES;
    }
    if (!sized || ![url.path containsString:@"/styles/profileBanner_"]) return url;
    components.query = nil;
    return components.URL ?: url;
}
