#import <Foundation/Foundation.h>

// Re-applies the profile-picture tab icon after a custom tab-bar presentation
// releases UIKit's native item views. The refresh is coalesced and includes
// delayed passes for UIKit's asynchronous floating-tab reconstruction.
FOUNDATION_EXPORT void ApolloRefreshProfileTabAvatarAfterPresentation(void);
