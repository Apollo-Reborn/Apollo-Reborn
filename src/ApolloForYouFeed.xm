// ApolloForYouFeed.xm — Reddit's personalized "For You" feed on Home.
//
// Picked from Home's "Sort by..." menu (a "For You" row above Best/Hot/...);
// any native sort turns it off again. The choice persists (UDKeyHomeFeedForYou),
// like Reddit's own app remembering the last feed. Home's sort button shows a
// sparkles icon while it's on.
//
// ============================== Where it hooks ===============================
// Home's listings go -[RDKClient frontPageLinksWithCategory:pagination:completion:]
// -> listingTaskWithPath:@"<sort>.json" -> fullListingWithPath:parameters:
// pagination:completion:, whose completion receives the raw listing JSON
// (id response, NSError *error). RDKClient's own block then parses it with
// objectsFromListingResponse: + RDKPagination paginationFromListingResponse:
// on a global queue and calls Apollo on main (Hopper: sub_100007cdc /
// sub_100007de8). So this module answers fullListingWithPath: for Home's root
// paths itself, handing back an ordinary listing dictionary: every hook above
// it (ListEmptyState's first-page bookkeeping, filters, avatars, Apollo's own
// handleNewLinks) runs unchanged, and posts render exactly like Home's.
//
// =========================== Where the posts come from ======================
// See ApolloForYouFeedModel.h for the endpoint. Two budgets matter:
//   * The For You HTML fragment counts against the session's WEBSITE budget
//     (x-ratelimit-*, 2000 per 10 minutes). Used only for post IDs.
//   * Full post data comes from /api/info (RDKClient's own thingsByFullNames:
//     path, already routed for API-Key-Free accounts by ApolloWebJSONRoutes),
//     in batches of up to 100 IDs. That's the scarce budget API-key-free
//     accounts hit 429s on: Home spends 1 request per 12 posts there; this
//     spends about 1 per 75-100 once the buffer is warm.
//
// ================================ Rate safety ===============================
//   * Nothing runs in the background except a bounded HTML read-ahead (at most
//     kApolloFYReadAheadIDs post IDs pending, one request in flight), and only
//     while the website budget reports plenty left and no 429 is in force.
//   * Reopening Home within kApolloFYSessionReuseSeconds replays the feed from
//     memory — no requests. Pull to refresh (refreshControlActivatedWithSender:)
//     starts a new one.
//   * Every network step is single-flight per session; concurrent page asks
//     queue behind it. A failed step is remembered for kApolloFYFailureHoldSeconds,
//     so ASDK's batch fetching can't turn one failure into a retry storm.
//   * A 429 on the HTML stops all For You HTML reads until x-ratelimit-reset.
//
// Signed-out accounts, and accounts with no Reddit web session, keep the
// normal Home feed. Choosing For You on an OAuth account without a web session
// runs the same targeted web sign-in Polls use
// (+[ApolloWebSessionLoginViewController loginControllerForUsername:completion:]).

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloAccountCredentials.h"
#import "ApolloActionMenu.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloForYouFeedModel.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"
#import "UserDefaultConstants.h"

@interface RDKPagination : NSObject
@property (nonatomic) unsigned long long limit;
@property (copy, nonatomic) NSString *after;
@end

@interface RDKClient : NSObject
- (id)fullListingWithPath:(id)path parameters:(id)parameters pagination:(id)pagination completion:(id)completion;
@end

@interface UIAction (ApolloForYouPrivate)
- (void (^)(UIAction *))handler;
- (void)setHandler:(void (^)(UIAction *))handler;
@end

// Defined in ApolloSubredditHeaders.xm: the raw PostsType case tag, -1 if unreadable.
extern NSInteger ApolloPostsTypeTagFromViewController(UIViewController *viewController);

typedef void (^ApolloFYRawCompletion)(id response, NSError *error);
typedef void (^ApolloFYPageCompletion)(NSDictionary *listing, NSError *error);

static NSString *const kApolloFYFeed = @"for-you";
static NSString *const kApolloFYTitle = @"For You";
static NSString *const kApolloFYSymbol = @"sparkles";
static NSString *const kApolloFYErrorDomain = @"ApolloForYouFeed";

