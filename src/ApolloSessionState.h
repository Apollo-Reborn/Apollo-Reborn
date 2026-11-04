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
FOUNDATION_EXPORT NSString *const ApolloSessionStateDetailContextualKey;
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

// Only the feed represented by the saved route may receive pre-fetch sort
// state; startup and secondary-pane listings must retain their own ordering.
FOUNDATION_EXPORT BOOL
ApolloSessionStateFeedURLMatchesSavedRoute(NSString * _Nullable candidateURL,
                                           NSString * _Nullable savedURL);

// Popular and All are saved as r/popular and r/all routes, but restoring them
// must reopen Apollo's built-in feed rather than a subreddit page of that name.
// Returns the feed shortcut index (1 Popular, 2 All) or NSNotFound.
FOUNDATION_EXPORT NSUInteger ApolloSessionStateBuiltInFeedIndex(NSString * _Nullable savedURL);

// Account-ready notifications expose the coherent live selection before the
// defaults mirror necessarily catches up. Lifecycle-only callbacks retain the
// persisted identity as their primary signal.
FOUNDATION_EXPORT NSString * _Nullable
ApolloSessionStatePreferredAccountScope(NSString * _Nullable persistedScope,
                                        NSString * _Nullable liveScope,
                                        BOOL preferLiveScope);

// Turns a post route into Apollo's canonical contextual-comment route. The
// comment ID may be a bare base36 value or a t1_ fullname. Invalid IDs leave
// the original route unchanged.
FOUNDATION_EXPORT NSString * _Nullable
ApolloSessionStateDetailURLByAddingCommentID(NSString * _Nullable detailURL,
                                             NSString * _Nullable commentID);

// Converts Apollo's canonical contextual route back to a full-post route with
// a harmless title placeholder. Apollo's legacy parser requires that segment
// to avoid treating the route as contextual.
FOUNDATION_EXPORT NSString * _Nullable
ApolloSessionStateDetailURLByRemovingCommentID(NSString * _Nullable detailURL);

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

// Sort restoration is post-scoped even when the saved route also contains a
// contextual comment anchor.
FOUNDATION_EXPORT BOOL
ApolloSessionStateDetailPostIdentifierMatchesSavedRoute(NSString * _Nullable postID,
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
                                                                   BOOL inNavigationStack,
                                                                   BOOL underRestoredDetail,
                                                                   BOOL applicationActive);

// Leaving the navigation stack cancels either phase. A detail controller also
// cancels when another controller replaces it on top; temporary invisibility
// while it remains topmost is a pause, not a cancellation.
FOUNDATION_EXPORT BOOL
ApolloSessionStateViewportRestoreWasCancelled(BOOL detail,
                                              BOOL visible,
                                              BOOL top,
                                              BOOL inNavigationStack,
                                              BOOL underRestoredDetail,
                                              BOOL applicationActive);

// A pan-began notification is durable evidence of reader intent even when the
// gesture finishes between bounded restore polls. Only the active unfinished
// restore phase owned by that controller should react to it.
FOUNDATION_EXPORT BOOL
ApolloSessionStateShouldCancelForReaderScroll(BOOL hasPendingRestore,
                                              BOOL controllerOwnsRestore,
                                              BOOL phaseStarted,
                                              BOOL phaseFinished,
                                              BOOL panBegan);

// Feed and detail phases finish independently while sharing one pending
// snapshot. A delayed retry must stop when its own phase is terminal even if
// the other phase keeps the shared restore alive.
FOUNDATION_EXPORT BOOL
ApolloSessionStateQueuedPhaseWorkShouldRun(BOOL hasPendingRestore,
                                           BOOL generationMatches,
                                           BOOL phaseFinished);

// The route deadline only handles a post controller that never appeared. Once
// it has appeared, temporary background detachment must leave its anchor phase
// available to resume on the next foreground appearance.
FOUNDATION_EXPORT BOOL
ApolloSessionStateDetailRouteDeadlineShouldFinish(BOOL detailControllerSeen,
                                                  BOOL detailFinished);

