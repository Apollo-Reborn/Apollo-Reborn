#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <math.h>
#import <limits.h>
#import <dlfcn.h>

#import "ApolloCommon.h"
#import "ApolloPostReadState.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "UserDefaultConstants.h"
#import "ApolloSwiftSingletonCapture.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloActionMenu.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloTextureDecls.h"
#import "ApolloAccountCredentials.h"

// MARK: - Recently Read Posts
//
// Apollo's ReadPostsTracker keeps read-post IDs in an NSMutableOrderedSet
// (bare IDs, newest appended at the end, trimmed to 5000 from the front)
// guarded by a private CONCURRENT dispatch queue: every native write is an
// async .barrier block on that queue and every native read is a dispatch_sync
// (confirmed in Hopper). The "ReadPostIDs" NSUserDefaults key is only
// persisted on scene-background / app-terminate, so the in-memory set is the
// sole in-session source of truth. We mirror the same queue discipline below
// so our reads are ordered after any pending native mark and never race the
// barrier writers.

// Direct access to ReadPostsTracker's in-memory ordered set via the ObjC runtime
static __unsafe_unretained id sReadPostsTracker = nil;
static Ivar sReadPostIDsIvar = NULL;
// Cached resolved values - both ivars are assigned once in the tracker's init
// and never replaced, and the tracker itself lives for the app's lifetime.
static __unsafe_unretained NSMutableOrderedSet *sTrackerReadPostIDsCached = nil;
static BOOL sReadPostIDsLookupFailed = NO;
static dispatch_queue_t sTrackerQueueCached = nil;
static BOOL sTrackerQueueLookupFailed = NO;
static char sTrackerQueueSpecificKey;

NSNotificationName const ApolloPostReadStateDidChangeNotification = @"ApolloPostReadStateDidChangeNotification";

// Native marks run on the tracker's queue, while comments snapshots may be
// saved from any comments controller. Never synchronously notify UIKit from
// either path: observers take queue-ordered snapshots and could otherwise
// deadlock with the writer. Coalesce bursts (including remove/re-add revisits)
// into one main-queue refresh; the observer's queue-ordered snapshot waits for
// any pending writer before reading the IDs.
static os_unfair_lock sReadStateNotificationLock = OS_UNFAIR_LOCK_INIT;
static BOOL sReadStateNotificationPending = NO;

static void ApolloSchedulePostReadStateDidChange(void) {
    os_unfair_lock_lock(&sReadStateNotificationLock);
    BOOL alreadyPending = sReadStateNotificationPending;
    sReadStateNotificationPending = YES;
    os_unfair_lock_unlock(&sReadStateNotificationLock);
    if (alreadyPending) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        os_unfair_lock_lock(&sReadStateNotificationLock);
        sReadStateNotificationPending = NO;
        os_unfair_lock_unlock(&sReadStateNotificationLock);
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloPostReadStateDidChangeNotification object:nil];
    });
}

// Post IDs are stored bare (no t3_ prefix) in the tracker's set
static NSString *ApolloBarePostID(NSString *postID) {
    return [postID hasPrefix:@"t3_"] ? [postID substringFromIndex:3] : postID;
}

// Scan the tracker's ivar list for a name containing nameSubstr
static Ivar ApolloTrackerIvarNamed(const char *nameSubstr) {
    if (!sReadPostsTracker) return NULL;
    Ivar found = NULL;
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([sReadPostsTracker class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (name && strstr(name, nameSubstr)) {
                found = ivars[i];
                break;
            }
        }
        free(ivars);
    }
    return found;
}

// Captured at allocation by ApolloSwiftSingletonCapture (the shared owner of
// the swift_allocObject hook).
static void ApolloRecentlyReadCaptureTracker(void *object) {
    sReadPostsTracker = (__bridge id)object;
}

// Retrieve the in-memory NSMutableOrderedSet of read post IDs from the tracker
static NSMutableOrderedSet *getTrackerReadPostIDs(void) {
    // Cached so the hot-path NSMutableOrderedSet addObject: hook below is a
    // pointer compare after the first resolution.
    if (sTrackerReadPostIDsCached) return sTrackerReadPostIDsCached;
    if (sReadPostIDsLookupFailed || !sReadPostsTracker) return nil;

    // Lazily find the ivar by name. Latch on failure - this runs inside the
    // app-wide NSMutableOrderedSet addObject: hook, so a renamed ivar must
    // not turn every add into an ivar-list scan.
    if (!sReadPostIDsIvar) {
        sReadPostIDsIvar = ApolloTrackerIvarNamed("readPostIDs");
        if (!sReadPostIDsIvar) {
            sReadPostIDsLookupFailed = YES;
            ApolloLog(@"[RecentlyRead] readPostIDs ivar not found");
            return nil;
        }
    }

    id value = object_getIvar(sReadPostsTracker, sReadPostIDsIvar);
    if ([value isKindOfClass:[NSMutableOrderedSet class]]) {
        sTrackerReadPostIDsCached = (NSMutableOrderedSet *)value;
        return sTrackerReadPostIDsCached;
    }
    return nil;
}

// Retrieve the tracker's private concurrent dispatch queue (ivar "dispatchQueue")
static dispatch_queue_t getTrackerQueue(void) {
    if (sTrackerQueueCached) return sTrackerQueueCached;
    if (sTrackerQueueLookupFailed || !sReadPostsTracker) return nil;

    Ivar queueIvar = ApolloTrackerIvarNamed("dispatchQueue");
    if (!queueIvar) {
        sTrackerQueueLookupFailed = YES;
        ApolloLog(@"[RecentlyRead] dispatchQueue ivar not found - native read state unavailable");
        return nil;
    }

    id value = object_getIvar(sReadPostsTracker, queueIvar);
    // The singleton is captured at allocation, before its initializer assigns
    // the queue. An early UI read must be allowed to retry after initialization.
    if (!value) return nil;
    // Sanity-check the class: barrier semantics only mean anything on a real
    // private dispatch queue.
    if ([value isKindOfClass:objc_getClass("OS_dispatch_queue")]) {
        sTrackerQueueCached = (dispatch_queue_t)value;
        dispatch_queue_set_specific(sTrackerQueueCached, &sTrackerQueueSpecificKey, &sTrackerQueueSpecificKey, NULL);
    } else {
        sTrackerQueueLookupFailed = YES;
        ApolloLog(@"[RecentlyRead] dispatchQueue ivar is not a dispatch queue - native read state unavailable");
    }
    return sTrackerQueueCached;
}

// Snapshot the tracker's in-memory IDs. Reads go through dispatch_sync on the
// tracker's queue when available so they are ordered AFTER any pending native
// barrier write (Apollo enqueues marks as async barrier blocks) - this is
// what guarantees a refresh sees a just-marked post. -[NSOrderedSet array]
// returns a live proxy, not a snapshot, so the copy MUST be materialized
// inside the block. Returns nil when the tracker/queue isn't available, rather
// than racing native barrier writers through an unguarded direct read.
NSArray<NSString *> *ApolloReadPostIDsSnapshot(void) {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    if (!trackerSet) return nil;

    dispatch_queue_t queue = getTrackerQueue();
    if (!queue) return nil;
    __block NSArray *snapshot = nil;
    if (dispatch_get_specific(&sTrackerQueueSpecificKey)) {
        // Already executing on this queue: dispatch_sync would deadlock.
        snapshot = [[NSArray alloc] initWithArray:[trackerSet array]];
    } else {
        dispatch_sync(queue, ^{
            snapshot = [[NSArray alloc] initWithArray:[trackerSet array]];
        });
    }
    return snapshot;
}

