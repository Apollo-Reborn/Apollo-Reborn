// Durable, bounded restoration for the reading session Apollo loses when iOS
// eventually evicts the suspended process. This does not request background
// execution. It records a small identity-based viewport snapshot on normal
// backgrounding, then rebuilds navigation through Apollo's own URL router on a
// later cold launch.

#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import "ApolloPerPostCommentSort.h"
#import "ApolloSessionState.h"
#import "ApolloSwiftRuntime.h"

extern NSInteger ApolloPostsTypeTagFromViewController(UIViewController *viewController);
extern NSString *ApolloSubredditNameFromViewController(UIViewController *viewController);
extern NSString *ApolloSpecialFeedSlugFromViewController(UIViewController *viewController);
extern NSString *ApolloMultiredditPathFromViewController(UIViewController *viewController);

static NSString *const kApolloSessionHomeURL = @"apollo-reborn://session/home";
static const NSTimeInterval kApolloSessionMaximumAge = 7.0 * 24.0 * 60.0 * 60.0;
static const NSUInteger kApolloSessionRouteAttempts = 24;
static const NSUInteger kApolloSessionDetailAnchorAttempts = 48;
static const NSUInteger kApolloSessionFeedAnchorAttempts = 120;
static const NSTimeInterval kApolloSessionRetryDelay = 0.25;
static const NSTimeInterval kApolloSessionDetailRouteGrace = 0.75;

static __weak UIViewController *sApolloSessionFeedController;
static __weak UIViewController *sApolloSessionCommentsController;
static NSDictionary<NSString *, id> *sApolloSessionPendingRestore;
static BOOL sApolloSessionInitialRestoreConsidered;
static BOOL sApolloSessionDetailRouteStarted;
static BOOL sApolloSessionFeedViewportStarted;
static BOOL sApolloSessionDetailViewportStarted;
static BOOL sApolloSessionFeedViewportFinished;
static BOOL sApolloSessionDetailViewportFinished;
static __weak UIViewController *sApolloSessionFeedSortPreparedController;
static __weak UIViewController *sApolloSessionPagingController;
static NSInteger sApolloSessionLastRequestedPage = NSNotFound;
static NSUInteger sApolloSessionRestoreGeneration;

static BOOL ApolloSessionReadOptionalEnum(id object, const char *name, int64_t *outRaw) {
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0 || (size_t)(offset + 9) > class_getInstanceSize(object_getClass(object))) return NO;
    const uint8_t *base = (const uint8_t *)(__bridge const void *)object;
    if ((*(base + offset + 8)) & 0x1) return NO;
    int64_t raw = 0;
    memcpy(&raw, base + offset, sizeof(raw));
    if (outRaw) *outRaw = raw;
    return YES;
}

static BOOL ApolloSessionWriteOptionalEnum(id object, const char *name, int64_t raw) {
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0 || (size_t)(offset + 9) > class_getInstanceSize(object_getClass(object))) return NO;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    memcpy(base + offset, &raw, sizeof(raw));
    *(base + offset + 8) = 0;
    return YES;
}

static NSInteger ApolloSessionCurrentFeedPage(UIViewController *controller) {
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(controller), "currentPage");
    if (offset < 0 || (size_t)(offset + sizeof(NSInteger)) >
        class_getInstanceSize(object_getClass(controller))) return 0;
    NSInteger page = 0;
    memcpy(&page, (const uint8_t *)(__bridge const void *)controller + offset, sizeof(page));
    return MAX(0, page);
}

static NSString *ApolloSessionAccountScope(BOOL live) {
    NSString *username = nil;
    ApolloPersistedAccountIdentityStatus status = live
        ? ApolloResolveLiveActiveAccountIdentity(&username)
        : ApolloResolvePersistedActiveAccountIdentity(&username);
    if (status == ApolloPersistedAccountIdentityUnknown) return nil;
    if (status == ApolloPersistedAccountIdentitySignedOut) return @"signed-out";
    NSData *data = [username.lowercaseString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *scope = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [scope appendFormat:@"%02x", digest[i]];
    }
    return scope;
}

static NSString *ApolloSessionFilePath(void) {
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:
                           @"Library/Application Support/ApolloReborn"];
    return [directory stringByAppendingPathComponent:@"reading-session-v1.plist"];
}

