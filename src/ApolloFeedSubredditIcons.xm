#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <os/lock.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Fix: in a feed that shows the subreddit instead of the author (Home, Popular,
// All, multireddits, r/a+b), a post's subreddit icon can stay an empty circle
// for good. The circle is filled with the theme's background color, so on a dark
// theme it reads as a black avatar (reported on a mod post in r/ApolloReborn
// under the Synthwave theme: #0D0420 fill, no image at all).
//
// Root cause (Hopper, Apollo 1.15.11): Apollo keeps subreddit icons in
// `SubredditIconTracker` (name -> URL). A post row that is built before its
// subreddit is in the tracker shows a placeholder and waits for
// "com.christianselig.SubredditIconAvailable" with `object:` set to ITS OWN
// RDKLink:
//
//   PostInfoNode init -> sub_10039ad04: tracker miss -> placeholder image
//     (sub_1007ad54c, a solid theme-color square the image modification block
//     rounds) + -addObserver:self selector:subredditIconAvailableWithNotification:
//     name:SubredditIconAvailable object:link
//   LargePostCellNode's top icon (sub_100306194) does the same with `link`, and
//   CrosspostNode with `crosspostParent`.
//
// The feed fetches missing icons in one batch per page
// (PostsViewController sub_1005c2010 -> -[RDKClient thingsByFullNames:completion:]
// with t5_ ids). While building that batch it walks the page's links and skips
// a link whose subredditFullName is already in the batch — skipping BOTH the id
// (fine) and the link's slot in the "notify these links" list (the bug). The
// completion (sub_1005b1e20) fills the tracker, then posts SubredditIconAvailable
// only for the listed links. So only the FIRST post of each subreddit on the
// page hears about its icon; every later post of that subreddit was already
// built (Texture measures every inserted row up front), already waiting, and
// keeps the placeholder until the feed is reloaded.
//
// Repro: open r/Aquariums+houseplants with neither sub's icon cached — the first
// post of each sub gets its icon, the next ones keep the empty circle.
//
// Fix strategy
// ------------
// 1. Deliver the notification Apollo meant to send. We record every object
//    Apollo registers for -subredditIconAvailableWithNotification: (that
//    registration is exactly Apollo's own "this row is waiting" decision), and
//    when Apollo posts SubredditIconAvailable for one link we run each OTHER
//    still-waiting row of the same subreddit through its own native handler.
//    The handler re-reads the tracker (now filled) and takes the stock path:
//    icon URL (PIN cache hit, or the HEAD size check first), or the letter
//    placeholder for subreddits without an icon.
//
// 2. Make the native handler safe to deliver twice. It is not idempotent: it
//    does setImage:nil, then setURL:, and ASNetworkImageNode ignores a setURL:
//    with the URL it already has, so a second delivery to a row that already
//    has its icon leaves it blank. Two batches can be in flight for the same
//    subreddit (Home and a feed opened from it, or page 1 and page 2), and each
//    notifies its own first link, so once (1) resolves a row early, Apollo's own
//    later delivery would blank it. The handler now returns early for a row
//    that already has a URL or the letter placeholder.

// The three Apollo node classes that wait on SubredditIconAvailable, with the
// ivars their handlers read (names from the class metadata, verified in Hopper):
// the icon node and the link whose `subreddit` picks the tracker entry. All
// three also carry the Swift Bool `isUsingPlaceholderSubredditIcon`, set when
// the tracker said "no icon" and the letter placeholder was applied.
typedef struct {
    const char *className;
    const char *iconNodeIvar;
    const char *linkIvar;
} ApolloFeedSubredditIconSpec;

static const ApolloFeedSubredditIconSpec kApolloFeedSubredditIconSpecs[] = {
    { "_TtC6Apollo12PostInfoNode",      "subredditIconNode",      "link" },
    { "_TtC6Apollo17LargePostCellNode", "upperSubredditIconNode", "link" },
    { "_TtC6Apollo13CrosspostNode",     "subredditIconNode",      "crosspostParent" },
};

typedef NS_ENUM(NSInteger, ApolloFeedSubredditIconState) {
    ApolloFeedSubredditIconStateUnknown,   // ivars unreadable: behave natively
    ApolloFeedSubredditIconStateWaiting,   // init placeholder, nothing applied yet
    ApolloFeedSubredditIconStatePending,   // no image, no URL: HEAD size check in flight
    ApolloFeedSubredditIconStateResolved,  // URL set, or the letter placeholder applied
};

