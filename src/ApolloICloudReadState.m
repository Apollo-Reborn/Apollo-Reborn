#import "ApolloICloudReadState.h"

#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <Security/Security.h>
#import <limits.h>
#if !defined(APOLLO_ICLOUD_READ_STATE_TESTS)
#import <UIKit/UIKit.h>
#import "ApolloCommon.h"
#import "ApolloPostReadState.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#endif
#import <math.h>

static NSString *const kJournalVersion = @"v";
static NSString *const kJournalWriter = @"w";
static NSString *const kJournalClear = @"clear";
static NSString *const kJournalGeneration = @"g";
static NSString *const kJournalRecords = @"records";
static NSString *const kRecordRead = @"r";
static NSString *const kRecordUnread = @"u";
static NSString *const kRecordCommentTime = @"c";
static NSString *const kRecordCommentCount = @"n";
static NSString *const kRecordWriter = @"w";
static NSString *const kCloudStateKey = @"ApolloReadStateSync.v1";
static NSString *const kEncryptionKeyService = @"app.apolloreborn.icloud-read-state";
static NSString *const kEncryptionKeyAccount = @"v1";
static NSUInteger const kMaximumJournalRecords = 6500;
static NSUInteger const kMaximumJournalBytes = 900 * 1024;
static const uint8_t kEncryptedMagic[] = {'A', 'R', 'S', '1'};

NSData *ApolloICloudReadStateResetMarker(long long generation) {
    NSDictionary *marker = @{@"reset": @(MAX(1, generation))};
    return [NSPropertyListSerialization dataWithPropertyList:marker
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

BOOL ApolloICloudReadStateParseResetMarker(NSData *data, long long *generation) {
    id marker = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    NSNumber *value = [marker isKindOfClass:NSDictionary.class] &&
        [marker[@"reset"] isKindOfClass:NSNumber.class] ? marker[@"reset"] : nil;
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() || value.longLongValue < 1) return NO;
    if (generation) *generation = value.longLongValue;
    return YES;
}

static NSData *ApolloICloudReadStateDerivedKey(NSData *masterKey, const char *label) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, masterKey.bytes, masterKey.length, label, strlen(label), digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSError *ApolloICloudReadStateCryptoError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloICloudReadStateCrypto" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSData *ApolloICloudReadStateEncrypt(NSData *plaintext, NSData *key, NSError **error) {
    if (key.length != 32 || !plaintext) {
        if (error) *error = ApolloICloudReadStateCryptoError(@"Invalid encryption input.");
        return nil;
    }
    NSMutableData *iv = [NSMutableData dataWithLength:kCCBlockSizeAES128];
    if (SecRandomCopyBytes(kSecRandomDefault, iv.length, iv.mutableBytes) != errSecSuccess) {
        if (error) *error = ApolloICloudReadStateCryptoError(@"Could not create encryption randomness.");
        return nil;
    }
    NSData *encryptionKey = ApolloICloudReadStateDerivedKey(key, "encryption");
    NSMutableData *ciphertext = [NSMutableData dataWithLength:plaintext.length + kCCBlockSizeAES128];
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        encryptionKey.bytes, encryptionKey.length, iv.bytes, plaintext.bytes, plaintext.length,
        ciphertext.mutableBytes, ciphertext.length, &written);
    if (status != kCCSuccess) {
        if (error) *error = ApolloICloudReadStateCryptoError(@"Could not encrypt read history.");
        return nil;
    }
    ciphertext.length = written;
    NSMutableData *body = [NSMutableData dataWithBytes:kEncryptedMagic length:sizeof(kEncryptedMagic)];
    [body appendData:iv];
    [body appendData:ciphertext];
    NSData *authenticationKey = ApolloICloudReadStateDerivedKey(key, "authentication");
    uint8_t mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, authenticationKey.bytes, authenticationKey.length,
           body.bytes, body.length, mac);
    [body appendBytes:mac length:sizeof(mac)];
    return body;
}

