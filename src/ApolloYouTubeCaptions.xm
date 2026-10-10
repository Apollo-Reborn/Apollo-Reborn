// ApolloYouTubeCaptions.xm
//
// YouTube videos: keep captions off unless the user asked for them
// (issues #1344 and #747).
//
// THE SYMPTOM
// On iOS 27, a YouTube video opened in Apollo plays with captions (often
// YouTube's auto-generated track) that can't be turned off. For those videos
// the fullscreen player has no Subtitles option at all, and turning every
// switch in Settings > Accessibility > Subtitles & Captioning off makes no
// difference.
//
// THE CAUSE (iOS 27.0 WebKit, 24A434)
// Apollo plays YouTube through YouTubePlayerController: a hidden
// YouTubeWebView (a WKWebView) loads the YouTube IFrame API, and the <video>
// goes straight into WebKit's native fullscreen player. YouTube's embed
// switches its own captions on by itself (seen at loadedmetadata, even with
// WebKit's site quirks disabled). Before iOS 27 those captions only existed in
// the page, which native fullscreen never shows.
// iOS 27 WebKit adds a site-specific quirk for YouTube
// (WebCore::Quirks::needsYouTubeCaptionsQuirk, injected into the page world as
// __InjectedScript_YouTubeCaptionQuirk.js; iOS 26.5's WebCore has none). The
// quirk:
//  - mirrors YouTube's on-page captions into a "forced" text track on the
//    <video>;
//  - when the video leaves inline mode, calls player.loadModule('captions'),
//    which switches YouTube's captions on, and sets that track to "showing";
//  - publishes YouTube's caption tracks to the player's Subtitles menu through
//    navigator.mediaSession, and applies the menu's On through the
//    'selectcaptiontrack' action. The menu's Off is WebKit's own
//    closed-captions switch and never reaches the page.
// Forced tracks are never listed in the Subtitles menu, and nothing checks the
// user's caption settings first. When the embed lists no caption tracks
// (auto-generated captions only), the player has no Subtitles option at all,
// so nothing can turn the mirrored captions off.
//
// THE FIX
// Add a page-world user script to Apollo's YouTube web view, injected in every
// frame; it only acts in the youtube.com embed frame.
//  - It keeps the quirk's forced track "hidden" whenever the quirk asks for
//    "showing", unless captions were asked for.
//  - When the quirk publishes captionsEnabled = true without that, it
//    publishes false instead and turns YouTube's captions off again.
//  - A pick from the Subtitles menu (offered when YouTube lists tracks)
//    decides for the rest of that video.
// Captions count as asked for when Closed Captions + SDH is on, or when iOS's
// subtitle setting for Apollo is On. iOS 27 saves the Subtitles menu's last
// On/Off per app, and that is also the menu's checkmark
// (MACaptionAppearanceGetDisplayType: On is AlwaysOn). Then the script isn't
// added and WebKit's behaviour is unchanged, its Off included. The Automatic
// Subtitles switches only ever store Automatic for Apollo (the menu shows Off),
// so they don't count.
// Without the iOS 27 quirk, no forced track and no caption action handlers
// ever appear, so the script stays inert.

#import <MediaAccessibility/MediaAccessibility.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

static NSString *const kApolloYouTubeCaptionsMessageName = @"apolloYouTubeCaptions";
static NSString *const kApolloYouTubeCaptionsScriptMarker = @"__apolloYouTubeCaptionGuard";

static Class sApolloYouTubeWebViewClass;

static NSString *const kApolloYouTubeCaptionsScript = @""
"(function () {"
"  'use strict';"
"  if (window.__apolloYouTubeCaptionGuard) { return; }"
"  window.__apolloYouTubeCaptionGuard = true;"
   // Apollo's own page is only a shell around the youtube.com embed frame.
"  if (!/(^|\\.)youtube(-nocookie)?\\.com$/i.test(location.hostname)) { return; }"
"  var modeProperty = Object.getOwnPropertyDescriptor(TextTrack.prototype, 'mode');"
"  var addTextTrack = HTMLMediaElement.prototype.addTextTrack;"
"  if (!modeProperty || !modeProperty.get || !modeProperty.set || typeof addTextTrack !== 'function') { return; }"
"  var mirrors = [];"
"  var captionsWanted = false;"
   // YouTube turns its captions back on a few times while a video loads,
   // seeks or loops. Undo that at most 8 times per 10 s so a page that keeps
   // re-enabling them can't spin; the hidden track covers anything past that.
