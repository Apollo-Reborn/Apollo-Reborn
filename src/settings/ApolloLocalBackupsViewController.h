#import "settings/ApolloSettingsForm.h"

// Lists Apollo-owned backup archives and exposes explicit restore, export, and
// delete actions. Files access is requested only for a user-initiated export.
@interface ApolloLocalBackupsViewController : ApolloSettingsFormViewController
@end