NSData *ApolloICloudReadStateDecrypt(NSData *envelope, NSData *key, NSError **error) {
    NSUInteger overhead = sizeof(kEncryptedMagic) + kCCBlockSizeAES128 + CC_SHA256_DIGEST_LENGTH;
    if (key.length != 32 || envelope.length <= overhead ||
        memcmp(envelope.bytes, kEncryptedMagic, sizeof(kEncryptedMagic)) != 0) {
        if (error) *error = ApolloICloudReadStateCryptoError(@"Invalid encrypted read history.");
        return nil;
    }
    NSRange bodyRange = NSMakeRange(0, envelope.length - CC_SHA256_DIGEST_LENGTH);
    NSData *body = [envelope subdataWithRange:bodyRange];
    const uint8_t *storedMAC = (const uint8_t *)envelope.bytes + body.length;
    NSData *authenticationKey = ApolloICloudReadStateDerivedKey(key, "authentication");
    uint8_t expectedMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, authenticationKey.bytes, authenticationKey.length,
           body.bytes, body.length, expectedMAC);
    uint8_t difference = 0;
    for (NSUInteger i = 0; i < sizeof(expectedMAC); i++) difference |= expectedMAC[i] ^ storedMAC[i];
    if (difference != 0) {
        if (error) *error = ApolloICloudReadStateCryptoError(@"Encrypted read history failed authentication.");
        return nil;
    }
    NSData *iv = [envelope subdataWithRange:NSMakeRange(sizeof(kEncryptedMagic), kCCBlockSizeAES128)];
    NSData *ciphertext = [envelope subdataWithRange:NSMakeRange(sizeof(kEncryptedMagic) + kCCBlockSizeAES128,
        body.length - sizeof(kEncryptedMagic) - kCCBlockSizeAES128)];
    NSData *encryptionKey = ApolloICloudReadStateDerivedKey(key, "encryption");
    NSMutableData *plaintext = [NSMutableData dataWithLength:ciphertext.length + kCCBlockSizeAES128];
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        encryptionKey.bytes, encryptionKey.length, iv.bytes, ciphertext.bytes, ciphertext.length,
        plaintext.mutableBytes, plaintext.length, &written);
    if (status != kCCSuccess) {
        if (error) *error = ApolloICloudReadStateCryptoError(@"Could not decrypt read history.");
        return nil;
    }
    plaintext.length = written;
    return plaintext;
}

static BOOL ApolloICloudFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 && number <= [NSDate date].timeIntervalSince1970 + 24 * 60 * 60;
}

static NSString *ApolloICloudBarePostID(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *postID = [value hasPrefix:@"t3_"] ? [value substringFromIndex:3] : value;
    if (postID.length == 0 || postID.length > 32) return nil;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"].invertedSet;
    return [postID rangeOfCharacterFromSet:invalid].location == NSNotFound ? postID.lowercaseString : nil;
}

static NSDictionary *ApolloICloudValidatedRecord(id value, NSString *defaultWriter) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    for (NSString *key in @[kRecordRead, kRecordUnread, kRecordCommentTime]) {
        id number = value[key];
        if (number && !ApolloICloudFiniteNumber(number)) return nil;
        if (number) record[key] = @([number doubleValue]);
    }
    id count = value[kRecordCommentCount];
    if (count) {
        if (!ApolloICloudFiniteNumber(count) || floor([count doubleValue]) != [count doubleValue] ||
            [count doubleValue] >= (double)LLONG_MAX || !record[kRecordCommentTime]) return nil;
        record[kRecordCommentCount] = @([count longLongValue]);
    }
    NSString *writer = [value[kRecordWriter] isKindOfClass:NSString.class] ? value[kRecordWriter] : defaultWriter;
    if (writer.length == 0 || writer.length > 64) return nil;
    record[kRecordWriter] = writer;
    return record.count > 1 ? record : nil;
}

NSDictionary *ApolloICloudReadStateValidatedJournal(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[kJournalVersion] isEqual:@1]) return nil;
    NSString *writer = [value[kJournalWriter] isKindOfClass:NSString.class] ? value[kJournalWriter] : nil;
    NSDictionary *records = [value[kJournalRecords] isKindOfClass:NSDictionary.class] ? value[kJournalRecords] : nil;
    if (writer.length == 0 || writer.length > 64 || !records || records.count > kMaximumJournalRecords) return nil;
    id clear = value[kJournalClear];
    if (clear && !ApolloICloudFiniteNumber(clear)) return nil;
    id generation = value[kJournalGeneration];
    if (generation && (!ApolloICloudFiniteNumber(generation) || floor([generation doubleValue]) != [generation doubleValue])) return nil;

    NSMutableDictionary *cleanRecords = [NSMutableDictionary dictionaryWithCapacity:records.count];
    for (id rawID in records) {
        NSString *postID = ApolloICloudBarePostID(rawID);
        NSDictionary *record = postID ? ApolloICloudValidatedRecord(records[rawID], writer) : nil;
        if (!postID || !record || cleanRecords[postID]) return nil;
        cleanRecords[postID] = record;
    }
    return @{kJournalVersion: @1, kJournalWriter: writer, kJournalClear: clear ?: @0,
             kJournalGeneration: generation ?: @0,
             kJournalRecords: cleanRecords};
}

