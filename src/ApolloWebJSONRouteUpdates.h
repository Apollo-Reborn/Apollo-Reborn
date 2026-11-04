#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Use Route Updates: fetches keyless-routes.json from the repository and hands
// the validated table to ApolloWebJSONRouteSetRemoteTable (ApolloWebJSONRoutes.h),
// so maintainers can change which reddit.com routes blocked API-key-free reads
// take without a release (docs/keyless-routes.md). Only while API-Key-Free Mode
// is on and the setting (UDKeyKeylessRouteUpdates) is on: API-key users never
// fetch it. Same cadence as the update check: on foreground and every 15
// minutes while active, 5 minutes after a failure, never in the background, as
// a conditional request (ETag) that is usually answered 304.

// Applies the cached table on first call, then fetches when due. Main thread;
// called on every UIApplicationDidBecomeActiveNotification.
void ApolloWebJSONRouteUpdatesCheckIfNeeded(void);

// The settings switch. Off drops the remote table at once (built-in routes
// only) and stops fetching; on applies the cached table and checks. Main thread.
void ApolloWebJSONRouteUpdatesSetEnabled(BOOL enabled);

#pragma mark - Route Status (ApolloKeylessRouteStatusViewController, logs)

// For the active web-session account, since launch. Main thread.

// "enabled" (NSNumber), "lastChecked" ("3 min ago", "never") and "result"
// ("Unchanged", "Updated", "Couldn't connect", …) of the route updates.
NSDictionary<NSString *, id> *ApolloWebJSONRouteUpdatesStatus(void);

// One dictionary per endpoint with fallback routes: "key" ("GET /api/info"),
// "using" (the ApolloWebJSONRoute a request takes now, -1 if none), "allCooling",
// "remote" (order from keyless-routes.json) and "routes", one dictionary per
// route in order with "route", "ok", "blocked", "lastOkAt" and
// "cooldownRemaining" (see ApolloWebJSONRouteHealthSnapshot).
NSArray<NSDictionary<NSString *, id> *> *ApolloWebJSONRouteStatusEndpoints(void);

// Paths without another route that got Reddit's block page, most blocked first
// (ApolloWebJSONRouteHealthSnapshot rows).
NSArray<NSDictionary<NSString *, id> *> *ApolloWebJSONRouteStatusBlockedPaths(void);

// "Working", "Using Fallback", "Some Blocked" or "Blocked", for the settings row;
// "" with no web-session account.
NSString *ApolloWebJSONRouteStatusHeadline(void);

// The whole screen as plain text, for "Copy Summary" and the log.
NSString *ApolloWebJSONRouteStatusSummary(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
