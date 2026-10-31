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
/// The thread the last close (the button, a Back, the drag) took from beside
/// the Posts feed `nav`, while it can still come back: the feed page it was
/// closed from is on top, no thread is open, the split still pairs columns and
/// nothing has forgotten it (another thread, a feed change, a memory warning,
/// a long stay in the background). Restore reopens it beside the feed, with
/// any pages pushed over it, through the normal open.
BOOL ApolloDuoSplitCanRestoreClosedThread(UINavigationController *nav);
BOOL ApolloDuoSplitRestoreClosedThread(UINavigationController *nav);
/// The closed thread brought back with the finger, by the feed's forward
/// swipe: the snapshot of its pane taken as it closed slides in from the
/// screen's edge. Begin returns NO without a snapshot that fits (the swipe
/// then restores on release). Update moves it by the drag's translation and
/// returns NO once the drag was let go. Progress is the drag over the thread
/// pane's width, signed like the translation. Finish brings the thread back
/// or springs it out again, still remembered; Cancel removes the drag at once
/// (with a nil navigation, whichever drag is active).
BOOL ApolloDuoSplitInteractiveRestoreBegin(UINavigationController *nav);
BOOL ApolloDuoSplitInteractiveRestoreUpdate(UINavigationController *nav, CGFloat translation);
CGFloat ApolloDuoSplitInteractiveRestoreProgress(UINavigationController *nav, CGFloat translation);
void ApolloDuoSplitInteractiveRestoreFinish(UINavigationController *nav, BOOL commit, CGFloat velocity);
void ApolloDuoSplitInteractiveRestoreCancel(UINavigationController *nav, BOOL animated);
BOOL ApolloDuoSplitShowSidebar(UINavigationController *navigation);
/// The Posts split is moving a navigation between its columns. That takes the
/// navigation out of the window and back in within one turn; its title keeps
/// its presentation and capsule through it.
BOOL ApolloDuoSplitIsMovingColumns(void);
/// A subreddit opened from Search hides the search column; a Back swipe at
/// that subreddit's root brings it back.
BOOL ApolloDuoSplitCanRevealSearchColumnWithSwipe(UINavigationController *navigation);
BOOL ApolloDuoSplitRevealSearchColumn(UINavigationController *navigation);
/// A left swipe on the open Posts list, or on the search column shown beside
/// a subreddit, closes it. A tap on that subreddit closes the search column.
BOOL ApolloDuoSplitCanHideSidebarWithSwipe(UINavigationController *navigation);
BOOL ApolloDuoSplitCanHideSearchColumnWithTap(UINavigationController *navigation);
/// The Posts tab's subreddit list drawer.
BOOL ApolloDuoSplitIsPostsListNavigation(UINavigationController *navigation);
BOOL ApolloDuoSplitHideSidebar(UINavigationController *navigation);
__END_DECLS

void ApolloDuoSplitPrepareOverlaySurface(UIView *surface);

BOOL ApolloDuoSplitSuppressesFeedActions(UIViewController *controller);

UIColor *ApolloDuoSplitOverlayBackground(UIView *view, UIColor *color);
