#import "ApolloRandomSubreddit.h"
#import "ApolloSubredditName.h"
#import <os/lock.h>

const NSTimeInterval kApolloRandomArmWindow = 5.0;
const NSTimeInterval kApolloRandomReuseWindow = 10.0;
const NSTimeInterval kApolloRandomListingGrace = 2.0;
const NSTimeInterval kApolloRandomStatelessPairWindow = kApolloRandomReuseWindow;

@implementation ApolloRandomPendingRoll
@end

@implementation ApolloRandomStatelessMemo
@end

@implementation ApolloRandomRoute
@end

@implementation ApolloRandomArmInput
@end

@implementation ApolloRandomArmPlan
@end

static NSArray<NSString *> *ApolloRandomPathSegments(NSString *path) {
    if (path.length == 0) return @[];
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    for (NSString *segment in [path componentsSeparatedByString:@"/"]) {
        if (segment.length > 0) [segments addObject:segment];
    }
    return segments;
}

static NSString *ApolloRandomStripJSONSuffix(NSString *segment) {
    if (segment.length > 5 && [segment.lowercaseString hasSuffix:@".json"]) {
        return [segment substringToIndex:segment.length - 5];
    }
    return segment;
}

// The lowercased normalized name, or nil when `name` is not one community.
// Normalized names are ASCII [A-Za-z0-9_], so equal keys are exactly the
// case-insensitive matches ApolloRandomNamesEqual tests for.
static NSString *ApolloRandomKindKey(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return nil;
    // Fast path for the common case, a bare slug: when every character is
    // ASCII [A-Za-z0-9_] there is nothing to trim and no "r/" prefix, so the
    // normalized name is the string itself (unless it is a special feed) and
    // its key is its ASCII lowercase. Anything else takes the full path.
    NSUInteger length = name.length;
    unichar buffer[64];
    if (length > 0 && length <= sizeof(buffer) / sizeof(buffer[0])) {
        [name getCharacters:buffer range:NSMakeRange(0, length)];
        BOOL slug = YES;
        for (NSUInteger index = 0; index < length; index++) {
            unichar c = buffer[index];
            if (c >= 'A' && c <= 'Z') {
                buffer[index] = (unichar)(c + ('a' - 'A'));
            } else if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) {
                slug = NO;
                break;
            }
        }
        if (slug) {
            NSString *key = [[NSString alloc] initWithCharacters:buffer length:length];
            return ApolloSubredditNameIsSpecialFeed(key) ? nil : key;
        }
    }
    return ApolloNormalizedSubredditName(name).lowercaseString;
}

static BOOL ApolloRandomNamesEqual(NSString *left, NSString *right) {
    NSString *normalizedLeft = ApolloNormalizedSubredditName(left);
    NSString *normalizedRight = ApolloNormalizedSubredditName(right);
    if (normalizedLeft.length == 0 || normalizedRight.length == 0) return NO;
    return [normalizedLeft caseInsensitiveCompare:normalizedRight] == NSOrderedSame;
}

// The keys of `names` (non-strings and non-communities skipped): normalize the
// needles once, then each list entry is one hash lookup.
static NSSet<NSString *> *ApolloRandomKeySet(NSArray<NSString *> *names) {
    if (names.count == 0) return nil;
    NSMutableSet<NSString *> *keys = [NSMutableSet setWithCapacity:names.count];
    for (NSString *name in names) {
        NSString *key = ApolloRandomKindKey(name);
        if (key.length > 0) [keys addObject:key];
    }
    return keys;
}

// The key of every entry of `list`, index for index (NSNull where an entry has
// none). Normalizing a few thousand entries costs milliseconds, so the result
// is cached per immutable list instance: the configured lists are copied
// arrays that stay the same object until the source reloads. Any thread.
enum { kApolloRandomListKeyCacheSize = 4 };
static os_unfair_lock sApolloRandomListKeyLock = OS_UNFAIR_LOCK_INIT;
static NSArray *sApolloRandomListKeyLists[kApolloRandomListKeyCacheSize];
static NSArray *sApolloRandomListKeyValues[kApolloRandomListKeyCacheSize];
static NSUInteger sApolloRandomListKeyNext;

