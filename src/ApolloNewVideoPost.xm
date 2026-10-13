#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloNewVideoPost.h"
#import "Tweak.h"

// MARK: - New video post: open it from the Posted! banner already playing
//
// Reddit creates a native video post as soon as /api/submit accepts the
// upload, and only then transcodes it on v.redd.it. Until that finishes the
// post reads is_video=true, post_hint=hosted:video, but media=null (measured
// on real posts: the video arrived 3.3 s after the submit for a 6 s clip and
// 8-10 s after for a 40 s 1080p clip), so RDKLink.mediaVideo is nil and Apollo
// draws the poster from `preview` as a still image.
//
// Apollo closes the composer when the upload finishes and submits in the
// background; PostSubmitWatcher.postSubmitted shows "Posted! Tap to view." as
// soon as the submit returns, and its tap closure (sub_100749f64 ->
// sub_10074740c) pushes a CommentsViewController built from the link ID and
// subreddit alone, which fetches the post right then, almost always inside
// that window. Nothing rebuilds the header afterwards, which is why the same
// post played when opened again later.
//
// Fix, part 1: ApolloImageUploadHost hands a video submit's success to
// ApolloNewVideoPostDeliverWhenPlayable, which holds it (and with it the
// banner; the composer is already gone, so nothing on screen waits) until
// Reddit has attached the video, checking through Apollo's own client
// (api/info, which works for API-key and API-key-free accounts alike), for at
// most kApolloNewVideoPostHoldLimit. Tapping the banner then opens a post that
// already plays.
//
// Part 2, for videos Reddit takes longer than that on (or the post opened some
// other way first): when a comments screen for a recently submitted video post
// appears without the video, the post is polled until RDKLink.mediaVideo shows
// up, then the screen gets the playable link and its media row is rebuilt.
// Pull-to-refresh can't do that: the media row's list object is the constant
// "header-image-token", so the ListAdapter keeps the old RichMediaHeaderCellNode,
// and RichMediaNode only creates its video node when it is built. A
// ModelObjectUpdated broadcast alone hands the new link to
// CommentsMediaHeaderSectionController (sub_1006dbcf8 -> sub_1006dc438), but
// that only re-colors the existing media node (sub_10057b3a0). So the screen
// gets the playable link the way Apollo spreads any model change
// (ModelObjectUpdated with newModel: the screen, both header section
// controllers and any feed cell sharing the stale link swap to it), and its
// media row is reloaded so the section controller builds a new
// RichMediaHeaderCellNode, now with the player (same pattern as
// ApolloChatsFilter.xm's mirror rows).

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

@interface RDKLink (ApolloNewVideoPost)
@property (readonly, nonatomic) id mediaVideo;
@property (readonly, copy, nonatomic) NSString *identifier;
@end

// How long the Posted! banner may wait for Reddit to attach the video. Normal
// clips finish well inside this; longer ones fall back to part 2.
static NSTimeInterval const kApolloNewVideoPostHoldLimit = 20.0;
static NSTimeInterval const kApolloNewVideoPostHoldFirstCheck = 1.0;
static NSTimeInterval const kApolloNewVideoPostHoldInterval = 1.5;
// A post submitted longer ago than this has long finished processing.
static NSTimeInterval const kApolloNewVideoPostPendingLifetime = 15.0 * 60.0;
// Upper bound for one poll run; Reddit accepts videos up to 15 minutes long.
static NSTimeInterval const kApolloNewVideoPostWatchLimit = 5.0 * 60.0;
// Short clips finish in a few seconds, so poll quickly first and back off.
static NSTimeInterval const kApolloNewVideoPostPollDelays[] = { 1.5, 1.5, 2.0, 2.0, 3.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 15.0 };
static NSUInteger const kApolloNewVideoPostPollDelayCount = sizeof(kApolloNewVideoPostPollDelays) / sizeof(kApolloNewVideoPostPollDelays[0]);
// After the video is ready, keep checking open screens this long (one whose
// own fetch is still in flight, or a row reload that hasn't landed yet), and
// upgrade at most this many times, this far apart.
static NSTimeInterval const kApolloNewVideoPostSettleWindow = 20.0;
static NSTimeInterval const kApolloNewVideoPostSettleInterval = 1.0;
static NSUInteger const kApolloNewVideoPostMaxUpgrades = 3;
static NSTimeInterval const kApolloNewVideoPostUpgradeSpacing = 2.0;
// The media header is the first row of a post's comments list.
static NSInteger const kApolloNewVideoPostMediaRowSearchLimit = 3;

