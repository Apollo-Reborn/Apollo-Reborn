#import <Foundation/Foundation.h>

#import "ApolloGoogleSearch.h"

// Kagi search restricted to Reddit, for the Search tab's "Kagi" mode.
//
// Kagi has no free API, but every subscriber has a Session Link
// (kagi.com → Settings → Account → Session Link,
// "https://kagi.com/search?token=…") that signs a browser in without a
// password. Its token is the `kagi_session` cookie, so one plain GET of Kagi's
// server-rendered results page (https://kagi.com/html/search) with that cookie
// returns the subscriber's own results: the same approach kagi-cli
// (github.com/Microck/kagi-cli) uses. No web view, no JavaScript, no per-search
// API cost; each page counts as one search on the subscriber's plan.
//
// Unlike Google, Kagi links every result straight to its reddit.com URL, so
// the whole page is enriched from Reddit (one batched /api/info.json read)
// before it is delivered: the cards show Reddit's score, comment count and age
// right away.
//
// The token lives in the Keychain (service com.christianselig.Apollo.kagi),
// never in NSUserDefaults or the logs. Backup Settings carries it along with
// Apollo's own Keychain items.

NS_ASSUME_NONNULL_BEGIN

// Posted (main queue) whenever the saved Session Link is set or removed.
FOUNDATION_EXPORT NSString *const ApolloKagiSessionTokenDidChangeNotification;

// Keychain identity of the saved token, for the backup allowlist.
FOUNDATION_EXPORT NSString *const ApolloKagiSessionKeychainService;
FOUNDATION_EXPORT NSString *const ApolloKagiSessionKeychainAccount;

FOUNDATION_EXPORT NSString *_Nullable ApolloKagiSessionToken(void);
FOUNDATION_EXPORT BOOL ApolloKagiHasSessionToken(void);
// Saves `token` (already normalized, see ApolloKagiNormalizeSessionToken), or
// removes the saved one when nil/empty. NO when the Keychain refused the write.
FOUNDATION_EXPORT BOOL ApolloKagiSetSessionToken(NSString *_Nullable token);

typedef NS_ENUM(NSInteger, ApolloKagiSessionCheck) {
    ApolloKagiSessionCheckValid = 0,
    ApolloKagiSessionCheckRejected,      // Kagi sent it to sign-in
    ApolloKagiSessionCheckUnreachable,   // network error, Kagi down, ...
};

// Asks Kagi whether `token` signs in, with one request to an account page (not
// a search, so it costs nothing on metered plans). Completion on main.
FOUNDATION_EXPORT void ApolloKagiCheckSessionToken(NSString *token,
                                                   void (^completion)(ApolloKagiSessionCheck result, NSError *_Nullable error));

@interface ApolloKagiSearchSession : NSObject <ApolloExternalSearchSession>
@end

#if APOLLO_SIM_BUILD
// Simulator debug bridge ("ksearch [p=N t=d|w|m|y x=1 |] <query>"): run a Kagi
// search with the saved Session Link and log every result.
FOUNDATION_EXPORT void ApolloKagiSearchDebugRun(NSString *query);
// "ksearchdebug fixture=<path>|off expired=0|1|welcome fail info=0|1 token=<link>|off":
// feed a saved results page to the parser instead of the network, fake a
// rejected session, fail the next search, skip the Reddit read, or seed/remove
// the Session Link without the sheet.
FOUNDATION_EXPORT void ApolloKagiSearchDebugConfigure(NSString *arguments);
#endif

NS_ASSUME_NONNULL_END
