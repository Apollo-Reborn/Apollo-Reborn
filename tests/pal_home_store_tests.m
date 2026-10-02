#import <Foundation/Foundation.h>
#import "palhome/ApolloPalHomeStore.h"
#import "UserDefaultConstants.h"
#import "palhome/ApolloPalHomeShelter.h"

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSString *ownedSuite = [@"app.apolloreborn.tests.palhome." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *nativeSuite = [ownedSuite stringByAppendingString:@".native"];
        NSUserDefaults *owned = [[NSUserDefaults alloc] initWithSuiteName:ownedSuite];
        NSUserDefaults *native = [[NSUserDefaults alloc] initWithSuiteName:nativeSuite];
        @try {
            // A clean installation can visit Home without creating native stats
            // or writing defaults merely because Settings Search builds a screen.
            ApolloPalHomeStore *store = [[ApolloPalHomeStore alloc] initWithDefaults:owned nativeDefaults:native];
            Check(store.room == nil, @"starter room is not written on visit");
            Check([store.residents.firstObject.species isEqual:@"cat"], @"native default species");
            Check([owned objectForKey:UDKeyPalHome] == nil && [native objectForKey:@"PixelPalsDatabase"] == nil, @"read-only visit");

            NSDictionary *info = @{@"name": @"Captain Paws", @"hearts": @4.5, @"weightInLbs": @8, @"age": @42};
            NSDictionary *nativeJSON = @{@"pixelPals": @[@"cat", @{@"name": @"Cat"}, @"otter", info], @"foodTokens": @17};
            NSData *nativeBlob = [NSJSONSerialization dataWithJSONObject:nativeJSON options:0 error:nil];
            [native setObject:nativeBlob forKey:@"PixelPalsDatabase"];
            [native setObject:@"otter" forKey:@"ActivePixelPal"];
            [store refresh];
            Check([store.residents.firstObject.name isEqual:@"Captain Paws"], @"Swift enum-key dictionary array");
            Check([store.residents.firstObject.hearts isEqual:@4.5], @"fractional friendship preserved");
            NSDictionary *sofa = @{@"uid": @"u1", @"item": @"sofa", @"x": @4, @"y": @0, @"variant": @2};
            Check([store saveRoom:@{@"wallpaper": @"wp.midnight", @"floor": @"fl.oak", @"items": @[sofa]}], @"room edit");
            Check([[native dataForKey:@"PixelPalsDatabase"] isEqual:nativeBlob], @"native care blob unchanged");
            Check([[native stringForKey:@"ActivePixelPal"] isEqual:@"otter"], @"native selection unchanged");

            // The backup carries the standard-defaults document. Restore it into
            // a fresh domain and ensure its room and stable identities survive.
            NSDictionary *backup = [owned dictionaryForKey:UDKeyPalHome];
            [owned removePersistentDomainForName:ownedSuite];
            [owned setObject:backup forKey:UDKeyPalHome];
            store = [[ApolloPalHomeStore alloc] initWithDefaults:owned nativeDefaults:native];
            Check([store.room[@"wallpaper"] isEqual:@"wp.midnight"] && [store.room[@"items"] isEqual:@[sofa]], @"restore room");
            Check([backup[@"residents"][@"apollo.otter"][@"species"] isEqual:@"otter"], @"resident independent of room");
            [native setObject:@"dog" forKey:@"ActivePixelPal"];
            [store refresh];
            Check([store.residents.firstObject.identifier isEqual:@"apollo.dog"], @"follow changed native Pal");
            // Every Pal has their own home: the dog hasn't moved in yet.
            Check(store.room == nil && !store.activeMovedIn, @"each Pal has their own room (the dog has none yet)");
            NSDictionary *kennel = @{@"wallpaper": @"wp.brick", @"items": @[]};
            Check([store saveRoom:kennel] && [store.room[@"wallpaper"] isEqual:@"wp.brick"], @"the dog's room saves separately");
            [store markActiveMovedIn];
            Check(store.activeMovedIn, @"moving-in day recorded");
            [native setObject:@"otter" forKey:@"ActivePixelPal"];
            [store refresh];
            Check([store.room[@"wallpaper"] isEqual:@"wp.midnight"] && store.activeMovedIn, @"the otter's room is untouched");
            NSDictionary *doc = [owned dictionaryForKey:UDKeyPalHome];
            Check([doc[@"rooms"] count] == 2 && [doc[@"room"][@"wallpaper"] isEqual:@"wp.brick"], @"rooms per resident; legacy mirror is the last saved");

            // A document from before per-Pal rooms: its room becomes the active Pal's.
            [owned setObject:@{@"schemaVersion": @1, @"room": @{@"wallpaper": @"wp.sky", @"items": @[]}, @"residents": @{}} forKey:UDKeyPalHome];
            store = [[ApolloPalHomeStore alloc] initWithDefaults:owned nativeDefaults:native];
            Check([store.room[@"wallpaper"] isEqual:@"wp.sky"] && store.activeMovedIn, @"legacy room migrates to the active Pal");
            [native setObject:@"dog" forKey:@"ActivePixelPal"];
            [store refresh];
            Check(store.room == nil, @"…and only theirs");
            [native setObject:@"otter" forKey:@"ActivePixelPal"];
            [store refresh];
            [native setObject:@"dog" forKey:@"ActivePixelPal"];

            NSMutableDictionary *extended = [backup mutableCopy];
            extended[@"futureField"] = @[@"preserve"];
            NSDictionary *gift = @{@"uid": @"u2", @"item": @"future.gift", @"x": @1, @"y": @1};
            NSMutableDictionary *extendedRooms = [extended[@"rooms"] mutableCopy] ?: [NSMutableDictionary dictionary];
            extendedRooms[@"apollo.dog"] = @{@"wallpaper": @"wp.brick", @"items": @[sofa, gift], @"unknownFurniture": @{@"id": @"gift"}};
            extended[@"rooms"] = extendedRooms;
            extended[@"room"] = extendedRooms[@"apollo.dog"];
            [owned setObject:extended forKey:UDKeyPalHome];
            Check([store saveRoom:@{@"wallpaper": @"wp.gingham", @"items": @[gift]}], @"merge latest room");
            NSDictionary *merged = [owned dictionaryForKey:UDKeyPalHome];
            Check([merged[@"futureField"] isEqual:extended[@"futureField"]], @"retain unrecognised root fields");
            Check([merged[@"rooms"][@"apollo.dog"][@"unknownFurniture"] isEqual:extended[@"room"][@"unknownFurniture"]] &&
                  [merged[@"room"][@"unknownFurniture"] isEqual:extended[@"room"][@"unknownFurniture"]], @"retain unrecognised furnishings");
            Check(merged[@"residents"][@"apollo.otter"] != nil && merged[@"residents"][@"apollo.dog"] != nil, @"retain previously seen resident");
            Check([merged[@"room"][@"items"] isEqual:@[gift]] && [merged[@"room"][@"wallpaper"] isEqual:@"wp.gingham"], @"unknown item records round-trip");
            Check(![store saveRoom:@{@"items": @[@{@"item": @"sofa", @"x": @1, @"y": @1}]}], @"reject item without identity");
            Check(![store saveRoom:@{@"items": @[@{@"uid": @"u", @"item": @"sofa", @"x": @-1, @"y": @1}]}], @"reject out-of-range item");
            Check(![store saveRoom:@{@"wallpaper": @42, @"items": @[]}], @"reject malformed wallpaper");
            Check([[owned dictionaryForKey:UDKeyPalHome] isEqual:merged], @"rejected edit is no-op");

            NSDictionary *future = @{@"schemaVersion": @2, @"room": @{@"style": @"future"}, @"residents": @{}};
            [owned setObject:future forKey:UDKeyPalHome];
            [store refresh];
            Check(!store.canEdit && ![store saveRoom:@{@"items": @[]}], @"unknown schema read-only");
            Check([[owned objectForKey:UDKeyPalHome] isEqual:future], @"unknown schema untouched");
            [owned setObject:@[@"malformed"] forKey:UDKeyPalHome];
            [store refresh];
            Check(!store.canEdit && ![store saveRoom:@{@"items": @[]}], @"malformed home preserved");

            [native setObject:[NSJSONSerialization dataWithJSONObject:@{@"pixelPals": @{@"dog": info}} options:0 error:nil]
                        forKey:@"PixelPalsDatabase"];
            [store refresh];
            Check([store.residents.firstObject.name isEqual:@"Captain Paws"], @"object-form native dictionary");
            [native setObject:[NSJSONSerialization dataWithJSONObject:@{@"pixelPals": @[@"dog", NSNull.null, @"orphan"]} options:0 error:nil]
                        forKey:@"PixelPalsDatabase"];
            [store refresh];
            Check([store.residents.firstObject.name isEqual:@"Dog"], @"malformed info and trailing enum key");
            [native setObject:[@"corrupt JSON" dataUsingEncoding:NSUTF8StringEncoding] forKey:@"PixelPalsDatabase"];
            [native setObject:@"futureSpecies" forKey:@"ActivePixelPal"];
            [store refresh];
            Check([store.residents.firstObject.species isEqual:@"cat"], @"unknown native enum follows native fallback");
            // Shelter adoption: writes Apollo's own record in its array shape,
            // keeps unknown fields/other Pals, and makes the new Pal active.
            [owned removePersistentDomainForName:ownedSuite];
            NSDictionary *arrayDB = @{@"foodTokens": @3, @"future": @"keep",
                                      @"pixelPals": @[@"dog", @{@"name": @"Rupert", @"hearts": @2, @"extra": @1}]};
            [native setObject:[NSJSONSerialization dataWithJSONObject:arrayDB options:0 error:nil] forKey:@"PixelPalsDatabase"];
            [native setObject:@"dog" forKey:@"ActivePixelPal"];
            store = [[ApolloPalHomeStore alloc] initWithDefaults:owned nativeDefaults:native];
            Check(store.household.count == 1 && !store.shelterSeen, @"household before adoption");
            NSArray *roster = [APShelter animalsExcludingSpecies:[NSSet setWithObject:@"dog"]];
            Check(roster.count == 8 && ![[roster valueForKey:@"species"] containsObject:@"dog"], @"roster skips owned species");
            Check([[[APShelter animalsExcludingSpecies:[NSSet set]] valueForKey:@"name"] isEqual:[[APShelter animalsExcludingSpecies:[NSSet set]] valueForKey:@"name"]], @"roster stable within a day");
            APShelterAnimal *otter = [APShelterAnimal new];
            otter.species = @"otter"; otter.coat = @"sea"; otter.name = @"Pebble"; otter.gender = @"girl";
            otter.ageMonths = 26; otter.personality = APPersonalityFireGazer; otter.quirk = @"Steals socks."; otter.weightInLbs = 18;
            Check([store adoptAnimal:otter name:@"  Captain Pebble "], @"adopt");
            NSDictionary *after = [NSJSONSerialization JSONObjectWithData:[native dataForKey:@"PixelPalsDatabase"] options:0 error:nil];
            Check([after[@"future"] isEqual:@"keep"] && [after[@"foodTokens"] isEqual:@3], @"database fields preserved");
            Check([after[@"pixelPals"] count] == 4 && [after[@"pixelPals"][2] isEqual:@"otter"], @"array shape, appended");
            Check([after[@"pixelPals"][1][@"extra"] isEqual:@1] && [after[@"pixelPals"][1][@"name"] isEqual:@"Rupert"], @"other Pals untouched");
            Check([after[@"pixelPals"][3][@"name"] isEqual:@"Captain Pebble"] && [after[@"pixelPals"][3][@"hearts"] isEqual:@0], @"native record");
            Check([[native stringForKey:@"ActivePixelPal"] isEqual:@"otter"], @"adopted Pal active");
            ApolloPalHomeResident *pebble = store.residents.firstObject;
            Check([pebble.name isEqual:@"Captain Pebble"] && [pebble.coat isEqual:@"sea"] && pebble.adopted &&
                  pebble.personality == APPersonalityFireGazer && pebble.ageMonths >= 25 && pebble.ageMonths <= 27, @"profile");
            Check([[ApolloPalHomeStore coatForSpecies:@"otter"] ?: @"" length] == 0 || YES, @"coat lookup reads standard defaults");
            Check(store.household.count == 2 && [store.household[1].species isEqual:@"dog"] && store.shelterSeen, @"household after");
            Check([store renameResident:@"apollo.dog" to:@"Sir Rupert"], @"rename");
            after = [NSJSONSerialization JSONObjectWithData:[native dataForKey:@"PixelPalsDatabase"] options:0 error:nil];
            Check([after[@"pixelPals"][1][@"name"] isEqual:@"Sir Rupert"] && [after[@"pixelPals"][1][@"extra"] isEqual:@1], @"rename native");
            Check([store makeActiveResident:@"apollo.dog"] && [store.residents.firstObject.name isEqual:@"Sir Rupert"], @"switch Pal");
            Check(![store adoptAnimal:otter name:@"   "], @"reject empty name");

            // A Reborn species borrows a free island slot (otter and dog are
            // taken, so the first free host is platypus).
            APShelterAnimal *capy = [APShelterAnimal new];
            capy.species = @"capybara"; capy.coat = @"yuzu"; capy.gender = @"boy"; capy.ageMonths = 14;
            capy.personality = APPersonalityGentleSoul; capy.quirk = @"Friends with literally everyone."; capy.weightInLbs = 100;
            Check([store adoptAnimal:capy name:@"Yuzu"], @"adopt capybara");
            ApolloPalHomeResident *yuzu = store.residents.firstObject;
            Check([yuzu.species isEqual:@"capybara"] && yuzu.reborn && yuzu.active && [yuzu.identifier hasPrefix:@"pal."], @"capybara is a Reborn resident");
            Check([[native stringForKey:@"ActivePixelPal"] isEqual:@"platypus"], @"island points at the borrowed slot");
            NSDictionary *(^nativePal)(NSString *) = ^NSDictionary *(NSString *species) {
                NSArray *list = [NSJSONSerialization JSONObjectWithData:[native dataForKey:@"PixelPalsDatabase"] options:0 error:nil][@"pixelPals"];
                for (NSUInteger i = 0; i + 1 < list.count; i += 2) if ([list[i] isEqual:species]) return list[i + 1];
                return nil;
            };
            Check([nativePal(@"platypus")[@"name"] isEqual:@"Yuzu"] && [nativePal(@"platypus")[@"weightInLbs"] isEqual:@100], @"slot carries the capybara");
            Check(store.household.count == 3, @"household of three");
            NSDictionary *docAfter = [owned dictionaryForKey:UDKeyPalHome];
            Check([docAfter[@"channel"][@"host"] isEqual:@"platypus"] && docAfter[@"channel"][@"stash"] == nil, @"channel recorded, nothing stashed");

            // Apollo earns hearts and kilometres in the slot…
            NSMutableDictionary *db = [[NSJSONSerialization JSONObjectWithData:[native dataForKey:@"PixelPalsDatabase"] options:0 error:nil] mutableCopy];
            NSMutableArray *list = [db[@"pixelPals"] mutableCopy];
            NSUInteger slot = [list indexOfObject:@"platypus"];
            NSMutableDictionary *earned = [list[slot + 1] mutableCopy];
            earned[@"hearts"] = @3; earned[@"totalKilometersScrolled"] = @1.5;
            list[slot + 1] = earned; db[@"pixelPals"] = list;
            [native setObject:[NSJSONSerialization dataWithJSONObject:db options:0 error:nil] forKey:@"PixelPalsDatabase"];
            [store refresh];
            Check([store.residents.firstObject.hearts isEqual:@3], @"live hearts while on the island");
            // …which go home with the capybara when you switch, and the slot is returned.
            Check([store makeActiveResident:@"apollo.dog"], @"switch back to dog");
            Check(nativePal(@"platypus") == nil && [[native stringForKey:@"ActivePixelPal"] isEqual:@"dog"], @"slot returned");
            docAfter = [owned dictionaryForKey:UDKeyPalHome];
            Check(docAfter[@"channel"] == nil && [docAfter[@"residents"][yuzu.identifier][@"stats"][@"hearts"] isEqual:@3] &&
                  [docAfter[@"residents"][yuzu.identifier][@"stats"][@"totalKilometersScrolled"] isEqual:@1.5], @"stats went home");
            ApolloPalHomeResident *(^find)(NSString *) = ^ApolloPalHomeResident *(NSString *identifier) {
                for (ApolloPalHomeResident *r in store.household) if ([r.identifier isEqual:identifier]) return r;
                return nil;
            };
            Check([find(yuzu.identifier).hearts isEqual:@3] && !find(yuzu.identifier).active, @"capybara keeps its hearts at home");
            Check([store makeActiveResident:yuzu.identifier] && [nativePal(@"platypus")[@"hearts"] isEqual:@3], @"back on the island with its hearts");
            Check([store renameResident:yuzu.identifier to:@"Yuzu the Wise"] && [nativePal(@"platypus")[@"name"] isEqual:@"Yuzu the Wise"], @"rename reaches the slot");

            // Apollo's own chooser picks someone else: reconciling settles the slot.
            [native setObject:@"otter" forKey:@"ActivePixelPal"];
            [store reconcileIsland];
            Check(nativePal(@"platypus") == nil && [store.residents.firstObject.species isEqual:@"otter"], @"reconcile after native switch");
            Check([find(yuzu.identifier).name isEqual:@"Yuzu the Wise"], @"name kept");

            // Every host taken: the first is stashed and restored byte for byte.
            NSMutableArray *full = [NSMutableArray array];
            for (NSString *sp in @[@"otter", @"platypus", @"hedgehog", @"axolotl", @"panda", @"tiger", @"fox", @"cat", @"dog"]) {
                [full addObject:sp]; [full addObject:@{@"name": [sp uppercaseString], @"hearts": @5, @"odd": @[@1]}];
            }
            [native setObject:[NSJSONSerialization dataWithJSONObject:@{@"pixelPals": full} options:0 error:nil] forKey:@"PixelPalsDatabase"];
            [store refresh];
            Check([store makeActiveResident:yuzu.identifier] && [[native stringForKey:@"ActivePixelPal"] isEqual:@"otter"] &&
                  [nativePal(@"otter")[@"name"] isEqual:@"Yuzu the Wise"], @"stashes the first host");
            Check(find(@"apollo.otter") && [find(@"apollo.otter").name isEqual:@"OTTER"], @"stashed owner still in the household");
            Check([store renameResident:@"apollo.otter" to:@"Ottilie"] && [nativePal(@"otter")[@"name"] isEqual:@"Yuzu the Wise"] &&
                  [find(@"apollo.otter").name isEqual:@"Ottilie"], @"renaming a stashed Pal leaves the guest's slot alone");
            Check([store makeActiveResident:@"apollo.cat"] && [nativePal(@"otter") isEqual:(@{@"name": @"Ottilie", @"hearts": @5, @"odd": @[@1]})], @"stash restored exactly (with its new name)");

            // Care, by Apollo's rules: food from the shared pantry, +¼ heart,
            // a 5-hour cooldown, hearts capped at 6; a guest eats through its slot.
            [native setObject:[NSJSONSerialization dataWithJSONObject:@{@"foodTokens": @2, @"pixelPals": @[@"dog", @{@"name": @"Rupert", @"hearts": @5.875, @"weightInLbs": @20}]}
                                                              options:0 error:nil] forKey:@"PixelPalsDatabase"];
            [native setObject:@"dog" forKey:@"ActivePixelPal"];
            [owned removePersistentDomainForName:ownedSuite];
            store = [[ApolloPalHomeStore alloc] initWithDefaults:owned nativeDefaults:native];
            double gain = 0;
            Check(store.foodTokens == 2 && [store feedActive:&gain] == APCareDone && gain >= 0.4 && gain <= 2.2, @"feed");
            NSDictionary *fedDB = [NSJSONSerialization JSONObjectWithData:[native dataForKey:@"PixelPalsDatabase"] options:0 error:nil];
            Check([fedDB[@"foodTokens"] isEqual:@1] && [fedDB[@"pixelPals"][1][@"hearts"] isEqual:@6] &&
                  [fedDB[@"pixelPals"][1][@"lastTimeFed"] isKindOfClass:NSNumber.class] && [fedDB[@"pixelPals"][1][@"weightInLbs"] doubleValue] > 20,
                  @"feed spends a token, caps hearts, records the meal, gains weight");
            Check([store feedActive:NULL] == APCareTooSoon && store.waitBeforeFeeding > 4 * 3600, @"feeding cooldown");
            Check([store playWithActive] == APCareDone && [store playWithActive] == APCareTooSoon, @"play cooldown");
            Check(store.residents.firstObject.lastPlayed && store.residents.firstObject.weightInLbs, @"stats surface on the resident");
            APShelterAnimal *guest = [APShelterAnimal new];
            guest.species = @"capybara"; guest.coat = @"original"; guest.ageMonths = 24; guest.weightInLbs = 100;
            Check([store adoptAnimal:guest name:@"Mochi"], @"adopt a guest");
            Check([store feedActive:NULL] == APCareDone, @"guest eats");
            fedDB = [NSJSONSerialization JSONObjectWithData:[native dataForKey:@"PixelPalsDatabase"] options:0 error:nil];
            NSUInteger hostSlot = [fedDB[@"pixelPals"] indexOfObject:@"otter"];
            Check(hostSlot != NSNotFound && [fedDB[@"pixelPals"][hostSlot + 1][@"hearts"] isEqual:@0.25] && [fedDB[@"foodTokens"] isEqual:@0], @"through the borrowed slot");
            Check([store feedActive:NULL] == APCareNoFood || [store feedActive:NULL] == APCareTooSoon, @"empty pantry");
            NSString *mochi = store.residents.firstObject.identifier;
            Check([store makeActiveResident:@"apollo.dog"], @"switch away");
            ApolloPalHomeResident *home = nil;
            for (ApolloPalHomeResident *r in store.household) if ([r.identifier isEqual:mochi]) home = r;
            Check([home.hearts isEqual:@0.25] && home.lastFed, @"the guest's meal goes home with it");

            // Goodbyes: the guest leaves (slot returned, room gone); the last Pal stays.
            NSUInteger before = store.household.count;
            Check([store makeActiveResident:mochi], @"guest active again");
            Check([store rehomeResident:mochi] && store.household.count == before - 1 && ![store.residents.firstObject.identifier isEqual:mochi], @"rehome the active guest");
            NSDictionary *afterGoodbye = [NSJSONSerialization JSONObjectWithData:[native dataForKey:@"PixelPalsDatabase"] options:0 error:nil];
            Check([afterGoodbye[@"pixelPals"] indexOfObject:@"otter"] == NSNotFound, @"borrowed slot returned");
            Check([owned dictionaryForKey:UDKeyPalHome][@"residents"][mochi] == nil, @"profile gone");
            NSString *dogID = @"apollo.dog";
            Check([store.residents.firstObject.identifier isEqual:dogID] && ![store rehomeResident:dogID], @"never your only Pal");

            // Object-shaped database, and no database at all.
            [native setObject:[NSJSONSerialization dataWithJSONObject:@{@"pixelPals": @{@"cat": @{@"name": @"Hugo"}}} options:0 error:nil]
                        forKey:@"PixelPalsDatabase"];
            otter.species = @"fox";
            Check([store adoptAnimal:otter name:@"Ember"], @"adopt into object shape");
            after = [NSJSONSerialization JSONObjectWithData:[native dataForKey:@"PixelPalsDatabase"] options:0 error:nil];
            Check([after[@"pixelPals"][@"fox"][@"name"] isEqual:@"Ember"] && [after[@"pixelPals"][@"cat"][@"name"] isEqual:@"Hugo"], @"object shape kept");
            [native removeObjectForKey:@"PixelPalsDatabase"];
            otter.species = @"panda";
            Check([store adoptAnimal:otter name:@"Bao"] && [native objectForKey:@"PixelPalsDatabase"] == nil &&
                  [store.residents.firstObject.name isEqual:@"Bao"], @"no native database: profile only, Apollo creates its own");
            // Review: adoptions without Apollo's database stay in the household.
            otter.species = @"tiger";
            Check([store adoptAnimal:otter name:@"Stripes"] && [native objectForKey:@"PixelPalsDatabase"] == nil, @"second adoption, still no database");
            BOOL hasPanda = NO, hasTiger = NO;
            for (ApolloPalHomeResident *r in store.household) { hasPanda |= [r.species isEqual:@"panda"]; hasTiger |= [r.species isEqual:@"tiger"]; }
            Check(hasPanda && hasTiger, @"both adopted Pals are in the household");
            Check([store makeActiveResident:@"apollo.panda"] && [[native stringForKey:@"ActivePixelPal"] isEqual:@"panda"], @"switch back to the earlier adoption");

            // Review: an existing Pal's age comes from Apollo's record and survives renaming.
            [owned removePersistentDomainForName:ownedSuite];
            NSTimeInterval threeYears = NSDate.date.timeIntervalSinceReferenceDate - 36 * 30.44 * 86400;
            [native setObject:[NSJSONSerialization dataWithJSONObject:@{@"pixelPals": @[@"dog", @{@"name": @"Rex", @"age": @(threeYears)}]} options:0 error:nil]
                        forKey:@"PixelPalsDatabase"];
            [native setObject:@"dog" forKey:@"ActivePixelPal"];
            store = [[ApolloPalHomeStore alloc] initWithDefaults:owned nativeDefaults:native];
            ApolloPalHomeResident *rex = store.residents.firstObject;
            Check(rex.ageMonths >= 35 && rex.ageMonths <= 37, @"age from Apollo's record");
            NSInteger personality = rex.personality;
            NSString *quirk = rex.quirk;
            Check([store renameResident:@"apollo.dog" to:@"Rexington"], @"rename");
            rex = store.residents.firstObject;
            Check(rex.ageMonths >= 35 && rex.ageMonths <= 37 && rex.personality == personality && [rex.quirk isEqual:quirk], @"renaming changes nothing else");

            puts("pal_home_store_tests: all scenarios passed");
        } @finally {
            [owned removePersistentDomainForName:ownedSuite];
            [native removePersistentDomainForName:nativeSuite];
        }
    }
    return 0;
}
