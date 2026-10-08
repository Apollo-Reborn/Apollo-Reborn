// ApolloCommentVoteFlicker
//
// Fixes the one-frame "flicker" of a comment when it is up/down-voted (and on
// any other in-place model update): the whole comment body flashes blank for a
// single frame before redrawing, even though only the score digit + arrow tint
// actually change. Reported on both plain-text and media comments.
//
// ── Mechanism (measured in the sim, not inferred) ──────────────────────────
// A vote delivers the updated RDKComment via the
// "com.christianselig.ModelObjectUpdated" notification to the row's
// -[CommentSectionController modelObjectUpdatedNotificationReceived:], which
// reconfigures the cell in place (byline rebuild + -setNeedsLayout, re-running
// the cell's layoutSpecThatFits:). Texture then re-displays several of the
// cell's text/image nodes ASYNCHRONOUSLY. Instrumenting the display pipeline
// during a real vote showed one of those nodes being committed to screen with
// layer.contents == nil — i.e. the frame renders with that node BLANK, and the
// async redraw only lands on the next frame. That nil-contents commit is the
// flicker. (Whether a given node blanks depends on whether the reconfigure
// clears/replaces it — the byline usually survives, body/text nodes don't —
// but the fix below doesn't need to care which node it is.)
//
// ── Fix ────────────────────────────────────────────────────────────────────
// Make the voted cell finish its (re)display synchronously, inside the same
// frame, so there is never a nil-contents commit:
//   1. neverShowPlaceholders = YES on the cell — Texture then blocks the main
//      thread briefly to complete display of on-screen content instead of
//      committing a placeholder/blank and filling it in a frame later.
//   2. recursivelyEnsureDisplaySynchronously:YES right after the reconfigure,
//      and again on the next main-queue turn — flushes the display passes the
//      reconfigure scheduled (the -setNeedsLayout wave lands a turn later).
//   3. For each flush, image nodes that would commit blank (e.g. the rebuilt
//      rich link card's hero image) temporarily drop Texture's
//      shouldBypassEnsureDisplay so the flush waits for them too.
// All three selectors exist in Apollo's bundled Texture (verified in the binary).
//
// Scope: ONLY cells that actually receive a model-update notification while
// visible (votes, live edits). Cells never get touched during scrolling, so
// scroll perf is unaffected. The one-off synchronous draw of an already
// visible cell is a sub-millisecond text render on a tap, plus (step 3) one
// image draw for each network image the vote rebuilt that would otherwise
// commit blank, such as a link card's hero (~10 ms for a 1280x720 thumbnail
// in the sim).
//
// Covers both the comment rows (CommentSectionController) and the post header
// in the comments view (CommentsHeaderSectionController) — both flicker the
// same way when voted.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloTranslation.h"
#import "ApolloState.h"
#import "ApolloClasses.h"

@interface ASDisplayNode : NSObject
@property (nonatomic) BOOL neverShowPlaceholders;
@property (nonatomic) BOOL displaysAsynchronously;
@property (nonatomic) BOOL shouldBypassEnsureDisplay;
@property (nonatomic, readonly) BOOL isNodeLoaded;
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, readonly) CALayer *layer;
- (NSArray<ASDisplayNode *> *)subnodes;
- (void)didEnterHierarchy;
- (void)didExitHierarchy;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
- (void)recursivelyEnsureDisplaySynchronously:(BOOL)sync;
@end

// MARK: - macOS Texture focus redraw
//
// The iOS-on-Mac compatibility layer changes window tint/focus state whenever
// Apollo gains or loses key-window status, including when UIKit presents an
// alert. Texture responds by invalidating tinted ASTextNode/ASImageNode leaves,
// then redraws them asynchronously. Track only those leaves while they are in
// the hierarchy and synchronously finish their pending display at each Mac
// focus boundary. Normal scrolling and ordinary redraws remain asynchronous.
static BOOL ApolloVFIsMacRuntime(void) {
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    return processInfo.isiOSAppOnMac || processInfo.isMacCatalystApp;
}