static UITableView *ApolloSessionTableView(UIViewController *controller) {
    id tableNode = ApolloObjectIvar(controller, "tableNode");
    if (![tableNode respondsToSelector:@selector(isNodeLoaded)] ||
        !((BOOL (*)(id, SEL))objc_msgSend)(tableNode, @selector(isNodeLoaded)) ||
        ![tableNode respondsToSelector:@selector(view)]) return nil;
    id view = ((id (*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
    return [view isKindOfClass:UITableView.class] ? view : nil;
}

static id ApolloSessionNode(UIViewController *controller, NSIndexPath *path) {
    id tableNode = ApolloObjectIvar(controller, "tableNode");
    SEL selector = @selector(nodeForRowAtIndexPath:);
    if (!path || ![tableNode respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(tableNode, selector, path);
}

static NSString *ApolloSessionNodeIdentifier(id node) {
    for (NSString *ivarName in @[@"link", @"comment"]) {
        id model = ApolloObjectIvar(node, ivarName.UTF8String);
        if ([model respondsToSelector:@selector(fullName)]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(model, @selector(fullName));
            if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
        }
    }
    return nil;
}

static NSDictionary<NSString *, id> *ApolloSessionViewport(UIViewController *controller,
                                                            BOOL preferComment) {
    UITableView *table = ApolloSessionTableView(controller);
    if (!table) return nil;
    CGFloat viewportTop = table.contentOffset.y + table.adjustedContentInset.top;
    NSArray<NSIndexPath *> *visible =
        [[table indexPathsForVisibleRows] sortedArrayUsingSelector:@selector(compare:)];
    NSDictionary<NSString *, id> *firstIdentifiedRow = nil;
    for (NSIndexPath *path in visible) {
        CGRect row = [table rectForRowAtIndexPath:path];
        if (CGRectGetMaxY(row) <= viewportTop + 0.5) continue;
        NSString *identifier = ApolloSessionNodeIdentifier(ApolloSessionNode(controller, path));
        if (identifier.length) {
            NSDictionary<NSString *, id> *candidate = @{
                @"item": identifier,
                @"delta": @(viewportTop - row.origin.y),
                @"offset": @(table.contentOffset.y),
            };
            // A comments header is one very tall t3 row. Anchoring to it is
            // fragile because its title, media, and link-summary heights can
            // change while a cold load hydrates. Prefer the first visible
            // comment identity whenever one is on screen; only retain the
            // post row when the reader is still wholly inside the header.
            if (!preferComment || [identifier hasPrefix:@"t1_"]) return candidate;
            if (!firstIdentifiedRow) firstIdentifiedRow = candidate;
        }
    }
    if (firstIdentifiedRow) return firstIdentifiedRow;
    return @{ @"offset": @(table.contentOffset.y) };
}

static NSString *ApolloSessionURLStringWithPath(NSString *path) {
    if (![path hasPrefix:@"/"]) return nil;
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"apollo";
    components.host = @"reddit.com";
    components.path = path;
    return components.URL.absoluteString;
}

static NSString *ApolloSessionFeedURL(UIViewController *controller) {
    if (!controller) return nil;
    NSInteger tag = ApolloPostsTypeTagFromViewController(controller);
    NSString *title = controller.navigationItem.title ?: controller.title;
    if (tag == 6 && [title isEqualToString:@"Home"]) return kApolloSessionHomeURL;
    NSString *subreddit = ApolloSubredditNameFromViewController(controller)
        ?: ApolloSpecialFeedSlugFromViewController(controller);
    if (subreddit.length) {
        return ApolloSessionURLStringWithPath([@"/r/" stringByAppendingString:subreddit]);
    }
    NSString *multireddit = ApolloMultiredditPathFromViewController(controller);
    if (multireddit.length) return ApolloSessionURLStringWithPath(multireddit);
    return nil;
}

static id ApolloSessionLinkFromComments(UIViewController *controller) {
    static const char *const names[] = { "link", "_link", "post", "currentLink", NULL };
    for (size_t index = 0; names[index]; index++) {
        id link = ApolloObjectIvar(controller, names[index]);
        if ([link respondsToSelector:@selector(permalink)]) return link;
    }
    UITableView *table = ApolloSessionTableView(controller);
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        for (NSInteger row = 0; row < [table numberOfRowsInSection:section]; row++) {
            id node = ApolloSessionNode(controller,
                                        [NSIndexPath indexPathForRow:row inSection:section]);
            id link = ApolloObjectIvar(node, "link");
            if ([link respondsToSelector:@selector(permalink)]) return link;
        }
    }
    return nil;
}

static NSString *ApolloSessionDetailURL(UIViewController *controller, NSString *visibleItem) {
    id link = ApolloSessionLinkFromComments(controller);
    if (![link respondsToSelector:@selector(permalink)]) return nil;
    id permalink = ((id (*)(id, SEL))objc_msgSend)(link, @selector(permalink));
    if ([permalink isKindOfClass:NSURL.class]) permalink = [permalink path];
    if (![permalink isKindOfClass:NSString.class] || ![permalink hasPrefix:@"/"]) return nil;
    NSString *URLString = ApolloSessionURLStringWithPath(permalink);
    NSString *commentID = ApolloReadSwiftStringIvar(controller, "commentID");
    if (!commentID.length && [visibleItem hasPrefix:@"t1_"]) commentID = visibleItem;
    return ApolloSessionStateDetailURLByAddingCommentID(URLString, commentID);
}

static void ApolloSessionCaptureOptionalEnum(NSMutableDictionary *snapshot, id controller,
                                             const char *ivarName, NSString *key,
                                             int64_t minimum, int64_t maximum) {
    int64_t raw = 0;
    if (ApolloSessionReadOptionalEnum(controller, ivarName, &raw) && raw >= minimum && raw <= maximum) {
        snapshot[key] = @(raw);
    }
}

static NSDictionary<NSString *, id> *ApolloSessionCapture(void) {
    UIViewController *feed = sApolloSessionFeedController;
    NSString *feedURL = ApolloSessionFeedURL(feed);
    NSString *accountScope = ApolloSessionAccountScope(YES);
    if (!feedURL || !accountScope) return nil;
    NSMutableDictionary *snapshot = [@{
        ApolloSessionStateSavedAtKey: NSDate.date,
        ApolloSessionStateFeedURLKey: feedURL,
        ApolloSessionStateAccountScopeKey: accountScope,
    } mutableCopy];
    NSDictionary *feedViewport = ApolloSessionViewport(feed, NO);
    if (feedViewport[@"item"]) snapshot[ApolloSessionStateFeedItemKey] = feedViewport[@"item"];
    if (feedViewport[@"delta"]) snapshot[ApolloSessionStateFeedDeltaKey] = feedViewport[@"delta"];
    if (feedViewport[@"offset"]) snapshot[ApolloSessionStateFeedOffsetKey] = feedViewport[@"offset"];
    snapshot[ApolloSessionStateFeedPageKey] = @(MIN(20, ApolloSessionCurrentFeedPage(feed)));
    ApolloSessionCaptureOptionalEnum(snapshot, feed, "currentSort", ApolloSessionStateFeedSortKey, 1, 6);
    ApolloSessionCaptureOptionalEnum(snapshot, feed, "currentTimeSort",
                                     ApolloSessionStateFeedTimeSortKey, 1, 7);

    UIViewController *comments = sApolloSessionCommentsController;
    if (comments && comments.navigationController.topViewController == comments) {
        NSDictionary *detailViewport = ApolloSessionViewport(comments, YES);
        NSString *detailURL = ApolloSessionDetailURL(comments, detailViewport[@"item"]);
        if (detailURL) snapshot[ApolloSessionStateDetailURLKey] = detailURL;
        if (detailViewport[@"item"]) snapshot[ApolloSessionStateDetailItemKey] = detailViewport[@"item"];
        if (detailViewport[@"delta"]) snapshot[ApolloSessionStateDetailDeltaKey] = detailViewport[@"delta"];
        if (detailViewport[@"offset"]) snapshot[ApolloSessionStateDetailOffsetKey] = detailViewport[@"offset"];
        // Live Update is intentionally not restored: Apollo only starts its
        // timer from the interactive menu path. The stable 1...7 sorts are
        // safe to apply before the restored controller's first fetch.
        ApolloSessionCaptureOptionalEnum(snapshot, comments, "currentSort",
                                         ApolloSessionStateDetailSortKey, 1, 7);
    }
    return ApolloSessionStateNormalize(snapshot, NSDate.date, kApolloSessionMaximumAge);
}

static void ApolloSessionPersist(void) {
    if (!NSThread.isMainThread) return;
    NSDictionary *snapshot = ApolloSessionCapture();
    if (!snapshot) return;
    NSString *path = ApolloSessionFilePath();
    NSString *directory = path.stringByDeletingLastPathComponent;
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![snapshot writeToFile:path atomically:YES]) {
        ApolloLogError(@"[SessionRestore] Could not persist reading session: %@", error);
        return;
    }
    [[NSFileManager defaultManager] setAttributes:@{ NSFileProtectionKey:
        NSFileProtectionCompleteUntilFirstUserAuthentication } ofItemAtPath:path error:nil];
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    [fileURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    ApolloLog(@"[SessionRestore] Saved feed %@%@", snapshot[ApolloSessionStateFeedURLKey],
              snapshot[ApolloSessionStateDetailURLKey] ? @" and open post" : @"");
}

static UINavigationController *ApolloSessionNavigationControllerForTabChild(UIViewController *child) {
    if (!child) return nil;
    if ([child isKindOfClass:UINavigationController.class]) {
        return (UINavigationController *)child;
    }
    if ([child isKindOfClass:UISplitViewController.class]) {
        for (UIViewController *column in [(UISplitViewController *)child viewControllers].reverseObjectEnumerator) {
            UINavigationController *navigation = ApolloSessionNavigationControllerForTabChild(column);
            if (navigation) return navigation;
        }
    }
    return child.navigationController;
}

static UINavigationController *ApolloSessionSelectedNavigation(id tabs) {
    if (![tabs isKindOfClass:UITabBarController.class]) return nil;
    return ApolloSessionNavigationControllerForTabChild(
        [(UITabBarController *)tabs selectedViewController]);
}

static BOOL ApolloSessionOpenHomeFeed(void) {
    id tabs = ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class]) return NO;
    if ([tabs respondsToSelector:@selector(goToHomeTab)]) {
        ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToHomeTab));
    }
    UINavigationController *navigation = ApolloSessionSelectedNavigation(tabs);
    [navigation popToRootViewControllerAnimated:NO];
    UIViewController *root = navigation.viewControllers.firstObject;
    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    SEL selector = @selector(tableView:didSelectRowAtIndexPath:);
    if (!listClass || ![root isMemberOfClass:listClass] || ![root respondsToSelector:selector]) return NO;
    UITableView *table = [root respondsToSelector:@selector(tableView)]
        ? ((id (*)(id, SEL))objc_msgSend)(root, @selector(tableView)) : nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(root, selector, table,
        [NSIndexPath indexPathForRow:0 inSection:0]);
    return YES;
}

