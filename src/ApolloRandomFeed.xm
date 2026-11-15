// ApolloRandomFeed.xm
//
// Random / Random NSFW feeds after Reddit stopped serving /r/random and
// /r/randnsfw. The tweak rewrites those requests to a community from the
// configured list (Settings > Subreddits). This file keeps a pull-to-refresh
// on such a feed moving to a new community.
//
// Why a plain rewrite was not enough:
//   - Apollo renames a random feed only from the posts in the listing it lands
//     on. A banned or private community returns an empty listing, so the title
//     stays on the previous community (or the "Random" placeholder, for a first
//     pick) and Apollo shows "banned" against it.
//   - Apollo's next pull-to-refresh requests the community it resolved
//     (/r/<shown>/hot), not /r/random, so the feed stayed pinned there.
//   - After a banned roll Apollo's model (`currentSubreddit`, and probably the
//     Swift `randomSubredditName`) still names the community before it, so that
//     is what its next refresh or sort change requests, while the screen shows
//     the rolled one.
//
// What this file does:
//   1. Arm. -[PostsViewController refreshControlActivatedWithSender:] on a
//      random feed (PostsType tag 5) arms one pending roll: the communities
//      being left and a pick from the feed's list that is none of them
//      (ApolloRandomPlanArm). The list (safe or NSFW) is read from what is on
//      screen, never remembered on the controller: Random and Random NSFW
//      share tag 5 and the jump bar switches between them in place. A
//      placeholder JumpBar label names it ("Random" / "RandNSFW"; the
//      navigation title reads "Random" on both), else the record of recent
//      picks, else the kind of the feed's last route, else the one list that
//      holds the community; when none can tell, nothing is armed. Only
//      this gesture rolls; a sort change, a filter toggle or a
//      reload Apollo starts itself does not. Tapping the sort button drops a
//      roll no request has used yet.
//   2. Pending route. ApolloRandomRequestByRolling, called from Tweak.xm's
//      NSURLSession hooks on whatever thread Apollo creates the task, rewrites
//      the first listing page and the about of a leaving community to the pick
//      while the roll is live. Explicit /r/random and /r/randnsfw requests
//      always get a pick, stateless when no roll matches. The tweak's own
//      fetches (the completion-handler entry point, probe-tagged requests,
//      and calls through Apollo's RDKClient wrapped in
//      ApolloRandomTweakFetchScope) only ever get the stateless explicit
//      pick: ApolloSubredditInfoCache caches an about under the name it asked
//      for, so rewriting it would store B's data under A.
//   3. Title guard. When a request first uses the roll, a guard on that feed
//      turns on (main queue): it shows the pick in the navigation item title
//      and the JumpBar name label, replacing a leaving community or the
//      Random placeholder, and rewrites later writes of those to the pick.
//      Nothing here depends on when Apollo's response handler runs.
//   4. Confirmation. When Apollo itself writes the pick and its model
//      (currentSubreddit.name or randomSubredditName) names the pick too, the
//      listing loaded: the guard is confirmed and turns off, its job done. The
//      model check matters because Apollo might copy our own rewrite back
//      (e.g. refresh the label from navigationItem.title). A guard that never
//      confirms belongs to a banned/private pick, and Apollo's model still
//      names a leaving community.
//   5. Sticky route. While an unconfirmed guard's feed is the one on screen,
//      its current community is the pick, so a later listing or about of a
//      leaving community from Apollo (a sort change after the roll expired) is
//      sent to the pick too: content and title never disagree. This runs only
//      on the main thread, where "on screen" can be checked; off the main
//      thread such a request goes out unchanged and the guard is turned off
//      instead. The guard's feed must still be a random feed (a jump-bar
//      switch to r/<leaving> sends its listing before its title write), and
//      no other on-screen feed (an iPad pane, another column, an r/<leaving>
//      feed pushed on top) may show that community, since it could be the one
//      asking.
//   6. Stateless claim. A stateless random listing from Apollo (a first open,
//      a jump-bar switch, a refresh that armed nothing) names no feed, so on
//      the main thread the one on-screen random feed whose label is that
//      kind's placeholder, or which still shows its own failed route, takes
//      it: a guard shows the routed community there (a banned listing never
//      makes Apollo write it). Retried briefly while the pushed feed reaches
//      a window; with several candidates nothing is relabeled.
//
// Nothing here changes Apollo's model: `currentSubreddit` and
// `randomSubredditName` are read, never written. Renaming the model in place
// left every other field (fullName, over18, subscription state) describing the
// old community.
//
// Not verifiable without Hopper (no Apollo binary or simulator was available
// when this was written; verify on a device or in the sim):
//   - The visible feed title is drawn by Apollo's JumpBar titleView
//     (`jumpBar` ivar, its `nameLabel`), which Apollo sets separately from
//     navigationItem.title (the mod feed shows "Modded Subs" while
//     navigationItem.title is "Mod", see ApolloSubredditHeaders.xm). Whether
//     Apollo writes that label through -setText: or -setAttributedText: (both
//     are guarded) and whether it holds the bare slug is unconfirmed; a label
//     whose text is not exactly one community name or a placeholder is left
//     alone.
//   - What Apollo's refresh requests: `currentSubreddit.name` and
//     `randomSubredditName` are both treated as requested names.
//   - Which name Apollo's "banned"/"private" message uses. If it is built from
//     the model, it can still name the community before the roll.
//   - Whether the refresh action creates its listing task synchronously. The
//     arm window (kApolloRandomArmWindow) allows for a short delay.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "ApolloRandomFeed.h"
#import "ApolloSubredditName.h"
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloWebJSON.h"

// Defined in ApolloSubredditHeaders.xm (Objective-C++ like this file, so the
// declaration's linkage matches).
extern NSInteger ApolloPostsTypeTagFromViewController(UIViewController *viewController);
// ApolloSwiftIvarBridge.swift: a retained NSString copy of a Swift String?, or
// NULL for nil. Swift decodes the Optional layout.
extern "C" void *ApolloSwiftCopyOptionalString(const void *storage);

// PostsType case tag for Random / Random NSFW (kApolloPostsTypeRandom in
// ApolloSubredditHeaders.xm).
static const NSInteger kApolloRandomPostsTypeTag = 5;
// Picks remembered for kind inference (an NSCache-backed list can be evicted).
static const NSUInteger kApolloRandomPickedKindLimit = 64;

