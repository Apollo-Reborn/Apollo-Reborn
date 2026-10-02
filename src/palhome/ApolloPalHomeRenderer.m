#import "ApolloPalHomeRenderer.h"
#import <math.h>

#pragma mark - Placement

@interface APPlacedItem ()
@property (nonatomic, readwrite) int px, py;
@property (nonatomic, readwrite) double z;
@property (nonatomic, copy) NSDictionary *sourceRecord;
@end

@implementation APPlacedItem

+ (void)placementForSpec:(APItemSpec *)spec x:(int)x y:(int)y px:(int *)px py:(int *)py {
    switch (spec.layer) {
        case APLayerWall:
            *px = APSideWall + x * APTile;
            *py = APCeiling + APCrown + y * APTile;
            break;
        case APLayerTrim:
            *px = APSideWall + x * APTile;
            *py = APCeiling;
            break;
        default:
            *px = APSideWall + x * APTile;
            *py = APFloorTop + (y + spec.d) * APTile - spec.pixelHeight;
            break;
    }
}

- (void)resolve {
    int px, py;
    [APPlacedItem placementForSpec:self.spec x:self.x y:self.y px:&px py:&py];
    self.px = px;
    self.py = py;
    switch (self.spec.layer) {
        case APLayerWall: self.z = 20 + self.y * 0.1 + self.x * 0.001; break;
        case APLayerTrim: self.z = 30 + self.x * 0.001; break;
        case APLayerRug: self.z = 40 + self.y * 0.1 + self.x * 0.001; break;
        // Floor furniture sorts by its front edge so nearer pieces overlap
        // farther ones (and the Pal, whose z is its feet).
        default:
            // Walkable pieces (beds, bowls) sort by their back edge so a Pal
            // standing on them is drawn on top.
            self.z = self.spec.walkable ? 100 + self.y * APTile + 1 + self.x * 0.001
                                        : 100 + (self.y + self.spec.d) * APTile - 0.5 + self.x * 0.001;
            break;
    }
}

- (int)shellXForLocalX:(int)x { return self.px + (self.flip ? self.spec.pixelWidth - 1 - x : x); }
- (int)shellYForLocalY:(int)y { return self.py + y; }

- (NSDictionary *)record {
    NSMutableDictionary *record = [self.sourceRecord mutableCopy] ?: [NSMutableDictionary dictionary];
    record[@"uid"] = self.uid;
    record[@"item"] = self.spec.identifier;
    record[@"x"] = @(self.x);
    record[@"y"] = @(self.y);
    record[@"variant"] = @(self.variant);
    record[@"flip"] = @(self.flip);
    record[@"off"] = @(!self.on);
    return record;
}
@end

#pragma mark - Layout

@interface APRoomLayout ()
@property (nonatomic, strong, readwrite) APSurfaceSpec *wallpaper;
@property (nonatomic, strong, readwrite) APSurfaceSpec *floor;
@property (nonatomic, strong, readwrite) APStyleSpec *style;
@property (nonatomic, readwrite) APLighting lighting;
@property (nonatomic, copy, readwrite) NSArray<APPlacedItem *> *items;
@property (nonatomic, copy, readwrite) NSArray<NSDictionary *> *unknownRecords;
@property (nonatomic, strong, readwrite) APCanvasBox *litShell;
@property (nonatomic) float *lightmap;
@end

static int APIntValue(id value, int fallback) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) ? [value intValue] : fallback;
}

@implementation APRoomLayout

- (void)dealloc { free(_lightmap); }

+ (instancetype)layoutWithRoom:(NSDictionary *)room {
    APRoomLayout *layout = [self new];
    layout.wallpaper = [APCatalog wallpaperWithID:room[@"wallpaper"]] ?: [APCatalog wallpaperWithID:@"wp.rosebud"];
    layout.floor = [APCatalog floorWithID:room[@"floor"]] ?: [APCatalog floorWithID:@"fl.oak"];
    layout.style = [APCatalog styleWithID:room[@"style"]];
    NSDictionary *lighting = @{@"auto": @(APLightingAuto), @"day": @(APLightingDay), @"evening": @(APLightingEvening), @"night": @(APLightingNight),
                               @"candle": @(APLightingCandle), @"overcast": @(APLightingOvercast)};
    layout.lighting = [lighting[room[@"lighting"]] integerValue];
    NSMutableArray *placed = [NSMutableArray array], *unknown = [NSMutableArray array];
    NSArray *records = [room[@"items"] isKindOfClass:NSArray.class] ? room[@"items"] : @[];
    layout.items = @[];
    NSMutableSet *uids = [NSMutableSet set];
    for (id record in records) {
        if (![record isKindOfClass:NSDictionary.class]) continue;
        APItemSpec *spec = [APCatalog itemWithID:record[@"item"]];
        NSString *uid = [record[@"uid"] isKindOfClass:NSString.class] ? record[@"uid"] : NSUUID.UUID.UUIDString;
        if (!spec) { [unknown addObject:record]; continue; } // a newer build's furniture
        if ([uids containsObject:uid]) uid = NSUUID.UUID.UUIDString;
        APPlacedItem *item = [APPlacedItem new];
        item.uid = uid;
        item.spec = spec;
        item.x = APIntValue(record[@"x"], -1);
        item.y = APIntValue(record[@"y"], -1);
        item.variant = MAX(0, MIN(APIntValue(record[@"variant"], 0), (int)spec.variants.count - 1));
        item.flip = [record[@"flip"] isKindOfClass:NSNumber.class] && [record[@"flip"] boolValue];
        item.on = !([record[@"off"] isKindOfClass:NSNumber.class] && [record[@"off"] boolValue]);
        item.sourceRecord = record;
        // Invalid or overlapping placements are dropped from display (the
        // first wins); an edit then saves the cleaned-up room.
        if (![layout canPlace:spec x:item.x y:item.y ignoringUID:nil]) continue;
        [item resolve];
        [uids addObject:uid];
        [placed addObject:item];
        layout.items = [self sorted:placed];
    }
    layout.items = [self sorted:placed];
    layout.unknownRecords = unknown;
    return layout;
}

