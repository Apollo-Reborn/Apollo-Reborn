#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import <QuartzCore/QuartzCore.h>

#import "ApolloCommon.h"

// Exported from ApolloVideoUnmute.xm — fixes disconnected playerLayer
// after the reclaim puts it in an orphaned playerLayerSuperlayer.
extern void ApolloVideoUnmute_FixDisconnectedPlayerLayer(id postsViewController);
// Exported from ApolloVideoUnmute.xm — puts the header's mute icon back in step
// with the player it just got back.
extern void ApolloVideoUnmute_SyncMuteButtonIcon(id richMediaNode, BOOL isMuted);

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Fixes the "grey video" bug during interactive back swipe (pop) gesture in
// comments view when compact posts are OFF (shared AVPlayerLayer path).
//
// Root cause: When the user begins a swipe-back gesture, UIKit speculatively
// calls viewWillAppear: on the underlying VC. Apollo's reclaim function
// (sub_100561a40) runs inside viewWillAppear:, moving the shared AVPlayerLayer
// from the comments header back to the feed cell. This is one-shot — the
// sharing state is consumed. If the gesture is cancelled, the layer is stuck
// in the feed cell and the comments header shows a grey rectangle.
//
// Fix: During interactive pop transitions, we call [super viewWillAppear:]
// (UIKit lifecycle) but skip Apollo's reclaim loop. When the gesture commits,
// we re-run the full viewWillAppear: which performs the reclaim at the right
// time. If the gesture is cancelled, nothing happened — video stays in place.
//
// Affected VCs (all call sub_100561a40 in viewWillAppear:):
//   - PostsViewController          (main feed)
//   - SavedPostsCommentsViewController (saved posts)
//   - ProfileViewController        (user profile)
//
// PostsSearchResultsViewController has no native reclaim to defer; its
// tweak-side equivalent lives in ApolloVideoUnmute.xm (%group
// SearchResultsReclaim) — deferral changes here likely need mirroring there.
//
// The second half of this file (MARK: Header Re-take) fixes the other way the
// comments header ends up grey: another node takes the shared layer while the
// comments screen is covered, and the header never takes it back.
//
// =============================================================================

// Flag: prevents re-entry into the deferral path when we manually invoke
// viewWillAppear: from the commit callback.
static BOOL sCommittedPopRunningReclaim = NO;

// =============================================================================
// MARK: - Shared Deferral Logic
// =============================================================================

