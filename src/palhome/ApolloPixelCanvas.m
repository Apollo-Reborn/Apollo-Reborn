#import "ApolloPixelCanvas.h"
#import <CoreText/CoreText.h>
#import <math.h>

#pragma mark - Canvas

APCanvas *APCanvasCreate(int w, int h) {
    APCanvas *c = calloc(1, sizeof(APCanvas));
    c->w = MAX(w, 1);
    c->h = MAX(h, 1);
    c->px = calloc((size_t)c->w * c->h, sizeof(uint32_t));
    return c;
}

void APCanvasFree(APCanvas *c) {
    if (!c) return;
    free(c->px);
    free(c);
}

APCanvas *APCanvasCopy(const APCanvas *c) {
    APCanvas *copy = APCanvasCreate(c->w, c->h);
    memcpy(copy->px, c->px, (size_t)c->w * c->h * sizeof(uint32_t));
    return copy;
}

static inline BOOL APIn(const APCanvas *c, int x, int y) { return x >= 0 && y >= 0 && x < c->w && y < c->h; }

void APPx(APCanvas *c, int x, int y, uint32_t rgb) {
    if (APIn(c, x, y)) c->px[y * c->w + x] = 0xFF000000u | (rgb & 0xFFFFFF);
}

void APRect(APCanvas *c, int x, int y, int w, int h, uint32_t rgb) {
    int x0 = MAX(x, 0), y0 = MAX(y, 0), x1 = MIN(x + w, c->w), y1 = MIN(y + h, c->h);
    uint32_t v = 0xFF000000u | (rgb & 0xFFFFFF);
    for (int yy = y0; yy < y1; yy++) for (int xx = x0; xx < x1; xx++) c->px[yy * c->w + xx] = v;
}

void APHLine(APCanvas *c, int x, int y, int w, uint32_t rgb) { APRect(c, x, y, w, 1, rgb); }
void APVLine(APCanvas *c, int x, int y, int h, uint32_t rgb) { APRect(c, x, y, 1, h, rgb); }