static BOOL ApolloVFNeedsMacSynchronousDisplay(id node) {
    if (!node) return NO;
    return [node isKindOfClass:ApolloClassASTextNode] ||
           [node isKindOfClass:ApolloClassASTextNode2] ||
           [node isKindOfClass:ApolloClassASImageNode];
}

static NSHashTable *ApolloVFMacDisplayLeaves(void) {
    static NSHashTable *leaves = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ leaves = [NSHashTable weakObjectsHashTable]; });
    return leaves;
}

static void ApolloVFTrackMacDisplayLeaf(id node, BOOL inHierarchy) {
    if (!ApolloVFNeedsMacSynchronousDisplay(node)) return;
    NSHashTable *leaves = ApolloVFMacDisplayLeaves();
    @synchronized (leaves) {
        if (inHierarchy) [leaves addObject:node];
        else [leaves removeObject:node];
    }
}

static UIWindowScene *ApolloVFFocusSceneForNotification(NSNotification *notification) {
    id object = notification.object;
    if ([object isKindOfClass:[UIWindowScene class]]) return object;
    if ([object isKindOfClass:[UIWindow class]]) return ((UIWindow *)object).windowScene;
    return nil;
}

static void ApolloVFFlushTrackedMacDisplayLeaves(UIWindowScene *focusScene) {
    NSHashTable *leaves = ApolloVFMacDisplayLeaves();
    NSArray *snapshot = nil;
    @synchronized (leaves) { snapshot = leaves.allObjects; }
    for (ASDisplayNode *node in snapshot) {
        @try {
            // Check isNodeLoaded before touching .view: asking an unloaded
            // Texture node for its view can force it to load. Only a node in a
            // live window can contribute a blank frame, and scene/window
            // notifications must not flush another Catalyst window.
            if (![node respondsToSelector:@selector(isNodeLoaded)] || !node.isNodeLoaded) continue;
            UIView *view = [node respondsToSelector:@selector(view)] ? node.view : nil;
            UIWindow *window = view.window;
            if (!window || (focusScene && window.windowScene != focusScene)) continue;
            if (view.hidden || view.alpha < 0.01 || CGRectIsEmpty(view.bounds)) continue;
            CGRect frameInWindow = [view convertRect:view.bounds toView:window];
            if (!CGRectIntersectsRect(window.bounds, frameInWindow)) continue;
            if (![node respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) continue;
            [node recursivelyEnsureDisplaySynchronously:YES];
        } @catch (__unused NSException *e) {}
    }
}

static NSUInteger sApolloVFMacFocusGeneration = 0;
static CFAbsoluteTime sApolloVFMacLastFocusTime = 0;
static __weak UIWindowScene *sApolloVFMacLastFocusScene = nil;

static void ApolloVFScheduleMacFocusFlush(UIWindowScene *focusScene) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL sameTransition = sApolloVFMacLastFocusTime > 0 &&
        now - sApolloVFMacLastFocusTime <= 0.05 &&
        (!focusScene || !sApolloVFMacLastFocusScene || focusScene == sApolloVFMacLastFocusScene);
    NSUInteger generation = ++sApolloVFMacFocusGeneration;
    sApolloVFMacLastFocusTime = now;
    sApolloVFMacLastFocusScene = focusScene;

    // Catalyst can post scene, application, and window notifications for the
    // same focus boundary. Keep one immediate/next/late sequence instead of
    // multiplying synchronous work for duplicate notifications.
    if (!sameTransition) ApolloVFFlushTrackedMacDisplayLeaves(focusScene);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation == sApolloVFMacFocusGeneration) {
            ApolloVFFlushTrackedMacDisplayLeaves(focusScene);
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == sApolloVFMacFocusGeneration) {
            ApolloVFFlushTrackedMacDisplayLeaves(focusScene);
        }
    });
}

%group ApolloVFMacTextureSync

%hook ASDisplayNode

- (void)didEnterHierarchy {
    %orig;
    ApolloVFTrackMacDisplayLeaf(self, YES);
}

- (void)didExitHierarchy {
    ApolloVFTrackMacDisplayLeaf(self, NO);
    %orig;
}

%end

%end

