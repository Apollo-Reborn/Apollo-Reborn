#import "ApolloPalHomeWidgetRenderer.h"
#import "ApolloPalHomeRenderer.h"
#import "ApolloPalHomeChrome.h"
#import "ApolloPixelPalCoats.h"
#import "ApolloRebornPalSprites.h"
#import "ApolloPalSpecies.h"
#import "ApolloPalHomeShelter.h"
#import <math.h>

static NSString *const kPrefix = @"PAL1:";

@implementation APPalWidget

#pragma mark - Payload

+ (NSString *)encodePal:(NSDictionary *)pal room:(NSDictionary *)room {
    NSDictionary *payload = @{@"v": @1, @"issued": @((long long)NSDate.date.timeIntervalSince1970), @"pal": pal ?: @{}, @"room": room ?: @{}};
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSData *packed = [json compressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
    if (!packed) return nil;
    return [kPrefix stringByAppendingString:[packed base64EncodedStringWithOptions:0]];
}

+ (NSDictionary *)decode:(NSString *)code {
    NSString *trimmed = [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRange marker = [trimmed rangeOfString:kPrefix options:NSCaseInsensitiveSearch];
    if (marker.location == NSNotFound) return nil;
    NSString *body = [trimmed substringFromIndex:NSMaxRange(marker)];
    // Pasted text sometimes gains spaces/newlines; base64 never has them.
    body = [[body componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    NSData *packed = [[NSData alloc] initWithBase64EncodedString:body options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!packed || packed.length > 64 * 1024) return nil;
    NSData *json = [packed decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
    if (!json || json.length > 512 * 1024) return nil;
    id payload = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![payload isKindOfClass:NSDictionary.class]) return nil;
    if (![payload[@"pal"] isKindOfClass:NSDictionary.class] || ![payload[@"room"] isKindOfClass:NSDictionary.class]) return nil;
    return payload;
}

#pragma mark - Geometry

+ (CGSize)canvasSizeForFamily:(APPalWidgetFamily)family {
    switch (family) {
        case APPalWidgetSmall: return CGSizeMake(62, 62);
        case APPalWidgetMedium: return CGSizeMake(162, 76);
        case APPalWidgetLarge: return CGSizeMake(200, 212);
        case APPalWidgetExtraLarge: return CGSizeMake(340, 160);
        case APPalWidgetExtraLargePortrait: return CGSizeMake(170, 300);
    }
    return CGSizeMake(76, 76);
}

+ (uint32_t)backgroundColorForStyle:(NSString *)style {
    APCanvas *one = APBackdropCanvas(4, 4, [APCatalog styleWithID:style]);
    uint32_t colour = APGet(one, 1, 1) & 0xFFFFFF;
    APCanvasFree(one);
    return colour;
}

#pragma mark - Pal sprite

static APCanvas *APWidgetPalFrame(NSString *species, NSString *coat, NSString *action, APSpriteSheetProvider sprites) {
    if (![species isKindOfClass:NSString.class]) return NULL;
    // Reborn species are drawn; Apollo's come from the app's sheets.
    CGImageRef sheet = APPalCreateSheet(species, [coat isKindOfClass:NSString.class] ? coat : @"original", action,
                                        ^CGImageRef(NSString *assetName) { return sprites(assetName); });
    if (!sheet) return NULL;
    APCanvas *frame = CGImageGetHeight(sheet) == 14 ? APCanvasCreateFromCGImage(sheet, CGRectMake(0, 0, 32, 14)) : NULL;
    CGImageRelease(sheet);
    return frame;
}

// The capybara's thing: a yuzu balanced on its head (see the scene).
static void APWidgetYuzu(APCanvas *canvas, NSString *species, NSString *action, int frameX, int frameY, BOOL flip) {
    CGPoint head = APRebornHeadTop(species, action);
    if (head.x < 0) return;
    int hx = flip ? 31 - (int)head.x : (int)head.x;
    int x = frameX + hx - 1 - (flip ? 1 : 0), y = frameY + (int)head.y - 5;
    APRect(canvas, x + 1, y + 1, 2, 4, 0xF2B320);
    APRect(canvas, x, y + 2, 4, 2, 0xF2B320);
    APPx(canvas, x + 1, y + 2, 0xFFE07A);
    APPx(canvas, x + 2, y + 4, 0xD08A10); APPx(canvas, x + 3, y + 3, 0xD08A10);
    APPx(canvas, x + 2, y, 0x5A9A3A); APPx(canvas, x + 3, y, 0x7AC24A);
}

static uint32_t APHash(NSString *s) {
    uint32_t h = 2166136261u;
    for (NSUInteger i = 0; i < s.length; i++) { h ^= [s characterAtIndex:i]; h *= 16777619u; }
    return h;
}

#pragma mark - Rendering

// Draws the room with the Pal in it, in shell coordinates, and reports where
// the Pal's feet are (for cropping small/medium around them).
+ (APCanvas *)roomCanvasForPayload:(NSDictionary *)payload minute:(int)minute state:(NSDictionary *)state
                            sprites:(APSpriteSheetProvider)sprites palX:(int *)outX palY:(int *)outY layout:(APRoomLayout **)outLayout
                               info:(NSMutableDictionary *)info {
    NSMutableDictionary *room = [payload[@"room"] mutableCopy];
    BOOL lightsOff = [state[@"lightsOff"] boolValue];
    if (lightsOff) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *record in room[@"items"]) {
            if (![record isKindOfClass:NSDictionary.class]) continue;
            APItemSpec *spec = [APCatalog itemWithID:record[@"item"]];
            NSMutableDictionary *copy = [record mutableCopy];
            if (spec.toggleable) copy[@"off"] = @YES;
            [items addObject:copy];
        }
        room[@"items"] = items;
    }
    APRoomLayout *layout = [APRoomLayout layoutWithRoom:room];
    [layout renderAtMinute:minute];
    APCanvasBox *snapshot = [layout snapshot];
    APCanvas *canvas = APCanvasCopy(snapshot.canvas);
    if (outLayout) *outLayout = layout;

    NSDictionary *pal = payload[@"pal"];
    NSString *species = pal[@"species"], *coat = pal[@"coat"];
    NSString *name = [pal[@"name"] isKindOfClass:NSString.class] ? pal[@"name"] : @"Your Pal";
    NSString *pose = state[@"pose"] ?: @"idle";
    int hour = (minute / 60) % 24;
    if ([pose isEqual:@"idle"] && (hour >= 22 || hour < 7)) pose = @"sleep";
    uint32_t seed = (uint32_t)[state[@"seed"] unsignedIntValue] * 2654435761u + APHash(species ?: @"");

    // What the Pal is up to this slot: a weighted pick from what the room
    // offers, tilted by personality (see APPersonality in the shelter).
    __block int feetX = APShellWidth / 2, feetY = APFloorTop + 4 * APTile;
    __block double z = 100 + (feetY - APFloorTop);
    NSString *action = @"sit", *caption = nil, *thought = nil;
    BOOL flip = (seed >> 7) & 1;
    APPlacedItem *(^firstWith)(BOOL (^)(APPlacedItem *)) = ^APPlacedItem *(BOOL (^test)(APPlacedItem *)) {
        NSMutableArray *matches = [NSMutableArray array];
        for (APPlacedItem *item in layout.items) if (test(item)) [matches addObject:item];
        return matches.count ? matches[seed % matches.count] : nil;
    };
    BOOL (^walkable)(int, int) = ^BOOL(int x, int y) { return [layout isWalkableTileX:x y:y]; };
    void (^standAt)(int, int) = ^(int x, int y) {
        feetX = APSideWall + x * APTile + 8;
        feetY = APFloorTop + y * APTile + 12;
        z = 100 + (feetY - APFloorTop);
    };
    if ([pose isEqual:@"sleep"]) {
        APPlacedItem *bed = firstWith(^BOOL(APPlacedItem *i) { return i.spec.petBed; });
        if (bed) {
            feetX = [bed shellXForLocalX:bed.spec.sleepX];
            feetY = [bed shellYForLocalY:bed.spec.sleepY];
            z = bed.z + 0.1;
        }
        action = @"sleep";
        flip = NO;
        caption = [NSString stringWithFormat:hour >= 22 || hour < 7 ? @"%@ is fast asleep" : @"%@ is having a nap", name];
    } else {
        int personality = [pal[@"personality"] intValue];
        NSMutableArray<NSString *> *choices = [NSMutableArray array];
        void (^add)(NSString *, int) = ^(NSString *what, int weight) { for (int i = 0; i < weight; i++) [choices addObject:what]; };
        add(@"wander", 3);
        add(@"fire", personality == 4 ? 6 : 2);   // Fire Gazer
        add(@"seat", personality == 2 ? 6 : 2);   // Couch Potato
        add(@"window", personality == 3 ? 6 : 2); // Window Watcher
        add(@"eat", personality == 6 ? 5 : 1);    // Snack Bandit
        if (personality == 0) add(@"bed", 3);     // Napper
        NSString *activity = [pose isEqual:@"idle"] ? choices[(seed >> 3) % choices.count] : @"wander";
        BOOL placed = NO;
        if ([activity isEqual:@"fire"]) {
            APPlacedItem *fire = firstWith(^BOOL(APPlacedItem *i) {
                if (i.spec.layer != APLayerFloor || !i.on) return NO;
                for (APAnim *anim in i.art.anims) if (anim.kind == APAnimFire) return YES;
                return NO;
            });
            int fx = fire.x + fire.spec.w / 2, fy = fire.y + fire.spec.d;
            if (fire && walkable(fx, fy)) {
                standAt(fx, fy);
                placed = YES;
                caption = [NSString stringWithFormat:@"%@ is warming up by the fire", name];
                thought = @"t.flame";
            }
        } else if ([activity isEqual:@"seat"]) {
            APPlacedItem *seat = firstWith(^BOOL(APPlacedItem *i) { return i.spec.seat; });
            if (seat) {
                feetX = [seat shellXForLocalX:seat.spec.seatX];
                feetY = [seat shellYForLocalY:seat.spec.seatY];
                z = seat.z + 0.1;
                placed = YES;
                caption = [NSString stringWithFormat:@"%@ has claimed the %@", name, seat.spec.title.lowercaseString];
                thought = @"t.heart";
            }
        } else if ([activity isEqual:@"window"]) {
            APPlacedItem *window = firstWith(^BOOL(APPlacedItem *i) {
                if (i.spec.layer != APLayerWall) return NO;
                for (APAnim *anim in i.art.anims) if (anim.kind == APAnimWindow) return YES;
                return NO;
            });
            int wx = window.x + (window.spec.w - 1) / 2, wy = walkable(wx, 0) ? 0 : 1;
            if (window && walkable(wx, wy)) {
                standAt(wx, wy);
                flip = NO;
                placed = YES;
                int weather = 3;
                for (APAnim *anim in window.art.anims) if (anim.kind == APAnimWindow) weather = anim.variant;
                BOOL day = hour >= 8 && hour < 18;
                NSString *view = weather == 0 ? @"the snow" : weather == 2 ? @"the rain" : weather == 4 ? @"the stars" : weather == 5 ? @"the fish"
                               : day ? @"the world go by" : @"the stars";
                caption = [NSString stringWithFormat:@"%@ is watching %@", name, view];
                thought = weather == 0 ? @"t.snow" : weather == 5 ? @"t.fish" : day && weather != 4 ? @"t.sun" : @"t.star";
            }
        } else if ([activity isEqual:@"eat"]) {
            APPlacedItem *bowls = firstWith(^BOOL(APPlacedItem *i) { return [i.spec.identifier isEqual:@"bowls"]; });
            if (bowls) {
                standAt(bowls.x, bowls.y);
                feetX -= 6;
                flip = NO;
                placed = YES;
                caption = [NSString stringWithFormat:@"%@ is having a snack", name];
                thought = [APSpecies speciesWithID:species].snackThought ?: @"t.fish";
            }
        } else if ([activity isEqual:@"bed"]) {
            APPlacedItem *bed = firstWith(^BOOL(APPlacedItem *i) { return i.spec.petBed; });
            if (bed) {
                feetX = [bed shellXForLocalX:bed.spec.sleepX];
                feetY = [bed shellYForLocalY:bed.spec.sleepY];
                z = bed.z + 0.1;
                action = @"sleep";
                flip = NO;
                placed = YES;
                caption = [NSString stringWithFormat:@"%@ is having a little nap", name];
            }
        }
        if (!placed) {
            // A walkable tile picked by the seed, preferring spots with nothing
            // tall standing in front.
            NSMutableArray *tiles = [NSMutableArray array];
            for (int y = 1; y < APRows; y++) for (int x = 0; x < APCols; x++) {
                if (walkable(x, y) && (y == APRows - 1 || walkable(x, y + 1))) [tiles addObject:@[@(x), @(y)]];
            }
            if (!tiles.count) for (int y = 1; y < APRows; y++) for (int x = 0; x < APCols; x++) if (walkable(x, y)) [tiles addObject:@[@(x), @(y)]];
            if (tiles.count) {
                NSArray *tile = tiles[seed % tiles.count];
                standAt([tile[0] intValue], [tile[1] intValue]);
            }
            caption = [NSString stringWithFormat:@"%@ is pottering about", name];
            thought = (seed >> 11) % 3 == 0 ? @"t.yarn" : nil;
        }
        if ([pose isEqual:@"pet"]) {
            caption = [species isEqual:@"capybara"] ? [NSString stringWithFormat:@"A yuzu! %@ is unbothered", name]
                                                    : [NSString stringWithFormat:@"%@ loves that!", name];
            thought = nil;
        }
        if ([pose isEqual:@"play"]) { caption = [NSString stringWithFormat:@"%@ is chasing the yarn!", name]; thought = nil; action = @"run"; }
    }

    APCanvas *frame = species ? APWidgetPalFrame(species, coat, action, sprites) : NULL;
    if (!frame && species && ![action isEqual:@"sit"]) frame = APWidgetPalFrame(species, coat, @"sit", sprites);
    if (frame) {
        // Lit like everything else in the room.
        float r, g, b;
        [layout lightAtX:feetX y:feetY - 6 r:&r g:&g b:&b];
        for (int i = 0; i < frame->w * frame->h; i++) {
            uint32_t p = frame->px[i];
            if (p >> 24) frame->px[i] = (p & 0xFF000000u) | APMultiply(p, fminf(1, r), fminf(1, g), fminf(1, b));
        }
        APDraw(canvas, frame, feetX - 16, feetY - 14, flip);
        APCanvasFree(frame);
        if ([pose isEqual:@"pet"] && [species isEqual:@"capybara"]) APWidgetYuzu(canvas, species, action, feetX - 16, feetY - 14, flip);
        // Redraw items in front of the Pal over it, so depth stays right.
        for (APPlacedItem *item in layout.items) {
            if (item.spec.layer != APLayerFloor || item.z <= z || item.spec.walkable) continue;
            APDraw(canvas, item.lit.canvas, item.px, item.py, NO);
            APDraw(canvas, item.glowing.canvas, item.px, item.py, NO);
            APDraw(canvas, item.litFront.canvas, item.px, item.py, NO);
        }
        if ([pose isEqual:@"pet"]) {
            for (int i = 0; i < 3; i++) {
                APCanvas *heart = APIconCanvas(@"smallheart");
                APDraw(canvas, heart, feetX - 9 + i * 6, feetY - 22 - (i % 2) * 3, NO);
                APCanvasFree(heart);
            }
        } else if ([pose isEqual:@"play"]) {
            // The yarn, just out of reach.
            int bx = feetX + (flip ? -18 : 14), by = feetY - 5;
            APCircle(canvas, bx, by, 2, 0xE88AA8);
            APPx(canvas, bx - 1, by - 1, 0xF8C8D8); APPx(canvas, bx + 1, by + 1, 0xC86A88);
            APLine(canvas, bx + (flip ? 2 : -2), by + 1, bx + (flip ? 8 : -8), by + 2, 0xE88AA8);
        } else if ([action isEqual:@"sleep"]) {
            APCanvas *zz = APIconCanvas(@"z");
            APDraw(canvas, zz, feetX + 4, feetY - 20, NO);
            APDraw(canvas, zz, feetX + 9, feetY - 26, NO);
            APCanvasFree(zz);
        }
    }
    if (info) {
        if (caption) info[@"caption"] = caption;
        if (thought) info[@"thought"] = thought;
    }
    *outX = feetX;
    *outY = feetY;
    return canvas;
}

// A little thought bubble above the Pal (large sizes).
static void APThoughtBubble(APCanvas *c, NSString *iconName, int feetX, int feetY) {
    APCanvas *icon = APIconCanvas(iconName);
    int w = MAX(icon->w + 6, 11), h = MAX(icon->h + 5, 9);
    int x = feetX + 2, y = feetY - 14 - h - 6;
    APCanvas *bubble = APCanvasCreate(w, h + 4);
    APRoundRect(bubble, 0, 0, w, h, 0xFAF6EE);
    APOutlineInside(bubble, 0x3A2A22);
    APPx(bubble, 3, h, 0xFAF6EE); APPx(bubble, 2, h + 1, 0x3A2A22); APPx(bubble, 4, h, 0x3A2A22); APPx(bubble, 3, h + 1, 0x3A2A22);
    APPx(bubble, 1, h + 3, 0x3A2A22);
    APDraw(bubble, icon, (w - icon->w) / 2, (h - icon->h) / 2, NO);
    APDraw(c, bubble, x, MAX(0, y), NO);
    APCanvasFree(icon);
    APCanvasFree(bubble);
}

static void APBlitCrop(APCanvas *dst, APCanvas *src, int sx, int sy, int w, int h, int dx, int dy) {
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        uint32_t p = APGet(src, sx + x, sy + y);
        if (p >> 24) APPx(dst, dx + x, dy + y, p);
    }
}

// A name plaque strip: "MANGO ♥♥♥♡♡♡".
static void APNameStrip(APCanvas *c, APChromeTheme t, NSString *name, double hearts, int x, int y, int w) {
    APCanvas *strip = APChromePanel(t, w, 11);
    NSString *text = name.uppercaseString;
    int heartsW = hearts >= 0 ? 6 * 6 - 1 : 0;
    int maxText = w - 8 - (heartsW ? heartsW + 4 : 0);
    while (text.length > 1 && APTextWidth(text, APFontSmall) > maxText) text = [text substringToIndex:text.length - 1];
    APTextShadow(strip, text, 4, 3, APFontSmall, t.text, t.shadow);
    if (heartsW) for (int i = 0; i < 6; i++) {
        APChromeHeart(strip, w - 4 - heartsW + i * 6, 3, hearts >= i + 1 ? 1 : hearts >= i + 0.5 ? 0.5f : 0, APShade(t.panel.d, 0.8f), 0);
    }
    APDraw(c, strip, x, y, NO);
    APCanvasFree(strip);
}

// The Pal card panel used by the extra-large sizes.
static void APPalCard(APCanvas *c, APChromeTheme t, NSDictionary *pal, int x, int y, int w, int h, APSpriteSheetProvider sprites) {
    APCanvas *panel = APChromePanel(t, w, h);
    APDraw(c, panel, x, y, NO);
    APCanvasFree(panel);
    NSString *name = [pal[@"name"] description].uppercaseString ?: @"";
    int cy = y + 6;
    APTextShadow(c, name, x + (w - APTextWidth(name, APFontLarge)) / 2, cy, APFontLarge, t.text, t.shadow);
    cy += 10;
    NSString *summary = [pal[@"summary"] description].uppercaseString ?: @"";
    if (summary.length) { APText(c, summary, x + (w - APTextWidth(summary, APFontSmall)) / 2, cy, APFontSmall, t.subtext); cy += 8; }
    APCanvas *frame = APWidgetPalFrame(pal[@"species"], pal[@"coat"], @"sit", sprites);
    if (frame) {
        APCanvas *big = APCanvasCreate(64, 28);
        for (int yy = 0; yy < 28; yy++) for (int xx = 0; xx < 64; xx++) big->px[yy * 64 + xx] = frame->px[(yy / 2) * 32 + xx / 2];
        APDraw(c, big, x + (w - 64) / 2, cy, NO);
        APCanvasFree(big);
        APCanvasFree(frame);
    }
    cy += 31;
    double hearts = [pal[@"hearts"] isKindOfClass:NSNumber.class] ? [pal[@"hearts"] doubleValue] : -1;
    if (hearts >= 0) {
        for (int i = 0; i < 6; i++) APText(c, @"♥", x + (w - 35) / 2 + i * 6, cy, APFontSmall, i < hearts ? 0xF06A7A : APShade(t.panel.d, 0.8f));
        cy += 9;
    }
    for (NSString *key in @[@"personalityTitle", @"personalityBlurb", @"quirk"]) {
        NSString *value = [pal[key] isKindOfClass:NSString.class] ? pal[key] : nil;
        if (!value.length) continue;
        uint32_t colour = [key isEqual:@"personalityTitle"] ? t.accent : [key isEqual:@"quirk"] ? t.subtext : t.text;
        for (NSString *line in APTextWrap(value, APFontSmall, w - 10)) {
            if (cy > y + h - 8) break;
            APText(c, line.uppercaseString, x + (w - APTextWidth(line.uppercaseString, APFontSmall)) / 2, cy, APFontSmall, colour);
            cy += 7;
        }
        cy += 2;
    }
}

+ (CGImageRef)renderPayload:(NSDictionary *)payload family:(APPalWidgetFamily)family minute:(int)minute
                       state:(NSDictionary *)state sprites:(APSpriteSheetProvider)sprites {
    CGSize size = [self canvasSizeForFamily:family];
    int W = (int)size.width, H = (int)size.height;
    NSDictionary *room = payload[@"room"], *pal = payload[@"pal"];
    APStyleSpec *style = [APCatalog styleWithID:room[@"style"]];
    APChromeTheme t = APChromeThemeForStyle(style.identifier);
    APCanvas *out = APBackdropCanvas(W, H, style);
    int feetX, feetY;
    APRoomLayout *layout = nil;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    APCanvas *roomCanvas = [self roomCanvasForPayload:payload minute:minute state:state sprites:sprites palX:&feetX palY:&feetY
                                               layout:&layout info:info];
    NSString *caption = info[@"caption"];
    // Thought bubbles on the roomier sizes.
    if (info[@"thought"] && family != APPalWidgetSmall && family != APPalWidgetMedium) APThoughtBubble(roomCanvas, info[@"thought"], feetX, feetY);
    NSString *name = [pal[@"name"] isKindOfClass:NSString.class] ? pal[@"name"] : @"";
    double hearts = [pal[@"hearts"] isKindOfClass:NSNumber.class] ? [pal[@"hearts"] doubleValue] : -1;
    switch (family) {
        case APPalWidgetSmall: {
            // A close-up around the Pal.
            int cw = W, ch = H - 11;
            int sx = MAX(0, MIN(feetX - cw / 2, APShellWidth - cw)), sy = MAX(0, MIN(feetY - ch * 2 / 3, APShellHeight - ch));
            APBlitCrop(out, roomCanvas, sx, sy, cw, ch, 0, 0);
            APNameStrip(out, t, name, -1, 0, H - 11, W);
            break;
        }
        case APPalWidgetMedium: {
            int ch = H - 11, sx = 0, dx = (W - APShellWidth) / 2;
            int sy = MAX(0, MIN(feetY - ch * 2 / 3, APShellHeight - ch));
            APBlitCrop(out, roomCanvas, sx, sy, APShellWidth, ch, dx, 0);
            APNameStrip(out, t, caption ?: name, caption ? -1 : hearts, 0, H - 11, W);
            break;
        }
        case APPalWidgetLarge: {
            // The whole room under its name sign.
            int rx = (W - APShellWidth) / 2, ry = H - APShellHeight + 4;
            APBlitCrop(out, roomCanvas, 0, 0, APShellWidth, APShellHeight - 4, rx, ry);
            NSString *title = [NSString stringWithFormat:@"%@’s Home", name];
            if (APTextWidth(title.uppercaseString, APFontLarge) > W - 24) title = name;
            APCanvas *sign = APChromeSign(t, title, hearts, 6);
            APDraw(out, sign, (W - sign->w) / 2, ry - sign->h + 4, NO);
            APCanvasFree(sign);
            if (caption) APNameStrip(out, t, caption, -1, 0, H - 11, W);
            break;
        }
        case APPalWidgetExtraLarge: {
            int rx = 6, ry = (H - APShellHeight) / 2;
            APBlitCrop(out, roomCanvas, 0, 0, APShellWidth, APShellHeight, rx, MAX(0, ry));
            NSMutableDictionary *card = [pal mutableCopy];
            if (caption) card[@"personalityBlurb"] = caption;
            APPalCard(out, t, card, rx + APShellWidth + 8, 8, W - APShellWidth - 20, H - 16, sprites);
            break;
        }
        case APPalWidgetExtraLargePortrait: {
            NSString *title = [NSString stringWithFormat:@"%@’s Home", name];
            if (APTextWidth(title.uppercaseString, APFontLarge) > W - 24) title = name;
            APCanvas *sign = APChromeSign(t, title, hearts, 6);
            int rx = (W - APShellWidth) / 2, ry = sign->h;
            APBlitCrop(out, roomCanvas, 0, 0, APShellWidth, APShellHeight, rx, ry);
            APDraw(out, sign, (W - sign->w) / 2, 2, NO);
            APCanvasFree(sign);
            int cardY = ry + APShellHeight + 4;
            NSMutableDictionary *card = [pal mutableCopy];
            card[@"name"] = @"";
            [card removeObjectForKey:@"summary"];
            if (H - cardY > 30) {
                // Personality and quirk under the room (the sign has the name).
                APChromeTheme cardTheme = t;
                APCanvas *panel = APChromePanel(cardTheme, W - 12, H - cardY - 4);
                APDraw(out, panel, 6, cardY, NO);
                APCanvasFree(panel);
                int cy = cardY + 6;
                NSMutableDictionary *lines = [pal mutableCopy];
                if (caption) lines[@"caption"] = caption;
                for (NSString *key in @[@"caption", @"summary", @"personalityTitle", @"personalityBlurb", @"quirk"]) {
                    NSString *value = [lines[key] isKindOfClass:NSString.class] ? lines[key] : nil;
                    if (!value.length) continue;
                    uint32_t colour = [key isEqual:@"caption"] || [key isEqual:@"personalityTitle"] ? t.accent
                                    : [key isEqual:@"quirk"] || [key isEqual:@"summary"] ? t.subtext : t.text;
                    for (NSString *line in APTextWrap(value, APFontSmall, W - 24)) {
                        if (cy > H - 12) break;
                        APText(out, line.uppercaseString, (W - APTextWidth(line.uppercaseString, APFontSmall)) / 2, cy, APFontSmall, colour);
                        cy += 7;
                    }
                    cy += 2;
                }
            }
            break;
        }
    }
    APCanvasFree(roomCanvas);
    CGImageRef image = APCanvasCreateCGImage(out);
    APCanvasFree(out);
    return image;
}

+ (CGImageRef)setupImageForFamily:(APPalWidgetFamily)family {
    CGSize size = [self canvasSizeForFamily:family];
    int W = (int)size.width, H = (int)size.height;
    APChromeTheme t = APChromeThemeForStyle(nil);
    APCanvas *out = APBackdropCanvas(W, H, nil);
    int pw = W - 8, ph = MIN(H - 8, family == APPalWidgetSmall ? H - 8 : 56);
    APCanvas *panel = APChromePanel(t, pw, ph);
    APDraw(out, panel, 4, (H - ph) / 2, NO);
    APCanvasFree(panel);
    NSArray *lines = family == APPalWidgetSmall ? @[@"Pal Home", @"Paste your", @"Pal code:", @"edit widget"]
        : @[@"Pal Home", @"In Apollo: Pal Home, your Pal,", @"Widget. Then edit this widget", @"and paste the Pal code."];
    int y = (H - ph) / 2 + 6;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = [lines[i] uppercaseString];
        APFont font = i == 0 ? APFontLarge : APFontSmall;
        APTextShadow(out, line, (W - APTextWidth(line, font)) / 2, y, font, i == 0 ? t.accent : t.text, t.shadow);
        y += i == 0 ? 11 : 8;
    }
    APCanvas *paw = APIconCanvas(@"paw");
    if (y + paw->h < (H + ph) / 2 - 2) APDraw(out, paw, (W - paw->w) / 2, y + 1, NO);
    APCanvasFree(paw);
    CGImageRef image = APCanvasCreateCGImage(out);
    APCanvasFree(out);
    return image;
}