void APLine(APCanvas *c, int x0, int y0, int x1, int y1, uint32_t rgb) {
    int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        APPx(c, x0, y0, rgb);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

void APRectOutline(APCanvas *c, int x, int y, int w, int h, uint32_t rgb) {
    APHLine(c, x, y, w, rgb);
    APHLine(c, x, y + h - 1, w, rgb);
    APVLine(c, x, y, h, rgb);
    APVLine(c, x + w - 1, y, h, rgb);
}

void APRoundRect(APCanvas *c, int x, int y, int w, int h, uint32_t rgb) {
    APRect(c, x + 1, y, w - 2, h, rgb);
    APRect(c, x, y + 1, 1, h - 2, rgb);
    APRect(c, x + w - 1, y + 1, 1, h - 2, rgb);
}

// Midpoint-style ellipse membership test on pixel centres, so small ellipses
// come out symmetric and without single-pixel spurs.
static inline BOOL APInEllipse(int px, int py, int x, int y, int w, int h) {
    double rx = w / 2.0, ry = h / 2.0;
    double dx = (px + 0.5 - (x + rx)) / rx, dy = (py + 0.5 - (y + ry)) / ry;
    return dx * dx + dy * dy <= 1.0;
}

void APEllipse(APCanvas *c, int x, int y, int w, int h, uint32_t rgb) {
    for (int yy = y; yy < y + h; yy++) for (int xx = x; xx < x + w; xx++) {
        if (APInEllipse(xx, yy, x, y, w, h)) APPx(c, xx, yy, rgb);
    }
}

void APEllipseOutline(APCanvas *c, int x, int y, int w, int h, uint32_t rgb) {
    for (int yy = y; yy < y + h; yy++) for (int xx = x; xx < x + w; xx++) {
        if (!APInEllipse(xx, yy, x, y, w, h)) continue;
        if (!APInEllipse(xx - 1, yy, x, y, w, h) || !APInEllipse(xx + 1, yy, x, y, w, h) ||
            !APInEllipse(xx, yy - 1, x, y, w, h) || !APInEllipse(xx, yy + 1, x, y, w, h)) APPx(c, xx, yy, rgb);
    }
}

void APCircle(APCanvas *c, int cx, int cy, int r, uint32_t rgb) { APEllipse(c, cx - r, cy - r, r * 2 + 1, r * 2 + 1, rgb); }

void APBlendPx(APCanvas *c, int x, int y, uint32_t rgb, float alpha) {
    if (!APIn(c, x, y) || alpha <= 0) return;
    if (alpha >= 1) { APPx(c, x, y, rgb); return; }
    uint32_t d = c->px[y * c->w + x];
    float da = ((d >> 24) & 255) / 255.0f;
    float oa = alpha + da * (1 - alpha);
    if (oa <= 0) return;
    float sr = (rgb >> 16) & 255, sg = (rgb >> 8) & 255, sb = rgb & 255;
    float dr = (d >> 16) & 255, dg = (d >> 8) & 255, db = d & 255;
    uint32_t r = (uint32_t)lroundf((sr * alpha + dr * da * (1 - alpha)) / oa);
    uint32_t g = (uint32_t)lroundf((sg * alpha + dg * da * (1 - alpha)) / oa);
    uint32_t b = (uint32_t)lroundf((sb * alpha + db * da * (1 - alpha)) / oa);
    uint32_t a = (uint32_t)lroundf(oa * 255);
    c->px[y * c->w + x] = (a << 24) | (MIN(r, 255u) << 16) | (MIN(g, 255u) << 8) | MIN(b, 255u);
}

void APBlendRect(APCanvas *c, int x, int y, int w, int h, uint32_t rgb, float alpha) {
    for (int yy = y; yy < y + h; yy++) for (int xx = x; xx < x + w; xx++) APBlendPx(c, xx, yy, rgb, alpha);
}

static const int kBayer[4][4] = {{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}};
float APBayer(int x, int y) { return (kBayer[y & 3][x & 3] + 0.5f) / 16.0f; }

void APDitherRect(APCanvas *c, int x, int y, int w, int h, uint32_t rgb, float amount) {
    for (int yy = y; yy < y + h; yy++) for (int xx = x; xx < x + w; xx++) {
        if (APBayer(xx, yy) < amount) APPx(c, xx, yy, rgb);
    }
}

uint32_t APGet(const APCanvas *c, int x, int y) { return APIn(c, x, y) ? c->px[y * c->w + x] : 0; }
BOOL APCanvasIsEmpty(const APCanvas *c) {
    for (int i = 0; i < c->w * c->h; i++) if (c->px[i] >> 24) return NO;
    return YES;
}

BOOL APOpaqueAt(const APCanvas *c, int x, int y) { return (APGet(c, x, y) >> 24) > 0x40; }

void APDraw(APCanvas *dst, const APCanvas *src, int x, int y, BOOL flip) {
    for (int sy = 0; sy < src->h; sy++) for (int sx = 0; sx < src->w; sx++) {
        uint32_t p = src->px[sy * src->w + (flip ? src->w - 1 - sx : sx)];
        uint32_t a = p >> 24;
        if (!a) continue;
        if (a == 255) APPx(dst, x + sx, y + sy, p);
        else APBlendPx(dst, x + sx, y + sy, p & 0xFFFFFF, a / 255.0f);
    }
}

void APTint(APCanvas *c, uint32_t rgb) {
    for (int i = 0; i < c->w * c->h; i++) {
        if (c->px[i] >> 24) c->px[i] = (c->px[i] & 0xFF000000u) | (rgb & 0xFFFFFF);
    }
}

void APOutlineInside(APCanvas *c, uint32_t rgb) {
    APCanvas *copy = APCanvasCopy(c);
    for (int y = 0; y < c->h; y++) for (int x = 0; x < c->w; x++) {
        if (!APOpaqueAt(copy, x, y)) continue;
        if (!APOpaqueAt(copy, x - 1, y) || !APOpaqueAt(copy, x + 1, y) ||
            !APOpaqueAt(copy, x, y - 1) || !APOpaqueAt(copy, x, y + 1)) APPx(c, x, y, rgb);
    }
    APCanvasFree(copy);
}

void APShadow(APCanvas *c, int x, int y, int w, int h) {
    // Only under what's already there's edges: shadows go beneath, so paint
    // into transparent pixels (and gently darken nothing that's opaque).
    for (int yy = y; yy < y + h; yy++) for (int xx = x; xx < x + w; xx++) {
        if (!APInEllipse(xx, yy, x, y, w, h) || APOpaqueAt(c, xx, yy)) continue;
        APBlendPx(c, xx, yy, 0x1A0C06, 0.38f);
    }
}

APCanvas *APCanvasOutline(const APCanvas *src, uint32_t rgb) {
    APCanvas *out = APCanvasCreate(src->w + 2, src->h + 2);
    for (int y = -1; y <= src->h; y++) for (int x = -1; x <= src->w; x++) {
        if (APOpaqueAt(src, x, y)) continue;
        if (APOpaqueAt(src, x - 1, y) || APOpaqueAt(src, x + 1, y) ||
            APOpaqueAt(src, x, y - 1) || APOpaqueAt(src, x, y + 1)) APPx(out, x + 1, y + 1, rgb);
    }
    return out;
}

#pragma mark - Colour

uint32_t APMix(uint32_t a, uint32_t b, float t) {
    t = fmaxf(0, fminf(1, t));
    int r = (int)lroundf(((a >> 16) & 255) * (1 - t) + ((b >> 16) & 255) * t);
    int g = (int)lroundf(((a >> 8) & 255) * (1 - t) + ((b >> 8) & 255) * t);
    int bl = (int)lroundf((a & 255) * (1 - t) + (b & 255) * t);
    return (uint32_t)((r << 16) | (g << 8) | bl);
}

uint32_t APMultiply(uint32_t rgb, float r, float g, float b) {
    int rr = MIN(255, (int)lroundf(((rgb >> 16) & 255) * r));
    int gg = MIN(255, (int)lroundf(((rgb >> 8) & 255) * g));
    int bb = MIN(255, (int)lroundf((rgb & 255) * b));
    return (uint32_t)((MAX(rr, 0) << 16) | (MAX(gg, 0) << 8) | MAX(bb, 0));
}

uint32_t APShade(uint32_t rgb, float f) { return APMultiply(rgb, f, f, f); }

#pragma mark - PRNG

uint32_t APRandNext(APRand *r) {
    uint32_t x = r->s ?: 0x9E3779B9u;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    r->s = x;
    return x;
}
float APRandFloat(APRand *r) { return (APRandNext(r) & 0xFFFFFF) / (float)0x1000000; }
int APRandInt(APRand *r, int lo, int hi) { return lo + (int)(APRandNext(r) % (uint32_t)(hi - lo + 1)); }

#pragma mark - Pixel font

// Glyph rows are separated by '|'. Widths are per glyph, so text is
// proportional ("I" is narrower than "M") the way hand-made pixel fonts are.
static NSDictionary<NSString *, NSString *> *APSmallGlyphs(void) {
    static NSDictionary *glyphs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        glyphs = @{
            @"A": @".#.|#.#|###|#.#|#.#", @"B": @"##.|#.#|##.|#.#|##.", @"C": @".##|#..|#..|#..|.##",
            @"D": @"##.|#.#|#.#|#.#|##.", @"E": @"###|#..|##.|#..|###", @"F": @"###|#..|##.|#..|#..",
            @"G": @".##|#..|#.#|#.#|.##", @"H": @"#.#|#.#|###|#.#|#.#", @"I": @"###|.#.|.#.|.#.|###",
            @"J": @"..#|..#|..#|#.#|.#.", @"K": @"#.#|#.#|##.|#.#|#.#", @"L": @"#..|#..|#..|#..|###",
            @"M": @"#...#|##.##|#.#.#|#...#|#...#", @"N": @"#..#|##.#|#.##|#..#|#..#", @"O": @".#.|#.#|#.#|#.#|.#.",
            @"P": @"##.|#.#|##.|#..|#..", @"Q": @".#..|#.#.|#.#.|#.#.|.#.#", @"R": @"##.|#.#|##.|#.#|#.#",
            @"S": @".##|#..|.#.|..#|##.", @"T": @"###|.#.|.#.|.#.|.#.", @"U": @"#.#|#.#|#.#|#.#|###",
            @"V": @"#.#|#.#|#.#|#.#|.#.", @"W": @"#...#|#...#|#.#.#|##.##|#...#", @"X": @"#.#|#.#|.#.|#.#|#.#",
            @"Y": @"#.#|#.#|.#.|.#.|.#.", @"Z": @"###|..#|.#.|#..|###",
            @"0": @"###|#.#|#.#|#.#|###", @"1": @".#|##|.#|.#|.#", @"2": @"##.|..#|.#.|#..|###",
            @"3": @"##.|..#|.#.|..#|##.", @"4": @"#.#|#.#|###|..#|..#", @"5": @"###|#..|##.|..#|##.",
            @"6": @".##|#..|###|#.#|###", @"7": @"###|..#|.#.|.#.|.#.", @"8": @"###|#.#|###|#.#|###",
            @"9": @"###|#.#|###|..#|##.",
            @" ": @"..|..|..|..|..", @".": @".|.|.|.|#", @",": @".|.|.|#|#", @"!": @"#|#|#|.|#",
            @"?": @"##.|..#|.#.|...|.#.", @"'": @"#|#|.|.|.", @"-": @"..|..|##|..|..", @":": @".|#|.|#|.",
            @"/": @"..#|..#|.#.|#..|#..", @"&": @".#.|#.#|.#.|#.#|.##", @"+": @"...|.#.|###|.#.|...",
            @"(": @".#|#.|#.|#.|.#", @")": @"#.|.#|.#|.#|#.", @"♥": @"##.##|#####|.###.|..#..|.....",
            @"·": @".|.|#|.|.", @"’": @"#|#|.|.|.",
        };
    });
    return glyphs;
}

