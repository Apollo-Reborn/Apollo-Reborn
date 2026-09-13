#import <UIKit/UIKit.h>

// Reveal scroll-hidden bottom chrome when a status-bar jump reaches the top.
void ApolloTabBarRevealAfterScrollToTop(UITabBarController *controller);

// Cancel a pending reveal retry when the user leaves or resumes scrolling.
void ApolloTabBarCancelScrollToTopReveal(UITabBarController *controller);
