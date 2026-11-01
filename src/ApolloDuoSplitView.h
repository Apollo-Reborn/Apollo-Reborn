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
/// Appearance only; both styles remain overlays for geometry and navigation.
BOOL ApolloDuoSplitIsGlassSubredditOverlayView(UIView *view);
BOOL ApolloDuoSplitIsSidebarController(UIViewController *controller);
BOOL ApolloDuoSplitRevealPostsList(UINavigationController *navigation);
/// Excludes containment controllers, the open drawer, and adapting columns.
BOOL ApolloDuoSplitAllowsNavigationSwipe(UINavigationController *navigation);
/// Only the Posts feed root can open its closed drawer with an edge swipe.
BOOL ApolloDuoSplitCanRevealPostsListWithSwipe(UINavigationController *navigation);
/// Closes the Posts subreddit drawer when it is open; NO when it was not.
BOOL ApolloDuoSplitDismissPostsList(UINavigationController *navigation);
/// Returns from a visited profile dashboard to its retained Posts Back stack.
BOOL ApolloDuoSplitCanReturnFromVisitedProfile(UINavigationController *navigation);
BOOL ApolloDuoSplitReturnFromVisitedProfile(UINavigationController *navigation);
/// The thread the last close (the button or a Back) took from beside the Posts
/// feed `nav`, while it can still come back: the feed page it was closed from
/// is on top and shows the same feed for the same account, no thread is open,
/// the split still pairs columns and nothing has forgotten it (another thread,
/// a feed change, an account switch, scrolling on when Forget Forward Swipe
/// After Scrolling is on, a memory warning, a long stay in the background).
/// Restore reopens it beside the feed, with any pages pushed over it, through
/// the normal open.
BOOL ApolloDuoSplitCanRestoreClosedThread(UINavigationController *nav);
BOOL ApolloDuoSplitRestoreClosedThread(UINavigationController *nav);
/// For ApolloForwardSwipeExpiry: the feed's closed thread counted as a forward
/// page (a token for it, nil without one) and its forget.
id ApolloDuoSplitClosedThreadToken(UINavigationController *nav);
void ApolloDuoSplitForgetClosedThreadAfterScrolling(UINavigationController *nav);
BOOL ApolloDuoSplitShowSidebar(UINavigationController *navigation);
__END_DECLS

void ApolloDuoSplitPrepareOverlaySurface(UIView *surface);

BOOL ApolloDuoSplitSuppressesFeedActions(UIViewController *controller);

UIColor *ApolloDuoSplitOverlayBackground(UIView *view, UIColor *color);
