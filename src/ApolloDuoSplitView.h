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
/// A native pop here uncovers a real page of the same pane, not the Posts
/// backstop under a thread, an empty detail's placeholder or Account's Overview.
BOOL ApolloDuoSplitPopRevealsContent(UINavigationController *nav);
/// An unfolded split lays `nav` out (folded and portrait have none).
BOOL ApolloDuoSplitIsActive(UINavigationController *nav);
/// Back in `nav` is the Posts thread close: the thread right above its backstop.
BOOL ApolloDuoSplitBackClosesThread(UINavigationController *nav);
/// The Posts thread close that follows the finger, driven by the pane Back
/// from the thread pane. Begin covers the live
/// thread with its snapshot; NO when it can't, and the Back then acts on
/// release. Update moves the thread by the drag's translation and returns NO
/// once the drag was let go (a fold, a tab switch, a push). Finish commits
/// the close or springs the thread back; Cancel removes the drag at once
/// (with a nil navigation, whichever drag is active).
BOOL ApolloDuoSplitInteractiveCloseBegin(UINavigationController *nav);
BOOL ApolloDuoSplitInteractiveCloseUpdate(UINavigationController *nav, CGFloat translation);
void ApolloDuoSplitInteractiveCloseFinish(UINavigationController *nav, BOOL commit, CGFloat velocity);
void ApolloDuoSplitInteractiveCloseCancel(UINavigationController *nav, BOOL animated);
/// The Posts subreddit list pulled in with the finger from the feed root, by
/// the same pane Back. Begin prepares the hidden drawer; NO when it can't, and
/// the Back then acts on release. Update moves it by the drag's translation and
/// returns NO once the drag was let go. Progress is the share of the drawer
/// shown. Finish commits it shown or slides it back on the drawer's spring with
/// the release velocity; Cancel removes the drag at once (with a nil
/// navigation, whichever drag is active).
BOOL ApolloDuoSplitInteractiveDrawerBegin(UINavigationController *nav);
BOOL ApolloDuoSplitInteractiveDrawerUpdate(UINavigationController *nav, CGFloat translation);
CGFloat ApolloDuoSplitInteractiveDrawerProgress(UINavigationController *nav, CGFloat translation);
void ApolloDuoSplitInteractiveDrawerFinish(UINavigationController *nav, BOOL commit, CGFloat velocity);
void ApolloDuoSplitInteractiveDrawerCancel(UINavigationController *nav, BOOL animated);
BOOL ApolloDuoSplitShowSidebar(UINavigationController *navigation);
/// The Posts split is moving a navigation between its columns. That takes the
/// navigation out of the window and back in within one turn; its title keeps
/// its presentation and capsule through it.
BOOL ApolloDuoSplitIsMovingColumns(void);
__END_DECLS

void ApolloDuoSplitPrepareOverlaySurface(UIView *surface);

BOOL ApolloDuoSplitSuppressesFeedActions(UIViewController *controller);

UIColor *ApolloDuoSplitOverlayBackground(UIView *view, UIColor *color);
