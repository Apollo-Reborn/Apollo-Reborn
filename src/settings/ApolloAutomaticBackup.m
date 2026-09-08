#import "settings/ApolloAutomaticBackup.h"

#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdlib.h>
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloBackupRestore.h"

NSNotificationName const ApolloAutomaticBackupDidChangeNotification = @"ApolloAutomaticBackupDidChangeNotification";

static NSString *const kBackupDirectoryName = @"Apollo Reborn Backups";
static NSTimeInterval const kRetryInterval = 15 * 60;
static NSUInteger const kBackupsToKeep = 10;
static NSTimeInterval const kFolderReadTimeout = 15;

// A job can be cancelled by expiration or restore without waiting for the worker:
// archive capture sometimes dispatches to main, so waiting here would deadlock.
@interface ApolloAutomaticBackupJob : NSObject
@property (atomic, getter=isCancelled) BOOL cancelled;
@property (atomic, strong) NSFileCoordinator *coordinator;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
- (void)cancel;
@end

@implementation ApolloAutomaticBackupJob
- (instancetype)init {
    if ((self = [super init])) _backgroundTask = UIBackgroundTaskInvalid;
    return self;
}
- (void)cancel {
    self.cancelled = YES;
    [self.coordinator cancel];
}
@end

static NSError *ApolloAutomaticBackupError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloAutomaticBackup" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSInteger ApolloAutomaticBackupDays(NSInteger days) {
    switch (days) {
        case 1: case 3: case 7: return days;
        default: return 3;
    }
}

static NSURL *ApolloAutomaticBackupStateURL(void) {
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"ApolloReborn/AutomaticBackups/state.plist"];
}

static BOOL ApolloAutomaticBackupDirectoryIsUsable(NSURL *directory, NSError **error) {
    // attributesOfItemAtPath reports a final symlink itself, rather than following
    // it. Do not let a replaced backup subfolder redirect writes or retention.
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:directory.path error:error];
    if ([attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) return YES;
    if (error) *error = ApolloAutomaticBackupError(@"The backup folder is unavailable. Choose a folder again in Files.");
    return NO;
}

// Coordinate each affected item that Files may be reading.
// A coordinated write to an ordinary directory does not lock its descendants.
// These helpers finish their coordination before a caller starts another one.
static BOOL ApolloAutomaticBackupReadItem(
    NSURL *url, ApolloAutomaticBackupJob *job, NSError **outError,
    BOOL (^accessor)(NSURL *coordinatedURL, NSError **error)) {
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    job.coordinator = coordinator;
    __block BOOL success = NO;
    __block NSError *workError = nil;
    NSError *coordinationError = nil;
    @try {
        if (!job.isCancelled) {
            [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError byAccessor:^(NSURL *newURL) {
                if (!job.isCancelled) success = accessor(newURL, &workError);
            }];
        }
    } @finally {
        job.coordinator = nil;
    }
    if (coordinationError || !success) {
        if (outError) *outError = workError ?: ApolloAutomaticBackupError(
            job.isCancelled ? @"Backup was interrupted. It will be retried when Apollo is open."
                            : @"The backup folder is unavailable. Reconnect it or choose a folder again in Files.");
        return NO;
    }
    return YES;
}

static BOOL ApolloAutomaticBackupWriteItems(
    NSURL *url, NSFileCoordinatorWritingOptions options,
    NSURL *secondURL, NSFileCoordinatorWritingOptions secondOptions,
    ApolloAutomaticBackupJob *job, NSError **outError,
    BOOL (^accessor)(NSURL *coordinatedURL, NSURL *coordinatedSecondURL, NSError **error)) {
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    job.coordinator = coordinator;
    __block BOOL success = NO;
    __block NSError *workError = nil;
    NSError *coordinationError = nil;
    @try {
        if (!job.isCancelled) {
            if (secondURL) {
                [coordinator coordinateWritingItemAtURL:url options:options
                                      writingItemAtURL:secondURL options:secondOptions
                                                 error:&coordinationError
                                            byAccessor:^(NSURL *newURL, NSURL *newSecondURL) {
                    if (!job.isCancelled) success = accessor(newURL, newSecondURL, &workError);
                }];
            } else {
                [coordinator coordinateWritingItemAtURL:url options:options error:&coordinationError
                                            byAccessor:^(NSURL *newURL) {
                    if (!job.isCancelled) success = accessor(newURL, nil, &workError);
                }];
            }
        }
    } @finally {
        job.coordinator = nil;
    }
    if (coordinationError || !success) {
        if (outError) *outError = workError ?: ApolloAutomaticBackupError(
            job.isCancelled ? @"Backup was interrupted. It will be retried when Apollo is open."
                            : @"The backup folder is unavailable. Reconnect it or choose a folder again in Files.");
        return NO;
    }
    return YES;
}

// Short names are user-facing only; ownership comes from this installation's
// private ledger. A content fingerprint prevents a reused name from authorizing
// deletion of a replacement file saved by another installation.
static BOOL ApolloAutomaticBackupIsShortArchiveName(NSString *name) {
    return [name rangeOfString:@"^Apollo_(Auto|Manual)_Backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{3,}\\.zip$"
        options:NSRegularExpressionSearch].location != NSNotFound;
}

static NSData *ApolloAutomaticBackupFingerprint(NSURL *url, ApolloAutomaticBackupJob *job, NSError **error) {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    BOOL success = YES;
    for (;;) {
        if (job.isCancelled) { success = NO; break; }
        NSInteger length = [stream read:buffer maxLength:sizeof(buffer)];
        if (length == 0) break;
        if (length < 0) {
            if (error) *error = stream.streamError;
            success = NO;
            break;
        }
        CC_SHA256_Update(&context, buffer, (CC_LONG)length);
    }
    [stream close];
    if (!success) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(hash, &context);
    return [NSData dataWithBytes:hash length:sizeof(hash)];
}

static NSMutableDictionary *ApolloAutomaticBackupOwnershipRecords(id stored) {
    NSMutableDictionary *records = [NSMutableDictionary dictionary];
    if (![stored isKindOfClass:NSDictionary.class]) return records;
    for (id name in stored) {
        if (![name isKindOfClass:NSString.class] || ![name hasPrefix:@"Apollo_Auto_Backup_"] ||
            !ApolloAutomaticBackupIsShortArchiveName(name)) continue;
        id record = stored[name];
        if (![record isKindOfClass:NSDictionary.class]) continue;
        id hash = record[@"sha256"], date = record[@"savedAt"];
        if ([hash isKindOfClass:NSData.class] && [hash length] == CC_SHA256_DIGEST_LENGTH &&
            [date isKindOfClass:NSDate.class]) records[name] = record;
    }
    return records;
}

