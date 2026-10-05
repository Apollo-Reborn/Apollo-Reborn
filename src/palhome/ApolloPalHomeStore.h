#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pal Home owns resident identities: every Pal has its own id, and its species
// is just a property (an APSpecies id, so Reborn species are first-class).
//
//  - "apollo.<species>" residents are Apollo's own Pals: their name, hearts
//    and age live in Apollo's PixelPalsDatabase (one per species, its rule).
//  - "pal.<uuid>" residents are Reborn's: any species, as many as you like.
//    Their stats live in the Pal Home document.
//
// Apollo's island can only show one of its 16 enum cases, so a Reborn
// resident reaches it through the *island channel*: while it's the active
// Pal, it borrows a spare Apollo slot (a species you don't own). Its name and
// stats are written into that slot's native record, ActivePixelPal points at
// the slot, and the sprite hook draws the resident there instead. When you
// switch away, the slot's stats (hearts earned, kilometres scrolled) are
// copied back to the resident and the slot is returned exactly as it was.
// Apollo never sees a value outside its enum.
@interface ApolloPalHomeResident : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *species;
@property (nonatomic, copy, readonly) NSString *speciesTitle;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, strong, readonly, nullable) NSNumber *hearts;
// Shelter profile (made up, stably, for Pals that predate the shelter).
@property (nonatomic, copy, readonly) NSString *coat;
@property (nonatomic, copy, readonly) NSString *gender;
@property (nonatomic, readonly) int ageMonths;
@property (nonatomic, readonly) NSInteger personality; // APPersonality
@property (nonatomic, copy, readonly) NSString *quirk;
@property (nonatomic, readonly) BOOL adopted;          // came home from the shelter
@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly, getter=isReborn) BOOL reborn; // a "pal.<uuid>" resident
// Apollo's care stats (PixelPalInfo): weight, distance scrolled together, and
// when they last ate / played (nil = never).
@property (nonatomic, strong, readonly, nullable) NSNumber *weightInLbs;
@property (nonatomic, readonly) double kilometersScrolled;
@property (nonatomic, strong, readonly, nullable) NSDate *lastFed, *lastPlayed;
@end

// Care, by Apollo's own rules (Hopper, PixelPalScene):
//  - feed (sub_10004fd34): one food token, +¼ heart, weight +uniform(0.4, 2.2)
//    × the species' factor, at most every 5 hours (sub_1007e9088);
//  - play (sub_100052e4c): +¼ heart, at most every 5 hours (sub_1007e8f08).
// Hearts are 0…6 (we clamp; Apollo's editor caps there too). Food is
// Apollo's shared `foodTokens`, which it keeps awarding while you browse
// (at most one per hour by chance, sub_10074bb24), so both apps spend the
// same pantry.
typedef NS_ENUM(NSInteger, APCareResult) {
    APCareDone = 0,
    APCareNoFood,    // the pantry is empty
    APCareTooSoon,   // fed/played less than 5 hours ago
    APCareUnavailable,
};
FOUNDATION_EXTERN const NSTimeInterval APCareCooldown; // 5 hours
// How many Pals a home can adopt up to (adopting or welcoming one back stops
// here). Never removes anyone: households from before the limit, or Classic
// users with all 16 of Apollo's Pals, keep everyone.
FOUNDATION_EXTERN const NSUInteger APHouseholdLimit; // 8

@class APShelterAnimal;

@interface ApolloPalHomeStore : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults nativeDefaults:(NSUserDefaults *)nativeDefaults;
- (instancetype)init;
// Unknown/newer schemas remain untouched, including when merely visiting Home.
@property (nonatomic, readonly) BOOL canEdit;
// The saved room: {wallpaper, floor, lighting, items: [{uid, item, x, y,
// variant, flip, off}]}. nil until the first edit (Home shows the starter
// room without writing anything). The store validates shape only; the
// catalogue decides which furniture exists, and unknown items round-trip.
@property (nonatomic, copy, readonly, nullable) NSDictionary<NSString *, id> *room;
@property (nonatomic, copy, readonly) NSArray<ApolloPalHomeResident *> *residents;
// `room` is the *active* Pal's: every Pal has a home of their own. nil means
// they haven't moved in yet (moving-in day: an empty room and the boxes).
@property (nonatomic, readonly) BOOL activeMovedIn; // moving-in day has been shown
- (void)markActiveMovedIn;
// Any Pal's home (Pal Home can visit a Pal without putting them on the island).
- (nullable NSDictionary<NSString *, id> *)roomForResident:(NSString *)identifier;
- (BOOL)hasMovedIn:(NSString *)identifier;
- (void)markMovedIn:(NSString *)identifier;
// nil = the active Pal's room.
- (BOOL)saveRoom:(NSDictionary<NSString *, id> *)room forResident:(nullable NSString *)identifier;
- (nullable ApolloPalHomeResident *)residentWithID:(NSString *)identifier;
- (void)refresh;
- (BOOL)saveRoom:(NSDictionary<NSString *, id> *)room;

