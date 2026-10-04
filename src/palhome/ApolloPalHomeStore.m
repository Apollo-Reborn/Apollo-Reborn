#import "ApolloPalHomeStore.h"
#import "UserDefaultConstants.h"
#import "ApolloPalHomeShelter.h"
#import "ApolloPixelPalCoats.h"
#import "ApolloPalSpecies.h"
#import <os/log.h>

// Foundation-only (the widget and host tests link this file), so not ApolloLog;
// same subsystem, so it shows up alongside it.
static os_log_t APPalStoreLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("apollofix", "PalHome"); });
    return log;
}
#define ApolloLog(fmt, ...) os_log(APPalStoreLog(), "%{public}s", [[NSString stringWithFormat:@"[ApolloFix] " fmt, ##__VA_ARGS__] UTF8String])

static void ApolloPalHomeNotifyApollo(void);
#import <math.h>

@interface ApolloPalHomeResident ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *species;
@property (nonatomic, copy, readwrite) NSString *speciesTitle;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, strong, readwrite) NSNumber *hearts;
@property (nonatomic, copy, readwrite) NSString *coat;
@property (nonatomic, copy, readwrite) NSString *gender;
@property (nonatomic, readwrite) int ageMonths;
@property (nonatomic, readwrite) NSInteger personality;
@property (nonatomic, copy, readwrite) NSString *quirk;
@property (nonatomic, readwrite) BOOL adopted;
@property (nonatomic, readwrite) BOOL active;
@property (nonatomic, readwrite) BOOL reborn;
@property (nonatomic, strong, readwrite) NSNumber *weightInLbs;
@property (nonatomic, readwrite) double kilometersScrolled;
@property (nonatomic, strong, readwrite) NSDate *lastFed, *lastPlayed;
@end
@implementation ApolloPalHomeResident
@end

const NSTimeInterval APCareCooldown = 5 * 3600;
const NSUInteger APHouseholdLimit = 8;

static NSString *const kApolloPrefix = @"apollo.";
static NSString *const kRebornPrefix = @"pal.";

// Slots a Reborn resident may borrow on the island, best first. All are plain
// walkers with only the standard sheets: no "settings"/"lieN" extras (bat,
// borzoi, butterfly, parrot, raccoon, trex have them) and not superAI, whose
// tap sounds Apollo special-cases (Hopper: sub_10004b698 compares tag 0xb).
static NSArray<NSString *> *APIslandHosts(void) {
    return @[@"otter", @"platypus", @"hedgehog", @"axolotl", @"panda", @"tiger", @"fox", @"cat", @"dog"];
}

// The native record fields that are a Pal's stats (Apollo's PixelPalInfo).
static NSDictionary *APStatsFromInfo(NSDictionary *info) {
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"hearts", @"age", @"weightInLbs", @"totalKilometersScrolled", @"lastTimeFed", @"lastTimePlayedWith"]) {
        id n = info[key];
        if ([n isKindOfClass:NSNumber.class] && isfinite([n doubleValue])) stats[key] = n;
    }
    return stats;
}

static NSObject *APIslandChannelLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSDictionary *sIslandChannel;
static BOOL sIslandChannelLoaded;

static void APInvalidateIslandChannel(void) {
    @synchronized (APIslandChannelLock()) { sIslandChannelLoaded = NO; sIslandChannel = nil; }
}

// A well-formed channel record, or nil.
static NSDictionary *APChannelFromDocument(NSDictionary *document) {
    NSDictionary *channel = [document[@"channel"] isKindOfClass:NSDictionary.class] ? document[@"channel"] : nil;
    NSDictionary *residents = [document[@"residents"] isKindOfClass:NSDictionary.class] ? document[@"residents"] : nil;
    if (!channel || !residents) return nil;
    NSString *host = channel[@"host"], *resident = channel[@"resident"];
    if (![APSpecies isApolloSpecies:host] || ![resident isKindOfClass:NSString.class] || ![resident hasPrefix:kRebornPrefix]) return nil;
    if (![residents[resident] isKindOfClass:NSDictionary.class]) return nil;
    return channel;
}

@interface ApolloPalHomeStore ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) NSUserDefaults *nativeDefaults;
@property (nonatomic, copy) NSDictionary *document;
@property (nonatomic, readwrite) BOOL canEdit;
@property (nonatomic, copy, readwrite) NSDictionary *room;
@property (nonatomic, copy, readwrite) NSArray<ApolloPalHomeResident *> *residents;
@property (nonatomic, copy, readwrite) NSArray<ApolloPalHomeResident *> *household;
@property (nonatomic, readwrite) BOOL shelterSeen;
@property (nonatomic, readwrite) BOOL activeMovedIn;
@end

@implementation ApolloPalHomeStore