static NSString *ApolloAutomaticBackupDayString(NSDate *date) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:date];
}

// Share a daily sequence across automatic/manual backups and count every matching
// name, regardless of owner or file type. Never reuse an existing file's number.
static NSUInteger ApolloAutomaticBackupNextSequence(NSArray<NSString *> *names, NSString *day) {
    NSUInteger largest = 0;
    for (NSString *name in names) {
        if (!ApolloAutomaticBackupIsShortArchiveName(name)) continue;
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

static NSURL *ApolloAutomaticBackupPublish(NSURL *zip, NSURL *directory, BOOL automatic,
                                          NSDate *date, ApolloAutomaticBackupJob *job, NSError **error) {
    __block NSArray<NSString *> *names = nil;
    if (!ApolloAutomaticBackupReadItem(directory, job, error, ^BOOL(NSURL *newDirectory, NSError **readError) {
        if (!ApolloAutomaticBackupDirectoryIsUsable(newDirectory, readError)) return NO;
        names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:newDirectory.path error:readError];
        return names != nil;
    })) return nil;
    NSString *day = ApolloAutomaticBackupDayString(date);
    NSUInteger sequence = ApolloAutomaticBackupNextSequence(names, day);
    // Coordination serializes cooperating providers; the filesystem's no-overwrite
    // move also catches a competing writer that creates a name after enumeration.
    for (NSUInteger retry = 0; sequence && retry < 128 && !job.isCancelled; retry++, sequence++) {
        NSString *name = [NSString stringWithFormat:@"Apollo_%@_Backup_%@_%03lu.zip",
            automatic ? @"Auto" : @"Manual", day, (unsigned long)sequence];
        NSURL *destination = [directory URLByAppendingPathComponent:name];
        NSURL *pending = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.%@.pending", name, NSUUID.UUID.UUIDString]];
        __block NSURL *published = nil;
        __block BOOL collision = NO;
        NSError *publishError = nil;
        BOOL success = ApolloAutomaticBackupWriteItems(pending, NSFileCoordinatorWritingForMoving,
            destination, 0, job, &publishError, ^BOOL(NSURL *newPending, NSURL *newDestination, NSError **writeError) {
                NSFileManager *fm = NSFileManager.defaultManager;
                NSURL *parent = newPending.URLByDeletingLastPathComponent;
                if (!ApolloAutomaticBackupDirectoryIsUsable(parent, writeError) ||
                    ![parent.URLByStandardizingPath.path isEqualToString:
                        newDestination.URLByDeletingLastPathComponent.URLByStandardizingPath.path]) {
                    if (writeError) *writeError = ApolloAutomaticBackupError(@"The backup folder moved. Please try again.");
                    return NO;
                }
                if ([fm attributesOfItemAtPath:newDestination.path error:nil]) {
                    collision = YES;
                    return NO;
                }
                @try {
                    if (![fm copyItemAtURL:zip toURL:newPending error:writeError]) return NO;
                    if (job.isCancelled) return NO;
                    NSFileCoordinator *coordinator = job.coordinator;
                    [coordinator itemAtURL:newPending willMoveToURL:newDestination];
                    NSError *moveError = nil;
                    if (![fm moveItemAtURL:newPending toURL:newDestination error:&moveError]) {
                        collision = [moveError.domain isEqualToString:NSCocoaErrorDomain] &&
                            moveError.code == NSFileWriteFileExistsError;
                        if (writeError) *writeError = moveError;
                        return NO;
                    }
                    [coordinator itemAtURL:newPending didMoveToURL:newDestination];
                    published = newDestination;
                    return YES;
                } @finally {
                    [fm removeItemAtURL:newPending error:nil];
                }
            });
        if (success) return published;
        if (!collision) {
            if (error) *error = publishError;
            return nil;
        }
    }
    if (error) *error = ApolloAutomaticBackupError(job.isCancelled
        ? @"Backup was interrupted. It will be retried when Apollo is open."
        : @"Could not reserve a unique backup name. Please try again.");
    return nil;
}

static void ApolloAutomaticBackupPrune(NSURL *directory, NSURL *justSaved, NSMutableDictionary *ownership,
                                      ApolloAutomaticBackupJob *job) {
    __block NSArray<NSURL *> *contents = nil;
    if (!ApolloAutomaticBackupReadItem(directory, job, nil, ^BOOL(NSURL *newDirectory, NSError **error) {
        if (!ApolloAutomaticBackupDirectoryIsUsable(newDirectory, error)) return NO;
        contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:newDirectory
            includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:error];
        return contents != nil;
    })) return;
    NSSet *existingNames = [NSSet setWithArray:[contents valueForKey:@"lastPathComponent"]];
    for (NSString *name in ownership.allKeys) {
        if (![existingNames containsObject:name]) [ownership removeObjectForKey:name];
    }
    NSMutableArray<NSDictionary *> *archives = [NSMutableArray array];
    for (NSURL *url in contents) {
        if (job.isCancelled) return;
        NSString *name = url.lastPathComponent;
        // Older UUID-named archives labeled manual runs as Auto too. Preserve
        // every ambiguous legacy archive rather than risk pruning a manual one.
        if (![name hasPrefix:@"Apollo_Auto_Backup_"] || !ApolloAutomaticBackupIsShortArchiveName(name)) continue;
        NSDictionary *record = ownership[name];
        if (!record) continue;
        __block BOOL replaced = NO;
        BOOL owned = ApolloAutomaticBackupReadItem(url, job, nil, ^BOOL(NSURL *newURL, NSError **readError) {
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:newURL.path error:readError];
            if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) return NO;
            NSData *hash = ApolloAutomaticBackupFingerprint(newURL, job, readError);
            replaced = hash && ![hash isEqual:record[@"sha256"]];
            return hash && !replaced;
        });
        if (replaced) [ownership removeObjectForKey:name];
        if (!owned) continue;
        [archives addObject:@{@"url": url, @"date": record[@"savedAt"]}];
    }
    [archives sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult dateOrder = [b[@"date"] compare:a[@"date"]];
        return dateOrder != NSOrderedSame ? dateOrder
            : [[b[@"url"] lastPathComponent] compare:[a[@"url"] lastPathComponent] options:NSNumericSearch];
    }];
    // Keep the new automatic archive even after a clock correction. Manual
    // archives never consume an automatic retention slot or become candidates.
    BOOL justSavedIsAutomatic = [justSaved.lastPathComponent hasPrefix:@"Apollo_Auto_Backup_"] &&
        ApolloAutomaticBackupIsShortArchiveName(justSaved.lastPathComponent);
    NSUInteger retained = justSavedIsAutomatic ? 1 : 0;
    for (NSDictionary *archive in archives) {
        if (job.isCancelled) return;
        NSURL *url = archive[@"url"];
        NSString *name = url.lastPathComponent;
        if ([name isEqualToString:justSaved.lastPathComponent]) continue;
        if (retained++ < kBackupsToKeep) continue;
        NSDictionary *record = ownership[name];
        __block BOOL noLongerOwned = NO;
        NSError *error = nil;
        BOOL removed = ApolloAutomaticBackupWriteItems(url, NSFileCoordinatorWritingForDeleting, nil, 0,
            job, &error, ^BOOL(NSURL *newURL, __unused NSURL *unused, NSError **deleteError) {
                if (!ApolloAutomaticBackupDirectoryIsUsable(newURL.URLByDeletingLastPathComponent, deleteError)) return NO;
                NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:newURL.path error:deleteError];
                if (!attributes) return YES;
                if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
                    ![newURL.lastPathComponent isEqualToString:name] ||
                    ![newURL.URLByDeletingLastPathComponent.URLByStandardizingPath.path isEqualToString:
                        directory.URLByStandardizingPath.path]) return YES;
                NSData *hash = ApolloAutomaticBackupFingerprint(newURL, job, deleteError);
                if (!hash) return NO;
                if (![hash isEqual:record[@"sha256"]]) { noLongerOwned = YES; return YES; }
                return !job.isCancelled && [NSFileManager.defaultManager removeItemAtURL:newURL error:deleteError];
            });
        if (removed || noLongerOwned) [ownership removeObjectForKey:name];
        else ApolloLog(@"[AutomaticBackup] Could not prune an older archive (code %ld)", (long)error.code);
    }
}