static const NSUInteger kApolloFYPageSize = 25;           // posts per page handed to Apollo
static const NSUInteger kApolloFYHydrateBatch = 100;      // /api/info's own maximum
static const NSUInteger kApolloFYReadAheadIDs = 75;       // pending IDs to read ahead to once paging
static const NSUInteger kApolloFYFirstReadAheadIDs = 25;  // ...and before the user has paged at all
static const NSUInteger kApolloFYMaxItems = 1000;         // session cap (memory)
static const NSUInteger kApolloFYMaxEmptyPages = 3;       // HTML pages of only repeats before giving up
static const double kApolloFYReadAheadMinRemaining = 200; // website budget floor for read-ahead
static const CFTimeInterval kApolloFYSessionReuseSeconds = 10 * 60;
static const CFTimeInterval kApolloFYFailureHoldSeconds = 8;
static const CFTimeInterval kApolloFYRefreshArmSeconds = 5;
static const CFTimeInterval kApolloFYSortArmGraceSeconds = 1.5;

static NSString *const kApolloFYDesktopUA =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

static BOOL ApolloForYouFeedEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:UDKeyHomeFeedForYou];
}

#pragma mark - Session

// One For You feed as fetched for one account. Mutated only on sApolloFYQueue.
@interface ApolloFYSession : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *username;     // lowercased
@property (nonatomic, copy) NSString *cookieHeader;
@property (nonatomic) CFAbsoluteTime createdAt;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *items;   // hydrated t3 children, feed order
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingIDs;  // parsed from HTML, not hydrated yet
@property (nonatomic, strong) NSMutableSet<NSString *> *seenIDs;
@property (nonatomic, copy) NSString *lastFullname;  // last post ID read from HTML: the next page's cursor
@property (nonatomic) BOOL htmlStarted;
@property (nonatomic) BOOL htmlExhausted;
@property (nonatomic) NSUInteger emptyPagesInARow;
@property (nonatomic) BOOL busy;                     // a network step is in flight
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *waiting;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic) CFAbsoluteTime lastErrorAt;
@property (nonatomic) NSUInteger furthestIndex;     // furthest page index Apollo has asked for
@property (nonatomic) NSUInteger htmlRequests;
@property (nonatomic) NSUInteger hydrateRequests;
@end

@implementation ApolloFYSession
@end

static dispatch_queue_t sApolloFYQueue;
// Guarded by sApolloFYQueue.
static NSMutableDictionary<NSString *, ApolloFYSession *> *sApolloFYSessions; // by identifier (current + previous)
static ApolloFYSession *sApolloFYCurrent;
static CFAbsoluteTime sApolloFYHTMLBlockedUntil;
static double sApolloFYLastRemaining = -1;
static NSMutableSet<NSString *> *sApolloFYSignedOutUsers;

// Main thread only.
static CFAbsoluteTime sApolloFYRefreshArmedAt;
static BOOL sApolloFYSuppressRefreshArm;
static __weak UIViewController *sApolloFYSortArmedVC;
static CFAbsoluteTime sApolloFYSortArmedAt;
static NSHashTable<UIViewController *> *sApolloFYHomeControllers;

static NSError *ApolloFYError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kApolloFYErrorDomain code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static NSURLSession *ApolloFYHTMLSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Cookie-jar free, like Badge Book's direct fetch: the account's cookies
        // ride along per request and nothing Reddit sets is ever stored.
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPCookieStorage = nil;
        config.HTTPShouldSetCookies = NO;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = 15.0;
        config.timeoutIntervalForResource = 30.0;
        config.HTTPAdditionalHeaders = @{ @"Accept-Language": @"en-US,en;q=0.9" };
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

// RDKClient's callers keep the returned task (and may cancel it). Answers that
// don't touch the network hand back a task that is never resumed.
static NSURLSessionDataTask *ApolloFYPlaceholderTask(void) {
    return [ApolloFYHTMLSession() dataTaskWithURL:[NSURL URLWithString:@"https://www.reddit.com/"]];
}

#pragma mark - Network steps

