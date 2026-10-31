#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <os/lock.h>

#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloWebJSON.h"           // ApolloWebJSONOptionalReadBackoff
#import "ApolloWebSessionStore.h"   // ApolloActiveWebSessionUsername

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Fix (#1607, and #1463 before it): subreddit icons stay empty circles in the
// Subreddits list and on feed posts. The circle is filled with the theme's
// background color, so on a dark theme it reads as a black dot.
//
// Apollo keeps subreddit icons in SubredditIconTracker (name -> URL, saved in
// defaults, never expired). Any subreddit it has no entry for is looked up by
// fullname through -[RDKClient thingsByFullNames:completion:] (GET /api/info):
//
//   RedditListViewController sub_10063c6e0 -> sub_100650fcc: every subscribed
//     subreddit missing from the tracker, in batches of 100 t5_ ids; the
//     completion (sub_10063d040) saves each returned RDKSubreddit's name,
//     iconURL and key color, then reloads the list.
//   PostsViewController sub_1005c2010: one batch per feed page; the completion
//     (sub_1005b1e20) saves the icons and posts SubredditIconAvailable.
//
// Rows of a subreddit with no tracker entry show the placeholder until that
// answer arrives. Reddit no longer answers /api/info for some API-key setups:
// the reporter (RedReader client id) has the Inbox's /api/info parent lookup
// failing in the same log ("[InboxParents] Lookup of 22 reply parent(s) failed
// (no list)"), and a commenter on #1463 says signing in with the Dystopia client
// id brings the icons back. RedditKit turns a body that isn't a Listing (Reddit's HTML
// block page) into (nil, nil) (objectsFromListingResponse: checks kind ==
// Listing), so Apollo saves nothing and the circles never fill. Subreddits the
// tracker already had keep their icons, which is why only some rows break and
// why it looks fine on an account whose /api/info still answers.
//
// Fix strategy
// ------------
// When an all-t5_ lookup comes back without subreddits, answer it ourselves
// with RDKSubreddit objects for the same ids, so Apollo's own completion saves
// the icons exactly as if /api/info had answered (the tracker then keeps them,
// so this runs once per subreddit):
//   1. subreddits already seen this session: every t5 RedditKit builds out of
//      a listing (+[RDKObjectBuilder objectFromJSON:], subreddit search for
//      one), plus what steps 2 and 3 loaded;
//   2. the account's subscriptions (GET /subreddits/mine/subscriber, 100 per
//      page, once per client per session): the whole Subreddits list and the
//      Home feed;
//   3. GET /r/<name>/about for what's left, when a parsed post told
//      us the name behind the t5_ id (Popular, All, other feeds).
// The account's own client makes every request, so API-key and API-Key-Free
// accounts each go through their usual route.

static NSUInteger const kApolloSubredditIconLookupMaxRemembered = 4000;
static NSUInteger const kApolloSubredditIconLookupMaxSubscriptionPages = 20;   // 2,000 subscriptions
static NSUInteger const kApolloSubredditIconLookupMaxAboutLookups = 25;        // per unanswered batch
static NSUInteger const kApolloSubredditIconLookupAboutConcurrency = 4;
// A failed subscription load is retried by the next unanswered batch after this.
static NSTimeInterval const kApolloSubredditIconLookupSubscriptionRetry = 5.0 * 60.0;
// RedditKit's subscriber category (sub_100040320: 2 and 3 are contributor and moderator).
static unsigned long long const kApolloSubredditIconLookupSubscriberCategory = 1;

typedef NS_ENUM(NSInteger, ApolloSubredditIconSubscriptionState) {
    ApolloSubredditIconSubscriptionStateLoading,
    ApolloSubredditIconSubscriptionStateLoaded,
    ApolloSubredditIconSubscriptionStateFailed,
};

@interface ApolloSubredditIconSubscriptionLoad : NSObject
@property (nonatomic) ApolloSubredditIconSubscriptionState state;
@property (nonatomic, strong) NSDate *finishedAt;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *waiters;
@end

@implementation ApolloSubredditIconSubscriptionLoad
@end

// Filled from RedditKit's parse threads, read on main: every access takes the lock.
// A subreddit is kept as a t5 JSON object with only what the icon completions
// read (name, iconURL from community_icon/icon_img, the two colors), not the
// RDKSubreddit: that one carries the sidebar text, and the account-specific
// user_is_* flags that must not answer another account's lookup.
static os_unfair_lock sApolloSubredditIconLookupLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSDictionary *> *sApolloSubredditIconLookupSubreddits; // t5_ id -> t5 JSON
static NSMutableDictionary<NSString *, NSString *> *sApolloSubredditIconLookupNames;          // t5_ id -> display name
// Main thread only. Client -> its subscription load. Weak keys, so the table
// never keeps a signed-out account's client alive (its small entry lingers until
// the table compacts; a new client can't match a zeroed key).
static NSMapTable<id, ApolloSubredditIconSubscriptionLoad *> *sApolloSubredditIconLookupSubscriptionLoads;

static BOOL ApolloSubredditIconLookupIsFullName(id value) {
    return [value isKindOfClass:[NSString class]] && [value hasPrefix:@"t5_"] && [value length] > 3;
}

static BOOL ApolloSubredditIconLookupIsName(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] > 0;
}

