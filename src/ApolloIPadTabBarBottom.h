#import <UIKit/UIKit.h>

// Full-screen pages (Pal Home) that hide the iPad tab bar while visible.
// iPad's top tabs ignore hidesBottomBarWhenPushed, and the tab placement
// hook re-syncs visibility on every layout, so hiding goes through here:
// while suppressed, both the native bar and the bottom-tabs bar stay hidden.
UIKIT_EXTERN void ApolloIPadSetTabBarSuppressed(UITabBarController *tabs, BOOL suppressed);