static BOOL ApolloICloudRecordWins(NSDictionary *candidate, NSDictionary *current, NSString *timeKey) {
    double candidateTime = [candidate[timeKey] doubleValue];
    double currentTime = [current[timeKey] doubleValue];
    if (candidateTime != currentTime) return candidateTime > currentTime;
    if ([timeKey isEqualToString:kRecordCommentTime]) {
        long long candidateCount = [candidate[kRecordCommentCount] longLongValue];
        long long currentCount = [current[kRecordCommentCount] longLongValue];
        if (candidateCount != currentCount) return candidateCount > currentCount;
    }
    return NO;
}

NSDictionary *ApolloICloudReadStateMergeJournals(NSArray<NSDictionary *> *journals) {
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    double clearAt = 0;
    long long generation = 0;
    NSMutableArray *validJournals = [NSMutableArray array];
    for (id rawJournal in journals) {
        NSDictionary *journal = ApolloICloudReadStateValidatedJournal(rawJournal);
        if (journal) [validJournals addObject:journal];
    }
    [validJournals sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[kJournalWriter] compare:b[kJournalWriter]];
    }];
    for (NSDictionary *journal in validJournals) {
        clearAt = MAX(clearAt, [journal[kJournalClear] doubleValue]);
        generation = MAX(generation, [journal[kJournalGeneration] longLongValue]);
        [journal[kJournalRecords] enumerateKeysAndObjectsUsingBlock:^(NSString *postID, NSDictionary *record, __unused BOOL *stop) {
            NSMutableDictionary *current = [merged[postID] mutableCopy] ?: [NSMutableDictionary dictionary];
            for (NSString *timeKey in @[kRecordRead, kRecordUnread]) {
                if (record[timeKey] && (!current[timeKey] || ApolloICloudRecordWins(record, current, timeKey))) {
                    current[timeKey] = record[timeKey];
                    current[kRecordWriter] = record[kRecordWriter];
                }
            }
            if (record[kRecordCommentTime] && (!current[kRecordCommentTime] ||
                ApolloICloudRecordWins(record, current, kRecordCommentTime))) {
                current[kRecordCommentTime] = record[kRecordCommentTime];
                current[kRecordCommentCount] = record[kRecordCommentCount];
                current[kRecordWriter] = record[kRecordWriter];
            }
            merged[postID] = current;
        }];
    }
    if (merged.count > kMaximumJournalRecords) {
        NSArray *oldestFirst = [merged keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double aTime = MAX(MAX([a[kRecordRead] doubleValue], [a[kRecordUnread] doubleValue]), [a[kRecordCommentTime] doubleValue]);
            double bTime = MAX(MAX([b[kRecordRead] doubleValue], [b[kRecordUnread] doubleValue]), [b[kRecordCommentTime] doubleValue]);
            return aTime < bTime ? NSOrderedAscending : aTime > bTime ? NSOrderedDescending : NSOrderedSame;
        }];
        NSUInteger removeCount = merged.count - kMaximumJournalRecords;
        for (NSUInteger index = 0; index < removeCount; index++) {
            NSDictionary *record = merged[oldestFirst[index]];
            // A compaction floor prevents an old device from resurrecting a
            // read whose individual tombstone no longer fits in the one-value
            // KVS budget. It intentionally affects only read/unread clocks.
            clearAt = MAX(clearAt, MAX([record[kRecordRead] doubleValue], [record[kRecordUnread] doubleValue]));
            [merged removeObjectForKey:oldestFirst[index]];
        }
    }
    return @{kJournalVersion: @1, kJournalWriter: @"merged", kJournalClear: @(clearAt),
             kJournalGeneration: @(generation),
             kJournalRecords: merged};
}

