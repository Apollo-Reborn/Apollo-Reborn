#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// "Edit Profile" in the own-profile "..." menu (ApolloProfileMoreMenu.xm).
// Pushes Reddit's web profile editor (www.reddit.com/settings/profile) onto
// `viewController`'s navigation stack, signed in as the active account through
// the Reddit web session the tweak already stores for it. Where the in-app page
// can't work (iOS 14/15 WebKit, no navigation stack, no active account) the
// URL goes to the system as before.
void ApolloProfileEditorOpenFromViewController(UIViewController *viewController);

#if APOLLO_SIM_BUILD
// Simulator debug bridge ("profilejs <js>"): evaluate JS in the open editor's
// web view and log the result.
void ApolloProfileEditorDebugEvaluateJS(NSString *js);
#endif

__END_DECLS

NS_ASSUME_NONNULL_END
