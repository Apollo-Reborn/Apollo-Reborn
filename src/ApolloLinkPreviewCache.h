#import <Foundation/Foundation.h>

#import "ApolloLinkPreviewModel.h"

@interface ApolloLinkPreviewCache : NSObject

+ (instancetype)sharedCache;
- (ApolloLinkPreview *)cachedPreviewForURL:(NSURL *)url;
- (BOOL)cachedPreviewIsRichForURL:(NSURL *)url;
- (void)storePreview:(ApolloLinkPreview *)preview forURL:(NSURL *)url;
- (void)markNoMetadataForURL:(NSURL *)url;
// Empties the in-memory and disk caches. Triggered from the "Clear Link
// Preview Cache" settings row when entries get poisoned across versions.
- (void)flushCache;

@end
