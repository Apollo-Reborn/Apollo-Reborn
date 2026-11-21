#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
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
- (id)currentItem;
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
- (void)videoNode:(id)videoNode willChangePlayerState:(NSInteger)fromState toState:(NSInteger)toState;
@end

#if APOLLO_SIM_BUILD
static void ApolloVideoTimingRecord(NSString *step, CFTimeInterval ms, id node);
#define APOLLO_VIDEO_TIMING_BEGIN CFTimeInterval _apolloTimingStart = CACurrentMediaTime()
#define APOLLO_VIDEO_TIMING_END(step, node) ApolloVideoTimingRecord(step, (CACurrentMediaTime() - _apolloTimingStart) * 1000.0, node)
#else
#define APOLLO_VIDEO_TIMING_BEGIN
#define APOLLO_VIDEO_TIMING_END(step, node)
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
static BOOL sFeedVideoPrewarmCanTryLock = NO;  // the node answers -tryLock/-unlock (checked in %ctor)

static dispatch_queue_t ApolloFeedVideoPrewarmQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Concurrent, not serial (issues #1698/#1714/#1716/#1720/#1721 on
        // upstream): with a serial queue one build that stalls inside
        // AVFoundation — a slow fig player creation, or -constructPlayerItem
        // waiting on the node lock — held every later feed video behind it, so
        // one stuck GIF became "multiple after will be stuck as well" (#1714).
        // Builds are independent (each touches only its own node), so they
        // must not wait on each other. User-initiated because the cell is about
        // to scroll on screen.
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("app.apolloreborn.feed-video-prewarm", attr);
    });
    return queue;
}

// A build that has not handed back a player after this long is treated as
// stalled. A healthy build takes a few ms (see Overview §2); 2.5 s is far past
// that yet short enough that a stuck spinner recovers on its own.
static const NSTimeInterval kApolloFeedVideoPrewarmTimeout = 2.5;
// Builds slower than this are logged in release logs, so in-app reports show
// whether the pre-warm is where feed media stalls.
static const NSTimeInterval kApolloFeedVideoPrewarmSlowLog = 0.5;

// One background build for one node. Identity (not the asset) decides which
// build may attach: a node can leave and re-enter the preload range, get a
// fresh asset, or have a stalled build replaced by a retry, and only the
// newest build's result may be used — late results are dropped, never
// swallowed silently.
@interface ApolloFeedVideoPrewarmBuild : NSObject
@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, copy) NSArray *keys;
@property (nonatomic, assign) NSUInteger attempt;   // 1 = first build, 2 = retry after a stall
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) NSUInteger lockWaits; // timer checks that found the node lock still held
@end
@implementation ApolloFeedVideoPrewarmBuild
@end

// The build currently allowed to attach to this node (main thread only).
static const void *kApolloFeedVideoPrewarmAssetKey = &kApolloFeedVideoPrewarmAssetKey;
// Set while Texture's own -prepareToPlayAsset:withKeys: is re-run for a node
// whose background build produced no player or stalled twice (the hook lets
// that call straight through to %orig).
static const void *kApolloFeedVideoPrewarmBypassKey = &kApolloFeedVideoPrewarmBypassKey;

