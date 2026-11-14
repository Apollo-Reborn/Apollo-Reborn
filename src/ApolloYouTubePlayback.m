// ApolloYouTubePlayback.m
//
// YouTube videos: start a video WebKit refused to autoplay (issue #1647).
//
// THE SYMPTOM
// Tapping a YouTube video leaves Apollo's "Loading..." screen up forever: no
// error, no video, no sound. Cancel and Open in Safari still work.
//
// THE CAUSE
// Apollo plays YouTube in a hidden YouTubeWebView. Its page cues the video
// through the YouTube IFrame API, then calls loadPlaylist, so YouTube's embed
// calls play() on its <video> from script, with no tap behind it. The web view
// lets that through (mediaTypesRequiringUserActionForPlayback is none), and
// with inline playback off the video goes straight into WebKit's fullscreen
// player. Apollo removes the loading screen only when that fullscreen window
// appears, and has no timeout.
// WebKit still refuses a script play() without a tap in some states, even
// with that setting: Low Power Mode, a hot phone (thermal mitigation) and
// possibly others. play() then rejects with NotAllowedError and nothing else
// happens. Apollo handles Low Power Mode only: there its loading screen shows
// "Play Video", whose tap passes through to the web view, so WebKit gets a
// real tap. In every other refusal the screen just spins.
// A forced refusal (mediaTypesRequiringUserActionForPlayback = all) gives the
// reporter's screen and log line for line on iOS 27.2.
//
// THE FIX
// A page-world user script in the youtube.com embed frame watches play() on
// the <video>. When WebKit rejects it with NotAllowedError, it tells us, and we
// call play() again in that frame through callAsyncJavaScript. WebKit runs
// script from the app as a user action (WKWebView's evaluate/call APIs force a
// user gesture), so the retry is allowed and the video goes fullscreen as
// usual. Low Power Mode keeps Apollo's own Play Video screen: when the loading
// screen has that button, we leave it alone.
//
// Only an autoplay refusal is handled here. When the video's owner doesn't
// allow it to be embedded (YouTube's onError 101/150), Apollo's own error
// screen and its YouTube/Safari handoff stay as they are.
//
// The message handler can be reached by any script in any frame of the page,
// so the decision to retry is native (ApolloYouTubePlaybackRetryDecision): the
// message has to come from YouTube's HTTPS player frame, and each playback
// (one YouTubeLoadingView) gets one retry, recorded on that loading view before
// the retry runs. A duplicate or forged message after that does nothing.

#import "ApolloYouTubePlayback.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"

static NSString *const kApolloYouTubePlaybackMessageName = @"apolloYouTubePlayback";
static NSString *const kApolloYouTubePlaybackScriptMarker = @"__apolloYouTubePlaybackRetry";

static NSString *const kApolloYouTubePlaybackScript = @""
"(function () {"
"  'use strict';"
"  if (window.__apolloYouTubePlaybackRetry) { return; }"
"  window.__apolloYouTubePlaybackRetry = true;"
   // Apollo's own page is only a shell around the youtube.com embed frame.
"  if (!/(^|\\.)youtube(-nocookie)?\\.com$/i.test(location.hostname)) { return; }"
"  var play = HTMLMediaElement.prototype.play;"
"  if (typeof play !== 'function') { return; }"
"  var reported = false;"
"  HTMLMediaElement.prototype.play = function () {"
"    var result = play.apply(this, arguments);"
     // YouTube gets play()'s own promise back, rejection included. The catch
     // below hangs off a separate branch of it.
"    if (!reported && this instanceof HTMLVideoElement && result && typeof result.catch === 'function') {"
"      result.catch(function (error) {"
"        if (reported || !error || error.name !== 'NotAllowedError') { return; }"
"        reported = true;"
"        try { window.webkit.messageHandlers.apolloYouTubePlayback.postMessage('refused'); } catch (e) {}"
"      });"
"    }"
"    return result;"
"  };"
"})();";

// Runs in the embed frame, in our own content world, so it calls WebKit's
// play() rather than the wrapper above. YouTube keeps one <video> per player.
static NSString *const kApolloYouTubePlaybackRetryScript = @""
"var video = document.querySelector('video.html5-main-video') || document.querySelector('video');"
"if (!video) { return 'no-video'; }"
"if (!video.paused) { return 'already-playing'; }"
"await video.play();"
"return 'playing';";

