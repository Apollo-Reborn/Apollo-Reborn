#import "ApolloPixelPalCoats.h"
#import "ApolloPalHomeStore.h"
#import <math.h>

static NSString *const kCoatsDefaultsKey = @"ApolloRebornPixelPalCoats";

// Palette roles recovered from the Assets.car sprites (see header). Groups
// list their original colours, base first.
typedef struct {
    const char *species;
    const char *groups; // groups separated by '|', colours by ','
} APSpeciesRoles;

static const APSpeciesRoles kRoles[] = {
    {"cat", "d68438,d68538|3c291a,674423|f4cca1,f4cba2"},
    {"dog", "967d67,967d68|6d4b39|f4cca1,f4cba2"},
    {"hedgehog", "422b1a|c5a97d,826646,eacfa0,e9cfa0"},
    {"fox", "b75800,b75801,793f00,793f01|27170e,27170f|f4cca1,f4cba2,bb966d"},
    {"axolotl", "ecc8cc,c98c90,c98d91|e56290,e56391"},
    {"otter", "715555,947a75,947b76,634545|beafa7,beafa8|2f1e20,2f1e21"},
    {"bat", "5d667b,646f88,757f8b,75808b,909cab|1f1f24,1f1f23,494c54,494c53"},
    {"parrot", "c92039,c42940|e2bd4a,ebb611|548ad4,4f7bb8"},
    {"tiger", "e8973b,e8963c|ffffff|565655,565656"},
    {"platypus", "5e809a,425072|c8631a"},
    {"panda", "ffffff,c9c9c9|2c354d"},
    {"superAI", "3478f5,82b7ff|e5535d"},
    {"raccoon", "898075|3f3731|e0d1c0"},
    {"borzoi", "d0cbc9,a59f9c|ffffff"},
    {"butterfly", "c52f3b,c5303b|ffb600,ffb601|da6816"},
    {"trex", "439700,449705,439601,419701,449600,419605|c6d50a,c6d508"},
    // Reborn species (ApolloRebornPalSprites draws these colours).
    {"capybara", "a47449,7a5233|c8a073|4b3121"},
    {"ghost", "f2f2fa,c4c4dc|e8a0b4|4a3a5a"},
    {"goose", "f4f4f0,c8c8c4|f09030,c86a1a"},
};

// Coats: species, id, title, new base per group ('-' keeps the original).
typedef struct { const char *species, *identifier, *title, *bases; } APCoatDef;