static NSDictionary<NSString *, NSString *> *APLargeGlyphs(void) {
    static NSDictionary *glyphs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        glyphs = @{
            @"A": @".###.|#...#|#...#|#####|#...#|#...#|#...#", @"B": @"####.|#...#|#...#|####.|#...#|#...#|####.",
            @"C": @".###.|#...#|#....|#....|#....|#...#|.###.", @"D": @"####.|#...#|#...#|#...#|#...#|#...#|####.",
            @"E": @"#####|#....|#....|####.|#....|#....|#####", @"F": @"#####|#....|#....|####.|#....|#....|#....",
            @"G": @".###.|#...#|#....|#.###|#...#|#...#|.####", @"H": @"#...#|#...#|#...#|#####|#...#|#...#|#...#",
            @"I": @"###|.#.|.#.|.#.|.#.|.#.|###", @"J": @"..###|...#.|...#.|...#.|#..#.|#..#.|.##..",
            @"K": @"#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#", @"L": @"#....|#....|#....|#....|#....|#....|#####",
            @"M": @"#...#|##.##|#.#.#|#.#.#|#...#|#...#|#...#", @"N": @"#...#|##..#|#.#.#|#..##|#...#|#...#|#...#",
            @"O": @".###.|#...#|#...#|#...#|#...#|#...#|.###.", @"P": @"####.|#...#|#...#|####.|#....|#....|#....",
            @"Q": @".###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#", @"R": @"####.|#...#|#...#|####.|#.#..|#..#.|#...#",
            @"S": @".####|#....|#....|.###.|....#|....#|####.", @"T": @"#####|..#..|..#..|..#..|..#..|..#..|..#..",
            @"U": @"#...#|#...#|#...#|#...#|#...#|#...#|.###.", @"V": @"#...#|#...#|#...#|#...#|#...#|.#.#.|..#..",
            @"W": @"#...#|#...#|#...#|#.#.#|#.#.#|#.#.#|.#.#.", @"X": @"#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#",
            @"Y": @"#...#|#...#|.#.#.|..#..|..#..|..#..|..#..", @"Z": @"#####|....#|...#.|..#..|.#...|#....|#####",
            @"0": @".###.|#...#|#..##|#.#.#|##..#|#...#|.###.", @"1": @".#.|##.|.#.|.#.|.#.|.#.|###",
            @"2": @".###.|#...#|....#|...#.|..#..|.#...|#####", @"3": @"####.|....#|....#|.###.|....#|....#|####.",
            @"4": @"...#.|..##.|.#.#.|#..#.|#####|...#.|...#.", @"5": @"#####|#....|####.|....#|....#|#...#|.###.",
            @"6": @"..##.|.#...|#....|####.|#...#|#...#|.###.", @"7": @"#####|....#|...#.|..#..|.#...|.#...|.#...",
            @"8": @".###.|#...#|#...#|.###.|#...#|#...#|.###.", @"9": @".###.|#...#|#...#|.####|....#|...#.|.##..",
            @" ": @"...|...|...|...|...|...|...", @".": @".|.|.|.|.|.|#", @",": @".|.|.|.|.|#|#",
            @"!": @"#|#|#|#|#|.|#", @"?": @".###.|#...#|....#|...#.|..#..|.....|..#..", @"'": @"#|#|.|.|.|.|.",
            @"’": @"#|#|.|.|.|.|.", @"-": @"....|....|....|####|....|....|....", @":": @".|.|#|.|#|.|.",
            @"&": @".##..|#..#.|.##..|.#...|#.#.#|#..#.|.##.#", @"+": @".....|..#..|..#..|#####|..#..|..#..|.....",
            @"♥": @".##.##.|#######|#######|.#####.|..###..|...#...|.......",
        };
    });
    return glyphs;
}