static void ApolloFeedVideoPrewarmRunStockPath(ASVideoNode *node, AVAsset *asset, NSArray *keys) {
    objc_setAssociatedObject(node, kApolloFeedVideoPrewarmBypassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [node prepareToPlayAsset:asset withKeys:keys];
    objc_setAssociatedObject(node, kApolloFeedVideoPrewarmBypassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloFeedVideoPrewarmStart(ASVideoNode *node, AVAsset *asset, NSArray *keys, NSUInteger attempt);
static void ApolloFeedVideoPrewarmArmTimeout(ASVideoNode *node, ApolloFeedVideoPrewarmBuild *build);

// Main thread. NO when the node lock is held right now. Texture builds the
// player item under that lock, so if a stalled build is stuck inside
// -constructPlayerItem holding it, running the stock path here would block the
// main thread until the build lets go (forever, if it never does). Without
// -tryLock we can't tell, so keep the stock fallback.
static BOOL ApolloFeedVideoPrewarmNodeLockIsFree(ASVideoNode *node) {
    if (!sFeedVideoPrewarmCanTryLock) return YES;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(node, @selector(tryLock))) return NO;
    ((void (*)(id, SEL))objc_msgSend)(node, @selector(unlock));
    return YES;
}

// Main thread: the build's timer fired. If it is still the node's current
// build it never came back — supersede it so its late result is dropped, then
// retry once off the main thread (a retry can't freeze the UI even if the node
// lock is still held). A second stall hands the node to Texture's stock path,
// i.e. Apollo's behaviour with Smoother Video Scrolling off — but only once
// the node lock is free; until then the retry stays current (it is waiting on
// that lock off the main thread and attaches as soon as it gets it) and the
// timer checks again, so a stuck lock leaves a spinner, never a frozen app.
static void ApolloFeedVideoPrewarmCheckTimeout(ASVideoNode *node, ApolloFeedVideoPrewarmBuild *build) {
    if (!node || objc_getAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey) != build) return; // attached or superseded
    if (ApolloObjectIvar(node, "_player")) { // Texture attached a player another way
        objc_setAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (build.attempt >= 2 && !ApolloFeedVideoPrewarmNodeLockIsFree(node)) {
        build.lockWaits += 1;
        if (build.lockWaits == 1 || build.lockWaits % 12 == 0) {
            ApolloLog(@"[FeedVideoScrolling] pre-warm retry stalled %.1fs and the node lock is still held node=%p — waiting off the main thread (check %lu)",
                      CACurrentMediaTime() - build.startTime, node, (unsigned long)build.lockWaits);
        }
        ApolloFeedVideoPrewarmArmTimeout(node, build);
        return;
    }
    objc_setAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (build.attempt < 2) {
        ApolloLog(@"[FeedVideoScrolling] pre-warm stalled %.1fs node=%p — retrying in the background",
                  CACurrentMediaTime() - build.startTime, node);
        ApolloFeedVideoPrewarmStart(node, build.asset, build.keys, build.attempt + 1);
        return;
    }
    ApolloLog(@"[FeedVideoScrolling] pre-warm retry also stalled %.1fs node=%p — falling back to Texture's path",
              CACurrentMediaTime() - build.startTime, node);
    ApolloFeedVideoPrewarmRunStockPath(node, build.asset, build.keys);
}

static void ApolloFeedVideoPrewarmArmTimeout(ASVideoNode *node, ApolloFeedVideoPrewarmBuild *build) {
    __weak ASVideoNode *weakNode = node;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloFeedVideoPrewarmTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloFeedVideoPrewarmCheckTimeout(weakNode, build);
    });
}

