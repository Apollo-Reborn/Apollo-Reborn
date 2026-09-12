#import <UIKit/UIKit.h>

__BEGIN_DECLS

// Presentation-only companion to the bottom bar's existing scroll policy.
// The caller supplies bottom-bar state; this module owns no gesture or timer.
void ApolloTopBarSetScrollHidden(UITabBarController *controller, BOOL hidden,
    BOOL animated, NSString *reason);
void ApolloTopBarRestoreNavigationController(UINavigationController *controller);
void ApolloTopBarRevalidateNavigationController(UINavigationController *controller);
void ApolloTopBarRevalidateHeaderView(UIView *view);

__END_DECLS
