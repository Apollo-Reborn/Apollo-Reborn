#import "ApolloPalHomeShelter.h"
#import "ApolloPixelPalCoats.h"
#import "ApolloPalSpecies.h"

@implementation APShelterAnimal
@end

static uint32_t APShelterHash(NSString *s) {
    uint32_t h = 2166136261u;
    for (NSUInteger i = 0; i < s.length; i++) { h ^= [s characterAtIndex:i]; h *= 16777619u; }
    return h ?: 1;
}

typedef struct { uint32_t s; } APShelterRand;
static uint32_t APSRNext(APShelterRand *r) { uint32_t x = r->s; x ^= x << 13; x ^= x >> 17; x ^= x << 5; r->s = x ?: 1; return x; }
static int APSRInt(APShelterRand *r, int n) { return n > 0 ? (int)(APSRNext(r) % (uint32_t)n) : 0; }

@implementation APShelter

+ (NSArray<NSString *> *)allSpecies {
    return [APSpecies allIDs];
}

+ (NSString *)titleForSpecies:(NSString *)species {
    return [APSpecies speciesWithID:species].title ?: species.capitalizedString;
}

+ (NSArray<NSString *> *)namesForSpecies:(NSString *)species {
    NSDictionary *names = @{
        @"cat": @[@"Sir Pounce", @"Meatball", @"Prof. Whiskers", @"Toast", @"Chairman Meow", @"Pickle", @"Noodle", @"Biscuit"],
        @"dog": @[@"Sir Barksalot", @"Waffles", @"Bark Twain", @"Pancake", @"Tater Tot", @"Gravy", @"Chewie", @"Sergeant Floof"],
        @"hedgehog": @[@"Pincushion", @"Spike Lee", @"Prickles", @"Chestnut", @"Sonic Jr.", @"Thistle"],
        @"fox": @[@"Ziggy", @"Rusty", @"Ember", @"Clementine", @"Mr. Fox", @"Pumpkin"],
        @"axolotl": @[@"Lotl Lotl", @"Gilbert", @"Wasabi", @"Lord Gills", @"Dumpling", @"Bubbles"],
        @"otter": @[@"Otterly", @"Pebble", @"Sir Floats", @"Ottis", @"Mochi", @"Kelpie"],
        @"bat": @[@"Batrick", @"Count Fluff", @"Echo", @"Nugget", @"Vlad", @"Moth Snack"],
        @"parrot": @[@"Capt. Squawk", @"Mango", @"Kiwi", @"Polly Esther", @"Pistachio", @"Sir Chatsalot"],
        @"tiger": @[@"Tigger Smalls", @"Stripes", @"Mr. Mittens", @"Shere Kitten", @"Clawdia", @"Rajah"],
        @"platypus": @[@"Perry", @"Duckbill Dan", @"Agent P", @"Puddles", @"Bill"],
        @"panda": @[@"Bamboozle", @"Dumpling", @"Oreo", @"Pudding", @"Bao", @"Sir Chomps"],
        @"superAI": @[@"Unit 7", @"HAL 9001", @"Beep", @"Byte", @"Clippy 2", @"Modem"],
        @"raccoon": @[@"Trash Panda", @"Bandit", @"Rocket", @"Dumpster Dan", @"Rascal", @"Masky"],
        @"borzoi": @[@"Duchess", @"Spaghetti", @"Sir Snoot", @"Noodle", @"Lady Pointy", @"Fancypaws"],
        @"butterfly": @[@"Flutters", @"Pixie", @"Confetti", @"Marmalade", @"Twinkle", @"Petal"],
        @"trex": @[@"Rexy", @"Tiny Arms", @"Chomp", @"Dino Mite", @"Pebbles", @"Sir Roars"],
        @"capybara": @[@"Capy Barry", @"Chill Bill", @"Sir Soaks", @"Yuzu", @"Hot Tub Tim", @"Potato", @"Okay I Pull Up", @"Mellow"],
    };
    return names[species] ?: @[@"Buddy"];
}

+ (NSString *)randomNameForSpecies:(NSString *)species {
    NSArray *names = [self namesForSpecies:species];
    return names[arc4random_uniform((uint32_t)names.count)];
}

+ (NSString *)titleForPersonality:(APPersonality)p {
    NSArray *titles = @[@"Professional Napper", @"Zoomies Champion", @"Couch Potato", @"Window Watcher", @"Fire Gazer",
                        @"Velcro Pal", @"Snack Bandit", @"Chaos Gremlin", @"Gentle Soul", @"Drama Queen"];
    return p >= 0 && p < (APPersonality)titles.count ? titles[p] : titles.firstObject;
}

+ (NSString *)blurbForPersonality:(APPersonality)p {
    NSArray *blurbs = @[@"Will nap anywhere, anytime.", @"Has two speeds: asleep and FULL SPEED.", @"Believes furniture is for sitting on. Specifically by them.",
                        @"Could watch the snow fall for hours.", @"Happiest by a crackling fire.", @"Will follow you from room to room.",
                        @"Always thinking about the next snack.", @"Cannot. Sit. Still.", @"Calm, sweet and patient.",
                        @"Has a LOT of thoughts. Shares all of them."];
    return p >= 0 && p < (APPersonality)blurbs.count ? blurbs[p] : blurbs.firstObject;
}

