#import "ApolloMessageDraftStore.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <os/lock.h>

// Deliberately outside Apollo's Valet service prefix: draft traffic must not
// enter the account keychain self-heal/mirror pipeline.
NSString * const ApolloMessageDraftKeychainService = @"app.apolloreborn.message-drafts";

static NSString *const kApolloMessageDraftNamespace = @"apollo-message-draft-v1";
static NSString *const kApolloMessageDraftIndexKey = @"ApolloMessageDraftOpaqueIndex";
static const NSTimeInterval kApolloMessageDraftMaximumAge = 30.0 * 24.0 * 60.0 * 60.0;
static NSString *ApolloMessageDraftAccountHash(NSString *account);
static dispatch_queue_t ApolloMessageDraftStoreQueue(void) { static dispatch_queue_t q; static dispatch_once_t once; dispatch_once(&once, ^{ q = dispatch_queue_create("app.apolloreborn.message-drafts", DISPATCH_QUEUE_SERIAL); }); return q; }
void ApolloMessageDraftStoreAsync(dispatch_block_t block) { if (block) dispatch_async(ApolloMessageDraftStoreQueue(), block); }
void ApolloMessageDraftStoreBarrier(dispatch_block_t block) { if (block) dispatch_sync(ApolloMessageDraftStoreQueue(), block); }
// Generation tokens have their own short lock so the main thread's per-keystroke
// snapshot reads never wait behind keychain I/O, which runs on the store queue
// under the store lock (@synchronized ApolloMessageDraftKeychainService). The
// store lock still wraps "check generation + write" and "advance generation +
// mark index", so a stale save is either rejected or marked for deletion.
static os_unfair_lock sApolloMessageDraftGenerationLock = OS_UNFAIR_LOCK_INIT;
static NSUInteger sApolloMessageDraftInvalidationGeneration = 0;
static NSMutableDictionary<NSString *, NSNumber *> *sApolloMessageDraftAccountGenerations;

static NSUInteger ApolloMessageDraftAccountGenerationForHash(NSString *accountHash) {
    os_unfair_lock_lock(&sApolloMessageDraftGenerationLock);
    NSUInteger generation = sApolloMessageDraftAccountGenerations[accountHash].unsignedIntegerValue;
    os_unfair_lock_unlock(&sApolloMessageDraftGenerationLock);
    return generation;
}

NSUInteger ApolloMessageDraftStoreInvalidationGeneration(void) {
    os_unfair_lock_lock(&sApolloMessageDraftGenerationLock);
    NSUInteger generation = sApolloMessageDraftInvalidationGeneration;
    os_unfair_lock_unlock(&sApolloMessageDraftGenerationLock);
    return generation;
}

NSUInteger ApolloMessageDraftStoreAccountGeneration(NSString *account) {
    NSString *key = ApolloMessageDraftAccountHash(account);
    return key ? ApolloMessageDraftAccountGenerationForHash(key) : 0;
}

// Callers hold the store lock while advancing a generation and changing its
// index entries, so a queued save cannot slip between those two operations.
static void ApolloMessageDraftAdvanceGenerationLocked(NSString *accountHash) {
    os_unfair_lock_lock(&sApolloMessageDraftGenerationLock);
    if (!accountHash) {
        sApolloMessageDraftInvalidationGeneration += 1;
    } else {
        if (!sApolloMessageDraftAccountGenerations) sApolloMessageDraftAccountGenerations = [NSMutableDictionary dictionary];
        sApolloMessageDraftAccountGenerations[accountHash] = @(sApolloMessageDraftAccountGenerations[accountHash].unsignedIntegerValue + 1);
    }
    os_unfair_lock_unlock(&sApolloMessageDraftGenerationLock);
}

#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
static NSMutableDictionary<NSString *, NSString *> *sApolloMessageDraftTestItems;
static NSDictionary *sApolloMessageDraftTestIndex;
static NSTimeInterval sApolloMessageDraftTestNow = 0;
static BOOL sApolloMessageDraftTestDeleteFailure = NO;
#endif

static NSTimeInterval ApolloMessageDraftNow(void) {
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    return sApolloMessageDraftTestNow;
#else
    return [NSDate date].timeIntervalSince1970;
#endif
}

