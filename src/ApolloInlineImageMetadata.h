#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns height / width for a Reddit-hosted image whose URL can be matched
/// to one valid media_metadata entry. Returns 0 when the URL is external, the
/// entry cannot be identified unambiguously, or dimensions are unavailable.
FOUNDATION_EXPORT double ApolloInlineImageAspectRatioFromMediaMetadata(
    NSURL *url,
    NSDictionary * _Nullable mediaMetadata);

/// Remembers image dimensions from a comment's or post's media_metadata when
/// the model is parsed. Texture measures a new comment body before its
/// MarkdownNode joins the CommentCellNode, so the host model cannot always be
/// reached when the inline image node is first created.
FOUNDATION_EXPORT void ApolloInlineImageRegisterMediaMetadata(
    NSDictionary * _Nullable mediaMetadata);

/// Returns height / width recorded by ApolloInlineImageRegisterMediaMetadata
/// for a Reddit-hosted image URL, keyed by its asset ID. Returns 0 when the URL
/// is external or its asset has not been registered.
FOUNDATION_EXPORT double ApolloInlineImageAspectRatioFromRegisteredMetadata(NSURL *url);

NS_ASSUME_NONNULL_END
