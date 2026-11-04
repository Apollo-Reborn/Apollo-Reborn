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
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloPerPostCommentSort.h"
#import "ApolloSessionRestoration.h"
#import "ApolloSessionState.h"
#import "ApolloDuoSplitView.h"
#import "ApolloFeedShortcutsAppearance.h"
#import "ApolloState.h"
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
static const NSUInteger kApolloSessionMaximumMoreCommentsRequests = 4;
static const NSInteger kApolloSessionMaximumFeedPage = 5;
static const NSTimeInterval kApolloSessionRetryDelay = 0.25;
static const NSTimeInterval kApolloSessionDetailRouteGrace = 0.75;

static __weak UIViewController *sApolloSessionFeedController;
static __weak UIViewController *sApolloSessionCommentsController;
static __weak UIWindowScene *sApolloSessionRestoreScene;
static NSDictionary<NSString *, id> *sApolloSessionPendingRestore;
static BOOL sApolloSessionInitialRestoreConsidered;
static BOOL sApolloSessionAccountReadyRetryPending;
static BOOL sApolloSessionDetailRouteStarted;
static BOOL sApolloSessionDetailRouteOpened;
static BOOL sApolloSessionFeedViewportStarted;
static BOOL sApolloSessionDetailViewportStarted;
static BOOL sApolloSessionDetailControllerSeen;
static BOOL sApolloSessionFeedViewportFinished;
static BOOL sApolloSessionDetailViewportFinished;
static BOOL sApolloSessionDeleteSnapshotAfterRestore;
static BOOL sApolloSessionLaunchHasExplicitDestination;
static __weak UIViewController *sApolloSessionFeedSortPreparedController;
static __weak UIViewController *sApolloSessionPagingController;
static NSInteger sApolloSessionLastRequestedPage = NSNotFound;
static NSHashTable *sApolloSessionRequestedMoreComments;
static NSUInteger sApolloSessionMoreCommentsRequestCount;
static NSUInteger sApolloSessionRestoreGeneration;

static void ApolloSessionRevalidatePendingNavigation(void);

@interface ApolloSessionScrollMarker : NSObject
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic) BOOL detail;
@property(nonatomic) NSUInteger generation;
@end

@implementation ApolloSessionScrollMarker
@end

@interface ApolloSessionScrollObserver : NSObject
- (void)apollo_sessionPanChanged:(UIPanGestureRecognizer *)gesture;
@end

static const void *kApolloSessionScrollMarkerKey = &kApolloSessionScrollMarkerKey;
static const void *kApolloSessionScrollObserverInstalledKey =
    &kApolloSessionScrollObserverInstalledKey;

static UIWindowScene *ApolloSessionOnlyForegroundScene(void) {
    UIWindowScene *only = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class] ||
            candidate.activationState != UISceneActivationStateForegroundActive) continue;
        if (only) return nil;
        only = (UIWindowScene *)candidate;
    }
    return only;
}

static UIWindowScene *ApolloSessionControllerScene(UIViewController *controller) {
    return controller.viewIfLoaded.window.windowScene ?:
           controller.navigationController.viewIfLoaded.window.windowScene;
}

static BOOL ApolloSessionControllerOwnsRestore(UIViewController *controller) {
    UIWindowScene *controllerScene = ApolloSessionControllerScene(controller);
    return ApolloSessionStateControllerSceneOwnsRestore(
        sApolloSessionPendingRestore != nil,
        sApolloSessionRestoreScene != nil,
        controllerScene == sApolloSessionRestoreScene);
}

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

static NSString *ApolloSessionDetailURL(UIViewController *controller) {
    id link = ApolloSessionLinkFromComments(controller);
    if (![link respondsToSelector:@selector(permalink)]) return nil;
    id permalink = ((id (*)(id, SEL))objc_msgSend)(link, @selector(permalink));
    if ([permalink isKindOfClass:NSURL.class]) permalink = [permalink path];
    if (![permalink isKindOfClass:NSString.class] || ![permalink hasPrefix:@"/"]) return nil;
    NSString *URLString = ApolloSessionURLStringWithPath(permalink);
    NSString *commentID = ApolloReadSwiftStringIvar(controller, "commentID");
    return ApolloSessionStateDetailURLByAddingCommentID(URLString, commentID);
}

static BOOL ApolloSessionCommentsControllerMatchesPendingDetail(UIViewController *controller) {
    NSString *savedURL = sApolloSessionPendingRestore[ApolloSessionStateDetailURLKey];
    // URL-routed controllers have no link object until their first fetch. The
    // Swift initializer has already populated these IDs before viewDidLoad,
    // which is exactly where the saved sort must be written.
    NSString *postID = ApolloReadSwiftStringIvar(controller, "linkID");
    NSString *commentID = ApolloReadSwiftStringIvar(controller, "commentID");
    return ApolloSessionStateDetailIdentifiersMatchSavedRoute(postID, commentID, savedURL);
}

