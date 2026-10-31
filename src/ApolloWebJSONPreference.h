#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Old builds could leave the master flag off even though one or more primary
// web-session accounts existed. Preserve the launch repair for that legacy
// state, but never override a deliberate "Turn Off Anyway" choice.
BOOL ApolloWebJSONLaunchShouldEnable(BOOL storedEnabled,
                                     BOOL hasStoredPrimarySession,
                                     BOOL explicitlyDisabled);

#ifdef __cplusplus
}
#endif
