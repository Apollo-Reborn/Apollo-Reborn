#import <Foundation/Foundation.h>

// Keeps an account's subscription list when a refresh of it fails (#1635, #1409).
//
// Apollo re-fetches every signed-in account's subscriptions on a 55-minute timer
// (-[AccountManager refreshSubscriptionTimerTickedWithTimer:] 0x10082ba24, 3300 s,
// rescheduled on every tick, walks each account in FUN_10083d094). Its completion
// (FUN_10083d2ec) never looks at the error: RedditKit's page walker (FUN_1001ed81c)
// answers a failed page with (the pages it already had, error), and the closure
// stores those pages in RDKUser.subscribedSubreddits and posts
// SubscribedSubredditsUpdatedForAccount anyway. So a first page that fails (no
// network yet, a timeout, a 5xx, a refusal) leaves the account with no
// subscriptions, and the subreddit list (which reloads from that property on the
// notification) shows only Home, Popular and All until a pull to refresh. The
// emptied list is also what gets saved with the account, so the next launch
// starts without it too. A timer that came due while the app was suspended fires
// as soon as it resumes, often before the network is back, which is when people
// find the list blank. A page that fails later in the walk cuts the list short
// the same way (#1409: 1,935 subscriptions became 947).
//
// The RDKClient -taskWithMethod: hook (ApolloWebJSONIdentity.xm) hands a failed
// page of a subscriptions walk to its completion inside
// ApolloSubscriptionRefreshDeliverFailedPage, and the RDKUser
// -setSubscribedSubreddits: hook asks ApolloSubscriptionRefreshDecideList. RedditKit's
// listing block, the page walker and AccountManager's closure all run synchronously
// from that completion, on the thread that delivers it, so the scope is that
// thread's for exactly that long. It covers the list the failed walk produces and
// never another write: not a later one (an unsubscribe right after), and not one
// made on another thread while the delivery runs, even for the same account. The other two
// subscription walks (the subreddit list's own and AccountManager's launch walk,
// FUN_10063b94c and FUN_100839a70) already skip the store on an error; for them
// the scope never sees a setter call.
//
// Foundation-only, so it compiles straight into the host-side test
// (tests/run_subscription_refresh_guard_tests.sh).

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, ApolloSubscriptionListDecision) {
    // No failed refresh page is being delivered for this account: store the list.
    ApolloSubscriptionListDecisionApply = 0,
    // The failed refresh's list is shorter than the one the account has: keep the old one.
    ApolloSubscriptionListDecisionKeep,
    // A failed refresh, but the account has no list yet, so there's nothing to keep.
    ApolloSubscriptionListDecisionApplyNothingToKeep,
    // A failed refresh, but its list isn't shorter than the current one.
    ApolloSubscriptionListDecisionApplyNotShorter,
};

// Runs `deliver` (the failed page's completion) with `username`'s subscription
// refresh marked as failing on the calling thread only. Usernames compare
// case-insensitively. An empty username runs `deliver` unmarked. Safe to nest;
// the mark is removed even if `deliver` throws.
void ApolloSubscriptionRefreshDeliverFailedPage(NSString *_Nullable username, void (NS_NOESCAPE ^deliver)(void));

// What -[RDKUser setSubscribedSubreddits:] should do with `incoming` for the
// account `username`, whose list is `current`. Only a failed delivery running on
// the calling thread counts. Safe from any thread.
ApolloSubscriptionListDecision ApolloSubscriptionRefreshDecideList(NSString *_Nullable username,
                                                                   NSArray *_Nullable current,
                                                                   NSArray *_Nullable incoming);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