// GET one For You HTML page. completion on sApolloFYQueue.
static void ApolloFYFetchHTML(ApolloFYSession *session, void (^completion)(NSError *error)) {
    NSURL *url = ApolloForYouFeedPageURL(kApolloFYFeed, session.htmlStarted ? session.lastFullname : nil);
    // The probe fragment (never sent) tells the Web JSON transport hooks this
    // request authenticates itself: leave it alone.
    url = ApolloWebJSONProbeURL(url) ?: url;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:kApolloFYDesktopUA forHTTPHeaderField:@"User-Agent"];
    [request setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
    session.htmlRequests++;
    NSUInteger requestNumber = session.htmlRequests;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();

    NSURLSessionDataTask *task = [ApolloFYHTMLSession() dataTaskWithRequest:request
                                                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = http.statusCode;
        double remaining = ApolloForYouFeedRateLimitRemaining(http.allHeaderFields);
        double reset = ApolloForYouFeedRateLimitReset(http.allHeaderFields);
        // Parse here, off the main thread and off the state queue: the page is
        // ~700 KB and only the IDs are kept.
        NSString *html = (status == 200 && data.length) ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSArray<NSString *> *ids = ApolloForYouFeedParsePostIDs(html);
        BOOL hasNext = ApolloForYouFeedHTMLHasNextPage(html);
        BOOL signedIn = ApolloForYouFeedHTMLIsSignedIn(html);
        double elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;

        dispatch_async(sApolloFYQueue, ^{
            if (remaining >= 0) sApolloFYLastRemaining = remaining;
            ApolloLog(@"[ForYou] html #%lu status=%ld bytes=%lu ids=%lu next=%d signedIn=%d remaining=%.0f reset=%.0f %.0fms err=%ld",
                      (unsigned long)requestNumber, (long)status, (unsigned long)data.length, (unsigned long)ids.count,
                      hasNext, signedIn, remaining, reset, elapsed, (long)error.code);
            if (error) {
                completion(ApolloFYError(1, @"Couldn't load For You. Check your connection and pull to refresh."));
                return;
            }
            if (status == 429) {
                CFTimeInterval wait = reset > 0 ? reset : 60;
                sApolloFYHTMLBlockedUntil = CFAbsoluteTimeGetCurrent() + wait;
                completion(ApolloFYError(2, [NSString stringWithFormat:
                    @"Reddit is limiting requests. For You will load again in about %.0f minute%@.",
                    ceil(wait / 60.0), wait > 60 ? @"s" : @""]));
                return;
            }
            if (status != 200 || !html) {
                completion(ApolloFYError(3, [NSString stringWithFormat:@"Reddit couldn't load For You (HTTP %ld).", (long)status]));
                return;
            }
            if (!signedIn) {
                [sApolloFYSignedOutUsers addObject:session.username];
                completion(ApolloFYError(4, @"Your Reddit web sign-in has expired. Choose For You from the sort menu to sign in again."));
                return;
            }

            session.htmlStarted = YES;
            NSUInteger added = 0;
            for (NSString *fullname in ids) {
                if ([session.seenIDs containsObject:fullname]) continue;
                [session.seenIDs addObject:fullname];
                [session.pendingIDs addObject:fullname];
                added++;
            }
            if (ids.count > 0) session.lastFullname = ids.lastObject;
            session.emptyPagesInARow = added > 0 ? 0 : session.emptyPagesInARow + 1;
            if (!hasNext || ids.count == 0 || session.emptyPagesInARow >= kApolloFYMaxEmptyPages ||
                session.seenIDs.count >= kApolloFYMaxItems) {
                session.htmlExhausted = YES;
                ApolloLog(@"[ForYou] feed exhausted after %lu posts", (unsigned long)session.seenIDs.count);
            }
            completion(nil);
        });
    }];
    [task resume];
}

// Hydrate up to kApolloFYHydrateBatch pending IDs through Apollo's own
// /api/info request. completion on sApolloFYQueue.
static void ApolloFYHydrate(ApolloFYSession *session, RDKClient *client, void (^completion)(NSError *error)) {
    NSUInteger count = MIN(kApolloFYHydrateBatch, session.pendingIDs.count);
    NSArray<NSString *> *batch = [session.pendingIDs subarrayWithRange:NSMakeRange(0, count)];
    session.hydrateRequests++;
    NSUInteger requestNumber = session.hydrateRequests;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();

    ApolloFYRawCompletion done = ^(id response, NSError *error) {
        NSArray<NSDictionary *> *children = error ? @[] : ApolloForYouFeedOrderedChildren(response, batch);
        dispatch_async(sApolloFYQueue, ^{
            ApolloLog(@"[ForYou] hydrate #%lu asked=%lu got=%lu %.0fms err=%@",
                      (unsigned long)requestNumber, (unsigned long)batch.count, (unsigned long)children.count,
                      (CFAbsoluteTimeGetCurrent() - started) * 1000.0, error.localizedDescription ?: @"-");
            if (error) {
                completion(error);
                return;
            }
            [session.pendingIDs removeObjectsInRange:NSMakeRange(0, count)];
            [session.items addObjectsFromArray:children];
            completion(nil);
        });
    };
    // Through RDKClient (and back into this hook, which passes api/info
    // straight to the original), so auth, API-Key-Free routing and the
    // response serializer's repairs all apply.
    dispatch_async(dispatch_get_main_queue(), ^{
        ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(client, @selector(fullListingWithPath:parameters:pagination:completion:),
            @"api/info.json", @{ @"id": [batch componentsJoinedByString:@","] }, nil, done);
    });
}

