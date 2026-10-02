#import "ApolloPalHomeCatalog.h"
#import <math.h>

// Furniture and surfaces for the home styles (castle, library, space station,
// saloon, treehouse, under the sea). Everything joins the shared catalogue,
// so pieces mix freely between styles.

static void APGlowAnim(APDrawContext *ctx, int x, int y, int size, uint32_t colour, int pulse) {
    APAnim *glow = [APAnim kind:APAnimGlow x:x y:y w:0 h:0];
    glow.size = size;
    glow.color = colour;
    glow.variant = pulse;
    [ctx addAnim:glow];
}

static void APBlink(APDrawContext *ctx, int x, int y, uint32_t colour) {
    APPx(ctx.emissive, x, y, colour);
    APAnim *blink = [APAnim kind:APAnimBlink x:x y:y w:1 h:1];
    blink.color = colour;
    [ctx addAnim:blink];
}

// Four toe beans and a pad: the household crest.
static void APPawCrest(APCanvas *c, int cx, int cy, uint32_t colour) {
    APPx(c, cx - 2, cy - 2, colour); APPx(c, cx, cy - 3, colour); APPx(c, cx + 2, cy - 2, colour);
    APPx(c, cx - 1, cy - 3, colour); APPx(c, cx + 1, cy - 3, colour);
    APRect(c, cx - 1, cy - 1, 3, 2, colour);
    APPx(c, cx - 3, cy - 1, colour); APPx(c, cx + 3, cy - 1, colour);
}

#pragma mark - Castle

static void APRegisterCastle(NSMutableArray *items) {
    NSArray *velvets = @[@"red", @"navy", @"sage", @"lavender"];
    APItemSpec *throne = APSpec(@"throne", @"Throne", APLayerFloor, APCategoryFurniture, 2, 1, 26,
                            @[@"Royal Red", @"Sapphire", @"Emerald", @"Amethyst"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp v = APRampNamed(velvets[ctx.variant % velvets.count]);
        APRamp g = APRampNamed(@"gold");
        int H = ctx.height; // 42
        // Crown finials over a tall arched back.
        for (int i = 0; i < 3; i++) { APRect(c, 9 + i * 6, 2, 2, 3, g.l); APPx(c, 10 + i * 6, 1, g.h); APPx(c, 10 + i * 6, 0, 0xC44A44); }
        APRoundRect(c, 7, 4, 18, 26, g.m);
        APRect(c, 9, 6, 14, 22, v.m);
        APRect(c, 10, 6, 12, 2, v.l);
        for (int y = 9; y < 27; y += 5) for (int x = 11; x < 22; x += 5) APPx(c, x, y, v.d);
        APPawCrest(c, 16, 15, g.l);
        // Arms, seat, base.
        for (int side = 0; side < 2; side++) {
            int ax = side ? 24 : 2;
            APRoundRect(c, ax, 17, 6, 15, g.m);
            APHLine(c, ax + 1, 17, 4, g.h);
            APRect(c, ax + 1, 19, 4, 3, v.m);
        }
        APRect(c, 6, 26, 20, 5, v.l);
        APHLine(c, 6, 26, 20, v.h);
        APRect(c, 5, 31, 22, 4, g.m);
        APHLine(c, 5, 31, 22, g.h);
        APRect(c, 4, 35, 3, 4, g.d); APRect(c, 25, 35, 3, 4, g.d);
        APPx(c, 16, 33, 0xC44A44);
        APOutlineInside(c, g.o);
        APShadow(c, 1, H - 5, 30, 5);
    });
    throne.seat = YES; throne.seatX = 16; throne.seatY = 30;
    [items addObject:throne];

    [items addObject:APSpec(@"armour", @"Suit of Armour", APLayerFloor, APCategoryFurniture, 1, 1, 34,
                            @[@"Steel", @"Gilded", @"Blackened"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp m = APRampNamed(ctx.variant == 1 ? @"gold" : ctx.variant == 2 ? @"iron" : @"stone");
        if (ctx.variant == 0) m = (APRamp){0x2A2A30, 0x6A6E78, 0x9AA0AA, 0xC4CAD2, 0xEEF2F6};
        int H = ctx.height; // 50
        // Halberd behind.
        APVLine(c, 14, 3, H - 6, 0x6A4228);
        APRect(c, 12, 2, 3, 5, m.l); APPx(c, 15, 4, m.l); APPx(c, 14, 0, m.h); APPx(c, 14, 1, m.l);
        APRect(c, 5, 0, 5, 3, 0xC44A44); APPx(c, 4, 1, 0xC44A44); // plume
        APRoundRect(c, 4, 3, 7, 9, m.m);
        APHLine(c, 5, 7, 5, m.o);  // visor slit
        APVLine(c, 5, 4, 7, m.h);
        APRoundRect(c, 3, 12, 9, 13, m.m);
        APVLine(c, 4, 13, 10, m.h);
        APHLine(c, 4, 18, 7, m.d);
        APRect(c, 1, 13, 2, 10, m.l); APRect(c, 12, 13, 2, 10, m.l); // arms
        APRect(c, 12, 22, 3, 2, m.d); // gauntlet on halberd
        APRect(c, 4, 25, 3, 15, m.m); APRect(c, 8, 25, 3, 15, m.m);
        APVLine(c, 4, 26, 13, m.h); APVLine(c, 8, 26, 13, m.h);
        APRect(c, 3, 39, 4, 2, m.d); APRect(c, 8, 39, 4, 2, m.d);
        APRect(c, 2, 41, 12, 4, 0x6A4228); APHLine(c, 2, 41, 12, 0x8A5A36);
        APOutlineInside(c, m.o);
        APShadow(c, 1, H - 6, 14, 5);
    })];

    APItemSpec *chest = APSpec(@"chest", @"Treasure Chest", APLayerFloor, APCategoryCosy, 1, 1, 8,
                               @[@"Oak & Iron", @"Barnacled"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"teal" : @"oak");
        int H = ctx.height; // 24
        // Lid propped open with treasure spilling.
        APRect(c, 2, 2, 12, 5, w.d);
        APHLine(c, 2, 2, 12, w.m);
        APRect(c, 3, 6, 10, 3, 0xE8BE48);
        for (int x = 3; x < 13; x += 2) APPx(c, x, 6, 0xFCE69A);
        APPx(c, 6, 5, 0xC44A44); APPx(c, 10, 5, 0x5A8AE0);
        APRect(c, 1, 9, 14, 10, w.m);
        APHLine(c, 1, 9, 14, w.l);
        APVLine(c, 3, 9, 10, 0x3E3E48); APVLine(c, 12, 9, 10, 0x3E3E48);
        APRect(c, 7, 11, 2, 3, 0xE8BE48);
        if (ctx.variant) { APPx(c, 2, 16, 0xE8E0D0); APPx(c, 13, 12, 0xE8E0D0); APPx(c, 5, 18, 0x86B052); }
        APOutlineInside(c, w.o);
        APPx(ctx.emissive, 5, 6, 0xFFF8D0); APPx(ctx.emissive, 11, 7, 0xFFF8D0); // glints
        APShadow(c, 0, H - 5, 16, 5);
    });
    [items addObject:chest];

    APItemSpec *royal = APSpec(@"petbed.royal", @"Royal Cushion", APLayerFloor, APCategoryCosy, 1, 1, 4,
                               @[@"Purple", @"Crimson", @"Teal"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp v = APRampNamed(ctx.variant == 1 ? @"red" : ctx.variant == 2 ? @"teal" : @"lavender");
        APRamp g = APRampNamed(@"gold");
        APRoundRect(c, 1, 6, 14, 12, v.m);
        APRect(c, 2, 7, 12, 4, v.l);
        APHLine(c, 3, 7, 10, v.h);
        APPx(c, 8, 12, v.d); APPx(c, 5, 10, v.d); APPx(c, 11, 10, v.d);
        int corners[4][2] = {{0, 5}, {15, 5}, {0, 17}, {15, 17}};
        for (int i = 0; i < 4; i++) { APPx(c, corners[i][0], corners[i][1], g.l); APPx(c, corners[i][0], corners[i][1] + 1, g.m); }
        APOutlineInside(c, v.o);
        // A tiny crown resting on top.
        APRect(c, 6, 3, 5, 2, g.l); APPx(c, 6, 2, g.h); APPx(c, 8, 1, g.h); APPx(c, 10, 2, g.h);
        APShadow(c, 0, 16, 16, 5);
    });
    royal.petBed = YES;
    royal.walkable = YES;
    royal.sleepX = 8; royal.sleepY = 15;
    [items addObject:royal];

    NSArray *cloths = @[@"red", @"navy", @"sage", @"lavender"];
    [items addObject:APSpec(@"banner", @"Heraldic Banner", APLayerWall, APCategoryWall, 1, 2, 0,
                            @[@"Crimson", @"Azure", @"Verdant", @"Royal Purple"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp v = APRampNamed(cloths[ctx.variant % cloths.count]);
        APRamp g = APRampNamed(@"gold");
        APHLine(c, 1, 1, 14, 0x6A4228); APPx(c, 0, 1, g.l); APPx(c, 15, 1, g.l);
        for (int y = 2; y < 30; y++) {
            int cut = y > 23 ? (y - 23) : 0; // swallowtail
            for (int x = 3; x < 13; x++) {
                if (cut && x >= 8 - cut && x < 8 + cut) continue;
                APPx(c, x, y, x == 3 || x == 12 ? g.m : (x < 5 ? v.l : v.m));
            }
        }
        APPawCrest(c, 8, 13, g.l);
        APHLine(c, 5, 6, 6, g.m);
        APPaintingShadowRect(c, 3, 2, 10, 22);
    })];

    APItemSpec *torch = APSpec(@"torch", @"Wall Torch", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Iron"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRect(c, 6, 11, 4, 2, 0x3E3E48); APRect(c, 7, 13, 2, 2, 0x2A2A30);
        APRect(c, 7, 6, 2, 6, 0x6A4228); APVLine(c, 7, 6, 6, 0x8A5A36);
        APRect(c, 6, 5, 4, 2, 0x3E3E48);
        if (ctx.on) {
            [ctx addAnim:[APAnim kind:APAnimFire x:5 y:0 w:6 h:6]];
            APGlowAnim(ctx, 8, 3, 18, 0xFF9A48, 0);
            [ctx addLight:[APLight x:8 y:4 radius:52 color:0xFFA050 strength:0.7f]];
        }
        APPaintingShadowRect(c, 6, 5, 4, 8);
    });
    torch.toggleable = YES;
    [items addObject:torch];

    [items addObject:APSpec(@"tapestry", @"Dragon Tapestry", APLayerWall, APCategoryArt, 2, 2, 0, @[@"Crimson", @"Forest"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t border = ctx.variant ? 0x2E4A30 : 0x7A1E22, field = ctx.variant ? 0x5A7A4A : 0xB88A5A;
        APHLine(c, 1, 1, 30, 0x6A4228);
        APRect(c, 3, 2, 26, 27, border);
        APRect(c, 5, 4, 22, 23, field);
        APDitherRect(c, 5, 4, 22, 23, APShade(field, 0.9f), 0.3f);
        for (int x = 3; x < 29; x += 2) APPx(c, x, 29, border);
        // Castle tower and a friendly dragon.
        APRect(c, 7, 12, 5, 13, 0x8E8478); APRect(c, 7, 10, 1, 2, 0x8E8478); APRect(c, 9, 10, 1, 2, 0x8E8478); APRect(c, 11, 10, 1, 2, 0x8E8478);
        APRect(c, 9, 16, 1, 2, 0x2A2020);
        APRect(c, 5, 24, 22, 3, 0x6A8A4A);
        APEllipse(c, 15, 12, 9, 5, 0x3E7A3E);
        APRect(c, 22, 10, 3, 3, 0x3E7A3E); APPx(c, 24, 10, 0xF2C860);
        APLine(c, 16, 13, 13, 9, 0x2E5A2E); APLine(c, 18, 12, 19, 7, 0x2E5A2E); APLine(c, 19, 7, 21, 10, 0x2E5A2E);
        APPx(c, 25, 11, 0xF08A30); APPx(c, 26, 11, 0xFCC846);
        APPaintingShadowRect(c, 3, 2, 26, 27);
    })];
}

