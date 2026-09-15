#import "settings/ApolloBackupRestore.h"
#import "settings/ApolloAutomaticBackup.h"

#import "ApolloCommon.h"
#import "ApolloPerAccountFavorites.h"
#import "ApolloState.h"
#import "ApolloTranslation.h"
#import "UserDefaultConstants.h"
#import "SSZipArchive.h"
#import <Security/Security.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import "minizip/compat/unzip.h"

static NSString *const kMainPlistFilename = @"preferences.plist";
static NSString *const kGroupPlistFilename = @"group.plist";
static NSString *const kAccountsFilename = @"accounts.txt";
static NSString *const kKeychainPlistFilename = @"keychain.plist";
static NSString *const kGroupSuiteName = @"group.com.christianselig.apollo";

// Export and restore use the same exact Apollo-owned namespaces. Never accept
// an unrelated service merely because its name contains Apollo's bundle ID.
static BOOL ApolloBackupOwnsKeychainIdentity(id service, id account) {
    if (![service isKindOfClass:NSString.class] || ![account isKindOfClass:NSString.class] ||
        ![account length] || [account rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [service rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    if ([service isEqualToString:@"com.christianselig.Apollo.webjson"]) {
        if ([@[@"sessionCookieHeader", @"sessionModhash", @"sessionUsername"] containsObject:account]) return YES;
        return [account rangeOfString:@"^websession:[^:\\s\\p{Cc}]+:(cookie|modhash)$"
                              options:NSRegularExpressionSearch].location != NSNotFound;
    }
    // The shared-group form is confirmed by ApolloWebJSONIdentity's live-device
    // service. Both initializer forms and the two ordinary Valet classes exist
    // in Apollo's bundled Valet framework; older accessibility names stay valid.
    NSString *pattern = @"^VAL_VAL(?:Synchronizable)?Valet_initWith(?:SharedAccessGroupIdentifier|Identifier):accessibility:_com\\.christianselig\\.Apollo_Accessible(?:AfterFirstUnlock|WhenUnlocked|Always)(?:ThisDeviceOnly)?$";
    return [service rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound ||
        [service isEqualToString:@"VAL_VALValet_initWithIdentifier:accessibility:_com.christianselig.Apollo_AccessibleWhenPasscodeSetThisDeviceOnly"] ||
        [service isEqualToString:@"VAL_VALValet_initWithSharedAccessGroupIdentifier:accessibility:_com.christianselig.Apollo_AccessibleWhenPasscodeSetThisDeviceOnly"];
}

// Capture Apollo's Valet keychain items so a backup can fully restore a signed-in session —
// not just the NSUserDefaults mirror. Returns an array of { service, account, data } dicts.
// The accounts blob lives only in the keychain in Apollo's load path, so without this a
// restored backup can't sign the user back in. Pairs with ApolloReplayValetKeychainItems and,
// in the simulator, with the tweak's keychain shim (which serves these on launch).
static NSArray<NSDictionary *> *ApolloCaptureValetKeychainItems(OSStatus *outStatus) {
    // Backup is an Apollo/Valet export, not permission to unlock some other protected
    // generic-password item visible to this signing identity. MatchLimitAll otherwise
    // defaults to allowing authentication UI and can unexpectedly request the device
    // passcode. Protected rows are unrelated to Apollo's ordinary Valet stores, so skip
    // them silently just like the recovery/diagnostic enumeration in Tweak.xm.
    const void *queryKeys[] = {
        kSecClass, kSecMatchLimit, kSecReturnAttributes, kSecReturnData,
        kSecUseAuthenticationUI,
    };
    const void *queryValues[] = {
        kSecClassGenericPassword, kSecMatchLimitAll, kCFBooleanTrue, kCFBooleanTrue,
        kSecUseAuthenticationUISkip,
    };
    CFDictionaryRef query = CFDictionaryCreate(kCFAllocatorDefault,
                                                queryKeys, queryValues, 5,
                                                &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    // Keyed by service+account so mirror-only items can be merged in without duplicating a key.
    NSMutableDictionary<NSString *, NSDictionary *> *byKey = [NSMutableDictionary dictionary];

    // The enumeration can fail (errSecMissingEntitlement -34018 on a broken-keychain device) or
    // return nothing (errSecItemNotFound) — the exact devices the mirror exists for. Don't early
    // return on that: fall through so the mirror merge below still runs and the backup carries
    // the account.
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching(query, &result);
    if (outStatus) *outStatus = st;
    CFRelease(query);
    if (st == errSecSuccess && result && CFGetTypeID(result) == CFArrayGetTypeID()) {
        CFArrayRef found = (CFArrayRef)result;
        for (CFIndex index = 0; index < CFArrayGetCount(found); index++) {
            CFTypeRef rawItem = CFArrayGetValueAtIndex(found, index);
            if (!rawItem || CFGetTypeID(rawItem) != CFDictionaryGetTypeID()) continue;
            CFDictionaryRef item = (CFDictionaryRef)rawItem;
            CFStringRef service = CFDictionaryGetValue(item, kSecAttrService);
            CFDataRef data = CFDictionaryGetValue(item, kSecValueData);
            if (!service || CFGetTypeID(service) != CFStringGetTypeID()) continue;
            if (!data || CFGetTypeID(data) != CFDataGetTypeID()) continue;
            CFStringRef account = CFDictionaryGetValue(item, kSecAttrAccount);
            NSString *serviceObject = (__bridge NSString *)service;
            NSString *accountObject = account && CFGetTypeID(account) == CFStringGetTypeID()
                ? (__bridge NSString *)account : @"";
            if (!ApolloBackupOwnsKeychainIdentity(serviceObject, accountObject)) continue;
            // The protection class isn't stored: it's recovered from the service name on replay
            // (see ApolloAccessibleFromValetService), which is poison-proof — an item captured on
            // an affected device carries the wrong class, but its service name still names the
            // right one.
            byKey[[NSString stringWithFormat:@"%@\n%@", serviceObject, accountObject]] = @{
                @"service": serviceObject,
                @"account": accountObject,
                @"data": (__bridge NSData *)data,
            };
        }
    }
    if (result) CFRelease(result);

    // Merge the container mirror. On a keychain-broken device the account item exists ONLY in
    // the mirror (the real keychain enumeration above missed it), and where both exist the
    // mirror value is the authoritative one (the real copy is the stale row that failed to
    // update), so mirror entries win.
    for (id item in ApolloKeychainMirrorItemsForBackup()) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *service = item[@"service"];
        NSData *data = item[@"data"];
        if (![data isKindOfClass:[NSData class]]) continue;
        // Mirror entries carry no protection class (the container mirror only stores
        // service/account/data), so a mirror-only item restores as AfterFirstUnlock — correct for
        // the keychain-broken devices the mirror exists for.
        NSString *acct = [item[@"account"] isKindOfClass:[NSString class]] ? item[@"account"] : @"";
        if (!ApolloBackupOwnsKeychainIdentity(service, acct)) continue;
        byKey[[NSString stringWithFormat:@"%@\n%@", service, acct]] = @{
            @"service": service, @"account": acct, @"data": data,
        };
    }

    return byKey.allValues;
}

// Valet encodes the accessibility it reads with into its service name
// (…_AccessibleAfterFirstUnlock), so that — not the item's stored class — is the class an item
// under that service MUST carry to be readable. Derive it from the service string, which is the
// same source of truth Valet uses. Returns NULL for a non-Valet or unrecognized service so the
// caller can fall back. Deliberately ignores whatever class the item was captured with: a backup
// taken on an already-affected device recorded WhenUnlocked (the poison), and replaying that
// faithfully would recreate an item its own reader can't see.
static CFStringRef ApolloAccessibleFromValetService(id service) {
    if (![service isKindOfClass:[NSString class]]) return NULL;
    NSRange r = [(NSString *)service rangeOfString:@"_Accessible" options:NSBackwardsSearch];
    if (r.location == NSNotFound) return NULL;
    NSString *suffix = [(NSString *)service substringFromIndex:r.location + r.length];
    if ([suffix isEqualToString:@"AfterFirstUnlock"])               return kSecAttrAccessibleAfterFirstUnlock;
    if ([suffix isEqualToString:@"AfterFirstUnlockThisDeviceOnly"]) return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    if ([suffix isEqualToString:@"WhenUnlocked"])                   return kSecAttrAccessibleWhenUnlocked;
    if ([suffix isEqualToString:@"WhenUnlockedThisDeviceOnly"])     return kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    if ([suffix isEqualToString:@"WhenPasscodeSetThisDeviceOnly"])  return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly;
    return NULL;
}

static NSArray<NSDictionary *> *ApolloBackupValidatedKeychainItems(id rawItems) {
    if (![rawItems isKindOfClass:NSArray.class]) return nil;
    NSMutableSet<NSString *> *identities = [NSMutableSet set];
    for (id item in rawItems) {
        if (![item isKindOfClass:NSDictionary.class] ||
            !ApolloBackupOwnsKeychainIdentity(item[@"service"], item[@"account"]) ||
            ![item[@"data"] isKindOfClass:NSData.class]) return nil;
        NSString *identity = [NSString stringWithFormat:@"%@\n%@", item[@"service"], item[@"account"]];
        if ([identities containsObject:identity]) return nil;
        [identities addObject:identity];
    }
    return rawItems;
}

// Read every original before changing any item. An unreadable old credential is
// not absence: abort rather than risking an update we cannot safely roll back.
static NSArray<NSDictionary *> *ApolloBackupCaptureReplayOriginals(NSArray<NSDictionary *> *items, OSStatus *outStatus) {
    NSMutableArray *originals = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        CFDictionaryRef query = ApolloCreateGenericPasswordDataQuery((__bridge CFStringRef)item[@"service"],
                                                                      (__bridge CFStringRef)item[@"account"]);
        NSMutableDictionary *read = [(__bridge NSDictionary *)query mutableCopy];
        CFRelease(query);
        read[(__bridge id)kSecReturnAttributes] = @YES;
        read[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUIFail;
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
        id found = CFBridgingRelease(result);
        if (status == -34018) {
            // This installed signing identity cannot update the real keychain;
            // its successful writes use Apollo's durable container mirror.
            // Preserve first restore on that cohort, including a fresh mirror.
            // Other read errors (locked/protected items) remain hard failures.
            NSDictionary *mirrored = nil;
            for (id candidate in ApolloKeychainMirrorItemsForBackup()) {
                if ([candidate isKindOfClass:NSDictionary.class] &&
                    [candidate[@"service"] isEqual:item[@"service"]] &&
                    [candidate[@"account"] isEqual:item[@"account"]]) { mirrored = candidate; break; }
            }
            if (mirrored) {
                if (![mirrored[@"data"] isKindOfClass:NSData.class]) {
                    if (outStatus) *outStatus = errSecDecode;
                    return nil;
                }
                [originals addObject:@{@"service": item[@"service"], @"account": item[@"account"], @"data": mirrored[@"data"]}];
                continue;
            }
        }
        if (status == errSecItemNotFound || status == -34018) {
            [originals addObject:@{@"service": item[@"service"], @"account": item[@"account"], @"absent": @YES}];
            continue;
        }
        NSData *data = [found isKindOfClass:NSDictionary.class] ? found[(__bridge id)kSecValueData] : found;
        if (status != errSecSuccess || ![data isKindOfClass:NSData.class]) {
            if (outStatus) *outStatus = status == errSecSuccess ? errSecDecode : status;
            return nil;
        }
        id accessible = [found isKindOfClass:NSDictionary.class] ? found[(__bridge id)kSecAttrAccessible] : nil;
        NSMutableDictionary *original = [@{@"service": item[@"service"], @"account": item[@"account"], @"data": data} mutableCopy];
        if ([accessible isKindOfClass:NSString.class]) original[@"accessible"] = accessible;
        [originals addObject:original];
    }
    return originals;
}

static OSStatus ApolloBackupReplayItem(NSDictionary *item) {
    CFStringRef accessible = ApolloAccessibleFromValetService(item[@"service"]);
    return ApolloUpsertGenericPasswordData((__bridge CFStringRef)item[@"service"],
                                          (__bridge CFStringRef)item[@"account"], item[@"data"],
                                          accessible ?: kSecAttrAccessibleAfterFirstUnlock);
}

static BOOL ApolloBackupRollbackKeychainItems(NSArray<NSDictionary *> *originals) {
    BOOL restored = YES;
    for (NSDictionary *item in originals.reverseObjectEnumerator) {
        OSStatus status;
        if ([item[@"absent"] boolValue]) {
            CFDictionaryRef identity = ApolloCreateGenericPasswordIdentity((__bridge CFStringRef)item[@"service"],
                                                                            (__bridge CFStringRef)item[@"account"]);
            status = SecItemDelete(identity);
            CFRelease(identity);
            if (status == errSecItemNotFound) status = errSecSuccess;
        } else {
            CFStringRef accessible = item[@"accessible"] ? (__bridge CFStringRef)item[@"accessible"]
                : ApolloAccessibleFromValetService(item[@"service"]);
            status = ApolloUpsertGenericPasswordData((__bridge CFStringRef)item[@"service"],
                                                    (__bridge CFStringRef)item[@"account"], item[@"data"],
                                                    accessible ?: kSecAttrAccessibleAfterFirstUnlock);
        }
        if (status != errSecSuccess) restored = NO;
    }
    return restored;
}

// Validation runs again at the write boundary, so a malformed caller can never
// reach a keychain API. Roll back the successful prefix: a failed native update
// does not change its item, and ApolloMirrorPut restores its old entry on failure.
static BOOL ApolloReplayValetKeychainItems(NSArray<NSDictionary *> *items,
                                         NSArray<NSDictionary *> *originals,
                                         BOOL *rollbackSucceeded, OSStatus *outStatus) {
    if (rollbackSucceeded) *rollbackSucceeded = YES;
    if (!ApolloBackupValidatedKeychainItems(items) || originals.count != items.count) {
        if (outStatus) *outStatus = errSecParam;
        return NO;
    }
    for (NSUInteger index = 0; index < items.count; index++) {
        OSStatus status = ApolloBackupReplayItem(items[index]);
        if (status != errSecSuccess) {
            if (outStatus) *outStatus = status;
            BOOL rolledBack = ApolloBackupRollbackKeychainItems([originals subarrayWithRange:NSMakeRange(0, index)]);
            if (rollbackSucceeded) *rollbackSucceeded = rolledBack;
            ApolloLog(@"[BackupRestore] Valet replay failed (OSStatus %d), rollback %@", (int)status, rolledBack ? @"succeeded" : @"failed");
            return NO;
        }
    }
    return YES;
}

// Default: Library/Preferences/com.christianselig.Apollo.plist, depending on bundle ID.
// Contains: most Apollo settings
NSString *ApolloMainPreferencesPath(void) {
    NSString *containerPath = NSHomeDirectory();
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSString *plistName = [NSString stringWithFormat:@"Library/Preferences/%@.plist", bundleId];
    return [containerPath stringByAppendingPathComponent:plistName];
}

// Should always Library/Preferences/group.com.christianselig.apollo.plist, no matter the bundle ID.
// Contains: theme settings, keyword filters, some account state
NSString *ApolloGroupPreferencesPath(void) {
    NSString *containerPath = NSHomeDirectory();
    NSString *plistName = [NSString stringWithFormat:@"Library/Preferences/%@.plist", kGroupSuiteName];
    return [containerPath stringByAppendingPathComponent:plistName];
}

// User-presentable failure for ApolloBackupRestoreCreateBackupZip — the message goes
// straight into the caller's "Backup Failed" alert.
static NSError *ApolloBackupRestoreError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloBackupRestore" code:1
                           userInfo:@{ NSLocalizedDescriptionKey: (message ?: @"") }];
}

// Freeze nested arrays/dictionaries as well as the envelope before leaving the
// main queue. The disk/keychain/compression phase must never inspect mutable
// Apollo objects while its UI is changing them.
static NSDictionary *ApolloBackupImmutablePreferences(NSDictionary *preferences) {
    if (!preferences) return nil;
    return CFBridgingRelease(CFPropertyListCreateDeepCopy(kCFAllocatorDefault,
                                                        (__bridge CFPropertyListRef)preferences,
                                                        kCFPropertyListImmutable));
}

static BOOL ApolloBackupWritePlist(id propertyList, NSString *path) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:propertyList
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0 error:nil];
    return data && [data writeToFile:path
                            options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                              error:nil];
}

