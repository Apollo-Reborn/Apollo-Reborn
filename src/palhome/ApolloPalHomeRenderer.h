#import <Foundation/Foundation.h>
#import "ApolloPalHomeCatalog.h"

// Turns a saved room document into lit pixel art: validates placements,
// renders the shell (wallpaper/floor), bakes a dithered lightmap from every
// lamp/fire/window, and lights each item's bitmap. Foundation/CoreGraphics
// only, so tests/run_pal_home_render.sh can render rooms to PNG on a Mac.

NS_ASSUME_NONNULL_BEGIN

// One item in the room, resolved against the catalogue.
@interface APPlacedItem : NSObject
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, strong) APItemSpec *spec;
@property (nonatomic) int x, y, variant;
@property (nonatomic) BOOL flip, on;
// Art-space placement in the room shell (top-left of the bitmap).
@property (nonatomic, readonly) int px, py;
@property (nonatomic, readonly) double z;
// Rendered art (valid after -[APRoomLayout renderAtMinute:]).
@property (nonatomic, strong, nullable) APDrawContext *art;
@property (nonatomic, strong, nullable) APCanvasBox *lit;      // base × light, flipped as placed
@property (nonatomic, strong, nullable) APCanvasBox *glowing;  // emissive (unlit), flipped as placed
@property (nonatomic, strong, nullable) APCanvasBox *litFront; // front × light
// Item-local → shell coordinates, honouring flip.
- (int)shellXForLocalX:(int)x;
- (int)shellYForLocalY:(int)y;
// The record as stored in the room document.
- (NSDictionary *)record;
+ (void)placementForSpec:(APItemSpec *)spec x:(int)x y:(int)y px:(int *)px py:(int *)py;
@end

typedef NS_ENUM(NSInteger, APLighting) { APLightingAuto = 0, APLightingDay, APLightingEvening, APLightingNight, APLightingCandle, APLightingOvercast };

@interface APRoomLayout : NSObject
+ (instancetype)layoutWithRoom:(NSDictionary *)room;
@property (nonatomic, strong, readonly) APSurfaceSpec *wallpaper;
@property (nonatomic, strong, readonly) APSurfaceSpec *floor;
@property (nonatomic, strong, readonly) APStyleSpec *style;
@property (nonatomic, readonly) APLighting lighting;
@property (nonatomic, copy, readonly) NSArray<APPlacedItem *> *items; // valid, non-overlapping, z-sorted
@property (nonatomic, copy, readonly) NSArray<NSDictionary *> *unknownRecords; // preserved, not shown

// Placement rules: footprint in bounds, back-wall pieces against the wall,
// no overlap within a layer (rugs may sit under furniture).
- (BOOL)canPlace:(APItemSpec *)spec x:(int)x y:(int)y ignoringUID:(nullable NSString *)uid;
- (BOOL)findSpotForSpec:(APItemSpec *)spec x:(int *)x y:(int *)y;
- (BOOL)isWalkableTileX:(int)x y:(int)y;
- (nullable APPlacedItem *)itemWithUID:(NSString *)uid;
- (NSArray<APPlacedItem *> *)petBeds;

// Rendering.
- (void)renderAtMinute:(int)minuteOfDay;
@property (nonatomic, readonly, nullable) APCanvasBox *litShell;
// Multiplicative light at a shell pixel (for tinting the Pal).
- (void)lightAtX:(int)x y:(int)y r:(float *)r g:(float *)g b:(float *)b;
// Everything static, composed (first fire frame etc.). For previews/tests.
- (APCanvasBox *)snapshot;
// Serialise back to a room document, keeping unknown records.
- (NSArray<NSDictionary *> *)itemRecords;
@end

APCanvas *APRenderShell(APSurfaceSpec *wallpaper, APSurfaceSpec *floor, APStyleSpec *_Nullable style);
// `intensity` 1 = hearth, 0 = small stove window. Frames loop.
NSArray<APCanvasBox *> *APFireFrames(int w, int h, int count, float intensity, uint32_t seed);
// Dithered radial bloom for additive blending.
APCanvas *APGlowCanvas(int radius, uint32_t rgb);
// Warm dark surroundings the room floats in.
APCanvas *APBackdropCanvas(int w, int h, APStyleSpec *_Nullable style);
// A miniature of a style's template room for the drawer.
APCanvas *APStyleThumbnail(APStyleSpec *style);
// The same little painting of any room document.
APCanvas *APRoomThumbnail(NSDictionary *room);
// Drawer thumbnails: fully lit item / a surface swatch.
APCanvas *APItemThumbnail(APItemSpec *spec, int variant);
APCanvas *APSurfaceThumbnail(APSurfaceSpec *spec, BOOL isFloor, int size);
// A heart/ball/Z etc. used by interactions.
APCanvas *APIconCanvas(NSString *name);

NS_ASSUME_NONNULL_END