static void ApolloFeedVideoPrewarmStart(ASVideoNode *node, AVAsset *asset, NSArray *keys, NSUInteger attempt) {
    ApolloFeedVideoPrewarmBuild *build = [ApolloFeedVideoPrewarmBuild new];
    build.asset = asset;
    build.keys = keys;
    build.attempt = attempt;
    build.startTime = CACurrentMediaTime();
    objc_setAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey, build, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloFeedVideoPrewarmArmTimeout(node, build);

    __weak ASVideoNode *weakNode = node;

    dispatch_async(ApolloFeedVideoPrewarmQueue(), ^{
        ASVideoNode *bgNode = weakNode;
        if (!bgNode) return;
        // Texture's item factory: locks the node, reads _assetURL/_asset/
        // _videoComposition/_audioMix, touches no UI. Building the item from a
        // URL creates its own AVURLAsset and stores it into _asset — the same
        // thing that happens on the stock path, just not on the main thread.
        AVPlayerItem *item = [bgNode constructPlayerItem];
        bgNode = nil; // don't keep the node alive across the AVPlayer build
        AVAsset *itemAsset = item.asset;
        AVPlayer *player = item ? [AVPlayer playerWithPlayerItem:item] : nil;
        CFTimeInterval buildSeconds = CACurrentMediaTime() - build.startTime;
        dispatch_async(dispatch_get_main_queue(), ^{
            ASVideoNode *strongNode = weakNode;
            if (!strongNode) return;
            if (buildSeconds >= kApolloFeedVideoPrewarmSlowLog) {
                ApolloLog(@"[FeedVideoScrolling] slow pre-warm build %.2fs node=%p attempt=%lu player=%d",
                          buildSeconds, strongNode, (unsigned long)build.attempt, player != nil);
            }
            if (objc_getAssociatedObject(strongNode, kApolloFeedVideoPrewarmAssetKey) != build) {
                // A newer build (new asset, or the retry after a stall) owns
                // this node now; this result is stale.
                if (buildSeconds >= kApolloFeedVideoPrewarmTimeout) {
                    ApolloLog(@"[FeedVideoScrolling] late pre-warm result dropped after %.2fs node=%p attempt=%lu",
                              buildSeconds, strongNode, (unsigned long)build.attempt);
                } else {
                    os_log_debug(ApolloFixLog(), "[ApolloFix] [FeedVideoScrolling] pre-warmed player dropped (superseded) node=%p", strongNode);
                }
                return;
            }
            objc_setAssociatedObject(strongNode, kApolloFeedVideoPrewarmAssetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            id currentAsset = [strongNode asset];
            BOOL assetMatches = currentAsset == asset || (itemAsset && currentAsset == itemAsset);
            if (!assetMatches || ApolloObjectIvar(strongNode, "_player")) {
                // The node moved on (left the preload range, got a different
                // asset, or Texture attached a player another way): drop the
                // warm one; the next preload builds again.
                os_log_debug(ApolloFixLog(), "[ApolloFix] [FeedVideoScrolling] pre-warmed player dropped node=%p player=%p match=%d",
                               strongNode, player, assetMatches);
                return;
            }
            if (!player) {
                // Nothing to attach but the node still wants this asset: run
                // Texture's own path so it reports/handles the failure exactly
                // as it would have without us.
                ApolloLog(@"[FeedVideoScrolling] pre-warm produced no player node=%p — falling back to Texture's path", strongNode);
                ApolloFeedVideoPrewarmRunStockPath(strongNode, asset, keys);
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
            if (build.attempt > 1) {
                ApolloLog(@"[FeedVideoScrolling] pre-warm retry attached a player after a stall node=%p", strongNode);
            }
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                ApolloLog(@"[FeedVideoScrolling] first pre-warmed player attached (built off the main thread) node=%p", strongNode);
            });
        });
    });
}

// Returns YES when the player construction was taken over (the caller must
// not run Texture's -prepareToPlayAsset:withKeys:); NO hands the call back to
// Texture untouched — every failure or "already has a player" case goes down
// the stock path so its error reporting stays exactly as before.
static BOOL ApolloFeedVideoPrewarmPlayer(ASVideoNode *node, AVAsset *asset, NSArray *keys) {
    if (!sFeedVideoPrewarmAvailable || !asset) return NO;
    // Texture reads the _player ivar here (an existing player takes the
    // replaceCurrentItemWithPlayerItem: path) — same test.
    if (ApolloObjectIvar(node, "_player")) return NO;
    ApolloFeedVideoPrewarmBuild *inFlight = objc_getAssociatedObject(node, kApolloFeedVideoPrewarmAssetKey);
    if (inFlight.asset == asset) return YES; // in flight; its timer recovers it if it stalls
    // Texture's own preflight, so a failed key or an unplayable asset still
    // reaches its delegate error path (videoNode:didFailToLoadValueForKey:...).
    for (NSString *key in keys) {
        NSError *error = nil;
        if ([asset statusOfValueForKey:key error:&error] != AVKeyValueStatusLoaded) return NO;
    }
    if (![asset isPlayable]) return NO;

    ApolloFeedVideoPrewarmStart(node, asset, keys, 1);
    return YES;
}

