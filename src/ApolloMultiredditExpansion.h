#ifndef APOLLO_MULTIREDDIT_EXPANSION_H
#define APOLLO_MULTIREDDIT_EXPANSION_H

#include "ApolloTableSnapshot.h"

// Included only by ApolloFollowingSection.xm, which already owns this list's
// coordinate translation and UITableView hooks. UITableView and Foundation
// must be declared by the caller (host tests provide a small table double).
//
// Native Apollo stores expansion by account + case-insensitive multi.name,
// not by path. Its data source expands EVERY matching model, while the tap
// handler inserts/deletes children for only the tapped model. For two equal
// names with 2 and 3 children, the count changes 2 -> 7 but it inserts only 2.
// UIKit rejects the batch at endUpdates. Other stale table snapshots can fail
// the same way. Let Apollo update its state and chevron, but defer that one
// table's synchronous row batch and rebuild from the resulting model once.
// The favorite star's batch reuses the same deferral when the table's cached
// counts are already stale (see the note above ApolloPerformBatchAsReload).
//
// ANIMATION (added for the multireddit expand/collapse animation): the
// deferral above is still the safe default, and it is still what runs
// whenever the gate below cannot prove the batch consistent. When the gate
// passes, ApolloPerformMultiredditExpansionAnimated runs the same native
// handler WITHOUT a deferral scope, so its beginUpdates / insertRows /
// deleteRows / endUpdates batch reaches UIKit and animates; the table hooks
// in ApolloFollowingSection.xm force that batch's row animation to Fade and
// translate its paths through the Following map exactly as they do for the
// favorite star and the animated unsubscribe. A reloadData that arrives
// inside an animated scope is still deferred and reconciled once at the end
// of the scope, and the scope re-checks the snapshot after the batch: if the
// counts no longer match the model, it reloads once instead of leaving a
// half-presented list on screen.
//
// Phase 1 RE notes (source-only; no Hopper and no running app were
// available when this was written, so anything marked UNVERIFIED is a
// reading of the tweak's own comments and hooks, not a fact about Apollo):
// - Native handler shape: ApolloFollowingSection.xm's design comment says
//   multiredditExpandButtonTapped: resolves the tapped row via
//   -[UITableView indexPathForRowAtPoint:] and then "imperatively animates
//   rows (insert/delete/reloadRowsAtIndexPaths:) with MODEL-space paths" —
//   i.e. a begin/endUpdates batch, not performBatchUpdates:. UNVERIFIED:
//   the exact row-animation value Apollo passes, and whether it also
//   reloads the parent row for the chevron.
// - Expanded state: keyed by account + case-insensitive multi.name (this
//   header's original comment). UNVERIFIED: the ivar that holds it, and
//   whether Apollo updates the chevron by image swap or by transform when
//   the row is configured. The chevron rotation in the tap handler is
//   therefore driven by the OBSERVED row-count change (section 2 grew =
//   expanded, shrank = collapsed), not by reading Apollo's state, and it
//   assumes a right-pointing collapsed chevron rotating 90 degrees down
//   when expanded — also UNVERIFIED, check on device.
// - The gate does not guess the tapped model from the title alone: two
//   multireddits can share a display name. It asks ApolloMultiredditEdit
//   (ApolloMultiEditExpansionChildCounts) for the tapped model's child
//   count, resolved by title AND subtitle exactly as the edit flow resolves
//   a row, plus the total children of every distinct model sharing that
//   title. Animating requires the two to be equal, which is exactly the
//   condition under which the native batch accounts for the whole model
//   delta. Anything unresolvable (no captured model lists yet, subtitle
//   replaced by a description, tied subtitle overlap) falls back to the
//   reload path. The tap handler additionally catches only
//   NSInternalInconsistencyException from an animated batch as a
//   last-resort net for a duplicate the gate could not see; recovery by
//   reloadData after such a throw is UNVERIFIED on device and must be
//   exercised with a real duplicate-name case before this is trusted.

// Duration of the chevron rotation, matched to the row batch. UIKit's
// begin/endUpdates batch animates over roughly this long; there is no API
// to read its exact duration, so this is a fixed, deliberately plain value.
static const NSTimeInterval ApolloMultiredditExpansionAnimationDuration = 0.25;

typedef struct ApolloMultiredditExpansionScope {
    __unsafe_unretained UITableView *table;
    struct ApolloMultiredditExpansionScope *parent;
    BOOL needsReload;
    // YES when the scope lets the native batch through to UIKit (animated
    // path). NO is the original deferral scope: every table call inside it
    // is swallowed and reconciled with one reloadData at the end.
    BOOL animated;
} ApolloMultiredditExpansionScope;

static ApolloMultiredditExpansionScope *sApolloMultiredditExpansionScope;

static inline ApolloMultiredditExpansionScope *ApolloMultiredditExpansionForTable(UITableView *table) {
    if (!table || ![NSThread isMainThread]) return NULL;
    for (ApolloMultiredditExpansionScope *scope = sApolloMultiredditExpansionScope;
         scope; scope = scope->parent) {
        if (scope->table == table) return scope;
    }
    return NULL;
}

// YES while the innermost scope for this table is an animated one, i.e. the
// native batch is supposed to reach UIKit. A nested deferral scope (the
// favorite star's stale-snapshot fallback) is innermost while it runs, so
// this correctly reports NO inside it.
static inline BOOL ApolloMultiredditExpansionIsAnimated(UITableView *table) {
    ApolloMultiredditExpansionScope *scope = ApolloMultiredditExpansionForTable(table);
    return scope && scope->animated;
}

