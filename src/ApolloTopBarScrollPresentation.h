#import <UIKit/UIKit.h>

__BEGIN_DECLS

BOOL ApolloSubredditListIsEditing(UINavigationController *controller);

// Duo's native header policy is independent of the bottom-bar preference.
// Pass the destination navigation controller before pushing/installing a
// controller; nil uses its current navigation controller. Safe to reapply.
void ApolloTopBarApplyNativeScrollPolicy(UIViewController *controller,
    UINavigationController *navigationController);

// Presentation-only companion to the bottom bar's existing scroll policy.
// The caller supplies bottom-bar state; Duo ignores it in favor of its native
// header policy. This module owns no gesture or timer.
void ApolloTopBarSetScrollHidden(UITabBarController *controller, BOOL hidden,
    BOOL animated, NSString *reason);
// A status-bar jump temporarily keeps its return control visible until the
// next real drag, return action, or navigation away. Does not alter settings.
void ApolloTopBarSetScrollToTopActive(UINavigationController *controller, BOOL active);
// Animate a scroll-hidden header back without first removing its presentation.
void ApolloTopBarRevealNavigationController(UINavigationController *controller, NSString *reason);
void ApolloTopBarRestoreNavigationController(UINavigationController *controller);
void ApolloTopBarRevalidateNavigationController(UINavigationController *controller);
void ApolloTopBarRevalidateHeaderView(UIView *view);

__END_DECLS
