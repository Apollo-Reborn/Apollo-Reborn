#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Apollo-Reborn's own account switcher: lists every signed-in account with a
// per-account API-key status badge, and lets the user edit/clear each
// account's Reddit OAuth credentials (see ApolloAccountCredentials.{h,m}).
//
// Visually this fully replaces Apollo's native AccountManagerViewController,
// but every actual switch/add/delete is performed by driving a real, live
// instance of that native class through its existing ObjC-visible selectors
// (verified via Hopper decompilation of -[AccountManagerViewController
// tableView:didSelectRowAtIndexPath:] / -addBarButtonItemTapped: /
// -tableView:commitEditingStyle:forRowAtIndexPath:) — so account persistence,
// keychain writes, and OAuth add-account flows are still 100% Apollo's own
// code, not a reimplementation.
@interface ApolloAccountSwitcherViewController : UITableViewController

// Whether the custom switcher should be presented in place of Apollo's
// native AccountManagerViewController. Backed by UDKeyUseCustomAccountSwitcher
// (default YES) — flip to NO via defaults as an emergency fallback to the
// stock switcher if a future Apollo build changes the native ObjC selector
// surface this file drives (see ApolloAccountSwitcherViewController.xm).
+ (BOOL)isAvailable;

@end

#ifdef __cplusplus
extern "C" {
#endif

// Opens Apollo's Accounts screen (and this switcher over it) from any tab, via
// the Account tab's own accounts bar button. NO when that tab isn't loaded yet.
// sourceWindow picks the scene; nil falls back to the key window. Defined in
// ApolloLiquidGlass.xm beside the tab long-press opener, which shares its lookup.
BOOL ApolloOpenAccountManager(UIWindow *_Nullable sourceWindow);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
