// Smooth "N more replies" loads.
//
// Apollo's tap handler (CommentsViewController.moreCommentsCellTapped(withMoreComments:),
// Hopper sub_1007237ec) hides the row's label, shows its spinner and calls
// -[RDKClient moreComments:forLink:sort:completion:]. That completion (sub_10071c308) either
// inserts the comments right away (sub_10071cca8) or, with Highlight New Accounts
// (HighlightAccountAge) on, first fetches their authors through
// -[RDKClient usersByFullNames:completion:] and inserts from that completion. The insert puts
// the row's label back (isLoading = false, every subnode's alpha 1, spinner alpha 0) and then
// refreshes the list with `animated: false` (sub_100173230(0, …)). Texture builds and measures
// the new rows off the main thread before UIKit commits them, so on device:
//   1. the "N more replies" label flashes back for a frame or more before the rows land;
//   2. the rows snap in and every row below jumps in a single frame;
//   3. in a thread showing translations (auto-translate, or the thread's globe) every new
//      comment is measured with its original-language body and reflows when its translation
//      lands, and the rows below bounce.
// This module keeps the spinner up until the rows land, animates the insert through the shared
// comments batch promotion (ApolloCommentsBatchAnimation.h: the rows fade in, the rows below
// slide, fresh cells are drawn before the animation starts) and, in a thread showing
// translations, holds the insert for a bounded time while the new comments are translated so
// they are built and measured already translated (ApolloTranslation.h).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloCommentsBatchAnimation.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloTranslation.h"

// RedditKit completions: the parsed comments/more objects (or the user data) and an error.
typedef void (^ApolloLoadMoreCompletion)(id results, NSError *error);

// Longest the insert waits for the new comments' translations once Reddit has answered. The
// spinner keeps spinning meanwhile; comments still untranslated at the deadline are inserted
// as they are and translate afterwards, as before.
static const NSTimeInterval kApolloLoadMoreTranslationBudget = 1.2;

// One "N more replies" tap. Main thread only.
@interface ApolloLoadMoreRequest : NSObject
@property (nonatomic, weak) id moreComments;                    // RDKMoreComments
@property (nonatomic, weak) id cellNode;                        // the MoreCommentsCellNode showing the spinner
@property (nonatomic, weak) UIViewController *commentsController;
@property (nonatomic, copy) NSArray *things;                    // what Reddit returned
@property (nonatomic) BOOL waitingForTranslations;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *heldInserts;
@end

@implementation ApolloLoadMoreRequest
@end

// The request whose morechildren completion is running right now, so the author lookup Apollo
// issues from inside it can be paired with the request. Main-thread only.
static ApolloLoadMoreRequest *sApolloLoadMoreRespondingRequest = nil;

static UIViewController *ApolloLoadMoreCommentsControllerForView(UIView *view) {
    Class commentsClass = ApolloClassCommentsViewController;
    if (!commentsClass) return nil;
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:commentsClass]) return (UIViewController *)responder;
    }
    return nil;
}

// The on-screen MoreCommentsCellNode for `moreComments` (Apollo's tap handler has just put it in
// its loading state). Matched by identity: the cell keeps the RDKMoreComments it was built with.
static id ApolloLoadMoreVisibleCellNode(id moreComments, UIViewController **controllerOut) {
    Class cellNodeClass = objc_getClass("_TtC6Apollo20MoreCommentsCellNode"); // once per tap
    if (!moreComments || !cellNodeClass) return nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden) continue;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count > 0) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:[UITableView class]]) {
                for (UITableViewCell *cell in ((UITableView *)view).visibleCells) {
                    id node = ApolloSendObject(cell, @selector(node));
                    if (![node isKindOfClass:cellNodeClass]) continue;
                    if (ApolloObjectIvar(node, "moreComments") != moreComments) continue;
                    UIViewController *controller = ApolloLoadMoreCommentsControllerForView(view);
                    if (!controller) continue;
                    if (controllerOut) *controllerOut = controller;
                    return node;
                }
                continue;  // cells don't nest tables
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
    return nil;
}