static NSString *const kApolloSubredditIconAvailableName = @"com.christianselig.SubredditIconAvailable";
static SEL sApolloSubredditIconAvailableSelector;

// Objects Apollo registered as waiting. Weak, so a row that is freed simply
// drops out; resolved rows are removed on the next pass that sees them. Written
// from Texture's background node construction (the addObserver call happens in
// the Swift init), read on main — every access goes through the lock.
static NSHashTable *sApolloFeedSubredditIconWaiters;
static os_unfair_lock sApolloFeedSubredditIconWaitersLock = OS_UNFAIR_LOCK_INIT;

static const ApolloFeedSubredditIconSpec *ApolloFeedSubredditIconSpecForObject(id object) {
    for (size_t i = 0; i < sizeof(kApolloFeedSubredditIconSpecs) / sizeof(kApolloFeedSubredditIconSpecs[0]); i++) {
        Class cls = objc_getClass(kApolloFeedSubredditIconSpecs[i].className);
        if (cls && [object isKindOfClass:cls]) return &kApolloFeedSubredditIconSpecs[i];
    }
    return NULL;
}

static NSString *ApolloFeedSubredditIconSubredditOfLink(id link) {
    if (![link respondsToSelector:@selector(subreddit)]) return nil;
    id subreddit = ((id (*)(id, SEL))objc_msgSend)(link, @selector(subreddit));
    return [subreddit isKindOfClass:[NSString class]] ? subreddit : nil;
}

static ApolloFeedSubredditIconState ApolloFeedSubredditIconStateOf(id node, const ApolloFeedSubredditIconSpec *spec) {
    if (!spec) return ApolloFeedSubredditIconStateUnknown;
    id iconNode = ApolloReadObjectIvar(node, spec->iconNodeIvar);
    if (![iconNode respondsToSelector:@selector(URL)] || ![iconNode respondsToSelector:@selector(image)]) {
        return ApolloFeedSubredditIconStateUnknown;
    }
    if (ApolloIvarOffset(object_getClass(node), "isUsingPlaceholderSubredditIcon") < 0) {
        return ApolloFeedSubredditIconStateUnknown;
    }
    if (ApolloReadBoolIvar(node, "isUsingPlaceholderSubredditIcon", NO)) return ApolloFeedSubredditIconStateResolved;
    if (((id (*)(id, SEL))objc_msgSend)(iconNode, @selector(URL))) return ApolloFeedSubredditIconStateResolved;
    return ((id (*)(id, SEL))objc_msgSend)(iconNode, @selector(image))
        ? ApolloFeedSubredditIconStateWaiting
        : ApolloFeedSubredditIconStatePending;
}

// Shared body of the three handler hooks: YES = let the native handler run.
static BOOL ApolloFeedSubredditIconShouldRunHandler(id node) {
    const ApolloFeedSubredditIconSpec *spec = ApolloFeedSubredditIconSpecForObject(node);
    if (ApolloFeedSubredditIconStateOf(node, spec) != ApolloFeedSubredditIconStateResolved) return YES;
    ApolloLogDebug(@"[FeedSubredditIcons] skipped a second icon delivery to a %s that already has its icon",
                   spec->className);
    return NO;
}

// Main thread only. `postedLink` is the object Apollo posted the notification
// for; `subreddit` is its subreddit name.
static void ApolloFeedSubredditIconDeliverToWaiters(id postedLink, NSString *subreddit) {
    os_unfair_lock_lock(&sApolloFeedSubredditIconWaitersLock);
    NSArray *waiters = sApolloFeedSubredditIconWaiters.allObjects;
    os_unfair_lock_unlock(&sApolloFeedSubredditIconWaitersLock);
    if (waiters.count == 0) return;

    NSMutableArray *finished = [NSMutableArray array];
    NSUInteger delivered = 0, resolved = 0;
    for (id node in waiters) {
        const ApolloFeedSubredditIconSpec *spec = ApolloFeedSubredditIconSpecForObject(node);
        id link = spec ? ApolloReadObjectIvar(node, spec->linkIvar) : nil;
        // Apollo notifies the rows observing the posted link itself.
        if (!link || link == postedLink) continue;
        NSString *nodeSubreddit = ApolloFeedSubredditIconSubredditOfLink(link);
        if (!nodeSubreddit || [nodeSubreddit caseInsensitiveCompare:subreddit] != NSOrderedSame) continue;

        ApolloFeedSubredditIconState state = ApolloFeedSubredditIconStateOf(node, spec);
        if (state != ApolloFeedSubredditIconStateWaiting) {
            // Resolved, or a HEAD check already in flight that will finish it.
            if (state != ApolloFeedSubredditIconStateUnknown) [finished addObject:node];
            continue;
        }

        NSNotification *note = [NSNotification notificationWithName:kApolloSubredditIconAvailableName object:link];
        ((void (*)(id, SEL, id))objc_msgSend)(node, sApolloSubredditIconAvailableSelector, note);
        delivered++;
        if (ApolloFeedSubredditIconStateOf(node, spec) != ApolloFeedSubredditIconStateWaiting) {
            resolved++;
            [finished addObject:node];
        }
    }

    if (finished.count) {
        os_unfair_lock_lock(&sApolloFeedSubredditIconWaitersLock);
        for (id node in finished) [sApolloFeedSubredditIconWaiters removeObject:node];
        os_unfair_lock_unlock(&sApolloFeedSubredditIconWaitersLock);
    }
    if (delivered) {
        ApolloLog(@"[FeedSubredditIcons] r/%@ icon available: delivered to %lu more waiting row(s), %lu resolved",
                  subreddit, (unsigned long)delivered, (unsigned long)resolved);
    }
}

