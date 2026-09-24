#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

FOUNDATION_EXPORT NSString * const ApolloMessageDraftKeychainService;

// Message drafts are deliberately stored in the Keychain rather than defaults:
// their text can be sensitive, and neither account nor conversation identifiers
// are exposed in the Keychain item's metadata. `account` and `conversation` are
// inputs to an opaque SHA-256 key, never persisted verbatim.
NSString * _Nullable ApolloMessageDraftOpaqueKey(NSString * _Nullable account,
                                                  NSString * _Nullable conversation);

// Saving an empty string removes the draft. All functions reject an empty or
// malformed account/conversation key so an unresolved identity cannot share a
// draft with another account or conversation.
BOOL ApolloMessageDraftStoreText(NSString * _Nullable account,
                                 NSString * _Nullable conversation,
                                 NSString * _Nullable text);
NSString * _Nullable ApolloMessageDraftLoadText(NSString * _Nullable account,
                                                NSString * _Nullable conversation);
BOOL ApolloMessageDraftClear(NSString * _Nullable account,
                             NSString * _Nullable conversation);

// A draft may be cleared for a network send only after the originating client
// reports a successful HTTP response. Non-2xx responses and missing status
// retain it, so a failed send cannot erase the user's text.
BOOL ApolloMessageDraftShouldClearForHTTPStatus(NSInteger statusCode);
// A send completion owns only the text generation it captured. If typing has
// advanced since that request was issued, its response must leave newer text.
BOOL ApolloMessageDraftShouldClearForSendGeneration(NSInteger statusCode,
                                                    NSUInteger sentGeneration,
                                                    NSUInteger currentGeneration);
// A response may cancel the optimistic empty-editor timer only when it still
// owns the current text generation. Newer typing, including a later manual
// clear, must keep its own timer intact.
BOOL ApolloMessageDraftShouldInvalidateEmptyClearForSendGeneration(NSUInteger sentGeneration,
                                                                    NSUInteger currentGeneration);
BOOL ApolloMessageDraftSendOwnsContentGeneration(NSUInteger sentGeneration,
                                                 NSUInteger currentGeneration);
BOOL ApolloMessageDraftHandleSendHTTPStatus(NSString * _Nullable account,
                                            NSString * _Nullable conversation,
                                            NSInteger statusCode);
// Maintenance stores only opaque item/account hashes in defaults, never draft
// text or usernames. Entries expire after a bounded idle interval.
void ApolloMessageDraftStoreRemoveAccount(NSString * _Nullable account);
void ApolloMessageDraftStoreClearAll(void);
void ApolloMessageDraftStorePruneExpired(void);
void ApolloMessageDraftStoreMarkAllPendingDelete(void);
void ApolloMessageDraftStoreMarkAccountPendingDelete(NSString * _Nullable account);
void ApolloMessageDraftStoreAsync(dispatch_block_t block);
void ApolloMessageDraftStoreBarrier(dispatch_block_t block);
NSUInteger ApolloMessageDraftStoreInvalidationGeneration(void);
NSUInteger ApolloMessageDraftStoreAccountGeneration(NSString * _Nullable account);
BOOL ApolloMessageDraftStoreTextIfCurrent(NSString * _Nullable account, NSString * _Nullable conversation,
                                          NSString * _Nullable text, NSUInteger globalGeneration,
                                          NSUInteger accountGeneration);

#ifdef APOLLO_MESSAGE_DRAFTS_TESTING
void ApolloMessageDraftStoreResetForTesting(void);
void ApolloMessageDraftStoreSetTestingNow(NSTimeInterval now);
void ApolloMessageDraftStoreSetTestingDeleteFailure(BOOL fail);
#endif

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
