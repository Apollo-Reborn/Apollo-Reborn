#import "ApolloPalHomeCatalog.h"
#import <math.h>

// Hanging things: windows (with a live sky), clocks, shelves, neon, garlands
// and the art catalogue. Wall items are drawn into whole 16px wall cells.

typedef NS_ENUM(int, APSkyPhase) { APSkyDay, APSkyDusk, APSkyNight };

static APSkyPhase APSkyPhaseForHour(int hour) {
    if (hour >= 8 && hour < 17) return APSkyDay;
    if ((hour >= 17 && hour < 20) || (hour >= 6 && hour < 8)) return APSkyDusk;
    return APSkyNight;
}

// Vertical gradient using ordered dithering between stops.
static void APGradient(APCanvas *c, int x, int y, int w, int h, const uint32_t *stops, int count) {
    for (int yy = 0; yy < h; yy++) {
        float t = h > 1 ? yy / (float)(h - 1) * (count - 1) : 0;
        int i = MIN((int)t, count - 2);
        float f = t - i;
        for (int xx = 0; xx < w; xx++) {
            APPx(c, x + xx, y + yy, APBayer(x + xx, y + yy) < f ? stops[i + 1] : stops[i]);
        }
    }
}

// The view through a window: sky for the time of day, weather tint, rolling
// hills, a distant cottage whose window lights up at night.
static void APSky(APCanvas *c, int x, int y, int w, int h, int hour, int weather, uint32_t seed) {
    APSkyPhase phase = APSkyPhaseForHour(hour);
    BOOL snow = weather == 0, rain = weather == 2;
    if (phase == APSkyDay) {
        uint32_t clear[] = {0x5AA0DA, 0x8CC4E8, 0xC4E4F4};
        uint32_t grey[] = {0x8A98AC, 0xA8B4C4, 0xCAD2DC};
        APGradient(c, x, y, w, h, (snow || rain) ? grey : clear, 3);
    } else if (phase == APSkyDusk) {
        uint32_t stops[] = {0x2E2A56, 0x7A4A76, 0xD06A6A, 0xF4A860};
        APGradient(c, x, y, w, h, stops, 4);
    } else {
        uint32_t stops[] = {0x0C1230, 0x16204A, 0x26345E};
        APGradient(c, x, y, w, h, stops, 3);
    }
    APRand r = {seed};
    if (phase == APSkyNight && !rain) {
        for (int i = 0; i < w * h / 18; i++) APPx(c, x + APRandInt(&r, 0, w - 1), y + APRandInt(&r, 0, h * 2 / 3), i % 3 ? 0x9AA4C8 : 0xF0E6C0);
        int mx = x + w - 7, my = y + 3;
        APCircle(c, mx, my + 1, 2, 0xF4EAC4);
        APPx(c, mx - 1, my, 0xD8CCA0);
    } else if (phase == APSkyDusk && !snow && !rain) {
        APCircle(c, x + w / 3, y + h - 7, 3, 0xFFD890);
        APHLine(c, x + w / 3 - 2, y + h - 10, 5, 0xFFE8B0);
    } else if (phase == APSkyDay && !snow && !rain) {
        APCircle(c, x + w - 6, y + 4, 2, 0xFFF4C0);
        for (int i = 0; i < 2; i++) {
            int cx = x + APRandInt(&r, 2, w - 10), cy = y + APRandInt(&r, 2, h / 2);
            APHLine(c, cx, cy, 7, 0xF4F8FC); APHLine(c, cx + 2, cy - 1, 3, 0xF4F8FC);
        }
    } else if (snow || rain) {
        // Heavy clouds.
        uint32_t cloud = phase == APSkyNight ? 0x2A3050 : phase == APSkyDusk ? 0x6A4A6A : 0x9AA6B6;
        for (int cx = x - 2; cx < x + w; cx += 6) APEllipse(c, cx, y - 2 + (cx % 3), 9, 5, cloud);
    }
    // Hills and trees.
    uint32_t far = phase == APSkyDay ? 0x7AA86A : phase == APSkyDusk ? 0x5A4868 : 0x1C2840;
    uint32_t near = phase == APSkyDay ? 0x5A8A4E : phase == APSkyDusk ? 0x3E3450 : 0x141E30;
    if (snow) { far = APMix(far, 0xE8EEF4, phase == APSkyNight ? 0.25f : 0.7f); near = APMix(near, 0xF4F8FC, phase == APSkyNight ? 0.3f : 0.8f); }
    for (int xx = 0; xx < w; xx++) {
        int hf = (int)(h * 0.72f + sinf((xx + seed % 7) * 0.35f) * 2.2f);
        int hn = (int)(h * 0.84f + sinf((xx + 3) * 0.22f + 1.3f) * 1.6f);
        APVLine(c, x + xx, y + hf, h - hf, far);
        APVLine(c, x + xx, y + hn, h - hn, near);
    }
    uint32_t pine = phase == APSkyNight ? 0x0C1424 : phase == APSkyDusk ? 0x2A2440 : 0x3A6A3E;
    for (int t = 0; t < 2; t++) {
        int tx = x + (t ? w - 5 : 3), ty = y + h - 9 + t;
        for (int k = 0; k < 6; k++) APHLine(c, tx - k / 2, ty + k, 1 + (k / 2) * 2, pine);
        if (snow) APPx(c, tx, ty, 0xF4F8FC);
    }
    // Distant cottage.
    int hx = x + w / 2 + 1, hy = y + (int)(h * 0.78f);
    uint32_t wall = phase == APSkyNight ? 0x2A2A40 : phase == APSkyDusk ? 0x6A4A5A : 0xC8B8A0;
    APRect(c, hx, hy, 5, 3, wall);
    APHLine(c, hx - 1, hy - 1, 7, snow ? 0xF0F4F8 : 0x8A3A34);
    APHLine(c, hx, hy - 2, 5, snow ? 0xF0F4F8 : 0x8A3A34);
    APPx(c, hx + 2, hy + 1, phase == APSkyDay ? 0x5A6A7A : 0xFFD070);
}

