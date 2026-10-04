#import "ApolloPalHomeCatalog.h"
#import <math.h>

// Halloween: the Haunted Manor style, its wallpaper and floor, and a spooky
// item set (cauldron, candelabra, tombstone, candy bowl, cobwebs, bat
// garland). Every piece is October-seasonal: it leads the catalogue in
// October and stays available (and placed) all year.

#define I(identifier, x, y, v) APRoomItem(identifier, x, y, v)

#pragma mark - Surfaces

void APRegisterHalloweenSurfaces(NSMutableArray<APSurfaceSpec *> *walls, NSMutableArray<APSurfaceSpec *> *floors) {
    APSurfaceSpec *(^surface)(NSString *, NSString *, uint32_t, void (^)(APCanvas *, int, int, int, int)) =
        ^APSurfaceSpec *(NSString *identifier, NSString *title, uint32_t swatch, void (^paint)(APCanvas *, int, int, int, int)) {
        APSurfaceSpec *spec = [APSurfaceSpec new];
        spec.identifier = identifier;
        spec.title = title;
        spec.swatch = swatch;
        spec.paint = paint;
        return spec;
    };
    // Faded aubergine damask with a peeling seam or two.
    [walls addObject:surface(@"wp.haunted", @"Haunted Damask", 0x3E2650, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x3A2248);
        for (int xx = 0; xx < w; xx += 16) APRect(c, x + xx + 7, y, 2, h, 0x34203F);
        for (int row = 0; row * 12 < h + 12; row++) for (int col = 0; col * 16 < w + 16; col++) {
            int cx = x + col * 16 + (row % 2) * 8 - 4, cy = y + row * 12;
            // A little damask lozenge.
            for (int k = 0; k < 4; k++) {
                APPx(c, cx + k, cy + 3 - k, 0x523466); APPx(c, cx + k, cy + 3 + k, 0x523466);
                APPx(c, cx + 6 - k, cy + 3 - k, 0x523466); APPx(c, cx + 6 - k, cy + 3 + k, 0x523466);
            }
            APPx(c, cx + 3, cy + 3, 0x6A4A80);
        }
        APRand r = {0xB00};
        for (int k = 0; k < w / 40 + 1; k++) {
            int px = x + APRandInt(&r, 4, MAX(5, w - 6)), py = y + APRandInt(&r, 0, MAX(1, h / 2));
            APLine(c, px, py, px + 3, py + 6, 0x24142E); // a peeling seam
            APPx(c, px + 4, py + 6, 0x7A5A8A);
        }
    })];
    // Dark, worn floorboards with gaps you could lose a candy down.
    [floors addObject:surface(@"fl.creaky", @"Creaky Boards", 0x4A3428, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x1E140E);
        APRand r = {0xC2EA};
        for (int row = 0; row * 6 < h; row++) {
            int bx = -APRandInt(&r, 0, 30);
            while (bx < w) {
                int len = APRandInt(&r, 18, 40);
                uint32_t tone = (uint32_t[]){0x4A3428, 0x42302A, 0x50382C, 0x3E2C24}[APRandInt(&r, 0, 3)];
                int x0 = MAX(bx, 0), x1 = MIN(bx + len - 1, w);
                if (x1 > x0) {
                    APRect(c, x + x0, y + row * 6, x1 - x0, 5, tone);
                    APHLine(c, x + x0, y + row * 6, x1 - x0, APShade(tone, 1.12f));
                    if (APRandInt(&r, 0, 2) == 0) APHLine(c, x + x0 + 3, y + row * 6 + 2, MIN(6, x1 - x0 - 4), APShade(tone, 0.85f)); // grain
                    APPx(c, x + x0 + 1, y + row * 6 + 2, 0x2A2A30); // nail
                }
                bx += len;
            }
        }
    })];
}

#pragma mark - Items