#pragma mark - Paging

static BOOL ApolloFYHTMLBlocked(void) {
    return CFAbsoluteTimeGetCurrent() < sApolloFYHTMLBlockedUntil;
}

static void ApolloFYRunWaiting(ApolloFYSession *session) {
    NSArray<dispatch_block_t> *waiting = [session.waiting copy];
    [session.waiting removeAllObjects];
    for (dispatch_block_t block in waiting) block();
}

// Bounded HTML read-ahead after a page is delivered, so the next page needs
// one hydrate call and no HTML wait. Website budget only.
static void ApolloFYMaybeReadAhead(ApolloFYSession *session) {
    if (session.busy || session.htmlExhausted || ApolloFYHTMLBlocked()) return;
    // Read one page ahead until the user actually pages, then keep a full
    // hydrate batch's worth ready.
    NSUInteger target = session.furthestIndex > 0 ? kApolloFYReadAheadIDs : kApolloFYFirstReadAheadIDs;
    if (session.pendingIDs.count >= target) return;
    if (sApolloFYLastRemaining >= 0 && sApolloFYLastRemaining < kApolloFYReadAheadMinRemaining) return;
    if (session.lastError && CFAbsoluteTimeGetCurrent() - session.lastErrorAt < kApolloFYFailureHoldSeconds) return;
    if (session != sApolloFYCurrent) return;
    session.busy = YES;
    ApolloFYFetchHTML(session, ^(NSError *error) {
        session.busy = NO;
        if (error) {
            session.lastError = error;
            session.lastErrorAt = CFAbsoluteTimeGetCurrent();
        }
        ApolloFYRunWaiting(session);
        // Keep reading until the buffer holds kApolloFYReadAheadIDs, so the next
        // hydrate is one large batch rather than one per page. Each step
        // re-checks every guard above (error hold, budget, 429, exhaustion).
        if (!error) ApolloFYMaybeReadAhead(session);
    });
}

// Serve items [index, index + pageSize) of `session`, fetching only what's
// missing. Runs on sApolloFYQueue; `completion` is called exactly once.
static void ApolloFYServe(ApolloFYSession *session, RDKClient *client, NSUInteger index, ApolloFYPageCompletion completion) {
    if (session.busy) {
        // The session owns its waiting list, so the waiter holds it weakly. The
        // in-flight step keeps it alive until the list is drained.
        __weak ApolloFYSession *weakSession = session;
        [session.waiting addObject:^{
            ApolloFYSession *strongSession = weakSession;
            if (strongSession) {
                ApolloFYServe(strongSession, client, index, completion);
            } else {
                completion(ApolloForYouFeedListing(@[], nil), nil);
            }
        }];
        return;
    }

    session.furthestIndex = MAX(session.furthestIndex, index);
    NSUInteger available = session.items.count > index ? session.items.count - index : 0;
    BOOL canGrow = session.pendingIDs.count > 0 || !session.htmlExhausted;
    if (available >= kApolloFYPageSize || !canGrow) {
        NSUInteger count = MIN(available, kApolloFYPageSize);
        NSArray *page = count ? [session.items subarrayWithRange:NSMakeRange(index, count)] : @[];
        NSUInteger next = index + count;
        BOOL more = session.items.count > next || canGrow;
        NSString *after = more && count > 0 ? ApolloForYouFeedToken(session.identifier, next) : nil;
        ApolloLog(@"[ForYou] serve index=%lu count=%lu more=%d (items=%lu pending=%lu html=%lu hydrate=%lu)",
                  (unsigned long)index, (unsigned long)count, more, (unsigned long)session.items.count,
                  (unsigned long)session.pendingIDs.count, (unsigned long)session.htmlRequests,
                  (unsigned long)session.hydrateRequests);
        completion(ApolloForYouFeedListing(page, after), nil);
        ApolloFYMaybeReadAhead(session);
        return;
    }

    // Something has to be fetched. Answer a recent failure without asking again.
    if (session.lastError && CFAbsoluteTimeGetCurrent() - session.lastErrorAt < kApolloFYFailureHoldSeconds) {
        completion(nil, session.lastError);
        return;
    }

    NSUInteger needed = kApolloFYPageSize - available;
    BOOL hydrateNow = session.pendingIDs.count >= needed || session.htmlExhausted ||
                      session.pendingIDs.count >= kApolloFYHydrateBatch;
    if (!hydrateNow && ApolloFYHTMLBlocked()) {
        // No more IDs can be read for now; use what's pending rather than nothing.
        hydrateNow = session.pendingIDs.count > 0;
        if (!hydrateNow) {
            completion(nil, ApolloFYError(2, @"Reddit is limiting requests. Try For You again in a few minutes."));
            return;
        }
    }

    session.busy = YES;
    void (^stepDone)(NSError *) = ^(NSError *error) {
        session.busy = NO;
        if (error) {
            session.lastError = error;
            session.lastErrorAt = CFAbsoluteTimeGetCurrent();
            completion(nil, error);
            ApolloFYRunWaiting(session);
            return;
        }
        session.lastError = nil;
        ApolloFYServe(session, client, index, completion);
        ApolloFYRunWaiting(session);
    };
    if (hydrateNow) {
        ApolloFYHydrate(session, client, stepDone);
    } else {
        ApolloFYFetchHTML(session, stepDone);
    }
}

