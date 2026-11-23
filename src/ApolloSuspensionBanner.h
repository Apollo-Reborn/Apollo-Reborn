#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The red bar Reddit's website shows a suspended account ("This account has 7
// days left on its ban"), as a drop-down banner over the top of the app. Shown
// for the ACTIVE account while ApolloAccountIsSuspended says so: when the
// suspension is first learned, on launch, and on switching to that account (at
// most once every six hours each), and once when Reddit's limit on the
// suspended account starts. One limit is announced once: it lasts up to ten
// minutes, and every refused request and every return to the app during it
// used to bring the banner down again (ApolloSuspensionBannerIsDue has the
// rules). While something is presented over the app's screens it waits for
// that to close. It leaves on its own, on a swipe up, or on a tap, which opens
// the Inbox where Reddit's message about it is.

#ifdef __cplusplus
extern "C" {
#endif

// Registers the observers (suspension changes, app becoming active, account
// switches). Call once, from %ctor.
void ApolloSuspensionBannerInstall(void);

// Reddit is refusing the active API-Key-Free account's requests
// (ApolloWebJSONOptionalReadBackoff). When that account is suspended this shows
// the banner with the wait in it and returns YES, and the caller skips its own
// rate-limit notice: Reddit gives a suspended account a far smaller budget, so
// the suspension is the reason. NO (and nothing shown) for any other account.
// YES doesn't mean a banner went up: a limit it has already announced isn't
// announced again. `backAfterAway` is NO when the limit has just started and
// YES when the user has come back to the app after a while away and it still
// holds, which is worth one reminder. Main thread.
BOOL ApolloSuspensionBannerShowForRateLimit(BOOL backAfterAway);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