NSArray<NSString *> *ApolloICloudReadStateProjectedReadIDs(NSDictionary *merged, NSUInteger limit) {
    NSDictionary *journal = ApolloICloudReadStateValidatedJournal(merged);
    if (!journal || limit == 0) return @[];
    double clearAt = [journal[kJournalClear] doubleValue];
    NSMutableArray *rows = [NSMutableArray array];
    [journal[kJournalRecords] enumerateKeysAndObjectsUsingBlock:^(NSString *postID, NSDictionary *record, __unused BOOL *stop) {
        double readAt = [record[kRecordRead] doubleValue];
        if (readAt > MAX(clearAt, [record[kRecordUnread] doubleValue])) {
            [rows addObject:@{ @"id": postID, @"time": @(readAt), @"writer": record[kRecordWriter] ?: @"" }];
        }
    }];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult time = [a[@"time"] compare:b[@"time"]];
        return time != NSOrderedSame ? time : [a[@"id"] compare:b[@"id"]];
    }];
    if (rows.count > limit) [rows removeObjectsInRange:NSMakeRange(0, rows.count - limit)];
    return [rows valueForKey:@"id"];
}

NSData *ApolloICloudReadStateProjectedCommentData(NSDictionary *merged, NSUInteger limit) {
    NSDictionary *journal = ApolloICloudReadStateValidatedJournal(merged);
    if (!journal || limit == 0) return [NSJSONSerialization dataWithJSONObject:@[] options:0 error:nil];
    NSMutableArray *rows = [NSMutableArray array];
    [journal[kJournalRecords] enumerateKeysAndObjectsUsingBlock:^(NSString *postID, NSDictionary *record, __unused BOOL *stop) {
        if (record[kRecordCommentTime] && record[kRecordCommentCount]) {
            [rows addObject:@{ @"id": postID, @"time": record[kRecordCommentTime],
                               @"count": record[kRecordCommentCount], @"writer": record[kRecordWriter] ?: @"" }];
        }
    }];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult time = [a[@"time"] compare:b[@"time"]];
        return time != NSOrderedSame ? time : [a[@"id"] compare:b[@"id"]];
    }];
    if (rows.count > limit) [rows removeObjectsInRange:NSMakeRange(0, rows.count - limit)];
    NSMutableArray *native = [NSMutableArray arrayWithCapacity:rows.count * 2];
    for (NSDictionary *row in rows) {
        [native addObject:row[@"id"]];
        [native addObject:@{ @"timestamp": row[@"time"], @"totalComments": row[@"count"] }];
    }
    return [NSJSONSerialization dataWithJSONObject:native options:0 error:nil];
}

NSDictionary *ApolloICloudReadStateJournalByCapturing(NSDictionary *rawJournal,
    NSArray<NSString *> *readIDs, NSDictionary<NSString *, NSDictionary *> *comments,
    NSSet<NSString *> *previousReadIDs, NSTimeInterval now, BOOL historicalSeed) {
    NSDictionary *validated = ApolloICloudReadStateValidatedJournal(rawJournal);
    if (!validated) return rawJournal ?: @{};
    NSMutableDictionary *journal = [validated mutableCopy];
    NSMutableDictionary *records = [journal[kJournalRecords] mutableCopy];
    NSString *writer = journal[kJournalWriter];
    NSUInteger index = 0;
    for (NSString *rawID in readIDs) {
        NSString *postID = ApolloICloudBarePostID(rawID);
        if (!postID) continue;
        NSMutableDictionary *record = [records[postID] mutableCopy] ?: [NSMutableDictionary dictionary];
        BOOL newlyObserved = previousReadIDs && ![previousReadIDs containsObject:postID];
        if (!record[kRecordRead] || newlyObserved) {
            record[kRecordRead] = historicalSeed && !previousReadIDs
                ? @1 : @(now - (double)(readIDs.count - index) / 1000.0);
            record[kRecordWriter] = writer;
        }
        index++;
        records[postID] = record;
    }
    [comments enumerateKeysAndObjectsUsingBlock:^(NSString *rawID, NSDictionary *snapshot, __unused BOOL *stop) {
        NSString *postID = ApolloICloudBarePostID(rawID);
        NSNumber *timestamp = snapshot[@"timestamp"];
        NSNumber *count = snapshot[@"totalComments"];
        if (!postID || !ApolloICloudFiniteNumber(timestamp) || !ApolloICloudFiniteNumber(count) ||
            floor(count.doubleValue) != count.doubleValue) return;
        NSMutableDictionary *record = [records[postID] mutableCopy] ?: [NSMutableDictionary dictionary];
        BOOL newerTime = !record[kRecordCommentTime] || timestamp.doubleValue > [record[kRecordCommentTime] doubleValue];
        BOOL higherEqualTimeCount = record[kRecordCommentTime] &&
            timestamp.doubleValue == [record[kRecordCommentTime] doubleValue] &&
            count.longLongValue > [record[kRecordCommentCount] longLongValue];
        if (newerTime || higherEqualTimeCount) {
            record[kRecordCommentTime] = @([timestamp doubleValue]);
            record[kRecordCommentCount] = @([count longLongValue]);
            record[kRecordWriter] = writer;
            records[postID] = record;
        }
    }];
    journal[kJournalRecords] = records;
    return journal;
}