+ (NSArray *)sorted:(NSArray<APPlacedItem *> *)items {
    return [items sortedArrayUsingComparator:^NSComparisonResult(APPlacedItem *a, APPlacedItem *b) {
        return a.z < b.z ? NSOrderedAscending : a.z > b.z ? NSOrderedDescending : NSOrderedSame;
    }];
}

- (APPlacedItem *)itemWithUID:(NSString *)uid {
    for (APPlacedItem *item in self.items) if ([item.uid isEqual:uid]) return item;
    return nil;
}

static BOOL APSameGroup(APLayer a, APLayer b) {
    if (a == APLayerFloor || b == APLayerFloor) return a == b;
    return a == b;
}

- (BOOL)canPlace:(APItemSpec *)spec x:(int)x y:(int)y ignoringUID:(NSString *)uid {
    int cols = APCols, rows = spec.layer == APLayerWall ? APWallRows : spec.layer == APLayerTrim ? 1 : APRows;
    int depth = spec.layer == APLayerTrim ? 1 : spec.d;
    if (x < 0 || y < 0 || x + spec.w > cols || y + depth > rows) return NO;
    if (spec.backWall && y != 0) return NO;
    for (APPlacedItem *other in self.items) {
        if (uid && [other.uid isEqual:uid]) continue;
        if (!APSameGroup(spec.layer, other.spec.layer)) continue;
        int od = other.spec.layer == APLayerTrim ? 1 : other.spec.d;
        if (x < other.x + other.spec.w && other.x < x + spec.w && y < other.y + od && other.y < y + depth) return NO;
    }
    return YES;
}

- (BOOL)findSpotForSpec:(APItemSpec *)spec x:(int *)outX y:(int *)outY {
    // Prefer the middle of the room, working outward, like dropping it in front of you.
    int rows = spec.layer == APLayerWall ? APWallRows : spec.layer == APLayerTrim ? 1 : APRows;
    NSMutableArray *candidates = [NSMutableArray array];
    for (int y = 0; y < rows; y++) for (int x = 0; x < APCols; x++) [candidates addObject:@[@(x), @(y)]];
    float cx = (APCols - spec.w) / 2.0f, cy = spec.layer == APLayerFloor || spec.layer == APLayerRug ? 3 : 0;
    [candidates sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        float da = fabsf([a[0] intValue] - cx) + fabsf([a[1] intValue] - cy) * 1.2f;
        float db = fabsf([b[0] intValue] - cx) + fabsf([b[1] intValue] - cy) * 1.2f;
        return da < db ? NSOrderedAscending : da > db ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSArray *c in candidates) {
        if ([self canPlace:spec x:[c[0] intValue] y:[c[1] intValue] ignoringUID:nil]) {
            *outX = [c[0] intValue];
            *outY = [c[1] intValue];
            return YES;
        }
    }
    return NO;
}

- (BOOL)isWalkableTileX:(int)x y:(int)y {
    if (x < 0 || y < 0 || x >= APCols || y >= APRows) return NO;
    for (APPlacedItem *item in self.items) {
        if (item.spec.layer != APLayerFloor || item.spec.walkable) continue;
        if (x >= item.x && x < item.x + item.spec.w && y >= item.y && y < item.y + item.spec.d) return NO;
    }
    return YES;
}

- (NSArray<APPlacedItem *> *)petBeds {
    NSMutableArray *beds = [NSMutableArray array];
    for (APPlacedItem *item in self.items) if (item.spec.petBed) [beds addObject:item];
    return beds;
}

- (NSArray<NSDictionary *> *)itemRecords {
    NSMutableArray *records = [NSMutableArray array];
    for (APPlacedItem *item in self.items) [records addObject:item.record];
    [records addObjectsFromArray:self.unknownRecords];
    return records;
}

#pragma mark Lighting

static void APAmbient(APLighting lighting, int hour, float *r, float *g, float *b) {
    if (lighting == APLightingAuto) {
        lighting = hour >= 8 && hour < 17 ? APLightingDay : ((hour >= 17 && hour < 21) || (hour >= 6 && hour < 8)) ? APLightingEvening : APLightingNight;
    }
    switch (lighting) {
        case APLightingDay: *r = 0.92f; *g = 0.9f; *b = 0.86f; break;
        case APLightingEvening: *r = 0.56f; *g = 0.47f; *b = 0.5f; break;
        case APLightingCandle: *r = 0.24f; *g = 0.2f; *b = 0.26f; break;      // let every flame glow
        case APLightingOvercast: *r = 0.62f; *g = 0.66f; *b = 0.74f; break;   // a grey, rainy afternoon
        default: *r = 0.38f; *g = 0.37f; *b = 0.5f; break;
    }
}

