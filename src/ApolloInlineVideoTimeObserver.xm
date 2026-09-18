#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Inline video time-observer rate (issue #1158, "Scrolling choppy through video
// posts").
//
// Every inline video (feed cell and comments header) is an ASVideoNode from
// Apollo's AsyncDisplayKit build. When Texture attaches a player it installs an
// AVPlayer periodic time observer (-[ASVideoNode addPlayerObservers:]) with the
// interval CMTimeMake(1, _periodicTimeObserverTimescale), and Texture's default
// timescale is 10000 — a 0.1 ms interval. AVFoundation clamps that to its own
// floor and delivers the block 200 times a second per PLAYING video (measured
// in the simulator with the tick counter below: 200.0 ticks/s per node on both
// iOS 26.5 and iOS 27; this is AVFoundation's minimum interval, not the display
// rate, so a phone gets the same 200 Hz). Each tick runs on the main thread and
// lands in -[RichMediaNode videoNode:didPlayToTimeInterval:], which reads the
// item duration, bridges the post URL, consults a per-URL throttle dictionary,
// builds a notification name + userInfo, posts it, and has the progress overlay
// (VideoGIFProgressView) re-set its image view geometry. AVFoundation then
// re-arms its timebase timer (CMTimebaseSetTimerDispatchSourceNextFireTime →
// CMSyncConvertTime → the audio device clock) for the next fire.
//
// Sampled on the iOS 26.5 simulator with two autoplaying feed videos on screen
// and nothing else happening, that chain (observer block + Apollo's handler +
// the timer re-arm) was 57% of all main-thread work (392 of 684 busy samples
// over 15 s), and it keeps running while the user scrolls a video-heavy
// subreddit — competing with cell layout and display for the 8.3 ms frame
// budget on a 120 Hz phone. Apollo's own handler already throttles the
// notification to 60 Hz, so it never needed the observer faster than that;
// the per-tick work before the throttle (duration/CMTime, URL bridging,
// dictionary lookup) and AVFoundation's re-arm still ran 200 times a second.
//
// Fix: before Texture installs the observer, lower the node's timescale to
// kApolloInlineVideoTimeObserverTimescale (30 → a 33 ms interval, 30 ticks/s,
// measured 30.0). The overlay is a thin progress bar over the video; 30
// updates a second is visually indistinguishable for it, and the same two-video
// scene drops to 175 chain samples (−55%) and 434 busy samples (−37%) on iOS
// 26.5, 201 (−49%) and 538 (−25%) on iOS 27. Only Texture's untouched default
// is overridden — a node whose timescale Apollo set on purpose is left alone
// (Apollo never calls the setter today; the check is a tripwire for future
// binaries). -setPeriodicTimeObserverTimescale: is a plain ivar store in this
// AsyncDisplayKit build (Hopper: no lock, no side effects), and
// -addPlayerObservers: reads the ivar right after the KVO registration, so
// setting it here is exactly the supported "configure before the player is
// attached" path.
//
// Verified in Apollo's AsyncDisplayKit (Hopper): -[ASVideoNode addPlayerObservers:]
// → ldrsw _OBJC_IVAR_$_ASVideoNode._periodicTimeObserverTimescale → CMTimeMake(1, ts)
// → addPeriodicTimeObserverForInterval:queue:usingBlock:; the block calls
// -[ASVideoNode periodicTimeObserver:] → delegate videoNode:didPlayToTimeInterval:.
// Nothing else in the tweak hooks -addPlayerObservers: (PiP hooks
// -[ASVideoNode didPlayToEnd:]; both chain independently).
//
// =============================================================================

// Texture's default (ASVideoNode -initWithCache:downloader: stores 10000).
static const int32_t kTextureDefaultPeriodicTimeObserverTimescale = 10000;
// 30 ticks per second: smooth for the inline progress overlay, a fraction of
// the per-frame rate the default produces.
static const int32_t kApolloInlineVideoTimeObserverTimescale = 30;

@interface ASVideoNode : NSObject
- (int32_t)periodicTimeObserverTimescale;
- (void)setPeriodicTimeObserverTimescale:(int32_t)timescale;
@end

