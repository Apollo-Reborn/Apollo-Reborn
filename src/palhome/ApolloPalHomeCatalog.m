#import "ApolloPalHomeCatalog.h"

@implementation APAnim
+ (instancetype)kind:(APAnimKind)kind x:(int)x y:(int)y w:(int)w h:(int)h {
    APAnim *anim = [self new];
    anim.kind = kind;
    anim.x = x; anim.y = y; anim.w = w; anim.h = h;
    anim.color = 0xFFD27A;
    return anim;
}
@end

@implementation APLight
+ (instancetype)x:(int)x y:(int)y radius:(float)radius color:(uint32_t)color strength:(float)strength {
    APLight *light = [self new];
    light.x = x; light.y = y; light.radius = radius; light.color = color; light.strength = strength;
    return light;
}
@end

@interface APDrawContext ()
@property (nonatomic, readwrite) APCanvas *base;
@property (nonatomic, readwrite) APCanvas *emissive;
@property (nonatomic, readwrite) APCanvas *front;
@property (nonatomic, readwrite) int width, height, variant, hour, minute;
@property (nonatomic, readwrite) BOOL on;
@property (nonatomic, readwrite) NSMutableArray<APAnim *> *anims;
@property (nonatomic, readwrite) NSMutableArray<APLight *> *lights;
@end

@implementation APDrawContext
- (void)dealloc {
    APCanvasFree(_base);
    APCanvasFree(_emissive);
    APCanvasFree(_front);
}
- (void)addAnim:(APAnim *)anim { [self.anims addObject:anim]; }
- (void)addLight:(APLight *)light { [self.lights addObject:light]; }
@end

@implementation APItemSpec
- (int)pixelWidth { return self.w * APTile; }
- (int)pixelHeight {
    return self.layer == APLayerWall || self.layer == APLayerTrim ? self.d * APTile : self.d * APTile + self.rise;
}
@end

@implementation APSurfaceSpec
@end

@implementation APStyleSpec
@end

NSDictionary *APRoomItem(NSString *identifier, int x, int y, int variant) {
    return @{@"uid": [NSString stringWithFormat:@"tpl.%@.%d.%d", identifier, x, y], @"item": identifier, @"x": @(x), @"y": @(y), @"variant": @(variant)};
}

APItemSpec *APSpec(NSString *identifier, NSString *title, APLayer layer, APCategory category, int w, int d, int rise,
                   NSArray<NSString *> *variants, APDrawBlock draw) {
    APItemSpec *spec = [APItemSpec new];
    spec.identifier = identifier;
    spec.title = title;
    spec.layer = layer;
    spec.category = category;
    spec.w = w;
    spec.d = d;
    spec.rise = rise;
    spec.variants = variants.count ? variants : @[@"Standard"];
    spec.draw = draw;
    spec.walkable = layer == APLayerRug;
    return spec;
}

APDrawContext *APRenderItem(APItemSpec *spec, int variant, BOOL on, int minuteOfDay) {
    APDrawContext *ctx = [APDrawContext new];
    ctx.width = spec.pixelWidth;
    ctx.height = spec.pixelHeight;
    ctx.base = APCanvasCreate(ctx.width, ctx.height);
    ctx.emissive = APCanvasCreate(ctx.width, ctx.height);
    ctx.front = APCanvasCreate(ctx.width, ctx.height);
    ctx.variant = MAX(0, MIN(variant, (int)spec.variants.count - 1));
    ctx.on = on;
    ctx.hour = (minuteOfDay / 60) % 24;
    ctx.minute = minuteOfDay % 60;
    ctx.anims = [NSMutableArray array];
    ctx.lights = [NSMutableArray array];
    if (spec.draw) spec.draw(ctx);
    return ctx;
}

APRamp APRampNamed(NSString *name) {
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *ramps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ramps = @{
            @"rust": @[@0x4A2218, @0x7A3A24, @0xA85432, @0xC87444, @0xE09A62],
            @"sage": @[@0x2A3A2A, @0x4A6248, @0x6A8A64, @0x8CAA82, @0xB0C8A2],
            @"navy": @[@0x1E2238, @0x2E3A5E, @0x44568A, @0x6076AA, @0x8AA0C8],
            @"mustard": @[@0x4A3414, @0x8A6420, @0xC0902E, @0xDCB04A, @0xF0D07A],
            @"rose": @[@0x4A2230, @0x84404E, @0xB0607A, @0xCC8498, @0xE8AABA],
            @"cream": @[@0x5A4A3A, @0xB8A488, @0xD8C8A8, @0xECE0C4, @0xFAF4E4],
            @"oak": @[@0x3A2414, @0x6A4228, @0x8A5A36, @0xA8744A, @0xC8966A],
            @"walnut": @[@0x24160E, @0x4A2E1C, @0x62402A, @0x7C5436, @0x9A6E4A],
            @"white": @[@0x4A4440, @0x9A928A, @0xC8C0B4, @0xE4DED2, @0xF8F4EC],
            @"stone": @[@0x3A3430, @0x5E5650, @0x7E766C, @0x9E9488, @0xBEB4A6],
            @"brick": @[@0x3A1E18, @0x6A3226, @0x8E4432, @0xAA5A40, @0xC47A5A],
            @"iron": @[@0x16161A, @0x2A2A30, @0x3E3E48, @0x56566A, @0x74748A],
            @"lavender": @[@0x2E2440, @0x4E4270, @0x6E62A0, @0x9488C4, @0xB8AEDC],
            @"teal": @[@0x14302E, @0x245450, @0x347A72, @0x4EA094, @0x7CC4B6],
            @"leaf": @[@0x1E3018, @0x2E4A24, @0x44682E, @0x5E8A3C, @0x86B052],
            @"gold": @[@0x4A3410, @0x8A6418, @0xC8962A, @0xE8BE48, @0xFCE69A],
            @"terracotta": @[@0x4A2014, @0x7E3A22, @0xA8543A, @0xC87050, @0xE09A78],
            @"red": @[@0x3A1014, @0x6E1C22, @0x9E2E30, @0xC44A44, @0xE07A6A],
        };
    });
    NSArray<NSNumber *> *r = ramps[name] ?: ramps[@"oak"];
    return (APRamp){r[0].unsignedIntValue, r[1].unsignedIntValue, r[2].unsignedIntValue, r[3].unsignedIntValue, r[4].unsignedIntValue};
}