- (void)renderAtMinute:(int)minuteOfDay {
    int hour = (minuteOfDay / 60) % 24;
    for (APPlacedItem *item in self.items) item.art = APRenderItem(item.spec, item.variant, item.on, minuteOfDay);
    // Accumulate light in shell space.
    int W = APShellWidth, H = APShellHeight;
    free(self.lightmap);
    self.lightmap = calloc((size_t)W * H * 3, sizeof(float));
    float ar, ag, ab;
    APAmbient(self.lighting, hour, &ar, &ag, &ab);
    ar *= self.style.tintR; ag *= self.style.tintG; ab *= self.style.tintB;
    for (int i = 0; i < W * H; i++) { self.lightmap[i * 3] = ar; self.lightmap[i * 3 + 1] = ag; self.lightmap[i * 3 + 2] = ab; }
    for (APPlacedItem *item in self.items) {
        for (APLight *light in item.art.lights) {
            int lx = [item shellXForLocalX:light.x], ly = [item shellYForLocalY:light.y];
            float cr = ((light.color >> 16) & 255) / 255.0f, cg = ((light.color >> 8) & 255) / 255.0f, cb = (light.color & 255) / 255.0f;
            int rad = (int)ceilf(light.radius);
            for (int y = MAX(0, ly - rad); y < MIN(H, ly + rad); y++) for (int x = MAX(0, lx - rad); x < MIN(W, lx + rad); x++) {
                float dx = x - lx, dy = (y - ly) * 1.15f;
                float d = sqrtf(dx * dx + dy * dy) / light.radius;
                if (d >= 1) continue;
                float f = (1 - d) * (1 - d) * light.strength;
                float *p = &self.lightmap[(y * W + x) * 3];
                p[0] += cr * f; p[1] += cg * f; p[2] += cb * f;
            }
        }
    }
    // Daylight (or moonlight) through each window pools on the floor beneath
    // it, slanting with the time of day.
    BOOL day = hour >= 8 && hour < 17, dusk = (hour >= 17 && hour < 20) || (hour >= 6 && hour < 8);
    APLighting mode = self.lighting;
    if (mode == APLightingDay) { day = YES; dusk = NO; }
    else if (mode == APLightingEvening) { day = NO; dusk = YES; }
    else if (mode == APLightingNight || mode == APLightingCandle) { day = NO; dusk = NO; }
    float poolStrength = mode == APLightingOvercast ? 0.12f : day ? 0.34f : dusk ? 0.26f : 0.13f;
    float pr = day ? 1.0f : dusk ? 1.0f : 0.55f, pg = day ? 0.96f : dusk ? 0.66f : 0.62f, pb = day ? 0.84f : dusk ? 0.42f : 0.95f;
    float slant = (hour >= 12 ? -0.45f : 0.45f) * (day || dusk ? 1 : 0.4f);
    for (APPlacedItem *item in self.items) {
        if (item.spec.layer != APLayerWall) continue;
        for (APAnim *anim in item.art.anims) {
            if (anim.kind != APAnimWindow || anim.variant == 4) continue; // no sun in deep space
            int gx0 = [item shellXForLocalX:item.flip ? anim.x + anim.w - 1 : anim.x], gw = anim.w;
            int poolH = 30 + gw / 2;
            for (int dy = 0; dy < poolH; dy++) {
                float fade = 1 - dy / (float)poolH;
                int y = APFloorTop + dy;
                int x0 = gx0 + (int)lroundf(dy * slant) - 1, x1 = x0 + gw + 2 + dy / 6;
                for (int x = MAX(APSideWall, x0); x < MIN(W - APSideWall, x1); x++) {
                    float edge = MIN(x - x0, x1 - 1 - x) < 2 ? 0.5f : 1.0f;
                    float f = poolStrength * fade * edge;
                    float *p = &self.lightmap[(y * W + x) * 3];
                    p[0] += pr * f; p[1] += pg * f; p[2] += pb * f;
                }
            }
        }
    }
    // A gentle vignette pulls the eye into the room.
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        float dx = (x - W / 2.0f) / (W / 2.0f), dy = (y - H * 0.55f) / (H * 0.6f);
        float v = 1 - 0.16f * fminf(1, fmaxf(0, dx * dx + dy * dy - 0.35f));
        float *p = &self.lightmap[(y * W + x) * 3];
        p[0] *= v; p[1] *= v; p[2] *= v;
    }
    // Quantise to a few dithered bands: pixel-art lighting, not a smooth gradient.
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        float *p = &self.lightmap[(y * W + x) * 3];
        float t = APBayer(x, y);
        for (int k = 0; k < 3; k++) p[k] = fminf(1.12f, floorf(p[k] * 7 + t) / 7);
    }
    APCanvas *shell = APRenderShell(self.wallpaper, self.floor, self.style);
    [self applyLightTo:shell ox:0 oy:0];
    self.litShell = [APCanvasBox boxWithCanvas:shell];
    for (APPlacedItem *item in self.items) {
        int w = item.spec.pixelWidth, h = item.spec.pixelHeight;
        APCanvas *lit = APCanvasCreate(w, h), *front = APCanvasCreate(w, h);
        APDraw(lit, item.art.base, 0, 0, item.flip);
        APDraw(front, item.art.front, 0, 0, item.flip);
        [self applyLightTo:lit ox:item.px oy:item.py];
        [self applyLightTo:front ox:item.px oy:item.py];
        APCanvas *glowing = APCanvasCreate(w, h);
        APDraw(glowing, item.art.emissive, 0, 0, item.flip);
        item.lit = [APCanvasBox boxWithCanvas:lit];
        item.glowing = [APCanvasBox boxWithCanvas:glowing];
        item.litFront = [APCanvasBox boxWithCanvas:front];
    }
}

