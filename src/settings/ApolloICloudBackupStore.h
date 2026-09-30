#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloICloudBackupAvailability) {
    ApolloICloudBackupAvailabilityUnknown = 0,
    ApolloICloudBackupAvailabilityAvailable,
    ApolloICloudBackupAvailabilityMissingEntitlement,
    ApolloICloudBackupAvailabilityAccountUnavailable,
};

__BEGIN_DECLS
extern NSNotificationName const ApolloICloudBackupStoreDidChangeNotification;
__END_DECLS

// Owns the iCloud Drive seam. Every public completion returns on main. The
// backup engine remains unaware of iCloud and continues to create/restore the
// same .apollobackup archives.
@interface ApolloICloudBackupStore : NSObject
+ (instancetype)sharedStore;

@property (nonatomic, readonly) ApolloICloudBackupAvailability availability;
@property (nonatomic, readonly, copy) NSString *availabilityDescription;
@property (nonatomic, readonly, getter=isWorking) BOOL working;
@property (nonatomic, readonly, copy, nullable) NSString *scopeIdentifier;
@property (nonatomic, readonly, copy, nullable) NSString *selectedFolderName;

- (void)refreshAvailabilityWithCompletion:(nullable void (^)(void))completion;
- (void)selectFolderURL:(NSURL *)folderURL completion:(void (^)(NSError *_Nullable error))completion;
- (void)uploadLocalBackupURL:(NSURL *)localURL
               expectedScope:(nullable NSString *)expectedScope
               identityToken:(NSString *)identityToken
                  completion:(nullable void (^)(NSURL *_Nullable cloudURL, NSError *_Nullable error))completion;
- (void)backupURLsWithCompletion:(void (^)(NSArray<NSURL *> *urls, NSError *_Nullable error))completion;

// Downloads if needed and returns a protected local copy suitable for the
// existing restore validator. The caller owns cleanup of the returned URL.
- (void)prepareLocalCopyOfBackupURL:(NSURL *)cloudURL
                         completion:(void (^)(NSURL *_Nullable localURL, NSError *_Nullable error))completion;
- (void)deleteBackupURL:(NSURL *)cloudURL
             completion:(nullable void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