static void APPaintingShadow(APCanvas *c, int x, int y, int w, int h) {
    APBlendRect(c, x + 1, y + h, w, 1, 0x1A0C06, 0.35f);
    APBlendRect(c, x + w, y + 1, 1, h, 0x1A0C06, 0.35f);
}

void APPaintingShadowRect(APCanvas *c, int x, int y, int w, int h) { APPaintingShadow(c, x, y, w, h); }

// Picture frame; returns the inner rect via out params.
static void APFrame(APCanvas *c, int x, int y, int w, int h, int style, int *ix, int *iy, int *iw, int *ih) {
    APRamp f;
    switch (style) {
        case 1: f = APRampNamed(@"gold"); break;
        case 2: f = APRampNamed(@"white"); break;
        case 3: f = APRampNamed(@"iron"); break;
        default: f = APRampNamed(@"oak"); break;
    }
    APPaintingShadow(c, x, y, w, h);
    APRect(c, x, y, w, h, f.m);
    APHLine(c, x, y, w, f.h);
    APVLine(c, x, y, h, f.l);
    APHLine(c, x, y + h - 1, w, f.d);
    APVLine(c, x + w - 1, y, h, f.d);
    APRectOutline(c, x + 1, y + 1, w - 2, h - 2, style == 1 ? f.l : f.m);
    if (style == 1) { APPx(c, x, y, f.h); APPx(c, x + w - 1, y, f.h); }
    *ix = x + 2; *iy = y + 2; *iw = w - 4; *ih = h - 4;
}

typedef void (^APPaintBlock)(APCanvas *c, int x, int y, int w, int h);

static APItemSpec *APArt(NSString *identifier, NSString *title, int w, int d, APPaintBlock paint) {
    return APSpec(identifier, title, APLayerWall, APCategoryArt, w, d, 0, @[@"Oak Frame", @"Gilded Frame", @"White Frame", @"Black Frame"],
                  ^(APDrawContext *ctx) {
        int ix, iy, iw, ih;
        APFrame(ctx.base, 1, 1, ctx.width - 3, ctx.height - 3, ctx.variant, &ix, &iy, &iw, &ih);
        APCanvas *inner = APCanvasCreate(iw, ih);
        paint(inner, 0, 0, iw, ih);
        APDraw(ctx.base, inner, ix, iy, NO);
        APCanvasFree(inner);
    });
}

