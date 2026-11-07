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
// usual. One retry per page, and only while Apollo's loading screen is up.
// Low Power Mode keeps Apollo's own Play Video screen: when the loading screen
// has that button, we leave it alone.

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

static Class sApolloYouTubeLoadingViewClass;

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
    // Any script in the embed frame can post here; only act on our own code.
    if (![message.body isEqual:@"refused"]) return;
    WKWebView *webView = message.webView;
    WKFrameInfo *frame = message.frameInfo;
    if (!webView || !frame) return;
    UIView *loading = ApolloYouTubeLoadingViewForWebView(webView);
    if (!loading || ApolloYouTubeLoadingIsClosing(loading)) {
        ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay, but the player is %@; leaving it",
                  loading ? @"closing (Cancel)" : @"closed");
        return;
    }
    if (ApolloReadBoolIvar(loading, "errorOccurred", NO)) {
        ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay after Apollo's YouTube error screen; leaving it");
        return;
    }
    // Apollo builds its Low Power Mode "Play Video" button only when Low Power
    // Mode is on as the loading screen is made. That screen is Apollo's answer
    // to this same refusal, so it stays the user's tap.
    if (ApolloObjectIvar(loading, "lowPowerModePlayButton")) {
        ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay; Apollo's Low Power Mode Play Video button is up, leaving it to the user");
        return;
    }
    ApolloLog(@"[YouTubePlayback] WebKit refused to autoplay the video (lowPower=%d thermal=%ld); starting it as a user action",
              NSProcessInfo.processInfo.isLowPowerModeEnabled, (long)NSProcessInfo.processInfo.thermalState);
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