static BOOL ApolloSessionOpenURLString(NSString *URLString) {
    if ([URLString isEqualToString:kApolloSessionHomeURL]) return ApolloSessionOpenHomeFeed();
    NSURL *URL = [NSURL URLWithString:URLString];
    return URL ? ApolloRouteURLThroughApp(URL) : NO;
}

static NSIndexPath *ApolloSessionPathForIdentifier(UIViewController *controller,
                                                    NSString *identifier) {
    UITableView *table = ApolloSessionTableView(controller);
    if (!table || identifier.length == 0) return nil;
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        for (NSInteger row = 0; row < [table numberOfRowsInSection:section]; row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
            if ([ApolloSessionNodeIdentifier(ApolloSessionNode(controller, path))
                    isEqualToString:identifier]) return path;
        }
    }
    return nil;
}

static void ApolloSessionFinishViewport(BOOL detail) {
    if (detail) sApolloSessionDetailViewportFinished = YES;
    else sApolloSessionFeedViewportFinished = YES;
    if (sApolloSessionFeedViewportFinished && sApolloSessionDetailViewportFinished) {
        sApolloSessionPendingRestore = nil;
    }
}

static BOOL ApolloSessionApplyFeedSort(UIViewController *controller) {
    BOOL changed = NO;
    NSNumber *sort = sApolloSessionPendingRestore[ApolloSessionStateFeedSortKey];
    NSNumber *timeSort = sApolloSessionPendingRestore[ApolloSessionStateFeedTimeSortKey];
    for (NSArray *entry in @[
        @[@"currentSort", sort ?: NSNull.null],
        @[@"currentTimeSort", timeSort ?: NSNull.null],
    ]) {
        NSNumber *saved = entry[1];
        if (saved == (id)NSNull.null) continue;
        int64_t current = 0;
        const char *name = [entry[0] UTF8String];
        if ((!ApolloSessionReadOptionalEnum(controller, name, &current) || current != saved.longLongValue) &&
            ApolloSessionWriteOptionalEnum(controller, name, saved.longLongValue)) changed = YES;
    }
    return changed;
}

