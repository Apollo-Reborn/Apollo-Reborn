#import "ApolloRebornPalSprites.h"
#import "ApolloPixelCanvas.h"
#import "ApolloPixelPalCoats.h"

// Reborn species are hand-drawn here as character grids, in the exact format
// of Apollo's own Pal sheets (Assets.car): 32×14 frames laid left to right,
// facing right, #000000 outline, grey #828282 sleep "Z". Same frame counts per
// action as Apollo's, so its island animates them without knowing the
// difference (sit 1, alert 1, walk 8, run 4, crouch 8, sleep 2, lie 24,
// lie-single 1). Coats recolour these like any other Pal (ApolloPixelPalCoats
// has the palette roles).
//
// Grid key: '.' clear, 'o' outline, 'f' fur, 's' shade, 'l' belly,
// 'n' nose, 'e' eye, 'z' sleep Z.

enum { kW = 32, kH = 14 };

typedef struct { char px[kH][kW + 1]; } APGrid;

static uint32_t APCapyColor(char ch) {
    switch (ch) {
        case 'o': return 0x000000;
        case 'f': return 0xA47449;
        case 's': return 0x7A5233;
        case 'l': return 0xC8A073;
        case 'n': return 0x4B3121;
        case 'e': return 0x0B0E10;
        case 'z': return 0x828282;
        default: return 0xFFFFFFFF; // clear
    }
}

static APGrid APGridFrom(const char *const rows[kH]) {
    APGrid g;
    for (int y = 0; y < kH; y++) {
        memset(g.px[y], '.', kW);
        g.px[y][kW] = 0;
        size_t n = MIN(strlen(rows[y]), (size_t)kW);
        memcpy(g.px[y], rows[y], n);
    }
    return g;
}

static APGrid APGridBlank(void) {
    APGrid g;
    for (int y = 0; y < kH; y++) { memset(g.px[y], '.', kW); g.px[y][kW] = 0; }
    return g;
}

static void APGridSet(APGrid *g, int x, int y, char ch) {
    if (x >= 0 && x < kW && y >= 0 && y < kH) g->px[y][x] = ch;
}

static char APGridGet(const APGrid *g, int x, int y) {
    return x >= 0 && x < kW && y >= 0 && y < kH ? g->px[y][x] : '.';
}

#pragma mark - Capybara

// Standing, legs drawn separately (rows 12–13).
static const char *const kCapyBody[kH] = {
    "................................",
    "................................",
    "................................",
    "..................oo............",
    ".................osfoooooo......",
    "........oooooooooffffffffoo.....",
    "......ooffffffffffffffeffffo....",
    ".....offffffffffffffffffffffo...",
    ".....offffffffffffffffsfffffno..",
    ".....osfffffffffffffffsffffnno..",
    ".....ossfffffffffffffsoosssso...",
    "......osslllllllllllsfo.oooo....",
    "................................",
    "................................",
};

// The loaf: Apollo's "sit" is the idle pose, and capybaras idle like this.
static const char *const kCapySit[kH] = {
    "................................",
    "................................",
    "...................oo...........",
    "..................osfoooooo.....",
    ".............oooooffffffffoo....",
    "...........oofffffffffffeffffo..",
    "..........offfffffffffffffffffo.",
    ".........offffffffffffffsfffffno",
    "........offfffffffffffffsffffnno",
    ".......osffffffffffffffsoosssso.",
    ".......osfffffffffffffsfo.oooo..",
    ".......ossffffffffffllsfo.......",
    ".......ossslllllllllllsfo.......",
    "........oooooooooooooooooo......",
};

// Leg columns (left edge of each 4-wide leg): back pair, front pair.
static const int kCapyLegX[4] = {7, 12, 18, 22};

// One stubby leg: a 4-wide column from the belly down to a foot. A lifted
// leg is one row shorter (the foot hovers).
static void APCapyLeg(APGrid *g, int x, int top, BOOL lifted) {
    int foot = lifted ? 12 : 13;
    for (int y = top; y < foot; y++) {
        APGridSet(g, x, y, 'o'); APGridSet(g, x + 1, y, 's'); APGridSet(g, x + 2, y, 'f'); APGridSet(g, x + 3, y, 'o');
    }
    for (int i = 0; i < 4; i++) APGridSet(g, x + i, foot, 'o');
}