#pragma mark - Library

static void APRegisterLibrary(NSMutableArray *items) {
    [items addObject:APSpec(@"globe", @"Globe", APLayerFloor, APCategoryCosy, 1, 1, 18, @[@"Antique", @"Night Sky"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 34
        APRamp w = APRampNamed(@"walnut");
        APLine(c, 8, 24, 3, 31, w.m); APLine(c, 8, 24, 13, 31, w.m); APVLine(c, 8, 24, 8, w.d);
        APCircle(c, 8, 13, 6, ctx.variant ? 0x1E2A5A : 0x4A7AA8);
        if (ctx.variant) {
            APPx(c, 6, 10, 0xF2E6B0); APPx(c, 10, 13, 0xF2E6B0); APPx(c, 7, 16, 0xF2E6B0); APPx(c, 11, 9, 0xF2E6B0);
            APLine(c, 6, 10, 10, 13, 0x6A7AB0);
        } else {
            APEllipse(c, 4, 9, 5, 4, 0x8AAA5A); APEllipse(c, 9, 13, 4, 5, 0xC8A870); APPx(c, 11, 9, 0x8AAA5A);
        }
        APPx(c, 5, 10, 0xE0ECF4);
        APEllipseOutline(c, 1, 6, 15, 15, 0xC8962A);
        APPx(c, 8, 5, 0xC8962A); APPx(c, 8, 21, 0xC8962A);
        APRect(c, 6, 22, 5, 2, w.l);
        APOutlineInside(c, w.o);
        APShadow(c, 1, H - 5, 14, 5);
    })];

    APItemSpec *desk = APSpec(@"desk", @"Writing Desk", APLayerFloor, APCategoryFurniture, 2, 1, 20, @[@"Walnut", @"Oak"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"oak" : @"walnut");
        int H = ctx.height; // 36
        APRect(c, 1, 16, 30, 4, w.l);
        APHLine(c, 1, 16, 30, w.h);
        APRect(c, 2, 20, 28, 12, w.m);
        for (int i = 0; i < 2; i++) {
            APRectOutline(c, 3 + i * 18, 21, 9, 10, w.d);
            APPx(c, 7 + i * 18, 25, 0xE8BE48);
        }
        APRect(c, 13, 21, 6, 4, w.d);
        APRect(c, 2, 32, 3, 3, w.d); APRect(c, 27, 32, 3, 3, w.d);
        // Papers, ink and quill.
        APRect(c, 4, 14, 8, 3, 0xF2EAD4); APHLine(c, 5, 15, 5, 0xB8A888);
        APRect(c, 13, 13, 3, 3, 0x2A2A40); APLine(c, 15, 12, 18, 7, 0xF4F4F4); APPx(c, 18, 7, 0xD8D8D8);
        // Banker's lamp.
        APRect(c, 22, 14, 6, 2, 0xC8962A);
        APVLine(c, 25, 9, 5, 0xC8962A);
        APRect(c, 20, 6, 10, 4, 0x2E7A4E); APHLine(c, 21, 6, 8, 0x4EA06E);
        APOutlineInside(c, w.o);
        if (ctx.on) {
            APHLine(ctx.emissive, 21, 10, 8, 0xFFF0B8);
            APHLine(ctx.emissive, 22, 7, 6, 0x6AD08A);
            APGlowAnim(ctx, 25, 11, 16, 0xFFD890, 0);
            [ctx addLight:[APLight x:25 y:13 radius:46 color:0xFFD080 strength:0.7f]];
        }
        APShadow(c, 0, H - 5, 32, 5);
    });
    desk.toggleable = YES;
    [items addObject:desk];

    [items addObject:APSpec(@"grandfather", @"Grandfather Clock", APLayerFloor, APCategoryFurniture, 1, 1, 40, @[@"Walnut", @"Oak"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"oak" : @"walnut");
        int H = ctx.height; // 56
        APRect(c, 2, 2, 12, 14, w.m);
        APHLine(c, 1, 1, 14, w.l); APPx(c, 8, 0, w.l);
        APCircle(c, 8, 9, 4, 0xF2EAD4);
        APEllipseOutline(c, 3, 4, 11, 11, 0xC8962A);
        float ma = ctx.minute / 60.0f * 2 * M_PI, ha = ((ctx.hour % 12) + ctx.minute / 60.0f) / 12.0f * 2 * M_PI;
        APLine(c, 8, 9, 8 + (int)lroundf(sinf(ma) * 3), 9 - (int)lroundf(cosf(ma) * 3), 0x2A2020);
        APLine(c, 8, 9, 8 + (int)lroundf(sinf(ha) * 2), 9 - (int)lroundf(cosf(ha) * 2), 0x2A2020);
        APRect(c, 3, 16, 10, 30, w.m);
        APRect(c, 5, 18, 6, 22, APShade(w.d, 0.7f)); // glass window
        APVLine(c, 5, 18, 22, w.l);
        APRect(c, 2, 46, 12, 6, w.l); APHLine(c, 2, 46, 12, w.h);
        APOutlineInside(c, w.o);
        APAnim *pendulum = [APAnim kind:APAnimPendulum x:8 y:18 w:0 h:0];
        pendulum.size = 14;
        pendulum.color = 0xE8BE48;
        [ctx addAnim:pendulum];
        [ctx addAnim:[APAnim kind:APAnimClockHands x:8 y:9 w:0 h:0]];
        APShadow(c, 1, H - 5, 14, 5);
    })];

    [items addObject:APSpec(@"bookstack", @"Book Stacks", APLayerFloor, APCategoryCosy, 1, 1, 10, @[@"Leather"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 26
        uint32_t spines[] = {0x9E2E30, 0x2E4A7A, 0x2E6A4A, 0x8A6418, 0x6A3A6A, 0xA85432};
        for (int i = 0; i < 5; i++) {
            uint32_t col = spines[i];
            APRect(c, 1 + (i % 2), H - 6 - i * 3, 8 - (i % 3), 3, col);
            APHLine(c, 1 + (i % 2), H - 6 - i * 3, 8 - (i % 3), APShade(col, 1.25f));
            APPx(c, 8 - (i % 3), H - 5 - i * 3, 0xF2EAD4);
        }
        for (int i = 0; i < 3; i++) {
            uint32_t col = spines[5 - i];
            APRect(c, 10, H - 6 - i * 3, 5, 3, col);
            APHLine(c, 10, H - 6 - i * 3, 5, APShade(col, 1.25f));
        }
        APOutlineInside(c, 0x1A1010);
        APCandle(ctx, 12, H - 15, 3, 0xF4E8D0);
        APShadow(c, 0, H - 5, 16, 5);
    })];

    [items addObject:APSpec(@"art.map", @"Old World Map", APLayerWall, APCategoryArt, 2, 1, 0, @[@"Parchment"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APPaintingShadowRect(c, 1, 1, 29, 13);
        APRect(c, 1, 1, 29, 13, 0x6A4228);
        APRect(c, 2, 2, 27, 11, 0xE8D8B0);
        APDitherRect(c, 2, 2, 27, 11, 0xD8C090, 0.25f);
        APEllipse(c, 4, 4, 7, 5, 0x9A8A5A); APEllipse(c, 13, 3, 6, 8, 0x9A8A5A); APEllipse(c, 21, 6, 5, 4, 0x9A8A5A);
        APLine(c, 9, 9, 22, 4, 0xB0403A);
        APPx(c, 22, 4, 0xB0403A); APPx(c, 21, 3, 0xB0403A); APPx(c, 23, 5, 0xB0403A);
        APPx(c, 26, 10, 0x3A3A3A); APPx(c, 25, 10, 0x3A3A3A); APPx(c, 27, 10, 0x3A3A3A); APPx(c, 26, 9, 0x3A3A3A); APPx(c, 26, 11, 0x3A3A3A);
    })];
}

