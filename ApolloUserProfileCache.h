#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString * const ApolloUserProfileInfoUpdatedNotification;
extern NSString * const ApolloUserProfileUsernameKey;

@interface ApolloUserProfileInfo : NSObject

@property(nonatomic, copy) NSString *username;
@property(nonatomic, strong) NSURL *iconURL;
@property(nonatomic, strong) NSURL *bannerURL;
@property(nonatomic, strong) NSURL *snoovatarURL;
@property(nonatomic, strong) NSURL *decoratorURL;
@property(nonatomic, strong) NSDate *fetchedAt;
@property(nonatomic, copy) NSString *avatarFrameKind;
@property(nonatomic) BOOL defaultSnoo;
@property(nonatomic) BOOL hasSnoovatar;

- (instancetype)initWithUsername:(NSString *)username
                          iconURL:(NSURL *)iconURL
                        bannerURL:(NSURL *)bannerURL
                       defaultSnoo:(BOOL)defaultSnoo
                        fetchedAt:(NSDate *)fetchedAt;

@end

@interface ApolloUserProfileCache : NSObject

+ (instancetype)sharedCache;

- (ApolloUserProfileInfo *)cachedInfoForUsername:(NSString *)username;
- (void)requestInfoForUsername:(NSString *)username completion:(void (^)(ApolloUserProfileInfo *info))completion;
- (void)refetchInfoForUsername:(NSString *)username completion:(void (^)(ApolloUserProfileInfo *info))completion;

- (UIImage *)cachedImageForURL:(NSURL *)url;
- (void)requestImageForURL:(NSURL *)url completion:(void (^)(UIImage *image))completion;

- (void)clearAllCaches;

@end