static NSString *ApolloMessageDraftNormalizePart(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *normalized = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return normalized.length > 0 ? normalized : nil;
}

static NSString *ApolloMessageDraftAccountHash(NSString *account) {
    return ApolloMessageDraftOpaqueKey(account, @"account-index");
}

static NSDictionary *ApolloMessageDraftIndex(void) {
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    return sApolloMessageDraftTestIndex ?: @{};
#else
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:kApolloMessageDraftIndexKey] ?: @{};
#endif
}

static void ApolloMessageDraftWriteIndex(NSDictionary *index) {
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    sApolloMessageDraftTestIndex = [index copy];
#else
    [[NSUserDefaults standardUserDefaults] setObject:index forKey:kApolloMessageDraftIndexKey];
#endif
}

static void ApolloMessageDraftIndexTouchLocked(NSString *opaqueKey, NSString *account) {
    NSString *accountHash = ApolloMessageDraftAccountHash(account);
    if (opaqueKey.length == 0 || accountHash.length == 0) return;
    NSMutableDictionary *index = [ApolloMessageDraftIndex() mutableCopy];
    index[opaqueKey] = @{ @"account": accountHash, @"updated": @(ApolloMessageDraftNow()) };
    ApolloMessageDraftWriteIndex(index);
}

static void ApolloMessageDraftIndexRemoveLocked(NSString *opaqueKey) {
    NSDictionary *index = ApolloMessageDraftIndex();
    if (!index[opaqueKey]) return;
    NSMutableDictionary *updated = [index mutableCopy];
    [updated removeObjectForKey:opaqueKey];
    ApolloMessageDraftWriteIndex(updated);
}

NSString *ApolloMessageDraftOpaqueKey(NSString *account, NSString *conversation) {
    NSString *normalizedAccount = ApolloMessageDraftNormalizePart(account).lowercaseString;
    NSString *normalizedConversation = ApolloMessageDraftNormalizePart(conversation);
    if (normalizedAccount.length == 0 || normalizedConversation.length == 0) return nil;

    // Length-prefix each component rather than relying on a delimiter that an
    // arbitrary route or Reddit identifier could contain.
    NSString *material = [NSString stringWithFormat:@"%@:%lu:%@:%lu:%@",
                         kApolloMessageDraftNamespace,
                         (unsigned long)normalizedAccount.length, normalizedAccount,
                         (unsigned long)normalizedConversation.length, normalizedConversation];
    NSData *data = [material dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *key = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [key appendFormat:@"%02x", digest[i]];
    return key;
}

#ifndef APOLLO_MESSAGE_DRAFTS_TESTING
static NSDictionary *ApolloMessageDraftIdentity(NSString *opaqueKey) {
    if (opaqueKey.length == 0) return nil;
    return @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: ApolloMessageDraftKeychainService,
              (__bridge id)kSecAttrAccount: opaqueKey };
}
#endif

BOOL ApolloMessageDraftStoreText(NSString *account, NSString *conversation, NSString *text) {
    NSString *key = ApolloMessageDraftOpaqueKey(account, conversation);
    if (key.length == 0) return NO;
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return ApolloMessageDraftClear(account, conversation);

    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;
    @synchronized (ApolloMessageDraftKeychainService) {
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
        if (!sApolloMessageDraftTestItems) sApolloMessageDraftTestItems = [NSMutableDictionary dictionary];
        sApolloMessageDraftTestItems[key] = [text copy];
        ApolloMessageDraftIndexTouchLocked(key, account);
        return YES;
#else
        NSDictionary *identity = ApolloMessageDraftIdentity(key);
        NSDictionary *update = @{ (__bridge id)kSecValueData: data };
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)identity, (__bridge CFDictionaryRef)update);
        if (status == errSecItemNotFound) {
            NSMutableDictionary *add = [identity mutableCopy];
            add[(__bridge id)kSecValueData] = data;
            // The app must be unlocked before the user can compose. This keeps the
            // draft encrypted at rest and out of iCloud Keychain synchronization.
            add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
            status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
            if (status == errSecDuplicateItem) status = SecItemUpdate((__bridge CFDictionaryRef)identity, (__bridge CFDictionaryRef)update);
        }
        if (status == errSecSuccess) ApolloMessageDraftIndexTouchLocked(key, account);
        return status == errSecSuccess;