// Folder URLs from the iOS picker carry sandbox permission, even when no app-owned
// iCloud container exists. Minimal bookmarks preserve that permission on iOS;
// NSURLBookmarkCreationWithSecurityScope is a macOS-only option.
// Hold scope across the whole operation, but coordinate directory preparation,
// archive publication, and each retention deletion separately. Never wait for a
// provider on the main thread, and never nest coordinated-write accessors.
static BOOL ApolloAutomaticBackupInDirectory(
    NSURL *root, BOOL rootIsBackupDirectory, ApolloAutomaticBackupJob *job, NSError **outError,
    BOOL (^accessor)(NSURL *directory, NSError **error)) {
    if (!root.isFileURL) {
        if (outError) *outError = ApolloAutomaticBackupError(@"Choose the backup folder again in Files.");
        return NO;
    }
    BOOL scoped = [root startAccessingSecurityScopedResource];
    BOOL success = NO;
    NSError *workError = nil;
    @try {
        __block NSURL *directory = nil;
        BOOL rootReady = ApolloAutomaticBackupReadItem(root, job, &workError, ^BOOL(NSURL *newRoot, NSError **readError) {
            if (!ApolloAutomaticBackupDirectoryIsUsable(newRoot, readError)) return NO;
            directory = rootIsBackupDirectory ? newRoot
                : [newRoot URLByAppendingPathComponent:kBackupDirectoryName isDirectory:YES];
            return YES;
        });
        // A directly selected/exported directory already exists and its scope
        // need not permit inspecting the parent. Only legacy parent selections
        // require creating the backup subdirectory.
        BOOL directoryReady = rootReady && (rootIsBackupDirectory || ApolloAutomaticBackupWriteItems(directory, 0, nil, 0,
            job, &workError, ^BOOL(NSURL *newDirectory, __unused NSURL *unused, NSError **createError) {
                NSFileManager *fm = NSFileManager.defaultManager;
                if (!ApolloAutomaticBackupDirectoryIsUsable(newDirectory.URLByDeletingLastPathComponent, createError)) return NO;
                NSDictionary *existing = [fm attributesOfItemAtPath:newDirectory.path error:nil];
                if (!existing) {
                    if (![fm createDirectoryAtURL:newDirectory withIntermediateDirectories:NO
                                       attributes:nil error:createError]) return NO;
                }
                if (!ApolloAutomaticBackupDirectoryIsUsable(newDirectory, createError)) return NO;
                directory = newDirectory;
                return YES;
            }));
        if (directoryReady && !job.isCancelled) {
            success = accessor(directory, &workError);
        }
    } @finally {
        // A resolved bookmark can be usable even when startAccessing returns NO.
        // Trust the actual coordinated I/O result, and balance only a YES start.
        if (scoped) [root stopAccessingSecurityScopedResource];
    }
    if (!success && outError) {
        *outError = workError ?: ApolloAutomaticBackupError(@"Backup was interrupted. It will be retried when Apollo is open.");
    }
    return success;
}

// An access lease owns exactly one startAccessing acquisition until it is either
// transferred to the manager's live cache or released, including timeout paths.
@interface ApolloAutomaticBackupFolderLease : NSObject
@property (nonatomic, strong) NSURL *root;
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) NSData *refreshedBookmark;
@property (nonatomic, strong) id resourceIdentifier;
@property (nonatomic) BOOL scopeActive;
@end
@implementation ApolloAutomaticBackupFolderLease
- (void)dealloc {
    if (_scopeActive) [_root stopAccessingSecurityScopedResource];
}
@end

@interface ApolloAutomaticBackupFolderRequest : NSObject
@property (nonatomic, strong) ApolloAutomaticBackupJob *job;
@property (nonatomic, strong) NSBlockOperation *operation;
@property (nonatomic, copy) void (^completion)(NSURL *, NSError *);
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL finished; // main queue only
@end
@implementation ApolloAutomaticBackupFolderRequest
@end

