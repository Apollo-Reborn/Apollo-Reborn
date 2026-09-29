#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Feed video scrolling (issue #1158, "Scrolling choppy through video posts").
//
// Every inline video (feed cell and comments header) is an ASVideoNode from
// Apollo's AsyncDisplayKit build. Profiling a video-heavy subreddit scroll on
// the simulator (`sample` on the main thread + the per-step timing hooks in the
// sim-only section below) found three main-thread costs that only video posts
// pay, in the order they hit a cell:
//
//  1. Texture's player time observer (always on). When Texture attaches a
//     player it installs an AVPlayer periodic time observer with the interval
//     CMTimeMake(1, _periodicTimeObserverTimescale); Texture's default
//     timescale is 10000, a 0.1 ms interval. AVFoundation clamps that to its
//     floor and delivers the block 200 times a second per PLAYING video
//     (measured 200.0 ticks/s per node on iOS 26.5 and iOS 27; this is not
//     display-bound, phones get the same). Each tick runs
//     -[RichMediaNode videoNode:didPlayToTimeInterval:] (duration read, URL
//     bridging, a per-URL 1/60 s throttle dictionary, a notification post and
//     the VideoGIFProgressView geometry update) and AVFoundation re-arms its
//     timebase timer. With two playing videos on screen that chain was 57% of
//     all main-thread work (392 of 684 busy samples per 15 s). Fix: lower the
//     timescale to 30 right before Texture installs the observer (30.0 ticks/s
//     measured; the overlay is a thin progress bar, 30 updates/s look the
//     same). Two-video scene: 392 → 175 chain samples, 684 → 434 busy.
//
//  2. Player creation on the main thread ("Smoother Video Scrolling"). When
//     the asset's keys finish loading, Texture's -prepareToPlayAsset:withKeys:
//     builds the AVPlayerItem and the AVPlayer on the main thread; the AVPlayer
//     init alone is a synchronous trip through AVFoundation's serialized
//     scheduler (fig player creation). Measured 4–14 ms per video, 68–73 ms
//     per 14-flick scroll (45 players). Fix: do the same two constructions on
//     a background queue and hand the finished pair to Texture's own setters
//     on the main thread (6–7 ms per scroll, −90%; playback verified: same
//     30 ticks/s, same play → first-frame latency).
//
//  3. The synchronous display wait when a video cell scrolls on screen
//     ("Smoother Video Scrolling"). Apollo sets neverShowPlaceholders on its
//     cells (setNeverShowPlaceholders: call sites in the binary), so
//     -[ASCellNode didEnterVisibleState] blocks the main thread in
//     -recursivelyEnsureDisplaySynchronously: until the cell's async drawing
//     (for a video post: the full-width poster) has landed. Measured per cell:
//     up to 42 ms, 98–227 ms per scroll, the largest single stalls in the
//     profile and 2–3× what image/text cells pay. Fix: report NO from the
//     flag for feed cells that carry an inline video, so those cells appear as
//     their nodes finish drawing (Texture's stock behaviour; the poster is
//     covered by the playing video within a few frames anyway). Frame strips
//     of the scripted flick showed no visible blanking on the sim; frozen
//     frames in the recording fell from 22% to 17%.
//
// (2) and (3) are gated by the "Smoother Video Scrolling" toggle (default ON,
// Settings > Posts & Feeds > Feed). OFF restores Apollo's exact stock paths: Texture
// builds the player itself and the cell keeps its synchronous display wait.
// (1) has no visual effect and is always on.
//
// Verified in Apollo's AsyncDisplayKit (Hopper/otool): -[ASVideoNode
// addPlayerObservers:] → ldrsw _OBJC_IVAR_$_ASVideoNode._periodicTimeObserverTimescale
// → CMTimeMake(1, ts) → addPeriodicTimeObserverForInterval:queue:usingBlock:,
// the block calls -[ASVideoNode periodicTimeObserver:] → delegate
// videoNode:didPlayToTimeInterval:. -setPeriodicTimeObserverTimescale: is a
// plain ivar store. -prepareToPlayAsset:withKeys: = statusOfValueForKey: for
// each key (failure → delegate videoNode:didFailToLoadValueForKey:asset:error:),
// isPlayable, constructPlayerItem, setCurrentItem:, then
// replaceCurrentItemWithPlayerItem: on an existing _player or playerWithPlayerItem:
// + setPlayer:, delegate videoNode:didSetCurrentItem:, and
// generatePlaceholderImage when image == nil && URL == nil. -constructPlayerItem
// locks the node and builds the item from _assetURL (storing the item's asset
// back into _asset) or from _asset; it touches no UI. -[ASCellNode
// didEnterVisibleState] calls the neverShowPlaceholders getter and, when YES,
// recursivelyEnsureDisplaySynchronously:YES. Nothing else in the tweak hooks
// these selectors (PiP hooks -[ASVideoNode didPlayToEnd:]; the vote-flicker
// module sets neverShowPlaceholders on comment cells and PostInfoNode subtrees,
// never on LargePostCellNode).
//
// =============================================================================