void APRegisterHalloweenItems(NSMutableArray<APItemSpec *> *items) {
    // A bubbling cauldron with a green glow (and audible bubbles).
    APItemSpec *cauldron = APSpec(@"cauldron", @"Cauldron", APLayerFloor, APCategoryCosy, 1, 1, 4, @[@"Witch's Brew", @"Pumpkin Soup"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 20
        uint32_t brew = ctx.variant ? 0xF08A2A : 0x6AE05A, brewHi = ctx.variant ? 0xFFC060 : 0xB8FF8A;
        // Little fire beneath.
        APRect(c, 4, H - 6, 8, 2, 0x4A2E1C);
        if (ctx.on) { APPx(ctx.emissive, 6, H - 7, 0xFFA040); APPx(ctx.emissive, 9, H - 7, 0xFFC060); APPx(ctx.emissive, 7, H - 8, 0xFFE080); }
        // The pot.
        APEllipse(c, 1, 6, 14, 11, 0x26222A);
        APEllipse(c, 2, 7, 6, 6, 0x3A3540);
        APRect(c, 0, 5, 16, 3, 0x34303A);
        APHLine(c, 0, 5, 16, 0x56505E);
        APRect(c, 2, H - 4, 2, 2, 0x1A161E); APRect(c, 12, H - 4, 2, 2, 0x1A161E); // feet
        APOutlineInside(c, 0x0C0A10);
        // Brew surface (glowing).
        APHLine(ctx.emissive, 2, 6, 12, brew);
        APHLine(ctx.emissive, 3, 5, 10, brewHi);
        APPx(ctx.emissive, 5, 4, brewHi); APPx(ctx.emissive, 10, 4, brew);
        APAnim *bubbles = [APAnim kind:APAnimBubbles x:8 y:4 w:1 h:1];
        bubbles.color = brewHi;
        [ctx addAnim:bubbles];
        APAnim *glow = [APAnim kind:APAnimGlow x:8 y:5 w:0 h:0];
        glow.size = 14; glow.color = brew; glow.variant = 1;
        [ctx addAnim:glow];
        [ctx addLight:[APLight x:8 y:5 radius:40 color:brew strength:0.45f]];
        APShadow(c, 0, H - 5, 16, 5);
    });
    cauldron.season = 10;
    [items addObject:cauldron];

    // A three-armed candelabra, candles guttering.
    APItemSpec *candelabra = APSpec(@"candelabra", @"Candelabra", APLayerFloor, APCategoryCosy, 1, 1, 14, @[@"Brass", @"Silver"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 30
        uint32_t metal = ctx.variant ? 0xB8BCC8 : 0xC8962A, dark = ctx.variant ? 0x6A6E7A : 0x7A5418;
        APRect(c, 5, H - 6, 6, 2, metal); APRect(c, 6, H - 8, 4, 2, dark);
        APVLine(c, 7, 9, H - 16, metal); APVLine(c, 8, 9, H - 16, dark);
        APHLine(c, 2, 14, 12, metal); APHLine(c, 2, 15, 12, dark);
        APVLine(c, 2, 10, 5, metal); APVLine(c, 13, 10, 5, metal);
        APOutlineInside(c, 0x2A1C0C);
        // Three guttering candles (the flames flicker in the scene).
        APCandle(ctx, 2, 10, 4, 0xEEE4D0);
        APCandle(ctx, 7, 9, 6, 0xEEE4D0);
        APCandle(ctx, 12, 10, 4, 0xEEE4D0);
        APPx(c, 3, 8, 0xD8CCB4); APPx(c, 8, 6, 0xD8CCB4); // drips
        if (ctx.on) [ctx addLight:[APLight x:8 y:4 radius:44 color:0xFFC070 strength:0.55f]];
        APShadow(c, 2, H - 5, 12, 4);
    });
    candelabra.season = 10;
    candelabra.toggleable = YES;
    [items addObject:candelabra];

    // A mossy headstone. "Rest in pixels."
    [items addObject:({
        APItemSpec *stone = APSpec(@"tombstone", @"Tombstone", APLayerFloor, APCategoryCosy, 1, 1, 6, @[@"Weathered", @"Mossy"], ^(APDrawContext *ctx) {
            APCanvas *c = ctx.base;
            int H = ctx.height; // 22
            APRect(c, 2, 6, 12, H - 9, 0x8A8690);
            APEllipse(c, 2, 1, 12, 10, 0x8A8690);
            APRect(c, 3, 6, 4, H - 10, 0x9A96A0);
            APEllipse(c, 3, 2, 6, 6, 0x9A96A0);
            APOutlineInside(c, 0x2A2830);
            APText(c, @"RIP", 3, 8, APFontSmall, 0x3E3A44);
            APHLine(c, 4, 15, 8, 0x6E6A74); APHLine(c, 5, 17, 6, 0x6E6A74);
            if (ctx.variant) {
                for (int x = 2; x < 14; x += 2) APPx(c, x, H - 4 - (x % 3), 0x5E8A3C);
                APPx(c, 3, 3, 0x5E8A3C); APPx(c, 4, 2, 0x6E9A4A); APPx(c, 12, 6, 0x5E8A3C);
            }
            // Grass tufts.
            for (int x = 1; x < 15; x += 3) { APPx(c, x, H - 4, 0x4A6A2E); APPx(c, x + 1, H - 5, 0x5E8A3C); }
            APShadow(c, 0, H - 5, 16, 5);
        });
        stone.season = 10;
        stone;
    })];

    // Trick or treat: a candy bowl your Pal can eat from (feeding, like the
    // bowls).
    APItemSpec *candy = APSpec(@"candybowl", @"Candy Bowl", APLayerFloor, APCategoryCosy, 1, 1, 0, @[@"Pumpkin Pail", @"Skull Bowl"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        if (ctx.variant) {
            APEllipse(c, 2, 4, 12, 10, 0xEEE8DC); // skull
            APPx(c, 5, 8, 0x1A161E); APPx(c, 6, 8, 0x1A161E); APPx(c, 9, 8, 0x1A161E); APPx(c, 10, 8, 0x1A161E);
            APPx(c, 7, 11, 0x1A161E); APPx(c, 8, 11, 0x1A161E);
        } else {
            APEllipse(c, 2, 4, 12, 10, 0xE07A22); // pumpkin pail
            APVLine(c, 6, 5, 8, 0xC0601A); APVLine(c, 9, 5, 8, 0xC0601A);
            APPx(c, 5, 8, 0x3A1A08); APPx(c, 10, 8, 0x3A1A08); APHLine(c, 6, 11, 4, 0x3A1A08);
            APLine(c, 2, 5, 8, 0, 0x2A2A30); APLine(c, 8, 0, 14, 5, 0x2A2A30); // handle
        }
        // Wrapped candies heaped on top.
        uint32_t wrappers[] = {0xE84A5A, 0x5AB0E8, 0xF2C040, 0x9A5AE0, 0x6AD07A};
        int spots[][2] = {{4, 4}, {7, 3}, {10, 4}, {6, 5}, {9, 5}};
        for (int i = 0; i < 5; i++) {
            APPx(c, spots[i][0], spots[i][1], wrappers[i]);
            APPx(c, spots[i][0] + 1, spots[i][1], APShade(wrappers[i], 1.2f));
            APPx(c, spots[i][0] - 1, spots[i][1], APShade(wrappers[i], 0.8f));
        }
        APOutlineInside(c, 0x2A1408);
        APShadow(c, 1, 11, 14, 4);
    });
    candy.walkable = YES;
    candy.season = 10;
    [items addObject:candy];

    // A cobweb for a top corner (trim rail): it hangs from the left; flip it
    // for the right-hand corner.
    [items addObject:({
        APItemSpec *webs = APSpec(@"cobwebs", @"Cobwebs", APLayerTrim, APCategoryWall, 2, 1, 0, @[@"Dusty", @"Glowing"], ^(APDrawContext *ctx) {
            APCanvas *target = ctx.variant ? ctx.emissive : ctx.base;
            uint32_t silk = ctx.variant ? 0xB8F0D8 : 0xD8D4DC;
            float rx = 24, ry = 14;
            // Radial threads from the corner…
            for (int k = 0; k < 5; k++) {
                float a = (k + 0.5f) / 5 * (float)M_PI_2;
                APLine(target, 0, 0, (int)lroundf(cosf(a) * rx), (int)lroundf(sinf(a) * ry), silk);
            }
            // …and sagging rings between them.
            for (int ring = 1; ring <= 3; ring++) {
                float f = ring / 3.5f;
                for (int s = 0; s <= 20; s++) {
                    float a = s / 20.0f * (float)M_PI_2;
                    float sag = sinf(fmodf(a * 5 / (float)M_PI_2 * (float)M_PI, (float)M_PI)) * ring * 0.6f;
                    APPx(target, (int)lroundf(cosf(a) * rx * f + sag * 0.5f), (int)lroundf(sinf(a) * ry * f + sag), silk);
                }
            }
            // A little spider on a thread.
            APVLine(ctx.base, 22, 0, 10, 0xC8C4CC);
            APRect(ctx.base, 21, 10, 3, 2, 0x1A161E);
            APPx(ctx.base, 20, 10, 0x1A161E); APPx(ctx.base, 24, 10, 0x1A161E);
            APPx(ctx.base, 20, 12, 0x1A161E); APPx(ctx.base, 24, 12, 0x1A161E);
            APPx(ctx.emissive, 22, 10, 0xE84A4A);
        });
        webs.season = 10;
        webs;
    })];

    // Paper bats on a string.
    [items addObject:({
        APItemSpec *bats = APSpec(@"batgarland", @"Bat Garland", APLayerTrim, APCategoryWall, 4, 1, 0, @[@"Midnight", @"Pumpkin"], ^(APDrawContext *ctx) {
            APCanvas *c = ctx.base;
            for (int x = 0; x < ctx.width; x++) {
                float t = (x % 32) / 32.0f;
                APPx(c, x, (int)lroundf(1 + 18 * t * (1 - t)), 0x8A7A6A);
            }
            uint32_t body = ctx.variant ? 0xE07A22 : 0x2A2232, edge = ctx.variant ? 0x8A3A0A : 0x0C0A10;
            for (int x = 6; x < ctx.width - 6; x += 10) {
                float t = (x % 32) / 32.0f;
                int y = (int)lroundf(2 + 18 * t * (1 - t));
                // Wings out, little ears.
                APRect(c, x - 1, y + 1, 3, 2, body);
                APHLine(c, x - 4, y + 1, 3, body); APHLine(c, x + 2, y + 1, 3, body);
                APPx(c, x - 4, y + 2, body); APPx(c, x + 4, y + 2, body);
                APPx(c, x - 1, y, body); APPx(c, x + 1, y, body);
                APPx(c, x - 2, y + 2, edge); APPx(c, x + 2, y + 2, edge);
                APPx(ctx.emissive, x - 1, y + 1, 0xFFE070); APPx(ctx.emissive, x + 1, y + 1, 0xFFE070); // eyes
            }
        });
        bats.season = 10;
        bats;
    })];
}

