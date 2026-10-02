#import "ApolloPalHomeCatalog.h"

// Floor furniture, pet beds and rugs. Items are drawn in a 3/4 top-down view:
// the bottom `d` tiles of each bitmap are the footprint on the floor, and
// anything above rises in front of the wall/tiles behind it.

#pragma mark - Shared pieces

// Irregular rounded stones / bricks for hearths.
static void APMasonry(APCanvas *c, int x, int y, int w, int h, int style, uint32_t seed) {
    APRand r = {seed};
    if (style == 0) {
        APRamp s = APRampNamed(@"stone");
        APRect(c, x, y, w, h, s.o);
        for (int yy = y; yy < y + h; ) {
            int sh = APRandInt(&r, 4, 6);
            for (int xx = x - APRandInt(&r, 0, 5); xx < x + w; ) {
                int sw = APRandInt(&r, 5, 9);
                uint32_t tone = (uint32_t[]){s.m, s.l, APMix(s.m, 0x9A7A62, 0.35f), APMix(s.l, 0xA08C74, 0.3f)}[APRandInt(&r, 0, 3)];
                int x0 = MAX(xx, x), x1 = MIN(xx + sw - 1, x + w), y1 = MIN(yy + sh - 1, y + h);
                if (x1 - x0 >= 2 && y1 - yy >= 2) {
                    APRoundRect(c, x0, yy, x1 - x0, y1 - yy, tone);
                    APHLine(c, x0 + 1, yy, x1 - x0 - 2, APShade(tone, 1.14f));
                    APHLine(c, x0 + 1, y1 - 1, x1 - x0 - 2, APShade(tone, 0.84f));
                }
                xx += sw;
            }
            yy += sh;
        }
    } else {
        BOOL white = style == 2;
        APRamp b = APRampNamed(white ? @"white" : @"brick");
        APRect(c, x, y, w, h, white ? 0xA8A096 : 0x5A342A);
        for (int row = 0; row * 4 < h; row++) {
            for (int xx = x - (row % 2 ? 4 : 0); xx < x + w; xx += 8) {
                uint32_t tone = (uint32_t[]){b.m, b.l, APShade(b.m, 0.94f)}[APRandInt(&r, 0, 2)];
                int x0 = MAX(xx, x), x1 = MIN(xx + 7, x + w);
                APRect(c, x0, y + row * 4, x1 - x0, MIN(3, y + h - (y + row * 4)), tone);
                APHLine(c, x0, y + row * 4, x1 - x0, APShade(tone, 1.1f));
            }
        }
    }
}

// A little pillar candle; returns the flame tip for the animation hook.
void APCandle(APDrawContext *ctx, int x, int y, int height, uint32_t wax) {
    APRect(ctx.base, x, y - height, 2, height, wax);
    APVLine(ctx.base, x + 1, y - height, height, APShade(wax, 0.82f));
    APPx(ctx.base, x, y - height - 1, 0x3A2A20); // wick
    if (ctx.on) {
        APPx(ctx.emissive, x, y - height - 2, 0xFEE890);
        APPx(ctx.emissive, x, y - height - 3, 0xFFFBE0);
        APPx(ctx.emissive, x, y - height, APMix(wax, 0xFFE8A0, 0.6f));
        APAnim *anim = [APAnim kind:APAnimCandle x:x y:y - height - 3 w:1 h:2];
        [ctx addAnim:anim];
    }
}

static void APMug(APDrawContext *ctx, int x, int y, uint32_t colour) {
    // 5×5 mug with a handle; y is the base line.
    APRect(ctx.base, x, y - 5, 4, 5, colour);
    APHLine(ctx.base, x, y - 5, 4, APShade(colour, 1.15f));
    APHLine(ctx.base, x, y - 4, 4, 0x5A3420); // tea
    APPx(ctx.base, x + 4, y - 4, colour); APPx(ctx.base, x + 5, y - 3, colour); APPx(ctx.base, x + 4, y - 2, colour);
    APVLine(ctx.base, x + 3, y - 3, 3, APShade(colour, 0.8f));
    APAnim *steam = [APAnim kind:APAnimSteam x:x + 1 y:y - 6 w:1 h:1];
    [ctx addAnim:steam];
}

static void APLeaf(APCanvas *c, int x, int y, int w, int h, APRamp leaf, BOOL split) {
    APEllipse(c, x, y, w, h, leaf.m);
    APEllipse(c, x + 1, y, w - 2, h / 2, leaf.l);
    APLine(c, x + w / 2, y + 1, x + w / 2, y + h - 1, leaf.d);
    if (split && w >= 6) {
        // Monstera fenestrations: little notches cut back to transparent.
        int ny = y + h / 2;
        if (ny >= 0 && ny < c->h && x >= 0 && x + w - 1 < c->w) {
            c->px[ny * c->w + x] = 0;
            c->px[(ny - 1) * c->w + x + w - 1] = 0;
            c->px[(ny + 1) * c->w + x + 1] = 0;
        }
    }
}

#pragma mark - Floor furniture