- (void)applyLightTo:(APCanvas *)c ox:(int)ox oy:(int)oy {
    for (int y = 0; y < c->h; y++) for (int x = 0; x < c->w; x++) {
        uint32_t p = c->px[y * c->w + x];
        if (!(p >> 24)) continue;
        float r, g, b;
        [self lightAtX:ox + x y:oy + y r:&r g:&g b:&b];
        c->px[y * c->w + x] = (p & 0xFF000000u) | APMultiply(p, r, g, b);
    }
}

- (void)lightAtX:(int)x y:(int)y r:(float *)r g:(float *)g b:(float *)b {
    x = MAX(0, MIN(x, APShellWidth - 1));
    y = MAX(0, MIN(y, APShellHeight - 1));
    if (!self.lightmap) { *r = *g = *b = 1; return; }
    float *p = &self.lightmap[(y * APShellWidth + x) * 3];
    *r = p[0]; *g = p[1]; *b = p[2];
}

- (APCanvasBox *)snapshot {
    APCanvas *out = APCanvasCopy(self.litShell.canvas);
    for (APPlacedItem *item in self.items) {
        APDraw(out, item.lit.canvas, item.px, item.py, NO);
        APDraw(out, item.glowing.canvas, item.px, item.py, NO);
        for (APAnim *anim in item.art.anims) {
            if (anim.kind != APAnimFire) continue;
            APCanvasBox *frame = APFireFrames(anim.w, anim.h, 1, anim.w > 10 ? 1 : 0, 7).firstObject;
            APDraw(out, frame.canvas, [item shellXForLocalX:item.flip ? anim.x + anim.w - 1 : anim.x], item.py + anim.y, NO);
        }
        APDraw(out, item.litFront.canvas, item.px, item.py, NO);
    }
    return [APCanvasBox boxWithCanvas:out];
}

@end

#pragma mark - Shell

APCanvas *APRenderShell(APSurfaceSpec *wallpaper, APSurfaceSpec *floor, APStyleSpec *style) {
    int W = APShellWidth, H = APShellHeight;
    APCanvas *c = APCanvasCreate(W, H);
    int wallTop = APCeiling + APCrown, wallH = APWallRows * APTile;
    // Wallpaper and floor patterns are painted on scratch canvases so any
    // pattern bleed is clipped to their own rect.
    APCanvas *paper = APCanvasCreate(W - APSideWall * 2, wallH + APCrown);
    wallpaper.paint(paper, 0, 0, paper->w, paper->h);
    APDraw(c, paper, APSideWall, wallTop - 2, NO);
    APCanvasFree(paper);
    APCanvas *boards = APCanvasCreate(W - APSideWall * 2, APRows * APTile);
    floor.paint(boards, 0, 0, boards->w, boards->h);
    APDraw(c, boards, APSideWall, APFloorTop, NO);
    APCanvasFree(boards);
    // Ceiling beam and crown moulding.
    APRect(c, 0, 0, W, APCeiling, 0x2E1C12);
    APHLine(c, 0, APCeiling - 1, W, 0x4A3020);
    APRect(c, APSideWall, APCeiling, W - APSideWall * 2, 2, 0xE8D8BC);
    APHLine(c, APSideWall, APCeiling + 2, W - APSideWall * 2, 0xC8B494);
    APDitherRect(c, APSideWall, APCeiling + 3, W - APSideWall * 2, 2, 0x000000, 0.25f);
    // The top of the wall falls into soft shadow under the moulding.
    for (int y = 0; y < 6; y++) APDitherRect(c, APSideWall, wallTop + 1 + y, W - APSideWall * 2, 1, 0x000000, 0.22f - y * 0.035f);
    // Baseboard.
    int base = APFloorTop - APBaseboard;
    APRect(c, APSideWall, base, W - APSideWall * 2, APBaseboard, 0x6A4228);
    APHLine(c, APSideWall, base, W - APSideWall * 2, 0xC8966A);
    APHLine(c, APSideWall, base + 1, W - APSideWall * 2, 0xA8744A);
    APHLine(c, APSideWall, base + APBaseboard - 1, W - APSideWall * 2, 0x3A2414);
    // Contact shadow where wall meets floor and along the side walls.
    for (int y = 0; y < 4; y++) APDitherRect(c, APSideWall, APFloorTop + y, W - APSideWall * 2, 1, 0x24140C, 0.6f - y * 0.15f);
    for (int x = 0; x < 3; x++) {
        APDitherRect(c, APSideWall + x, APCeiling, 1, H - APCeiling - APFrontLip, 0x24140C, 0.5f - x * 0.15f);
        APDitherRect(c, W - APSideWall - 1 - x, APCeiling, 1, H - APCeiling - APFrontLip, 0x24140C, 0.5f - x * 0.15f);
    }
    // Side walls seen edge-on, and the front wall's cap.
    uint32_t cap = 0x3A2A22, capLight = 0x5A4234, capDark = 0x221812;
    APRect(c, 0, 0, APSideWall, H, cap);
    APRect(c, W - APSideWall, 0, APSideWall, H, cap);
    APVLine(c, APSideWall - 1, 0, H, capLight);
    APVLine(c, W - APSideWall, 0, H, capLight);
    APVLine(c, 0, 0, H, capDark);
    APVLine(c, W - 1, 0, H, capDark);
    APRect(c, 0, H - APFrontLip, W, APFrontLip, cap);
    APHLine(c, 0, H - APFrontLip, W, capLight);
    APHLine(c, 0, H - 1, W, capDark);
    if (style.paintShell) style.paintShell(c);
    return c;
}

