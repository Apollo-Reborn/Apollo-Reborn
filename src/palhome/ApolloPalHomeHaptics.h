#import <Foundation/Foundation.h>

// Pal Home's haptic vocabulary. Every interaction names what happened and
// this decides how it feels, so the whole room has one consistent "touch".
// Uses UIFeedbackGenerator (which follows the system haptics setting), plus a
// Core Haptics purr for petting on hardware that supports it. Main thread.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, APHaptic) {
    APHapticTap = 0,   // any pixel button
    APHapticSelect,    // picking something in a list, snapping a drag
    APHapticToggle,    // lamps, fires, curtains, switches
    APHapticPlace,     // furniture set down
    APHapticRemove,    // furniture put away
    APHapticHop,       // the Pal hops onto something
    APHapticThump,     // a moving box landing
    APHapticPop,       // unpacking, a style landing
    APHapticPurr,      // petting: a soft rumble
    APHapticNom,       // eating: three little bites
    APHapticHeart,     // a heart earned
    APHapticSuccess,   // adoption, moving-in day done
    APHapticNope,      // can't do that (no food, full, can't place)
};

FOUNDATION_EXTERN void APHapticPlay(APHaptic haptic);

NS_ASSUME_NONNULL_END