static void APRegisterHearths(NSMutableArray *items) {
    APItemSpec *fireplace = APSpec(@"fireplace", @"Stone Fireplace", APLayerFloor, APCategoryFurniture, 3, 1, 34,
                                   @[@"Fieldstone", @"Red Brick", @"Whitewash"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 50
        APRamp wood = APRampNamed(@"walnut");
        APRamp stone = APRampNamed(ctx.variant == 2 ? @"white" : @"stone");
        // Chimney breast.
        APMasonry(c, 4, 10, 40, H - 18, ctx.variant, 0xF12E);
        // Firebox opening with an arched top.
        int fx = 13, fy = 18, fw = 22, fh = H - 8 - fy;
        for (int yy = fy; yy < fy + fh; yy++) for (int xx = fx; xx < fx + fw; xx++) {
            int dy = yy - fy, dx = MIN(xx - fx, fx + fw - 1 - xx);
            if (dy < 4 && dx < 4 - dy) continue; // arch corners
            APPx(c, xx, yy, dy < 3 ? 0x140A08 : 0x1E120E);
        }
        for (int yy = fy + 5; yy < fy + fh; yy += 3) APHLine(c, fx + 2, yy, fw - 4, 0x2A1812);
        // Voussoir stones around the arch.
        for (int i = 0; i < fw + 4; i += 3) {
            int xx = fx - 2 + i;
            int dx = MIN(xx - fx + 2, fx + fw + 1 - xx);
            int yy = fy - 3 + MAX(0, 4 - dx);
            APRect(c, xx, yy, 2, 2, ctx.variant == 1 ? 0xC47A5A : stone.h);
        }
        // Mantel shelf.
        APRect(c, 0, 8, 48, 3, wood.l);
        APHLine(c, 0, 8, 48, wood.h);
        APRect(c, 1, 11, 46, 2, wood.m);
        APHLine(c, 1, 13, 46, wood.o);
        APRect(c, 5, 13, 3, 2, wood.d); APRect(c, 40, 13, 3, 2, wood.d); // corbels
        // Hearth slab.
        APRect(c, 0, H - 8, 48, 4, stone.l);
        APHLine(c, 0, H - 8, 48, stone.h);
        APRect(c, 0, H - 4, 48, 3, stone.d);
        APHLine(c, 0, H - 1, 48, stone.o);
        // Mantel dressing: candles, a tiny frame and a sprig vase.
        APCandle(ctx, 5, 8, 5, 0xF4E8D0);
        APCandle(ctx, 8, 8, 3, 0xE8C8A0);
        APRect(c, 21, 2, 7, 6, 0xB08040); APRect(c, 22, 3, 5, 4, 0xE8D8B8);
        APPx(c, 24, 4, 0x8A5A3A); APHLine(c, 23, 5, 3, 0x6A8A5A);
        APRect(c, 38, 4, 3, 4, 0x5A7A9A); APPx(c, 38, 2, 0x6A9A58); APPx(c, 40, 1, 0x6A9A58); APPx(c, 39, 3, 0x6A9A58);
        APPx(c, 41, 2, 0xE87A6A);
        // Logs and grate (front layer, over the flames).
        APCanvas *f = ctx.front;
        int ly = H - 12;
        APRect(f, fx + 3, ly, fw - 6, 3, 0x5A3A22);
        APHLine(f, fx + 3, ly, fw - 6, 0x7A5032);
        APRect(f, fx + 3, ly, 2, 3, 0xC89A6A); APPx(f, fx + 3, ly + 1, 0x8A5A36);
        APLine(f, fx + 5, ly - 1, fx + fw - 6, ly + 2, 0x4A2E1A);
        APLine(f, fx + 5, ly - 2, fx + fw - 6, ly + 1, 0x6A4228);
        for (int xx = fx + 1; xx < fx + fw - 1; xx += 3) APVLine(f, xx, ly + 2, 2, 0x2A2A30);
        APHLine(f, fx + 1, ly + 3, fw - 2, 0x3E3E48);
        APOutlineInside(c, 0x2A1A14);
        if (ctx.on) {
            // Ember bed glowing under the logs.
            for (int xx = fx + 2; xx < fx + fw - 2; xx++) {
                APPx(ctx.emissive, xx, ly + 3, APBayer(xx, ly) < 0.5f ? 0xFF6A1E : 0xC8401A);
            }
            [ctx addAnim:[APAnim kind:APAnimFire x:fx + 2 y:fy + 4 w:fw - 4 h:ly + 3 - (fy + 4)]];
            APAnim *embers = [APAnim kind:APAnimEmbers x:fx + 4 y:fy + 8 w:fw - 8 h:1];
            [ctx addAnim:embers];
            APAnim *glow = [APAnim kind:APAnimGlow x:24 y:ly w:0 h:0];
            glow.size = 34;
            glow.color = 0xFF9A48;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:24 y:ly - 4 radius:92 color:0xFFA050 strength:1.05f]];
        } else {
            for (int xx = fx + 2; xx < fx + fw - 2; xx++) APPx(f, xx, ly + 3, 0x5A5450);
        }
        APShadow(c, 0, H - 3, 48, 4);
    });
    fireplace.backWall = YES;
    fireplace.toggleable = YES;
    [items addObject:fireplace];

    APItemSpec *stove = APSpec(@"stove", @"Pot-Belly Stove", APLayerFloor, APCategoryFurniture, 1, 1, 40,
                               @[@"Cast Iron", @"Cherry Enamel", @"Forest Enamel"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp body = APRampNamed(ctx.variant == 1 ? @"red" : ctx.variant == 2 ? @"sage" : @"iron");
        APRamp iron = APRampNamed(@"iron");
        int H = ctx.height; // 56
        // Flue pipe to the ceiling.
        APRect(c, 6, 0, 4, 24, iron.m); APVLine(c, 6, 0, 24, iron.l); APVLine(c, 9, 0, 24, iron.d);
        APRect(c, 5, 10, 6, 2, iron.l);
        // Pot-belly body.
        APRect(c, 4, 24, 8, 3, body.d);
        APEllipse(c, 1, 26, 14, 20, body.m);
        APEllipse(c, 2, 27, 5, 14, body.l);
        APVLine(c, 3, 30, 8, body.h);
        APRect(c, 3, 25, 10, 2, body.l);
        // Fire window.
        APRect(c, 5, 34, 6, 6, 0x140A08);
        APRect(c, 3, 45, 10, 3, iron.d);
        APRect(c, 3, 48, 2, 4, iron.o); APRect(c, 11, 48, 2, 4, iron.o);
        APOutlineInside(c, body.o);
        if (ctx.on) {
            [ctx addAnim:[APAnim kind:APAnimFire x:5 y:34 w:6 h:6]];
            APAnim *glow = [APAnim kind:APAnimGlow x:8 y:37 w:0 h:0];
            glow.size = 20; glow.color = 0xFF8A3A;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:8 y:37 radius:62 color:0xFF9A48 strength:0.8f]];
        }
        APShadow(c, 0, H - 6, 16, 6);
    });
    stove.toggleable = YES;
    [items addObject:stove];
}