static BOOL ApolloSessionRequestNextFeedPage(UIViewController *controller) {
    NSInteger page = ApolloSessionCurrentFeedPage(controller);
    NSInteger lastRequested = sApolloSessionPagingController == controller
        ? sApolloSessionLastRequestedPage : NSNotFound;
    NSInteger savedPage = [sApolloSessionPendingRestore[ApolloSessionStateFeedPageKey] integerValue];
    if (!ApolloSessionStateShouldRequestNextFeedPage(savedPage, page, lastRequested)) return NO;
    id tableNode = ApolloObjectIvar(controller, "tableNode");
    id adapter = ApolloObjectIvar(controller, "listAdapter");
    Class contextClass = objc_getClass("ASBatchContext");
    SEL selector = @selector(tableNode:willBeginBatchFetchWithContext:);
    if (!tableNode || !adapter || !contextClass || ![adapter respondsToSelector:selector]) return NO;
    id context = [contextClass new];
    if (!context) return NO;
    sApolloSessionPagingController = controller;
    sApolloSessionLastRequestedPage = page;
    ((void (*)(id, SEL, id, id))objc_msgSend)(adapter, selector, tableNode, context);
    ApolloLog(@"[SessionRestore] Requested feed page after page %ld for saved anchor", (long)page);
    return YES;
}

