#import "settings/ApolloAutomaticBackup.h"

#import <UIKit/UIKit.h>
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloBackupRestore.h"
#import <stdlib.h>

NSNotificationName const ApolloAutomaticBackupDidChangeNotification = @"ApolloAutomaticBackupDidChangeNotification";

static NSString *const kBackupDirectoryName = @"Apollo Reborn Backups";
static NSTimeInterval const kRetryInterval = 15 * 60;
static NSUInteger const kAutomaticBackupsToKeep = 10;

@interface ApolloAutomaticBackupJob : NSObject
@property (atomic, getter=isCancelled) BOOL cancelled;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@end

@implementation ApolloAutomaticBackupJob
- (instancetype)init {
    if ((self = [super init])) _backgroundTask = UIBackgroundTaskInvalid;
    return self;
}
@end

static NSError *ApolloAutomaticBackupError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloAutomaticBackup" code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"The backup could not be completed."}];
}

static NSInteger ApolloAutomaticBackupDays(NSInteger days) {
    switch (days) {
        case 0: case 1: case 3: case 7: return days;
        default: return 3;
    }
}

static NSURL *ApolloAutomaticBackupStateURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"ApolloReborn/AutomaticBackups/state.plist"];
}

static NSURL *ApolloAutomaticBackupDirectoryURL(void) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:kBackupDirectoryName isDirectory:YES];
}

static BOOL ApolloAutomaticBackupIsArchiveName(NSString *name) {
    return [name rangeOfString:@"^Apollo_(Auto|Manual)_Backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{3,}\\.zip$"
        options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL ApolloAutomaticBackupIsAutomaticName(NSString *name) {
    return [name hasPrefix:@"Apollo_Auto_Backup_"] && ApolloAutomaticBackupIsArchiveName(name);
}

static BOOL ApolloAutomaticBackupDirectoryIsUsable(NSURL *directory, NSError **error) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:directory.path error:error];
    if ([attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) return YES;
    if (error && !*error) *error = ApolloAutomaticBackupError(@"Apollo's local backup storage is unavailable.");
    return NO;
}

static BOOL ApolloAutomaticBackupPrepareDirectory(NSError **error) {
    NSURL *directory = ApolloAutomaticBackupDirectoryURL();
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attributes = [fm attributesOfItemAtPath:directory.path error:nil];
    if (attributes) return ApolloAutomaticBackupDirectoryIsUsable(directory, error);
    return [fm createDirectoryAtURL:directory withIntermediateDirectories:NO
        attributes:@{NSFileProtectionKey: NSFileProtectionComplete, NSFilePosixPermissions: @0700}
        error:error];
}

static NSArray<NSURL *> *ApolloAutomaticBackupArchives(void) {
    NSURL *directory = ApolloAutomaticBackupDirectoryURL();
    if (!ApolloAutomaticBackupDirectoryIsUsable(directory, nil)) return @[];
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLContentModificationDateKey, NSURLFileSizeKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSURL *> *archives = [NSMutableArray array];
    for (NSURL *url in contents) {
        if (!ApolloAutomaticBackupIsArchiveName(url.lastPathComponent)) continue;
        NSNumber *regular = nil, *symlink = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (regular.boolValue && !symlink.boolValue) [archives addObject:url];
    }
    [archives sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *aDate = nil, *bDate = nil;
        [a getResourceValue:&aDate forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&bDate forKey:NSURLContentModificationDateKey error:nil];
        NSComparisonResult dateOrder = [(bDate ?: NSDate.distantPast) compare:(aDate ?: NSDate.distantPast)];
        return dateOrder != NSOrderedSame ? dateOrder
            : [b.lastPathComponent compare:a.lastPathComponent options:NSNumericSearch];
    }];
    return archives;
}

static NSString *ApolloAutomaticBackupDayString(NSDate *date) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:date];
}

static NSUInteger ApolloAutomaticBackupNextSequence(NSArray<NSURL *> *archives, NSString *day) {
    NSUInteger largest = 0;
    for (NSURL *url in archives) {
        NSString *name = url.lastPathComponent;
        NSString *prefix = [NSString stringWithFormat:@"Apollo_%@_Backup_%@_",
            [name hasPrefix:@"Apollo_Auto_"] ? @"Auto" : @"Manual", day];
        if (![name hasPrefix:prefix]) continue;
        NSString *digits = [[name substringFromIndex:prefix.length] stringByDeletingPathExtension];
        unsigned long long number = strtoull(digits.UTF8String, NULL, 10);
        if (number >= NSUIntegerMax) return 0;
        largest = MAX(largest, (NSUInteger)number);
    }
    return largest + 1;
}

