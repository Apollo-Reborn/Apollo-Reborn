#import <UIKit/UIKit.h>

// Reveal scroll-hidden bottom chrome when a status-bar jump reaches the top.
void ApolloTabBarRevealAfterScrollToTop(UITabBarController *controller);

// Cancel a pending reveal retry when the user leaves or resumes scrolling.
void ApolloTabBarCancelScrollToTopReveal(UITabBarController *controller);

// Simulator builds expose bounded probes for the allocation-free tab-navigation
// fast paths without adding diagnostics to production scroll callbacks.
#if APOLLO_SIM_BUILD
NSString *ApolloAutoHideTabBarSimScanStatus(NSUInteger iterations);
NSString *ApolloAutoHideTabBarSimSetPolicy(BOOL enabled);
#endif
