#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// The bare subreddit slug in `subredditName`: whitespace trimmed and a leading
// "r/" or "/r/" removed. Nil for anything that is not one real community: an
// empty string, a name with characters outside [A-Za-z0-9_], and Apollo's
// special feeds (home, popular, all, mod, random, randnsfw, ...).
// Foundation-only so host-side test harnesses can compile it.
NSString *ApolloNormalizedSubredditName(NSString *subredditName);

// YES for one of the special feed names ApolloNormalizedSubredditName rejects
// (home, popular, all, random, ...). `lowercaseName` must already be lowercase.
BOOL ApolloSubredditNameIsSpecialFeed(NSString *lowercaseName);

#ifdef __cplusplus
}
#endif