// Texture's default (ASVideoNode -initWithCache:downloader: stores 10000).
static const int32_t kTextureDefaultPeriodicTimeObserverTimescale = 10000;
// 30 ticks per second: smooth for the inline progress overlay, a fraction of
// the 200 Hz the default produces.
static const int32_t kApolloInlineVideoTimeObserverTimescale = 30;

@interface ASVideoNode : NSObject
- (int32_t)periodicTimeObserverTimescale;
- (void)setPeriodicTimeObserverTimescale:(int32_t)timescale;
- (id)asset;
- (id)player;
- (id)constructPlayerItem;
- (void)setCurrentItem:(id)item;
- (void)setPlayer:(id)player;
- (id)delegate;
- (id)image;
- (id)URL;
- (void)generatePlaceholderImage;
- (void)prepareToPlayAsset:(id)asset withKeys:(id)keys;
@end

@protocol ApolloVideoNodeDelegateProbe <NSObject>
@optional
- (void)videoNode:(id)videoNode didSetCurrentItem:(id)item;
@end

#if APOLLO_SIM_BUILD
static void ApolloVideoTimingRecord(NSString *step, CFTimeInterval ms, id node);
#define APOLLO_VIDEO_TIMED(step, node, call) do { \
    CFTimeInterval _t0 = CACurrentMediaTime(); \
    call; \
    ApolloVideoTimingRecord(step, (CACurrentMediaTime() - _t0) * 1000.0, node); \
} while (0)
#else
#define APOLLO_VIDEO_TIMED(step, node, call) do { call; } while (0)
#endif

// The timescale to install. Simulator builds can override it from the launch
// environment (SIMCTL_CHILD_APOLLOFIX_INLINE_VIDEO_TIMESCALE=10000 restores
// Texture's default for A/B profiling; any other positive value is used as-is).
// Device builds always use the constant.
static int32_t ApolloInlineVideoTimeObserverTimescale(void) {
#if APOLLO_SIM_BUILD
    static int32_t override = -1;
    if (override < 0) {
        NSString *env = NSProcessInfo.processInfo.environment[@"APOLLOFIX_INLINE_VIDEO_TIMESCALE"];
        override = env.intValue > 0 ? env.intValue : 0;
        if (override) ApolloLog(@"[FeedVideoScrolling] sim override: timescale %d", override);
    }
    if (override) return override;
#endif
    return kApolloInlineVideoTimeObserverTimescale;
}

// =============================================================================
// MARK: - Player pre-warm (off the main thread)
// =============================================================================

static BOOL sFeedVideoPrewarmAvailable = NO;   // every selector we rely on exists (checked in %ctor)

static dispatch_queue_t ApolloFeedVideoPrewarmQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Serial: preloads arrive in bursts while flicking, and one construction
        // at a time is plenty (each is a few ms); user-initiated because the
        // cell is about to scroll on screen.
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("app.apolloreborn.feed-video-prewarm", attr);
    });
    return queue;
}

static id ApolloFeedVideoIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