static char kApolloRandomTitleGuardKey;
// The feed's last random route (an ApolloRandomRoute: kind and name), set when
// a used roll or a claimed stateless pick turns its guard on. Main thread only.
static char kApolloRandomRoutedKey;
// Delays before the 2nd, 3rd and 4th attempt to find the feed a stateless
// listing belongs to: a pushed feed may not be in a window yet, and Apollo may
// write its placeholder label after sending the request.
static const NSTimeInterval kApolloRandomClaimRetryDelays[] = {0.15, 0.4, 1.0};

// One feed's title guard. Main thread only.
@interface ApolloRandomTitleGuard : NSObject
@property(nonatomic, weak) UIViewController *feed;
@property(nonatomic, weak) UINavigationItem *navigationItem;
@property(nonatomic, weak) UILabel *nameLabel;
@property(nonatomic) ApolloRandomFeedKind kind;
@property(nonatomic, copy) NSArray<NSString *> *leavingNames;
@property(nonatomic, copy) NSString *rolledName;
@property(nonatomic) BOOL active;
// Apollo itself wrote `rolledName`: the pick loaded.
@property(nonatomic) BOOL confirmed;
@end

@implementation ApolloRandomTitleGuard
@end

// Active guards (main thread only), and their count so the UINavigationItem
// and UILabel hooks cost one load when nothing is guarded. Those setters run
// on any thread, so the count is only written on the main thread and read
// with relaxed atomics (ApolloRandomGuardCount / ApolloRandomPublishGuardCount).
static NSMutableArray<ApolloRandomTitleGuard *> *sApolloRandomActiveGuards;
static NSUInteger sApolloRandomActiveGuardCount;

static inline NSUInteger ApolloRandomGuardCount(void) {
    return __atomic_load_n(&sApolloRandomActiveGuardCount, __ATOMIC_RELAXED);
}

// Main thread only.
static inline void ApolloRandomPublishGuardCount(void) {
    __atomic_store_n(&sApolloRandomActiveGuardCount, (NSUInteger)sApolloRandomActiveGuards.count, __ATOMIC_RELAXED);
}
// Set while this file writes the pick itself, so that write is not mistaken
// for Apollo confirming it. Main thread only.
static BOOL sApolloRandomApplying;

// Shared with the request rewrite on any thread, under one lock:
//   - the armed roll and the guard it turns on;
//   - the leaving names of active guards, for the off-main sticky check;
//   - the record of recent picks and the kind each was drawn for.
static os_unfair_lock sApolloRandomLock = OS_UNFAIR_LOCK_INIT;
static ApolloRandomPendingRoll *sApolloRandomPending;
static ApolloRandomTitleGuard *sApolloRandomPendingGuard;
static NSArray<NSString *> *sApolloRandomStickyNames;
static NSMutableDictionary<NSString *, NSNumber *> *sApolloRandomPickedKinds;
static NSMutableArray<NSString *> *sApolloRandomPickedOrder;
// The last stateless route of each kind (Apollo's feed requests only), so a
// listing and its about land on the same community.
static ApolloRandomStatelessMemo *sApolloRandomStatelessSafe;
static ApolloRandomStatelessMemo *sApolloRandomStatelessNSFW;
// Bumped whenever a route lands on a feed (a roll's first request, a stateless
// listing), so a delayed claim of an older stateless listing gives up.
static NSUInteger sApolloRandomRouteGeneration;

static NSString *ApolloRandomKindLabel(ApolloRandomFeedKind kind) {
    switch (kind) {
        case ApolloRandomFeedKindSafe: return @"random";
        case ApolloRandomFeedKindNSFW: return @"randnsfw";
        default: return @"unknown";
    }
}

static uint32_t ApolloRandomBound(uint32_t bound) {
    return bound == 0 ? 0 : arc4random_uniform(bound);
}

// Case-insensitive compares, so no lowercased copy is made per request.
static BOOL ApolloRandomHostIsReddit(NSString *host) {
    if (host.length < 10) return NO;
    if ([host caseInsensitiveCompare:@"reddit.com"] == NSOrderedSame) return YES;
    return [host rangeOfString:@".reddit.com"
                       options:NSCaseInsensitiveSearch | NSAnchoredSearch | NSBackwardsSearch].location != NSNotFound;
}

// Caller holds sApolloRandomLock.
static void ApolloRandomRememberPickLocked(NSString *name, ApolloRandomFeedKind kind) {
    if (!sApolloRandomPickedKinds) {
        sApolloRandomPickedKinds = [NSMutableDictionary dictionary];
        sApolloRandomPickedOrder = [NSMutableArray array];
    }
    ApolloRandomRememberPickedKind(sApolloRandomPickedKinds, sApolloRandomPickedOrder, name, kind,
                                   kApolloRandomPickedKindLimit);
}

// The feed the user is looking at: loaded, in a window, and the top of its
// navigation stack. Main thread only.
static BOOL ApolloRandomFeedOnScreen(UIViewController *feed) {
    if (!feed || !feed.isViewLoaded || !feed.view.window) return NO;
    UINavigationController *navigation = feed.navigationController;
    return !navigation || navigation.topViewController == feed;
}

// MARK: - Title guard (main thread)

// Publishes the leaving names of active unconfirmed guards for the off-main
// sticky check.
static void ApolloRandomPublishStickyNames(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (ApolloRandomTitleGuard *guard in sApolloRandomActiveGuards) {
        if (!guard.confirmed) [names addObjectsFromArray:guard.leavingNames];
    }
    os_unfair_lock_lock(&sApolloRandomLock);
    sApolloRandomStickyNames = names.count > 0 ? [names copy] : nil;
    os_unfair_lock_unlock(&sApolloRandomLock);
}

static void ApolloRandomDeactivateGuard(ApolloRandomTitleGuard *guard, NSString *reason) {
    if (!guard.active) return;
    guard.active = NO;
    [sApolloRandomActiveGuards removeObjectIdenticalTo:guard];
    ApolloRandomPublishGuardCount();
    ApolloRandomPublishStickyNames();
    ApolloLog(@"[Random] title guard r/%@ off: %@", guard.rolledName ?: @"-", reason);
}

