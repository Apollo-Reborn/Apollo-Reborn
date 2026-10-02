#import "ApolloPalSpecies.h"

@interface APSpecies ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *apolloCase;
@property (nonatomic, readwrite) double weightInLbs;
@property (nonatomic, readwrite) BOOL genderless;
@property (nonatomic, copy, readwrite) NSString *snackThought;
@property (nonatomic, copy, readwrite) NSString *babyWord;
@property (nonatomic, readwrite) double feedWeightFactor;
@end

typedef struct {
    const char *identifier, *title;
    BOOL apollo;       // one of Apollo.PixelPal's cases (identifier == rawValue)
    double weightInLbs;
    BOOL genderless;
    const char *snack; // thought icon: "bone", "fish", "yuzu"
    const char *baby;
    double feedWeightFactor; // Apollo's, or our own for Reborn species
} APSpeciesDef;

// Apollo's 16 first, in Apollo.PixelPal's declaration order (Hopper: field
// descriptor 0x100b46b6c), then Reborn's own.
static const APSpeciesDef kSpecies[] = {
    {"cat", "Cat", YES, 9, NO, "fish", "Kitten", 0.75},
    {"dog", "Dog", YES, 25, NO, "bone", "Puppy", 1.0},
    {"hedgehog", "Hedgehog", YES, 1, NO, "fish", "Hoglet", 0.1},
    {"fox", "Fox", YES, 12, NO, "bone", "Kit", 0.25},
    {"axolotl", "Axolotl", YES, 0.3, NO, "fish", NULL, 0.04},
    {"otter", "Otter", YES, 20, NO, "fish", "Pup", 0.28},
    {"bat", "Bat", YES, 0.1, NO, "fish", "Pup", 0.01},
    {"parrot", "Parrot", YES, 2, NO, "fish", "Chick", 0.03},
    {"tiger", "Tiger", YES, 300, NO, "fish", "Cub", 2.5},
    {"platypus", "Platypus", YES, 3, NO, "fish", "Puggle", 0.16},
    {"panda", "Panda", YES, 200, NO, "fish", "Cub", 0.25},
    {"superAI", "Superintelligence", YES, 0, YES, "fish", NULL, 15.0},
    {"raccoon", "Raccoon", YES, 15, NO, "fish", "Kit", 0.16},
    {"borzoi", "Borzoi", YES, 70, NO, "bone", "Puppy", 0.95},
    {"butterfly", "Butterfly", YES, 0.01, YES, "fish", NULL, 0.001},
    {"trex", "T. rex", YES, 14000, NO, "bone", "Hatchling", 39.6},
    // Reborn'd.
    {"capybara", "Capybara", NO, 110, NO, "yuzu", "Pup", 1.2},
};

@implementation APSpecies

- (BOOL)isReborn { return self.apolloCase == nil; }

+ (NSArray<APSpecies *> *)all {
    static NSArray *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (size_t i = 0; i < sizeof(kSpecies) / sizeof(kSpecies[0]); i++) {
            APSpecies *s = [APSpecies new];
            s.identifier = @(kSpecies[i].identifier);
            s.title = @(kSpecies[i].title);
            s.apolloCase = kSpecies[i].apollo ? s.identifier : nil;
            s.weightInLbs = kSpecies[i].weightInLbs;
            s.genderless = kSpecies[i].genderless;
            s.snackThought = [@"t." stringByAppendingString:@(kSpecies[i].snack)];
            s.babyWord = kSpecies[i].baby ? @(kSpecies[i].baby) : nil;
            s.feedWeightFactor = kSpecies[i].feedWeightFactor;
            [list addObject:s];
        }
        all = list;
    });
    return all;
}

+ (NSDictionary<NSString *, APSpecies *> *)byID {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (APSpecies *s in [self all]) m[s.identifier] = s;
        map = m;
    });
    return map;
}

+ (APSpecies *)speciesWithID:(NSString *)identifier {
    return [identifier isKindOfClass:NSString.class] ? [self byID][identifier] : nil;
}

+ (NSArray<NSString *> *)allIDs { return [[self all] valueForKey:@"identifier"]; }

+ (NSArray<NSString *> *)apolloIDs {
    static NSArray *ids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (APSpecies *s in [self all]) if (s.apolloCase) [list addObject:s.identifier];
        ids = list;
    });
    return ids;
}

+ (BOOL)isApolloSpecies:(NSString *)identifier {
    return [self speciesWithID:identifier].apolloCase != nil;
}

@end