static NSArray *ApolloRandomListKeys(NSArray<NSString *> *list) {
    if (list.count == 0) return @[];
    // A mutable array could change behind the cache; it is keyed fresh.
    BOOL cacheable = ![list isKindOfClass:[NSMutableArray class]];
    if (cacheable) {
        NSArray *cached = nil;
        os_unfair_lock_lock(&sApolloRandomListKeyLock);
        for (NSUInteger index = 0; index < kApolloRandomListKeyCacheSize; index++) {
            if (sApolloRandomListKeyLists[index] == list) {
                cached = sApolloRandomListKeyValues[index];
                break;
            }
        }
        os_unfair_lock_unlock(&sApolloRandomListKeyLock);
        if (cached) return cached;
    }
    NSMutableArray *keys = [NSMutableArray arrayWithCapacity:list.count];
    for (NSString *name in list) {
        NSString *key = ApolloRandomKindKey(name);
        [keys addObject:key.length > 0 ? key : (id)[NSNull null]];
    }
    NSArray *result = [keys copy];
    if (cacheable) {
        os_unfair_lock_lock(&sApolloRandomListKeyLock);
        NSUInteger slot = sApolloRandomListKeyNext;
        sApolloRandomListKeyNext = (slot + 1) % kApolloRandomListKeyCacheSize;
        sApolloRandomListKeyLists[slot] = list;
        sApolloRandomListKeyValues[slot] = result;
        os_unfair_lock_unlock(&sApolloRandomListKeyLock);
    }
    return result;
}

static BOOL ApolloRandomEntryUsable(id name) {
    return [name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0;
}

// YES when the entry's precomputed key (from ApolloRandomListKeys) is in `keys`.
static BOOL ApolloRandomKeyIn(id key, NSSet<NSString *> *keys) {
    return keys && key != (id)[NSNull null] && [keys containsObject:key];
}

static BOOL ApolloRandomIsPostsSort(NSString *sort) {
    static NSSet<NSString *> *sorts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sorts = [NSSet setWithObjects:@"hot", @"new", @"top", @"best",
                                      @"rising", @"controversial", nil];
    });
    return [sorts containsObject:sort.lowercaseString];
}

BOOL ApolloRandomMatchSubredditPath(NSString *path,
                                    ApolloRandomRequestRole *role,
                                    ApolloRandomFeedKind *kind,
                                    NSString *__autoreleasing *community) {
    if (role) *role = ApolloRandomRequestRoleNone;
    if (kind) *kind = ApolloRandomFeedKindNone;
    if (community) *community = nil;
    NSArray<NSString *> *segments = ApolloRandomPathSegments(path);
    if (segments.count < 2 || segments.count > 3) return NO;
    if ([segments[0] caseInsensitiveCompare:@"r"] != NSOrderedSame) return NO;

    NSString *name = ApolloRandomStripJSONSuffix(segments[1]);
    if (name.length == 0 || [name rangeOfString:@"+"].location != NSNotFound) return NO;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    });
    if ([name rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;

    ApolloRandomRequestRole matched = ApolloRandomRequestRoleNone;
    if (segments.count == 2) {
        matched = ApolloRandomRequestRolePosts;
    } else {
        NSString *tail = ApolloRandomStripJSONSuffix(segments[2]);
        if (ApolloRandomIsPostsSort(tail)) matched = ApolloRandomRequestRolePosts;
        else if ([tail caseInsensitiveCompare:@"about"] == NSOrderedSame) matched = ApolloRandomRequestRoleAbout;
    }
    if (matched == ApolloRandomRequestRoleNone) return NO;

    ApolloRandomFeedKind matchedKind = ApolloRandomFeedKindNone;
    if ([name caseInsensitiveCompare:@"random"] == NSOrderedSame) matchedKind = ApolloRandomFeedKindSafe;
    else if ([name caseInsensitiveCompare:@"randnsfw"] == NSOrderedSame) matchedKind = ApolloRandomFeedKindNSFW;

    if (role) *role = matched;
    if (kind) *kind = matchedKind;
    if (community) *community = name;
    return YES;
}

BOOL ApolloRandomPostsListingHasCursor(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if (([item.name isEqualToString:@"after"] || [item.name isEqualToString:@"before"]) &&
            item.value.length > 0) {
            return YES;
        }
    }
    return NO;
}

