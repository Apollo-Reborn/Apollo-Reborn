#import "settings/ApolloICloudBackupStore.h"

#import <Security/Security.h>
#import "ApolloCommon.h"
#import "settings/ApolloICloudBackupSupport.h"

NSNotificationName const ApolloICloudBackupStoreDidChangeNotification = @"ApolloICloudBackupStoreDidChangeNotification";

static NSString *const kApolloICloudBackupDirectoryName = @"Apollo Reborn Backups";
static NSTimeInterval const kApolloICloudDownloadTimeout = 45.0;

typedef struct __SecTask *ApolloICloudSecTaskRef;
extern ApolloICloudSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(ApolloICloudSecTaskRef task,
                                                CFStringRef entitlement,
                                                CFErrorRef *error);

static NSError *ApolloICloudBackupError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloICloudBackupStore" code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"iCloud Drive is unavailable."}];
}

static void ApolloICloudBackupCancelCoordinatorAfterTimeout(NSFileCoordinator *coordinator) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloICloudDownloadTimeout * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [coordinator cancel]; });
}

static NSDictionary *ApolloICloudBackupCurrentEntitlements(void) {
    ApolloICloudSecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return @{};
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"com.apple.developer.ubiquity-container-identifiers",
                            @"com.apple.developer.icloud-services"]) {
        CFTypeRef value = SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)key, NULL);
        if (value) values[key] = CFBridgingRelease(value);
    }
    CFRelease(task);
    return values;
}

@interface ApolloICloudBackupStore ()
@property (nonatomic) ApolloICloudBackupAvailability availability;
@property (nonatomic, copy) NSString *availabilityDescription;
@property (nonatomic, getter=isWorking) BOOL working;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, copy) NSString *scopeIdentifier;
@property (nonatomic, copy) NSString *selectedFolderName;
@end

@implementation ApolloICloudBackupStore

+ (instancetype)sharedStore {
    static ApolloICloudBackupStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[self alloc] init]; });
    return store;
}

static NSURL *ApolloICloudBackupSelectionURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"ApolloReborn/ICloudBackups/folder.plist"];
}

- (NSDictionary *)selectedFolderState {
    NSData *data = [NSData dataWithContentsOfURL:ApolloICloudBackupSelectionURL()];
    id value = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] && [value[@"bookmark"] isKindOfClass:NSData.class] ? value : nil;
}

- (BOOL)writeSelectedFolderState:(NSDictionary *)state error:(NSError **)error {
    NSURL *stateURL = ApolloICloudBackupSelectionURL();
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:stateURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES
        attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:error]) return NO;
    [stateURL.URLByDeletingLastPathComponent setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:state
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToURL:stateURL
        options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:error];
}

