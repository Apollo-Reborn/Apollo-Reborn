// Interval-based settings archives. Scheduling and UI-facing state are main-thread
// owned; archive compression and coordinated Files-provider I/O run off main.
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
@property (nonatomic, readonly) BOOL usesSelectedFolder;
@property (nonatomic, readonly) NSString *destinationName;
@property (nonatomic, readonly) BOOL hasSavedFolder;
@property (nonatomic, readonly, nullable) NSString *savedFolderName;
@property (nonatomic, readonly, nullable) NSDate *lastBackupDate;
@property (nonatomic, readonly, nullable) NSDate *nextBackupDate;
// Future retry eligibility while an automatic failure is in backoff; otherwise nil.
@property (nonatomic, readonly, nullable) NSDate *nextRetryDate;
@property (nonatomic, readonly, nullable) NSString *lastErrorMessage;

- (void)setEnabled:(BOOL)enabled;
- (void)setIntervalDays:(NSInteger)days; // supported values: 1, 3, 7
// Resolves the actual backup directory for an in-app Files browser or restore picker.
// This does not change the selected destination or its backup schedule.
- (void)selectedFolderURLWithCompletion:(void (^)(NSURL *_Nullable folderURL, NSError *_Nullable error))completion;
// Cancel outstanding folder-browser requests without interrupting backup jobs.
- (void)cancelFolderResolution;
// Pass the original exported directory URL from the Files Save callback.
// The returned directory itself becomes the destination, including provider renames.
// Completion, like every public completion below, is delivered on the main queue.
- (void)selectFolderURL:(NSURL *)url completion:(void (^)(NSError *_Nullable error))completion;
// Successful completion includes the actual archive filename saved by Files.
- (void)backUpNowWithCompletion:(void (^)(NSString *_Nullable filename, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