BOOL ApolloRandomNamesContain(NSArray<NSString *> *names, NSString *name) {
    if (names.count == 0) return NO;
    // Normalize the needle once; each candidate is normalized once.
    NSString *key = ApolloRandomKindKey(name);
    if (key.length == 0) return NO;
    for (NSString *candidate in names) {
        if ([candidate isKindOfClass:[NSString class]] && [ApolloRandomKindKey(candidate) isEqualToString:key]) {
            return YES;
        }
    }
    return NO;
}

static NSString *ApolloRandomPickFromPool(NSArray<NSString *> *pool, ApolloRandomBoundFunction randomBound) {
    if (pool.count == 0) return nil;
    uint32_t bound = (uint32_t)pool.count;
    uint32_t index = randomBound(bound);
    if (index >= bound) index = bound - 1;
    return pool[index];
}

NSString *ApolloRandomPickSubreddit(NSArray<NSString *> *subreddits,
                                    NSArray<NSString *> *hardExcluding,
                                    NSArray<NSString *> *softExcluding,
                                    ApolloRandomBoundFunction randomBound) {
    if (subreddits.count == 0 || !randomBound) return nil;
    NSSet<NSString *> *hard = ApolloRandomKeySet(hardExcluding);
    NSSet<NSString *> *soft = ApolloRandomKeySet(softExcluding);
    NSArray *keys = ApolloRandomListKeys(subreddits);
    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
    NSMutableArray<NSString *> *notHard = [NSMutableArray array];
    NSMutableArray<NSString *> *usable = [NSMutableArray array];
    NSUInteger count = subreddits.count;
    for (NSUInteger index = 0; index < count; index++) {
        NSString *name = subreddits[index];
        if (!ApolloRandomEntryUsable(name)) continue;
        [usable addObject:name];
        id key = keys[index];
        if (ApolloRandomKeyIn(key, hard)) continue;
        [notHard addObject:name];
        if (ApolloRandomKeyIn(key, soft)) continue;
        [fresh addObject:name];
    }
    NSArray<NSString *> *pool = fresh.count > 0 ? fresh : (notHard.count > 0 ? notHard : usable);
    return ApolloRandomPickFromPool(pool, randomBound);
}

NSString *ApolloRandomPickSubredditAvoidingRecent(NSArray<NSString *> *subreddits,
                                                  NSArray<NSString *> *hardExcluding,
                                                  NSArray<NSString *> *recentNewestFirst,
                                                  ApolloRandomBoundFunction randomBound) {
    if (subreddits.count == 0 || !randomBound) return nil;
    // Recency rank by key: 0 is the newest pick.
    NSMutableDictionary<NSString *, NSNumber *> *ranks = [NSMutableDictionary dictionary];
    NSUInteger index = 0;
    for (NSString *name in recentNewestFirst) {
        NSString *key = ApolloRandomKindKey(name);
        if (key.length > 0 && !ranks[key]) ranks[key] = @(index);
        index++;
    }
    NSSet<NSString *> *hard = ApolloRandomKeySet(hardExcluding);
    NSArray *keys = ApolloRandomListKeys(subreddits);
    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
    NSMutableArray<NSString *> *leastRecent = [NSMutableArray array];
    NSInteger leastRecentRank = -1;
    NSMutableArray<NSString *> *usable = [NSMutableArray array];
    NSUInteger count = subreddits.count;
    for (NSUInteger index = 0; index < count; index++) {
        NSString *name = subreddits[index];
        if (!ApolloRandomEntryUsable(name)) continue;
        [usable addObject:name];
        id key = keys[index];
        if (ApolloRandomKeyIn(key, hard)) continue;
        NSNumber *rank = key != (id)[NSNull null] ? ranks[key] : nil;
        if (!rank) {
            [fresh addObject:name];
            continue;
        }
        if (rank.integerValue > leastRecentRank) {
            leastRecentRank = rank.integerValue;
            [leastRecent removeAllObjects];
        }
        if (rank.integerValue == leastRecentRank) [leastRecent addObject:name];
    }
    NSArray<NSString *> *pool = fresh.count > 0 ? fresh : (leastRecent.count > 0 ? leastRecent : usable);
    return ApolloRandomPickFromPool(pool, randomBound);
}

