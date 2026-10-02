#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// A tiny RGBA pixel-art painter. Everything in Pal Home is drawn with this at
// true art resolution (one unit = one art pixel) and shown with nearest-
// neighbour scaling, so the room reads as hand-placed pixels rather than
// smoothed vectors. Foundation/CoreGraphics only: the host-side harness
// (tests/run_pal_home_render.sh) renders the same art to PNG on a Mac.
//
// Coordinates are top-left origin, y down, like an image editor. Colours are
// 0xRRGGBB (always opaque); translucency goes through the explicit alpha APIs.

NS_ASSUME_NONNULL_BEGIN

typedef struct APCanvas {
    int w, h;
    uint32_t *px; // 0xAARRGGBB, straight (non-premultiplied) alpha
} APCanvas;

APCanvas *APCanvasCreate(int w, int h);
void APCanvasFree(APCanvas *_Nullable c);
APCanvas *APCanvasCopy(const APCanvas *c);

// Opaque writes (clipped).
void APPx(APCanvas *c, int x, int y, uint32_t rgb);
void APRect(APCanvas *c, int x, int y, int w, int h, uint32_t rgb);
void APHLine(APCanvas *c, int x, int y, int w, uint32_t rgb);
void APVLine(APCanvas *c, int x, int y, int h, uint32_t rgb);
void APLine(APCanvas *c, int x0, int y0, int x1, int y1, uint32_t rgb);
void APRectOutline(APCanvas *c, int x, int y, int w, int h, uint32_t rgb);
// A rectangle with its four corner pixels knocked out (the pixel-art "rounded" box).
void APRoundRect(APCanvas *c, int x, int y, int w, int h, uint32_t rgb);
void APEllipse(APCanvas *c, int x, int y, int w, int h, uint32_t rgb);
void APEllipseOutline(APCanvas *c, int x, int y, int w, int h, uint32_t rgb);
void APCircle(APCanvas *c, int cx, int cy, int r, uint32_t rgb);

// Translucent writes (source-over).
void APBlendPx(APCanvas *c, int x, int y, uint32_t rgb, float alpha);
void APBlendRect(APCanvas *c, int x, int y, int w, int h, uint32_t rgb, float alpha);

// Ordered-dither fills: `amount` 0…1 of the pixels (Bayer 4×4) get `rgb`.
// This is how shading and gradients stay crisp at pixel scale.
void APDitherRect(APCanvas *c, int x, int y, int w, int h, uint32_t rgb, float amount);
float APBayer(int x, int y); // 0…1 threshold

uint32_t APGet(const APCanvas *c, int x, int y);
BOOL APCanvasIsEmpty(const APCanvas *c); // no visible pixels at all // 0xAARRGGBB, 0 outside
BOOL APOpaqueAt(const APCanvas *c, int x, int y);

// Composite `src` onto `dst` at (x, y), optionally mirrored horizontally.
void APDraw(APCanvas *dst, const APCanvas *src, int x, int y, BOOL flip);
// Only where dst is already opaque (for painting inside a shape).
// Replace every opaque pixel's colour with rgb (for silhouettes/outlines).
void APTint(APCanvas *c, uint32_t rgb);
// Recolour opaque pixels that touch transparency (4-neighbour) — the inner
// silhouette outline pixel artists hand-draw around sprites.
void APOutlineInside(APCanvas *c, uint32_t rgb);
// Drop shadow ellipse under furniture (translucent warm black).
void APShadow(APCanvas *c, int x, int y, int w, int h);
// A 1px outline around the opaque pixels of `src`, as a new canvas 2px larger.
APCanvas *APCanvasOutline(const APCanvas *src, uint32_t rgb);

// Colour helpers.
uint32_t APMix(uint32_t a, uint32_t b, float t);
uint32_t APShade(uint32_t rgb, float factor); // multiply brightness
uint32_t APMultiply(uint32_t rgb, float r, float g, float b);

// Pixel font: 5-row caps with proportional widths, plus a 7-row display face.
// Non-ASCII characters are rasterised from the system font with anti-aliasing
// off, so names in any script still read as pixels.
typedef NS_ENUM(NSInteger, APFont) {
    APFontSmall = 0, // 5px tall, used for labels
    APFontLarge = 1, // 7px tall, used for the name sign
};
int APTextWidth(NSString *text, APFont font);
int APTextHeight(APFont font);
void APText(APCanvas *c, NSString *text, int x, int y, APFont font, uint32_t rgb);
// Greedy word wrap to `maxWidth` pixels.
NSArray<NSString *> *APTextWrap(NSString *text, APFont font, int maxWidth);
// Draws with a 1px drop shadow below/right.
void APTextShadow(APCanvas *c, NSString *text, int x, int y, APFont font, uint32_t rgb, uint32_t shadow);

// Tiny deterministic PRNG so generated art is identical every launch.
typedef struct { uint32_t s; } APRand;
uint32_t APRandNext(APRand *r);
float APRandFloat(APRand *r);           // 0…1
int APRandInt(APRand *r, int lo, int hi); // inclusive

CGImageRef APCanvasCreateCGImage(const APCanvas *c) CF_RETURNS_RETAINED;
// Reads any CGImage (or a sub-rect of it) into a new canvas.
APCanvas *APCanvasCreateFromCGImage(CGImageRef image, CGRect rect);

// Owns a canvas for Objective-C collections/caches; frees it on dealloc.
@interface APCanvasBox : NSObject
@property (nonatomic, readonly) APCanvas *canvas;
+ (instancetype)boxWithCanvas:(APCanvas *)canvas; // takes ownership
@end

NS_ASSUME_NONNULL_END
