#import <Foundation/Foundation.h>
#import <math.h>
#import "ApolloGallerySlideshow.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

// An empty page: nothing loaded, no player.
static ApolloGallerySlideSample S(void) {
    ApolloGallerySlideSample sample;
    memset(&sample, 0, sizeof(sample));
    sample.playbackPosition = NAN;
    return sample;
}

static ApolloGallerySlideshow *Begin(ApolloGallerySlideKind kind, NSTimeInterval photoSeconds, NSTimeInterval now) {
    ApolloGallerySlideshow *model = [[ApolloGallerySlideshow alloc] init];
    [model beginSlideOfKind:kind photoSeconds:photoSeconds atTime:now];
    return model;
}

static ApolloGallerySlideshowAdvance T(ApolloGallerySlideshow *model, NSTimeInterval now, ApolloGallerySlideSample sample) {
    return [model tickAtTime:now sample:sample];
}

static ApolloGallerySlideshowAdvance const None = ApolloGallerySlideshowAdvanceNone;
static ApolloGallerySlideshowAdvance const Photo = ApolloGallerySlideshowAdvancePhotoTimer;
static ApolloGallerySlideshowAdvance const Loop = ApolloGallerySlideshowAdvanceAnimationLoop;
static ApolloGallerySlideshowAdvance const Ended = ApolloGallerySlideshowAdvancePlaybackEnded;
static ApolloGallerySlideshowAdvance const Failed = ApolloGallerySlideshowAdvanceMediaFailed;
static ApolloGallerySlideshowAdvance const Stalled = ApolloGallerySlideshowAdvanceStalled;

static void TestDurationSettings(void) {
    Check([ApolloGallerySlideshowPhotoDurationChoices() isEqualToArray:@[@2, @3, @5, @8, @10, @15, @20, @30]],
          @"duration choices");
    Check(ApolloGallerySlideshowSanitizedPhotoSeconds(10) == 10, @"a listed choice is kept");
    Check(ApolloGallerySlideshowSanitizedPhotoSeconds(7) == 5 && ApolloGallerySlideshowSanitizedPhotoSeconds(0) == 5 &&
          ApolloGallerySlideshowSanitizedPhotoSeconds(-3) == 5, @"anything else falls back to 5");
    Check([ApolloGallerySlideshowPhotoDurationTitle(5) isEqualToString:@"5 seconds"], @"title copy");
    Check([ApolloGallerySlideshowAdvanceName(Photo) isEqualToString:@"photo timer"] &&
          [ApolloGallerySlideshowAdvanceName(Stalled) isEqualToString:@"stalled"], @"advance names for logs");
}

static void TestPhotoAdvancesAfterDurationOnceFullImageShown(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPhoto, 5, 0);
    ApolloGallerySlideSample shown = S();
    shown.fullImageShown = YES;
    Check(T(model, 0, S()) == None, @"photo: thumbnail only, stays");
    Check(T(model, 1, shown) == None, @"photo: full image arrives, timer starts");
    Check(T(model, 5.75, shown) == None, @"photo: not yet five seconds of the full image");
    Check(T(model, 6, shown) == Photo, @"photo: five seconds of the full image");
    Check(T(model, 6.25, shown) == Photo, @"photo: advance reason repeats until the next slide begins");
}

static void TestPhotoTimerStartsAfterReadyTimeout(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPhoto, 5, 0);
    Check(T(model, 9.75, S()) == None, @"photo: still waiting for the full image");
    Check(T(model, 10, S()) == None, @"photo: readiness timeout starts the timer on the thumbnail");
    Check(T(model, 14.75, S()) == None, @"photo: thumbnail timer running");
    Check(T(model, 15, S()) == Photo, @"photo: thumbnail shown for the photo duration");
}

static void TestPhotoFailureShowsForPhotoDuration(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPhoto, 5, 0);
    ApolloGallerySlideSample failed = S();
    failed.mediaFailed = YES;
    Check(T(model, 2, failed) == None, @"photo: failure starts the timer");
    Check(T(model, 6.75, failed) == None, @"photo: failed media still on screen");
    Check(T(model, 7, failed) == Failed, @"photo: failed media advances after the photo duration");
}