// The asset whose player is being built for this node (main thread only).
// Keyed by asset, not a flag: a node can leave and re-enter the preload range
// while a build is in flight, which gives it a fresh asset; the build for the
// old one must then be dropped and a new one started, not swallowed.
static const void *kApolloFeedVideoPrewarmAssetKey = &kApolloFeedVideoPrewarmAssetKey;
// Set while the completion re-runs Texture's own -prepareToPlayAsset:withKeys:
// for a node whose background build produced no player (the hook lets that
// call straight through to %orig).
static const void *kApolloFeedVideoPrewarmBypassKey = &kApolloFeedVideoPrewarmBypassKey;

// Returns YES when the player construction was taken over (the caller must
// not run Texture's -prepareToPlayAsset:withKeys:); NO hands the call back to
// Texture untouched — every failure or "already has a player" case goes down
// the stock path so its error reporting stays exactly as before.
static BOOL ApolloFeedVideoPrewarmPlayer(ASVideoNode *node, AVAsset *asset, NSArray *keys) {
    if (!sFeedVideoPrewarmAvailable || !asset) return NO;
    // Texture reads the _player ivar here (an existing player takes the
    // replaceCurrentItemWithPlayerItem: path) — same test.
    if (ApolloFeedVideoIvar(node, "_player")) return NO;
    if (objc_getAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey) == asset) return YES; // in flight
    // Texture's own preflight, so a failed key or an unplayable asset still
    // reaches its delegate error path (videoNode:didFailToLoadValueForKey:...).
    for (NSString *key in keys) {
        NSError *error = nil;
        if ([asset statusOfValueForKey:key error:&error] != AVKeyValueStatusLoaded) return NO;
    }
    if (![asset isPlayable]) return NO;

    objc_setAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey, asset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak ASVideoNode *weakNode = node;
    dispatch_async(ApolloFeedVideoPrewarmQueue(), ^{
        ASVideoNode *bgNode = weakNode;
        if (!bgNode) return;
        // Texture's item factory: locks the node, reads _assetURL/_asset/
        // _videoComposition/_audioMix, touches no UI. Building the item from a
        // URL creates its own AVURLAsset and stores it into _asset — the same
        // thing that happens on the stock path, just not on the main thread.
        AVPlayerItem *item = [bgNode constructPlayerItem];
        AVAsset *itemAsset = item.asset;
        AVPlayer *player = item ? [AVPlayer playerWithPlayerItem:item] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            ASVideoNode *strongNode = weakNode;
            if (!strongNode) return;
            if (objc_getAssociatedObject(strongNode, kApolloFeedVideoPrewarmAssetKey) != asset) {
                // A newer asset started its own build; this one is stale.
                ApolloLogDebug(@"[FeedVideoScrolling] pre-warmed player dropped (superseded) node=%p", strongNode);
                return;
            }
            objc_setAssociatedObject(strongNode, kApolloFeedVideoPrewarmAssetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id currentAsset = [strongNode asset];
            BOOL assetMatches = currentAsset == asset || (itemAsset && currentAsset == itemAsset);
            if (!assetMatches || ApolloFeedVideoIvar(strongNode, "_player")) {
                // The node moved on (left the preload range, got a different
                // asset, or Texture attached a player another way): drop the
                // warm one; the next preload builds again.
                ApolloLogDebug(@"[FeedVideoScrolling] pre-warmed player dropped node=%p player=%p match=%d",
                               strongNode, player, assetMatches);
                return;
            }
            if (!player) {
                // Nothing to attach but the node still wants this asset: run
                // Texture's own path so it reports/handles the failure exactly
                // as it would have without us.
                ApolloLog(@"[FeedVideoScrolling] pre-warm produced no player node=%p — falling back to Texture's path", strongNode);
                objc_setAssociatedObject(strongNode, kApolloFeedVideoPrewarmBypassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [strongNode prepareToPlayAsset:asset withKeys:keys];
                objc_setAssociatedObject(strongNode, kApolloFeedVideoPrewarmBypassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return;
            }
            // The tail of Texture's -prepareToPlayAsset:withKeys:, through its
            // own setters (item + player observers, the fork's shared-layer
            // wiring in setPlayer:), then the delegate and placeholder steps.
            CFTimeInterval t0 = CACurrentMediaTime();
            [strongNode setCurrentItem:item];
            [strongNode setPlayer:player];
            id<ApolloVideoNodeDelegateProbe> delegate = [strongNode delegate];
            if ([delegate respondsToSelector:@selector(videoNode:didSetCurrentItem:)]) {
                [delegate videoNode:strongNode didSetCurrentItem:item];
            }
            if ([strongNode image] == nil && [strongNode URL] == nil) {
                [strongNode generatePlaceholderImage];
            }
#if APOLLO_SIM_BUILD
            ApolloVideoTimingRecord(@"ASVideoNode.prewarmAttach(main)", (CACurrentMediaTime() - t0) * 1000.0, strongNode);
#else
            (void)t0;
#endif
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                ApolloLog(@"[FeedVideoScrolling] first pre-warmed player attached (built off the main thread) node=%p", strongNode);
            });
        });
    });
    return YES;
}

