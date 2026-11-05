#import "ApolloAllPlusNSFW.h"
#import "ApolloAllPlusMerge.h"
#import "ApolloAccountCredentials.h"   // ApolloActiveAccountUsername()
#import "ApolloState.h"
#import "ApolloCommon.h"
#import <math.h>

// The NSFW candidates come from Reddit's site-wide NSFW hot search, which
// takes about two seconds. The r/all page never waits for it: searches run in
// the background and keep a buffer filled ahead of the pages that merge from
// it. All state below is touched only on APQueue(): pages parse on the
// networking stack's concurrent processing queue and searches complete on
// NSURLSession's delegate queue.
//
// Only the hot-ranked sorts (hot, best, rising -- and the bare /r/all, which is
// hot) are blended. The search ranks by hot and carries no time window, so its
// candidates have no business in Top/New/Controversial (Top / Past Hour would
// otherwise show a days-old post); those pages are left stock without touching
// any state here.

// Everything cached or in flight belongs to ONE account: the owner. It is the
// active account's lowercased username plus its auth mode ("oauth" when a real
// bearer is in hand, "web" for an API-Key-Free account) -- not the bearer
// itself, which refreshes without the account changing. Every merge recomputes
// the owner; a different one (account switch, sign-out, auth mode change) wipes
// the buffer, the cursor and the first-batch cache and bumps the generation, so
// account B never sees A's cached dictionaries (A's vote state included) and a
// search A started can't publish into B's buffer.
static NSString *sAPOwner = nil;

// Search cursor, advanced as the buffer refills. Reset on a fresh r/all load
// (an inbound request with no `after`).
static NSString *sAPNsfwAfter = nil;

// Candidates carried across pages. Candidates that don't clear a page's floor
// stay buffered and drain on later, weaker pages -- no per-page quota.
static NSMutableArray *sAPBuffer = nil;
static NSMutableSet<NSString *> *sAPSeen = nil;
static const NSInteger kAPRefillTarget = 100;

// Refill bookkeeping. A fresh load, an owner change and ApolloAllPlusInvalidate
// all bump the generation and cancel the in-flight search, so a completion from
// before is dropped instead of filling the new buffer.
static BOOL sAPRefilling = NO;
static BOOL sAPExhausted = NO;   // the search ran out (or only repeated itself)
static NSUInteger sAPGeneration = 0;
static NSURLSessionDataTask *sAPTask = nil;   // the in-flight search, for cancellation

// The first search page (no cursor) and when it arrived. A fresh load reached
// by pull-to-refresh or reopening r/all seeds the buffer from it while it is
// recent, so page 1 can still carry NSFW posts without waiting on a search.
// A cold start has none: page 1 is plain r/all and the blend starts on page 2
// (which is where it usually starts anyway -- page 1's natives are the hottest).
// Owned like the buffer: an owner change drops it.
static NSArray *sAPFirstBatch = nil;
static NSString *sAPFirstBatchAfter = nil;
static CFAbsoluteTime sAPFirstBatchTime = 0;
static const CFTimeInterval kAPFirstBatchMaxAge = 10 * 60;

// Candidate fetch size, at Reddit's per-request ceiling.
static const NSInteger kAPFetchLimit = 100;

static dispatch_queue_t APQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.apolloreborn.allplus", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// "/r/all", "/r/All/best.json" etc. — case-insensitive `all` segment, `.json` tolerated.
static BOOL IsRAllPath(NSURL *url) {
    NSArray<NSString *> *parts = url.pathComponents;
    NSUInteger rIdx = [parts indexOfObject:@"r"];
    if (rIdx == NSNotFound || rIdx + 1 >= parts.count) return NO;
    return [parts[rIdx + 1] caseInsensitiveCompare:@"all"] == NSOrderedSame;
}

// Sort segment following "all" in the path, e.g. "/r/all/top.json" -> "top";
// "/r/all" (no further segment -- Reddit's own default) -> "hot". Lowercased
// and ".json" stripped so it matches ApolloAPSortKey's exact-string checks.
static NSString *SortSegmentFromURL(NSURL *url) {
    NSArray<NSString *> *parts = url.pathComponents;
    NSUInteger rIdx = [parts indexOfObject:@"r"];
    if (rIdx == NSNotFound || rIdx + 2 >= parts.count) return @"hot";
    NSString *seg = parts[rIdx + 2];
    if ([seg.lowercaseString hasSuffix:@".json"]) {
        seg = [seg substringToIndex:seg.length - 5];
    }
    return seg.length ? seg.lowercaseString : @"hot";
}