static void ApolloVFInstallMacTextureSync(void) {
    Class displayNodeClass = objc_getClass("ASDisplayNode");
    if (!displayNodeClass) return;
    %init(ApolloVFMacTextureSync, ASDisplayNode = displayNodeClass);
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSArray<NSNotificationName> *focusNotifications = @[
        UISceneWillDeactivateNotification,
        UISceneDidActivateNotification,
        UIApplicationWillResignActiveNotification,
        UIApplicationDidBecomeActiveNotification,
        UIWindowDidResignKeyNotification,
        UIWindowDidBecomeKeyNotification,
    ];
    for (NSNotificationName name in focusNotifications) {
        [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *notification) {
            ApolloVFScheduleMacFocusFlush(ApolloVFFocusSceneForNotification(notification));
        }];
    }
    ApolloLog(@"[VoteFlicker] Mac focus redraw guard enabled");
}

static void ApolloVFInstallMacTextureSyncIfNeeded(void) {
    if (ApolloVFIsMacRuntime()) ApolloVFInstallMacTextureSync();
}

// MARK: - end macOS Texture focus redraw

// Weak set of comment/header cells currently on screen. Only consulted when a
// model-update notification arrives, so the bookkeeping cost is two hash-table
// ops per cell appearance.
static NSHashTable *sApolloVFVisibleCells = nil;

static void ApolloVFTrackCell(id cell, BOOL visible) {
    if (!sApolloVFVisibleCells) sApolloVFVisibleCells = [NSHashTable weakObjectsHashTable];
    if (visible) [sApolloVFVisibleCells addObject:cell];
    else [sApolloVFVisibleCells removeObject:cell];
}

static NSString *ApolloVFFullName(id model) {
    if (![model respondsToSelector:@selector(fullName)]) return nil;
    @try {
        NSString *fn = ((NSString *(*)(id, SEL))objc_msgSend)(model, @selector(fullName));
        return [fn isKindOfClass:[NSString class]] ? fn : nil;
    } @catch (__unused NSException *e) { return nil; }
}

// The visible cell(s) whose model matches the updated one. A vote updates
// exactly one comment; matching by fullname keeps this surgical even when the
// notification fires for unrelated model updates.
static NSArray *ApolloVFCellsForUpdatedModel(id note) {
    id model = [note isKindOfClass:[NSNotification class]] ? [(NSNotification *)note object] : nil;
    NSString *fullName = ApolloVFFullName(model);
    if (fullName.length == 0) return @[];
    NSMutableArray *hits = [NSMutableArray array];
    for (id cell in sApolloVFVisibleCells.allObjects) {
        id m = ApolloObjectIvar(cell, "comment") ?: ApolloObjectIvar(cell, "link");
        if ([ApolloVFFullName(m) isEqualToString:fullName]) [hits addObject:cell];
    }
    return hits;
}

// ASNetworkImageNode's init sets shouldBypassEnsureDisplay, so
// recursivelyEnsureDisplaySynchronously: starts its draw but never waits for
// it. A comment vote rebuilds the comment's LinkButtonNode, so the rich link
// card comes back with a fresh hero image node: the flush drew the rebuilt
// text in-frame, but the card image committed blank for ~2 frames until its
// async draw landed. Opt in, for one flush, only the image nodes that would
// commit blank (in the layer tree, unhidden, non-empty, image set, no contents
// yet). Image nodes that already show pixels keep bypassing. Texture replays a
// pending setNeedsDisplay on them a turn later, and that redraw keeps the old
// contents up until it lands, so waiting on it would only cost main-thread
// time.
static void ApolloVFOptInBlankImageNodes(ASDisplayNode *root, NSMutableArray *optedIn) {
    if (!root) return;
    Class networkImageClass = ApolloClassASNetworkImageNode;
    if (!networkImageClass ||
        ![networkImageClass instancesRespondToSelector:@selector(setShouldBypassEnsureDisplay:)]) {
        // Without the opt-in a rebuilt card image commits blank again on a vote.
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            ApolloLog(@"[VoteFlicker] blank-image opt-in NOT armed: ASNetworkImageNode or -setShouldBypassEnsureDisplay: missing");
        });
        return;
    }
    NSMutableArray *pending = [NSMutableArray arrayWithObject:root];
    while (pending.count > 0) {
        ASDisplayNode *node = pending.lastObject;
        [pending removeLastObject];
        NSArray *children = node.subnodes;
        if (children.count > 0) [pending addObjectsFromArray:children];
        if (![node isKindOfClass:networkImageClass] || !node.isNodeLoaded || !node.shouldBypassEnsureDisplay) continue;
        CALayer *layer = node.layer;
        if (layer.contents || !layer.superlayer || layer.hidden || CGRectIsEmpty(layer.bounds)) continue;
        if (!ApolloSendObject(node, @selector(image))) continue;
        node.shouldBypassEnsureDisplay = NO;
        [optedIn addObject:node];
    }
}

