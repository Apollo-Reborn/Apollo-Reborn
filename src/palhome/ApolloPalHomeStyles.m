#import "ApolloPalHomeCatalog.h"
#import <math.h>

// Home styles: whole-room themes. Each repaints the shell's trim (beam, crown,
// baseboard, side walls, front lip), paints the world outside the room, tints
// the ambient light and provides a furnished template room.

#define I(identifier, x, y, v) APRoomItem(identifier, x, y, v)

static APStyleSpec *APStyle(NSString *identifier, NSString *title) {
    APStyleSpec *style = [APStyleSpec new];
    style.identifier = identifier;
    style.title = title;
    style.tintR = style.tintG = style.tintB = 1;
    return style;
}

#pragma mark - Shell trim

// Regions of the shell (see APRenderShell): beam y [0, APCeiling), crown just
// under it, baseboard above the floor, side walls and the front lip.
static void APTrimCaps(APCanvas *c, uint32_t cap, uint32_t light, uint32_t dark) {
    int W = APShellWidth, H = APShellHeight;
    APRect(c, 0, 0, APSideWall, H, cap);
    APRect(c, W - APSideWall, 0, APSideWall, H, cap);
    APVLine(c, APSideWall - 1, 0, H, light);
    APVLine(c, W - APSideWall, 0, H, light);
    APVLine(c, 0, 0, H, dark);
    APVLine(c, W - 1, 0, H, dark);
    APRect(c, 0, H - APFrontLip, W, APFrontLip, cap);
    APHLine(c, 0, H - APFrontLip, W, light);
    APHLine(c, 0, H - 1, W, dark);
}

static void APTrimStoneBlocks(APCanvas *c, int x, int y, int w, int h, uint32_t a, uint32_t b, uint32_t mortar) {
    APRect(c, x, y, w, h, mortar);
    for (int yy = 0; yy < h; yy += 6) for (int xx = ((yy / 6) % 2) * -4; xx < w; xx += 8) {
        int x0 = MAX(xx, 0), x1 = MIN(xx + 7, w);
        if (x1 <= x0) continue;
        APRect(c, x + x0, y + yy, x1 - x0, MIN(5, h - yy), ((xx + yy) / 2) % 2 ? a : b);
        APHLine(c, x + x0, y + yy, x1 - x0, APShade(a, 1.15f));
    }
}

static void APShellCastle(APCanvas *c) {
    int W = APShellWidth, H = APShellHeight;
    APTrimStoneBlocks(c, 0, 0, APSideWall, H, 0x6E6A66, 0x625E5A, 0x3A3634);
    APTrimStoneBlocks(c, W - APSideWall, 0, APSideWall, H, 0x6E6A66, 0x625E5A, 0x3A3634);
    APTrimStoneBlocks(c, 0, H - APFrontLip, W, APFrontLip, 0x6E6A66, 0x625E5A, 0x3A3634);
    // Arch voussoirs along the ceiling and a stone plinth.
    APTrimStoneBlocks(c, 0, 0, W, APCeiling + 2, 0x7A7672, 0x6E6A66, 0x3A3634);
    int base = APFloorTop - APBaseboard;
    APTrimStoneBlocks(c, APSideWall, base, W - APSideWall * 2, APBaseboard, 0x7A7672, 0x6E6A66, 0x3A3634);
    APHLine(c, APSideWall, base, W - APSideWall * 2, 0xA09A94);
}

static void APShellLibrary(APCanvas *c) {
    int W = APShellWidth;
    APRamp w = APRampNamed(@"walnut");
    APTrimCaps(c, w.d, w.m, w.o);
    APRect(c, 0, 0, W, APCeiling, w.d);
    APHLine(c, 0, APCeiling - 1, W, 0xC8962A);
    APRect(c, APSideWall, APCeiling, W - APSideWall * 2, 2, w.l);
    APHLine(c, APSideWall, APCeiling + 2, W - APSideWall * 2, 0xC8962A);
    int base = APFloorTop - APBaseboard;
    APRect(c, APSideWall, base, W - APSideWall * 2, APBaseboard, w.m);
    APHLine(c, APSideWall, base, W - APSideWall * 2, 0xC8962A);
    APHLine(c, APSideWall, base + APBaseboard - 1, W - APSideWall * 2, w.o);
}