// YES when the guard's feed is still a random feed. A guard whose feed the
// jump bar switched to a plain subreddit (or that is gone) is turned off here.
static BOOL ApolloRandomGuardFeedIsRandom(ApolloRandomTitleGuard *guard) {
    UIViewController *feed = guard.feed;
    if (!feed) {
        ApolloRandomDeactivateGuard(guard, @"feed released");
        return NO;
    }
    if (ApolloPostsTypeTagFromViewController(feed) != kApolloRandomPostsTypeTag) {
        ApolloRandomDeactivateGuard(guard, @"feed is no longer a random feed");
        return NO;
    }
    return YES;
}

// Turns off active, unconfirmed guards whose random feed is on screen and,
// when `community` is given, has it among its leaving names. A nil
// `community` matches every such guard, whatever its kind.
static void ApolloRandomDeactivateOnScreenGuards(NSString *community, NSString *reason) {
    // A copy: the UIKit calls below can re-enter the setter hooks, which may
    // turn guards off and remove them from the live array.
    NSArray<ApolloRandomTitleGuard *> *guards = [sApolloRandomActiveGuards copy];
    for (ApolloRandomTitleGuard *guard in guards.reverseObjectEnumerator) {
        if (!guard.active) continue;
        if (guard.confirmed || !ApolloRandomGuardFeedIsRandom(guard) || !ApolloRandomFeedOnScreen(guard.feed)) continue;
        if (!guard.active) continue;
        if (community.length == 0 || ApolloRandomNamesContain(guard.leavingNames, community)) {
            ApolloRandomDeactivateGuard(guard, reason);
        }
    }
}

static UILabel *ApolloRandomJumpBarNameLabel(UIViewController *feed) {
    if (!ApolloClassJumpBar) return nil;
    UIView *jumpBar = ApolloObjectIvar(feed, "jumpBar");
    if (![jumpBar isKindOfClass:ApolloClassJumpBar]) {
        UIView *titleView = feed.navigationItem.titleView;
        jumpBar = [titleView isKindOfClass:ApolloClassJumpBar] ? titleView : nil;
    }
    if (!jumpBar) return nil;
    UILabel *label = ApolloObjectIvar(jumpBar, "nameLabel");
    return [label isKindOfClass:[UILabel class]] ? label : nil;
}

static NSString *ApolloRandomLabelText(UILabel *label) {
    return label.attributedText.string ?: label.text;
}

static ApolloRandomRoute *ApolloRandomFeedRouted(UIViewController *feed) {
    ApolloRandomRoute *routed = feed ? objc_getAssociatedObject(feed, &kApolloRandomRoutedKey) : nil;
    return [routed isKindOfClass:[ApolloRandomRoute class]] ? routed : nil;
}

static void ApolloRandomSetFeedRouted(UIViewController *feed, ApolloRandomFeedKind kind, NSString *name) {
    if (!feed || name.length == 0) return;
    ApolloRandomRoute *routed = [ApolloRandomRoute new];
    routed.kind = kind;
    routed.name = name;
    objc_setAssociatedObject(feed, &kApolloRandomRoutedKey, routed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The guard that owns this write, or nil. Prunes guards whose feed is gone or
// no longer random (the jump bar switched it to a plain subreddit). With one
// guard this is a weak load and a pointer compare: no associated-object lookup
// and no allocation per label write.
static ApolloRandomTitleGuard *ApolloRandomGuardForWriter(id writer, BOOL label) {
    for (NSInteger index = (NSInteger)sApolloRandomActiveGuards.count - 1; index >= 0; index--) {
        ApolloRandomTitleGuard *guard = sApolloRandomActiveGuards[(NSUInteger)index];
        id owned = label ? (id)guard.nameLabel : (id)guard.navigationItem;
        if (owned != writer) {
            if (!owned && !guard.feed) ApolloRandomDeactivateGuard(guard, @"feed released");
            continue;
        }
        return ApolloRandomGuardFeedIsRandom(guard) ? guard : nil;
    }
    return nil;
}

// Offset of PostsViewController's Swift `randomSubredditName: String?`, or -1.
// The Optional<String> is decoded by Swift from 16 bytes, so the slot must be
// exactly that wide: the next stored property (`currentMultireddit`) has to
// start 16 bytes later. Any other layout (a renamed, retyped or reordered
// ivar) is not read. Layout is read once from PostsViewController itself.
static ptrdiff_t ApolloRandomSubredditNameOffset(UIViewController *feed) {
    static ptrdiff_t offset = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = ApolloClassPostsViewController;
        Ivar ivar = cls ? class_getInstanceVariable(cls, "randomSubredditName") : NULL;
        Ivar next = cls ? class_getInstanceVariable(cls, "currentMultireddit") : NULL;
        ptrdiff_t width = ivar && next ? ivar_getOffset(next) - ivar_getOffset(ivar) : -1;
        if (width == 16) {
            offset = ivar_getOffset(ivar);
        } else {
            ApolloLog(@"[Random] PostsViewController.randomSubredditName not read: ivar %@, slot width %ld "
                      @"(expected 16 before currentMultireddit)",
                      ivar ? @"found" : @"missing", (long)width);
        }
    });
    if (offset < 0 || ![feed isKindOfClass:ApolloClassPostsViewController]) return -1;
    return offset;
}

// The communities Apollo's own model names for a feed: currentSubreddit.name
// and the Swift randomSubredditName. Read only. Main thread only.
static NSArray<NSString *> *ApolloRandomFeedModelNames(UIViewController *feed) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (!feed) return names;
    id subreddit = ApolloReadObjectIvar(feed, "currentSubreddit");
    if (ApolloClassRDKSubreddit && [subreddit isKindOfClass:ApolloClassRDKSubreddit] &&
        [subreddit respondsToSelector:@selector(name)]) {
        id name = ((id (*)(id, SEL))objc_msgSend)(subreddit, @selector(name));
        if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) [names addObject:name];
    }
    ptrdiff_t offset = ApolloRandomSubredditNameOffset(feed);
    if (offset >= 0) {
        NSString *randomName = (__bridge_transfer NSString *)ApolloSwiftCopyOptionalString(
            (uint8_t *)(__bridge void *)feed + offset);
        if (randomName.length > 0) [names addObject:randomName];
    }
    return names;
}

