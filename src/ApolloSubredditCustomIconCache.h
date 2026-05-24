#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const ApolloSubredditCustomIconChangedNotification;
FOUNDATION_EXPORT NSString *const ApolloSubredditCustomIconSubredditNameKey;

@interface ApolloSubredditCustomIconCache : NSObject

+ (instancetype)sharedCache;

- (nullable UIImage *)cachedIconForSubreddit:(NSString *)subredditName;
- (BOOL)hasCustomIconForSubreddit:(NSString *)subredditName;
- (BOOL)saveIcon:(UIImage *)image forSubreddit:(NSString *)subredditName error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeIconForSubreddit:(NSString *)subredditName;
- (void)clearAllCustomIcons;
- (NSUInteger)customIconCount;

@end

NS_ASSUME_NONNULL_END