static void APDrawCouch(APDrawContext *ctx, int W, BOOL sofa) {
    APCanvas *c = ctx.base;
    NSArray *names = @[@"rust", @"sage", @"navy", @"mustard", @"rose"];
    APRamp r = APRampNamed(names[ctx.variant % names.count]);
    APRamp cream = APRampNamed(@"cream");
    APRamp wood = APRampNamed(@"walnut");
    int H = ctx.height; // 30
    // Legs.
    APRect(c, 3, H - 5, 2, 3, wood.d); APRect(c, W - 5, H - 5, 2, 3, wood.d);
    // Backrest.
    APRoundRect(c, 3, 0, W - 6, 15, r.m);
    APHLine(c, 4, 1, W - 8, r.h);
    APHLine(c, 4, 2, W - 8, r.l);
    for (int x = 9; x < W - 8; x += 8) { APPx(c, x, 7, r.d); APPx(c, x + 4, 10, r.d); }
    // Seat top and front.
    APRect(c, 6, 12, W - 12, 8, r.l);
    APHLine(c, 6, 12, W - 12, r.d); // tuck under the back
    if (sofa) for (int x = 6 + (W - 12) / 3; x < W - 7; x += (W - 12) / 3) APVLine(c, x, 13, 11, r.m);
    APRect(c, 6, 20, W - 12, 5, r.m);
    APHLine(c, 6, 20, W - 12, r.h);
    APHLine(c, 6, 24, W - 12, r.d);
    // Arms.
    for (int side = 0; side < 2; side++) {
        int ax = side ? W - 8 : 0;
        APRoundRect(c, ax, 6, 8, 20, r.m);
        APRect(c, ax + 1, 6, 6, 3, r.l);
        APHLine(c, ax + 2, 6, 4, r.h);
        APVLine(c, side ? ax : ax + 7, 9, 16, r.d);
    }
    // Throw pillows.
    APRoundRect(c, 8, 7, 9, 8, cream.l);
    APHLine(c, 9, 7, 7, cream.h);
    APHLine(c, 9, 14, 7, cream.d);
    APPx(c, 12, 10, cream.m);
    if (sofa) {
        APRamp accent = APRampNamed(ctx.variant == 3 ? @"rust" : @"mustard");
        APRoundRect(c, W - 17, 7, 9, 8, accent.l);
        APHLine(c, W - 16, 7, 7, accent.h);
        for (int y = 8; y < 15; y += 3) APHLine(c, W - 16, y, 7, accent.m);
        APVLine(c, W - 13, 8, 6, accent.m);
        // Plaid blanket over the right arm.
        APRamp blanket = APRampNamed(ctx.variant == 1 ? @"rose" : @"sage");
        for (int y = 5; y < 22; y++) for (int x = W - 8; x < W - 1; x++) {
            uint32_t col = ((x / 2) % 2 && (y / 2) % 2) ? blanket.d : ((x / 2) % 2 || (y / 2) % 2) ? blanket.m : cream.l;
            APPx(c, x, y, col);
        }
        for (int x = W - 8; x < W - 1; x += 2) APPx(c, x, 22, cream.m);
    }
    APOutlineInside(c, r.o);
    APShadow(c, 1, H - 4, W - 2, 5);
}

static void APRegisterSeating(NSMutableArray *items) {
    NSArray *fabrics = @[@"Rust Velvet", @"Sage Linen", @"Navy Wool", @"Mustard Corduroy", @"Rose Velvet"];
    APItemSpec *sofa = APSpec(@"sofa", @"Comfy Sofa", APLayerFloor, APCategoryFurniture, 3, 1, 14, fabrics, ^(APDrawContext *ctx) {
        APDrawCouch(ctx, 48, YES);
    });
    sofa.seat = YES; sofa.seatX = 28; sofa.seatY = 19;
    [items addObject:sofa];
    APItemSpec *armchair = APSpec(@"armchair", @"Armchair", APLayerFloor, APCategoryFurniture, 2, 1, 14, fabrics, ^(APDrawContext *ctx) {
        APDrawCouch(ctx, 32, NO);
    });
    armchair.seat = YES; armchair.seatX = 17; armchair.seatY = 19;
    [items addObject:armchair];

    APItemSpec *futon = APSpec(@"futon", @"Floor Bed", APLayerFloor, APCategoryFurniture, 2, 2, 4,
                               @[@"Patchwork", @"Blue Gingham", @"Starry Night", @"Rosy"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp cream = APRampNamed(@"cream");
        // Mattress (top + side).
        APRoundRect(c, 1, 2, 30, 30, cream.l);
        APRect(c, 1, 30, 30, 4, cream.m);
        APHLine(c, 2, 33, 28, cream.d);
        // Pillows.
        for (int px = 3; px < 28; px += 13) {
            APRoundRect(c, px, 4, 12, 8, cream.h);
            APHLine(c, px + 1, 10, 10, cream.m);
            APPx(c, px + 5, 7, cream.l);
        }
        // Quilt with a turned-down sheet.
        APRect(c, 1, 13, 30, 3, cream.h);
        APHLine(c, 1, 15, 30, cream.m);
        int qy = 16;
        for (int y = qy; y < 34; y++) for (int x = 1; x < 31; x++) {
            uint32_t col;
            switch (ctx.variant) {
                case 1: { APRamp n = APRampNamed(@"navy");
                    BOOL a = (x / 3) % 2, b = (y / 3) % 2;
                    col = a && b ? n.m : (a || b) ? n.l : cream.h; break; }
                case 2: { APRamp n = APRampNamed(@"navy");
                    col = n.d;
                    if ((x * 7 + y * 13) % 23 == 0) col = 0xF0DC98;
                    else if ((x * 5 + y * 3) % 31 == 0) col = n.l;
                    break; }
                case 3: { APRamp p = APRampNamed(@"rose");
                    col = ((x + y) % 8 < 4) ? p.l : p.m;
                    if ((x % 8 == 4) && (y % 6 == 2)) col = p.h;
                    break; }
                default: {
                    uint32_t patches[] = {0xA85432, 0xDCB04A, 0x6A8A64, 0xECE0C4, 0x6076AA, 0xCC8498};
                    col = patches[((x - 1) / 6 + (y - qy) / 6 * 3) % 6];
                    if ((x - 1) % 6 == 0 || (y - qy) % 6 == 0) col = APShade(col, 0.85f);
                    break;
                }
            }
            if (y >= 31) col = APShade(col, 0.8f); // quilt folding over the edge
            APPx(c, x, y, col);
        }
        APOutlineInside(c, cream.o);
        APShadow(c, 0, 31, 32, 5);
    });
    futon.walkable = YES;
    futon.petBed = YES;
    futon.sleepX = 16; futon.sleepY = 26;
    [items addObject:futon];
}