- (instancetype)init {
    return [self initWithDefaults:NSUserDefaults.standardUserDefaults
                  nativeDefaults:[[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"]];
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults nativeDefaults:(NSUserDefaults *)nativeDefaults {
    if ((self = [super init])) {
        _defaults = defaults;
        _nativeDefaults = nativeDefaults;
        [self refresh];
    }
    return self;
}

- (NSString *)nativeActiveSpecies {
    id selected = [self.nativeDefaults objectForKey:@"ActivePixelPal"];
    return [APSpecies isApolloSpecies:selected] ? selected : @"cat"; // Apollo's native default
}

- (void)refresh {
    APInvalidateIslandChannel();
    id saved = [self.defaults objectForKey:UDKeyPalHome];
    NSDictionary *document = [saved isKindOfClass:NSDictionary.class] ? saved : nil;
    id version = document[@"schemaVersion"];
    self.canEdit = !saved || ([version isKindOfClass:NSNumber.class] && [version isEqual:@1] &&
                             [document[@"room"] isKindOfClass:NSDictionary.class] &&
                             [document[@"residents"] isKindOfClass:NSDictionary.class]);
    self.document = document ?: @{@"schemaVersion": @1, @"room": @{}, @"residents": @{}};

    self.shelterSeen = [document[@"shelterSeen"] isKindOfClass:NSNumber.class] && [document[@"shelterSeen"] boolValue];

    // Hopper: sub_10074b9fc reads ActivePixelPal; sub_1007e92f4 decodes
    // PixelPalsDatabase. Swift dictionaries with enum keys encode as alternating
    // key/value arrays. Accept the object representation too. Writes go
    // through -writeNativeSpecies:, which keeps whichever shape and every
    // field it finds.
    NSString *nativeActive = [self nativeActiveSpecies];
    NSDictionary<NSString *, NSDictionary *> *pets = [self nativePets];
    NSDictionary *profiles = [self.document[@"residents"] isKindOfClass:NSDictionary.class] ? self.document[@"residents"] : @{};
    NSDictionary *channel = APChannelFromDocument(self.document);
    NSString *host = channel[@"host"];
    BOOL guestActive = channel && [self.document[@"active"] isEqual:channel[@"resident"]] && [nativeActive isEqual:host];

    // Apollo's own Pals: its records, except the borrowed slot is really the
    // stashed owner's (or nobody's).
    NSMutableDictionary *apolloPets = [pets mutableCopy];
    if (channel) {
        if ([channel[@"stash"] isKindOfClass:NSDictionary.class]) apolloPets[host] = channel[@"stash"];
        else [apolloPets removeObjectForKey:host];
    }
    NSMutableArray<ApolloPalHomeResident *> *household = [NSMutableArray array];
    for (NSString *species in [APSpecies apolloIDs]) {
        BOOL isActive = !guestActive && [species isEqual:nativeActive];
        NSString *identifier = [kApolloPrefix stringByAppendingString:species];
        NSDictionary *profile = [profiles[identifier] isKindOfClass:NSDictionary.class] ? profiles[identifier] : @{};
        // Adopted here but Apollo has no record yet (it only creates its
        // database once Pixel Pals is used): still part of the household.
        BOOL adoptedHere = [profile[@"adopted"] isKindOfClass:NSNumber.class];
        if (!isActive && !apolloPets[species] && !adoptedHere) continue;
        ApolloPalHomeResident *resident = [self residentWithID:identifier species:species profile:profile
                                                         stats:apolloPets[species] ?: @{} nameFromStats:YES];
        resident.active = isActive;
        [household addObject:resident];
    }
    // Reborn residents, oldest first.
    NSMutableArray<NSString *> *reborn = [NSMutableArray array];
    for (NSString *identifier in profiles) {
        NSDictionary *profile = profiles[identifier];
        if ([identifier isKindOfClass:NSString.class] && [identifier hasPrefix:kRebornPrefix] && identifier.length <= 64 &&
            [profile isKindOfClass:NSDictionary.class] && [profile[@"species"] isKindOfClass:NSString.class] &&
            [profile[@"species"] length] && [profile[@"species"] length] <= 64) [reborn addObject:identifier];
    }
    [reborn sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double ta = [profiles[a][@"adopted"] isKindOfClass:NSNumber.class] ? [profiles[a][@"adopted"] doubleValue] : 0;
        double tb = [profiles[b][@"adopted"] isKindOfClass:NSNumber.class] ? [profiles[b][@"adopted"] doubleValue] : 0;
        return ta < tb ? NSOrderedAscending : ta > tb ? NSOrderedDescending : [a compare:b];
    }];
    for (NSString *identifier in reborn) {
        NSDictionary *profile = profiles[identifier];
        BOOL onIsland = [channel[@"resident"] isEqual:identifier];
        // On the island, Apollo is counting its hearts/kilometres live in the slot.
        NSDictionary *stats = onIsland && pets[host] ? pets[host]
            : ([profile[@"stats"] isKindOfClass:NSDictionary.class] ? profile[@"stats"] : @{});
        ApolloPalHomeResident *resident = [self residentWithID:identifier species:profile[@"species"] profile:profile
                                                         stats:stats nameFromStats:NO];
        resident.reborn = YES;
        resident.active = guestActive && onIsland;
        [household addObject:resident];
    }
    // Active first.
    NSUInteger activeIndex = NSNotFound;
    for (NSUInteger i = 0; i < household.count && activeIndex == NSNotFound; i++) if (household[i].active) activeIndex = i;
    if (activeIndex != NSNotFound && activeIndex > 0) {
        ApolloPalHomeResident *active = household[activeIndex];
        [household removeObjectAtIndex:activeIndex];
        [household insertObject:active atIndex:0];
    }
    if (household.count > 64) [household removeObjectsInRange:NSMakeRange(64, household.count - 64)];
    self.household = household;
    self.residents = household.count ? @[household.firstObject] : @[];
    [self loadRoomForActive];
}

// Every Pal has a home of their own: document.rooms[residentID]. The single
// room older versions saved (document.room) becomes the home of whoever was
// active the first time this version looks (recorded as roomOwner), and
// document.room keeps mirroring the active Pal's room so an older build still
// shows something sensible. A Pal with no room yet gets moving-in day.
static BOOL APValidRoom(id room) {
    return [room isKindOfClass:NSDictionary.class] && [room[@"items"] isKindOfClass:NSArray.class];
}

- (void)loadRoomForActive {
    NSString *active = self.household.firstObject.identifier;
    NSDictionary *rooms = [self.document[@"rooms"] isKindOfClass:NSDictionary.class] ? self.document[@"rooms"] : @{};
    NSDictionary *legacy = APValidRoom(self.document[@"room"]) ? self.document[@"room"] : nil;
    BOOL migrated = [self.document[@"roomsMigrated"] isKindOfClass:NSNumber.class] && [self.document[@"roomsMigrated"] boolValue];
    if (legacy && !migrated && !self.document[@"roomOwner"] && !rooms.count && active && self.canEdit && [self.defaults objectForKey:UDKeyPalHome]) {
        // One-time migration: the existing room is the current Pal's.
        NSMutableDictionary *document = [self.document mutableCopy];
        document[@"rooms"] = @{active: legacy};
        document[@"roomOwner"] = active;
        document[@"roomsMigrated"] = @YES;
        NSMutableArray *movedIn = [document[@"movedIn"] isKindOfClass:NSArray.class] ? [document[@"movedIn"] mutableCopy] : [NSMutableArray array];
        if (![movedIn containsObject:active]) [movedIn addObject:active];
        document[@"movedIn"] = movedIn;
        [self.defaults setObject:document forKey:UDKeyPalHome];
        self.document = document;
        rooms = document[@"rooms"];
        ApolloLog(@"[PalHome] Rooms: the household room is now %@'s", active);
    }
    self.room = active ? [self roomForResident:active] : nil;
    self.activeMovedIn = active && [self hasMovedIn:active];
}

- (NSDictionary *)roomForResident:(NSString *)identifier {
    NSDictionary *rooms = [self.document[@"rooms"] isKindOfClass:NSDictionary.class] ? self.document[@"rooms"] : @{};
    return [identifier isKindOfClass:NSString.class] && APValidRoom(rooms[identifier]) ? rooms[identifier] : nil;
}

- (BOOL)hasMovedIn:(NSString *)identifier {
    if (!identifier) return NO;
    NSArray *movedIn = [self.document[@"movedIn"] isKindOfClass:NSArray.class] ? self.document[@"movedIn"] : @[];
    // A Pal with a room has moved in, whether or not they saw the show.
    return [self roomForResident:identifier] || [movedIn containsObject:identifier];
}

- (void)markActiveMovedIn { [self markMovedIn:self.household.firstObject.identifier]; }

- (void)markMovedIn:(NSString *)identifier {
    if (!identifier || [self hasMovedIn:identifier]) return;
    [self updateDocument:^(NSMutableDictionary *document) {
        NSMutableArray *movedIn = [document[@"movedIn"] isKindOfClass:NSArray.class] ? [document[@"movedIn"] mutableCopy] : [NSMutableArray array];
        if (![movedIn containsObject:identifier]) [movedIn addObject:identifier];
        document[@"movedIn"] = movedIn;
    }];
}

- (ApolloPalHomeResident *)residentWithID:(NSString *)identifier species:(NSString *)species profile:(NSDictionary *)profile
                                    stats:(NSDictionary *)info nameFromStats:(BOOL)nameFromStats {
    ApolloPalHomeResident *resident = [ApolloPalHomeResident new];
    resident.identifier = identifier;
    resident.species = species;
    resident.speciesTitle = [APShelter titleForSpecies:species];
    BOOL (^validName)(id) = ^BOOL(id name) { return [name isKindOfClass:NSString.class] && [name length] > 0 && [name length] <= 120; };
    id name = nameFromStats ? info[@"name"] : profile[@"name"];
    if (!validName(name)) name = nameFromStats ? profile[@"name"] : info[@"name"];
    resident.name = validName(name) ? name : resident.speciesTitle;
    id hearts = info[@"hearts"];
    if ([hearts isKindOfClass:NSNumber.class] && isfinite([hearts doubleValue]) &&
        [hearts doubleValue] >= 0 && [hearts doubleValue] <= 6) resident.hearts = hearts;
    id weight = info[@"weightInLbs"], km = info[@"totalKilometersScrolled"];
    if ([weight isKindOfClass:NSNumber.class] && isfinite([weight doubleValue]) && [weight doubleValue] >= 0) resident.weightInLbs = weight;
    if ([km isKindOfClass:NSNumber.class] && isfinite([km doubleValue]) && [km doubleValue] >= 0) resident.kilometersScrolled = [km doubleValue];
    // Swift's Codable Date: seconds since the reference date.
    NSDate *(^date)(id) = ^NSDate *(id n) {
        return [n isKindOfClass:NSNumber.class] && isfinite([n doubleValue]) ? [NSDate dateWithTimeIntervalSinceReferenceDate:[n doubleValue]] : nil;
    };
    resident.lastFed = date(info[@"lastTimeFed"]);
    resident.lastPlayed = date(info[@"lastTimePlayedWith"]);
    // Profile: the shelter's, or a stable made-up one for older Pals.
    // Seeded by the resident's id, so renaming never reshuffles it.
    APShelterAnimal *fallback = [APShelter profileForExistingSpecies:species seed:identifier];
    resident.adopted = [profile[@"adopted"] isKindOfClass:NSNumber.class];
    resident.coat = [profile[@"coat"] isKindOfClass:NSString.class] ? profile[@"coat"]
        : ([APPixelPalCoats legacyCoatForSpecies:species] ?: fallback.coat);
    resident.gender = [profile[@"gender"] isKindOfClass:NSString.class] ? profile[@"gender"] : fallback.gender;
    resident.quirk = [profile[@"quirk"] isKindOfClass:NSString.class] ? profile[@"quirk"] : fallback.quirk;
    id personality = profile[@"personality"];
    resident.personality = [personality isKindOfClass:NSNumber.class] && [personality integerValue] >= 0 &&
        [personality integerValue] < APPersonalityCount ? [personality integerValue] : fallback.personality;
    // Age: Apollo's own record first (its `age` is the birthday, seconds since
    // the reference date; adoption writes the shelter birthday there), then
    // the profile's, then the made-up one.
    id born = info[@"age"];
    if (![born isKindOfClass:NSNumber.class] || !isfinite([born doubleValue])) born = profile[@"born"];
    if ([born isKindOfClass:NSNumber.class] && isfinite([born doubleValue])) {
        resident.ageMonths = MAX(1, (int)((NSDate.date.timeIntervalSinceReferenceDate - [born doubleValue]) / (86400 * 30.44)));
    } else {
        resident.ageMonths = fallback.ageMonths;
    }
    return resident;
}

- (nullable ApolloPalHomeResident *)residentWithID:(NSString *)identifier {
    for (ApolloPalHomeResident *resident in self.household) if ([resident.identifier isEqual:identifier]) return resident;
    return nil;
}

#pragma mark - Native Pixel Pals data

- (NSDictionary *)nativeDatabase {
    id data = [self.nativeDefaults objectForKey:@"PixelPalsDatabase"];
    id database = [data isKindOfClass:NSData.class] && [data length] <= 1024 * 1024
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [database isKindOfClass:NSDictionary.class] ? database : nil;
}

- (NSDictionary<NSString *, NSDictionary *> *)nativePets {
    id pets = [self nativeDatabase][@"pixelPals"];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if ([pets isKindOfClass:NSDictionary.class]) {
        for (id key in pets) if ([key isKindOfClass:NSString.class] && [pets[key] isKindOfClass:NSDictionary.class]) result[key] = pets[key];
    } else if ([pets isKindOfClass:NSArray.class]) {
        for (NSUInteger i = 0; i + 1 < [pets count]; i += 2) {
            if ([pets[i] isKindOfClass:NSString.class] && [pets[i + 1] isKindOfClass:NSDictionary.class]) result[pets[i]] = pets[i + 1];
        }
    }
    return result;
}

// Edit one species' native record in place, preserving the database's shape
// (alternating array or object), its order, and every field we don't know.
// `change` returning nil removes the record. Returns NO when there is no
// database yet (Apollo creates it on first use).
- (BOOL)writeNativeSpecies:(NSString *)species create:(BOOL)create change:(NSDictionary *_Nullable (^)(NSMutableDictionary *info))change {
    if (![APSpecies isApolloSpecies:species]) return NO; // never write outside Apollo's enum
    NSMutableDictionary *database = [[self nativeDatabase] mutableCopy];
    if (!database) return NO;
    id pets = database[@"pixelPals"];
    BOOL found = NO;
    if ([pets isKindOfClass:NSArray.class]) {
        NSMutableArray *list = [pets mutableCopy];
        for (NSUInteger i = 0; i + 1 < list.count; i += 2) {
            if (![list[i] isEqual:species] || ![list[i + 1] isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *info = change([list[i + 1] mutableCopy]);
            found = YES;
            if (info) {
                list[i + 1] = info;
            } else {
                [list removeObjectsInRange:NSMakeRange(i, 2)];
                break;
            }
        }
        if (!found && create) {
            NSDictionary *info = change([NSMutableDictionary dictionary]);
            if (info) { [list addObject:species]; [list addObject:info]; }
            found = YES;
        }
        database[@"pixelPals"] = list;
    } else if ([pets isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *map = [pets mutableCopy];
        if ([map[species] isKindOfClass:NSDictionary.class] || create) {
            NSMutableDictionary *info = [map[species] isKindOfClass:NSDictionary.class] ? [map[species] mutableCopy] : [NSMutableDictionary dictionary];
            map[species] = change(info);
            found = YES;
        }
        database[@"pixelPals"] = map;
    } else {
        return NO;
    }
    if (!found) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:database options:0 error:nil];
    if (!data) return NO;
    [self.nativeDefaults setObject:data forKey:@"PixelPalsDatabase"];
    return YES;
}

- (BOOL)updateDocument:(void (^)(NSMutableDictionary *document))change {
    [self refresh];
    if (!self.canEdit) return NO;
    NSMutableDictionary *document = [self.document mutableCopy];
    if (![document[@"room"] isKindOfClass:NSDictionary.class]) document[@"room"] = @{};
    document[@"residents"] = [document[@"residents"] isKindOfClass:NSDictionary.class] ? [document[@"residents"] mutableCopy] : [NSMutableDictionary dictionary];
    change(document);
    [self.defaults setObject:document forKey:UDKeyPalHome];
    [self refresh];
    return YES;
}

- (void)markShelterSeen {
    [self updateDocument:^(NSMutableDictionary *document) { document[@"shelterSeen"] = @YES; }];
}

#pragma mark - Island channel

// Gives the borrowed slot back: its stats go home to the resident, and the
// slot's original record (or its absence) is restored. Doesn't notify.
- (BOOL)settleChannel {
    [self refresh];
    NSDictionary *channel = APChannelFromDocument(self.document);
    if (!channel || !self.canEdit) return NO;
    NSString *host = channel[@"host"], *guest = channel[@"resident"];
    NSDictionary *live = [self nativePets][host];
    ApolloLog(@"[PalHome] Island channel: %@ leaves the %@ slot", guest, host);
    [self updateDocument:^(NSMutableDictionary *document) {
        NSMutableDictionary *residents = document[@"residents"];
        if (live && [residents[guest] isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *profile = [residents[guest] mutableCopy];
            NSMutableDictionary *stats = [profile[@"stats"] isKindOfClass:NSDictionary.class] ? [profile[@"stats"] mutableCopy] : [NSMutableDictionary dictionary];
            [stats addEntriesFromDictionary:APStatsFromInfo(live)];
            profile[@"stats"] = stats;
            residents[guest] = profile;
        }
        [document removeObjectForKey:@"channel"];
        if ([document[@"active"] isEqual:guest]) [document removeObjectForKey:@"active"];
    }];
    NSDictionary *stash = [channel[@"stash"] isKindOfClass:NSDictionary.class] ? channel[@"stash"] : nil;
    [self writeNativeSpecies:host create:stash != nil change:^NSDictionary *(__unused NSMutableDictionary *info) { return stash; }];
    [self refresh];
    return YES;
}

- (void)reconcileIsland {
    [self refresh];
    NSDictionary *channel = APChannelFromDocument(self.document);
    if (!channel) return;
    NSString *host = channel[@"host"], *guest = channel[@"resident"];
    if ([[self nativeActiveSpecies] isEqual:host] && [self.document[@"active"] isEqual:guest]) {
        // Still on the island. If Apollo made the slot's record itself (no
        // database yet when we borrowed it), give it the right name.
        NSString *name = self.household.firstObject.name;
        NSDictionary *live = [self nativePets][host];
        if (live && name && ![live[@"name"] isEqual:name]) {
            [self writeNativeSpecies:host create:NO change:^NSDictionary *(NSMutableDictionary *info) { info[@"name"] = name; return info; }];
        }
        return;
    }
    [self settleChannel];
}

- (BOOL)makeActiveResident:(NSString *)identifier {
    [self refresh];
    if (!self.canEdit) return NO;
    ApolloPalHomeResident *resident = [self residentWithID:identifier];
    if (!resident) return NO;
    if (resident.active) return YES;
    [self settleChannel];
    if (!resident.reborn) {
        [self updateDocument:^(NSMutableDictionary *document) { [document removeObjectForKey:@"active"]; }];
        [self.nativeDefaults setObject:resident.species forKey:@"ActivePixelPal"];
    } else {
        // Borrow a slot nobody's using (or, with all of them taken, stash one).
        NSDictionary *pets = [self nativePets];
        NSString *host = nil;
        NSDictionary *profiles = [self.document[@"residents"] isKindOfClass:NSDictionary.class] ? self.document[@"residents"] : @{};
        for (NSString *candidate in APIslandHosts()) {
            // Free: no Apollo record, and not a Pal of ours waiting for one.
            if (!pets[candidate] && !profiles[[kApolloPrefix stringByAppendingString:candidate]]) { host = candidate; break; }
        }
        if (!host) host = APIslandHosts().firstObject;
        NSDictionary *stash = pets[host];
        NSDictionary *profile = self.document[@"residents"][identifier];
        NSDictionary *stats = [profile[@"stats"] isKindOfClass:NSDictionary.class] ? APStatsFromInfo(profile[@"stats"]) : @{};
        NSString *name = resident.name;
        ApolloLog(@"[PalHome] Island channel: %@ (%@) borrows the %@ slot%@", identifier, resident.species, host, stash ? @" (stashed)" : @"");
        BOOL saved = [self updateDocument:^(NSMutableDictionary *document) {
            NSMutableDictionary *channel = [@{@"host": host, @"resident": identifier} mutableCopy];
            if (stash) channel[@"stash"] = stash;
            document[@"channel"] = channel;
            document[@"active"] = identifier;
        }];
        if (!saved) return NO;
        [self writeNativeSpecies:host create:YES change:^NSDictionary *(NSMutableDictionary *info) {
            [info removeAllObjects];
            [info addEntriesFromDictionary:stats];
            info[@"name"] = name;
            if (!info[@"age"]) info[@"age"] = @(NSDate.date.timeIntervalSinceReferenceDate);
            if (!info[@"weightInLbs"]) info[@"weightInLbs"] = @([APSpecies speciesWithID:resident.species].weightInLbs);
            if (!info[@"hearts"]) info[@"hearts"] = @0;
            if (!info[@"totalKilometersScrolled"]) info[@"totalKilometersScrolled"] = @0;
            return info;
        }];
        [self.nativeDefaults setObject:host forKey:@"ActivePixelPal"];
    }
    [self refresh];
    ApolloPalHomeNotifyApollo();
    return YES;
}

#pragma mark - Care

- (BOOL)islandEnabled {
    id enabled = [self.nativeDefaults objectForKey:@"PixelPalsEnabled"];
    return [enabled isKindOfClass:NSNumber.class] ? [enabled boolValue] : NO;
}

- (void)setIslandEnabled:(BOOL)islandEnabled {
    [self.nativeDefaults setBool:islandEnabled forKey:@"PixelPalsEnabled"];
    ApolloLog(@"[PalHome] Island Pal %@", islandEnabled ? @"on" : @"off");
    ApolloPalHomeNotifyApollo();
}

- (NSInteger)foodTokens {
    id tokens = [self nativeDatabase][@"foodTokens"];
    return [tokens isKindOfClass:NSNumber.class] ? MAX(0, [tokens integerValue]) : 0;
}

static NSTimeInterval APCareWait(NSDate *last) {
    if (!last) return 0;
    NSTimeInterval since = -last.timeIntervalSinceNow;
    return since >= APCareCooldown || since < 0 ? 0 : APCareCooldown - since;
}

- (NSTimeInterval)waitBeforeFeeding { [self refresh]; return APCareWait(self.household.firstObject.lastFed); }
- (NSTimeInterval)waitBeforePlaying { [self refresh]; return APCareWait(self.household.firstObject.lastPlayed); }
- (NSTimeInterval)waitBeforeFeeding:(NSString *)identifier { [self refresh]; return APCareWait([self residentWithID:identifier].lastFed); }
- (NSTimeInterval)waitBeforePlaying:(NSString *)identifier { [self refresh]; return APCareWait([self residentWithID:identifier].lastPlayed); }

// Writes a Pal's live care record, wherever it lives:
//  - an Apollo Pal: its own native record (or, while a guest borrows its
//    slot, the stashed copy in the channel);
//  - a Reborn Pal on the island: the borrowed slot's native record;
//  - a Reborn Pal at home: its stats in the Pal Home document.
// New records get the fields Apollo always writes. Apollo's database is
// created if it doesn't exist yet (its shape: {foodTokens, pixelPals}).
- (BOOL)updateRecordForResident:(ApolloPalHomeResident *)resident change:(void (^)(NSMutableDictionary *info))change {
    if (!resident) return NO;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    NSString *name = resident.name;
    double weight = [APSpecies speciesWithID:resident.species].weightInLbs;
    void (^fill)(NSMutableDictionary *) = ^(NSMutableDictionary *info) {
        if (![info[@"name"] isKindOfClass:NSString.class]) info[@"name"] = name;
        if (![info[@"age"] isKindOfClass:NSNumber.class]) info[@"age"] = @(now);
        if (![info[@"weightInLbs"] isKindOfClass:NSNumber.class]) info[@"weightInLbs"] = @(weight);
        if (![info[@"hearts"] isKindOfClass:NSNumber.class]) info[@"hearts"] = @0;
        if (![info[@"totalKilometersScrolled"] isKindOfClass:NSNumber.class]) info[@"totalKilometersScrolled"] = @0;
        change(info);
    };
    NSDictionary *channel = APChannelFromDocument(self.document);
    NSString *identifier = resident.identifier;
    if (resident.reborn && ![channel[@"resident"] isEqual:identifier]) {
        // At home: the document holds their stats.
        return [self updateDocument:^(NSMutableDictionary *document) {
            NSMutableDictionary *profile = [document[@"residents"][identifier] mutableCopy];
            if (!profile) return;
            NSMutableDictionary *stats = [profile[@"stats"] isKindOfClass:NSDictionary.class] ? [profile[@"stats"] mutableCopy] : [NSMutableDictionary dictionary];
            fill(stats);
            profile[@"stats"] = stats;
            document[@"residents"][identifier] = profile;
        }];
    }
    if (!resident.reborn && [channel[@"host"] isEqual:resident.species]) {
        // A guest is borrowing their slot: their real record is the stash.
        if (![channel[@"stash"] isKindOfClass:NSDictionary.class]) return NO;
        return [self updateDocument:^(NSMutableDictionary *document) {
            NSMutableDictionary *slot = [document[@"channel"] mutableCopy];
            NSMutableDictionary *stash = [slot[@"stash"] mutableCopy];
            fill(stash);
            slot[@"stash"] = stash;
            document[@"channel"] = slot;
        }];
    }
    NSString *species = resident.reborn ? channel[@"host"] : resident.species;
    if (!species) return NO;
    if (![self nativeDatabase]) {
        NSDictionary *fresh = @{@"foodTokens": @0, @"pixelPals": @[]};
        [self.nativeDefaults setObject:[NSJSONSerialization dataWithJSONObject:fresh options:0 error:nil] forKey:@"PixelPalsDatabase"];
    }
    return [self writeNativeSpecies:species create:YES change:^NSDictionary *(NSMutableDictionary *info) {
        fill(info);
        return info;
    }];
}

static NSNumber *APAddHeart(id hearts) {
    double h = [hearts isKindOfClass:NSNumber.class] && isfinite([hearts doubleValue]) ? [hearts doubleValue] : 0;
    return @(MIN(6.0, MAX(0.0, h) + 0.25));
}

- (APCareResult)feedActive:(double *)gain { return [self feedResident:self.household.firstObject.identifier gain:gain]; }
- (APCareResult)playWithActive { return [self playWithResident:self.household.firstObject.identifier]; }

- (APCareResult)feedResident:(NSString *)identifier gain:(double *)gain {
    [self refresh];
    ApolloPalHomeResident *resident = [self residentWithID:identifier];
    if (!resident || !self.canEdit) return APCareUnavailable;
    if (self.foodTokens < 1) return APCareNoFood;
    if (APCareWait(resident.lastFed) > 0) return APCareTooSoon;
    APSpecies *species = [APSpecies speciesWithID:resident.species];
    // Apollo: (random in [0, 1) × 1.8 + 0.4) × the species' factor.
    double grams = (arc4random_uniform(1u << 30) / (double)(1u << 30) * 1.8 + 0.4) * (species.feedWeightFactor ?: 1.0);
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    BOOL saved = [self updateRecordForResident:resident change:^(NSMutableDictionary *info) {
        info[@"hearts"] = APAddHeart(info[@"hearts"]);
        double w = [info[@"weightInLbs"] doubleValue];
        info[@"weightInLbs"] = @(round((w + grams) * 1000) / 1000);
        info[@"lastTimeFed"] = @(now);
    }];
    if (!saved) return APCareUnavailable;
    // Spend the food (Apollo's changeFoodTokens(by: -1)).
    NSMutableDictionary *database = [[self nativeDatabase] mutableCopy];
    database[@"foodTokens"] = @(MAX(0, [database[@"foodTokens"] integerValue] - 1));
    NSData *data = [NSJSONSerialization dataWithJSONObject:database options:0 error:nil];
    if (data) [self.nativeDefaults setObject:data forKey:@"PixelPalsDatabase"];
    if (gain) *gain = grams;
    ApolloLog(@"[PalHome] Fed %@ (+%.2f lbs, %ld food left)", identifier, grams, (long)self.foodTokens);
    [self refresh];
    ApolloPalHomeNotifyApollo();
    return APCareDone;
}

- (APCareResult)playWithResident:(NSString *)identifier {
    [self refresh];
    ApolloPalHomeResident *resident = [self residentWithID:identifier];
    if (!resident || !self.canEdit) return APCareUnavailable;
    if (APCareWait(resident.lastPlayed) > 0) return APCareTooSoon;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    BOOL saved = [self updateRecordForResident:resident change:^(NSMutableDictionary *info) {
        info[@"hearts"] = APAddHeart(info[@"hearts"]);
        info[@"lastTimePlayedWith"] = @(now);
    }];
    if (!saved) return APCareUnavailable;
    ApolloLog(@"[PalHome] Played with %@", identifier);
    [self refresh];
    ApolloPalHomeNotifyApollo();
    return APCareDone;
}

#pragma mark - Goodbyes

- (BOOL)rehomeResident:(NSString *)identifier {
    [self refresh];
    if (!self.canEdit || self.household.count < 2) return NO;
    ApolloPalHomeResident *leaving = [self residentWithID:identifier];
    if (!leaving) return NO;
    // If the departing Pal is on the island through a borrowed slot, or owns
    // the slot a guest is borrowing, give it back *before* choosing who's
    // next, so the replacement's own channel is never dismantled.
    // Pick the replacement from the real household now, before any slot is
    // returned (returning one can briefly point Apollo at an empty slot).
    BOOL wasActive = leaving.active;
    ApolloPalHomeResident *next = nil;
    for (ApolloPalHomeResident *resident in self.household) if (![resident.identifier isEqual:identifier]) { next = resident; break; }
    NSDictionary *channel = APChannelFromDocument(self.document);
    if (channel && ([channel[@"resident"] isEqual:identifier] || (!leaving.reborn && [channel[@"host"] isEqual:leaving.species]))) {
        [self settleChannel];
        [self refresh];
    }
    // Hand the island to the replacement if the departing Pal had it, or if
    // returning a slot left Apollo pointing at an empty one.
    ApolloPalHomeResident *now = self.household.firstObject;
    BOOL emptySlot = now && !now.reborn && ![self nativePets][now.species] && !now.adopted;
    if (wasActive || emptySlot) {
        if (!next || ![self makeActiveResident:next.identifier]) return NO;
        [self refresh];
    }
    ApolloLog(@"[PalHome] %@ (%@) went to a new home", identifier, leaving.species);
    NSDictionary *leavingRoom = [self.document[@"rooms"] isKindOfClass:NSDictionary.class] ? self.document[@"rooms"][identifier] : nil;
    // Not gone for good: keep everything needed to bring them back.
    NSMutableDictionary *archive = [NSMutableDictionary dictionary];
    archive[@"id"] = identifier;
    archive[@"species"] = leaving.species;
    archive[@"name"] = leaving.name;
    archive[@"coat"] = leaving.coat ?: @"original";
    archive[@"at"] = @(NSDate.date.timeIntervalSinceReferenceDate);
    NSDictionary *profile = self.document[@"residents"][identifier];
    if ([profile isKindOfClass:NSDictionary.class]) archive[@"profile"] = profile;
    if (leavingRoom) archive[@"room"] = leavingRoom;
    if (!leaving.reborn && [self nativePets][leaving.species]) archive[@"record"] = [self nativePets][leaving.species];
    [self updateDocument:^(NSMutableDictionary *document) {
        NSMutableArray *rehomed = [document[@"rehomed"] isKindOfClass:NSArray.class] ? [document[@"rehomed"] mutableCopy] : [NSMutableArray array];
        [rehomed insertObject:archive atIndex:0];
        while (rehomed.count > 12) [rehomed removeLastObject];
        document[@"rehomed"] = rehomed;
        [document[@"residents"] removeObjectForKey:identifier];
        if ([document[@"rooms"] isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *rooms = [document[@"rooms"] mutableCopy];
            [rooms removeObjectForKey:identifier];
            document[@"rooms"] = rooms;
        }
        if ([document[@"movedIn"] isKindOfClass:NSArray.class]) {
            NSMutableArray *movedIn = [document[@"movedIn"] mutableCopy];
            [movedIn removeObject:identifier];
            document[@"movedIn"] = movedIn;
        }
        // Their room leaves with them: if the legacy mirror (document.room) is
        // theirs, empty it, and mark migration done so it can never be handed
        // to another Pal as "the household room".
        NSDictionary *mirror = document[@"room"];
        BOOL mirrorIsTheirs = [document[@"roomOwner"] isEqual:identifier] || [mirror isEqual:leavingRoom];
        if (mirrorIsTheirs) document[@"room"] = @{};
        document[@"roomsMigrated"] = @YES;
        if ([document[@"active"] isEqual:identifier]) [document removeObjectForKey:@"active"];
    }];
    if (!leaving.reborn) {
        // Apollo's own record goes too (as if it had never been adopted).
        [self writeNativeSpecies:leaving.species create:NO change:^NSDictionary *(__unused NSMutableDictionary *info) { return nil; }];
    }
    [self refresh];
    ApolloPalHomeNotifyApollo();
    return YES;
}

- (NSArray<NSDictionary *> *)rehomed {
    NSArray *list = [self.document[@"rehomed"] isKindOfClass:NSArray.class] ? self.document[@"rehomed"] : @[];
    NSMutableArray *valid = [NSMutableArray array];
    for (NSDictionary *entry in list) {
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"id"] isKindOfClass:NSString.class] &&
            [entry[@"species"] isKindOfClass:NSString.class] && [entry[@"name"] isKindOfClass:NSString.class]) [valid addObject:entry];
    }
    return valid;
}

- (NSString *)restoreRehomed:(NSString *)identifier {
    [self refresh];
    if (!self.canEdit) return nil;
    NSDictionary *entry = nil;
    for (NSDictionary *candidate in [self rehomed]) if ([candidate[@"id"] isEqual:identifier]) { entry = candidate; break; }
    if (!entry || self.householdFull) return nil;
    [self settleChannel]; // native writes below need the real records
    [self refresh];
    NSString *species = entry[@"species"];
    NSDictionary *profile = [entry[@"profile"] isKindOfClass:NSDictionary.class] ? entry[@"profile"] : @{};
    NSDictionary *record = [entry[@"record"] isKindOfClass:NSDictionary.class] ? entry[@"record"] : nil;
    // Back as an Apollo Pal if their species' slot is free; otherwise (a
    // Reborn species, or you've adopted another of theirs) as a Reborn Pal
    // carrying the same stats.
    BOOL slotFree = [APSpecies isApolloSpecies:species] && ![self nativePets][species] &&
                    ![self.document[@"residents"][[kApolloPrefix stringByAppendingString:species]] isKindOfClass:NSDictionary.class];
    NSString *newID = slotFree ? [kApolloPrefix stringByAppendingString:species]
                    : ([identifier hasPrefix:kRebornPrefix] && ![self residentWithID:identifier] ? identifier
                       : [kRebornPrefix stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]);
    NSMutableDictionary *restored = [profile mutableCopy];
    restored[@"id"] = newID;
    restored[@"species"] = species;
    restored[@"source"] = slotFree ? @"apollo" : @"reborn";
    if (!restored[@"name"]) restored[@"name"] = entry[@"name"];
    if (!slotFree && record && ![restored[@"stats"] isKindOfClass:NSDictionary.class]) restored[@"stats"] = APStatsFromInfo(record);
    BOOL saved = [self updateDocument:^(NSMutableDictionary *document) {
        document[@"residents"][newID] = restored;
        NSMutableArray *rehomed = [document[@"rehomed"] mutableCopy];
        [rehomed filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, __unused id b) { return ![e[@"id"] isEqual:identifier]; }]];
        document[@"rehomed"] = rehomed;
        if ([entry[@"room"] isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *rooms = [document[@"rooms"] isKindOfClass:NSDictionary.class] ? [document[@"rooms"] mutableCopy] : [NSMutableDictionary dictionary];
            rooms[newID] = entry[@"room"];
            document[@"rooms"] = rooms;
        }
        NSMutableArray *movedIn = [document[@"movedIn"] isKindOfClass:NSArray.class] ? [document[@"movedIn"] mutableCopy] : [NSMutableArray array];
        if (![movedIn containsObject:newID]) [movedIn addObject:newID];
        document[@"movedIn"] = movedIn;
    }];
    if (!saved) return nil;
    if (slotFree) {
        if (![self nativeDatabase]) {
            [self.nativeDefaults setObject:[NSJSONSerialization dataWithJSONObject:@{@"foodTokens": @0, @"pixelPals": @[]} options:0 error:nil]
                                    forKey:@"PixelPalsDatabase"];
        }
        NSString *name = restored[@"name"];
        [self writeNativeSpecies:species create:YES change:^NSDictionary *(NSMutableDictionary *info) {
            if (record) [info setDictionary:record];
            if (![info[@"name"] isKindOfClass:NSString.class]) info[@"name"] = name;
            return info;
        }];
    }
    ApolloLog(@"[PalHome] %@ came home as %@", identifier, newID);
    [self refresh];
    ApolloPalHomeNotifyApollo();
    return newID;
}

#pragma mark - Adoption

- (BOOL)isHouseholdFull { return self.household.count >= APHouseholdLimit; }

- (BOOL)adoptAnimal:(APShelterAnimal *)animal name:(NSString *)name {
    NSString *clean = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!clean.length || clean.length > 40 || ![APSpecies speciesWithID:animal.species]) return NO;
    [self refresh];
    if (self.householdFull) return NO;
    [self settleChannel]; // native writes below need the real records
    [self refresh];
    if (!self.canEdit) return NO;
    BOOL ownsSpecies = NO;
    for (ApolloPalHomeResident *resident in self.household) if (!resident.reborn && [resident.species isEqual:animal.species]) ownsSpecies = YES;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    NSDictionary *profile = @{@"species": animal.species, @"name": clean,
                              @"coat": animal.coat ?: @"original", @"gender": animal.gender ?: @"",
                              @"born": @(now - animal.ageMonths * 86400 * 30.44), @"personality": @(animal.personality),
                              @"quirk": animal.quirk ?: @"", @"adopted": @(now)};
    if ([APSpecies isApolloSpecies:animal.species] && !ownsSpecies) {
        // One of Apollo's: it gets Apollo's own record, so its chooser and
        // hearts know them natively.
        NSString *identifier = [kApolloPrefix stringByAppendingString:animal.species];
        BOOL saved = [self updateDocument:^(NSMutableDictionary *document) {
            document[@"shelterSeen"] = @YES;
            NSMutableDictionary *record = [profile mutableCopy];
            record[@"id"] = identifier;
            record[@"source"] = @"apollo";
            document[@"residents"][identifier] = record;
            [document removeObjectForKey:@"active"];
        }];
        if (!saved) return NO;
        [self writeNativeSpecies:animal.species create:YES change:^NSDictionary *(NSMutableDictionary *info) {
            info[@"name"] = clean;
            // Apollo's "Age" is counted from here: their birthday, so the
            // island's card agrees with the shelter's.
            if (![info[@"age"] isKindOfClass:NSNumber.class]) info[@"age"] = profile[@"born"];
            if (![info[@"weightInLbs"] isKindOfClass:NSNumber.class]) info[@"weightInLbs"] = @(animal.weightInLbs);
            if (![info[@"hearts"] isKindOfClass:NSNumber.class]) info[@"hearts"] = @0;
            if (![info[@"totalKilometersScrolled"] isKindOfClass:NSNumber.class]) info[@"totalKilometersScrolled"] = @0;
            return info;
        }];
        [self.nativeDefaults setObject:animal.species forKey:@"ActivePixelPal"];
        [self refresh];
        ApolloPalHomeNotifyApollo();
        return YES;
    }
    // Reborn: a species Apollo doesn't have, or a second of one it does.
    NSString *identifier = [kRebornPrefix stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    BOOL saved = [self updateDocument:^(NSMutableDictionary *document) {
        document[@"shelterSeen"] = @YES;
        NSMutableDictionary *record = [profile mutableCopy];
        record[@"id"] = identifier;
        record[@"source"] = @"reborn";
        record[@"stats"] = @{@"age": profile[@"born"], @"weightInLbs": @(animal.weightInLbs), @"hearts": @0, @"totalKilometersScrolled": @0};
        document[@"residents"][identifier] = record;
    }];
    return saved && [self makeActiveResident:identifier];
}

- (BOOL)renameResident:(NSString *)identifier to:(NSString *)name {
    NSString *clean = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!clean.length || clean.length > 40) return NO;
    [self refresh];
    ApolloPalHomeResident *resident = [self residentWithID:identifier];
    if (!resident) return NO;
    NSDictionary *channel = APChannelFromDocument(self.document);
    // An Apollo Pal whose slot a guest is borrowing lives in the stash right
    // now: rename it there, never in the guest's live record.
    BOOL stashed = !resident.reborn && [channel[@"host"] isEqual:resident.species] && [channel[@"stash"] isKindOfClass:NSDictionary.class];
    BOOL saved = [self updateDocument:^(NSMutableDictionary *document) {
        NSMutableDictionary *residents = document[@"residents"];
        NSMutableDictionary *profile = [residents[identifier] isKindOfClass:NSDictionary.class] ? [residents[identifier] mutableCopy]
            : [@{@"id": identifier, @"source": @"apollo", @"species": resident.species} mutableCopy];
        profile[@"name"] = clean;
        residents[identifier] = profile;
        if (stashed) {
            NSMutableDictionary *slot = [document[@"channel"] mutableCopy];
            NSMutableDictionary *stash = [slot[@"stash"] mutableCopy];
            stash[@"name"] = clean;
            slot[@"stash"] = stash;
            document[@"channel"] = slot;
        }
    }];
    // The name Apollo shows: its own record, or the borrowed slot.
    NSString *nativeSpecies = stashed ? nil : !resident.reborn ? resident.species
        : ([channel[@"resident"] isEqual:identifier] ? channel[@"host"] : nil);
    if (nativeSpecies) {
        [self writeNativeSpecies:nativeSpecies create:NO change:^NSDictionary *(NSMutableDictionary *info) { info[@"name"] = clean; return info; }];
    }
    [self refresh];
    ApolloPalHomeNotifyApollo();
    return saved;
}

// Apollo's island/strip listen for this and reload the active Pal.
static void ApolloPalHomeNotifyApollo(void) {
    APInvalidateIslandChannel();
    void (^post)(void) = ^{ [NSNotificationCenter.defaultCenter postNotificationName:@"PixelPalSettingChanged" object:nil]; };
    if (NSThread.isMainThread) post(); else dispatch_async(dispatch_get_main_queue(), post);
}

+ (BOOL)isPalHomeEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:UDKeyPalHomeEnabled]; }