// =============================================================================
// MARK: - Video cells draw asynchronously
// =============================================================================

// YES for a feed cell whose media (or crosspost media) is an inline video.
static BOOL ApolloFeedCellHasInlineVideo(id cell) {
    id richMediaNode = ApolloObjectIvar(cell, "richMediaNode");
    if (richMediaNode && ApolloObjectIvar(richMediaNode, "videoNode")) return YES;
    id crosspostNode = ApolloObjectIvar(cell, "crosspostNode");
    id crosspostMedia = crosspostNode ? ApolloObjectIvar(crosspostNode, "richMediaNode") : nil;
    return crosspostMedia && ApolloObjectIvar(crosspostMedia, "videoNode") != nil;
}

// =============================================================================
// MARK: - Hooks
// =============================================================================

// Starts loading the video tracks' sizes as soon as a player is attached, so
// Apollo's RichMediaNode layout (which also reads -naturalSize, on the main
// thread when Texture lays out there) finds them loaded instead of loading
// them synchronously. Never blocks: everything here is asynchronous.
static void ApolloFeedVideoPreloadVideoSizes(AVAsset *asset) {
    if (!asset) return;
    void (^loadSizes)(NSArray<AVAssetTrack *> *) = ^(NSArray<AVAssetTrack *> *tracks) {
        for (AVAssetTrack *track in tracks) {
            if ([track statusOfValueForKey:@"naturalSize" error:NULL] == AVKeyValueStatusLoaded) continue;
            [track loadValuesAsynchronouslyForKeys:@[@"naturalSize"] completionHandler:^{}];
        }
    };
    if (@available(iOS 15.0, *)) {
        [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
            if (tracks.count) loadSizes(tracks);
        }];
    } else {
        [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
            if ([asset statusOfValueForKey:@"tracks" error:NULL] != AVKeyValueStatusLoaded) return;
            loadSizes([asset tracksWithMediaType:AVMediaTypeVideo]);
        }];
    }
}

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
        os_log_debug(ApolloFixLog(), "[ApolloFix] [FeedVideoScrolling] leaving non-default timescale %d on %{public}@",
                       timescale, [self class]);
    }
    ApolloFeedVideoPreloadVideoSizes(player.currentItem.asset);
    %orig;
}

- (void)prepareToPlayAsset:(id)asset withKeys:(id)keys {
    if (sFeedVideoScrollSmoothing
        && !objc_getAssociatedObject(self, kApolloFeedVideoPrewarmBypassKey)
        && ApolloFeedVideoPrewarmPlayer(self, asset, keys)) {
        return;
    }
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"ASVideoNode.prepareToPlayAsset", self);
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
// MARK: - Video size without blocking the main thread
// =============================================================================
//
// Apollo's -[RichMediaNode videoNode:willChangePlayerState:toState:] walks the
// player item's tracks, reads the video track's -naturalSize, compares it with
// the node's bounds and then sets the player layer's videoGravity and un-hides
// it. When that track's size hasn't loaded yet the read loads it synchronously
// on the main thread. AVFoundation reports it ("[AVFoundation Hang Risk] Asset
// track property "naturalSize" accessed synchronously before being loaded"),
// and the wait also holds up every other asset's track property loads, so on a
// slow host one feed video can freeze scrolling and leave the next ones
// spinning (#1698/#1714/#1720/#1721 on upstream). Seen 84 times in one
// 5-minute feed session on an iPhone 15 Pro (build 374).
//
// When a video track's size isn't loaded, load it asynchronously first and
// replay the delegate call on the main thread once it is. Only a node's newest
// call is replayed, and only while the node still shows the same item. Calls
// whose size is already loaded run untouched.

static const void *kApolloRichMediaSizeGenerationKey = &kApolloRichMediaSizeGenerationKey;
static BOOL sApolloRichMediaSizeReplaying = NO; // main thread only