@implementation APCatalog

+ (NSArray<APItemSpec *> *)items {
    static NSArray *items;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *all = [NSMutableArray array];
        APRegisterFurniture(all);
        APRegisterWallItems(all);
        APRegisterThemedItems(all);
        APRegisterHalloweenItems(all);
        items = all;
    });
    return items;
}

+ (APItemSpec *)itemWithID:(NSString *)identifier {
    static NSDictionary *index;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (APItemSpec *spec in [self items]) map[spec.identifier] = spec;
        index = map;
    });
    return [identifier isKindOfClass:NSString.class] ? index[identifier] : nil;
}

+ (NSArray<APItemSpec *> *)itemsInCategory:(APCategory)category {
    // Seasonal pieces show up in the catalogue during their month, first.
    NSInteger month = [NSCalendar.currentCalendar component:NSCalendarUnitMonth fromDate:NSDate.date];
    NSMutableArray *seasonal = [NSMutableArray array], *regular = [NSMutableArray array];
    for (APItemSpec *spec in [self items]) {
        if (spec.category != category) continue;
        if (spec.season == 0) [regular addObject:spec];
        else if (spec.season == month) [seasonal addObject:spec];
    }
    return [seasonal arrayByAddingObjectsFromArray:regular];
}

+ (void)loadSurfaces:(void (^)(NSArray *walls, NSArray *floors))block {
    static NSArray *walls, *floors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *w = [NSMutableArray array], *f = [NSMutableArray array];
        APRegisterSurfaces(w, f);
        APRegisterThemedSurfaces(w, f);
        APRegisterHalloweenSurfaces(w, f);
        walls = w;
        floors = f;
    });
    block(walls, floors);
}

+ (NSArray<APSurfaceSpec *> *)wallpapers {
    __block NSArray *result;
    [self loadSurfaces:^(NSArray *walls, NSArray *floors) { result = walls; }];
    return result;
}

+ (NSArray<APSurfaceSpec *> *)floors {
    __block NSArray *result;
    [self loadSurfaces:^(NSArray *walls, NSArray *floors) { result = floors; }];
    return result;
}

+ (APSurfaceSpec *)wallpaperWithID:(NSString *)identifier {
    for (APSurfaceSpec *spec in [self wallpapers]) if ([spec.identifier isEqual:identifier]) return spec;
    return nil;
}

+ (APSurfaceSpec *)floorWithID:(NSString *)identifier {
    for (APSurfaceSpec *spec in [self floors]) if ([spec.identifier isEqual:identifier]) return spec;
    return nil;
}

+ (NSArray<APStyleSpec *> *)styles {
    static NSArray *styles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *all = [NSMutableArray array];
        APRegisterStyles(all);
        [all addObject:APHalloweenManorStyle()];
        styles = all;
    });
    return styles;
}

+ (NSArray<APStyleSpec *> *)stylesForDisplay {
    NSInteger month = [NSCalendar.currentCalendar component:NSCalendarUnitMonth fromDate:NSDate.date];
    NSMutableArray *seasonal = [NSMutableArray array], *regular = [NSMutableArray array];
    for (APStyleSpec *style in [self styles]) [(style.season == month ? seasonal : regular) addObject:style];
    return [seasonal arrayByAddingObjectsFromArray:regular];
}

+ (APStyleSpec *)styleWithID:(NSString *)identifier {
    for (APStyleSpec *style in [self styles]) if ([style.identifier isEqual:identifier]) return style;
    return [self styles].firstObject;
}

+ (NSString *)titleForCategory:(APCategory)category {
    switch (category) {
        case APCategoryStyles: return @"Home Styles";
        case APCategoryFurniture: return @"Furniture";
        case APCategoryCosy: return @"Cosy Things";
        case APCategoryRugs: return @"Rugs";
        case APCategoryWall: return @"Wall";
        case APCategoryArt: return @"Art";
        case APCategoryWallpaper: return @"Wallpaper";
        case APCategoryFlooring: return @"Flooring";
        default: return @"";
    }
}

// Moving-in day: bare walls and floor, one window for light, and the boxes.
// Everything in the catalogue is yours from the start; the styles' furnished
// rooms are a tap away in the Styles tab.
+ (NSDictionary *)starterRoom {
    return @{@"style": @"cottage", @"wallpaper": @"wp.plaster", @"floor": @"fl.oak", @"lighting": @"auto", @"items": @[
        @{@"uid": @"start.window", @"item": @"window", @"x": @3, @"y": @0, @"variant": @3},
        @{@"uid": @"start.boxes", @"item": @"boxes", @"x": @6, @"y": @1},
    ]};
}

@end
