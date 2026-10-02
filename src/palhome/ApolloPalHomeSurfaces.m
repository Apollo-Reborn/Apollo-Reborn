#import "ApolloPalHomeCatalog.h"

// Wallpapers and floors. Each paints a pattern into a rect aligned to its
// own origin so tiles line up with the room grid.

static APSurfaceSpec *APSurface(NSString *identifier, NSString *title, uint32_t swatch,
                                void (^paint)(APCanvas *c, int x, int y, int w, int h)) {
    APSurfaceSpec *spec = [APSurfaceSpec new];
    spec.identifier = identifier;
    spec.title = title;
    spec.swatch = swatch;
    spec.paint = paint;
    return spec;
}

#pragma mark - Wallpaper motifs

static void APSprig(APCanvas *c, int x, int y, uint32_t petal, uint32_t centre, uint32_t leaf) {
    APPx(c, x, y - 1, petal); APPx(c, x - 1, y, petal); APPx(c, x + 1, y, petal); APPx(c, x, y + 1, petal);
    APPx(c, x, y, centre);
    APPx(c, x + 1, y + 2, leaf); APPx(c, x + 2, y + 2, leaf);
}

static void APTinyStar(APCanvas *c, int x, int y, uint32_t rgb, BOOL big) {
    APPx(c, x, y, rgb);
    if (!big) return;
    APPx(c, x - 1, y, APShade(rgb, 0.7f)); APPx(c, x + 1, y, APShade(rgb, 0.7f));
    APPx(c, x, y - 1, APShade(rgb, 0.7f)); APPx(c, x, y + 1, APShade(rgb, 0.7f));
}

static void APWoodPanels(APCanvas *c, int x, int y, int w, int h, APRamp wood) {
    APRect(c, x, y, w, h, wood.m);
    APHLine(c, x, y, w, wood.h);          // dado rail cap
    APHLine(c, x, y + 1, w, wood.l);
    APHLine(c, x, y + 2, w, wood.d);
    int panelW = 14;
    for (int px = x + 2; px + panelW <= x + w; px += panelW + 2) {
        APRectOutline(c, px, y + 5, panelW, h - 8, wood.d);
        APHLine(c, px + 1, y + 6, panelW - 2, wood.l);
        APVLine(c, px + 1, y + 6, h - 10, wood.l);
    }
}

