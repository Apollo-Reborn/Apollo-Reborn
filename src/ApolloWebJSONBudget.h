#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Reddit's request budget for an API-Key-Free account, as its answers report it.
//
// Reddit counts an account's API-shaped requests (the .json and /api/ reads the
// API-Key-Free transport makes, cookie or web bearer, www or oauth) per
// ten-minute window: 100 a window, one per request, and four per request for an
// account Reddit has suspended. Since November 2026 every such answer says
// where the account stands:
//   x-ratelimit-used        units spent this window
//   x-ratelimit-remaining   units left
//   x-ratelimit-reset       seconds until the window ends
// (Before that it said nothing until the HTTP 429; see
// ApolloWebJSONOptionalReadBackoff.) The count is per account, shared by every
// session and device signed in to it.
//
// This keeps the latest report per account, so Reduce Rate Limiting can stop
// the tweak's optional lookups once a chosen share of the window is spent
// (ApolloWebJSONOptionalReadPause) and Settings can show the number.
//
// Foundation-only, so the .m compiles straight into a host-side test
// (tests/run_web_json_budget_tests.sh). Thread-safe.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    BOOL known;               // NO: Reddit hasn't reported on this account in the current window
    double used;              // units spent
    double limit;             // used + remaining
    NSTimeInterval resetsIn;  // seconds until the window ends
} ApolloWebJSONBudgetState;

// Reads the three headers off an answer to one of `username`'s API-shaped
// requests. An answer without all three, or with numbers that make no sense,
// changes nothing. Within a window the count only goes up, so an answer that
// arrives out of order can't lower it, and the tightest limit seen is the one
// kept, so an answer counted against one of Reddit's roomier budgets (its own
// pages' 600, an API key's 10000) can't stand in for this one. Returns YES
// when the stored report changed.
BOOL ApolloWebJSONBudgetNoteResponse(NSString *_Nullable username, NSHTTPURLResponse *_Nullable response);

// The latest report for `username`; `known` is NO once its window has ended.
ApolloWebJSONBudgetState ApolloWebJSONBudgetCurrent(NSString *_Nullable username);

// How long optional lookups should stay paused for `username`: the seconds left
// in the window when at least `pauseAtPercent` of it is spent, else 0. A percent
// of 100 or more pauses only once nothing is left; one of 0 or less never
// pauses.
NSTimeInterval ApolloWebJSONBudgetPause(NSString *_Nullable username, NSInteger pauseAtPercent);

// "34 of 100 used, resets in 6 min", or nil when nothing is known.
NSString *_Nullable ApolloWebJSONBudgetStatusText(NSString *_Nullable username);

// Tests only: a fixed clock (epoch seconds; 0 restores the real one), and a
// clean slate.
void ApolloWebJSONBudgetSetNowForTesting(NSTimeInterval now);
void ApolloWebJSONBudgetResetForTesting(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