#if !defined(APOLLO_ICLOUD_READ_STATE_TESTS)
static NSError *ApolloICloudReadStateError(NSString *message) {
    return [NSError errorWithDomain:@"ApolloICloudReadState" code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"iCloud read-state sync is unavailable."}];
}

static NSURL *ApolloICloudReadStateURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"ApolloReborn/ICloudReadState/state.plist"];
}

@interface ApolloICloudReadState ()
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL available;
@property (nonatomic, copy) NSString *availabilityMessage;
@property (nonatomic, strong) NSMutableDictionary *journal;
@property (nonatomic, strong) NSData *encryptionKey;
@property (nonatomic, strong) NSTimer *uploadTimer;
@property (nonatomic) BOOL applyingProjection;
@property (nonatomic, copy) NSSet<NSString *> *lastObservedReadIDs;
@property (nonatomic) BOOL hasObservedReadIDs;
@end

@implementation ApolloICloudReadState

+ (instancetype)sharedManager {
    static ApolloICloudReadState *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [self new]; });
    return manager;
}

- (instancetype)init {
    return [super init];
}

- (BOOL)isEnabled { return sICloudReadStateSyncEnabled; }

- (NSDictionary *)loadOrCreateJournal {
    NSData *data = [NSData dataWithContentsOfURL:ApolloICloudReadStateURL()];
    NSDictionary *saved = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    NSDictionary *valid = ApolloICloudReadStateValidatedJournal(saved);
    if (valid) return valid;
    NSString *writer = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""].lowercaseString;
    long long generation = 0;
    ApolloICloudReadStateParseResetMarker([NSUbiquitousKeyValueStore.defaultStore dataForKey:kCloudStateKey], &generation);
    return @{kJournalVersion: @1, kJournalWriter: writer, kJournalClear: @0,
             kJournalGeneration: @(generation),
             kJournalRecords: @{}};
}

- (void)saveJournal {
    NSURL *url = ApolloICloudReadStateURL();
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:nil];
    [url.URLByDeletingLastPathComponent setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:self.journal
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:nil];
}

- (BOOL)probeAvailability {
    @try {
        BOOL synchronized = [NSUbiquitousKeyValueStore.defaultStore synchronize];
        self.available = synchronized;
        self.availabilityMessage = synchronized ? nil :
            @"This build is not signed with a usable iCloud key-value-store entitlement, or iCloud is unavailable.";
    } @catch (__unused NSException *exception) {
        self.available = NO;
        self.availabilityMessage = @"This build cannot access iCloud. Local read history still works normally.";
    }
    return self.available;
}

- (NSData *)existingEncryptionKey {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kEncryptionKeyService,
        (__bridge id)kSecAttrAccount: kEncryptionKeyAccount,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *key = CFBridgingRelease(result);
    return status == errSecSuccess && [key isKindOfClass:NSData.class] && key.length == 32 ? key : nil;
}

- (BOOL)prepareEncryptionKey:(NSError **)error {
    NSData *key = [self existingEncryptionKey];
    NSData *cloudEnvelope = [NSUbiquitousKeyValueStore.defaultStore dataForKey:kCloudStateKey];
    long long resetGeneration = 0;
    BOOL resetMarker = ApolloICloudReadStateParseResetMarker(cloudEnvelope, &resetGeneration);
    if (resetMarker && resetGeneration > [self.journal[kJournalGeneration] longLongValue]) {
        self.journal[kJournalGeneration] = @(resetGeneration);
        [self saveJournal];
        NSDictionary *oldKey = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kEncryptionKeyService,
            (__bridge id)kSecAttrAccount: kEncryptionKeyAccount,
            (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
        };
        SecItemDelete((__bridge CFDictionaryRef)oldKey);
        key = nil;
    }
    if (!key && cloudEnvelope.length > 0 && !resetMarker) {
        self.availabilityMessage = @"The encrypted iCloud read-state key has not reached this device yet. Make sure iCloud Keychain is on, then try again.";
        if (error) *error = ApolloICloudReadStateError(self.availabilityMessage);
        return NO;
    }
    if (!key) {
        NSMutableData *created = [NSMutableData dataWithLength:32];
        if (SecRandomCopyBytes(kSecRandomDefault, created.length, created.mutableBytes) != errSecSuccess) {
            if (error) *error = ApolloICloudReadStateError(@"Could not create the encrypted sync key.");
            return NO;
        }
        NSDictionary *item = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kEncryptionKeyService,
            (__bridge id)kSecAttrAccount: kEncryptionKeyAccount,
            (__bridge id)kSecAttrSynchronizable: @YES,
            (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
            (__bridge id)kSecValueData: created,
        };
        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        if (status == errSecDuplicateItem) key = [self existingEncryptionKey];
        else if (status == errSecSuccess) key = created;
        if (!key) {
            if (error) *error = ApolloICloudReadStateError(
                @"This build cannot create an iCloud Keychain encryption key. Local read history is unchanged.");
            return NO;
        }
    }
    if (cloudEnvelope.length > 0 && !resetMarker && !ApolloICloudReadStateDecrypt(cloudEnvelope, key, nil)) {
        self.availabilityMessage = @"The encrypted iCloud read-state key does not match this device yet. No cloud data was overwritten.";
        if (error) *error = ApolloICloudReadStateError(self.availabilityMessage);
        return NO;
    }
    self.encryptionKey = key;
    return YES;
}