static void ApolloSessionStartDetailRoute(void) {
    if (sApolloSessionDetailRouteStarted) return;
    sApolloSessionDetailRouteStarted = YES;
    NSString *detailURL = sApolloSessionPendingRestore[ApolloSessionStateDetailURLKey];
    if (!detailURL.length) {
        sApolloSessionPendingRestore = nil;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSessionRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!ApolloSessionOpenURLString(detailURL)) {
            ApolloLog(@"[SessionRestore] Apollo rejected saved post route %@", detailURL);
            ApolloSessionFinishViewport(YES);
            [[NSFileManager defaultManager] removeItemAtPath:ApolloSessionFilePath() error:nil];
            return;
        }
        NSUInteger generation = sApolloSessionRestoreGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kApolloSessionDetailAnchorAttempts * kApolloSessionRetryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation == sApolloSessionRestoreGeneration && sApolloSessionPendingRestore &&
                !sApolloSessionDetailViewportStarted) {
                ApolloLog(@"[SessionRestore] Saved post did not become available; keeping restored feed");
                ApolloSessionFinishViewport(YES);
                [[NSFileManager defaultManager] removeItemAtPath:ApolloSessionFilePath() error:nil];
            }
        });
    });
}

static void ApolloSessionScheduleDetailRoute(NSUInteger generation) {
    if (![sApolloSessionPendingRestore[ApolloSessionStateDetailURLKey] length]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kApolloSessionDetailRouteGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sApolloSessionRestoreGeneration || !sApolloSessionPendingRestore) return;
        // Feed restoration builds the back stack, but a moved/deleted post may
        // no longer be present in the refreshed first page. Do not hold the
        // authoritative post route behind twelve seconds of feed-anchor
        // retries. The short grace period still lets the common in-page anchor
        // case settle before the detail route is opened.
        ApolloSessionStartDetailRoute();
    });
}

