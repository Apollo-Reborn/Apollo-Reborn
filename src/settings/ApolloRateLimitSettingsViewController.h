#import <UIKit/UIKit.h>

#import "settings/ApolloSettingsForm.h"

NS_ASSUME_NONNULL_BEGIN

// Settings → Apollo Reborn → Accounts & API Keys → Rate Limit (route
// rate-limit). Everything about Reddit's request budget for API-Key-Free
// accounts in one place: the Reduce Rate Limiting switch with its Pause Extras
// At slider (ApolloReduceRateLimiting.h), and the Rate Limit Warnings and Rate
// Limit Meter switches (ApolloRateLimitMeter.h).
@interface ApolloRateLimitSettingsViewController : ApolloSettingsFormViewController
@end

NS_ASSUME_NONNULL_END