void APRegisterSurfaces(NSMutableArray<APSurfaceSpec *> *walls, NSMutableArray<APSurfaceSpec *> *floors) {
    [walls addObject:APSurface(@"wp.rosebud", @"Rosebud", 0xD49C8C, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xD49C8C);
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) {
            if (xx % 8 == 0) APDitherRect(c, x + xx, y + yy, 1, 1, 0xC88E80, 0.5f);
        }
        for (int yy = 3; yy < h; yy += 10) for (int xx = 4 + ((yy / 10) % 2) * 8; xx < w; xx += 16) {
            APSprig(c, x + xx, y + yy, 0xB0605A, 0xF0C0A8, 0x7E8A5A);
        }
    })];
    [walls addObject:APSurface(@"wp.forest", @"Forest Stripe", 0x44604A, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int xx = 0; xx < w; xx++) {
            int band = xx % 12;
            uint32_t col = band < 6 ? 0x3E5A44 : 0x4A6A50;
            if (band == 9) col = 0x8C8656;
            APRect(c, x + xx, y, 1, h, col);
        }
        for (int yy = 2; yy < h; yy += 8) for (int xx = 3; xx < w; xx += 12) APPx(c, x + xx, y + yy, 0x5A7A5E);
    })];
    [walls addObject:APSurface(@"wp.midnight", @"Midnight Stars", 0x2A3050, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x2A3050);
        APDitherRect(c, x, y, w, h, 0x303860, 0.25f);
        APRand r = {0xC0FFEE};
        for (int i = 0; i < w * h / 40; i++) {
            int sx = APRandInt(&r, 1, w - 2), sy = APRandInt(&r, 1, h - 2);
            APTinyStar(c, x + sx, y + sy, i % 5 ? 0xB8B090 : 0xF0DC98, i % 7 == 0);
        }
        for (int yy = 6; yy < h; yy += 16) for (int xx = 8 + (yy / 16 % 2) * 16; xx < w; xx += 32) {
            // Crescent moons in the pattern.
            APCircle(c, x + xx, y + yy, 2, 0xE8D48C);
            APCircle(c, x + xx + 1, y + yy - 1, 2, 0x2A3050);
        }
    })];
    [walls addObject:APSurface(@"wp.logcabin", @"Log Cabin", 0x8A5A36, ^(APCanvas *c, int x, int y, int w, int h) {
        APRamp wood = APRampNamed(@"oak");
        APRand r = {0x10C};
        for (int yy = 0; yy < h; yy += 8) {
            APRect(c, x, y + yy, w, 8, wood.m);
            APHLine(c, x, y + yy + 1, w, wood.l);
            APHLine(c, x, y + yy + 2, w, wood.h);
            APHLine(c, x, y + yy + 6, w, wood.d);
            APHLine(c, x, y + yy + 7, w, wood.o);
            for (int k = 0; k < w / 10; k++) {
                int kx = APRandInt(&r, 0, w - 3);
                APPx(c, x + kx, y + yy + 4, wood.d); APPx(c, x + kx + 1, y + yy + 4, wood.d);
            }
        }
    })];
    [walls addObject:APSurface(@"wp.brick", @"Red Brick", 0xA05040, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x6A4034);
        APRand r = {0xB41C};
        uint32_t tones[] = {0x9A4A38, 0xA85640, 0x8E4432, 0xB06248};
        for (int row = 0; row * 6 < h; row++) {
            int offset = row % 2 ? 6 : 0;
            for (int bx = -offset; bx < w; bx += 12) {
                uint32_t col = tones[APRandInt(&r, 0, 3)];
                APRect(c, x + bx, y + row * 6, 11, 5, col);
                APHLine(c, x + bx, y + row * 6, 11, APShade(col, 1.12f));
                APHLine(c, x + bx, y + row * 6 + 4, 11, APShade(col, 0.85f));
            }
        }
        // Knock the brick bleed back into the wall's rect.
    })];
    [walls addObject:APSurface(@"wp.lavender", @"Lavender Trellis", 0x9A88B8, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x9A88B8);
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) {
            if ((xx + yy) % 10 == 0 || (xx - yy + 1000) % 10 == 0) APPx(c, x + xx, y + yy, 0x8676A6);
            if ((xx + yy) % 10 == 0 && (xx - yy + 1000) % 10 == 0) {
                APPx(c, x + xx, y + yy, 0xD8CCEC);
            }
        }
    })];
    [walls addObject:APSurface(@"wp.gingham", @"Mint Gingham", 0xA8D0B8, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) {
            BOOL col = (xx / 4) % 2, row = (yy / 4) % 2;
            APPx(c, x + xx, y + yy, col && row ? 0x74A888 : (col || row) ? 0x9CC8AE : 0xCCE6D6);
        }
    })];
    [walls addObject:APSurface(@"wp.sunny", @"Sunny Wainscot", 0xE8C870, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xE4C470);
        for (int yy = 3; yy < h; yy += 8) for (int xx = 3 + (yy / 8 % 2) * 6; xx < w; xx += 12) {
            APPx(c, x + xx, y + yy, 0xF8ECC0); APPx(c, x + xx + 1, y + yy, 0xF8ECC0);
            APPx(c, x + xx, y + yy + 1, 0xF8ECC0); APPx(c, x + xx + 1, y + yy + 1, 0xD8A850);
        }
        int wainscot = h * 45 / 100;
        APWoodPanels(c, x, y + h - wainscot, w, wainscot, APRampNamed(@"oak"));
    })];
    [walls addObject:APSurface(@"wp.plaster", @"Cream Plaster", 0xE4D4B8, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xE4D4B8);
        APRand r = {0x9A57};
        for (int i = 0; i < w * h / 9; i++) APPx(c, x + APRandInt(&r, 0, w - 1), y + APRandInt(&r, 0, h - 1), 0xD8C8AA);
        for (int i = 0; i < w * h / 40; i++) APPx(c, x + APRandInt(&r, 0, w - 1), y + APRandInt(&r, 0, h - 1), 0xECE0C8);
    })];
    [walls addObject:APSurface(@"wp.damask", @"Burgundy Damask", 0x6A2A30, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x6A2A30);
        static const char *motif[] = {
            "....#....", "...###...", "..#.#.#..", ".#..#..#.", "##.###.##", ".#..#..#.", "..#.#.#..", "...###...", "....#....",
        };
        for (int ty = 0; ty < h; ty += 12) for (int tx = (ty / 12 % 2) * 8; tx < w; tx += 16) {
            for (int my = 0; my < 9; my++) for (int mx = 0; mx < 9; mx++) {
                if (motif[my][mx] == '#') APPx(c, x + tx + mx, y + ty + my + 1, 0x86404A);
            }
            APPx(c, x + tx + 4, y + ty + 5, 0xA85A58);
        }
    })];
    [walls addObject:APSurface(@"wp.sky", @"Cloud Nine", 0x9CC4E0, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x9CC4E0);
        APDitherRect(c, x, y + h / 2, w, h - h / 2, 0xB0D2EA, 0.4f);
        APRand r = {0xC10D};
        for (int i = 0; i < w / 14; i++) {
            int cx = APRandInt(&r, 0, w), cy = APRandInt(&r, 2, h - 6);
            APEllipse(c, x + cx - 5, y + cy, 10, 4, 0xF2F6FA);
            APEllipse(c, x + cx - 2, y + cy - 2, 6, 4, 0xF2F6FA);
            APHLine(c, x + cx - 4, y + cy + 3, 8, 0xD4E4F0);
        }
    })];

    [floors addObject:APSurface(@"fl.oak", @"Oak Planks", 0xA8744A, ^(APCanvas *c, int x, int y, int w, int h) {
        APRand r = {0x0A4};
        uint32_t tones[] = {0xA8744A, 0x9E6C44, 0xB07C50, 0xA27048};
        for (int row = 0; row * 6 < h; row++) {
            int start = -APRandInt(&r, 0, 30);
            for (int px = start; px < w; ) {
                int len = APRandInt(&r, 26, 44);
                uint32_t col = tones[APRandInt(&r, 0, 3)];
                APRect(c, x + MAX(px, 0), y + row * 6, MIN(len, w - MAX(px, 0)) + MIN(px, 0), 5, col);
                APHLine(c, x + MAX(px, 0), y + row * 6, MIN(len, w - MAX(px, 0)) + MIN(px, 0), APShade(col, 1.08f));
                for (int g = 0; g < len / 9; g++) {
                    int gx = px + APRandInt(&r, 1, len - 3);
                    if (gx >= 0 && gx < w - 2) APHLine(c, x + gx, y + row * 6 + APRandInt(&r, 2, 3), 2, APShade(col, 0.9f));
                }
                if (px + len < w && px + len >= 0) APVLine(c, x + px + len, y + row * 6, 5, 0x6A4228);
                px += len + 1;
            }
            APHLine(c, x, y + row * 6 + 5, w, 0x6E4629);
        }
    })];
    [floors addObject:APSurface(@"fl.walnut", @"Walnut Planks", 0x6A4A30, ^(APCanvas *c, int x, int y, int w, int h) {
        APRand r = {0x3A1};
        uint32_t tones[] = {0x6E4A30, 0x64422A, 0x785234, 0x6A462C};
        for (int row = 0; row * 7 < h; row++) {
            int start = -APRandInt(&r, 0, 30);
            for (int px = start; px < w; ) {
                int len = APRandInt(&r, 34, 54);
                uint32_t col = tones[APRandInt(&r, 0, 3)];
                int from = MAX(px, 0), to = MIN(px + len, w);
                APRect(c, x + from, y + row * 7, to - from, 6, col);
                APHLine(c, x + from, y + row * 7, to - from, APShade(col, 1.12f));
                for (int g = 0; g < len / 8; g++) {
                    int gx = px + APRandInt(&r, 1, len - 4);
                    if (gx >= 0 && gx < w - 3) APHLine(c, x + gx, y + row * 7 + APRandInt(&r, 2, 4), 3, APShade(col, 0.88f));
                }
                if (px + len < w && px + len >= 0) APVLine(c, x + px + len, y + row * 7, 6, 0x3A2414);
                px += len + 1;
            }
            APHLine(c, x, y + row * 7 + 6, w, 0x3E2818);
        }
    })];
    [floors addObject:APSurface(@"fl.parquet", @"Parquet", 0xB88452, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int ty = 0; ty < h; ty += 8) for (int tx = 0; tx < w; tx += 8) {
            BOOL across = ((tx / 8) + (ty / 8)) % 2;
            for (int k = 0; k < 3; k++) {
                uint32_t col = k == 1 ? 0xB07C4C : 0xBC8856;
                if (across) {
                    APRect(c, x + tx, y + ty + k * 3, 8, 2, col);
                    APHLine(c, x + tx, y + ty + k * 3 + 2, 8, 0x7A5030);
                } else {
                    APRect(c, x + tx + k * 3, y + ty, 2, 8, col);
                    APVLine(c, x + tx + k * 3 + 2, y + ty, 8, 0x7A5030);
                }
            }
        }
    })];
    [floors addObject:APSurface(@"fl.checker", @"Terracotta Check", 0xB8664A, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int ty = 0; ty < h; ty += 8) for (int tx = 0; tx < w; tx += 8) {
            BOOL dark = ((tx / 8) + (ty / 8)) % 2;
            uint32_t col = dark ? 0xB0604A : 0xE2CEA8;
            APRect(c, x + tx, y + ty, 8, 8, col);
            APHLine(c, x + tx, y + ty, 7, APShade(col, 1.08f));
            APHLine(c, x + tx, y + ty + 7, 8, APShade(col, 0.82f));
            APVLine(c, x + tx + 7, y + ty, 8, APShade(col, 0.82f));
        }
    })];
    [floors addObject:APSurface(@"fl.stone", @"Flagstone", 0x8E8478, ^(APCanvas *c, int x, int y, int w, int h) {
        // Voronoi stones with mortar at the cell borders.
        APRand r = {0x57};
        int n = MAX(4, w * h / 150);
        int sx[256], sy[256];
        uint32_t sc[256];
        uint32_t tones[] = {0x8E8478, 0x9A9084, 0x847A6E, 0xA0948A, 0x928274};
        n = MIN(n, 256);
        for (int i = 0; i < n; i++) {
            sx[i] = APRandInt(&r, 0, w - 1); sy[i] = APRandInt(&r, 0, h - 1); sc[i] = tones[APRandInt(&r, 0, 4)];
        }
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) {
            int best = 0, bestD = INT_MAX, second = INT_MAX;
            for (int i = 0; i < n; i++) {
                int dx = xx - sx[i], dy = (yy - sy[i]) * 3 / 2;
                int d = dx * dx + dy * dy;
                if (d < bestD) { second = bestD; bestD = d; best = i; } else if (d < second) second = d;
            }
            uint32_t col = sc[best];
            if (sqrt(second) - sqrt(bestD) < 1.2) col = 0x5E564E;
            else if (sqrt(second) - sqrt(bestD) < 2.4 && yy % 2 == 0) col = APShade(col, 1.08f);
            APPx(c, x + xx, y + yy, col);
        }
    })];
    [floors addObject:APSurface(@"fl.tatami", @"Tatami", 0xC4B876, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int ty = 0; ty < h; ty += 16) for (int tx = ((ty / 16) % 2) * -16; tx < w; tx += 32) {
            for (int yy = 0; yy < 16; yy++) for (int xx = 0; xx < 32; xx++) {
                uint32_t col = yy % 2 ? 0xC4B876 : 0xB8AC6A;
                if (xx == 0 || xx == 31) col = 0x3E4E32;
                if (yy == 15) col = 0x8A7E4A;
                APPx(c, x + tx + xx, y + ty + yy, col);
            }
        }
    })];
    [floors addObject:APSurface(@"fl.carpet", @"Moss Carpet", 0x6A7A4A, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x6A7A4A);
        APRand r = {0xCA9};
        for (int i = 0; i < w * h / 3; i++) {
            APPx(c, x + APRandInt(&r, 0, w - 1), y + APRandInt(&r, 0, h - 1), i % 2 ? 0x74844E : 0x5E6E42);
        }
    })];
    [floors addObject:APSurface(@"fl.tiles", @"Blue Tiles", 0x5A7AB0, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int ty = 0; ty < h; ty += 8) for (int tx = 0; tx < w; tx += 8) {
            APRect(c, x + tx, y + ty, 8, 8, 0xE6EAEE);
            APHLine(c, x + tx, y + ty + 7, 8, 0xAAB4C0);
            APVLine(c, x + tx + 7, y + ty, 8, 0xAAB4C0);
            APPx(c, x + tx + 3, y + ty + 2, 0x3A5A9A); APPx(c, x + tx + 2, y + ty + 3, 0x3A5A9A);
            APPx(c, x + tx + 4, y + ty + 3, 0x3A5A9A); APPx(c, x + tx + 3, y + ty + 4, 0x3A5A9A);
            APPx(c, x + tx + 3, y + ty + 3, 0xC8A848);
            APPx(c, x + tx, y + ty, 0x6A88BA);
        }
    })];
    [floors addObject:APSurface(@"fl.pink", @"Strawberry Boards", 0xD89A9A, ^(APCanvas *c, int x, int y, int w, int h) {
        for (int row = 0; row * 6 < h; row++) {
            uint32_t col = row % 2 ? 0xD89A9A : 0xE0A8A4;
            APRect(c, x, y + row * 6, w, 5, col);
            APHLine(c, x, y + row * 6 + 5, w, 0xA86A6E);
            for (int px = (row % 3) * 13; px < w; px += 40) APVLine(c, x + px, y + row * 6, 5, 0xA86A6E);
        }
    })];
}
