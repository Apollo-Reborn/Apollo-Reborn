#import "ApolloMessageDraftStore.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

NSString * const ApolloMessageDraftKeychainService = @"app.apolloreborn.message-drafts";

#ifndef APOLLO_MESSAGE_DRAFTS_TESTING
// Deliberately outside Apollo's Valet service prefix: draft traffic must not
// enter the account keychain self-heal/mirror pipeline.
static NSString *const kApolloMessageDraftService = ApolloMessageDraftKeychainService;
#endif
static NSString *const kApolloMessageDraftNamespace = @"apollo-message-draft-v1";
static NSString *const kApolloMessageDraftIndexKey = @"ApolloMessageDraftOpaqueIndex";
static const NSTimeInterval kApolloMessageDraftMaximumAge = 30.0 * 24.0 * 60.0 * 60.0;
static NSString *ApolloMessageDraftAccountHash(NSString *account);
static dispatch_queue_t ApolloMessageDraftStoreQueue(void) { static dispatch_queue_t q; static dispatch_once_t once; dispatch_once(&once, ^{ q = dispatch_queue_create("app.apolloreborn.message-drafts", DISPATCH_QUEUE_SERIAL); }); return q; }
void ApolloMessageDraftStoreAsync(dispatch_block_t block) { if (block) dispatch_async(ApolloMessageDraftStoreQueue(), block); }
void ApolloMessageDraftStoreBarrier(dispatch_block_t block) { if (block) dispatch_sync(ApolloMessageDraftStoreQueue(), block); }
static NSUInteger sApolloMessageDraftInvalidationGeneration = 0;
static NSMutableDictionary<NSString *, NSNumber *> *sApolloMessageDraftAccountGenerations;
NSUInteger ApolloMessageDraftStoreInvalidationGeneration(void) { @synchronized (ApolloMessageDraftKeychainService) { return sApolloMessageDraftInvalidationGeneration; } }
NSUInteger ApolloMessageDraftStoreAccountGeneration(NSString *account) { @synchronized (ApolloMessageDraftKeychainService) { return sApolloMessageDraftAccountGenerations[ApolloMessageDraftAccountHash(account)] .unsignedIntegerValue; } }
static void ApolloMessageDraftAdvanceInvalidationGeneration(void) { @synchronized (ApolloMessageDraftKeychainService) { sApolloMessageDraftInvalidationGeneration += 1; } }
static void ApolloMessageDraftAdvanceAccountGeneration(NSString *account) { @synchronized (ApolloMessageDraftKeychainService) { NSString *key = ApolloMessageDraftAccountHash(account); if (!sApolloMessageDraftAccountGenerations) sApolloMessageDraftAccountGenerations = [NSMutableDictionary dictionary]; sApolloMessageDraftAccountGenerations[key] = @([sApolloMessageDraftAccountGenerations[key] unsignedIntegerValue] + 1); } }

#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
static NSMutableDictionary<NSString *, NSString *> *sApolloMessageDraftTestItems;
static NSMutableDictionary *sApolloMessageDraftTestIndex;
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

static NSMutableDictionary *ApolloMessageDraftIndex(void) {
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    if (!sApolloMessageDraftTestIndex) sApolloMessageDraftTestIndex = [NSMutableDictionary dictionary];
    return [sApolloMessageDraftTestIndex mutableCopy];
#else
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kApolloMessageDraftIndexKey];
    return [stored isKindOfClass:[NSDictionary class]] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
#endif
}

static void ApolloMessageDraftWriteIndex(NSDictionary *index) {
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    sApolloMessageDraftTestIndex = [index mutableCopy];
#else
    [[NSUserDefaults standardUserDefaults] setObject:index forKey:kApolloMessageDraftIndexKey];
#endif
}

static void ApolloMessageDraftIndexTouch(NSString *opaqueKey, NSString *account) {
    @synchronized (ApolloMessageDraftKeychainService) {
    NSString *accountHash = ApolloMessageDraftAccountHash(account);
    if (opaqueKey.length == 0 || accountHash.length == 0) return;
    NSMutableDictionary *index = ApolloMessageDraftIndex();
    index[opaqueKey] = @{ @"account": accountHash, @"updated": @(ApolloMessageDraftNow()) };
    ApolloMessageDraftWriteIndex(index);
    }
}