- (void)start {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self start]; }); return; }
    if (self.started) return;
    self.started = YES;
    self.journal = [[self loadOrCreateJournal] mutableCopy];
    if (!self.enabled) return;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(cloudDidChange:)
        name:NSUbiquitousKeyValueStoreDidChangeExternallyNotification object:NSUbiquitousKeyValueStore.defaultStore];
    [nc addObserver:self selector:@selector(localDidChange:)
        name:ApolloPostReadStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(refreshForLifecycle:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(flushForLifecycle:)
        name:UIApplicationWillResignActiveNotification object:nil];
    if (![self probeAvailability]) return;
    if (![self prepareEncryptionKey:nil]) { self.available = NO; return; }
    [self captureLocalStateUsingHistoricalSeed:YES];
    [self refreshFromCloud];
}

- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"iCloud read-state setting is main-thread owned");
    if (enabled && ![self probeAvailability]) {
        if (error) *error = ApolloICloudReadStateError(self.availabilityMessage);
        return NO;
    }
    if (enabled && ![self prepareEncryptionKey:error]) {
        self.available = NO;
        return NO;
    }
    sICloudReadStateSyncEnabled = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:UDKeyICloudReadStateSyncEnabled];
    if (enabled) {
        self.started = NO;
        [self start];
    } else {
        [self.uploadTimer invalidate];
        self.uploadTimer = nil;
        [NSNotificationCenter.defaultCenter removeObserver:self];
        self.started = NO;
    }
    return YES;
}

- (BOOL)resetEncryptedCloudState:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"iCloud read-state reset is main-thread owned");
    long long generation = [self.journal[kJournalGeneration] longLongValue] + 1;
    [NSUbiquitousKeyValueStore.defaultStore setData:ApolloICloudReadStateResetMarker(generation)
                                             forKey:kCloudStateKey];
    [NSUbiquitousKeyValueStore.defaultStore synchronize];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kEncryptionKeyService,
        (__bridge id)kSecAttrAccount: kEncryptionKeyAccount,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
    };
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        if (error) *error = ApolloICloudReadStateError(@"The encrypted iCloud key could not be reset.");
        return NO;
    }
    [self setEnabled:NO error:nil];
    self.encryptionKey = nil;
    self.journal[kJournalGeneration] = @(generation);
    [self saveJournal];
    self.availabilityMessage = @"Encrypted cloud state was reset. Enable sync on one device first, then enable the others.";
    return YES;
}

- (BOOL)handleNewerResetGeneration {
    long long cloudGeneration = 0;
    if (!ApolloICloudReadStateParseResetMarker(
        [NSUbiquitousKeyValueStore.defaultStore dataForKey:kCloudStateKey], &cloudGeneration)) return NO;
    if (cloudGeneration <= [self.journal[kJournalGeneration] longLongValue]) return NO;
    self.journal[kJournalGeneration] = @(cloudGeneration);
    [self saveJournal];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kEncryptionKeyService,
        (__bridge id)kSecAttrAccount: kEncryptionKeyAccount,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    self.encryptionKey = nil;
    [self setEnabled:NO error:nil];
    self.availabilityMessage = @"Another device reset encrypted cloud state. Local history was preserved; enable sync again after the reset finishes.";
    return YES;
}