- (void)selectFolderURL:(NSURL *)folderURL completion:(void (^)(NSError *))completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self selectFolderURL:folderURL completion:completion]; });
        return;
    }
    NSError *error = nil;
    if (!folderURL.isFileURL) error = ApolloICloudBackupError(@"Files did not return a usable backup folder.");
    BOOL scoped = !error && [folderURL startAccessingSecurityScopedResource];
    NSData *bookmark = !error ? [folderURL bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
        includingResourceValuesForKeys:@[NSURLNameKey, NSURLFileResourceIdentifierKey]
        relativeToURL:nil error:&error] : nil;
    NSString *scope = bookmark ? ApolloICloudBackupScopeIdentifier(bookmark) : nil;
    if (error || !bookmark) {
        if (scoped) [folderURL stopAccessingSecurityScopedResource];
        if (completion) completion(error ?: ApolloICloudBackupError(@"Could not remember that folder."));
        return;
    }
    [self publishState:self.availability description:@"Checking Selected Folder…" working:YES];

    // Capture the bookmark while Files is still calling its delegate, then do
    // provider coordination off main. A minimal bookmark URL can remain usable
    // when startAccessingSecurityScopedResource returns NO, so the write probe
    // is the authority and only a successful start is balanced.
    dispatch_async(self.workQueue, ^{
        @autoreleasepool {
            __block NSError *probeError = nil;
            __block id resourceIdentifier = nil;
            NSError *coordinationError = nil;
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            ApolloICloudBackupCancelCoordinatorAfterTimeout(coordinator);
            [coordinator coordinateWritingItemAtURL:folderURL options:0 error:&coordinationError
                byAccessor:^(NSURL *coordinatedURL) {
                    NSNumber *directory = nil, *symlink = nil;
                    [coordinatedURL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:&probeError];
                    if (!probeError) [coordinatedURL getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:&probeError];
                    if (probeError) return;
                    if (!directory.boolValue || symlink.boolValue) {
                        probeError = ApolloICloudBackupError(@"Files did not return a safe backup folder.");
                        return;
                    }
                    [coordinatedURL getResourceValue:&resourceIdentifier
                        forKey:NSURLFileResourceIdentifierKey error:nil];
                    NSURL *probe = [coordinatedURL URLByAppendingPathComponent:
                        [NSString stringWithFormat:@".apollo-access-%@", NSUUID.UUID.UUIDString] isDirectory:NO];
                    NSData *probeData = [@"Apollo" dataUsingEncoding:NSUTF8StringEncoding];
                    if (![probeData writeToURL:probe options:NSDataWritingWithoutOverwriting error:&probeError]) return;
                    if (![NSFileManager.defaultManager removeItemAtURL:probe error:&probeError]) return;
                }];
            NSError *resultError = probeError ?: coordinationError;
            NSMutableDictionary *state = [@{
                @"bookmark": bookmark,
                @"name": folderURL.lastPathComponent ?: kApolloICloudBackupDirectoryName,
                @"isBackupDirectory": @YES,
                @"scope": scope ?: @"",
            } mutableCopy];
            if (resourceIdentifier && [NSPropertyListSerialization propertyList:resourceIdentifier
                isValidForFormat:NSPropertyListBinaryFormat_v1_0]) state[@"resourceIdentifier"] = resourceIdentifier;
            if (!resultError && ![self writeSelectedFolderState:state error:&resultError]) state = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (scoped) [folderURL stopAccessingSecurityScopedResource];
                if (!resultError && state) {
                    self.selectedFolderName = state[@"name"];
                    self.scopeIdentifier = scope;
                    self.availability = ApolloICloudBackupAvailabilityUnknown;
                    self.availabilityDescription = @"Checking Selected Folder…";
                }
                self.working = NO;
                [NSNotificationCenter.defaultCenter postNotificationName:
                    ApolloICloudBackupStoreDidChangeNotification object:self];
                if (completion) completion(resultError ?: (state ? nil
                    : ApolloICloudBackupError(@"Could not remember that folder.")));
            });
        }
    });
}

- (instancetype)init {
    if ((self = [super init])) {
        _availability = ApolloICloudBackupAvailabilityUnknown;
        _availabilityDescription = @"Checking iCloud Drive…";
        _workQueue = dispatch_queue_create("app.apolloreborn.icloud-backups", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)publishState:(ApolloICloudBackupAvailability)availability
          description:(NSString *)description working:(BOOL)working {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.availability = availability;
        self.availabilityDescription = description;
        self.working = working;
        [NSNotificationCenter.defaultCenter postNotificationName:ApolloICloudBackupStoreDidChangeNotification object:self];
    });
}

