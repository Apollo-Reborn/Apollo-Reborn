#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// The lowercased subreddit name when `path` is one subreddit's post listing
// ("r/<name>" or "r/<name>/<sort>", with or without a leading "/" and ".json"),
// else nil. Home, Popular, All, Mod, Friends, Random, "a+b" lists,
// multireddits, search and comment pages all return nil.
NSString *_Nullable ApolloShowHiddenSubredditForListingPath(NSString *_Nullable path);

// A copy of `parameters` with show=all, which makes Reddit keep the posts the
// account has hidden in a listing.
NSDictionary *ApolloShowHiddenListingParameters(NSDictionary *_Nullable parameters);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