- (void)refreshForLifecycle:(__unused NSNotification *)note {
    if (!self.enabled) return;
    if (!self.available) {
        if (![self probeAvailability] || ![self prepareEncryptionKey:nil]) {
            self.available = NO;
            return;
        }
        [self captureLocalStateUsingHistoricalSeed:!self.hasObservedReadIDs];
    }
    [self refreshFromCloud];
}
- (void)flushForLifecycle:(__unused NSNotification *)note {
    [self.uploadTimer invalidate];
    self.uploadTimer = nil;
    [self captureLocalStateAndUpload];
}

- (void)localDidChange:(__unused NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self localDidChange:nil]; });
        return;
    }
    if (self.applyingProjection) return;
    [self.uploadTimer invalidate];
    self.uploadTimer = [NSTimer scheduledTimerWithTimeInterval:0.75 target:self
        selector:@selector(captureLocalStateAndUpload) userInfo:nil repeats:NO];
}

- (void)recordPostIDAsUnread:(NSString *)postID {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self recordPostIDAsUnread:postID]; });
        return;
    }
    if (!self.enabled) return;
    NSString *bare = ApolloICloudBarePostID(postID);
    if (!bare) return;
    NSMutableDictionary *records = [self.journal[kJournalRecords] mutableCopy];
    NSMutableDictionary *record = [records[bare] mutableCopy] ?: [NSMutableDictionary dictionary];
    record[kRecordUnread] = @([NSDate date].timeIntervalSince1970);
    record[kRecordWriter] = self.journal[kJournalWriter];
    records[bare] = record;
    self.journal[kJournalRecords] = records;
    [self saveJournal];
    [self flushNow];
}

- (void)recordClearAll {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self recordClearAll]; });
        return;
    }
    if (!self.enabled) return;
    self.journal[kJournalClear] = @([NSDate date].timeIntervalSince1970);
    [self saveJournal];
    [self flushNow];
}

- (void)captureLocalStateAndUpload {
    [self captureLocalStateUsingHistoricalSeed:NO];
    [self flushNow];
}

- (void)captureLocalStateUsingHistoricalSeed:(BOOL)historicalSeed {
    if (!self.enabled || !self.available) return;
    NSArray *readIDs = ApolloReadPostIDsSnapshot();
    if (!readIDs) readIDs = [NSUserDefaults.standardUserDefaults stringArrayForKey:@"ReadPostIDs"] ?: @[];
    NSDictionary *comments = ApolloRawPostCommentSnapshots();
    if (!readIDs) return;
    double now = [NSDate date].timeIntervalSince1970;
    NSMutableSet *observed = [NSMutableSet set];
    for (NSString *rawID in readIDs) {
        NSString *postID = ApolloICloudBarePostID(rawID);
        if (postID) [observed addObject:postID];
    }
    self.journal = [ApolloICloudReadStateJournalByCapturing(self.journal, readIDs, comments,
        self.hasObservedReadIDs ? self.lastObservedReadIDs : nil, now, historicalSeed) mutableCopy];
    self.lastObservedReadIDs = observed;
    self.hasObservedReadIDs = YES;
    [self pruneOwnJournal];
    [self saveJournal];
}

- (void)pruneOwnJournal {
    NSMutableDictionary *records = [self.journal[kJournalRecords] mutableCopy];
    if (records.count <= kMaximumJournalRecords) return;
    NSArray *keys = [records keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double aTime = MAX(MAX([a[kRecordRead] doubleValue], [a[kRecordUnread] doubleValue]), [a[kRecordCommentTime] doubleValue]);
        double bTime = MAX(MAX([b[kRecordRead] doubleValue], [b[kRecordUnread] doubleValue]), [b[kRecordCommentTime] doubleValue]);
        return aTime < bTime ? NSOrderedAscending : aTime > bTime ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSUInteger i = 0; i < keys.count - kMaximumJournalRecords; i++) [records removeObjectForKey:keys[i]];
    self.journal[kJournalRecords] = records;
}

