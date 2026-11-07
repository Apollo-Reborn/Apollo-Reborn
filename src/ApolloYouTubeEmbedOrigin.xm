// ApolloYouTubeEmbedOrigin.xm
//
// YouTube videos whose owner only allows embedding on approved sites: play
// them in Apollo's player instead of showing "Error Occurred! Off to Safari we
// goooo..." and handing them to Safari.
//
// THE SYMPTOM
// With Settings > General > Open in App > YouTube off, tapping some YouTube
// videos (NFL highlights, e.g. the r/CHIBears post 1xizvlz) shows "Error
// Occurred! Off to Safari we goooo..." over the thumbnail, then opens the
// video in Safari. Most other YouTube videos play in Apollo.
//
// THE CAUSE (Apollo binary, YouTubePlayerController.swift)
// Apollo plays YouTube through YouTubePlayerController. Its loader
// (FUN_10072f28c) puts a YouTubeWebView (a WKWebView) behind
// YouTubeLoadingView and loads a small page that runs the YouTube IFrame API,
// with loadHTMLString:baseURL: and baseURL "http://<bundle id>". The same URL
// string is the player's "origin" playerVar, so YouTube sees the embed as
// coming from that site. An owner can limit embedding to sites they approve,
// and YouTube then answers the cue with onError 150 (101 is the older code for
// the same refusal). The page posts that to the "errorCallback" script message;
// Apollo's handler (FUN_100737070) sets YouTubeLoadingView.errorOccurred, fades
// in the error label and opens the video in Safari 0.7 s later.
// youtube.com itself counts as an approved site: the same page served from
// https://m.youtube.com cues and plays these videos (checked in the simulator).
// https://www.youtube.com does not work as the origin; YouTube answers 152.
//
// THE FIX
// Every video still loads with Apollo's own origin first. When YouTube refuses
// that origin with 150 or 101, reload the same page once, in the same web
// view, with origin https://m.youtube.com, and keep that error from Apollo, so
// its loading screen stays up and its cued and duration callbacks fire as
// usual. Any other error, or an error from the m.youtube.com page, reaches
// Apollo unchanged, so its Safari fallback still covers videos that can't be
// embedded anywhere.
// The reloaded main frame is now on youtube.com, so ApolloYouTubeCaptions'
// user script also starts in it; that frame has no <video> and no caption
// action handlers, so the guard stays inert there.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

static NSString *const kApolloYouTubeErrorMessageName = @"errorCallback";
static NSString *const kApolloYouTubeFallbackOrigin = @"https://m.youtube.com";

static Class sApolloYouTubeWebViewClass;
// Set while this file reloads a page, so the loadHTMLString: hook doesn't take
// the reload for a new video.
static BOOL sApolloYouTubeReloading;

// Per YouTubeWebView: the player page with its origin switched to
// kApolloYouTubeFallbackOrigin (nil when the page isn't the template this file
// knows), and whether that page has been loaded.
static const void *kApolloYouTubeFallbackPageKey = &kApolloYouTubeFallbackPageKey;
static const void *kApolloYouTubeRetriedKey = &kApolloYouTubeRetriedKey;

@interface ApolloYouTubePlayerController : NSObject <WKScriptMessageHandler>
@end

// Apollo's page sets playerVars { "origin": "<baseURL.absoluteString>" }.
// Swap that one value; the base URL is swapped by the caller.
static NSString *ApolloYouTubeFallbackPage(NSString *html, NSURL *baseURL) {
    NSString *origin = baseURL.absoluteString;
    if (html.length == 0 || origin.length == 0) return nil;
    NSString *current = [NSString stringWithFormat:@"\"origin\": \"%@\"", origin];
    NSRange range = [html rangeOfString:current];
    if (range.location == NSNotFound) return nil;
    NSString *replacement = [NSString stringWithFormat:@"\"origin\": \"%@\"", kApolloYouTubeFallbackOrigin];
    return [html stringByReplacingCharactersInRange:range withString:replacement];
}