static void TestHoldRestartsPhotoDuration(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPhoto, 5, 0);
    ApolloGallerySlideSample shown = S();
    shown.fullImageShown = YES;
    ApolloGallerySlideSample held = shown;
    held.held = YES;
    Check(T(model, 0, shown) == None, @"hold: timer starts");
    Check(T(model, 4, held) == None, @"hold: held");
    Check(T(model, 8, held) == None, @"hold: still held past the duration");
    Check(T(model, 8.25, shown) == None, @"hold: released, full duration again");
    Check(T(model, 13, shown) == None, @"hold: not yet five seconds since the release");
    Check(T(model, 13.25, shown) == Photo, @"hold: five seconds since the release");
}

static void TestNothingAdvancesWhileHeld(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPhoto, 5, 0);
    ApolloGallerySlideSample shown = S();
    shown.fullImageShown = YES;
    ApolloGallerySlideSample held = shown;
    held.held = YES;
    Check(T(model, 0, shown) == None, @"held: timer starts");
    Check(T(model, 20, held) == None, @"held: never advances while held");
    Check(T(model, 40, held) == None, @"held: still never advances");
}

static void TestAnimationAdvancesAfterOneFullLoop(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindAnimation, 5, 0);
    ApolloGallerySlideSample anim = S();
    anim.fullImageShown = YES;
    anim.animationShown = YES;
    Check(T(model, 0, anim) == None, @"gif: animating from the first frame");
    Check(T(model, 1, anim) == None, @"gif: mid-loop");
    anim.animationLoops = 1;
    Check(T(model, 2, anim) == Loop, @"gif: one full loop played");
}

static void TestAnimationAfterHoldNeedsLoopThatStartsAfterIt(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindAnimation, 5, 0);
    ApolloGallerySlideSample anim = S();
    anim.fullImageShown = YES;
    anim.animationShown = YES;
    ApolloGallerySlideSample held = anim;
    held.held = YES;
    Check(T(model, 0, anim) == None, @"gif hold: animating");
    Check(T(model, 1, held) == None, @"gif hold: held mid-loop");
    Check(T(model, 1.25, anim) == None, @"gif hold: released mid-loop");
    anim.animationLoops = 1;
    Check(T(model, 2, anim) == None, @"gif hold: the loop that was interrupted doesn't count");
    anim.animationLoops = 2;
    Check(T(model, 4, anim) == Loop, @"gif hold: a full loop after the hold");
}

static void TestVeryShortAnimationJumpByTwoAdvances(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindAnimation, 5, 0);
    ApolloGallerySlideSample anim = S();
    anim.fullImageShown = YES;
    anim.animationShown = YES;
    ApolloGallerySlideSample held = anim;
    held.held = YES;
    held.animationLoops = 3;
    Check(T(model, 0, anim) == None, @"short gif: animating");
    Check(T(model, 0.25, held) == None, @"short gif: held while it loops");
    anim.animationLoops = 3;
    Check(T(model, 0.5, anim) == None, @"short gif: released");
    anim.animationLoops = 5;
    Check(T(model, 0.75, anim) == Loop, @"short gif: two loops in one tick include a full one after the hold");
}

static void TestAnimationResetToFirstFrameCountsFresh(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindAnimation, 5, 0);
    ApolloGallerySlideSample anim = S();
    anim.fullImageShown = YES;
    anim.animationShown = YES;
    ApolloGallerySlideSample held = anim;
    held.held = YES;
    Check(T(model, 0, anim) == None, @"gif reset: animating");
    Check(T(model, 1, held) == None, @"gif reset: held");
    anim.animationLoops = 3;
    Check(T(model, 1.25, anim) == None, @"gif reset: released mid-loop");
    anim.animationLoops = 0;
    Check(T(model, 1.5, anim) == None, @"gif reset: animation re-set from the first frame");
    anim.animationLoops = 1;
    Check(T(model, 2.5, anim) == Loop, @"gif reset: one full loop from the first frame");
}

