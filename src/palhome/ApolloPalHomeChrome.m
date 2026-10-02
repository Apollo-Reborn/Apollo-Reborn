#import "ApolloPalHomeChrome.h"
#import "ApolloPalHomeRenderer.h"
#import <math.h>

static APRamp R(uint32_t o, uint32_t d, uint32_t m, uint32_t l, uint32_t h) { return (APRamp){o, d, m, l, h}; }

APChromeTheme APChromeThemeForStyle(NSString *styleID) {
    APChromeTheme t = {
        .material = APMaterialWood,
        .panel = APRampNamed(@"walnut"),
        .button = APRampNamed(@"oak"),
        .toggled = APRampNamed(@"mustard"),
        .slot = 0x4A2E1C, .slotEdge = 0x24160E, .accent = 0xE8BE48,
        .text = 0xFAF0D8, .subtext = 0xD8B88A, .shadow = 0x24160E,
    };
    if ([styleID isEqualToString:@"castle"]) {
        t.material = APMaterialStone;
        t.panel = R(0x1E1C1A, 0x3E3A38, 0x5A5652, 0x7A7570, 0x9C968F);
        t.button = R(0x24211F, 0x55504C, 0x77716B, 0x958E87, 0xB8B0A8);
        t.toggled = APRampNamed(@"gold");
        t.slot = 0x2E2A28; t.slotEdge = 0x141210; t.accent = 0xE8BE48;
        t.text = 0xF2EAD8; t.subtext = 0xC8BCA8; t.shadow = 0x141210;
    } else if ([styleID isEqualToString:@"library"]) {
        t.panel = R(0x140A06, 0x2E1A10, 0x42261A, 0x5A3624, 0x784A30);
        t.button = R(0x22090A, 0x521C1A, 0x722824, 0x923A32, 0xB45848); // oxblood leather
        t.toggled = APRampNamed(@"gold");
        t.slot = 0x1E0F08; t.slotEdge = 0x0E0704; t.accent = 0xE8BE48;
        t.text = 0xF8E8C8; t.subtext = 0xD8B070; t.shadow = 0x0E0704;
        t.trim = 0xC8962A;
    } else if ([styleID isEqualToString:@"space"]) {
        t.material = APMaterialMetal;
        t.panel = R(0x12161C, 0x323842, 0x4E5662, 0x6E7884, 0x9AA4AE);
        t.button = R(0x1E2228, 0x48505C, 0x66707C, 0x8E98A4, 0xC4CCD6);
        t.toggled = R(0x0A2A32, 0x186070, 0x2896A8, 0x52CADA, 0xA8F4FF);
        t.slot = 0x0A1018; t.slotEdge = 0x05080C; t.accent = 0x5AE0F0;
        t.text = 0xD8F8FF; t.subtext = 0x7ACCE0; t.shadow = 0x061018;
        t.trim = 0x5AE0F0;
    } else if ([styleID isEqualToString:@"saloon"]) {
        t.panel = R(0x2E1C10, 0x5A3E26, 0x7A5634, 0x987046, 0xB88C5E);
        t.button = R(0x3A2414, 0x7A5634, 0x9A7044, 0xB88C5A, 0xD4AA78);
        t.toggled = R(0x4A3014, 0x8A6420, 0xC08A2E, 0xDCA848, 0xF2CC7A); // brass
        t.slot = 0x3E2818; t.slotEdge = 0x1E120A; t.accent = 0xF2C060;
        t.text = 0xFFF2D8; t.subtext = 0xF2C080; t.shadow = 0x1E120A;
        t.nails = YES;
    } else if ([styleID isEqualToString:@"treehouse"]) {
        t.material = APMaterialBark;
        t.panel = R(0x1A120A, 0x3A2818, 0x523822, 0x6E4E30, 0x8E6A44);
        t.button = R(0x3A2A14, 0x7A5A30, 0x9A7840, 0xBA9858, 0xD8B878);
        t.toggled = R(0x1E3014, 0x3E6A2A, 0x5E8A3C, 0x86B052, 0xB8D888);
        t.slot = 0x24180E; t.slotEdge = 0x120C06; t.accent = 0xA8E07A;
        t.text = 0xF2F0D8; t.subtext = 0xB8D890; t.shadow = 0x120C06;
    } else if ([styleID isEqualToString:@"underwater"]) {
        t.material = APMaterialDriftwood;
        t.panel = R(0x0C1E24, 0x24424A, 0x385C64, 0x527A80, 0x76A0A4);
        t.button = R(0x0A3232, 0x226662, 0x348680, 0x52A8A0, 0x92D4CA); // sea glass
        t.toggled = R(0x5A4A52, 0xBCA8B4, 0xE0D0DA, 0xF0E6EE, 0xFFFFFF); // pearl
        t.slot = 0x0A1C22; t.slotEdge = 0x050E12; t.accent = 0xF6E0EE;
        t.text = 0xE8FAFF; t.subtext = 0x9AD8D8; t.shadow = 0x050E12;
    }
    return t;
}