// Caller holds the lock. Both maps only grow from what Reddit sent this
// session; past the cap they start over rather than track recency.
static void ApolloSubredditIconLookupRememberSubredditLocked(NSString *fullName, NSString *name, NSDictionary *json) {
    if (sApolloSubredditIconLookupSubreddits.count >= kApolloSubredditIconLookupMaxRemembered) {
        [sApolloSubredditIconLookupSubreddits removeAllObjects];
    }
    if (sApolloSubredditIconLookupNames.count >= kApolloSubredditIconLookupMaxRemembered) {
        [sApolloSubredditIconLookupNames removeAllObjects];
    }
    if (json) sApolloSubredditIconLookupSubreddits[fullName] = json;
    if (name) sApolloSubredditIconLookupNames[fullName] = name;
}

static void ApolloSubredditIconLookupCopyString(NSMutableDictionary *data, NSString *key, id value) {
    if ([value isKindOfClass:[NSURL class]]) value = [value absoluteString];
    if ([value isKindOfClass:[NSString class]]) data[key] = value;
}

// RDKSubreddit's key paths (JSONKeyPathsByPropertyKey, Apollo 1.15.11): name <-
// display_name, fullName <- name, identifier <- id, communityIconURL <-
// community_icon, iconImageURL <- icon_img, redesignColorHexcode <-
// primary_color, oldSiteColorHexcode <- key_color.
static void ApolloSubredditIconLookupRememberSubreddit(id subreddit) {
    if (![subreddit isKindOfClass:ApolloClassRDKSubreddit]) return;
    NSString *identifier = ApolloSendObject(subreddit, @selector(identifier));
    NSString *fullName = ApolloSendObject(subreddit, @selector(fullName));
    if (!ApolloSubredditIconLookupIsFullName(fullName)) {
        fullName = ApolloSubredditIconLookupIsName(identifier) ? [@"t5_" stringByAppendingString:identifier] : nil;
    }
    NSString *name = ApolloSendObject(subreddit, @selector(name));
    if (!ApolloSubredditIconLookupIsFullName(fullName) || !ApolloSubredditIconLookupIsName(name)) return;

    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:fullName, @"name", name, @"display_name", nil];
    ApolloSubredditIconLookupCopyString(data, @"id", identifier);
    ApolloSubredditIconLookupCopyString(data, @"community_icon", ApolloSendObject(subreddit, @selector(communityIconURL)));
    ApolloSubredditIconLookupCopyString(data, @"icon_img", ApolloSendObject(subreddit, @selector(iconImageURL)));
    ApolloSubredditIconLookupCopyString(data, @"primary_color", ApolloSendObject(subreddit, @selector(redesignColorHexcode)));
    ApolloSubredditIconLookupCopyString(data, @"key_color", ApolloSendObject(subreddit, @selector(oldSiteColorHexcode)));
    NSDictionary *json = @{ @"kind": @"t5", @"data": [data copy] };

    os_unfair_lock_lock(&sApolloSubredditIconLookupLock);
    ApolloSubredditIconLookupRememberSubredditLocked(fullName, name, json);
    os_unfair_lock_unlock(&sApolloSubredditIconLookupLock);
}

// A t5 RedditKit just built, or the subreddit a post names. Runs for every
// object RedditKit parses (whole comment threads too), so anything that isn't
// a t5 or t3 leaves on the kind check.
static void ApolloSubredditIconLookupRememberJSON(id json, id object) {
    if (![json isKindOfClass:[NSDictionary class]]) return;
    id kind = json[@"kind"];
    BOOL isSubreddit = [kind isEqual:@"t5"];
    if (!isSubreddit && ![kind isEqual:@"t3"]) return;
    id data = json[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) return;
    if (isSubreddit) {
        ApolloSubredditIconLookupRememberSubreddit(object);
        return;
    }
    id fullName = data[@"subreddit_id"];
    id name = data[@"subreddit"];
    if (!ApolloSubredditIconLookupIsFullName(fullName) || !ApolloSubredditIconLookupIsName(name)) return;
    os_unfair_lock_lock(&sApolloSubredditIconLookupLock);
    if (!sApolloSubredditIconLookupNames[fullName]) ApolloSubredditIconLookupRememberSubredditLocked(fullName, name, nil);
    os_unfair_lock_unlock(&sApolloSubredditIconLookupLock);
}

