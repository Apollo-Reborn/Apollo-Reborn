#import <UIKit/UIKit.h>

// Prepare only the standard own-profile sheet currently being built by Apollo.
// Returns NO to stop presentation if that sheet could not be configured safely.
BOOL ApolloProfileMoreMenuPreparePresentation(UIViewController *presenter, UIViewController *controller);
