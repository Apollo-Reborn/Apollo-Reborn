// The update manifest and its HTTP validator are one cache entry. Keeping them
// together lets a 304 be parsed exactly like a 200, including after a relaunch.
// Foundation-only; see tests/run_update_manifest_cache_tests.sh.

#import <Foundation/Foundation.h>
#import "ApolloUpdateManifest.h"

NS_ASSUME_NONNULL_BEGIN

// Call on one serial queue (the checker's main queue). Only a validated manifest
// is saved; this cache contains public release metadata, never account data.
@interface ApolloUpdateManifestCache : NSObject

// Library/Caches/ApolloReborn/UpdateManifest.plist in the app's container.
- (instancetype)init;
// Injectable storage location for the host tests. A failed write still leaves
// the validated entry usable in memory for this launch.
- (instancetype)initWithFileURL:(NSURL *)fileURL NS_DESIGNATED_INITIALIZER;

// Bypasses NSURLCache so our saved body and ETag are the only conditional pair.
// Never sends a validator without a body usable by the current variant parser.
- (NSURLRequest *)requestForURL:(NSURL *)url variantKey:(nullable NSString *)variantKey;
- (nullable ApolloUpdateInfo *)cachedInfoForURL:(NSURL *)url variantKey:(nullable NSString *)variantKey;

// Call only when the transport completed without an error. A valid 200 replaces
// the pair; a matching 304 reuses it; failures leave the last good body intact.
// An impossible 304 drops the validator so the next request is unconditional.
// Simulator file:// responses are parsed but never stored as an HTTP cache entry.
- (nullable ApolloUpdateInfo *)infoForResponse:(nullable NSURLResponse *)response
                                        data:(nullable NSData *)data
                                     request:(NSURLRequest *)request
                                  variantKey:(nullable NSString *)variantKey;

@end

NS_ASSUME_NONNULL_END