static NSArray<AVAssetTrack *> *ApolloRichMediaUnloadedVideoTracks(AVPlayerItem *item) {
    NSMutableArray<AVAssetTrack *> *pending = nil;
    for (AVPlayerItemTrack *itemTrack in item.tracks) {
        AVAssetTrack *track = itemTrack.assetTrack;
        if (![track.mediaType isEqualToString:AVMediaTypeVideo]) continue;
        if ([track statusOfValueForKey:@"naturalSize" error:NULL] == AVKeyValueStatusLoaded) continue;
        if (!pending) pending = [NSMutableArray array];
        [pending addObject:track];
    }
    return pending;
}

static NSUInteger ApolloRichMediaBumpSizeGeneration(id node) {
    NSUInteger generation = [objc_getAssociatedObject(node, kApolloRichMediaSizeGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(node, kApolloRichMediaSizeGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return generation;
}

%group FeedVideoNaturalSize

%hook RichMediaNode

- (void)videoNode:(ASVideoNode *)videoNode willChangePlayerState:(NSInteger)fromState toState:(NSInteger)toState {
    if (sApolloRichMediaSizeReplaying || !videoNode) { %orig; return; }
    NSUInteger generation = ApolloRichMediaBumpSizeGeneration(self);
    AVPlayerItem *item = [videoNode currentItem];
    NSArray<AVAssetTrack *> *pending = item ? ApolloRichMediaUnloadedVideoTracks(item) : nil;
    if (pending.count == 0) { %orig; return; }

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ApolloLog(@"[FeedVideoScrolling] video size not loaded at a player state change — loading it off the main thread before Apollo reads it");
    });
    CFTimeInterval start = CACurrentMediaTime();
    __weak id weakSelf = self;
    __weak ASVideoNode *weakVideoNode = videoNode;
    __weak AVPlayerItem *weakItem = item;
    dispatch_group_t group = dispatch_group_create();
    for (AVAssetTrack *track in pending) {
        dispatch_group_enter(group);
        [track loadValuesAsynchronouslyForKeys:@[@"naturalSize"] completionHandler:^{ dispatch_group_leave(group); }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        id strongSelf = weakSelf;
        ASVideoNode *strongVideoNode = weakVideoNode;
        AVPlayerItem *strongItem = weakItem;
        if (!strongSelf || !strongVideoNode || !strongItem) return;
        if ([objc_getAssociatedObject(strongSelf, kApolloRichMediaSizeGenerationKey) unsignedIntegerValue] != generation) return; // a newer state change ran
        if ([strongVideoNode currentItem] != strongItem) return; // the node moved on to another item
        CFTimeInterval seconds = CACurrentMediaTime() - start;
        if (seconds >= kApolloFeedVideoPrewarmSlowLog) {
            ApolloLog(@"[FeedVideoScrolling] video size took %.2fs to load node=%p (main thread stayed free)", seconds, strongVideoNode);
        }
        sApolloRichMediaSizeReplaying = YES;
        [strongSelf videoNode:strongVideoNode willChangePlayerState:fromState toState:toState];
        sApolloRichMediaSizeReplaying = NO;
    });
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
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"ASVideoNode.play", self);
}

- (void)pause {
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"ASVideoNode.pause", self);
}

- (id)constructPlayerNode {
    CFTimeInterval t0 = CACurrentMediaTime();
    id r = %orig;
    ApolloVideoTimingRecord(@"ASVideoNode.constructPlayerNode", (CACurrentMediaTime() - t0) * 1000.0, self);
    return r;
}

- (void)didEnterPreloadState {
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"ASVideoNode.didEnterPreloadState", self);
}

- (void)didExitPreloadState {
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"ASVideoNode.didExitPreloadState", self);
}

- (void)didEnterVisibleState {
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"ASVideoNode.didEnterVisibleState", self);
}

%end

%hook RichMediaNodeTiming

- (void)didEnterPreloadState {
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"RichMediaNode.didEnterPreloadState", self);
}

- (void)didExitPreloadState {
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"RichMediaNode.didExitPreloadState", self);
}

