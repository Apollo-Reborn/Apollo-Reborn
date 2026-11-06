// ApolloGallerySlideshow.m — see ApolloGallerySlideshow.h.

#import "ApolloGallerySlideshow.h"

#import <math.h>

NSArray<NSNumber *> *ApolloGallerySlideshowPhotoDurationChoices(void) {
    return @[@2, @3, @5, @8, @10, @15, @20, @30];
}

NSInteger ApolloGallerySlideshowSanitizedPhotoSeconds(NSInteger stored) {
    return [ApolloGallerySlideshowPhotoDurationChoices() containsObject:@(stored)]
        ? stored : ApolloGallerySlideshowDefaultPhotoSeconds;
}

NSString *ApolloGallerySlideshowPhotoDurationTitle(NSInteger seconds) {
    return [NSString stringWithFormat:@"%ld seconds", (long)seconds];
}

NSString *ApolloGallerySlideshowAdvanceName(ApolloGallerySlideshowAdvance reason) {
    switch (reason) {
        case ApolloGallerySlideshowAdvancePhotoTimer: return @"photo timer";
        case ApolloGallerySlideshowAdvanceAnimationLoop: return @"animation loop";
        case ApolloGallerySlideshowAdvancePlaybackEnded: return @"playback ended";
        case ApolloGallerySlideshowAdvanceMediaFailed: return @"media failed";
        case ApolloGallerySlideshowAdvanceStalled: return @"stalled";
        case ApolloGallerySlideshowAdvanceNone: break;
    }
    return @"none";
}

@interface ApolloGallerySlideshow ()
@property (nonatomic, readwrite) ApolloGallerySlideKind kind;
@property (nonatomic) NSTimeInterval photoSeconds;
@property (nonatomic) NSTimeInterval slideStart;
// The previous tick was held; the next unheld one restarts the clocks.
@property (nonatomic) BOOL heldOnLastTick;

// Photo: when timing began. NAN until something is showing.
@property (nonatomic) NSTimeInterval showingSince;
@property (nonatomic) BOOL showingBecauseFailed;

// Animation: loops already counted. Only a loop that began unheld can finish the slide.
@property (nonatomic) NSUInteger loopsSeen;
@property (nonatomic) BOOL loopClean;

// Playable: an end only counts after seeing the clip run, because a page
// swiped back to can still be parked on its previous end.
@property (nonatomic) BOOL playbackSeenRunning;
@property (nonatomic) NSTimeInterval failedSince;
@property (nonatomic) double lastPosition;
@property (nonatomic) NSTimeInterval lastProgressAt;
@end

@implementation ApolloGallerySlideshow

- (void)beginSlideOfKind:(ApolloGallerySlideKind)kind
            photoSeconds:(NSTimeInterval)photoSeconds
                  atTime:(NSTimeInterval)now {
    self.kind = kind;
    self.photoSeconds = photoSeconds;
    self.slideStart = now;
    self.heldOnLastTick = NO;
    self.showingSince = NAN;
    self.showingBecauseFailed = NO;
    // The viewer rewinds the GIF, so the next loop is a whole one.
    self.loopsSeen = 0;
    self.loopClean = YES;
    self.playbackSeenRunning = NO;
    self.failedSince = NAN;
    self.lastPosition = NAN;
    self.lastProgressAt = now;
}

- (ApolloGallerySlideshowAdvance)tickAtTime:(NSTimeInterval)now sample:(ApolloGallerySlideSample)sample {
    if (sample.held) {
        self.heldOnLastTick = YES;
        return ApolloGallerySlideshowAdvanceNone;
    }
    if (self.heldOnLastTick) {
        // Released: the timing starts over.
        self.heldOnLastTick = NO;
        if (!isnan(self.showingSince)) self.showingSince = now;
        if (!isnan(self.failedSince)) self.failedSince = now;
        self.lastProgressAt = now;
        // A loop already in progress began during the hold, so it can't count.
        self.loopsSeen = sample.animationLoops;
        self.loopClean = !sample.animationShown;
    }

    switch (self.kind) {
        case ApolloGallerySlideKindPhoto:
            return [self apollo_photoTickAtTime:now sample:sample];
        case ApolloGallerySlideKindAnimation:
            return [self apollo_animationTickAtTime:now sample:sample];
        case ApolloGallerySlideKindPlayable:
            return [self apollo_playableTickAtTime:now sample:sample];
    }
    return ApolloGallerySlideshowAdvanceNone;
}

- (ApolloGallerySlideshowAdvance)apollo_photoTickAtTime:(NSTimeInterval)now sample:(ApolloGallerySlideSample)sample {
    if (isnan(self.showingSince)) {
        if (sample.fullImageShown || sample.mediaFailed ||
            now - self.slideStart >= ApolloGallerySlideshowReadyTimeout) {
            self.showingSince = now;
            self.showingBecauseFailed = sample.mediaFailed && !sample.fullImageShown;
        } else {
            return ApolloGallerySlideshowAdvanceNone;
        }
    }
    if (now - self.showingSince < self.photoSeconds) return ApolloGallerySlideshowAdvanceNone;
    return self.showingBecauseFailed ? ApolloGallerySlideshowAdvanceMediaFailed
                                     : ApolloGallerySlideshowAdvancePhotoTimer;
}

- (ApolloGallerySlideshowAdvance)apollo_animationTickAtTime:(NSTimeInterval)now sample:(ApolloGallerySlideSample)sample {
    if (!sample.animationShown) {
        // A still, a failure or a timeout: time it as a photo from here on.
        if (sample.fullImageShown || sample.mediaFailed ||
            now - self.slideStart >= ApolloGallerySlideshowReadyTimeout) {
            self.kind = ApolloGallerySlideKindPhoto;
            return [self apollo_photoTickAtTime:now sample:sample];
        }
        return ApolloGallerySlideshowAdvanceNone;
    }

    NSUInteger loops = sample.animationLoops;
    if (loops < self.loopsSeen) {
        // The animation was reset to its first frame.
        self.loopsSeen = loops;
        self.loopClean = YES;
    }
    if (loops > self.loopsSeen) {
        // Two completions in one tick include a whole loop after the hold.
        if (self.loopClean || loops - self.loopsSeen >= 2) return ApolloGallerySlideshowAdvanceAnimationLoop;
        self.loopsSeen = loops;
        self.loopClean = YES;
    }
    return ApolloGallerySlideshowAdvanceNone;
}

- (ApolloGallerySlideshowAdvance)apollo_playableTickAtTime:(NSTimeInterval)now sample:(ApolloGallerySlideSample)sample {
    if (!sample.playbackEnded) {
        self.playbackSeenRunning = YES;
    } else if (self.playbackSeenRunning) {
        return ApolloGallerySlideshowAdvancePlaybackEnded;
    }

    if (sample.mediaFailed) {
        if (isnan(self.failedSince)) self.failedSince = now;
        return now - self.failedSince >= self.photoSeconds ? ApolloGallerySlideshowAdvanceMediaFailed
                                                           : ApolloGallerySlideshowAdvanceNone;
    }

    double position = sample.playbackPosition;
    if (isfinite(position) && (isnan(self.lastPosition) || fabs(position - self.lastPosition) > 0.01)) {
        self.lastPosition = position;
        self.lastProgressAt = now;
    }
    return now - self.lastProgressAt >= ApolloGallerySlideshowStallTimeout ? ApolloGallerySlideshowAdvanceStalled
                                                                         : ApolloGallerySlideshowAdvanceNone;
}

@end
