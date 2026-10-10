#import "settings/ApolloSettingsForm.h"

NS_ASSUME_NONNULL_BEGIN

// An existing user opening this route starts with Keep My Settings selected.
@interface ApolloSetupAssistantViewController : ApolloSettingsFormViewController
- (instancetype)init;
@end

__BEGIN_DECLS
void ApolloSetupAssistantStart(void);
// Suppresses competing automatic launch UI and the first usage heartbeat while
// first-run setup is pending, or while a manually opened assistant is on screen.
BOOL ApolloSetupAssistantBlocksLaunchPrompts(void);
__END_DECLS

NS_ASSUME_NONNULL_END