// Returns YES if the reclaim was deferred (caller should NOT call %orig).
// Returns NO if the caller should proceed with %orig normally.
//
// When an interactive pop of CommentsVC is in progress, this function:
//   1. Calls [super viewWillAppear:] for UIKit lifecycle correctness
//   2. Registers a commit/cancel callback on the transition coordinator
//   3. On commit: re-runs the full viewWillAppear: (including reclaim)
//   4. On cancel: does nothing (video stays in comments header)
static BOOL DeferReclaimIfInteractivePop(id self_, BOOL animated) {
    UINavigationController *nav = [(UIViewController *)self_ navigationController];
    id<UIViewControllerTransitionCoordinator> coordinator = nav ? [nav transitionCoordinator] : nil;

    // Only defer when a CommentsViewController is being popped.
    // viewWillAppear: also fires during other interactive transitions
    // (e.g. pushing from subreddit list) — we must not interfere.
    static Class sCommentsVCClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sCommentsVCClass = objc_getClass("_TtC6Apollo22CommentsViewController");
    });

    BOOL poppingComments = NO;
    if (coordinator && [coordinator isInteractive]) {
        id fromVC = [coordinator viewControllerForKey:UITransitionContextFromViewControllerKey];
        poppingComments = sCommentsVCClass && [fromVC isMemberOfClass:sCommentsVCClass];
    }

    if (!poppingComments || sCommittedPopRunningReclaim) return NO;

    ApolloLog(@"[VideoSwipeFix] viewWillAppear: during interactive pop of CommentsVC — deferring reclaim");

    // Call [super viewWillAppear:] to maintain UIKit lifecycle correctness,
    // but skip Apollo's reclaim loop (which is in %orig after the super call).
    struct objc_super superInfo;
    superInfo.receiver = self_;
    superInfo.super_class = class_getSuperclass(object_getClass(self_));
    ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(
        &superInfo, @selector(viewWillAppear:), animated);

    // Register for transition interaction change.
    // This fires when the gesture crosses the commit threshold (or cancels),
    // BEFORE the completion animation finishes and before viewDidAppear:.
    __weak id weakSelf = self_;
    BOOL capturedAnimated = animated;
    [coordinator notifyWhenInteractionChangesUsingBlock:
        ^(id<UIViewControllerTransitionCoordinatorContext> context) {
            if ([context isCancelled]) {
                ApolloLog(@"[VideoSwipeFix] Interactive pop cancelled — video preserved in comments header");
                return;
            }

            // Pop committed — now run the full viewWillAppear: including reclaim.
            // At this point, isInteractive returns NO (interaction ended), so we
            // won't re-enter the deferral path. The sCommittedPopRunningReclaim
            // flag is a safety net.
            id strongSelf = weakSelf;
            if (!strongSelf) return;

            ApolloLog(@"[VideoSwipeFix] Interactive pop committed — running deferred reclaim");

            // The commit callback fires while the transition's completion
            // animation is still active. The reclaim moves the AVPlayerLayer
            // to the feed cell and sets its frame — without disabling
            // animations, Core Animation would interpolate the frame change,
            // causing a visible "zoom from center" artifact.
            [CATransaction begin];
            [CATransaction setDisableActions:YES];

            sCommittedPopRunningReclaim = YES;
            [(UIViewController *)strongSelf viewWillAppear:capturedAnimated];
            sCommittedPopRunningReclaim = NO;

            [CATransaction commit];

            // After the reclaim, the shared playerLayer may end up in a
            // disconnected layer tree (playerLayerSuperlayer orphaned by
            // fullscreen transitions). dispatch_async so we run after the
            // reclaim's own async block (if it fires) has completed.
            dispatch_async(dispatch_get_main_queue(), ^{
                id s = weakSelf;
                if (s) ApolloVideoUnmute_FixDisconnectedPlayerLayer(s);
            });
        }];

    return YES;
}

// =============================================================================
// MARK: - Header Re-take (shared layer taken by another node)
// =============================================================================
//
// Apollo keeps ONE AVPlayerLayer per video URL in VideoSharingManager
// (sharedPlayerLayers + playerLayerUsageCount, keyed by the post URL). Every
// RichMediaNode showing that URL takes the layer the first time it prepares
// its video: -[RichMediaNode didEnterPreloadState] -> sub_100582a0c, or the
// play decision's asset path (sub_10057bae8 -> sub_10057c93c). Both look the
// URL up (sub_1005e684c), bump the usage count (sub_1005e635c), then
// removeFromSuperlayer / setAllowPlayerLayerToBeShareable:YES / setPlayerLayer:
// / [videoNode.layer addSublayer:]. -[ASVideoNode playerLayer] then answers
// with that sublayer instead of the node's own, player-less _playerNode layer.
//
// The take is one-shot. Once the video node is shareable, -didEnterPreloadState
// skips sub_100582a0c entirely (tbnz on allowPlayerLayerToBeShareable) and the
// asset path has already run, so a node that loses the layer never takes it
// back. Two everyday ways the comments header loses it:
//   1. Tapping the OP's name opens their profile, whose overview lists this
//      same post. That cell enters the preload range under the profile header
//      and takes the layer. Back on the post, the header is a grey box with no
//      player.
//   2. Swiping back to the feed runs the feed's reclaim (sub_100561a40: layer
//      home, usage count - 1, share released at zero). Swiping FORWARD into the
//      post re-pushes the same CommentsViewController from the forward history:
//      the header is on screen again but never re-takes.
// A grey header also breaks the Feed Video Scrubber on the post: with no
// player the strip refuses the touch, so a drag on the progress bar falls
// through to swipe back / forward.
//
// Fix: remember (weakly) the layer each comments header took. When the header
// is on screen again without it, and wherever the layer sits now is not on
// screen (an off-screen profile cell, the feed underneath, never the fullscreen
// viewer or a visible cell), move it back with the same steps as Apollo's take.
// The move leaves VideoSharingManager alone, and in case 2 the share is already
// released, so the feed's next reclaim would not find the layer. The header
// therefore remembers where it took the layer from and hands it back when its
// comments screen is popped: right after the parent's own reclaim for
// Posts/Saved/Profile parents (the viewWillAppear: hooks below), otherwise in
// the comments screen's viewDidDisappear:. If Apollo's reclaim already moved
// the layer (case 1, where the share is still registered), there is nothing to
// hand back. A take-back made at the start of an interactive swipe onto the
// post is handed back the moment that swipe is cancelled.