static void ApolloVFEnsureSynchronousDisplay(NSArray *cells, const char *stage) {
    NSUInteger waitedImages = 0;
    for (ASDisplayNode *cell in cells) {
        NSMutableArray *optedIn = [NSMutableArray array];
        @try {
            if ([cell respondsToSelector:@selector(setNeverShowPlaceholders:)]) {
                cell.neverShowPlaceholders = YES;
            }
            // The rebuilt card's nodes only join the layer tree in the cell's
            // pending layout pass, which the flush runs first. Run it here so
            // the scan can see them (the flush then finds no layout to do).
            CALayer *layer = cell.isNodeLoaded ? cell.layer : nil;
            if (layer.needsLayout) [layer layoutIfNeeded];
            ApolloVFOptInBlankImageNodes(cell, optedIn);
            if ([cell respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
                [cell recursivelyEnsureDisplaySynchronously:YES];
            }
        } @catch (__unused NSException *e) {}
        // Restore Texture's default even if the flush threw.
        for (ASDisplayNode *node in optedIn) node.shouldBypassEnsureDisplay = YES;
        waitedImages += optedIn.count;
    }
    if (cells.count > 0) {
        os_log_info(ApolloFixLog(), "[ApolloFix] [VoteFlicker] ensured synchronous display for %lu cell(s) (%{public}s), waited on %lu new image(s)",
                    (unsigned long)cells.count, stage, (unsigned long)waitedImages);
    }
}

// The comment-count bubble in a feed's info row is a tiny layer-backed Texture
// subtree. When a pushed comments controller covers the feed, Texture leaves
// that subtree's display range and discards its backing contents. On an
// interactive pop it normally redraws the bubble asynchronously; UIKit can
// remove the transition snapshot one frame before that redraw commits, which
// is the isolated bubble flicker visible on swipe-back.
//
// Keep this one cheap subtree synchronous for its lifetime. PostInfoNode arms
// the initial subtree when it enters the hierarchy, then re-arms Apollo's
// replacement subtree inside readCommentsUpdatedWithNotification:. This avoids
// navigation timing assumptions and does not make the post body, media, or the
// rest of the feed draw synchronously.
static void ApolloVFStabilizeCommentsInfoNode(ASDisplayNode *node, BOOL flush) {
    if (!node) return;
    @try {
        NSMutableArray<ASDisplayNode *> *pending = [NSMutableArray arrayWithObject:node];
        while (pending.count > 0) {
            ASDisplayNode *current = pending.lastObject;
            [pending removeLastObject];
            if ([current respondsToSelector:@selector(setNeverShowPlaceholders:)]) {
                current.neverShowPlaceholders = YES;
            }
            if ([current respondsToSelector:@selector(setDisplaysAsynchronously:)]) {
                current.displaysAsynchronously = NO;
            }
            if ([current respondsToSelector:@selector(subnodes)]) {
                NSArray *children = current.subnodes;
                if (children.count > 0) [pending addObjectsFromArray:children];
            }
        }
        if (flush && [node respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
            [node recursivelyEnsureDisplaySynchronously:YES];
        }
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            ApolloLog(@"[VoteFlicker] comments info subtree armed for synchronous display");
        });
    } @catch (__unused NSException *e) {}
}