static void ApolloSessionRestoreViewport(UIViewController *controller, BOOL detail,
                                         NSUInteger attempt, NSUInteger generation) {
    UINavigationController *navigation = controller.navigationController;
    BOOL visible = controller.viewIfLoaded.window != nil;
    BOOL top = navigation.topViewController == controller;
    BOOL inStack = [navigation.viewControllers containsObject:controller];
    if (generation != sApolloSessionRestoreGeneration || !sApolloSessionPendingRestore ||
        !ApolloSessionStateViewportRestoreIsEligible(detail, visible, top, inStack)) return;
    UITableView *table = ApolloSessionTableView(controller);
    NSString *itemKey = detail ? ApolloSessionStateDetailItemKey : ApolloSessionStateFeedItemKey;
    NSString *deltaKey = detail ? ApolloSessionStateDetailDeltaKey : ApolloSessionStateFeedDeltaKey;
    NSString *offsetKey = detail ? ApolloSessionStateDetailOffsetKey : ApolloSessionStateFeedOffsetKey;
    NSString *identifier = sApolloSessionPendingRestore[itemKey];
    NSIndexPath *path = ApolloSessionPathForIdentifier(controller, identifier);
    BOOL settled = table && table.numberOfSections > 0 && table.contentSize.height > 0;
    if (path) {
        CGFloat delta = [sApolloSessionPendingRestore[deltaKey] doubleValue];
        CGFloat y = [table rectForRowAtIndexPath:path].origin.y + delta - table.adjustedContentInset.top;
        CGFloat top = -table.adjustedContentInset.top;
        CGFloat bottom = MAX(top, table.contentSize.height - table.bounds.size.height +
                             table.adjustedContentInset.bottom);
        [table setContentOffset:CGPointMake(table.contentOffset.x, MIN(MAX(y, top), bottom)) animated:NO];
        ApolloLog(@"[SessionRestore] Restored %@ anchor %@", detail ? @"post" : @"feed", identifier);
        if (!detail) ApolloSessionStartDetailRoute();
        ApolloSessionFinishViewport(detail);
        return;
    }
    NSUInteger maximumAttempts = detail ? kApolloSessionDetailAnchorAttempts
                                        : kApolloSessionFeedAnchorAttempts;
    NSInteger savedPage = [sApolloSessionPendingRestore[ApolloSessionStateFeedPageKey] integerValue];
    NSInteger currentPage = detail ? savedPage : ApolloSessionCurrentFeedPage(controller);
    if (!detail && settled && currentPage < savedPage && attempt % 4 == 3) {
        ApolloSessionRequestNextFeedPage(controller);
    }
    if (attempt + 1 < maximumAttempts) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSessionRetryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloSessionRestoreViewport(controller, detail, attempt + 1, generation);
        });
        return;
    }
    // Identity is authoritative. A raw offset is used only after content has
    // settled and the saved row cannot be found (for example after deletion).
    NSNumber *fallback = sApolloSessionPendingRestore[offsetKey];
    if (settled && fallback) {
        CGFloat top = -table.adjustedContentInset.top;
        CGFloat bottom = MAX(top, table.contentSize.height - table.bounds.size.height +
                             table.adjustedContentInset.bottom);
        [table setContentOffset:CGPointMake(table.contentOffset.x,
            MIN(MAX(fallback.doubleValue, top), bottom)) animated:NO];
        ApolloLog(@"[SessionRestore] %@ anchor unavailable; used bounded pixel fallback",
                  detail ? @"Post" : @"Feed");
    }
    if (!detail) ApolloSessionStartDetailRoute();
    ApolloSessionFinishViewport(detail);
}

static void ApolloSessionRouteFeed(NSUInteger attempt, NSUInteger generation) {
    if (generation != sApolloSessionRestoreGeneration || !sApolloSessionPendingRestore) return;
    if (ApolloSessionOpenURLString(sApolloSessionPendingRestore[ApolloSessionStateFeedURLKey])) return;
    if (attempt + 1 >= kApolloSessionRouteAttempts) {
        ApolloLog(@"[SessionRestore] Timed out opening saved feed");
        sApolloSessionPendingRestore = nil;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSessionRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ApolloSessionRouteFeed(attempt + 1, generation); });
}