static void APRegisterPetBeds(NSMutableArray *items) {
    NSArray *colours = @[@"rose", @"sage", @"navy", @"mustard", @"lavender"];
    NSArray *titles = @[@"Rose", @"Sage", @"Navy", @"Mustard", @"Lavender"];
    APItemSpec *cushion = APSpec(@"petbed.cushion", @"Pet Cushion", APLayerFloor, APCategoryCosy, 1, 1, 2, titles, ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp r = APRampNamed(colours[ctx.variant % colours.count]);
        APEllipse(c, 0, 4, 16, 13, r.m);
        APEllipse(c, 1, 4, 14, 6, r.l);
        APEllipse(c, 3, 7, 10, 7, r.d);
        APEllipse(c, 4, 8, 8, 5, APRampNamed(@"cream").l);
        APHLine(c, 5, 8, 6, APRampNamed(@"cream").h);
        APOutlineInside(c, r.o);
        APShadow(c, 0, 13, 16, 5);
    });
    cushion.walkable = YES;
    cushion.petBed = YES;
    cushion.sleepX = 8; cushion.sleepY = 14;
    [items addObject:cushion];

    APItemSpec *basket = APSpec(@"petbed.basket", @"Wicker Basket", APLayerFloor, APCategoryCosy, 1, 1, 6,
                                @[@"Natural", @"Honey"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t light = ctx.variant ? 0xE0B060 : 0xD0A870, mid = ctx.variant ? 0xB88838 : 0xA87A48, dark = 0x7A5028;
        APEllipse(c, 0, 6, 16, 8, mid);
        APRect(c, 1, 10, 14, 10, mid);
        APEllipse(c, 1, 16, 14, 6, mid);
        for (int y = 11; y < 20; y++) for (int x = 1; x < 15; x++) {
            if (((x + (y / 2) * 2) % 4) < 2) APPx(c, x, y, light);
            if (y % 2 == 0 && x % 4 == 0) APPx(c, x, y, dark);
        }
        APEllipse(c, 2, 7, 12, 5, 0xECE0C4);
        APHLine(c, 4, 7, 8, 0xFAF4E4);
        // Blanket flopping over the rim.
        APRect(c, 9, 8, 5, 6, 0x6A8A64); APPx(c, 10, 10, 0xECE0C4); APPx(c, 12, 12, 0xECE0C4);
        APOutlineInside(c, 0x4A2E14);
        APShadow(c, 0, 17, 16, 5);
    });
    basket.walkable = YES;
    basket.petBed = YES;
    basket.sleepX = 8; basket.sleepY = 13;
    [items addObject:basket];

    APItemSpec *tent = APSpec(@"petbed.tent", @"Pet Teepee", APLayerFloor, APCategoryCosy, 2, 1, 22,
                              @[@"Canvas", @"Mint", @"Blush"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp r = APRampNamed(ctx.variant == 1 ? @"teal" : ctx.variant == 2 ? @"rose" : @"cream");
        int H = ctx.height; // 38
        APRamp wood = APRampNamed(@"oak");
        APLine(c, 10, 0, 16, 7, wood.m); APLine(c, 22, 0, 16, 7, wood.m); APLine(c, 16, 0, 16, 6, wood.l);
        for (int y = 5; y < H - 3; y++) {
            float t = (y - 5) / (float)(H - 8);
            int half = (int)(2 + t * 13);
            APHLine(c, 16 - half, y, half * 2, r.l);
            APPx(c, 16 - half, y, r.m); APPx(c, 16 + half - 1, y, r.m);
        }
        // Door flap.
        for (int y = 16; y < H - 3; y++) {
            int half = (y - 16) / 2 + 1;
            APHLine(c, 16 - half, y, half * 2, 0x3A2A22);
        }
        APLine(c, 16, 16, 9, H - 4, r.h);
        APRect(c, 13, H - 7, 6, 3, 0xECE0C4);
        // Bunting.
        uint32_t flags[] = {0xE06A5A, 0xF0C050, 0x6AA0C8, 0x7AB07A};
        for (int i = 0; i < 4; i++) {
            int fx = 8 + i * 4, fy = 13;
            APHLine(c, fx, fy, 3, flags[i]); APPx(c, fx + 1, fy + 1, flags[i]);
        }
        APHLine(c, 7, 12, 18, 0x8A6A4A);
        APOutlineInside(c, r.o);
        APShadow(c, 1, H - 5, 30, 6);
    });
    tent.petBed = YES;
    tent.walkable = YES;
    tent.sleepX = 16; tent.sleepY = 34;
    [items addObject:tent];
}

