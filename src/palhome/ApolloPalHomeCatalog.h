#import <Foundation/Foundation.h>
#import "ApolloPixelCanvas.h"

// Pal Home's furniture/wallpaper/flooring catalogue. Every item is original
// procedural pixel art drawn at runtime by the blocks registered here (no
// bundled images), so new pieces are a few dozen lines each and variants are
// just palette swaps. Foundation/CoreGraphics only (host-renderable).

NS_ASSUME_NONNULL_BEGIN

// Room geometry, in art pixels. The room is an Animal Crossing-style 3/4 view:
// a back wall of hanging slots above an 8 × 7 floor grid.
enum {
    APTile = 16,
    APCols = 8,
    APRows = 7,
    APWallRows = 3,
    APSideWall = 6,                         // edge-on side walls
    APCeiling = 4,                          // beam above the back wall
    APCrown = 5,                            // crown moulding under the beam
    APBaseboard = 7,
    APWallHeight = APCrown + APWallRows * APTile + APBaseboard, // 60
    APFrontLip = 6,
    APShellWidth = APSideWall * 2 + APCols * APTile,           // 140
    APFloorTop = APCeiling + APWallHeight,                     // 64
    APShellHeight = APFloorTop + APRows * APTile + APFrontLip, // 182
};

typedef NS_ENUM(NSInteger, APLayer) {
    APLayerFloor = 0, // furniture standing on floor tiles
    APLayerRug,       // flat floor coverings; furniture may stand on them
    APLayerWall,      // hung in the back wall's 8 × 3 slots
    APLayerTrim,      // garlands along the top of the wall (x only)
};

typedef NS_ENUM(NSInteger, APCategory) {
    APCategoryStyles = 0,  // whole-room themes (not items)
    APCategoryFurniture,
    APCategoryCosy,      // lights, plants, small things, pet beds
    APCategoryRugs,
    APCategoryWall,
    APCategoryArt,
    APCategoryWallpaper,
    APCategoryFlooring,
    APCategoryCount,
};

typedef NS_ENUM(NSInteger, APAnimKind) {
    APAnimFire = 0,  // rect: flame box; `size` = intensity (0 small stove, 1 hearth)
    APAnimEmbers,    // rect: spawn line above a fire
    APAnimCandle,    // point: 1×2 flame tip
    APAnimTwinkle,   // point: fairy bulb, `color`
    APAnimSteam,     // point: mug/kettle steam source
    APAnimWindow,    // rect: glass; `variant` = weather (0 snow 1 stars 2 rain 3 clear)
    APAnimClockHands,// point: clock centre; `size` = hand length
    APAnimPendulum,  // point: pivot; `size` = length
    APAnimNeon,      // rect: whole emissive sign flickers occasionally
    APAnimNotes,     // point: music notes float up
    APAnimGlow,      // point: soft additive light bloom; `size` = radius, `color`; variant 1 = slow pulse
    APAnimBlink,     // point: indicator light blinking on/off, `color`
    APAnimBubbles,   // point: bubbles rising; `color` tints them (0 = water)
    APAnimFireflies, // rect: fireflies drifting inside
};

// Animation/light hooks an item declares while drawing, in item-local pixels
// (top-left origin). The scene turns these into sprites/actions; the static
// renderer just ignores the moving parts.
@interface APAnim : NSObject
@property (nonatomic) APAnimKind kind;
@property (nonatomic) int x, y, w, h;
@property (nonatomic) uint32_t color;
@property (nonatomic) int size;
@property (nonatomic) int variant;
+ (instancetype)kind:(APAnimKind)kind x:(int)x y:(int)y w:(int)w h:(int)h;
@end

@interface APLight : NSObject
@property (nonatomic) int x, y;         // item-local
@property (nonatomic) float radius;
@property (nonatomic) uint32_t color;
@property (nonatomic) float strength;
+ (instancetype)x:(int)x y:(int)y radius:(float)radius color:(uint32_t)color strength:(float)strength;
@end

// Everything a draw block may paint into / declare.
@interface APDrawContext : NSObject
@property (nonatomic, readonly) APCanvas *base;     // lit by the room's lightmap
@property (nonatomic, readonly) APCanvas *emissive; // glows; not darkened
@property (nonatomic, readonly) APCanvas *front;    // lit, drawn above animations (e.g. logs over fire)
@property (nonatomic, readonly) int width, height;
@property (nonatomic, readonly) int variant;
@property (nonatomic, readonly) BOOL on;            // toggleable items (lamps, fires)
@property (nonatomic, readonly) int hour, minute;   // local time, for windows/clocks
@property (nonatomic, readonly) NSMutableArray<APAnim *> *anims;
@property (nonatomic, readonly) NSMutableArray<APLight *> *lights;
- (void)addAnim:(APAnim *)anim;
- (void)addLight:(APLight *)light;
@end

typedef void (^APDrawBlock)(APDrawContext *ctx);