// =============================================================================
// MARK: - Video cells draw asynchronously
// =============================================================================

// YES for a feed cell whose media (or crosspost media) is an inline video.
static BOOL ApolloFeedCellHasInlineVideo(id cell) {
    id richMediaNode = ApolloFeedVideoIvar(cell, "richMediaNode");
    if (richMediaNode && ApolloFeedVideoIvar(richMediaNode, "videoNode")) return YES;
    id crosspostNode = ApolloFeedVideoIvar(cell, "crosspostNode");
    id crosspostMedia = crosspostNode ? ApolloFeedVideoIvar(crosspostNode, "richMediaNode") : nil;
    return crosspostMedia && ApolloFeedVideoIvar(crosspostMedia, "videoNode") != nil;
}

// =============================================================================
// MARK: - Hooks
// =============================================================================

%group FeedVideoObserver

%hook ASVideoNode

- (void)addPlayerObservers:(AVPlayer *)player {
    // Texture calls this from -setPlayer: (main thread, node lock held — the
    // setter is a plain ivar store, so no re-entrancy concern) right before it
    // reads the timescale for the periodic observer's interval.
    int32_t timescale = [self periodicTimeObserverTimescale];
    int32_t wanted = ApolloInlineVideoTimeObserverTimescale();
    if (timescale == kTextureDefaultPeriodicTimeObserverTimescale && wanted != timescale) {
        [self setPeriodicTimeObserverTimescale:wanted];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            ApolloLog(@"[FeedVideoScrolling] periodic time observer interval 1/%d s → 1/%d s (first player attached to %@)",
                      kTextureDefaultPeriodicTimeObserverTimescale, wanted, [self class]);
        });
    } else if (timescale != wanted) {
        // Not Texture's default: the app chose a rate for this node — keep it.
        ApolloLogDebug(@"[FeedVideoScrolling] leaving non-default timescale %d on %@",
                       timescale, [self class]);
    }
    %orig;
}

- (void)prepareToPlayAsset:(id)asset withKeys:(id)keys {
    if (sFeedVideoScrollSmoothing
        && !objc_getAssociatedObject(self, kApolloFeedVideoPrewarmBypassKey)
        && ApolloFeedVideoPrewarmPlayer(self, asset, keys)) {
        return;
    }
    APOLLO_VIDEO_TIMED(@"ASVideoNode.prepareToPlayAsset", self, %orig);
}

%end

%end

%group FeedVideoCells

%hook LargePostCellNode

// Read by -[ASCellNode didEnterVisibleState] to decide whether to block on
// the cell's pending display. Video cells answer NO while Smoother Video
// Scrolling is on; everything else keeps Apollo's answer.
- (BOOL)neverShowPlaceholders {
    if (sFeedVideoScrollSmoothing && ApolloFeedCellHasInlineVideo(self)) return NO;
    return %orig;
}

%end

%end

// =============================================================================
// MARK: - Simulator diagnostics (never compiled into device builds)
// =============================================================================
//
// Tick counter (ticks/s per node every 5 s of playback; 200.0 with Texture's
// default via the env override, 30.0 with the fix), play → first-tick latency
// (40–195 ms on a node's first play, ~12 ms on re-plays, with either
// timescale), what each inline player is configured with, main-thread timing
// of every step of a video cell's life (logged per call ≥ 2 ms plus a 5 s
// summary), and the feed table's Texture range tuning. Its own guarded group,
// with hook and %init both inside the guard (see ApolloSimDebugTap.xm: an
// ungrouped hook here would break the device build).