+ (void)setPalHomeEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:UDKeyPalHomeEnabled];
    ApolloLog(@"[PalHome] Pal Home %@", enabled ? @"on" : @"off (Classic Pixel Pals)");
    if (!enabled) [[ApolloPalHomeStore new] returnToClassic];
    // The Subreddits list's Pal Home shortcut comes and goes with it.
    [NSNotificationCenter.defaultCenter postNotificationName:ApolloFeedShortcutsChangedNotification object:nil];
}

- (void)returnToClassic {
    [self refresh];
    if (!self.canEdit) return;
    // A Reborn Pal on the island goes home (its progress saved), the slot is
    // returned, and one of Apollo's own Pals takes the island.
    NSDictionary *channel = APChannelFromDocument(self.document);
    if (channel) [self settleChannel];
    [self refresh];
    ApolloPalHomeResident *now = self.household.firstObject;
    BOOL real = now && !now.reborn && [self nativePets][now.species];
    if (!real) {
        for (ApolloPalHomeResident *resident in self.household) {
            if (!resident.reborn && [self nativePets][resident.species]) { [self makeActiveResident:resident.identifier]; break; }
        }
    }
    [self refresh];
    ApolloPalHomeNotifyApollo();
}

+ (NSString *)coatForSpecies:(NSString *)species {
    id document = [NSUserDefaults.standardUserDefaults objectForKey:UDKeyPalHome];
    id residents = [document isKindOfClass:NSDictionary.class] ? document[@"residents"] : nil;
    id profile = [residents isKindOfClass:NSDictionary.class] ? residents[[kApolloPrefix stringByAppendingString:species]] : nil;
    id coat = [profile isKindOfClass:NSDictionary.class] ? profile[@"coat"] : nil;
    return [coat isKindOfClass:NSString.class] ? coat : nil;
}

