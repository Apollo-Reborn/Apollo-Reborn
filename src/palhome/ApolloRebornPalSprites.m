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
// Grid key: '.' clear, 'o' outline, 'f' fur, 's' shade, 'l' belly (cheeks,
// beak), 'n' nose (mouth), 'e' eye, 'z' sleep Z.

enum { kW = 32, kH = 14 };

typedef struct { char px[kH][kW + 1]; } APGrid;

// Each species' base colours per grid key (the coat roles in
// ApolloPixelPalCoats match these exactly).
static uint32_t APSpriteColor(NSString *species, char ch) {
    switch (ch) {
        case 'o': return 0x000000;
        case 'e': return 0x0B0E10;
        case 'z': return 0x828282;
        case '.': return 0xFFFFFFFF; // clear
        default: break;
    }
    if ([species isEqualToString:@"ghost"]) {
        switch (ch) {
            case 'f': return 0xF2F2FA;
            case 's': return 0xC4C4DC;
            case 'l': return 0xE8A0B4; // cheeks
            case 'n': return 0x4A3A5A; // mouth
            default: return 0xFFFFFFFF;
        }
    }
    if ([species isEqualToString:@"goose"]) {
        switch (ch) {
            case 'f': return 0xF4F4F0;
            case 's': return 0xC8C8C4;
            case 'l': return 0xF09030; // beak and feet
            case 'n': return 0xC86A1A;
            default: return 0xFFFFFFFF;
        }
    }
    switch (ch) {
        case 'f': return 0xA47449;
        case 's': return 0x7A5233;
        case 'l': return 0xC8A073;
        case 'n': return 0x4B3121;
        default: return 0xFFFFFFFF;
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

#pragma mark - Ghost

// A little bedsheet ghost: a dome with a scalloped hem, floating (no legs, so
// the hem never touches the floor). Drawn from a shape so it can bob, lean
// and squash; outlined afterwards.

typedef struct {
    int bob;       // rows raised (+) or lowered (-)
    int squash;    // rows shorter (lying, crouching)
    int lean;      // forward lean of the lower half, in pixels
    int hem;       // scallop phase
    int eyes;      // 0 open, 1 closed (content), 2 wide (alert)
    BOOL mouthO;   // "oooh"
} APGhostPose;

static APGrid APGhostDraw(APGhostPose p) {
    APGrid g = APGridBlank();
    int height = 11 - p.squash, top = 12 - height - p.bob - 1, cx = 16, r = 6;
    // Body fill.
    for (int y = 0; y < height; y++) {
        int row = top + y;
        int half;
        if (y < r) {
            float dy = r - y - 0.5f;
            half = (int)lroundf(sqrtf(MAX(0.0f, r * r - dy * dy)));
        } else {
            half = r + (y - r >= height - r - 2 ? 1 : 0); // a slight flare at the hem
        }
        int shift = y >= height / 2 ? -p.lean * (y - height / 2) / MAX(1, height / 2) : 0; // trailing hem
        for (int x = cx - half; x <= cx + half - 1; x++) {
            // Scalloped hem: notch every third pixel on the last row.
            if (y == height - 1 && (x + p.hem) % 3 == 0) continue;
            APGridSet(&g, x + shift, row, 'f');
        }
    }
    // Shade: the back (left) edge and the hem.
    for (int y = 0; y < kH; y++) {
        for (int x = 0; x < kW; x++) {
            if (g.px[y][x] != 'f') continue;
            if (APGridGet(&g, x - 1, y) == '.' || APGridGet(&g, x - 2, y) == '.') { g.px[y][x] = 's'; break; }
        }
    }
    for (int x = 0; x < kW; x++) for (int y = kH - 1; y >= 0; y--) {
        if (g.px[y][x] == 'f') { g.px[y][x] = 's'; break; }
        if (g.px[y][x] == 's') break;
    }
    // Face (facing right).
    int ey = top + 3;
    if (p.eyes == 1) {
        // Content closed eyes: ^ ^
        APGridSet(&g, 16, ey + 1, 'e'); APGridSet(&g, 17, ey, 'e'); APGridSet(&g, 18, ey + 1, 'e');
        APGridSet(&g, 19, ey + 1, 'e'); APGridSet(&g, 20, ey, 'e'); APGridSet(&g, 21, ey + 1, 'e');
    } else {
        int tall = p.eyes == 2 ? 3 : 2;
        for (int k = 0; k < tall; k++) { APGridSet(&g, 17, ey + k - (tall == 3), 'e'); APGridSet(&g, 20, ey + k - (tall == 3), 'e'); }
    }
    if (p.mouthO) { APGridSet(&g, 18, ey + 3, 'n'); APGridSet(&g, 19, ey + 3, 'n'); APGridSet(&g, 18, ey + 4, 'n'); APGridSet(&g, 19, ey + 4, 'n'); }
    else if (p.eyes != 1) { APGridSet(&g, 18, ey + 3, 'n'); APGridSet(&g, 19, ey + 3, 'n'); }
    APGridSet(&g, 16, ey + 2, 'l'); APGridSet(&g, 21, ey + 2, 'l');
    // Outline everything.
    APGrid out = g;
    for (int y = 0; y < kH; y++) for (int x = 0; x < kW; x++) {
        if (g.px[y][x] != '.') continue;
        if (APGridGet(&g, x + 1, y) != '.' || APGridGet(&g, x - 1, y) != '.' || APGridGet(&g, x, y + 1) != '.' || APGridGet(&g, x, y - 1) != '.') out.px[y][x] = 'o';
    }
    return out;
}

static NSArray<NSValue *> *APGhostFrames(NSString *action) {
    NSMutableArray *frames = [NSMutableArray array];
    void (^add)(APGrid) = ^(APGrid g) { [frames addObject:[NSValue valueWithBytes:&g objCType:@encode(APGrid)]]; };
    if ([action isEqualToString:@"sit"]) {
        add(APGhostDraw((APGhostPose){.bob = 1}));
    } else if ([action isEqualToString:@"alert"]) {
        add(APGhostDraw((APGhostPose){.bob = 1, .eyes = 2, .mouthO = YES}));
    } else if ([action isEqualToString:@"walk"]) {
        // A lazy drift: gentle bob, the hem rippling.
        static const int bob[8] = {1, 1, 0, 0, 0, 1, 1, 1};
        for (int f = 0; f < 8; f++) add(APGhostDraw((APGhostPose){.bob = bob[f], .lean = 1, .hem = f % 3}));
    } else if ([action isEqualToString:@"run"]) {
        // Whoosh: leaning hard, the hem streaming behind.
        for (int f = 0; f < 4; f++) add(APGhostDraw((APGhostPose){.bob = f % 2, .lean = 3, .hem = f % 3, .mouthO = f % 2}));
    } else if ([action isEqualToString:@"crouch"]) {
        for (int f = 0; f < 8; f++) add(APGhostDraw((APGhostPose){.bob = 0, .squash = 2, .hem = (f / 2) % 3}));
    } else if ([action isEqualToString:@"lie"]) {
        // Hovering low and comfy: a slow blink, the hem stirring.
        for (int f = 0; f < 24; f++) {
            add(APGhostDraw((APGhostPose){.squash = 3, .bob = f % 12 < 6 ? 0 : 1, .hem = (f / 4) % 3, .eyes = f >= 8 && f <= 13 ? 1 : 0}));
        }
    } else if ([action isEqualToString:@"lie-single"]) {
        add(APGhostDraw((APGhostPose){.squash = 3}));
    } else if ([action isEqualToString:@"sleep"]) {
        for (int f = 0; f < 2; f++) {
            APGrid g = APGhostDraw((APGhostPose){.squash = 3, .bob = f, .eyes = 1});
            if (f == 0) APDrawZ(&g, 24, 3, 3); else APDrawZ(&g, 25, 0, 4);
            add(g);
        }
    }
    return frames;
}

#pragma mark - Goose

// A white farmyard goose: long neck, orange beak and feet, unearned
// confidence. Stamped from parts (body, neck, head, legs) per pose.

static void APStamp(APGrid *g, const char *const *rows, int count, int ox, int oy) {
    for (int y = 0; y < count; y++) {
        size_t n = strlen(rows[y]);
        for (size_t x = 0; x < n; x++) if (rows[y][x] != '.') APGridSet(g, ox + (int)x, oy + y, rows[y][x]);
    }
}

// Body, rows 0–5 (top outline to bottom outline), tail on the left.
static const char *const kGooseBody[6] = {
    "oo..............",
    "osooooooooooooo.",
    "ossfffffffffffffo",
    ".ossssssssffffffo",
    "..ossfffffffffffo",
    "...ooooooooooooo",
};

// Head, 4 rows: x 0–3 head, then the beak.
static const char *const kGooseHead[4] = {
    ".ooo....",
    "offfo...",
    "ofefllno",
    "offfooo.",
};
static const char *const kGooseHeadHonk[4] = {
    ".ooo..o.",
    "offfollo",
    "ofefo...",
    "offfolln",
};
static const char *const kGooseHeadSleepy[4] = {
    ".ooo....",
    "offfo...",
    "ooofllno",
    "offfooo.",
};

typedef struct {
    int bodyY;      // top row of the body
    int headX, headY;
    int legs;       // 0 standing, 1/2 stepping, 3 tucked (sitting), 4 stretched (running)
    int head;       // 0 normal, 1 honk, 2 sleepy
    BOOL wingUp;
} APGoosePose;

static APGrid APGooseDraw(APGoosePose p) {
    APGrid g = APGridBlank();
    int bx = 5, by = p.bodyY;
    // Legs first, so the body's bottom outline sits over their tops.
    if (p.legs != 3) {
        int lx[2] = {bx + 8, bx + 11};
        int lean[2] = {0, 0};
        if (p.legs == 1) { lean[0] = 1; lean[1] = -1; }
        if (p.legs == 2) { lean[0] = -1; lean[1] = 1; }
        if (p.legs == 4) { lean[0] = -2; lean[1] = 2; }
        for (int i = 0; i < 2; i++) {
            int top = by + 6, foot = 13;
            for (int y = top; y < foot; y++) APGridSet(&g, lx[i] + (y == foot - 1 ? lean[i] : 0), y, 'l');
            APGridSet(&g, lx[i] + lean[i], foot, 'l');
            APGridSet(&g, lx[i] + lean[i] + 1, foot, 'l');
            APGridSet(&g, lx[i] + lean[i] + 2, foot, 'n');
        }
    }
    APStamp(&g, kGooseBody, 6, bx, by);
    if (p.wingUp) {
        static const char *const wing[3] = {"..ooooo..", ".offffffo", "osssssso."};
        APStamp(&g, wing, 3, bx + 3, by - 2);
    }
    // Neck: a two-wide white stroke from the chest to the head, wherever the
    // head is (up and proud, stretched forward, or down grazing). Outline
    // first, fill second, so it reads as one smooth tube.
    int x0 = bx + 13, y0 = by + 2, x1 = p.headX + 1, y1 = p.headY + 3;
    int steps = MAX(abs(x1 - x0), abs(y1 - y0));
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i <= steps; i++) {
            int x = x0 + (int)lroundf((x1 - x0) * (float)i / MAX(1, steps)), y = y0 + (int)lroundf((y1 - y0) * (float)i / MAX(1, steps));
            if (pass == 0) {
                for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 2; dx++) {
                    if (APGridGet(&g, x + dx, y + dy) == '.') APGridSet(&g, x + dx, y + dy, 'o');
                }
            } else {
                APGridSet(&g, x, y, 'f'); APGridSet(&g, x + 1, y, 'f');
            }
        }
    }
    const char *const *head = p.head == 1 ? kGooseHeadHonk : p.head == 2 ? kGooseHeadSleepy : kGooseHead;
    APStamp(&g, head, 4, p.headX, p.headY);
    return g;
}