#pragma mark - Space station

static void APRegisterSpace(NSMutableArray *items) {
    [items addObject:APSpec(@"porthole", @"Porthole", APLayerWall, APCategoryWall, 2, 2, 0,
                            @[@"Deep Space", @"Earthrise", @"Ocean Deep"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp m = (APRamp){0x2A2E36, 0x5A606C, 0x8A929E, 0xB4BCC6, 0xDDE2E8};
        APCircle(c, 16, 15, 14, m.m);
        APEllipseOutline(c, 2, 1, 29, 29, m.o);
        APEllipseOutline(c, 3, 2, 27, 27, m.l);
        for (int i = 0; i < 8; i++) {
            float a = i / 8.0f * 2 * M_PI;
            APPx(c, 16 + (int)lroundf(cosf(a) * 12), 15 + (int)lroundf(sinf(a) * 12), m.h);
        }
        APCanvas *view = APCanvasCreate(32, 32);
        if (ctx.variant == 2) {
            uint32_t sea[] = {0x2A7AA0, 0x1E5A80, 0x123A5A};
            for (int y = 0; y < 32; y++) APHLine(view, 0, y, 32, sea[MIN(2, y / 11)]);
            APDitherRect(view, 0, 0, 32, 32, 0x3A8AB0, 0.12f);
            APEllipse(view, 9, 12, 6, 3, 0xF2A040); APPx(view, 8, 13, 0xF2A040); APPx(view, 14, 13, 0x1A1A1A);
            APEllipse(view, 18, 20, 5, 2, 0xE8E060);
            for (int x = 6; x < 26; x += 3) APVLine(view, x, 26 - (x % 4), 6, 0x2E6A3A);
        } else {
            APRect(view, 0, 0, 32, 32, 0x06081A);
            APDitherRect(view, 0, 14, 32, 18, 0x1A1440, 0.3f);
            APRand r = {0x57A2};
            for (int i = 0; i < 40; i++) APPx(view, APRandInt(&r, 0, 31), APRandInt(&r, 0, 31), i % 4 ? 0x9AA4C8 : 0xFFF4D0);
            if (ctx.variant == 1) {
                APCircle(view, 18, 34, 14, 0x2E6AC8);
                APEllipse(view, 10, 22, 8, 4, 0x4E9A4E); APEllipse(view, 20, 25, 6, 3, 0x4E9A4E);
                APEllipseOutline(view, 4, 20, 29, 29, 0x8AC0F0);
            } else {
                APCircle(view, 20, 12, 5, 0xD89A5A);
                APHLine(view, 15, 11, 11, 0xB87A4A); APHLine(view, 16, 14, 9, 0xE8B070);
                APLine(view, 11, 15, 29, 9, 0xE8D8B0); APLine(view, 11, 14, 29, 8, 0xC8B890);
            }
        }
        for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
            if ((x - 16) * (x - 16) + (y - 15) * (y - 15) <= 100) APPx(ctx.emissive, x, y, APGet(view, x, y));
        }
        APCanvasFree(view);
        APLine(ctx.emissive, 10, 10, 13, 7, 0xC8D8E8);
        APAnim *glass = [APAnim kind:APAnimWindow x:7 y:6 w:18 h:18];
        glass.variant = ctx.variant == 2 ? 5 : 4;
        [ctx addAnim:glass];
        [ctx addLight:[APLight x:16 y:16 radius:46 color:ctx.variant == 2 ? 0x5AB0E0 : 0x8A9ADA strength:0.3f]];
    })];

    [items addObject:APSpec(@"console", @"Control Console", APLayerFloor, APCategoryFurniture, 2, 1, 16, @[@"Starfleet Grey", @"Retro Orange"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp m = ctx.variant ? APRampNamed(@"terracotta") : (APRamp){0x2A2E36, 0x4A505C, 0x6A727E, 0x9AA2AE, 0xC8D0D8};
        int H = ctx.height; // 32
        for (int y = 6; y < 16; y++) APHLine(c, 2 + (16 - y) / 3, y, 28 - (16 - y) / 3 * 2, m.l);
        APRect(c, 2, 16, 28, 12, m.m);
        APHLine(c, 2, 16, 28, m.h);
        APRect(c, 4, 19, 24, 2, m.d);
        for (int x = 5; x < 27; x += 2) APPx(c, x, 19, m.l);
        APRect(c, 3, 28, 4, 2, m.d); APRect(c, 25, 28, 4, 2, m.d);
        APOutlineInside(c, m.o);
        // Screen and blinking lights.
        APRect(ctx.emissive, 9, 8, 14, 6, 0x0E2A30);
        APLine(ctx.emissive, 10, 12, 13, 10, 0x5AF0C8); APLine(ctx.emissive, 13, 10, 16, 12, 0x5AF0C8); APLine(ctx.emissive, 16, 12, 21, 9, 0x5AF0C8);
        uint32_t lights[] = {0xFF5A5A, 0x5AF07A, 0xF2D040, 0x5AB0FF};
        for (int i = 0; i < 4; i++) APBlink(ctx, 5 + i * 2, 24, lights[i]);
        for (int i = 0; i < 3; i++) APBlink(ctx, 21 + i * 2, 24, lights[(i + 1) % 4]);
        APGlowAnim(ctx, 16, 11, 12, 0x5AF0C8, 1);
        [ctx addLight:[APLight x:16 y:11 radius:36 color:0x6AE0D0 strength:0.4f]];
        APShadow(c, 0, H - 4, 32, 5);
    })];

    NSArray *cores = @[@0x4AF0D0, @0xF05AE0, @0xF2B040];
    APItemSpec *reactor = APSpec(@"reactor", @"Fusion Core", APLayerFloor, APCategoryCosy, 1, 1, 34, @[@"Teal", @"Magenta", @"Amber"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t core = [cores[ctx.variant % cores.count] unsignedIntValue];
        APRamp m = (APRamp){0x2A2E36, 0x4A505C, 0x6A727E, 0x9AA2AE, 0xC8D0D8};
        int H = ctx.height; // 50
        APRect(c, 2, 2, 12, 5, m.m); APHLine(c, 2, 2, 12, m.h);
        APRect(c, 3, 7, 10, 32, 0x14181E);
        APRect(c, 1, 39, 14, 7, m.m); APHLine(c, 1, 39, 14, m.h); APHLine(c, 1, 45, 14, m.d);
        for (int y = 12; y < 38; y += 8) APHLine(c, 2, y, 12, m.l);
        APOutlineInside(c, m.o);
        if (ctx.on) {
            for (int y = 8; y < 39; y++) for (int x = 4; x < 12; x++) {
                float t = fabsf(x - 7.5f) / 4;
                uint32_t col = t < 0.35f ? 0xFFFFFF : t < 0.7f ? APMix(core, 0xFFFFFF, 0.4f) : core;
                if ((y + x) % 7 == 0) col = APMix(col, 0xFFFFFF, 0.5f);
                APPx(ctx.emissive, x, y, col);
            }
            for (int y = 12; y < 38; y += 8) APHLine(ctx.emissive, 4, y, 8, APShade(core, 0.6f));
            APGlowAnim(ctx, 8, 22, 26, core, 1);
            [ctx addLight:[APLight x:8 y:22 radius:80 color:APMix(core, 0xFFFFFF, 0.3f) strength:0.85f]];
        }
        APShadow(c, 0, H - 5, 16, 5);
    });
    reactor.toggleable = YES;
    [items addObject:reactor];

    APItemSpec *pod = APSpec(@"petbed.pod", @"Sleep Pod", APLayerFloor, APCategoryCosy, 2, 1, 10, @[@"Arctic", @"Midnight"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp shell = ctx.variant ? (APRamp){0x14161E, 0x2A2E3A, 0x3E4454, 0x5A6274, 0x7A8296}
                                   : (APRamp){0x4A5260, 0x9AA2AE, 0xC8D0D8, 0xE4E8EE, 0xFAFCFE};
        int H = ctx.height; // 26
        APRoundRect(c, 1, 10, 30, 13, shell.m);
        APHLine(c, 2, 10, 28, shell.h);
        APRect(c, 4, 12, 24, 6, 0x2A3A5A);
        APRect(c, 5, 13, 7, 4, 0xE8ECF4); // pillow
        APHLine(c, 1, 21, 30, shell.d);
        APOutlineInside(c, shell.o);
        // Glass canopy (emissive tint) and LED strip.
        for (int y = 2; y < 12; y++) {
            int half = (int)lroundf(sqrtf(fmaxf(0, 1 - powf((12 - y) / 10.0f, 2))) * 12);
            for (int x = 16 - half; x < 16 + half; x++) APBlendPx(c, x, y, 0x8AD0F0, (x + y) % 5 == 0 ? 0.55f : 0.25f);
        }
        APLine(c, 9, 5, 12, 3, 0xF0F8FF);
        if (ctx.on) {
            APHLine(ctx.emissive, 4, 19, 24, 0x5AD0FF);
            APGlowAnim(ctx, 16, 18, 14, 0x5AD0FF, 1);
            [ctx addLight:[APLight x:16 y:18 radius:30 color:0x5AD0FF strength:0.35f]];
        }
        APShadow(c, 0, H - 4, 32, 5);
    });
    pod.petBed = YES;
    pod.walkable = YES;
    pod.toggleable = YES;
    pod.sleepX = 18; pod.sleepY = 19;
    [items addObject:pod];

    APItemSpec *hydro = APSpec(@"hydroponics", @"Hydroponics Tube", APLayerFloor, APCategoryCosy, 1, 1, 30, @[@"Greens", @"Strawberries"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 46
        APRect(c, 2, 2, 12, 4, 0xC8D0D8); APHLine(c, 2, 2, 12, 0xF0F4F8);
        APRect(c, 3, 6, 10, 32, 0x1E2A26);
        for (int y = 36; y > 8; y -= 6) {
            APEllipse(c, 4, y - 4, 4, 4, 0x4E9A4E); APEllipse(c, 8, y - 6, 4, 5, 0x6AB85A); APVLine(c, 7, y - 4, 4, 0x3E7A3E);
            if (ctx.variant) { APPx(c, 5, y - 2, 0xE84A4A); APPx(c, 10, y - 4, 0xE84A4A); }
        }
        for (int y = 7; y < 38; y += 3) APBlendPx(c, 4, y, 0xE0F4FF, 0.6f);
        APRect(c, 1, 38, 14, 5, 0x9AA2AE); APHLine(c, 1, 38, 14, 0xC8D0D8);
        APOutlineInside(c, 0x2A2E36);
        if (ctx.on) {
            APRect(ctx.emissive, 4, 5, 8, 1, 0xE88AFF);
            APGlowAnim(ctx, 8, 14, 14, 0xC86AF0, 1);
            [ctx addLight:[APLight x:8 y:10 radius:34 color:0xD08AF0 strength:0.35f]];
        }
        APShadow(c, 0, H - 5, 16, 5);
    });
    hydro.toggleable = YES;
    [items addObject:hydro];

    [items addObject:APSpec(@"robot", @"Robot Buddy", APLayerFloor, APCategoryCosy, 1, 1, 12, @[@"Mint", @"Tangerine", @"Chrome"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp b = ctx.variant == 1 ? APRampNamed(@"mustard") : ctx.variant == 2 ? (APRamp){0x3A3E48, 0x7A828E, 0xA8B0BC, 0xD0D6DE, 0xF4F6F8} : APRampNamed(@"teal");
        int H = ctx.height; // 28
        APVLine(c, 8, 1, 3, 0x6A6E78);
        APRoundRect(c, 3, 4, 10, 8, b.l);
        APRect(c, 4, 6, 8, 4, 0x14181E);
        APRect(c, 4, 13, 8, 8, b.m);
        APHLine(c, 4, 13, 8, b.h);
        APRect(c, 6, 15, 4, 3, b.d);
        APRect(c, 2, 14, 2, 5, b.d); APRect(c, 12, 14, 2, 5, b.d);
        APRect(c, 3, 21, 10, 3, 0x2A2E36); for (int x = 4; x < 12; x += 2) APPx(c, x, 22, 0x6A6E78);
        APOutlineInside(c, b.o);
        APPx(ctx.emissive, 6, 7, 0x6AF0F0); APPx(ctx.emissive, 9, 7, 0x6AF0F0);
        APHLine(ctx.emissive, 6, 9, 4, 0x6AF0F0);
        APBlink(ctx, 8, 0, 0xFF5A5A);
        APShadow(c, 1, H - 5, 14, 5);
    })];
}