// Mutate the tracker's set with the same async-barrier discipline native
// writes use. The block must never synchronously dispatch to other queues
// (deadlock risk for the dispatch_sync readers).
static BOOL ApolloMutateTrackerSet(void (^mutation)(NSMutableOrderedSet *trackerSet)) {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    if (!trackerSet) return NO;

    dispatch_queue_t queue = getTrackerQueue();
    if (!queue) return NO;
    dispatch_barrier_async(queue, ^{
        mutation(trackerSet);
        ApolloSchedulePostReadStateDidChange();
    });
    return YES;
}

// Mark a post as read in the tracker (stored as a bare ID, matching native
// storage). Returns YES when the mark was enqueued. Re-adding an existing ID
// bumps it to the most-recent slot via the NSMutableOrderedSet addObject:
// hook below. Note: this writes the tracker's set directly, so the native
// Reddit-account batch counters (hide-read sync, Premium visited sync) never
// see tweak marks - there is no stable native entry point to route through.
static BOOL ApolloMarkPostIDAsRead(NSString *postID) {
    if (postID.length == 0) return NO;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DisableMarkingPostsRead"]) return NO;
    if (!getTrackerReadPostIDs()) {
        ApolloLog(@"[RecentlyRead] Cannot mark %@ read - tracker not captured yet", postID);
        return NO;
    }

    NSString *bareID = ApolloBarePostID(postID);
    if (bareID.length == 0) return NO;
    NSString *prefixedID = [@"t3_" stringByAppendingString:bareID];
    return ApolloMutateTrackerSet(^(NSMutableOrderedSet *trackerSet) {
        // Drop a legacy prefixed twin so the two ID forms can't coexist as
        // duplicate entries.
        [trackerSet removeObject:prefixedID];
        [trackerSet addObject:bareID];
    });
}

// NewCommentsTracker synchronously publishes its snapshots to defaults before
// posting com.christianselig.ReadCommentsUpdated. This avoids reading its inline
// Swift OrderedDictionary: the JSON is ["abc123", {"totalComments": 42,
// "timestamp": ...}, ...]. CommentsViewController.viewDidDisappear: owns baseline
// updates, including for apollo:// links, so rendering never creates a baseline.
NSDictionary<NSString *, NSNumber *> *ApolloLastReadCommentTotalsSnapshot(void) {
    static NSObject *cacheLock;
    static NSData *cachedData;
    static NSDictionary<NSString *, NSNumber *> *cachedTotals;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cacheLock = [[NSObject alloc] init];
        cachedTotals = @{};
    });

    @synchronized (cacheLock) {
        NSData *data = [[NSUserDefaults standardUserDefaults] dataForKey:@"PostCommentsSnapshots"];
        if (data == cachedData || [data isEqualToData:cachedData]) return cachedTotals;
        cachedData = [data copy];
        cachedTotals = @{};
        if (data.length == 0) return cachedTotals;

        // Apollo caps the native collection at 1,000 snapshots. Bound parsing
        // generously above that size so malformed restored preferences cannot
        // make every card refresh decode an unbounded payload.
        if (data.length > 2 * 1024 * 1024) {
            ApolloLog(@"[RecentlyRead] Ignoring oversized native comment snapshot data (%lu bytes)", (unsigned long)data.length);
            return cachedTotals;
        }
        NSError *error = nil;
        id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (![decoded isKindOfClass:[NSArray class]] || [(NSArray *)decoded count] % 2 != 0) {
            ApolloLogError(@"[RecentlyRead] Native comment snapshots have an unsupported JSON shape (decode error: %ld)", (long)error.code);
            return cachedTotals;
        }

        NSArray *entries = decoded;
        NSMutableDictionary<NSString *, NSNumber *> *totals = [NSMutableDictionary dictionaryWithCapacity:entries.count / 2];
        for (NSUInteger i = 0; i + 1 < entries.count; i += 2) {
            NSString *postID = [entries[i] isKindOfClass:[NSString class]] ? entries[i] : nil;
            NSDictionary *snapshot = [entries[i + 1] isKindOfClass:[NSDictionary class]] ? entries[i + 1] : nil;
            NSNumber *count = [snapshot[@"totalComments"] isKindOfClass:[NSNumber class]] ? snapshot[@"totalComments"] : nil;
            if (postID.length == 0 || !count || CFGetTypeID((__bridge CFTypeRef)count) == CFBooleanGetTypeID()) continue;
            double value = count.doubleValue;
            // Keep only integral, nonnegative counts that are exactly usable in
            // the cards' signed 64-bit delta arithmetic; absent stays unknown.
            if (!isfinite(value) || value < 0 || value >= (double)LLONG_MAX || floor(value) != value) continue;
            NSString *bareID = ApolloBarePostID(postID);
            if (bareID.length) totals[bareID] = @(count.longLongValue);
        }
        cachedTotals = [totals copy];
        ApolloLog(@"[RecentlyRead] Loaded %lu native last-read comment baselines", (unsigned long)cachedTotals.count);
        return cachedTotals;
    }
}

// Flush the in-memory ReadPostIDs to NSUserDefaults so backup captures current state
void ApolloFlushReadPostIDsToDefaults(void) {
    NSArray *postIDs = ApolloReadPostIDsSnapshot();
    if (postIDs.count > 0) {
        ApolloLog(@"[RecentlyRead] Flushing %lu in-memory ReadPostIDs to NSUserDefaults", (unsigned long)postIDs.count);
        [[NSUserDefaults standardUserDefaults] setObject:postIDs forKey:@"ReadPostIDs"];
    } else {
        ApolloLog(@"[RecentlyRead] Flush skipped - tracker %s, count: %lu",
                  sReadPostsTracker ? "available" : "nil",
                  (unsigned long)postIDs.count);
    }
}

// MARK: - Recently Read Feed
//
// Recently Read is Apollo's own PostsViewController, so every feed setting
// (post size, thumbnails, voting buttons, text size, themes, swipe and action
// menus) applies to it exactly as it does to a subreddit. It is built as an
// Upvoted list for a sentinel user: that list loads every page, the first from
// viewDidLoad and the rest from ASDK batch fetches off the main thread, through
// -[RDKClient upvotedLinksForUser:pagination:completion:] with the username it
// was built with. The hook below answers those calls with the read history.
//
// PostsType is a 33-byte Swift enum: payload in bytes 0-31, case tag at byte 32
// (subreddit 0, multireddit 1, upvoted 2, downvoted 3, submissions 4, random 5,
// home/hidden 6). Apollo passes it indirectly to PostsViewController's
// designated initializer, with the allocated object as Swift self (x20).

// '~' never appears in a Reddit username, and at 13 bytes the name is an inline
// Swift small string, so the enum holds no reference to retain or release.
static NSString *const kRecentlyReadFeedUser = @"~recentlyread";
static const uint8_t kPostsTypeUpvotedTag = 2;
static const NSUInteger kRecentlyReadDefaultPageSize = 25;
static const NSUInteger kRecentlyReadMaxPageSize = 100;
// Pages fully hidden by the NSFW filter are skipped, at most this many in a row.
static const NSUInteger kRecentlyReadMaxSkippedPages = 3;
static char kRecentlyReadFeedKey;

@interface RDKPagination (ApolloRecentlyRead)
@property (nonatomic) unsigned long long limit;
@property (copy, nonatomic) NSString *after;
+ (instancetype)paginationWithLimit:(unsigned long long)limit;
@end

@interface RDKClient (ApolloRecentlyRead)
- (id)thingsByFullNames:(NSArray *)fullNames completion:(void (^)(NSArray *things, NSError *error))completion;
@end

