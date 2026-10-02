// Host-side renderer for Pal Home art: writes lit room snapshots and a
// catalogue contact sheet as PNGs, so the pixel art can be reviewed (and
// regressions spotted) without building the tweak. Usage:
//   sh tests/run_pal_home_render.sh [output-dir]
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import "palhome/ApolloPalHomeRenderer.h"
#import "palhome/ApolloPalHomeChrome.h"
#import "palhome/ApolloPalHomeWidgetRenderer.h"

static void WritePNG(APCanvas *c, int scale, NSString *path) {
    APCanvas *big = APCanvasCreate(c->w * scale, c->h * scale);
    for (int y = 0; y < big->h; y++) for (int x = 0; x < big->w; x++) big->px[y * big->w + x] = c->px[(y / scale) * c->w + x / scale];
    CGImageRef image = APCanvasCreateCGImage(big);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dest, image, NULL);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(image);
    APCanvasFree(big);
}

static APCanvas *Framed(APRoomLayout *layout, NSString *sign) {
    APStyleSpec *style = layout.style;
    // Mimic the phone composition: backdrop, sign, room.
    int W = APShellWidth + 12, H = APShellHeight + 44;
    APCanvas *c = APBackdropCanvas(W, H, style);
    APCanvasBox *snap = [layout snapshot];
    APDraw(c, snap.canvas, 6, 36, NO);
    APCanvas *plaque = APChromeSign(APChromeThemeForStyle(style.identifier), sign, 4, 6);
    APDraw(c, plaque, (W - plaque->w) / 2, 4, NO);
    APCanvasFree(plaque);
    return c;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *out = argc > 1 ? @(argv[1]) : NSTemporaryDirectory();
        [[NSFileManager defaultManager] createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *starter = [APCatalog starterRoom];
        struct { const char *name; int minute; const char *lighting; } shots[] = {
            {"room-night", 22 * 60, "auto"}, {"room-evening", 18 * 60, "auto"}, {"room-day", 12 * 60, "auto"},
        };
        for (int i = 0; i < 3; i++) {
            NSMutableDictionary *room = [starter mutableCopy];
            room[@"lighting"] = @(shots[i].lighting);
            APRoomLayout *layout = [APRoomLayout layoutWithRoom:room];
            [layout renderAtMinute:shots[i].minute];
            APCanvas *c = Framed(layout, @"Rupert's Home");
            WritePNG(c, 4, [out stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.png", shots[i].name]]);
            APCanvasFree(c);
        }
        // Every home style's template, at evening light, side by side.
        NSArray<APStyleSpec *> *styles = [APCatalog styles];
        int fw = APShellWidth + 12, fh = APShellHeight + 44;
        APCanvas *gallery = APCanvasCreate(fw * 4, fh * 2);
        for (NSUInteger i = 0; i < styles.count; i++) {
            NSDictionary *room = styles[i].room();
            APRoomLayout *layout = [APRoomLayout layoutWithRoom:room];
            [layout renderAtMinute:21 * 60];
            printf("%s: %lu of %lu placed\n", styles[i].identifier.UTF8String, (unsigned long)layout.items.count, (unsigned long)[room[@"items"] count]);
            APCanvas *c = Framed(layout, styles[i].title);
            APDraw(gallery, c, (int)(i % 4) * fw, (int)(i / 4) * fh, NO);
            APCanvasFree(c);
            APCanvas *thumb = APStyleThumbnail(styles[i]);
            APDraw(gallery, thumb, 3 * fw + (int)(i % 3) * 40 + 4, fh + 10 + (int)(i / 3) * 52, NO);
            APCanvasFree(thumb);
        }
        WritePNG(gallery, 3, [out stringByAppendingPathComponent:@"styles.png"]);
        // Chrome per style: a panel with tiles (one toggled), slots and the sign.
        APCanvas *chrome = APCanvasCreate(150, (int)styles.count * 62 + 4);
        APRect(chrome, 0, 0, chrome->w, chrome->h, 0x202020);
        for (NSUInteger i = 0; i < styles.count; i++) {
            APChromeTheme t = APChromeThemeForStyle(styles[i].identifier);
            int y0 = (int)i * 62 + 4;
            APCanvas *panel = APChromePanel(t, 96, 56); APDraw(chrome, panel, 2, y0, NO); APCanvasFree(panel);
            NSArray *icons = @[@"heart", @"ball", @"moon", @"brush"];
            for (int k = 0; k < 4; k++) {
                APCanvas *tile = APChromeTile(t, 20, 18, NO, k == 3);
                APCanvas *icon = APIconCanvas(icons[k]);
                APDraw(tile, icon, (20 - icon->w) / 2, (16 - icon->h) / 2, NO);
                APDraw(chrome, tile, 6 + k * 22, y0 + 6, NO);
                APCanvasFree(tile); APCanvasFree(icon);
            }
            for (int k = 0; k < 3; k++) { APCanvas *slot = APChromeSlot(t, 26, 24, NO, k == 1); APDraw(chrome, slot, 6 + k * 29, y0 + 28, NO); APCanvasFree(slot); }
            APText(chrome, @"FURNITURE", 6, y0 + 3 + 50, APFontSmall, t.text);
            APCanvas *sign = APChromeSign(t, @"Rupert", 3, 6); APDraw(chrome, sign, 100, y0 + 10, NO); APCanvasFree(sign);
        }
        WritePNG(chrome, 4, [out stringByAppendingPathComponent:@"chrome.png"]);
        APCanvasFree(chrome);
        APCanvasFree(gallery);
        printf("room items placed: %lu of %lu\n", (unsigned long)[APRoomLayout layoutWithRoom:starter].items.count,
               (unsigned long)[starter[@"items"] count]);

        // Contact sheet: every item's every variant, then surfaces and icons.
        NSArray<APItemSpec *> *items = [APCatalog items];
        int sheetW = 420, x = 4, y = 4, rowH = 0;
        NSMutableArray *placements = [NSMutableArray array];
        for (APItemSpec *spec in items) for (int v = 0; v < (int)spec.variants.count; v++) {
            int w = spec.pixelWidth, h = spec.pixelHeight;
            if (x + w + 4 > sheetW) { x = 4; y += rowH + 6; rowH = 0; }
            [placements addObject:@[spec, @(v), @(x), @(y)]];
            x += w + 4;
            rowH = MAX(rowH, h);
        }
        y += rowH + 8; x = 4; rowH = 0;
        int surfacesY = y;
        y += 30 * 2 + 12;
        int iconsY = y;
        APCanvas *sheet = APCanvasCreate(sheetW, iconsY + 20);
        APRect(sheet, 0, 0, sheetW, sheet->h, 0x3A2E28);
        for (NSArray *p in placements) {
            APCanvas *thumb = APItemThumbnail(p[0], [p[1] intValue]);
            APDraw(sheet, thumb, [p[2] intValue], [p[3] intValue], NO);
            APCanvasFree(thumb);
        }
        x = 4;
        for (APSurfaceSpec *s in [APCatalog wallpapers]) {
            APCanvas *t = APSurfaceThumbnail(s, NO, 28); APDraw(sheet, t, x, surfacesY, NO); APCanvasFree(t); x += 32;
        }
        x = 4;
        for (APSurfaceSpec *s in [APCatalog floors]) {
            APCanvas *t = APSurfaceThumbnail(s, YES, 28); APDraw(sheet, t, x, surfacesY + 32, NO); APCanvasFree(t); x += 32;
        }
        x = 4;
        for (NSString *name in @[@"heart", @"ball", @"moon", @"brush", @"paw", @"back", @"check", @"flip", @"palette", @"box", @"sun", @"bulb",
                                 @"sofa", @"candle", @"rug", @"window", @"art", @"wallpaper", @"floor", @"note", @"z", @"smallheart"]) {
            APCanvas *t = APIconCanvas(name); APDraw(sheet, t, x, iconsY, NO); x += t->w + 4; APCanvasFree(t);
        }
        WritePNG(sheet, 3, [out stringByAppendingPathComponent:@"catalogue.png"]);
        APCanvasFree(sheet);

        // Fire frames strip.
        NSArray *frames = APFireFrames(18, 20, 8, 1, 7);
        APCanvas *strip = APCanvasCreate(8 * 20, 22);
        APRect(strip, 0, 0, strip->w, strip->h, 0x1E120E);
        for (int i = 0; i < 8; i++) APDraw(strip, [frames[i] canvas], i * 20 + 1, 1, NO);
        WritePNG(strip, 6, [out stringByAppendingPathComponent:@"fire.png"]);
        APCanvasFree(strip);
        // Widget previews (needs extracted Pal sprites: env PAL_SPRITES=dir).
        NSString *spriteDir = NSProcessInfo.processInfo.environment[@"PAL_SPRITES"];
        if (spriteDir.length) {
            APSpriteSheetProvider sprites = ^CGImageRef(NSString *name) {
                NSURL *url = [NSURL fileURLWithPath:[spriteDir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]]];
                CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
                if (!source) return NULL;
                CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
                CFRelease(source);
                return (CGImageRef)CFAutorelease(image);
            };
            NSDictionary *pal = @{@"species": @"dog", @"coat": @"corgi", @"name": @"Rupert", @"hearts": @3,
                                  @"summary": @"Boy \u00B7 2 yrs \u00B7 Dog", @"personalityTitle": @"Couch Potato",
                                  @"personalityBlurb": @"Believes furniture is for sitting on. Specifically by them.", @"quirk": @"Only reads the comments."};
            NSArray *families = @[@(APPalWidgetSmall), @(APPalWidgetMedium), @(APPalWidgetLarge), @(APPalWidgetExtraLargePortrait), @(APPalWidgetExtraLarge)];
            int gx = 0;
            APCanvas *wall = APCanvasCreate(1100, 330 * 2);
            APRect(wall, 0, 0, wall->w, wall->h, 0x606060);
            NSArray *styleIDs = @[@"cottage", @"space"];
            for (NSUInteger si = 0; si < styleIDs.count; si++) {
                // Second row: a Reborn species (drawn, not from the sprite dir), petted = yuzu.
                NSMutableDictionary *who = [pal mutableCopy];
                if (si == 1) { who[@"species"] = @"capybara"; who[@"coat"] = @"original"; who[@"name"] = @"Yuzu"; }
                NSString *code = [APPalWidget encodePal:who room:[APCatalog styleWithID:styleIDs[si]].room()];
                NSDictionary *payload = [APPalWidget decode:code];
                if (si == 0) printf("pal code length: %lu\n", (unsigned long)code.length);
                gx = 4;
                for (NSNumber *family in families) {
                    NSDictionary *state = @{@"pose": family.intValue == APPalWidgetMedium ? @"pet" : @"idle", @"seed": @(family.intValue * 3 + 1)};
                    CGImageRef image = [APPalWidget renderPayload:payload family:family.integerValue minute:20 * 60 state:state sprites:sprites];
                    APCanvas *c = APCanvasCreateFromCGImage(image, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)));
                    APDraw(wall, c, gx, 4 + (int)si * 330, NO);
                    gx += c->w + 6;
                    APCanvasFree(c);
                    CGImageRelease(image);
                }
            }
            // Setup cards and the gallery sample.
            gx = 4;
            for (NSNumber *family in @[@(APPalWidgetSmall), @(APPalWidgetMedium)]) {
                CGImageRef image = [APPalWidget setupImageForFamily:family.integerValue];
                APCanvas *c = APCanvasCreateFromCGImage(image, CGRectMake(0, 0, CGImageGetWidth(image), CGImageGetHeight(image)));
                APDraw(wall, c, gx, 240, NO);
                gx += c->w + 6;
                APCanvasFree(c);
                CGImageRelease(image);
            }
            CGImageRef sample = [APPalWidget renderPayload:[APPalWidget samplePayload] family:APPalWidgetMedium minute:12 * 60 state:@{@"seed": @2} sprites:sprites];
            APCanvas *sc = APCanvasCreateFromCGImage(sample, CGRectMake(0, 0, CGImageGetWidth(sample), CGImageGetHeight(sample)));
            APDraw(wall, sc, gx, 240, NO);
            APCanvasFree(sc);
            CGImageRelease(sample);
            WritePNG(wall, 2, [out stringByAppendingPathComponent:@"widgets.png"]);
            APCanvasFree(wall);
        }
        printf("wrote to %s\n", out.UTF8String);
    }
    return 0;
}