static const APCoatDef kCoats[] = {
    {"cat", "midnight", "Midnight", "4a4a58|2c2c36|6a6a78"},
    {"cat", "tuxedo", "Tuxedo", "464654|2a2a34|f4f4f2"},
    {"cat", "silver", "Silver Tabby", "a8a8b0|4a4a54|ececf0"},
    {"cat", "cream", "Cream", "eccc94|c09a60|fff0d8"},
    {"cat", "lilac", "Lilac", "b8a8c4|86749a|f2eaf6"},
    {"cat", "snow", "Snowball", "f2f0ec|d4d0c8|ffffff"},

    {"dog", "golden", "Golden", "d8a050|a87428|f8e0b0"},
    {"dog", "blacklab", "Black Lab", "4e4844|302c2a|6a625c"},
    {"dog", "chocolate", "Chocolate", "7a4a2a|52301a|a87050"},
    {"dog", "husky", "Husky", "9aa0aa|565c66|f6f6f6"},
    {"dog", "corgi", "Corgi Red", "d4802e|a4521a|fff4e8"},
    {"dog", "cream", "Cream", "ecd8b0|c8a878|fff4e0"},

    {"hedgehog", "albino", "Albino", "ece4dc|f6e6e0"},
    {"hedgehog", "cinnamon", "Cinnamon", "8a5030|e0c090"},
    {"hedgehog", "saltpepper", "Salt & Pepper", "5c5c62|d8ccc0"},
    {"hedgehog", "blush", "Blush", "c87a98|f6d6de"},

    {"fox", "arctic", "Arctic", "eaf0f6|8a96a6|ffffff"},
    {"fox", "silver", "Silver", "62626e|2e2e36|eeeeee"},
    {"fox", "fennec", "Fennec", "e8c890|8a6438|fff4e0"},
    {"fox", "marble", "Marble", "dcdcdc|3a3a40|ffffff"},

    {"axolotl", "wild", "Wild", "6a6a44|8a5a6a"},
    {"axolotl", "golden", "Golden", "f2d272|f09060"},
    {"axolotl", "melanoid", "Melanoid", "4c4c5a|7a5a8a"},
    {"axolotl", "lavender", "Lavender", "cebcec|b070d8"},
    {"axolotl", "glow", "Glow", "c8f2b2|5ed874"},

    {"otter", "sea", "Sea Otter", "5a4030|eadec8|201410"},
    {"otter", "golden", "Golden", "9a7040|ecd4a4|3a2614"},
    {"otter", "cocoa", "Cocoa", "5e3e2a|a8866a|2a1a10"},
    {"otter", "frost", "Frost", "9aa4b0|f0f4f8|3a424c"},

    {"bat", "fruit", "Fruit Bat", "a86634|3a2418"},
    {"bat", "ghost", "Ghost Bat", "e8e8f0|a8a8bc"},
    {"bat", "vampire", "Vampire", "7a2a36|2a1418"},
    {"bat", "candy", "Candy", "e094b8|6a3a5e"},

    {"parrot", "blueandgold", "Blue & Gold", "2f72d4|f2c430|2a4c9a"},
    {"parrot", "hyacinth", "Hyacinth", "3c3cb0|f2d440|2a2a86"},
    {"parrot", "amazon", "Amazon", "40a844|e8e040|3070c4"},
    {"parrot", "cockatoo", "Cockatoo", "f6f6f4|f2e060|c8c8d0"},
    {"parrot", "galah", "Galah", "e88aaa|d0d0d8|9a9aaa"},

    {"tiger", "white", "White Tiger", "f2eee6|-|3a3a40"},
    {"tiger", "golden", "Golden Tabby", "f6ca72|-|d08a40"},
    {"tiger", "snow", "Snow Leopard", "dadad2|-|6a6a6c"},
    {"tiger", "panther", "Black Panther", "484856|5c5c6a|2c2c36"},

    {"platypus", "real", "River", "6a4a30|3c3c44"},
    {"platypus", "mint", "Mint", "72baa2|f2a442"},
    {"platypus", "grape", "Grape", "8a70c2|f2c440"},

    {"panda", "qinling", "Qinling Brown", "f2e6d2|6a4a34"},
    {"panda", "sakura", "Sakura", "fff2f6|c86a8c"},
    {"panda", "inverted", "Night Shift", "3a3a4a|eaeaf2"},

    {"superAI", "emerald", "Emerald", "28c070|-"},
    {"superAI", "amber", "Amber", "f2a420|-"},
    {"superAI", "violet", "Violet", "9a52f2|-"},
    {"superAI", "rose", "Rose", "f25a9c|5aa0f2"},

    {"raccoon", "blonde", "Blonde", "c8a878|8a6a48|f6ead6"},
    {"raccoon", "midnight", "Midnight", "56565e|303036|9a9aa2"},
    {"raccoon", "cinnamon", "Cinnamon", "a46c42|5a3420|eacaa2"},

    {"borzoi", "gold", "Gold", "dab272|-"},
    {"borzoi", "blacktan", "Black & Tan", "504848|c89060"},
    {"borzoi", "red", "Red", "c27242|f2dcc6"},
    {"borzoi", "silver", "Silver", "9c9ca4|eaeaf0"},

    {"butterfly", "monarch", "Monarch", "ea7a22|fff2d8|c45210"},
    {"butterfly", "morpho", "Blue Morpho", "2a7ae8|90d4ff|1a50b0"},
    {"butterfly", "swallowtail", "Lime Swallowtail", "9ad040|f2f282|5a9a28"},
    {"butterfly", "pink", "Pink Lady", "f282b2|fff2f8|d05a92"},

    {"trex", "ocean", "Ocean", "2a82c2|82d2f2"},
    {"trex", "lava", "Lava", "c23222|f2a232"},
    {"trex", "grape", "Grape", "7a42b2|caa2f2"},
    {"trex", "fossil", "Fossil", "d8d0c0|a8a090"},
    {"trex", "bubblegum", "Bubblegum", "e472a2|ffd2e2"},

    {"capybara", "honey", "Honey", "c8904a|ecc890|5a3a1c"},
    {"capybara", "cocoa", "Cocoa", "6a4a34|9a7458|2a1a12"},
    {"capybara", "ash", "Ash", "8a8078|bcb0a4|3a3430"},
    {"capybara", "sakura", "Sakura", "d49a96|f4d0cc|8a5058"},
    {"capybara", "yuzu", "Yuzu", "d8a438|f2d890|7a5418"},

    {"ghost", "pumpkin", "Pumpkin Spice", "f2b070|-|-"},
    {"ghost", "slime", "Slime", "a8f0a8|-|-"},
    {"ghost", "spectral", "Spectral", "b0dcff|-|-"},
    {"ghost", "lavender", "Lavender", "d4c0f4|-|-"},
    {"ghost", "shadow", "Shadow", "6a6080|f04a7a|-"},

    {"goose", "greylag", "Greylag", "aaa69e|-"},
    {"goose", "toulouse", "Toulouse", "7a7670|e88a3a"},
    {"goose", "golden", "Golden Egg", "f2d27a|-"},
    {"goose", "midnight", "Midnight", "4a4858|f2c040"},
};

