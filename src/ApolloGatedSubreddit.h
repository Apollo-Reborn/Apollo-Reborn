#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Reddit puts a warning in front of some communities (r/Drugs: "Content
// Advisory: This community may contain discussions and content pertaining to
// drug use and abuse…") and serves the community to an account only once that
// account has accepted it. Until then every read of the subreddit answers HTTP
// 403 with
//
//   {"reason": "gated", "interstitial_warning_message": "…", "error": 403}
//
// RedditKit's +[RDKClient errorFromResponseObject:] knows the reasons
// "private", "banned" and "quarantined" and nothing else, so a gated subreddit
// reached Apollo as a plain HTTP 403 and its feed as a failed load ("Couldn't
// load posts. Pull down to try again."), with no way to get past it in the app.
//
// This is the Foundation-only half of showing that warning and accepting it
// (tests/run_gated_subreddit_tests.sh): reading the answer, and building the
// request Reddit's own warning page sends when its "continue" button is
// pressed. The page is old.reddit.com/gated?dest=<the subreddit>, a form with
// the hidden fields uh, sr_name and dest and the buttons accept=no and
// accept=yes, posted back to its own address (2026-11-26). The request is
// built from the page as it is served rather than from a stored modhash, so it
// carries whatever that form carries. ApolloListEmptyState.xm has the rest.

// The userInfo key of a gated answer's NSError: Reddit's warning (NSString).
extern NSString *const ApolloGatedSubredditWarningKey;

// Reddit's warning for a response object that says its subreddit is gated, or
// nil for any other object. Never empty: a gated answer without text gets a
// line that says what it is.
NSString *_Nullable ApolloGatedWarningFromResponseObject(id _Nullable responseObject);

// `error` (the one RedditKit made for the answer, or nil when it made none)
// with the warning in its userInfo; its domain and code are kept.
NSError *ApolloGatedErrorWithWarning(NSError *_Nullable error, NSString *warning);

// The one subreddit a listing path reads ("r/Drugs/best.json" is "Drugs"), or
// nil for anything else: Home, a "+" list, a profile, a multireddit.
NSString *_Nullable ApolloGatedSubredditFromListingPath(NSString *_Nullable path);

// The address of Reddit's warning page for a subreddit, or nil for a name that
// isn't one.
NSURL *_Nullable ApolloGatedPageURL(NSString *subreddit);

// The request the page's "continue" button sends: a POST of the form's hidden
// fields and accept=yes to the form's address, as a browser would send it.
// nil when `pageHTML` isn't that form for `subreddit` (a sign-in page, a
// subreddit that isn't gated for the account, a page Reddit has changed), or
// when the form posts anywhere but the host the page came from. The caller
// adds the account's cookie.
NSURLRequest *_Nullable ApolloGatedAcceptRequest(NSData *_Nullable pageHTML, NSURL *pageURL, NSString *subreddit);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