@interface ApolloHeaderLayerRecord : NSObject
// The shared layer this comments header took (weak: VideoSharingManager and
// whichever node hosts it own it).
@property (nonatomic, weak) AVPlayerLayer *sharedLayer;
// Set only while the header holds a layer WE moved back into it.
@property (nonatomic, weak) CALayer *borrowedFrom;
@property (nonatomic, assign) CGRect borrowedFromFrame;
@property (nonatomic, weak) UIViewController *borrowingScreen;
// Last reason a take-back was refused (log de-dup).
@property (nonatomic, copy) NSString *lastBlockedReason;
@end

@implementation ApolloHeaderLayerRecord
@end

static const void *kApolloHeaderLayerRecordKey = &kApolloHeaderLayerRecordKey;

// Weak set of header RichMediaNodes that have a record, so a comments screen can
// find its own headers on appear / pop without walking its table.
static NSHashTable *sHeaderLayerNodes = nil;

static Class sRichMediaNodeClass = nil;
static Class sCommentsViewControllerClass = nil;

static id HeaderRetakeIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

// Swift Bool ivar (1 byte); NO when missing.
static BOOL HeaderRetakeBoolIvar(id obj, const char *name) {
    if (!obj) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return NO;
    return *(BOOL *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(ivar));
}

static BOOL HeaderRetakeNodeIsLoaded(id node) {
    if (!node) return NO;
    if (![node respondsToSelector:@selector(isNodeLoaded)]) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(node, @selector(isNodeLoaded));
}

// A loaded node's layer, without forcing an off-screen node to load.
static CALayer *HeaderRetakeLayerOfNode(id node) {
    if (!HeaderRetakeNodeIsLoaded(node) || ![node respondsToSelector:@selector(layer)]) return nil;
    return ((CALayer *(*)(id, SEL))objc_msgSend)(node, @selector(layer));
}