static void APRegisterArt(NSMutableArray *items) {
    [items addObject:APArt(@"art.mountains", @"Misty Peaks", 1, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        uint32_t sky[] = {0x8CB8D8, 0xE8C8B0};
        APGradient(c, x, y, w, h, sky, 2);
        for (int xx = 0; xx < w; xx++) {
            int peak = abs(xx - 3) < abs(xx - 8) ? 2 + abs(xx - 3) : 3 + abs(xx - 8);
            APVLine(c, x + xx, y + peak, h - peak, 0x6A6A8A);
            if (peak < 5) APPx(c, x + xx, y + peak, 0xF4F4F8);
        }
        APRect(c, x, y + h - 3, w, 3, 0x4A7A6A);
        APHLine(c, x + 1, y + h - 2, 3, 0x8AB8C8);
    })];
    [items addObject:APArt(@"art.sunset", @"Sunset Sea", 2, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        uint32_t sky[] = {0x4A3A7A, 0xD0607A, 0xF4A860};
        APGradient(c, x, y, w, h * 2 / 3, sky, 3);
        APCircle(c, x + w / 2, y + h * 2 / 3 - 1, 3, 0xFFE0A0);
        for (int yy = h * 2 / 3; yy < h; yy++) {
            APHLine(c, x, y + yy, w, yy % 2 ? 0x3A4A7A : 0x4A5A8A);
            APHLine(c, x + w / 2 - 3 + (yy % 3), y + yy, 3, 0xF4C080);
        }
    })];
    [items addObject:APArt(@"art.wave", @"Great Wave", 2, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xE8DCC0);
        // Mount Fuji in the distance.
        for (int k = 0; k < 3; k++) APHLine(c, x + 17 - k, y + 5 + k, 1 + k * 2, k ? 0x5A6A8A : 0xF4F4F8);
        // The wave: a thick curl with foam claws.
        for (int xx = 0; xx < 14; xx++) {
            int top = (int)(h - 1 - sinf(xx / 13.0f * 3.1f) * (h - 1));
            APVLine(c, x + xx, y + top, h - top, 0x2A4A7A);
            APPx(c, x + xx, y + top, 0xF4F4F8);
            if (xx % 2 == 0) APPx(c, x + xx, y + top + 1, 0x6A8AB8);
        }
        APPx(c, x + 12, y + 1, 0xF4F4F8); APPx(c, x + 13, y + 2, 0xF4F4F8); APPx(c, x + 11, y + 2, 0xF4F4F8);
        for (int xx = 14; xx < w; xx++) APVLine(c, x + xx, y + h - 2 - (xx % 4 == 0), 3, 0x3A5A8A);
    })];
    [items addObject:APArt(@"art.starry", @"Swirly Night", 2, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x1E3A7A);
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) {
            float a = atan2f(yy - 4, xx - 12) * 3 + hypotf(xx - 12, yy - 4) * 0.9f;
            if (sinf(a) > 0.6f) APPx(c, x + xx, y + yy, 0x4A6AB0);
        }
        APCircle(c, x + w - 4, y + 2, 1, 0xF8D860);
        APPx(c, x + 5, y + 2, 0xF8E890); APPx(c, x + 18, y + 4, 0xF8E890);
        APRect(c, x + 8, y + h - 2, w - 8, 2, 0x1A2A4A);
        APPx(c, x + 14, y + h - 2, 0xF8D860); APPx(c, x + 20, y + h - 2, 0xF8D860);
        for (int k = 0; k < h; k++) APHLine(c, x + 2 - k / 4, y + k, 1 + k / 3, 0x14241A);
    })];
    [items addObject:APArt(@"art.sunflowers", @"Sunflowers", 1, 2, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xE8C860);
        APRect(c, x, y + h - 8, w, 8, 0xD8A840);
        APRect(c, x + 3, y + h - 11, 4, 7, 0x4A6AA0); APHLine(c, x + 3, y + h - 11, 4, 0x6A8AC0);
        int heads[][2] = {{2, 6}, {7, 4}, {5, 11}};
        for (int i = 0; i < 3; i++) {
            APLine(c, x + 5, y + h - 11, x + heads[i][0], y + heads[i][1], 0x5E7A3A);
            APCircle(c, x + heads[i][0], y + heads[i][1], 2, 0xF0A020);
            APPx(c, x + heads[i][0], y + heads[i][1], 0x6A3A1A);
        }
    })];
    [items addObject:APArt(@"art.cat", @"Cat Portrait", 1, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x4EA094);
        APEllipse(c, x + 1, y + 3, 8, 6, 0xE8964A);
        APPx(c, x + 2, y + 2, 0xE8964A); APPx(c, x + 7, y + 2, 0xE8964A);
        APPx(c, x + 2, y + 1, 0xE8964A); APPx(c, x + 7, y + 1, 0xE8964A);
        APPx(c, x + 3, y + 5, 0x1A1A1E); APPx(c, x + 6, y + 5, 0x1A1A1E);
        APPx(c, x + 4, y + 6, 0xE87A8A); APPx(c, x + 5, y + 6, 0xE87A8A);
        APHLine(c, x + 3, y + 7, 4, 0xF4D8B0);
    })];
    [items addObject:APArt(@"art.dog", @"Good Dog", 1, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xECE0C4);
        APEllipse(c, x + 2, y + 1, 7, 7, 0x9A6A44);
        APRect(c, x + 1, y + 2, 2, 5, 0x6A4228); APRect(c, x + 8, y + 2, 2, 5, 0x6A4228);
        APPx(c, x + 4, y + 4, 0x1A1A1E); APPx(c, x + 7, y + 4, 0x1A1A1E);
        APEllipse(c, x + 4, y + 5, 4, 3, 0xD8B890); APPx(c, x + 5, y + 5, 0x1A1A1E);
        APHLine(c, x + 2, y + h - 1, 7, 0xC44A44);
    })];
    [items addObject:APArt(@"art.blocks", @"Composition", 1, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xF4F0E4);
        APRect(c, x, y, 5, 4, 0xC8302A);
        APRect(c, x + 7, y + 6, 3, 3, 0x2A4A9A);
        APRect(c, x, y + 7, 3, 2, 0xF0C020);
        APVLine(c, x + 5, y, h, 0x1A1A1E); APHLine(c, x, y + 4, w, 0x1A1A1E);
        APHLine(c, x + 5, y + 6, w - 5, 0x1A1A1E); APVLine(c, x + 3, y + 4, h - 4, 0x1A1A1E);
    })];
    [items addObject:APArt(@"art.forest", @"Foggy Pines", 2, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        uint32_t sky[] = {0xC8D4D0, 0xE8ECE4};
        APGradient(c, x, y, w, h, sky, 2);
        uint32_t layers[] = {0xA0B4AC, 0x6A8A7A, 0x3A5A4A};
        for (int l = 0; l < 3; l++) for (int t = l * 3; t < w; t += 5 + l) {
            int ty = y + 1 + l * 2;
            for (int k = 0; k < h - 1 - l * 2; k++) APHLine(c, x + t - k / 3, ty + k, 1 + (k / 3) * 2, layers[l]);
        }
    })];
    [items addObject:APArt(@"art.moons", @"Moon Phases", 2, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x1A1E3A);
        for (int i = 0; i < 5; i++) {
            int cx = x + 2 + i * 5, cy = y + h / 2;
            APCircle(c, cx, cy, 2, 0xF0E6C0);
            if (i != 2) APCircle(c, cx + (i < 2 ? -(2 - i) * 2 : (i - 2) * 2), cy, 2, 0x1A1E3A);
        }
    })];
    [items addObject:APArt(@"art.fern", @"Pressed Fern", 1, 1, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0xF0E8D4);
        APLine(c, x + 2, y + h - 1, x + w - 3, y + 1, 0x5E7A3A);
        for (int k = 1; k < 8; k++) {
            int px = x + 2 + k, py = y + h - 1 - k;
            APPx(c, px - 1, py - 1, 0x86B052); APPx(c, px + 1, py + 1, 0x86B052);
        }
    })];
    [items addObject:APArt(@"art.portrait", @"Girl with Pearl", 1, 2, ^(APCanvas *c, int x, int y, int w, int h) {
        APRect(c, x, y, w, h, 0x1A1A1E);
        APEllipse(c, x + 2, y + 6, 7, 8, 0xE8C8A0);
        APRect(c, x + 2, y + 3, 7, 4, 0x3A6AB0); APRect(c, x + 5, y + 2, 3, 2, 0xE8C860);
        APVLine(c, x + 7, y + 6, 8, 0xE8C860);
        APPx(c, x + 4, y + 9, 0x2A2A30); APPx(c, x + 7, y + 9, 0x2A2A30);
        APPx(c, x + 5, y + 12, 0xB8505A);
        APPx(c, x + 2, y + 13, 0xF8F8F8);
        APRect(c, x + 1, y + 15, 9, h - 15, 0x8A6A3A);
    })];

    // An unframed retro poster, taped up.
    APItemSpec *poster = APSpec(@"art.space", @"Space Poster", APLayerWall, APCategoryArt, 1, 2, 0, @[@"Midnight", @"Sunset"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t bg = ctx.variant ? 0xD0605A : 0x1E2A5A;
        APPaintingShadow(c, 2, 1, 12, 29);
        APRect(c, 2, 1, 12, 29, bg);
        APDitherRect(c, 2, 16, 12, 14, APShade(bg, 1.2f), 0.3f);
        APCircle(c, 10, 22, 4, 0xE8964A); APHLine(c, 5, 22, 10, 0xF4C080);
        APRect(c, 6, 7, 3, 8, 0xF4F4F8); APPx(c, 7, 6, 0xF4F4F8); APPx(c, 7, 5, 0xC44A44);
        APPx(c, 5, 13, 0xC44A44); APPx(c, 9, 13, 0xC44A44);
        APPx(c, 7, 15, 0xFFD060); APPx(c, 7, 16, 0xF08A30);
        APPx(c, 4, 4, 0xF0E6C0); APPx(c, 11, 9, 0xF0E6C0); APPx(c, 12, 3, 0xF0E6C0);
        APText(c, @"GO", 4, 24, APFontSmall, 0xF8F4EC);
        APBlendRect(c, 1, 0, 3, 2, 0xF0E8C8, 0.8f); APBlendRect(c, 12, 0, 3, 2, 0xF0E8C8, 0.8f);
    });
    [items addObject:poster];
}