int64_t ApolloSessionRestorationPendingCommentSortForPost(NSString *postID) {
    NSNumber *sort = sApolloSessionPendingRestore[ApolloSessionStateDetailSortKey];
    NSString *savedURL = sApolloSessionPendingRestore[ApolloSessionStateDetailURLKey];
    if (!sApolloSessionDetailRouteStarted || sApolloSessionDetailViewportFinished ||
        ![sort isKindOfClass:NSNumber.class] || sort.longLongValue < 1 ||
        sort.longLongValue > 7 ||
        !ApolloSessionStateDetailPostIdentifierMatchesSavedRoute(postID, savedURL)) {
        return 0;
    }
    return sort.longLongValue;
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
    NSInteger feedPage = ApolloSessionCurrentFeedPage(feed);
    if (feedPage <= kApolloSessionMaximumFeedPage) {
        NSDictionary *feedViewport = ApolloSessionViewport(feed, NO);
        if (feedViewport[@"item"]) snapshot[ApolloSessionStateFeedItemKey] = feedViewport[@"item"];
        if (feedViewport[@"delta"]) snapshot[ApolloSessionStateFeedDeltaKey] = feedViewport[@"delta"];
        if (feedViewport[@"offset"]) snapshot[ApolloSessionStateFeedOffsetKey] = feedViewport[@"offset"];
        snapshot[ApolloSessionStateFeedPageKey] = @(feedPage);
    } else {
        snapshot[ApolloSessionStateFeedPageKey] = @0;
    }
    ApolloSessionCaptureOptionalEnum(snapshot, feed, "currentSort", ApolloSessionStateFeedSortKey, 1, 6);
    ApolloSessionCaptureOptionalEnum(snapshot, feed, "currentTimeSort",
                                     ApolloSessionStateFeedTimeSortKey, 1, 7);

    UIViewController *comments = sApolloSessionCommentsController;
    UIViewController *(^tabChild)(UIViewController *) = ^UIViewController *(UIViewController *controller) {
        while (controller.parentViewController &&
               ![controller.parentViewController isKindOfClass:UITabBarController.class]) {
            controller = controller.parentViewController;
        }
        return controller;
    };
    if (comments && tabChild(comments) == tabChild(feed) &&
        comments.navigationController.topViewController == comments) {
        NSDictionary *detailViewport = ApolloSessionViewport(comments, YES);
        NSString *detailURL = ApolloSessionDetailURL(comments);
        if (detailURL) snapshot[ApolloSessionStateDetailURLKey] = detailURL;
        snapshot[ApolloSessionStateDetailContextualKey] =
            @(ApolloReadSwiftStringIvar(comments, "commentID").length > 0);
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
    if (!sRestoreReadingSession) {
        [[NSFileManager defaultManager] removeItemAtPath:ApolloSessionFilePath() error:nil];
        return;
    }
    ApolloSessionRevalidatePendingNavigation();
    if (ApolloSessionStateShouldDeferPersistence(sApolloSessionPendingRestore != nil,
                                                 sApolloSessionFeedViewportFinished,
                                                 sApolloSessionDetailViewportFinished)) {
        // The complete pre-eviction snapshot is still on disk. Replacing it
        // with a partially rebuilt feed would discard an open post/detail
        // anchor if the process is evicted during this background transition.
        ApolloLog(@"[SessionRestore] Keeping saved session while restoration is incomplete");
        return;
    }
    NSDictionary *snapshot = ApolloSessionCapture();
    if (!snapshot) {
        [[NSFileManager defaultManager] removeItemAtPath:ApolloSessionFilePath() error:nil];
        return;
    }
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

// Selects a built-in feed row (0 Home, 1 Popular, 2 All) in the subreddit
// list, exactly as tapping it does. NO while the list is not ready, or when a
// hidden Popular/All shortcut has no row.
static BOOL ApolloSessionOpenBuiltInFeed(NSUInteger feedIndex) {
    id tabs = ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class]) return NO;
    if ([tabs respondsToSelector:@selector(goToHomeTab)]) {
        ((void (*)(id, SEL))objc_msgSend)(tabs, @selector(goToHomeTab));
    }
    UINavigationController *navigation = ApolloSessionSelectedNavigation(tabs);
    [navigation popToRootViewControllerAnimated:NO];
    // An open Duo moves the list into its split host; Duo retains the native
    // list controller as the tab's root.
    UIViewController *root = ApolloDuoSplitRootController(navigation) ?: navigation.viewControllers.firstObject;
    SEL selector = @selector(tableView:didSelectRowAtIndexPath:);
    if (!ApolloClassRedditListViewController ||
        ![root isMemberOfClass:ApolloClassRedditListViewController] ||
        ![root respondsToSelector:selector]) return NO;
    UITableView *table = [root respondsToSelector:@selector(tableView)]
        ? ((id (*)(id, SEL))objc_msgSend)(root, @selector(tableView)) : nil;
    // Hidden Popular/All shortcuts shift the rows after them.
    NSUInteger row = feedIndex == 0 ? 0 : [ApolloFeedShortcutVisibleIndexes() indexOfObject:@(feedIndex)];
    if (row == NSNotFound || (feedIndex != 0 && (table.numberOfSections == 0 ||
        row >= (NSUInteger)[table numberOfRowsInSection:0]))) return NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)(root, selector, table,
        [NSIndexPath indexPathForRow:row inSection:0]);
    return YES;
}