#if APOLLO_SIM_BUILD
static NSMapTable *ApolloInlineVideoSimStats(void) {
    static NSMapTable *stats = nil;   // node (weak) → mutable dict
    static dispatch_once_t once;
    dispatch_once(&once, ^{ stats = [NSMapTable weakToStrongObjectsMapTable]; });
    return stats;
}

static NSMutableDictionary *ApolloInlineVideoSimEntry(id node) {
    NSMutableDictionary *entry = [ApolloInlineVideoSimStats() objectForKey:node];
    if (!entry) {
        entry = [NSMutableDictionary dictionary];
        [ApolloInlineVideoSimStats() setObject:entry forKey:node];
    }
    return entry;
}

static void ApolloInlineVideoNotePlay(id node) {
    NSMutableDictionary *entry = ApolloInlineVideoSimEntry(node);
    entry[@"playAt"] = @(CFAbsoluteTimeGetCurrent());
    entry[@"firstTickLogged"] = @NO;
    AVPlayer *player = nil;
    id layer = [node respondsToSelector:@selector(playerLayer)] ? [node performSelector:@selector(playerLayer)] : nil;
    if ([layer isKindOfClass:[AVPlayerLayer class]]) player = [(AVPlayerLayer *)layer player];
    if (!player) player = [node player];
    AVPlayerItem *item = player.currentItem;
    AVAsset *asset = item.asset;
    NSURL *url = [asset isKindOfClass:[AVURLAsset class]] ? ((AVURLAsset *)asset).URL : nil;
    ApolloLog(@"[FeedVideoScrolling] play node=%p player=%p item=%p url=%@ peakBitRate=%.0f fwdBuffer=%.1f waitsToMinimizeStalling=%d presentation=%.0fx%.0f livePlayers=%lu",
              node, player, item, url.absoluteString ?: @"(nil)", item.preferredPeakBitRate,
              item.preferredForwardBufferDuration, player.automaticallyWaitsToMinimizeStalling,
              item.presentationSize.width, item.presentationSize.height,
              (unsigned long)ApolloInlineVideoSimStats().count);
}

static void ApolloInlineVideoNoteTick(id node) {
    NSMutableDictionary *entry = ApolloInlineVideoSimEntry(node);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (entry[@"playAt"] && ![entry[@"firstTickLogged"] boolValue]) {
        entry[@"firstTickLogged"] = @YES;
        ApolloLog(@"[FeedVideoScrolling] node=%p first tick %.0f ms after play (timescale %d)",
                  node, (now - [entry[@"playAt"] doubleValue]) * 1000.0,
                  [node periodicTimeObserverTimescale]);
    }
    if (!entry[@"start"]) {
        entry[@"start"] = @(now);
        entry[@"count"] = @0;
        return;
    }
    NSUInteger count = [entry[@"count"] unsignedIntegerValue] + 1;
    CFAbsoluteTime elapsed = now - [entry[@"start"] doubleValue];
    if (elapsed >= 5.0) {
        ApolloLog(@"[FeedVideoScrolling] node=%p %.1f ticks/s over %.1fs (timescale %d)",
                  node, count / elapsed, elapsed, [node periodicTimeObserverTimescale]);
        entry[@"start"] = @(now);
        entry[@"count"] = @0;
    } else {
        entry[@"count"] = @(count);
    }
}

static NSMutableDictionary *ApolloVideoTimingStats(void) {
    static NSMutableDictionary *stats = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ stats = [NSMutableDictionary dictionary]; });
    return stats;
}