// Apollo's own loading look for the row, exactly as its tap handler and insert set it: every
// subnode's alpha (the label and disclosure arrow) and the spinner's alpha.
static void ApolloLoadMoreSetRowLoading(id cellNode, BOOL loading) {
    if (!cellNode) return;
    NSArray *subnodes = ApolloSendObject(cellNode, @selector(subnodes));
    for (id subnode in subnodes) {
        if ([subnode respondsToSelector:@selector(setAlpha:)]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(subnode, @selector(setAlpha:), loading ? 0.0 : 1.0);
        }
    }
    UIView *spinner = ApolloObjectIvar(cellNode, "activityIndicator");
    if ([spinner isKindOfClass:[UIView class]]) spinner.alpha = loading ? 1.0 : 0.0;
}

// Runs one of Apollo's insert paths (the morechildren completion, or the author-lookup
// completion it chains to) with the batch promotion armed and the new comments' translations
// armed. Apollo restores the row's label right before its batch, and again from the batch's
// completion (sub_10071d264). Texture runs that completion as soon as UIKit has the update,
// before the fade has played, so a deleted row would fade out showing its label. willAnimate
// puts the spinner back before the batch; didFinish (which runs after Apollo's completion)
// puts it back again while the deleted row fades out, and leaves the label up only when the
// row survived the update (the table node still has an index path for it).
static void ApolloLoadMoreRunInsert(ApolloLoadMoreRequest *request, dispatch_block_t insert) {
    id translationToken = ApolloTranslationArmInsertedComments(request.commentsController, request.things);
    __weak id weakCellNode = request.cellNode;
    __block __weak id weakTableNode = nil;
    @try {
        ApolloCommentsRunWithAnimatedBatch(@"load more", insert, ^(id tableNode) {
            weakTableNode = tableNode;
            ApolloLoadMoreSetRowLoading(weakCellNode, YES);
        }, ^(__unused BOOL finished) {
            id cellNode = weakCellNode;
            id tableNode = weakTableNode;
            if (!cellNode || ![tableNode respondsToSelector:@selector(indexPathForNode:)]) return;
            NSIndexPath *survivingRow = ((NSIndexPath *(*)(id, SEL, id))objc_msgSend)(tableNode, @selector(indexPathForNode:), cellNode);
            ApolloLoadMoreSetRowLoading(cellNode, survivingRow == nil);
        });
    } @finally {
        // Texture asks for the new rows' node blocks synchronously inside the batch, and each
        // wrapped block keeps its own copy of the translations, so the arm can end here.
        ApolloTranslationDisarmInsertedComments(translationToken);
    }
}

// Runs `insert` now, or once the new comments' translations are in (or the budget ran out).
static void ApolloLoadMoreRunInsertWhenReady(ApolloLoadMoreRequest *request, dispatch_block_t insert) {
    if (!request.waitingForTranslations) {
        ApolloLoadMoreRunInsert(request, insert);
        return;
    }
    if (!request.heldInserts) request.heldInserts = [NSMutableArray array];
    [request.heldInserts addObject:[insert copy]];
}

static void ApolloLoadMoreTranslationsDone(ApolloLoadMoreRequest *request, NSString *why) {
    if (!request.waitingForTranslations) return;  // the other of {done, deadline} got here first
    request.waitingForTranslations = NO;
    NSArray<dispatch_block_t> *held = [request.heldInserts copy];
    request.heldInserts = nil;
    ApolloLog(@"[LoadMore] translations %@ — inserting %lu held update(s)", why, (unsigned long)held.count);
    for (dispatch_block_t insert in held) ApolloLoadMoreRunInsert(request, insert);
}

