#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdlib.h>
#import "ApolloLiquidGlassSpotlight.h"
#import "LiquidGlassIconPreviews.gen.h"

enum { kLineupCount = 5 };

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"LiquidGlassSpotlightTestFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

#pragma mark - Registry from the generated header

static NSArray<NSString *> *sIconIDs;
static NSArray<NSNumber *> *sGroupIndexes;
static NSDictionary<NSString *, NSNumber *> *sGroupForIconID;
// Holiday-only (Standard-pack) icons -> their own pack index, as the picker
// builds it: kLGIconGroupCount + LGStandardPack (originals 0, community 1,
// ultra 2, sekrit 3).
static NSDictionary<NSString *, NSNumber *> *sStandardGroups;

static NSInteger StandardPackIndex(const char *name) {
    if (strcmp(name, "originals") == 0) return 0;
    if (strcmp(name, "community") == 0) return 1;
    if (strcmp(name, "ultra") == 0) return 2;
    if (strcmp(name, "sekrit") == 0) return 3;
    return -1;
}

static void LoadRegistry(void) {
    NSMutableArray<NSString *> *iconIDs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *groupIndexes = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *groupForIconID = [NSMutableDictionary dictionary];
    for (size_t gi = 0; gi < kLGIconGroupCount; gi++) {
        for (size_t ri = 0; ri < kLGIconGroups[gi].entryCount; ri++) {
            NSString *iconID = @(kLGIconGroups[gi].entries[ri].iconID);
            [iconIDs addObject:iconID];
            [groupIndexes addObject:@(gi)];
            groupForIconID[iconID] = @(gi);
        }
    }
    NSMutableDictionary<NSString *, NSNumber *> *standardGroups = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < kLGNativeIconCount; i++) {
        NSInteger pack = StandardPackIndex(kLGNativeIcons[i].standardPack);
        Require(pack >= 0, @"native icons name a known Standard pack");
        standardGroups[@(kLGNativeIcons[i].iconID)] = @((NSInteger)kLGIconGroupCount + pack);
    }
    for (size_t i = 0; i < kLGStandardPackEntries_ultraCount; i++) {
        standardGroups[@(kLGStandardPackEntries_ultra[i].iconID)] = @((NSInteger)kLGIconGroupCount + 2);
    }
    sIconIDs = iconIDs;
    sGroupIndexes = groupIndexes;
    sStandardGroups = standardGroups;
    [groupForIconID addEntriesFromDictionary:standardGroups];
    sGroupForIconID = groupForIconID;
}

static NSArray<NSString *> *Strings(const char *const *values, size_t count) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (size_t i = 0; i < count; i++) [result addObject:@(values[i])];
    return result;
}

#pragma mark - The pre-seasons generator, verbatim apart from its inputs

static uint64_t LegacyRandomNext(uint64_t *state) {
    uint64_t value = *state;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    *state = value;
    return value * UINT64_C(2685821657736338717);
}

typedef struct {
    NSInteger icon;
    NSInteger groupIndex;
    BOOL selected;
} LegacyCandidate;