static void APRegisterWindows(NSMutableArray *items) {
    NSArray *curtains = @[@"red", @"navy", @"sage", @"cream", @"rose"];
    APItemSpec *window = APSpec(@"window", @"Cottage Window", APLayerWall, APCategoryWall, 2, 2, 0,
                                @[@"Snowfall", @"Starry", @"Rainy", @"Clear Skies", @"Blossom"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp wood = APRampNamed(@"oak");
        APRamp curtain = APRampNamed(curtains[ctx.variant % curtains.count]);
        int weather = ctx.variant == 0 ? 0 : ctx.variant == 2 ? 2 : ctx.variant == 1 ? 1 : 3;
        // Frame and glass.
        APRect(c, 3, 2, 26, 25, wood.m);
        APHLine(c, 3, 2, 26, wood.h);
        int gx = 5, gy = 4, gw = 22, gh = 21;
        if (!ctx.on) {
            // Curtains drawn (tap to open): fabric across the glass, folds
            // and a seam down the middle, a sliver of the sky's colour at
            // the gap. No sky, no daylight in the room.
            for (int y = 1; y < 27; y++) for (int x = 1; x < 31; x++) {
                int fold = (x + (x > 15 ? 1 : 0)) % 4;
                APPx(c, x, y, fold == 0 ? curtain.d : fold == 3 ? curtain.l : curtain.m);
            }
            APVLine(c, 15, 2, 25, curtain.d);
            APVLine(c, 16, 2, 25, curtain.d);
            APHLine(c, 0, 1, 32, 0xC8962A);
            APPx(c, 0, 0, 0xE8BE48); APPx(c, 31, 0, 0xE8BE48);
            APRect(c, 1, 26, 30, 3, wood.l);
            APHLine(c, 1, 26, 30, wood.h);
            APHLine(c, 1, 29, 30, wood.d);
            APPaintingShadow(c, 1, 26, 30, 3);
            if (APSkyPhaseForHour(ctx.hour) == APSkyDay) [ctx addLight:[APLight x:16 y:20 radius:24 color:0xFFE8C8 strength:0.08f]];
            return;
        }
        APSky(ctx.emissive, gx, gy, gw, gh, ctx.hour, weather, 0x5EED);
        // Mullions live on the emissive layer so they sit over the sky.
        APRect(ctx.emissive, gx + gw / 2 - 1, gy, 2, gh, wood.l);
        APRect(ctx.emissive, gx, gy + gh / 2 - 1, gw, 2, wood.l);
        APVLine(ctx.emissive, gx + gw / 2, gy, gh, wood.m);
        APHLine(ctx.emissive, gx, gy + gh / 2, gw, wood.m);
        // Frost in the corners on snowy nights.
        if (weather == 0) {
            for (int k = 0; k < 3; k++) { APPx(ctx.emissive, gx + k, gy + gh - 1 - (2 - k), 0xE8F0F8); APPx(ctx.emissive, gx + gw - 1 - k, gy + gh - 1 - (2 - k), 0xE8F0F8); }
        }
        // Sill.
        APRect(c, 1, 26, 30, 3, wood.l);
        APHLine(c, 1, 26, 30, wood.h);
        APHLine(c, 1, 29, 30, wood.d);
        APPaintingShadow(c, 1, 26, 30, 3);
        // Curtain rod + gathered curtains with tie-backs.
        APHLine(c, 0, 1, 32, 0xC8962A);
        APPx(c, 0, 0, 0xE8BE48); APPx(c, 31, 0, 0xE8BE48);
        for (int side = 0; side < 2; side++) {
            for (int y = 1; y < 27; y++) {
                int width = y < 14 ? 6 - y / 5 : 3 + (y - 14) / 3;
                width = MAX(3, MIN(width, 7));
                for (int k = 0; k < width; k++) {
                    int xx = side ? 31 - k : k;
                    uint32_t col = (k + y / 3) % 3 == 0 ? curtain.d : k == width - 1 ? curtain.l : curtain.m;
                    APPx(c, xx, y, col);
                }
            }
            int tx = side ? 28 : 1;
            APHLine(c, tx, 14, 3, 0xE8BE48);
        }
        // A tiny plant on the sill (front of everything).
        APRect(ctx.front, 22, 22, 4, 4, 0xB0643A);
        APPx(ctx.front, 23, 21, 0x5E8A3C); APPx(ctx.front, 24, 20, 0x86B052); APPx(ctx.front, 25, 21, 0x5E8A3C);
        APPx(ctx.front, 22, 20, 0x86B052);
        APAnim *glass = [APAnim kind:APAnimWindow x:gx y:gy w:gw h:gh];
        glass.variant = weather;
        [ctx addAnim:glass];
        APSkyPhase phase = APSkyPhaseForHour(ctx.hour);
        if (phase == APSkyDay) [ctx addLight:[APLight x:16 y:30 radius:84 color:0xE8EEFF strength:0.55f]];
        else if (phase == APSkyDusk) [ctx addLight:[APLight x:16 y:30 radius:60 color:0xFFB08A strength:0.35f]];
        else [ctx addLight:[APLight x:16 y:30 radius:46 color:0x8A9ADA strength:0.22f]];
    });
    window.toggleable = YES; // tap: open/close the curtains
    [items addObject:window];

    APItemSpec *round = APSpec(@"window.round", @"Round Window", APLayerWall, APCategoryWall, 1, 1, 0,
                               @[@"Snowfall", @"Starry", @"Rainy", @"Clear Skies"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp wood = APRampNamed(@"oak");
        int weather = ctx.variant == 0 ? 0 : ctx.variant == 2 ? 2 : ctx.variant == 1 ? 1 : 3;
        APCircle(c, 8, 7, 7, wood.m);
        APEllipseOutline(c, 1, 0, 15, 15, wood.d);
        APEllipseOutline(c, 2, 1, 13, 13, wood.h);
        APCanvas *sky = APCanvasCreate(16, 16);
        APSky(sky, 0, 0, 16, 16, ctx.hour, weather, 0xB0B);
        for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
            int d2 = (x - 8) * (x - 8) + (y - 7) * (y - 7);
            if (d2 > 26) continue;
            // A single thin mullion cross, only across the glass.
            BOOL bar = (x == 8 || y == 7) && d2 <= 26;
            APPx(ctx.emissive, x, y, bar ? wood.l : APGet(sky, x, y));
        }
        APCanvasFree(sky);
        APPx(ctx.emissive, 6, 5, 0xE8F0F8); // glint
        APPaintingShadow(c, 1, 0, 14, 15);
        APAnim *glass = [APAnim kind:APAnimWindow x:4 y:3 w:9 h:9];
        glass.variant = weather;
        [ctx addAnim:glass];
    });
    [items addObject:round];
}

