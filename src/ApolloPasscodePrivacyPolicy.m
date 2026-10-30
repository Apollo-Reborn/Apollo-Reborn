#import "ApolloPasscodePrivacyPolicy.h"

BOOL ApolloPasscodePrivacyCoverRequired(BOOL lockEnabled,
                                        NSInteger authenticationDelayMinutes,
                                        BOOL hasLastUnlockedBackgroundTime,
                                        NSTimeInterval lastUnlockedBackgroundTime,
                                        NSTimeInterval currentTime) {
    if (!lockEnabled) return NO;
    if (authenticationDelayMinutes <= 0 || !hasLastUnlockedBackgroundTime) return YES;

    NSTimeInterval elapsed = currentTime - lastUnlockedBackgroundTime;
    NSTimeInterval required = (NSTimeInterval)authenticationDelayMinutes * 60.0;
    return elapsed >= required;
}

BOOL ApolloPasscodePrivacyBackgroundCoverRequired(BOOL lockEnabled,
                                                  NSInteger authenticationDelayMinutes) {
    return lockEnabled && authenticationDelayMinutes <= 0;
}

BOOL ApolloPasscodePrivacyNativeGateRequiresCover(BOOL lockEnabled,
                                                  BOOL blurExists,
                                                  double alpha) {
    return lockEnabled && (!blurExists || alpha > 0.0);
}

BOOL ApolloPasscodePrivacyNativeGateIsUsable(BOOL directWindowChild,
                                             BOOL hidden,
                                             double alpha) {
    return directWindowChild && !hidden && alpha > 0.0;
}
