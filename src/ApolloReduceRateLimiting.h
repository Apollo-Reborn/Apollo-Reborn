#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Reduce Rate Limiting (Settings → Apollo Reborn → Experimental, key
// UDKeyReduceRateLimiting).
//
// An API-key-free account reads Reddit through its web session cookie on
// www.reddit.com/....json, and Reddit gives that a far smaller request budget
// than an API key: it counts per ten-minute window, never says how much is
// left, and answers HTTP 429 to everything (Apollo's own feed included) once
// it's spent (see ApolloWebJSONOptionalReadBackoff). While such an account is
// active, this mode trades a little polish for fewer requests:
//   • profile pictures come only from batched lookups (ApolloUserAvatars.xm):
//     feed authors are batched too and nobody is looked up one at a time, so
//     they show without collectible frames;
//   • Community Highlights refresh every 30 minutes instead of every 2
//     (ApolloSubredditHighlights.xm); pull-to-refresh still refreshes;
//   • the session check runs every 10 minutes instead of every minute
//     (ApolloWebJSONCheckAccountSession).
// Off by default. Offered once: at the first API-key-free sign-in, or at the
// first rate limit for an account that signed in before the offer existed.

// Posted on the main thread whenever the setting is turned on or off, so a
// Settings screen that's already showing the switch can catch up.
extern NSNotificationName const ApolloReduceRateLimitingDidChangeNotification;

// YES while the setting is on AND the active account is API-key-free.
// Defaults-backed, cheap; any thread.
BOOL ApolloReduceRateLimitingActive(void);

// Turns the setting on or off (persisted) and records the offer as answered.
void ApolloReduceRateLimitingSetEnabled(BOOL enabled);

// Sign-in offer. When it hasn't been made yet and the setting is off, presents
// the one-time alert on `presenter` and calls `then` once it's answered;
// otherwise calls `then` straight away. A `presenter` that's already presenting
// (a Google/Apple sign-in popup: close it first with ApolloWebAuthClosePopups)
// counts as busy, and the offer waits for the first rate limit. Main thread.
void ApolloReduceRateLimitingOfferAtSignIn(UIViewController *presenter, void (^then)(void));

// Rate-limit offer for an API-key-free account that never saw the sign-in one:
// presents it on the visible screen in place of the "Reddit Rate Limit
// Reached" toast (with the wait in its message) and returns YES. Returns NO
// when the caller should show the toast as usual. Main thread.
BOOL ApolloReduceRateLimitingOfferAtRateLimit(NSTimeInterval seconds);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