#pragma mark - Haunted Manor

static NSDictionary *APFlipped(NSDictionary *item) {
    NSMutableDictionary *flipped = [item mutableCopy];
    flipped[@"flip"] = @YES;
    return flipped;
}

static void APShellManor(APCanvas *c) {
    int W = APShellWidth, H = APShellHeight;
    // Dark, carved wood with a purple sheen.
    uint32_t cap = 0x2A1A24, light = 0x4A3040, dark = 0x120A10;
    APRect(c, 0, 0, APSideWall, H, cap);
    APRect(c, W - APSideWall, 0, APSideWall, H, cap);
    APVLine(c, APSideWall - 1, 0, H, light);
    APVLine(c, W - APSideWall, 0, H, light);
    APVLine(c, 0, 0, H, dark); APVLine(c, W - 1, 0, H, dark);
    APRect(c, 0, H - APFrontLip, W, APFrontLip, cap);
    APHLine(c, 0, H - APFrontLip, W, light);
    APHLine(c, 0, H - 1, W, dark);
    APRect(c, 0, 0, W, APCeiling, 0x22141E);
    for (int x = 0; x < W; x += 12) { APPx(c, x + 5, 3, 0x6A4A5E); APPx(c, x + 6, 2, 0x6A4A5E); } // carved rosettes
    APHLine(c, 0, APCeiling - 1, W, light);
    int base = APFloorTop - APBaseboard;
    APRect(c, APSideWall, base, W - APSideWall * 2, APBaseboard, 0x2E1E28);
    APHLine(c, APSideWall, base, W - APSideWall * 2, 0x5A3A50);
    // Cobwebs tucked in the top corners of the shell itself.
    for (int k = 0; k < 6; k++) {
        APPx(c, APSideWall + k, APCeiling + 5 - k, 0xB8B4C0);
        APPx(c, W - APSideWall - 1 - k, APCeiling + 5 - k, 0xB8B4C0);
    }
}

