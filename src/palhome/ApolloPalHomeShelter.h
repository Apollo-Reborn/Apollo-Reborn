#import <Foundation/Foundation.h>

// The Paws & Claws Shelter: a small, daily-changing roster of adoptable Pals.
// Each animal has a species, a coat (fixed for life once adopted), a silly
// starter name, gender, age, a personality that shapes how it behaves at
// home, and a quirk. Foundation only.

NS_ASSUME_NONNULL_BEGIN

// Personalities nudge the Pal's idle behaviour (see the scene's -think).
typedef NS_ENUM(NSInteger, APPersonality) {
    APPersonalityNapper = 0,   // naps a lot
    APPersonalityZoomies,      // runs instead of walks, plays more
    APPersonalityCouchPotato,  // loves sitting on furniture
    APPersonalityWindowWatcher,
    APPersonalityFireGazer,
    APPersonalityVelcro,       // all heart thoughts, comes when called
    APPersonalitySnackBandit,  // always thinking about food
    APPersonalityChaosGremlin, // never sits still
    APPersonalityGentleSoul,   // calm, slow
    APPersonalityDramaQueen,   // so many thoughts
    APPersonalityCount,
};

@interface APShelterAnimal : NSObject
@property (nonatomic, copy) NSString *species;
@property (nonatomic, copy) NSString *coat;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *gender;    // "girl", "boy" or "" (it's complicated)
@property (nonatomic) int ageMonths;
@property (nonatomic) APPersonality personality;
@property (nonatomic, copy) NSString *quirk;
@property (nonatomic) double weightInLbs;
@end

@interface APShelter : NSObject
// Today's roster (same all day), skipping species already at home.
+ (NSArray<APShelterAnimal *> *)animalsExcludingSpecies:(NSSet<NSString *> *)owned;
+ (NSString *)titleForSpecies:(NSString *)species;
+ (NSArray<NSString *> *)allSpecies;
+ (NSString *)randomNameForSpecies:(NSString *)species;
+ (NSString *)titleForPersonality:(APPersonality)personality;
+ (NSString *)blurbForPersonality:(APPersonality)personality;
// "4 mo", "2 yrs"; "Kitten"/"Puppy" for the very young.
+ (NSString *)ageTextForMonths:(int)months species:(NSString *)species;
// "Girl · 2 yrs · Cat" style summary line.
+ (NSString *)summaryForSpecies:(NSString *)species gender:(NSString *)gender ageMonths:(int)months;
// A stable made-up profile for a Pal that was already home before the shelter
// existed (seeded by species + a stable seed, the resident id, so renaming
// never changes it). Only for what Apollo doesn't store.
+ (APShelterAnimal *)profileForExistingSpecies:(NSString *)species seed:(NSString *)seed;
@end

NS_ASSUME_NONNULL_END