static ApolloFYSession *ApolloFYNewSession(NSString *username, NSString *cookieHeader) {
    ApolloFYSession *session = [ApolloFYSession new];
    session.identifier = [[NSUUID UUID].UUIDString substringToIndex:8];
    session.username = username;
    session.cookieHeader = cookieHeader;
    session.createdAt = CFAbsoluteTimeGetCurrent();
    session.items = [NSMutableArray array];
    session.pendingIDs = [NSMutableArray array];
    session.seenIDs = [NSMutableSet set];
    session.waiting = [NSMutableArray array];
    // Keep the outgoing session for its in-flight pages; drop anything older.
    NSMutableDictionary *kept = [NSMutableDictionary dictionary];
    if (sApolloFYCurrent) kept[sApolloFYCurrent.identifier] = sApolloFYCurrent;
    kept[session.identifier] = session;
    sApolloFYSessions = kept;
    sApolloFYCurrent = session;
    return session;
}

#pragma mark - Sort button

static UIViewController *ApolloFYHomeOwner(UIViewController *vc) {
    Class postsClass = ApolloClassPostsViewController;
    if (!postsClass || ![vc isKindOfClass:postsClass]) return nil;
    // Home's PostsType tag is 6 (ApolloGalleryMenu.xm measured it); the nav
    // title is the second lock, as there.
    if (ApolloPostsTypeTagFromViewController(vc) != 6) return nil;
    NSString *title = vc.navigationItem.title ?: vc.title;
    return [title isEqualToString:@"Home"] ? vc : nil;
}

static char kApolloFYOriginalSortImageKey;
static char kApolloFYOurSortImageKey;

