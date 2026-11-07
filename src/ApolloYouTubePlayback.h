#import <WebKit/WebKit.h>

// Starts a YouTube video WebKit refused to autoplay (issue #1647). Called from
// the YouTubeWebView init hook in ApolloYouTubeCaptions.xm, before Apollo's
// own initializer runs.
FOUNDATION_EXPORT void ApolloYouTubePlaybackInstall(WKWebViewConfiguration *configuration);