static void APShellSpace(APCanvas *c) {
    int W = APShellWidth, H = APShellHeight;
    APTrimCaps(c, 0x4A505C, 0x8A929E, 0x1E2228);
    for (int y = 6; y < H; y += 12) { APPx(c, 2, y, 0xC8D0D8); APPx(c, W - 3, y, 0xC8D0D8); }
    // Hazard-striped girder and a glowing light strip.
    APRect(c, 0, 0, W, APCeiling, 0x2A2E36);
    for (int x = 0; x < W; x++) if ((x / 3) % 2) APPx(c, x, 1, 0xE8B830);
    APHLine(c, 0, APCeiling - 1, W, 0x8A929E);
    APRect(c, APSideWall, APCeiling, W - APSideWall * 2, 2, 0x9AE8F4);
    APHLine(c, APSideWall, APCeiling + 2, W - APSideWall * 2, 0x3A6A7A);
    int base = APFloorTop - APBaseboard;
    APRect(c, APSideWall, base, W - APSideWall * 2, APBaseboard, 0x4A505C);
    APHLine(c, APSideWall, base, W - APSideWall * 2, 0x9AA2AE);
    for (int x = APSideWall + 2; x < W - APSideWall - 2; x += 3) APVLine(c, x, base + 2, 3, 0x2A2E36);
    for (int x = APSideWall; x < W - APSideWall; x++) if ((x / 2) % 2) APPx(c, x, H - APFrontLip + 2, 0xE8B830);
}

static void APShellSaloon(APCanvas *c) {
    int W = APShellWidth;
    APTrimCaps(c, 0x5A3A22, 0x8A5E3A, 0x2A1A10);
    APRect(c, 0, 0, W, APCeiling, 0x4A2E1C);
    for (int x = 0; x < W; x += 9) APVLine(c, x, 0, APCeiling, 0x2A1A10);
    APHLine(c, 0, APCeiling - 1, W, 0x7A5032);
    APRect(c, APSideWall, APCeiling, W - APSideWall * 2, 2, 0x8A5E3A);
    int base = APFloorTop - APBaseboard;
    APRect(c, APSideWall, base, W - APSideWall * 2, APBaseboard, 0x6A4228);
    APHLine(c, APSideWall, base, W - APSideWall * 2, 0x9A6A44);
    for (int x = APSideWall + 4; x < W - APSideWall; x += 18) APPx(c, x, base + 3, 0x3A3A40);
}

static void APShellTreehouse(APCanvas *c) {
    int W = APShellWidth, H = APShellHeight;
    APTrimCaps(c, 0x5E3E24, 0x7A5434, 0x2E1C10);
    for (int y = 3; y < H; y += 5) { APPx(c, 2, y, 0x4A2E1C); APPx(c, W - 3, y + 2, 0x4A2E1C); }
    // A great branch for a beam, with leaves tumbling over the crown.
    APRect(c, 0, 0, W, APCeiling + 1, 0x6A4628);
    APHLine(c, 0, 0, W, 0x8A6240);
    for (int x = 0; x < W; x += 7) APPx(c, x, 2, 0x4A2E1C);
    for (int x = APSideWall; x < W - APSideWall; x++) {
        int d = (int)lroundf(1.5f + sinf(x * 0.5f) * 1.5f + sinf(x * 0.21f) * 1.2f);
        APVLine(c, x, APCeiling, MAX(1, d), x % 3 ? 0x4E8A3E : 0x6AA84A);
    }
    int base = APFloorTop - APBaseboard;
    APRect(c, APSideWall, base, W - APSideWall * 2, APBaseboard, 0x5E3E24);
    for (int x = APSideWall; x < W - APSideWall; x++) if (sinf(x * 0.7f) > 0.2f) APPx(c, x, base, 0x5E8A3C);
    APRect(c, 0, H - APFrontLip, W, APFrontLip, 0x5E3E24);
    for (int x = 0; x < W; x++) if (sinf(x * 0.45f) > 0) APPx(c, x, H - APFrontLip, 0x5E8A3C);
}