static id ApolloAutomaticBackupResourceIdentifier(NSURL *url) {
    // A fresh URL avoids NSURL's resource-value cache returning the old inode
    // after another directory has replaced this same path.
    NSURL *freshURL = [NSURL fileURLWithPath:url.path isDirectory:YES];
    id identifier = nil;
    [freshURL getResourceValue:&identifier forKey:NSURLFileResourceIdentifierKey error:nil];
    return identifier;
}

// A moved cached URL is only a hint. Retry its original bookmark once, validate
// the resulting directory, and refresh permission data while its scope is held.
// All provider work happens off main, outside any archive publication accessor.
static ApolloAutomaticBackupFolderLease *ApolloAutomaticBackupResolveFolder(
    NSURL *cachedRoot, id cachedIdentifier, NSData *bookmark, BOOL rootIsBackupDirectory, BOOL prepareLegacyDirectory,
    ApolloAutomaticBackupJob *job, NSError **error) {
    NSError *lastError = nil;
    for (NSUInteger attempt = 0; attempt < (cachedRoot ? 2u : 1u); attempt++) {
        if (job.isCancelled) break;
        BOOL usingCache = cachedRoot && attempt == 0;
        // Without a known live identity, resolve the bookmark rather than trust
        // a path that another folder may have taken over after a move.
        if (usingCache && !cachedIdentifier) continue;
        BOOL stale = NO;
        NSURL *root = usingCache ? cachedRoot : [NSURL URLByResolvingBookmarkData:bookmark options:0
            relativeToURL:nil bookmarkDataIsStale:&stale error:&lastError];
        if (!root.isFileURL) continue;
        ApolloAutomaticBackupFolderLease *lease = [ApolloAutomaticBackupFolderLease new];
        lease.root = root;
        lease.scopeActive = [root startAccessingSecurityScopedResource];
        __block id actualIdentifier = nil;
        BOOL rootReady = ApolloAutomaticBackupReadItem(root, job, &lastError,
            ^BOOL(NSURL *coordinatedRoot, NSError **readError) {
                if (!ApolloAutomaticBackupDirectoryIsUsable(coordinatedRoot, readError)) return NO;
                actualIdentifier = ApolloAutomaticBackupResourceIdentifier(coordinatedRoot);
                // Some existing minimal bookmarks fall back to the old path
                // when a replacement folder appears there. Never transfer a
                // known live selection to a different directory in that case.
                return !cachedIdentifier || (actualIdentifier && [actualIdentifier isEqual:cachedIdentifier]);
            });
        if (!rootReady || job.isCancelled) continue;
        lease.resourceIdentifier = actualIdentifier;
        __block NSURL *directory = rootIsBackupDirectory ? root
            : [root URLByAppendingPathComponent:kBackupDirectoryName isDirectory:YES];
        BOOL usable = prepareLegacyDirectory
            ? ApolloAutomaticBackupInDirectory(root, rootIsBackupDirectory, job, &lastError,
                ^BOOL(NSURL *preparedDirectory, __unused NSError **prepareError) {
                    directory = preparedDirectory;
                    return YES;
                })
            : ApolloAutomaticBackupReadItem(directory, job, &lastError,
                ^BOOL(NSURL *coordinatedDirectory, NSError **readError) {
                    if (!ApolloAutomaticBackupDirectoryIsUsable(coordinatedDirectory, readError)) return NO;
                    directory = coordinatedDirectory;
                    return YES;
                });
        if (!usable || job.isCancelled) continue;
        lease.directory = directory;
        if (!usingCache && stale) {
            lease.refreshedBookmark = [root bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                includingResourceValuesForKeys:@[NSURLPathKey] relativeToURL:nil error:&lastError];
            if (!lease.refreshedBookmark) continue;
        }
        return lease;
    }
    if (error) *error = ApolloAutomaticBackupError(job.isCancelled
        ? @"Folder access was cancelled. Please try again."
        : @"The backup folder is unavailable. Reconnect it or select a folder again in Files.");
    return nil;
}

// Older builds keyed ownership by the directory path. The path may no longer
// exist after a move. Only adopt records whose exact name AND content fingerprint
// match a file in the validated selected directory; never infer ownership from a
// short filename or from a directory's new name. Existing destination records win.
static void ApolloAutomaticBackupMigrateOwnership(NSURL *directory, NSDictionary *legacyLedgers,
    NSMutableDictionary *ownership, ApolloAutomaticBackupJob *job) {
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *candidates = [NSMutableDictionary dictionary];
    for (id value in legacyLedgers.allValues) {
        NSDictionary *records = ApolloAutomaticBackupOwnershipRecords(value);
        for (NSString *name in records) {
            if (ownership[name]) continue;
            if (!candidates[name]) candidates[name] = [NSMutableArray array];
            [candidates[name] addObject:records[name]];
        }
    }
    for (NSString *name in candidates) {
        if (job.isCancelled) return;
        NSURL *url = [directory URLByAppendingPathComponent:name];
        __block NSData *hash = nil;
        if (!ApolloAutomaticBackupReadItem(url, job, nil, ^BOOL(NSURL *coordinatedURL, NSError **readError) {
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:coordinatedURL.path error:readError];
            if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) return NO;
            if (![coordinatedURL.lastPathComponent isEqualToString:name] ||
                ![coordinatedURL.URLByDeletingLastPathComponent.URLByStandardizingPath.path isEqualToString:
                    directory.URLByStandardizingPath.path]) return NO;
            hash = ApolloAutomaticBackupFingerprint(coordinatedURL, job, readError);
            return hash != nil;
        })) continue;
        for (NSDictionary *record in candidates[name]) {
            if ([hash isEqual:record[@"sha256"]]) {
                ownership[name] = record;
                break;
            }
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
@property (nonatomic, strong) NSOperationQueue *folderReadQueue;
@property (nonatomic, strong) NSMutableSet<ApolloAutomaticBackupFolderRequest *> *folderRequests;
@property (nonatomic) NSUInteger folderSelectionGeneration;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL suspendedForRestore;
@property (nonatomic, strong) NSURL *selectedFolderURL;
@property (nonatomic, strong) id selectedFolderResourceIdentifier;
@property (nonatomic) BOOL selectedFolderScopeActive;
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
        // The tweak can load for a push while the phone is locked. Do not read a
        // protected file yet: an unreadable existing state is not a new install.
        _state = [NSMutableDictionary dictionary];
        _workQueue = dispatch_queue_create("app.apolloreborn.automatic-backup", DISPATCH_QUEUE_SERIAL);
        _folderReadQueue = [NSOperationQueue new];
        _folderReadQueue.name = @"app.apolloreborn.backup-folder-reader";
        _folderReadQueue.maxConcurrentOperationCount = 2;
        _folderReadQueue.qualityOfService = NSQualityOfServiceUtility;
        _folderRequests = [NSMutableSet set];
    }
    return self;
}