// All state is main-thread only.
static NSMutableDictionary<NSString *, NSDate *> *sApolloNewVideoPostSubmittedAt;  // bare link ID -> submit time
static NSMutableDictionary<NSString *, id> *sApolloNewVideoPostReadyLinks;         // bare link ID -> RDKLink with the video
static NSMutableSet<NSString *> *sApolloNewVideoPostPolling;
static NSMutableSet<NSString *> *sApolloNewVideoPostSettling;
static char kApolloNewVideoPostReplacedCellKey;

static NSString *ApolloNewVideoPostBareID(NSString *linkID) {
    if (![linkID isKindOfClass:[NSString class]] || linkID.length == 0) return nil;
    return [linkID hasPrefix:@"t3_"] ? [linkID substringFromIndex:3] : linkID;
}

static BOOL ApolloNewVideoPostLinkHasVideo(id link) {
    return [link respondsToSelector:@selector(mediaVideo)] && [(RDKLink *)link mediaVideo] != nil;
}

// The post a comments screen shows: its RDKLink once the fetch lands, else the
// link ID it was created with (a Swift `String?` set by CommentsViewController's
// init before anything loads, sub_100722458).
static NSString *ApolloNewVideoPostControllerLinkID(UIViewController *controller) {
    id link = ApolloObjectIvar(controller, "link");
    NSString *identifier = [link respondsToSelector:@selector(identifier)] ? [(RDKLink *)link identifier] : nil;
    if (identifier.length == 0) identifier = ApolloReadSwiftStringIvar(controller, "linkID");
    return ApolloNewVideoPostBareID(identifier);
}

static void ApolloNewVideoPostCollectControllers(UIViewController *controller, NSString *bareID,
                                                 NSMutableArray<UIViewController *> *matches, NSHashTable *visited) {
    if (!controller || [visited containsObject:controller]) return;
    [visited addObject:controller];
    Class commentsClass = ApolloClassCommentsViewController;
    if (commentsClass && [controller isKindOfClass:commentsClass] &&
        [ApolloNewVideoPostControllerLinkID(controller) isEqualToString:bareID]) {
        [matches addObject:controller];
    }
    for (UIViewController *child in controller.childViewControllers) {
        ApolloNewVideoPostCollectControllers(child, bareID, matches, visited);
    }
    ApolloNewVideoPostCollectControllers(controller.presentedViewController, bareID, matches, visited);
}

static NSArray<UIViewController *> *ApolloNewVideoPostCommentsControllers(NSString *bareID) {
    NSMutableArray<UIViewController *> *matches = [NSMutableArray array];
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (UIWindow *window in ApolloAllWindows()) {
        ApolloNewVideoPostCollectControllers(window.rootViewController, bareID, matches, visited);
    }
    return matches;
}

// The screen's media header row (RichMediaHeaderCellNode), or nil when the
// post has none or the row isn't allocated (scrolled far away).
static id ApolloNewVideoPostMediaCell(id tableNode, NSIndexPath **outIndexPath) {
    Class mediaCellClass = objc_getClass("_TtC6Apollo23RichMediaHeaderCellNode");
    if (!tableNode || !mediaCellClass ||
        ![tableNode respondsToSelector:@selector(numberOfRowsInSection:)] ||
        ![tableNode respondsToSelector:@selector(nodeForRowAtIndexPath:)]) return nil;
    NSInteger rows = ((NSInteger (*)(id, SEL, NSInteger))objc_msgSend)(tableNode, @selector(numberOfRowsInSection:), 0);
    for (NSInteger row = 0; row < MIN(rows, kApolloNewVideoPostMediaRowSearchLimit); row++) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:0];
        id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, @selector(nodeForRowAtIndexPath:), indexPath);
        if (![node isKindOfClass:mediaCellClass]) continue;
        if (outIndexPath) *outIndexPath = indexPath;
        return node;
    }
    return nil;
}

typedef NS_ENUM(NSInteger, ApolloNewVideoPostScreenState) {
    ApolloNewVideoPostScreenLoading,   // its own fetch hasn't landed yet
    ApolloNewVideoPostScreenPlaying,   // header shows the video (or will when built)
    ApolloNewVideoPostScreenStale,     // header still shows the poster
};