static void APShellUnderwater(APCanvas *c) {
    int W = APShellWidth, H = APShellHeight;
    APRand r = {0x5EA};
    APTrimCaps(c, 0x3A4A54, 0x5A6E78, 0x1A2228);
    for (int i = 0; i < H / 3; i++) { APPx(c, APRandInt(&r, 1, 4), APRandInt(&r, 0, H - 1), 0x6A7E88); APPx(c, W - APRandInt(&r, 2, 5), APRandInt(&r, 0, H - 1), 0x6A7E88); }
    // Rocky overhang with hanging seaweed, sand drifts along the base.
    APRect(c, 0, 0, W, APCeiling + 1, 0x3A4A54);
    for (int x = 0; x < W; x++) if (APRandInt(&r, 0, 3) == 0) APPx(c, x, APCeiling + 1, 0x3A4A54);
    for (int x = APSideWall + 3; x < W - APSideWall; x += APRandInt(&r, 6, 14)) {
        int len = APRandInt(&r, 4, 10);
        for (int k = 0; k < len; k++) APPx(c, x + (int)lroundf(sinf(k * 0.8f)), APCeiling + 1 + k, k % 2 ? 0x3E8A4A : 0x5AA85A);
    }
    int base = APFloorTop - APBaseboard;
    for (int x = APSideWall; x < W - APSideWall; x++) {
        int d = (int)lroundf(4 + sinf(x * 0.2f) * 2);
        APVLine(c, x, APFloorTop - d, d, x % 4 ? 0xD8C48A : 0xCCB87E);
    }
    (void)base;
    APRect(c, 0, H - APFrontLip, W, APFrontLip, 0x3A4A54);
    APHLine(c, 0, H - APFrontLip, W, 0x5A6E78);
}

#pragma mark - Backdrops

static void APStars(APCanvas *c, int w, int h, int density, uint32_t seed, float maxY) {
    APRand r = {seed};
    for (int i = 0; i < w * h / density; i++) {
        int x = APRandInt(&r, 0, w - 1), y = APRandInt(&r, 0, (int)(h * maxY));
        APPx(c, x, y, i % 5 ? 0x6A7098 : 0xE8E4D0);
        if (i % 37 == 0) { APPx(c, x - 1, y, 0x6A7098); APPx(c, x + 1, y, 0x6A7098); APPx(c, x, y - 1, 0x6A7098); APPx(c, x, y + 1, 0x6A7098); }
    }
}

static void APBackdropCastle(APCanvas *c, int w, int h) {
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) APPx(c, x, y, 0x18161A);
    for (int row = 0; row * 10 < h; row++) for (int bx = (row % 2) * -10; bx < w; bx += 20) {
        APRect(c, bx + 1, row * 10 + 1, 18, 8, (row + bx / 20) % 3 ? 0x221F24 : 0x262328);
        APHLine(c, bx + 1, row * 10 + 1, 18, 0x2C2930);
    }
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float t = fabsf(y - h * 0.45f) / (h * 0.55f);
        if (APBayer(x, y) < t * 0.7f) APPx(c, x, y, 0x121014);
    }
}

static void APBackdropLibrary(APCanvas *c, int w, int h) {
    APRect(c, 0, 0, w, h, 0x160F0C);
    uint32_t spines[] = {0x2A1414, 0x14202A, 0x1A2A1A, 0x2A2414, 0x24142A};
    APRand r = {0x1B8};
    for (int shelf = 8; shelf < h; shelf += 22) {
        APHLine(c, 0, shelf + 14, w, 0x2A1C14);
        for (int x = 0; x < w; ) {
            int bw = APRandInt(&r, 2, 3), bh = APRandInt(&r, 9, 13);
            APRect(c, x, shelf + 14 - bh, bw, bh, spines[APRandInt(&r, 0, 4)]);
            x += bw + (APRandInt(&r, 0, 6) == 0 ? 3 : 0);
        }
    }
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float t = fabsf(y - h * 0.45f) / (h * 0.55f);
        if (APBayer(x, y) < t * 0.8f) APPx(c, x, y, 0x0E0907);
    }
}

