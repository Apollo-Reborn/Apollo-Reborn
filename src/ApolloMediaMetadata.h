#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// YES for Reddit-uploaded GIF asset IDs (not giphy| tokens).
BOOL ApolloMetadataEntryIsRedditHostedGIF(NSString *assetID, NSDictionary *entry);

/// Canonical inline display URL for a Reddit-hosted GIF asset.
NSString *_Nullable ApolloRedditHostedGIFDisplayURL(NSString *assetID);

/// Normalize Reddit-hosted GIF entries so s.gif/s.mp4 point at i.redd.it.
NSDictionary *ApolloFixRedditHostedGifMetadata(NSDictionary *orig, NSUInteger *_Nullable outFixedCount);

/// Resolve a media_metadata entry to an inline display URL.
/// preferMP4ForExternalGIFs mirrors sPreferredGIFFallbackFormat for non-Reddit GIFs.
NSString *_Nullable ApolloMediaDisplayURLFromMetadataEntry(NSString *assetID,
                                                            NSDictionary *entry,
                                                            BOOL preferMP4ForExternalGIFs);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