// Splits `fullNames` into subreddits we have (as t5 JSON) and ids we don't.
static NSArray<NSDictionary *> *ApolloSubredditIconLookupKnownSubreddits(NSArray<NSString *> *fullNames,
                                                                         NSMutableArray<NSString *> *missing) {
    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
    [missing removeAllObjects];
    os_unfair_lock_lock(&sApolloSubredditIconLookupLock);
    for (NSString *fullName in fullNames) {
        NSDictionary *json = sApolloSubredditIconLookupSubreddits[fullName];
        if (json) [found addObject:json];
        else [missing addObject:fullName];
    }
    os_unfair_lock_unlock(&sApolloSubredditIconLookupLock);
    return found;
}

// The answer Apollo's completion casts to [RDKSubreddit], built by RedditKit's
// own parser as /api/info's children would be.
static NSArray *ApolloSubredditIconLookupBuildSubreddits(NSArray<NSDictionary *> *jsons) {
    NSMutableArray *subreddits = [NSMutableArray arrayWithCapacity:jsons.count];
    for (NSDictionary *json in jsons) {
        id subreddit = ((id (*)(id, SEL, id))objc_msgSend)(ApolloClassRDKObjectBuilder, @selector(objectFromJSON:), json);
        if ([subreddit isKindOfClass:ApolloClassRDKSubreddit]) [subreddits addObject:subreddit];
    }
    return subreddits;
}

// MARK: - Subscriptions

static void ApolloSubredditIconLookupFinishSubscriptions(ApolloSubredditIconSubscriptionLoad *load, BOOL loaded,
                                                          NSUInteger count, NSUInteger pages) {
    load.state = loaded ? ApolloSubredditIconSubscriptionStateLoaded : ApolloSubredditIconSubscriptionStateFailed;
    load.finishedAt = [NSDate date];
    ApolloLog(@"[SubredditIconLookup] %@ %lu subscription(s) in %lu page(s) for icon lookups",
              loaded ? @"Loaded" : @"Stopped after", (unsigned long)count, (unsigned long)pages);
    NSArray<dispatch_block_t> *waiters = [load.waiters copy];
    [load.waiters removeAllObjects];
    for (dispatch_block_t waiter in waiters) waiter();
}

// Main thread. Loads page after page, remembering each subreddit, until Reddit
// runs out of pages or the cap.
static void ApolloSubredditIconLookupLoadSubscriptionPage(id client, ApolloSubredditIconSubscriptionLoad *load,
                                                         id pagination, NSUInteger page, NSUInteger count) {
    SEL selector = @selector(subscribedSubredditsInCategory:pagination:completion:);
    __weak id weakClient = client;
    // sub_10004048c answers (subreddits, next page's pagination, nil), or (nil, nil, error).
    void (^completion)(id, id, NSError *) = ^(id subreddits, id next, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger total = count;
            if ([subreddits isKindOfClass:[NSArray class]]) {
                for (id subreddit in subreddits) ApolloSubredditIconLookupRememberSubreddit(subreddit);
                total += [subreddits count];
            }
            id after = ApolloSendObject(next, @selector(after));
            BOOL morePages = !error && [subreddits isKindOfClass:[NSArray class]] &&
                             [after isKindOfClass:[NSString class]] && [after length] > 0;
            id strongClient = weakClient;
            if (!morePages || !strongClient || page + 1 >= kApolloSubredditIconLookupMaxSubscriptionPages) {
                ApolloSubredditIconLookupFinishSubscriptions(load, !error && [subreddits isKindOfClass:[NSArray class]],
                                                              total, page + 1);
                return;
            }
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(next, @selector(setLimit:), 100);
            ApolloSubredditIconLookupLoadSubscriptionPage(strongClient, load, next, page + 1, total);
        });
    };
    ((id (*)(id, SEL, unsigned long long, id, id))objc_msgSend)(client, selector,
        kApolloSubredditIconLookupSubscriberCategory, pagination, completion);
}