// The sorts ApolloAPSortKey keys by hot rank -- the only ones the hot-ranked
// search candidates can be merged into honestly.
static BOOL IsHotKeyedSort(NSString *sort) {
    return [sort isEqualToString:@"hot"]
        || [sort isEqualToString:@"best"]
        || [sort isEqualToString:@"rising"];
}

static NSString *QueryItem(NSURL *url, NSString *name) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *q in c.queryItems) { if ([q.name isEqualToString:name]) return q.value; }
    return nil;
}

// The owner key for the active account: "<username>|oauth" or "<username>|web"
// (username empty when none is signed in / resolvable). `token` is what
// ApolloActiveAccountRedditBearerToken() returned for this merge.
static NSString *APOwnerKey(NSString *username, NSString *token) {
    return [NSString stringWithFormat:@"%@|%@", username ?: @"", token.length ? @"oauth" : @"web"];
}

// Site-wide nsfw:1 search sorted HOT — Reddit's own
// freshness-weighted ranking over all NSFW (incl. subs filtered from r/all).
// No t= param: time windows only apply to top-style sorts. With a bearer the
// read goes to oauth.reddit.com; without one (API-Key-Free account) it goes
// bearer-less to www.reddit.com, where the request chokepoint signs it with the
// active account's web session -- the same split ApolloGoogleSearch uses.
static NSString *NSFWSearchURL(NSString *token, NSString *after, NSInteger limit) {
    NSString *base = token.length ? @"https://oauth.reddit.com" : @"https://www.reddit.com";
    NSMutableString *u = [NSMutableString stringWithFormat:
        @"%@/search?q=nsfw%%3A1&include_over_18=on&sort=hot&limit=%ld&raw_json=1",
        base, (long)limit];
    if (after.length) { [u appendFormat:@"&after=%@", after]; }
    return u;
}

// GET one search page for the account that owns `token` (nil = API-Key-Free);
// `completion` gets the parsed JSON dict or nil. Returns the task so the owner
// can cancel it when it stops mattering.
static NSURLSessionDataTask *FetchListing(NSString *token, NSString *after, void (^completion)(NSDictionary *listing)) {
    NSURL *url = [NSURL URLWithString:NSFWSearchURL(token, after, kAPFetchLimit)];
    if (!url) { completion(nil); return nil; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;
    if (token.length) [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:(sUserAgent.length ? sUserAgent : @"ApolloReborn/AllPlus") forHTTPHeaderField:@"User-Agent"];
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, __unused NSURLResponse *resp, NSError *err) {
            id json = (!err && d) ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            ApolloLog(@"[AllPlus] NSFW search %@ in %.0fms", json ? @"arrived" : @"failed",
                      (CFAbsoluteTimeGetCurrent() - started) * 1000.0);
            completion([json isKindOfClass:[NSDictionary class]] ? json : nil);
        }];
    [task resume];
    return task;
}

static NSArray *RawChildren(NSDictionary *listing) {
    id d = [listing isKindOfClass:[NSDictionary class]] ? listing[@"data"] : nil;
    id ch = [d isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)d)[@"children"] : nil;
    return [ch isKindOfClass:[NSArray class]] ? ch : @[];
}

// Safe fullname read. The JSON `data` may be null (NSNull) or missing, so a
// malformed child is skipped, never crashed on -- [NSNull
// objectForKeyedSubscript:] is unrecognized.
static NSString *ChildName(id child) {
    if (![child isKindOfClass:[NSDictionary class]]) return nil;
    id d = ((NSDictionary *)child)[@"data"];
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    id nm = ((NSDictionary *)d)[@"name"];
    return [nm isKindOfClass:[NSString class]] ? nm : nil;
}