#pragma mark - Saloon

static void APRegisterSaloon(NSMutableArray *items) {
    APItemSpec *bar = APSpec(@"bar", @"Saloon Bar", APLayerFloor, APCategoryFurniture, 3, 1, 24, @[@"Walnut", @"Oak"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"oak" : @"walnut");
        int H = ctx.height; // 40
        // Bottles and glasses along the counter.
        uint32_t glass[] = {0x8A5A20, 0x3A6A3A, 0x6A2A2A, 0xC8962A, 0x3A6A3A};
        for (int i = 0; i < 5; i++) {
            int x = 4 + i * 5 + (i > 2 ? 9 : 0);
            APRect(c, x, 10, 3, 6, glass[i]); APRect(c, x + 1, 7, 1, 3, glass[i]);
            APPx(c, x, 11, APMix(glass[i], 0xFFFFFF, 0.5f));
            APRect(c, x, 12, 3, 2, 0xE8D8B0);
        }
        APRect(c, 22, 13, 3, 3, 0xD8E8F0); APPx(c, 23, 13, 0xF2E6B0);
        APRect(c, 0, 16, 48, 4, w.l);
        APHLine(c, 0, 16, 48, w.h);
        APRect(c, 1, 20, 46, 16, w.m);
        for (int x = 3; x < 46; x += 11) { APRectOutline(c, x, 22, 9, 11, w.d); APHLine(c, x + 1, 23, 7, w.l); }
        APHLine(c, 1, 34, 46, 0xC8962A); APHLine(c, 1, 35, 46, 0x8A6418);
        APOutlineInside(c, w.o);
        APShadow(c, 0, H - 5, 48, 5);
    });
    bar.backWall = YES;
    [items addObject:bar];

    APItemSpec *piano = APSpec(@"piano", @"Upright Piano", APLayerFloor, APCategoryFurniture, 2, 1, 26, @[@"Walnut", @"Ebony"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = ctx.variant ? (APRamp){0x0A0A0E, 0x1E1E26, 0x2E2E3A, 0x44444E, 0x6A6A78} : APRampNamed(@"walnut");
        int H = ctx.height; // 42
        APRect(c, 1, 4, 30, 30, w.m);
        APHLine(c, 1, 4, 30, w.l); APHLine(c, 1, 5, 30, w.h);
        APRect(c, 4, 8, 24, 8, w.d);
        APRect(c, 10, 9, 12, 6, 0xF2EAD4); for (int y = 10; y < 15; y += 2) APHLine(c, 11, y, 10, 0x8A8070);
        APRect(c, 2, 20, 28, 5, 0xF6F2EA);
        for (int x = 3; x < 30; x += 2) APVLine(c, x, 20, 5, 0xC8C0B0);
        for (int x = 4; x < 29; x += 4) if (x % 12 != 0) APRect(c, x, 20, 1, 3, 0x1A1A1E);
        APRect(c, 1, 25, 30, 3, w.l);
        APRect(c, 3, 34, 3, 4, w.d); APRect(c, 26, 34, 3, 4, w.d);
        APOutlineInside(c, w.o);
        APCandle(ctx, 25, 4, 3, 0xF4E8D0);
        if (ctx.on) [ctx addAnim:[APAnim kind:APAnimNotes x:16 y:8 w:1 h:1]];
        APShadow(c, 0, H - 5, 32, 5);
    });
    piano.backWall = YES;
    piano.toggleable = YES;
    [items addObject:piano];

    [items addObject:APSpec(@"barrel", @"Barrel", APLayerFloor, APCategoryCosy, 1, 1, 12, @[@"Oak", @"With Cactus"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(@"oak");
        int H = ctx.height; // 28
        int top = ctx.variant ? 10 : 6;
        APEllipse(c, 2, top, 12, 4, w.l);
        APRect(c, 2, top + 2, 12, H - top - 7, w.m);
        APRect(c, 1, top + 5, 14, H - top - 13, w.m);
        for (int x = 4; x < 13; x += 3) APVLine(c, x, top + 3, H - top - 9, w.d);
        APHLine(c, 1, top + 5, 14, 0x3E3E48); APHLine(c, 1, H - 9, 14, 0x3E3E48);
        APEllipseOutline(c, 2, top, 12, 4, w.d);
        if (ctx.variant) {
            APRoundRect(c, 6, 1, 4, top, 0x5E8A3C); APVLine(c, 7, 2, top - 2, 0x86B052);
            APRoundRect(c, 3, 3, 2, 4, 0x5E8A3C); APRoundRect(c, 11, 4, 2, 4, 0x5E8A3C);
        }
        APOutlineInside(c, w.o);
        APShadow(c, 0, H - 6, 16, 5);
    })];

    APItemSpec *hay = APSpec(@"petbed.hay", @"Hay Bale", APLayerFloor, APCategoryCosy, 1, 1, 6, @[@"Golden"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 22
        APRect(c, 1, 6, 14, 6, 0xE8C060);
        APRect(c, 1, 12, 14, 7, 0xC89A40);
        APRand r = {0x4A7};
        for (int i = 0; i < 26; i++) {
            int x = APRandInt(&r, 1, 13), y = APRandInt(&r, 6, 17);
            APHLine(c, x, y, 2, y < 12 ? 0xF4D888 : 0xA87A28);
        }
        APVLine(c, 4, 6, 13, 0x8A5A30); APVLine(c, 11, 6, 13, 0x8A5A30);
        APPx(c, 0, 8, 0xF4D888); APPx(c, 15, 10, 0xF4D888); APPx(c, 3, 5, 0xF4D888);
        APOutlineInside(c, 0x6A4A18);
        APShadow(c, 0, H - 5, 16, 5);
    });
    hay.petBed = YES;
    hay.walkable = YES;
    hay.sleepX = 8; hay.sleepY = 11;
    [items addObject:hay];

    [items addObject:APSpec(@"art.wanted", @"Wanted Poster", APLayerWall, APCategoryArt, 2, 2, 0, @[@"Parchment"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APPaintingShadowRect(c, 3, 2, 26, 27);
        APRect(c, 3, 2, 26, 27, 0xE8D4A8);
        APDitherRect(c, 3, 2, 26, 27, 0xD4B880, 0.2f);
        APText(c, @"WANTED", 16 - APTextWidth(@"WANTED", APFontSmall) / 2, 4, APFontSmall, 0x3A2414);
        // A suspiciously cute outlaw.
        APEllipse(c, 11, 11, 10, 8, 0xD68438);
        APPx(c, 12, 10, 0xD68438); APPx(c, 19, 10, 0xD68438); APPx(c, 12, 9, 0xD68438); APPx(c, 19, 9, 0xD68438);
        APPx(c, 13, 14, 0x1A1010); APPx(c, 18, 14, 0x1A1010); APPx(c, 15, 16, 0xE87A8A); APPx(c, 16, 16, 0xE87A8A);
        APText(c, @"$100", 16 - APTextWidth(@"$100", APFontSmall) / 2, 22, APFontSmall, 0x6A2A1A);
        APPx(c, 15, 3, 0x9E9488);
    })];

    [items addObject:APSpec(@"wagonwheel", @"Wagon Wheel", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Oak"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(@"oak");
        for (int i = 0; i < 8; i++) {
            float a = i / 8.0f * M_PI;
            APLine(c, 8 - (int)lroundf(cosf(a) * 6), 7 - (int)lroundf(sinf(a) * 6), 8 + (int)lroundf(cosf(a) * 6), 7 + (int)lroundf(sinf(a) * 6), w.m);
        }
        APEllipseOutline(c, 1, 0, 15, 15, w.d);
        APEllipseOutline(c, 2, 1, 13, 13, w.l);
        APCircle(c, 8, 7, 1, 0x3E3E48);
        APBlendRect(c, 9, 14, 6, 1, 0x1A0C06, 0.3f);
    })];

    [items addObject:APSpec(@"skull", @"Longhorn Skull", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Bleached"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APLine(c, 0, 3, 5, 6, 0xE8DCC0); APLine(c, 0, 2, 4, 5, 0xC8B898);
        APLine(c, 15, 3, 10, 6, 0xE8DCC0); APLine(c, 15, 2, 11, 5, 0xC8B898);
        APRoundRect(c, 5, 5, 6, 6, 0xF2EAD8);
        APRect(c, 6, 11, 4, 3, 0xE8DCC0);
        APPx(c, 6, 7, 0x2A2020); APPx(c, 9, 7, 0x2A2020);
        APPx(c, 7, 12, 0x6A5A4A); APPx(c, 8, 12, 0x6A5A4A);
        APOutlineInside(c, 0x8A7A60);
        APBlendRect(c, 6, 14, 5, 1, 0x1A0C06, 0.3f);
    })];

    [items addObject:APSpec(@"rug.cowhide", @"Cowhide Rug", APLayerRug, APCategoryRugs, 3, 2, 0, @[@"Holstein", @"Brown & White"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t spot = ctx.variant ? 0x6A4228 : 0x1E1A1A;
        APEllipse(c, 6, 4, 36, 24, 0xF2EEE6);
        APEllipse(c, 1, 2, 10, 8, 0xF2EEE6); APEllipse(c, 37, 2, 10, 8, 0xF2EEE6);
        APEllipse(c, 1, 22, 10, 8, 0xF2EEE6); APEllipse(c, 37, 22, 10, 8, 0xF2EEE6);
        APEllipse(c, 12, 7, 9, 7, spot); APEllipse(c, 26, 14, 11, 8, spot); APEllipse(c, 9, 18, 6, 5, spot);
        APEllipse(c, 33, 5, 6, 4, spot); APEllipse(c, 2, 4, 5, 4, spot);
        APOutlineInside(c, 0xB8B0A4);
    })];
}