// What a guarded title or label write should become. Returns `text` itself
// when the write is not ours to change.
static NSString *ApolloRandomGuardedText(ApolloRandomTitleGuard *guard, NSString *text, NSString *where) {
    NSString *rewritten = nil;
    switch (ApolloRandomJudgeTitle(text, guard.leavingNames, guard.rolledName, guard.confirmed, &rewritten)) {
        case ApolloRandomTitleVerdictRewrite:
            ApolloLog(@"[Random] title guard: %@ write \"%@\" -> \"%@\"", where, text, rewritten);
            return rewritten;
        case ApolloRandomTitleVerdictRelease:
            ApolloRandomDeactivateGuard(guard, [NSString stringWithFormat:@"Apollo wrote \"%@\" to the %@", text, where]);
            return text;
        case ApolloRandomTitleVerdictConfirm: {
            if (sApolloRandomApplying || guard.confirmed) return text;
            // Apollo may copy our own rewrite back (e.g. refresh the label
            // from navigationItem.title), so the write alone proves nothing.
            // Its model naming the pick does: the pick's listing loaded.
            NSArray<NSString *> *model = ApolloRandomFeedModelNames(guard.feed);
            if (!ApolloRandomNamesContain(model, guard.rolledName)) {
                ApolloLog(@"[Random] title guard: %@ write \"%@\" names the pick but Apollo's model says {%@}; not confirmed",
                          where, text, [model componentsJoinedByString:@","]);
                return text;
            }
            // Nothing is left for the guard to correct.
            guard.confirmed = YES;
            ApolloRandomDeactivateGuard(guard, [NSString stringWithFormat:@"confirmed: Apollo wrote r/%@ to the %@ and its model names it",
                                                                         guard.rolledName, where]);
            return text;
        }
        case ApolloRandomTitleVerdictKeep:
            return text;
    }
    return text;
}

// Shows the pick right away: a banned listing never makes Apollo rename the
// feed itself. Runs from a main-queue block, never from layout.
static void ApolloRandomApplyRolledName(ApolloRandomTitleGuard *guard) {
    sApolloRandomApplying = YES;
    UINavigationItem *item = guard.navigationItem;
    NSString *rewritten = nil;
    NSString *title = item.title;
    if (ApolloRandomJudgeTitle(title, guard.leavingNames, guard.rolledName, guard.confirmed, &rewritten) ==
        ApolloRandomTitleVerdictRewrite) {
        // Goes through the setTitle: hook, which sees the pick.
        item.title = rewritten;
        ApolloLog(@"[Random] title \"%@\" -> \"%@\"", title, rewritten);
    } else {
        ApolloLog(@"[Random] title \"%@\" left as is", title ?: @"-");
    }

    UILabel *label = guard.nameLabel;
    NSString *labelText = label.attributedText.string ?: label.text;
    if (!label) {
        ApolloLog(@"[Random] no JumpBar name label found; only navigationItem.title follows the roll");
    } else if (ApolloRandomJudgeTitle(labelText, guard.leavingNames, guard.rolledName, guard.confirmed, &rewritten) !=
               ApolloRandomTitleVerdictRewrite) {
        ApolloLog(@"[Random] JumpBar label \"%@\" left as is", labelText ?: @"-");
    } else {
        if (label.attributedText.length > 0) {
            NSDictionary *attributes = [label.attributedText attributesAtIndex:0 effectiveRange:NULL];
            label.attributedText = [[NSAttributedString alloc] initWithString:rewritten attributes:attributes];
        } else {
            label.text = rewritten;
        }
        UIView *jumpBar = label.superview;
        while (jumpBar && ![jumpBar isKindOfClass:ApolloClassJumpBar]) jumpBar = jumpBar.superview;
        [jumpBar invalidateIntrinsicContentSize];
        [jumpBar setNeedsLayout];
        ApolloLog(@"[Random] JumpBar label \"%@\" -> \"%@\"", labelText, rewritten);
    }
    sApolloRandomApplying = NO;
}

// `kind` and `name` are the route that turns the guard on; a re-picked roll
// replaces the guard's kind and pick with them.
static void ApolloRandomActivateGuard(ApolloRandomTitleGuard *guard, ApolloRandomFeedKind kind, NSString *name) {
    UIViewController *feed = guard.feed;
    if (!feed) {
        ApolloLog(@"[Random] title guard r/%@ not turned on: feed released", guard.rolledName);
        return;
    }
    if (objc_getAssociatedObject(feed, &kApolloRandomTitleGuardKey) != guard) {
        ApolloLog(@"[Random] title guard r/%@ not turned on: a newer refresh replaced it", guard.rolledName);
        return;
    }
    if (ApolloPostsTypeTagFromViewController(feed) != kApolloRandomPostsTypeTag) {
        ApolloLog(@"[Random] title guard r/%@ not turned on: feed is no longer a random feed", guard.rolledName);
        return;
    }
    if (name.length > 0 && !ApolloRandomNamesContain(@[guard.rolledName ?: @""], name)) {
        ApolloLog(@"[Random] title guard re-picked: r/%@ (%@) -> r/%@ (%@)", guard.rolledName ?: @"-",
                  ApolloRandomKindLabel(guard.kind), name, ApolloRandomKindLabel(kind));
        guard.rolledName = name;
    }
    if (kind == ApolloRandomFeedKindSafe || kind == ApolloRandomFeedKindNSFW) guard.kind = kind;
    ApolloRandomSetFeedRouted(feed, guard.kind, guard.rolledName);
    if (!guard.active) {
        guard.active = YES;
        if (!sApolloRandomActiveGuards) sApolloRandomActiveGuards = [NSMutableArray array];
        [sApolloRandomActiveGuards addObject:guard];
        ApolloRandomPublishGuardCount();
        ApolloRandomPublishStickyNames();
        ApolloLog(@"[Random] title guard on (%@): r/{%@} -> r/%@", ApolloRandomKindLabel(guard.kind),
                  [guard.leavingNames componentsJoinedByString:@","], guard.rolledName);
    }
    ApolloRandomApplyRolledName(guard);
}