static NSArray<NSString *> *LegacyLineup(NSInteger dayIdentifier, NSSet<NSString *> *excludedIDs) {
    NSInteger groupCount = (NSInteger)kLGIconGroupCount;
    NSInteger capacity = (NSInteger)sIconIDs.count;
    LegacyCandidate *candidates = (LegacyCandidate *)calloc((size_t)capacity, sizeof(LegacyCandidate));
    NSInteger candidateCount = 0;
    for (NSInteger i = 0; i < capacity; i++) {
        if ([excludedIDs containsObject:sIconIDs[(NSUInteger)i]]) continue;
        candidates[candidateCount++] = (LegacyCandidate){ i, sGroupIndexes[(NSUInteger)i].integerValue, NO };
    }

    uint64_t randomState = ((uint64_t)dayIdentifier << 32) ^ UINT64_C(0xA90110DA17F34D6B);
    for (NSInteger i = candidateCount - 1; i > 0; i--) {
        NSInteger j = (NSInteger)(LegacyRandomNext(&randomState) % (uint64_t)(i + 1));
        LegacyCandidate swap = candidates[i];
        candidates[i] = candidates[j];
        candidates[j] = swap;
    }

    NSInteger *groupOrder = (NSInteger *)calloc((size_t)groupCount, sizeof(NSInteger));
    for (NSInteger gi = 0; gi < groupCount; gi++) groupOrder[gi] = gi;
    for (NSInteger i = groupCount - 1; i > 0; i--) {
        NSInteger j = (NSInteger)(LegacyRandomNext(&randomState) % (uint64_t)(i + 1));
        NSInteger swap = groupOrder[i];
        groupOrder[i] = groupOrder[j];
        groupOrder[j] = swap;
    }

    NSInteger selected[kLineupCount] = { 0 };
    NSInteger selectedCount = 0;
    NSInteger requiredGroups = MIN(3, groupCount);
    for (NSInteger orderIndex = 0; orderIndex < groupCount && selectedCount < requiredGroups; orderIndex++) {
        NSInteger wantedGroup = groupOrder[orderIndex];
        for (NSInteger ci = 0; ci < candidateCount; ci++) {
            if (!candidates[ci].selected && candidates[ci].groupIndex == wantedGroup) {
                candidates[ci].selected = YES;
                selected[selectedCount++] = candidates[ci].icon;
                break;
            }
        }
    }
    for (NSInteger ci = 0; ci < candidateCount && selectedCount < kLineupCount; ci++) {
        if (candidates[ci].selected) continue;
        candidates[ci].selected = YES;
        selected[selectedCount++] = candidates[ci].icon;
    }
    for (NSInteger i = selectedCount - 1; i > 0; i--) {
        NSInteger j = (NSInteger)(LegacyRandomNext(&randomState) % (uint64_t)(i + 1));
        NSInteger swap = selected[i];
        selected[i] = selected[j];
        selected[j] = swap;
    }

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSInteger i = 0; i < selectedCount; i++) [result addObject:sIconIDs[(NSUInteger)selected[i]]];
    free(groupOrder);
    free(candidates);
    return result;
}

#pragma mark - Calendar walking

typedef struct {
    NSInteger year;
    NSInteger month;
    NSInteger day;
} TestDate;

static TestDate NextDay(TestDate date) {
    static const NSInteger kDaysInMonth[] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    BOOL leap = (date.year % 4 == 0 && date.year % 100 != 0) || date.year % 400 == 0;
    NSInteger monthDays = kDaysInMonth[date.month - 1] + (date.month == 2 && leap ? 1 : 0);
    if (++date.day > monthDays) {
        date.day = 1;
        if (++date.month > 12) {
            date.month = 1;
            date.year++;
        }
    }
    return date;
}

static NSInteger DayIdentifier(TestDate date) {
    return date.year * 10000 + date.month * 100 + date.day;
}

static const LGSeasonDef *SeasonForDate(TestDate date, NSInteger *daysUntilEnd) {
    for (size_t i = 0; i < kLGSeasonCount; i++) {
        const LGSeasonDef *season = &kLGSeasons[i];
        NSInteger left = ApolloLGSeasonDaysUntilEnd(date.year, date.month, date.day,
                                                    season->startMonth, season->startDay,
                                                    season->endMonth, season->endDay);
        if (left == NSNotFound) continue;
        if (daysUntilEnd) *daysUntilEnd = left;
        return season;
    }
    return NULL;
}

// The made-for icons of every season except `season` (the picker's
// everyday-pick exclusion while a holiday is on).
static NSSet<NSString *> *OtherHolidayIcons(const LGSeasonDef *season) {
    NSMutableSet<NSString *> *result = [NSMutableSet set];
    if (!season) return result;
    for (size_t i = 0; i < kLGSeasonCount; i++) {
        if (&kLGSeasons[i] == season) continue;
        [result addObjectsFromArray:Strings(kLGSeasons[i].iconIDs, kLGSeasons[i].iconIDCount)];
    }
    return result;
}

