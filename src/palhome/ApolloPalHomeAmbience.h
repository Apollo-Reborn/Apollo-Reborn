#import <Foundation/Foundation.h>
#import "ApolloPalHomeChiptune.h"

@class APRoomLayout;

NS_ASSUME_NONNULL_BEGIN

// Procedural ambient sound for Pal Home: nothing is bundled, every layer is
// synthesised live (crackling fire, rain, wind, ticking clocks, a music-box
// lullaby, station hum, crickets, bubbles) and mixed from what's in the room.
// Mixes with other audio. On: the ambient category, quiet in Silent Mode.
// Always: the playback category, so it plays in Silent Mode too.
typedef NS_ENUM(NSInteger, APSoundMode) { APSoundOff = 0, APSoundOn, APSoundAlways };

@interface ApolloPalHomeAmbience : NSObject
@property (class, nonatomic) APSoundMode mode; // persisted, default On
@property (class, nonatomic, readonly, getter=isEnabled) BOOL enabled; // mode != Off
- (void)updateForLayout:(APRoomLayout *)layout minuteOfDay:(int)minute;
- (void)start;
- (void)stop;
// A chiptune sting over the room sound (only while sound is on and running).
- (void)playJingle:(APJingle)jingle;
@end

NS_ASSUME_NONNULL_END