static void APBackdropSpace(APCanvas *c, int w, int h) {
    APRect(c, 0, 0, w, h, 0x05060F);
    // A soft violet nebula, dithered.
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        float d = hypotf((x - w * 0.25f) / (w * 0.5f), (y - h * 0.3f) / (h * 0.25f));
        float n = (1 - d) + sinf(x * 0.13f + y * 0.07f) * 0.15f;
        if (n > 0 && APBayer(x, y) < n * 0.5f) APPx(c, x, y, n > 0.5f ? 0x2A1A4A : 0x160E2E);
    }
    APStars(c, w, h, 30, 0x5ACE, 1);
    // A ringed planet peeking in from the corner.
    int px = w - 18, py = h - 40, pr = 26;
    for (int y = py - pr; y <= py + pr; y++) for (int x = px - pr; x <= px + pr; x++) {
        float d = hypotf(x - px, y - py);
        if (d > pr) continue;
        float band = sinf((y - py) * 0.5f);
        uint32_t col = band > 0.3f ? 0xC88A5A : band > -0.4f ? 0xA86A44 : 0xE0A870;
        if (x - px > d * 0.4f) col = APShade(col, 0.6f); // terminator
        APPx(c, x, y, col);
    }
    for (int x = px - pr - 14; x < px + pr + 14; x++) {
        int y = py + (int)lroundf((x - px) * 0.25f);
        if (hypotf(x - px, y - py) < pr && x > px - pr / 2) continue;
        APPx(c, x, y, 0xE8D8B0); APPx(c, x, y + 1, 0xA89878);
    }
    APCircle(c, 22, 30, 4, 0xB8B8C0); APPx(c, 21, 29, 0x8A8A94); APCircle(c, 24, 30, 3, 0x9A9AA4);
}

static void APBackdropSaloon(APCanvas *c, int w, int h) {
    uint32_t stops[] = {0x0E1030, 0x1E1A4A, 0x4A2A5A, 0xA0485A, 0xE88A4A};
    for (int y = 0; y < h; y++) {
        float t = y / (float)(h - 1) * 4;
        int i = MIN((int)t, 3);
        for (int x = 0; x < w; x++) APPx(c, x, y, APBayer(x, y) < t - i ? stops[i + 1] : stops[i]);
    }
    APStars(c, w, h, 40, 0x5A1, 0.5f);
    APCircle(c, w / 4, h / 6, 5, 0xF4EAC4);
    // Mesas and saguaros.
    for (int x = 0; x < w; x++) {
        float m = sinf(x * 0.035f) * 18 + sinf(x * 0.11f) * 4;
        int top = (int)(h - 46 - fmaxf(0, m) * 1.4f);
        if (m > 9) top = (int)(h - 46 - 14 * 1.4f); // flat mesa tops
        APVLine(c, x, top, h - top, 0x2A1420);
        if (APBayer(x, top) < 0.5f) APPx(c, x, top, 0x4A2430);
    }
    for (int k = 0; k < w / 50 + 1; k++) {
        int cx = 18 + k * 50, base = h - 30;
        APRect(c, cx, base - 18, 3, 18, 0x140A10);
        APRect(c, cx - 4, base - 12, 2, 6, 0x140A10); APRect(c, cx - 4, base - 8, 4, 2, 0x140A10);
        APRect(c, cx + 5, base - 15, 2, 6, 0x140A10); APRect(c, cx + 3, base - 11, 4, 2, 0x140A10);
    }
    APRect(c, 0, h - 30, w, 30, 0x140A10);
}