static NSArray<NSString *> *LineupForDate(TestDate date, NSArray<NSString *> *previous,
                                          NSString *activeIconID, const LGSeasonDef **outSeason,
                                          NSInteger *outSlots) {
    NSInteger daysUntilEnd = NSNotFound;
    const LGSeasonDef *season = SeasonForDate(date, &daysUntilEnd);
    NSArray *tiers = season
        ? @[ Strings(season->iconIDs, season->iconIDCount),
             Strings(season->colorMatchIconIDs, season->colorMatchIconIDCount) ]
        : @[];
    NSInteger slots = ApolloLGSeasonalSlotCount(daysUntilEnd, kLineupCount);
    if (outSeason) *outSeason = season;
    if (outSlots) *outSlots = slots;
    return ApolloLGSpotlightLineup(sIconIDs, sGroupIndexes, (NSInteger)kLGIconGroupCount,
                                   kLineupCount, DayIdentifier(date), previous, activeIconID,
                                   tiers, sStandardGroups, OtherHolidayIcons(season), slots);
}

#pragma mark - Tests

static void TestWindowArithmetic(void) {
    Require(ApolloLGSeasonDaysUntilEnd(2026, 10, 31, 10, 1, 10, 31) == 0, @"holiday itself is 0 days out");
    Require(ApolloLGSeasonDaysUntilEnd(2026, 10, 1, 10, 1, 10, 31) == 30, @"first day of October");
    Require(ApolloLGSeasonDaysUntilEnd(2026, 9, 30, 10, 1, 10, 31) == NSNotFound, @"day before the window");
    Require(ApolloLGSeasonDaysUntilEnd(2026, 11, 1, 10, 1, 10, 31) == NSNotFound, @"day after the window");
    Require(ApolloLGSeasonDaysUntilEnd(2026, 7, 1, 7, 1, 7, 1) == 0, @"one-day window");
    Require(ApolloLGSeasonDaysUntilEnd(2026, 12, 1, 12, 1, 12, 25) == 24, @"Christmas window start");
    Require(ApolloLGSeasonDaysUntilEnd(2028, 2, 28, 2, 20, 3, 10) == 11, @"counts Feb 29 in a leap year");
    Require(ApolloLGSeasonDaysUntilEnd(2027, 2, 28, 2, 20, 3, 10) == 10, @"no Feb 29 in a common year");

    Require(ApolloLGSeasonalSlotCount(NSNotFound, 5) == 0, @"no slots outside a window");
    Require(ApolloLGSeasonalSlotCount(-1, 5) == 0, @"no slots after the end");
    Require(ApolloLGSeasonalSlotCount(30, 5) == 2, @"two slots a month out");
    Require(ApolloLGSeasonalSlotCount(14, 5) == 2, @"two slots two weeks out");
    Require(ApolloLGSeasonalSlotCount(13, 5) == 3, @"three slots in the second-to-last week");
    Require(ApolloLGSeasonalSlotCount(7, 5) == 3, @"three slots a week out");
    Require(ApolloLGSeasonalSlotCount(6, 5) == 5, @"every slot in the final week");
    Require(ApolloLGSeasonalSlotCount(0, 5) == 5, @"every slot on the holiday");
    Require(ApolloLGSeasonalSlotCount(0, 2) == 2 && ApolloLGSeasonalSlotCount(30, 1) == 1,
            @"never more slots than the lineup has");
}

// Off-season days must keep producing exactly the pre-seasons lineups.
static void TestMatchesLegacyWithoutSeason(void) {
    TestDate date = { 2026, 1, 1 };
    NSArray<NSString *> *previous = @[];
    NSInteger compared = 0;
    for (NSInteger i = 0; i < 730; i++, date = NextDay(date)) {
        NSString *active = (i % 3 == 0) ? sIconIDs[(NSUInteger)(i * 7) % sIconIDs.count] : nil;
        NSMutableSet<NSString *> *excluded = [NSMutableSet setWithArray:previous];
        if (active) [excluded addObject:active];
        NSArray<NSString *> *legacy = LegacyLineup(DayIdentifier(date), excluded);
        // The holiday-only icons are passed too: without a season they must
        // not change a thing.
        NSArray<NSString *> *current = ApolloLGSpotlightLineup(sIconIDs, sGroupIndexes,
                                                               (NSInteger)kLGIconGroupCount,
                                                               kLineupCount, DayIdentifier(date),
                                                               previous, active, @[], sStandardGroups,
                                                               [NSSet set], 0);
        Require([legacy isEqualToArray:current],
                [NSString stringWithFormat:@"%ld: %@ != legacy %@", (long)DayIdentifier(date),
                                           current, legacy]);
        previous = current;
        compared++;
    }
    Require(compared == 730, @"compared two years of lineups");
}