static const char *kOriginalTitles[][2] = {
    {"cat", "Ginger"}, {"dog", "Mocha"}, {"hedgehog", "Classic"}, {"fox", "Red"}, {"axolotl", "Leucistic"},
    {"otter", "River"}, {"bat", "Dusk"}, {"parrot", "Scarlet Macaw"}, {"tiger", "Bengal"}, {"platypus", "Apollo Blue"},
    {"panda", "Giant"}, {"superAI", "Sapphire"}, {"raccoon", "Grey"}, {"borzoi", "White"}, {"butterfly", "Red Admiral"},
    {"trex", "Jungle"},
    {"capybara", "Wild"},
    {"ghost", "Bedsheet"}, {"goose", "Farmyard"},
};

@interface APCoat ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy) NSString *bases;
@end

@implementation APCoat
@end

#pragma mark - Colour maths

typedef struct { float h, s, l; } APHSL;

static APHSL APToHSL(uint32_t rgb) {
    float r = ((rgb >> 16) & 255) / 255.0f, g = ((rgb >> 8) & 255) / 255.0f, b = (rgb & 255) / 255.0f;
    float mx = fmaxf(r, fmaxf(g, b)), mn = fminf(r, fminf(g, b)), d = mx - mn;
    APHSL out = {0, 0, (mx + mn) / 2};
    if (d > 1e-5f) {
        out.s = out.l > 0.5f ? d / (2 - mx - mn) : d / (mx + mn);
        if (mx == r) out.h = fmodf((g - b) / d + (g < b ? 6 : 0), 6);
        else if (mx == g) out.h = (b - r) / d + 2;
        else out.h = (r - g) / d + 4;
        out.h /= 6;
    }
    return out;
}

static float APHue(float p, float q, float t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6.0f) return p + (q - p) * 6 * t;
    if (t < 0.5f) return q;
    if (t < 2 / 3.0f) return p + (q - p) * (2 / 3.0f - t) * 6;
    return p;
}