// A sort-triggered reload normally replaces or clears the old rows before
// viewport identity is read. observedContentChange remembers a transient empty
// state; reloadWaitExpired permits a nonempty identical result only after the
// bounded reload wait, because two sorts can legitimately return the same page.
FOUNDATION_EXPORT BOOL
ApolloSessionStateSortedFeedReloadHasProducedRows(NSString * _Nullable initialFingerprint,
                                                  NSString * _Nullable currentFingerprint,
                                                  BOOL observedContentChange,
                                                  BOOL reloadWaitExpired);

// A rejected/missing post invalidates the detail portion of the snapshot, but
// the only on-disk recovery point remains necessary until feed restoration has
// also reached a terminal state.
FOUNDATION_EXPORT BOOL
ApolloSessionStateShouldDeleteSnapshotAfterDetailFailure(BOOL feedFinished,
                                                         BOOL detailFinished);

// A user-driven feed replacement also suppresses a detail route that has not
// started. An already-started or already-finished detail phase remains
// independent and reaches its own terminal state.
FOUNDATION_EXPORT BOOL
ApolloSessionStateShouldCancelUnstartedDetail(BOOL detailRouteOpened,
                                              BOOL detailFinished);

// A detail controller that appeared and was then popped is terminal even when
// its delayed anchor retry has not fired yet.
FOUNDATION_EXPORT BOOL
ApolloSessionStateShouldFinishAbandonedDetail(BOOL detailRouteOpened,
                                              BOOL detailControllerSeen,
                                              BOOL detailFinished,
                                              BOOL restoredDetailOnTop);

// Once restoration is active, an account-ready notification is a cancellation
// boundary when its coherent live scope differs from the saved snapshot.
// Unknown live identity waits for a later notification rather than guessing.
FOUNDATION_EXPORT BOOL
ApolloSessionStateShouldCancelForAccountChange(BOOL hasPendingRestore,
                                               NSString * _Nullable savedScope,
                                               NSString * _Nullable liveScope);

// A stale persisted mismatch may be reconsidered exactly by an account-ready
// callback using live identity; ordinary lifecycle callbacks remain one-shot.
FOUNDATION_EXPORT BOOL
ApolloSessionStateAccountReadyMayRetry(BOOL initialRestoreConsidered,
                                       BOOL accountReadyRetryPending,
                                       BOOL preferLiveScope);

// Background persistence uses navigation topology rather than window
// visibility: UIKit may detach every window after the user has already changed
// tabs or pushed another controller.
FOUNDATION_EXPORT BOOL
ApolloSessionStateFeedOwnsSelectedNavigation(BOOL feedNavigationSelected,
                                             BOOL topIsFeed,
                                             BOOL topIsRestoredDetail);

// While restoration is pending, only controllers belonging to the originating
// UIWindowScene may consume it. Ordinary capture remains scene-agnostic.
FOUNDATION_EXPORT BOOL
ApolloSessionStateControllerSceneOwnsRestore(BOOL hasPendingRestore,
                                             BOOL restoreSceneAvailable,
                                             BOOL controllerSceneMatches);

// Page restoration is monotonic and requests each observed page at most once.
FOUNDATION_EXPORT BOOL ApolloSessionStateShouldRequestNextFeedPage(NSInteger savedPage,
                                                                  NSInteger currentPage,
                                                                  NSInteger lastRequestedPage);

// Reddit's morechildren payload uses bare comment IDs while viewport anchors
// use t1_ fullnames. This identifies the one load-more row that can reveal the
// saved anchor without expanding unrelated branches.
FOUNDATION_EXPORT BOOL
ApolloSessionStateMoreCommentsChildrenContainIdentifier(NSArray * _Nullable children,
                                                         NSString * _Nullable identifier);

NS_ASSUME_NONNULL_END
