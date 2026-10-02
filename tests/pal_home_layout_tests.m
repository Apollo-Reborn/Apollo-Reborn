// Pal Home layout/renderer robustness: placement rules, hostile room documents,
// every catalogue item in every variant, every style template, and Pal codes.
#import <Foundation/Foundation.h>
#import "palhome/ApolloPalHomeRenderer.h"
#import "palhome/ApolloPalHomeWidgetRenderer.h"

static int failures = 0;
static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); failures++; }
}

static NSDictionary *Item(NSString *uid, NSString *item, id x, id y) {
    return @{@"uid": uid, @"item": item, @"x": x, @"y": y};
}

int main(void) {
    @autoreleasepool {
        // Placement rules.
        APRoomLayout *layout = [APRoomLayout layoutWithRoom:@{@"items": @[
            Item(@"a", @"sofa", @1, @2), Item(@"b", @"armchair", @2, @2),       // overlaps a → dropped
            Item(@"c", @"rug.round", @0, @1),                                   // rugs may sit under furniture
            Item(@"d", @"fireplace", @3, @2),                                   // back-wall piece off the wall → dropped
            Item(@"e", @"lamp.floor", @7, @6), Item(@"f", @"lamp.floor", @8, @6), // out of bounds → dropped
            Item(@"g", @"window", @0, @0), Item(@"h", @"clock", @1, @1),        // h overlaps the window
            Item(@"i", @"fairylights", @4, @0), Item(@"j", @"bunting", @2, @0), // trim overlap
            Item(@"k", @"future.gadget", @4, @4),                               // unknown → kept, not shown
            Item(@"a", @"plant.cactus", @0, @6),                                // duplicate uid → renamed
        ]}];
        NSArray *uids = [layout.items valueForKey:@"uid"];
        Check([uids containsObject:@"a"] && ![uids containsObject:@"b"], @"floor overlap dropped");
        Check([uids containsObject:@"c"], @"rug under furniture allowed");
        Check(![uids containsObject:@"d"], @"back-wall rule enforced");
        Check([uids containsObject:@"e"] && ![uids containsObject:@"f"], @"bounds enforced");
        Check([uids containsObject:@"g"] && ![uids containsObject:@"h"], @"wall overlap dropped");
        Check([uids containsObject:@"i"] && ![uids containsObject:@"j"], @"trim overlap dropped");
        Check(layout.items.count == 6, [NSString stringWithFormat:@"6 shown items, got %lu", (unsigned long)layout.items.count]);
        Check([[layout.itemRecords valueForKey:@"item"] containsObject:@"future.gadget"], @"unknown item preserved on save");
        NSArray *cactus = [layout.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"spec.identifier == 'plant.cactus'"]];
        Check(cactus.count == 1 && ![[cactus.firstObject uid] isEqual:@"a"], @"duplicate uid renamed");
        int x = -1, y = -1;
        Check([layout findSpotForSpec:[APCatalog itemWithID:@"sofa"] x:&x y:&y] &&
              [layout canPlace:[APCatalog itemWithID:@"sofa"] x:x y:y ignoringUID:nil], @"found spot is placeable");
        Check(![layout isWalkableTileX:1 y:2] && [layout isWalkableTileX:0 y:2] && ![layout isWalkableTileX:-1 y:0], @"walkability");

        // Hostile documents never crash and fall back sensibly.
        NSArray *hostile = @[@{}, @{@"items": @"nope"}, @{@"items": @[NSNull.null, @1, @"x", @{}]},
                             @{@"items": @[@{@"uid": @5, @"item": @"sofa", @"x": @"1", @"y": @[@2]}]},
                             @{@"items": @[@{@"uid": @"n", @"item": @"sofa", @"x": @(NAN), @"y": @(INFINITY)}]},
                             @{@"items": @[@{@"uid": @"v", @"item": @"sofa", @"x": @0, @"y": @0, @"variant": @99999, @"flip": @"yes"}]},
                             @{@"style": @"no-such-style", @"wallpaper": @42, @"floor": NSNull.null, @"lighting": @"disco", @"items": @[]}];
        for (NSDictionary *room in hostile) {
            APRoomLayout *l = [APRoomLayout layoutWithRoom:room];
            [l renderAtMinute:12 * 60];
            Check(l.litShell != nil && l.style != nil && l.wallpaper != nil && l.floor != nil, @"hostile room renders");
        }
        APRoomLayout *clamped = [APRoomLayout layoutWithRoom:hostile[5]];
        Check(clamped.items.count == 1 && [clamped.items.firstObject variant] == (int)[clamped.items.firstObject spec].variants.count - 1, @"variant clamped");

        // Every catalogue item, every variant, on and off, at day and night.
        int rendered = 0;
        for (APItemSpec *spec in [APCatalog items]) {
            Check(spec.variants.count > 0 && spec.title.length > 0 && spec.pixelWidth > 0 && spec.pixelHeight > 0, spec.identifier);
            for (int v = 0; v < (int)spec.variants.count; v++) for (int on = 0; on < 2; on++) for (int minute = 0; minute < 1440; minute += 720) {
                APDrawContext *art = APRenderItem(spec, v, on, minute);
                Check(art.base->w == spec.pixelWidth && art.base->h == spec.pixelHeight, [NSString stringWithFormat:@"%@ size", spec.identifier]);
                Check(!APCanvasIsEmpty(art.base) || !APCanvasIsEmpty(art.emissive), [NSString stringWithFormat:@"%@ draws something", spec.identifier]);
                if (spec.petBed) Check(spec.sleepX >= 0 && spec.sleepX < spec.pixelWidth && spec.sleepY > 0 && spec.sleepY <= spec.pixelHeight, spec.identifier);
                if (spec.seat) Check(spec.seatX >= 0 && spec.seatX < spec.pixelWidth && spec.seatY > 0 && spec.seatY <= spec.pixelHeight, spec.identifier);
                rendered++;
            }
        }
        NSMutableSet *ids = [NSMutableSet set];
        for (APItemSpec *spec in [APCatalog items]) { Check(![ids containsObject:spec.identifier], [@"unique id " stringByAppendingString:spec.identifier]); [ids addObject:spec.identifier]; }

        // Every style's template places every item (a dropped item is a template bug).
        for (APStyleSpec *style in [APCatalog styles]) {
            NSDictionary *room = style.room();
            APRoomLayout *l = [APRoomLayout layoutWithRoom:room];
            Check(l.items.count == [room[@"items"] count], [NSString stringWithFormat:@"%@ template places all items", style.identifier]);
            Check([l.style.identifier isEqual:style.identifier], @"template style");
            for (NSDictionary *record in room[@"items"]) Check([APCatalog itemWithID:record[@"item"]] != nil, record[@"item"]);
        }

        // Pal codes: round trip, garbage, and tampering.
        NSDictionary *pal = @{@"species": @"cat", @"name": @"Meatball", @"coat": @"tuxedo"};
        NSString *code = [APPalWidget encodePal:pal room:[APCatalog starterRoom]];
        NSDictionary *decoded = [APPalWidget decode:[NSString stringWithFormat:@"  here you go:\n%@\n ", code]];
        Check([decoded[@"pal"][@"name"] isEqual:@"Meatball"] && [decoded[@"room"][@"items"] count] == [[APCatalog starterRoom][@"items"] count], @"pal code round trip");
        for (NSString *junk in @[@"", @"PAL1:", @"PAL1:!!!!", @"PAL1:aGVsbG8=", @"hello", [code substringToIndex:code.length / 2]]) {
            Check([APPalWidget decode:junk] == nil, [@"junk rejected: " stringByAppendingString:junk]);
        }
        APSpriteSheetProvider none = ^CGImageRef(NSString *n) { return NULL; };
        for (NSInteger family = APPalWidgetSmall; family <= APPalWidgetExtraLargePortrait; family++) {
            for (NSString *pose in @[@"idle", @"pet", @"play", @"sleep"]) {
                CGImageRef image = [APPalWidget renderPayload:decoded family:family minute:arc4random_uniform(1440)
                                                         state:@{@"pose": pose, @"lightsOff": @(arc4random_uniform(2)), @"seed": @(arc4random())} sprites:none];
                CGSize size = [APPalWidget canvasSizeForFamily:family];
                Check(image && CGImageGetWidth(image) == size.width && CGImageGetHeight(image) == size.height, @"widget renders without sprites");
                CGImageRelease(image);
            }
        }
        if (failures) { printf("pal_home_layout_tests: %d failure(s)\n", failures); return 1; }
        printf("pal_home_layout_tests: all scenarios passed (%d item renders)\n", rendered);
    }
    return 0;
}
