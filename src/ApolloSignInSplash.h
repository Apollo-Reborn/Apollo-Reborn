#import <Foundation/Foundation.h>

__BEGIN_DECLS
// Starts Apollo's real OAuth account-add flow using its existing Profile VC.
// AuthenticationServices/ApolloWebAuth presents over the current interface.
// Call on main after collecting API credentials. NO if Apollo isn't ready.
BOOL ApolloStartAPIKeySignIn(void);
__END_DECLS