static ApolloNewVideoPostScreenState ApolloNewVideoPostStateOfScreen(UIViewController *controller, id *outMediaCell,
                                                                    NSIndexPath **outIndexPath) {
    id link = ApolloObjectIvar(controller, "link");
    if (!link) return ApolloNewVideoPostScreenLoading;
    id mediaCell = ApolloNewVideoPostMediaCell(ApolloObjectIvar(controller, "tableNode"), outIndexPath);
    if (outMediaCell) *outMediaCell = mediaCell;
    if (!mediaCell) {
        // Not built (or scrolled off): it is built from the screen's link when
        // it comes back, so the link alone decides.
        return ApolloNewVideoPostLinkHasVideo(link) ? ApolloNewVideoPostScreenPlaying : ApolloNewVideoPostScreenStale;
    }
    // An is_video post with no media.reddit_video still gets a video node
    // (TouchHintVideoNode), just one that is never given an asset, so it
    // shows the poster. A playable header's node has the HLS AVURLAsset.
    id richMediaNode = ApolloObjectIvar(mediaCell, "richMediaNode");
    id videoNode = ApolloObjectIvar(richMediaNode, "videoNode");
    id asset = [videoNode respondsToSelector:@selector(asset)] ? ((id (*)(id, SEL))objc_msgSend)(videoNode, @selector(asset)) : nil;
    if (asset) return ApolloNewVideoPostScreenPlaying;
    // A cell we asked the table to replace stays stale until the new one lands.
    if (objc_getAssociatedObject(mediaCell, &kApolloNewVideoPostReplacedCellKey)) return ApolloNewVideoPostScreenStale;
    // Built from the playable post but no asset yet (an NSFW or spoiler cover
    // can hold the player back until it's tapped): nothing left to rebuild.
    return ApolloNewVideoPostLinkHasVideo(ApolloObjectIvar(richMediaNode, "link")) ? ApolloNewVideoPostScreenPlaying
                                                                                 : ApolloNewVideoPostScreenStale;
}

// Upgrades every listed screen in one go. They are gathered before anything is
// broadcast because the broadcast also repoints the media node of any other
// screen sharing a stale link, which would then look rebuilt without being so.
static void ApolloNewVideoPostUpgradeScreens(NSArray<NSDictionary *> *screens, id readyLink) {
    // Every stale instance the screens hand out: each screen's own link, and the
    // one its media node was built with (normally the same object).
    NSMutableArray *staleLinks = [NSMutableArray array];
    void (^noteStale)(id) = ^(id link) {
        if (link && link != readyLink && ![staleLinks containsObject:link] && !ApolloNewVideoPostLinkHasVideo(link)) [staleLinks addObject:link];
    };
    for (NSDictionary *screen in screens) {
        noteStale(ApolloObjectIvar(screen[@"controller"], "link"));
        noteStale(ApolloObjectIvar(ApolloObjectIvar(screen[@"mediaCell"], "richMediaNode"), "link"));
    }
    // The broadcast points these old nodes at the playable link too, so flag
    // them first: none may pass for a rebuilt node while it's still on screen.
    for (NSDictionary *screen in screens) {
        if (screen[@"indexPath"]) objc_setAssociatedObject(screen[@"mediaCell"], &kApolloNewVideoPostReplacedCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (id staleLink in staleLinks) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"com.christianselig.ModelObjectUpdated"
                                                            object:staleLink
                                                          userInfo:@{ @"newModel": readyLink }];
    }
    for (NSDictionary *screen in screens) {
        UIViewController *controller = screen[@"controller"];
        NSIndexPath *mediaIndexPath = screen[@"indexPath"];
        id tableNode = ApolloObjectIvar(controller, "tableNode");
        BOOL reloaded = NO;
        if (mediaIndexPath && [tableNode respondsToSelector:@selector(reloadRowsAtIndexPaths:withRowAnimation:)]) {
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(tableNode, @selector(reloadRowsAtIndexPaths:withRowAnimation:),
                                                            @[ mediaIndexPath ], (NSInteger)UITableViewRowAnimationNone);
            reloaded = YES;
        }
        ApolloLog(@"[NewVideoPost] Gave an open comments screen the playable post (stale links=%lu, media row %@, on screen=%@)",
                  (unsigned long)staleLinks.count, reloaded ? [NSString stringWithFormat:@"%ld reloaded", (long)mediaIndexPath.row] : @"not built",
                  controller.viewIfLoaded.window ? @"yes" : @"no");
    }
}