static void TestTwoYearsOfLineups(void) {
    TestDate date = { 2026, 1, 1 };
    NSArray<NSString *> *previous = @[];
    NSInteger seasonalDays = 0;
    for (NSInteger i = 0; i < 730; i++, date = NextDay(date)) {
        // Rotate an active icon through the registry, including holiday ones.
        NSString *active = (i % 5 == 0) ? nil : sIconIDs[(NSUInteger)(i * 11) % sIconIDs.count];
        const LGSeasonDef *season = NULL;
        NSInteger slots = 0;
        NSArray<NSString *> *lineup = LineupForDate(date, previous, active, &season, &slots);
        NSString *where = [NSString stringWithFormat:@"%ld %@", (long)DayIdentifier(date), lineup];

        Require(lineup.count == (NSUInteger)kLineupCount, [where stringByAppendingString:@" has 5 icons"]);
        Require([NSSet setWithArray:lineup].count == lineup.count, [where stringByAppendingString:@" is unique"]);
        Require(![lineup containsObject:active], [where stringByAppendingString:@" skips the active icon"]);
        NSMutableIndexSet *groups = [NSMutableIndexSet indexSet];
        for (NSString *iconID in lineup) {
            Require(sGroupForIconID[iconID] != nil, [where stringByAppendingString:@" uses registered icons"]);
            [groups addIndex:sGroupForIconID[iconID].unsignedIntegerValue];
        }

        NSArray<NSString *> *made = season ? Strings(season->iconIDs, season->iconIDCount) : @[];
        NSArray<NSString *> *matches = season
            ? Strings(season->colorMatchIconIDs, season->colorMatchIconIDCount) : @[];
        NSMutableArray<NSString *> *available = [NSMutableArray array];
        for (NSString *iconID in [made arrayByAddingObjectsFromArray:matches]) {
            if (![iconID isEqualToString:active]) [available addObject:iconID];
        }
        NSInteger expectedSeasonal = MIN(slots, (NSInteger)available.count);
        if (season) seasonalDays++;

        // The seasonal picks lead, made-for icons before color matches.
        NSInteger leading = 0;
        BOOL sawColorMatch = NO;
        for (NSString *iconID in lineup) {
            if (leading == expectedSeasonal) break;
            BOOL isMade = [made containsObject:iconID];
            Require(isMade || [matches containsObject:iconID],
                    [where stringByAppendingString:@" leads with the holiday icons"]);
            Require(!(isMade && sawColorMatch), [where stringByAppendingString:@" puts made-for icons first"]);
            sawColorMatch = sawColorMatch || !isMade;
            leading++;
        }
        Require(leading == expectedSeasonal, [where stringByAppendingString:@" fills its seasonal slots"]);
        // Three packs when there is room: holiday picks count with their packs,
        // and each everyday slot can add one more.
        NSMutableIndexSet *holidayGroups = [NSMutableIndexSet indexSet];
        for (NSString *iconID in [lineup subarrayWithRange:NSMakeRange(0, (NSUInteger)leading)]) {
            [holidayGroups addIndex:sGroupForIconID[iconID].unsignedIntegerValue];
        }
        NSInteger roomForPacks = (NSInteger)holidayGroups.count + (kLineupCount - leading);
        Require((NSInteger)groups.count >= MIN(MIN(3, (NSInteger)kLGIconGroupCount), roomForPacks),
                [where stringByAppendingString:@" spans as many packs as it has room for, up to 3"]);
        NSInteger madeAvailable = 0;
        for (NSString *iconID in made) madeAvailable += [iconID isEqualToString:active] ? 0 : 1;
        NSInteger madeShown = 0;
        for (NSString *iconID in [lineup subarrayWithRange:NSMakeRange(0, (NSUInteger)leading)]) {
            madeShown += [made containsObject:iconID] ? 1 : 0;
        }
        Require(madeShown == MIN(madeAvailable, expectedSeasonal),
                [where stringByAppendingString:@" uses every made-for icon before color matches"]);

        // Everything after the seasonal picks still rotates daily, and never
        // includes a holiday-only (Standard-pack) icon.
        for (NSString *iconID in [lineup subarrayWithRange:NSMakeRange((NSUInteger)leading,
                                                                       lineup.count - (NSUInteger)leading)]) {
            Require(![previous containsObject:iconID], [where stringByAppendingString:@" rotates the rest"]);
            Require(sStandardGroups[iconID] == nil,
                    [where stringByAppendingString:@" keeps Standard-pack icons to holiday picks"]);
            Require(![OtherHolidayIcons(season) containsObject:iconID],
                    [where stringByAppendingString:@" keeps other holidays' icons out of the everyday picks"]);
        }

        Require([lineup isEqualToArray:LineupForDate(date, previous, active, NULL, NULL)],
                [where stringByAppendingString:@" is deterministic"]);
        previous = lineup;
    }
    Require(seasonalDays > 0, @"the registry has at least one season");
}

