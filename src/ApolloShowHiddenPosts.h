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

// A copy of `parameters` with show=all, so the listing keeps hidden posts.
NSDictionary *ApolloShowHiddenListingParameters(NSDictionary *_Nullable parameters);

// Choices made in a subreddit's ••• menu, keyed by lowercased subreddit name.
// A choice lasts until the app quits and wins over a saved one. With
// `remember` it is also saved in `defaults`, and applies after a restart while
// `useSaved` is set. A choice stays until the choices are cleared, also when
// it equals the setting. Any thread.
NSNumber *_Nullable ApolloShowHiddenChoiceForSubreddit(NSString *subreddit, BOOL useSaved, NSUserDefaults *defaults);
void ApolloShowHiddenSetChoiceForSubreddit(NSString *subreddit, BOOL show, BOOL remember, NSUserDefaults *defaults);
// Saves this launch's choices, for when remembering is turned on.
void ApolloShowHiddenSaveSessionChoices(NSUserDefaults *defaults);
NSUInteger ApolloShowHiddenSavedChoiceCount(NSUserDefaults *defaults);
// Removes this launch's choices and the saved ones.
void ApolloShowHiddenClearChoices(NSUserDefaults *defaults);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