"  var recentTurnOffs = [];"
"  function report(code) {"
"    try { window.webkit.messageHandlers.apolloYouTubeCaptions.postMessage(code); } catch (e) {}"
"  }"
"  function youTubePlayer() {"
"    var video = mirrors.length ? mirrors[mirrors.length - 1].video : null;"
"    return (video && video.closest && video.closest('.html5-video-player')) || document.getElementById('movie_player');"
"  }"
"  function youTubeCaptionsOn(player) {"
"    try { return !!(player && player.isSubtitlesOn()); } catch (e) { return false; }"
"  }"
"  function applyMode(mirror) {"
"    var mode = (mirror.requested === 'showing' && !captionsWanted) ? 'hidden' : mirror.requested;"
"    modeProperty.set.call(mirror.track, mode);"
"  }"
"  function setCaptionsWanted(wanted) {"
"    captionsWanted = wanted;"
"    mirrors.forEach(applyMode);"
"  }"
"  function turnOffYouTubeCaptions() {"
"    var player = youTubePlayer();"
"    if (captionsWanted || !youTubeCaptionsOn(player)) { return; }"
"    var now = Date.now();"
"    recentTurnOffs = recentTurnOffs.filter(function (time) { return now - time < 10000; });"
"    if (recentTurnOffs.length >= 8) { return; }"
"    recentTurnOffs.push(now);"
"    try { player.unloadModule('captions'); report('youtube-off'); } catch (e) {}"
"  }"
   // The quirk builds its mirror with video.addTextTrack('forced', ...).
   // Nothing on YouTube's side adds forced tracks.
"  HTMLMediaElement.prototype.addTextTrack = function (kind) {"
"    var track = addTextTrack.apply(this, arguments);"
"    if (kind !== 'forced' || !track) { return track; }"
"    var mirror = { track: track, video: this, requested: modeProperty.get.call(track) };"
"    mirrors.push(mirror);"
     // The getter reports what the quirk asked for, so its own bookkeeping
     // stays consistent; WebKit renders from the applied mode.
"    Object.defineProperty(track, 'mode', {"
"      configurable: true,"
"      enumerable: true,"
"      get: function () { return mirror.requested; },"
"      set: function (value) {"
"        mirror.requested = String(value);"
"        applyMode(mirror);"
"        if (mirror.requested === 'showing' && !captionsWanted) { report('kept-hidden'); }"
"      }"
"    });"
"    report('guarding');"
"    return track;"
"  };"
"  var session = navigator.mediaSession;"
"  if (!session) { return; }"
   // The quirk writes captionsEnabled every time YouTube's captions change,
   // including right after its own loadModule('captions').
"  var enabledProperty = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(session), 'captionsEnabled');"
"  if (enabledProperty && enabledProperty.get && enabledProperty.set) {"
"    Object.defineProperty(session, 'captionsEnabled', {"
"      configurable: true,"
"      enumerable: true,"
"      get: function () { return enabledProperty.get.call(session); },"
"      set: function (value) {"
"        if (value && !captionsWanted) {"
"          value = false;"
"          setTimeout(turnOffYouTubeCaptions, 0);"
"        }"
"        enabledProperty.set.call(session, value);"
"      }"
"    });"
"  }"
   // The Subtitles menu reaches YouTube through the quirk's handlers for these
   // actions (its On sends 'selectcaptiontrack' with the picked language), so
   // a call here is the user's choice.