static NSURL *ApolloAutomaticBackupPublish(NSURL *zip, BOOL automatic, NSDate *date,
                                           ApolloAutomaticBackupJob *job, NSError **error) {
    if (!ApolloAutomaticBackupPrepareDirectory(error)) return nil;
    NSURL *directory = ApolloAutomaticBackupDirectoryURL();
    NSUInteger sequence = ApolloAutomaticBackupNextSequence(ApolloAutomaticBackupArchives(),
        ApolloAutomaticBackupDayString(date));
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSUInteger attempt = 0; sequence && attempt < 128 && !job.isCancelled; attempt++, sequence++) {
        NSString *name = [NSString stringWithFormat:@"Apollo_%@_Backup_%@_%03lu.zip",
            automatic ? @"Auto" : @"Manual", ApolloAutomaticBackupDayString(date), (unsigned long)sequence];
        NSURL *destination = [directory URLByAppendingPathComponent:name isDirectory:NO];
        NSURL *pending = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.%@.pending", name, NSUUID.UUID.UUIDString] isDirectory:NO];
        if ([fm fileExistsAtPath:destination.path]) continue;
        NSError *copyError = nil;
        BOOL copied = [fm copyItemAtURL:zip toURL:pending error:&copyError];
        if (copied && !job.isCancelled) {
            NSError *moveError = nil;
            if ([fm moveItemAtURL:pending toURL:destination error:&moveError]) return destination;
            copyError = moveError;
        }
        [fm removeItemAtURL:pending error:nil];
        if (copyError.code != NSFileWriteFileExistsError) {
            if (error) *error = copyError;
            return nil;
        }
    }
    if (error) *error = ApolloAutomaticBackupError(job.isCancelled
        ? @"Backup was interrupted. It will be retried when Apollo is open."
        : @"Could not reserve a unique backup name. Please try again.");
    return nil;
}

static void ApolloAutomaticBackupPrune(__unused NSURL *justSaved, ApolloAutomaticBackupJob *job) {
    NSArray<NSURL *> *archives = ApolloAutomaticBackupArchives();
    NSMutableSet<NSString *> *retainedNames = [NSMutableSet set];
    for (NSURL *url in archives) {
        if (job.isCancelled) return;
        if (!ApolloAutomaticBackupIsAutomaticName(url.lastPathComponent)) continue;
        // ApolloAutomaticBackupArchives is newest-first. Count filenames rather
        // than URL object identity so the newly published URL cannot consume a
        // slot twice when Foundation returns an equivalent-but-distinct URL.
        if (retainedNames.count < kAutomaticBackupsToKeep) {
            [retainedNames addObject:url.lastPathComponent];
        }
    }
    for (NSURL *url in archives) {
        if (job.isCancelled) return;
        if (ApolloAutomaticBackupIsAutomaticName(url.lastPathComponent) &&
            ![retainedNames containsObject:url.lastPathComponent]) {
            // Every candidate is a regular, non-symlink file in the exact local
            // backup directory and matches Apollo's automatic filename grammar.
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        }
    }
}

@interface ApolloAutomaticBackup ()
@property (nonatomic, strong) NSMutableDictionary *state;
@property (nonatomic) BOOL stateLoaded;
@property (nonatomic, copy) NSString *stateReadError;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) ApolloAutomaticBackupJob *job;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL suspendedForRestore;
@end

@implementation ApolloAutomaticBackup

+ (instancetype)sharedManager {
    static ApolloAutomaticBackup *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [[self alloc] init]; });
    return manager;
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = [NSMutableDictionary dictionary];
        _workQueue = dispatch_queue_create("app.apolloreborn.automatic-backup", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)enabled { return sAutomaticBackupsEnabled; }
- (NSInteger)intervalDays { return ApolloAutomaticBackupDays(sAutomaticBackupIntervalDays); }
- (BOOL)isBackingUp { return self.job != nil; }

- (BOOL)loadStateIfNeeded {
    if (self.stateLoaded) return YES;
    if (!UIApplication.sharedApplication.isProtectedDataAvailable) return NO;
    NSURL *url = ApolloAutomaticBackupStateURL();
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!data && [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError) {
        self.stateLoaded = YES;
        self.stateReadError = nil;
        return YES;
    }
    NSDictionary *saved = data ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:&error] : nil;
    if (![saved isKindOfClass:NSDictionary.class]) {
        self.stateReadError = @"Could not read the backup configuration. Unlock the phone and reopen Apollo to try again.";
        return NO;
    }
    self.state = [saved mutableCopy];
    self.stateLoaded = YES;
    self.stateReadError = nil;
    return YES;
}

- (NSDate *)lastBackupDate {
    [self loadStateIfNeeded];
    id date = self.state[@"localLastSuccess"];
    return [date isKindOfClass:NSDate.class] ? date : nil;
}