#pragma mark - Material textures

// Fills (x, y, w, h) with the theme's material. Used for panels and signs.
static void APMaterialFill(APCanvas *c, APChromeTheme t, int x, int y, int w, int h, uint32_t seed) {
    APRamp p = t.panel;
    APRand r = {seed};
    switch (t.material) {
        case APMaterialStone: {
            APRect(c, x, y, w, h, p.o);
            for (int row = 0; row * 7 < h; row++) for (int bx = (row % 2) * -6; bx < w; bx += 12) {
                int x0 = MAX(bx, 0), x1 = MIN(bx + 11, w), y0 = row * 7, y1 = MIN(y0 + 6, h);
                if (x1 <= x0 || y1 <= y0) continue;
                uint32_t tone = (uint32_t[]){p.m, p.l, APMix(p.m, p.l, 0.5f), APShade(p.m, 0.92f)}[APRandInt(&r, 0, 3)];
                APRect(c, x + x0, y + y0, x1 - x0, y1 - y0, tone);
                APHLine(c, x + x0, y + y0, x1 - x0, APShade(tone, 1.15f));
                APHLine(c, x + x0, y + y1 - 1, x1 - x0, APShade(tone, 0.82f));
                if (APRandInt(&r, 0, 3) == 0) APPx(c, x + x0 + APRandInt(&r, 1, MAX(1, x1 - x0 - 2)), y + y0 + 2, APShade(tone, 0.8f));
            }
            break;
        }
        case APMaterialMetal: {
            // Brushed steel: faint horizontal grain bands.
            for (int yy = 0; yy < h; yy++) {
                uint32_t band = (yy / 2) % 3 == 0 ? APMix(p.m, p.l, 0.35f) : p.m;
                APHLine(c, x, y + yy, w, band);
            }
            for (int k = 0; k < w * h / 40; k++) APHLine(c, x + APRandInt(&r, 0, w - 4), y + APRandInt(&r, 0, h - 1), 3, APMix(p.m, p.h, 0.3f));
            // Panel seams with rivets.
            for (int sx = 24; sx < w - 4; sx += 24) {
                APVLine(c, x + sx, y, h, p.d);
                APVLine(c, x + sx + 1, y, h, APMix(p.m, p.l, 0.6f));
                for (int ry = 4; ry < h - 2; ry += 8) APPx(c, x + sx - 2, y + ry, p.h);
            }
            break;
        }
        case APMaterialBark: {
            APRect(c, x, y, w, h, p.m);
            for (int xx = 0; xx < w; xx++) {
                int groove = (int)((xx * 7 + (xx / 5) * 13) % 9);
                if (groove == 0) APVLine(c, x + xx, y, h, p.d);
                else if (groove == 1) APVLine(c, x + xx, y, h, p.l);
            }
            for (int k = 0; k < w * h / 30; k++) APVLine(c, x + APRandInt(&r, 0, w - 1), y + APRandInt(&r, 0, h - 4), 3, p.d);
            break;
        }
        case APMaterialDriftwood: {
            for (int yy = 0; yy < h; yy++) {
                int plank = yy / 7;
                uint32_t tone = plank % 2 ? p.m : APMix(p.m, p.l, 0.3f);
                for (int xx = 0; xx < w; xx++) {
                    uint32_t col = tone;
                    if ((int)lroundf(sinf((xx + plank * 11) * 0.21f) * 1.6f) + 3 == yy % 7) col = APShade(tone, 0.9f);
                    if (yy % 7 == 6) col = p.d;
                    APPx(c, x + xx, y + yy, col);
                }
            }
            // Barnacles.
            for (int k = 0; k < w * h / 160; k++) {
                int bx = x + APRandInt(&r, 2, w - 3), by = y + APRandInt(&r, 2, h - 3);
                APPx(c, bx, by, 0xD8D4C8); APPx(c, bx + 1, by, 0xA8A498); APPx(c, bx, by + 1, 0xA8A498);
            }
            break;
        }
        default: {
            for (int yy = 0; yy < h; yy++) APHLine(c, x, y + yy, w, p.m);
            for (int py = 7; py < h; py += 8) {
                APHLine(c, x, y + py, w, p.d);
                APHLine(c, x, y + py + 1, w, APShade(p.m, 1.08f));
            }
            for (int k = 0; k < w * h / 60; k++) APHLine(c, x + APRandInt(&r, 0, w - 3), y + APRandInt(&r, 0, h - 1), 2, APShade(p.m, 0.9f));
            if (t.nails) {
                for (int py = 0; py < h; py += 8) for (int px = 4 + (py / 8 % 2) * 14; px < w - 3; px += 28) {
                    APPx(c, x + px, y + py + 3, 0x3A3A40);
                    APPx(c, x + px + 1, y + py + 3, 0x8A8A94);
                }
                // Weathering streaks.
                for (int k = 0; k < w / 6; k++) APVLine(c, x + APRandInt(&r, 0, w - 1), y + APRandInt(&r, 0, h - 3), 2, APShade(p.m, 1.12f));
            }
            break;
        }
    }
}

