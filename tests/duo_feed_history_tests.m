#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

@interface UIView : NSObject
@property(nonatomic) CGRect bounds;
@end
@implementation UIView @end
@class UINavigationController, ApolloDuoSplitState;
@interface UIViewController : NSObject
@property(nonatomic, weak) UINavigationController *navigationController;
@property(nonatomic) BOOL isEditing;
@property(nonatomic, copy) NSString *subreddit;
@end
@implementation UIViewController @end
@interface PostsController : UIViewController @end
@implementation PostsController @end
@interface CommentsController : UIViewController @end
@implementation CommentsController @end
@interface UINavigationController : UIViewController
@property(nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property(nonatomic, readonly) UIViewController *topViewController;
@property(nonatomic, weak) ApolloDuoSplitState *duoState;
@property(nonatomic) NSUInteger writes;
@property(nonatomic) BOOL lastAnimated;
@property(nonatomic, copy) void (^didSet)(void);
- (void)setViewControllers:(NSArray *)pages animated:(BOOL)animated;
@end
@implementation UINavigationController
- (UIViewController *)topViewController { return self.viewControllers.lastObject; }
- (void)setViewControllers:(NSArray *)pages animated:(BOOL)animated {
    self.viewControllers = pages;
    self.writes++;
    self.lastAnimated = animated;
    if (self.didSet) self.didSet();
}
@end
@interface UITableViewCell : NSObject
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated;
@end
@implementation UITableViewCell
- (void)setHighlighted:(__unused BOOL)highlighted animated:(__unused BOOL)animated {}
@end
@interface UITableView : NSObject
@property(nonatomic) BOOL isEditing;
@property(nonatomic, copy) NSString *selectedSubreddit;
@property(nonatomic, copy) NSArray<NSIndexPath *> *indexPathsForSelectedRows;
- (UITableViewCell *)cellForRowAtIndexPath:(NSIndexPath *)path;
- (void)deselectRowAtIndexPath:(NSIndexPath *)path animated:(BOOL)animated;
@end
@implementation UITableView
- (UITableViewCell *)cellForRowAtIndexPath:(__unused NSIndexPath *)path { return nil; }
- (void)deselectRowAtIndexPath:(__unused NSIndexPath *)path animated:(__unused BOOL)animated {}
@end
@interface ApolloDuoSplitHost : NSObject
@property(nonatomic) BOOL postsSplitEnabled;
@property(nonatomic) BOOL listVisible;
@property(nonatomic, strong) UIView *view;
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated;
@end
@implementation ApolloDuoSplitHost
- (void)setListVisible:(BOOL)visible animated:(__unused BOOL)animated { self.listVisible = visible; }
@end
@interface ApolloDuoSplitState : NSObject
@property(nonatomic, strong) UINavigationController *feed, *secondary, *primary;
@property(nonatomic, strong) NSObject *split;
@property(nonatomic, strong) ApolloDuoSplitHost *host;
@property(nonatomic) BOOL changing;
@end
@implementation ApolloDuoSplitState @end
@interface ApolloDuoFeedLinkReturn : NSObject
@property(nonatomic, copy) NSArray<UIViewController *> *detail;
@property(nonatomic, weak) UIViewController *openedFeed;
@end
@implementation ApolloDuoFeedLinkReturn @end

static Class ApolloClassPostsViewController;
static char kDuoFeedLinkReturnDetail, kDuoFeedLinkPage;
static NSObject *sDuoSplitResizingTabs;
static CGSize sDuoSplitTargetSize;
static NSIndexPath *(*sApolloDuoListWillSelectOriginal)(id, SEL, UITableView *, NSIndexPath *);
static NSUInteger syncs, detailWrites, checks, failures;
#define ApolloLog(...) ((void)0)
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { failures++; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}
static void ApolloDuoPostsSyncColumns(__unused ApolloDuoSplitState *state) { syncs++; }
static void ApolloDuoPostsSetDetail(ApolloDuoSplitState *state, UIViewController *page, __unused BOOL animated) {
    detailWrites++;
    [state.secondary setViewControllers:@[state.secondary.viewControllers.firstObject, page] animated:NO];
}
static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, __unused BOOL create) { return nav.duoState; }
static NSString *ApolloSubredditListNameAtIndexPath(UITableView *table, __unused NSIndexPath *path) { return table.selectedSubreddit; }
static NSString *ApolloNamedSubredditForPostsController(UIViewController *page) { return page.subreddit; }