// The standing body with legs: dx per leg and which legs are lifted, the body
// raised by `lift` rows (legs stretch to reach the floor).
static APGrid APCapyStanding(const int dx[4], const BOOL lifted[4], int lift) {
    APGrid g = APGridBlank();
    APGrid body = APGridFrom(kCapyBody);
    for (int y = 0; y < kH; y++) for (int x = 0; x < kW; x++) {
        char ch = body.px[y][x];
        if (ch != '.') APGridSet(&g, x, y - lift, ch);
    }
    // Legs first fill under the belly, then the belly line is redrawn over them.
    for (int i = 0; i < 4; i++) APCapyLeg(&g, kCapyLegX[i] + dx[i], 12 - lift, lifted[i]);
    return g;
}

static APGrid APCapyStand(void) {
    static const int dx[4] = {0, 0, 0, 0};
    static const BOOL up[4] = {NO, NO, NO, NO};
    return APCapyStanding(dx, up, 0);
}

// Legs tucked away: the body settles onto the floor.
static APGrid APCapyLying(void) {
    APGrid g = APGridBlank();
    APGrid body = APGridFrom(kCapyBody);
    for (int y = 0; y < kH; y++) for (int x = 0; x < kW; x++) {
        char ch = body.px[y][x];
        if (ch != '.') APGridSet(&g, x, y + 1, ch);
    }
    // A flat underside on the floor, with the front paws peeking out.
    for (int x = 6; x <= 20; x++) APGridSet(&g, x, 13, 'o');
    APGridSet(&g, 21, 12, 'f'); APGridSet(&g, 22, 12, 'f'); APGridSet(&g, 23, 12, 'o');
    APGridSet(&g, 21, 13, 'o'); APGridSet(&g, 22, 13, 'o'); APGridSet(&g, 23, 13, 'o');
    return g;
}

// Little expressions, all relative to a pose's eye.
static BOOL APGridFind(const APGrid *g, char ch, int *outX, int *outY) {
    for (int y = 0; y < kH; y++) for (int x = 0; x < kW; x++) if (g->px[y][x] == ch) { *outX = x; *outY = y; return YES; }
    return NO;
}

static void APCapyCloseEyes(APGrid *g) {
    int x, y;
    if (!APGridFind(g, 'e', &x, &y)) return;
    // A content little closed-eye line: ‿
    APGridSet(g, x, y, 's');
    APGridSet(g, x - 1, y + 1, 'o'); APGridSet(g, x, y + 1, 'o');
}

static void APCapyFlickEar(APGrid *g) {
    // The ear tips back a pixel.
    int ex = -1, ey = -1;
    for (int y = 0; y < kH && ex < 0; y++) for (int x = 0; x < kW; x++) {
        if (g->px[y][x] == 'o' && APGridGet(g, x + 1, y) == 'o' && APGridGet(g, x, y + 1) == 's') { ex = x; ey = y; break; }
    }
    if (ex < 0) return;
    APGridSet(g, ex + 1, ey, '.');
    APGridSet(g, ex - 1, ey, 'o');
}

static void APCapyTwitchNose(APGrid *g) {
    for (int y = 0; y < kH; y++) for (int x = kW - 1; x >= 0; x--) {
        if (g->px[y][x] == 'n') { g->px[y][x] = 's'; return; }
    }
}

static void APDrawZ(APGrid *g, int x, int y, int size) {
    for (int i = 0; i < size; i++) { APGridSet(g, x + i, y, 'z'); APGridSet(g, x + i, y + size - 1, 'z'); }
    for (int i = 1; i < size - 1; i++) APGridSet(g, x + size - 1 - i, y + i, 'z');
}