static void ApolloVideoTimingRecord(NSString *step, CFTimeInterval ms, id node) {
    if (!NSThread.isMainThread) return;
    NSMutableDictionary *stats = ApolloVideoTimingStats();
    NSMutableDictionary *e = stats[step];
    if (!e) { e = [@{@"n": @0, @"total": @0.0, @"max": @0.0} mutableCopy]; stats[step] = e; }
    e[@"n"] = @([e[@"n"] integerValue] + 1);
    e[@"total"] = @([e[@"total"] doubleValue] + ms);
    if (ms > [e[@"max"] doubleValue]) e[@"max"] = @(ms);
    if (ms >= 2.0) {
        ApolloLog(@"[VideoTiming] %@ %.1f ms node=%p", step, ms, node);
    }
    static CFAbsoluteTime lastSummary = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastSummary == 0) lastSummary = now;
    if (now - lastSummary >= 5.0) {
        lastSummary = now;
        NSMutableString *line = [NSMutableString stringWithString:@"[VideoTiming] 5s summary:"];
        for (NSString *k in [stats.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary *d = stats[k];
            [line appendFormat:@" %@ n=%@ total=%.1fms max=%.1fms |", k, d[@"n"],
             [d[@"total"] doubleValue], [d[@"max"] doubleValue]];
        }
        ApolloLog(@"%@", line);
        [stats removeAllObjects];
    }
}

// Apollo's Texture range tuning (how far ahead of the visible area cells are
// preloaded / displayed), logged once per launch for every ASTableView on
// screen. Stock Texture values were found: scrolling (mode 1) display lead 1.0
// / trail 0.5, preload lead 2.5 / trail 1.5. Raising the display lead to 2.0
// did not reduce the visible-entry stalls (it added main-thread work), which
// is why the fix above changes the wait instead.
typedef struct { CGFloat leadingBufferScreenfuls; CGFloat trailingBufferScreenfuls; } ApolloRangeTuning;
@interface NSObject (ApolloRangeTuningProbe)
- (ApolloRangeTuning)tuningParametersForRangeMode:(NSUInteger)mode rangeType:(NSUInteger)type;
@end
static void ApolloLogRangeTuningInView(UIView *view, NSUInteger depth) {
    if (!view || depth > 40) return;
    if ([NSStringFromClass([view class]) isEqualToString:@"ASTableView"]) {
        NSMutableString *line = [NSMutableString stringWithFormat:@"[VideoTiming] range tuning %@ %p:", [view class], view];
        for (NSUInteger mode = 0; mode < 4; mode++) {
            for (NSUInteger type = 0; type < 2; type++) {
                ApolloRangeTuning t = [(id)view tuningParametersForRangeMode:mode rangeType:type];
                [line appendFormat:@" mode%lu/%@ lead=%.2f trail=%.2f;", (unsigned long)mode,
                 type == 0 ? @"display" : @"preload", t.leadingBufferScreenfuls, t.trailingBufferScreenfuls];
            }
        }
        ApolloLog(@"%@", line);
    }
    for (UIView *sub in view.subviews) ApolloLogRangeTuningInView(sub, depth + 1);
}
static void ApolloLogRangeTuningOnce(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    for (UIWindow *w in ApolloAllWindows()) ApolloLogRangeTuningInView(w, 0);
}

%group FeedVideoScrollingSim

%hook ASVideoNode

- (void)periodicTimeObserver:(CMTime)time {
    ApolloInlineVideoNoteTick(self);
    %orig;
}

- (void)play {
    ApolloInlineVideoNotePlay(self);
    APOLLO_VIDEO_TIMED(@"ASVideoNode.play", self, %orig);
}

- (void)pause {
    APOLLO_VIDEO_TIMED(@"ASVideoNode.pause", self, %orig);
}

- (id)constructPlayerNode {
    CFTimeInterval t0 = CACurrentMediaTime();
    id r = %orig;
    ApolloVideoTimingRecord(@"ASVideoNode.constructPlayerNode", (CACurrentMediaTime() - t0) * 1000.0, self);
    return r;
}

- (void)didEnterPreloadState {
    APOLLO_VIDEO_TIMED(@"ASVideoNode.didEnterPreloadState", self, %orig);
}

- (void)didExitPreloadState {
    APOLLO_VIDEO_TIMED(@"ASVideoNode.didExitPreloadState", self, %orig);
}