static void ApolloVFRealizeUpdatedCommentsInfo(id postInfo, const char *stage) {
    @try {
        ASDisplayNode *commentsInfo = (ASDisplayNode *)ApolloObjectIvar(postInfo, "commentsInfoNode");
        if (!commentsInfo) return;
        ApolloVFStabilizeCommentsInfoNode(commentsInfo, NO);
        if ([postInfo respondsToSelector:@selector(setNeedsLayout)]) {
            [postInfo setNeedsLayout];
        }
        if ([postInfo respondsToSelector:@selector(layoutIfNeeded)]) {
            [postInfo layoutIfNeeded];
        }
        ApolloVFStabilizeCommentsInfoNode(commentsInfo, YES);
        if ([postInfo respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
            [postInfo recursivelyEnsureDisplaySynchronously:YES];
        }
        // Confirmation only (helpful, not essential): info level.
        os_log_info(ApolloFixLog(), "[ApolloFix] [VoteFlicker] read-comments update realized synchronously (%{public}s)", stage);
    } @catch (__unused NSException *e) {}
}

// A vote (or any in-place model update) makes Apollo splice a Mantle COPY of
// the comment into the tree, and Mantle's copy re-runs every property setter —
// including setCollapsed: with whatever the model last parsed from the server.
// Reddit marks crowd-controlled comments `collapsed: true` in the listing JSON,
// but Apollo's initial cell build renders them EXPANDED (the flatten only
// collapses tracker/blocked/AutoMod comments), so the flag sits latent in the
// model. The vote-time reconfigure (unlike the initial build) DOES honor
// comment.collapsed, so the row the user just voted on snaps into the
// collapsed presentation (body hidden, child-count badge) and then bounces
// back when the next update lands — the "flicker" on every vote in
// crowd-controlled threads (reported against translated threads because
// foreign-language subs are where both crowd control and translation are on).
//
// Neutralize the flag on the incoming copy ONLY when the visible row is
// actually RENDERED EXPANDED: an expanded row whose replacement model says
// collapsed can only be latent server state (or our own setStickied: hook
// re-asserting on the copy) — Apollo's own collapse toggle never routes
// through this notification (it splices + rebuilds directly). A row that is
// rendered collapsed, on the other hand, is a DELIBERATE collapse — the user's
// manual toggle, a blocked/AutoMod collapse, or the tweak's own Collapse
// Pinned Comments feature (ApolloCommentsCollapse.xm forces _collapsed on
// stickied comments) — and clearing the copy's flag there would pop the row
// open on vote. Gate on the rendered presentation, not the model flags.
//
// The rendered state is probed structurally: CommentCellNode's byline layout
// switches its trailing accessories on comment.collapsed — the collapsed
// presentation carries totalCollapsedChildrenIndicator (the child-count
// badge) and collapseDisclosureIndicator, the expanded one carries the
// age/more-options cluster instead. Either indicator live in the hierarchy ⇒
// the row is rendered collapsed. The write goes straight to the ivar so no
// setCollapsed: hooks (cover views, settle windows) fire for what is a pure
// metadata correction.
static BOOL ApolloVFAccessoryNodeIsLive(id node) {
    if (!node) return NO;
    @try {
        if (![node respondsToSelector:@selector(isNodeLoaded)] ||
            !((BOOL (*)(id, SEL))objc_msgSend)(node, @selector(isNodeLoaded))) return NO;
        // Probe at the LAYER level: these indicator nodes are layer-backed
        // (no UIView — -view returns nil for them), and a layer probe also
        // covers view-backed nodes uniformly.
        CALayer *layer = [node respondsToSelector:@selector(layer)]
            ? ((CALayer *(*)(id, SEL))objc_msgSend)(node, @selector(layer)) : nil;
        if (!layer.superlayer || layer.hidden) return NO;
        CGRect f = layer.frame;
        return f.size.width > 0.5 && f.size.height > 0.5;
    } @catch (__unused NSException *e) { return NO; }
}

static BOOL ApolloVFCellRendersCollapsed(id cell) {
    return ApolloVFAccessoryNodeIsLive(ApolloObjectIvar(cell, "totalCollapsedChildrenIndicator")) ||
           ApolloVFAccessoryNodeIsLive(ApolloObjectIvar(cell, "collapseDisclosureIndicator"));
}

static void ApolloVFNeutralizeCarriedOverCollapse(id note) {
    @try {
        id oldModel = [note isKindOfClass:[NSNotification class]] ? [(NSNotification *)note object] : nil;
        id newModel = [note isKindOfClass:[NSNotification class]] ? [(NSNotification *)note userInfo][@"newModel"] : nil;
        Class commentClass = ApolloClassRDKComment;
        if (!commentClass || ![oldModel isMemberOfClass:commentClass] || ![newModel isMemberOfClass:commentClass]) return;
        if (![newModel respondsToSelector:@selector(collapsed)]) return;
        BOOL newCollapsed = ((BOOL (*)(id, SEL))objc_msgSend)(newModel, @selector(collapsed));
        if (!newCollapsed) return; // nothing to neutralize
        NSArray *cells = ApolloVFCellsForUpdatedModel(note);
        if (cells.count == 0) return; // no visible row — nothing can flicker, and an
                                      // off-screen pinned/collapsed comment keeps its flag
        for (id cell in cells) {
            if (ApolloVFCellRendersCollapsed(cell)) {
                ApolloLog(@"[VoteFlicker] kept collapse on updated comment — row is rendered collapsed (deliberate)");
                return;
            }
        }
        Ivar collapsedIvar = class_getInstanceVariable([newModel class], "_collapsed");
        if (!collapsedIvar) return;
        *(BOOL *)((uint8_t *)(__bridge void *)newModel + ivar_getOffset(collapsedIvar)) = NO;
        ApolloLog(@"[VoteFlicker] cleared carried-over server collapse on updated comment (row renders expanded)");
    } @catch (__unused NSException *e) {}
}

// ── Vote-window row-height quiesce ──────────────────────────────────────────
// A vote's reconfigure rebuilds the comment's body text node and the fresh
// node briefly holds the UNTRANSLATED original — one "Translated from X"
// marker line shorter than what's on screen. The rebuilt node is still
// detached when its text is set, so the translation module's identity-checked
// preempt must decline (an identical body could otherwise borrow another
// comment's translation), and the scheduled reapply restores the text ~10ms
// later. The text race is invisible (the reapply's synchronous heal wins),
// but ASTableView's requeryNodeHeights runs in between: it commits the
// one-line-shorter measure as an ANIMATED row update and then a second
// animated update restores it — the comment's bottom divider visibly nudges
// up and springs back on every vote. Suppress height re-queries for a short
// window around the reconfigure and re-run once after it: the intermediate
// measure is never committed, and the deferred re-query commits the (by then
// unchanged) final height.
static CFAbsoluteTime sApolloVFHeightQuiesceUntil = 0;
static char kApolloVFRequeryDeferredKey;

static void (*orig_ApolloVFRequeryNodeHeights)(id, SEL);
static void ApolloVFRequeryNodeHeights(id self, SEL _cmd) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < sApolloVFHeightQuiesceUntil) {
        if (!objc_getAssociatedObject(self, &kApolloVFRequeryDeferredKey)) {
            objc_setAssociatedObject(self, &kApolloVFRequeryDeferredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSTimeInterval delay = MAX(0.02, (sApolloVFHeightQuiesceUntil - now) + 0.02);
            __weak UIView *weakSelf = (UIView *)self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIView *strongSelf = weakSelf;
                if (!strongSelf) return;
                objc_setAssociatedObject(strongSelf, &kApolloVFRequeryDeferredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                // Run the deferred requery even off-window: dropping it
                // left the table's committed row heights permanently stale —
                // any row that grew during the quiesce (e.g. an inline image
                // getting its ratio) stayed short until something else happened
                // to re-query. requeryNodeHeights is a pure recompute and safe
                // off-window; the quiesce's only job is to SKIP the mid-vote
                // intermediate measure, never to lose the final one.
                @try { orig_ApolloVFRequeryNodeHeights(strongSelf, _cmd); } @catch (__unused NSException *e) {}
            });
        }
        return;
    }
    orig_ApolloVFRequeryNodeHeights(self, _cmd);
}