#pragma mark - Treehouse

static void APRegisterTreehouse(NSMutableArray *items) {
    APItemSpec *mushroom = APSpec(@"mushroom", @"Mushroom Stool", APLayerFloor, APCategoryCosy, 1, 1, 8,
                                  @[@"Toadstool", @"Porcini", @"Glowcap"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 24
        uint32_t cap = ctx.variant == 1 ? 0x8A5A30 : ctx.variant == 2 ? 0x5A3A8A : 0xC8302A;
        APRect(c, 5, 10, 6, 10, 0xF2E6D0); APVLine(c, 5, 10, 10, 0xFAF4E8); APVLine(c, 10, 11, 9, 0xD8C8B0);
        APEllipse(c, 1, 3, 14, 9, cap);
        APEllipse(c, 2, 3, 12, 4, APMix(cap, 0xFFFFFF, 0.25f));
        APHLine(c, 2, 10, 12, APShade(cap, 0.6f));
        APOutlineInside(c, APShade(cap, 0.4f));
        int spots[][2] = {{4, 5}, {8, 4}, {11, 6}, {6, 8}};
        for (int i = 0; i < 4; i++) {
            APCanvas *layer = ctx.variant == 2 ? ctx.emissive : c;
            APPx(layer, spots[i][0], spots[i][1], ctx.variant == 2 ? 0x9AF0FF : 0xFAF4E8);
            if (i < 2) APPx(layer, spots[i][0] + 1, spots[i][1], ctx.variant == 2 ? 0x6AD0F0 : 0xFAF4E8);
        }
        if (ctx.variant == 2) {
            APGlowAnim(ctx, 8, 6, 12, 0x7AE0FF, 1);
            [ctx addLight:[APLight x:8 y:6 radius:30 color:0x7AD0FF strength:0.35f]];
        }
        APShadow(c, 1, H - 5, 14, 5);
    });
    mushroom.seat = YES; mushroom.seatX = 8; mushroom.seatY = 7;
    [items addObject:mushroom];

    APItemSpec *hammock = APSpec(@"petbed.hammock", @"Hammock", APLayerFloor, APCategoryCosy, 2, 1, 12, @[@"Sunset Stripes", @"Forest Stripes"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 28
        APRamp w = APRampNamed(@"oak");
        APRect(c, 1, 2, 3, H - 5, w.m); APVLine(c, 1, 2, H - 5, w.l);
        APRect(c, 28, 2, 3, H - 5, w.m); APVLine(c, 28, 2, H - 5, w.l);
        uint32_t stripes[2][3] = {{0xE8664A, 0xF2C060, 0xF4EEE0}, {0x3E7A4A, 0xE8D8A0, 0x6A9A5A}};
        for (int x = 4; x < 28; x++) {
            float t = (x - 4) / 23.0f;
            int sag = (int)lroundf(sinf(t * M_PI) * 7);
            for (int k = 0; k < 4; k++) APPx(c, x, 6 + sag + k, stripes[ctx.variant % 2][(x / 3) % 3]);
            APPx(c, x, 10 + sag, APShade(stripes[ctx.variant % 2][(x / 3) % 3], 0.7f));
        }
        APLine(c, 3, 5, 6, 7, 0xE8DCC0); APLine(c, 28, 5, 25, 7, 0xE8DCC0);
        APOutlineInside(c, w.o);
        APShadow(c, 4, H - 6, 24, 5);
    });
    hammock.petBed = YES;
    hammock.walkable = YES;
    hammock.sleepX = 16; hammock.sleepY = 15;
    [items addObject:hammock];

    APItemSpec *jar = APSpec(@"fireflyjar", @"Firefly Jar", APLayerFloor, APCategoryCosy, 1, 1, 8, @[@"Fireflies", @"Glow-worms"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 24
        APRect(c, 4, 3, 8, 2, 0x8A6418); APHLine(c, 4, 3, 8, 0xC8962A);
        for (int y = 5; y < 19; y++) for (int x = 3; x < 13; x++) APBlendPx(c, x, y, 0xC8E8E0, x == 3 || x == 12 || y == 18 ? 0.8f : 0.18f);
        APVLine(c, 5, 6, 10, 0xF0FAF8);
        uint32_t bug = ctx.variant ? 0x7AE0FF : 0xE8F06A;
        if (ctx.on) {
            APPx(ctx.emissive, 6, 9, bug); APPx(ctx.emissive, 10, 12, bug); APPx(ctx.emissive, 8, 15, bug); APPx(ctx.emissive, 7, 12, APShade(bug, 0.7f));
            APAnim *flies = [APAnim kind:APAnimFireflies x:4 y:6 w:8 h:12];
            flies.color = bug;
            [ctx addAnim:flies];
            APGlowAnim(ctx, 8, 12, 14, bug, 1);
            [ctx addLight:[APLight x:8 y:12 radius:38 color:bug strength:0.45f]];
        }
        APShadow(c, 1, H - 5, 14, 5);
    });
    jar.toggleable = YES;
    [items addObject:jar];

    [items addObject:APSpec(@"stump", @"Stump Table", APLayerFloor, APCategoryFurniture, 2, 1, 6, @[@"Oak"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 22
        APRect(c, 2, 8, 28, 10, 0x6A4228);
        for (int x = 3; x < 29; x += 3) APVLine(c, x, 9, 8, 0x4A2E1C);
        APEllipse(c, 1, 2, 30, 10, 0xC89A6A);
        APEllipseOutline(c, 4, 3, 24, 8, 0xA87A4A);
        APEllipseOutline(c, 8, 4, 16, 6, 0xA87A4A);
        APEllipseOutline(c, 12, 5, 8, 4, 0xA87A4A);
        APRect(c, 0, 16, 3, 3, 0x6A4228); APRect(c, 29, 15, 3, 3, 0x6A4228); // roots
        APOutlineInside(c, 0x2E1C10);
        // A mug and a little mushroom friend.
        APRect(c, 7, 2, 4, 4, 0xE8D8C0); APPx(c, 11, 3, 0xE8D8C0); APHLine(c, 7, 2, 4, 0x6A4228);
        APAnim *steam = [APAnim kind:APAnimSteam x:8 y:1 w:1 h:1];
        [ctx addAnim:steam];
        APRect(c, 22, 4, 2, 3, 0xF2E6D0); APRect(c, 20, 2, 6, 2, 0xC8302A); APPx(c, 21, 2, 0xFAF4E8);
        APShadow(c, 0, H - 5, 32, 5);
    })];

    [items addObject:APSpec(@"vines", @"Ivy & Blossoms", APLayerTrim, APCategoryWall, 4, 1, 0, @[@"Ivy", @"Wisteria"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t leaf = 0x4E8A3E, light = 0x7AB052, flower = ctx.variant ? 0xB08AE0 : 0xF2A0B8;
        for (int x = 0; x < ctx.width; x++) {
            int y = (int)lroundf(1 + 3 * fabsf(sinf(x / 32.0f * M_PI)));
            APPx(c, x, y, 0x3E5A2A);
            if (x % 3 == 0) { APPx(c, x, y + 1, leaf); APPx(c, x + 1, y + 1, light); }
            if (x % 9 == 4) for (int k = 0; k < 3 + (x % 4); k++) APPx(c, x + (k % 2), y + 2 + k, k % 2 ? leaf : light);
            if (x % 11 == 6) { APPx(c, x, y + 3, flower); APPx(c, x + 1, y + 2, flower); APPx(c, x - 1, y + 2, APShade(flower, 0.8f)); }
        }
    })];

    [items addObject:APSpec(@"birdhouse", @"Birdhouse", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Robin's Egg", @"Cherry"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t body = ctx.variant ? 0xC44A44 : 0x7ABAC8;
        for (int k = 0; k < 4; k++) APHLine(c, 8 - 2 - k * 2 + 1, 1 + k, 2 + k * 4, 0x8A5A36);
        APRect(c, 4, 5, 8, 8, body);
        APVLine(c, 4, 5, 8, APMix(body, 0xFFFFFF, 0.3f));
        APCircle(c, 8, 8, 1, 0x1A1A1E);
        APHLine(c, 6, 11, 4, 0x6A4228);
        APOutlineInside(c, 0x2E2018);
        APPaintingShadowRect(c, 4, 5, 8, 8);
    })];
}