APCanvas *APChromePanel(APChromeTheme t, int w, int h) {
    APCanvas *c = APCanvasCreate(w, h);
    APRamp p = t.panel;
    APRoundRect(c, 0, 0, w, h, p.o);
    APRect(c, 1, 1, w - 2, h - 2, p.d);
    APCanvas *fill = APCanvasCreate(w - 4, h - 4);
    APMaterialFill(fill, t, 0, 0, fill->w, fill->h, 0xD4A);
    // Quiet the material: panels hold text, so the grain is a hint, not a
    // pattern. (Signs and the room keep the full-strength texture.)
    for (int i = 0; i < fill->w * fill->h; i++) {
        uint32_t px = fill->px[i];
        if (px >> 24) fill->px[i] = (px & 0xFF000000u) | APMix(px & 0xFFFFFF, p.m, 0.7f);
    }
    APDraw(c, fill, 2, 2, NO);
    APCanvasFree(fill);
    APHLine(c, 2, 2, w - 4, p.l);
    switch (t.material) {
        case APMaterialMetal: {
            // Rivets all round and an LED strip along the top edge.
            for (int x = 4; x < w - 3; x += 10) { APPx(c, x, 3, p.h); APPx(c, x, h - 4, p.h); APPx(c, x + 1, h - 3, p.d); }
            for (int y = 8; y < h - 4; y += 10) { APPx(c, 3, y, p.h); APPx(c, w - 4, y, p.h); }
            if (t.trim) { APHLine(c, 6, 1, w - 12, t.trim); APHLine(c, 6, 2, w - 12, APMix(t.trim, 0xFFFFFF, 0.5f)); }
            // Hazard stripes in the corners.
            for (int k = 0; k < 6; k++) for (int s = 0; s < 2; s++) {
                int sx = s ? w - 9 : 2;
                if ((k / 2) % 2 == 0) { APPx(c, sx + k, h - 3, 0xE8B830); APPx(c, sx + k + 1, h - 2, 0xE8B830); }
            }
            break;
        }
        case APMaterialStone:
            APHLine(c, 2, 2, w - 4, APShade(p.l, 1.1f));
            break;
        case APMaterialBark: {
            // Moss along the top, leaf sprigs in the corners.
            for (int x = 2; x < w - 2; x++) if (sinf(x * 0.6f) + sinf(x * 0.23f) > 0.3f) APPx(c, x, 2, (x % 3) ? 0x5E8A3C : 0x7AB052);
            int corners[2] = {3, w - 7};
            for (int i = 0; i < 2; i++) {
                int cx = corners[i];
                APPx(c, cx, 1, 0x7AB052); APPx(c, cx + 1, 0, 0x86B052); APPx(c, cx + 2, 1, 0x5E8A3C);
                APPx(c, cx + 3, 0, 0x7AB052); APPx(c, cx + 1, 2, 0x5E8A3C);
            }
            break;
        }
        case APMaterialDriftwood: {
            // A little starfish resting on the corner.
            int sx = w - 9, sy = h - 8;
            APPx(c, sx + 3, sy, 0xF2945A); APPx(c, sx + 3, sy + 1, 0xF2945A);
            APHLine(c, sx, sy + 2, 7, 0xF2945A); APPx(c, sx + 3, sy + 2, 0xF8B080);
            APPx(c, sx + 2, sy + 3, 0xF2945A); APPx(c, sx + 4, sy + 3, 0xF2945A);
            APPx(c, sx + 1, sy + 4, 0xE07A44); APPx(c, sx + 5, sy + 4, 0xE07A44);
            break;
        }
        default:
            if (t.trim) APRectOutline(c, 3, 3, w - 6, h - 6, t.trim);
            break;
    }
    if (t.material != APMaterialMetal) {
        int corners[4][2] = {{3, 3}, {w - 4, 3}, {3, h - 4}, {w - 4, h - 4}};
        uint32_t nail = t.material == APMaterialStone ? 0 : 0xBEB4A6;
        if (nail) for (int i = 0; i < 4; i++) APPx(c, corners[i][0], corners[i][1], nail);
    }
    return c;
}

