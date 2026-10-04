#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Pixel Pal coat colours.
//
// Apollo's Pal sprites (Assets.car, `<species>-<action>`: alert, crouch, lie,
// lie-single, run, settings, sit, sleep, walk; 32×14 frames) each use a tiny
// hand-made palette: a #000000 outline, a few fur/feature colours, and the
// grey sleep "Z" (#828282/#808080). Some colours appear twice one step apart
// (e.g. #d68438/#d68538), so matching uses a small tolerance.
//
// A coat recolours by *role*: each species' palette is split into groups
// (fur, shade, stripes, belly…) and a coat gives a new base colour per group.
// Every colour in a group keeps its lightness/hue offset from the group's
// original base, so the hand-made shading survives. Outline, eyes and the Z
// are never in a group, so they never change.
//
// Foundation/CoreGraphics only (host-renderable for review).

NS_ASSUME_NONNULL_BEGIN

@interface APCoat : NSObject
@property (nonatomic, copy, readonly) NSString *identifier; // "original" = Apollo's own colours
@property (nonatomic, copy, readonly) NSString *title;
@end

@interface APPixelPalCoats : NSObject
+ (NSArray<APCoat *> *)coatsForSpecies:(NSString *)species;
// Recoloured copy (or NULL when the coat is original/unknown). Caller releases.
+ (nullable CGImageRef)createRecoloredImage:(CGImageRef)image species:(NSString *)species coat:(NSString *)coat CF_RETURNS_RETAINED;
// Parses "<species>-<action>" asset names; nil for anything else.
+ (nullable NSString *)speciesForAssetName:(NSString *)name;
// Coats that glow in the dark (the Glow axolotl): the light's colour, else 0.
+ (uint32_t)glowColourForSpecies:(NSString *)species coat:(nullable NSString *)coat;

// Persistence (standard defaults, so settings backups carry it).
+ (NSString *)selectedCoatForSpecies:(NSString *)species;
// The pre-shelter free-choice coat, if one was picked (nil otherwise).
+ (nullable NSString *)legacyCoatForSpecies:(NSString *)species;
@end

NS_ASSUME_NONNULL_END