static BOOL ApolloSessionOpenURLString(NSString *URLString) {
    if (!sApolloSessionRestoreScene) return NO;
    if ([URLString isEqualToString:kApolloSessionHomeURL]) return ApolloSessionOpenBuiltInFeed(0);
    // Popular/All are saved as r/popular and r/all. Routing those URLs opens a
    // separate subreddit page named "all" on top of (or, on an open Duo,
    // beside) the built-in feed. Reopen the built-in feed itself.
    NSUInteger feedIndex = ApolloSessionStateBuiltInFeedIndex(URLString);
    if (feedIndex != NSNotFound && [ApolloFeedShortcutVisibleIndexes() containsObject:@(feedIndex)]) {
        return ApolloSessionOpenBuiltInFeed(feedIndex);
    }
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

static NSString *ApolloSessionFeedContentFingerprint(UIViewController *controller) {
    UITableView *table = ApolloSessionTableView(controller);
    if (!table || table.numberOfSections == 0 || table.contentSize.height <= 0) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSInteger rowCount = 0;
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        for (NSInteger row = 0; row < [table numberOfRowsInSection:section]; row++) {
            rowCount++;
            NSString *identifier = ApolloSessionNodeIdentifier(ApolloSessionNode(
                controller, [NSIndexPath indexPathForRow:row inSection:section]));
            if (identifier.length) [parts addObject:identifier];
        }
    }
    if (rowCount == 0) return nil;
    return [NSString stringWithFormat:@"%ld:%@", (long)rowCount,
            [parts componentsJoinedByString:@","]];
}

static void ApolloSessionFinishViewport(BOOL detail) {
    if (detail) sApolloSessionDetailViewportFinished = YES;
    else sApolloSessionFeedViewportFinished = YES;
    if (sApolloSessionFeedViewportFinished && sApolloSessionDetailViewportFinished) {
        sApolloSessionPendingRestore = nil;
        if (sApolloSessionDeleteSnapshotAfterRestore &&
            ApolloSessionStateShouldDeleteSnapshotAfterDetailFailure(
                sApolloSessionFeedViewportFinished, sApolloSessionDetailViewportFinished)) {
            [[NSFileManager defaultManager] removeItemAtPath:ApolloSessionFilePath() error:nil];
            sApolloSessionDeleteSnapshotAfterRestore = NO;
        }
    }
}

static void ApolloSessionCancelFeedForRouteChange(void) {
    // If detail routing has not begun, the in-place feed change is the user's
    // newer navigation intent and should also suppress the pending route. Once
    // Apollo has accepted the detail route, that independent phase owns its own
    // terminal state and must not be cancelled by the underlying feed.
    if (ApolloSessionStateShouldCancelUnstartedDetail(
            sApolloSessionDetailRouteOpened, sApolloSessionDetailViewportFinished)) {
        ApolloSessionFinishViewport(YES);
    }
    ApolloSessionFinishViewport(NO);
}

@implementation ApolloSessionScrollObserver

- (void)apollo_sessionPanChanged:(UIPanGestureRecognizer *)gesture {
    ApolloSessionScrollMarker *marker =
        objc_getAssociatedObject(gesture, kApolloSessionScrollMarkerKey);
    if (!marker || marker.generation != sApolloSessionRestoreGeneration) return;
    BOOL phaseStarted = marker.detail ? sApolloSessionDetailViewportStarted
                                      : sApolloSessionFeedViewportStarted;
    BOOL phaseFinished = marker.detail ? sApolloSessionDetailViewportFinished
                                       : sApolloSessionFeedViewportFinished;
    if (!ApolloSessionStateShouldCancelForReaderScroll(
            sApolloSessionPendingRestore != nil,
            ApolloSessionControllerOwnsRestore(marker.controller),
            phaseStarted, phaseFinished,
            gesture.state == UIGestureRecognizerStateBegan)) return;
    objc_setAssociatedObject(gesture, kApolloSessionScrollMarkerKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[SessionRestore] Reader started scrolling the %@ during restore; leaving it there",
              marker.detail ? @"post" : @"feed");
    if (marker.detail) ApolloSessionFinishViewport(YES);
    else ApolloSessionCancelFeedForRouteChange();
}

@end

static ApolloSessionScrollObserver *ApolloSessionSharedScrollObserver(void) {
    static ApolloSessionScrollObserver *observer = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ observer = [ApolloSessionScrollObserver new]; });
    return observer;
}