APCanvas *APChromeTile(APChromeTheme t, int w, int h, BOOL down, BOOL toggled) {
    APCanvas *c = APCanvasCreate(w, h);
    APRamp b = toggled ? t.toggled : t.button;
    int depth = down ? 1 : 2, top = down ? 1 : 0;
    APRoundRect(c, 0, top, w, h - top, b.o);
    APRect(c, 1, h - depth - 1, w - 2, depth, b.d);
    APRect(c, 1, top + 1, w - 2, h - top - depth - 2, b.m);
    int fy = top + 1, fh = h - top - depth - 2;
    switch (t.material) {
        case APMaterialStone:
            for (int k = 0; k < w * fh / 14; k++) APPx(c, 2 + (k * 7) % MAX(1, w - 4), fy + (k * 5) % MAX(1, fh), APShade(b.m, (k % 2) ? 0.9f : 1.08f));
            APHLine(c, 2, fy, w - 4, b.h);
            break;
        case APMaterialMetal:
            for (int y = fy; y < fy + fh; y += 2) APHLine(c, 2, y, w - 4, APMix(b.m, b.l, 0.25f));
            APHLine(c, 2, fy, w - 4, b.h);
            APPx(c, 2, fy + 1, b.d); APPx(c, w - 3, fy + 1, b.d); APPx(c, 2, fy + fh - 2, b.d); APPx(c, w - 3, fy + fh - 2, b.d);
            if (toggled && t.trim) APHLine(c, 3, h - depth - 1, w - 6, t.trim);
            break;
        case APMaterialBark:
            APHLine(c, 2, fy, w - 4, b.h);
            for (int x = 2; x < w - 2; x += 3) APPx(c, x, fy, toggled ? b.h : 0x7AB052); // moss lip
            for (int y = fy + 3; y < fy + fh - 1; y += 4) APHLine(c, 3, y, w - 6, APShade(b.m, 0.92f));
            break;
        case APMaterialDriftwood:
            APHLine(c, 2, fy, w - 4, b.h);
            APLine(c, 3, fy + fh - 2, MIN(w - 4, 3 + fh), fy + 1, APMix(b.m, 0xFFFFFF, 0.25f)); // glassy glint
            break;
        default:
            APHLine(c, 2, fy, w - 4, b.h);
            APVLine(c, 1, fy + 1, MAX(0, fh - 2), b.l);
            if (t.trim && !toggled) { APPx(c, 2, fy + 1, t.trim); APPx(c, w - 3, fy + 1, t.trim); }
            break;
    }
    return c;
}

APCanvas *APChromeSlot(APChromeTheme t, int w, int h, BOOL down, BOOL toggled) {
    APCanvas *c = APCanvasCreate(w, h);
    APRoundRect(c, 0, 0, w, h, toggled ? t.accent : t.slotEdge);
    APRect(c, 1, 1, w - 2, h - 2, down ? APMix(t.slot, t.panel.m, 0.5f) : t.slot);
    APHLine(c, 1, 1, w - 2, APShade(t.slot, 0.7f));
    if (t.material == APMaterialMetal) {
        // Screen-like slots: faint scanlines.
        for (int y = 3; y < h - 1; y += 3) APHLine(c, 1, y, w - 2, APMix(t.slot, t.toggled.d, 0.25f));
    }
    if (toggled) APRectOutline(c, 1, 1, w - 2, h - 2, APShade(t.accent, 0.75f));
    return c;
}