static NSArray<NSValue *> *APCapyFrames(NSString *action) {
    NSMutableArray *frames = [NSMutableArray array];
    void (^add)(APGrid) = ^(APGrid g) { [frames addObject:[NSValue valueWithBytes:&g objCType:@encode(APGrid)]]; };
    if ([action isEqualToString:@"sit"]) {
        add(APGridFrom(kCapySit));
    } else if ([action isEqualToString:@"alert"]) {
        // All ears: the ear pricks up a pixel, nose going.
        APGrid g = APCapyStand();
        APGridSet(&g, 18, 2, 'o'); APGridSet(&g, 19, 2, 'o');
        APGridSet(&g, 17, 3, 'o'); APGridSet(&g, 18, 3, 's'); APGridSet(&g, 19, 3, 'f'); APGridSet(&g, 20, 3, 'o');
        APGridSet(&g, 18, 4, 'f'); APGridSet(&g, 19, 4, 'f');
        APCapyTwitchNose(&g);
        add(g);
    } else if ([action isEqualToString:@"walk"]) {
        // A steady trot: diagonal pairs swap, the leg swinging forward lifts.
        static const int stride[8] = {1, 1, 0, 0, -1, -1, 0, 0};
        static const BOOL swing[8] = {NO, NO, NO, NO, NO, NO, YES, YES};
        for (int f = 0; f < 8; f++) {
            int a = f, b = (f + 4) % 8;
            int dx[4] = {stride[a], stride[b], stride[b], stride[a]};
            BOOL up[4] = {swing[a], swing[b], swing[b], swing[a]};
            APGrid g = APCapyStanding(dx, up, 0);
            if (f == 2 || f == 6) APCapyTwitchNose(&g);
            add(g);
        }
    } else if ([action isEqualToString:@"run"]) {
        // A surprisingly quick gallop: stretch, gather (airborne), stretch, gather.
        static const int stretch[4] = {-1, -1, 1, 2}, gather[4] = {1, 1, -1, -1};
        for (int f = 0; f < 4; f++) {
            BOOL air = f % 2 == 1;
            const int *dx = air ? gather : stretch;
            BOOL up[4] = {air, air, air, air};
            add(APCapyStanding(dx, up, air ? 1 : 0));
        }
    } else if ([action isEqualToString:@"crouch"]) {
        // Low and still, ears going.
        for (int f = 0; f < 8; f++) {
            APGrid g = APCapyLying();
            if (f % 4 == 1 || f % 4 == 2) APCapyFlickEar(&g);
            if (f == 5) APCapyTwitchNose(&g);
            add(g);
        }
    } else if ([action isEqualToString:@"lie"]) {
        // Twenty-four frames of profound relaxation: a slow blink, an ear
        // flick, one nose twitch.
        for (int f = 0; f < 24; f++) {
            APGrid g = APCapyLying();
            if (f >= 8 && f <= 13) APCapyCloseEyes(&g);
            if (f == 18 || f == 19) APCapyFlickEar(&g);
            if (f == 3) APCapyTwitchNose(&g);
            add(g);
        }
    } else if ([action isEqualToString:@"lie-single"]) {
        add(APCapyLying());
    } else if ([action isEqualToString:@"sleep"]) {
        for (int f = 0; f < 2; f++) {
            APGrid g = APCapyLying();
            APCapyCloseEyes(&g);
            if (f == 0) APDrawZ(&g, 6, 3, 3); else APDrawZ(&g, 4, 0, 4);
            add(g);
        }
    }
    return frames;
}

#pragma mark - Sheets

static NSArray<NSValue *> *APRebornFrames(NSString *species, NSString *action) {
    if ([species isEqualToString:@"capybara"]) return APCapyFrames(action);
    return @[];
}

BOOL APRebornHasSprites(NSString *species) {
    return [species isEqualToString:@"capybara"];
}

CGImageRef APRebornCreateSheet(NSString *species, NSString *action) {
    NSArray<NSValue *> *frames = APRebornFrames(species, action);
    if (!frames.count) return NULL;
    APCanvas *sheet = APCanvasCreate(kW * (int)frames.count, kH);
    for (NSUInteger i = 0; i < frames.count; i++) {
        APGrid g;
        [frames[i] getValue:&g size:sizeof(g)];
        for (int y = 0; y < kH; y++) for (int x = 0; x < kW; x++) {
            uint32_t rgb = APCapyColor(g.px[y][x]);
            if (rgb != 0xFFFFFFFF) APPx(sheet, (int)i * kW + x, y, rgb);
        }
    }
    CGImageRef image = APCanvasCreateCGImage(sheet);
    APCanvasFree(sheet);
    return image;
}

CGPoint APRebornHeadTop(NSString *species, NSString *action) {
    // Where a hat (or a yuzu) sits, in a frame's top-left pixel coordinates.
    if (![species isEqualToString:@"capybara"]) return CGPointMake(-1, -1);
    if ([action isEqualToString:@"sit"]) return CGPointMake(23, 3);
    if ([action isEqualToString:@"alert"]) return CGPointMake(22, 3);
    if ([action hasPrefix:@"lie"] || [action isEqualToString:@"sleep"] || [action isEqualToString:@"crouch"]) return CGPointMake(22, 5);
    return CGPointMake(22, 4);
}

CGImageRef APPalCreateSheet(NSString *species, NSString *coat, NSString *action, APNativeSheetLoader native) {
    if (!species.length || !action.length) return NULL;
    CGImageRef base = NULL;
    if (APRebornHasSprites(species)) {
        base = APRebornCreateSheet(species, action);
    } else if (native) {
        base = native([NSString stringWithFormat:@"%@-%@", species, action]);
        if (base) CGImageRetain(base);
    }
    if (!base) return NULL;
    CGImageRef recolored = coat ? [APPixelPalCoats createRecoloredImage:base species:species coat:coat] : NULL;
    if (!recolored) return base;
    CGImageRelease(base);
    return recolored;
}