static BOOL HeaderRetakeVideoNodeIsShareable(id videoNode) {
    SEL sel = NSSelectorFromString(@"allowPlayerLayerToBeShareable");
    if (!videoNode || ![videoNode respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(videoNode, sel);
}

// The shared layer a shareable video node is showing, if any. Mirrors
// -[ASVideoNode playerLayer]: an AVPlayerLayer sublayer of the node's own layer
// that is not its own _playerNode layer.
static AVPlayerLayer *HeaderRetakeSharedSublayer(id videoNode) {
    CALayer *host = HeaderRetakeLayerOfNode(videoNode);
    if (!host) return nil;
    CALayer *own = HeaderRetakeLayerOfNode(HeaderRetakeIvar(videoNode, "_playerNode"));
    for (CALayer *sublayer in host.sublayers) {
        if (sublayer != own && [sublayer isKindOfClass:[AVPlayerLayer class]]) {
            return (AVPlayerLayer *)sublayer;
        }
    }
    return nil;
}

// Is this layer actually visible in a window right now? Bails on hidden or
// transparent ancestors, finds the window through the first view-backed
// ancestor (the window's own root layer has no usable delegate on iOS 26/27),
// and checks the layer's rect against it. A cell below the fold of a pushed
// profile, the feed under the comments screen, or a screen in the forward
// history all read NO; the fullscreen viewer and a visible feed cell read YES.
static BOOL HeaderRetakeLayerIsOnScreen(CALayer *layer) {
    if (!layer) return NO;
    UIWindow *window = nil;
    BOOL sawView = NO;
    for (CALayer *l = layer; l; l = l.superlayer) {
        if (l.hidden || l.opacity <= 0.01f) return NO;
        if (!sawView && [l.delegate isKindOfClass:[UIView class]]) {
            sawView = YES;
            window = ((UIView *)l.delegate).window;
        }
    }
    if (!window || window.hidden) return NO;
    CGRect inWindow = [layer convertRect:layer.bounds toLayer:window.layer];
    CGRect visible = CGRectIntersection(inWindow, window.layer.bounds);
    return !CGRectIsNull(visible) && visible.size.width >= 1.0 && visible.size.height >= 1.0;
}

static UIViewController *HeaderRetakeScreenForNode(id node) {
    if (!HeaderRetakeNodeIsLoaded(node) || ![node respondsToSelector:@selector(view)]) return nil;
    UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(node, @selector(view));
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
    }
    return nil;
}

static ApolloHeaderLayerRecord *HeaderRetakeRecord(id richMediaNode, BOOL create) {
    if (!richMediaNode) return nil;
    ApolloHeaderLayerRecord *record = objc_getAssociatedObject(richMediaNode, kApolloHeaderLayerRecordKey);
    if (!record && create) {
        record = [ApolloHeaderLayerRecord new];
        objc_setAssociatedObject(richMediaNode, kApolloHeaderLayerRecordKey, record,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sHeaderLayerNodes) sHeaderLayerNodes = [NSHashTable weakObjectsHashTable];
        [sHeaderLayerNodes addObject:richMediaNode];
    }
    return record;
}

static BOOL HeaderRetakeRestore(id richMediaNode, NSString *reason);
static void HeaderRetakeHandBack(UIViewController *screen, NSString *reason);

// Remember the shared layer a comments header is showing. Never overwrites a
// known layer with nil: a header that lost its layer keeps pointing at it.
static void HeaderRetakeRememberLayer(id richMediaNode, AVPlayerLayer *shared, NSString *source) {
    if (!richMediaNode || !shared) return;
    ApolloHeaderLayerRecord *record = HeaderRetakeRecord(richMediaNode, YES);
    if (record.sharedLayer != shared) {
        record.sharedLayer = shared;
        ApolloLog(@"[VideoSwipeFix] comments header %p holds shared layer %p (%@)", richMediaNode, shared, source);
    }
}

// Backup for the setPlayerLayer: hook below, called from the header cells' own
// visibility events: note the layer a visible header is already showing.
static void HeaderRetakeNoteSharedLayer(id richMediaNode) {
    id videoNode = HeaderRetakeIvar(richMediaNode, "videoNode");
    if (!HeaderRetakeVideoNodeIsShareable(videoNode)) return;
    HeaderRetakeRememberLayer(richMediaNode, HeaderRetakeSharedSublayer(videoNode), @"visible");
}

// The header cells' visibility events: note the layer (event 0, or the first
// tick after the take when the record is still empty), then take it back if
// something took it.
static void HeaderRetakeHeaderVisibility(id richMediaNode, unsigned long long event) {
    if (!richMediaNode || (event != 0 && event != 1)) return;
    if (event == 0 || !HeaderRetakeRecord(richMediaNode, NO).sharedLayer) {
        HeaderRetakeNoteSharedLayer(richMediaNode);
    }
    HeaderRetakeRestore(richMediaNode, event == 0 ? @"header visible" : @"header scrolled");
}

// Move the header's shared layer back into it when something off screen took
// it. Returns YES when it moved the layer.
static BOOL HeaderRetakeRestore(id richMediaNode, NSString *reason) {
    ApolloHeaderLayerRecord *record = HeaderRetakeRecord(richMediaNode, NO);
    AVPlayerLayer *layer = record.sharedLayer;
    if (!layer) return NO;

    id videoNode = HeaderRetakeIvar(richMediaNode, "videoNode");
    CALayer *host = HeaderRetakeLayerOfNode(videoNode);
    if (!host || layer.superlayer == host) return NO;   // still ours (the common case)

    // Lost it. Name the reason when we can't take it back (logged once per
    // reason, so a scroll doesn't repeat it every frame).
    NSString *blocked = nil;
    if (!HeaderRetakeVideoNodeIsShareable(videoNode)) blocked = @"video node not shareable";
    else if (HeaderRetakeSharedSublayer(videoNode)) blocked = @"showing another shared layer";
    else if (!layer.player) blocked = @"layer has no player";
    else if (!HeaderRetakeLayerIsOnScreen(host)) blocked = @"header not on screen";
    else if (HeaderRetakeLayerIsOnScreen(layer)) blocked = @"layer on screen elsewhere";
    if (blocked) {
        if (![record.lastBlockedReason isEqualToString:blocked]) {
            record.lastBlockedReason = blocked;
            ApolloLog(@"[VideoSwipeFix] comments header %p lost shared layer %p, not taking it back: %@ (%@)",
                      richMediaNode, layer, blocked, reason);
        }
        return NO;
    }
    record.lastBlockedReason = nil;

    CALayer *from = layer.superlayer;
    CGRect fromFrame = layer.frame;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer removeFromSuperlayer];
    SEL setPlayerLayerSel = NSSelectorFromString(@"setPlayerLayer:");
    if ([videoNode respondsToSelector:setPlayerLayerSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(videoNode, setPlayerLayerSel, layer);
    }
    [host addSublayer:layer];
    layer.frame = host.bounds;
    [CATransaction commit];
    // -[ASVideoNode layout] keeps shared sublayers sized to the node.
    if ([videoNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(videoNode, @selector(setNeedsLayout));
    }

    UIViewController *screen = HeaderRetakeScreenForNode(richMediaNode);
    record.borrowedFrom = from;
    record.borrowedFromFrame = fromFrame;
    record.borrowingScreen = screen;

    ApolloLog(@"[VideoSwipeFix] comments header %p lost its shared layer %p to %@ — took it back (%@)",
              richMediaNode, layer,
              from ? NSStringFromClass([from.delegate class] ?: [from class]) : @"(nowhere)", reason);
    ApolloVideoUnmute_SyncMuteButtonIcon(richMediaNode, layer.player.isMuted);

    // Taken at the start of an interactive swipe onto the post (back from the
    // profile, or forward into the post): if the swipe is cancelled the post
    // never shows, so the layer goes straight back to where it was.
    id<UIViewControllerTransitionCoordinator> coordinator = screen.transitionCoordinator;
    if (coordinator.isInteractive) {
        __weak UIViewController *weakScreen = screen;
        [coordinator notifyWhenInteractionChangesUsingBlock:
            ^(id<UIViewControllerTransitionCoordinatorContext> context) {
                UIViewController *strongScreen = weakScreen;
                if (context.isCancelled && strongScreen) {
                    HeaderRetakeHandBack(strongScreen, @"swipe cancelled");
                }
            }];
    }
    return YES;
}

static void HeaderRetakeRestoreHeadersOfScreen(UIViewController *screen, NSString *reason) {
    for (id node in sHeaderLayerNodes.allObjects) {
        if (HeaderRetakeScreenForNode(node) == screen) HeaderRetakeRestore(node, reason);
    }
}

// Give a layer we took back to where it came from, if it is still in the
// header (Apollo's own reclaim, when it finds the layer, has already moved it).
static void HeaderRetakeHandBack(UIViewController *screen, NSString *reason) {
    for (id node in sHeaderLayerNodes.allObjects) {
        ApolloHeaderLayerRecord *record = HeaderRetakeRecord(node, NO);
        if (!record.borrowingScreen || record.borrowingScreen != screen) continue;

        AVPlayerLayer *layer = record.sharedLayer;
        CALayer *from = record.borrowedFrom;
        CALayer *host = HeaderRetakeLayerOfNode(HeaderRetakeIvar(node, "videoNode"));
        if (layer && from && host && layer.superlayer == host) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [layer removeFromSuperlayer];
            [from addSublayer:layer];
            layer.frame = record.borrowedFromFrame;
            [CATransaction commit];
            ApolloLog(@"[VideoSwipeFix] comments header %p handed shared layer %p back to %@ (%@)",
                      node, layer, NSStringFromClass([from.delegate class] ?: [from class]), reason);
        }
        record.borrowedFrom = nil;
        record.borrowingScreen = nil;
    }
}

// Called from the reclaiming parents' viewWillAppear: right after Apollo's
// reclaim (%orig): if a comments screen is being popped off this navigation
// controller, hand back whatever its header borrowed.
static void HeaderRetakeHandBackAfterReclaim(UIViewController *appearing) {
    UINavigationController *nav = appearing.navigationController;
    id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
    UIViewController *from = [coordinator viewControllerForKey:UITransitionContextFromViewControllerKey];
    if (!from || !sCommentsViewControllerClass || ![from isKindOfClass:sCommentsViewControllerClass]) return;
    if ([nav.viewControllers containsObject:from]) return;   // not a pop
    HeaderRetakeHandBack(from, @"after reclaim");
}

// =============================================================================
// MARK: - Hooks
// =============================================================================

%hook PostsViewController
- (void)viewWillAppear:(BOOL)animated {
    if (DeferReclaimIfInteractivePop(self, animated)) return;
    %orig;
    HeaderRetakeHandBackAfterReclaim((UIViewController *)self);
}
%end

%hook SavedPostsCommentsViewController
- (void)viewWillAppear:(BOOL)animated {
    if (DeferReclaimIfInteractivePop(self, animated)) return;
    %orig;
    HeaderRetakeHandBackAfterReclaim((UIViewController *)self);
}
%end

%hook ProfileViewController
- (void)viewWillAppear:(BOOL)animated {
    if (DeferReclaimIfInteractivePop(self, animated)) return;
    %orig;
    HeaderRetakeHandBackAfterReclaim((UIViewController *)self);
}
%end

// Apollo's take hands the shared layer to the video node with setPlayerLayer:
// (then adds it as a sublayer), wherever the take runs from. Remember it when
// that video node belongs to a comments header.
%group HeaderRetakeTake
%hook ASVideoNode
- (void)setPlayerLayer:(id)playerLayer {
    %orig;
    if (![NSThread isMainThread] || ![playerLayer isKindOfClass:[AVPlayerLayer class]]) return;
    if (![self respondsToSelector:@selector(supernode)]) return;
    id supernode = ((id (*)(id, SEL))objc_msgSend)(self, @selector(supernode));
    if (!sRichMediaNodeClass || ![supernode isKindOfClass:sRichMediaNodeClass]) return;
    if (HeaderRetakeIvar(supernode, "videoNode") != self) return;
    if (!HeaderRetakeBoolIvar(supernode, "isShownInCommentsHeader")) return;
    HeaderRetakeRememberLayer(supernode, (AVPlayerLayer *)playerLayer, @"take");
}
%end
%end

// The header comes back on screen: take the layer back if it was taken.
// Before %orig, so Apollo's visibility logic and the other tweak hooks on this
// event (unmute, scrubber) already see the player.
%group HeaderRetakeRichMediaHeader
%hook RichMediaHeaderCellNode
- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    HeaderRetakeHeaderVisibility(HeaderRetakeIvar(self, "richMediaNode"), event);
    %orig;
}
%end
%end