// BEGIN_YOUTUBE_RETRY_DECISION (tests/run_youtube_playback_retry_tests.sh
// compiles this part on the Mac.)

// The IFrame API puts the player in an https://www.youtube.com/embed/... frame
// (www.youtube-nocookie.com when a page asks for privacy-enhanced mode). Apollo's
// own page around it is http://<bundle id>, and the player can hold other
// frames (ads, sign-in). Only the player frame's refusal is ours to retry.
BOOL ApolloYouTubePlaybackIsPlayerFrame(BOOL isMainFrame, NSString *scheme, NSString *host, NSInteger port) {
    if (isMainFrame) return NO;
    // Checked first: a compare sent to nil returns 0, which reads as NSOrderedSame.
    if (scheme.length == 0 || host.length == 0) return NO;
    if ([scheme caseInsensitiveCompare:@"https"] != NSOrderedSame) return NO;
    if (port != 0 && port != 443) return NO;
    return [host caseInsensitiveCompare:@"www.youtube.com"] == NSOrderedSame ||
           [host caseInsensitiveCompare:@"www.youtube-nocookie.com"] == NSOrderedSame;
}

ApolloYouTubePlaybackRetryDecision ApolloYouTubePlaybackRetryDecisionFor(id body, BOOL isPlayerFrame,
                                                                         BOOL hasLoadingView, BOOL loadingClosing,
                                                                         BOOL errorOccurred, BOOL lowPowerPlayButton,
                                                                         BOOL alreadyRetried) {
    if (![body isEqual:@"refused"]) return ApolloYouTubePlaybackRetryIgnoreMessage;
    if (!isPlayerFrame) return ApolloYouTubePlaybackRetryIgnoreFrame;
    if (!hasLoadingView) return ApolloYouTubePlaybackRetryPlayerClosed;
    if (loadingClosing) return ApolloYouTubePlaybackRetryPlayerClosing;
    if (errorOccurred) return ApolloYouTubePlaybackRetryErrorScreen;
    if (lowPowerPlayButton) return ApolloYouTubePlaybackRetryLowPowerScreen;
    if (alreadyRetried) return ApolloYouTubePlaybackRetryAlreadyRetried;
    return ApolloYouTubePlaybackRetryNow;
}

// END_YOUTUBE_RETRY_DECISION

static Class sApolloYouTubeLoadingViewClass;
// On the YouTubeLoadingView: this playback already got its retry.
static char kApolloYouTubePlaybackRetriedKey;

// Apollo adds its loading screen and the web view to the same window
// (FUN_10072f28c) and removes both when the player closes. No loading screen
// next to the web view means the player is gone or never showed.
static UIView *ApolloYouTubeLoadingViewForWebView(WKWebView *webView) {
    if (!webView.window) return nil;
    for (UIView *view in webView.superview.subviews) {
        if ([view isKindOfClass:sApolloYouTubeLoadingViewClass]) return view;
    }
    return nil;
}

// Cancel and the swipe down on the loading screen (both
// cancelTappedWithSender:) stop the page, then slide the screen down with a
// property animator (transform = translate(0, opener height), FUN_100730f2c)
// and only remove the views when it finishes. The transform is the animation's
// target, set as it starts, so a refusal that lands during the slide sees it.
// YouTube can still call play() in that window.
static BOOL ApolloYouTubeLoadingIsClosing(UIView *loading) {
    return !CGAffineTransformIsIdentity(loading.transform);
}

@interface ApolloYouTubePlaybackMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation ApolloYouTubePlaybackMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    WKWebView *webView = message.webView;
    WKFrameInfo *frame = message.frameInfo;
    if (!webView || !frame) return;
    WKSecurityOrigin *origin = frame.securityOrigin;
    BOOL playerFrame = ApolloYouTubePlaybackIsPlayerFrame(frame.isMainFrame, origin.protocol, origin.host, origin.port);
    UIView *loading = ApolloYouTubeLoadingViewForWebView(webView);
    // Apollo builds its Low Power Mode "Play Video" button only when Low Power
    // Mode is on as the loading screen is made. That screen is Apollo's answer
    // to this same refusal, so it stays the user's tap.
    ApolloYouTubePlaybackRetryDecision decision = ApolloYouTubePlaybackRetryDecisionFor(
        message.body, playerFrame,
        loading != nil,
        loading && ApolloYouTubeLoadingIsClosing(loading),
        loading && ApolloReadBoolIvar(loading, "errorOccurred", NO),
        loading && ApolloObjectIvar(loading, "lowPowerModePlayButton") != nil,
        loading && objc_getAssociatedObject(loading, &kApolloYouTubePlaybackRetriedKey) != nil);

    switch (decision) {
        case ApolloYouTubePlaybackRetryIgnoreMessage:
            return;   // not our watcher's message
        case ApolloYouTubePlaybackRetryIgnoreFrame:
            ApolloLog(@"[YouTubePlayback] ignored a refusal from %@ (%@://%@:%ld), not YouTube's player frame",
                      frame.isMainFrame ? @"the main frame" : @"a subframe", origin.protocol ?: @"?", origin.host ?: @"?", (long)origin.port);
            return;
        case ApolloYouTubePlaybackRetryPlayerClosed:
            ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay, but the player is closed; leaving it");
            return;
        case ApolloYouTubePlaybackRetryPlayerClosing:
            ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay, but the player is closing (Cancel); leaving it");
            return;
        case ApolloYouTubePlaybackRetryErrorScreen:
            ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay after Apollo's YouTube error screen; leaving it");
            return;
        case ApolloYouTubePlaybackRetryLowPowerScreen:
            ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay; Apollo's Low Power Mode Play Video button is up, leaving it to the user");
            return;
        case ApolloYouTubePlaybackRetryAlreadyRetried:
            ApolloLog(@"[YouTubePlayback] another refusal for this playback; it already had its one retry, leaving it");
            return;
        case ApolloYouTubePlaybackRetryNow:
            break;
    }
    // Recorded before the call, so a message that arrives while the retry is
    // still running can't start a second one.
    objc_setAssociatedObject(loading, &kApolloYouTubePlaybackRetriedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay the video in %@ (lowPower=%d thermal=%ld); starting it as a user action",
              origin.host, NSProcessInfo.processInfo.isLowPowerModeEnabled, (long)NSProcessInfo.processInfo.thermalState);
    [webView callAsyncJavaScript:kApolloYouTubePlaybackRetryScript
                       arguments:nil
                         inFrame:frame
                  inContentWorld:WKContentWorld.defaultClientWorld
               completionHandler:^(id result, NSError *error) {
        if (error) {
            ApolloLog(@"[YouTubePlayback] retry failed: %@ %ld", error.domain, (long)error.code);
        } else {
            ApolloLog(@"[YouTubePlayback] retry result: %@", [result isKindOfClass:NSString.class] ? result : @"?");
        }
    }];
}

@end

void ApolloYouTubePlaybackInstall(WKWebViewConfiguration *configuration) {
    WKUserContentController *controller = configuration.userContentController;
    if (!controller) return;
    for (WKUserScript *script in controller.userScripts) {
        if ([script.source containsString:kApolloYouTubePlaybackScriptMarker]) return;
    }

    static ApolloYouTubePlaybackMessageHandler *handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handler = [ApolloYouTubePlaybackMessageHandler new];
        sApolloYouTubeLoadingViewClass = objc_getClass("_TtC6Apollo18YouTubeLoadingView");
        if (!sApolloYouTubeLoadingViewClass) {
            ApolloLog(@"[YouTubePlayback] YouTubeLoadingView missing; autoplay retry NOT installed");
        }
    });
    // The retry only runs while that loading screen is up, so without the
    // class there is nothing to add.
    if (!sApolloYouTubeLoadingViewClass) return;
    [controller addUserScript:[[WKUserScript alloc] initWithSource:kApolloYouTubePlaybackScript
                                                     injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                  forMainFrameOnly:NO]];
    [controller removeScriptMessageHandlerForName:kApolloYouTubePlaybackMessageName];
    [controller addScriptMessageHandler:handler name:kApolloYouTubePlaybackMessageName];
    ApolloLog(@"[YouTubePlayback] autoplay retry added to a YouTube player web view");
}