// A promoted post (ad) in the native listing. It must not set the admission
// floor (an ad's hot would raise the bar candidates have to clear), but
// placement still counts it -- an ad is a real slot on the page.
static BOOL IsPromoted(id child) {
    if (![child isKindOfClass:[NSDictionary class]]) return NO;
    id d = ((NSDictionary *)child)[@"data"];
    if (![d isKindOfClass:[NSDictionary class]]) return NO;
    id p = ((NSDictionary *)d)[@"promoted"];
    return [p respondsToSelector:@selector(boolValue)] && [p boolValue];
}

// Add a search page's unseen candidates to the buffer. On APQueue().
static NSUInteger APAppendCandidates(NSArray *children) {
    NSUInteger added = 0;
    for (NSDictionary *c in children) {
        NSString *nm = ChildName(c);
        if (nm.length && ![sAPSeen containsObject:nm]) {
            [sAPSeen addObject:nm];
            [sAPBuffer addObject:c];
            added++;
        }
    }
    return added;
}

// Stop caring about the in-flight search: bump the generation so its
// completion is dropped, cancel it, and free the refill slot so the next
// refill can start right away. On APQueue().
static void APDiscardInFlight(void) {
    sAPGeneration++;
    [sAPTask cancel];
    sAPTask = nil;
    sAPRefilling = NO;
}

// Top the buffer up toward kAPRefillTarget in the background, one search page
// at a time, for the current owner. On APQueue().
static void APRefillIfNeeded(NSString *token) {
    if (!sAllPlusNSFWEnabled) return;   // switched off while a page was in flight
    if (sAPRefilling || sAPExhausted || (NSInteger)sAPBuffer.count >= kAPRefillTarget) return;
    sAPRefilling = YES;
    NSUInteger generation = sAPGeneration;
    NSString *owner = sAPOwner;
    NSString *after = sAPNsfwAfter;
    sAPTask = FetchListing(token, after, ^(NSDictionary *src) {
        dispatch_async(APQueue(), ^{
            // Only the owner that asked, for the load that asked, while All+ is
            // still on, gets to publish -- anything else is dropped without
            // starting another search. A stale generation already had its
            // refill slot freed by APDiscardInFlight (and may be someone
            // else's slot by now), so only a current completion frees it.
            BOOL stale = generation != sAPGeneration || ![owner isEqualToString:sAPOwner];
            if (!stale) {
                sAPRefilling = NO;
                sAPTask = nil;
            }
            // The account can change before any r/all page adopts the new
            // owner: check the live one too, so the previous account's answer
            // never publishes or asks again with its token.
            BOOL switched = !stale && ![APOwnerKey(ApolloActiveAccountUsername(),
                                                   ApolloActiveAccountRedditBearerToken()) isEqualToString:owner];
            if (stale || switched || !sAllPlusNSFWEnabled) {
                ApolloLog(@"[AllPlus] NSFW search dropped: %@",
                          stale ? @"load or account replaced" : switched ? @"account switched" : @"All+ switched off");
                return;
            }
            NSArray *more = src ? RawChildren(src) : @[];
            id sd = src[@"data"];
            id na = [sd isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)sd)[@"after"] : nil;
            NSString *next = [na isKindOfClass:[NSString class]] ? na : nil;
            if (!src) return;   // failed: the next page asks again
            if (!after.length && more.count) {
                sAPFirstBatch = more;
                sAPFirstBatchAfter = next;
                sAPFirstBatchTime = CFAbsoluteTimeGetCurrent();
            }
            NSUInteger added = APAppendCandidates(more);
            sAPNsfwAfter = next;
            // Only already-seen posts (the search cycling) or no cursor: done
            // until the next fresh load.
            if (added == 0 || !next.length) sAPExhausted = YES;
            APRefillIfNeeded(token);
        });
    });
}

// Drop everything cached and in flight. On APQueue().
static void APDropAll(void) {
    APDiscardInFlight();
    sAPBuffer = [NSMutableArray array];
    sAPSeen = [NSMutableSet set];
    sAPNsfwAfter = nil;
    sAPExhausted = NO;
    sAPFirstBatch = nil;
    sAPFirstBatchAfter = nil;
    sAPFirstBatchTime = 0;
}

// Make `owner` the account the cached state belongs to. A change (account
// switch, sign-out, API key <-> API-Key-Free) drops the previous owner's
// candidates, cursor and first-batch cache along with its in-flight search.
// On APQueue().
static void APAdoptOwner(NSString *owner) {
    if ([owner isEqualToString:sAPOwner]) return;
    if (sAPOwner) ApolloLog(@"[AllPlus] account changed; dropping the previous account's candidates");
    APDropAll();
    sAPOwner = owner;
}