"  if (typeof session.setActionHandler === 'function') {"
"    var setActionHandler = session.setActionHandler;"
"    session.setActionHandler = function (action, handler) {"
"      if ((action === 'togglecaptions' || action === 'selectcaptiontrack') && typeof handler === 'function') {"
"        var quirkHandler = handler;"
"        handler = function (details) {"
"          var player = youTubePlayer();"
"          var wanted;"
"          if (action === 'togglecaptions') {"
"            wanted = !captionsWanted;"
"          } else {"
"            var tracks = [];"
"            try { tracks = player.getOption('captions', 'tracklist') || []; } catch (e) {}"
"            var index = details && details.trackIndex;"
"            wanted = typeof index === 'number' && index >= 0 && index < tracks.length;"
"          }"
           // Before the quirk's handler, so the track is already showing when
           // YouTube's first cue arrives.
"          setCaptionsWanted(wanted);"
"          report(wanted ? 'user-on' : 'user-off');"
           // The quirk's toggle flips YouTube's state; skip it when that state
           // already matches what the user picked.
"          if (action === 'togglecaptions' && youTubeCaptionsOn(player) === wanted) { return; }"
"          return quirkHandler.apply(this, arguments);"
"        };"
"      }"
"      return setActionHandler.call(this, action, handler);"
"    };"
"  }"
"})();";

@interface ApolloYouTubeCaptionsMessageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation ApolloYouTubeCaptionsMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    // Any script in the embed frame can post here, so only log the guard's own codes.
    static NSDictionary<NSString *, NSString *> *descriptions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        descriptions = @{
            @"guarding": @"WebKit's YouTube caption mirror track created; guarding it",
            @"kept-hidden": @"kept the caption mirror hidden (captions not requested)",
            @"youtube-off": @"turned off YouTube's own captions",
            @"user-on": @"Subtitles menu: captions turned on",
            @"user-off": @"Subtitles menu: captions turned off",
        };
    });
    NSString *description = [message.body isKindOfClass:[NSString class]] ? descriptions[message.body] : nil;
    if (description) ApolloLog(@"[YouTubeCaptions] %@", description);
}

@end

static void ApolloYouTubeCaptionsInstall(WKWebViewConfiguration *configuration) {
    WKUserContentController *controller = configuration.userContentController;
    if (!controller) return;
    if (UIAccessibilityIsClosedCaptioningEnabled()) {
        ApolloLog(@"[YouTubeCaptions] Closed Captions + SDH is on; leaving YouTube captions to WebKit");
        return;
    }
    if (MACaptionAppearanceGetDisplayType(kMACaptionAppearanceDomainUser) == kMACaptionAppearanceDisplayTypeAlwaysOn) {
        ApolloLog(@"[YouTubeCaptions] Subtitles are On for Apollo; leaving YouTube captions to WebKit");
        return;
    }
    for (WKUserScript *script in controller.userScripts) {
        if ([script.source containsString:kApolloYouTubeCaptionsScriptMarker]) return;
    }

    static ApolloYouTubeCaptionsMessageHandler *handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handler = [ApolloYouTubeCaptionsMessageHandler new];
    });
    [controller addUserScript:[[WKUserScript alloc] initWithSource:kApolloYouTubeCaptionsScript
                                                     injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                  forMainFrameOnly:NO]];
    [controller removeScriptMessageHandlerForName:kApolloYouTubeCaptionsMessageName];
    [controller addScriptMessageHandler:handler name:kApolloYouTubeCaptionsMessageName];
    ApolloLog(@"[YouTubeCaptions] caption guard added to a YouTube player web view");
}

%hook WKWebView

// YouTubeWebView's Swift initializer reaches WKWebView through super, so this
// base implementation is the reliable entry point.
- (id)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    // Every WKWebView in the process comes through here; only Apollo's YouTube
    // player is ours to touch.
    if (!sApolloYouTubeWebViewClass || ![self isKindOfClass:sApolloYouTubeWebViewClass]) return %orig;
    ApolloYouTubeCaptionsInstall(configuration);
    return %orig;
}

%end

%ctor {
    sApolloYouTubeWebViewClass = objc_getClass("_TtC6Apollo14YouTubeWebView");
    if (!sApolloYouTubeWebViewClass) {
        ApolloLog(@"[YouTubeCaptions] YouTubeWebView missing; hook not installed");
        return;
    }
    %init;
    ApolloLog(@"[YouTubeCaptions] hook installed (YouTube captions follow Closed Captions + SDH and the player's Subtitles setting)");
}
