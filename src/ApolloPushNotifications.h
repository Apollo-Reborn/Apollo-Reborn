#import <Foundation/Foundation.h>

@class UIView;

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Sideload push-notification support
//
// APNs delivery requires the `aps-environment` entitlement, which Apple only
// grants to a paid Apple Developer team and bakes in at signing time. A build
// sideloaded with a free Apple ID never carries it, so push notifications,
// watchers, and inbox alerts can never be delivered to that build — no runtime
// trick can change that.
//
// When the user opens Apollo's Notifications settings, Apollo registers for
// remote notifications; on a free-account sideload iOS answers
// -application:didFailToRegisterForRemoteNotificationsWithError: with the
// permanent NSCocoaErrorDomain 3000 ("no valid 'aps-environment' entitlement
// string found for application"), which Apollo resurfaces as an alarming
// "Error Loading Notifications — contact developer" alert.
//
// By default the tweak detects this signing-time limitation up front,
// replaces the Notifications screen with a clear explanation, and suppresses
// the misleading error — faking a working registration with no delivery path
// would only mislead users. The one exception is Bark mode (see
// ApolloBarkNotifications.h): when the user has configured delivery through
// the Bark app, a synthetic registration is genuinely backed by a working
// delivery path, so the failed registration is answered with a synthetic
// token instead and the stock Notifications screen is left alone.

// YES when the running build carries an `aps-environment` entitlement, i.e. push
// registration can actually succeed (an App Store build, or a sideload signed
// with a paid Apple Developer account). NO on a free-account sideload, where
// push can never be delivered. Determined from the process's own code-signing
// entitlements, so it is accurate before any registration is attempted. When the
// entitlement state can't be read it conservatively returns YES, leaving the
// stock behavior untouched.
BOOL ApolloPushNotificationsSupported(void);

// YES when the `aps-environment` entitlement value is "development" (a paid
// *developer*-profile sideload, whose tokens belong to Apple's sandbox APNs
// gateway); NO for "production" or when the entitlement is absent/unreadable.
// Used to report a truthful sandbox flag when the tweak registers a device
// row itself (the backend's APPLE_APNS_SANDBOX can still override it).
BOOL ApolloAPSEnvironmentIsDevelopment(void);

// YES only when `error` is the missing-`aps-environment`-entitlement failure
// described above. This is a signing-time condition that can never be resolved
// at runtime, so it is treated as an expected sideload state rather than a bug.
// Returns NO for genuine/transient failures (offline, rate limiting, …) so they
// still surface to the user. Safe to call with nil.
BOOL ApolloErrorIsMissingPushEntitlement(NSError *error);

// Why Apollo's Notifications settings can't work on this install.
typedef NS_ENUM(NSInteger, ApolloNotificationsUnavailableReason) {
    // Free-account sideload: no `aps-environment` entitlement, so APNs can
    // never deliver (Bark is the only route).
    ApolloNotificationsUnavailableReasonNoPushEntitlement,
    // Push-capable signing, but no self-hosted notification backend is set.
    // The legacy push hosts are gone, so every request the screen waits on
    // would otherwise go nowhere (issue #828: endless spinner).
    ApolloNotificationsUnavailableReasonNoBackend,
};

// Builds the opaque, non-interactive informational view shown in place of
// Apollo's Notifications settings when notifications can't work (see
// ApolloNotificationsUnavailableReason). It explains why and swallows touches
// so the disabled controls underneath can't be tapped. Pinning it into the
// view hierarchy is the caller's responsibility.
UIView *ApolloMakeNotificationsUnavailableView(ApolloNotificationsUnavailableReason reason);

#ifdef __cplusplus
}
#endif