// Atomically reserve the output name: a manual backup and an automatic backup
// can finish within the same second. File-exists-then-create would let one ZIP
// truncate the other's archive. The reserved file is protected before minizip
// opens it for writing, and its filename remains familiar when no collision occurs.
static NSString *ApolloBackupReserveZipPath(NSFileManager *fileManager, NSError **error) {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.dateFormat = @"yyyy-MM-dd_HHmmss";
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        NSString *suffix = attempt == 0 ? @"" : [@"_" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *filename = [NSString stringWithFormat:@"Apollo_Backup_%@%@.zip", timestamp, suffix];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
        int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (descriptor < 0) {
            if (errno == EEXIST) continue;
            break;
        }
        close(descriptor);
        if ([fileManager setAttributes:@{ NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication }
                           ofItemAtPath:path error:nil]) {
            return path;
        }
        [fileManager removeItemAtPath:path error:nil];
        break;
    }
    if (error) *error = ApolloBackupRestoreError(@"Could not create a protected temporary backup file.");
    return nil;
}

NSURL *ApolloBackupRestoreCreateBackupZip(NSError **error) {
    if (error) *error = nil;
    __block NSDictionary *mainPrefs = nil;
    __block NSDictionary *groupPrefs = nil;
    __block NSError *snapshotError = nil;
    void (^capturePreferences)(void) = ^{
        // The tracker uses its own queue for its ordered-set snapshot; its
        // cached runtime lookup and the favorites account state are main-owned.
        // Neither helper dispatches work to the archive caller's queue.
        ApolloFlushReadPostIDsToDefaults();
        NSDictionary *favoritesState = ApolloPerAccountFavoritesCopyBackupPreferenceValues();
        if (!favoritesState) {
            snapshotError = ApolloBackupRestoreError(
                @"Could not capture favorites while the active account is changing. Please try again.");
            return;
        }

        // A persistent-domain snapshot includes every current saved setting,
        // even before cfprefsd writes its plist, while excluding registerDefaults
        // and unrelated global defaults from dictionaryRepresentation.
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *preferences = [[defaults persistentDomainForName:bundleID] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        for (NSString *key in favoritesState) {
            id value = favoritesState[key];
            if (value != NSNull.null) preferences[key] = value;
            else [preferences removeObjectForKey:key];
        }
        mainPrefs = ApolloBackupImmutablePreferences(preferences);
        NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName];
        groupPrefs = ApolloBackupImmutablePreferences([groupDefaults persistentDomainForName:kGroupSuiteName]);
        if (!mainPrefs) {
            snapshotError = ApolloBackupRestoreError(@"Could not capture the latest preferences for backup.");
        }
    };
    if (NSThread.isMainThread) capturePreferences();
    else dispatch_sync(dispatch_get_main_queue(), capturePreferences);
    if (snapshotError) {
        if (error) *error = snapshotError;
        return nil;
    }

    NSFileManager *fileManager = [[NSFileManager alloc] init];
    // Unprovisioned/sideloaded group suites can live in the app container.
    // Preserve that legacy source only when there was no live suite domain;
    // an explicitly empty live domain must not revive stale on-disk keys.
    NSString *groupPlistPath = ApolloGroupPreferencesPath();
    if (!groupPrefs && [fileManager fileExistsAtPath:groupPlistPath]) {
        groupPrefs = [NSDictionary dictionaryWithContentsOfFile:groupPlistPath];
        if (!groupPrefs) {
            if (error) *error = ApolloBackupRestoreError(@"Could not read the shared Apollo preferences for backup.");
            return nil;
        }
    }

    OSStatus keychainStatus = errSecSuccess;
    NSArray *keychainItems = ApolloCaptureValetKeychainItems(&keychainStatus);
    NSDictionary *accountDetails = groupPrefs[@"LoggedInAccountDetails"];
    BOOL hasAccounts = [accountDetails isKindOfClass:NSDictionary.class] && accountDetails.count > 0;
    BOOL capturedAccountCredentials = NO;
    for (NSDictionary *item in keychainItems) {
        NSString *account = item[@"account"];
        NSData *data = item[@"data"];
        if ([account isKindOfClass:NSString.class] && [account containsString:@"RedditAccounts2"] &&
            [data isKindOfClass:NSData.class] && data.length > 0) {
            capturedAccountCredentials = YES;
            break;
        }
    }
    if (hasAccounts && !capturedAccountCredentials) {
        // Empty/no-account installs still back up settings, including ad-hoc
        // installs without keychain access. A known signed-in account must not
        // silently disappear when the keychain is temporarily inaccessible.
        // Capturing only an Ultra flag or app-only token is not sufficient,
        // even if the enumeration itself reported success. The canonical
        // account-secrets key is 2RedditAccounts2; the mirror merge counts too.
        ApolloLog(@"[BackupRestore] Could not capture account credentials (OSStatus %d)", (int)keychainStatus);
        if (error) *error = ApolloBackupRestoreError(@"Could not read the saved account credentials. Unlock your device and try again.");
        return nil;
    }

    NSString *backupDir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSDictionary *directoryAttributes = @{
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
        NSFilePosixPermissions: @0700,
    };
    if (![fileManager createDirectoryAtPath:backupDir withIntermediateDirectories:YES
                                 attributes:directoryAttributes error:nil]) {
        [fileManager removeItemAtPath:backupDir error:nil];
        if (error) *error = ApolloBackupRestoreError(@"Could not create a protected temporary directory.");
        return nil;
    }

    // Keep one cleanup path for every write and compression failure; the staging
    // directory and a partial ZIP both contain credentials and must not linger.
    __block NSString *zipPath = nil;
    __block NSError *archiveError = nil;
    BOOL success = ^BOOL {
        if (!ApolloBackupWritePlist(mainPrefs, [backupDir stringByAppendingPathComponent:kMainPlistFilename])) {
            archiveError = ApolloBackupRestoreError(@"Could not write the preferences for backup.");
            return NO;
        }
        if (groupPrefs && !ApolloBackupWritePlist(groupPrefs, [backupDir stringByAppendingPathComponent:kGroupPlistFilename])) {
            archiveError = ApolloBackupRestoreError(@"Could not write the shared preferences for backup.");
            return NO;
        }
        if (hasAccounts) {
            NSMutableArray<NSString *> *usernames = [NSMutableArray array];
            for (id username in accountDetails.allValues) {
                if ([username isKindOfClass:NSString.class]) [usernames addObject:username];
            }
            NSData *accountsData = [[usernames componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            if (![accountsData writeToFile:[backupDir stringByAppendingPathComponent:kAccountsFilename]
                                   options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                                     error:nil]) {
                archiveError = ApolloBackupRestoreError(@"Could not write the account list for backup.");
                return NO;
            }
        }
        // Always write the captured array, including a valid empty capture. A
        // disk failure here must never report an account-restorable backup.
        if (!ApolloBackupWritePlist(keychainItems, [backupDir stringByAppendingPathComponent:kKeychainPlistFilename])) {
            archiveError = ApolloBackupRestoreError(@"Could not write the saved account credentials for backup.");
            return NO;
        }
        zipPath = ApolloBackupReserveZipPath(fileManager, &archiveError);
        if (!zipPath) return NO;
        if (![SSZipArchive createZipFileAtPath:zipPath withContentsOfDirectory:backupDir]) {
            archiveError = ApolloBackupRestoreError(@"Could not create backup archive.");
            return NO;
        }
        return YES;
    }();

    [fileManager removeItemAtPath:backupDir error:nil];
    if (!success) {
        if (zipPath) [fileManager removeItemAtPath:zipPath error:nil];
        if (error) *error = archiveError;
        return nil;
    }
    return [NSURL fileURLWithPath:zipPath isDirectory:NO];
}

// Current and legacy exporters contain only these flat files. Reject duplicate
// names, links, directories and unexpected paths before the ZIP can extract them.
static BOOL ApolloBackupArchiveHasSafeEntries(NSURL *url) {
    unzFile archive = unzOpen(url.fileSystemRepresentation);
    if (!archive) return NO;
    BOOL valid = NO;
    @try {
        unz_global_info64 info = {0};
        if (unzGetGlobalInfo64(archive, &info) != UNZ_OK || info.number_entry < 1 || info.number_entry > 4) return NO;
        NSSet *allowed = [NSSet setWithArray:@[kMainPlistFilename, kGroupPlistFilename, kKeychainPlistFilename, kAccountsFilename]];
        NSMutableSet *seen = [NSMutableSet set];
        // Settings backups contain plists and a username list, never media.
        // This generous ceiling prevents a tiny ZIP exhausting the device.
        uint64_t const maximumBytes = 128ULL * 1024 * 1024;
        uint64_t totalBytes = 0;
        uint64_t inflatedBytes = 0;
        uint8_t buffer[64 * 1024];
        int status = unzGoToFirstFile(archive);
        for (uint64_t index = 0; index < info.number_entry; index++) {
            unz_file_info64 entry = {0};
            char filename[128] = {0};
            if (status != UNZ_OK || unzGetCurrentFileInfo64(archive, &entry, filename, sizeof(filename), NULL, 0, NULL, 0) != UNZ_OK ||
                entry.size_filename == 0 || entry.size_filename >= sizeof(filename)) return NO;
            if (entry.uncompressed_size > maximumBytes - totalBytes) return NO;
            totalBytes += entry.uncompressed_size;
            NSString *name = [[NSString alloc] initWithBytes:filename length:entry.size_filename encoding:NSUTF8StringEncoding];
            mode_t kind = (mode_t)(entry.external_fa >> 16) & S_IFMT;
            if (!name || ![allowed containsObject:name] || [seen containsObject:name] ||
                (kind && kind != S_IFREG) || (entry.external_fa & 0x10)) return NO;
            // Do not trust advertised sizes alone: minizip can inflate an
            // entry whose header says zero bytes. Bound the actual stream and
            // require its byte count and CRC to agree before any extraction.
            if (unzOpenCurrentFile(archive) != UNZ_OK) return NO;
            uint64_t entryBytes = 0;
            BOOL contentValid = YES;
            int bytesRead = 0;
            while ((bytesRead = unzReadCurrentFile(archive, buffer, sizeof(buffer))) > 0) {
                uint64_t amount = (uint64_t)bytesRead;
                if (amount > maximumBytes - inflatedBytes || amount > entry.uncompressed_size - entryBytes) {
                    contentValid = NO;
                    break;
                }
                entryBytes += amount;
                inflatedBytes += amount;
            }
            if (bytesRead < 0 || entryBytes != entry.uncompressed_size) contentValid = NO;
            int closeStatus = unzCloseCurrentFile(archive);
            if (!contentValid || closeStatus != UNZ_OK) return NO;
            [seen addObject:name];
            status = unzGoToNextFile(archive);
        }
        valid = status == UNZ_END_OF_LIST_OF_FILE && [seen containsObject:kMainPlistFilename];
    } @finally {
        unzClose(archive);
    }
    return valid;
}

// Missing optional files are valid old backups; a present unreadable, malformed
// or wrongly typed file rejects the whole backup before defaults/keychain change.
static id ApolloBackupReadRestorePlist(NSString *path, Class expectedClass, BOOL required, BOOL *valid) {
    NSError *error = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:&error];
    if (!attributes) {
        if (required || ![error.domain isEqualToString:NSCocoaErrorDomain] || error.code != NSFileReadNoSuchFileError) *valid = NO;
        return nil;
    }
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) { *valid = NO; return nil; }
    NSData *data = [NSData dataWithContentsOfFile:path];
    id contents = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
    if (![contents isKindOfClass:expectedClass]) { *valid = NO; return nil; }
    return contents;
}