#pragma mark - Under the sea

static void APRegisterUnderwater(NSMutableArray *items) {
    APItemSpec *clam = APSpec(@"petbed.clam", @"Giant Clam", APLayerFloor, APCategoryCosy, 2, 1, 10, @[@"Coral Pink", @"Lagoon Blue"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t shell = ctx.variant ? 0x6AA8C8 : 0xE8A0A8;
        int H = ctx.height; // 26
        // Upper shell open behind.
        for (int x = 2; x < 30; x++) {
            int top = (int)lroundf(10 - sinf((x - 2) / 27.0f * M_PI) * 9);
            APVLine(c, x, top, 12 - top, (x / 3) % 2 ? shell : APShade(shell, 0.85f));
        }
        APRect(c, 4, 12, 24, 4, 0xF2E6EA); // inner lip
        APEllipse(c, 12, 11, 8, 5, 0xFAF6FA); // pearl pillow
        APPx(c, 14, 12, 0xFFFFFF);
        for (int x = 1; x < 31; x++) {
            int bottom = (int)lroundf(16 + sinf((x - 1) / 29.0f * M_PI) * 6);
            APVLine(c, x, 16, bottom - 16, (x / 3) % 2 ? APShade(shell, 0.9f) : shell);
        }
        APOutlineInside(c, APShade(shell, 0.45f));
        APPx(ctx.emissive, 13, 12, 0xFFFFFF);
        APGlowAnim(ctx, 16, 13, 10, 0xFFE8F0, 1);
        APShadow(c, 1, H - 5, 30, 5);
    });
    clam.petBed = YES;
    clam.walkable = YES;
    clam.sleepX = 16; clam.sleepY = 17;
    [items addObject:clam];

    NSArray *corals = @[@0xF06A8A, @0xF2944A, @0xA06AE0];
    [items addObject:APSpec(@"coral", @"Coral", APLayerFloor, APCategoryCosy, 1, 1, 18, @[@"Pink", @"Orange", @"Violet"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t col = [corals[ctx.variant % corals.count] unsignedIntValue];
        int H = ctx.height; // 34
        // Branching, drawn as a little recursive tree.
        __block void (^branch)(int, int, float, int);
        __weak __block void (^weakBranch)(int, int, float, int);
        branch = ^(int x, int y, float angle, int length) {
            int x2 = x + (int)lroundf(cosf(angle) * length), y2 = y - (int)lroundf(sinf(angle) * length);
            APLine(c, x, y, x2, y2, col);
            APLine(c, x + 1, y, x2 + 1, y2, APShade(col, 0.8f));
            APPx(c, x2, y2, APMix(col, 0xFFFFFF, 0.4f));
            if (length > 3) {
                weakBranch(x2, y2, angle + 0.5f, length * 2 / 3);
                weakBranch(x2, y2, angle - 0.55f, length * 2 / 3);
            }
        };
        weakBranch = branch;
        branch(8, H - 6, M_PI / 2, 11);
        APEllipse(c, 4, H - 8, 9, 4, 0xC8B890);
        APOutlineInside(c, APShade(col, 0.4f));
        APShadow(c, 2, H - 5, 12, 5);
    })];

    [items addObject:APSpec(@"kelp", @"Kelp", APLayerFloor, APCategoryCosy, 1, 1, 38, @[@"Golden Kelp", @"Sea Grass"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 54
        uint32_t a = ctx.variant ? 0x3E8A4A : 0x8A8A2A, b = ctx.variant ? 0x6AB06A : 0xB0A83A;
        for (int s = 0; s < 3; s++) {
            int bx = 4 + s * 4, top = 2 + s * 6;
            for (int y = top; y < H - 5; y++) {
                int x = bx + (int)lroundf(sinf(y * 0.25f + s) * 1.5f);
                APPx(c, x, y, a);
                if (y % 6 == s) { APPx(c, x + 1, y, b); APPx(c, x + 2, y - 1, b); }
                if (y % 7 == s + 3) { APPx(c, x - 1, y, b); APPx(c, x - 2, y - 1, b); }
            }
        }
        APEllipse(c, 3, H - 7, 10, 3, 0x8A8070);
        APAnim *bubbles = [APAnim kind:APAnimBubbles x:8 y:6 w:1 h:1];
        [ctx addAnim:bubbles];
        APShadow(c, 2, H - 5, 12, 5);
    })];

    [items addObject:APSpec(@"anchor", @"Anchor", APLayerWall, APCategoryWall, 1, 2, 0, @[@"Iron", @"Brass"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp m = APRampNamed(ctx.variant ? @"gold" : @"iron");
        APEllipseOutline(c, 6, 1, 5, 5, m.l);
        APRect(c, 7, 6, 2, 19, m.m); APVLine(c, 7, 6, 19, m.l);
        APRect(c, 4, 8, 8, 2, m.m);
        for (int x = 2; x < 14; x++) {
            int y = 26 - (int)lroundf(sqrtf(fmaxf(0, 36 - (x - 8) * (x - 8))) * 0.7f);
            APRect(c, x, y, 1, 2, m.m);
        }
        APPx(c, 1, 22, m.l); APPx(c, 14, 22, m.l); APPx(c, 2, 21, m.l); APPx(c, 13, 21, m.l);
        APLine(c, 9, 3, 13, 12, 0xC8B890); APLine(c, 13, 12, 10, 18, 0xC8B890);
        APPaintingShadowRect(c, 7, 6, 2, 19);
    })];

    NSArray *jellies = @[@0xF0A0E0, @0x8AD0FF, @0xC0F08A];
    APItemSpec *jelly = APSpec(@"jellylamp", @"Jellyfish Lamp", APLayerTrim, APCategoryWall, 1, 2, 0, @[@"Moon Jelly", @"Blue Bell", @"Lime"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t col = [jellies[ctx.variant % jellies.count] unsignedIntValue];
        APVLine(c, 8, 0, 8, 0x5A6A7A);
        APCanvas *layer = ctx.on ? ctx.emissive : c;
        uint32_t body = ctx.on ? col : APShade(col, 0.55f);
        APEllipse(layer, 2, 8, 12, 9, body);
        APHLine(layer, 3, 15, 10, APShade(body, 0.8f));
        APPx(layer, 5, 10, APMix(body, 0xFFFFFF, 0.6f)); APPx(layer, 6, 9, APMix(body, 0xFFFFFF, 0.6f));
        for (int t = 0; t < 4; t++) {
            int tx = 4 + t * 3;
            for (int y = 16; y < 28 - (t % 2) * 3; y++) APPx(layer, tx + ((y / 3 + t) % 2), y, APShade(body, 0.85f));
        }
        if (ctx.on) {
            APGlowAnim(ctx, 8, 12, 18, col, 1);
            [ctx addLight:[APLight x:8 y:12 radius:46 color:col strength:0.5f]];
        }
    });
    jelly.toggleable = YES;
    [items addObject:jelly];

    [items addObject:APSpec(@"divehelmet", @"Diving Helmet", APLayerFloor, APCategoryCosy, 1, 1, 12, @[@"Brass", @"Copper"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp m = ctx.variant ? APRampNamed(@"terracotta") : APRampNamed(@"gold");
        int H = ctx.height; // 28
        APRect(c, 1, H - 9, 14, 5, 0x8A5A36); APHLine(c, 1, H - 9, 14, 0xA8744A);
        APCircle(c, 8, 10, 7, m.m);
        APEllipse(c, 3, 4, 6, 6, m.l);
        APRect(c, 3, 16, 10, 3, m.d);
        APCircle(c, 8, 10, 3, 0x2A4A5A);
        APPx(c, 7, 9, 0x8AC0D0);
        APEllipseOutline(c, 4, 6, 9, 9, m.h);
        APPx(c, 1, 10, m.d); APPx(c, 15, 10, m.d);
        APOutlineInside(c, m.o);
        APShadow(c, 0, H - 5, 16, 5);
    })];
}

