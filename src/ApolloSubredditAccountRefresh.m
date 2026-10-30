#import "ApolloSubredditAccountRefresh.h"

@interface ApolloSubredditAccountRefreshCoordinator ()
@property (nonatomic, copy) ApolloSubredditAccountRefreshScheduler scheduler;
@property (nonatomic, copy) dispatch_block_t refresh;
@property (nonatomic, assign) BOOL acceptingRequests;
@property (nonatomic, assign) BOOL refreshScheduled;
@end

@implementation ApolloSubredditAccountRefreshCoordinator

- (instancetype)initWithScheduler:(ApolloSubredditAccountRefreshScheduler)scheduler
                           refresh:(dispatch_block_t)refresh {
    NSParameterAssert(scheduler);
    NSParameterAssert(refresh);
    self = [super init];
    if (self) {
        _scheduler = [scheduler copy];
        _refresh = [refresh copy];
        _acceptingRequests = YES;
    }
    return self;
}

- (void)requestRefresh {
    ApolloSubredditAccountRefreshScheduler scheduler = nil;
    @synchronized (self) {
        if (!self.acceptingRequests || self.refreshScheduled) return;
        self.refreshScheduled = YES;
        scheduler = self.scheduler;
    }

    __weak typeof(self) weakSelf = self;
    scheduler(^{
        [weakSelf runScheduledRefresh];
    });
}

- (void)disarm {
    @synchronized (self) {
        self.acceptingRequests = NO;
    }
}

- (void)nativeRefreshHandled {
    @synchronized (self) {
        self.acceptingRequests = NO;
        self.refreshScheduled = NO;
    }
}

- (void)runScheduledRefresh {
    dispatch_block_t refresh = nil;
    @synchronized (self) {
        if (!self.refreshScheduled) return;
        self.refreshScheduled = NO;
        refresh = self.refresh;
    }
    refresh();
}

@end
