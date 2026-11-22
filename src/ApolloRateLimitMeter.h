#import <Foundation/Foundation.h>

// Rate Limit Warnings and the Rate Limit Meter: two optional ways to watch
// Reddit's request budget for the API-Key-Free account in use (100 requests per
// ten-minute window; ApolloWebJSONBudget.h keeps the count Reddit reports).
//
//   • Warnings (UDKeyRateLimitWarnings): a notice when the count reaches 50, 75
//     and 90 percent, and when Reduce Rate Limiting's Pause Extras At stop is
//     reached. Each once per window. Running out altogether is still the
//     existing "Reddit Rate Limit Reached" notice.
//   • Meter (UDKeyRateLimitMeter): a small gauge floating over the app with the
//     live count, green through to red. It can be dragged anywhere and stays
//     where it's dropped; a tap shows the time left for a few seconds.
//
// Both are off by default, independent of each other and of Reduce Rate
// Limiting, and do nothing while the account in use signs in with an API key.
// Neither sends a request: they only read what Reddit's answers already said.

#ifdef __cplusplus
extern "C" {
#endif

// Starts following the count. Once, from %ctor; any thread.
void ApolloRateLimitMeterInstall(void);

// After sRateLimitWarnings, sRateLimitMeter or API-Key-Free Mode changes: shows
// or removes the meter to match. Main thread.
void ApolloRateLimitMeterSettingsChanged(void);

#ifdef __cplusplus
}
#endif