#pragma mark - Fire

NSArray<APCanvasBox *> *APFireFrames(int w, int h, int count, float intensity, uint32_t seed) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%d:%d:%d:%.2f:%u", w, h, count, intensity, seed];
    NSArray *hit = [cache objectForKey:key];
    if (hit) return hit;
    // Classic "doom fire": heat spreads upward with random decay and sideways
    // drift. Deterministic seed, warmed up, sampled as a loop of frames.
    int maxHeat = intensity > 0.5f ? 18 : 7;
    int gh = h + 2;
    uint8_t *heat = calloc((size_t)w * gh, 1);
    __block APRand r = {seed ?: 1};
    void (^step)(void) = ^{
        for (int x = 0; x < w; x++) {
            int edge = MIN(x, w - 1 - x);
            int base = maxHeat - (edge < 2 ? (2 - edge) * 4 : 0) - APRandInt(&r, 0, 3);
            heat[(gh - 1) * w + x] = (uint8_t)MAX(0, base);
        }
        for (int y = 1; y < gh; y++) for (int x = 0; x < w; x++) {
            int src = y * w + x;
            int v = heat[src];
            int rnd = APRandInt(&r, 0, 3);
            int dst = src - (rnd - 1);
            int above = dst - w;
            if (above < 0 || above >= w * gh) continue;
            // Extra cooling toward the sides and at random so the fire breaks
            // into separate tapering tongues instead of a solid block.
            float side = fabsf(x - (w - 1) / 2.0f) / (w / 2.0f);
            int cool = (rnd & 1) + (APRandInt(&r, 0, 2) == 0) + (APRandFloat(&r) < side * side * 1.4f);
            heat[above] = (uint8_t)MAX(0, v - cool);
        }
    };
    for (int i = 0; i < 40; i++) step();
    static const uint32_t palette[] = {0, 0x5A160C, 0x8A2410, 0xB43216, 0xD2461A, 0xE85E1E, 0xF27A26, 0xF8962E, 0xFBB23A, 0xFCCA4C, 0xFDE07A, 0xFEF0B0, 0xFFFBE0};
    NSMutableArray *frames = [NSMutableArray array];
    for (int f = 0; f < count; f++) {
        step(); step();
        APCanvas *c = APCanvasCreate(w, h);
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
            int v = heat[(y + 2) * w + x];
            if (v <= 0) continue;
            int idx = (int)lroundf(v * 12.0f / maxHeat + 0.4f);
            idx = MAX(1, MIN(idx, 12));
            if (idx <= 1 && APBayer(x, y + f) < 0.5f) continue; // ragged smoky tips
            APPx(c, x, y, palette[idx]);
        }
        [frames addObject:[APCanvasBox boxWithCanvas:c]];
    }
    free(heat);
    [cache setObject:frames forKey:key];
    return frames;
}

APCanvas *APGlowCanvas(int radius, uint32_t rgb) {
    int size = radius * 2 + 1;
    APCanvas *c = APCanvasCreate(size, size);
    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++) {
        float d = hypotf(x - radius, (y - radius) * 1.1f) / radius;
        if (d >= 1) continue;
        float a = (1 - d) * (1 - d);
        // Three dithered alpha steps keep the bloom pixel-y.
        float level = floorf(a * 4 + APBayer(x, y)) / 4;
        if (level <= 0) continue;
        c->px[y * size + x] = ((uint32_t)(level * 200) << 24) | (rgb & 0xFFFFFF);
    }
    return c;
}

#pragma mark - Sign, backdrop, thumbnails, icons

APCanvas *APBackdropCanvas(int w, int h, APStyleSpec *style) {
    APCanvas *c = APCanvasCreate(w, h);
    if (style.paintBackdrop) {
        style.paintBackdrop(c, w, h);
        return c;
    }
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float t = fabsf(y - h * 0.45f) / (h * 0.55f);
        uint32_t col = APBayer(x, y) < t * 0.8f ? 0x120C0A : 0x1C1310;
        APPx(c, x, y, col);
    }
    // A faint warm pattern so the void reads as a cosy dark, not a hole.
    for (int y = 4; y < h; y += 12) for (int x = (y / 12 % 2) * 6; x < w; x += 12) APPx(c, x, y, 0x2A1C16);
    return c;
}

APCanvas *APStyleThumbnail(APStyleSpec *style) { return APRoomThumbnail(style.room()); }

APCanvas *APRoomThumbnail(NSDictionary *room) {
    // Render the room at evening light, then shrink 4× by taking each
    // block's most common colour: a little painting of the room, not a blur.
    APRoomLayout *layout = [APRoomLayout layoutWithRoom:room];
    [layout renderAtMinute:19 * 60];
    APCanvasBox *snap = [layout snapshot];
    APCanvas *src = snap.canvas;
    int f = 4, w = src->w / f, h = src->h / f;
    APCanvas *out = APCanvasCreate(w, h);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        uint32_t colours[16];
        int counts[16], n = 0;
        for (int dy = 0; dy < f; dy++) for (int dx = 0; dx < f; dx++) {
            uint32_t p = APGet(src, x * f + dx, y * f + dy);
            if (!(p >> 24)) continue;
            int k = 0;
            for (; k < n; k++) if (colours[k] == p) break;
            if (k == n) { colours[n] = p; counts[n++] = 0; }
            counts[k] += (dx == 1 || dx == 2) && (dy == 1 || dy == 2) ? 2 : 1; // favour the centre
        }
        int best = -1;
        for (int k = 0; k < n; k++) if (best < 0 || counts[k] > counts[best]) best = k;
        if (best >= 0) APPx(out, x, y, colours[best]);
    }
    return out;
}

