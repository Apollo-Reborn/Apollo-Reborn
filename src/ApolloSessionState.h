#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedURLKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedItemKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedDeltaKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedOffsetKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedPageKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedSortKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateFeedTimeSortKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailURLKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailItemKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailDeltaKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailOffsetKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailSortKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateSavedAtKey;
FOUNDATION_EXPORT NSString *const ApolloSessionStateAccountScopeKey;

// Returns a property-list-safe, bounded session snapshot, or nil for malformed,
// unsupported, or expired data. Unknown keys are discarded so a future format
// cannot accidentally become an execution surface in an older build.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
ApolloSessionStateNormalize(NSDictionary * _Nullable candidate,
                            NSDate *now,
                            NSTimeInterval maximumAge);

// Apollo-owned destinations accepted by cold restoration. Feed and post routes
// are deliberately distinct so a modified plist cannot turn the detail phase
// into an arbitrary second navigation. The Reborn home sentinel is local; all
// Reddit destinations go through Apollo's own URL router.
FOUNDATION_EXPORT BOOL ApolloSessionStateFeedURLIsAllowed(NSString * _Nullable value);
FOUNDATION_EXPORT BOOL ApolloSessionStateDetailURLIsAllowed(NSString * _Nullable value);

// Turns a post route into Apollo's canonical contextual-comment route. The
// comment ID may be a bare base36 value or a t1_ fullname. Invalid IDs leave
// the original route unchanged.
FOUNDATION_EXPORT NSString * _Nullable
ApolloSessionStateDetailURLByAddingCommentID(NSString * _Nullable detailURL,
                                             NSString * _Nullable commentID);

// Matches the Reddit post and optional contextual comment rather than a title
// slug, which Reddit may rewrite independently of the post identity.
FOUNDATION_EXPORT BOOL
ApolloSessionStateDetailURLMatchesSavedRoute(NSString * _Nullable candidateURL,
                                             NSString * _Nullable savedURL);

// URL-routed comments controllers have no RDKLink before their first fetch.
// Match the Swift linkID/commentID ivars to the saved route at that boundary.
FOUNDATION_EXPORT BOOL
ApolloSessionStateDetailIdentifiersMatchSavedRoute(NSString * _Nullable postID,
                                                    NSString * _Nullable commentID,
                                                    NSString * _Nullable savedURL);

// A cold launch with an explicit URL, notification, activity, or quick action
// owns navigation and must not be replaced by passive reading-session restore.
FOUNDATION_EXPORT BOOL
ApolloSessionStateLaunchHasExplicitDestination(NSUInteger URLContextCount,
                                               BOOL hasNotificationResponse,
                                               NSUInteger userActivityCount,
                                               BOOL hasShortcutItem);

// Keep the last complete on-disk snapshot while either requested restore phase
// is still pending, so a quick background/eviction cannot erase its detail.
FOUNDATION_EXPORT BOOL
ApolloSessionStateShouldDeferPersistence(BOOL hasPendingRestore,
                                         BOOL feedFinished,
                                         BOOL detailFinished);

// A detail viewport is safe to mutate only while it is visible and on top.
// A feed viewport may continue restoring while a detail controller pushed
// from it is visible, provided the feed still belongs to that navigation stack.
FOUNDATION_EXPORT BOOL ApolloSessionStateViewportRestoreIsEligible(BOOL detail,
                                                                   BOOL visible,
                                                                   BOOL top,
                                                                   BOOL inNavigationStack);

// Page restoration is monotonic and requests each observed page at most once.
FOUNDATION_EXPORT BOOL ApolloSessionStateShouldRequestNextFeedPage(NSInteger savedPage,
                                                                  NSInteger currentPage,
                                                                  NSInteger lastRequestedPage);

NS_ASSUME_NONNULL_END
