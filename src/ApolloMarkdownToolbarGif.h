#import <Foundation/Foundation.h>

/// Bootstrap markdown toolbar Gif injection. Called from Tweak.xm %ctor.
void ApolloMarkdownGifInstall(void);

/// Cached regex matching the `![gif](giphy|<id>)` tokens this module inserts
/// when the user picks a GIF from the toolbar. Shared with the submit-form
/// rewriter (`ApolloImageUploadHost.xm`) and the body-text renderer
/// (`ApolloMedia.xm`) so all three sites agree on the exact token shape.
/// Capture group 1 is the bare Giphy GIF ID.
NSRegularExpression *ApolloNativeGiphyMarkdownTokenRegex(void);
