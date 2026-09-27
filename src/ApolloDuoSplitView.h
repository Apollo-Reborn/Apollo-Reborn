#import <UIKit/UIKit.h>
__BEGIN_DECLS
void ApolloDuoSplitScheduleUpdate(void);
BOOL ApolloDuoSplitIsResizing(void);
BOOL ApolloDuoSplitIsUnfolded(void);
BOOL ApolloDuoRequiresSubredditEnhancements(void);
BOOL ApolloDuoSplitIsUnfoldedPortrait(void);
CGFloat ApolloDuoSplitTransitionContentWidth(UIView *view, CGFloat trailingInset);
UINavigationController *ApolloDuoSplitDetailNavigation(UINavigationController *navigation);
/// The native tab root retained by Duo, including while its tab is offscreen.
/// Returns nil when the navigation controller has no Duo split state.
UIViewController *ApolloDuoSplitRootController(UINavigationController *navigation);
CGRect ApolloDuoSplitContentFrame(UIViewController *controller, UIView *coordinateView);
BOOL ApolloDuoSplitIsAccountFeedController(UIViewController *controller);
BOOL ApolloDuoSplitIsOwnAccountController(UIViewController *controller);
BOOL ApolloDuoSplitIsSubredditOverlayView(UIView *view);
BOOL ApolloDuoSplitIsSidebarController(UIViewController *controller);
BOOL ApolloDuoSplitRevealPostsList(UINavigationController *navigation);
/// Returns from a visited profile dashboard to its retained Posts Back stack.
BOOL ApolloDuoSplitReturnFromVisitedProfile(UINavigationController *navigation);
BOOL ApolloDuoSplitShowSidebar(UINavigationController *navigation);
__END_DECLS

void ApolloDuoSplitPrepareOverlaySurface(UIView *surface);

BOOL ApolloDuoSplitSuppressesFeedActions(UIViewController *controller);

UIColor *ApolloDuoSplitOverlayBackground(UIView *view, UIColor *color);
