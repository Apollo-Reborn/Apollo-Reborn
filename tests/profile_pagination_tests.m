#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#define ApolloLog(...) do {} while (0)

@class UINavigationController, UITabBarController;
@interface UIViewController : NSObject
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic, weak) UITabBarController *tabBarController;
@end
@implementation UIViewController
@end
@interface UINavigationController : UIViewController
@property (nonatomic, copy) NSArray *viewControllers;
@end
@implementation UINavigationController
@end
@interface UITabBarController : UIViewController
@property (nonatomic, copy) NSArray *viewControllers;
@end
@implementation UITabBarController
@end

@interface TestBatchContext : NSObject
@property (nonatomic) BOOL fetching;
@property (nonatomic) NSUInteger completions;
- (BOOL)isFetching;
- (void)completeBatchFetching:(BOOL)complete;
@end
@implementation TestBatchContext
- (BOOL)isFetching { return self.fetching; }
- (void)completeBatchFetching:(BOOL)complete {
    if (complete) { self.fetching = NO; self.completions++; }
}
@end
@interface TestTable : NSObject
@property (nonatomic, strong) TestBatchContext *batchContext;
@end
@implementation TestTable
@end
@interface TestNode : NSObject
@property (nonatomic) BOOL loaded;
@property (nonatomic, strong) TestTable *view;
- (BOOL)isNodeLoaded;
@end
@implementation TestNode
- (BOOL)isNodeLoaded { return self.loaded; }
@end

typedef void (^TestOverviewCompletion)(NSArray *, id, NSError *);
@interface RDKClient : NSObject
@property (nonatomic, copy) TestOverviewCompletion lastCompletion;
@property (nonatomic, strong) id returnTask;
- (id)overviewOfUserWithUsername:(id)username pagination:(id)pagination completion:(TestOverviewCompletion)completion;
@end
@implementation RDKClient
- (id)overviewOfUserWithUsername:(__unused id)username pagination:(__unused id)pagination completion:(TestOverviewCompletion)completion {
    self.lastCompletion = completion;
    return self.returnTask;
}
@end

@interface _TtC6Apollo21ProfileViewController : UIViewController {
    id pagination;
    TestNode *tableNode;
}
@property (nonatomic, strong) id pagination;
@property (nonatomic, strong) TestNode *tableNode;
@property (nonatomic) BOOL accountChangeReplacesPagination;
- (void)viewDidLoad;
- (void)refreshControlActivatedWithSender:(id)sender;
- (void)redditAccountChangedWithNotification:(id)notification;
@end
@implementation _TtC6Apollo21ProfileViewController
@synthesize pagination, tableNode;
- (void)viewDidLoad {}
- (void)refreshControlActivatedWithSender:(__unused id)sender { self.pagination = [NSObject new]; }
- (void)redditAccountChangedWithNotification:(__unused id)notification {
    if (self.accountChangeReplacesPagination) self.pagination = [NSObject new];
}
@end

// INCLUDE_PRODUCTION_GUARD

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void DrainMainQueue(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!done && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    Check(done, @"main-queue callback delivery drains");
}
static void OnBackground(dispatch_block_t block) {
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        block();
        dispatch_semaphore_signal(finished);
    });
    Check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
          @"background request lookup never waits for main");
}
static _TtC6Apollo21ProfileViewController *Profile(void) {
    _TtC6Apollo21ProfileViewController *profile = [_TtC6Apollo21ProfileViewController new];
    profile.pagination = [NSObject new];
    profile.tableNode = [TestNode new];
    profile.tableNode.loaded = YES;
    profile.tableNode.view = [TestTable new];
    profile.tableNode.view.batchContext = [TestBatchContext new];
    [profile viewDidLoad];
    return profile;
}