static void APRegisterTables(NSMutableArray *items) {
    NSArray *woods = @[@"oak", @"walnut", @"white"];
    [items addObject:APSpec(@"table.coffee", @"Coffee Table", APLayerFloor, APCategoryFurniture, 2, 1, 8,
                            @[@"Oak", @"Walnut", @"Painted White"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(woods[ctx.variant % 3]);
        int H = ctx.height; // 24
        APRect(c, 2, 17, 2, 5, w.d); APRect(c, 28, 17, 2, 5, w.d);
        APRect(c, 1, 5, 30, 10, w.l);
        APHLine(c, 1, 5, 30, w.h);
        for (int x = 4; x < 29; x += 7) APHLine(c, x, 8 + (x % 3), 3, w.m);
        APRect(c, 1, 15, 30, 3, w.m);
        APHLine(c, 1, 17, 30, w.d);
        APOutlineInside(c, w.o);
        // Tabletop still-life.
        APMug(ctx, 5, 11, 0xECE0C4);
        APRect(c, 17, 7, 9, 2, 0x6076AA); APHLine(c, 17, 7, 9, 0x8AA0C8);
        APRect(c, 18, 9, 8, 2, 0xA85432); APHLine(c, 18, 9, 8, 0xC87444);
        APPx(c, 25, 7, 0xF8F4EC);
        APShadow(c, 0, H - 4, 32, 5);
    })];

    APItemSpec *side = APSpec(@"table.lantern", @"Lantern Table", APLayerFloor, APCategoryCosy, 1, 1, 14,
                              @[@"Oak", @"Walnut", @"Painted White"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(woods[ctx.variant % 3]);
        int H = ctx.height; // 30
        APEllipse(c, 1, 12, 14, 6, w.l);
        APHLine(c, 3, 12, 10, w.h);
        APRect(c, 7, 17, 2, 9, w.m);
        APRect(c, 4, 25, 8, 2, w.d);
        // Glass lantern.
        APRect(c, 5, 5, 6, 8, 0x3E3E48);
        APRect(c, 6, 6, 4, 6, 0x6A6A70);
        APRect(c, 6, 3, 4, 2, 0x3E3E48); APPx(c, 7, 2, 0x3E3E48); APPx(c, 8, 1, 0x3E3E48);
        APOutlineInside(c, w.o);
        if (ctx.on) {
            APRect(ctx.emissive, 6, 7, 4, 5, 0xF8C860);
            APRect(ctx.emissive, 7, 9, 2, 3, 0xFFF0B0);
            [ctx addAnim:[APAnim kind:APAnimCandle x:7 y:8 w:1 h:2]];
            APAnim *glow = [APAnim kind:APAnimGlow x:8 y:9 w:0 h:0];
            glow.size = 12; glow.color = 0xFFC060;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:8 y:9 radius:34 color:0xFFB860 strength:0.55f]];
        }
        APShadow(c, 1, H - 5, 14, 5);
    });
    side.toggleable = YES;
    [items addObject:side];

    APItemSpec *record = APSpec(@"record", @"Record Player", APLayerFloor, APCategoryFurniture, 1, 1, 14,
                                @[@"Walnut", @"Teal"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"teal" : @"walnut");
        int H = ctx.height; // 30
        APRect(c, 1, 14, 14, 12, w.m);
        APRect(c, 1, 11, 14, 4, w.l);
        APHLine(c, 1, 11, 14, w.h);
        APRect(c, 3, 17, 10, 7, w.d);
        APVLine(c, 8, 17, 7, w.m);
        APPx(c, 6, 20, w.h); APPx(c, 10, 20, w.h);
        APRect(c, 2, 26, 2, 2, 0x24160E); APRect(c, 12, 26, 2, 2, 0x24160E);
        // Turntable.
        APEllipse(c, 2, 6, 10, 6, 0x1A1A1E);
        APEllipse(c, 5, 7, 4, 3, ctx.variant ? 0xE8BE48 : 0xC44A44);
        APHLine(c, 3, 7, 3, 0x3E3E48);
        APLine(c, 13, 5, 10, 9, 0xBEB4A6);
        APRect(c, 12, 4, 2, 2, 0x9E9488);
        APOutlineInside(c, w.o);
        if (ctx.on) [ctx addAnim:[APAnim kind:APAnimNotes x:9 y:4 w:1 h:1]];
        APShadow(c, 0, H - 4, 16, 5);
    });
    record.toggleable = YES;
    [items addObject:record];
}

static void APRegisterLamps(NSMutableArray *items) {
    NSArray *shades = @[@"cream", @"mustard", @"sage", @"rose"];
    APItemSpec *lamp = APSpec(@"lamp.floor", @"Floor Lamp", APLayerFloor, APCategoryCosy, 1, 1, 40,
                              @[@"Cream Shade", @"Mustard Shade", @"Sage Shade", @"Rose Shade"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp shade = APRampNamed(shades[ctx.variant % shades.count]);
        APRamp brass = APRampNamed(@"gold");
        int H = ctx.height; // 56
        APVLine(c, 7, 15, H - 22, brass.m);
        APVLine(c, 8, 15, H - 22, brass.d);
        APEllipse(c, 3, H - 9, 10, 5, 0x2A2A30);
        APHLine(c, 5, H - 9, 6, 0x56566A);
        for (int y = 2; y < 16; y++) {
            int half = 5 + (y - 2) * 3 / 13;
            APHLine(c, 8 - half, y, half * 2, shade.m);
            APPx(c, 8 - half, y, shade.d); APPx(c, 8 + half - 1, y, shade.d);
        }
        APHLine(c, 3, 2, 10, shade.l);
        APOutlineInside(c, shade.o);
        if (ctx.on) {
            // The shade glows from within; the underside spills light.
            for (int y = 3; y < 15; y++) {
                int half = 4 + (y - 2) * 3 / 13;
                for (int x = 8 - half; x < 8 + half; x++) {
                    float t = fabsf(x - 7.5f) / half;
                    APPx(ctx.emissive, x, y, t < 0.45f ? 0xFFE8B0 : t < 0.8f ? APMix(shade.h, 0xFFD890, 0.6f) : APMix(shade.l, 0xF0B060, 0.5f));
                }
            }
            APHLine(ctx.emissive, 2, 15, 12, 0xFFF4CC);
            APAnim *glow = [APAnim kind:APAnimGlow x:8 y:12 w:0 h:0];
            glow.size = 22; glow.color = 0xFFC878;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:8 y:14 radius:64 color:0xFFC070 strength:0.8f]];
        }
        APShadow(c, 1, H - 6, 14, 5);
    });
    lamp.toggleable = YES;
    [items addObject:lamp];
}