static void APBackdropTreehouse(APCanvas *c, int w, int h) {
    uint32_t stops[] = {0x0A1420, 0x0E2228, 0x12302A};
    for (int y = 0; y < h; y++) {
        float t = y / (float)(h - 1) * 2;
        int i = MIN((int)t, 1);
        for (int x = 0; x < w; x++) APPx(c, x, y, APBayer(x, y) < t - i ? stops[i + 1] : stops[i]);
    }
    APStars(c, w, h, 90, 0x7EE, 0.35f);
    APCircle(c, w - 30, 26, 6, 0xE8E4C8); APCircle(c, w - 27, 24, 5, 0x0A1420);
    APRand r = {0x7EE5};
    // Trunks of the forest around the treehouse, and leafy clumps.
    for (int k = 0; k < w / 28 + 2; k++) {
        int tx = k * 28 + APRandInt(&r, -6, 6), tw = APRandInt(&r, 6, 11);
        APRect(c, tx, 0, tw, h, 0x0A1210);
        APVLine(c, tx + 1, 0, h, 0x101C18);
    }
    for (int i = 0; i < w / 6; i++) {
        int lx = APRandInt(&r, -10, w), ly = APRandInt(&r, -6, 30);
        APEllipse(c, lx, ly, APRandInt(&r, 14, 26), APRandInt(&r, 8, 14), i % 2 ? 0x0E2A1E : 0x12321E);
    }
    APRect(c, 0, h - 20, w, 20, 0x0A1810);
    for (int x = 0; x < w; x += 3) APVLine(c, x, h - 22 - (x * 7 % 5), 3, 0x14301E);
}

static void APBackdropUnderwater(APCanvas *c, int w, int h) {
    uint32_t stops[] = {0x1E6A8A, 0x14506E, 0x0C3450, 0x081E34};
    for (int y = 0; y < h; y++) {
        float t = y / (float)(h - 1) * 3;
        int i = MIN((int)t, 2);
        for (int x = 0; x < w; x++) APPx(c, x, y, APBayer(x, y) < t - i ? stops[i + 1] : stops[i]);
    }
    // Light rays slanting down from the surface.
    for (int k = 0; k < 5; k++) {
        int x0 = k * w / 4 - 10;
        for (int y = 0; y < h * 2 / 3; y++) for (int dx = 0; dx < 8; dx++) {
            int x = x0 + dx + y / 3;
            if (x >= 0 && x < w && APBayer(x, y) < 0.22f * (1 - y / (h * 0.66f))) APPx(c, x, y, 0x5AB0C8);
        }
    }
    APRand r = {0x5EA2};
    APRect(c, 0, h - 24, w, 24, 0x2E3A30);
    for (int x = 0; x < w; x++) APVLine(c, x, h - 26 + (int)lroundf(sinf(x * 0.15f) * 2), 3, 0x3A4A3A);
    for (int k = 0; k < w / 12; k++) {
        int sx = APRandInt(&r, 0, w), len = APRandInt(&r, 14, 40);
        for (int y = 0; y < len; y++) APPx(c, sx + (int)lroundf(sinf(y * 0.3f + k) * 1.5f), h - 24 - y, 0x0E3A2A);
    }
}

#pragma mark - Registry