static NSString *APGlyph(NSString *ch, APFont font) {
    NSDictionary *table = font == APFontLarge ? APLargeGlyphs() : APSmallGlyphs();
    return table[ch] ?: table[ch.uppercaseString];
}

int APTextHeight(APFont font) { return font == APFontLarge ? 7 : 5; }

// Rasterise one character we have no hand-drawn glyph for (any script) with
// anti-aliasing disabled, thresholded to 1-bit, at the face's pixel height.
static APCanvas *APFallbackGlyph(NSString *ch, APFont font) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%ld:%@", (long)font, ch];
    NSValue *hit = [cache objectForKey:key];
    if (hit) return hit.pointerValue;
    int height = APTextHeight(font) + 3;
    CTFontRef ctFont = CTFontCreateWithName(CFSTR("Helvetica-Bold"), height, NULL);
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:ch
        attributes:@{(__bridge NSString *)kCTFontAttributeName: (__bridge id)ctFont}];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    int w = MAX(2, (int)ceil(width)), h = height + 2;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    uint8_t *buffer = calloc((size_t)w * h, 1);
    CGContextRef ctx = CGBitmapContextCreate(buffer, w, h, 8, w, space, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextSetShouldAntialias(ctx, false);
    CGContextSetAllowsAntialiasing(ctx, false);
    CGContextSetGrayFillColor(ctx, 1, 1);
    CGContextSetTextPosition(ctx, 0, 2);
    CTLineDraw(line, ctx);
    APCanvas *glyph = APCanvasCreate(w, APTextHeight(font) + 2);
    for (int y = 0; y < glyph->h; y++) for (int x = 0; x < w; x++) {
        // Bitmap rows are bottom-up; align the glyph's baseline to our cell.
        int sy = h - 1 - (y + (h - glyph->h));
        if (sy >= 0 && sy < h && buffer[sy * w + x] > 127) APPx(glyph, x, y, 0xFFFFFF);
    }
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    free(buffer);
    CFRelease(line);
    CFRelease(ctFont);
    [cache setObject:[NSValue valueWithPointer:glyph] forKey:key]; // Lives for the process; glyphs are tiny.
    return glyph;
}

