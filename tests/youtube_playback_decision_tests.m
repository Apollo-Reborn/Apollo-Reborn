// Host tests for the native side of the YouTube autoplay retry (#1647,
// src/ApolloYouTubePlayback.m): which frame may ask for a retry, and that each
// playback gets one. run_youtube_playback_retry_tests.sh pastes the production
// decision code in below.
#import <Foundation/Foundation.h>
#import "ApolloYouTubePlayback.h"

// INSERT_PRODUCTION_DECISION

static int sChecks = 0, sFailures = 0;
#define CHECK(cond, ...) do { sChecks++; if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); } } while (0)

typedef struct {
    BOOL isMainFrame;
    const char *scheme;
    const char *host;
    NSInteger port;
} Frame;

static const Frame kPlayer = { NO, "https", "www.youtube.com", 0 };

static NSString *S(const char *s) { return s ? @(s) : nil; }

static BOOL IsPlayer(Frame f) { return ApolloYouTubePlaybackIsPlayerFrame(f.isMainFrame, S(f.scheme), S(f.host), f.port); }

// A playback: Apollo's loading screen next to the web view, and whether the
// native handler already retried it.
typedef struct {
    BOOL hasLoadingView, closing, errorOccurred, lowPowerButton, retried;
} Playback;

static const Playback kLoading = { YES, NO, NO, NO, NO };

static ApolloYouTubePlaybackRetryDecision Decide(id body, Frame f, Playback p) {
    return ApolloYouTubePlaybackRetryDecisionFor(body, IsPlayer(f), p.hasLoadingView, p.closing, p.errorOccurred, p.lowPowerButton, p.retried);
}

// What the handler does: decide, and on a retry mark the playback before the
// retry runs (as the handler does on the loading view).
static ApolloYouTubePlaybackRetryDecision Deliver(id body, Frame f, Playback *p) {
    ApolloYouTubePlaybackRetryDecision d = Decide(body, f, *p);
    if (d == ApolloYouTubePlaybackRetryNow) p->retried = YES;
    return d;
}