- (BOOL)enabled { return sAutomaticBackupsEnabled; }
- (NSInteger)intervalDays { return ApolloAutomaticBackupDays(sAutomaticBackupIntervalDays); }
- (BOOL)isBackingUp { return self.job != nil; }
- (BOOL)usesSelectedFolder { return self.hasSavedFolder; }
- (BOOL)loadStateIfNeeded {
    if (self.stateLoaded) return YES;
    if (!UIApplication.sharedApplication.isProtectedDataAvailable) return NO;
    NSURL *url = ApolloAutomaticBackupStateURL();
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!data && error.code == NSFileReadNoSuchFileError && [error.domain isEqualToString:NSCocoaErrorDomain]) {
        self.stateLoaded = YES;
        self.stateReadError = nil;
        return YES;
    }
    NSDictionary *saved = data ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:&error] : nil;
    if (![saved isKindOfClass:NSDictionary.class]) {
        self.stateReadError = @"Could not read the backup configuration. Unlock the phone and reopen Apollo to try again.";
        // Never overwrite an existing unreadable/corrupt file: it can still
        // contain the only usable permission bookmark for the selected folder.
        return NO;
    }
    self.state = [saved mutableCopy];
    self.stateLoaded = YES;
    self.stateReadError = nil;
    return YES;
}
- (NSString *)destinationName {
    return self.savedFolderName ?: @"Select Folder";
}
- (BOOL)hasSavedFolder {
    [self loadStateIfNeeded];
    id bookmark = self.state[@"folderBookmark"];
    return [bookmark isKindOfClass:NSData.class] && [bookmark length] > 0;
}
- (NSString *)savedFolderName {
    if (!self.hasSavedFolder) return nil;
    if (![self.state[@"folderIsBackupDirectory"] boolValue]) return kBackupDirectoryName;
    id name = self.state[@"folderName"];
    return [name isKindOfClass:NSString.class] && [name length] ? name : nil;
}
- (NSString *)folderIdentifier {
    id identifier = self.state[@"folderIdentifier"];
    if ([identifier isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:identifier]) return identifier;
    NSString *created = NSUUID.UUID.UUIDString;
    self.state[@"folderIdentifier"] = created;
    return created;
}
- (void)adoptFolderLease:(ApolloAutomaticBackupFolderLease *)lease {
    if (lease.root == self.selectedFolderURL) return; // lease releases its extra acquisition
    if (self.selectedFolderScopeActive) [self.selectedFolderURL stopAccessingSecurityScopedResource];
    self.selectedFolderURL = lease.root;
    self.selectedFolderResourceIdentifier = lease.resourceIdentifier;
    self.selectedFolderScopeActive = lease.scopeActive;
    lease.scopeActive = NO;
}
- (NSString *)stateKey:(NSString *)suffix {
    return [@"folder" stringByAppendingString:suffix];
}
- (NSDate *)lastBackupDate {
    [self loadStateIfNeeded];
    id date = self.state[[self stateKey:@"LastSuccess"]];
    return [date isKindOfClass:NSDate.class] ? date : nil;
}
- (NSDate *)nextBackupDate {
    if (!self.enabled || !self.hasSavedFolder) return nil;
    NSDate *last = self.lastBackupDate;
    // An implausibly future last-success after a clock correction must not defer
    // all backups until that old wall-clock date eventually comes around again.
    if (!last || last.timeIntervalSinceNow > 300) return [NSDate date];
    return [last dateByAddingTimeInterval:self.intervalDays * 24 * 60 * 60];
}
- (NSDate *)nextRetryDate {
    if (!self.enabled || !self.hasSavedFolder || self.isBackingUp || self.suspendedForRestore) return nil;
    id attempted = self.state[[self stateKey:@"LastAttempt"]];
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
    id message = self.state[[self stateKey:@"LastError"]];
    return [message isKindOfClass:NSString.class] ? message : nil;
}

- (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloAutomaticBackupDidChangeNotification object:self];
}

- (BOOL)saveState:(NSError **)error {
    if (![self loadStateIfNeeded]) {
        if (error) *error = ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again.");
        return NO;
    }
    NSURL *url = ApolloAutomaticBackupStateURL();
    NSURL *directory = url.URLByDeletingLastPathComponent;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *underlying = nil;
    BOOL success = [fm createDirectoryAtURL:directory withIntermediateDirectories:YES
                               attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:&underlying];
    // Permission bookmarks, installation ID and last-run state belong to this
    // installation. They must not migrate in a ZIP or an iOS device backup.
    if (success) success = [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&underlying];
    NSData *data = success ? [NSPropertyListSerialization dataWithPropertyList:self.state
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&underlying] : nil;
    success = data && [data writeToURL:url options:(NSDataWritingAtomic | NSDataWritingFileProtectionComplete)
                                error:&underlying];
    if (!success) {
        ApolloLog(@"[AutomaticBackup] Could not persist backup state (code %ld)", (long)underlying.code);
        if (error) *error = ApolloAutomaticBackupError(@"Could not save the backup configuration. Check the phone's free space and try again.");
    }
    return success;
}