- (NSURL *)resolveDirectoryWithError:(NSError **)error accessRoot:(NSURL **)accessRoot scoped:(BOOL *)outScoped {
    NSDictionary *entitlements = ApolloICloudBackupCurrentEntitlements();
    NSDictionary *selection = [self selectedFolderState];
    NSURL *container = nil;
    BOOL scoped = NO;
    BOOL selectedBookmarkStale = NO;
    if (selection) {
        NSURLBookmarkResolutionOptions options = NSURLBookmarkResolutionWithoutUI;
        if (@available(iOS 14.2, *)) options |= NSURLBookmarkResolutionWithoutImplicitStartAccessing;
        container = [NSURL URLByResolvingBookmarkData:selection[@"bookmark"] options:options
            relativeToURL:nil bookmarkDataIsStale:&selectedBookmarkStale error:error];
        if (container) {
            if (@available(iOS 14.2, *)) scoped = [container startAccessingSecurityScopedResource];
            else scoped = YES; // bookmark resolution implicitly started one balanced access
        }
        if (!container) {
            if (error && !*error) *error = ApolloICloudBackupError(
                @"Apollo no longer has access to the selected folder. Reconnect it in Files; local backups are unchanged.");
            [self publishState:ApolloICloudBackupAvailabilityAccountUnavailable
                   description:@"Reconnect iCloud Drive Folder" working:NO];
            return nil;
        }
    } else if (!ApolloICloudBackupEntitlementsAllowDocuments(entitlements)) {
        if (error) *error = ApolloICloudBackupError(
            @"This copy of Apollo was not signed with iCloud Documents access. Choose an iCloud Drive folder, or keep using local backups and Files export.");
        [self publishState:ApolloICloudBackupAvailabilityMissingEntitlement
               description:@"Unavailable for This Build" working:NO];
        return nil;
    } else if (!NSFileManager.defaultManager.ubiquityIdentityToken) {
        if (error) *error = ApolloICloudBackupError(
            @"Sign in to iCloud and turn on iCloud Drive, then reopen Apollo.");
        [self publishState:ApolloICloudBackupAvailabilityAccountUnavailable
               description:@"iCloud Drive Is Off" working:NO];
        return nil;
    }

    // nil deliberately selects the signing identity's default container. A
    // fixed Apollo/team identifier would break re-signed and rebranded builds.
    else {
        container = [NSFileManager.defaultManager URLForUbiquityContainerIdentifier:nil];
        NSData *scopeData = [[entitlements[@"com.apple.developer.ubiquity-container-identifiers"]
            componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        self.scopeIdentifier = ApolloICloudBackupScopeIdentifier(scopeData);
        self.selectedFolderName = nil;
    }
    if (!container) {
        if (error) *error = ApolloICloudBackupError(
            @"The signed iCloud container is not available. Local backups are unchanged.");
        [self publishState:ApolloICloudBackupAvailabilityAccountUnavailable
               description:@"iCloud Container Unavailable" working:NO];
        return nil;
    }

    if (selection) {
        NSFileCoordinator *rootCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        ApolloICloudBackupCancelCoordinatorAfterTimeout(rootCoordinator);
        __block BOOL rootReady = NO;
        __block NSError *rootError = nil;
        __block id actualIdentifier = nil;
        NSError *rootCoordinationError = nil;
        [rootCoordinator coordinateReadingItemAtURL:container options:0 error:&rootCoordinationError
            byAccessor:^(NSURL *coordinatedRoot) {
                NSNumber *directory = nil, *symlink = nil;
                [coordinatedRoot getResourceValue:&directory forKey:NSURLIsDirectoryKey error:&rootError];
                if (!rootError) [coordinatedRoot getResourceValue:&symlink
                    forKey:NSURLIsSymbolicLinkKey error:&rootError];
                if (rootError) return;
                if (!directory.boolValue || symlink.boolValue) {
                    rootError = ApolloICloudBackupError(@"The selected iCloud backup location is not a safe folder.");
                    return;
                }
                // Avoid NSURL's cached resource identity after a provider moves
                // or replaces a folder at the same path.
                NSURL *freshRoot = [NSURL fileURLWithPath:coordinatedRoot.path isDirectory:YES];
                [freshRoot getResourceValue:&actualIdentifier forKey:NSURLFileResourceIdentifierKey error:nil];
                id expectedIdentifier = selection[@"resourceIdentifier"];
                if (expectedIdentifier && ![actualIdentifier isEqual:expectedIdentifier]) {
                    rootError = ApolloICloudBackupError(
                        @"The selected folder changed identity. Reconnect it in Files before uploading credentials.");
                    return;
                }
                rootReady = YES;
            }];
        if (!rootReady) {
            if (scoped) [container stopAccessingSecurityScopedResource];
            if (error) *error = rootError ?: rootCoordinationError
                ?: ApolloICloudBackupError(@"Reconnect the selected folder in Files.");
            [self publishState:ApolloICloudBackupAvailabilityAccountUnavailable
                   description:@"Reconnect iCloud Drive Folder" working:NO];
            return nil;
        }

        NSError *refreshError = nil;
        NSMutableDictionary *updated = [selection mutableCopy];
        BOOL selectionChanged = NO;
        BOOL bookmarkRefreshFailed = NO;
        if (!selection[@"resourceIdentifier"] && actualIdentifier &&
            [NSPropertyListSerialization propertyList:actualIdentifier
                isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
            updated[@"resourceIdentifier"] = actualIdentifier;
            selectionChanged = YES;
        }
        if (selectedBookmarkStale) {
            NSData *refreshed = [container bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                includingResourceValuesForKeys:@[NSURLNameKey, NSURLFileResourceIdentifierKey]
                relativeToURL:nil error:&refreshError];
            if (refreshed) {
                updated[@"bookmark"] = refreshed;
                selectionChanged = YES;
            }
            else bookmarkRefreshFailed = YES;
        }
        if (bookmarkRefreshFailed ||
            (selectionChanged && ![self writeSelectedFolderState:updated error:&refreshError])) {
            if (scoped) [container stopAccessingSecurityScopedResource];
            if (error) *error = refreshError ?: ApolloICloudBackupError(@"Reconnect the selected folder in Files.");
            [self publishState:ApolloICloudBackupAvailabilityAccountUnavailable
                   description:@"Reconnect iCloud Drive Folder" working:NO];
            return nil;
        }
        if (selectionChanged) selection = updated;
        self.selectedFolderName = selection[@"name"];
        self.scopeIdentifier = [selection[@"scope"] isKindOfClass:NSString.class]
            ? selection[@"scope"] : ApolloICloudBackupScopeIdentifier(selection[@"bookmark"]);
    }

    NSURL *base = selection ? container : [container URLByAppendingPathComponent:@"Documents" isDirectory:YES];
    NSURL *directory = selection && [selection[@"isBackupDirectory"] boolValue] ? base
        : [base URLByAppendingPathComponent:kApolloICloudBackupDirectoryName isDirectory:YES];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block BOOL ready = NO;
    __block NSError *workError = nil;
    NSError *coordinationError = nil;
    ApolloICloudBackupCancelCoordinatorAfterTimeout(coordinator);
    [coordinator coordinateWritingItemAtURL:directory options:0 error:&coordinationError
        byAccessor:^(NSURL *newURL) {
            NSDictionary *attributes = [fm attributesOfItemAtPath:newURL.path error:nil];
            if (attributes) {
                NSNumber *symlink = nil;
                [newURL getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:&workError];
                ready = !workError && !symlink.boolValue &&
                    [attributes[NSFileType] isEqualToString:NSFileTypeDirectory];
                if (!ready && !workError) workError = ApolloICloudBackupError(
                    @"The iCloud backup location is not a safe folder.");
                return;
            }
            ready = [fm createDirectoryAtURL:newURL withIntermediateDirectories:YES attributes:nil error:&workError];
        }];
    if (!ready) {
        if (scoped) [container stopAccessingSecurityScopedResource];
        if (error) *error = workError ?: coordinationError ?: ApolloICloudBackupError(@"Could not open the iCloud backup folder.");
        [self publishState:ApolloICloudBackupAvailabilityAccountUnavailable
               description:@"iCloud Drive Unavailable" working:NO];
        return nil;
    }
    if (accessRoot) *accessRoot = container;
    if (outScoped) *outScoped = scoped;
    return directory;
}

- (void)refreshAvailabilityWithCompletion:(void (^)(void))completion {
    [self publishState:self.availability description:self.availabilityDescription working:YES];
    dispatch_async(self.workQueue, ^{
        NSURL *root = nil; BOOL scoped = NO;
        NSURL *directory = [self resolveDirectoryWithError:nil accessRoot:&root scoped:&scoped];
        if (scoped) [root stopAccessingSecurityScopedResource];
        if (directory) [self publishState:ApolloICloudBackupAvailabilityAvailable description:@"Available" working:NO];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(); });
    });
}

- (void)uploadLocalBackupURL:(NSURL *)localURL expectedScope:(NSString *)expectedScope
               identityToken:(NSString *)identityToken
                  completion:(void (^)(NSURL *, NSError *))completion {
    [self publishState:self.availability description:@"Saving to iCloud…" working:YES];
    dispatch_async(self.workQueue, ^{
        NSError *error = nil;
        NSURL *root = nil; BOOL scoped = NO;
        NSURL *directory = [self resolveDirectoryWithError:&error accessRoot:&root scoped:&scoped];
        if (directory && (expectedScope.length == 0 || ![self.scopeIdentifier isEqualToString:expectedScope])) {
            error = ApolloICloudBackupError(@"The signed iCloud container or selected folder changed. Confirm iCloud backup access again before uploading credentials.");
            directory = nil;
        }
        __block NSURL *published = nil;
        NSNumber *sourceRegular = nil, *sourceSymlink = nil;
        [localURL getResourceValue:&sourceRegular forKey:NSURLIsRegularFileKey error:nil];
        [localURL getResourceValue:&sourceSymlink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (directory && localURL.isFileURL && sourceRegular.boolValue && !sourceSymlink.boolValue &&
            ApolloICloudBackupArchiveNameIsSupported(localURL.lastPathComponent)) {
            NSString *name = ApolloICloudBackupUniqueFilename(localURL.lastPathComponent, identityToken);
            NSURL *destination = [directory URLByAppendingPathComponent:name isDirectory:NO];
            NSURL *pending = [directory URLByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.%@.pending", name, NSUUID.UUID.UUIDString] isDirectory:NO];
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            __block NSError *workError = nil;
            __block BOOL copied = NO;
            NSError *coordinationError = nil;
            [coordinator coordinateWritingItemAtURL:pending options:NSFileCoordinatorWritingForMoving
                                   writingItemAtURL:destination options:0
                                              error:&coordinationError
                                         byAccessor:^(NSURL *newPending, NSURL *newDestination) {
                NSFileManager *fm = NSFileManager.defaultManager;
                @try {
                    if ([fm fileExistsAtPath:newDestination.path]) {
                        copied = [fm contentsEqualAtPath:localURL.path andPath:newDestination.path];
                        if (copied) published = newDestination;
                        else workError = ApolloICloudBackupError(@"An iCloud backup with this identity already exists but has different contents.");
                        return;
                    }
                    if (![fm copyItemAtURL:localURL toURL:newPending error:&workError]) return;
                    [coordinator itemAtURL:newPending willMoveToURL:newDestination];
                    copied = [fm moveItemAtURL:newPending toURL:newDestination error:&workError];
                    if (copied) {
                        [coordinator itemAtURL:newPending didMoveToURL:newDestination];
                        published = newDestination;
                    }
                } @finally {
                    [fm removeItemAtURL:newPending error:nil];
                }
            }];
            if (!copied) error = workError ?: coordinationError ?: ApolloICloudBackupError(@"Could not save the backup to iCloud Drive.");
        } else if (!error) {
            error = ApolloICloudBackupError(@"The local backup is unavailable or has an unexpected filename.");
        }
        if (scoped) [root stopAccessingSecurityScopedResource];
        if (directory) [self publishState:ApolloICloudBackupAvailabilityAvailable
            description:error ? @"Last iCloud Save Failed" : @"Available" working:NO];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(published, error); });
    });
}

- (void)backupURLsWithCompletion:(void (^)(NSArray<NSURL *> *, NSError *))completion {
    [self publishState:self.availability description:@"Refreshing iCloud Backups…" working:YES];
    dispatch_async(self.workQueue, ^{
        NSError *error = nil;
        NSURL *root = nil; BOOL scoped = NO;
        NSURL *directory = [self resolveDirectoryWithError:&error accessRoot:&root scoped:&scoped];
        NSMutableArray<NSURL *> *backups = [NSMutableArray array];
        if (directory) {
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            __block NSError *workError = nil;
            NSError *coordinationError = nil;
            [coordinator coordinateReadingItemAtURL:directory options:0 error:&coordinationError
                byAccessor:^(NSURL *newURL) {
                    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:newURL
                        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey,
                            NSURLContentModificationDateKey, NSURLFileSizeKey, NSURLUbiquitousItemDownloadingStatusKey]
                        options:NSDirectoryEnumerationSkipsHiddenFiles error:&workError];
                    for (NSURL *url in contents) {
                        if (!ApolloICloudBackupArchiveNameIsSupported(url.lastPathComponent)) continue;
                        NSNumber *regular = nil, *symlink = nil;
                        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
                        [url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
                        if (regular.boolValue && !symlink.boolValue) [backups addObject:url];
                    }
                }];
            error = workError ?: coordinationError;
        }
        NSArray *sorted = ApolloICloudBackupSortURLsNewestFirst(backups);
        if (scoped) [root stopAccessingSecurityScopedResource];
        if (directory) [self publishState:ApolloICloudBackupAvailabilityAvailable
            description:error ? @"Could Not Refresh iCloud" : @"Available" working:NO];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(sorted, error); });
    });
}