APCanvas *APItemThumbnail(APItemSpec *spec, int variant) {
    APDrawContext *art = APRenderItem(spec, variant, YES, 20 * 60 + 30);
    APCanvas *c = APCanvasCreate(art.width, art.height);
    APDraw(c, art.base, 0, 0, NO);
    APDraw(c, art.emissive, 0, 0, NO);
    for (APAnim *anim in art.anims) {
        if (anim.kind != APAnimFire) continue;
        APCanvasBox *frame = APFireFrames(anim.w, anim.h, 1, anim.w > 10 ? 1 : 0, 7).firstObject;
        APDraw(c, frame.canvas, anim.x, anim.y, NO);
    }
    APDraw(c, art.front, 0, 0, NO);
    return c;
}

APCanvas *APSurfaceThumbnail(APSurfaceSpec *spec, BOOL isFloor, int size) {
    APCanvas *c = APCanvasCreate(size, size);
    APCanvas *pattern = APCanvasCreate(size - 2, size - 2);
    spec.paint(pattern, 0, 0, pattern->w, pattern->h);
    APDraw(c, pattern, 1, 1, NO);
    APCanvasFree(pattern);
    if (!isFloor) {
        APRect(c, 1, size - 5, size - 2, 4, 0x6A4228);
        APHLine(c, 1, size - 5, size - 2, 0xC8966A);
    }
    APRectOutline(c, 0, 0, size, size, 0x2A1A12);
    return c;
}

