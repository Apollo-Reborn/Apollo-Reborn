#import <UIKit/UIKit.h>

__BEGIN_DECLS

BOOL ApolloSubredditListIsEditing(UINavigationController *controller);

// Presentation-only companion to the bottom bar's existing scroll policy.
// The caller supplies bottom-bar state; this module owns no gesture or timer.
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
