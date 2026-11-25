#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Reddit's site-wide account suspension ("Your account has been temporarily
// banned"), per signed-in account.
//
// Reddit's website shows a suspended account a red bar on every page. Apollo
// shows nothing: reads keep working, a comment or post comes back as a bare
// HTTP 403 ("Authentication Error"), and an API-Key-Free account gets a much
// smaller request budget from Reddit while it lasts (measured 2026-11-22 on two
// suspended accounts: 100 units per ten minutes at 4 units a request, where the
// same session was unmetered before), which shows up as "Reddit Rate Limit
// Reached" a minute after opening the app. None of that says why.
//
// Reddit reports the suspension on the account's own user object:
//   is_suspended                true / false
//   suspension_expiration_utc   epoch seconds, or null when it has no end date
// That object comes back from GET api/v1/me (API-key accounts), from
// api/me.json (the API-Key-Free session check) and from the account's own
// user/<name>/about, all of which Apollo or the tweak already request. This
// module only reads those answers; it never sends a request of its own.
//
// Foundation-only, so the .m compiles straight into a host-side test
// (tests/run_account_suspension_tests.sh). Thread-safe.

#ifdef __cplusplus
extern "C" {
#endif

// Posted on the main queue when an account's suspension starts, ends or gets a
// different end date. userInfo: @"username" (lowercased).
extern NSString *const ApolloAccountSuspensionDidChangeNotification;

// Reads a response RedditKit just delivered. `clientUsername` is the account
// the request was sent for (nil when its client hasn't loaded its user yet);
// `path` is RedditKit's relative path ("api/v1/me", "user/name/about.json").
// Only the three account-object reads above are looked at, and only when the
// object describes that same account: another user's about.json also carries
// is_suspended, and says nothing about ours. Returns YES when stored state
// changed.
BOOL ApolloAccountSuspensionNoteResponse(NSString *_Nullable clientUsername, NSString *_Nullable method,
                                         NSString *_Nullable path, id _Nullable responseObject);

// Reads Reddit's own description of `username` (the "data" of api/me.json or
// about.json, or the whole api/v1/me object). An object with no is_suspended
// boolean changes nothing: an answer that doesn't say is not an answer of
// "not suspended". Returns YES when stored state changed.
BOOL ApolloAccountSuspensionNoteUserData(NSString *username, NSDictionary *_Nullable userData);

// Whether Reddit last reported `username` suspended and that suspension hasn't
// run out since. An end date in the past ends it without another answer.
BOOL ApolloAccountIsSuspended(NSString *_Nullable username);

// When the suspension ends, or nil when the account isn't suspended or Reddit
// gave no end date.
NSDate *_Nullable ApolloAccountSuspensionEnd(NSString *_Nullable username);

// "7 days left", "1 day left", "5 hours left", "Less than an hour left"; nil
// when the account isn't suspended or Reddit gave no end date. Rounded up, the
// way Reddit's own bar counts ("7 days left" for 6 days 23 hours).
NSString *_Nullable ApolloAccountSuspensionTimeLeftText(NSString *_Nullable username);

// Drops what's stored for accounts that aren't in `usernames` any more (the
// signed-in accounts), so a removed account leaves nothing behind.
void ApolloAccountSuspensionKeepOnly(NSSet<NSString *> *usernames);

// Why the banner (ApolloSuspensionBanner.h) is being asked for.
typedef NS_ENUM(NSInteger, ApolloSuspensionBannerOccasion) {
    // Launch, a return to the app, an account switch: nothing just happened.
    ApolloSuspensionBannerOccasionUnprompted = 0,
    // Reddit has just started refusing the account's requests.
    ApolloSuspensionBannerOccasionLimitStarted,
    // Back in the app after a while away, and Reddit is still refusing them.
    ApolloSuspensionBannerOccasionBackDuringLimit,
};

// An unprompted banner is kept to once per account in this long.
extern const NSTimeInterval ApolloSuspensionBannerQuietPeriod;
// A reminder on coming back during a limit isn't repeated within this long.
extern const NSTimeInterval ApolloSuspensionBannerReminderGap;

// Whether one account's banner is due. Every time is in seconds on one clock;
// 0 means "never": `lastShownAt` is when its banner last went up,
// `limitEndsAt` when Reddit's limit on it resets (0 or a past time: it isn't
// limited), and `announcedLimitEndsAt` the reset time of the limit its banner
// last named.
//   Unprompted          once per ApolloSuspensionBannerQuietPeriod.
//   LimitStarted        once per limit: a limit whose banner has already been
//                       up isn't announced again while it lasts, however often
//                       a request is refused or the app comes forward.
//   BackDuringLimit     only while the limit lasts, and not within
//                       ApolloSuspensionBannerReminderGap of the last banner.
BOOL ApolloSuspensionBannerIsDue(ApolloSuspensionBannerOccasion occasion, NSTimeInterval now, NSTimeInterval lastShownAt,
                                 NSTimeInterval limitEndsAt, NSTimeInterval announcedLimitEndsAt);

// Tests only: a fixed clock (epoch seconds; 0 restores the real one), and a
// reload of the stored state.
void ApolloAccountSuspensionSetNowForTesting(NSTimeInterval now);
void ApolloAccountSuspensionReloadForTesting(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