static void APBackdropManor(APCanvas *c, int w, int h) {
    // A violet night: sky gradient, a great moon, a bare tree, distant graves.
    for (int y = 0; y < h; y++) {
        float t = (float)y / MAX(1, h - 1);
        uint32_t sky = APMix(0x1A1030, 0x3A2458, t);
        for (int x = 0; x < w; x++) {
            uint32_t col = sky;
            if (APBayer(x, y) < fmodf(t * 6, 1.0f) * 0.5f) col = APMix(0x1A1030, 0x3A2458, MIN(1.0f, t + 0.08f));
            APPx(c, x, y, col);
        }
    }
    int mx = w * 3 / 4, my = h / 5, mr = MAX(8, MIN(w, h) / 9);
    APCircle(c, mx, my, mr + 3, 0x4A3468);
    APCircle(c, mx, my, mr, 0xF4ECD0);
    APCircle(c, mx - mr / 3, my - mr / 4, mr / 4, 0xE0D6B8);
    APCircle(c, mx + mr / 3, my + mr / 3, mr / 5, 0xE0D6B8);
    // Rolling hills and headstones at the bottom.
    for (int x = 0; x < w; x++) {
        int hill = h - 10 - (int)lroundf(4 * sinf(x * 0.05f) + 3 * sinf(x * 0.013f + 1));
        APVLine(c, x, hill, h - hill, 0x120A18);
    }
    APRand r = {0x6A7E};
    for (int x = 6; x < w - 6; x += APRandInt(&r, 14, 30)) {
        int gy = h - 12 - (int)lroundf(4 * sinf(x * 0.05f) + 3 * sinf(x * 0.013f + 1));
        APRect(c, x, gy - 5, 4, 5, 0x241A2C); APHLine(c, x + 1, gy - 6, 2, 0x241A2C);
    }
    // A bare, crooked tree on the left.
    int tx = w / 6, ty = h - 14;
    APLine(c, tx, ty, tx + 2, ty - 26, 0x0C0610); APLine(c, tx + 1, ty, tx + 3, ty - 26, 0x0C0610);
    APLine(c, tx + 2, ty - 16, tx - 8, ty - 24, 0x0C0610);
    APLine(c, tx + 2, ty - 20, tx + 12, ty - 30, 0x0C0610);
    APLine(c, tx + 3, ty - 26, tx + 1, ty - 34, 0x0C0610);
    APLine(c, tx - 4, ty - 21, tx - 6, ty - 28, 0x0C0610);
}