// Halloween's final week is all Halloween: five of its eight icons a day, the
// ones not shown yesterday always among them.
static void TestHalloweenFinalWeek(void) {
    const LGSeasonDef *halloween = NULL;
    for (size_t i = 0; i < kLGSeasonCount; i++) {
        if (strcmp(kLGSeasons[i].seasonID, "halloween") == 0) halloween = &kLGSeasons[i];
    }
    Require(halloween != NULL, @"icons.json has a Halloween season");
    NSArray<NSString *> *made = Strings(halloween->iconIDs, halloween->iconIDCount);
    Require([made containsObject:@"witching-hour"] && [made containsObject:@"jackopollo"],
            @"Halloween lists Liquid Glass and Apollo icons");

    NSArray<NSString *> *previous = @[];
    TestDate date = { 2026, 10, 25 };
    for (NSInteger i = 0; i < 7; i++, date = NextDay(date)) {
        NSArray<NSString *> *lineup = LineupForDate(date, previous, nil, NULL, NULL);
        for (NSString *iconID in lineup) {
            Require([made containsObject:iconID],
                    [NSString stringWithFormat:@"Oct %ld is all Halloween: %@", (long)date.day, lineup]);
        }
        // Fresh (not shown yesterday) icons go first: all of them when they
        // fit, otherwise every card is a fresh one.
        NSMutableArray<NSString *> *fresh = [NSMutableArray array];
        for (NSString *iconID in made) if (![previous containsObject:iconID]) [fresh addObject:iconID];
        for (NSString *iconID in fresh.count <= (NSUInteger)kLineupCount ? fresh : lineup) {
            Require([lineup containsObject:iconID] && [fresh containsObject:iconID],
                    [NSString stringWithFormat:@"Oct %ld puts fresh icons first (%@): %@", (long)date.day, iconID, lineup]);
        }
        previous = lineup;
    }

    // The active icon is never featured, Standard-pack choices included.
    TestDate day = { 2026, 10, 31 };
    for (NSString *active in @[ @"witching-hour", @"jackopollo", @"poe-the-space-ghost" ]) {
        NSArray<NSString *> *lineup = LineupForDate(day, @[], active, NULL, NULL);
        Require(![lineup containsObject:active], [NSString stringWithFormat:@"skips active %@", active]);
        for (NSString *iconID in lineup) {
            Require([made containsObject:iconID], @"still all Halloween");
        }
    }
}