- (void)start {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    if (self.started) return;
    self.started = YES;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
    [nc addObserver:self selector:@selector(scheduleNextCheck) name:UIApplicationSignificantTimeChangeNotification object:nil];
    [nc addObserver:self selector:@selector(stopTimer) name:UIApplicationWillResignActiveNotification object:nil];
    [self scheduleNextCheck];
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)scheduleNextCheck {
    [self stopTimer];
    UIApplication *app = UIApplication.sharedApplication;
    if (!self.started || !self.enabled || self.isBackingUp || self.suspendedForRestore ||
        app.applicationState != UIApplicationStateActive || !app.isProtectedDataAvailable) return;
    if (![self loadStateIfNeeded]) {
        [self notifyChange];
        return;
    }
    if (!self.hasSavedFolder) return;
    NSTimeInterval delay = MAX(2, self.nextBackupDate.timeIntervalSinceNow);
    NSDate *retry = self.nextRetryDate;
    if (retry) delay = MAX(delay, retry.timeIntervalSinceNow);
    // No periodic polling: one foreground timer for the due date. An inactive app
    // has no timer; becoming active always recomputes from the last successful save.
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        [weakSelf runBackupAutomatically:YES completion:nil];
    }];
    self.timer.tolerance = MIN(60, delay / 10);
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)setEnabled:(BOOL)enabled {
    if (self.isBackingUp || self.suspendedForRestore || self.enabled == enabled) return;
    sAutomaticBackupsEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UDKeyAutomaticBackupsEnabled];
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)setIntervalDays:(NSInteger)days {
    if (self.isBackingUp || self.suspendedForRestore) return;
    days = ApolloAutomaticBackupDays(days);
    if (sAutomaticBackupIntervalDays == days) return;
    sAutomaticBackupIntervalDays = days;
    [[NSUserDefaults standardUserDefaults] setInteger:days forKey:UDKeyAutomaticBackupIntervalDays];
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)completeFolderRequest:(ApolloAutomaticBackupFolderRequest *)request
                         lease:(ApolloAutomaticBackupFolderLease *)lease error:(NSError *)error {
    if (request.finished) return;
    request.finished = YES;
    [request.job cancel];
    [request.operation cancel];
    request.operation = nil;
    [self.folderRequests removeObject:request];
    NSError *resultError = error;
    if (!resultError && (request.generation != self.folderSelectionGeneration || self.suspendedForRestore)) {
        resultError = ApolloAutomaticBackupError(@"The selected backup folder changed. Open it again to continue.");
    }
    if (!resultError && lease.refreshedBookmark) {
        id previous = self.state[@"folderBookmark"];
        self.state[@"folderBookmark"] = lease.refreshedBookmark;
        if (![self saveState:&resultError]) self.state[@"folderBookmark"] = previous;
    }
    if (!resultError && lease) [self adoptFolderLease:lease];
    void (^completion)(NSURL *, NSError *) = request.completion;
    request.completion = nil;
    if (completion) completion(resultError ? nil : lease.directory, resultError);
}

- (void)cancelFolderResolution {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self cancelFolderResolution]; });
        return;
    }
    for (ApolloAutomaticBackupFolderRequest *request in self.folderRequests.allObjects) {
        [self completeFolderRequest:request lease:nil error:ApolloAutomaticBackupError(@"Folder access was cancelled.")];
    }
}

- (void)selectedFolderURLWithCompletion:(void (^)(NSURL *, NSError *))completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self selectedFolderURLWithCompletion:completion]; });
        return;
    }
    if (![self loadStateIfNeeded] || self.suspendedForRestore) {
        completion(nil, ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again."));
        return;
    }
    NSData *bookmark = [self.state[@"folderBookmark"] isKindOfClass:NSData.class]
        ? self.state[@"folderBookmark"] : nil;
    if (!bookmark.length) {
        completion(nil, ApolloAutomaticBackupError(@"Select a backup folder in Files first."));
        return;
    }
    // Establish a stable destination identity before a stale bookmark's original
    // path is refreshed. Identity stays unchanged when that folder moves.
    [self folderIdentifier];
    NSURL *cachedRoot = self.selectedFolderURL;
    id cachedIdentifier = self.selectedFolderResourceIdentifier;
    BOOL rootIsBackupDirectory = [self.state[@"folderIsBackupDirectory"] boolValue];
    ApolloAutomaticBackupFolderRequest *request = [ApolloAutomaticBackupFolderRequest new];
    request.job = [ApolloAutomaticBackupJob new];
    request.generation = self.folderSelectionGeneration;
    request.completion = completion;
    [self.folderRequests addObject:request];
    __weak typeof(self) weakSelf = self;
    request.operation = [NSBlockOperation blockOperationWithBlock:^{
        NSError *error = nil;
        ApolloAutomaticBackupFolderLease *lease = ApolloAutomaticBackupResolveFolder(
            cachedRoot, cachedIdentifier, bookmark, rootIsBackupDirectory, NO, request.job, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf completeFolderRequest:request lease:lease error:error];
        });
    }];
    [self.folderReadQueue addOperation:request.operation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFolderReadTimeout * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (request.finished) return;
            [weakSelf completeFolderRequest:request lease:nil error:ApolloAutomaticBackupError(
                @"Files is taking too long to open this folder. Reconnect its provider and try again.")];
        });
}

- (ApolloAutomaticBackupJob *)beginJob {
    [self stopTimer];
    ApolloAutomaticBackupJob *job = [ApolloAutomaticBackupJob new];
    self.job = job;
    __weak typeof(self) weakSelf = self;
    job.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Apollo Settings Backup"
        expirationHandler:^{
            [job cancel];
            [weakSelf endBackgroundTimeForJob:job];
        }];
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
    [self cancelFolderResolution];
    [self stopTimer];
    [self.job cancel];
    ApolloLog(@"[AutomaticBackup] Suspended for settings restore until relaunch");
}

- (void)resumeAfterFailedSettingsRestore {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self resumeAfterFailedSettingsRestore]; });
        return;
    }
    self.suspendedForRestore = NO;
    [self notifyChange];
    [self scheduleNextCheck];
}