static void APEnumerateCharacters(NSString *text, void (^block)(NSString *ch)) {
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *ch, NSRange r, NSRange e, BOOL *stop) { block(ch); }];
}

int APTextWidth(NSString *text, APFont font) {
    __block int width = 0;
    __block BOOL first = YES;
    APEnumerateCharacters(text, ^(NSString *ch) {
        if (!first) width += 1;
        first = NO;
        NSString *glyph = APGlyph(ch, font);
        if (glyph) width += (int)[glyph componentsSeparatedByString:@"|"].firstObject.length;
        else width += APFallbackGlyph(ch, font)->w;
    });
    return width;
}

void APText(APCanvas *c, NSString *text, int x, int y, APFont font, uint32_t rgb) {
    __block int cursor = x;
    APEnumerateCharacters(text, ^(NSString *ch) {
        NSString *glyph = APGlyph(ch, font);
        if (glyph) {
            NSArray<NSString *> *rows = [glyph componentsSeparatedByString:@"|"];
            for (NSUInteger row = 0; row < rows.count; row++) {
                NSString *bits = rows[row];
                for (NSUInteger col = 0; col < bits.length; col++) {
                    if ([bits characterAtIndex:col] == '#') APPx(c, cursor + (int)col, y + (int)row, rgb);
                }
            }
            cursor += (int)rows.firstObject.length + 1;
        } else {
            APCanvas *fallback = APFallbackGlyph(ch, font);
            for (int gy = 0; gy < fallback->h; gy++) for (int gx = 0; gx < fallback->w; gx++) {
                if (APOpaqueAt(fallback, gx, gy)) APPx(c, cursor + gx, y + gy - 1, rgb);
            }
            cursor += fallback->w + 1;
        }
    });
}