%hook NSNotificationCenter

- (void)addObserver:(id)observer selector:(SEL)aSelector name:(NSNotificationName)aName object:(id)anObject {
    %orig;
    // Every observer registration in the process lands here: bail on the
    // selector pointer before doing anything else.
    if (aSelector != sApolloSubredditIconAvailableSelector) return;
    if (!observer || !anObject || ![aName isEqualToString:kApolloSubredditIconAvailableName]) return;
    if (!ApolloFeedSubredditIconSpecForObject(observer)) return;

    os_unfair_lock_lock(&sApolloFeedSubredditIconWaitersLock);
    [sApolloFeedSubredditIconWaiters addObject:observer];
    os_unfair_lock_unlock(&sApolloFeedSubredditIconWaitersLock);
}

%end

%hook _TtC6Apollo12PostInfoNode
- (void)subredditIconAvailableWithNotification:(id)notification {
    if (ApolloFeedSubredditIconShouldRunHandler(self)) %orig;
}
%end

%hook _TtC6Apollo17LargePostCellNode
- (void)subredditIconAvailableWithNotification:(id)notification {
    if (ApolloFeedSubredditIconShouldRunHandler(self)) %orig;
}
%end

%hook _TtC6Apollo13CrosspostNode
- (void)subredditIconAvailableWithNotification:(id)notification {
    if (ApolloFeedSubredditIconShouldRunHandler(self)) %orig;
}
%end

%ctor {
    sApolloSubredditIconAvailableSelector = NSSelectorFromString(@"subredditIconAvailableWithNotification:");
    // Pointer personality: entries are added mid-init on Texture's background
    // threads, so never message the node (-hash/-isEqual:) to store it.
    sApolloFeedSubredditIconWaiters = [[NSHashTable alloc]
        initWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality capacity:0];

    // All three classes own the handler (class-dump + Hopper); without it the
    // Logos hook below would add a method Apollo never calls, so bail instead.
    for (size_t i = 0; i < sizeof(kApolloFeedSubredditIconSpecs) / sizeof(kApolloFeedSubredditIconSpecs[0]); i++) {
        Class cls = objc_getClass(kApolloFeedSubredditIconSpecs[i].className);
        if (!cls || !class_getInstanceMethod(cls, sApolloSubredditIconAvailableSelector)) {
            ApolloLog(@"[FeedSubredditIcons] %s missing or has no subredditIconAvailableWithNotification: — not installing",
                      kApolloFeedSubredditIconSpecs[i].className);
            return;
        }
    }

    %init;

    [[NSNotificationCenter defaultCenter] addObserverForName:kApolloSubredditIconAvailableName
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        id postedLink = note.object;
        NSString *subreddit = ApolloFeedSubredditIconSubredditOfLink(postedLink);
        if (subreddit.length == 0) return;
        // Apollo posts from its fetch completions; the handlers touch Texture
        // nodes and our walk reads them, so run the delivery on main.
        if ([NSThread isMainThread]) {
            ApolloFeedSubredditIconDeliverToWaiters(postedLink, subreddit);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloFeedSubredditIconDeliverToWaiters(postedLink, subreddit);
            });
        }
    }];

    ApolloLog(@"[FeedSubredditIcons] hook installed (SubredditIconAvailable delivered to every waiting row of the subreddit)");
}