// Marks the innermost scope for this table as needing a reconciling reload
// (used for a reloadData that arrives inside an animated scope, where the
// normal deferral check deliberately does not fire). Returns NO when no
// scope is active for the table.
static inline BOOL ApolloMultiredditExpansionMarkNeedsReload(UITableView *table) {
    ApolloMultiredditExpansionScope *scope = ApolloMultiredditExpansionForTable(table);
    if (!scope) return NO;
    scope->needsReload = YES;
    return YES;
}

static inline BOOL ApolloDeferMultiredditTableUpdate(UITableView *table) {
    ApolloMultiredditExpansionScope *scope = ApolloMultiredditExpansionForTable(table);
    if (!scope) return NO;
    // An animated scope lets the batch through: begin/endUpdates and the
    // row calls reach UIKit (the hooks force their animation to Fade).
    // A reloadData inside it is handled separately by
    // ApolloMultiredditExpansionMarkNeedsReload in the reloadData hook.
    if (scope->animated) return NO;
    scope->needsReload = YES;
    return YES;
}

// Gate for the animated path. All inputs are the caller's responsibility:
// tappedChildCount is the tapped model's member-subreddit count,
// totalChildrenForTitle is the sum over every distinct model sharing the
// tapped title (NSNotFound / negative when unknown). Returns YES only when
// the batch the handler is about to register can account for the whole
// model delta, the snapshot is fresh, and animation is wanted. Every NO
// means "use the reload path" — never "guess".
static inline BOOL ApolloMultiredditExpansionCanAnimate(UITableView *table, NSInteger tappedChildCount,
                                                        NSInteger totalChildrenForTitle, BOOL reduceMotionEnabled) {
    if (!table || ![NSThread isMainThread]) return NO;
    if (reduceMotionEnabled) return NO;
    // An empty multireddit registers no rows; there is nothing to animate,
    // and a zero-child count cannot prove the batch consistent.
    if (tappedChildCount <= 0) return NO;
    // Unknown totals, or a title shared by models whose children together
    // outnumber the tapped model's, mean the native batch cannot account
    // for the model delta (the duplicate-name crash case).
    if (totalChildrenForTitle < 0 || totalChildrenForTitle != tappedChildCount) return NO;
    if (ApolloTableSnapshotIsStale(table)) return NO;
    return YES;
}

static inline void ApolloPerformMultiredditExpansion(UITableView *table, dispatch_block_t original) {
    if (!table || ![NSThread isMainThread]) {
        original();
        return;
    }
    ApolloMultiredditExpansionScope scope = { table, sApolloMultiredditExpansionScope, NO, NO };
    ApolloMultiredditExpansionScope *outer = NULL;
    sApolloMultiredditExpansionScope = &scope;
    @try {
        original();
    } @finally {
        // Never swallow an exception or leave another table's calls deferred.
        sApolloMultiredditExpansionScope = scope.parent;
        outer = ApolloMultiredditExpansionForTable(table);
        // If a nested caller catches an exception, its enclosing successful
        // expansion must still reconcile any model changes already made.
        if (outer && scope.needsReload) outer->needsReload = YES;
    }
    if (scope.needsReload && !outer) {
        // Runs after the handler has closed FollowingSection's point window.
        // Its reloadData hook invalidates the section map before UIKit asks
        // for the final counts/cells. No partially applied batch exists.
        [table reloadData];
    }
}

// Animated twin of ApolloPerformMultiredditExpansion: runs the native
// handler with the batch live instead of deferred. If anything inside
// deferred a reload, or the snapshot no longer matches the model once the
// batch has run, one reloadData presents the final state instead of
// leaving a half-animated list. Exceptions propagate exactly as in the
// deferral scope (the tap handler catches only the UIKit row-count
// failure); a scope is never left behind.
static inline void ApolloPerformMultiredditExpansionAnimated(UITableView *table, dispatch_block_t original) {
    if (!table || ![NSThread isMainThread]) {
        original();
        return;
    }
    ApolloMultiredditExpansionScope scope = { table, sApolloMultiredditExpansionScope, NO, YES };
    ApolloMultiredditExpansionScope *outer = NULL;
    sApolloMultiredditExpansionScope = &scope;
    @try {
        original();
    } @finally {
        // Never swallow an exception or leave another table's calls deferred.
        sApolloMultiredditExpansionScope = scope.parent;
        outer = ApolloMultiredditExpansionForTable(table);
        // If a nested caller catches an exception, its enclosing successful
        // expansion must still reconcile any model changes already made.
        if (outer && scope.needsReload) outer->needsReload = YES;
    }
    if (!outer && (scope.needsReload || ApolloTableSnapshotIsStale(table))) {
        [table reloadData];
    }
}

// The favorite star is Apollo's one performBatchUpdates: on this list. It
// changes FavoriteSubreddits INSIDE the block and registers a single row, but
// UIKit checks EVERY section against the counts it cached at the last reload.
// If anything else changed since then without a reload, the batch throws
// whichever row it names (#1335). fetchSubredditData() is one such source: it
// assigns currentUser.moderatedSubreddits (Moderator Posts + the MODERATOR
// rows) and .multireddits as each request returns, and reloads only later.
// ApolloTableSnapshotIsStale (ApolloTableSnapshot.h) detects that state.
//
// Applies a batch's model change under the expansion deferral, then presents
// it with one reload. The reload is requested even when the block registers no
// rows, because the counts it would have animated from are already wrong.
static inline void ApolloPerformBatchAsReload(UITableView *table, dispatch_block_t updates) {
    ApolloPerformMultiredditExpansion(table, ^{
        if (updates) updates();
        [table reloadData];
    });
}

#endif