// Main thread. Runs `then` once the client's subscriptions are remembered (or
// can't be loaded right now).
static void ApolloSubredditIconLookupWithSubscriptions(id client, dispatch_block_t then) {
    if (![client respondsToSelector:@selector(subscribedSubredditsInCategory:pagination:completion:)] ||
        ![ApolloClassRDKPagination respondsToSelector:@selector(paginationWithLimit:)]) {
        then();
        return;
    }
    ApolloSubredditIconSubscriptionLoad *load = [sApolloSubredditIconLookupSubscriptionLoads objectForKey:client];
    if (load && load.state == ApolloSubredditIconSubscriptionStateLoading) {
        [load.waiters addObject:[then copy]];
        return;
    }
    if (load && (load.state == ApolloSubredditIconSubscriptionStateLoaded ||
                 -[load.finishedAt timeIntervalSinceNow] < kApolloSubredditIconLookupSubscriptionRetry)) {
        then();
        return;
    }
    load = [ApolloSubredditIconSubscriptionLoad new];
    load.state = ApolloSubredditIconSubscriptionStateLoading;
    load.waiters = [NSMutableArray arrayWithObject:[then copy]];
    [sApolloSubredditIconLookupSubscriptionLoads setObject:load forKey:client];
    id pagination = ((id (*)(id, SEL, unsigned long))objc_msgSend)(ApolloClassRDKPagination, @selector(paginationWithLimit:), 100);
    ApolloSubredditIconLookupLoadSubscriptionPage(client, load, pagination, 0, 0);
}

// MARK: - About pages

// Main thread only.
@interface ApolloSubredditIconAboutBatch : NSObject
@property (nonatomic, weak) id client;
@property (nonatomic, strong) NSMutableArray<NSString *> *queue;
@property (nonatomic) NSUInteger running;
@property (nonatomic, copy) dispatch_block_t done;
@end

@implementation ApolloSubredditIconAboutBatch
@end

// Starts lookups until the batch has its share in flight; calls `done` once
// the last one is back.
static void ApolloSubredditIconLookupPumpAbout(ApolloSubredditIconAboutBatch *batch) {
    id client = batch.client;
    while (client && batch.queue.count > 0 && batch.running < kApolloSubredditIconLookupAboutConcurrency) {
        NSString *name = batch.queue.firstObject;
        [batch.queue removeObjectAtIndex:0];
        batch.running++;
        // RDKClient's completion: ^(RDKSubreddit *subreddit, NSError *error).
        void (^completion)(id, NSError *) = ^(id subreddit, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloSubredditIconLookupRememberSubreddit(subreddit);
                batch.running--;
                ApolloSubredditIconLookupPumpAbout(batch);
            });
        };
        ((id (*)(id, SEL, id, id))objc_msgSend)(client, @selector(subredditWithName:completion:), name, completion);
    }
    if (batch.running == 0 && batch.done) {
        dispatch_block_t done = batch.done;
        batch.done = nil;
        done();
    }
}

// Main thread. Fetches /r/<name>/about for each name, a few at a time.
static void ApolloSubredditIconLookupFetchAbout(id client, NSArray<NSString *> *names, dispatch_block_t done) {
    if (names.count == 0 || ![client respondsToSelector:@selector(subredditWithName:completion:)] ||
        // Optional reads stand down while Reddit rate-limits an API-Key-Free session.
        ApolloWebJSONOptionalReadBackoff(ApolloActiveWebSessionUsername()) > 0) {
        done();
        return;
    }
    ApolloSubredditIconAboutBatch *batch = [ApolloSubredditIconAboutBatch new];
    batch.client = client;
    batch.queue = [names mutableCopy];
    batch.done = done;
    ApolloSubredditIconLookupPumpAbout(batch);
}

// MARK: - Answering Apollo's lookup