// The page's onError listener posts window.event.data: the IFrame API widget's
// JSON message, e.g. {"event":"onError","info":150,"channel":"widget","id":1}.
// Returns NSNotFound when there's no error code in it.
static NSInteger ApolloYouTubeErrorCode(id body) {
    id info = body;
    if ([body isKindOfClass:[NSString class]]) {
        NSData *data = [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        info = [json isKindOfClass:[NSDictionary class]] ? json[@"info"] : nil;
    } else if ([body isKindOfClass:[NSDictionary class]]) {
        info = body[@"info"];
    }
    if ([info isKindOfClass:[NSNumber class]]) return [info integerValue];
    if ([info isKindOfClass:[NSString class]] && [(NSString *)info length] > 0) return [info integerValue];
    return NSNotFound;
}

%hook WKWebView

// Apollo builds a new YouTubeWebView for every video and loads the player page
// into it once. Remember the page so a refusal can reload it.
- (WKNavigation *)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    // Every WKWebView in the process comes through here; only Apollo's YouTube
    // player is ours to touch.
    if (sApolloYouTubeReloading || !sApolloYouTubeWebViewClass || ![self isKindOfClass:sApolloYouTubeWebViewClass]) return %orig;
    NSString *fallbackPage = ApolloYouTubeFallbackPage(string, baseURL);
    objc_setAssociatedObject(self, kApolloYouTubeFallbackPageKey, fallbackPage, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, kApolloYouTubeRetriedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!fallbackPage) {
        ApolloLog(@"[YouTubeEmbed] player page has no \"origin\" for %@; a refused embed goes to Safari as before", baseURL.host ?: @"(no base URL)");
    }
    return %orig;
}

%end

%group ApolloYouTubeEmbedOriginHooks

%hook ApolloYouTubePlayerController

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:kApolloYouTubeErrorMessageName]) {
        %orig;
        return;
    }

    WKWebView *webView = message.webView;
    NSInteger code = ApolloYouTubeErrorCode(message.body);
    NSString *frameHost = message.frameInfo.securityOrigin.host;
    BOOL retried = webView && [objc_getAssociatedObject(webView, kApolloYouTubeRetriedKey) boolValue];

    if (retried) {
        // The IFrame API can post onError more than once. A late one from the
        // page being replaced must not open Safari over the reload.
        if (![frameHost isEqualToString:[NSURL URLWithString:kApolloYouTubeFallbackOrigin].host]) {
            ApolloLog(@"[YouTubeEmbed] dropped a late error %ld from the replaced %@ page", (long)code, frameHost ?: @"(unknown)");
            return;
        }
        ApolloLog(@"[YouTubeEmbed] YouTube also refused the %@ origin (error %ld); leaving it to Apollo's Safari fallback",
                  kApolloYouTubeFallbackOrigin, (long)code);
        %orig;
        return;
    }

    if (code != 150 && code != 101) {
        ApolloLog(@"[YouTubeEmbed] player error %ld; not an embedding refusal, leaving it to Apollo", (long)code);
        %orig;
        return;
    }

    NSString *fallbackPage = webView ? objc_getAssociatedObject(webView, kApolloYouTubeFallbackPageKey) : nil;
    if (!fallbackPage) {
        ApolloLog(@"[YouTubeEmbed] YouTube refused the embed (error %ld) but the player page wasn't captured; leaving it to Apollo", (long)code);
        %orig;
        return;
    }

    objc_setAssociatedObject(webView, kApolloYouTubeRetriedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[YouTubeEmbed] YouTube refused the embed from %@ (error %ld); reloading the player with origin %@",
              frameHost ?: @"(unknown)", (long)code, kApolloYouTubeFallbackOrigin);
    sApolloYouTubeReloading = YES;
    @try {
        [webView loadHTMLString:fallbackPage baseURL:[NSURL URLWithString:kApolloYouTubeFallbackOrigin]];
    } @finally {
        sApolloYouTubeReloading = NO;
    }
}

%end

%end

%ctor {
    sApolloYouTubeWebViewClass = objc_getClass("_TtC6Apollo14YouTubeWebView");
    Class playerController = objc_getClass("_TtC6Apollo23YouTubePlayerController");
    SEL messageSelector = @selector(userContentController:didReceiveScriptMessage:);
    if (!sApolloYouTubeWebViewClass || !playerController || !class_getInstanceMethod(playerController, messageSelector)) {
        ApolloLog(@"[YouTubeEmbed] YouTubeWebView or YouTubePlayerController missing; hook not installed");
        return;
    }
    %init;
    %init(ApolloYouTubeEmbedOriginHooks, ApolloYouTubePlayerController = playerController);
    ApolloLog(@"[YouTubeEmbed] hook installed (videos only embeddable on approved sites retry with a youtube.com origin)");
}