%end

%hook LargePostCellNodeTiming

- (void)didEnterVisibleState {
    // Split by cell kind so the video-cell policy can be read off the summary.
    NSString *step = ApolloFeedCellHasInlineVideo(self)
        ? @"LargePostCellNode(video).didEnterVisibleState"
        : @"LargePostCellNode(other).didEnterVisibleState";
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(step, self);
}

- (void)didEnterDisplayState {
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"LargePostCellNode.didEnterDisplayState", self);
}

- (void)didEnterPreloadState {
    APOLLO_VIDEO_TIMING_BEGIN;
    %orig;
    APOLLO_VIDEO_TIMING_END(@"LargePostCellNode.didEnterPreloadState", self);
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
                  (__bridge void *)videoNodeClass);
        return;
    }
    sFeedVideoPrewarmAvailable =
        [videoNodeClass instancesRespondToSelector:@selector(prepareToPlayAsset:withKeys:)]
        && [videoNodeClass instancesRespondToSelector:@selector(constructPlayerItem)]
        && [videoNodeClass instancesRespondToSelector:@selector(setCurrentItem:)]
        && [videoNodeClass instancesRespondToSelector:@selector(setPlayer:)]
        && [videoNodeClass instancesRespondToSelector:@selector(generatePlaceholderImage)]
        && class_getInstanceVariable(videoNodeClass, "_player") != NULL;
    sFeedVideoPrewarmCanTryLock = [videoNodeClass instancesRespondToSelector:@selector(tryLock)]
        && [videoNodeClass instancesRespondToSelector:@selector(unlock)];
    %init(FeedVideoObserver, ASVideoNode = videoNodeClass);
    ApolloLog(@"[FeedVideoScrolling] hook installed: ASVideoNode addPlayerObservers: (timescale %d → %d), prepareToPlayAsset:withKeys: (pre-warm %@, lock check %@, smoothing %@)",
              kTextureDefaultPeriodicTimeObserverTimescale, kApolloInlineVideoTimeObserverTimescale,
              sFeedVideoPrewarmAvailable ? @"available" : @"UNAVAILABLE — stock path",
              sFeedVideoPrewarmCanTryLock ? @"on" : @"off",
              sFeedVideoScrollSmoothing ? @"on" : @"off");

    Class richMediaClass = objc_getClass("_TtC6Apollo13RichMediaNode");
    if (richMediaClass
        && [richMediaClass instancesRespondToSelector:@selector(videoNode:willChangePlayerState:toState:)]
        && [videoNodeClass instancesRespondToSelector:@selector(currentItem)]) {
        %init(FeedVideoNaturalSize, RichMediaNode = richMediaClass);
        ApolloLog(@"[FeedVideoScrolling] hook installed: RichMediaNode videoNode:willChangePlayerState:toState: (video size loads off the main thread)");
    } else {
        ApolloLog(@"[FeedVideoScrolling] ctor: RichMediaNode=%p lacks videoNode:willChangePlayerState:toState: — video size check stays synchronous", (__bridge void *)richMediaClass);
    }

    Class cellClass = objc_getClass("_TtC6Apollo17LargePostCellNode");
    if (cellClass && [cellClass instancesRespondToSelector:@selector(neverShowPlaceholders)]) {
        %init(FeedVideoCells, LargePostCellNode = cellClass);
        ApolloLog(@"[FeedVideoScrolling] hook installed: LargePostCellNode neverShowPlaceholders (video cells draw asynchronously while smoothing is on)");
    } else {
        ApolloLog(@"[FeedVideoScrolling] ctor: LargePostCellNode=%p lacks neverShowPlaceholders — cells keep the stock display wait", (__bridge void *)cellClass);
    }

#if APOLLO_SIM_BUILD
    %init(FeedVideoScrollingSim, ASVideoNode = videoNodeClass,
          RichMediaNodeTiming = objc_getClass("_TtC6Apollo13RichMediaNode"),
          LargePostCellNodeTiming = cellClass);
#endif
}
