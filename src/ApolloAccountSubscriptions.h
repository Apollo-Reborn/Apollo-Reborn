#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Apollo's own "subscriptions changed" broadcast. Its native Subscribe and
// Unsubscribe (the posts screen's ⋯ menu) add or remove the subreddit's name
// on the active account's RDKUser.subscribedSubreddits and then post this,
// with the user's id (RDKUser.identifier, no "t2_" prefix; an empty string when
// the account has none) as the object.
// PostsViewController (the menu's Subscribe/Unsubscribe row) and
// RedditListViewController (the Subscriptions list) both observe it.
extern NSString *const ApolloSubscribedSubredditsUpdatedNotification;

// Whether the active account's subscription list includes the subreddit.
// Returns NO (unknown) when there is no signed-in account or its list has not
// loaded; otherwise YES, with *outSubscribed set.
BOOL ApolloAccountSubscriptionListState(NSString *subredditName, BOOL *outSubscribed);

// Mirrors a subscribe/unsubscribe that already succeeded on Reddit into
// Apollo's local state, the same two steps its native Subscribe/Unsubscribe
// take: add (or remove) the name on the active account's list, then post
// ApolloSubscribedSubredditsUpdatedNotification. Pass the display name
// ("AskReddit"); the list stores names as Reddit spells them. No-op when the
// list already agrees or has not loaded. Main thread.
void ApolloAccountApplySubscriptionChange(NSString *subredditName, BOOL subscribed);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
