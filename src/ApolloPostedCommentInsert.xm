// Animate a freshly posted comment into the thread.
//
// Apollo's CommentsViewController.commentSubmitted(_:composeViewController:replyingTo:comment:error:)
// appends the new RDKComment to its CommentTree, bumps the link's totalComments, and refreshes the
// list through its ListAdapter with `animated: false` (Hopper: sub_10071a8f0 → sub_100701e44 →
// sub_100173230(0, …)). The adapter's updates block picks UITableViewRowAnimationNone (5) when that
// flag is false and UITableViewRowAnimationAutomatic (100) when true, then calls
// -[ASTableNode performBatchAnimated:updates:completion:] with the same flag. So the new row and
// everything below it snap into place in a single frame — usually while the compose sheet is still
// sliding away, which is the "forced into place" feel.
//
// The delegate call runs synchronously inside the RDKClient submit completion on the main thread,
// so the window is narrow and precise: wrap the completion of the submit funnel, and while it runs
// treat the comments list's non-animated batch as animated, with the new row fading in while the
// rows below slide down to make room.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

@interface ASDisplayNode : NSObject
- (BOOL)isNodeLoaded;
- (UIView *)view;
- (void)layoutIfNeeded;
- (void)recursivelyEnsureDisplaySynchronously:(BOOL)sync;
@end

@interface ASTableNode : ASDisplayNode
@end

// RedditKit's RDKObjectCompletionBlock: the parsed RDKComment (or nil) and an error.
typedef void (^ApolloPostedCommentCompletion)(id object, NSError *error);

// YES only while a SUCCESSFUL comment-submit completion is running on the main thread; set and
// restored around the original completion (@finally-guarded), so the only batch update that can
// observe it is the one Apollo issues for that comment. Main-thread only.
static BOOL sApolloPostedCommentCompletionActive = NO;
// Non-zero while the animated batch's updates block runs, so the row-level calls inside it can
// swap `.none` for a fade. Main-thread only.
static NSUInteger sApolloPostedCommentBatchDepth = 0;

static Class ApolloPostedCommentCommentsClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("_TtC6Apollo22CommentsViewController"); });
    return cls;
}

// The batch must belong to a comments thread: walk the responder chain from the table view.
static BOOL ApolloPostedCommentTableIsCommentsList(ASTableNode *tableNode) {
    Class commentsClass = ApolloPostedCommentCommentsClass();
    if (!commentsClass) return NO;
    if (![tableNode respondsToSelector:@selector(isNodeLoaded)] || ![tableNode isNodeLoaded]) return NO;
    UIResponder *responder = [tableNode view];
    while (responder) {
        if ([responder isKindOfClass:commentsClass]) return YES;
        responder = responder.nextResponder;
    }
    return NO;
}


// Rows the promoted batch inserts or reloads. Their cells are created a moment later, and
// Texture rasterises a fresh cell's text nodes asynchronously — the body lands a frame before
// the byline (text plus the avatar attachment), which is visible while the row fades in. So
// each of those cells is laid out and drawn synchronously in -willDisplayCell:, before UIKit
// starts the insert/reload animation. Consumed row by row; cleared when the batch completes
// or after a short deadline (a cancelled pop can leave rows undisplayed). Main-thread only.
static __weak UITableView *sApolloPostedCommentPendingTableView = nil;
static NSMutableSet<NSIndexPath *> *sApolloPostedCommentPendingRows = nil;
static CFAbsoluteTime sApolloPostedCommentPendingDeadline = 0;
// Row operations recorded while the promoted batch's updates block runs.
static NSMutableArray<NSIndexPath *> *sApolloPostedCommentInsertedRows = nil;
static NSMutableArray<NSIndexPath *> *sApolloPostedCommentReloadedRows = nil;
static NSMutableArray<NSIndexPath *> *sApolloPostedCommentDeletedRows = nil;

static void ApolloPostedCommentClearPending(void) {
    sApolloPostedCommentPendingTableView = nil;
    sApolloPostedCommentPendingRows = nil;
    sApolloPostedCommentPendingDeadline = 0;
}