NSArray<NSString *> *APTextWrap(NSString *text, APFont font, int maxWidth) {
    NSMutableArray *lines = [NSMutableArray array];
    NSString *line = @"";
    for (NSString *word in [text componentsSeparatedByString:@" "]) {
        if (!word.length) continue;
        NSString *candidate = line.length ? [line stringByAppendingFormat:@" %@", word] : word;
        if (line.length && APTextWidth(candidate.uppercaseString, font) > maxWidth) {
            [lines addObject:line];
            line = word;
        } else {
            line = candidate;
        }
    }
    if (line.length) [lines addObject:line];
    return lines;
}

void APTextShadow(APCanvas *c, NSString *text, int x, int y, APFont font, uint32_t rgb, uint32_t shadow) {
    APText(c, text, x, y + 1, font, shadow);
    APText(c, text, x, y, font, rgb);
}

#pragma mark - Export

APCanvas *APCanvasCreateFromCGImage(CGImageRef image, CGRect rect) {
    int w = (int)rect.size.width, h = (int)rect.size.height;
    APCanvas *c = APCanvasCreate(w, h);
    if (!image) return c;
    uint8_t *rgba = calloc((size_t)w * h * 4, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, w * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    // Position the image so `rect` (top-left origin) lands in our bitmap.
    CGFloat ih = CGImageGetHeight(image);
    CGContextDrawImage(ctx, CGRectMake(-rect.origin.x, -(ih - rect.origin.y - h), CGImageGetWidth(image), ih), image);
    for (int i = 0; i < w * h; i++) {
        uint32_t a = rgba[i * 4 + 3];
        if (!a) continue;
        uint32_t r = rgba[i * 4] * 255 / a, g = rgba[i * 4 + 1] * 255 / a, b = rgba[i * 4 + 2] * 255 / a;
        c->px[i] = (a << 24) | (MIN(r, 255u) << 16) | (MIN(g, 255u) << 8) | MIN(b, 255u);
    }
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    free(rgba);
    return c;
}

CGImageRef APCanvasCreateCGImage(const APCanvas *c) {
    size_t count = (size_t)c->w * c->h;
    uint8_t *rgba = malloc(count * 4);
    for (size_t i = 0; i < count; i++) {
        uint32_t p = c->px[i];
        uint32_t a = p >> 24;
        // Premultiply for CoreGraphics/SpriteKit.
        rgba[i * 4 + 0] = (uint8_t)((((p >> 16) & 255) * a + 127) / 255);
        rgba[i * 4 + 1] = (uint8_t)((((p >> 8) & 255) * a + 127) / 255);
        rgba[i * 4 + 2] = (uint8_t)(((p & 255) * a + 127) / 255);
        rgba[i * 4 + 3] = (uint8_t)a;
    }
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, rgba, count * 4, kCFAllocatorMalloc);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(c->w, c->h, 8, 32, c->w * 4, space,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return image;
}

@implementation APCanvasBox
+ (instancetype)boxWithCanvas:(APCanvas *)canvas {
    APCanvasBox *box = [self new];
    box->_canvas = canvas;
    return box;
}
- (void)dealloc { APCanvasFree(_canvas); }
@end