static void ApolloLoadMoreHandleResponse(ApolloLoadMoreRequest *request, id results, NSError *error,
                                         ApolloLoadMoreCompletion completion) {
    // A failed load puts the label back and reports the error: nothing to smooth.
    if (error || ![results isKindOfClass:[NSArray class]] || !NSThread.isMainThread) {
        completion(results, error);
        return;
    }
    request.things = results;
    UIViewController *controller = request.commentsController;
    if (controller) {
        __weak ApolloLoadMoreRequest *weakRequest = request;
        request.waitingForTranslations = ApolloTranslationPrefetchCommentsForInsertion(controller, results, ^{
            ApolloLoadMoreRequest *strongRequest = weakRequest;
            if (strongRequest) ApolloLoadMoreTranslationsDone(strongRequest, @"ready");
        });
    }
    if (request.waitingForTranslations) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloLoadMoreTranslationBudget * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloLoadMoreTranslationsDone(request, @"timed out");
        });
    }

    // With Highlight New Accounts on, Apollo looks the authors up before inserting: let that
    // request start now, in parallel with the translations, and hold its completion instead
    // (see the usersByFullNames: hook). Otherwise Apollo inserts from this completion.
    BOOL looksUpAuthors = [[NSUserDefaults standardUserDefaults] boolForKey:@"HighlightAccountAge"];
    if (looksUpAuthors) {
        ApolloLoadMoreRequest *previous = sApolloLoadMoreRespondingRequest;
        sApolloLoadMoreRespondingRequest = request;
        @try {
            // Still promoted and armed: if Apollo inserts from here after all, that insert is
            // smoothed too (without waiting for translations).
            ApolloLoadMoreRunInsert(request, ^{ completion(results, error); });
        } @finally {
            sApolloLoadMoreRespondingRequest = previous;
        }
        return;
    }
    ApolloLoadMoreRunInsertWhenReady(request, ^{ completion(results, error); });
}

%hook RDKClient

// "N more replies". ApolloLiveCommentsFollow.xm hooks the same method to rewrite a live sort;
// both hooks pass everything else through, so their order doesn't matter.
- (id)moreComments:(id)moreComments forLink:(id)link sort:(long long)sort completion:(ApolloLoadMoreCompletion)completion {
    if (!completion || !NSThread.isMainThread) return %orig;
    ApolloLoadMoreRequest *request = [ApolloLoadMoreRequest new];
    request.moreComments = moreComments;
    UIViewController *controller = nil;
    request.cellNode = ApolloLoadMoreVisibleCellNode(moreComments, &controller);
    request.commentsController = controller;
    os_log_debug(ApolloFixLog(), "[ApolloFix] [LoadMore] request (row %{public}s, thread %{public}s)",
                 request.cellNode ? "on screen" : "not on screen", controller ? "found" : "not found");
    ApolloLoadMoreCompletion wrapped = ^(id results, NSError *error) {
        ApolloLoadMoreHandleResponse(request, results, error, completion);
    };
    return %orig(moreComments, link, sort, wrapped);
}

// Highlight New Accounts: Apollo's morechildren completion fetches the new authors and inserts
// from this completion. Only the lookup issued from inside a load-more response is touched.
- (id)usersByFullNames:(id)names completion:(ApolloLoadMoreCompletion)completion {
    if (!completion || !NSThread.isMainThread) return %orig;
    ApolloLoadMoreRequest *request = sApolloLoadMoreRespondingRequest;
    if (!request) return %orig;
    ApolloLoadMoreCompletion wrapped = ^(id users, NSError *error) {
        if (!NSThread.isMainThread) {
            completion(users, error);
            return;
        }
        ApolloLoadMoreRunInsertWhenReady(request, ^{ completion(users, error); });
    };
    return %orig(names, wrapped);
}

%end

%ctor {
    %init;
    ApolloLog(@"[LoadMore] hooks installed (more-replies insert: spinner hold, animated batch, translate before insert)");
}