void APRegisterStyles(NSMutableArray<APStyleSpec *> *styles) {
    APStyleSpec *cottage = APStyle(@"cottage", @"Cosy Cottage");
    cottage.room = ^NSDictionary *{
        return @{@"style": @"cottage", @"wallpaper": @"wp.rosebud", @"floor": @"fl.oak", @"lighting": @"auto", @"items": @[
            I(@"fireplace", 0, 0, 0), I(@"lamp.floor", 3, 0, 0), I(@"sofa", 4, 0, 0), I(@"plant.monstera", 7, 0, 0),
            I(@"rug.round", 2, 2, 0), I(@"petbed.cushion", 1, 1, 0), I(@"logbasket", 3, 1, 0), I(@"table.coffee", 3, 3, 0),
            I(@"armchair", 6, 3, 3), I(@"table.lantern", 7, 2, 1), I(@"futon", 0, 4, 0), I(@"bowls", 7, 6, 0),
            I(@"plant.fig", 0, 3, 1), I(@"yarn", 6, 5, 0),
            I(@"window", 4, 0, 0), I(@"art.mountains", 1, 0, 1), I(@"clock.cuckoo", 7, 0, 0),
            I(@"fairylights", 0, 0, 0), I(@"fairylights", 4, 0, 0)]};
    };
    [styles addObject:cottage];

    APStyleSpec *castle = APStyle(@"castle", @"Castle Keep");
    castle.paintShell = ^(APCanvas *c) { APShellCastle(c); };
    castle.paintBackdrop = ^(APCanvas *c, int w, int h) { APBackdropCastle(c, w, h); };
    castle.tintR = 0.96f; castle.tintG = 0.92f; castle.tintB = 0.96f;
    castle.room = ^NSDictionary *{
        return @{@"style": @"castle", @"wallpaper": @"wp.castle", @"floor": @"fl.hall", @"lighting": @"evening", @"items": @[
            I(@"fireplace", 0, 0, 0), I(@"armour", 3, 0, 0), I(@"throne", 4, 0, 0), I(@"armour", 6, 0, 0), I(@"plant.fig", 7, 0, 1),
            I(@"rug.woven", 2, 2, 0), I(@"petbed.royal", 3, 3, 0), I(@"chest", 6, 2, 0), I(@"table.lantern", 7, 4, 1),
            I(@"logbasket", 0, 1, 0), I(@"bowls", 0, 6, 0), I(@"bookstack", 7, 6, 0),
            I(@"tapestry", 4, 0, 0), I(@"banner", 3, 0, 0), I(@"banner", 6, 0, 1), I(@"torch", 1, 0, 0), I(@"torch", 7, 0, 0)]};
    };
    [styles addObject:castle];

    APStyleSpec *library = APStyle(@"library", @"Grand Library");
    library.paintShell = ^(APCanvas *c) { APShellLibrary(c); };
    library.paintBackdrop = ^(APCanvas *c, int w, int h) { APBackdropLibrary(c, w, h); };
    library.backdropAnim = APBackdropAnimDust;
    library.room = ^NSDictionary *{
        return @{@"style": @"library", @"wallpaper": @"wp.library", @"floor": @"fl.parquet", @"lighting": @"evening", @"items": @[
            I(@"bookshelf", 0, 0, 1), I(@"bookshelf", 2, 0, 1), I(@"grandfather", 4, 0, 0), I(@"bookshelf", 5, 0, 1), I(@"plant.fig", 7, 0, 1),
            I(@"rug.woven", 2, 2, 2), I(@"armchair", 1, 4, 2), I(@"desk", 5, 3, 0), I(@"globe", 7, 3, 0),
            I(@"bookstack", 0, 2, 0), I(@"petbed.cushion", 3, 3, 2), I(@"table.lantern", 3, 5, 1), I(@"bookstack", 7, 6, 0),
            I(@"bowls", 0, 6, 0),
            I(@"art.map", 0, 0, 0), I(@"sconce", 2, 0, 0), I(@"sconce", 3, 0, 0), I(@"art.portrait", 7, 0, 1)]};
    };
    [styles addObject:library];

    APStyleSpec *space = APStyle(@"space", @"Space Station");
    space.paintShell = ^(APCanvas *c) { APShellSpace(c); };
    space.paintBackdrop = ^(APCanvas *c, int w, int h) { APBackdropSpace(c, w, h); };
    space.backdropAnim = APBackdropAnimStars;
    space.tintR = 0.86f; space.tintG = 0.92f; space.tintB = 1.08f;
    space.room = ^NSDictionary *{
        return @{@"style": @"space", @"wallpaper": @"wp.hull", @"floor": @"fl.deck", @"lighting": @"evening", @"items": @[
            I(@"console", 0, 0, 0), I(@"hydroponics", 2, 0, 0), I(@"reactor", 3, 0, 0), I(@"hydroponics", 4, 0, 1), I(@"petbed.pod", 6, 0, 0),
            I(@"rug.round", 2, 2, 2), I(@"robot", 3, 3, 0), I(@"armchair", 6, 3, 2), I(@"table.coffee", 4, 4, 2),
            I(@"futon", 0, 5, 2), I(@"plant.cactus", 7, 5, 0), I(@"bowls", 5, 6, 0),
            I(@"porthole", 0, 0, 0), I(@"porthole", 6, 0, 1), I(@"neon.upvote", 4, 0, 1)]};
    };
    [styles addObject:space];

    APStyleSpec *saloon = APStyle(@"saloon", @"Wild West Saloon");
    saloon.paintShell = ^(APCanvas *c) { APShellSaloon(c); };
    saloon.paintBackdrop = ^(APCanvas *c, int w, int h) { APBackdropSaloon(c, w, h); };
    saloon.backdropAnim = APBackdropAnimStars;
    saloon.tintR = 1.04f; saloon.tintG = 0.96f; saloon.tintB = 0.9f;
    saloon.room = ^NSDictionary *{
        return @{@"style": @"saloon", @"wallpaper": @"wp.saloon", @"floor": @"fl.barn", @"lighting": @"evening", @"items": @[
            I(@"bar", 0, 0, 0), I(@"barrel", 3, 0, 0), I(@"barrel", 4, 0, 1), I(@"piano", 5, 0, 0), I(@"plant.cactus", 7, 0, 0),
            I(@"rug.cowhide", 2, 2, 0), I(@"petbed.hay", 3, 4, 0), I(@"table.lantern", 0, 2, 0), I(@"armchair", 5, 3, 0),
            I(@"barrel", 7, 3, 0), I(@"plant.cactus", 0, 6, 1), I(@"bowls", 6, 6, 0), I(@"stove", 7, 5, 0),
            I(@"wagonwheel", 0, 0, 0), I(@"art.wanted", 3, 0, 0), I(@"skull", 6, 0, 0),
            I(@"bunting", 0, 0, 0), I(@"bunting", 4, 0, 0)]};
    };
    [styles addObject:saloon];

    APStyleSpec *treehouse = APStyle(@"treehouse", @"Treehouse");
    treehouse.paintShell = ^(APCanvas *c) { APShellTreehouse(c); };
    treehouse.paintBackdrop = ^(APCanvas *c, int w, int h) { APBackdropTreehouse(c, w, h); };
    treehouse.backdropAnim = APBackdropAnimFireflies;
    treehouse.tintR = 0.94f; treehouse.tintG = 1.0f; treehouse.tintB = 0.94f;
    treehouse.room = ^NSDictionary *{
        return @{@"style": @"treehouse", @"wallpaper": @"wp.bark", @"floor": @"fl.mossy", @"lighting": @"auto", @"items": @[
            I(@"stove", 0, 0, 2), I(@"mushroom", 1, 0, 0), I(@"fireflyjar", 4, 0, 0), I(@"petbed.hammock", 5, 0, 0), I(@"plant.monstera", 7, 0, 0),
            I(@"rug.round", 1, 2, 0), I(@"stump", 2, 3, 0), I(@"mushroom", 1, 3, 2), I(@"mushroom", 4, 4, 1),
            I(@"futon", 0, 5, 0), I(@"yarn", 6, 5, 0), I(@"plant.fig", 7, 4, 0), I(@"bowls", 7, 6, 0), I(@"fireflyjar", 6, 2, 1),
            I(@"window", 2, 0, 4), I(@"birdhouse", 5, 0, 0), I(@"art.fern", 1, 0, 0),
            I(@"vines", 0, 0, 0), I(@"vines", 4, 0, 1)]};
    };
    [styles addObject:treehouse];

    APStyleSpec *sea = APStyle(@"underwater", @"Under the Sea");
    sea.paintShell = ^(APCanvas *c) { APShellUnderwater(c); };
    sea.paintBackdrop = ^(APCanvas *c, int w, int h) { APBackdropUnderwater(c, w, h); };
    sea.backdropAnim = APBackdropAnimBubbles;
    sea.tintR = 0.78f; sea.tintG = 0.95f; sea.tintB = 1.12f;
    sea.room = ^NSDictionary *{
        return @{@"style": @"underwater", @"wallpaper": @"wp.reef", @"floor": @"fl.sand", @"lighting": @"day", @"items": @[
            I(@"kelp", 0, 0, 0), I(@"coral", 1, 0, 0), I(@"chest", 2, 0, 1), I(@"petbed.clam", 3, 0, 0), I(@"divehelmet", 6, 0, 0),
            I(@"coral", 7, 0, 1), I(@"rug.round", 2, 3, 2), I(@"coral", 0, 4, 2), I(@"kelp", 7, 4, 1), I(@"futon", 4, 5, 2),
            I(@"bowls", 2, 6, 0), I(@"kelp", 5, 2, 0),
            I(@"porthole", 0, 0, 2), I(@"anchor", 6, 0, 0),
            I(@"jellylamp", 3, 0, 0), I(@"jellylamp", 5, 0, 1)]};
    };
    [styles addObject:sea];
}
