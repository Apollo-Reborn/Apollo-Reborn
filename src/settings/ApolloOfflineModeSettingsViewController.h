#import "ApolloSettingsTableViewController.h"

/// "Offline Mode" sub-screen (Apollo Reborn settings → Features). Chooses when
/// the saved batch is used (Automatic / Always / Never), what the next
/// download fetches (feeds, comments, images, data limit), and starts, cancels
/// or deletes the download. Runtime lives in ApolloOfflineMode.xm.
@interface ApolloOfflineModeSettingsViewController : ApolloSettingsTableViewController
@end