// Main thread. Calls `done` with RDKSubreddit objects for as many of
// `fullNames` as could be found (possibly none).
static void ApolloSubredditIconLookupResolve(id client, NSArray<NSString *> *fullNames, void (^done)(NSArray *)) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSInteger cached = (NSInteger)ApolloSubredditIconLookupKnownSubreddits(fullNames, missing).count;
    // The counts are for the log only (the maps can start over mid-lookup).
    void (^finish)(NSInteger) = ^(NSInteger afterSubscriptions) {
        NSMutableArray<NSString *> *stillMissing = [NSMutableArray array];
        NSArray *found = ApolloSubredditIconLookupBuildSubreddits(ApolloSubredditIconLookupKnownSubreddits(fullNames, stillMissing));
        ApolloLog(@"[SubredditIconLookup] Answered %lu of %lu subreddit icon lookup(s) without /api/info "
                  @"(%ld already loaded, %ld from subscriptions, %ld from about pages)",
                  (unsigned long)found.count, (unsigned long)fullNames.count, (long)cached,
                  (long)MAX(0, afterSubscriptions - cached), (long)MAX(0, (NSInteger)found.count - MAX(cached, afterSubscriptions)));
        done(found);
    };
    if (missing.count == 0) {
        finish(cached);
        return;
    }
    ApolloSubredditIconLookupWithSubscriptions(client, ^{
        NSMutableArray<NSString *> *afterSubscriptions = [NSMutableArray array];
        NSInteger knownAfterSubscriptions = (NSInteger)ApolloSubredditIconLookupKnownSubreddits(fullNames, afterSubscriptions).count;
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        os_unfair_lock_lock(&sApolloSubredditIconLookupLock);
        for (NSString *fullName in afterSubscriptions) {
            NSString *name = sApolloSubredditIconLookupNames[fullName];
            if (name && names.count < kApolloSubredditIconLookupMaxAboutLookups) [names addObject:name];
        }
        os_unfair_lock_unlock(&sApolloSubredditIconLookupLock);
        ApolloSubredditIconLookupFetchAbout(client, names, ^{ finish(knownAfterSubscriptions); });
    });
}

// Apollo's subreddit icon batches ask for t5_ ids only; anything else (Inbox
// parents, Recently Read, posted videos) passes straight through.
static NSArray<NSString *> *ApolloSubredditIconLookupFullNames(id fullNames) {
    if (![fullNames isKindOfClass:[NSArray class]] || [fullNames count] == 0) return nil;
    for (id fullName in fullNames) {
        if (!ApolloSubredditIconLookupIsFullName(fullName)) return nil;
    }
    // -thingsByFullNames: sends the first 100 (sub_10003e8d0).
    NSArray *ids = fullNames;
    return ids.count > 100 ? [ids subarrayWithRange:NSMakeRange(0, 100)] : ids;
}

%hook RDKObjectBuilder

+ (id)objectFromJSON:(id)json {
    id object = %orig(json);
    ApolloSubredditIconLookupRememberJSON(json, object);
    return object;
}

%end

%hook RDKClient

- (id)thingsByFullNames:(id)fullNames completion:(void (^)(NSArray *, NSError *))completion {
    NSArray<NSString *> *ids = completion ? ApolloSubredditIconLookupFullNames(fullNames) : nil;
    if (!ids) return %orig;
    __weak id weakClient = self;
    void (^lookupCompletion)(NSArray *, NSError *) = ^(NSArray *things, NSError *error) {
        // Reddit answered with subreddits: nothing to do. An empty listing (every
        // id banned or gone) and a failure both fall through.
        if ([things isKindOfClass:[NSArray class]] && things.count > 0) {
            completion(things, error);
            return;
        }
        id client = weakClient;
        if (!client) {
            completion(things, error);
            return;
        }
        ApolloLog(@"[SubredditIconLookup] /api/info gave no subreddits for %lu icon lookup(s) (%@); looking them up another way",
                  (unsigned long)ids.count, error.localizedDescription ?: ([things isKindOfClass:[NSArray class]] ? @"empty listing" : @"no list"));
        void (^answer)(void) = ^{
            ApolloSubredditIconLookupResolve(client, ids, ^(NSArray *subreddits) {
                if (subreddits.count > 0) completion(subreddits, nil);
                else completion(things, error);
            });
        };
        // RedditKit answers on main; the lookup state is main-thread only.
        if ([NSThread isMainThread]) answer();
        else dispatch_async(dispatch_get_main_queue(), answer);
    };
    return %orig(fullNames, lookupCompletion);
}

%end

%ctor {
    if (!ApolloClassRDKClient || !ApolloClassRDKObjectBuilder || !ApolloClassRDKSubreddit ||
        !class_getInstanceMethod(ApolloClassRDKClient, @selector(thingsByFullNames:completion:))) {
        ApolloLog(@"[SubredditIconLookup] RDKClient/RDKObjectBuilder/RDKSubreddit missing — not installing");
        return;
    }
    sApolloSubredditIconLookupSubreddits = [NSMutableDictionary dictionary];
    sApolloSubredditIconLookupNames = [NSMutableDictionary dictionary];
    sApolloSubredditIconLookupSubscriptionLoads = [NSMapTable weakToStrongObjectsMapTable];
    %init;
    ApolloLog(@"[SubredditIconLookup] hook installed (subreddit icons /api/info doesn't answer come from subscriptions and about pages)");
}