static void ApolloMessageDraftIndexRemove(NSString *opaqueKey) {
    @synchronized (ApolloMessageDraftKeychainService) {
    NSMutableDictionary *index = ApolloMessageDraftIndex();
    if (!index[opaqueKey]) return;
    [index removeObjectForKey:opaqueKey];
    ApolloMessageDraftWriteIndex(index);
    }
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
              (__bridge id)kSecAttrService: kApolloMessageDraftService,
              (__bridge id)kSecAttrAccount: opaqueKey };
}
#endif

BOOL ApolloMessageDraftStoreText(NSString *account, NSString *conversation, NSString *text) {
    NSString *key = ApolloMessageDraftOpaqueKey(account, conversation);
    if (key.length == 0) return NO;
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return ApolloMessageDraftClear(account, conversation);

    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    if (!sApolloMessageDraftTestItems) sApolloMessageDraftTestItems = [NSMutableDictionary dictionary];
    sApolloMessageDraftTestItems[key] = text;
    ApolloMessageDraftIndexTouch(key, account);
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
    if (status == errSecSuccess) ApolloMessageDraftIndexTouch(key, account);
    return status == errSecSuccess;
#endif
}

BOOL ApolloMessageDraftStoreTextIfCurrent(NSString *account, NSString *conversation, NSString *text, NSUInteger globalGeneration, NSUInteger accountGeneration) {
    // This is deliberately one lock scope with IndexTouch/MarkPending. Either
    // a write lands and cleanup subsequently marks its index entry, or cleanup
    // advances a token first and the stale write is rejected.
    @synchronized (ApolloMessageDraftKeychainService) {
        if (globalGeneration != sApolloMessageDraftInvalidationGeneration ||
            accountGeneration != sApolloMessageDraftAccountGenerations[ApolloMessageDraftAccountHash(account)].unsignedIntegerValue) return NO;
        return ApolloMessageDraftStoreText(account, conversation, text);
    }
}

NSString *ApolloMessageDraftLoadText(NSString *account, NSString *conversation) {
    NSString *key = ApolloMessageDraftOpaqueKey(account, conversation);
    if (key.length == 0) return nil;
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    if ([ApolloMessageDraftIndex()[key][@"pendingDelete"] boolValue]) return nil;
    NSDictionary *entry = ApolloMessageDraftIndex()[key];
    if ([entry[@"updated"] doubleValue] > 0 && ApolloMessageDraftNow() - [entry[@"updated"] doubleValue] > kApolloMessageDraftMaximumAge) {
        ApolloMessageDraftClear(account, conversation);
        return nil;
    }
    return sApolloMessageDraftTestItems[key];
#else
    NSDictionary *entry = ApolloMessageDraftIndex()[key];
    if ([entry[@"pendingDelete"] boolValue]) return nil;
    if ([entry[@"updated"] doubleValue] > 0 && ApolloMessageDraftNow() - [entry[@"updated"] doubleValue] > kApolloMessageDraftMaximumAge) {
        ApolloMessageDraftClear(account, conversation);
        return nil;
    }
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

static void ApolloMessageDraftRetryPendingDeletes(void) {
    NSDictionary *index = ApolloMessageDraftIndex();
    NSMutableDictionary *updated = [index mutableCopy];
    for (NSString *key in index.allKeys) {
        if (![index[key][@"pendingDelete"] boolValue]) continue;
        if (ApolloMessageDraftDeleteOpaqueKey(key)) [updated removeObjectForKey:key];
    }
    if (updated.count != index.count) ApolloMessageDraftWriteIndex(updated);
}

static void ApolloMessageDraftMarkPending(BOOL (^predicate)(NSDictionary *entry)) {
    @synchronized (ApolloMessageDraftKeychainService) {
    NSMutableDictionary *index = ApolloMessageDraftIndex();
    for (NSString *key in index.allKeys) {
        NSDictionary *entry = index[key];
        if (!predicate(entry)) continue;
        NSMutableDictionary *marked = [entry mutableCopy];
        marked[@"pendingDelete"] = @YES;
        index[key] = marked;
    }
    ApolloMessageDraftWriteIndex(index);
    }
    ApolloMessageDraftStoreAsync(^{ ApolloMessageDraftRetryPendingDeletes(); });
}

void ApolloMessageDraftStoreMarkAllPendingDelete(void) {
    ApolloMessageDraftAdvanceInvalidationGeneration();
    ApolloMessageDraftMarkPending(^BOOL(__unused NSDictionary *entry) { return YES; });
}

void ApolloMessageDraftStoreMarkAccountPendingDelete(NSString *account) {
    NSString *hash = ApolloMessageDraftAccountHash(account);
    if (hash.length == 0) return;
    ApolloMessageDraftAdvanceAccountGeneration(account);
    ApolloMessageDraftMarkPending(^BOOL(NSDictionary *entry) { return [entry[@"account"] isEqualToString:hash]; });
}

BOOL ApolloMessageDraftClear(NSString *account, NSString *conversation) {
    NSString *key = ApolloMessageDraftOpaqueKey(account, conversation);
    if (key.length == 0) return NO;
#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
    [sApolloMessageDraftTestItems removeObjectForKey:key];
    ApolloMessageDraftIndexRemove(key);
    return YES;
#else
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)ApolloMessageDraftIdentity(key));
    if (status == errSecSuccess || status == errSecItemNotFound) ApolloMessageDraftIndexRemove(key);
    return status == errSecSuccess || status == errSecItemNotFound;