#endif
    }
}

BOOL ApolloMessageDraftStoreTextIfCurrent(NSString *account, NSString *conversation, NSString *text, NSUInteger globalGeneration, NSUInteger accountGeneration) {
    NSString *accountHash = ApolloMessageDraftAccountHash(account);
    if (!accountHash) return NO;
    // This is deliberately one lock scope with IndexTouch/MarkPending. Either
    // a write lands and cleanup subsequently marks its index entry, or cleanup
    // advances a token first and the stale write is rejected.
    @synchronized (ApolloMessageDraftKeychainService) {
        if (globalGeneration != ApolloMessageDraftStoreInvalidationGeneration() ||
            accountGeneration != ApolloMessageDraftAccountGenerationForHash(accountHash)) return NO;
        return ApolloMessageDraftStoreText(account, conversation, text);
    }
}

NSString *ApolloMessageDraftLoadText(NSString *account, NSString *conversation) {
    NSString *key = ApolloMessageDraftOpaqueKey(account, conversation);
    if (key.length == 0) return nil;
    @synchronized (ApolloMessageDraftKeychainService) {
        NSDictionary *entry = ApolloMessageDraftIndex()[key];
        if ([entry[@"pendingDelete"] boolValue]) return nil;
        NSTimeInterval updated = [entry[@"updated"] doubleValue];
        if (updated > 0 && ApolloMessageDraftNow() - updated > kApolloMessageDraftMaximumAge) {
            ApolloMessageDraftClear(account, conversation);
            return nil;
        }
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
        return sApolloMessageDraftTestItems[key];
#else
        NSMutableDictionary *query = [ApolloMessageDraftIdentity(key) mutableCopy];
        query[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status != errSecSuccess || !result) {
            if (result) CFRelease(result);
            return nil;
        }
        NSData *data = CFBridgingRelease(result);
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
#endif
    }
}

static BOOL ApolloMessageDraftDeleteOpaqueKey(NSString *key) {
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    if (sApolloMessageDraftTestDeleteFailure) return NO;
    [sApolloMessageDraftTestItems removeObjectForKey:key];
    return YES;
#else
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)ApolloMessageDraftIdentity(key));
    return status == errSecSuccess || status == errSecItemNotFound;
#endif
}

// The caller holds the state lock across keychain deletion and index publication.
// Keep failed deletions indexed so a later retry can still find them.
static void ApolloMessageDraftDeleteMatchingLocked(BOOL (^predicate)(NSDictionary *entry)) {
    NSDictionary *index = ApolloMessageDraftIndex();
    NSMutableDictionary *updated = nil;
    for (NSString *key in index) {
        if (!predicate(index[key]) || !ApolloMessageDraftDeleteOpaqueKey(key)) continue;
        if (!updated) updated = [index mutableCopy];
        [updated removeObjectForKey:key];
    }
    if (updated) ApolloMessageDraftWriteIndex(updated);
}

static void ApolloMessageDraftMarkPending(NSString *accountHash) {
    @synchronized (ApolloMessageDraftKeychainService) {
        ApolloMessageDraftAdvanceGenerationLocked(accountHash);
        NSDictionary *index = ApolloMessageDraftIndex();
        NSMutableDictionary *updated = nil;
        for (NSString *key in index) {
            NSDictionary *entry = index[key];
            if (accountHash && ![entry[@"account"] isEqualToString:accountHash]) continue;
            if ([entry[@"pendingDelete"] boolValue]) continue;
            if (!updated) updated = [index mutableCopy];
            NSMutableDictionary *marked = [entry mutableCopy];
            marked[@"pendingDelete"] = @YES;
            updated[key] = marked;
        }
        if (updated) ApolloMessageDraftWriteIndex(updated);
    }
    ApolloMessageDraftStoreAsync(^{
        @synchronized (ApolloMessageDraftKeychainService) {
            ApolloMessageDraftDeleteMatchingLocked(^BOOL(NSDictionary *entry) {
                return [entry[@"pendingDelete"] boolValue];
            });
        }
    });
}

