#import <Foundation/Foundation.h>

// Little chiptune stings for Pal Home's moments, synthesised (no assets): a
// pulse-wave lead, a triangle bass and a noise snare, NES style. Rendered to
// mono float samples; ApolloPalHomeAmbience plays them over the room sound.
// Foundation only (host-renderable).

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, APJingle) {
    APJingleMovingDay = 0, // ~2.6s: a bouncy "we're home!" fanfare
    APJingleUnpack,        // a pop and a rising run
    APJingleYum,           // two happy blips
    APJingleHeart,         // a sparkly arpeggio
    APJingleAdopt,         // a short welcome tune
};

// Mono samples at `sampleRate`, `*frames` long. Caller frees.
FOUNDATION_EXTERN float *_Nullable APJingleRender(APJingle jingle, double sampleRate, NSUInteger *frames);

NS_ASSUME_NONNULL_END