// Multi-colour icons as character art; each letter maps to a colour.
APCanvas *APIconCanvas(NSString *name) {
    static NSDictionary<NSString *, NSArray *> *icons;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *wood = @{@"o": @0x3A2414, @"a": @0xC8966A, @"b": @0xE8BE8A};
        icons = @{
            @"heart": @[@[@".ooo.ooo.", @"oabaoaaao", @"oabaaaaao", @"oaaaaaaao", @".oaaaaao.", @"..oaaao..", @"...oao...", @"....o...."],
                        @{@"o": @0x5A1A24, @"a": @0xF06A7A, @"b": @0xFFC0C8}],
            // A waving hand: saying goodbye.
            @"wave": @[@[@"..o.o.o...", @".oaoaoao..", @".oaoaoao.o", @".oaaaaaoao", @"oaaaaaaaao", @"oaaaaaaao.", @".oaaaaao..", @"..ooooo..."],
                       @{@"o": @0x5A3A2A, @"a": @0xF4CCA1}],
            // The Dynamic Island, with a tiny Pal on top.
            @"island": @[@[@"...oo....", @"..oaao...", @".ooooooo.", @"obbbbbbbo", @"obbbbbbbo", @".ooooooo."], @{@"o": @0x1A1A1E, @"a": @0xC08A5A, @"b": @0x3A3A44}],
            @"island.off": @[@[@".........", @".........", @".ooooooo.", @"obbbbbbbo", @"obbbbbbbo", @".ooooooo."], @{@"o": @0x1A1A1E, @"b": @0x3A3A44}],
            // An apple: Apollo's own Feed button uses one.
            @"food": @[@[@"....og...", @"....ogg..", @".oooooo..", @"oabaaaaao", @"oaaaaaaao", @"oaaaaaaao", @"oaaaaaaco", @".oaaaaco.", @"..ooooo.."],
                       @{@"o": @0x5A1414, @"a": @0xE04A3A, @"b": @0xFFB0A0, @"c": @0xA82A22, @"g": @0x5AA03A}],
            @"ball": @[@[@"..ooooo..", @".oaaabao.", @"oaaaabaao", @"oabbaabao", @"oaaabbaao", @"oaaaaabao", @"oaabaaaao", @".oaabaao.", @"..ooooo.."],
                       @{@"o": @0x6A2A3A, @"a": @0xE88AA8, @"b": @0xF8C8D8}],
            @"moon": @[@[@"..oooo...", @".oaaao...", @"oaabo....", @"oaao.....", @"oaao...o.", @"oaabo.oao", @".oaaaoaao", @"..oaaaao.", @"...oooo.."],
                       @{@"o": @0x5A4A1A, @"a": @0xF4D870, @"b": @0xFFF4C0}],
            @"brush": @[@[@"......oo.", @".....oabo", @"....oaao.", @"...oaao..", @"..occo...", @".occco...", @"occco....", @"occo.....", @"oo......."],
                        @{@"o": @0x3A2414, @"a": @0xC8966A, @"b": @0xE8BE8A, @"c": @0x6AA0C8}],
            @"paw": @[@[@"...oo.oo...", @"..oaaoaao..", @"..oaaoaao..", @"oo.oo.oo.oo", @"oaao...oaao", @"oaao...oaao", @".oo.ooo.oo.", @"...oaaao...", @"..oaaaaao..", @"..oaaaaao..", @"...ooooo..."],
                      @{@"o": @0x5A2A34, @"a": @0xF0A8B8}],
            @"back": @[@[@"...oo....", @"..oao....", @".oaaooooo", @"oaaaaaaao", @".oaaooooo", @"..oao....", @"...oo...."],
                       @{@"o": @0x3A2414, @"a": @0xF4E8D0}],
            @"check": @[@[@".......oo", @"......oao", @".....oao.", @"oo..oao..", @"oaooao...", @".oaaao...", @"..ooo...."],
                        @{@"o": @0x1E3A18, @"a": @0x8AD07A}],
            @"flip": @[@[@"..o.....o..", @".oa.....ao.", @"oaaaaaaaaao", @".oa.....ao.", @"..o.....o.."],
                       @{@"o": @0x3A2414, @"a": @0xF4E8D0}],
            @"palette": @[@[@"..oooooo..", @".oaaaaaao.", @"oarraabbao", @"oarraabbao", @"oaaaaaaaao", @"oayyaa.oo.", @"oayyao....", @".oaao.....", @"..oo......"],
                          @{@"o": @0x3A2414, @"a": @0xE8D0A8, @"r": @0xE05A5A, @"b": @0x5A8AE0, @"y": @0xF0C040}],
            @"box": @[@[@"ooooooooo", @"obbbbbbbo", @"ooooooooo", @".oaaaaao.", @".oaoooao.", @".oaaaaao.", @".oaaaaao.", @".ooooooo."], wood],
            @"sun": @[@[@"....o....", @".o..o..o.", @"..ooooo..", @"..oaaao..", @"oooabaooo", @"..oaaao..", @"..ooooo..", @".o..o..o.", @"....o...."],
                      @{@"o": @0x6A4A10, @"a": @0xF8D860, @"b": @0xFFF4C0}],
            @"bulb": @[@[@"..ooooo..", @".oaaaaao.", @"oaabaaaao", @"oaaaaaaao", @".oaaaaao.", @"..oaaao..", @"..ooooo..", @"..occco..", @"...ooo..."],
                       @{@"o": @0x5A4A1A, @"a": @0xF8E078, @"b": @0xFFF8D0, @"c": @0x9E9488}],
            @"sofa": @[@[@"..ooooooo..", @".oaaaaaaao.", @"oobbbbbbboo", @"oaobbbbboao", @"oaaaaaaaaao", @"ooooooooooo", @".o.......o."],
                       @{@"o": @0x4A2218, @"a": @0xA85432, @"b": @0xC87444}],
            @"candle": @[@[@"....f....", @"...fef...", @"...fef...", @"....o....", @"..ooooo..", @"..oaaao..", @"..oaaao..", @"..oaaao..", @".ooooooo."],
                         @{@"o": @0x5A4A3A, @"a": @0xF4E8D0, @"f": @0xF8A830, @"e": @0xFFF4C0}],
            @"rug": @[@[@"o.o.o.o.o.o", @"ooooooooooo", @"oaaabbbaaao", @"oabbacabbao", @"oaaabbbaaao", @"ooooooooooo", @"o.o.o.o.o.o"],
                      @{@"o": @0x2E3A5E, @"a": @0x9E2E30, @"b": @0xE0B058, @"c": @0xECE0C4}],
            @"window": @[@[@"ooooooooo", @"oaaaoaaao", @"oabaoaaao", @"ooooooooo", @"oaaaoaaao", @"oaaaoaaao", @"ooooooooo"],
                         @{@"o": @0x6A4228, @"a": @0x8CC4E8, @"b": @0xE0F0FA}],
            @"art": @[@[@"ooooooooooo", @"ogggggggggo", @"ogssssssygo", @"ogssssssssgo", @"ogssmssssgo", @"ogsmmmsssgo", @"ogmmmmmmsgo", @"ogggggggggo", @"ooooooooooo"],
                      @{@"o": @0x4A3410, @"g": @0xE8BE48, @"s": @0x8CC4E8, @"y": @0xFFE070, @"m": @0x5A8A4E}],
            @"wallpaper": @[@[@".ooooooo...", @"oaabaabao..", @"oaaaaaaao..", @"oabaabaao..", @"oaaaaaaao..", @"oaabaabaoo.", @"oaaaaaaaoao", @".ooooooooao", @".......ooo."],
                            @{@"o": @0x4A2230, @"a": @0xE0B0A4, @"b": @0xB0605A}],
            @"floor": @[@[@"ooooooooooo", @"oaaaoaaaaao", @"ooooooooooo", @"oaaaaaaoaao", @"ooooooooooo", @"oaoaaaaaaao", @"ooooooooooo"],
                        @{@"o": @0x4A2E1C, @"a": @0xC8966A}],
            @"house": @[@[@"....o....", @"...oao...", @"..oaaao..", @".oaaaaao.", @"ooooooooo", @".obbbbbo.", @".obbcbbo.", @".obbcbbo.", @".ooooooo."],
                        @{@"o": @0x3A2414, @"a": @0xC44A44, @"b": @0xE8D8B0, @"c": @0x8A5A36}],
            @"undo": @[@[@"..o......", @".oao.....", @"oaaaooo..", @".oao.aao.", @"..o...ao.", @".......ao", @"......ao.", @"...oooo.."],
                       @{@"o": @0x3A2414, @"a": @0xF4E8D0}],
            @"t.fish": @[@[@".aaa.a", @"aaaoaa", @".aaa.a"], @{@"a": @0x6AA8E0, @"o": @0x1A1A1E}],
            @"t.bone": @[@[@"o...o", @".ooo.", @"o...o"], @{@"o": @0xE8DCC0}],
            @"t.yuzu": @[@[@"..gl", @".aa.", @"abaa", @"aaac", @".cc."], @{@"a": @0xF2B320, @"b": @0xFFE07A, @"c": @0xD08A10, @"g": @0x5A9A3A, @"l": @0x7AC24A}],
            @"t.flame": @[@[@"..a..", @".aba.", @"abcba", @".aba."], @{@"a": @0xF27A22, @"b": @0xFBB23A, @"c": @0xFFF0B0}],
            @"t.snow": @[@[@"a.a.a", @".aaa.", @"aa.aa", @".aaa.", @"a.a.a"], @{@"a": @0x8AC8F0}],
            @"t.star": @[@[@"..a..", @"aaaaa", @".aaa.", @"a...a"], @{@"a": @0xF2C840}],
            @"t.sun": @[@[@"a.a.a", @".bbb.", @"abbba", @".bbb.", @"a.a.a"], @{@"a": @0xF2C840, @"b": @0xF8E070}],
            @"t.moon": @[@[@".aa.", @"aa..", @"aa..", @".aa."], @{@"a": @0xC8B850}],
            @"t.yarn": @[@[@".aaa.", @"abaab", @"aabaa", @".aaa."], @{@"a": @0xE88AA8, @"b": @0xF8C8D8}],
            @"t.heart": @[@[@"aa.aa", @"aaaaa", @".aaa.", @"..a.."], @{@"a": @0xF06A7A}],
            @"t.note": @[@[@".aa", @".a.", @"aa.", @"aa."], @{@"a": @0x7A6AB0}],
            @"camera": @[@[@"..ooo....", @"ooaaaoooo", @"oaaobboao", @"oaabccboo", @"oaabccbao", @"oaaobboao", @"ooooooooo"],
                         @{@"o": @0x2A2A30, @"a": @0x8A929E, @"b": @0x3A3A44, @"c": @0x8AC0E0}],
            @"pencil": @[@[@"......oo", @".....oao", @"....oaao", @"...oaao.", @"..oaao..", @".obao...", @"obbo....", @"ooo....."],
                         @{@"o": @0x3A2414, @"a": @0xF2C040, @"b": @0xE8A0A0}],
            @"shelter": @[@[@"....o....", @"...oao...", @"..oaaao..", @".oaaaaao.", @"ooooooooo", @".obhbhbo.", @".obhhhbo.", @".obbhbbo.", @".ooooooo."],
                          @{@"o": @0x3A2414, @"a": @0x6AA0C8, @"b": @0xE8D8B0, @"h": @0xF06A7A}],
            @"dice": @[@[@"ooooooo", @"oaaaaao", @"oabaaao", @"oaabaao", @"oaaabao", @"oaaaaao", @"ooooooo"],
                       @{@"o": @0x3A2414, @"a": @0xF8F4EC, @"b": @0xC44A44}],
            @"speaker": @[@[@"...o.....", @"..oo..o..", @"oooo.o.o.", @"oaao...o.", @"oaao...o.", @"oooo.o.o.", @"..oo..o..", @"...o....."],
                          @{@"o": @0x3A2414, @"a": @0xF4E8D0}],
            @"mute": @[@[@"...o.....", @"..oo.....", @"oooo.o.o.", @"oaao..o..", @"oaao..o..", @"oooo.o.o.", @"..oo.....", @"...o....."],
                       @{@"o": @0x3A2414, @"a": @0xF4E8D0}],
            @"girl": @[@[@".ooo.", @"o...o", @".ooo.", @"..o..", @".ooo.", @"..o.."], @{@"o": @0xF07AA0}],
            @"boy": @[@[@"..ooo", @"...oo", @".oo.o", @"o..o.", @"o..o.", @".oo.."], @{@"o": @0x6AA8E8}],
            @"widget": @[@[@"oooo.oooo", @"oaao.obbo", @"oaao.obbo", @"oooo.oooo", @".........", @"oooo.oooo", @"occo.oaao", @"occo.oaao", @"oooo.oooo"],
                         @{@"o": @0x3A2414, @"a": @0xF4E8D0, @"b": @0xF06A7A, @"c": @0x6AA0C8}],
            @"note": @[@[@".##", @".#.", @".#.", @"##.", @"##."], @{@"#": @0xF4E8D0}],
            @"z": @[@[@"####", @"..#.", @".#..", @"####"], @{@"#": @0xE8E4FF}],
            @"smallheart": @[@[@"##.##", @"#####", @".###.", @"..#.."], @{@"#": @0xF06A7A}],
        };
    });
    NSArray *icon = icons[name];
    if (!icon) return APCanvasCreate(1, 1);
    NSArray<NSString *> *rows = icon[0];
    NSDictionary *palette = icon[1];
    int w = 0;
    for (NSString *row in rows) w = MAX(w, (int)row.length);
    APCanvas *c = APCanvasCreate(w, (int)rows.count);
    for (int y = 0; y < (int)rows.count; y++) {
        NSString *row = rows[y];
        for (int x = 0; x < (int)row.length; x++) {
            NSNumber *col = palette[[row substringWithRange:NSMakeRange(x, 1)]];
            if (col) APPx(c, x, y, col.unsignedIntValue);
        }
    }
    return c;
}