static NSArray<NSValue *> *APGooseFrames(NSString *action) {
    NSMutableArray *frames = [NSMutableArray array];
    void (^add)(APGrid) = ^(APGrid g) { [frames addObject:[NSValue valueWithBytes:&g objCType:@encode(APGrid)]]; };
    APGoosePose stand = {.bodyY = 6, .headX = 18, .headY = 0};
    if ([action isEqualToString:@"sit"]) {
        add(APGooseDraw(stand));
    } else if ([action isEqualToString:@"alert"]) {
        // HONK.
        APGoosePose honk = stand;
        honk.head = 1; honk.wingUp = YES;
        add(APGooseDraw(honk));
    } else if ([action isEqualToString:@"walk"]) {
        // The waddle: the body rocks a row, the head pumps forward.
        for (int f = 0; f < 8; f++) {
            APGoosePose w = stand;
            w.legs = f < 4 ? 1 : 2;
            w.bodyY = 6 - (f % 4 == 1 || f % 4 == 2 ? 1 : 0);
            w.headX = 18 + (f % 4 >= 2 ? 1 : 0);
            w.headY = w.bodyY - 6;
            add(APGooseDraw(w));
        }
    } else if ([action isEqualToString:@"run"]) {
        // Neck out, wings up, absolutely furious.
        for (int f = 0; f < 4; f++) {
            APGoosePose r = {.bodyY = 6 - f % 2, .headX = 22, .headY = 3 - f % 2, .legs = f % 2 ? 4 : 2, .head = 1, .wingUp = f % 2 == 0};
            add(APGooseDraw(r));
        }
    } else if ([action isEqualToString:@"crouch"]) {
        // Grazing: head down at the floor, nibbling.
        for (int f = 0; f < 8; f++) {
            APGoosePose e = {.bodyY = 6, .headX = 22, .headY = 9 - (f % 2), .legs = 0};
            add(APGooseDraw(e));
        }
    } else if ([action isEqualToString:@"lie"]) {
        // Settled on the floor like a loaf with a neck; a slow blink.
        for (int f = 0; f < 24; f++) {
            APGoosePose l = {.bodyY = 8, .headX = 18, .headY = 2 + (f >= 18 && f <= 20 ? 1 : 0), .legs = 3, .head = f >= 8 && f <= 12 ? 2 : 0};
            add(APGooseDraw(l));
        }
    } else if ([action isEqualToString:@"lie-single"]) {
        add(APGooseDraw((APGoosePose){.bodyY = 8, .headX = 18, .headY = 2, .legs = 3}));
    } else if ([action isEqualToString:@"sleep"]) {
        // Head tucked back over the wing.
        for (int f = 0; f < 2; f++) {
            APGrid g = APGooseDraw((APGoosePose){.bodyY = 8, .headX = 15, .headY = 5 + f, .legs = 3, .head = 2});
            if (f == 0) APDrawZ(&g, 24, 3, 3); else APDrawZ(&g, 25, 0, 4);
            add(g);
        }
    }
    return frames;
}

