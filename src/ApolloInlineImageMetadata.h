#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns height / width for a Reddit-hosted image whose URL can be matched
/// to one valid media_metadata entry. Returns 0 when the URL is external, the
/// entry cannot be identified unambiguously, or dimensions are unavailable.
FOUNDATION_EXPORT double ApolloInlineImageAspectRatioFromMediaMetadata(
    NSURL *url,
    NSDictionary * _Nullable mediaMetadata);

NS_ASSUME_NONNULL_END