static void ApolloSessionObserveReaderScroll(UIViewController *controller, BOOL detail) {
    UITableView *table = ApolloSessionTableView(controller);
    UIPanGestureRecognizer *gesture = table.panGestureRecognizer;
    if (!gesture) return;
    if (![objc_getAssociatedObject(gesture, kApolloSessionScrollObserverInstalledKey) boolValue]) {
        [gesture addTarget:ApolloSessionSharedScrollObserver()
                    action:@selector(apollo_sessionPanChanged:)];
        objc_setAssociatedObject(gesture, kApolloSessionScrollObserverInstalledKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloSessionScrollMarker *marker = [ApolloSessionScrollMarker new];
    marker.controller = controller;
    marker.detail = detail;
    marker.generation = sApolloSessionRestoreGeneration;
    objc_setAssociatedObject(gesture, kApolloSessionScrollMarkerKey, marker,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloSessionFeedOwnsPendingNavigation(void) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIViewController *feed = sApolloSessionFeedController;
    return feed.viewIfLoaded.window != nil &&
           ApolloSessionStateFeedOwnsSelectedNavigation(
               feed.navigationController == ApolloSessionSelectedNavigation(
                   ApolloMainTabBarController()),
               feed.navigationController.topViewController == feed,
               NO) &&
           ApolloSessionStateFeedURLMatchesSavedRoute(
               ApolloSessionFeedURL(feed),
               sApolloSessionPendingRestore[ApolloSessionStateFeedURLKey]);
}

static BOOL ApolloSessionFeedOwnsSelectedRestoreStack(void) {
    UIViewController *feed = sApolloSessionFeedController;
    UINavigationController *navigation = feed.navigationController;
    UIViewController *topController = navigation.topViewController;
    BOOL topIsRestoredDetail = sApolloSessionDetailRouteOpened &&
        ApolloClassCommentsViewController &&
        [topController isMemberOfClass:ApolloClassCommentsViewController] &&
        ApolloSessionCommentsControllerMatchesPendingDetail(topController);
    return feed && ApolloSessionStateFeedOwnsSelectedNavigation(
            navigation == ApolloSessionSelectedNavigation(
                ApolloMainTabBarController()),
            topController == feed,
            topIsRestoredDetail) &&
        ApolloSessionStateFeedURLMatchesSavedRoute(
            ApolloSessionFeedURL(feed),
            sApolloSessionPendingRestore[ApolloSessionStateFeedURLKey]);
}

static void ApolloSessionRevalidatePendingNavigation(void) {
    if (!sApolloSessionPendingRestore || !sApolloSessionFeedController ||
        (!sApolloSessionFeedViewportStarted && !sApolloSessionFeedViewportFinished)) return;
    UIViewController *topController = sApolloSessionFeedController.navigationController.topViewController;
    BOOL restoredDetailOnTop = ApolloClassCommentsViewController &&
        [topController isMemberOfClass:ApolloClassCommentsViewController] &&
        ApolloSessionCommentsControllerMatchesPendingDetail(topController);
    if (ApolloSessionStateShouldFinishAbandonedDetail(
            sApolloSessionDetailRouteOpened, sApolloSessionDetailControllerSeen,
            sApolloSessionDetailViewportFinished, restoredDetailOnTop)) {
        ApolloLog(@"[SessionRestore] Reader left restored post before its anchor retry completed");
        ApolloSessionFinishViewport(YES);
        if (!sApolloSessionPendingRestore) return;
    }
    if (!ApolloSessionFeedOwnsSelectedRestoreStack()) {
        ApolloLog(@"[SessionRestore] Newer navigation replaced the restore stack before backgrounding");
        ApolloSessionCancelFeedForRouteChange();
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
    SEL selector = @selector(tableNode:willBeginBatchFetchWithContext:);
    if (!tableNode || !adapter || !ApolloClassASBatchContext ||
        ![adapter respondsToSelector:selector]) return NO;
    id context = [ApolloClassASBatchContext new];
    if (!context) return NO;
    sApolloSessionPagingController = controller;
    sApolloSessionLastRequestedPage = page;
    ((void (*)(id, SEL, id, id))objc_msgSend)(adapter, selector, tableNode, context);
    ApolloLog(@"[SessionRestore] Requested feed page after page %ld for saved anchor", (long)page);
    return YES;
}

static BOOL ApolloSessionRequestMoreCommentsForAnchor(UIViewController *controller,
                                                      NSString *identifier) {
    if (!controller || identifier.length == 0 ||
        sApolloSessionMoreCommentsRequestCount >= kApolloSessionMaximumMoreCommentsRequests) {
        return NO;
    }
    UITableView *table = ApolloSessionTableView(controller);
    SEL tapSelector = NSSelectorFromString(@"moreCommentsCellTappedWithMoreComments:");
    if (!table || !ApolloClassMoreCommentsCellNode ||
        ![controller respondsToSelector:tapSelector]) return NO;
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        for (NSInteger row = 0; row < [table numberOfRowsInSection:section]; row++) {
            id node = ApolloSessionNode(controller,
                [NSIndexPath indexPathForRow:row inSection:section]);
            if (![node isKindOfClass:ApolloClassMoreCommentsCellNode]) continue;
            id moreComments = ApolloObjectIvar(node, "moreComments");
            if (!moreComments || [sApolloSessionRequestedMoreComments containsObject:moreComments] ||
                ![moreComments respondsToSelector:@selector(children)]) continue;
            id children = ((id (*)(id, SEL))objc_msgSend)(moreComments, @selector(children));
            if (!ApolloSessionStateMoreCommentsChildrenContainIdentifier(children, identifier)) continue;
            [sApolloSessionRequestedMoreComments addObject:moreComments];
            sApolloSessionMoreCommentsRequestCount++;
            ((void (*)(id, SEL, id))objc_msgSend)(controller, tapSelector, moreComments);
            ApolloLog(@"[SessionRestore] Requested the comment branch containing saved anchor %@",
                      identifier);
            return YES;
        }
    }
    return NO;
}

static void ApolloSessionStartDetailRoute(void) {
    if (sApolloSessionDetailRouteStarted || !sApolloSessionPendingRestore ||
        sApolloSessionDetailViewportFinished) return;
    sApolloSessionDetailRouteStarted = YES;
    NSString *detailURL = sApolloSessionPendingRestore[ApolloSessionStateDetailURLKey];
    if (!detailURL.length) {
        ApolloSessionFinishViewport(YES);
        return;
    }
    NSUInteger generation = sApolloSessionRestoreGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSessionRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!ApolloSessionStateQueuedPhaseWorkShouldRun(
                sApolloSessionPendingRestore != nil,
                generation == sApolloSessionRestoreGeneration,
                sApolloSessionDetailViewportFinished)) return;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            // Foregrounding schedules the route again after Apollo has
            // reattached the feed controller's window.
            sApolloSessionDetailRouteStarted = NO;
            return;
        }
        if (!ApolloSessionFeedOwnsPendingNavigation()) {
            sApolloSessionDetailRouteStarted = NO;
            ApolloLog(@"[SessionRestore] Newer navigation suppressed the saved post route");
            ApolloSessionCancelFeedForRouteChange();
            return;
        }
        if (!ApolloSessionOpenURLString(detailURL)) {
            ApolloLog(@"[SessionRestore] Apollo rejected saved post route %@", detailURL);
            sApolloSessionDeleteSnapshotAfterRestore = YES;
            ApolloSessionFinishViewport(YES);
            return;
        }
        sApolloSessionDetailRouteOpened = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(kApolloSessionDetailAnchorAttempts * kApolloSessionRetryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (ApolloSessionStateQueuedPhaseWorkShouldRun(
                    sApolloSessionPendingRestore != nil,
                    generation == sApolloSessionRestoreGeneration,
                    sApolloSessionDetailViewportFinished) &&
                ApolloSessionStateDetailRouteDeadlineShouldFinish(
                    sApolloSessionDetailControllerSeen, sApolloSessionDetailViewportFinished)) {
                ApolloLog(@"[SessionRestore] Saved post did not become available; keeping restored feed");
                sApolloSessionDeleteSnapshotAfterRestore = YES;
                ApolloSessionFinishViewport(YES);
            }
        });
    });
}

