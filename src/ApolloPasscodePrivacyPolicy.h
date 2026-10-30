#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

/// Mirrors Apollo's native foreground lock decision. Authentication delay is
/// stored in whole minutes and compared against system uptime; a missing
/// background timestamp means cold launch and therefore requires authentication.
BOOL ApolloPasscodePrivacyCoverRequired(BOOL lockEnabled,
                                        NSInteger authenticationDelayMinutes,
                                        BOOL hasLastUnlockedBackgroundTime,
                                        NSTimeInterval lastUnlockedBackgroundTime,
                                        NSTimeInterval currentTime);

/// Apollo's immediate policy also needs an opaque task-switcher snapshot. A
/// positive delay does not lock merely because the app entered background.
BOOL ApolloPasscodePrivacyBackgroundCoverRequired(BOOL lockEnabled,
                                                  NSInteger authenticationDelayMinutes);

/// Whether Apollo's post-foreground blur state requires the preflight cover to
/// remain. A missing private blur fails closed when native locking is enabled.
BOOL ApolloPasscodePrivacyNativeGateRequiresCover(BOOL lockEnabled,
                                                  BOOL blurExists,
                                                  double alpha);

/// Only a visible, direct window child can provide usable native unlock
/// controls above the cover. Other locked states use the modal-cover fallback.
BOOL ApolloPasscodePrivacyNativeGateIsUsable(BOOL directWindowChild,
                                             BOOL hidden,
                                             double alpha);

__END_DECLS
NS_ASSUME_NONNULL_END
