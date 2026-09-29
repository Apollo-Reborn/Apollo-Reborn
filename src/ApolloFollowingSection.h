// ApolloFollowingSection — public surface of the Subreddits-list remap module
// (the FOLLOWING section + configurable section order). See the .xm header
// comment for the full design.

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// Section order tokens persisted in UDKeySubredditSectionOrder.
FOUNDATION_EXPORT NSString *const ApolloSubredditSectionTokenFavorites;
FOUNDATION_EXPORT NSString *const ApolloSubredditSectionTokenMultireddits;
FOUNDATION_EXPORT NSString *const ApolloSubredditSectionTokenModerator;
FOUNDATION_EXPORT NSString *const ApolloSubredditSectionTokenFollowing;

// The canonical order (favorites, multireddits, moderator, following).
NSArray<NSString *> *ApolloSubredditSectionsDefaultOrder(void);

// The stored order sanitized to a complete, duplicate-free token list.
NSArray<NSString *> *ApolloSubredditSectionsResolvedOrder(void);

// Display name for a token ("Favorites", "Multireddits", …).
NSString *ApolloSubredditSectionDisplayName(NSString *token);

// Animate the next confirmed removal. Complex model changes use a full reload.
void ApolloFollowingAnimateNextRemoval(UITableView *tableView, NSIndexPath *visiblePath);

// Remap-awareness bridge for the other subreddit-list modules
// (ApolloHideModSubreddits / ApolloMultiredditEdit): those modules identify a
// row's section by reading the on-screen header title for indexPath.section.
// While this module's remap is engaged, the index paths that reach them have
// already been translated into Apollo's NATIVE section space, where the
// special sections sit at fixed indices — so the header walk (which speaks the
// VISIBLE layout) would lie. Returns nil when the remap is not engaged for
// this table (caller should fall back to its own walk); otherwise the
// canonical uppercase title for the native special sections ("FAVORITES" /
// "MULTIREDDITS" / "MODERATOR") or @"" for any other native section.
NSString *ApolloFollowingCanonicalTitleForNativeSection(UITableView *tableView, NSInteger nativeSection);

// Visible-space twin of the bridge above, for code that walks the table itself
// (-visibleCells / -indexPathForCell:) and so holds VISIBLE section numbers that
// never passed through this module's translating hooks. Returns nil when the
// remap is not engaged (the caller's header walk already speaks visible space);
// otherwise the canonical title of the section on screen: "FAVORITES" /
// "MULTIREDDITS" / "MODERATOR" / "FOLLOWING", or @"" for any other section.
NSString *ApolloFollowingCanonicalTitleForVisibleSection(UITableView *tableView, NSInteger visibleSection);

// YES while the list is in a row's swipe-to-delete rather than Edit mode. A
// swipe makes UIKit report -isEditing for the whole table (only the swiped row
// is set up for editing), and Apollo's tableView:willBeginEditingRowAtIndexPath:
// calls the list's setEditing:YES animated:YES, so Edit-mode decorations (the
// moderator hide controls, the feed-shortcut remove badges) must check this
// before showing. Already YES inside that setEditing: call; NO again once
// didEndEditingRowAtIndexPath: has run.
BOOL ApolloSubredditListIsSwipeEditing(UITableView *tableView);

// Section-header half of the list's snapshot-then-animate updates (the Edit
// toggle, the confirmed removal), in three steps. `offsetDelta` is always the
// table's contentOffset change since the snapshot. See the .xm for why headers
// need all three.
//  1. Before the update: snapshot the on-screen header frames, keyed by title.
//  2. Right after the update: park each header visually at its old place (and
//     hide newly visible ones) without touching the view itself.
//  3. Immediately before -startAnimation: hand the offset to the animator —
//     each header gets the transform/alpha the animator returns to its
//     original, recorded in `restores`. Pass nil `restores` when the animator
//     will not start (superseded): the parking is simply dropped.
NSDictionary<NSString *, NSValue *> *ApolloSubredditListSectionHeaderFrames(UITableView *tableView);
void ApolloSubredditListParkSectionHeaders(UITableView *tableView, NSDictionary<NSString *, NSValue *> *oldFrames,
                                           CGFloat offsetDelta);
void ApolloSubredditListStartSectionHeaders(UITableView *tableView, NSDictionary<NSString *, NSValue *> *oldFrames,
                                            CGFloat offsetDelta, NSMutableArray<NSArray *> *restores);

// Subreddit name backing a VISIBLE row of the Subreddits list, from Apollo's
// model (FavoriteSubreddits / sectionedSubreddits). Translates through the
// Following remap when that remap is engaged. nil for rows without a
// favoritable name (feed shortcuts, multireddits, moderator) or on failure.
NSString *ApolloSubredditListNameAtIndexPath(UITableView *tableView, NSIndexPath *visiblePath);

// Native -> visible, for a module whose hook received one of this module's
// translated (NATIVE) index paths and then has to address the table itself
// (-cellForRowAtIndexPath:, -deselectRowAtIndexPath:…), which speaks the
// VISIBLE layout. Returns the path unchanged when the remap is not engaged,
// nil when the presented layout has no row for it.
NSIndexPath *ApolloFollowingVisibleIndexPathForNative(UITableView *tableView, NSIndexPath *nativePath);

#ifdef __cplusplus
}
#endif