static void ApolloSessionScheduleDetailRoute(NSUInteger generation) {
    BOOL canSchedule = ApolloSessionStateQueuedPhaseWorkShouldRun(
            sApolloSessionPendingRestore != nil,
            generation == sApolloSessionRestoreGeneration,
            sApolloSessionDetailViewportFinished);
    if (!canSchedule || sApolloSessionDetailRouteStarted ||
        ![sApolloSessionPendingRestore[ApolloSessionStateDetailURLKey] length]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kApolloSessionDetailRouteGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL shouldRun = ApolloSessionStateQueuedPhaseWorkShouldRun(
                sApolloSessionPendingRestore != nil,
                generation == sApolloSessionRestoreGeneration,
                sApolloSessionDetailViewportFinished);
        if (!shouldRun || sApolloSessionDetailRouteStarted) return;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        if (!ApolloSessionFeedOwnsPendingNavigation()) {
            ApolloLog(@"[SessionRestore] Newer navigation suppressed the saved post route");
            ApolloSessionCancelFeedForRouteChange();
            return;
        }
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
    BOOL phaseFinished = detail ? sApolloSessionDetailViewportFinished
                                : sApolloSessionFeedViewportFinished;
    if (!ApolloSessionStateQueuedPhaseWorkShouldRun(
            sApolloSessionPendingRestore != nil,
            generation == sApolloSessionRestoreGeneration,
            phaseFinished)) return;
    UINavigationController *navigation = controller.navigationController;
    BOOL visible = controller.viewIfLoaded.window != nil;
    BOOL top = navigation.topViewController == controller;
    BOOL inStack = [navigation.viewControllers containsObject:controller];
    UIViewController *topController = navigation.topViewController;
    BOOL applicationActive = UIApplication.sharedApplication.applicationState ==
                             UIApplicationStateActive;
    BOOL underRestoredDetail = !detail && sApolloSessionDetailRouteStarted &&
        topController != controller && ApolloClassCommentsViewController &&
        [topController isMemberOfClass:ApolloClassCommentsViewController] &&
        ApolloSessionCommentsControllerMatchesPendingDetail(topController);
    if (!detail && !ApolloSessionStateFeedURLMatchesSavedRoute(
                       ApolloSessionFeedURL(controller),
                       sApolloSessionPendingRestore[ApolloSessionStateFeedURLKey])) {
        ApolloLog(@"[SessionRestore] Feed changed during anchor retries; cancelling feed phase");
        ApolloSessionCancelFeedForRouteChange();
        return;
    }
    if (ApolloSessionStateViewportRestoreWasCancelled(
            detail, visible, top, inStack, underRestoredDetail, applicationActive)) {
        ApolloLog(@"[SessionRestore] %@ controller left its restore stack; cancelling phase",
                  detail ? @"Post" : @"Feed");
        if (detail) ApolloSessionFinishViewport(YES);
        else ApolloSessionCancelFeedForRouteChange();
        return;
    }
    if (detail && !visible) {
        // Backgrounding can temporarily detach the top controller's window.
        // Let its next viewDidAppear restart retries instead of leaving the
        // phase permanently started-but-unfinished.
        sApolloSessionDetailViewportStarted = NO;
        return;
    }
    if (!ApolloSessionStateViewportRestoreIsEligible(
            detail, visible, top, inStack, underRestoredDetail, applicationActive)) return;
    UITableView *table = ApolloSessionTableView(controller);
    if (table.isTracking || table.isDragging || table.isDecelerating) {
        ApolloLog(@"[SessionRestore] Reader scrolled the %@ during restore; leaving it there",
                  detail ? @"post" : @"feed");
        if (detail) ApolloSessionFinishViewport(YES);
        else ApolloSessionCancelFeedForRouteChange();
        return;
    }
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
    if (detail && settled && attempt % 4 == 3) {
        ApolloSessionRequestMoreCommentsForAnchor(controller, identifier);
    }
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

static void ApolloSessionWaitForSortedFeed(UIViewController *controller,
                                           NSString *initialFingerprint,
                                           BOOL observedContentChange,
                                           NSUInteger attempt,
                                           NSUInteger generation) {
    if (!ApolloSessionStateQueuedPhaseWorkShouldRun(
            sApolloSessionPendingRestore != nil,
            generation == sApolloSessionRestoreGeneration,
            sApolloSessionFeedViewportFinished)) return;
    NSString *savedURL = sApolloSessionPendingRestore[ApolloSessionStateFeedURLKey];
    if (!ApolloSessionStateFeedURLMatchesSavedRoute(ApolloSessionFeedURL(controller), savedURL)) {
        ApolloLog(@"[SessionRestore] Feed changed while waiting for sorted rows; cancelling feed phase");
        ApolloSessionCancelFeedForRouteChange();
        return;
    }
    NSString *currentFingerprint = ApolloSessionFeedContentFingerprint(controller);
    BOOL changed = observedContentChange ||
        ((initialFingerprint || currentFingerprint) &&
         ![initialFingerprint isEqualToString:currentFingerprint]);
    BOOL reloadWaitExpired = attempt + 1 >= kApolloSessionFeedAnchorAttempts;
    if (ApolloSessionStateSortedFeedReloadHasProducedRows(
            initialFingerprint, currentFingerprint, changed, reloadWaitExpired)) {
        ApolloSessionRestoreViewport(controller, NO, 0, generation);
        return;
    }
    if (reloadWaitExpired) {
        ApolloLog(@"[SessionRestore] Sorted feed rows did not settle; skipping stale viewport data");
        ApolloSessionFinishViewport(NO);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSessionRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloSessionWaitForSortedFeed(controller, initialFingerprint, changed,
                                       attempt + 1, generation);
    });
}

static void ApolloSessionRouteFeed(NSUInteger attempt, NSUInteger generation) {
    if (!ApolloSessionStateQueuedPhaseWorkShouldRun(
            sApolloSessionPendingRestore != nil,
            generation == sApolloSessionRestoreGeneration,
            sApolloSessionFeedViewportFinished)) return;
    if (ApolloSessionOpenURLString(sApolloSessionPendingRestore[ApolloSessionStateFeedURLKey])) return;
    if (attempt + 1 >= kApolloSessionRouteAttempts) {
        ApolloLog(@"[SessionRestore] Timed out opening saved feed");
        sApolloSessionPendingRestore = nil;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSessionRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ApolloSessionRouteFeed(attempt + 1, generation); });
}