- (void)prepareLocalCopyOfBackupURL:(NSURL *)cloudURL
                         completion:(void (^)(NSURL *, NSError *))completion {
    [self publishState:self.availability description:@"Downloading Backup…" working:YES];
    dispatch_async(self.workQueue, ^{
        NSError *error = nil;
        NSURL *root = nil; BOOL scoped = NO;
        NSURL *directory = [self resolveDirectoryWithError:&error accessRoot:&root scoped:&scoped];
        NSURL *localCopy = nil;
        BOOL valid = directory && cloudURL.isFileURL &&
            [cloudURL.URLByDeletingLastPathComponent.URLByStandardizingPath.path
                isEqualToString:directory.URLByStandardizingPath.path] &&
            ApolloICloudBackupArchiveNameIsSupported(cloudURL.lastPathComponent);
        NSNumber *regular = nil, *symlink = nil;
        [cloudURL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [cloudURL getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
        valid = valid && regular.boolValue && !symlink.boolValue;
        if (!valid && !error) error = ApolloICloudBackupError(@"That backup is no longer in Apollo's iCloud folder.");
        if (valid) {
            NSString *downloadStatus = nil;
            [cloudURL getResourceValue:&downloadStatus forKey:NSURLUbiquitousItemDownloadingStatusKey error:nil];
            if (![downloadStatus isEqualToString:NSURLUbiquitousItemDownloadingStatusCurrent] &&
                ![NSFileManager.defaultManager startDownloadingUbiquitousItemAtURL:cloudURL error:&error]) {
                valid = NO;
            }
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kApolloICloudDownloadTimeout];
        while (valid && !error) {
            [cloudURL removeCachedResourceValueForKey:NSURLUbiquitousItemDownloadingStatusKey];
            NSString *downloadStatus = nil;
            [cloudURL getResourceValue:&downloadStatus forKey:NSURLUbiquitousItemDownloadingStatusKey error:&error];
            if ([downloadStatus isEqualToString:NSURLUbiquitousItemDownloadingStatusCurrent]) break;
            if (deadline.timeIntervalSinceNow <= 0) {
                error = ApolloICloudBackupError(@"The backup is taking too long to download from iCloud. Try again when the device is online.");
                break;
            }
            [NSThread sleepForTimeInterval:0.25];
        }
        if (valid && !error) {
            NSURL *stagingDirectory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
                URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
            if ([NSFileManager.defaultManager createDirectoryAtURL:stagingDirectory withIntermediateDirectories:YES
                attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
                             NSFilePosixPermissions: @0700} error:&error]) {
                localCopy = [stagingDirectory URLByAppendingPathComponent:cloudURL.lastPathComponent isDirectory:NO];
                NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
                __block NSError *copyError = nil;
                NSError *coordinationError = nil;
                [coordinator coordinateReadingItemAtURL:cloudURL options:NSFileCoordinatorReadingWithoutChanges
                    error:&coordinationError byAccessor:^(NSURL *newURL) {
                        if ([NSFileManager.defaultManager copyItemAtURL:newURL toURL:localCopy error:&copyError]) {
                            [NSFileManager.defaultManager setAttributes:@{
                                NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
                                NSFilePosixPermissions: @0600,
                            } ofItemAtPath:localCopy.path error:&copyError];
                        }
                    }];
                error = copyError ?: coordinationError;
                if (error) {
                    [NSFileManager.defaultManager removeItemAtURL:stagingDirectory error:nil];
                    localCopy = nil;
                }
            }
        }
        if (scoped) [root stopAccessingSecurityScopedResource];
        if (directory) [self publishState:ApolloICloudBackupAvailabilityAvailable
            description:error ? @"iCloud Download Failed" : @"Available" working:NO];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(localCopy, error); });
    });
}

