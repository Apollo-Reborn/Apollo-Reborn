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

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