#pragma mark - Surfaces

void APRegisterThemedSurfaces(NSMutableArray<APSurfaceSpec *> *walls, NSMutableArray<APSurfaceSpec *> *floors) {
    APSurfaceSpec *(^surface)(NSString *, NSString *, uint32_t, void (^)(APCanvas *, int, int, int, int)) =
        ^APSurfaceSpec *(NSString *identifier, NSString *title, uint32_t swatch, void (^paint)(APCanvas *, int, int, int, int)) {
        APSurfaceSpec *spec = [APSurfaceSpec new];
        spec.identifier = identifier;
        spec.title = title;
        spec.swatch = swatch;
        spec.paint = paint;
        return spec;
    };
    [walls addObject:surface(@"wp.castle", @"Castle Stone", 0x7A7672, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x4E4A48);
        APRand r = {0xCA57};
        for (int row = 0; row * 8 < h; row++) for (int bx = (row % 2) * -8; bx < w; bx += 16) {
            uint32_t tone = (uint32_t[]){0x7A7672, 0x86817C, 0x6E6A66, 0x8E8882}[APRandInt(&r, 0, 3)];
            APRect(c, x + bx, y + row * 8, 15, 7, tone);
            APHLine(c, x + bx, y + row * 8, 15, APShade(tone, 1.12f));
            APHLine(c, x + bx, y + row * 8 + 6, 15, APShade(tone, 0.85f));
            if (APRandInt(&r, 0, 9) == 0) { APPx(c, x + bx + 3, y + row * 8 + 5, 0x5E7A4A); APPx(c, x + bx + 4, y + row * 8 + 5, 0x6E8A52); }
        }
    })];
    [walls addObject:surface(@"wp.library", @"Library Green", 0x2E4A3A, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x2E4A3A);
        for (int xx = 0; xx < w; xx += 8) APRect(c, x + xx, y, 4, h, 0x34503E);
        for (int yy = 2; yy < h; yy += 8) for (int xx = 6; xx < w; xx += 8) APPx(c, x + xx, y + yy, 0x8A8050);
        int wainscot = h * 40 / 100;
        APRamp wood = APRampNamed(@"walnut");
        APRect(c, x, y + h - wainscot, w, wainscot, wood.m);
        APHLine(c, x, y + h - wainscot, w, 0xC8962A);
        APHLine(c, x, y + h - wainscot + 1, w, wood.l);
        for (int px = 2; px + 14 <= w; px += 16) APRectOutline(c, x + px, y + h - wainscot + 4, 14, wainscot - 6, wood.d);
    })];
    [walls addObject:surface(@"wp.hull", @"Hull Panels", 0x8A929E, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int ty = 0; ty < h; ty += 16) for (int tx = 0; tx < w; tx += 16) {
            APRect(c, x + tx, y + ty, 16, 16, ((tx + ty) / 16) % 2 ? 0x8A929E : 0x828A96);
            APHLine(c, x + tx, y + ty, 16, 0xB4BCC6);
            APVLine(c, x + tx, y + ty, 16, 0xA4ACB6);
            APHLine(c, x + tx, y + ty + 15, 16, 0x5A606C);
            APVLine(c, x + tx + 15, y + ty, 16, 0x5A606C);
            APPx(c, x + tx + 2, y + ty + 2, 0xDDE2E8); APPx(c, x + tx + 13, y + ty + 2, 0xDDE2E8);
            APPx(c, x + tx + 2, y + ty + 13, 0x6A727E); APPx(c, x + tx + 13, y + ty + 13, 0x6A727E);
        }
        APRect(c, x, y + 3, w, 2, 0x5AD0E8);
        APHLine(c, x, y + 3, w, 0xA8F0FF);
    })];
    [walls addObject:surface(@"wp.saloon", @"Saloon Boards", 0x9A6A44, ^(APCanvas *c, int x, int y, int w, int h) {
        APRand r = {0x5A1};
        for (int xx = 0; xx < w; xx += 6) {
            uint32_t tone = (uint32_t[]){0x9A6A44, 0x8A5E3A, 0xA87850, 0x925F3E}[APRandInt(&r, 0, 3)];
            APRect(c, x + xx, y, 5, h, tone);
            APVLine(c, x + xx + 5, y, h, 0x4A2E1C);
            APVLine(c, x + xx, y, h, APShade(tone, 1.1f));
            for (int k = 0; k < h / 12; k++) APVLine(c, x + xx + APRandInt(&r, 1, 4), y + APRandInt(&r, 0, h - 4), 3, APShade(tone, 0.85f));
            APPx(c, x + xx + 2, y + 3, 0x3A3A40); APPx(c, x + xx + 2, y + h - 4, 0x3A3A40);
        }
    })];
    [walls addObject:surface(@"wp.bark", @"Treehouse Logs", 0x7A5434, ^(APCanvas *c, int x, int y, int w, int h) {
        APRand r = {0xBA4C};
        for (int xx = 0; xx < w; xx += 8) {
            APRect(c, x + xx, y, 8, h, 0x7A5434);
            APVLine(c, x + xx + 1, y, h, 0x9A6E44);
            APVLine(c, x + xx + 2, y, h, 0x8A6240);
            APVLine(c, x + xx + 6, y, h, 0x5E3E24);
            APVLine(c, x + xx + 7, y, h, 0x3E2614);
            for (int k = 0; k < h / 10; k++) {
                int ky = APRandInt(&r, 0, h - 3);
                APPx(c, x + xx + 4, y + ky, 0x5E3E24); APPx(c, x + xx + 4, y + ky + 1, 0x4A2E1C);
            }
            if (APRandInt(&r, 0, 2) == 0) { int ky = APRandInt(&r, 2, h - 4); APPx(c, x + xx + 3, y + ky, 0x5E8A3C); APPx(c, x + xx + 4, y + ky + 1, 0x7AB052); }
        }
    })];
    [walls addObject:surface(@"wp.reef", @"Coral Reef", 0x2E7A8A, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) {
            float caustic = sinf(xx * 0.45f + sinf(yy * 0.3f) * 2) * sinf(yy * 0.4f + sinf(xx * 0.25f) * 2);
            uint32_t col = yy < h / 2 ? 0x2E7A8A : 0x286E7E;
            if (caustic > 0.55f) col = 0x4AA0AA;
            else if (caustic > 0.4f && APBayer(xx, yy) < 0.5f) col = 0x3E8E9A;
            APPx(c, x + xx, y + yy, col);
        }
        APRand r = {0xB0B};
        for (int i = 0; i < w * h / 90; i++) {
            int bx = APRandInt(&r, 1, w - 3), by = APRandInt(&r, 1, h - 3);
            APPx(c, x + bx, y + by, 0xA8E0E8); APPx(c, x + bx + 1, y + by - 1, 0x7AC0CC);
        }
    })];

    [floors addObject:surface(@"fl.hall", @"Great Hall Stone", 0x6E6A66, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x3E3A38);
        APRand r = {0x4A11};
        for (int row = 0; row * 12 < h; row++) for (int bx = (row % 2) * -10; bx < w; bx += 20) {
            uint32_t tone = (uint32_t[]){0x6E6A66, 0x76716C, 0x66625E, 0x7C7670}[APRandInt(&r, 0, 3)];
            APRect(c, x + bx + 1, y + row * 12 + 1, 18, 10, tone);
            APHLine(c, x + bx + 1, y + row * 12 + 1, 18, APShade(tone, 1.1f));
            if (APRandInt(&r, 0, 4) == 0) APLine(c, x + bx + 4, y + row * 12 + 4, x + bx + 8, y + row * 12 + 7, APShade(tone, 0.8f));
        }
    })];
    [floors addObject:surface(@"fl.deck", @"Grated Deck", 0x4A505C, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x2A2E36);
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) {
            if (xx % 4 == 0 || yy % 4 == 0) APPx(c, x + xx, y + yy, (xx + yy) % 8 < 4 ? 0x6A727E : 0x5A626E);
        }
        for (int ty = 0; ty < h; ty += 16) for (int tx = 0; tx < w; tx += 32) {
            APHLine(c, x + tx, y + ty, 32, 0x9AA2AE);
            APPx(c, x + tx + 1, y + ty + 1, 0xC8D0D8); APPx(c, x + tx + 30, y + ty + 1, 0xC8D0D8);
        }
    })];
    [floors addObject:surface(@"fl.barn", @"Barn Planks", 0xA87850, ^(APCanvas *c, int x, int y, int w, int h) {
        APRand r = {0xBA2};
        for (int row = 0; row * 8 < h; row++) {
            uint32_t tone = (uint32_t[]){0xA87850, 0x9A6C48, 0xB08458}[row % 3];
            APRect(c, x, y + row * 8, w, 7, tone);
            APHLine(c, x, y + row * 8, w, APShade(tone, 1.1f));
            APHLine(c, x, y + row * 8 + 7, w, 0x5A3A22);
            for (int k = 0; k < w / 14; k++) APHLine(c, x + APRandInt(&r, 0, w - 5), y + row * 8 + APRandInt(&r, 2, 5), 4, APShade(tone, 0.88f));
            for (int px = (row % 2) * 24 + 4; px < w; px += 48) { APPx(c, x + px, y + row * 8 + 2, 0x3A3A40); APPx(c, x + px, y + row * 8 + 5, 0x3A3A40); }
        }
    })];
    [floors addObject:surface(@"fl.mossy", @"Mossy Boards", 0x7A5A3A, ^(APCanvas *c, int x, int y, int w, int h) {
        APRand r = {0x3055};
        for (int row = 0; row * 6 < h; row++) {
            APRect(c, x, y + row * 6, w, 5, row % 2 ? 0x7A5A3A : 0x846240);
            APHLine(c, x, y + row * 6 + 5, w, 0x3E2A18);
            for (int px = (row % 3) * 17; px < w; px += 46) APVLine(c, x + px, y + row * 6, 5, 0x3E2A18);
        }
        for (int i = 0; i < w * h / 25; i++) {
            int mx = APRandInt(&r, 0, w - 1), my = APRandInt(&r, 0, h - 1);
            if ((mx / 20 + my / 14) % 3 == 0) APPx(c, x + mx, y + my, i % 2 ? 0x5E8A3C : 0x4E7A34);
        }
    })];
    [floors addObject:surface(@"fl.sand", @"Sandy Floor", 0xD8C48A, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xD8C48A);
        APRand r = {0x5A4D};
        for (int i = 0; i < w * h / 4; i++) APPx(c, x + APRandInt(&r, 0, w - 1), y + APRandInt(&r, 0, h - 1), i % 3 ? 0xCCB87E : 0xE4D29A);
        for (int yy = 3; yy < h; yy += 9) for (int xx = 0; xx < w; xx++) {
            if ((int)lroundf(sinf((xx + yy * 3) * 0.3f) * 1.5f) == 0) APPx(c, x + xx, y + yy, 0xC4AE74);
        }
        for (int i = 0; i < w * h / 500; i++) {
            int sx = APRandInt(&r, 2, w - 4), sy = APRandInt(&r, 2, h - 4);
            if (i % 2) { APPx(c, x + sx, y + sy, 0xF2D0C8); APPx(c, x + sx + 1, y + sy, 0xE8A8A0); APPx(c, x + sx, y + sy + 1, 0xE8A8A0); }
            else { APPx(c, x + sx, y + sy, 0x9A9488); APPx(c, x + sx + 1, y + sy, 0x8A8478); }
        }
    })];
}

