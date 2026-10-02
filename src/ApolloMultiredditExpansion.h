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

typedef struct ApolloMultiredditExpansionScope {
    __unsafe_unretained UITableView *table;
    struct ApolloMultiredditExpansionScope *parent;
    BOOL needsReload;
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

static inline BOOL ApolloDeferMultiredditTableUpdate(UITableView *table) {
    ApolloMultiredditExpansionScope *scope = ApolloMultiredditExpansionForTable(table);
    if (!scope) return NO;
    scope->needsReload = YES;
    return YES;
}

static inline void ApolloPerformMultiredditExpansion(UITableView *table, dispatch_block_t original) {
    if (!table || ![NSThread isMainThread]) {
        original();
        return;
    }
    ApolloMultiredditExpansionScope scope = { table, sApolloMultiredditExpansionScope, NO };
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