typedef void (^ApolloRecentlyReadListingCompletion)(NSArray *links, RDKPagination *pagination, NSError *error);

static BOOL ApolloIsRecentlyReadFeed(id controller) {
    return controller && objc_getAssociatedObject(controller, &kRecentlyReadFeedKey) != nil;
}

// Newest first, as t3_ fullnames, capped by the history size setting.
static NSArray<NSString *> *ApolloRecentReadFullNames(void) {
    NSArray *postIDs = ApolloReadPostIDsSnapshot();
    if (postIDs.count == 0) {
        // Tracker missing or empty: the persisted mirror (written on backgrounding).
        postIDs = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"ReadPostIDs"];
    }
    if (postIDs.count == 0) return @[];

    NSUInteger maxCount = sReadPostMaxCount > 0 ? MIN(postIDs.count, (NSUInteger)sReadPostMaxCount) : postIDs.count;
    // Newest IDs are at the end; dedupe bare/prefixed twins, keeping the newest.
    NSMutableArray<NSString *> *fullNames = [NSMutableArray arrayWithCapacity:maxCount];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:maxCount];
    NSUInteger scanned = 0;
    for (NSString *postID in [postIDs reverseObjectEnumerator]) {
        if (scanned++ >= maxCount) break;
        NSString *fullName = [postID hasPrefix:@"t3_"] ? postID : [@"t3_" stringByAppendingString:postID];
        if ([seen containsObject:fullName]) continue;
        [seen addObject:fullName];
        [fullNames addObject:fullName];
    }
    return [fullNames copy];
}

// The order a list pages through, taken on its first page. Reading a post
// bumps it to the front of the history; paging against a fresh order would
// skip or repeat posts below the ones already shown.
static os_unfair_lock sRecentlyReadOrderLock = OS_UNFAIR_LOCK_INIT;
static NSArray<NSString *> *sRecentlyReadOrder;

static NSArray<NSString *> *ApolloRecentlyReadOrder(void) {
    os_unfair_lock_lock(&sRecentlyReadOrderLock);
    NSArray<NSString *> *order = sRecentlyReadOrder;
    os_unfair_lock_unlock(&sRecentlyReadOrderLock);
    return order;
}

static void ApolloRecentlyReadSetOrder(NSArray<NSString *> *order) {
    os_unfair_lock_lock(&sRecentlyReadOrderLock);
    sRecentlyReadOrder = order;
    os_unfair_lock_unlock(&sRecentlyReadOrderLock);
}

// Post size. Apollo's feeds read the global UseCompactThumbnails (an Upvoted
// list has no per-feed RememberRedditPostSize entry) while building a page's
// sections, on the main thread, from either the page's completion or
// ListAdapter's row count. While either runs for this feed, that read answers
// with Recently Read's own size instead.
static NSUInteger sRecentlyReadSizeScope;
static NSString *const kApolloUseCompactThumbnailsKey = @"UseCompactThumbnails";

static BOOL ApolloRecentlyReadBeginSizeScope(void) {
    if (![NSThread isMainThread]) return NO;
    sRecentlyReadSizeScope++;
    return YES;
}

static void ApolloRecentlyReadEndSizeScope(BOOL began) {
    if (began) sRecentlyReadSizeScope--;
}

static void ApolloRecentlyReadInSizeScope(void (^block)(void)) {
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    block();
    ApolloRecentlyReadEndSizeScope(began);
}

static BOOL ApolloRecentlyReadUsesCompactPosts(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id own = [defaults objectForKey:UDKeyRecentlyReadCompactPosts];
    // objectForKey: rather than boolForKey:, which the override below answers.
    return [(own ?: [defaults objectForKey:kApolloUseCompactThumbnailsKey]) boolValue];
}

static void ApolloRecentlyReadRedraw(UIViewController *feed);
static NSHashTable<UIViewController *> *ApolloRecentlyReadOpenFeeds(void);

static void ApolloRecentlyReadFetchPage(RDKClient *client, NSArray<NSString *> *order, NSUInteger start,
                                        NSUInteger pageSize, NSUInteger skippedPages,
                                        ApolloRecentlyReadListingCompletion completion) {
    if (start >= order.count) {
        // Nil pagination ends the list (and picks Apollo's empty state).
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloRecentlyReadInSizeScope(^{ completion(@[], nil, nil); });
            // Apollo only redraws an empty first page for a subreddit, so a
            // cleared history would leave its old rows on screen.
            if (start == 0) {
                for (UIViewController *feed in ApolloRecentlyReadOpenFeeds().allObjects) ApolloRecentlyReadRedraw(feed);
            }
        });
        return;
    }
    NSRange range = NSMakeRange(start, MIN(pageSize, order.count - start));
    NSArray<NSString *> *pageNames = [order subarrayWithRange:range];
    [client thingsByFullNames:pageNames completion:^(NSArray *things, NSError *error) {
        if (error || !things) {
            ApolloLogError(@"[RecentlyRead] Page at %lu failed: %@", (unsigned long)start, error);
            ApolloRecentlyReadInSizeScope(^{ completion(nil, nil, error); });
            return;
        }
        NSMutableDictionary<NSString *, id> *linksByName = [NSMutableDictionary dictionaryWithCapacity:things.count];
        for (id thing in things) {
            if (![thing isKindOfClass:ApolloClassRDKLink]) continue;
            NSString *fullName = [(RDKLink *)thing fullName];
            if (fullName) linksByName[fullName] = thing;
        }
        BOOL hideNSFW = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyFilterNSFWRecentlyRead];
        NSMutableArray *links = [NSMutableArray arrayWithCapacity:pageNames.count];
        for (NSString *fullName in pageNames) {
            RDKLink *link = linksByName[fullName];
            if (!link || (hideNSFW && link.isNSFW)) continue;
            [links addObject:link];
        }

        NSUInteger end = NSMaxRange(range);
        if (links.count == 0 && end < order.count && skippedPages < kRecentlyReadMaxSkippedPages) {
            ApolloRecentlyReadFetchPage(client, order, end, pageSize, skippedPages + 1, completion);
            return;
        }
        RDKPagination *next = nil;
        if (end < order.count) {
            next = [ApolloClassRDKPagination paginationWithLimit:pageSize];
            next.after = pageNames.lastObject;
        }
        ApolloLog(@"[RecentlyRead] Served %lu posts (%lu-%lu of %lu)", (unsigned long)links.count,
                  (unsigned long)start, (unsigned long)end, (unsigned long)order.count);
        ApolloRecentlyReadInSizeScope(^{ completion(links, next, nil); });
    }];
}

static void ApolloRecentlyReadServe(RDKClient *client, RDKPagination *pagination, ApolloRecentlyReadListingCompletion completion) {
    NSString *after = pagination.after;
    NSArray<NSString *> *order = after.length ? ApolloRecentlyReadOrder() : nil;
    NSUInteger index = order ? [order indexOfObject:after] : NSNotFound;
    if (index == NSNotFound) {
        // A first page (or a cursor from an order that has since been replaced).
        order = ApolloRecentReadFullNames();
        ApolloRecentlyReadSetOrder(order);
        index = after.length ? [order indexOfObject:after] : NSNotFound;
    }
    NSUInteger start = after.length ? (index == NSNotFound ? order.count : index + 1) : 0;
    NSUInteger pageSize = pagination.limit > 0 ? MIN((NSUInteger)pagination.limit, kRecentlyReadMaxPageSize)
                                               : kRecentlyReadDefaultPageSize;
    ApolloRecentlyReadFetchPage(client, order, start, pageSize, 0, completion);
}