void ApolloMessageDraftStoreMarkAllPendingDelete(void) {
    ApolloMessageDraftMarkPending(nil);
}

void ApolloMessageDraftStoreMarkAccountPendingDelete(NSString *account) {
    NSString *hash = ApolloMessageDraftAccountHash(account);
    if (hash.length == 0) return;
    ApolloMessageDraftMarkPending(hash);
}

BOOL ApolloMessageDraftClear(NSString *account, NSString *conversation) {
    NSString *key = ApolloMessageDraftOpaqueKey(account, conversation);
    if (key.length == 0) return NO;
    @synchronized (ApolloMessageDraftKeychainService) {
        if (!ApolloMessageDraftDeleteOpaqueKey(key)) return NO;
        ApolloMessageDraftIndexRemoveLocked(key);
        return YES;
    }
}

void ApolloMessageDraftStoreRemoveAccount(NSString *account) {
    NSString *accountHash = ApolloMessageDraftAccountHash(account);
    if (accountHash.length == 0) return;
    @synchronized (ApolloMessageDraftKeychainService) {
        ApolloMessageDraftAdvanceGenerationLocked(accountHash);
        ApolloMessageDraftDeleteMatchingLocked(^BOOL(NSDictionary *entry) {
            return [entry[@"account"] isEqualToString:accountHash];
        });
    }
}

void ApolloMessageDraftStoreClearAll(void) {
    @synchronized (ApolloMessageDraftKeychainService) {
        ApolloMessageDraftAdvanceGenerationLocked(nil);
        ApolloMessageDraftDeleteMatchingLocked(^BOOL(__unused NSDictionary *entry) { return YES; });
    }
}

void ApolloMessageDraftStorePruneExpired(void) {
    @synchronized (ApolloMessageDraftKeychainService) {
        NSTimeInterval now = ApolloMessageDraftNow();
        ApolloMessageDraftDeleteMatchingLocked(^BOOL(NSDictionary *entry) {
            return [entry[@"pendingDelete"] boolValue] ||
                now - [entry[@"updated"] doubleValue] > kApolloMessageDraftMaximumAge;
        });
    }
}

BOOL ApolloMessageDraftShouldClearForHTTPStatus(NSInteger statusCode) {
    return statusCode >= 200 && statusCode < 300;
}

BOOL ApolloMessageDraftShouldClearForSendGeneration(NSInteger statusCode,
                                                     NSUInteger sentGeneration,
                                                     NSUInteger currentGeneration) {
    return ApolloMessageDraftShouldClearForHTTPStatus(statusCode) &&
        currentGeneration <= sentGeneration;
}

BOOL ApolloMessageDraftShouldInvalidateEmptyClearForSendGeneration(NSUInteger sentGeneration,
                                                                    NSUInteger currentGeneration) {
    return currentGeneration <= sentGeneration;
}

BOOL ApolloMessageDraftSendOwnsContentGeneration(NSUInteger sentGeneration,
                                                  NSUInteger currentGeneration) {
    return sentGeneration == currentGeneration;
}

BOOL ApolloMessageDraftHandleSendHTTPStatus(NSString *account,
                                            NSString *conversation,
                                            NSInteger statusCode) {
    if (!ApolloMessageDraftShouldClearForHTTPStatus(statusCode)) return NO;
    return ApolloMessageDraftClear(account, conversation);
}

#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
void ApolloMessageDraftStoreResetForTesting(void) {
    sApolloMessageDraftTestItems = [NSMutableDictionary dictionary];
    sApolloMessageDraftTestIndex = @{};
    sApolloMessageDraftTestNow = 0;
    sApolloMessageDraftTestDeleteFailure = NO;
    sApolloMessageDraftInvalidationGeneration = 0;
    sApolloMessageDraftAccountGenerations = nil;
}
void ApolloMessageDraftStoreSetTestingNow(NSTimeInterval now) { sApolloMessageDraftTestNow = now; }
void ApolloMessageDraftStoreSetTestingDeleteFailure(BOOL fail) { sApolloMessageDraftTestDeleteFailure = fail; }
#endif