NSArray<NSString *> *ApolloRandomRecentPicks(NSDictionary<NSString *, NSNumber *> *kinds,
                                             NSArray<NSString *> *order,
                                             ApolloRandomFeedKind kind) {
    NSMutableArray<NSString *> *recent = [NSMutableArray array];
    if (kind != ApolloRandomFeedKindSafe && kind != ApolloRandomFeedKindNSFW) return recent;
    for (NSString *key in order.reverseObjectEnumerator) {
        if ((ApolloRandomFeedKind)kinds[key].integerValue == kind) [recent addObject:key];
    }
    return recent;
}

NSURL *ApolloRandomURLByReplacingCommunity(NSURL *url, NSString *community, NSString *replacement) {
    if (!url || community.length == 0 || replacement.length == 0) return nil;
    if ([replacement rangeOfString:@"/"].location != NSNotFound) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSArray<NSString *> *segments = ApolloRandomPathSegments(components.path);
    if (segments.count < 2 || [segments[0] caseInsensitiveCompare:@"r"] != NSOrderedSame) return nil;
    NSString *name = ApolloRandomStripJSONSuffix(segments[1]);
    // A path component, compared as written: "random" is not a normalized
    // community name, so ApolloRandomNamesEqual would reject it.
    if (name.length == 0 || [name caseInsensitiveCompare:community] != NSOrderedSame) return nil;

    NSString *suffix = [segments[1].lowercaseString hasSuffix:@".json"] ? @".json" : @"";
    NSMutableArray<NSString *> *replaced = [segments mutableCopy];
    replaced[1] = [replacement stringByAppendingString:suffix];
    components.path = [@"/" stringByAppendingString:[replaced componentsJoinedByString:@"/"]];
    return components.URL;
}