static void APClockHands(APCanvas *c, int cx, int cy, int hour, int minute, int len) {
    float ma = minute / 60.0f * 2 * M_PI, ha = ((hour % 12) + minute / 60.0f) / 12.0f * 2 * M_PI;
    APLine(c, cx, cy, cx + (int)lroundf(sinf(ma) * len), cy - (int)lroundf(cosf(ma) * len), 0x2A2020);
    APLine(c, cx, cy, cx + (int)lroundf(sinf(ha) * (len - 2)), cy - (int)lroundf(cosf(ha) * (len - 2)), 0x2A2020);
    APPx(c, cx, cy, 0xC44A44);
}

static void APRegisterClocks(NSMutableArray *items) {
    [items addObject:APSpec(@"clock", @"Wall Clock", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Oak", @"Brass", @"Mint"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp rim = APRampNamed(ctx.variant == 1 ? @"gold" : ctx.variant == 2 ? @"teal" : @"oak");
        APPaintingShadow(c, 2, 1, 13, 13);
        APCircle(c, 8, 7, 6, rim.m);
        APEllipseOutline(c, 2, 1, 13, 13, rim.d);
        APCircle(c, 8, 7, 4, 0xF8F4EC);
        APPx(c, 8, 3, 0x6A5A4A); APPx(c, 8, 11, 0x6A5A4A); APPx(c, 4, 7, 0x6A5A4A); APPx(c, 12, 7, 0x6A5A4A);
        APClockHands(c, 8, 7, ctx.hour, ctx.minute, 3);
        [ctx addAnim:[APAnim kind:APAnimClockHands x:8 y:7 w:0 h:0]];
    })];
    [items addObject:APSpec(@"clock.cuckoo", @"Cuckoo Clock", APLayerWall, APCategoryWall, 1, 2, 0, @[@"Chalet", @"Painted"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"teal" : @"walnut");
        APRamp roof = APRampNamed(ctx.variant ? @"rose" : @"oak");
        // Roof.
        for (int k = 0; k < 5; k++) APHLine(c, 8 - 2 - k * 2 + 1, 1 + k, 4 + k * 4 - 2, roof.m);
        APHLine(c, 0, 5, 16, roof.l);
        // Body.
        APRect(c, 2, 6, 12, 12, w.m);
        APHLine(c, 2, 6, 12, w.l);
        APRect(c, 6, 3, 4, 3, w.d); APPx(c, 7, 4, 0xF0C050); // bird door
        APCircle(c, 8, 11, 3, 0xF8F4EC);
        APClockHands(c, 8, 11, ctx.hour, ctx.minute, 2);
        APHLine(c, 3, 16, 10, w.d);
        APPx(c, 3, 8, 0x86B052); APPx(c, 12, 8, 0x86B052); APPx(c, 4, 9, 0x6A8A64); APPx(c, 11, 9, 0x6A8A64);
        APOutlineInside(c, w.o);
        APPaintingShadow(c, 2, 6, 12, 12);
        // Pine-cone weights on chains.
        APVLine(c, 5, 18, 9, 0x8A8070); APVLine(c, 11, 18, 6, 0x8A8070);
        APRect(c, 4, 27, 3, 4, 0x6A4228); APRect(c, 10, 24, 3, 4, 0x6A4228);
        APPx(c, 5, 28, 0x8A5A36); APPx(c, 11, 25, 0x8A5A36);
        APAnim *pendulum = [APAnim kind:APAnimPendulum x:8 y:17 w:0 h:0];
        pendulum.size = 9;
        pendulum.color = 0xC8962A;
        [ctx addAnim:pendulum];
        [ctx addAnim:[APAnim kind:APAnimClockHands x:8 y:11 w:0 h:0]];
    })];
}

static void APShelfBoard(APCanvas *c, int y, APRamp w) {
    APRect(c, 1, y, 30, 2, w.l);
    APHLine(c, 1, y, 30, w.h);
    APHLine(c, 1, y + 2, 30, w.d);
    APRect(c, 4, y + 2, 2, 2, w.d); APRect(c, 26, y + 2, 2, 2, w.d);
    APBlendRect(c, 2, y + 3, 30, 1, 0x1A0C06, 0.3f);
}

