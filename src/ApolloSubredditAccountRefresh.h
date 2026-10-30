#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ApolloSubredditAccountRefreshScheduler)(dispatch_block_t work);

/// Coalesces account-change notifications until their scheduled list refresh runs.
/// Apollo emits both the broad and current-account notifications for one change,
/// so refreshing directly from each observer would start the same network load twice.
@interface ApolloSubredditAccountRefreshCoordinator : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithScheduler:(ApolloSubredditAccountRefreshScheduler)scheduler
                           refresh:(dispatch_block_t)refresh NS_DESIGNATED_INITIALIZER;
- (void)requestRefresh;
- (void)disarm;
- (void)nativeRefreshHandled;

@end

NS_ASSUME_NONNULL_END
