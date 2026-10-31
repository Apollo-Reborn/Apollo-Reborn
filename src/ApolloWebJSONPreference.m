#import "ApolloWebJSONPreference.h"

BOOL ApolloWebJSONLaunchShouldEnable(BOOL storedEnabled,
                                     BOOL hasStoredPrimarySession,
                                     BOOL explicitlyDisabled) {
    if (storedEnabled) return YES;
    return hasStoredPrimarySession && !explicitlyDisabled;
}