// INCLUDE_PRODUCTION_HISTORY

static ApolloDuoSplitState *State(BOOL portrait) {
    ApolloDuoSplitState *state = [ApolloDuoSplitState new];
    state.split = [NSObject new];
    state.feed = [UINavigationController new];
    state.secondary = [UINavigationController new];
    state.primary = [UINavigationController new];
    for (UINavigationController *nav in @[state.feed, state.secondary, state.primary]) nav.duoState = state;
    state.host = [ApolloDuoSplitHost new];
    state.host.postsSplitEnabled = YES;
    state.host.view = [UIView new];
    state.host.view.bounds = portrait ? CGRectMake(0, 0, 700, 950) : CGRectMake(0, 0, 950, 700);
    PostsController *feed = [PostsController new];
    feed.subreddit = @"A";
    state.feed.viewControllers = @[feed];
    state.secondary.viewControllers = @[[UIViewController new]];
    return state;
}
static void SaveThread(UIViewController *feed, UIViewController *openedFeed, NSArray *detail) {
    ApolloDuoFeedLinkReturn *ret = [ApolloDuoFeedLinkReturn new];
    ret.detail = detail;
    ret.openedFeed = openedFeed;
    objc_setAssociatedObject(feed, &kDuoFeedLinkReturnDetail, ret, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL HasSavedThread(UIViewController *feed) { return objc_getAssociatedObject(feed, &kDuoFeedLinkReturnDetail) != nil; }
static void TestRestore(BOOL portrait, BOOL splitDisabled, BOOL folded, NSUInteger threadCount) {
    ApolloDuoSplitState *state = State(portrait);
    UINavigationController *navigation = state.feed;
    UIViewController *feed = navigation.topViewController;
    PostsController *opened = [PostsController new];
    NSMutableArray *thread = [NSMutableArray array];
    for (NSUInteger i = 0; i < threadCount; i++) [thread addObject:[CommentsController new]];
    SaveThread(feed, opened, thread);
    if (splitDisabled) state.host.postsSplitEnabled = NO;
    if (folded) { state.feed = nil; state.split = nil; }
    NSUInteger previous = detailWrites;
    ApolloDuoPostsRestoreFeedLinkDetail(state, navigation, feed);
    BOOL paired = !portrait && !splitDisabled && !folded;
    NSArray *restored = paired ? [state.secondary.viewControllers subarrayWithRange:NSMakeRange(1, state.secondary.viewControllers.count - 1)]
        : [navigation.viewControllers subarrayWithRange:NSMakeRange(1, navigation.viewControllers.count - 1)];
    NSString *scenario = [NSString stringWithFormat:@"portrait=%d disabled=%d folded=%d depth=%lu", portrait, splitDisabled, folded, (unsigned long)threadCount];
    Check([restored isEqualToArray:thread], [@"retained thread order and identity: " stringByAppendingString:scenario]);
    Check(!HasSavedThread(feed), @"successful restoration consumes the return record");
    Check(!state.changing, @"restoration releases the migration guard");
    Check(!navigation.lastAnimated, @"single-stack restoration does not start a second push animation");
    Check(detailWrites - previous == (paired && threadCount == 1 ? 1 : 0), @"only paired single threads use the column animation");
    Check(ApolloDuoFeedStackKeptCount(navigation) == 1, @"comments remain outside the retained feed prefix");
    NSArray *before = navigation.viewControllers;
    ApolloDuoPostsRestoreFeedLinkDetail(state, navigation, feed);
    Check([navigation.viewControllers isEqualToArray:before], @"a repeated callback cannot append the thread twice");
}
static void TestGuards(void) {
    ApolloDuoSplitState *state = State(YES);
    UIViewController *feed = state.feed.topViewController;
    UIViewController *opened = [PostsController new], *thread = [CommentsController new];
    SaveThread(feed, opened, @[thread]);
    state.feed.viewControllers = @[feed, opened];
    ApolloDuoPostsRestoreFeedLinkDetail(state, state.feed, feed);
    Check(HasSavedThread(feed) && state.feed.writes == 0, @"a hidden feed is not a Back destination");
    state.feed.viewControllers = @[opened, feed];
    ApolloDuoPostsRestoreFeedLinkDetail(state, state.feed, feed);
    Check(HasSavedThread(feed) && state.feed.writes == 0, @"an opened feed still in history prevents premature restoration");
    state.feed.viewControllers = @[feed];
    state.changing = YES;
    ApolloDuoPostsRestoreFeedLinkDetail(state, state.feed, feed);
    Check(HasSavedThread(feed) && state.feed.writes == 0, @"column migration retains the pending record");
    state.changing = NO;
    state.secondary.viewControllers = @[feed];
    ApolloDuoPostsRestoreFeedLinkDetail(state, state.secondary, feed);
    Check(HasSavedThread(feed) && state.secondary.writes == 0, @"another pane cannot consume feed history");
    state.host.view.bounds = CGRectMake(0, 0, 950, 700);
    state.secondary.viewControllers = @[];
    ApolloDuoPostsRestoreFeedLinkDetail(state, state.feed, feed);
    Check(HasSavedThread(feed), @"a missing column backstop does not discard the thread");
    state.host.view.bounds = CGRectMake(0, 0, 700, 950);
    __weak ApolloDuoSplitState *weakState = state;
    __weak UIViewController *weakFeed = feed;
    state.feed.didSet = ^{ ApolloDuoPostsRestoreFeedLinkDetail(weakState, weakState.feed, weakFeed); };
    ApolloDuoPostsRestoreFeedLinkDetail(state, state.feed, feed);
    Check(state.feed.viewControllers.count == 2 && state.feed.topViewController == thread, @"synchronous navigation callbacks do not duplicate history");
}
static void TestDrawer(void) {
    ApolloDuoSplitState *state = State(NO);
    UIViewController *a = state.feed.topViewController;
    PostsController *b = [PostsController new]; b.subreddit = @"B";
    CommentsController *comments = [CommentsController new];
    UIViewController *list = [UIViewController new]; list.navigationController = state.primary;
    UITableView *table = [UITableView new];
    NSIndexPath *path = [NSIndexPath indexPathWithIndex:1];
    for (NSArray *pages in @[@[a, b], @[a, b, comments]]) {
        state.feed.viewControllers = pages;
        state.host.listVisible = YES;
        table.selectedSubreddit = @"A";
        Check(ApolloDuoListWillSelect(list, NULL, table, path) == path, @"the drawer can select an older retained feed");
        table.selectedSubreddit = @"b";
        Check(ApolloDuoListWillSelect(list, NULL, table, path) == nil, @"the drawer suppresses reselection of the visible feed, case-insensitively");
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        Check(!state.host.listVisible, @"current-feed reselection dismisses the drawer");
        Check([state.feed.viewControllers isEqualToArray:pages], @"reselection preserves feed and thread controllers");
    }
    state.host.listVisible = YES;
    list.isEditing = YES;
    Check(ApolloDuoListWillSelect(list, NULL, table, path) == path, @"editing retains native selection behavior");
    list.isEditing = NO;
    state.feed.viewControllers = @[];
    Check(ApolloDuoListWillSelect(list, NULL, table, path) == path, @"an empty feed stack safely passes selection through");
}
int main(void) { @autoreleasepool {
    ApolloClassPostsViewController = PostsController.class;
    for (NSNumber *depth in @[@1, @2]) {
        TestRestore(NO, NO, NO, depth.unsignedIntegerValue);
        TestRestore(YES, NO, NO, depth.unsignedIntegerValue);
        TestRestore(NO, YES, NO, depth.unsignedIntegerValue);
        TestRestore(NO, NO, YES, depth.unsignedIntegerValue);
    }
    TestGuards();
    TestDrawer();
    printf("Duo feed history: %lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    return failures ? 1 : 0;
} }