// PostsViewController's Swift designated initializer in Apollo 1.15.11. Its
// ObjC entry points trap, so it is found from initWithCoder:'s thunk and both
// are verified; any other binary fails closed.
typedef void *__attribute__((swiftcall)) (*ApolloPostsViewControllerInit)(
    const void *postsType, void *self __attribute__((swift_context)));

static ApolloPostsViewControllerInit ApolloPostsViewControllerInitEntry(void) {
    static ApolloPostsViewControllerInit entry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method coder = class_getInstanceMethod(ApolloClassPostsViewController, @selector(initWithCoder:));
        const uint8_t *coderIMP = coder ? (const uint8_t *)method_getImplementation(coder) : NULL;
        Dl_info binary;
        if (!coderIMP || !dladdr(coderIMP, &binary) || !binary.dli_fbase ||
            coderIMP - (const uint8_t *)binary.dli_fbase != 0x596f0c) {
            ApolloLog(@"[RecentlyRead] PostsViewController initializer not found (unsupported Apollo binary)");
            return;
        }
        const uint8_t *candidate = coderIMP - 0x15f4;
        const uint32_t expected[] = {0xd10503ff, 0xa90e6ffc, 0xa90f67fa, 0xa9105ff8, 0xa91157f6,
                                     0xa9124ff4, 0xa9137bfd, 0x9104c3fd, 0xaa0003fb};
        if (memcmp(candidate, expected, sizeof(expected)) != 0) {
            ApolloLog(@"[RecentlyRead] PostsViewController initializer prologue mismatch");
            return;
        }
        entry = (ApolloPostsViewControllerInit)candidate;
    });
    return entry;
}

static UIViewController *ApolloRecentlyReadMakeFeed(void) {
    ApolloPostsViewControllerInit init = ApolloPostsViewControllerInitEntry();
    Class feedClass = ApolloClassPostsViewController;
    if (!init || !feedClass) return nil;

    // .upvoted(username:): the small string's bytes inline, its length in the
    // top byte with the ASCII/small flags (0xE0), then the tag.
    const char *user = kRecentlyReadFeedUser.UTF8String;
    size_t length = strlen(user);
    if (length > 15) return nil;
    uint8_t postsType[40] __attribute__((aligned(16))) = {0};
    memcpy(postsType, user, length);
    postsType[15] = (uint8_t)(0xE0 | length);
    postsType[32] = kPostsTypeUpvotedTag;

    void *allocated = (__bridge_retained void *)[feedClass alloc];
    UIViewController *feed = CFBridgingRelease(init(postsType, allocated));
    if (feed) objc_setAssociatedObject(feed, &kRecentlyReadFeedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return feed;
}

// Pull to refresh, driven programmatically: a fresh first page, in the new order.
static void ApolloRecentlyReadReload(UIViewController *feed) {
    UIRefreshControl *refreshControl = ApolloObjectIvar(feed, "refreshControl");
    if (![refreshControl isKindOfClass:[UIRefreshControl class]]) return;
    [refreshControl beginRefreshing];
    [refreshControl sendActionsForControlEvents:UIControlEventValueChanged];
}

static char kRecentlyReadNavigationItemKey;
static char kRecentlyReadBarItemsKey;
static char kRecentlyReadListAdapterKey;
static char kRecentlyReadHideReadButtonKey;
static NSString *const kRecentlyReadTitle = @"Recently Read";

// Apollo's own feed-menu icon for the size a tap switches to.
static UIImage *ApolloRecentlyReadSizeImage(BOOL compact) {
    NSString *name = compact ? @"option-large-thumbnails"
        : ([[NSUserDefaults standardUserDefaults] boolForKey:@"CompactModeLeftThumbnails"]
               ? @"option-compact-thumbnails-left" : @"option-compact-thumbnails-right");
    UIImage *image = [UIImage imageNamed:name];
    if (!image) image = [UIImage systemImageNamed:compact ? @"rectangle.grid.1x2" : @"list.bullet"];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// ListAdapter's Swift row rebuild in Apollo 1.15.11 (self only, in x20). Apollo's
// own Compact/Large menu action calls it after saving the size, then reloads
// the table; that is what makes existing rows take the new size. Verified by
// prologue; any other binary fails closed (the caller falls back to a reload).
typedef void __attribute__((swiftcall)) (*ApolloListAdapterRebuild)(void *self __attribute__((swift_context)));

static ApolloListAdapterRebuild ApolloListAdapterRebuildEntry(void) {
    static ApolloListAdapterRebuild entry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // The adapter's ObjC thunks are hooked, so anchor on PostsViewController's
        // initWithCoder: thunk, which also pins the binary.
        Dl_info binary;
        Method coder = class_getInstanceMethod(ApolloClassPostsViewController, @selector(initWithCoder:));
        const uint8_t *coderIMP = coder ? (const uint8_t *)method_getImplementation(coder) : NULL;
        if (!coderIMP || !dladdr(coderIMP, &binary) || !binary.dli_fbase ||
            coderIMP - (const uint8_t *)binary.dli_fbase != 0x596f0c) return;
        const uint8_t *candidate = (const uint8_t *)binary.dli_fbase + 0x172b28;
        const uint32_t expected[] = {0xa9ba6ffc, 0xa90167fa, 0xa9025ff8, 0xa90357f6, 0xa9044ff4,
                                     0xa9057bfd, 0x910143fd, 0xd106c3ff, 0x910003f3};
        if (memcmp(candidate, expected, sizeof(expected)) != 0) {
            ApolloLog(@"[RecentlyRead] ListAdapter rebuild prologue mismatch");
            return;
        }
        entry = (ApolloListAdapterRebuild)candidate;
    });
    return entry;
}

// Redraw the loaded posts in the current size without refetching, the way
// Apollo's own menu action does.
static void ApolloRecentlyReadRedraw(UIViewController *feed) {
    id listAdapter = ApolloObjectIvar(feed, "listAdapter");
    id tableNode = listAdapter ? (ApolloObjectIvar(listAdapter, "tableNode") ?: ApolloReadSwiftWeakObjectIvar(listAdapter, "tableNode")) : nil;
    ApolloListAdapterRebuild rebuild = ApolloListAdapterRebuildEntry();
    if (!rebuild || ![tableNode respondsToSelector:@selector(reloadData)]) {
        ApolloLog(@"[RecentlyRead] Can't redraw in place; reloading instead");
        ApolloRecentlyReadReload(feed);
        return;
    }
    // Rows change height, so keep the top visible post in place, not the offset.
    // The first row whose middle is below the (translucent) bars is the one in view.
    NSIndexPath *anchor = nil;
    UITableView *tableView = [tableNode respondsToSelector:@selector(view)] ? ApolloSendObject(tableNode, @selector(view)) : nil;
    if ([tableView isKindOfClass:[UITableView class]]) {
        CGFloat visibleTop = tableView.contentOffset.y + tableView.adjustedContentInset.top;
        for (NSIndexPath *indexPath in [tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)]) {
            if (CGRectGetMidY([tableView rectForRowAtIndexPath:indexPath]) > visibleTop) {
                anchor = indexPath;
                break;
            }
        }
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    rebuild((__bridge void *)listAdapter);
    [tableNode reloadData];
    ApolloRecentlyReadEndSizeScope(began);
    SEL scroll = @selector(scrollToRowAtIndexPath:atScrollPosition:animated:);
    if (anchor && anchor.row > 0 && [tableNode respondsToSelector:scroll]) {
        ((void (*)(id, SEL, NSIndexPath *, UITableViewScrollPosition, BOOL))objc_msgSend)(
            tableNode, scroll, anchor, UITableViewScrollPositionTop, NO);
    }
}