- (void)didEnterVisibleState {
    APOLLO_VIDEO_TIMED(@"ASVideoNode.didEnterVisibleState", self, %orig);
}

%end

%hook RichMediaNodeTiming

- (void)didEnterPreloadState {
    APOLLO_VIDEO_TIMED(@"RichMediaNode.didEnterPreloadState", self, %orig);
}

- (void)didExitPreloadState {
    APOLLO_VIDEO_TIMED(@"RichMediaNode.didExitPreloadState", self, %orig);
}

%end

%hook LargePostCellNodeTiming

- (void)didEnterVisibleState {
    // Split by cell kind so the video-cell policy can be read off the summary.
    NSString *step = ApolloFeedCellHasInlineVideo(self)
        ? @"LargePostCellNode(video).didEnterVisibleState"
        : @"LargePostCellNode(other).didEnterVisibleState";
    APOLLO_VIDEO_TIMED(step, self, %orig);
}

- (void)didEnterDisplayState {
    APOLLO_VIDEO_TIMED(@"LargePostCellNode.didEnterDisplayState", self, %orig);
}

- (void)didEnterPreloadState {
    APOLLO_VIDEO_TIMED(@"LargePostCellNode.didEnterPreloadState", self, %orig);
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloLogRangeTuningOnce(); });
}

%end

%end
#endif

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class videoNodeClass = objc_getClass("ASVideoNode");
    BOOL hasObserverHook = videoNodeClass
        && [videoNodeClass instancesRespondToSelector:@selector(addPlayerObservers:)]
        && [videoNodeClass instancesRespondToSelector:@selector(periodicTimeObserverTimescale)]
        && [videoNodeClass instancesRespondToSelector:@selector(setPeriodicTimeObserverTimescale:)];
    if (!hasObserverHook) {
        ApolloLog(@"[FeedVideoScrolling] ctor: ASVideoNode=%p lacks addPlayerObservers:/periodicTimeObserverTimescale — module disabled",
                  (void *)videoNodeClass);
        return;
    }
    sFeedVideoPrewarmAvailable =
        [videoNodeClass instancesRespondToSelector:@selector(prepareToPlayAsset:withKeys:)]
        && [videoNodeClass instancesRespondToSelector:@selector(constructPlayerItem)]
        && [videoNodeClass instancesRespondToSelector:@selector(setCurrentItem:)]
        && [videoNodeClass instancesRespondToSelector:@selector(setPlayer:)]
        && [videoNodeClass instancesRespondToSelector:@selector(generatePlaceholderImage)]
        && class_getInstanceVariable(videoNodeClass, "_player") != NULL;
    %init(FeedVideoObserver, ASVideoNode = videoNodeClass);
    ApolloLog(@"[FeedVideoScrolling] hook installed: ASVideoNode addPlayerObservers: (timescale %d → %d), prepareToPlayAsset:withKeys: (pre-warm %@, smoothing %@)",
              kTextureDefaultPeriodicTimeObserverTimescale, kApolloInlineVideoTimeObserverTimescale,
              sFeedVideoPrewarmAvailable ? @"available" : @"UNAVAILABLE — stock path",
              sFeedVideoScrollSmoothing ? @"on" : @"off");

    Class cellClass = objc_getClass("_TtC6Apollo17LargePostCellNode");
    if (cellClass && [cellClass instancesRespondToSelector:@selector(neverShowPlaceholders)]) {
        %init(FeedVideoCells, LargePostCellNode = cellClass);
        ApolloLog(@"[FeedVideoScrolling] hook installed: LargePostCellNode neverShowPlaceholders (video cells draw asynchronously while smoothing is on)");
    } else {
        ApolloLog(@"[FeedVideoScrolling] ctor: LargePostCellNode=%p lacks neverShowPlaceholders — cells keep the stock display wait", (void *)cellClass);
    }

#if APOLLO_SIM_BUILD
    %init(FeedVideoScrollingSim, ASVideoNode = videoNodeClass,
          RichMediaNodeTiming = objc_getClass("_TtC6Apollo13RichMediaNode"),
          LargePostCellNodeTiming = cellClass);
#endif
}