#endif
}

void ApolloMessageDraftStoreRemoveAccount(NSString *account) {
    ApolloMessageDraftAdvanceAccountGeneration(account);
    NSString *accountHash = ApolloMessageDraftAccountHash(account);
    if (accountHash.length == 0) return;
    NSDictionary *index = ApolloMessageDraftIndex();
    NSMutableDictionary *updated = [index mutableCopy];
    for (NSString *key in index.allKeys) {
        if (![index[key][@"account"] isEqualToString:accountHash]) continue;
        BOOL deleted = NO;
#if APOLLO_MESSAGE_DRAFTS_TESTING
        [sApolloMessageDraftTestItems removeObjectForKey:key];
        deleted = YES;
#else
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)ApolloMessageDraftIdentity(key));
        deleted = status == errSecSuccess || status == errSecItemNotFound;
#endif
        if (deleted) [updated removeObjectForKey:key];
    }
    ApolloMessageDraftWriteIndex(updated);
}

void ApolloMessageDraftStoreClearAll(void) {
    ApolloMessageDraftAdvanceInvalidationGeneration();
    NSDictionary *index = ApolloMessageDraftIndex();
    NSMutableDictionary *updated = [index mutableCopy];
    for (NSString *key in index.allKeys) {
        BOOL deleted = NO;
#if APOLLO_MESSAGE_DRAFTS_TESTING
        [sApolloMessageDraftTestItems removeObjectForKey:key];
        deleted = YES;
#else
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)ApolloMessageDraftIdentity(key));
        deleted = status == errSecSuccess || status == errSecItemNotFound;
#endif
        if (deleted) [updated removeObjectForKey:key];
    }
    ApolloMessageDraftWriteIndex(updated);
}

void ApolloMessageDraftStorePruneExpired(void) {
    ApolloMessageDraftRetryPendingDeletes();
    NSDictionary *index = ApolloMessageDraftIndex();
    NSTimeInterval now = ApolloMessageDraftNow();
    NSMutableDictionary *updated = [index mutableCopy];
    for (NSString *key in index.allKeys) {
        if (now - [index[key][@"updated"] doubleValue] <= kApolloMessageDraftMaximumAge) continue;
#if APOLLO_MESSAGE_DRAFTS_TESTING
        [sApolloMessageDraftTestItems removeObjectForKey:key];
        BOOL deleted = YES;
#else
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)ApolloMessageDraftIdentity(key));
        BOOL deleted = status == errSecSuccess || status == errSecItemNotFound;
#endif
        if (deleted) [updated removeObjectForKey:key];
    }
    if (updated.count != index.count) ApolloMessageDraftWriteIndex(updated);
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
    sApolloMessageDraftTestIndex = [NSMutableDictionary dictionary];
    sApolloMessageDraftTestNow = 0;
}
void ApolloMessageDraftStoreSetTestingNow(NSTimeInterval now) { sApolloMessageDraftTestNow = now; }
void ApolloMessageDraftStoreSetTestingDeleteFailure(BOOL fail) { sApolloMessageDraftTestDeleteFailure = fail; }
#endif