// Recently Read feeds that are alive, for redraws Apollo doesn't do itself.
static NSHashTable<UIViewController *> *ApolloRecentlyReadOpenFeeds(void) {
    static NSHashTable *feeds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ feeds = [NSHashTable weakObjectsHashTable]; });
    return feeds;
}

@interface ApolloRecentlyReadFeedActions : NSObject
@property (nonatomic, weak) UIViewController *feed;
@property (nonatomic, weak) UIBarButtonItem *moreItem;
- (UIMenu *)menu;
@end

@implementation ApolloRecentlyReadFeedActions

- (UIMenu *)menu {
    __weak __typeof__(self) weakSelf = self;
    BOOL compact = ApolloRecentlyReadUsesCompactPosts();
    UIAction *size = [UIAction actionWithTitle:compact ? @"Large Thumbnails" : @"Compact Posts"
                                         image:ApolloRecentlyReadSizeImage(compact)
                                    identifier:nil
                                       handler:^(__unused UIAction *action) { [weakSelf toggleSize]; }];
    UIAction *clear = [UIAction actionWithTitle:@"Clear Read History"
                                          image:[UIImage systemImageNamed:@"trash"]
                                     identifier:nil
                                        handler:^(__unused UIAction *action) { [weakSelf confirmClear]; }];
    clear.attributes = UIMenuElementAttributesDestructive;
    return [UIMenu menuWithTitle:@"" children:@[
        size,
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[clear]],
    ]];
}

- (void)toggleSize {
    UIViewController *feed = self.feed;
    if (!feed) return;
    BOOL compact = !ApolloRecentlyReadUsesCompactPosts();
    [[NSUserDefaults standardUserDefaults] setBool:compact forKey:UDKeyRecentlyReadCompactPosts];
    ApolloLog(@"[RecentlyRead] Post size -> %@", compact ? @"compact" : @"large");
    self.moreItem.menu = [self menu];
    ApolloRecentlyReadRedraw(feed);
}

- (void)confirmClear {
    UIViewController *feed = self.feed;
    if (!feed) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear Read History"
        message:@"This will remove all recently read post entries and unmark all read posts. This cannot be undone."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIViewController *weakFeed = feed;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        ApolloMutateTrackerSet(^(NSMutableOrderedSet *trackerSet) {
            [trackerSet removeAllObjects];
        });
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ReadPostIDs"];
        ApolloRecentlyReadSetOrder(nil);
        // The reload's snapshot is ordered after the barrier clear above.
        UIViewController *strongFeed = weakFeed;
        if (strongFeed) ApolloRecentlyReadReload(strongFeed);
    }]];
    [feed presentViewController:alert animated:YES completion:nil];
}

@end

// Apollo titles the list "Upvoted" and resets its bar items, again each time a
// page arrives, so the feed's navigation item is tagged and those writes are
// replaced with Recently Read's as they happen.
static void ApolloRecentlyReadConfigureNavigationItem(UIViewController *feed) {
    UINavigationItem *item = feed.navigationItem;
    ApolloRecentlyReadFeedActions *actions = [ApolloRecentlyReadFeedActions new];
    actions.feed = feed;

    // A ••• menu like Apollo's own feeds: the layout switch and Clear History.
    // Apollo's own ••• glyph (the one its feeds' More button uses).
    UIImage *moreImage = [[UIImage imageNamed:@"option-more" inBundle:NSBundle.mainBundle compatibleWithTraitCollection:feed.traitCollection]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIBarButtonItem *moreItem = [[UIBarButtonItem alloc] initWithImage:moreImage ?: [UIImage systemImageNamed:@"ellipsis"]
                                                                  menu:[actions menu]];
    moreItem.accessibilityLabel = @"More Options";
    actions.moreItem = moreItem;

    // The item keeps the actions alive through this array.
    objc_setAssociatedObject(item, &kRecentlyReadBarItemsKey, @[moreItem, actions], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(item, &kRecentlyReadNavigationItemKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    feed.title = kRecentlyReadTitle;
    item.title = kRecentlyReadTitle;
    [item setRightBarButtonItems:@[] animated:NO];

    id listAdapter = ApolloObjectIvar(feed, "listAdapter");
    if (listAdapter) objc_setAssociatedObject(listAdapter, &kRecentlyReadListAdapterKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ApolloRecentlyReadOpenFeeds() addObject:feed];

    // Hide Read would hide every post here (they're all read), unconfirmed.
    UIButton *hideRead = ApolloObjectIvar(feed, "hideReadPostsButton");
    if ([hideRead isKindOfClass:[UIButton class]]) {
        objc_setAssociatedObject(hideRead, &kRecentlyReadHideReadButtonKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hideRead.hidden = YES;
    }
}

static NSArray<UIBarButtonItem *> *ApolloRecentlyReadBarItems(UINavigationItem *item) {
    NSArray *stored = objc_getAssociatedObject(item, &kRecentlyReadBarItemsKey);
    return stored.count > 0 ? @[stored[0]] : nil;
}

@interface _TtC6Apollo19PostsViewController : UIViewController
@end

%hook _TtC6Apollo19PostsViewController

- (void)hideReadPostsButtonTappedWithSender:(id)sender {
    if (ApolloIsRecentlyReadFeed(self)) return;
    %orig;
}

// Apollo's appearance and list notifications rebuild each open feed's rows from
// the global Post Size. For Recently Read, its handlers run in the size scope.

- (void)postCellAppearanceUpdatedWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)postsShowSubredditIconsChangedWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)reloadTableDataWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)appFontChangedWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)reloadPostsWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)keywordFiltersChangedWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)linkHiddenWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)linkDeletedWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)modelObjectUpdatedNotificationReceived:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)redditAccountChangedWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)hideReadPostsButtonUpdatedWithNotification:(NSNotification *)notification {
    if (!ApolloIsRecentlyReadFeed(self)) {
        %orig;
        return;
    }
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    %orig;
    ApolloRecentlyReadEndSizeScope(began);
}

- (void)viewDidLoad {
    if (ApolloIsRecentlyReadFeed(self)) {
        // Before Apollo's viewDidLoad, which builds the first sections.
        ApolloRecentlyReadConfigureNavigationItem(self);
        BOOL began = ApolloRecentlyReadBeginSizeScope();
        %orig;
        ApolloRecentlyReadEndSizeScope(began);
        return;
    }
    %orig;
}

%end

// Profile row (see "Profile row" below).
static UIViewController *ApolloRecentlyReadOwnProfileForAdapter(id adapter);
static id (^ApolloRecentlyReadProfileRowBlock(id (^originalBlock)(void), id (^separatorBlock)(void)))(void);

@interface _TtC6Apollo11ListAdapter : NSObject
@end

%hook _TtC6Apollo11ListAdapter

- (NSInteger)tableNode:(id)tableNode numberOfRowsInSection:(NSInteger)section {
    if (!objc_getAssociatedObject(self, &kRecentlyReadListAdapterKey)) return %orig;
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    NSInteger rows = %orig;
    ApolloRecentlyReadEndSizeScope(began);
    return rows;
}

- (id)tableNode:(id)tableNode nodeBlockForRowAtIndexPath:(NSIndexPath *)indexPath {
    id (^originalBlock)(void) = %orig;
    // Only your own profile's list; every other list keeps Apollo's factory.
    if (!originalBlock || indexPath.row == 0 || !ApolloRecentlyReadOwnProfileForAdapter(self)) return originalBlock;
    // Profile rows alternate with separator rows; reuse the one before Friends.
    NSIndexPath *previous = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
    id (^separatorBlock)(void) = %orig(tableNode, previous);
    return ApolloRecentlyReadProfileRowBlock(originalBlock, separatorBlock);
}