static BOOL ApolloBackupPreferencesMatchSchema(NSDictionary *preferences, NSDictionary *schema) {
    NSArray<Class> *types = @[NSString.class, NSNumber.class, NSArray.class, NSDictionary.class, NSData.class, NSDate.class];
    for (id key in preferences) {
        if (![key isKindOfClass:NSString.class]) return NO;
        id expected = schema[key];
        if (!expected) continue;
        for (Class type in types) {
            if ([expected isKindOfClass:type] && ![preferences[key] isKindOfClass:type]) return NO;
        }
    }
    return YES;
}

static BOOL ApolloBackupValidMainPreferences(NSDictionary *preferences) {
    NSDictionary *registered = [NSUserDefaults.standardUserDefaults volatileDomainForName:NSRegistrationDomain];
    if (!ApolloBackupPreferencesMatchSchema(preferences, registered)) return NO;
    // Some settings have no registered default but are read as strings during
    // restore's immediate in-memory synchronization. Validate those too.
    NSArray *stringKeys = @[
        UDKeyAISummaryProvider, UDKeyCustomAIAPIKey, UDKeyCustomAIBaseURL,
        UDKeyCustomAIModel, UDKeyGeminiAIModel, UDKeyGeminiAPIKey,
        UDKeyImageChestAPIToken, UDKeyImgurClientId, UDKeyLibreTranslateAPIKey,
        UDKeyLibreTranslateURL, UDKeyLinkPreviewCardColorHex, UDKeyOpenRouterAIModel,
        UDKeyOpenRouterAPIKey, UDKeyRandNsfwSubredditsSource, UDKeyRandomSubredditsSource,
        UDKeyRedditClientId, UDKeyRedditClientSecret, UDKeyRedirectURI,
        UDKeyTranslationProvider, UDKeyTranslationTargetLanguage, UDKeyTrendingSubredditsLimit,
        UDKeyTrendingSubredditsSource, UDKeyUserAgent,
    ];
    for (NSString *key in stringKeys) {
        if (preferences[key] && ![preferences[key] isKindOfClass:NSString.class]) return NO;
    }
    return YES;
}