// The placeholder slug ("random" / "randnsfw", optionally "r/"-prefixed) in a
// title, or nil.
static NSString *ApolloRandomPlaceholderSlug(NSString *title) {
    if (![title isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"] || [clean hasPrefix:@"/R/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"] || [clean hasPrefix:@"R/"]) clean = [clean substringFromIndex:2];
    if ([clean caseInsensitiveCompare:@"random"] == NSOrderedSame ||
        [clean caseInsensitiveCompare:@"randnsfw"] == NSOrderedSame) {
        return clean;
    }
    return nil;
}

// The kind a "Random"/"randnsfw" placeholder names, or None for other text.
static ApolloRandomFeedKind ApolloRandomPlaceholderKind(NSString *text) {
    NSString *placeholder = ApolloRandomPlaceholderSlug(text);
    if (!placeholder) return ApolloRandomFeedKindNone;
    return [placeholder caseInsensitiveCompare:@"randnsfw"] == NSOrderedSame ? ApolloRandomFeedKindNSFW
                                                                            : ApolloRandomFeedKindSafe;
}

// YES when an entry of `list` has one of `needles` as its key.
static BOOL ApolloRandomListHoldsAny(NSArray<NSString *> *list, NSSet<NSString *> *needles) {
    if (needles.count == 0 || list.count == 0) return NO;
    for (id key in ApolloRandomListKeys(list)) {
        if (ApolloRandomKeyIn(key, needles)) return YES;
    }
    return NO;
}

ApolloRandomFeedKind ApolloRandomInferKind(NSString *labelText,
                                           NSString *title,
                                           NSArray<NSString *> *names,
                                           ApolloRandomFeedKind routedKind,
                                           NSDictionary<NSString *, NSNumber *> *pickedKinds,
                                           NSArray<NSString *> *safeSubreddits,
                                           NSArray<NSString *> *nsfwSubreddits) {
    ApolloRandomFeedKind labelKind = ApolloRandomPlaceholderKind(labelText);
    if (labelKind != ApolloRandomFeedKindNone) return labelKind;
    // Apollo writes navigationItem.title = "Random" on Random NSFW feeds too,
    // so only the NSFW placeholder is trusted from the title.
    if (ApolloRandomPlaceholderKind(title) == ApolloRandomFeedKindNSFW) return ApolloRandomFeedKindNSFW;
    for (NSString *name in names) {
        NSString *key = ApolloRandomKindKey(name);
        if (key.length == 0) continue;
        ApolloRandomFeedKind picked = (ApolloRandomFeedKind)pickedKinds[key].integerValue;
        if (picked == ApolloRandomFeedKindSafe || picked == ApolloRandomFeedKindNSFW) return picked;
    }
    // Membership needs both lists: a name missing from a list that is not
    // loaded proves nothing. It outranks the routed kind, which can be stale
    // (the jump bar switched the feed's kind since that route).
    if (safeSubreddits && nsfwSubreddits) {
        NSSet<NSString *> *needles = ApolloRandomKeySet(names);
        BOOL inSafe = ApolloRandomListHoldsAny(safeSubreddits, needles);
        BOOL inNSFW = ApolloRandomListHoldsAny(nsfwSubreddits, needles);
        if (inSafe != inNSFW) return inNSFW ? ApolloRandomFeedKindNSFW : ApolloRandomFeedKindSafe;
    }
    // Ambiguous or unknown membership (on both lists, on neither, a list not
    // loaded): the kind of the feed's last route, e.g. a failed load whose
    // model names nothing.
    if (routedKind == ApolloRandomFeedKindSafe || routedKind == ApolloRandomFeedKindNSFW) return routedKind;
    return ApolloRandomFeedKindNone;
}

void ApolloRandomRememberPickedKind(NSMutableDictionary<NSString *, NSNumber *> *kinds,
                                    NSMutableArray<NSString *> *order,
                                    NSString *name,
                                    ApolloRandomFeedKind kind,
                                    NSUInteger limit) {
    NSString *key = ApolloRandomKindKey(name);
    if (!kinds || !order || key.length == 0 || limit == 0) return;
    if (kind != ApolloRandomFeedKindSafe && kind != ApolloRandomFeedKindNSFW) return;
    [order removeObject:key];
    [order addObject:key];
    kinds[key] = @(kind);
    while (order.count > limit) {
        [kinds removeObjectForKey:order.firstObject];
        [order removeObjectAtIndex:0];
    }
}

static void ApolloRandomAddLeavingName(NSMutableArray<NSString *> *names, NSString *name) {
    NSString *normalized = ApolloNormalizedSubredditName(name);
    if (normalized.length == 0 || ApolloRandomNamesContain(names, normalized)) return;
    [names addObject:normalized];
}

ApolloRandomArmPlan *ApolloRandomPlanArm(ApolloRandomArmInput *input,
                                         NSDictionary<NSString *, NSNumber *> *pickedKinds,
                                         NSArray<NSString *> *safeSubreddits,
                                         NSArray<NSString *> *nsfwSubreddits,
                                         ApolloRandomBoundFunction randomBound) {
    ApolloRandomArmPlan *plan = [ApolloRandomArmPlan new];
    NSString *titleName = ApolloNormalizedSubredditName(input.title);
    BOOL previousPending = input.previousActive && !input.previousConfirmed &&
                           input.previousRolledName.length > 0;
    // While the previous pick is unconfirmed the guard shows it, whatever
    // Apollo's own title write said.
    plan.shownName = previousPending ? ApolloNormalizedSubredditName(input.previousRolledName) : titleName;

    // Hard: what is on screen and what Apollo will request now. Never picked
    // while the list has anything else.
    NSMutableArray<NSString *> *hard = [NSMutableArray array];
    ApolloRandomAddLeavingName(hard, plan.shownName);
    for (NSString *name in input.requestedNames) ApolloRandomAddLeavingName(hard, name);
    ApolloRandomAddLeavingName(hard, titleName);
    // The feed's last routed community: on a failed load it is what the feed
    // shows while Apollo's model names nothing.
    ApolloRandomAddLeavingName(hard, input.routedName);
    // Soft: communities earlier unconfirmed rolls left. Avoided while the list
    // has room, so consecutive banned rolls do not go back.
    NSMutableArray<NSString *> *soft = [NSMutableArray array];
    if (previousPending) {
        for (NSString *name in input.previousLeavingNames) {
            if (!ApolloRandomNamesContain(hard, name)) ApolloRandomAddLeavingName(soft, name);
        }
    }
    plan.hardNames = hard;
    plan.leavingNames = [hard arrayByAddingObjectsFromArray:soft];

    plan.kind = ApolloRandomInferKind(input.labelText, input.title, hard, input.routedKind, pickedKinds,
                                      safeSubreddits, nsfwSubreddits);
    if (plan.kind == ApolloRandomFeedKindNone) {
        plan.outcome = ApolloRandomArmOutcomeKindUnknown;
        return plan;
    }
    NSArray<NSString *> *list = plan.kind == ApolloRandomFeedKindNSFW ? nsfwSubreddits : safeSubreddits;
    plan.pickedName = ApolloRandomPickSubreddit(list, hard, soft, randomBound);
    plan.outcome = plan.pickedName.length > 0 ? ApolloRandomArmOutcomeArmed : ApolloRandomArmOutcomeNoCandidate;
    return plan;
}

BOOL ApolloRandomPendingRollIsLive(ApolloRandomPendingRoll *pending, NSTimeInterval now) {
    if (!pending || pending.pickedName.length == 0) return NO;
    if (pending.consumedAt <= 0) {
        NSTimeInterval age = now - pending.armedAt;
        return age >= 0 && age < kApolloRandomArmWindow;
    }
    NSTimeInterval age = now - pending.consumedAt;
    return age >= 0 && age < kApolloRandomReuseWindow;
}

static ApolloRandomRoute *ApolloRandomMakeRoute(ApolloRandomRouteSource source,
                                                ApolloRandomFeedKind kind,
                                                NSString *name) {
    if (name.length == 0) return nil;
    ApolloRandomRoute *route = [ApolloRandomRoute new];
    route.source = source;
    route.kind = kind;
    route.name = name;
    return route;
}

// YES when `memo` is a stateless route of `kind`, served within the pair
// window, that has not yet served a request of `role`.
static BOOL ApolloRandomStatelessMemoPairs(ApolloRandomStatelessMemo *memo,
                                           ApolloRandomRequestRole role,
                                           ApolloRandomFeedKind kind,
                                           NSTimeInterval now) {
    if (!memo || memo.name.length == 0 || memo.kind != kind) return NO;
    NSTimeInterval age = now - memo.routedAt;
    if (age < 0 || age >= kApolloRandomStatelessPairWindow) return NO;
    if (role == ApolloRandomRequestRolePosts) return !memo.servedPosts;
    if (role == ApolloRandomRequestRoleAbout) return !memo.servedAbout;
    return NO;
}

ApolloRandomRoute *ApolloRandomRouteRequest(ApolloRandomRequestRole role,
                                            ApolloRandomFeedKind pathKind,
                                            NSString *community,
                                            BOOL hasCursor,
                                            ApolloRandomPendingRoll *pending,
                                            ApolloRandomStatelessMemo *statelessMemo,
                                            NSTimeInterval now,
                                            NSArray<NSString *> *safeSubreddits,
                                            NSArray<NSString *> *nsfwSubreddits,
                                            NSDictionary<NSString *, NSNumber *> *pickedKinds,
                                            NSArray<NSString *> *pickedOrder,
                                            ApolloRandomBoundFunction randomBound) {
    if (community.length == 0 || role == ApolloRandomRequestRoleNone) return nil;
    if (role == ApolloRandomRequestRolePosts && hasCursor) return nil;
    BOOL explicitRandom = pathKind == ApolloRandomFeedKindSafe || pathKind == ApolloRandomFeedKindNSFW;
    NSArray<NSString *> *list = pathKind == ApolloRandomFeedKindNSFW ? nsfwSubreddits : safeSubreddits;

    BOOL pendingLive = ApolloRandomPendingRollIsLive(pending, now);
    if (pendingLive) {
        BOOL joins = NO;
        if (explicitRandom) {
            // An about joins for the whole reuse window. A listing joins
            // before the roll's first request, or within a short grace after
            // it (a duplicate or retried listing of the same gesture); later
            // it is a new load, e.g. the jump bar's "Random" tapped after a pull.
            NSTimeInterval sinceUse = now - pending.consumedAt;
            joins = pathKind == pending.kind &&
                    (role == ApolloRandomRequestRoleAbout || pending.consumedAt <= 0 ||
                     (sinceUse >= 0 && sinceUse < kApolloRandomListingGrace));
        } else {
            // Only the communities the feed shows or requests. Soft names
            // (left by earlier banned rolls) only keep the pick away from
            // them; another feed asking for one must not land on the pick.
            joins = ApolloRandomNamesContain(pending.hardNames, community);
        }
        if (joins) return ApolloRandomMakeRoute(ApolloRandomRouteSourcePending, pending.kind, pending.pickedName);
        // The pull's own refresh, armed with the wrong kind: Apollo's path
        // says which list this feed draws from. Only a roll no request has
        // used yet; a later other-kind random is a new load (stateless).
        if (explicitRandom && pending.consumedAt <= 0) {
            ApolloRandomRoute *route = ApolloRandomMakeRoute(
                ApolloRandomRouteSourcePending, pathKind,
                ApolloRandomPickSubredditAvoidingRecent(list, pending.leavingNames,
                                                        ApolloRandomRecentPicks(pickedKinds, pickedOrder, pathKind),
                                                        randomBound));
            route.repicked = YES;
            return route;
        }
    }
    if (!explicitRandom) return nil;

    ApolloRandomRoute *route = nil;
    // The other half of a stateless load: a listing and its about each name
    // /r/random, and must land on the same community.
    if (ApolloRandomStatelessMemoPairs(statelessMemo, role, pathKind, now)) {
        route = ApolloRandomMakeRoute(ApolloRandomRouteSourceStateless, pathKind, statelessMemo.name);
        route.reusedStateless = YES;
    } else {
        route = ApolloRandomMakeRoute(ApolloRandomRouteSourceStateless, pathKind,
                                      ApolloRandomPickSubredditAvoidingRecent(
                                          list, nil, ApolloRandomRecentPicks(pickedKinds, pickedOrder, pathKind),
                                          randomBound));
    }
    // A new random listing of the roll's kind replaces the rolled community;
    // the roll's later requests (its about) must not bring the pick back.
    route.supersedesPending = pendingLive && role == ApolloRandomRequestRolePosts && pathKind == pending.kind;
    return route;
}

ApolloRandomStatelessMemo *ApolloRandomStatelessMemoAfterRoute(ApolloRandomStatelessMemo *memo,
                                                               ApolloRandomRoute *route,
                                                               ApolloRandomRequestRole role,
                                                               NSTimeInterval now) {
    if (route.source != ApolloRandomRouteSourceStateless || route.name.length == 0) return memo;
    if (route.reusedStateless && memo) {
        // The pair is complete for this role; the memo's time is not
        // refreshed, so it never outlives the first request's window.
        if (role == ApolloRandomRequestRolePosts) memo.servedPosts = YES;
        if (role == ApolloRandomRequestRoleAbout) memo.servedAbout = YES;
        return memo;
    }
    ApolloRandomStatelessMemo *fresh = [ApolloRandomStatelessMemo new];
    fresh.kind = route.kind;
    fresh.name = route.name;
    fresh.routedAt = now;
    fresh.servedPosts = role == ApolloRandomRequestRolePosts;
    fresh.servedAbout = role == ApolloRandomRequestRoleAbout;
    return fresh;
}

BOOL ApolloRandomRequestNamesLeaving(ApolloRandomRequestRole role,
                                     ApolloRandomFeedKind pathKind,
                                     NSString *community,
                                     BOOL hasCursor,
                                     NSArray<NSString *> *leavingNames) {
    if (role != ApolloRandomRequestRolePosts && role != ApolloRandomRequestRoleAbout) return NO;
    if (role == ApolloRandomRequestRolePosts && hasCursor) return NO;
    if (pathKind != ApolloRandomFeedKindNone) return NO;
    return ApolloRandomNamesContain(leavingNames, community);
}

// The range of the slug in a "Random"/"randnsfw" placeholder title, or
// NSNotFound when `title` is not one.
static NSRange ApolloRandomPlaceholderRange(NSString *title) {
    NSString *slug = ApolloRandomPlaceholderSlug(title);
    if (!slug) return NSMakeRange(NSNotFound, 0);
    return [title rangeOfString:slug options:NSCaseInsensitiveSearch | NSBackwardsSearch];
}

ApolloRandomTitleVerdict ApolloRandomJudgeTitle(NSString *title,
                                                NSArray<NSString *> *leavingNames,
                                                NSString *rolledName,
                                                BOOL confirmed,
                                                NSString *__autoreleasing *rewritten) {
    if (rewritten) *rewritten = nil;
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return ApolloRandomTitleVerdictKeep;
    if (rolledName.length == 0) return ApolloRandomTitleVerdictKeep;

    NSRange slug = ApolloRandomPlaceholderRange(title);
    if (slug.location == NSNotFound) {
        NSString *name = ApolloNormalizedSubredditName(title);
        // Not a single community (a display name, a placeholder): not ours to judge.
        if (name.length == 0) return ApolloRandomTitleVerdictKeep;
        if (ApolloRandomNamesEqual(name, rolledName)) return ApolloRandomTitleVerdictConfirm;
        if (confirmed || !ApolloRandomNamesContain(leavingNames, name)) return ApolloRandomTitleVerdictRelease;
        slug = [title rangeOfString:name options:NSCaseInsensitiveSearch | NSBackwardsSearch];
    } else if (confirmed) {
        return ApolloRandomTitleVerdictRelease;
    }
    if (slug.location == NSNotFound) return ApolloRandomTitleVerdictKeep;
    // Keep whatever surrounds the slug ("r/", whitespace) and swap the slug.
    if (rewritten) *rewritten = [title stringByReplacingCharactersInRange:slug withString:rolledName];
    return ApolloRandomTitleVerdictRewrite;
}

BOOL ApolloRandomFeedTakesRoute(NSString *labelText,
                                NSString *title,
                                NSArray<NSString *> *modelNames,
                                NSString *routedName,
                                ApolloRandomFeedKind routeKind) {
    if (routeKind != ApolloRandomFeedKindSafe && routeKind != ApolloRandomFeedKindNSFW) return NO;
    BOOL hasLabel = [labelText isKindOfClass:[NSString class]] && labelText.length > 0;
    if (hasLabel) {
        if (ApolloRandomPlaceholderKind(labelText) == routeKind) return YES;
    } else if (ApolloRandomPlaceholderKind(title) != ApolloRandomFeedKindNone) {
        return YES;
    }
    // A feed sitting on its own failed route: it shows the routed community
    // and Apollo's model does not name it.
    NSString *shown = ApolloNormalizedSubredditName(hasLabel ? labelText : title);
    if (shown.length == 0 || !ApolloRandomNamesEqual(shown, routedName)) return NO;
    return !ApolloRandomNamesContain(modelNames, routedName);
}
