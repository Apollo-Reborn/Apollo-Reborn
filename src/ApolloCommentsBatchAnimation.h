#import <Foundation/Foundation.h>

// Animated comments-list updates. Apollo refreshes a thread through its ListAdapter with
// `animated: false` after a comment is posted and after "N more replies" loads, so the new
// rows snap in and everything below jumps in one frame. Implemented in
// ApolloPostedCommentInsert.xm, which owns the comments-list batch hooks.

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// Runs `body` on the main thread with batch promotion armed: a NON-animated
// -[ASTableNode performBatchAnimated:updates:completion:] that a comments list issues while `body`
// runs is animated instead (inserted, reloaded and deleted rows fade while the rows below slide),
// and the batch's fresh cells are laid out and drawn synchronously before the animation starts.
// `willAnimate` runs right before each promoted batch is handed to Texture (the table node is
// passed in); `didFinish` runs when that batch completes. Both run on the main thread and are
// optional. Off the main thread `body` just runs.
void ApolloCommentsRunWithAnimatedBatch(NSString *reason,
                                        NS_NOESCAPE dispatch_block_t body,
                                        void (^_Nullable willAnimate)(id tableNode),
                                        void (^_Nullable didFinish)(BOOL finished));

__END_DECLS
NS_ASSUME_NONNULL_END