static BOOL ApolloBackupValidGroupPreferences(NSDictionary *preferences) {
    NSDictionary *schema = @{@"LoggedInAccountDetails": @{}, @"CurrentRedditAccountIndex": @0,
        @"RedditAccounts2": [NSData data], @"RedditApplicationOnlyAccount2": [NSData data]};
    return ApolloBackupPreferencesMatchSchema(preferences, schema);
}

BOOL ApolloBackupRestoreRestoreFromZipURL(NSURL *zipURL, NSString **outErrorTitle, NSString **outErrorMessage) {
    NSString *tempDir = NSTemporaryDirectory();
    NSString *extractDir = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    if (![fileManager createDirectoryAtPath:extractDir withIntermediateDirectories:YES
                                 attributes:@{
                                     NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
                                     NSFilePosixPermissions: @0700,
                                 } error:nil]) {
        [fileManager removeItemAtPath:extractDir error:nil];
        if (outErrorTitle) *outErrorTitle = @"Restore Failed";
        if (outErrorMessage) *outErrorMessage = @"Could not create a protected temporary directory.";
        return NO;
    }

    BOOL scoped = [zipURL startAccessingSecurityScopedResource];
    NSError *error = nil;
    BOOL safeArchive = ApolloBackupArchiveHasSafeEntries(zipURL);
    BOOL success = safeArchive && [SSZipArchive unzipFileAtPath:zipURL.path toDestination:extractDir overwrite:NO password:nil error:&error];
    if (scoped) [zipURL stopAccessingSecurityScopedResource];

    if (!success) {
        [fileManager removeItemAtPath:extractDir error:nil];
        if (outErrorTitle) *outErrorTitle = safeArchive ? @"Restore Failed" : @"Invalid Backup";
        if (outErrorMessage) *outErrorMessage = safeArchive ? @"Could not extract backup archive." : @"The archive contains unexpected, duplicate, or unsafe backup files.";
        return NO;
    }

    BOOL valid = YES;
    NSDictionary *mainPrefs = ApolloBackupReadRestorePlist([extractDir stringByAppendingPathComponent:kMainPlistFilename], NSDictionary.class, YES, &valid);
    NSDictionary *groupPrefs = ApolloBackupReadRestorePlist([extractDir stringByAppendingPathComponent:kGroupPlistFilename], NSDictionary.class, NO, &valid);
    NSArray *rawKeychain = ApolloBackupReadRestorePlist([extractDir stringByAppendingPathComponent:kKeychainPlistFilename], NSArray.class, NO, &valid);
    NSArray *keychainItems = rawKeychain ? ApolloBackupValidatedKeychainItems(rawKeychain) : @[];
    if (!valid || !mainPrefs || !ApolloBackupValidMainPreferences(mainPrefs) ||
        (groupPrefs && !ApolloBackupValidGroupPreferences(groupPrefs)) || !keychainItems) {
        [fileManager removeItemAtPath:extractDir error:nil];
        if (outErrorTitle) *outErrorTitle = @"Invalid Backup";
        if (outErrorMessage) *outErrorMessage = @"A settings or credentials file is malformed or contains unsupported keychain records. Nothing was restored.";
        return NO;
    }

    OSStatus replayStatus = errSecSuccess;
    NSArray *originalItems = ApolloBackupCaptureReplayOriginals(keychainItems, &replayStatus);
    if (!originalItems) {
        [fileManager removeItemAtPath:extractDir error:nil];
        if (outErrorTitle) *outErrorTitle = @"Restore Failed";
        if (outErrorMessage) *outErrorMessage = @"Could not read the existing account credentials safely. Unlock the device and try again. Nothing was restored.";
        return NO;
    }

    // Stop archive publication before credential mutation, without waiting for
    // worker capture that may need main. Favorites are not suspended until the
    // checked keychain transaction succeeds, so a rejected restore stays usable.
    ApolloAutomaticBackup *backupManager = ApolloAutomaticBackup.sharedManager;
    [backupManager suspendForSettingsRestore];
    BOOL rollbackSucceeded = YES;
    if (!ApolloReplayValetKeychainItems(keychainItems, originalItems, &rollbackSucceeded, &replayStatus)) {
        [fileManager removeItemAtPath:extractDir error:nil];
        if (rollbackSucceeded) [backupManager resumeAfterFailedSettingsRestore];
        if (outErrorTitle) *outErrorTitle = rollbackSucceeded ? @"Restore Failed" : @"Restore Incomplete";
        if (outErrorMessage) *outErrorMessage = rollbackSucceeded
            ? @"Could not restore the account credentials. The previous credentials and settings were preserved. Unlock the device and try again."
            : @"Some account credentials could not be restored or recovered. Settings were not changed. Close and reopen Apollo, then verify your accounts before trying again.";
        return NO;
    }
    ApolloPerAccountFavoritesSuspendForPreferencesRestore();

    // Restore main preferences, skipping analytics/tracking keys
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bundleId];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in mainPrefs) {
        if ([key isEqualToString:@"BugsnagUserUserId"] || [key hasPrefix:@"com.Statsig."]) {
            continue;
        }
        [defaults setObject:mainPrefs[key] forKey:key];
    }
    [defaults synchronize];

    // Sync in-memory globals with restored values.
    //
    // Intentionally partial: only the statics whose stale values could matter before the
    // process dies are re-synced here. Restore always force-exits — the caller's success
    // alert has a single action that calls exit(0) — and %ctor re-reads every default on
    // the next launch, so anything missing from this list self-heals on relaunch.
    sRedditClientId = [defaults stringForKey:UDKeyRedditClientId];
    sRedditClientSecret = [defaults stringForKey:UDKeyRedditClientSecret] ?: @"";
    sImgurClientId = [defaults stringForKey:UDKeyImgurClientId];
    sImageChestAPIToken = [defaults stringForKey:UDKeyImageChestAPIToken];
    sRedirectURI = [defaults stringForKey:UDKeyRedirectURI];
    sUserAgent = [defaults stringForKey:UDKeyUserAgent];
    sBlockAnnouncements = [defaults boolForKey:UDKeyBlockAnnouncements];
    sTrendingSubredditsSource = [defaults stringForKey:UDKeyTrendingSubredditsSource];    sRandomSubredditsSource = [defaults stringForKey:UDKeyRandomSubredditsSource];
    sRandNsfwSubredditsSource = [defaults stringForKey:UDKeyRandNsfwSubredditsSource];
    sTrendingSubredditsLimit = [defaults stringForKey:UDKeyTrendingSubredditsLimit];
    sReadPostMaxCount = [defaults integerForKey:UDKeyReadPostMaxCount];
    sShowDeletedComments = [defaults boolForKey:UDKeyShowDeletedComments];
    sTapToRevealDeletedComments = [defaults boolForKey:UDKeyTapToRevealDeletedComments];
    sPassiveDeletedComments = [defaults boolForKey:UDKeyPassiveDeletedComments];
    sPerPostCommentSort = [defaults boolForKey:UDKeyPerPostCommentSort];
    // A restored backup can carry both sort memories on (older build); they are
    // mutually exclusive (see ApolloPerPostCommentSort.xm) and per-post wins.
    if (sPerPostCommentSort && [defaults boolForKey:UDKeyApolloRememberSubredditCommentsSort]) {
        [defaults setBool:NO forKey:UDKeyApolloRememberSubredditCommentsSort];
    }
    sShowRecentlyReadThumbnails = [defaults boolForKey:UDKeyShowRecentlyReadThumbnails];
    sEnableFlairColors = [defaults boolForKey:UDKeyEnableFlairColors];
    sPreferredGIFFallbackFormat = ([defaults integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sUnmuteCommentsVideos = [defaults integerForKey:UDKeyUnmuteCommentsVideos];
    sVideoHoldSpeedEnabled = [defaults boolForKey:UDKeyVideoHoldSpeedEnabled];
    sVideoHoldSpeed = ApolloSanitizedHoldSpeed([defaults floatForKey:UDKeyVideoHoldSpeed]);
    sImageUploadProvider = [defaults integerForKey:UDKeyImageUploadProvider];
    sCommentLinkHost = [defaults integerForKey:UDKeyCommentLinkHost];
    if (sCommentLinkHost < CommentLinkHostOff || sCommentLinkHost > CommentLinkHostImgChest) sCommentLinkHost = CommentLinkHostOff;
    sLinkPreviewCardColor = [defaults integerForKey:UDKeyLinkPreviewCardColor];
    if (sLinkPreviewCardColor < ApolloLinkPreviewCardColorNeutral || sLinkPreviewCardColor > ApolloLinkPreviewCardColorSlate) {
        sLinkPreviewCardColor = ApolloLinkPreviewCardColorNeutral;
        [defaults setInteger:sLinkPreviewCardColor forKey:UDKeyLinkPreviewCardColor];
    }
    // Free-form hex card color. A backup made by a build with the color picker
    // carries the hex key directly; otherwise the card starts neutral (the legacy
    // preset enum is not promoted to a full-card fill — see Tweak.xm).
    NSString *restoredCardColorHex = [defaults stringForKey:UDKeyLinkPreviewCardColorHex];
    if (![defaults objectForKey:UDKeyLinkPreviewCardColorHex]) {
        restoredCardColorHex = @"";
        [defaults setObject:@"" forKey:UDKeyLinkPreviewCardColorHex];
    }
    ApolloSetLinkPreviewCardColorHex(restoredCardColorHex);
    sEnableBulkTranslation = [defaults boolForKey:UDKeyEnableBulkTranslation];
    sAutoTranslateOnAppear = [defaults boolForKey:UDKeyAutoTranslateOnAppear];
    sTapToTranslate = [defaults boolForKey:UDKeyTapToTranslate];
    sShowTranslationDetails = [defaults boolForKey:UDKeyShowTranslationDetails];
    sShowTranslationTitleDetails = [defaults boolForKey:UDKeyShowTranslationTitleDetails];
    sTranslationMarkerUseThemeColor = [defaults boolForKey:UDKeyTranslationMarkerUseThemeColor];

    NSString *targetLanguage = [defaults stringForKey:UDKeyTranslationTargetLanguage];
    sTranslationTargetLanguage = targetLanguage.length > 0 ? targetLanguage : nil;

    NSString *provider = [defaults stringForKey:UDKeyTranslationProvider];
    if ([provider isEqualToString:@"libre"]) {
        sTranslationProvider = @"libre";
    } else if ([provider isEqualToString:@"google"]) {
        sTranslationProvider = @"google";
    } else if ([provider isEqualToString:@"microsoft"]) {
        sTranslationProvider = @"microsoft";
    } else if ([provider isEqualToString:@"apple"] && IsAppleTranslationSupported()) {
        sTranslationProvider = @"apple";
    } else {
        // Unset, unrecognized, or "apple" on an unsupported OS — default to Google.
        sTranslationProvider = @"google";
        [defaults setObject:sTranslationProvider forKey:UDKeyTranslationProvider];
        [defaults setBool:NO forKey:UDKeyTranslationProviderUserSelected];
    }

    // Restored backups can carry the dead libretranslate.de default (issue
    // #995) — normalize exactly like %ctor does.
    NSString *libreURL = [defaults stringForKey:UDKeyLibreTranslateURL];
    sLibreTranslateURL = [ApolloNormalizedLibreTranslateURLSetting(libreURL) copy];

    NSString *libreAPIKey = [defaults stringForKey:UDKeyLibreTranslateAPIKey];
    sLibreTranslateAPIKey = libreAPIKey.length > 0 ? libreAPIKey : nil;
    // The Microsoft key/region statics are deliberately NOT re-synced here:
    // restore force-exits and %ctor re-reads everything on relaunch, and the
    // re-sync list is intentionally partial (see src/settings/README.md). The
    // provider chain above still needs its "microsoft" arm, though — the else
    // branch persists "google" back to defaults, which would corrupt a restored
    // Microsoft selection before the relaunch.

    // AI summary backend + per-provider cloud credentials (same sanitize rules
    // as the launch-time load in Tweak.xm: unknown provider → apple, empty → nil).
    NSString *aiProvider = [defaults stringForKey:UDKeyAISummaryProvider];
    if ([aiProvider isEqualToString:@"openrouter"] || [aiProvider isEqualToString:@"gemini"] ||
        [aiProvider isEqualToString:@"custom"] || [aiProvider isEqualToString:@"apple"]) {
        sAISummaryProvider = aiProvider;
    } else {
        sAISummaryProvider = @"apple";
    }
    NSString *(^aiKey)(NSString *) = ^NSString *(NSString *udKey) {
        NSString *v = [[defaults stringForKey:udKey] stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return v.length > 0 ? v : nil;
    };
    sOpenRouterAPIKey = aiKey(UDKeyOpenRouterAPIKey);
    sOpenRouterAIModel = aiKey(UDKeyOpenRouterAIModel);
    sGeminiAPIKey = aiKey(UDKeyGeminiAPIKey);
    sGeminiAIModel = aiKey(UDKeyGeminiAIModel);
    sCustomAIAPIKey = aiKey(UDKeyCustomAIAPIKey);
    sCustomAIModel = aiKey(UDKeyCustomAIModel);
    sCustomAIBaseURL = aiKey(UDKeyCustomAIBaseURL);

    // Restore group preferences, including the NSUserDefaults account state
    // (LoggedInAccountDetails, CurrentRedditAccountIndex, and the RedditAccounts2 /
    // RedditApplicationOnlyAccount2 mirrors). Apollo's AccountManager actually loads accounts
    // from the *keychain* via Valet on launch — gated behind Valet.canAccessKeychain() — so
    // these defaults alone don't sign the user in; the checked keychain replay above does.
    //
    // Non-destructive by design: only keys present in the backup are written. A backup made
    // while logged out has no account keys, so the current install's accounts are left
    // intact rather than wiped.
    if (groupPrefs) {
        NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGroupSuiteName];
        for (NSString *key in groupPrefs) [groupDefaults setObject:groupPrefs[key] forKey:key];
        [groupDefaults synchronize];
    }

    [fileManager removeItemAtPath:extractDir error:nil];
    return YES;
}