- (void)selectFolderURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self selectFolderURL:url completion:completion]; });
        return;
    }
    if (self.isBackingUp || self.suspendedForRestore) {
        completion(ApolloAutomaticBackupError(@"Wait for the current operation to finish."));
        return;
    }
    if (![self loadStateIfNeeded]) {
        completion(ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again."));
        return;
    }
    // Capture the new permission during the Files callback, but keep the working
    // destination and its scope until this candidate has passed validation.
    BOOL candidateScopeActive = [url startAccessingSecurityScopedResource];
    NSError *bookmarkError = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
        includingResourceValuesForKeys:nil relativeToURL:nil error:&bookmarkError];
    if (!bookmark) {
        if (candidateScopeActive) [url stopAccessingSecurityScopedResource];
        completion(ApolloAutomaticBackupError(@"Could not remember this folder. Please try again."));
        return;
    }
    ApolloAutomaticBackupJob *job = [self beginJob];
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            NSError *error = nil;
            __block id selectedIdentifier = nil;
            // Files has already exported the backup directory. Its actual name
            // may differ after a rename; never add a second directory inside it.
            BOOL success = ApolloAutomaticBackupInDirectory(url, YES, job, &error,
                ^BOOL(NSURL *directory, NSError **writeError) {
                    selectedIdentifier = ApolloAutomaticBackupResourceIdentifier(directory);
                    // A bookmark alone says nothing about write permission. Probe
                    // the folder now, before changing a working destination.
                    NSURL *probe = [directory URLByAppendingPathComponent:
                        [@".apollo-backup-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
                    BOOL writable = ApolloAutomaticBackupWriteItems(probe, 0, nil, 0, job, writeError,
                        ^BOOL(NSURL *newProbe, __unused NSURL *unused, NSError **probeError) {
                            if (!ApolloAutomaticBackupDirectoryIsUsable(newProbe.URLByDeletingLastPathComponent, probeError)) return NO;
                            if (![[NSData data] writeToURL:newProbe options:NSDataWritingWithoutOverwriting error:probeError]) return NO;
                            // This empty, newly created probe never escapes its
                            // exclusive item coordination or becomes a document.
                            return [NSFileManager.defaultManager removeItemAtURL:newProbe error:probeError];
                        });
                    if (!writable) return NO;
                    return !job.isCancelled;
                });
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *resultError = error;
                BOOL selected = NO;
                if (success && !job.isCancelled && !self.suspendedForRestore) {
                    NSMutableDictionary *previous = [self.state mutableCopy];
                    self.state[@"folderBookmark"] = bookmark;
                    BOOL sameDirectory = selectedIdentifier && self.selectedFolderResourceIdentifier &&
                        [selectedIdentifier isEqual:self.selectedFolderResourceIdentifier];
                    self.state[@"folderIdentifier"] = sameDirectory ? [self folderIdentifier] : NSUUID.UUID.UUIDString;
                    self.state[@"folderName"] = url.lastPathComponent.length ? url.lastPathComponent : @"Files Folder";
                    self.state[@"folderIsBackupDirectory"] = @YES;
                    [self.state removeObjectForKey:@"folderLastSuccess"];
                    [self.state removeObjectForKey:@"folderLastAttempt"];
                    [self.state removeObjectForKey:@"folderLastError"];
                    if ([self saveState:&resultError]) {
                        if (self.selectedFolderScopeActive) [self.selectedFolderURL stopAccessingSecurityScopedResource];
                        self.selectedFolderURL = url;
                        self.selectedFolderResourceIdentifier = selectedIdentifier;
                        self.selectedFolderScopeActive = candidateScopeActive;
                        self.folderSelectionGeneration += 1;
                        [self cancelFolderResolution];
                        selected = YES;
                        // Preserve the old preference for compatibility with
                        // earlier builds. New code always uses the saved folder.
                        sAutomaticBackupDestination = 1;
                        [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:UDKeyAutomaticBackupDestination];
                    } else {
                        self.state = previous;
                    }
                } else if (!resultError) {
                    resultError = ApolloAutomaticBackupError(@"Folder selection was interrupted. Please choose the folder again.");
                }
                if (!selected && candidateScopeActive) [url stopAccessingSecurityScopedResource];
                [self finishJob:job];
                completion(resultError);
            });
        }
    });
}

- (void)backUpNowWithCompletion:(void (^)(NSString *, NSError *))completion {
    [self runBackupAutomatically:NO completion:completion];
}