static void ApolloNewVideoPostSettle(NSString *bareID, NSDate *settleStart, NSUInteger upgrades, NSDate *lastUpgrade) {
    id readyLink = sApolloNewVideoPostReadyLinks[bareID];
    NSMutableArray<NSDictionary *> *staleScreens = [NSMutableArray array];
    BOOL loading = NO;
    for (UIViewController *controller in ApolloNewVideoPostCommentsControllers(bareID)) {
        id mediaCell = nil;
        NSIndexPath *mediaIndexPath = nil;
        ApolloNewVideoPostScreenState state = ApolloNewVideoPostStateOfScreen(controller, &mediaCell, &mediaIndexPath);
        if (state == ApolloNewVideoPostScreenPlaying) continue;
        if (state == ApolloNewVideoPostScreenLoading) {
            loading = YES;
            continue;
        }
        NSMutableDictionary *screen = [NSMutableDictionary dictionaryWithObject:controller forKey:@"controller"];
        if (mediaCell) screen[@"mediaCell"] = mediaCell;
        if (mediaIndexPath) screen[@"indexPath"] = mediaIndexPath;
        [staleScreens addObject:screen];
    }
    BOOL canUpgrade = readyLink && upgrades < kApolloNewVideoPostMaxUpgrades &&
        (!lastUpgrade || -[lastUpgrade timeIntervalSinceNow] >= kApolloNewVideoPostUpgradeSpacing);
    if (staleScreens.count > 0 && canUpgrade) {
        ApolloNewVideoPostUpgradeScreens(staleScreens, readyLink);
        upgrades++;
        lastUpgrade = [NSDate date];
    }
    // Keep going while a screen is still loading, or a stale one either has
    // upgrades left or is giving the last reload time to land.
    BOOL lastReloadPending = lastUpgrade && -[lastUpgrade timeIntervalSinceNow] < kApolloNewVideoPostUpgradeSpacing;
    BOOL waiting = loading || (staleScreens.count > 0 && (upgrades < kApolloNewVideoPostMaxUpgrades || lastReloadPending));
    if (waiting && -[settleStart timeIntervalSinceNow] < kApolloNewVideoPostSettleWindow) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloNewVideoPostSettleInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloNewVideoPostSettle(bareID, settleStart, upgrades, lastUpgrade);
        });
        return;
    }
    if (staleScreens.count > 0) {
        ApolloLog(@"[NewVideoPost] %lu comments screen(s) for t3_%@ still show the poster after %lu upgrade(s); leaving them",
                  (unsigned long)staleScreens.count, bareID, (unsigned long)upgrades);
    }
    [sApolloNewVideoPostSettling removeObject:bareID];
}

static void ApolloNewVideoPostStartSettling(NSString *bareID) {
    if (!sApolloNewVideoPostSettling) sApolloNewVideoPostSettling = [NSMutableSet new];
    if ([sApolloNewVideoPostSettling containsObject:bareID]) return;
    [sApolloNewVideoPostSettling addObject:bareID];
    ApolloNewVideoPostSettle(bareID, [NSDate date], 0, nil);
}

// Fetches the post through Apollo's own client (api/info; Web JSON routes it
// for API-key-free accounts) and calls back on the main queue with its RDKLink,
// or nil when there's no client or the request failed.
static void ApolloNewVideoPostFetchLink(NSString *bareID, void (^completion)(id link, NSError *error)) {
    id client = [ApolloClassRDKClient sharedClient];
    if (!client) {
        completion(nil, nil);
        return;
    }
    NSString *fullName = [@"t3_" stringByAppendingString:bareID];
    [(RDKClient *)client thingsByFullNames:@[ fullName ] completion:^(NSArray *things, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id link = nil;
            for (id thing in things) {
                if (![thing respondsToSelector:@selector(identifier)]) continue;
                if ([ApolloNewVideoPostBareID([(RDKLink *)thing identifier]) isEqualToString:bareID]) link = thing;
            }
            completion(link, error);
        });
    }];
}

