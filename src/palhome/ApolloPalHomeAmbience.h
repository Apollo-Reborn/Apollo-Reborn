#import <Foundation/Foundation.h>
#import "ApolloPalHomeChiptune.h"

@class APRoomLayout;

NS_ASSUME_NONNULL_BEGIN

// Procedural ambient sound for Pal Home: nothing is bundled, every layer is
// synthesised live (crackling fire, rain, wind, ticking clocks, a music-box
// lullaby, station hum, crickets, bubbles) and mixed from what's in the room.
// Uses the ambient audio category: mixes with other audio and respects the
// silent switch.
@interface ApolloPalHomeAmbience : NSObject
@property (class, nonatomic, getter=isEnabled) BOOL enabled; // persisted, default on
- (void)updateForLayout:(APRoomLayout *)layout minuteOfDay:(int)minute;
- (void)start;
- (void)stop;
// A chiptune sting over the room sound (only while sound is on and running).
- (void)playJingle:(APJingle)jingle;
@end

NS_ASSUME_NONNULL_END