// Every PostsViewController on screen: the visible window hierarchy through
// navigation tops, tab selections, split/pane children and presented
// controllers, depth-capped. Main thread only; only walked for sticky
// candidates.
static void ApolloRandomCollectOnScreenFeeds(UIViewController *controller,
                                             NSMutableArray<UIViewController *> *feeds,
                                             NSUInteger depth) {
    if (!controller || depth > 12 || !controller.isViewLoaded || !controller.view.window) return;
    if (ApolloClassPostsViewController && [controller isKindOfClass:ApolloClassPostsViewController] &&
        ![feeds containsObject:controller]) {
        [feeds addObject:controller];
    }
    if ([controller isKindOfClass:[UINavigationController class]]) {
        ApolloRandomCollectOnScreenFeeds(((UINavigationController *)controller).topViewController, feeds, depth + 1);
    } else if ([controller isKindOfClass:[UITabBarController class]]) {
        ApolloRandomCollectOnScreenFeeds(((UITabBarController *)controller).selectedViewController, feeds, depth + 1);
    } else {
        // Split views, Apollo's iPad panes and other containers.
        for (UIViewController *child in controller.childViewControllers) {
            ApolloRandomCollectOnScreenFeeds(child, feeds, depth + 1);
        }
    }
    UIViewController *presented = controller.presentedViewController;
    if (presented && presented.presentingViewController == controller) {
        ApolloRandomCollectOnScreenFeeds(presented, feeds, depth + 1);
    }
}

// Another on-screen feed (an iPad pane, a Duo column) that shows `community`
// by title or by model, and so may be the one asking for it.
static UIViewController *ApolloRandomOtherFeedShowing(NSString *community, UIViewController *except) {
    NSMutableArray<UIViewController *> *feeds = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        ApolloRandomCollectOnScreenFeeds(window.rootViewController, feeds, 0);
    }
    for (UIViewController *feed in feeds) {
        if (feed == except) continue;
        NSString *title = ApolloNormalizedSubredditName(feed.navigationItem.title ?: feed.title);
        if (title.length > 0 && ApolloRandomNamesContain(@[title], community)) return feed;
        id subreddit = ApolloReadObjectIvar(feed, "currentSubreddit");
        if (ApolloClassRDKSubreddit && [subreddit isKindOfClass:ApolloClassRDKSubreddit] &&
            [subreddit respondsToSelector:@selector(name)]) {
            id name = ((id (*)(id, SEL))objc_msgSend)(subreddit, @selector(name));
            if ([name isKindOfClass:[NSString class]] && ApolloRandomNamesContain(@[name], community)) return feed;
        }
    }
    return nil;
}

// The sticky route: the pick of an unconfirmed guard whose random feed is on
// screen and which is leaving `community`, unless another on-screen feed shows
// that community and may be the one asking. Main thread only.
static NSString *ApolloRandomStickyName(ApolloRandomRequestRole role, ApolloRandomFeedKind pathKind,
                                        NSString *community, BOOL hasCursor) {
    // A copy: the UIKit calls below can re-enter the setter hooks, which may
    // turn guards off and remove them from the live array.
    NSArray<ApolloRandomTitleGuard *> *guards = [sApolloRandomActiveGuards copy];
    for (ApolloRandomTitleGuard *guard in guards.reverseObjectEnumerator) {
        if (!guard.active || guard.confirmed) continue;
        if (!ApolloRandomRequestNamesLeaving(role, pathKind, community, hasCursor, guard.leavingNames)) continue;
        // A feed the jump bar switched to r/<community> sends its listing
        // before its title write; it must not land on the pick.
        if (!ApolloRandomGuardFeedIsRandom(guard)) continue;
        if (!ApolloRandomFeedOnScreen(guard.feed) || !guard.active) continue;
        UIViewController *other = ApolloRandomOtherFeedShowing(community, guard.feed);
        if (other) {
            ApolloLog(@"[Random] sticky r/%@ -> r/%@ skipped: another on-screen feed (%@) shows r/%@",
                      community, guard.rolledName, NSStringFromClass(other.class), community);
            return nil;
        }
        if (!guard.active) continue;
        return guard.rolledName;
    }
    return nil;
}

// MARK: - Arming (main thread)