static void ApolloNewVideoPostNoteReady(NSString *bareID, id link) {
    if (!sApolloNewVideoPostReadyLinks) sApolloNewVideoPostReadyLinks = [NSMutableDictionary new];
    sApolloNewVideoPostReadyLinks[bareID] = link;
}

static void ApolloNewVideoPostPoll(NSString *bareID, NSDate *pollStart, NSUInteger attempt) {
    // Nobody is looking at the post any more: stop. Opening it again restarts.
    if (ApolloNewVideoPostCommentsControllers(bareID).count == 0) {
        [sApolloNewVideoPostPolling removeObject:bareID];
        ApolloLog(@"[NewVideoPost] Stopped waiting for t3_%@: its comments are closed", bareID);
        return;
    }
    if (![ApolloClassRDKClient sharedClient]) {
        [sApolloNewVideoPostPolling removeObject:bareID];
        ApolloLog(@"[NewVideoPost] Stopped waiting for t3_%@: no Reddit client", bareID);
        return;
    }
    ApolloNewVideoPostFetchLink(bareID, ^(id link, NSError *error) {
        if (ApolloNewVideoPostLinkHasVideo(link)) {
            [sApolloNewVideoPostPolling removeObject:bareID];
            ApolloNewVideoPostNoteReady(bareID, link);
            NSDate *submittedAt = sApolloNewVideoPostSubmittedAt[bareID];
            ApolloLog(@"[NewVideoPost] t3_%@ has its video now (check %lu, %.1fs after posting)", bareID,
                      (unsigned long)(attempt + 1), submittedAt ? -[submittedAt timeIntervalSinceNow] : -1.0);
            ApolloNewVideoPostStartSettling(bareID);
            return;
        }
        NSTimeInterval elapsed = -[pollStart timeIntervalSinceNow];
        if (attempt == 0 || error) {
            ApolloLog(@"[NewVideoPost] t3_%@ is still processing (check %lu, link=%@, error=%@)", bareID,
                      (unsigned long)(attempt + 1), link ? @"yes" : @"no", error.localizedDescription ?: @"none");
        }
        if (elapsed >= kApolloNewVideoPostWatchLimit) {
            [sApolloNewVideoPostPolling removeObject:bareID];
            ApolloLog(@"[NewVideoPost] Gave up waiting for t3_%@'s video after %.0fs", bareID, elapsed);
            return;
        }
        NSTimeInterval delay = kApolloNewVideoPostPollDelays[MIN(attempt, kApolloNewVideoPostPollDelayCount - 1)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloNewVideoPostPoll(bareID, pollStart, attempt + 1);
        });
    });
}

static void ApolloNewVideoPostCommentsAppeared(UIViewController *controller) {
    if (sApolloNewVideoPostSubmittedAt.count == 0) return;
    NSString *bareID = ApolloNewVideoPostControllerLinkID(controller);
    NSDate *submittedAt = bareID ? sApolloNewVideoPostSubmittedAt[bareID] : nil;
    if (!submittedAt) return;
    if (-[submittedAt timeIntervalSinceNow] > kApolloNewVideoPostPendingLifetime) {
        [sApolloNewVideoPostSubmittedAt removeObjectForKey:bareID];
        [sApolloNewVideoPostReadyLinks removeObjectForKey:bareID];
        return;
    }
    if (ApolloNewVideoPostStateOfScreen(controller, NULL, NULL) == ApolloNewVideoPostScreenPlaying) return;
    if (sApolloNewVideoPostReadyLinks[bareID]) {
        // Already playable; this screen was opened (or restored) with an old copy.
        ApolloNewVideoPostStartSettling(bareID);
        return;
    }
    if (!sApolloNewVideoPostPolling) sApolloNewVideoPostPolling = [NSMutableSet new];
    if ([sApolloNewVideoPostPolling containsObject:bareID]) return;
    [sApolloNewVideoPostPolling addObject:bareID];
    ApolloLog(@"[NewVideoPost] Comments for t3_%@ opened %.1fs after posting; waiting for its video",
              bareID, -[submittedAt timeIntervalSinceNow]);
    ApolloNewVideoPostPoll(bareID, [NSDate date], 0);
}