%end

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)key {
    if (sRecentlyReadSizeScope > 0 && [NSThread isMainThread] && [key isEqualToString:kApolloUseCompactThumbnailsKey]) {
        return ApolloRecentlyReadUsesCompactPosts();
    }
    return %orig;
}

%end

%hook UINavigationItem

- (void)setTitle:(NSString *)title {
    if (title && objc_getAssociatedObject(self, &kRecentlyReadNavigationItemKey)) {
        %orig(kRecentlyReadTitle);
        return;
    }
    %orig;
}

- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)animated {
    NSArray<UIBarButtonItem *> *ours = ApolloRecentlyReadBarItems(self);
    // Re-applying the same items still relays out the bar and can truncate the title.
    if (ours && [self.rightBarButtonItems isEqualToArray:ours]) return;
    %orig(ours ?: items, animated);
}

- (void)setRightBarButtonItem:(UIBarButtonItem *)item animated:(BOOL)animated {
    NSArray<UIBarButtonItem *> *ours = ApolloRecentlyReadBarItems(self);
    if (ours) {
        [self setRightBarButtonItems:ours animated:animated];
        return;
    }
    %orig;
}

%end

// MARK: Remove from Recently Read
//
// The post's ••• menu (button or long press) gains a row when the post is in
// this feed. The cell arms its RDKLink on the tap; the spec claims it once.
static __weak id sRecentlyReadArmedLink;
static __weak UIViewController *sRecentlyReadArmedFeed;
static CFAbsoluteTime sRecentlyReadArmedAt;
static char kRecentlyReadMenuLinkKey;
static char kRecentlyReadMenuFeedKey;

static void ApolloRecentlyReadArmFromCellNode(id node) {
    if (![node respondsToSelector:@selector(closestViewController)]) return;
    id controller = ((id (*)(id, SEL))objc_msgSend)(node, @selector(closestViewController));
    if (!ApolloIsRecentlyReadFeed(controller)) return;
    id link = ApolloObjectIvar(node, "link");
    if (![link isKindOfClass:ApolloClassRDKLink]) return;
    sRecentlyReadArmedLink = link;
    sRecentlyReadArmedFeed = controller;
    sRecentlyReadArmedAt = CFAbsoluteTimeGetCurrent();
}

static void ApolloRecentlyReadRemoveLink(RDKLink *link, UIViewController *feed) {
    NSString *fullName = link.fullName;
    if (fullName.length == 0) return;
    NSString *bareID = ApolloBarePostID(fullName);
    ApolloMutateTrackerSet(^(NSMutableOrderedSet *trackerSet) {
        [trackerSet removeObject:fullName];
        [trackerSet removeObject:bareID];
    });
    NSMutableArray *savedIDs = [[[NSUserDefaults standardUserDefaults] stringArrayForKey:@"ReadPostIDs"] mutableCopy];
    if (savedIDs) {
        [savedIDs removeObject:fullName];
        [savedIDs removeObject:bareID];
        [[NSUserDefaults standardUserDefaults] setObject:savedIDs forKey:@"ReadPostIDs"];
    }
    ApolloLog(@"[RecentlyRead] Removed %@ from history", fullName);
    NSMutableArray<NSString *> *order = [ApolloRecentlyReadOrder() mutableCopy];
    [order removeObject:fullName];
    ApolloRecentlyReadSetOrder(order);
    if (!feed) return;
    // Drop the row in place through the feed's own deleted-post handler, sent
    // only to this feed (the global notification would remove it everywhere).
    SEL deleted = @selector(linkDeletedWithNotification:);
    if (![feed respondsToSelector:deleted]) {
        ApolloRecentlyReadReload(feed);
        return;
    }
    NSNotification *note = [NSNotification notificationWithName:@"com.christianselig.LinkDeleted"
                                                          object:link
                                                        userInfo:@{@"deletedLink": link}];
    BOOL began = ApolloRecentlyReadBeginSizeScope();
    ((void (*)(id, SEL, id))objc_msgSend)(feed, deleted, note);
    ApolloRecentlyReadEndSizeScope(began);
}

%hook _TtC6Apollo17LargePostCellNode
- (void)moreOptionsButtonTappedWithSender:(id)sender {
    ApolloRecentlyReadArmFromCellNode(self);
    %orig;
}
- (void)longPressedWithGestureRecognizer:(UIGestureRecognizer *)recognizer {
    ApolloRecentlyReadArmFromCellNode(self);
    %orig;
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)moreOptionsButtonTappedWithSender:(id)sender {
    ApolloRecentlyReadArmFromCellNode(self);
    %orig;
}
- (void)longPressedWithGestureRecognizer:(UIGestureRecognizer *)recognizer {
    ApolloRecentlyReadArmFromCellNode(self);
    %orig;
}
%end