static uint32_t APFromHSL(APHSL c) {
    float r, g, b;
    if (c.s <= 1e-5f) { r = g = b = c.l; }
    else {
        float q = c.l < 0.5f ? c.l * (1 + c.s) : c.l + c.s - c.l * c.s, p = 2 * c.l - q;
        r = APHue(p, q, c.h + 1 / 3.0f); g = APHue(p, q, c.h); b = APHue(p, q, c.h - 1 / 3.0f);
    }
    return ((uint32_t)lroundf(fminf(fmaxf(r, 0), 1) * 255) << 16) | ((uint32_t)lroundf(fminf(fmaxf(g, 0), 1) * 255) << 8) |
           (uint32_t)lroundf(fminf(fmaxf(b, 0), 1) * 255);
}

// Map `colour` (a member of a group whose original base is `base`) onto a
// group re-based at `target`, keeping its shading relationship.
static uint32_t APRebase(uint32_t colour, uint32_t base, uint32_t target) {
    if (colour == base) return target;
    APHSL c = APToHSL(colour), b = APToHSL(base), t = APToHSL(target), o;
    // Darker shades scale toward black, lighter ones toward white, so the
    // result always stays in range however light/dark the new coat is.
    if (c.l <= b.l) o.l = b.l > 1e-3f ? t.l * (c.l / b.l) : t.l;
    else o.l = b.l < 0.999f ? t.l + (1 - t.l) * (c.l - b.l) / (1 - b.l) : t.l;
    o.s = b.s > 0.05f ? fminf(1, t.s * (c.s / b.s)) : t.s;
    o.h = fmodf(t.h + (c.h - b.h) + 1, 1);
    return APFromHSL(o);
}

static uint32_t APParseHex(NSString *hex) { return (uint32_t)strtoul(hex.UTF8String, NULL, 16); }

static BOOL APNear(uint32_t a, uint32_t b) {
    int dr = abs((int)((a >> 16) & 255) - (int)((b >> 16) & 255));
    int dg = abs((int)((a >> 8) & 255) - (int)((b >> 8) & 255));
    int db = abs((int)(a & 255) - (int)(b & 255));
    return dr <= 3 && dg <= 3 && db <= 3;
}

@implementation APPixelPalCoats

+ (NSArray<NSArray<NSNumber *> *> *)groupsForSpecies:(NSString *)species {
    for (size_t i = 0; i < sizeof(kRoles) / sizeof(kRoles[0]); i++) {
        if (![species isEqualToString:@(kRoles[i].species)]) continue;
        NSMutableArray *groups = [NSMutableArray array];
        for (NSString *group in [@(kRoles[i].groups) componentsSeparatedByString:@"|"]) {
            NSMutableArray *colours = [NSMutableArray array];
            for (NSString *hex in [group componentsSeparatedByString:@","]) [colours addObject:@(APParseHex(hex))];
            [groups addObject:colours];
        }
        return groups;
    }
    return @[];
}

+ (NSArray<APCoat *> *)coatsForSpecies:(NSString *)species {
    static NSMutableDictionary<NSString *, NSArray *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized (cache) {
        if (cache[species]) return cache[species];
        NSMutableArray *coats = [NSMutableArray array];
        APCoat *original = [APCoat new];
        original.identifier = @"original";
        original.title = @"Original";
        for (size_t i = 0; i < sizeof(kOriginalTitles) / sizeof(kOriginalTitles[0]); i++) {
            if ([species isEqualToString:@(kOriginalTitles[i][0])]) original.title = @(kOriginalTitles[i][1]);
        }
        [coats addObject:original];
        for (size_t i = 0; i < sizeof(kCoats) / sizeof(kCoats[0]); i++) {
            if (![species isEqualToString:@(kCoats[i].species)]) continue;
            APCoat *coat = [APCoat new];
            coat.identifier = @(kCoats[i].identifier);
            coat.title = @(kCoats[i].title);
            coat.bases = @(kCoats[i].bases);
            [coats addObject:coat];
        }
        cache[species] = coats;
        return coats;
    }
}