- (void)deleteBackupURL:(NSURL *)cloudURL completion:(void (^)(NSError *))completion {
    [self publishState:self.availability description:@"Deleting iCloud Backup…" working:YES];
    dispatch_async(self.workQueue, ^{
        NSError *error = nil;
        NSURL *root = nil; BOOL scoped = NO;
        NSURL *directory = [self resolveDirectoryWithError:&error accessRoot:&root scoped:&scoped];
        BOOL valid = directory && cloudURL.isFileURL &&
            [cloudURL.URLByDeletingLastPathComponent.URLByStandardizingPath.path
                isEqualToString:directory.URLByStandardizingPath.path] &&
            ApolloICloudBackupArchiveNameIsSupported(cloudURL.lastPathComponent);
        if (!valid && !error) error = ApolloICloudBackupError(@"That backup is no longer in Apollo's iCloud folder.");
        if (valid) {
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            __block NSError *workError = nil;
            NSError *coordinationError = nil;
            [coordinator coordinateWritingItemAtURL:cloudURL options:NSFileCoordinatorWritingForDeleting
                error:&coordinationError byAccessor:^(NSURL *newURL) {
                    NSNumber *regular = nil, *symlink = nil;
                    [newURL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
                    [newURL getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
                    if (!regular.boolValue || symlink.boolValue ||
                        ![newURL.URLByDeletingLastPathComponent.URLByStandardizingPath.path
                            isEqualToString:directory.URLByStandardizingPath.path]) {
                        workError = ApolloICloudBackupError(@"That iCloud backup is no longer a safe Apollo archive.");
                        return;
                    }
                    if (![NSFileManager.defaultManager removeItemAtURL:newURL error:&workError] &&
                        [workError.domain isEqualToString:NSCocoaErrorDomain] && workError.code == NSFileNoSuchFileError) {
                        workError = nil;
                    }
                }];
            error = workError ?: coordinationError;
        }
        if (scoped) [root stopAccessingSecurityScopedResource];
        if (directory) [self publishState:ApolloICloudBackupAvailabilityAvailable
            description:error ? @"iCloud Delete Failed" : @"Available" working:NO];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    });
}

@end