- (NSDate *)nextBackupDate {
    if (!self.enabled) return nil;
    NSDate *last = self.lastBackupDate;
    if (!last || last.timeIntervalSinceNow > 300) return [NSDate date];
    return [last dateByAddingTimeInterval:self.intervalDays == 0 ? 60 : self.intervalDays * 24 * 60 * 60];
}

- (NSDate *)nextRetryDate {
    if (!self.enabled || self.isBackingUp || self.suspendedForRestore) return nil;
    id attempted = self.state[@"localLastAttempt"];
    if (![attempted isKindOfClass:NSDate.class] || [attempted timeIntervalSinceNow] > 300) return nil;
    NSDate *success = self.lastBackupDate;
    if (success && [success compare:attempted] != NSOrderedAscending) return nil;
    NSDate *retry = [attempted dateByAddingTimeInterval:kRetryInterval];
    NSDate *due = self.nextBackupDate;
    if (due && [due compare:retry] == NSOrderedDescending) retry = due;
    return retry.timeIntervalSinceNow > 0 ? retry : nil;
}

- (NSString *)lastErrorMessage {
    [self loadStateIfNeeded];
    if (self.stateReadError) return self.stateReadError;
    id message = self.state[@"localLastError"];
    return [message isKindOfClass:NSString.class] ? message : nil;
}

- (void)notifyChange {
    [NSNotificationCenter.defaultCenter postNotificationName:ApolloAutomaticBackupDidChangeNotification object:self];
}

- (BOOL)saveState:(NSError **)error {
    if (![self loadStateIfNeeded]) {
        if (error) *error = ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again.");
        return NO;
    }
    NSURL *url = ApolloAutomaticBackupStateURL();
    NSError *underlying = nil;
    BOOL success = [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:&underlying];
    if (success) success = [url.URLByDeletingLastPathComponent setResourceValue:@YES
        forKey:NSURLIsExcludedFromBackupKey error:&underlying];
    NSData *data = success ? [NSPropertyListSerialization dataWithPropertyList:self.state
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&underlying] : nil;
    success = data && [data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:&underlying];
    if (!success && error) *error = ApolloAutomaticBackupError(
        @"Could not save the backup configuration. Check the phone's free space and try again.");
    return success;
}

- (void)start {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
    if (self.started) return;
    self.started = YES;
    // Remove state from the discarded vault experiment. External test files are
    // user-owned and intentionally left alone.
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    [NSFileManager.defaultManager removeItemAtURL:
        [support URLByAppendingPathComponent:@"ApolloReborn/BackupVaultTest.plist"] error:nil];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationSignificantTimeChangeNotification object:nil];
    [nc addObserver:self selector:@selector(stopTimer) name:UIApplicationWillResignActiveNotification object:nil];
    [self scheduleNextCheck];
}

- (void)stopTimer { [self.timer invalidate]; self.timer = nil; }

- (void)scheduleNextCheck {
    [self stopTimer];
    UIApplication *app = UIApplication.sharedApplication;
    if (!self.started || !self.enabled || self.isBackingUp || self.suspendedForRestore ||
        app.applicationState != UIApplicationStateActive || !app.isProtectedDataAvailable) return;
    if (![self loadStateIfNeeded]) { [self notifyChange]; return; }
    NSTimeInterval delay = MAX(2, self.nextBackupDate.timeIntervalSinceNow);
    if (self.nextRetryDate) delay = MAX(delay, self.nextRetryDate.timeIntervalSinceNow);
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(__unused NSTimer *timer) {
        [weakSelf runBackupAutomatically:YES completion:nil];
    }];
    self.timer.tolerance = MIN(60, delay / 10);
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)setEnabled:(BOOL)enabled {
    if (self.isBackingUp || self.suspendedForRestore || self.enabled == enabled) return;
    sAutomaticBackupsEnabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:UDKeyAutomaticBackupsEnabled];
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)setIntervalDays:(NSInteger)days {
    if (self.isBackingUp || self.suspendedForRestore) return;
    days = ApolloAutomaticBackupDays(days);
    if (sAutomaticBackupIntervalDays == days) return;
    sAutomaticBackupIntervalDays = days;
    [NSUserDefaults.standardUserDefaults setInteger:days forKey:UDKeyAutomaticBackupIntervalDays];
    [self notifyChange];
    [self scheduleNextCheck];
}

- (ApolloAutomaticBackupJob *)beginJob {
    [self stopTimer];
    ApolloAutomaticBackupJob *job = [ApolloAutomaticBackupJob new];
    self.job = job;
    __weak typeof(self) weakSelf = self;
    job.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Apollo Settings Backup"
        expirationHandler:^{ job.cancelled = YES; [weakSelf endBackgroundTimeForJob:job]; }];
    [self notifyChange];
    return job;
}