static void ApolloSessionConsiderInitialRestore(BOOL preferLiveAccount) {
    if (!sRestoreReadingSession) {
        sApolloSessionInitialRestoreConsidered = YES;
        sApolloSessionAccountReadyRetryPending = NO;
        [[NSFileManager defaultManager] removeItemAtPath:ApolloSessionFilePath() error:nil];
        return;
    }
    if (!ApolloSessionStateAccountReadyMayRetry(
            sApolloSessionInitialRestoreConsidered,
            sApolloSessionAccountReadyRetryPending,
            preferLiveAccount)) return;
    if (sApolloSessionLaunchHasExplicitDestination) {
        sApolloSessionInitialRestoreConsidered = YES;
        sApolloSessionAccountReadyRetryPending = NO;
        ApolloLog(@"[SessionRestore] Explicit launch destination takes precedence");
        return;
    }
    if (!sApolloSessionRestoreScene) sApolloSessionRestoreScene = ApolloSessionOnlyForegroundScene();
    if (!sApolloSessionRestoreScene) return;
    NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:ApolloSessionFilePath()];
    NSDictionary *normalized = ApolloSessionStateNormalize(stored, NSDate.date,
                                                            kApolloSessionMaximumAge);
    if (!normalized) {
        sApolloSessionInitialRestoreConsidered = YES;
        sApolloSessionAccountReadyRetryPending = NO;
        return;
    }
    NSString *persistedAccountScope = ApolloSessionAccountScope(NO);
    NSString *liveAccountScope = ApolloSessionAccountScope(YES);
    // AccountManager posts its account-change notification as soon as its live
    // selection is coherent, before the defaults mirror is necessarily
    // persisted. Those account-ready callbacks prefer live identity; generic
    // lifecycle callbacks keep the persisted mirror as their primary signal.
    NSString *accountScope = ApolloSessionStatePreferredAccountScope(
        persistedAccountScope, liveAccountScope, preferLiveAccount);
    if (!accountScope) return; // The account notification will retry this path.
    sApolloSessionInitialRestoreConsidered = YES;
    if (![accountScope isEqualToString:normalized[ApolloSessionStateAccountScopeKey]]) {
        // A lifecycle callback can observe a stale defaults mirror before the
        // account-ready notification exposes the coherent live selection.
        sApolloSessionAccountReadyRetryPending = !preferLiveAccount;
        ApolloLog(@"[SessionRestore] Ignoring reading session saved for a different account");
        return;
    }
    sApolloSessionAccountReadyRetryPending = NO;
    sApolloSessionPendingRestore = normalized;
    sApolloSessionDetailRouteStarted = NO;
    sApolloSessionDetailRouteOpened = NO;
    sApolloSessionFeedViewportStarted = NO;
    sApolloSessionDetailViewportStarted = NO;
    sApolloSessionDetailControllerSeen = NO;
    sApolloSessionFeedViewportFinished = NO;
    sApolloSessionDetailViewportFinished = ![normalized[ApolloSessionStateDetailURLKey] length];
    sApolloSessionDeleteSnapshotAfterRestore = NO;
    sApolloSessionFeedSortPreparedController = nil;
    sApolloSessionPagingController = nil;
    sApolloSessionLastRequestedPage = NSNotFound;
    sApolloSessionRequestedMoreComments = [NSHashTable weakObjectsHashTable];
    sApolloSessionMoreCommentsRequestCount = 0;
    NSUInteger generation = ++sApolloSessionRestoreGeneration;
    ApolloLog(@"[SessionRestore] Cold launch has a recent reading session");
    ApolloSessionRouteFeed(0, generation);
}