static void ApolloSessionConsiderInitialRestore(void) {
    if (sApolloSessionInitialRestoreConsidered) return;
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:ApolloSessionFilePath()];
    NSDictionary *normalized = ApolloSessionStateNormalize(stored, NSDate.date,
                                                            kApolloSessionMaximumAge);
    if (!normalized) {
        sApolloSessionInitialRestoreConsidered = YES;
        return;
    }
    NSString *accountScope = ApolloSessionAccountScope(NO);
    if (!accountScope) return; // AccountManager has not finished restoring yet.
    sApolloSessionInitialRestoreConsidered = YES;
    if (![accountScope isEqualToString:normalized[ApolloSessionStateAccountScopeKey]]) {
        ApolloLog(@"[SessionRestore] Ignoring reading session saved for a different account");
        return;
    }
    sApolloSessionPendingRestore = normalized;
    sApolloSessionDetailRouteStarted = NO;
    sApolloSessionFeedViewportStarted = NO;
    sApolloSessionDetailViewportStarted = NO;
    sApolloSessionFeedViewportFinished = NO;
    sApolloSessionDetailViewportFinished = ![normalized[ApolloSessionStateDetailURLKey] length];
    sApolloSessionFeedSortPreparedController = nil;
    sApolloSessionPagingController = nil;
    sApolloSessionLastRequestedPage = NSNotFound;
    NSUInteger generation = ++sApolloSessionRestoreGeneration;
    ApolloLog(@"[SessionRestore] Cold launch has a recent reading session");
    ApolloSessionRouteFeed(0, generation);
}

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLoad {
    if (sApolloSessionPendingRestore && !sApolloSessionFeedViewportStarted) {
        ApolloSessionApplyFeedSort((UIViewController *)self);
        sApolloSessionFeedSortPreparedController = (UIViewController *)self;
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    sApolloSessionFeedController = (UIViewController *)self;
    sApolloSessionCommentsController = nil;
    NSDictionary *pending = sApolloSessionPendingRestore;
    if (pending && [ApolloSessionFeedURL((UIViewController *)self)
                        isEqualToString:pending[ApolloSessionStateFeedURLKey]] &&
        !sApolloSessionFeedViewportStarted) {
        id selfObject = (id)self;
        BOOL preparedBeforeLoad = sApolloSessionFeedSortPreparedController ==
                                  (UIViewController *)self;
        BOOL changedSort = preparedBeforeLoad ? NO :
            ApolloSessionApplyFeedSort((UIViewController *)self);
        if (changedSort && [selfObject respondsToSelector:@selector(reloadPostsWithNotification:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(selfObject,
                @selector(reloadPostsWithNotification:), nil);
        }
        sApolloSessionFeedViewportStarted = YES;
        NSUInteger generation = sApolloSessionRestoreGeneration;
        ApolloSessionRestoreViewport((UIViewController *)self, NO, 0,
                                     generation);
        ApolloSessionScheduleDetailRoute(generation);
    }
}

%end

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLoad {
    NSNumber *sort = sApolloSessionPendingRestore[ApolloSessionStateDetailSortKey];
    if (sApolloSessionDetailRouteStarted && sort) {
        ApolloCommentsVCWriteCurrentSort(self, sort.longLongValue);
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    sApolloSessionCommentsController = (UIViewController *)self;
    NSDictionary *pending = sApolloSessionPendingRestore;
    if (pending && sApolloSessionDetailRouteStarted && !sApolloSessionDetailViewportStarted) {
        sApolloSessionDetailViewportStarted = YES;
        ApolloSessionRestoreViewport((UIViewController *)self, YES, 0,
                                     sApolloSessionRestoreGeneration);
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig(animated);
    if (sApolloSessionCommentsController == (UIViewController *)self) {
        sApolloSessionCommentsController = nil;
    }
}

%end

%hook _TtC6Apollo13SceneDelegate

- (void)sceneWillEnterForeground:(UIScene *)scene {
    %orig;
    // The notification observer normally owns this. The scene callback is a
    // lifecycle-safe fallback for launch orders where this dylib finishes
    // loading after UIApplication posted its first active notification.
    ApolloSessionConsiderInitialRestore();
}

%end


%ctor {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ApolloSessionPersist();
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ApolloSessionConsiderInitialRestore();
    }];
    [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        // A warning is not an eviction guarantee, but it is a cheap opportunity
        // to refresh the same tiny snapshot before UIKit sheds controllers.
        ApolloSessionPersist();
    }];
    ApolloLog(@"[SessionRestore] Durable reading-session hooks installed");
}
