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
    sIconIDs = iconIDs;
    sGroupIndexes = groupIndexes;
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

static NSArray<NSString *> *LineupForDate(TestDate date, NSArray<NSString *> *previous,
                                          NSString *activeIconID, const LGSeasonDef **outSeason,
                                          NSInteger *outSlots) {
    NSInteger daysUntilEnd = NSNotFound;
    const LGSeasonDef *season = SeasonForDate(date, &daysUntilEnd);
    NSArray *tiers = season
        ? @[ Strings(season->iconIDs, season->iconIDCount),
             Strings(season->colorMatchIconIDs, season->colorMatchIconIDCount) ]
        : @[];
    NSInteger slots = ApolloLGSeasonalSlotCount(daysUntilEnd);
    if (outSeason) *outSeason = season;
    if (outSlots) *outSlots = slots;
    return ApolloLGSpotlightLineup(sIconIDs, sGroupIndexes, (NSInteger)kLGIconGroupCount,
                                   kLineupCount, DayIdentifier(date), previous, activeIconID,
                                   tiers, slots);
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

    Require(ApolloLGSeasonalSlotCount(NSNotFound) == 0, @"no slots outside a window");
    Require(ApolloLGSeasonalSlotCount(-1) == 0, @"no slots after the end");
    Require(ApolloLGSeasonalSlotCount(30) == 1, @"one slot a month out");
    Require(ApolloLGSeasonalSlotCount(14) == 1, @"one slot two weeks out");
    Require(ApolloLGSeasonalSlotCount(13) == 2, @"two slots in the second-to-last week");
    Require(ApolloLGSeasonalSlotCount(7) == 2, @"two slots a week out");
    Require(ApolloLGSeasonalSlotCount(6) == 3, @"three slots in the final week");
    Require(ApolloLGSeasonalSlotCount(0) == 3, @"three slots on the holiday");
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
        NSArray<NSString *> *current = ApolloLGSpotlightLineup(sIconIDs, sGroupIndexes,
                                                               (NSInteger)kLGIconGroupCount,
                                                               kLineupCount, DayIdentifier(date),
                                                               previous, active, @[], 0);
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
        Require(groups.count >= MIN(3, kLGIconGroupCount), [where stringByAppendingString:@" spans 3 packs"]);

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
        NSInteger madeAvailable = 0;
        for (NSString *iconID in made) madeAvailable += [iconID isEqualToString:active] ? 0 : 1;
        NSInteger madeShown = 0;
        for (NSString *iconID in [lineup subarrayWithRange:NSMakeRange(0, (NSUInteger)leading)]) {
            madeShown += [made containsObject:iconID] ? 1 : 0;
        }
        Require(madeShown == MIN(madeAvailable, expectedSeasonal),
                [where stringByAppendingString:@" uses every made-for icon before color matches"]);

        // Everything after the seasonal picks still rotates daily.
        for (NSString *iconID in [lineup subarrayWithRange:NSMakeRange((NSUInteger)leading,
                                                                       lineup.count - (NSUInteger)leading)]) {
            Require(![previous containsObject:iconID], [where stringByAppendingString:@" rotates the rest"]);
        }

        Require([lineup isEqualToArray:LineupForDate(date, previous, active, NULL, NULL)],
                [where stringByAppendingString:@" is deterministic"]);
        previous = lineup;
    }
    Require(seasonalDays > 0, @"the registry has at least one season");
}

// Halloween's final week shows both Halloween icons every day, plus one
// orange/black color match.
static void TestHalloweenFinalWeek(void) {
    NSArray<NSString *> *previous = @[];
    TestDate date = { 2026, 10, 25 };
    for (NSInteger i = 0; i < 7; i++, date = NextDay(date)) {
        const LGSeasonDef *season = NULL;
        NSArray<NSString *> *lineup = LineupForDate(date, previous, nil, &season, NULL);
        Require(season && strcmp(season->seasonID, "halloween") == 0, @"late October is Halloween");
        NSSet<NSString *> *lead = [NSSet setWithArray:[lineup subarrayWithRange:NSMakeRange(0, 2)]];
        Require([lead isEqualToSet:[NSSet setWithArray:@[ @"witching-hour", @"helios-count" ]]],
                [NSString stringWithFormat:@"Oct %ld leads with both Halloween icons: %@",
                                           (long)date.day, lineup]);
        Require([@[ @"LG-andru", @"LG-burnt-orange" ] containsObject:lineup[2]],
                [NSString stringWithFormat:@"Oct %ld adds a color match: %@", (long)date.day, lineup]);
        previous = lineup;
    }

    // With Witching Hour already active, Count Helios and both color matches lead.
    TestDate halloween = { 2026, 10, 31 };
    NSArray<NSString *> *lineup = LineupForDate(halloween, @[], @"witching-hour", NULL, NULL);
    Require([lineup[0] isEqualToString:@"helios-count"], @"remaining Halloween icon leads");
    Require([[NSSet setWithArray:[lineup subarrayWithRange:NSMakeRange(1, 2)]]
                isEqualToSet:[NSSet setWithArray:@[ @"LG-andru", @"LG-burnt-orange" ]]],
            @"color matches fill the active icon's slot");
}

// With one slot, early October alternates between the two Halloween icons
// instead of repeating yesterday's.
static void TestSingleSlotRotates(void) {
    NSArray<NSString *> *previous = @[];
    NSString *yesterdayPick = nil;
    TestDate date = { 2026, 10, 1 };
    for (NSInteger i = 0; i < 17; i++, date = NextDay(date)) {
        NSInteger slots = 0;
        NSArray<NSString *> *lineup = LineupForDate(date, previous, nil, NULL, &slots);
        Require(slots == 1, [NSString stringWithFormat:@"Oct %ld has one seasonal slot", (long)date.day]);
        Require([@[ @"witching-hour", @"helios-count" ] containsObject:lineup[0]],
                [NSString stringWithFormat:@"Oct %ld leads with a Halloween icon: %@", (long)date.day, lineup]);
        Require(![lineup[0] isEqualToString:yesterdayPick],
                [NSString stringWithFormat:@"Oct %ld rotates its Halloween icon: %@", (long)date.day, lineup]);
        yesterdayPick = lineup[0];
        previous = lineup;
    }
}

static void PrintCalendar(void) {
    static const TestDate kDates[] = {
        { 2026, 9, 30 }, { 2026, 10, 1 }, { 2026, 10, 9 }, { 2026, 10, 20 }, { 2026, 10, 31 },
        { 2026, 11, 15 }, { 2026, 12, 1 }, { 2026, 12, 15 }, { 2026, 12, 24 },
        { 2027, 2, 10 }, { 2027, 3, 17 }, { 2027, 5, 4 }, { 2027, 6, 5 }, { 2027, 6, 28 }, { 2027, 7, 1 },
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
        TestSingleSlotRotates();
        if (argc > 1 && strcmp(argv[1], "--calendar") == 0) PrintCalendar();
        NSLog(@"liquid_glass_spotlight_tests passed");
    }
    return 0;
}