#pragma mark - Sheets

static NSArray<NSValue *> *APRebornFrames(NSString *species, NSString *action) {
    if ([species isEqualToString:@"capybara"]) return APCapyFrames(action);
    if ([species isEqualToString:@"ghost"]) return APGhostFrames(action);
    if ([species isEqualToString:@"goose"]) return APGooseFrames(action);
    return @[];
}

BOOL APRebornHasSprites(NSString *species) {
    return [species isEqualToString:@"capybara"] || [species isEqualToString:@"ghost"] || [species isEqualToString:@"goose"];
}

CGImageRef APRebornCreateSheet(NSString *species, NSString *action) {
    NSArray<NSValue *> *frames = APRebornFrames(species, action);
    if (!frames.count) return NULL;
    APCanvas *sheet = APCanvasCreate(kW * (int)frames.count, kH);
    for (NSUInteger i = 0; i < frames.count; i++) {
        APGrid g;
        [frames[i] getValue:&g size:sizeof(g)];
        for (int y = 0; y < kH; y++) for (int x = 0; x < kW; x++) {
            uint32_t rgb = APSpriteColor(species, g.px[y][x]);
            if (rgb != 0xFFFFFFFF) APPx(sheet, (int)i * kW + x, y, rgb);
        }
    }
    CGImageRef image = APCanvasCreateCGImage(sheet);
    APCanvasFree(sheet);
    return image;
}

CGPoint APRebornHeadTop(NSString *species, NSString *action) {
    // Where a hat (or a yuzu) sits, in a frame's top-left pixel coordinates.
    BOOL low = [action hasPrefix:@"lie"] || [action isEqualToString:@"sleep"] || [action isEqualToString:@"crouch"];
    if ([species isEqualToString:@"capybara"]) {
        if ([action isEqualToString:@"sit"]) return CGPointMake(23, 3);
        if ([action isEqualToString:@"alert"]) return CGPointMake(22, 3);
        if (low) return CGPointMake(22, 5);
        return CGPointMake(22, 4);
    }
    if ([species isEqualToString:@"ghost"]) return CGPointMake(16, low ? 4 : 1);
    if ([species isEqualToString:@"goose"]) return CGPointMake(19, low ? 2 : 0);
    return CGPointMake(-1, -1);
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