+ (NSDictionary<NSString *, NSString *> *)islandChannel {
    // Reborn species are a Pal Home thing: in Classic, Apollo's island never
    // draws a guest, even if a channel was somehow left behind.
    if (!self.isPalHomeEnabled) return nil;
    @synchronized (APIslandChannelLock()) {
        if (sIslandChannelLoaded) return sIslandChannel;
        sIslandChannelLoaded = YES;
        sIslandChannel = nil;
        id document = [NSUserDefaults.standardUserDefaults objectForKey:UDKeyPalHome];
        NSDictionary *channel = [document isKindOfClass:NSDictionary.class] ? APChannelFromDocument(document) : nil;
        if (!channel) return nil;
        NSDictionary *profile = document[@"residents"][channel[@"resident"]];
        NSString *species = profile[@"species"];
        if (![species isKindOfClass:NSString.class] || ![APSpecies speciesWithID:species]) return nil;
        NSString *coat = [profile[@"coat"] isKindOfClass:NSString.class] ? profile[@"coat"] : @"original";
        sIslandChannel = @{@"host": channel[@"host"], @"species": species, @"coat": coat};
        return sIslandChannel;
    }
}

static BOOL ApolloPalHomeValidString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 64;
}

static BOOL ApolloPalHomeValidItem(id record) {
    if (![record isKindOfClass:NSDictionary.class]) return NO;
    if (!ApolloPalHomeValidString(record[@"item"]) || !ApolloPalHomeValidString(record[@"uid"])) return NO;
    for (NSString *key in @[@"x", @"y"]) {
        id n = record[key];
        if (![n isKindOfClass:NSNumber.class] || !isfinite([n doubleValue]) || [n intValue] < 0 || [n intValue] > 64) return NO;
    }
    return YES;
}