int main(void) {
    @autoreleasepool {
        RDKClient *client = [RDKClient new];
        client.returnTask = [NSObject new];
        _TtC6Apollo21ProfileViewController *profile = Profile();
        TestBatchContext *batch = profile.tableNode.view.batchContext;
        __block NSUInteger writes = 0;
        __block id receivedItems, receivedError;
        TestOverviewCompletion native = ^(NSArray *items, id next, NSError *error) {
            Check([NSThread isMainThread], @"native profile callback is on main");
            writes++;
            receivedItems = items;
            receivedError = error;
            if (!error) profile.pagination = next;
            [batch completeBatchFetching:YES];
        };

        // Real #1064 ordering: an ASDK background page starts, switching
        // accounts resets the persistent profile, then the old page arrives.
        id firstPage = profile.pagination;
        batch.fetching = YES;
        OnBackground(^{
            id task = [client overviewOfUserWithUsername:@"unused" pagination:firstPage completion:native];
            Check(task == client.returnTask, @"RDK task return value is preserved");
        });
        TestOverviewCompletion obsolete = client.lastCompletion;
        UINavigationController *navigation = [UINavigationController new];
        UITabBarController *tabs = [UITabBarController new];
        navigation.viewControllers = @[profile];
        tabs.viewControllers = @[navigation];
        profile.navigationController = navigation;
        profile.tabBarController = tabs;
        profile.accountChangeReplacesPagination = YES;
        [profile redditAccountChangedWithNotification:nil];
        Check(!batch.fetching && batch.completions == 1, @"reset releases the old batch before its response");
        id newAccountPage = profile.pagination;
        batch.fetching = YES;
        [client overviewOfUserWithUsername:nil pagination:newAccountPage completion:native];
        TestOverviewCompletion current = client.lastCompletion;
        obsolete(@[@"old account"], [NSObject new], nil);
        Check(writes == 0 && profile.pagination == newAccountPage, @"old account cannot replace pagination or mutate the native model");
        Check(batch.fetching && batch.completions == 1, @"late old response cannot finish the new account's batch");
        id nextPage = [NSObject new];
        NSArray *items = @[@"new account"];
        current(items, nextPage, nil);
        Check(writes == 1 && receivedItems == items && profile.pagination == nextPage, @"current account response passes through exactly");
        current(items, nextPage, nil);
        Check(writes == 1, @"a duplicate transport callback cannot mutate twice");

        // The accepted next-page object is published for the next background
        // ASDK request, and background completions serialize with UI resets.
        OnBackground(^{
            [client overviewOfUserWithUsername:nil pagination:nextPage completion:native];
            client.lastCompletion(@[], [NSObject new], nil);
        });
        Check(writes == 1, @"background delivery waits for main");
        DrainMainQueue();
        Check(writes == 2, @"normal pagination continues after account replacement");

        batch.fetching = YES;
        [client overviewOfUserWithUsername:nil pagination:profile.pagination completion:native];
        obsolete = client.lastCompletion;
        [profile refreshControlActivatedWithSender:nil];
        obsolete(@[@"pre-refresh"], [NSObject new], nil);
        Check(writes == 2 && !batch.fetching, @"pull to refresh retires old pages and releases fetching");

        // Error payloads and an empty end-of-list result retain their native
        // semantics. The guard does not turn errors into synthetic successes.
        [client overviewOfUserWithUsername:nil pagination:profile.pagination completion:native];
        NSError *error = [NSError errorWithDomain:@"Test" code:1 userInfo:nil];
        client.lastCompletion(nil, nil, error);
        Check(writes == 3 && receivedError == error, @"current native error is preserved");
        [client overviewOfUserWithUsername:nil pagination:profile.pagination completion:native];
        client.lastCompletion(nil, nil, nil);
        Check(writes == 4 && receivedItems == nil && profile.pagination == nil, @"end-of-list nil result is preserved");

        // Sign out can leave the old RDKPagination ivar unchanged. Epoch
        // invalidation still prevents an outstanding success from resurfacing.
        [profile refreshControlActivatedWithSender:nil];
        [client overviewOfUserWithUsername:nil pagination:profile.pagination completion:native];
        obsolete = client.lastCompletion;
        profile.accountChangeReplacesPagination = NO;
        [profile redditAccountChangedWithNotification:nil];
        obsolete(@[@"signed out"], [NSObject new], nil);
        Check(writes == 4, @"sign out rejects the old generation even when pagination is unchanged");

        // A pushed other-user profile does not reload for every account-change
        // notification; leave its request and ASDK context running in that case.
        _TtC6Apollo21ProfileViewController *other = Profile();
        __block NSUInteger otherCalls = 0;
        [client overviewOfUserWithUsername:nil pagination:other.pagination completion:^(NSArray *a, id p, NSError *e) {
            (void)a; (void)p; (void)e; otherCalls++;
        }];
        current = client.lastCompletion;
        [other redditAccountChangedWithNotification:nil];
        current(@[], nil, nil);
        Check(otherCalls == 1, @"unaffected pushed profiles retain their request");

        // Completing the native batch may start a background request before
        // the outer native completion returns. The next object must already be
        // discoverable, not merely published after the completion finishes.
        _TtC6Apollo21ProfileViewController *racing = Profile();
        __block TestOverviewCompletion following;
        __block NSUInteger followingCalls = 0;
        id proposed = [NSObject new];
        [client overviewOfUserWithUsername:nil pagination:racing.pagination completion:^(NSArray *a, id p, NSError *e) {
            (void)a; (void)e;
            racing.pagination = p;
            OnBackground(^{
                [client overviewOfUserWithUsername:nil pagination:p completion:^(NSArray *a2, id p2, NSError *e2) {
                    (void)a2; (void)p2; (void)e2; followingCalls++;
                }];
                following = client.lastCompletion;
            });
        }];
        client.lastCompletion(@[], proposed, nil);
        [racing refreshControlActivatedWithSender:nil];
        following(@[@"stale immediately scheduled page"], nil, nil);
        Check(followingCalls == 0, @"page scheduled during native completion was guarded before refresh");

        // A reentrant refresh inside a valid native completion owns the new
        // generation. Post-callback publication must not resurrect the old one.
        __block TestOverviewCompletion afterNestedReset;
        [client overviewOfUserWithUsername:nil pagination:racing.pagination completion:^(NSArray *a, id p, NSError *e) {
            (void)a; (void)e;
            racing.pagination = p;
            [racing refreshControlActivatedWithSender:nil];
            [client overviewOfUserWithUsername:nil pagination:racing.pagination completion:^(NSArray *a2, id p2, NSError *e2) {
                (void)a2; (void)p2; (void)e2; followingCalls++;
            }];
            afterNestedReset = client.lastCompletion;
        }];
        client.lastCompletion(@[], [NSObject new], nil);
        afterNestedReset(@[], nil, nil);
        Check(followingCalls == 1, @"nested reset remains current after its outer callback returns");

        // Some native reloads do not traverse the refresh-control selector.
        // A new pagination object at the next first-page request is still a
        // reset boundary, and cannot leave an old batch fetching indefinitely.
        racing.tableNode.view.batchContext.fetching = YES;
        [client overviewOfUserWithUsername:nil pagination:racing.pagination completion:^(NSArray *a, id p, NSError *e) {
            (void)a; (void)p; (void)e; followingCalls++;
        }];
        obsolete = client.lastCompletion;
        racing.pagination = [NSObject new];
        [client overviewOfUserWithUsername:nil pagination:racing.pagination completion:^(NSArray *a, id p, NSError *e) {
            (void)a; (void)p; (void)e; followingCalls++;
        }];
        Check(!racing.tableNode.view.batchContext.fetching, @"native first-page replacement releases the prior batch");
        obsolete(@[], nil, nil);
        Check(followingCalls == 1, @"implicit native reset rejects the preceding load");
        client.lastCompletion(@[], nil, nil);
        Check(followingCalls == 2, @"implicit native reset accepts its replacement load");

        // Unknown pagination belongs to some other RDK consumer, so even the
        // completion block identity and execution queue are preserved.
        TestOverviewCompletion unrelated = ^(NSArray *a, id p, NSError *e) { (void)a; (void)p; (void)e; };
        [client overviewOfUserWithUsername:nil pagination:[NSObject new] completion:unrelated];
        Check(client.lastCompletion == unrelated, @"non-profile overview consumers pass through unchanged");
        printf("PASS: %lu profile pagination checks\n", (unsigned long)checks);
    }
    return 0;
}