// UIKit batch semantics: reloads and deletes name OLD rows, inserts name NEW rows, and the
// surviving old rows fill the new slots the inserts leave free, in order. Map a reloaded old
// row to the slot its recreated cell will occupy.
static NSIndexPath *ApolloPostedCommentNewIndexPathForReloadedRow(NSIndexPath *oldPath) {
    NSInteger section = oldPath.section;
    NSInteger rank = oldPath.row;
    for (NSIndexPath *deleted in sApolloPostedCommentDeletedRows) {
        if (deleted.section == section && deleted.row < oldPath.row) rank--;
    }
    NSMutableIndexSet *insertedSlots = [NSMutableIndexSet indexSet];
    for (NSIndexPath *inserted in sApolloPostedCommentInsertedRows) {
        if (inserted.section == section) [insertedSlots addIndex:(NSUInteger)inserted.row];
    }
    NSInteger slot = 0;
    NSInteger survivorsSeen = -1;
    while (YES) {
        if (![insertedSlots containsIndex:(NSUInteger)slot]) {
            survivorsSeen++;
            if (survivorsSeen == rank) break;
        }
        slot++;
        if (slot > 100000) return nil;   // defensive: never spin on a malformed batch
    }
    return [NSIndexPath indexPathForRow:slot inSection:section];
}

static void ApolloPostedCommentRecordPendingRows(ASTableNode *tableNode) {
    NSMutableSet<NSIndexPath *> *rows = [NSMutableSet set];
    [rows addObjectsFromArray:sApolloPostedCommentInsertedRows];
    for (NSIndexPath *reloaded in sApolloPostedCommentReloadedRows) {
        NSIndexPath *mapped = ApolloPostedCommentNewIndexPathForReloadedRow(reloaded);
        if (mapped) [rows addObject:mapped];
    }
    UIView *view = [tableNode isNodeLoaded] ? [tableNode view] : nil;
    if (rows.count == 0 || ![view isKindOfClass:[UITableView class]]) {
        ApolloPostedCommentClearPending();
        return;
    }
    sApolloPostedCommentPendingTableView = (UITableView *)view;
    sApolloPostedCommentPendingRows = rows;
    sApolloPostedCommentPendingDeadline = CFAbsoluteTimeGetCurrent() + 2.0;
}

// Draw a pending row's fresh cell now: apply its pending layout (the frame is final, the row
// was measured before the batch) and rasterise every text/image node on this turn, so the
// first committed frame of the animation shows the whole comment.
static void ApolloPostedCommentDisplayPendingCell(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (tableView != sApolloPostedCommentPendingTableView || CFAbsoluteTimeGetCurrent() > sApolloPostedCommentPendingDeadline) {
        ApolloPostedCommentClearPending();
        return;
    }
    if (![sApolloPostedCommentPendingRows containsObject:indexPath]) return;
    [sApolloPostedCommentPendingRows removeObject:indexPath];
    if (sApolloPostedCommentPendingRows.count == 0) ApolloPostedCommentClearPending();

    id node = nil;
    if ([cell respondsToSelector:@selector(node)]) {
        node = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(node));
    }
    if (![node isKindOfClass:objc_getClass("ASCellNode")]) {
        ApolloLogDebug(@"[PostedCommentInsert] row %ld has no cell node to draw (%@)", (long)indexPath.row, NSStringFromClass([cell class]));
        return;
    }
    if ([node respondsToSelector:@selector(layoutIfNeeded)]) [node layoutIfNeeded];
    if ([node respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
        [node recursivelyEnsureDisplaySynchronously:YES];
    }
    ApolloLogDebug(@"[PostedCommentInsert] drew fresh cell synchronously for row %ld", (long)indexPath.row);
}

%hook RDKClient