// Every Pal you have, active first.
@property (nonatomic, copy, readonly) NSArray<ApolloPalHomeResident *> *household;
// Shown the shelter at least once (first-visit onboarding).
@property (nonatomic, readonly) BOOL shelterSeen;
// No room for another adoption (household at APHouseholdLimit or more).
@property (nonatomic, readonly, getter=isHouseholdFull) BOOL householdFull;
- (void)markShelterSeen;
// Adoption creates the resident (an Apollo Pal for an Apollo species you
// don't have yet, otherwise a Reborn one) and makes it the active Pal.
- (BOOL)adoptAnimal:(APShelterAnimal *)animal name:(NSString *)name;
- (BOOL)renameResident:(NSString *)identifier to:(NSString *)name;
- (BOOL)makeActiveResident:(NSString *)identifier;
// Saying goodbye: the Pal goes to a loving new family, taking their room,
// stats and Apollo record with them (archived: see -restoreRehomed:). Never
// your only Pal (returns NO). If they're the active Pal, the next one in the
// household becomes active.
- (BOOL)rehomeResident:(NSString *)identifier;
// Goodbyes aren't forever: the last 12 rehomed Pals ({id, name, species,
// coat, at}, newest first) can come back with their room and stats. Returns
// the restored resident's id (it changes if their Apollo slot is taken now).
@property (nonatomic, readonly) NSArray<NSDictionary *> *rehomed;
- (nullable NSString *)restoreRehomed:(NSString *)identifier;
// Apollo's "Enable Pixel Pals" (group default PixelPalsEnabled): the Pal on
// the Dynamic Island (or the top of the screen on older iPhones).
@property (nonatomic) BOOL islandEnabled;
// Food in Apollo's pantry (shared with the island's care sheet).
@property (nonatomic, readonly) NSInteger foodTokens;
// Seconds until the active Pal can eat / play again (0 = now).
- (NSTimeInterval)waitBeforeFeeding;
- (NSTimeInterval)waitBeforePlaying;
// Feeds / plays with the active Pal. On success the weight gained (lbs) is
// returned through `gain`.
- (APCareResult)feedActive:(nullable double *)gain;
- (APCareResult)playWithActive;
// The same for any Pal (whoever you're visiting), on their own record.
- (NSTimeInterval)waitBeforeFeeding:(NSString *)identifier;
- (NSTimeInterval)waitBeforePlaying:(NSString *)identifier;
- (APCareResult)feedResident:(NSString *)identifier gain:(nullable double *)gain;
- (APCareResult)playWithResident:(NSString *)identifier;
// Settles the island channel after someone else (Apollo's own chooser)
// changed the active Pal: the borrowed slot's stats go home and the slot is
// restored. Cheap and idempotent; call whenever the active Pal may have moved.
- (void)reconcileIsland;

// Where your Pal is shown while Pal Home is on (one place at a time):
// Apollo's Dynamic Island pill, the tab bar (Apollo's own strip on phones
// without an island; on island phones Reborn's overlay walks it along the
// tab bar), or the floating bubble. In the overlay modes Apollo's Pal keeps
// running hidden, so food and distance still count. `islandEnabled` (Apollo's
// PixelPalsEnabled) still turns the Pal off everywhere.
typedef NS_ENUM(NSInteger, APPalDisplay) { APPalDisplayIsland = 0, APPalDisplayTabBar, APPalDisplayBubble };
FOUNDATION_EXTERN NSString *const APPalDisplayKey;
// Posted when the display or Pal Home itself is switched.
FOUNDATION_EXTERN NSString *const APPalDisplayDidChangeNotification;
@property (class, nonatomic) APPalDisplay palDisplay;
// Set at launch by ApolloPixelPals.xm (UIKit knows): this phone has an island.
@property (class, nonatomic) BOOL deviceHasDynamicIsland;

// Pal Home replaces Apollo's Pixel Pals screens only when this is on
// (default off: Classic Pixel Pals). Turning it off returns any borrowed
// island slot and puts one of Apollo's own Pals back on the island; homes and
// adopted Pals are kept for next time.
@property (class, nonatomic, getter=isPalHomeEnabled) BOOL palHomeEnabled;
- (void)returnToClassic;

// The coat an Apollo species' resident wears (Pal Home profile).
+ (nullable NSString *)coatForSpecies:(NSString *)species;
// While a Reborn resident is on the island: {host, species, coat}. The sprite
// hook draws `species` in `coat` wherever Apollo asks for `host`. Cached.
+ (nullable NSDictionary<NSString *, NSString *> *)islandChannel;
@end

NS_ASSUME_NONNULL_END