static void ApolloNewVideoPostNoteSubmitted(NSString *bareID) {
    if (!sApolloNewVideoPostSubmittedAt) sApolloNewVideoPostSubmittedAt = [NSMutableDictionary new];
    for (NSString *key in sApolloNewVideoPostSubmittedAt.allKeys) {
        if (-[sApolloNewVideoPostSubmittedAt[key] timeIntervalSinceNow] > kApolloNewVideoPostPendingLifetime) {
            [sApolloNewVideoPostSubmittedAt removeObjectForKey:key];
            [sApolloNewVideoPostReadyLinks removeObjectForKey:key];
        }
    }
    sApolloNewVideoPostSubmittedAt[bareID] = [NSDate date];
    [sApolloNewVideoPostReadyLinks removeObjectForKey:bareID];
}

// One check of the hold: deliver as soon as the post has its video, or once
// the next check would land past the limit.
static void ApolloNewVideoPostHoldCheck(NSString *bareID, NSDate *holdStart, void (^deliver)(BOOL playable)) {
    ApolloNewVideoPostFetchLink(bareID, ^(id link, NSError *error) {
        NSTimeInterval elapsed = -[holdStart timeIntervalSinceNow];
        if (ApolloNewVideoPostLinkHasVideo(link)) {
            ApolloNewVideoPostNoteReady(bareID, link);
            ApolloLog(@"[NewVideoPost] t3_%@ has its video %.1fs after the submit; showing Posted! now", bareID, elapsed);
            deliver(YES);
            return;
        }
        if (elapsed + kApolloNewVideoPostHoldInterval > kApolloNewVideoPostHoldLimit) {
            ApolloLog(@"[NewVideoPost] t3_%@ is still processing after %.0fs (link=%@, error=%@); showing Posted! now, its comments switch to the video once it's ready",
                      bareID, elapsed, link ? @"yes" : @"no", error.localizedDescription ?: @"none");
            deliver(NO);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloNewVideoPostHoldInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloNewVideoPostHoldCheck(bareID, holdStart, deliver);
        });
    });
}

void ApolloNewVideoPostDeliverWhenPlayable(NSString *linkID, dispatch_block_t deliver) {
    NSString *bareID = ApolloNewVideoPostBareID(linkID);
    // Callers are the submit response transform: always hand the response on,
    // on a background queue like the transform's other completions.
    __block BOOL delivered = NO;
    void (^finish)(BOOL) = ^(__unused BOOL playable) {
        if (delivered || !deliver) return;
        delivered = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), deliver);
    };
    if (!bareID) {
        finish(NO);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloNewVideoPostNoteSubmitted(bareID);
        if (![ApolloClassRDKClient sharedClient]) {
            ApolloLog(@"[NewVideoPost] No Reddit client to check t3_%@; showing Posted! right away", bareID);
            finish(NO);
            return;
        }
        ApolloLog(@"[NewVideoPost] Holding Posted! for video post t3_%@ until Reddit attaches the video (up to %.0fs)",
                  bareID, kApolloNewVideoPostHoldLimit);
        NSDate *holdStart = [NSDate date];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloNewVideoPostHoldFirstCheck * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloNewVideoPostHoldCheck(bareID, holdStart, finish);
        });
    });
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloNewVideoPostCommentsAppeared((UIViewController *)self);
}

%end

%ctor {
    %init;
    // objc_getClass, not the ApolloClass* globals: constructor order across
    // translation units isn't guaranteed.
    Class commentsClass = objc_getClass("_TtC6Apollo22CommentsViewController");
    Class mediaCellClass = objc_getClass("_TtC6Apollo23RichMediaHeaderCellNode");
    Class richMediaClass = objc_getClass("_TtC6Apollo13RichMediaNode");
    BOOL found = commentsClass && mediaCellClass && richMediaClass && objc_getClass("RDKClient") &&
        class_getInstanceVariable(commentsClass, "link") &&
        class_getInstanceVariable(commentsClass, "linkID") &&
        class_getInstanceVariable(commentsClass, "tableNode") &&
        class_getInstanceVariable(mediaCellClass, "richMediaNode") &&
        class_getInstanceVariable(richMediaClass, "videoNode") &&
        class_getInstanceVariable(richMediaClass, "link");
    ApolloLog(@"[NewVideoPost] hook installed (Posted! waits for a just-posted video to finish processing; comments opened sooner switch to it)%@",
              found ? @"" : @", but a comments class or ivar is MISSING");
}