static void TestAnimationNotShownAtHoldEndStartsClean(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindAnimation, 5, 0);
    ApolloGallerySlideSample held = S();
    held.held = YES;
    Check(T(model, 0, S()) == None, @"gif loading: nothing yet");
    Check(T(model, 1, held) == None, @"gif loading: held");
    Check(T(model, 1.25, S()) == None, @"gif loading: released, still loading");
    ApolloGallerySlideSample anim = S();
    anim.fullImageShown = YES;
    anim.animationShown = YES;
    Check(T(model, 2, anim) == None, @"gif loading: animation starts after the hold");
    anim.animationLoops = 1;
    Check(T(model, 3, anim) == Loop, @"gif loading: its first loop counts");
}

static void TestAnimationNeverAnimatingFallsBackToPhoto(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindAnimation, 5, 0);
    ApolloGallerySlideSample still = S();
    still.fullImageShown = YES;
    Check(T(model, 1, still) == None, @"gif as still: full image without animation");
    Check(model.kind == ApolloGallerySlideKindPhoto, @"gif as still: timed as a photo");
    Check(T(model, 5.75, still) == None, @"gif as still: photo timer running");
    Check(T(model, 6, still) == Photo, @"gif as still: photo duration");
}

static void TestAnimationReadyTimeoutFallsBackToPhoto(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindAnimation, 5, 0);
    Check(T(model, 10, S()) == None, @"gif timeout: nothing after ten seconds");
    Check(model.kind == ApolloGallerySlideKindPhoto, @"gif timeout: timed as a photo");
    Check(T(model, 15, S()) == Photo, @"gif timeout: photo duration on the thumbnail");
}

static void TestPlayableAdvancesWhenPlaybackEnds(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPlayable, 5, 0);
    ApolloGallerySlideSample video = S();
    for (int second = 0; second <= 2; second++) {
        video.playbackPosition = second;
        Check(T(model, second, video) == None, @"video: playing");
    }
    video.playbackEnded = YES;
    Check(T(model, 3, video) == Ended, @"video: advances at its end");
}

static void TestPlayableEndedDuringHoldAdvancesAfterHold(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPlayable, 5, 0);
    ApolloGallerySlideSample playing = S();
    playing.playbackPosition = 8;
    ApolloGallerySlideSample ended = S();
    ended.playbackPosition = 9;
    ended.playbackEnded = YES;
    ApolloGallerySlideSample held = ended;
    held.held = YES;
    Check(T(model, 0, playing) == None, @"video hold: playing");
    Check(T(model, 1, held) == None, @"video hold: ended while held");
    Check(T(model, 1.25, ended) == Ended, @"video hold: advances once the hold ends");
}

// Swiping back to a clip that already finished: its end belongs to the last
// time it played, so it must play again rather than skip straight on.
static void TestPlayableEndFromBeforeTheSlideDoesNotCount(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPlayable, 5, 0);
    ApolloGallerySlideSample stale = S();
    stale.playbackPosition = 9;
    stale.playbackEnded = YES;
    Check(T(model, 0, stale) == None, @"stale end: a clip still at its old end doesn't finish the slide");
    ApolloGallerySlideSample replaying = S();
    replaying.playbackPosition = 0;
    Check(T(model, 0.25, replaying) == None, @"stale end: rewound and playing");
    replaying.playbackPosition = 4;
    Check(T(model, 4, replaying) == None, @"stale end: still playing");
    ApolloGallerySlideSample ended = S();
    ended.playbackPosition = 9;
    ended.playbackEnded = YES;
    Check(T(model, 9, ended) == Ended, @"stale end: the new end finishes the slide");
}

static void TestPlayableStallSkipsAfterTenSeconds(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPlayable, 5, 0);
    ApolloGallerySlideSample video = S();
    video.playbackPosition = 3.0;
    for (NSTimeInterval t = 0; t < 9.875; t += 0.25) {
        Check(T(model, t, video) == None, @"stall: not moving, under ten seconds");
    }
    Check(T(model, 10, video) == Stalled, @"stall: ten seconds without progress");
}

