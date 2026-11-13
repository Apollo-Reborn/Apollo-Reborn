#import <WebKit/WebKit.h>

// Starts a YouTube video WebKit refused to autoplay (issue #1647). Called from
// the YouTubeWebView init hook in ApolloYouTubeCaptions.xm, before Apollo's
// own initializer runs.
FOUNDATION_EXPORT void ApolloYouTubePlaybackInstall(WKWebViewConfiguration *configuration);

// What the native handler does with a message (Foundation-only, so the host
// tests compile it). Checked in this order; only ...RetryNow retries.
typedef NS_ENUM(NSInteger, ApolloYouTubePlaybackRetryDecision) {
    ApolloYouTubePlaybackRetryNow,
    ApolloYouTubePlaybackRetryIgnoreMessage,   // not the watcher's "refused"
    ApolloYouTubePlaybackRetryIgnoreFrame,     // not YouTube's HTTPS player frame
    ApolloYouTubePlaybackRetryPlayerClosed,    // no loading screen next to the web view
    ApolloYouTubePlaybackRetryPlayerClosing,   // Cancel / swipe down sliding it away
    ApolloYouTubePlaybackRetryErrorScreen,     // Apollo's YouTube error screen (it hands off itself)
    ApolloYouTubePlaybackRetryLowPowerScreen,  // Apollo's Low Power Mode Play Video button
    ApolloYouTubePlaybackRetryAlreadyRetried,  // this playback had its one retry
};

FOUNDATION_EXPORT BOOL ApolloYouTubePlaybackIsPlayerFrame(BOOL isMainFrame, NSString *scheme, NSString *host, NSInteger port);
FOUNDATION_EXPORT ApolloYouTubePlaybackRetryDecision ApolloYouTubePlaybackRetryDecisionFor(id body, BOOL isPlayerFrame,
                                                                                          BOOL hasLoadingView, BOOL loadingClosing,
                                                                                          BOOL errorOccurred, BOOL lowPowerPlayButton,
                                                                                          BOOL alreadyRetried);