// Swap Home's sort button to the sparkles glyph while For You is on, and back.
static void ApolloFYApplySortButton(UIViewController *vc) {
    if (!ApolloFYHomeOwner(vc)) return;
    // Home's title can arrive after its first viewWillAppear, so every Home
    // entry point registers it here.
    [sApolloFYHomeControllers addObject:vc];
    UIButton *button = ApolloObjectIvar(vc, "sortButton");
    if (![button isKindOfClass:[UIButton class]]) {
        ApolloLog(@"[ForYou] sortButton ivar unreadable (%@)", button ? NSStringFromClass([button class]) : @"nil");
        return;
    }
    UIImage *current = [button imageForState:UIControlStateNormal];
    UIImage *ours = objc_getAssociatedObject(button, &kApolloFYOurSortImageKey);
    if (ApolloForYouFeedEnabled()) {
        if (ours && current == ours) return;
        UIImage *sparkles = ApolloActionMenuSymbolIcon(kApolloFYSymbol) ?: [UIImage systemImageNamed:kApolloFYSymbol];
        if (!sparkles) return;
        objc_setAssociatedObject(button, &kApolloFYOriginalSortImageKey, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, &kApolloFYOurSortImageKey, sparkles, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button setImage:sparkles forState:UIControlStateNormal];
        button.accessibilityLabel = @"Sort: For You";
        ApolloLog(@"[ForYou] sort button shows For You");
    } else if (ours) {
        // Only restore when the glyph is still ours: a native sort pick has
        // already set its own icon, which must win.
        if (current == ours) {
            [button setImage:objc_getAssociatedObject(button, &kApolloFYOriginalSortImageKey) forState:UIControlStateNormal];
        }
        button.accessibilityLabel = nil;
        objc_setAssociatedObject(button, &kApolloFYOriginalSortImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(button, &kApolloFYOurSortImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloFYApplySortButtons(void) {
    for (UIViewController *vc in sApolloFYHomeControllers.allObjects) ApolloFYApplySortButton(vc);
}

#pragma mark - Turning it on and off

static void ApolloFYSetEnabled(BOOL enabled) {
    if (ApolloForYouFeedEnabled() == enabled) return;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:UDKeyHomeFeedForYou];
    ApolloLog(@"[ForYou] %@", enabled ? @"enabled" : @"disabled");
    ApolloFYApplySortButtons();
}

static void ApolloFYReload(UIViewController *owner) {
    if (![owner respondsToSelector:@selector(refreshControlActivatedWithSender:)]) return;
    // A mode switch may replay a fresh cached feed; only a real pull to
    // refresh forces a new one.
    sApolloFYSuppressRefreshArm = YES;
    ((void (*)(id, SEL, id))objc_msgSend)(owner, @selector(refreshControlActivatedWithSender:), nil);
    sApolloFYSuppressRefreshArm = NO;
}

static void ApolloFYShowAlert(UIViewController *presenter, NSString *message) {
    if (!presenter.view.window) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:kApolloFYTitle
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void ApolloFYActivate(UIViewController *owner) {
    if (!owner) return;
    NSString *username = ApolloActiveAccountUsername();
    if (username.length == 0) {
        ApolloFYShowAlert(owner, @"Sign in to a Reddit account to see posts picked for you.");
        return;
    }
    __block BOOL signedOut = NO;
    dispatch_sync(sApolloFYQueue, ^{ signedOut = [sApolloFYSignedOutUsers containsObject:username.lowercaseString]; });
    if (ApolloWebSessionPollFor(username) && !signedOut) {
        ApolloFYSetEnabled(YES);
        ApolloFYReload(owner);
        return;
    }

    // For You is a reddit.com feed: it needs a web session matching this
    // account. OAuth accounts get one the same way Polls do (stored as an
    // auxiliary session that never changes the account's API transport).
    ApolloLog(@"[ForYou] no usable web session for this account; presenting web sign-in");
    __weak UIViewController *weakOwner = owner;
    ApolloWebSessionLoginViewController *login = [ApolloWebSessionLoginViewController
        loginControllerForUsername:username completion:^(BOOL success) {
            UIViewController *strongOwner = weakOwner;
            if (!success || !strongOwner) return;
            dispatch_sync(sApolloFYQueue, ^{
                [sApolloFYSignedOutUsers removeObject:username.lowercaseString];
                if ([sApolloFYCurrent.username isEqualToString:username.lowercaseString]) sApolloFYCurrent = nil;
            });
            ApolloFYSetEnabled(YES);
            ApolloFYReload(strongOwner);
        }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
    [owner presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Sort menu row

// The Home controller whose sort button was just tapped, claimed once by the
// sheet it builds. Same arm-and-claim as ApolloGalleryMenu.xm.
static char kApolloFYSortOwnerKey;

static UIViewController *ApolloFYSortOwnerForController(id actionController) {
    if (!actionController) return nil;
    NSHashTable *holder = objc_getAssociatedObject(actionController, &kApolloFYSortOwnerKey);
    if (holder) return holder.anyObject;
    UIViewController *armed = sApolloFYSortArmedVC;
    if (!armed || CACurrentMediaTime() - sApolloFYSortArmedAt > kApolloFYSortArmGraceSeconds) return nil;
    holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:armed];
    objc_setAssociatedObject(actionController, &kApolloFYSortOwnerKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sApolloFYSortArmedVC = nil;
    return armed;
}

static BOOL ApolloFYIsSortSheetTitle(NSString *title) {
    // "Sort by…" — not its "Sort by Top for…" follow-up sheets.
    return [title hasPrefix:@"Sort by"] && [title rangeOfString:@" for"].location == NSNotFound;
}

static void ApolloFYPerformFromMenu(id actionController) {
    UIViewController *owner = ApolloFYSortOwnerForController(actionController);
    if (!owner) return;
    if (ApolloForYouFeedEnabled()) return; // already showing For You
    dispatch_block_t activate = ^{ ApolloFYActivate(owner); };
    if (!ApolloNativeActionMenuPerformAfterDismissal(actionController, activate)) activate();
}

// Native sort rows turn For You off before Apollo applies their sort (which
// reloads Home itself). UIAction's handler is a private read/write property.
static void ApolloFYWrapNativeSortActions(NSArray<UIMenuElement *> *elements) {
    for (UIMenuElement *element in elements) {
        if ([element isKindOfClass:[UIMenu class]]) {
            ApolloFYWrapNativeSortActions(((UIMenu *)element).children);
            continue;
        }
        if (![element isKindOfClass:[UIAction class]]) continue;
        UIAction *action = (UIAction *)element;
        if (![action respondsToSelector:@selector(handler)] || ![action respondsToSelector:@selector(setHandler:)]) continue;
        void (^original)(UIAction *) = [action handler];
        if (!original) continue;
        [action setHandler:^(UIAction *sender) {
            ApolloFYSetEnabled(NO);
            original(sender);
        }];
    }
}

#pragma mark - Hooks

%hook RDKClient

- (id)fullListingWithPath:(id)path parameters:(id)parameters pagination:(RDKPagination *)pagination completion:(ApolloFYRawCompletion)completion {
    if (!completion || !ApolloForYouFeedIsHomeListingPath(path)) return %orig;

    NSString *after = [pagination respondsToSelector:@selector(after)] ? pagination.after : nil;
    NSString *tokenSession = nil;
    NSUInteger tokenIndex = 0;
    BOOL isTokenPage = ApolloForYouFeedParseToken(after, &tokenSession, &tokenIndex);
    BOOL isFirstPage = after.length == 0;
    // Pages of a For You feed already on screen keep coming from it even if the
    // mode was switched off mid-scroll; Home's own pages pass through.
    if (!isTokenPage && !(isFirstPage && ApolloForYouFeedEnabled())) return %orig;

    NSString *username = ApolloActiveAccountUsername().lowercaseString;
    ApolloWebSessionEntry *webSession = username.length ? ApolloWebSessionPollFor(username) : nil;
    if (isFirstPage && webSession.cookieHeader.length == 0) {
        // Signed out, or the web session is gone: Home as usual.
        ApolloLog(@"[ForYou] no web session for the active account; showing Home");
        return %orig;
    }

    BOOL forceNew = isFirstPage && CFAbsoluteTimeGetCurrent() - sApolloFYRefreshArmedAt < kApolloFYRefreshArmSeconds;
    if (forceNew) sApolloFYRefreshArmedAt = 0;
    RDKClient *client = (RDKClient *)self;
    ApolloFYPageCompletion deliver = ^(NSDictionary *listing, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(listing, error);
            ApolloFYApplySortButtons();
        });
    };

    dispatch_async(sApolloFYQueue, ^{
        ApolloFYSession *session = nil;
        NSUInteger index = 0;
        if (isTokenPage) {
            session = sApolloFYSessions[tokenSession];
            index = tokenIndex;
            if (!session) {
                // A page of a feed that has since been replaced: end it there.
                ApolloLog(@"[ForYou] page for a replaced feed %@; ending it", tokenSession);
                deliver(ApolloForYouFeedListing(@[], nil), nil);
                return;
            }
        } else {
            ApolloFYSession *current = sApolloFYCurrent;
            BOOL reusable = current && !forceNew && [current.username isEqualToString:username] &&
                            CFAbsoluteTimeGetCurrent() - current.createdAt < kApolloFYSessionReuseSeconds &&
                            current.items.count > 0;
            if (reusable) {
                session = current;
                ApolloLog(@"[ForYou] replaying feed %@ (%lu posts, %.0fs old)", current.identifier,
                          (unsigned long)current.items.count, CFAbsoluteTimeGetCurrent() - current.createdAt);
            } else {
                session = ApolloFYNewSession(username, webSession.cookieHeader);
                ApolloLog(@"[ForYou] new feed %@ (refresh=%d)", session.identifier, forceNew);
            }
        }
        ApolloFYServe(session, client, index, deliver);
    });
    return ApolloFYPlaceholderTask();
}

%end

%hook _TtC6Apollo19PostsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIViewController *vc = (UIViewController *)self;
    if (!ApolloFYHomeOwner(vc)) return;
    [sApolloFYHomeControllers addObject:vc];
    ApolloFYApplySortButton(vc);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Apollo can set the sort glyph again while the view settles.
    ApolloFYApplySortButton((UIViewController *)self);
}

- (void)sortBarButtonItemTappedWithSender:(id)sender {
    UIViewController *vc = (UIViewController *)self;
    if (ApolloFYHomeOwner(vc)) {
        [sApolloFYHomeControllers addObject:vc];
        sApolloFYSortArmedVC = vc;
        sApolloFYSortArmedAt = CACurrentMediaTime();
    } else {
        sApolloFYSortArmedVC = nil;
    }
    %orig;
}

- (void)refreshControlActivatedWithSender:(id)sender {
    if (!sApolloFYSuppressRefreshArm && ApolloFYHomeOwner((UIViewController *)self)) {
        sApolloFYRefreshArmedAt = CFAbsoluteTimeGetCurrent();
    }
    %orig;
}

%end

%ctor {
    sApolloFYQueue = dispatch_queue_create("com.apolloreborn.foryou", DISPATCH_QUEUE_SERIAL);
    sApolloFYSessions = [NSMutableDictionary dictionary];
    sApolloFYSignedOutUsers = [NSMutableSet set];
    sApolloFYHomeControllers = [NSHashTable weakObjectsHashTable];
    %init;

    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"ForYouFeed";
    spec.placement = ApolloActionMenuPlacementAfterLeadingSubmitAffordance;
    spec.inlineSection = YES;
    spec.legacyDismissesSheet = YES;
    spec.matches = ^BOOL(id actionController, NSString *menuTitle) {
        if (!ApolloFYIsSortSheetTitle(menuTitle)) return NO;
        return ApolloFYSortOwnerForController(actionController) != nil;
    };
    spec.title = ^NSString *(id actionController, UITableViewCell *donor) {
        (void)actionController; (void)donor;
        return kApolloFYTitle;
    };
    spec.image = ^UIImage *(id actionController, UITableViewCell *donor) {
        (void)actionController; (void)donor;
        return ApolloActionMenuSymbolIcon(kApolloFYSymbol) ?: [UIImage systemImageNamed:kApolloFYSymbol];
    };
    spec.checked = ^BOOL(id actionController) {
        (void)actionController;
        return ApolloForYouFeedEnabled();
    };
    spec.perform = ^(id actionController) {
        ApolloFYPerformFromMenu(actionController);
    };
    // Glass menu: For You leads the sort list in its own group, checked while
    // it's the active feed, and every native sort row switches it off first.
    spec.buildElement = ^(id actionController, NSMutableArray<UIMenuElement *> *children) {
        if (!ApolloFYSortOwnerForController(actionController)) return;
        ApolloFYWrapNativeSortActions(children);
        __weak id weakController = actionController;
        UIImage *icon = ApolloActionMenuSymbolIcon(kApolloFYSymbol) ?: [UIImage systemImageNamed:kApolloFYSymbol];
        UIAction *forYou = [UIAction actionWithTitle:kApolloFYTitle
                                               image:icon
                                          identifier:nil
                                             handler:^(__unused __kindof UIAction *sender) {
            ApolloFYPerformFromMenu(weakController);
        }];
        if (@available(iOS 15.0, *)) forYou.subtitle = @"Picked by Reddit";
        forYou.state = ApolloForYouFeedEnabled() ? UIMenuElementStateOn : UIMenuElementStateOff;
        UIMenu *section = [UIMenu menuWithTitle:@""
                                          image:nil
                                     identifier:nil
                                        options:UIMenuOptionsDisplayInline
                                       children:@[forYou]];
        [children insertObject:section atIndex:0];
        ApolloLog(@"[ForYou] sort menu row injected (enabled=%d)", ApolloForYouFeedEnabled());
    };
    ApolloActionMenuRegister(spec);
    ApolloLog(@"[ForYou] hooks installed");
}