static void ApolloRecentlyReadRegisterMenuRow(void) {
    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"RecentlyReadRemove";
    spec.placement = ApolloActionMenuPlacementAppend;
    spec.legacyDismissesSheet = YES;
    spec.matches = ^BOOL(id actionController, __unused NSString *menuTitle) {
        id link = sRecentlyReadArmedLink;
        sRecentlyReadArmedLink = nil;
        if (!link || CFAbsoluteTimeGetCurrent() - sRecentlyReadArmedAt > 1.5) return NO;
        objc_setAssociatedObject(actionController, &kRecentlyReadMenuLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSHashTable *feed = [NSHashTable weakObjectsHashTable];
        if (sRecentlyReadArmedFeed) [feed addObject:sRecentlyReadArmedFeed];
        objc_setAssociatedObject(actionController, &kRecentlyReadMenuFeedKey, feed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    };
    spec.title = ^NSString *(__unused id controller, __unused UITableViewCell *donor) {
        return @"Remove from Recently Read";
    };
    spec.image = ^UIImage *(__unused id controller, __unused UITableViewCell *donor) {
        return ApolloActionMenuSymbolIcon(@"clock.badge.xmark");
    };
    spec.perform = ^(id controller) {
        RDKLink *link = objc_getAssociatedObject(controller, &kRecentlyReadMenuLinkKey);
        if (!link) return;
        UIViewController *feed = [objc_getAssociatedObject(controller, &kRecentlyReadMenuFeedKey) anyObject];
        __weak UIViewController *weakFeed = feed;
        dispatch_block_t remove = ^{ ApolloRecentlyReadRemoveLink(link, weakFeed); };
        if (!ApolloNativeActionMenuPerformAfterDismissal(controller, remove)) remove();
    };
    // Glass menu: first, in its own section. The legacy sheet can only append.
    void (^perform)(id) = spec.perform;
    spec.buildElement = ^(id controller, NSMutableArray<UIMenuElement *> *children) {
        UIAction *action = [UIAction actionWithTitle:@"Remove from Recently Read"
                                               image:ApolloActionMenuSymbolIcon(@"clock.badge.xmark")
                                          identifier:nil
                                             handler:^(__unused UIAction *a) { perform(controller); }];
        action.attributes = UIMenuElementAttributesDestructive;
        UIMenu *section = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                        options:UIMenuOptionsDisplayInline children:@[action]];
        [children insertObject:section atIndex:0];
    };
    ApolloActionMenuRegister(spec);
}

// MARK: Profile row
//
// Your own profile lists Recently Read with your other post lists, right below
// Hidden & Deleted (ApolloHiddenContentMenu.xm draws that one under Saved).
// This row sits on top of the next native row, Friends, so the two features
// stay independent of each other and of hook order. It is a second copy of
// Apollo's own Friends row, retitled and re-iconed, so it keeps native layout,
// theming and the disclosure chevron.

extern NSString *ApolloUsernameFromProfileViewController(UIViewController *viewController);
void ApolloRecentlyReadPresentFromViewController(UIViewController *fromViewController);

@interface ASDisplayNode (ApolloRecentlyReadRow)
@property (nonatomic) BOOL automaticallyManagesSubnodes;
@property (nonatomic, copy) id (^layoutSpecBlock)(id node, struct ApolloTextureSizeRange range);
@end

@interface ASImageNode (ApolloRecentlyReadRow)
@property (nonatomic, strong) UIImage *image;
@end

static char kRecentlyReadRowTitleKey;
static char kRecentlyReadRowIconKey;
static NSString *const kRecentlyReadRowTitle = @"Recently Read";

static UIViewController *ApolloRecentlyReadOwnProfileForAdapter(id adapter) {
    UIViewController *owner = ApolloReadSwiftWeakObjectIvar(adapter, "viewController");
    if (![owner isKindOfClass:ApolloClassProfileViewController]) return nil;
    NSString *profileUsername = ApolloUsernameFromProfileViewController(owner);
    NSString *activeUsername = ApolloActiveAccountUsername();
    if (profileUsername.length == 0 || activeUsername.length == 0 ||
        [profileUsername caseInsensitiveCompare:activeUsername] != NSOrderedSame) return nil;
    return owner;
}

// Apollo re-applies its row title and icon (themes, text size); keep ours.
%hook ASTextNode
- (void)setAttributedText:(NSAttributedString *)text {
    if (text.length && objc_getAssociatedObject(self, &kRecentlyReadRowTitleKey)) {
        NSMutableAttributedString *replacement = [text mutableCopy];
        [replacement replaceCharactersInRange:NSMakeRange(0, replacement.length) withString:kRecentlyReadRowTitle];
        %orig(replacement);
        return;
    }
    %orig(text);
}
%end

%hook ASImageNode
- (void)setImage:(UIImage *)image {
    if (objc_getAssociatedObject(self, &kRecentlyReadRowIconKey)) {
        // Fitted to the 28-point footprint of Apollo's own row artwork, as a
        // flat template so Apollo's redraws tint it like its neighbours.
        static UIImage *icon;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightRegular];
            UIImage *symbol = [[UIImage systemImageNamed:@"clock.arrow.circlepath" withConfiguration:configuration]
                imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            CGSize canvas = CGSizeMake(28, 28);
            // Keep the symbol's proportions; 26 points tall matches the
            // visible height of the neighbouring row glyphs.
            CGFloat height = 26;
            CGSize size = CGSizeMake(height * symbol.size.width / MAX(symbol.size.height, 1), height);
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas];
            icon = [[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
                [symbol drawInRect:CGRectMake((canvas.width - size.width) / 2,
                                             (canvas.height - size.height) / 2, size.width, size.height)];
            }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        });
        image = icon;
    }
    %orig(image);
}
%end

@interface ApolloRecentlyReadProfileTap : NSObject
+ (instancetype)shared;
- (void)open:(UITapGestureRecognizer *)gesture;
@end

@implementation ApolloRecentlyReadProfileTap
+ (instancetype)shared {
    static ApolloRecentlyReadProfileTap *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [self new]; });
    return target;
}
- (void)open:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) return;
    for (UIResponder *responder = gesture.view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:ApolloClassProfileViewController]) {
            ApolloRecentlyReadPresentFromViewController((UIViewController *)responder);
            return;
        }
    }
}
@end

// Wraps the Friends row's factory: [Recently Read, separator, Friends].
static id (^ApolloRecentlyReadProfileRowBlock(id (^originalBlock)(void), id (^separatorBlock)(void)))(void) {
    return [^id {
        ASDisplayNode *original = originalBlock();
        if (![original isKindOfClass:ApolloClassProfileFeatureCellNode]) return original;
        ASTextNode *title = ApolloReadObjectIvar(original, "titleNode");
        NSString *friends = [[NSBundle mainBundle] localizedStringForKey:@"Friends" value:@"Friends" table:nil];
        if (![title.attributedText.string isEqualToString:friends]) return original;

        // A fresh, fully themed native row from the same factory.
        ASDisplayNode *row = originalBlock();
        if (row == original || ![row isKindOfClass:[original class]]) return original;
        ASDisplayNode *separator = separatorBlock ? separatorBlock() : nil;
        if (![separator isKindOfClass:ApolloClassThinSeparatorCellNode]) {
            ApolloLog(@"[RecentlyRead] Expected a native separator before Friends; profile row skipped");
            return original;
        }
        ASTextNode *rowTitle = ApolloReadObjectIvar(row, "titleNode");
        ASImageNode *rowIcon = ApolloReadObjectIvar(row, "iconNode");
        objc_setAssociatedObject(rowTitle, &kRecentlyReadRowTitleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(rowIcon, &kRecentlyReadRowIconKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        rowTitle.attributedText = rowTitle.attributedText;
        rowIcon.image = rowIcon.image;
        [row onDidLoad:^(ASDisplayNode *loaded) {
            UIView *view = loaded.view;
            view.accessibilityLabel = kRecentlyReadRowTitle;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[ApolloRecentlyReadProfileTap shared]
                                                                                  action:@selector(open:)];
            tap.cancelsTouchesInView = YES;
            [view addGestureRecognizer:tap];
        }];

        Class cellNodeClass = ApolloClassASCellNode;
        if (!cellNodeClass) return original;
        ASDisplayNode *wrapper = [cellNodeClass new];
        wrapper.backgroundColor = UIColor.clearColor;
        wrapper.automaticallyManagesSubnodes = YES;
        // The wrapper takes Friends' native row: keep its label, and expose
        // both rows so the Duo portrait shortcut grid includes them.
        wrapper.accessibilityLabel = friends;
        objc_setAssociatedObject(wrapper, NSSelectorFromString(@"apollo_profileShortcutChildren"),
                                 @[row, original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        wrapper.layoutSpecBlock = ^id(__unused id node, __unused struct ApolloTextureSizeRange range) {
            return [ApolloClassASStackLayoutSpec stackLayoutSpecWithDirection:0 spacing:0 justifyContent:0 alignItems:3
                                                                     children:@[row, separator, original]];
        };
        ApolloLog(@"[RecentlyRead] Added profile row above Friends");
        return wrapper;
    } copy];
}

@interface _TtC6Apollo20FloatingActionButton : UIButton
@end

%hook _TtC6Apollo20FloatingActionButton
- (void)setHidden:(BOOL)hidden {
    %orig(objc_getAssociatedObject(self, &kRecentlyReadHideReadButtonKey) ? YES : hidden);
}
%end

// The list is an Upvoted one, so Apollo's empty state says "No upvoted posts".
static NSString *const kRecentlyReadNativeEmptyText = @"No upvoted posts";

static void ApolloRecentlyReadFixEmptyLabel(UILabel *label) {
    if (!label.window || ![label.text isEqualToString:kRecentlyReadNativeEmptyText]) return;
    for (UIResponder *responder = label.nextResponder; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:[UIViewController class]]) continue;
        if (ApolloIsRecentlyReadFeed(responder)) label.text = @"No recently read posts";
        return;
    }
}

@interface _TtC6Apollo15EmptyStateLabel : UILabel
@end

%hook _TtC6Apollo15EmptyStateLabel
- (void)didMoveToWindow {
    %orig;
    ApolloRecentlyReadFixEmptyLabel(self);
}
- (void)setText:(NSString *)text {
    %orig;
    ApolloRecentlyReadFixEmptyLabel(self);
}
%end

%hook RDKClient

- (id)upvotedLinksForUser:(id)user pagination:(RDKPagination *)pagination completion:(ApolloRecentlyReadListingCompletion)completion {
    if (![user isKindOfClass:[NSString class]] || ![user isEqualToString:kRecentlyReadFeedUser] || !completion) {
        return %orig;
    }
    ApolloRecentlyReadServe(self, pagination, completion);
    // Apollo discards the returned task.
    return nil;
}

%end

// The profile row (below) calls this to push the screen.
void ApolloRecentlyReadPresentFromViewController(UIViewController *fromViewController) {
    UINavigationController *navigationController = fromViewController.navigationController;
    if (!navigationController) {
        ApolloLog(@"[RecentlyRead] No navigation controller to push Recently Read from %@", fromViewController);
        return;
    }
    UIViewController *feed = ApolloRecentlyReadMakeFeed();
    if (!feed) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Recently Read Unavailable"
            message:@"This version of Apollo isn't supported."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [fromViewController presentViewController:alert animated:YES completion:nil];
        return;
    }
    [navigationController pushViewController:feed animated:YES];
}