%group HeaderRetakeCommentsHeader
%hook CommentsHeaderCellNode
- (void)cellNodeVisibilityEvent:(unsigned long long)event
                   inScrollView:(id)scrollView
                  withCellFrame:(CGRect)frame {
    // A crosspost's media sits one level down.
    HeaderRetakeHeaderVisibility(HeaderRetakeIvar(HeaderRetakeIvar(self, "crosspostNode"), "richMediaNode"), event);
    %orig;
}
%end
%end

%group HeaderRetakeCommentsScreen
%hook CommentsViewController
// A push or pop that ends on the post: whatever held the layer during the
// transition (the feed sliding away, the profile being popped) is off screen
// now, so a header that stayed grey through the animation gets its video here.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    HeaderRetakeRestoreHeadersOfScreen((UIViewController *)self, @"comments appeared");
}

// Popped to a parent without a native reclaim (inbox, search, links): hand
// back anything still borrowed now that the transition is over.
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if ([(UIViewController *)self isMovingFromParentViewController]) {
        HeaderRetakeHandBack((UIViewController *)self, @"comments popped");
    }
}
%end
%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class postsVCClass = objc_getClass("_TtC6Apollo19PostsViewController");
    Class savedPostsVCClass = objc_getClass("_TtC6Apollo32SavedPostsCommentsViewController");
    Class profileVCClass = objc_getClass("_TtC6Apollo21ProfileViewController");

    ApolloLog(@"[VideoSwipeFix] ctor: PostsViewController=%p, SavedPostsCommentsVC=%p, ProfileVC=%p",
              (void *)postsVCClass, (void *)savedPostsVCClass, (void *)profileVCClass);

    if (!postsVCClass) {
        ApolloLog(@"[VideoSwipeFix] ctor: FATAL — PostsViewController class not found!");
        return;
    }

    %init(
        PostsViewController = postsVCClass,
        SavedPostsCommentsViewController = savedPostsVCClass ?: postsVCClass,
        ProfileViewController = profileVCClass ?: postsVCClass
    );

    // Header re-take: each class in its own group, so binary drift in one
    // costs only that piece.
    sRichMediaNodeClass = objc_getClass("_TtC6Apollo13RichMediaNode");
    Class videoNodeClass = objc_getClass("ASVideoNode");
    Class richMediaHeaderClass = objc_getClass("_TtC6Apollo23RichMediaHeaderCellNode");
    Class commentsHeaderClass = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode");
    sCommentsViewControllerClass = objc_getClass("_TtC6Apollo22CommentsViewController");
    if (sRichMediaNodeClass && videoNodeClass
        && class_getInstanceMethod(videoNodeClass, NSSelectorFromString(@"setPlayerLayer:"))) {
        %init(HeaderRetakeTake, ASVideoNode = videoNodeClass);
    }
    if (richMediaHeaderClass) %init(HeaderRetakeRichMediaHeader, RichMediaHeaderCellNode = richMediaHeaderClass);
    if (commentsHeaderClass) %init(HeaderRetakeCommentsHeader, CommentsHeaderCellNode = commentsHeaderClass);
    if (sCommentsViewControllerClass) {
        %init(HeaderRetakeCommentsScreen, CommentsViewController = sCommentsViewControllerClass);
    }

    ApolloLog(@"[VideoSwipeFix] ctor: hooks initialized (header re-take: node=%d videoNode=%d mediaHeader=%d commentsHeader=%d comments=%d)",
              sRichMediaNodeClass != nil, videoNodeClass != nil, richMediaHeaderClass != nil,
              commentsHeaderClass != nil, sCommentsViewControllerClass != nil);
}