int main(void) {
    @autoreleasepool {
        // The player frame, and only it.
        CHECK(IsPlayer(kPlayer), @"www.youtube.com embed frame is the player");
        CHECK(IsPlayer((Frame){ NO, "HTTPS", "WWW.YouTube.com", 443 }), @"scheme/host case and the default port");
        CHECK(IsPlayer((Frame){ NO, "https", "www.youtube-nocookie.com", 0 }), @"privacy-enhanced embed host");
        CHECK(!IsPlayer((Frame){ YES, "https", "www.youtube.com", 0 }), @"a main frame on youtube.com is not the embed");
        CHECK(!IsPlayer((Frame){ YES, "http", "com.christianselig.apollo", 0 }), @"Apollo's own page around the player");
        CHECK(!IsPlayer((Frame){ NO, "http", "www.youtube.com", 0 }), @"plain http");
        CHECK(!IsPlayer((Frame){ NO, "https", "www.youtube.com", 8443 }), @"another port");
        CHECK(!IsPlayer((Frame){ NO, "https", "m.youtube.com", 0 }), @"m.youtube.com is not the embed host");
        CHECK(!IsPlayer((Frame){ NO, "https", "youtube.com", 0 }), @"bare youtube.com");
        CHECK(!IsPlayer((Frame){ NO, "https", "www.youtube.com.example.net", 0 }), @"lookalike suffix");
        CHECK(!IsPlayer((Frame){ NO, "https", "evilwww.youtube.com", 0 }), @"lookalike prefix");
        CHECK(!IsPlayer((Frame){ NO, "https", "googleads.g.doubleclick.net", 0 }), @"an ad frame inside the player");
        CHECK(!IsPlayer((Frame){ NO, "https", "", 0 }), @"empty host (about:blank child)");
        CHECK(!IsPlayer((Frame){ NO, NULL, NULL, 0 }), @"no origin");

        // A refusal from the player while the loading screen is up retries.
        CHECK(Decide(@"refused", kPlayer, kLoading) == ApolloYouTubePlaybackRetryNow, @"refusal retries");

        // Messages that aren't the watcher's.
        CHECK(Decide(@"Refused", kPlayer, kLoading) == ApolloYouTubePlaybackRetryIgnoreMessage, @"other text");
        CHECK(Decide(@{ @"refused": @YES }, kPlayer, kLoading) == ApolloYouTubePlaybackRetryIgnoreMessage, @"a dictionary");
        CHECK(Decide(nil, kPlayer, kLoading) == ApolloYouTubePlaybackRetryIgnoreMessage, @"no body");

        // Unexpected frames never retry, whatever the player's state.
        CHECK(Decide(@"refused", (Frame){ YES, "http", "com.christianselig.apollo", 0 }, kLoading) == ApolloYouTubePlaybackRetryIgnoreFrame, @"Apollo's page");
        CHECK(Decide(@"refused", (Frame){ NO, "https", "googleads.g.doubleclick.net", 0 }, kLoading) == ApolloYouTubePlaybackRetryIgnoreFrame, @"an ad frame");
        CHECK(Decide(@"refused", (Frame){ NO, "http", "www.youtube.com", 0 }, kLoading) == ApolloYouTubePlaybackRetryIgnoreFrame, @"http player");

        // Player states Apollo owns.
        CHECK(Decide(@"refused", kPlayer, (Playback){ NO, NO, NO, NO, NO }) == ApolloYouTubePlaybackRetryPlayerClosed, @"closed player");
        CHECK(Decide(@"refused", kPlayer, (Playback){ YES, YES, NO, NO, NO }) == ApolloYouTubePlaybackRetryPlayerClosing, @"Cancel sliding it away");
        CHECK(Decide(@"refused", kPlayer, (Playback){ YES, NO, YES, NO, NO }) == ApolloYouTubePlaybackRetryErrorScreen, @"Apollo's error screen hands off itself");
        CHECK(Decide(@"refused", kPlayer, (Playback){ YES, NO, NO, YES, NO }) == ApolloYouTubePlaybackRetryLowPowerScreen, @"Low Power Mode screen");

        // One retry per playback: duplicates, a forged second message from the
        // player frame, and a refusal of the retry itself all stop there.
        {
            Playback p = kLoading;
            CHECK(Deliver(@"refused", kPlayer, &p) == ApolloYouTubePlaybackRetryNow, @"first refusal retries");
            CHECK(Deliver(@"refused", kPlayer, &p) == ApolloYouTubePlaybackRetryAlreadyRetried, @"duplicate refusal");
            CHECK(Deliver(@"refused", kPlayer, &p) == ApolloYouTubePlaybackRetryAlreadyRetried, @"third refusal");
            CHECK(Deliver(@"refused", (Frame){ NO, "https", "www.youtube-nocookie.com", 0 }, &p) == ApolloYouTubePlaybackRetryAlreadyRetried, @"another player frame in the same playback");
        }
        // An unexpected frame first doesn't use up the playback's retry.
        {
            Playback p = kLoading;
            CHECK(Deliver(@"refused", (Frame){ YES, "http", "com.christianselig.apollo", 0 }, &p) == ApolloYouTubePlaybackRetryIgnoreFrame, @"main frame first");
            CHECK(!p.retried, @"main frame did not use the retry");
            CHECK(Deliver(@"refused", kPlayer, &p) == ApolloYouTubePlaybackRetryNow, @"then the player's refusal retries");
        }
        // Cancelled first, then refusals: nothing retries, and the retry stays unused.
        {
            Playback p = (Playback){ YES, YES, NO, NO, NO };
            CHECK(Deliver(@"refused", kPlayer, &p) == ApolloYouTubePlaybackRetryPlayerClosing, @"refusal during Cancel");
            p.hasLoadingView = NO;
            CHECK(Deliver(@"refused", kPlayer, &p) == ApolloYouTubePlaybackRetryPlayerClosed, @"refusal after the player closed");
            CHECK(!p.retried, @"no retry recorded after Cancel");
        }
        // A new playback (a new loading screen) gets its own retry.
        {
            Playback first = kLoading, second = kLoading;
            Deliver(@"refused", kPlayer, &first);
            CHECK(Deliver(@"refused", kPlayer, &second) == ApolloYouTubePlaybackRetryNow, @"second video retries");
        }

        printf("%d checks, %d failures\n", sChecks, sFailures);
        return sFailures == 0 ? 0 : 1;
    }
}
