#import <UIKit/UIKit.h>

#import "settings/ApolloSettingsForm.h"

NS_ASSUME_NONNULL_BEGIN

// Settings → Apollo Reborn → Accounts & API Keys → Routes (route
// keyless-route-status). For the active API-key-free account since launch:
// which route each read with fallbacks takes and how every route has answered,
// and the paths Reddit blocks that have no other route. Also holds the Use
// Route Updates switch (ApolloWebJSONRouteUpdates.h) with its last result. Copy
// Summary puts the status on the pasteboard as plain text for a bug report;
// nothing is sent anywhere.
@interface ApolloKeylessRouteStatusViewController : ApolloSettingsFormViewController
@end

NS_ASSUME_NONNULL_END