// Shared handler body for both section-controller hooks: arm the matching
// visible cell(s) before the reconfigure, flush the display wave right after,
// and once more on the next runloop turn (the -setNeedsLayout relayout lands
// there; its re-displays are what commit blank without this).
static void ApolloVFHandleModelUpdate(id note, void (^origCall)(void)) {
    ApolloVFNeutralizeCarriedOverCollapse(note);
    NSArray *cells = ApolloVFCellsForUpdatedModel(note);
    NSMutableArray *translatedBodyCovers = [NSMutableArray array];
    for (ASDisplayNode *cell in cells) {
        @try {
            if ([cell respondsToSelector:@selector(setNeverShowPlaceholders:)]) {
                cell.neverShowPlaceholders = YES;
            }
            id cover = ApolloTranslationInstallVoteBodyCover(cell);
            if (cover) [translatedBodyCovers addObject:cover];
        } @catch (__unused NSException *e) {}
    }
    if (cells.count > 0) {
        sApolloVFHeightQuiesceUntil = CFAbsoluteTimeGetCurrent() + 0.12;
    }
    origCall();
    if (cells.count == 0) return;
    // Settle the translation right before EACH flush: these synchronous
    // flushes exist to kill the blank frame, but they paint whatever the body
    // holds — and a vote rebuilds the body node with the untranslated
    // original ~a turn later, which the detached-node preempt can only
    // correct after attach. A flush landing inside that gap painted the
    // original language for a frame or two ("sometimes it flickers"). The
    // settle call is an exact-gate no-op when the text is already right, so
    // the usual pre-reset flush stays write-free — and the module's
    // recently-applied guard is content-scoped now, so even a pre-reset
    // write cannot strand the post-reset restore (the round-2 failure mode).
    for (ASDisplayNode *cell in cells) {
        @try { ApolloTranslationReapplySynchronouslyForVoteReconfigure(cell); }
        @catch (__unused NSException *e) {}
    }
    ApolloVFEnsureSynchronousDisplay(cells, "post-reconfigure");
    dispatch_async(dispatch_get_main_queue(), ^{
        for (ASDisplayNode *cell in cells) {
            @try { ApolloTranslationReapplySynchronouslyForVoteReconfigure(cell); }
            @catch (__unused NSException *e) {}
        }
        ApolloVFEnsureSynchronousDisplay(cells, "next-turn");
    });
    // The deferred translation preempt lands on the next main turn and the
    // replacement body's synchronous flush is complete by the following
    // frame. Keep the exact old translated pixels over the BODY ONLY for a
    // few extra frames, then remove them without animation. Score/byline
    // changes remain visible throughout because they sit outside the cover.
    if (translatedBodyCovers.count > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (id cover in translatedBodyCovers) {
                ApolloTranslationRemoveVoteBodyCover(cover);
            }
        });
    }
}