static void APRegisterPlants(NSMutableArray *items) {
    [items addObject:APSpec(@"plant.monstera", @"Monstera", APLayerFloor, APCategoryCosy, 1, 1, 22,
                            @[@"Terracotta", @"White Pot", @"Woven Pot"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp pot = APRampNamed(ctx.variant == 1 ? @"white" : ctx.variant == 2 ? @"mustard" : @"terracotta");
        APRamp leaf = APRampNamed(@"leaf");
        int H = ctx.height; // 38
        APRect(c, 3, H - 13, 10, 10, pot.m);
        APRect(c, 2, H - 14, 12, 3, pot.l);
        APHLine(c, 2, H - 14, 12, pot.h);
        APVLine(c, 11, H - 11, 8, pot.d);
        if (ctx.variant == 2) for (int y = H - 11; y < H - 3; y += 2) APHLine(c, 3, y, 10, pot.d);
        // Stems then leaves, back to front.
        APLine(c, 8, H - 14, 3, 10, leaf.d); APLine(c, 8, H - 14, 13, 8, leaf.d); APLine(c, 8, H - 14, 8, 3, leaf.d);
        APLeaf(c, 0, 6, 8, 9, leaf, YES);
        APLeaf(c, 9, 4, 7, 9, leaf, YES);
        APLeaf(c, 4, 0, 8, 8, leaf, YES);
        APLeaf(c, 2, 13, 7, 8, leaf, NO);
        APLeaf(c, 9, 12, 7, 8, leaf, YES);
        APOutlineInside(c, leaf.o);
        for (int y = H - 14; y < H - 3; y++) { APPx(c, 2, y, pot.o); APPx(c, 13, y, pot.o); }
        APShadow(c, 1, H - 5, 14, 5);
    })];
    [items addObject:APSpec(@"plant.fig", @"Fiddle-Leaf Fig", APLayerFloor, APCategoryCosy, 1, 1, 34,
                            @[@"Basket", @"Terracotta"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp pot = APRampNamed(ctx.variant ? @"terracotta" : @"cream");
        APRamp leaf = APRampNamed(@"leaf");
        int H = ctx.height; // 50
        APRect(c, 3, H - 12, 10, 9, pot.m);
        APRect(c, 2, H - 13, 12, 2, pot.l);
        if (!ctx.variant) for (int y = H - 11; y < H - 3; y += 2) APHLine(c, 3, y, 10, pot.d);
        APVLine(c, 8, 8, H - 20, 0x6A4A2A);
        APVLine(c, 7, 20, H - 32, 0x5A3A22);
        int ys[] = {2, 7, 12, 17, 22, 27};
        for (int i = 0; i < 6; i++) {
            int side = i % 2;
            APLeaf(c, side ? 8 : 1, ys[i], 7, 7, leaf, NO);
        }
        APLeaf(c, 4, 0, 7, 6, leaf, NO);
        APOutlineInside(c, leaf.o);
        APShadow(c, 1, H - 5, 14, 5);
    })];
    [items addObject:APSpec(@"plant.cactus", @"Little Cactus", APLayerFloor, APCategoryCosy, 1, 1, 8,
                            @[@"Flowering", @"Plain"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp pot = APRampNamed(@"terracotta");
        int H = ctx.height; // 24
        APRect(c, 4, H - 10, 8, 7, pot.m);
        APRect(c, 3, H - 11, 10, 2, pot.l);
        APRoundRect(c, 6, 4, 5, H - 14, 0x5E8A3C);
        APVLine(c, 7, 5, H - 16, 0x86B052);
        APRoundRect(c, 3, 8, 3, 5, 0x5E8A3C); APRect(c, 5, 11, 1, 2, 0x5E8A3C);
        APRoundRect(c, 11, 6, 3, 5, 0x5E8A3C); APRect(c, 11, 9, 1, 2, 0x5E8A3C);
        if (ctx.variant == 0) { APPx(c, 8, 3, 0xE87A9A); APPx(c, 7, 3, 0xF0A0B8); APPx(c, 9, 3, 0xF0A0B8); APPx(c, 8, 2, 0xF0A0B8); }
        APOutlineInside(c, 0x1E3018);
        APShadow(c, 2, H - 5, 12, 5);
    })];
}

