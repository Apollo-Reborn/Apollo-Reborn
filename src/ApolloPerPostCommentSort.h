// Runtime helpers exported by ApolloPerPostCommentSort.xm.
//
// ApolloURLOpenCommentSort.xm applies Apollo's comment-sort chain (per-post memory on top)
// to URL-scheme opens, where CommentsViewController's `link` is nil until the first fetch
// returns. The ivar layout knowledge stays in ApolloPerPostCommentSort.xm; these are the
// only entry points other modules use.

#import <Foundation/Foundation.h>

// `currentSort` on _TtC6Apollo22CommentsViewController (Optional<RDKCommentSortingMethod>:
// Int64 raw at +0, is-nil byte at +8). Read returns NO for .none / unknown layout; write is
// bounds-checked and returns NO instead of touching memory it cannot vouch for.
BOOL ApolloCommentsVCReadCurrentSort(id vc, int64_t *outRaw);
BOOL ApolloCommentsVCWriteCurrentSort(id vc, int64_t raw);

// The `link` ivar (RDKLink *). nil on URL-scheme / inbox opens until the first fetch lands.
id ApolloCommentsVCLink(id vc);

// "Top" / "Best" / ... / "Live Update" for an RDKCommentSortingMethod raw; "?" otherwise.
NSString *ApolloCommentSortName(int64_t raw);

// Saved "Remember Post Sort" raw (1-7) for a bare post id, 0 when nothing is saved. Does
// not consult the feature toggle; callers check sPerPostCommentSort themselves.
int64_t ApolloPerPostCommentSortSavedSort(NSString *postID);
