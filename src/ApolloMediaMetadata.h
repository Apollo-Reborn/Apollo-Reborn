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

/// Reddit marks every photo of a gallery made through its public API
/// (media/asset.json upload + submit_gallery_post.json, used by Apollo Reborn
/// and PRAW) as media_metadata {"status": "failed"}, with no URLs or sizes,
/// although the photos are served at i.redd.it/<media_id>.<ext> and show on
/// reddit.com (#1587). Apollo keeps only "valid" items, so such a post opens as
/// a bare reddit.com/gallery link with 0 images. Returns a copy of `metadata`
/// with each failed gallery item rebuilt as a valid entry pointing at
/// i.redd.it, or nil when no gallery item needed it. `galleryItems` is
/// gallery_data.items (or the gallery_data dictionary); `thumbnailURL` is the
/// post's thumbnail, which carries the first photo's file extension.
/// `knownExtensions` maps media IDs this device uploaded to the extension it
/// uploaded them with; those photos are also rebuilt while still
/// "unprocessed", right after posting.
NSDictionary *_Nullable ApolloRepairFailedRedditGalleryMetadata(NSDictionary *_Nullable metadata,
                                                               id _Nullable galleryItems,
                                                               NSString *_Nullable thumbnailURL,
                                                               NSDictionary<NSString *, NSString *> *_Nullable knownExtensions);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