+ (NSDictionary *)samplePayload {
    return @{@"pal": @{@"species": @"cat", @"coat": @"original", @"name": @"Biscuit", @"hearts": @4,
                       @"summary": @"Girl \u00B7 2 yrs \u00B7 Cat", @"personalityTitle": @"Fire Gazer",
                       @"personalityBlurb": @"Happiest by a crackling fire.", @"quirk": @"Knocks things off tables. On purpose."},
             @"room": [APCatalog styleWithID:@"cottage"].room(), @"issued": @0};
}

+ (CGImageRef)buttonImageForIcon:(NSString *)icon style:(NSString *)style toggled:(BOOL)toggled {
    APChromeTheme t = APChromeThemeForStyle(style);
    APCanvas *tile = APChromeTile(t, 18, 16, NO, toggled);
    APCanvas *glyph = APIconCanvas(icon);
    APDraw(tile, glyph, (18 - glyph->w) / 2, (14 - glyph->h) / 2, NO);
    APCanvasFree(glyph);
    CGImageRef image = APCanvasCreateCGImage(tile);
    APCanvasFree(tile);
    return image;
}

@end

@implementation ApolloPalHomeStore (PalHomeWidget)

- (NSString *)widgetCodeWithRoom:(NSDictionary *)room {
    [self refresh];
    ApolloPalHomeResident *pal = self.residents.firstObject;
    if (!pal) return nil;
    NSMutableDictionary *info = [@{@"species": pal.species, @"coat": pal.coat ?: @"original", @"name": pal.name,
                                   @"gender": pal.gender ?: @"", @"ageMonths": @(pal.ageMonths), @"personality": @(pal.personality),
                                   @"quirk": pal.quirk ?: @"",
                                   @"summary": [APShelter summaryForSpecies:pal.species gender:pal.gender ageMonths:pal.ageMonths],
                                   @"personalityTitle": [APShelter titleForPersonality:pal.personality],
                                   @"personalityBlurb": [APShelter blurbForPersonality:pal.personality]} mutableCopy];
    if (pal.hearts) info[@"hearts"] = pal.hearts;
    return [APPalWidget encodePal:info room:room ?: self.room ?: [APCatalog starterRoom]];
}

@end