+ (NSString *)speciesForAssetName:(NSString *)name {
    if (![name isKindOfClass:NSString.class] || name.length < 5 || name.length > 40) return nil;
    NSRange dash = [name rangeOfString:@"-"];
    if (dash.location == NSNotFound) return nil;
    NSString *species = [name substringToIndex:dash.location];
    static NSSet *known;
    static NSSet *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *set = [NSMutableSet set];
        for (size_t i = 0; i < sizeof(kRoles) / sizeof(kRoles[0]); i++) [set addObject:@(kRoles[i].species)];
        known = set;
        actions = [NSSet setWithArray:@[@"alert", @"crouch", @"lie", @"lie-single", @"run", @"settings", @"sit", @"sleep", @"walk",
                                        @"lie1", @"lie2", @"lie3", @"lie4", @"lie5", @"lie6", @"lie7"]];
    });
    if (![known containsObject:species]) return nil;
    return [actions containsObject:[name substringFromIndex:dash.location + 1]] ? species : nil;
}

+ (CGImageRef)createRecoloredImage:(CGImageRef)image species:(NSString *)species coat:(NSString *)coatID {
    if (!image || [coatID isEqualToString:@"original"]) return NULL;
    APCoat *coat = nil;
    for (APCoat *candidate in [self coatsForSpecies:species]) if ([candidate.identifier isEqual:coatID]) coat = candidate;
    if (!coat.bases) return NULL;
    NSArray<NSArray<NSNumber *> *> *groups = [self groupsForSpecies:species];
    NSArray<NSString *> *bases = [coat.bases componentsSeparatedByString:@"|"];
    // Build the exact colour → colour map once.
    NSMutableArray<NSArray<NSNumber *> *> *map = [NSMutableArray array]; // [from, to]
    for (NSUInteger g = 0; g < groups.count && g < bases.count; g++) {
        if ([bases[g] isEqualToString:@"-"]) continue;
        uint32_t target = APParseHex(bases[g]), base = groups[g].firstObject.unsignedIntValue;
        for (NSNumber *colour in groups[g]) [map addObject:@[colour, @(APRebase(colour.unsignedIntValue, base, target))]];
    }
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (!w || !h || w > 4096 || h > 256) return NULL;
    uint8_t *px = calloc(w * h * 4, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    for (size_t i = 0; i < w * h; i++) {
        uint8_t a = px[i * 4 + 3];
        if (a < 250) continue; // the sprites are 1-bit alpha; leave anything else alone
        uint32_t rgb = ((uint32_t)px[i * 4] << 16) | ((uint32_t)px[i * 4 + 1] << 8) | px[i * 4 + 2];
        for (NSArray<NSNumber *> *pair in map) {
            if (!APNear(rgb, pair[0].unsignedIntValue)) continue;
            uint32_t to = pair[1].unsignedIntValue;
            px[i * 4] = (to >> 16) & 255; px[i * 4 + 1] = (to >> 8) & 255; px[i * 4 + 2] = to & 255;
            break;
        }
    }
    CGImageRef result = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    free(px);
    return result;
}

#pragma mark Persistence

+ (NSDictionary *)storedCoats {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kCoatsDefaultsKey];
    return [stored isKindOfClass:NSDictionary.class] ? stored : @{};
}

+ (NSString *)selectedCoatForSpecies:(NSString *)species {
    // A Pal's coat is part of who they are (set at adoption); the older
    // free-choice coat setting is only a fallback for Pals with no profile.
    id coat = [ApolloPalHomeStore coatForSpecies:species] ?: self.storedCoats[species];
    if (![coat isKindOfClass:NSString.class]) return @"original";
    for (APCoat *candidate in [self coatsForSpecies:species]) if ([candidate.identifier isEqual:coat]) return coat;
    return @"original";
}

+ (NSString *)legacyCoatForSpecies:(NSString *)species {
    id coat = self.storedCoats[species];
    if (![coat isKindOfClass:NSString.class]) return nil;
    for (APCoat *candidate in [self coatsForSpecies:species]) if ([candidate.identifier isEqual:coat]) return coat;
    return nil;
}

@end