// Christmas is all Ultra icons. The final week shows five of its seven each day,
// even though that leaves the lineup in one pack.
static void TestChristmasWeek(void) {
    NSArray<NSString *> *previous = @[];
    TestDate date = { 2026, 12, 19 };
    for (NSInteger i = 0; i < 7; i++, date = NextDay(date)) {
        const LGSeasonDef *season = NULL;
        NSInteger slots = 0;
        NSArray<NSString *> *lineup = LineupForDate(date, previous, nil, &season, &slots);
        Require(season && strcmp(season->seasonID, "christmas") == 0 && slots == kLineupCount,
                [NSString stringWithFormat:@"Dec %ld is Christmas week", (long)date.day]);
        NSArray<NSString *> *made = Strings(season->iconIDs, season->iconIDCount);
        Require(made.count == 7 && ![made containsObject:@"LG-calico"], @"Christmas is the seven Christmas icons");
        Require(lineup.count == (NSUInteger)kLineupCount,
                [NSString stringWithFormat:@"Dec %ld still has five cards: %@", (long)date.day, lineup]);
        for (NSString *iconID in lineup) {
            Require([made containsObject:iconID],
                    [NSString stringWithFormat:@"Dec %ld is all Christmas: %@", (long)date.day, lineup]);
        }
        previous = lineup;
    }
}

// Early in the window two cards are Halloween, and with eight icons to rotate
// through they never repeat yesterday's.
static void TestSingleSlotRotates(void) {
    NSArray<NSString *> *previous = @[];
    NSArray<NSString *> *yesterdayPicks = @[];
    TestDate date = { 2026, 10, 1 };
    for (NSInteger i = 0; i < 17; i++, date = NextDay(date)) {
        NSInteger slots = 0;
        const LGSeasonDef *season = NULL;
        NSArray<NSString *> *lineup = LineupForDate(date, previous, nil, &season, &slots);
        Require(slots == 2, [NSString stringWithFormat:@"Oct %ld has two seasonal slots", (long)date.day]);
        NSArray<NSString *> *picks = [lineup subarrayWithRange:NSMakeRange(0, 2)];
        for (NSString *iconID in picks) {
            Require([Strings(season->iconIDs, season->iconIDCount) containsObject:iconID],
                    [NSString stringWithFormat:@"Oct %ld leads with Halloween icons: %@", (long)date.day, lineup]);
            Require(![yesterdayPicks containsObject:iconID],
                    [NSString stringWithFormat:@"Oct %ld rotates its Halloween icons: %@", (long)date.day, lineup]);
        }
        yesterdayPicks = picks;
        previous = lineup;
    }
}

static void PrintCalendar(void) {
    static const TestDate kDates[] = {
        { 2026, 9, 30 }, { 2026, 10, 1 }, { 2026, 10, 9 }, { 2026, 10, 20 }, { 2026, 10, 31 },
        { 2026, 11, 15 }, { 2026, 12, 1 }, { 2026, 12, 15 }, { 2026, 12, 24 },
        { 2027, 2, 10 }, { 2027, 3, 17 }, { 2027, 5, 4 }, { 2027, 6, 5 }, { 2027, 6, 28 }, { 2027, 7, 1 },
        { 2027, 7, 4 },
    };
    for (size_t i = 0; i < sizeof(kDates) / sizeof(kDates[0]); i++) {
        const LGSeasonDef *season = NULL;
        NSInteger slots = 0;
        NSArray<NSString *> *lineup = LineupForDate(kDates[i], @[], nil, &season, &slots);
        printf("%04ld-%02ld-%02ld  %-17s %ld  %s\n", (long)kDates[i].year, (long)kDates[i].month,
               (long)kDates[i].day, season ? season->title : "-", (long)slots,
               [lineup componentsJoinedByString:@", "].UTF8String);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        LoadRegistry();
        TestWindowArithmetic();
        TestMatchesLegacyWithoutSeason();
        TestTwoYearsOfLineups();
        TestHalloweenFinalWeek();
        TestChristmasWeek();
        TestSingleSlotRotates();
        if (argc > 1 && strcmp(argv[1], "--calendar") == 0) PrintCalendar();
        NSLog(@"liquid_glass_spotlight_tests passed");
    }
    return 0;
}
