#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const ApolloSubredditInfoUpdatedNotification;
extern NSString * const ApolloSubredditNameKey;

FOUNDATION_EXPORT NSString *ApolloSubredditFormattedMemberCount(NSInteger subscriberCount);

@interface ApolloSubredditInfo : NSObject

@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *aboutText;
@property(nonatomic, strong) NSURL *iconURL;
@property(nonatomic, strong) NSURL *bannerURL;
@property(nonatomic) NSInteger subscriberCount;
@property(nonatomic, strong) NSDate *fetchedAt;

- (instancetype)initWithSubredditName:(NSString *)subredditName
                          displayName:(NSString *)displayName
                            aboutText:(NSString *)aboutText
                              iconURL:(NSURL *)iconURL
                            bannerURL:(NSURL *)bannerURL
                      subscriberCount:(NSInteger)subscriberCount
                            fetchedAt:(NSDate *)fetchedAt;

@end

@interface ApolloSubredditInfoCache : NSObject

+ (instancetype)sharedCache;

- (ApolloSubredditInfo *)cachedInfoForSubreddit:(NSString *)subredditName;
- (void)requestInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion;
- (void)refetchInfoForSubreddit:(NSString *)subredditName completion:(void (^)(ApolloSubredditInfo *info))completion;
- (void)clearAllCaches;

@end

NS_ASSUME_NONNULL_END
