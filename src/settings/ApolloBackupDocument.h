#import <UIKit/UIKit.h>

__BEGIN_DECLS
// Shared by the restore picker, local backup list, and Files document handoff.
// Never restores until the user chooses Restore; the engine still validates all data.
void ApolloBackupPresentRestoreConfirmation(UIViewController *presenter, NSURL *url,
                                           void (^completion)(void));
// Claims only local .apollobackup URLs. Keep all other URLs on their native path.
BOOL ApolloBackupDocumentHandleURL(NSURL *url);
__END_DECLS