void APChromeHeart(APCanvas *c, int x, int y, float fill, uint32_t empty, uint32_t shadow) {
    if (shadow) APText(c, @"♥", x + 1, y + 1, APFontSmall, shadow);
    APText(c, @"♥", x, y, APFontSmall, fill >= 1 ? 0xF06A7A : empty);
    if (fill >= 1) {
        APPx(c, x + 1, y + 1, 0xFFB8C0);
    } else if (fill > 0) {
        // The left half, red.
        APCanvas *red = APCanvasCreate(5, 5);
        APText(red, @"♥", 0, 0, APFontSmall, 0xF06A7A);
        for (int yy = 0; yy < 5; yy++) for (int xx = 0; xx < 3; xx++) if (APOpaqueAt(red, xx, yy)) APPx(c, x + xx, y + yy, 0xF06A7A);
        APCanvasFree(red);
        APPx(c, x + 1, y + 1, 0xFFB8C0);
    }
}

APCanvas *APChromeSign(APChromeTheme t, NSString *title, double hearts, int maxHearts) {
    NSString *text = title.uppercaseString;
    int tw = APTextWidth(text, APFontLarge);
    int heartsW = maxHearts > 0 && hearts >= 0 ? maxHearts * 6 - 1 : 0;
    int w = MAX(tw, heartsW) + 16;
    int boardY = 8, boardH = heartsW ? 22 : 15;
    APCanvas *c = APCanvasCreate(w, boardY + boardH + 1);
    // Hangers: chains for stone and steel, rope for everything else.
    BOOL chain = t.material == APMaterialStone || t.material == APMaterialMetal;
    for (int y = 0; y < boardY + 2; y++) {
        uint32_t col = chain ? (y % 2 ? 0x6A6E78 : 0xA8AEB8) : 0xC8B488;
        int dx = chain ? 0 : (y % 2);
        APPx(c, 5 + dx, y, col); APPx(c, w - 7 + dx, y, col);
    }
    APRoundRect(c, 0, boardY, w, boardH, t.panel.o);
    APCanvas *fill = APCanvasCreate(w - 2, boardH - 2);
    APChromeTheme signTheme = t;
    // Plaques read better a touch lighter than panels.
    signTheme.panel = (APRamp){t.panel.o, t.panel.m, t.panel.l, t.panel.h, APMix(t.panel.h, 0xFFFFFF, 0.3f)};
    if (t.material == APMaterialStone) {
        // A smooth carved slab, so the lettering reads.
        APRect(fill, 0, 0, fill->w, fill->h, t.panel.l);
        APRand r = {0x51AB};
        for (int k = 0; k < fill->w * fill->h / 12; k++) APPx(fill, APRandInt(&r, 0, fill->w - 1), APRandInt(&r, 0, fill->h - 1), APShade(t.panel.l, k % 2 ? 0.92f : 1.06f));
        APPx(fill, 0, fill->h - 1, t.panel.o); APPx(fill, fill->w - 2, 0, t.panel.d); // chips
    } else {
        APMaterialFill(fill, signTheme, 0, 0, fill->w, fill->h, 0x5161);
    }
    APDraw(c, fill, 1, boardY + 1, NO);
    APCanvasFree(fill);
    APHLine(c, 1, boardY + 1, w - 2, signTheme.panel.h);
    APHLine(c, 1, boardY + boardH - 2, w - 2, t.panel.d);
    if (t.trim) APRectOutline(c, 1, boardY + 1, w - 2, boardH - 2, t.trim);
    uint32_t bolt = t.material == APMaterialMetal ? 0xC4CCD6 : 0xBEB4A6;
    APPx(c, 5, boardY + 2, bolt); APPx(c, w - 6, boardY + 2, bolt);
    uint32_t ink = t.material == APMaterialMetal ? t.trim : t.text;
    APTextShadow(c, text, (w - tw) / 2, boardY + 4, APFontLarge, ink, t.panel.o);
    if (heartsW) {
        int hx = (w - heartsW) / 2, hy = boardY + 14;
        for (int i = 0; i < maxHearts; i++) {
            float fill = hearts >= i + 1 ? 1 : hearts >= i + 0.5 ? 0.5f : 0;
            APChromeHeart(c, hx + i * 6, hy, fill, APShade(t.panel.d, 0.8f), t.panel.o);
        }
    }
    return c;
}