#pragma mark - Seasonal

static void APRegisterSeasonal(NSMutableArray *items) {
    APItemSpec *pumpkin = APSpec(@"pumpkin", @"Jack-o'-Lantern", APLayerFloor, APCategoryCosy, 1, 1, 6, @[@"Grinning", @"Spooky"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 22
        APRect(c, 7, 2, 2, 3, 0x5E7A3A); APPx(c, 9, 2, 0x86B052); APPx(c, 10, 3, 0x86B052);
        APEllipse(c, 1, 5, 14, 13, 0xE07A22);
        APEllipse(c, 4, 5, 8, 13, 0xF08C2E);
        APVLine(c, 5, 6, 11, 0xC0601A); APVLine(c, 10, 6, 11, 0xC0601A);
        APHLine(c, 4, 6, 8, 0xF8A848);
        APOutlineInside(c, 0x5A2A0A);
        // Carved face glowing from the candle inside.
        APCanvas *face = ctx.on ? ctx.emissive : c;
        uint32_t glow = ctx.on ? 0xFFD060 : 0x3A1A08;
        if (ctx.variant) {
            APPx(face, 4, 9, glow); APPx(face, 5, 9, glow); APPx(face, 5, 10, glow);
            APPx(face, 11, 9, glow); APPx(face, 10, 9, glow); APPx(face, 10, 10, glow);
            for (int x = 4; x < 12; x++) APPx(face, x, 13 + (x % 2), glow);
        } else {
            APPx(face, 5, 9, glow); APPx(face, 4, 10, glow); APPx(face, 5, 10, glow); APPx(face, 6, 10, glow);
            APPx(face, 10, 9, glow); APPx(face, 9, 10, glow); APPx(face, 10, 10, glow); APPx(face, 11, 10, glow);
            APHLine(face, 4, 13, 8, glow); APHLine(face, 5, 14, 6, glow); APPx(face, 6, 13, 0xE07A22); APPx(face, 9, 13, 0xE07A22);
        }
        if (ctx.on) {
            APAnim *glowAnim = [APAnim kind:APAnimGlow x:8 y:11 w:0 h:0];
            glowAnim.size = 14; glowAnim.color = 0xFF9A3A;
            [ctx addAnim:glowAnim];
            [ctx addLight:[APLight x:8 y:11 radius:36 color:0xFF9A48 strength:0.5f]];
        }
        APShadow(c, 0, H - 5, 16, 5);
    });
    pumpkin.season = 10;
    pumpkin.toggleable = YES;
    [items addObject:pumpkin];

    APItemSpec *tree = APSpec(@"xmastree", @"Holiday Tree", APLayerFloor, APCategoryCosy, 1, 1, 34, @[@"Classic", @"Snowy"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int H = ctx.height; // 50
        APRect(c, 6, H - 12, 4, 4, 0x6A4228);
        APRect(c, 4, H - 9, 8, 4, 0xC44A44); APHLine(c, 4, H - 9, 8, 0xE06A5A);
        for (int tier = 0; tier < 4; tier++) {
            int top = 4 + tier * 8, height = 11;
            for (int k = 0; k < height; k++) {
                int half = 1 + k * (3 + tier) / height + tier;
                APHLine(c, 8 - half, top + k, half * 2, k % 3 == 0 ? 0x3E7A3E : 0x2E6A34);
                if (ctx.variant && k < 2) APHLine(c, 8 - half, top + k, half * 2, 0xF0F4F8);
            }
        }
        APOutlineInside(c, 0x14301A);
        uint32_t baubles[] = {0xE84A4A, 0xF2C040, 0x5A9AE8, 0xE87AC0};
        int spots[][2] = {{6, 12}, {10, 18}, {5, 22}, {9, 27}, {4, 31}, {11, 33}, {7, 37}};
        for (int i = 0; i < 7; i++) {
            APPx(ctx.emissive, spots[i][0], spots[i][1], baubles[i % 4]);
            APAnim *twinkle = [APAnim kind:APAnimTwinkle x:spots[i][0] y:spots[i][1] w:1 h:1];
            twinkle.color = baubles[i % 4];
            [ctx addAnim:twinkle];
        }
        APPx(ctx.emissive, 8, 1, 0xFFF0A0); APPx(ctx.emissive, 7, 2, 0xFFE070); APPx(ctx.emissive, 9, 2, 0xFFE070);
        APPx(ctx.emissive, 8, 2, 0xFFFFFF); APPx(ctx.emissive, 8, 3, 0xFFE070);
        APAnim *glow = [APAnim kind:APAnimGlow x:8 y:20 w:0 h:0];
        glow.size = 20; glow.color = 0xFFD890; glow.variant = 1;
        [ctx addAnim:glow];
        [ctx addLight:[APLight x:8 y:22 radius:44 color:0xFFD8A0 strength:0.45f]];
        APShadow(c, 0, H - 5, 16, 5);
    });
    tree.season = 12;
    [items addObject:tree];

    [items addObject:({
        APItemSpec *hearts = APSpec(@"heartgarland", @"Heart Garland", APLayerTrim, APCategoryWall, 4, 1, 0, @[@"Valentine", @"Pastel"], ^(APDrawContext *ctx) {
            APCanvas *c = ctx.base;
            for (int x = 0; x < ctx.width; x++) {
                float t = (x % 32) / 32.0f;
                APPx(c, x, (int)lroundf(1 + 20 * t * (1 - t)), 0xE8DCC0);
            }
            uint32_t reds[] = {0xE84A5A, 0xF07A9A, 0xC8304A};
            uint32_t soft[] = {0xF4B8C8, 0xF8D8A0, 0xC8E0F4};
            for (int x = 4, i = 0; x < ctx.width - 4; x += 8, i++) {
                float t = ((x + 2) % 32) / 32.0f;
                int y = (int)lroundf(2 + 20 * t * (1 - t));
                uint32_t col = (ctx.variant ? soft : reds)[i % 3];
                APText(c, @"\u2665", x, y, APFontSmall, col);
                APPx(c, x + 1, y + 1, APMix(col, 0xFFFFFF, 0.5f));
            }
        });
        hearts.season = 2;
        hearts;
    })];
}

void APRegisterThemedItems(NSMutableArray<APItemSpec *> *items) {
    APRegisterSeasonal(items);
    APRegisterCastle(items);
    APRegisterLibrary(items);
    APRegisterSpace(items);
    APRegisterSaloon(items);
    APRegisterTreehouse(items);
    APRegisterUnderwater(items);
}
