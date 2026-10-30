#import <Foundation/Foundation.h>

#import "ApolloSubredditAccountRefresh.h"

static void ApolloAssert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"FAIL: %@", message);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        NSMutableArray<dispatch_block_t> *scheduled = [NSMutableArray array];
        __block NSUInteger refreshCount = 0;
        ApolloSubredditAccountRefreshCoordinator *coordinator =
            [[ApolloSubredditAccountRefreshCoordinator alloc]
                initWithScheduler:^(dispatch_block_t work) {
                    [scheduled addObject:[work copy]];
                }
                refresh:^{
                    refreshCount++;
                }];

        [coordinator requestRefresh];
        [coordinator requestRefresh];
        ApolloAssert(scheduled.count == 1,
                     @"duplicate account notifications should schedule one refresh");
        ApolloAssert(refreshCount == 0,
                     @"refresh should wait for the injected scheduler");

        [coordinator disarm];
        [coordinator requestRefresh];
        ApolloAssert(scheduled.count == 1,
                     @"post-launch account changes must not add another refresh");

        dispatch_block_t firstRefresh = scheduled.firstObject;
        [scheduled removeAllObjects];
        firstRefresh();
        ApolloAssert(refreshCount == 1,
                     @"disarming must preserve the already-scheduled launch recovery");

        [coordinator requestRefresh];
        ApolloAssert(scheduled.count == 0,
                     @"the coordinator must stay disarmed after launch");
        ApolloAssert(refreshCount == 1,
                     @"later account changes must remain native-only");

        NSMutableArray<dispatch_block_t> *overlapScheduled = [NSMutableArray array];
        __block NSUInteger overlapRefreshCount = 0;
        ApolloSubredditAccountRefreshCoordinator *overlapCoordinator =
            [[ApolloSubredditAccountRefreshCoordinator alloc]
                initWithScheduler:^(dispatch_block_t work) {
                    [overlapScheduled addObject:[work copy]];
                }
                refresh:^{
                    overlapRefreshCount++;
                }];

        [overlapCoordinator requestRefresh];
        [overlapCoordinator nativeRefreshHandled];
        ApolloAssert(overlapScheduled.count == 1,
                     @"native overlap should leave one cancelable queued work item");
        dispatch_block_t canceledRefresh = overlapScheduled.firstObject;
        [overlapScheduled removeAllObjects];
        canceledRefresh();
        ApolloAssert(overlapRefreshCount == 0,
                     @"native handling during setup must cancel the added refresh");
        [overlapCoordinator requestRefresh];
        ApolloAssert(overlapScheduled.count == 0,
                     @"native handling must keep the fallback disarmed");

        NSLog(@"subreddit_account_refresh_tests: all checks passed");
    }
    return 0;
}
