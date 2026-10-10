#import <UIKit/UIKit.h>

__BEGIN_DECLS

// Reveal scroll-hidden bottom chrome when a status-bar jump reaches the top.
void ApolloTabBarRevealAfterScrollToTop(UITabBarController *controller);

// Cancel a pending reveal retry when the user leaves or resumes scrolling.
void ApolloTabBarCancelScrollToTopReveal(UITabBarController *controller);

// Reconcile native bottom-bar policy once after the Duo bar changes placement.
void ApolloScheduleDuoBarPolicyUpdate(UITabBarController *controller);

__END_DECLS