// Start a fresh load's buffer: from the recent first search page when there is
// one, else empty with a search on its way. On APQueue().
static void APResetForFreshLoad(NSString *token) {
    APDiscardInFlight();
    sAPBuffer = [NSMutableArray array];
    sAPSeen = [NSMutableSet set];
    sAPNsfwAfter = nil;
    sAPExhausted = NO;
    if (sAPFirstBatch && CFAbsoluteTimeGetCurrent() - sAPFirstBatchTime < kAPFirstBatchMaxAge) {
        APAppendCandidates(sAPFirstBatch);
        sAPNsfwAfter = sAPFirstBatchAfter;
        if (!sAPNsfwAfter.length) sAPExhausted = YES;
    }
    APRefillIfNeeded(token);
}

// Merge buffered candidates into one r/all page for `owner` (whose bearer is
// `token`, nil for API-Key-Free). Returns the merged children, or nil to leave
// the page stock. On APQueue().
static NSArray *APMergePage(NSArray *sfwChildren, NSURL *url, NSString *owner, NSString *token) {
    APAdoptOwner(owner);
    if (!QueryItem(url, @"after").length) APResetForFreshLoad(token);
    if (sAPBuffer.count == 0) {
        APRefillIfNeeded(token);   // e.g. the last search failed: ask again
        ApolloLog(@"[AllPlus] buffer empty; page left stock while the NSFW search runs");
        return nil;
    }

    // Only hot-keyed sorts reach here (ApolloAllPlusRewriteData filters), so
    // the boost -- a hot-rank addend -- always applies.
    NSString *sort = SortSegmentFromURL(url);
    double b = sAllPlusNSFWBoost;

    // Native keys (in DOM order, for placement) + the admission floor. The floor
    // is the weakest REAL native (score > 0): a score-0 native collapses to
    // hotRank 0 (sign(0) zeroes the time term) and would peg the floor at 0,
    // admitting everything. Placement still counts against ALL natives.
    NSMutableArray<NSNumber *> *nativeKeys = [NSMutableArray arrayWithCapacity:sfwChildren.count];
    double floorVal = INFINITY;
    for (NSDictionary *n in sfwChildren) {
        double k = ApolloAPSortKey(n, sort);
        [nativeKeys addObject:@(k)];
        if (ApolloAPNumFromData(n, @"score") > 0 && !IsPromoted(n) && k < floorVal) floorVal = k;
    }
    if (!isfinite(floorVal)) floorVal = -INFINITY;   // no real natives -> admit all

    // Eligible = buffered candidates whose boosted key clears the floor. NO cap:
    // the per-page count emerges from ranking. Sort hottest-first.
    NSMutableArray<NSDictionary *> *eligible = [NSMutableArray array];
    for (NSDictionary *c in sAPBuffer) {
        double raw = ApolloAPSortKey(c, sort);
        if (raw + b >= floorVal) [eligible addObject:@{@"child": c, @"raw": @(raw)}];
    }
    // Stable sort, so equal-raw candidates keep buffer order (plain
    // sortUsingComparator: is not guaranteed stable).
    [eligible sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        double rx = [x[@"raw"] doubleValue], ry = [y[@"raw"] doubleValue];
        return (ry > rx) ? NSOrderedDescending : (ry < rx ? NSOrderedAscending : NSOrderedSame);
    }];

    if (eligible.count == 0) {
        ApolloLog(@"[AllPlus] sort=%@ B=%.2f floor=%.3f buffered=%lu eligible=0 injected=0",
                  sort, b, floorVal, (unsigned long)sAPBuffer.count);
        APRefillIfNeeded(token);
        return nil;   // nothing ranks on this page yet; leave r/all stock
    }

    // Remove the chosen from the buffer; the rest stay for later, weaker pages.
    NSMutableSet<NSString *> *chosenNames = [NSMutableSet set];
    for (NSDictionary *e in eligible) {
        NSString *nm = ChildName(e[@"child"]);
        if (nm.length) [chosenNames addObject:nm];
    }
    NSMutableArray *newBuf = [NSMutableArray array];
    for (NSDictionary *c in sAPBuffer) {
        NSString *nm = ChildName(c);
        if (!(nm.length && [chosenNames containsObject:nm])) [newBuf addObject:c];
    }
    sAPBuffer = newBuf;

    // Placement: slot = # natives outranking the
    // candidate. slot 0 -> before native 0; slot k>0 -> chained after native
    // MIN(k, count)-1. `eligible` is hottest-first, so same-slot candidates chain
    // in hot order and the hottest lands highest.
    NSMutableArray *beforeFirst = [NSMutableArray array];
    NSMutableArray<NSMutableArray *> *afterNative = [NSMutableArray arrayWithCapacity:sfwChildren.count];
    for (NSUInteger i = 0; i < sfwChildren.count; i++) [afterNative addObject:[NSMutableArray array]];
    for (NSDictionary *e in eligible) {
        double raw = [e[@"raw"] doubleValue];
        NSUInteger slot = ApolloAPSlotFor(nativeKeys, raw, b);
        if (slot == 0) {
            [beforeFirst addObject:e[@"child"]];
        } else {
            NSUInteger anchorIdx = MIN(slot, sfwChildren.count) - 1;
            [afterNative[anchorIdx] addObject:e[@"child"]];
        }
    }

    NSMutableArray *emit = [NSMutableArray arrayWithCapacity:sfwChildren.count + eligible.count];
    [emit addObjectsFromArray:beforeFirst];
    for (NSUInteger i = 0; i < sfwChildren.count; i++) {
        [emit addObject:sfwChildren[i]];
        [emit addObjectsFromArray:afterNative[i]];
    }

    NSUInteger injected = eligible.count;
    double density = (sfwChildren.count + injected) > 0
        ? (double)injected / (double)(sfwChildren.count + injected) : 0.0;
    ApolloLog(@"[AllPlus] sort=%@ B=%.2f floor=%.3f buffered=%lu eligible=%lu injected=%lu density=%.3f",
              sort, b, floorVal, (unsigned long)(sAPBuffer.count + injected),
              (unsigned long)eligible.count, (unsigned long)injected, density);
    APRefillIfNeeded(token);   // drained below the target: top it up for later pages
    return emit;
}