static void APRegisterStorage(NSMutableArray *items) {
    NSArray *woods = @[@"oak", @"walnut", @"white"];
    APItemSpec *shelf = APSpec(@"bookshelf", @"Bookshelf", APLayerFloor, APCategoryFurniture, 2, 1, 40,
                               @[@"Oak", @"Walnut", @"Painted White"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(woods[ctx.variant % 3]);
        int H = ctx.height; // 56
        APRect(c, 1, 4, 30, H - 8, w.d);
        APRect(c, 1, 4, 2, H - 8, w.m); APRect(c, 29, 4, 2, H - 8, w.m);
        APRect(c, 0, 3, 32, 3, w.l); APHLine(c, 0, 3, 32, w.h);
        APRand r = {0xB00C};
        uint32_t spines[] = {0xA85432, 0x6076AA, 0xDCB04A, 0x6A8A64, 0xCC8498, 0xECE0C4, 0x4E4270, 0x347A72};
        int shelves[] = {6, 19, 32, 45};
        for (int s = 0; s < 3; s++) {
            int top = shelves[s], bottom = shelves[s + 1] - 2;
            APRect(c, 3, bottom, 26, 2, w.l); APHLine(c, 3, bottom, 26, w.h);
            APRect(c, 3, top, 26, bottom - top, APShade(w.d, 0.7f));
            for (int x = 3; x < 28; ) {
                int bw = APRandInt(&r, 2, 3), bh = APRandInt(&r, bottom - top - 6, bottom - top - 1);
                if (APRandInt(&r, 0, 9) == 0 && x < 22) {
                    // a little ornament instead of a book
                    APRect(c, x + 1, bottom - 4, 4, 4, 0xB0643A); APPx(c, x + 2, bottom - 6, 0x5E8A3C);
                    APPx(c, x + 3, bottom - 7, 0x86B052); APPx(c, x + 4, bottom - 6, 0x5E8A3C);
                    x += 6; continue;
                }
                if (x + bw > 29) break;
                uint32_t col = spines[APRandInt(&r, 0, 7)];
                APRect(c, x, bottom - bh, bw, bh, col);
                APVLine(c, x, bottom - bh, bh, APShade(col, 1.15f));
                APHLine(c, x, bottom - bh + 2, bw, APShade(col, 0.75f));
                x += bw;
            }
        }
        APRect(c, 1, H - 5, 30, 2, w.m);
        // A trailing plant on top.
        APRect(c, 22, 0, 5, 3, 0xB0643A);
        APPx(c, 23, -1 + 1, 0x5E8A3C); APPx(c, 21, 1, 0x5E8A3C); APPx(c, 27, 2, 0x5E8A3C);
        APVLine(c, 28, 3, 6, 0x5E8A3C); APPx(c, 29, 6, 0x86B052); APPx(c, 27, 8, 0x86B052);
        APOutlineInside(c, w.o);
        APShadow(c, 0, H - 4, 32, 5);
    });
    shelf.backWall = YES;
    [items addObject:shelf];

    [items addObject:APSpec(@"logbasket", @"Log Basket", APLayerFloor, APCategoryCosy, 1, 1, 6, @[@"Wicker"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 22
        // Logs poking out.
        for (int i = 0; i < 3; i++) {
            int lx = 3 + i * 4, ly = 3 + (i % 2) * 2;
            APRect(c, lx, ly, 3, 8, 0x6A4228); APVLine(c, lx, ly, 8, 0x8A5A36);
            APRect(c, lx, ly, 3, 2, 0xC89A6A); APPx(c, lx + 1, ly, 0x8A5A36);
        }
        APRect(c, 1, 9, 14, 10, 0xA87A48);
        for (int y = 10; y < 19; y++) for (int x = 1; x < 15; x++) if (((x + (y / 2) * 2) % 4) < 2) APPx(c, x, y, 0xD0A870);
        APHLine(c, 1, 9, 14, 0xE0B880);
        APRect(c, 0, 11, 1, 3, 0x7A5028); APRect(c, 15, 11, 1, 3, 0x7A5028);
        APOutlineInside(c, 0x4A2E14);
        APShadow(c, 0, H - 5, 16, 5);
    })];

    // Moving boxes: what every new home starts with. Put them away and make
    // it yours (or keep them; Pals love a box).
    [items addObject:APSpec(@"boxes", @"Moving Boxes", APLayerFloor, APCategoryCosy, 1, 1, 8, @[@"Cardboard"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 24
        // The big box on the floor.
        APRect(c, 0, H - 14, 16, 11, 0xC8965A);
        APRect(c, 0, H - 14, 16, 2, 0xD8AA70);   // lid
        APRect(c, 7, H - 14, 2, 11, 0xE8D8A8);   // tape
        APRect(c, 0, H - 7, 16, 4, 0xB8864C);    // shaded front
        APRect(c, 7, H - 7, 2, 4, 0xD4C494);
        APHLine(c, 2, H - 10, 3, 0x6A4A2A);      // scribble ("KITCHEN")
        APHLine(c, 11, H - 10, 3, 0x6A4A2A);
        // A smaller one on top, a little askew.
        APRect(c, 3, H - 22, 11, 8, 0xD0A064);
        APRect(c, 3, H - 22, 11, 2, 0xE0B478);
        APRect(c, 8, H - 22, 2, 8, 0xE8D8A8);
        APRect(c, 3, H - 17, 11, 3, 0xB88A50);
        APPx(c, 5, H - 19, 0xC84A3A); APPx(c, 6, H - 19, 0xC84A3A); // a red "this way up"
        APOutlineInside(c, 0x4A3018);
        APShadow(c, 0, H - 5, 16, 5);
    })];

    APItemSpec *bowl = APSpec(@"bowls", @"Food & Water", APLayerFloor, APCategoryCosy, 1, 1, 0, @[@"Ceramic"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APEllipse(c, 0, 6, 8, 5, 0xC44A44); APEllipse(c, 1, 6, 6, 3, 0x8A5A36);
        APPx(c, 2, 7, 0xA8744A); APPx(c, 4, 7, 0xC8966A);
        APEllipse(c, 8, 8, 8, 5, 0x6076AA); APEllipse(c, 9, 8, 6, 3, 0x8CC4E8); APPx(c, 11, 8, 0xE0F0FA);
        APOutlineInside(c, 0x2A1A14);
        APShadow(c, 0, 11, 16, 4);
    });
    bowl.walkable = YES;
    [items addObject:bowl];

    [items addObject:APSpec(@"yarn", @"Yarn Basket", APLayerFloor, APCategoryCosy, 1, 1, 4, @[@"Wicker"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 20
        uint32_t balls[] = {0xCC8498, 0x6A8A64, 0xDCB04A};
        for (int i = 0; i < 3; i++) {
            int bx = 2 + i * 4, by = 3 + (i == 1 ? -1 : 1);
            APCircle(c, bx + 2, by + 3, 2, balls[i]);
            APPx(c, bx + 1, by + 2, APShade(balls[i], 1.2f));
            APPx(c, bx + 3, by + 4, APShade(balls[i], 0.8f));
        }
        APLine(c, 9, 8, 14, 12, 0xCC8498);
        APRect(c, 1, 8, 14, 9, 0xA87A48);
        for (int y = 9; y < 17; y++) for (int x = 1; x < 15; x++) if (((x + (y / 2) * 2) % 4) < 2) APPx(c, x, y, 0xD0A870);
        APOutlineInside(c, 0x4A2E14);
        APShadow(c, 0, H - 5, 16, 5);
    })];
}