static void ApolloRandomArm(UIViewController *feed) {
    if (ApolloPostsTypeTagFromViewController(feed) != kApolloRandomPostsTypeTag) return;

    ApolloRandomTitleGuard *previous = objc_getAssociatedObject(feed, &kApolloRandomTitleGuardKey);
    ApolloRandomArmInput *input = [ApolloRandomArmInput new];
    input.previousActive = previous.active;
    input.previousConfirmed = previous.confirmed;
    input.previousRolledName = previous.rolledName;
    input.previousLeavingNames = previous.leavingNames;
    input.title = feed.navigationItem.title ?: feed.title;
    // The JumpBar label tells Random from Random NSFW; Apollo writes "Random"
    // to the navigation title of both.
    input.labelText = ApolloRandomLabelText(ApolloRandomJumpBarNameLabel(feed));
    ApolloRandomRoute *routed = ApolloRandomFeedRouted(feed);
    input.routedName = routed.name;
    input.routedKind = routed.kind;

    // What Apollo's refresh will request: its model, read only.
    NSArray<NSString *> *requested = ApolloRandomFeedModelNames(feed);
    input.requestedNames = requested;

    os_unfair_lock_lock(&sApolloRandomLock);
    NSDictionary<NSString *, NSNumber *> *pickedKinds = [sApolloRandomPickedKinds copy];
    os_unfair_lock_unlock(&sApolloRandomLock);
    NSArray<NSString *> *safe = ApolloRandomCachedSubreddits(ApolloRandomFeedKindSafe);
    NSArray<NSString *> *nsfw = ApolloRandomCachedSubreddits(ApolloRandomFeedKindNSFW);
    ApolloRandomArmPlan *plan = ApolloRandomPlanArm(input, pickedKinds, safe, nsfw, ApolloRandomBound);

    NSString *requestedLabel = [requested componentsJoinedByString:@","];
    if (plan.outcome != ApolloRandomArmOutcomeArmed) {
        ApolloLog(@"[Random] refresh not armed (%@): kind=%@ shown=%@ requested=%@ title=%@ label=%@ "
                  @"routed=%@(%@) safeList=%@ nsfwList=%@",
                  plan.outcome == ApolloRandomArmOutcomeKindUnknown ? @"cannot tell safe from NSFW" : @"list empty or not loaded",
                  ApolloRandomKindLabel(plan.kind), plan.shownName ?: @"-",
                  requestedLabel.length > 0 ? requestedLabel : @"-", input.title ?: @"-", input.labelText ?: @"-",
                  routed.name ?: @"-", ApolloRandomKindLabel(routed.kind),
                  safe ? @(safe.count) : @"not loaded", nsfw ? @(nsfw.count) : @"not loaded");
        return;
    }

    ApolloRandomTitleGuard *guard = [ApolloRandomTitleGuard new];
    guard.feed = feed;
    guard.navigationItem = feed.navigationItem;
    guard.nameLabel = ApolloRandomJumpBarNameLabel(feed);
    guard.kind = plan.kind;
    guard.leavingNames = plan.leavingNames;
    guard.rolledName = plan.pickedName;
    if (previous) ApolloRandomDeactivateGuard(previous, @"replaced by a new refresh");
    objc_setAssociatedObject(feed, &kApolloRandomTitleGuardKey, guard, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloRandomPendingRoll *pending = [ApolloRandomPendingRoll new];
    pending.kind = plan.kind;
    pending.hardNames = plan.hardNames;
    pending.leavingNames = plan.leavingNames;
    pending.pickedName = plan.pickedName;
    pending.armedAt = CACurrentMediaTime();
    os_unfair_lock_lock(&sApolloRandomLock);
    sApolloRandomPending = pending;
    sApolloRandomPendingGuard = guard;
    ApolloRandomRememberPickLocked(plan.pickedName, plan.kind);
    os_unfair_lock_unlock(&sApolloRandomLock);

    ApolloLog(@"[Random] refresh armed: kind=%@ shown=%@ requested=%@ title=%@ label=%@ routed=%@(%@) "
              @"leaving={%@} picked=%@",
              ApolloRandomKindLabel(plan.kind), plan.shownName ?: @"-",
              requestedLabel.length > 0 ? requestedLabel : @"-", input.title ?: @"-", input.labelText ?: @"-",
              routed.name ?: @"-", ApolloRandomKindLabel(routed.kind),
              [plan.leavingNames componentsJoinedByString:@","], plan.pickedName);
}

// The sort button opens Apollo's sort menu; a roll armed by a pull that never
// sent a request must not catch the sorted reload.
static void ApolloRandomDropUnusedArm(UIViewController *feed, NSString *reason) {
    ApolloRandomPendingRoll *dropped = nil;
    os_unfair_lock_lock(&sApolloRandomLock);
    if (sApolloRandomPending && sApolloRandomPending.consumedAt <= 0 &&
        sApolloRandomPendingGuard.feed == feed) {
        dropped = sApolloRandomPending;
        sApolloRandomPending = nil;
        sApolloRandomPendingGuard = nil;
    }
    os_unfair_lock_unlock(&sApolloRandomLock);
    if (dropped) ApolloLog(@"[Random] dropped unused armed roll r/%@: %@", dropped.pickedName, reason);
}

// MARK: - Stateless claim (main thread)

// Shows a stateless random listing's community on the random feed that sent
// it. The request carries no feed, so the feed is found on screen: the one
// random feed whose label is that kind's placeholder, or which sits on its own
// failed route (ApolloRandomFeedTakesRoute). Several candidates (iPad/Duo
// panes) are ambiguous and nothing is relabeled; none is retried a few times.
// A newer route (`generation`) makes an older claim give up.
static void ApolloRandomClaimStatelessRoute(ApolloRandomRoute *route, NSUInteger generation, NSUInteger attempt) {
    os_unfair_lock_lock(&sApolloRandomLock);
    NSUInteger current = sApolloRandomRouteGeneration;
    os_unfair_lock_unlock(&sApolloRandomLock);
    if (current != generation) {
        ApolloLog(@"[Random] claim r/%@ (%@) attempt %lu: given up, a newer route landed", route.name,
                  ApolloRandomKindLabel(route.kind), (unsigned long)attempt + 1);
        return;
    }

    NSMutableArray<UIViewController *> *feeds = [NSMutableArray array];
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        ApolloRandomCollectOnScreenFeeds(window.rootViewController, feeds, 0);
    }
    NSMutableArray<UIViewController *> *candidates = [NSMutableArray array];
    NSUInteger randomFeeds = 0;
    for (UIViewController *feed in feeds) {
        if (ApolloPostsTypeTagFromViewController(feed) != kApolloRandomPostsTypeTag) continue;
        randomFeeds++;
        NSString *labelText = ApolloRandomLabelText(ApolloRandomJumpBarNameLabel(feed));
        NSString *title = feed.navigationItem.title ?: feed.title;
        ApolloRandomRoute *routed = ApolloRandomFeedRouted(feed);
        NSArray<NSString *> *model = ApolloRandomFeedModelNames(feed);
        BOOL takes = ApolloRandomFeedTakesRoute(labelText, title, model, routed.name, route.kind);
        ApolloLog(@"[Random] claim r/%@ (%@) attempt %lu: feed %p label=%@ title=%@ routed=%@ model={%@} -> %@",
                  route.name, ApolloRandomKindLabel(route.kind), (unsigned long)attempt + 1, feed,
                  labelText ?: @"-", title ?: @"-", routed.name ?: @"-",
                  [model componentsJoinedByString:@","], takes ? @"candidate" : @"no");
        if (takes) [candidates addObject:feed];
    }
    ApolloLog(@"[Random] claim r/%@ (%@) attempt %lu: %lu candidate(s) of %lu on-screen random feed(s)",
              route.name, ApolloRandomKindLabel(route.kind), (unsigned long)attempt + 1,
              (unsigned long)candidates.count, (unsigned long)randomFeeds);

    if (candidates.count == 0) {
        NSUInteger retries = sizeof(kApolloRandomClaimRetryDelays) / sizeof(kApolloRandomClaimRetryDelays[0]);
        if (attempt >= retries) {
            ApolloLog(@"[Random] claim r/%@ (%@): given up after %lu attempts, no on-screen random feed shows "
                      @"its placeholder or its own failed route", route.name, ApolloRandomKindLabel(route.kind),
                      (unsigned long)attempt + 1);
            return;
        }
        NSTimeInterval delay = kApolloRandomClaimRetryDelays[attempt];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloRandomClaimStatelessRoute(route, generation, attempt + 1);
        });
        return;
    }
    if (candidates.count > 1) {
        ApolloLog(@"[Random] claim r/%@ (%@): given up, %lu random feeds could have sent it", route.name,
                  ApolloRandomKindLabel(route.kind), (unsigned long)candidates.count);
        return;
    }

    UIViewController *feed = candidates.firstObject;
    ApolloRandomTitleGuard *previous = objc_getAssociatedObject(feed, &kApolloRandomTitleGuardKey);
    // What the feed showed before (its last routed community, the previous
    // guard's pick) now gives way to the routed community.
    NSMutableArray<NSString *> *leaving = [NSMutableArray array];
    for (NSString *name in @[ApolloRandomFeedRouted(feed).name ?: @"", previous.rolledName ?: @""]) {
        NSString *normalized = ApolloNormalizedSubredditName(name);
        if (normalized.length == 0 || ApolloRandomNamesContain(leaving, normalized) ||
            ApolloRandomNamesContain(@[route.name], normalized)) continue;
        [leaving addObject:normalized];
    }
    ApolloRandomTitleGuard *guard = [ApolloRandomTitleGuard new];
    guard.feed = feed;
    guard.navigationItem = feed.navigationItem;
    guard.nameLabel = ApolloRandomJumpBarNameLabel(feed);
    guard.kind = route.kind;
    guard.leavingNames = leaving;
    guard.rolledName = route.name;
    if (previous) ApolloRandomDeactivateGuard(previous, @"replaced by a claimed stateless route");
    objc_setAssociatedObject(feed, &kApolloRandomTitleGuardKey, guard, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[Random] claim r/%@ (%@) attempt %lu: claimed by feed %p, leaving={%@}", route.name,
              ApolloRandomKindLabel(route.kind), (unsigned long)attempt + 1, feed,
              [leaving componentsJoinedByString:@","]);
    ApolloRandomActivateGuard(guard, route.kind, route.name);
}