- (void)runBackupAutomatically:(BOOL)automatic completion:(void (^)(NSString *, NSError *))completion {
    UIApplication *app = UIApplication.sharedApplication;
    if (self.isBackingUp || self.suspendedForRestore ||
        app.applicationState != UIApplicationStateActive || !app.isProtectedDataAvailable ||
        (automatic && (!self.enabled || self.nextBackupDate.timeIntervalSinceNow > 0))) {
        if (completion) completion(nil, ApolloAutomaticBackupError(@"Keep Apollo open and wait for the current operation to finish, then try again."));
        [self scheduleNextCheck];
        return;
    }
    if (![self loadStateIfNeeded]) {
        [self notifyChange];
        if (completion) completion(nil, ApolloAutomaticBackupError(self.stateReadError ?: @"Unlock the phone and try again."));
        return;
    }
    if (!self.hasSavedFolder) {
        if (completion) completion(nil, ApolloAutomaticBackupError(@"Select a backup folder in Files first."));
        [self scheduleNextCheck];
        return;
    }
    NSString *installationID = [self.state[@"installationID"] isKindOfClass:NSString.class]
        ? self.state[@"installationID"] : nil;
    if (!installationID || ![[NSUUID alloc] initWithUUIDString:installationID]) {
        installationID = NSUUID.UUID.UUIDString;
        self.state[@"installationID"] = installationID;
        [self.state removeObjectForKey:@"archiveOwnershipByDirectory"];
        [self.state removeObjectForKey:@"archiveOwnershipByDestination"];
    }
    NSString *destinationIdentifier = [self folderIdentifier];
    NSString *prefix = @"folder";
    self.state[[prefix stringByAppendingString:@"LastAttempt"]] = [NSDate date];
    NSError *stateError = nil;
    if (![self saveState:&stateError]) {
        self.state[[prefix stringByAppendingString:@"LastError"]] = stateError.localizedDescription;
        [self notifyChange];
        [self scheduleNextCheck];
        if (completion) completion(nil, stateError);
        return;
    }
    NSData *bookmark = [self.state[@"folderBookmark"] isKindOfClass:NSData.class]
        ? self.state[@"folderBookmark"] : nil;
    NSDictionary *legacyOwnershipByDirectory = [self.state[@"archiveOwnershipByDirectory"] isKindOfClass:NSDictionary.class]
        ? [self.state[@"archiveOwnershipByDirectory"] copy] : @{};
    NSDictionary *ownershipByDestination = [self.state[@"archiveOwnershipByDestination"] isKindOfClass:NSDictionary.class]
        ? [self.state[@"archiveOwnershipByDestination"] copy] : @{};
    ApolloAutomaticBackupJob *job = [self beginJob];
    NSURL *cachedRoot = self.selectedFolderURL;
    id cachedIdentifier = self.selectedFolderResourceIdentifier;
    BOOL rootIsBackupDirectory = [self.state[@"folderIsBackupDirectory"] boolValue];
    ApolloLog(@"[AutomaticBackup] Starting %@ backup to Files storage",
              automatic ? @"scheduled" : @"requested");
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            NSError *error = nil;
            NSURL *zip = nil;
            ApolloAutomaticBackupFolderLease *folderLease = nil;
            NSMutableDictionary *updatedOwnership = nil;
            NSURL *publishedURL = nil;
            BOOL saved = NO;
            @try {
                folderLease = ApolloAutomaticBackupResolveFolder(cachedRoot, cachedIdentifier, bookmark,
                    rootIsBackupDirectory, YES, job, &error);
                if (folderLease && !job.isCancelled) {
                    zip = ApolloBackupRestoreCreateBackupZip(&error);
                    if (zip && !job.isCancelled) {
                        NSData *fingerprint = automatic ? ApolloAutomaticBackupFingerprint(zip, job, &error) : nil;
                        if (!automatic || fingerprint) {
                            updatedOwnership = ApolloAutomaticBackupOwnershipRecords(ownershipByDestination[destinationIdentifier]);
                            if (automatic) {
                                NSMutableDictionary *migrationSources = [legacyOwnershipByDirectory mutableCopy];
                                for (NSString *identifier in ownershipByDestination) {
                                    if (![identifier isEqualToString:destinationIdentifier]) {
                                        migrationSources[[@"destination:" stringByAppendingString:identifier]] = ownershipByDestination[identifier];
                                    }
                                }
                                ApolloAutomaticBackupMigrateOwnership(folderLease.directory, migrationSources, updatedOwnership, job);
                            }
                            NSDate *savedAt = [NSDate date];
                            publishedURL = ApolloAutomaticBackupPublish(zip, folderLease.directory, automatic, savedAt, job, &error);
                            if (publishedURL) {
                                if (automatic) updatedOwnership[publishedURL.lastPathComponent] =
                                    @{@"sha256": fingerprint, @"savedAt": savedAt};
                                saved = YES;
                            }
                        }
                    }
                }
            } @catch (__unused NSException *exception) {
                error = ApolloAutomaticBackupError(@"Could not complete the backup. Please try again.");
            } @finally {
                if (zip) [NSFileManager.defaultManager removeItemAtURL:zip error:nil];
            }
            BOOL interrupted = job.isCancelled;
            if (!saved || interrupted) {
                error = error ?: ApolloAutomaticBackupError(@"Backup was interrupted. It will be retried when Apollo is open.");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *resultError = error;
                BOOL cancelled = interrupted || job.isCancelled;
                void (^finish)(NSError *) = ^(NSError *finalError) {
                    [self finishJob:job];
                    if (completion) completion(finalError ? nil : publishedURL.lastPathComponent, finalError);
                };
                BOOL ledgerPersisted = NO;
                if (!self.suspendedForRestore) {
                    if (publishedURL && updatedOwnership) {
                        NSMutableDictionary *ledger = [ownershipByDestination mutableCopy];
                        ledger[destinationIdentifier] = [updatedOwnership copy];
                        self.state[@"archiveOwnershipByDestination"] = ledger;
                    }
                    if (folderLease) [self adoptFolderLease:folderLease];
                    if (folderLease.refreshedBookmark) self.state[@"folderBookmark"] = folderLease.refreshedBookmark;
                    if (saved && !cancelled) {
                        self.state[[prefix stringByAppendingString:@"LastSuccess"]] = [NSDate date];
                        [self.state removeObjectForKey:[prefix stringByAppendingString:@"LastError"]];
                        ApolloLog(@"[AutomaticBackup] Archive saved to Files storage");
                    } else {
                        resultError = resultError ?: ApolloAutomaticBackupError(@"Backup was interrupted. It will be retried when Apollo is open.");
                        self.state[[prefix stringByAppendingString:@"LastError"]] = resultError.localizedDescription;
                        ApolloLog(@"[AutomaticBackup] Backup failed or was interrupted (code %ld)", (long)resultError.code);
                    }
                    NSError *persistError = nil;
                    // The new archive's ownership must be durable before pruning
                    // any old archive. A failed state write leaves all archives.
                    ledgerPersisted = [self saveState:&persistError];
                    if (!ledgerPersisted && !resultError) {
                        resultError = ApolloAutomaticBackupError(@"Backup was saved, but its configuration could not be remembered. Check the phone's free space.");
                        self.state[[prefix stringByAppendingString:@"LastError"]] = resultError.localizedDescription;
                    }
                }
                if (!automatic || !saved || cancelled || self.suspendedForRestore || !ledgerPersisted || !publishedURL) {
                    finish(resultError);
                    return;
                }
                // Publication coordination ended before this main-queue save.
                // Resume cleanup asynchronously with a balanced extra scope;
                // never wait for main from a coordinator.
                dispatch_async(self.workQueue, ^{
                    BOOL scoped = [folderLease.root startAccessingSecurityScopedResource];
                    @try {
                        ApolloAutomaticBackupPrune(publishedURL.URLByDeletingLastPathComponent,
                            publishedURL, updatedOwnership, job);
                    } @catch (__unused NSException *exception) {
                        ApolloLog(@"[AutomaticBackup] Could not finish archive retention");
                    } @finally {
                        if (scoped) [folderLease.root stopAccessingSecurityScopedResource];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSError *cleanupError = nil;
                        if (!self.suspendedForRestore) {
                            NSMutableDictionary *ledger = [self.state[@"archiveOwnershipByDestination"] mutableCopy];
                            ledger[destinationIdentifier] = [updatedOwnership copy];
                            self.state[@"archiveOwnershipByDestination"] = ledger;
                            // If this save fails, the durable pre-prune ledger
                            // still owns the newest file; absent entries are
                            // removed on the next successful retention pass.
                            if (![self saveState:&cleanupError]) {
                                cleanupError = ApolloAutomaticBackupError(@"Backup was saved, but its cleanup state could not be remembered. Check the phone's free space.");
                                self.state[[prefix stringByAppendingString:@"LastError"]] = cleanupError.localizedDescription;
                            }
                        }
                        finish(cleanupError);
                    });
                });
            });
        }
    });
}

@end