@interface APItemSpec : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) APLayer layer;
@property (nonatomic) APCategory category;
@property (nonatomic) int w, d;          // tiles/cells; for wall items d = rows tall
@property (nonatomic) int rise;          // floor items: art pixels above the footprint
@property (nonatomic) BOOL backWall;     // floor item must sit against the back wall (row 0)
@property (nonatomic) BOOL walkable;     // the Pal may walk over it
@property (nonatomic) BOOL petBed;       // the Pal naps here
@property (nonatomic) int sleepX, sleepY;// item-local feet position for napping
@property (nonatomic) BOOL toggleable;   // tap to switch on/off
@property (nonatomic) BOOL seat;         // the Pal hops up and sits here
@property (nonatomic) int seatX, seatY;  // item-local feet position when sitting
@property (nonatomic) int season;        // 1-12: only in the catalogue that month (0 = always)
@property (nonatomic, copy) NSArray<NSString *> *variants;
@property (nonatomic, copy, nullable) NSString *variantNoun; // the drawer's cycle button ("Song"); nil = "Colour"
@property (nonatomic, copy) APDrawBlock draw;
// Bitmap size for this item in art pixels.
@property (nonatomic, readonly) int pixelWidth, pixelHeight;
@end

// Wallpaper/flooring: `draw` fills ctx.base (wall or floor sized) as a pattern.
@interface APSurfaceSpec : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) uint32_t swatch;
@property (nonatomic, copy) void (^paint)(APCanvas *c, int x, int y, int w, int h);
@end

// A whole-home theme: shell trim, the world outside, ambient tint and a
// furnished starter layout. Applying a style replaces the room (undoable).
typedef NS_ENUM(NSInteger, APBackdropAnim) { APBackdropAnimNone = 0, APBackdropAnimStars, APBackdropAnimBubbles, APBackdropAnimFireflies, APBackdropAnimDust, APBackdropAnimBats };

@interface APStyleSpec : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) float tintR, tintG, tintB;  // multiplies ambient light
@property (nonatomic) APBackdropAnim backdropAnim;
@property (nonatomic) int season; // 1-12: only offered that month, first in the list (0 = always)
@property (nonatomic, copy, nullable) void (^paintShell)(APCanvas *c);              // repaints trim over the base shell
@property (nonatomic, copy, nullable) void (^paintBackdrop)(APCanvas *c, int w, int h);
@property (nonatomic, copy) NSDictionary *(^room)(void);                           // template room document
@end

@interface APCatalog : NSObject
+ (NSArray<APStyleSpec *> *)styles;
// For the drawer: this month's seasonal styles first, then the year-round
// ones (other months' seasonal styles aren't offered).
+ (NSArray<APStyleSpec *> *)stylesForDisplay;
+ (APStyleSpec *)styleWithID:(nullable NSString *)identifier; // falls back to cottage
+ (NSArray<APItemSpec *> *)items;
+ (nullable APItemSpec *)itemWithID:(NSString *)identifier;
+ (NSArray<APItemSpec *> *)itemsInCategory:(APCategory)category;
+ (NSArray<APSurfaceSpec *> *)wallpapers;
+ (NSArray<APSurfaceSpec *> *)floors;
+ (nullable APSurfaceSpec *)wallpaperWithID:(NSString *)identifier;
+ (nullable APSurfaceSpec *)floorWithID:(NSString *)identifier;
+ (NSString *)titleForCategory:(APCategory)category;
// The starter room new homes are furnished with.
+ (NSDictionary *)starterRoom;
@end

// Renders one item. Caller frees the returned canvases (APDrawContext owns
// them until then; use the helpers below).
APDrawContext *APRenderItem(APItemSpec *spec, int variant, BOOL on, int minuteOfDay);

// Shared ramps (outline, dark, mid, light, highlight) for palette variants.
typedef struct { uint32_t o, d, m, l, h; } APRamp;
APRamp APRampNamed(NSString *name);

// Internal registration (split across files by theme).
void APRegisterFurniture(NSMutableArray<APItemSpec *> *items);
void APRegisterWallItems(NSMutableArray<APItemSpec *> *items);
void APRegisterSurfaces(NSMutableArray<APSurfaceSpec *> *walls, NSMutableArray<APSurfaceSpec *> *floors);
void APRegisterThemedItems(NSMutableArray<APItemSpec *> *items);
void APRegisterThemedSurfaces(NSMutableArray<APSurfaceSpec *> *walls, NSMutableArray<APSurfaceSpec *> *floors);
void APRegisterStyles(NSMutableArray<APStyleSpec *> *styles);
// Halloween (ApolloPalHomeHalloween.m): the Haunted Manor and its pieces.
void APRegisterHalloweenItems(NSMutableArray<APItemSpec *> *items);
void APRegisterHalloweenSurfaces(NSMutableArray<APSurfaceSpec *> *walls, NSMutableArray<APSurfaceSpec *> *floors);
APStyleSpec *APHalloweenManorStyle(void);
// Shared pieces used by themed items.
void APPaintingShadowRect(APCanvas *c, int x, int y, int w, int h);
NSDictionary *APRoomItem(NSString *identifier, int x, int y, int variant);
// Shared drawing pieces.
void APCandle(APDrawContext *ctx, int x, int y, int height, uint32_t wax);
APItemSpec *APSpec(NSString *identifier, NSString *title, APLayer layer, APCategory category, int w, int d, int rise,
                   NSArray<NSString *> *variants, APDrawBlock draw);

NS_ASSUME_NONNULL_END