// Every comment submit funnels through here (the onLink: / asReplyToComment: variants tail-call
// it). ApolloOwnCommentFlair.xm hooks the same funnel to arm its flair backfill; both hooks only
// observe and call %orig, so their order is irrelevant.
- (id)submitComment:(id)body onThingWithFullName:(id)fullName completion:(ApolloPostedCommentCompletion)completion {
    if (!completion) return %orig;
    ApolloPostedCommentCompletion wrapped = ^(id object, NSError *error) {
        BOOL previous = sApolloPostedCommentCompletionActive;
        // A failed submit shows an alert instead of inserting; an off-main delivery could not
        // be paired with the batch anyway.
        sApolloPostedCommentCompletionActive = (error == nil && object != nil && NSThread.isMainThread);
        @try {
            completion(object, error);
        } @finally {
            sApolloPostedCommentCompletionActive = previous;
        }
    };
    return %orig(body, fullName, wrapped);
}

%end

%hook ASTableNode

- (void)performBatchAnimated:(BOOL)animated updates:(void (^)(void))updates completion:(void (^)(BOOL))completion {
    if (!sApolloPostedCommentCompletionActive || animated) {
        %orig;
        return;
    }
    if (!ApolloPostedCommentTableIsCommentsList(self)) {
        ApolloLog(@"[PostedCommentInsert] non-animated batch during a comment submit is not on a comments list — leaving it");
        %orig;
        return;
    }
    ApolloLog(@"[PostedCommentInsert] animating the posted-comment batch on table %p", self);
    ApolloPostedCommentClearPending();
    sApolloPostedCommentInsertedRows = [NSMutableArray array];
    sApolloPostedCommentReloadedRows = [NSMutableArray array];
    sApolloPostedCommentDeletedRows = [NSMutableArray array];
    void (^animatedUpdates)(void) = ^{
        sApolloPostedCommentBatchDepth++;
        @try {
            if (updates) updates();
        } @finally {
            sApolloPostedCommentBatchDepth--;
        }
        ApolloPostedCommentRecordPendingRows(self);
        sApolloPostedCommentInsertedRows = nil;
        sApolloPostedCommentReloadedRows = nil;
        sApolloPostedCommentDeletedRows = nil;
    };
    void (^wrappedCompletion)(BOOL) = ^(BOOL finished) {
        ApolloPostedCommentClearPending();
        if (completion) completion(finished);
    };
    %orig(YES, animatedUpdates, wrappedCompletion);
}

// Apollo's updates block records the row animation it computed from its own (false) flag; inside
// the batch we promoted, substitute a fade. (`.automatic` — what Apollo's own animated updates
// use — resolves to a top slide for a row inserted right under the header, so the new comment
// emerges from underneath the post header; a fade keeps it in place while the rows below make
// room.)
- (void)insertRowsAtIndexPaths:(NSArray *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if (sApolloPostedCommentBatchDepth > 0 && animation == UITableViewRowAnimationNone) {
        [sApolloPostedCommentInsertedRows addObjectsFromArray:indexPaths];
        ApolloLogDebug(@"[PostedCommentInsert] insert %lu row(s) → fade", (unsigned long)indexPaths.count);
        %orig(indexPaths, UITableViewRowAnimationFade);
        return;
    }
    %orig;
}

- (void)reloadRowsAtIndexPaths:(NSArray *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if (sApolloPostedCommentBatchDepth > 0 && animation == UITableViewRowAnimationNone) {
        [sApolloPostedCommentReloadedRows addObjectsFromArray:indexPaths];
        ApolloLogDebug(@"[PostedCommentInsert] reload %lu row(s) → fade", (unsigned long)indexPaths.count);
        %orig(indexPaths, UITableViewRowAnimationFade);
        return;
    }
    %orig;
}

- (void)deleteRowsAtIndexPaths:(NSArray *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if (sApolloPostedCommentBatchDepth > 0 && animation == UITableViewRowAnimationNone) {
        [sApolloPostedCommentDeletedRows addObjectsFromArray:indexPaths];
        ApolloLogDebug(@"[PostedCommentInsert] delete %lu row(s) → fade", (unsigned long)indexPaths.count);
        %orig(indexPaths, UITableViewRowAnimationFade);
        return;
    }
    %orig;
}

%end

%hook ASTableView

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!sApolloPostedCommentPendingRows) return;
    ApolloPostedCommentDisplayPendingCell(tableView, cell, indexPath);
}

%end

%ctor {
    %init;
    ApolloLog(@"[PostedCommentInsert] hook installed (comment-submit batch → animated)");
}