+ (NSArray<NSString *> *)quirksForSpecies:(NSString *)species {
    NSMutableArray *quirks = [@[@"Steals socks.", @"Afraid of the vacuum.", @"Sings at 3am.", @"Loves belly rubs.",
        @"Hoards shiny things.", @"Snores like a tractor.", @"Only reads the comments.", @"Lurks on r/aww.",
        @"Doomscrolls past bedtime.", @"Upvotes everything.", @"Judges your posts.", @"Sleeps upside down.",
        @"Scared of its own shadow.", @"Collects bottle caps.", @"Has strong opinions on tabs vs spaces.",
        @"Thinks the fridge is a friend.", @"Sneezes when happy."] mutableCopy];
    if (![species isEqualToString:@"dog"]) [quirks addObject:@"Thinks it's a dog."];
    if ([species isEqualToString:@"cat"]) [quirks addObject:@"Knocks things off tables. On purpose."];
    if ([species isEqualToString:@"superAI"]) [quirks addObject:@"Is definitely not plotting anything."];
    if ([species isEqualToString:@"trex"]) [quirks addObject:@"Cannot reach the top shelf."];
    if ([species isEqualToString:@"raccoon"]) [quirks addObject:@"Washes every snack first."];
    if ([species isEqualToString:@"capybara"]) {
        [quirks addObject:@"Friends with literally everyone."];
        [quirks addObject:@"Has never once been in a hurry."];
        [quirks addObject:@"Unbothered. Moisturised. Thriving."];
    }
    return quirks;
}

+ (NSString *)ageTextForMonths:(int)months species:(NSString *)species {
    NSString *baby = [APSpecies speciesWithID:species].babyWord;
    if (months < 6 && baby) return baby;
    if (months < 12) return [NSString stringWithFormat:@"%d mo", MAX(1, months)];
    int years = months / 12;
    return years == 1 ? @"1 yr" : [NSString stringWithFormat:@"%d yrs", years];
}

+ (NSString *)summaryForSpecies:(NSString *)species gender:(NSString *)gender ageMonths:(int)months {
    NSMutableArray *parts = [NSMutableArray array];
    if ([gender isEqualToString:@"girl"]) [parts addObject:@"Girl"];
    else if ([gender isEqualToString:@"boy"]) [parts addObject:@"Boy"];
    [parts addObject:[self ageTextForMonths:months species:species]];
    [parts addObject:[self titleForSpecies:species]];
    return [parts componentsJoinedByString:@" · "];
}

+ (APShelterAnimal *)animalForSpecies:(NSString *)species rand:(APShelterRand *)r {
    APShelterAnimal *a = [APShelterAnimal new];
    a.species = species;
    NSArray<APCoat *> *coats = [APPixelPalCoats coatsForSpecies:species];
    a.coat = coats.count ? coats[APSRInt(r, (int)coats.count)].identifier : @"original";
    NSArray *names = [self namesForSpecies:species];
    a.name = names[APSRInt(r, (int)names.count)];
    BOOL genderless = [APSpecies speciesWithID:species].genderless;
    a.gender = genderless ? @"" : (APSRInt(r, 2) ? @"girl" : @"boy");
    int bucket = APSRInt(r, 10);
    a.ageMonths = bucket < 3 ? 2 + APSRInt(r, 9) : bucket < 8 ? 12 + APSRInt(r, 72) : 84 + APSRInt(r, 72);
    a.personality = (APPersonality)APSRInt(r, APPersonalityCount);
    if ([species isEqualToString:@"capybara"]) {
        // The calmest animal alive. (Same draw count either way, so the rest
        // of the profile stays stable.)
        static const APPersonality calm[] = {APPersonalityGentleSoul, APPersonalityNapper, APPersonalityCouchPotato,
                                             APPersonalityGentleSoul, APPersonalityFireGazer, APPersonalityVelcro};
        a.personality = calm[a.personality % 6];
    }
    NSArray *quirks = [self quirksForSpecies:species];
    a.quirk = quirks[APSRInt(r, (int)quirks.count)];
    double base = [APSpecies speciesWithID:species].weightInLbs;
    a.weightInLbs = round(base * (0.7 + APSRInt(r, 60) / 100.0) * 100) / 100;
    return a;
}

+ (NSArray<APShelterAnimal *> *)animalsExcludingSpecies:(NSSet<NSString *> *)owned {
    // Same roster all day; tomorrow brings new faces.
    NSInteger day = (NSInteger)floor(NSDate.date.timeIntervalSinceReferenceDate / 86400.0);
    APShelterRand r = {APShelterHash([NSString stringWithFormat:@"shelter-%ld", (long)day])};
    NSMutableArray *pool = [NSMutableArray array];
    for (NSString *species in [self allSpecies]) if (![owned containsObject:species]) [pool addObject:species];
    for (NSUInteger i = pool.count; i > 1; i--) [pool exchangeObjectAtIndex:i - 1 withObjectAtIndex:(NSUInteger)APSRInt(&r, (int)i)];
    // Reborn species are always in (and at the front): they're why you came.
    NSMutableArray *featured = [NSMutableArray array];
    for (NSString *species in pool) if ([APSpecies speciesWithID:species].reborn) [featured addObject:species];
    [pool removeObjectsInArray:featured];
    [pool insertObjects:featured atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, featured.count)]];
    NSMutableArray *animals = [NSMutableArray array];
    for (NSString *species in [pool subarrayWithRange:NSMakeRange(0, MIN(pool.count, 8))]) {
        [animals addObject:[self animalForSpecies:species rand:&r]];
    }
    return animals;
}

+ (APShelterAnimal *)profileForExistingSpecies:(NSString *)species seed:(NSString *)seed {
    APShelterRand r = {APShelterHash([NSString stringWithFormat:@"%@|%@", species, seed])};
    APShelterAnimal *a = [self animalForSpecies:species rand:&r];
    a.coat = @"original";
    return a;
}

@end
