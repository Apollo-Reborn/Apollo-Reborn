#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ApolloBackupActionHandler)(NSURL *backupURL);

// Expanded controls for one archive. Callbacks are retained until reuse; the
// presenting controller should capture itself weakly in these blocks.
@interface ApolloBackupActionsCell : UITableViewCell

- (void)configureWithBackupURL:(NSURL *)backupURL
                restoreAction:(nullable ApolloBackupActionHandler)restoreAction
                 exportAction:(nullable ApolloBackupActionHandler)exportAction
                 deleteAction:(nullable ApolloBackupActionHandler)deleteAction;

@end

NS_ASSUME_NONNULL_END