static void APRegisterShelves(NSMutableArray *items) {
    [items addObject:APSpec(@"shelf.plants", @"Plant Shelf", APLayerWall, APCategoryWall, 2, 1, 0, @[@"Oak", @"Walnut"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"walnut" : @"oak");
        APRamp leaf = APRampNamed(@"leaf");
        APShelfBoard(c, 10, w);
        APRect(c, 3, 6, 5, 4, 0xB0643A); APRect(c, 13, 5, 6, 5, 0xECE0C4); APRect(c, 24, 7, 4, 3, 0x6076AA);
        // Trailing pothos.
        for (int k = 0; k < 7; k++) { APPx(c, 4 + (k % 2), 10 + k, leaf.m); APPx(c, 5 + (k % 2), 10 + k, leaf.l); }
        APPx(c, 3, 5, leaf.l); APPx(c, 5, 4, leaf.m); APPx(c, 7, 5, leaf.l);
        for (int k = 0; k < 5; k++) APPx(c, 15 + k % 3, 4 - k % 2, k % 2 ? leaf.l : leaf.m);
        APVLine(c, 16, 1, 4, leaf.d); APPx(c, 17, 1, 0xE87A9A);
        APPx(c, 25, 6, leaf.l); APPx(c, 26, 5, leaf.m); APPx(c, 27, 6, leaf.l);
        for (int k = 0; k < 4; k++) APPx(c, 27 + (k % 2), 12 + k, leaf.m);
    })];
    APItemSpec *candles = APSpec(@"shelf.candles", @"Candle Shelf", APLayerWall, APCategoryWall, 2, 1, 0, @[@"Oak", @"Walnut"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"walnut" : @"oak");
        APShelfBoard(c, 11, w);
        APCandle(ctx, 6, 11, 6, 0xF4E8D0);
        APCandle(ctx, 10, 11, 4, 0xE8C8A0);
        APCandle(ctx, 22, 11, 5, 0xF4E8D0);
        APRect(c, 14, 7, 5, 4, 0x6A8AA0); APHLine(c, 14, 7, 5, 0x8AA8C0); // jar
        if (ctx.on) {
            APAnim *glow = [APAnim kind:APAnimGlow x:14 y:5 w:0 h:0];
            glow.size = 16; glow.color = 0xFFC060;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:14 y:6 radius:40 color:0xFFB860 strength:0.5f]];
        }
    });
    candles.toggleable = YES;
    [items addObject:candles];
    [items addObject:APSpec(@"shelf.books", @"Book Ledge", APLayerWall, APCategoryWall, 2, 1, 0, @[@"Oak", @"Walnut"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp w = APRampNamed(ctx.variant ? @"walnut" : @"oak");
        APShelfBoard(c, 11, w);
        uint32_t spines[] = {0xA85432, 0x6076AA, 0xDCB04A, 0x6A8A64, 0xCC8498, 0x4E4270};
        int x = 5;
        for (int i = 0; i < 8; i++) {
            int bh = 6 + (i * 5) % 4;
            APRect(c, x, 11 - bh, 2, bh, spines[i % 6]);
            APVLine(c, x, 11 - bh, bh, APShade(spines[i % 6], 1.15f));
            x += 2;
        }
        APLine(c, x, 10, x + 4, 5, 0xA85432); APLine(c, x + 1, 10, x + 5, 5, 0xC87444);
        APRect(c, 3, 6, 2, 5, 0x56566A); APRect(c, 25, 6, 2, 5, 0x56566A);
    })];
    APItemSpec *sconce = APSpec(@"sconce", @"Wall Sconce", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Brass", @"Black"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp metal = APRampNamed(ctx.variant ? @"iron" : @"gold");
        APRect(c, 7, 7, 2, 6, metal.d);
        APRect(c, 6, 12, 4, 2, metal.m);
        APLine(c, 8, 12, 11, 9, metal.m);
        for (int y = 3; y < 9; y++) APHLine(c, 11 - (y - 3) / 2 - 2, y, 4 + (y - 3) / 2 * 2 - 1, 0xE8D8B0);
        if (ctx.on) {
            for (int y = 3; y < 9; y++) APHLine(ctx.emissive, 11 - (y - 3) / 2 - 2, y, 4 + (y - 3) / 2 * 2 - 1, y < 6 ? 0xFFE8B0 : 0xFFD080);
            APAnim *glow = [APAnim kind:APAnimGlow x:10 y:6 w:0 h:0];
            glow.size = 16; glow.color = 0xFFC878;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:10 y:6 radius:48 color:0xFFC070 strength:0.6f]];
        }
        APPaintingShadow(c, 6, 7, 3, 7);
    });
    sconce.toggleable = YES;
    [items addObject:sconce];
    [items addObject:APSpec(@"mirror", @"Sunburst Mirror", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Gilded", @"Rattan"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp g = APRampNamed(ctx.variant ? @"oak" : @"gold");
        for (int i = 0; i < 12; i++) {
            float a = i / 12.0f * 2 * M_PI;
            APLine(c, 8, 7, 8 + (int)lroundf(cosf(a) * 7), 7 + (int)lroundf(sinf(a) * 7), i % 2 ? g.l : g.m);
        }
        APCircle(c, 8, 7, 4, g.d);
        APCircle(c, 8, 7, 3, 0xA8C0C8);
        APLine(c, 6, 8, 9, 5, 0xE0ECF0);
        APPx(c, 7, 9, 0xC8DCE0);
    })];
    [items addObject:APSpec(@"wreath", @"Wreath", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Evergreen", @"Dried Flowers"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t a = ctx.variant ? 0xC8A060 : 0x3E6A34, b = ctx.variant ? 0xA88048 : 0x5E8A3C;
        for (int i = 0; i < 18; i++) {
            float ang = i / 18.0f * 2 * M_PI;
            int x = 8 + (int)lroundf(cosf(ang) * 5), y = 7 + (int)lroundf(sinf(ang) * 5);
            APCircle(c, x, y, 1, i % 2 ? a : b);
        }
        uint32_t berry = ctx.variant ? 0xE8A0B0 : 0xC8302A;
        APPx(c, 4, 4, berry); APPx(c, 12, 6, berry); APPx(c, 6, 11, berry); APPx(c, 11, 11, berry);
        APPx(c, 7, 12, 0xC8302A); APPx(c, 9, 12, 0xC8302A); APPx(c, 8, 13, 0xC8302A); APPx(c, 8, 12, 0xE04A40);
    })];
    [items addObject:APSpec(@"corkboard", @"Memory Board", APLayerWall, APCategoryWall, 2, 1, 0, @[@"Cork"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APPaintingShadow(c, 1, 1, 30, 13);
        APRect(c, 1, 1, 30, 13, 0x8A5A36);
        APRect(c, 2, 2, 28, 11, 0xC8965A);
        APDitherRect(c, 2, 2, 28, 11, 0xB8864A, 0.35f);
        // Polaroids and notes.
        APRect(c, 4, 3, 6, 7, 0xF8F4EC); APRect(c, 5, 4, 4, 4, 0x6AA0C8); APPx(c, 6, 6, 0x5E8A3C);
        APRect(c, 12, 4, 6, 6, 0xF0E080); APHLine(c, 13, 6, 4, 0x8A8050); APHLine(c, 13, 8, 3, 0x8A8050);
        APRect(c, 20, 3, 6, 7, 0xF8F4EC); APRect(c, 21, 4, 4, 4, 0xE8964A); APPx(c, 22, 5, 0x1A1A1E);
        APRect(c, 26, 8, 3, 3, 0xE8A0B0);
        APPx(c, 7, 3, 0xC44A44); APPx(c, 15, 4, 0x3A6AB0); APPx(c, 23, 3, 0x5E8A3C);
    })];
    APItemSpec *upvote = APSpec(@"neon.upvote", @"Upvote Neon", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Orangered", @"Periwinkle"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t tube = ctx.variant ? 0x9494FF : 0xFF5A2A;
        APRect(c, 2, 1, 12, 13, 0x2A2226);
        APRectOutline(c, 2, 1, 12, 13, 0x1A1418);
        APPaintingShadow(c, 2, 1, 12, 13);
        // Arrow outline.
        static const char *arrow[] = {
            "....#....", "...#.#...", "..#...#..", ".#.....#.", "###...###", "..#...#..", "..#...#..", "..#...#..", "..#####..",
        };
        APCanvas *layer = ctx.on ? ctx.emissive : c;
        uint32_t col = ctx.on ? tube : APShade(tube, 0.45f);
        for (int y = 0; y < 9; y++) for (int x = 0; x < 9; x++) {
            if (arrow[y][x] == '#') APPx(layer, 4 + x, 3 + y, col);
        }
        if (ctx.on) {
            [ctx addAnim:[APAnim kind:APAnimNeon x:4 y:3 w:9 h:9]];
            APAnim *glow = [APAnim kind:APAnimGlow x:8 y:7 w:0 h:0];
            glow.size = 14; glow.color = tube;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:8 y:8 radius:36 color:tube strength:0.45f]];
        }
    });
    upvote.toggleable = YES;
    [items addObject:upvote];
    APItemSpec *heart = APSpec(@"neon.heart", @"Heart Neon", APLayerWall, APCategoryWall, 1, 1, 0, @[@"Pink", @"Warm White"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t tube = ctx.variant ? 0xFFE8B8 : 0xFF6AAA;
        static const char *shape[] = {
            ".##...##.", "#..#.#..#", "#...#...#", "#.......#", ".#.....#.", "..#...#..", "...#.#...", "....#....",
        };
        APCanvas *layer = ctx.on ? ctx.emissive : c;
        uint32_t col = ctx.on ? tube : APShade(tube, 0.45f);
        for (int y = 0; y < 8; y++) for (int x = 0; x < 9; x++) {
            if (shape[y][x] == '#') APPx(layer, 4 + x, 3 + y, col);
        }
        if (ctx.on) {
            [ctx addAnim:[APAnim kind:APAnimNeon x:4 y:3 w:9 h:8]];
            APAnim *glow = [APAnim kind:APAnimGlow x:8 y:7 w:0 h:0];
            glow.size = 14; glow.color = tube;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:8 y:8 radius:36 color:tube strength:0.45f]];
        }
    });
    heart.toggleable = YES;
    [items addObject:heart];
}