NSData *ApolloAllPlusRewriteData(NSURLResponse *response, NSData *data) {
    if (!sAllPlusNSFWEnabled) return nil;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return nil;
    if (![data isKindOfClass:[NSData class]] || data.length == 0) return nil;
    NSURL *url = response.URL;
    if (!IsRAllPath(url)) return nil; // r/all only
    // Hot-keyed sorts only: Top/New/Controversial (any t=) are left stock and
    // don't touch the buffer or cursor.
    if (!IsHotKeyedSort(SortSegmentFromURL(url))) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *listing = json;
    id dataDict = listing[@"data"];
    if (![dataDict isKindOfClass:[NSDictionary class]]) return nil;
    id sfwObj = ((NSDictionary *)dataDict)[@"children"];
    if (![sfwObj isKindOfClass:[NSArray class]] || [sfwObj count] == 0) return nil;
    NSArray *sfwChildren = sfwObj;

    // Resolve the owner off the serial queue: the username lookup may decode
    // the account archive, and the token tells which host/auth the search uses.
    NSString *token = ApolloActiveAccountRedditBearerToken();
    NSString *owner = APOwnerKey(ApolloActiveAccountUsername(), token);

    __block NSArray *emit = nil;
    dispatch_sync(APQueue(), ^{ emit = APMergePage(sfwChildren, url, owner, token); });
    if (!emit) return nil;

    NSMutableDictionary *outData = [dataDict mutableCopy];
    outData[@"children"] = emit;   // keep dataDict's REAL `after` -> native r/all pagination
    NSMutableDictionary *outListing = [listing mutableCopy];
    outListing[@"data"] = outData;

    NSData *result = [NSJSONSerialization dataWithJSONObject:outListing options:0 error:nil];
    if (!result) return nil;
    return result;
}

void ApolloAllPlusInvalidate(void) {
    dispatch_async(APQueue(), ^{
        APDropAll();
        sAPOwner = nil;   // the next merge adopts whoever is active then
    });
}