// MARK: - Bump Recently Read on Revisit
//
// NSMutableOrderedSet.addObject: is a no-op for existing items - revisiting
// a post leaves it at its original position.  Hook it so that when the
// ReadPostsTracker's readPostIDs set already contains the post ID, we remove
// it first, causing addObject: to re-append at the end (most-recent slot).
// Fires for every add regardless of caller: native feed taps, our marks, and
// (caveat) Apollo Premium's "visited" re-adds during feed cell rendering,
// which can reorder history for Premium accounts just by scrolling - those
// adds are indistinguishable from real marks at this level, and gating them
// out would also break feed-tap revisit bumps.

%hook NSMutableOrderedSet

- (void)addObject:(id)object {
    // Runs for every ordered set in the app; getTrackerReadPostIDs() caches,
    // so after first resolution this is a pointer compare.
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    BOOL isTracker = trackerSet && self == trackerSet;
    if (isTracker && object && [self containsObject:object]) {
        ApolloLog(@"[RecentlyRead] Bumping existing post to most-recent: %@", object);
        [self removeObject:object];
    }
    %orig;
    if (isTracker) ApolloSchedulePostReadStateDidChange();
}

// Native unmarks/history eviction must refresh existing cards too. Restrict
// every notification to the captured set; these selectors otherwise run on
// ordered collections throughout the app. Nested primitive calls coalesce.
- (void)removeObject:(id)object {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    BOOL changed = trackerSet && self == trackerSet && object && [self containsObject:object];
    %orig;
    if (changed) ApolloSchedulePostReadStateDidChange();
}

- (void)removeObjectAtIndex:(NSUInteger)index {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    BOOL isTracker = trackerSet && self == trackerSet;
    %orig;
    if (isTracker) ApolloSchedulePostReadStateDidChange();
}

- (void)removeObjectsInRange:(NSRange)range {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    BOOL changed = trackerSet && self == trackerSet && range.length > 0;
    %orig;
    if (changed) ApolloSchedulePostReadStateDidChange();
}

- (void)removeAllObjects {
    NSMutableOrderedSet *trackerSet = getTrackerReadPostIDs();
    BOOL changed = trackerSet && self == trackerSet && self.count > 0;
    %orig;
    if (changed) ApolloSchedulePostReadStateDidChange();
}

%end

// MARK: - Mark Posts Read When Opened Via URL Scheme
//
// Native Apollo only marks posts as read through PostCellActionTaker (feed tap
// path via sub_100324a84). Posts opened via apollo:// URL scheme (e.g. from
// Safari, share links, or our Recently Read list) skip the read-tracking
// entirely because CommentsViewController never self-marks (confirmed in
// Hopper). The RDKLink is fetched asynchronously on that path, so the old
// single fixed-delay retry missed slow fetches and quick back-outs entirely
// (#609). Instead, try to mark from several deterministic points:
//  - viewDidAppear (link already present, e.g. re-appear after a deeper push)
//  - viewDidLayoutSubviews (content laid out right after the async fetch)
//  - viewWillDisappear (last chance, and early enough: a nav pop runs this
//    BEFORE the underlying screen's viewWillAppear auto-refresh)
//  - one timed retry as a fallback for "link loaded but nothing relaid out
//    and the user backgrounded the app while reading"
// The helper disarms itself via an associated flag after the first success.

static const void *kCommentsVCMarkedReadKey = &kCommentsVCMarkedReadKey;

static void ApolloCommentsVCTryMarkRead(id commentsVC, const char *trigger) {
    if (!commentsVC) return;
    if (objc_getAssociatedObject(commentsVC, kCommentsVCMarkedReadKey)) return;

    // Respect the "Disable Marking Posts Read" setting (disarm - no point
    // rechecking on every layout pass)
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DisableMarkingPostsRead"]) {
        objc_setAssociatedObject(commentsVC, kCommentsVCMarkedReadKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // Read the link ivar (RDKLink, nil until the URL-scheme fetch completes).
    // Cache the Ivar - this runs on every layout pass while armed.
    static Ivar sLinkIvar = NULL;
    static BOOL sLinkIvarLookupDone = NO;
    if (!sLinkIvarLookupDone) {
        sLinkIvarLookupDone = YES;
        sLinkIvar = class_getInstanceVariable([commentsVC class], "link");
    }
    if (!sLinkIvar) return;
    id link = object_getIvar(commentsVC, sLinkIvar);
    if (!link) return; // stay armed - a later trigger retries

    NSString *identifier = [link performSelector:@selector(identifier)];
    if (identifier.length == 0) return;

    if (ApolloMarkPostIDAsRead(identifier)) {
        objc_setAssociatedObject(commentsVC, kCommentsVCMarkedReadKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[RecentlyRead] Marked post read from CommentsVC (%s): %@", trigger, identifier);
    }
    // Tracker not captured yet: stay armed and let a later trigger retry.
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    ApolloCommentsVCTryMarkRead((id)self, "viewDidAppear");

    if (!objc_getAssociatedObject((id)self, kCommentsVCMarkedReadKey)) {
        __weak id weakSelf = (id)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloCommentsVCTryMarkRead(weakSelf, "timed retry");
        });
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    // ASDK can invoke viewDidLayoutSubviews off-main during deferred CA
    // transaction flushes (same guard as ApolloInboxCommentScroll's hook).
    if (![NSThread isMainThread]) return;
    // One associated-object lookup once disarmed. Reads only - no layout
    // inputs are written here (see the layoutSubviews rule in CLAUDE.md).
    ApolloCommentsVCTryMarkRead((id)self, "layout");
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    ApolloCommentsVCTryMarkRead((id)self, "viewWillDisappear");
}

%end

%ctor {
    // Capture the ReadPostsTracker singleton when Apollo allocates it
    ApolloCaptureFirstSwiftAllocation(objc_getClass("_TtC6Apollo16ReadPostsTracker"), ApolloRecentlyReadCaptureTracker);

    // Native save completes (including its defaults write) before posting this.
    // In particular it arrives after a comments controller's viewDidDisappear,
    // later than the feed's initial viewWillAppear refresh on a navigation pop.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"com.christianselig.ReadCommentsUpdated"
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(__unused NSNotification *note) {
        ApolloSchedulePostReadStateDidChange();
    }];

    %init;
    ApolloRecentlyReadRegisterMenuRow();
}