// The timescale to install. Simulator builds can override it from the launch
// environment (SIMCTL_CHILD_APOLLOFIX_INLINE_VIDEO_TIMESCALE=10000 restores
// Texture's default for A/B profiling; any other positive value is used as-is)
// and log the measured tick rate per node every few seconds, which is how the
// numbers in the module comment were taken. Device builds always use the
// constant.
static int32_t ApolloInlineVideoTimeObserverTimescale(void) {
#if APOLLO_SIM_BUILD
    static int32_t override = -1;
    if (override < 0) {
        NSString *env = NSProcessInfo.processInfo.environment[@"APOLLOFIX_INLINE_VIDEO_TIMESCALE"];
        override = env.intValue > 0 ? env.intValue : 0;
        if (override) ApolloLog(@"[InlineVideoTimeObserver] sim override: timescale %d", override);
    }
    if (override) return override;
#endif
    return kApolloInlineVideoTimeObserverTimescale;
}

#if APOLLO_SIM_BUILD
// Sim-only tick counter: logs ticks/s per video node every 5 s of playback so
// the observer rate can be read straight off the log (200.0 with the default
// timescale via the env override above, 30.0 with the fix).
static void ApolloInlineVideoNoteTick(id node) {
    static NSMapTable *counts = nil;   // node (weak) → @[start, count]
    static dispatch_once_t once;
    dispatch_once(&once, ^{ counts = [NSMapTable weakToStrongObjectsMapTable]; });
    NSMutableArray *entry = [counts objectForKey:node];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!entry) {
        [counts setObject:[@[@(now), @0] mutableCopy] forKey:node];
        return;
    }
    NSUInteger count = [entry[1] unsignedIntegerValue] + 1;
    CFAbsoluteTime elapsed = now - [entry[0] doubleValue];
    if (elapsed >= 5.0) {
        ApolloLog(@"[InlineVideoTimeObserver] node=%p %.1f ticks/s over %.1fs (timescale %d)",
                  node, count / elapsed, elapsed, [node periodicTimeObserverTimescale]);
        entry[0] = @(now);
        entry[1] = @0;
    } else {
        entry[1] = @(count);
    }
}
#endif

%group InlineVideoTimeObserver

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
            ApolloLog(@"[InlineVideoTimeObserver] periodic time observer interval 1/%d s → 1/%d s (first player attached to %@)",
                      kTextureDefaultPeriodicTimeObserverTimescale, wanted, [self class]);
        });
    } else if (timescale != wanted) {
        // Not Texture's default: the app chose a rate for this node — keep it.
        ApolloLogDebug(@"[InlineVideoTimeObserver] leaving non-default timescale %d on %@",
                       timescale, [self class]);
    }
    %orig;
}

%end

%end

#if APOLLO_SIM_BUILD
// Sim-only tick counter (see ApolloInlineVideoNoteTick). Its own group, with
// both the hook and its %init inside the guard: an ungrouped hook here would
// make Logos append a registration for it after the #endif and break the
// device build (see the ApolloSimDebugTap.xm note).
%group InlineVideoTimeObserverSimTicks

%hook ASVideoNode

- (void)periodicTimeObserver:(CMTime)time {
    ApolloInlineVideoNoteTick(self);
    %orig;
}

%end

%end
#endif

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    Class videoNodeClass = objc_getClass("ASVideoNode");
    BOOL hasHookPoint = videoNodeClass
        && [videoNodeClass instancesRespondToSelector:@selector(addPlayerObservers:)]
        && [videoNodeClass instancesRespondToSelector:@selector(periodicTimeObserverTimescale)]
        && [videoNodeClass instancesRespondToSelector:@selector(setPeriodicTimeObserverTimescale:)];
    if (!hasHookPoint) {
        ApolloLog(@"[InlineVideoTimeObserver] ctor: ASVideoNode=%p lacks addPlayerObservers:/periodicTimeObserverTimescale — leaving Texture's observer rate alone",
                  (void *)videoNodeClass);
        return;
    }
    %init(InlineVideoTimeObserver, ASVideoNode = videoNodeClass);
#if APOLLO_SIM_BUILD
    %init(InlineVideoTimeObserverSimTicks, ASVideoNode = videoNodeClass);
#endif
    ApolloLog(@"[InlineVideoTimeObserver] hook installed: ASVideoNode addPlayerObservers: (timescale %d → %d)",
              kTextureDefaultPeriodicTimeObserverTimescale, kApolloInlineVideoTimeObserverTimescale);
}
