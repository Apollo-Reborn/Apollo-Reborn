// Interval-based settings archives stored inside Apollo's local container.
// Scheduling and UI-facing state are main-thread owned; compression and local
// filesystem work run on a serial worker queue.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS
extern NSNotificationName const ApolloAutomaticBackupDidChangeNotification;
__END_DECLS

@interface ApolloAutomaticBackup : NSObject
+ (instancetype)sharedManager;

// Called after the tweak's defaults and account-recovery setup have loaded.
- (void)start;
- (void)suspendForSettingsRestore;
- (void)resumeAfterFailedSettingsRestore;

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) NSInteger intervalDays;
@property (nonatomic, readonly, getter=isBackingUp) BOOL backingUp;
@property (nonatomic, readonly, nullable) NSDate *lastBackupDate;
@property (nonatomic, readonly, nullable) NSDate *nextBackupDate;
// Future retry eligibility while an automatic failure is in backoff; otherwise nil.
@property (nonatomic, readonly, nullable) NSDate *nextRetryDate;
@property (nonatomic, readonly, nullable) NSString *lastErrorMessage;

- (void)setEnabled:(BOOL)enabled;
- (void)setIntervalDays:(NSInteger)days; // test: 0 = 1 minute; production: 1, 3, 7 days
// Successful completion includes the actual archive filename saved by Files.
- (void)backUpNowWithCompletion:(void (^)(NSString *_Nullable filename, NSError *_Nullable error))completion;

// Local archives are returned newest first. Public completions are delivered on
// the main queue and URLs never leave Apollo's backup directory.
- (void)localBackupURLsWithCompletion:(void (^)(NSArray<NSURL *> *urls))completion;
- (void)deleteLocalBackupURL:(NSURL *)url completion:(void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