#pragma mark - Rugs

static void APRegisterRugs(NSMutableArray *items) {
    NSArray *rampNames = @[@"sage", @"rose", @"navy", @"mustard", @"lavender"];
    [items addObject:APSpec(@"rug.round", @"Braided Rug", APLayerRug, APCategoryRugs, 4, 3, 0,
                            @[@"Sage", @"Rose", @"Ocean", @"Mustard", @"Lavender"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp r = APRampNamed(rampNames[ctx.variant % rampNames.count]);
        APRamp cream = APRampNamed(@"cream");
        uint32_t rings[] = {r.d, r.m, cream.l, r.m, r.l, cream.h, r.l, r.h};
        for (int i = 0; i < 8; i++) {
            int inset = i * 3;
            if (inset * 2 >= 44) break;
            APEllipse(c, 1 + inset, 2 + inset * 2 / 3, 62 - inset * 2, 44 - inset * 4 / 3, rings[i]);
        }
        // Braid texture on the outer rings.
        for (int y = 0; y < c->h; y++) for (int x = 0; x < c->w; x++) {
            if (APOpaqueAt(c, x, y) && (x + y * 2) % 5 == 0) APPx(c, x, y, APShade(APGet(c, x, y), 0.9f));
        }
        APOutlineInside(c, r.o);
    })];
    [items addObject:APSpec(@"rug.woven", @"Woven Rug", APLayerRug, APCategoryRugs, 4, 3, 0,
                            @[@"Persian", @"Kilim", @"Indigo"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t field, border, accent, light;
        switch (ctx.variant) {
            case 1: field = 0xB8664A; border = 0x2E5A56; accent = 0xE8B860; light = 0xECE0C4; break;
            case 2: field = 0x2E3A5E; border = 0xC8B890; accent = 0x9E2E30; light = 0xE8E0D0; break;
            default: field = 0x8E2A2A; border = 0x2E3A5E; accent = 0xE0B058; light = 0xECE0C4; break;
        }
        int x0 = 4, y0 = 3, w = 56, h = 42;
        APRect(c, x0, y0, w, h, border);
        APRect(c, x0 + 4, y0 + 3, w - 8, h - 6, field);
        // Zig-zag border.
        for (int x = x0 + 1; x < x0 + w - 1; x++) {
            int zz = (x / 2) % 2;
            APPx(c, x, y0 + 1 + zz, accent); APPx(c, x, y0 + h - 2 - zz, accent);
        }
        for (int y = y0 + 1; y < y0 + h - 1; y++) {
            int zz = (y / 2) % 2;
            APPx(c, x0 + 1 + zz, y, accent); APPx(c, x0 + w - 2 - zz, y, accent);
        }
        // Medallion.
        int cx = x0 + w / 2, cy = y0 + h / 2;
        for (int y = -10; y <= 10; y++) for (int x = -18; x <= 18; x++) {
            int d = abs(x) / 2 + abs(y);
            if (d == 9 || d == 5) APPx(c, cx + x, cy + y, accent);
            else if (d < 3) APPx(c, cx + x, cy + y, light);
            else if (d == 7) APPx(c, cx + x, cy + y, APShade(field, 0.75f));
        }
        for (int i = 0; i < 4; i++) {
            int dx = i % 2 ? 1 : -1, dy = i / 2 ? 1 : -1;
            APCircle(c, cx + dx * 20, cy + dy * 12, 2, light);
            APPx(c, cx + dx * 20, cy + dy * 12, accent);
        }
        // Fringe.
        for (int y = y0 + 1; y < y0 + h - 1; y += 2) {
            APHLine(c, x0 - 3, y, 3, light); APHLine(c, x0 + w, y, 3, light);
        }
    })];
    APItemSpec *sheep = APSpec(@"rug.sheepskin", @"Sheepskin", APLayerRug, APCategoryRugs, 2, 1, 0,
                               @[@"Cream", @"Oat", @"Charcoal"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t base = ctx.variant == 2 ? 0x56566A : ctx.variant == 1 ? 0xD8C0A0 : 0xF0E8DA;
        APEllipse(c, 2, 2, 28, 13, base);
        APEllipse(c, 0, 5, 6, 6, base); APEllipse(c, 26, 5, 6, 6, base);
        APEllipse(c, 6, 0, 6, 5, base); APEllipse(c, 20, 0, 6, 5, base);
        APEllipse(c, 6, 11, 6, 5, base); APEllipse(c, 20, 11, 6, 5, base);
        for (int y = 0; y < 16; y++) for (int x = 0; x < 32; x++) {
            if (!APOpaqueAt(c, x, y)) continue;
            if ((x * 3 + y * 5) % 7 == 0) APPx(c, x, y, APShade(base, 0.9f));
            else if ((x * 5 + y * 3) % 11 == 0) APPx(c, x, y, APShade(base, 1.06f));
        }
        APOutlineInside(c, APShade(base, 0.72f));
    });
    [items addObject:sheep];
    [items addObject:APSpec(@"rug.checker", @"Picnic Mat", APLayerRug, APCategoryRugs, 2, 2, 0,
                            @[@"Cherry", @"Sky", @"Meadow"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp r = APRampNamed(ctx.variant == 1 ? @"navy" : ctx.variant == 2 ? @"sage" : @"red");
        for (int y = 2; y < 30; y++) for (int x = 2; x < 30; x++) {
            BOOL a = (x / 4) % 2, b = (y / 4) % 2;
            APPx(c, x, y, a && b ? r.m : (a || b) ? r.l : 0xF8F4EC);
        }
        APOutlineInside(c, r.d);
    })];
}

void APRegisterFurniture(NSMutableArray<APItemSpec *> *items) {
    APRegisterHearths(items);
    APRegisterSeating(items);
    APRegisterTables(items);
    APRegisterLamps(items);
    APRegisterPlants(items);
    APRegisterStorage(items);
    APRegisterPetBeds(items);
    APRegisterRugs(items);
}