void ApolloSessionRestorationSetEnabled(BOOL enabled) {
    if (enabled) return;
    sApolloSessionPendingRestore = nil;
    sApolloSessionAccountReadyRetryPending = NO;
    sApolloSessionDeleteSnapshotAfterRestore = NO;
    sApolloSessionRequestedMoreComments = nil;
    sApolloSessionMoreCommentsRequestCount = 0;
    ++sApolloSessionRestoreGeneration;
    [[NSFileManager defaultManager] removeItemAtPath:ApolloSessionFilePath() error:nil];
}

static void ApolloSessionHandleAccountReady(void) {
    if (sApolloSessionPendingRestore) {
        NSString *liveScope = ApolloSessionAccountScope(YES);
        NSString *savedScope = sApolloSessionPendingRestore[ApolloSessionStateAccountScopeKey];
        if (ApolloSessionStateShouldCancelForAccountChange(
                YES, savedScope, liveScope)) {
            ApolloLog(@"[SessionRestore] Account changed during restoration; cancelling saved session");
            sApolloSessionPendingRestore = nil;
            sApolloSessionDeleteSnapshotAfterRestore = NO;
            ++sApolloSessionRestoreGeneration;
        }
        return;
    }
    ApolloSessionConsiderInitialRestore(YES);
}

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLoad {
    NSString *candidateURL = ApolloSessionFeedURL((UIViewController *)self);
    NSString *savedURL = sApolloSessionPendingRestore[ApolloSessionStateFeedURLKey];
    if (ApolloSessionControllerOwnsRestore((UIViewController *)self) &&
        !sApolloSessionFeedViewportStarted &&
        ApolloSessionStateFeedURLMatchesSavedRoute(candidateURL, savedURL)) {
        ApolloSessionApplyFeedSort((UIViewController *)self);
        sApolloSessionFeedSortPreparedController = (UIViewController *)self;
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    if (!sApolloSessionPendingRestore || ApolloSessionControllerOwnsRestore((UIViewController *)self)) {
        sApolloSessionFeedController = (UIViewController *)self;
        sApolloSessionCommentsController = nil;
    }
    if (!ApolloSessionControllerOwnsRestore((UIViewController *)self)) return;
    NSDictionary *pending = sApolloSessionPendingRestore;
    if (pending && ApolloSessionStateFeedURLMatchesSavedRoute(
                       ApolloSessionFeedURL((UIViewController *)self),
                       pending[ApolloSessionStateFeedURLKey]) &&
        !sApolloSessionFeedViewportStarted) {
        id selfObject = (id)self;
        BOOL preparedBeforeLoad = sApolloSessionFeedSortPreparedController ==
                                  (UIViewController *)self;
        NSString *initialFingerprint = ApolloSessionFeedContentFingerprint(
            (UIViewController *)self);
        BOOL changedSort = preparedBeforeLoad ? NO :
            ApolloSessionApplyFeedSort((UIViewController *)self);
        if (changedSort && [selfObject respondsToSelector:@selector(reloadPostsWithNotification:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(selfObject,
                @selector(reloadPostsWithNotification:), nil);
        }
        sApolloSessionFeedViewportStarted = YES;
        ApolloSessionObserveReaderScroll((UIViewController *)self, NO);
        NSUInteger generation = sApolloSessionRestoreGeneration;
        ApolloSessionScheduleDetailRoute(generation);
        if (changedSort) {
            ApolloSessionWaitForSortedFeed((UIViewController *)self, initialFingerprint,
                                           NO, 0, generation);
        } else {
            ApolloSessionRestoreViewport((UIViewController *)self, NO, 0, generation);
        }
    }
}

%end

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLoad {
    NSNumber *sort = sApolloSessionPendingRestore[ApolloSessionStateDetailSortKey];
    if (ApolloSessionControllerOwnsRestore((UIViewController *)self) &&
        sApolloSessionDetailRouteStarted && !sApolloSessionDetailViewportStarted &&
        !sApolloSessionDetailViewportFinished && sort &&
        ApolloSessionCommentsControllerMatchesPendingDetail((UIViewController *)self)) {
        ApolloCommentsVCWriteCurrentSort(self, sort.longLongValue);
    }
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    sApolloSessionCommentsController = (UIViewController *)self;
    if (!ApolloSessionControllerOwnsRestore((UIViewController *)self)) return;
    NSDictionary *pending = sApolloSessionPendingRestore;
    if (pending && sApolloSessionDetailRouteStarted && !sApolloSessionDetailViewportStarted &&
        ApolloSessionCommentsControllerMatchesPendingDetail((UIViewController *)self)) {
        sApolloSessionDetailControllerSeen = YES;
        sApolloSessionDetailViewportStarted = YES;
        ApolloSessionObserveReaderScroll((UIViewController *)self, YES);
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

- (void)scene:(UIScene *)scene
 willConnectToSession:(UISceneSession *)session
             options:(UISceneConnectionOptions *)connectionOptions {
    BOOL explicitDestination = ApolloSessionStateLaunchHasExplicitDestination(
        connectionOptions.URLContexts.count,
        connectionOptions.notificationResponse != nil,
        connectionOptions.userActivities.count,
        connectionOptions.shortcutItem != nil);
    if (explicitDestination) {
        // Set this before Apollo consumes the options in %orig. Later
        // foreground/account callbacks must not route the saved session over
        // the URL, notification, Handoff activity, or quick action.
        sApolloSessionLaunchHasExplicitDestination = YES;
        sApolloSessionInitialRestoreConsidered = YES;
        sApolloSessionAccountReadyRetryPending = NO;
        sApolloSessionPendingRestore = nil;
        ++sApolloSessionRestoreGeneration;
    }
    %orig(scene, session, connectionOptions);
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    %orig;
    // The notification observer normally owns this. The scene callback is a
    // lifecycle-safe fallback for launch orders where this dylib finishes
    // loading after UIApplication posted its first active notification.
    if ([scene isKindOfClass:UIWindowScene.class] && !sApolloSessionPendingRestore &&
        !sApolloSessionInitialRestoreConsidered) {
        sApolloSessionRestoreScene = (UIWindowScene *)scene;
    }
    ApolloSessionConsiderInitialRestore(NO);
    if (sApolloSessionPendingRestore && !sApolloSessionDetailRouteStarted &&
        !sApolloSessionDetailViewportFinished &&
        [sApolloSessionPendingRestore[ApolloSessionStateDetailURLKey] length]) {
        ApolloSessionScheduleDetailRoute(sApolloSessionRestoreGeneration);
    }
}

%end


%ctor {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[
        @"com.christianselig.RedditCurrentAccountChanged",
        @"com.christianselig.RedditAccountChanged",
    ]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                         usingBlock:^(__unused NSNotification *note) {
            ApolloSessionHandleAccountReady();
        }];
    }
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ApolloSessionPersist();
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ApolloSessionConsiderInitialRestore(NO);
    }];
    [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        // A warning is not an eviction guarantee, but it is a cheap opportunity
        // to refresh the same tiny snapshot before UIKit sheds controllers.
        ApolloSessionPersist();
    }];
    ApolloLog(@"[SessionRestore] Durable reading-session hooks installed");
}
