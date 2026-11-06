// ApolloGallerySlideshow.h
//
// Timing model for the Gallery View slideshow. A slide is done when a photo's
// full image has been up for the photo duration, a GIF has played one whole
// loop, or a clip has played to its end. Nothing advances while held, and a
// release restarts the timing. No timers or UIKit: the viewer ticks it, so the
// rules are testable on the host (tests/run_gallery_slideshow_tests.sh).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static NSTimeInterval const ApolloGallerySlideshowTickInterval = 0.25;
static NSTimeInterval const ApolloGallerySlideshowCrossfadeDuration = 0.35;
static NSTimeInterval const ApolloGallerySlideshowReadyTimeout = 10.0;
static NSTimeInterval const ApolloGallerySlideshowStallTimeout = 10.0;
static NSInteger const ApolloGallerySlideshowDefaultPhotoSeconds = 5;

typedef NS_ENUM(NSInteger, ApolloGallerySlideKind) {
    ApolloGallerySlideKindPhoto = 0,
    ApolloGallerySlideKindAnimation,   // animated .gif through FLAnimatedImageView
    ApolloGallerySlideKindPlayable,    // AVPlayer: video, mp4 GIF, hosted video
};

typedef NS_ENUM(NSInteger, ApolloGallerySlideshowAdvance) {
    ApolloGallerySlideshowAdvanceNone = 0,
    ApolloGallerySlideshowAdvancePhotoTimer,
    ApolloGallerySlideshowAdvanceAnimationLoop,
    ApolloGallerySlideshowAdvancePlaybackEnded,
    ApolloGallerySlideshowAdvanceMediaFailed,
    ApolloGallerySlideshowAdvanceStalled,
};

typedef struct {
    BOOL held;                  // the user is interacting, or the app is inactive
    BOOL fullImageShown;        // the full-size picture (not the thumbnail) is on the page
    BOOL animationShown;        // an FLAnimatedImage is on the page
    NSUInteger animationLoops;  // loops completed since that animation was last (re)set
    BOOL mediaFailed;           // photo/GIF: full image failed; playable: hosted lookup found nothing
    BOOL playbackEnded;         // playable reached its end
    double playbackPosition;    // seconds; NAN when the page has no player
} ApolloGallerySlideSample;

NSArray<NSNumber *> *ApolloGallerySlideshowPhotoDurationChoices(void);
// `stored` if it is one of the choices, else the default.
NSInteger ApolloGallerySlideshowSanitizedPhotoSeconds(NSInteger stored);
NSString *ApolloGallerySlideshowPhotoDurationTitle(NSInteger seconds);
NSString *ApolloGallerySlideshowAdvanceName(ApolloGallerySlideshowAdvance reason);

@interface ApolloGallerySlideshow : NSObject

// An Animation that never animates is timed as a Photo.
@property (nonatomic, readonly) ApolloGallerySlideKind kind;

- (void)beginSlideOfKind:(ApolloGallerySlideKind)kind
            photoSeconds:(NSTimeInterval)photoSeconds
                  atTime:(NSTimeInterval)now;

// None to stay, otherwise why the slide is done (repeated until the next begin).
- (ApolloGallerySlideshowAdvance)tickAtTime:(NSTimeInterval)now sample:(ApolloGallerySlideSample)sample;

@end

NS_ASSUME_NONNULL_END