- (void)flushNow {
    if (!self.enabled || [self handleNewerResetGeneration] || !self.available) return;
    NSDictionary *remote = [self cloudJournal];
    NSData *cloudValue = [NSUbiquitousKeyValueStore.defaultStore dataForKey:kCloudStateKey];
    if (cloudValue.length > 0 && !ApolloICloudReadStateParseResetMarker(cloudValue, NULL) && !remote) {
        self.available = NO;
        self.availabilityMessage = @"Encrypted iCloud read state could not be authenticated. No cloud data was overwritten.";
        return;
    }
    NSDictionary *merged = ApolloICloudReadStateMergeJournals(remote ? @[remote, self.journal] : @[self.journal]);
    if (remote && [remote isEqualToDictionary:merged]) return;
    NSData *plaintext = [NSPropertyListSerialization dataWithPropertyList:merged
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSData *data = plaintext ? ApolloICloudReadStateEncrypt(plaintext, self.encryptionKey, nil) : nil;
    if (!data || data.length > kMaximumJournalBytes) {
        ApolloLog(@"[iCloudReadState] Refusing oversized, invalid, or unencrypted local journal (%lu bytes)", (unsigned long)data.length);
        return;
    }
    [NSUbiquitousKeyValueStore.defaultStore setData:data forKey:kCloudStateKey];
    [NSUbiquitousKeyValueStore.defaultStore synchronize];
}

- (NSDictionary *)cloudJournal {
    NSData *data = [NSUbiquitousKeyValueStore.defaultStore dataForKey:kCloudStateKey];
    if (!data || data.length > kMaximumJournalBytes) return nil;
    if (ApolloICloudReadStateParseResetMarker(data, NULL)) return nil;
    NSData *plaintext = ApolloICloudReadStateDecrypt(data, self.encryptionKey, nil);
    if (!plaintext) return nil;
    id raw = [NSPropertyListSerialization propertyListWithData:plaintext options:0 format:nil error:nil];
    return ApolloICloudReadStateValidatedJournal(raw);
}

- (void)refreshFromCloud {
    if (!self.enabled || [self handleNewerResetGeneration] || !self.available) return;
    [NSUbiquitousKeyValueStore.defaultStore synchronize];
    // Capture synchronously before the destructive projection. This closes the
    // notification-vs-debounce race where a just-read post could otherwise be
    // replaced by a stale cloud snapshot before its timer fires.
    [self captureLocalStateUsingHistoricalSeed:NO];
    NSDictionary *remote = [self cloudJournal];
    NSData *cloudValue = [NSUbiquitousKeyValueStore.defaultStore dataForKey:kCloudStateKey];
    if (cloudValue.length > 0 && !ApolloICloudReadStateParseResetMarker(cloudValue, NULL) && !remote) {
        self.available = NO;
        self.availabilityMessage = @"Encrypted iCloud read state could not be authenticated. Local history is unchanged.";
        return;
    }
    NSDictionary *merged = ApolloICloudReadStateMergeJournals(remote ? @[remote, self.journal] : @[self.journal]);
    NSUInteger configured = sReadPostMaxCount > 0 ? MIN((NSUInteger)sReadPostMaxCount, 5000u) : 5000u;
    NSArray *readIDs = ApolloICloudReadStateProjectedReadIDs(merged, configured);
    NSData *comments = ApolloICloudReadStateProjectedCommentData(merged, 1000);
    // Adopt the converged values before posting the projection notification.
    // The delayed observer then sees existing timestamps instead of turning
    // remote reads into newly-viewed local reads.
    NSMutableDictionary *convergedLocal = [merged mutableCopy];
    convergedLocal[kJournalWriter] = self.journal[kJournalWriter];
    self.journal = convergedLocal;
    [self saveJournal];
    self.applyingProjection = YES;
    ApolloApplySyncedPostReadState(readIDs, comments);
    self.applyingProjection = NO;
    self.lastObservedReadIDs = [NSSet setWithArray:readIDs];
    self.hasObservedReadIDs = YES;
    [self flushNow];
}

- (void)cloudDidChange:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self cloudDidChange:note]; });
        return;
    }
    NSNumber *reason = note.userInfo[NSUbiquitousKeyValueStoreChangeReasonKey];
    if (reason.integerValue == NSUbiquitousKeyValueStoreAccountChange) {
        // Never copy one iCloud account's browsing history into another. Keep
        // local Apollo state untouched and require an explicit opt-in again.
        [self setEnabled:NO error:nil];
        self.available = NO;
        self.availabilityMessage = @"The iCloud account changed. Sync was turned off to keep the accounts' read histories separate.";
        return;
    }
    if (reason.integerValue == NSUbiquitousKeyValueStoreQuotaViolationChange) {
        self.available = NO;
        self.availabilityMessage = @"iCloud rejected the read-state update because its key-value storage is full. Local history is unchanged.";
        return;
    }
    [self refreshFromCloud];
}

@end
#endif