%hook _TtC6Apollo15CommentCellNode
- (void)didEnterVisibleState {
    %orig;
    ApolloVFTrackCell(self, YES);
    // Cached translations can be installed by the global text-node preempt
    // before the normal translation apply function ever runs. Prime after the
    // cell has settled so that fast path also has a ready vote cover. With
    // bulk translation off there is nothing to snapshot — skip the per-cell
    // timer + comment-extraction work entirely.
    if (sEnableBulkTranslation) {
        __weak id weakCell = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id strongCell = weakCell;
            if (!strongCell || ![sApolloVFVisibleCells containsObject:strongCell]) return;
            ApolloTranslationPrimeVoteBodySnapshot(strongCell);
        });
    }
}
- (void)didExitVisibleState {
    %orig;
    ApolloVFTrackCell(self, NO);
    ApolloTranslationDiscardVoteBodySnapshot(self);
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didEnterVisibleState {
    %orig;
    ApolloVFTrackCell(self, YES);
}
- (void)didExitVisibleState {
    %orig;
    ApolloVFTrackCell(self, NO);
}
%end

// CommentsInfoNode's plain -init is intentionally unavailable in Apollo's
// Swift class, and its Texture lifecycle methods are inherited rather than
// class-owned. PostInfoNode does own didEnterHierarchy and already has the
// fully-built commentsInfoNode at that point, making this the reliable place
// to arm the bubble before its first display-range entry.
%hook _TtC6Apollo12PostInfoNode
- (void)didEnterHierarchy {
    %orig;
    ASDisplayNode *commentsInfo = (ASDisplayNode *)ApolloObjectIvar(self, "commentsInfoNode");
    ApolloVFStabilizeCommentsInfoNode(commentsInfo, YES);
}

- (void)readCommentsUpdatedWithNotification:(id)notification {
    %orig;
    ApolloVFRealizeUpdatedCommentsInfo(self, "now");
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloVFRealizeUpdatedCommentsInfo(weakSelf, "next-turn");
    });
}
%end