static void TestPlayableProgressResetsStall(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPlayable, 5, 0);
    ApolloGallerySlideSample video = S();
    video.playbackPosition = 1.0;
    for (NSTimeInterval t = 0; t < 4.875; t += 0.25) {
        Check(T(model, t, video) == None, @"progress: first position");
    }
    video.playbackPosition = 2.0;
    for (NSTimeInterval t = 5; t < 14.875; t += 0.25) {
        Check(T(model, t, video) == None, @"progress: moved at five seconds, no stall yet");
    }
    Check(T(model, 15, video) == Stalled, @"progress: ten seconds after the last movement");
}

static void TestPlayableWithoutPlayerStalls(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPlayable, 5, 0);
    Check(T(model, 9.75, S()) == None, @"no player: waiting");
    Check(T(model, 10, S()) == Stalled, @"no player: skipped after ten seconds");
}

static void TestUserPausedVideoIsAHoldNotAStall(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPlayable, 5, 0);
    ApolloGallerySlideSample video = S();
    video.playbackPosition = 3.0;
    ApolloGallerySlideSample paused = video;
    paused.held = YES;
    Check(T(model, 0, video) == None, @"user pause: playing");
    for (NSTimeInterval t = 1; t <= 60; t += 1) {
        Check(T(model, t, paused) == None, @"user pause: paused for a minute");
    }
    Check(T(model, 60.25, video) == None, @"user pause: resumed");
    Check(T(model, 70, video) == None, @"user pause: stall clock restarted at resume");
    Check(T(model, 70.25, video) == Stalled, @"user pause: ten seconds after resume without progress");
}

static void TestPlayableLookupFailureShowsPosterForPhotoDuration(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPlayable, 5, 0);
    ApolloGallerySlideSample failed = S();
    failed.mediaFailed = YES;
    Check(T(model, 1, failed) == None, @"lookup failure: poster shown");
    Check(T(model, 5.75, failed) == None, @"lookup failure: poster still up");
    Check(T(model, 6, failed) == Failed, @"lookup failure: poster for the photo duration");
}

static void TestBeginSlideResetsState(void) {
    ApolloGallerySlideshow *model = Begin(ApolloGallerySlideKindPhoto, 5, 0);
    ApolloGallerySlideSample shown = S();
    shown.fullImageShown = YES;
    Check(T(model, 0, shown) == None, @"reset: first slide timer starts");
    Check(T(model, 6, shown) == Photo, @"reset: first slide done");
    [model beginSlideOfKind:ApolloGallerySlideKindPhoto photoSeconds:5 atTime:6];
    Check(T(model, 6.25, shown) == None, @"reset: the next slide starts its own timer");
}

int main(void) {
    @autoreleasepool {
        TestDurationSettings();
        TestPhotoAdvancesAfterDurationOnceFullImageShown();
        TestPhotoTimerStartsAfterReadyTimeout();
        TestPhotoFailureShowsForPhotoDuration();
        TestHoldRestartsPhotoDuration();
        TestNothingAdvancesWhileHeld();
        TestAnimationAdvancesAfterOneFullLoop();
        TestAnimationAfterHoldNeedsLoopThatStartsAfterIt();
        TestVeryShortAnimationJumpByTwoAdvances();
        TestAnimationResetToFirstFrameCountsFresh();
        TestAnimationNotShownAtHoldEndStartsClean();
        TestAnimationNeverAnimatingFallsBackToPhoto();
        TestAnimationReadyTimeoutFallsBackToPhoto();
        TestPlayableAdvancesWhenPlaybackEnds();
        TestPlayableEndedDuringHoldAdvancesAfterHold();
        TestPlayableEndFromBeforeTheSlideDoesNotCount();
        TestPlayableStallSkipsAfterTenSeconds();
        TestPlayableProgressResetsStall();
        TestPlayableWithoutPlayerStalls();
        TestUserPausedVideoIsAHoldNotAStall();
        TestPlayableLookupFailureShowsPosterForPhotoDuration();
        TestBeginSlideResetsState();
        printf("gallery_slideshow_tests: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
