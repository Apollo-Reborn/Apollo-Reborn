#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Deterministic, Foundation-only helpers used by the runtime and host tests.
FOUNDATION_EXPORT NSDictionary * _Nullable ApolloICloudReadStateValidatedJournal(id value);
FOUNDATION_EXPORT NSDictionary *ApolloICloudReadStateMergeJournals(NSArray<NSDictionary *> *journals);
FOUNDATION_EXPORT NSArray<NSString *> *ApolloICloudReadStateProjectedReadIDs(NSDictionary *merged,
                                                                             NSUInteger limit);
FOUNDATION_EXPORT NSData * _Nullable ApolloICloudReadStateProjectedCommentData(NSDictionary *merged,
                                                                                NSUInteger limit);
FOUNDATION_EXPORT NSData * _Nullable ApolloICloudReadStateEncrypt(NSData *plaintext, NSData *key,
                                                                   NSError **error);
FOUNDATION_EXPORT NSData * _Nullable ApolloICloudReadStateDecrypt(NSData *envelope, NSData *key,
                                                                   NSError **error);
FOUNDATION_EXPORT NSDictionary *ApolloICloudReadStateJournalByCapturing(
    NSDictionary *journal, NSArray<NSString *> *readIDs, NSDictionary<NSString *, NSDictionary *> *comments,
    NSSet<NSString *> * _Nullable previousReadIDs, NSTimeInterval now, BOOL historicalSeed);
FOUNDATION_EXPORT NSData *ApolloICloudReadStateResetMarker(long long generation);
FOUNDATION_EXPORT BOOL ApolloICloudReadStateParseResetMarker(NSData *data, long long * _Nullable generation);

@interface ApolloICloudReadState : NSObject
+ (instancetype)sharedManager;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, getter=isAvailable) BOOL available;
@property (nonatomic, readonly, getter=isRecoveryNeeded) BOOL recoveryNeeded;
@property (nonatomic, readonly, nullable) NSString *availabilityMessage;

// Called after defaults are registered. The manager is completely dormant while
// the opt-in is off. Returns NO without changing the setting when iCloud KVS is
// unavailable for the current signing identity.
- (void)start;
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error;
// Explicit recovery for a mismatched first-time encryption-key race. Deletes
// only this feature's encrypted cloud value and synchronizable key, then turns
// sync off; local Apollo history is never changed.
- (BOOL)resetEncryptedCloudState:(NSError **)error;

// Explicit user intent. Ordinary native history eviction must not become a
// cross-device unread event.
- (void)recordPostIDAsUnread:(NSString *)postID;
- (void)recordClearAll;

@end

NS_ASSUME_NONNULL_END