#pragma mark - Garlands (top trim)

// A sagging wire between hooks; `sag` pixels at the middle of each span.
static int APCatenaryY(int x, int span, int sag) {
    float t = (x % span) / (float)span;
    return (int)lroundf(1 + sag * 4 * t * (1 - t));
}

static void APRegisterTrim(NSMutableArray *items) {
    APItemSpec *lights = APSpec(@"fairylights", @"Fairy Lights", APLayerTrim, APCategoryWall, 4, 1, 0,
                                @[@"Warm White", @"Rainbow", @"Rose Gold"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        int span = 32;
        for (int x = 0; x < ctx.width; x++) APPx(c, x, APCatenaryY(x, span, 6), 0x3A3A30);
        uint32_t rainbow[] = {0xFF6A6A, 0xFFC04A, 0x7AE07A, 0x6AC0FF, 0xD08AFF};
        for (int x = 3, i = 0; x < ctx.width - 1; x += 5, i++) {
            int y = APCatenaryY(x, span, 6) + 1;
            uint32_t bulb = ctx.variant == 1 ? rainbow[i % 5] : ctx.variant == 2 ? (i % 2 ? 0xFFB0A0 : 0xFFE0C0) : 0xFFE0A0;
            if (ctx.on) {
                APPx(ctx.emissive, x, y, bulb);
                APPx(ctx.emissive, x, y + 1, APShade(bulb, 0.85f));
                APAnim *twinkle = [APAnim kind:APAnimTwinkle x:x y:y w:1 h:2];
                twinkle.color = bulb;
                [ctx addAnim:twinkle];
            } else {
                APPx(c, x, y, APShade(bulb, 0.5f));
                APPx(c, x, y + 1, APShade(bulb, 0.4f));
            }
        }
        if (ctx.on) {
            [ctx addLight:[APLight x:16 y:6 radius:30 color:0xFFD090 strength:0.25f]];
            [ctx addLight:[APLight x:48 y:6 radius:30 color:0xFFD090 strength:0.25f]];
        }
    });
    lights.toggleable = YES;
    [items addObject:lights];

    [items addObject:APSpec(@"bunting", @"Bunting", APLayerTrim, APCategoryWall, 4, 1, 0, @[@"Carnival", @"Pastel"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t bold[] = {0xE06A5A, 0xF0C050, 0x6AA0C8, 0x7AB07A};
        uint32_t soft[] = {0xF0B8C0, 0xF8E0A0, 0xB0D0E8, 0xC0E0B8};
        for (int x = 0; x < ctx.width; x++) APPx(c, x, APCatenaryY(x, 32, 5), 0xE8DCC0);
        for (int x = 2, i = 0; x < ctx.width - 4; x += 6, i++) {
            int y = APCatenaryY(x + 2, 32, 5) + 1;
            uint32_t col = (ctx.variant ? soft : bold)[i % 4];
            for (int k = 0; k < 5; k++) APHLine(c, x + k / 2, y + k, 5 - (k / 2) * 2, col);
            APPx(c, x, y, APShade(col, 1.15f));
        }
    })];

    APItemSpec *lanterns = APSpec(@"lanterns", @"Paper Lanterns", APLayerTrim, APCategoryWall, 2, 1, 0, @[@"Amber", @"Blossom"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        uint32_t paper = ctx.variant ? 0xF4A8B8 : 0xF0A850;
        int xs[] = {7, 23}, drops[] = {5, 3};
        for (int i = 0; i < 2; i++) {
            int x = xs[i], y = drops[i];
            APVLine(c, x, 0, y, 0x3A3A30);
            APRect(c, x - 2, y, 5, 1, 0x3A2A20);
            APCanvas *layer = ctx.on ? ctx.emissive : c;
            uint32_t body = ctx.on ? paper : APShade(paper, 0.6f);
            APEllipse(layer, x - 4, y + 1, 9, 8, body);
            for (int k = 0; k < 3; k++) APHLine(layer, x - 3, y + 2 + k * 2, 7, APShade(body, 0.85f));
            if (ctx.on) APRect(ctx.emissive, x - 1, y + 3, 3, 3, 0xFFF0C0);
            APRect(c, x - 2, y + 9, 5, 1, 0x3A2A20);
        }
        if (ctx.on) {
            APAnim *glow = [APAnim kind:APAnimGlow x:15 y:8 w:0 h:0];
            glow.size = 18; glow.color = paper;
            [ctx addAnim:glow];
            [ctx addLight:[APLight x:15 y:8 radius:42 color:APMix(paper, 0xFFFFFF, 0.3f) strength:0.4f]];
        }
    });
    lanterns.toggleable = YES;
    [items addObject:lanterns];

    [items addObject:APSpec(@"garland", @"Evergreen Garland", APLayerTrim, APCategoryWall, 4, 1, 0, @[@"Berries", @"Baubles"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        for (int x = 0; x < ctx.width; x++) {
            int y = APCatenaryY(x, 32, 5);
            APVLine(c, x, y, 3, x % 3 ? 0x3E6A34 : 0x5E8A3C);
            if (x % 4 == 0) APPx(c, x, y + 3, 0x2E4A24);
        }
        for (int x = 5, i = 0; x < ctx.width; x += 9, i++) {
            int y = APCatenaryY(x, 32, 5) + 2;
            if (ctx.variant) { APCircle(c, x, y + 1, 1, i % 2 ? 0xC8962A : 0xC44A44); APPx(c, x - 1, y, 0xFCE69A); }
            else { APPx(c, x, y, 0xC8302A); APPx(c, x + 1, y + 1, 0xE04A40); }
        }
        // Bows at the hooks.
        for (int x = 0; x <= ctx.width; x += 32) {
            int bx = MIN(x, ctx.width - 3);
            APPx(c, bx, 0, 0xC44A44); APPx(c, bx + 2, 0, 0xC44A44); APPx(c, bx + 1, 1, 0x9E2E30);
        }
    })];

    [items addObject:APSpec(@"plant.hanging", @"Hanging Planter", APLayerTrim, APCategoryWall, 1, 2, 0, @[@"Macramé"], ^(APDrawContext *ctx) {
        APCanvas *c = ctx.base;
        APRamp leaf = APRampNamed(@"leaf");
        APLine(c, 8, 0, 4, 12, 0xE8DCC0); APLine(c, 8, 0, 12, 12, 0xE8DCC0); APVLine(c, 8, 0, 12, 0xD8C8A8);
        APRect(c, 4, 12, 9, 6, 0xECE0C4); APHLine(c, 4, 12, 9, 0xFAF4E4);
        for (int k = 0; k < 12; k++) {
            APPx(c, 3 + (k % 2), 13 + k, k % 3 ? leaf.m : leaf.l);
            APPx(c, 13 - (k % 2), 14 + k * 3 / 4, k % 2 ? leaf.m : leaf.l);
        }
        APPx(c, 5, 11, leaf.l); APPx(c, 7, 10, leaf.m); APPx(c, 10, 11, leaf.l); APPx(c, 12, 10, leaf.m);
        APOutlineInside(c, leaf.o);
    })];
}

void APRegisterWallItems(NSMutableArray<APItemSpec *> *items) {
    APRegisterWindows(items);
    APRegisterClocks(items);
    APRegisterShelves(items);
    APRegisterTrim(items);
    APRegisterArt(items);
}