// Feed post cells participate in the foreground heal below (their text blanks
// the same way when the app returns from the background).
%hook _TtC6Apollo17LargePostCellNode
- (void)didEnterVisibleState {
    %orig;
    ApolloVFTrackCell(self, YES);
}
- (void)didExitVisibleState {
    %orig;
    ApolloVFTrackCell(self, NO);
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)didEnterVisibleState {
    %orig;
    ApolloVFTrackCell(self, YES);
}
- (void)didExitVisibleState {
    %orig;
    ApolloVFTrackCell(self, NO);
}
%end

%hook _TtC6Apollo24CommentSectionController
- (void)modelObjectUpdatedNotificationReceived:(id)note {
    void (^originalUpdate)(void) = ^{
        %orig;
    };
    ApolloVFHandleModelUpdate(note, originalUpdate);
}
%end

%hook _TtC6Apollo31CommentsHeaderSectionController
- (void)modelObjectUpdatedNotificationReceived:(id)note {
    void (^originalUpdate)(void) = ^{
        %orig;
    };
    ApolloVFHandleModelUpdate(note, originalUpdate);
}
%end

// ── Foreground heal (issue #217's app-switch flicker) ──────────────────────
// Backgrounding makes Texture drop cell backing stores (cells leave the
// visible/display range and free their rendered contents to save memory);
// returning to the app re-displays them ASYNCHRONOUSLY, so every visible
// comment/post body renders BLANK until its redraw lands — measured in the
// sim at over a second of nil-contents commits after didBecomeActive, which
// matches the "text disappears for up to a second" reports. Same nil-contents
// mechanism as the vote flicker, so the same lever fixes it: flush the
// re-displays synchronously during the foreground transition, before the
// live view replaces the system snapshot. Staged passes because cells
// re-enter the visible range at slightly different times across the
// transition (willEnterForeground → didBecomeActive → first frames).
static void ApolloVFForegroundHeal(const char *stage) {
    NSArray *cells = sApolloVFVisibleCells.allObjects;
    if (cells.count == 0) return;
    for (ASDisplayNode *cell in cells) {
        @try {
            if ([cell respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)]) {
                [cell recursivelyEnsureDisplaySynchronously:YES];
            }
        } @catch (__unused NSException *e) {}
    }
    ApolloLog(@"[VoteFlicker] foreground heal: flushed display for %lu cell(s) (%s)",
              (unsigned long)cells.count, stage);
}

%ctor {
    %init;
    ApolloVFInstallMacTextureSyncIfNeeded();

    // Vote-window height quiesce (see sApolloVFHeightQuiesceUntil above).
    // Manual swizzle with an existence guard: requeryNodeHeights is a Texture
    // internal — if a future Apollo binary ships without it, the quiesce
    // silently disarms and the rest of the module is unaffected.
    Class tableClass = objc_getClass("ASTableView");
    Method requeryMethod = tableClass ? class_getInstanceMethod(tableClass, @selector(requeryNodeHeights)) : NULL;
    if (requeryMethod) {
        orig_ApolloVFRequeryNodeHeights = (void (*)(id, SEL))method_getImplementation(requeryMethod);
        ApolloSetMethodImplementation(tableClass, requeryMethod, (IMP)ApolloVFRequeryNodeHeights);
    }

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    void (^heal)(NSNotification *) = ^(__unused NSNotification *n) {
        ApolloVFForegroundHeal("now");
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloVFForegroundHeal("next-turn"); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{ ApolloVFForegroundHeal("late"); });
    };
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:heal];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:heal];
}