// MARK: - Request rewrite (any thread)

// Depth of tweak-owned fetches on this thread (ApolloRandomTweakFetchScope).
static __thread NSUInteger tApolloRandomTweakFetchDepth;

void ApolloRandomTweakFetchBegin(void) {
    tApolloRandomTweakFetchDepth++;
}

void ApolloRandomTweakFetchEnd(void) {
    if (tApolloRandomTweakFetchDepth > 0) tApolloRandomTweakFetchDepth--;
}

NSURLRequest *ApolloRandomRequestByRolling(NSURLRequest *request, BOOL allowFeedRoutes) {
    // Host first, without allocating: most requests (images, other APIs)
    // leave here.
    NSURL *url = request.URL;
    if (!ApolloRandomHostIsReddit(url.host)) return nil;
    NSString *method = request.HTTPMethod;
    if (method.length > 0 && [method caseInsensitiveCompare:@"GET"] != NSOrderedSame) return nil;
    // The tweak's own self-authenticated requests are never rerouted.
    if (ApolloWebJSONURLIsProbe(url)) return nil;

    ApolloRandomRequestRole role = ApolloRandomRequestRoleNone;
    ApolloRandomFeedKind pathKind = ApolloRandomFeedKindNone;
    NSString *community = nil;
    if (!ApolloRandomMatchSubredditPath(url.path, &role, &pathKind, &community)) return nil;
    if (role == ApolloRandomRequestRolePosts && ApolloRandomPostsListingHasCursor(url)) return nil;
    BOOL explicitRandom = pathKind != ApolloRandomFeedKindNone;
    // A tweak fetch sent through Apollo's own RDKClient arrives on Apollo's
    // entry point; its scope keeps it off the feed routes.
    if (tApolloRandomTweakFetchDepth > 0) allowFeedRoutes = NO;
    if (!explicitRandom && !allowFeedRoutes) return nil;

    // Only explicit random requests can need a list here; fetch it outside
    // the lock (a cache miss starts a background refresh).
    NSArray<NSString *> *safe = pathKind == ApolloRandomFeedKindSafe
        ? ApolloRandomCachedSubreddits(ApolloRandomFeedKindSafe) : nil;
    NSArray<NSString *> *nsfw = pathKind == ApolloRandomFeedKindNSFW
        ? ApolloRandomCachedSubreddits(ApolloRandomFeedKindNSFW) : nil;

    NSTimeInterval now = CACurrentMediaTime();
    ApolloRandomTitleGuard *activate = nil;
    ApolloRandomPendingRoll *expired = nil;
    BOOL stickyCandidate = NO;
    NSUInteger claimGeneration = 0;
    os_unfair_lock_lock(&sApolloRandomLock);
    ApolloRandomPendingRoll *pending = allowFeedRoutes ? sApolloRandomPending : nil;
    if (pending && !ApolloRandomPendingRollIsLive(pending, now)) {
        expired = pending;
        sApolloRandomPending = nil;
        sApolloRandomPendingGuard = nil;
        pending = nil;
    }
    // Tweak-owned fetches neither read nor update the memo: only Apollo's own
    // listing and about make up one load.
    ApolloRandomStatelessMemo *__strong *memoSlot = NULL;
    if (allowFeedRoutes && pathKind == ApolloRandomFeedKindSafe) memoSlot = &sApolloRandomStatelessSafe;
    if (allowFeedRoutes && pathKind == ApolloRandomFeedKindNSFW) memoSlot = &sApolloRandomStatelessNSFW;
    ApolloRandomRoute *route = ApolloRandomRouteRequest(role, pathKind, community, NO, pending,
                                                        memoSlot ? *memoSlot : nil, now,
                                                        safe, nsfw, sApolloRandomPickedKinds, sApolloRandomPickedOrder,
                                                        ApolloRandomBound);
    if (memoSlot) *memoSlot = ApolloRandomStatelessMemoAfterRoute(*memoSlot, route, role, now);
    ApolloRandomPendingRoll *superseded = nil;
    if (route.supersedesPending && pending) {
        // A new random listing replaced the rolled community: the roll's
        // about must not bring the pick back.
        superseded = pending;
        sApolloRandomPending = nil;
        sApolloRandomPendingGuard = nil;
    }
    if (route.repicked) {
        // The roll was armed with the wrong kind; later requests of this
        // gesture (its about) join the re-pick.
        pending.kind = route.kind;
        pending.pickedName = route.name;
        ApolloRandomRememberPickLocked(route.name, route.kind);
    }
    if (route.source == ApolloRandomRouteSourcePending && pending.consumedAt <= 0) {
        pending.consumedAt = now;
        activate = sApolloRandomPendingGuard;
        sApolloRandomRouteGeneration++;
    }
    if (route.source == ApolloRandomRouteSourceStateless && !route.reusedStateless) {
        ApolloRandomRememberPickLocked(route.name, route.kind);
    }
    if (route.source == ApolloRandomRouteSourceStateless && allowFeedRoutes && role == ApolloRandomRequestRolePosts) {
        claimGeneration = ++sApolloRandomRouteGeneration;
    }
    if (!route && allowFeedRoutes) {
        stickyCandidate = ApolloRandomRequestNamesLeaving(role, pathKind, community, NO, sApolloRandomStickyNames);
    }
    os_unfair_lock_unlock(&sApolloRandomLock);

    if (expired) {
        ApolloLog(@"[Random] armed roll r/%@ expired (%@)", expired.pickedName,
                  expired.consumedAt > 0 ? @"reuse window over" : @"no request used it");
    }
    if (superseded) {
        ApolloLog(@"[Random] armed roll r/%@ dropped: a new random listing (r/%@) replaced it",
                  superseded.pickedName, route.name);
    }

    NSString *name = route.name;
    NSString *source = route.source == ApolloRandomRouteSourcePending ? @"roll" : @"stateless pick";
    if (stickyCandidate) {
        if ([NSThread isMainThread]) {
            name = ApolloRandomStickyName(role, pathKind, community, NO);
            source = @"sticky";
        } else {
            // "On screen" can only be checked on the main thread. Send the
            // request unchanged and turn the guard off there, so the label
            // follows the content Apollo is about to show.
            NSString *left = [community copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloRandomDeactivateOnScreenGuards(left,
                    [NSString stringWithFormat:@"r/%@ was requested off the main thread and went out unchanged", left]);
            });
        }
    }
    if (claimGeneration > 0) {
        // A new random load (a first open, a jump-bar "Random" or "Random
        // NSFW", a refresh that armed nothing) replaces the community; the
        // old pick must not take over its placeholder. The feed that sent it
        // then shows the routed community, which a banned listing never makes
        // Apollo write itself. An explicit random about is not a new load and
        // leaves the guards alone.
        ApolloRandomRoute *claimed = route;
        NSUInteger generation = claimGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloRandomDeactivateOnScreenGuards(nil, @"a new random load started");
            ApolloRandomClaimStatelessRoute(claimed, generation, 0);
        });
    }
    if (name.length == 0) return nil;

    NSURL *rewritten = ApolloRandomURLByReplacingCommunity(url, community, name);
    if (!rewritten) return nil;
    ApolloLog(@"[Random] %@%@ %@ r/%@ -> r/%@ (%@)", source,
              route.repicked ? @" (re-picked for the path's kind)"
                             : (route.reusedStateless ? @" (same load as the last stateless route)" : @""),
              role == ApolloRandomRequestRoleAbout ? @"about" : @"listing", community, name,
              route ? ApolloRandomKindLabel(route.kind) : @"guard");
    if (activate) {
        // Always hop: the guard and the title live on the main thread, and the
        // task may be created off-main or from inside UIKit work.
        ApolloRandomFeedKind activateKind = route.kind;
        NSString *activateName = route.name;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloRandomActivateGuard(activate, activateKind, activateName);
        });
    }
    if ([rewritten.absoluteString isEqualToString:url.absoluteString]) return nil;
    NSMutableURLRequest *rolled = [request mutableCopy];
    rolled.URL = rewritten;
    // A cached 403, or the previous community's listing, must not replay in
    // place of the community this pull just selected.
    rolled.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    return rolled;
}