APStyleSpec *APHalloweenManorStyle(void) {
    APStyleSpec *manor = [APStyleSpec new];
    manor.identifier = @"manor";
    manor.title = @"Haunted Manor";
    manor.tintR = 0.9f; manor.tintG = 0.84f; manor.tintB = 1.0f;
    manor.backdropAnim = APBackdropAnimBats;
    manor.season = 10;
    manor.paintShell = ^(APCanvas *c) { APShellManor(c); };
    manor.paintBackdrop = ^(APCanvas *c, int w, int h) { APBackdropManor(c, w, h); };
    manor.room = ^NSDictionary *{
        return @{@"style": @"manor", @"wallpaper": @"wp.haunted", @"floor": @"fl.creaky", @"lighting": @"evening", @"items": @[
            I(@"fireplace", 0, 0, 0), I(@"candelabra", 3, 0, 1), I(@"bookshelf", 5, 0, 0), I(@"grandfather", 7, 0, 0),
            I(@"rug.woven", 2, 2, 0), I(@"armchair", 5, 2, 0), I(@"cauldron", 1, 3, 0), I(@"petbed.cushion", 6, 4, 0),
            I(@"pumpkin", 0, 6, 0), I(@"candybowl", 7, 6, 0), I(@"tombstone", 3, 6, 1),
            I(@"window", 3, 0, 1), I(@"sconce", 1, 0, 0), I(@"sconce", 6, 0, 0),
            I(@"cobwebs", 0, 0, 0), I(@"batgarland", 2, 0, 0), APFlipped(I(@"cobwebs", 6, 0, 0))]};
    };
    return manor;
}