- (void)endBackgroundTimeForJob:(ApolloAutomaticBackupJob *)job {
    if (job.backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:job.backgroundTask];
        job.backgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)finishJob:(ApolloAutomaticBackupJob *)job {
    [self endBackgroundTimeForJob:job];
    if (self.job == job) self.job = nil;
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)suspendForSettingsRestore {
    self.suspendedForRestore = YES;
    [self stopTimer];
    self.job.cancelled = YES;
}

- (void)resumeAfterFailedSettingsRestore {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self resumeAfterFailedSettingsRestore]; }); return; }
    self.suspendedForRestore = NO;
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)backUpNowWithCompletion:(void (^)(NSString *, NSError *))completion {
    [self runBackupAutomatically:NO completion:completion];
}

- (void)runBackupAutomatically:(BOOL)automatic completion:(void (^)(NSString *, NSError *))completion {
    UIApplication *app = UIApplication.sharedApplication;
    if (self.isBackingUp || self.suspendedForRestore ||
        app.applicationState != UIApplicationStateActive || !app.isProtectedDataAvailable ||
        (automatic && (!self.enabled || self.nextBackupDate.timeIntervalSinceNow > 0))) {
        if (completion) completion(nil, ApolloAutomaticBackupError(
            @"Keep Apollo open and wait for the current operation to finish, then try again."));
        [self scheduleNextCheck];
        return;
    }
    if (automatic && ![self loadStateIfNeeded]) {
        if (completion) completion(nil, ApolloAutomaticBackupError(self.stateReadError));
        return;
    }
    if (automatic) {
        self.state[@"localLastAttempt"] = NSDate.date;
        NSError *stateError = nil;
        if (![self saveState:&stateError]) {
            self.state[@"localLastError"] = stateError.localizedDescription;
            [self notifyChange];
            if (completion) completion(nil, stateError);
            return;
        }
    }
    ApolloAutomaticBackupJob *job = [self beginJob];
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            NSError *error = nil;
            NSURL *temporaryZip = nil;
            NSURL *published = nil;
            @try {
                temporaryZip = ApolloBackupRestoreCreateBackupZip(&error);
                if (temporaryZip && !job.isCancelled) {
                    published = ApolloAutomaticBackupPublish(temporaryZip, automatic, NSDate.date, job, &error);
                }
                if (published && automatic && !job.isCancelled) ApolloAutomaticBackupPrune(published, job);
            } @catch (__unused NSException *exception) {
                error = ApolloAutomaticBackupError(@"Could not complete the backup. Please try again.");
            } @finally {
                if (temporaryZip) [NSFileManager.defaultManager removeItemAtURL:temporaryZip error:nil];
            }
            if (!published || job.isCancelled) error = error ?: ApolloAutomaticBackupError(
                @"Backup was interrupted. It will be retried when Apollo is open.");
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *resultError = error;
                if (automatic && !self.suspendedForRestore && published && !job.isCancelled) {
                    self.state[@"localLastSuccess"] = NSDate.date;
                    [self.state removeObjectForKey:@"localLastError"];
                } else if (automatic && !self.suspendedForRestore) {
                    self.state[@"localLastError"] = resultError.localizedDescription;
                }
                NSError *persistError = nil;
                if (automatic && !self.suspendedForRestore && ![self saveState:&persistError] && !resultError) {
                    resultError = persistError;
                }
                [self finishJob:job];
                if (completion) completion(resultError ? nil : published.lastPathComponent, resultError);
            });
        }
    });
}

- (void)localBackupURLsWithCompletion:(void (^)(NSArray<NSURL *> *))completion {
    dispatch_async(self.workQueue, ^{
        NSArray<NSURL *> *urls = ApolloAutomaticBackupArchives();
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(urls); });
    });
}

- (void)deleteLocalBackupURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    dispatch_async(self.workQueue, ^{
        NSError *error = nil;
        NSURL *directory = ApolloAutomaticBackupDirectoryURL().URLByStandardizingPath;
        NSURL *candidate = url.URLByStandardizingPath;
        BOOL valid = candidate.isFileURL &&
            [candidate.URLByDeletingLastPathComponent.path isEqualToString:directory.path] &&
            ApolloAutomaticBackupIsArchiveName(candidate.lastPathComponent);
        if (!valid) error = ApolloAutomaticBackupError(@"That backup is no longer in Apollo's backup storage.");
        else if (![NSFileManager.defaultManager removeItemAtURL:candidate error:&error] &&
                 [error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileNoSuchFileError) error = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self notifyChange];
            if (completion) completion(error);
        });
    });
}

@end