// MARK: - Hooks

%group ApolloRandomRefresh

// Both actions are defined on PostsViewController itself, which has no
// subclasses, so the sim generator's inherited-method freeze does not apply.
// ApolloScrollToTop.xm hooks both too.
%hook ApolloRandomPostsController
// Pull-to-refresh. ApolloListEmptyState's retry button calls it too, which
// also rolls.
- (void)refreshControlActivatedWithSender:(id)sender {
    ApolloRandomArm((UIViewController *)self);
    %orig;
}

- (void)sortBarButtonItemTappedWithSender:(id)sender {
    ApolloRandomDropUnusedArm((UIViewController *)self, @"sort button tapped");
    %orig;
}
%end

%end

%group ApolloRandomTitles

// Other files hook these setters too (ApolloSpelling, ApolloSubredditHeaders,
// ApolloRecentlyRead, ApolloUserAvatars, ApolloNavigationTitlePresentation,
// ipad/ApolloPaneRouter, ApolloPhotoPostComposerScrollFix). Each passes the
// value on, so a rewrite here only changes the value for the guarded feed.
%hook UINavigationItem
- (void)setTitle:(NSString *)title {
    if (ApolloRandomGuardCount() == 0 || ![NSThread isMainThread]) {
        %orig;
        return;
    }
    ApolloRandomTitleGuard *guard = ApolloRandomGuardForWriter(self, NO);
    if (!guard) {
        %orig;
        return;
    }
    %orig(ApolloRandomGuardedText(guard, title, @"navigation title"));
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    if (ApolloRandomGuardCount() == 0 || ![NSThread isMainThread]) {
        %orig;
        return;
    }
    ApolloRandomTitleGuard *guard = ApolloRandomGuardForWriter(self, YES);
    if (!guard) {
        %orig;
        return;
    }
    %orig(ApolloRandomGuardedText(guard, text, @"JumpBar label"));
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (ApolloRandomGuardCount() == 0 || ![NSThread isMainThread]) {
        %orig;
        return;
    }
    ApolloRandomTitleGuard *guard = ApolloRandomGuardForWriter(self, YES);
    if (!guard || attributedText.length == 0) {
        %orig;
        return;
    }
    NSString *text = attributedText.string;
    NSString *guarded = ApolloRandomGuardedText(guard, text, @"JumpBar label");
    if (guarded == text) {
        %orig;
        return;
    }
    NSDictionary *attributes = [attributedText attributesAtIndex:0 effectiveRange:NULL];
    %orig([[NSAttributedString alloc] initWithString:guarded attributes:attributes]);
}
%end

%end

%ctor {
    %init(ApolloRandomTitles);
    if (ApolloClassPostsViewController &&
        class_getInstanceMethod(ApolloClassPostsViewController, @selector(refreshControlActivatedWithSender:)) &&
        class_getInstanceMethod(ApolloClassPostsViewController, @selector(sortBarButtonItemTappedWithSender:))) {
        %init(ApolloRandomRefresh, ApolloRandomPostsController = ApolloClassPostsViewController);
        ApolloLog(@"[Random] pull-to-refresh roll hooks installed");
    } else {
        ApolloLog(@"[Random] PostsViewController refresh/sort actions not found; pull-to-refresh will not roll");
    }
}