- (BOOL)saveRoom:(NSDictionary *)room { return [self saveRoom:room forResident:nil]; }

- (BOOL)saveRoom:(NSDictionary *)room forResident:(NSString *)identifier {
    if (![room isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"wallpaper", @"floor", @"lighting", @"style"]) {
        if (room[key] && !ApolloPalHomeValidString(room[key])) return NO;
    }
    NSArray *items = room[@"items"];
    if (![items isKindOfClass:NSArray.class] || items.count > 256) return NO;
    for (id item in items) if (!ApolloPalHomeValidItem(item)) return NO;
    [self refresh]; // Merge the latest document, including another screen's edits.
    if (!self.canEdit) return NO;
    NSMutableDictionary *document = [self.document mutableCopy];
    // This Pal's own home. Preserve room fields this version doesn't know about.
    NSString *active = identifier ?: self.household.firstObject.identifier;
    if (!active || ![self residentWithID:active]) return NO;
    NSMutableDictionary *rooms = [document[@"rooms"] isKindOfClass:NSDictionary.class] ? [document[@"rooms"] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *merged = [rooms[active] isKindOfClass:NSDictionary.class] ? [rooms[active] mutableCopy] : [NSMutableDictionary dictionary];
    [merged addEntriesFromDictionary:room];
    rooms[active] = merged;
    document[@"rooms"] = rooms;
    if (!document[@"roomOwner"]) document[@"roomOwner"] = active;
    document[@"roomsMigrated"] = @YES;
    if ([active isEqual:self.household.firstObject.identifier]) document[@"room"] = merged; // mirror for older versions
    // Keep room styling separate from the resident catalogue. Preserve unrecognised
    // residents/fields for forward compatibility; never copy mutable native stats.
    NSMutableDictionary *residents = [document[@"residents"] mutableCopy];
    ApolloPalHomeResident *current = self.residents.firstObject;
    if (current && !residents[current.identifier]) {
        residents[current.identifier] = @{@"id": current.identifier, @"source": @"apollo", @"species": current.species};
    }
    document[@"residents"] = residents;
    [self.defaults setObject:document forKey:UDKeyPalHome];
    [self refresh];
    return YES;
}
@end
