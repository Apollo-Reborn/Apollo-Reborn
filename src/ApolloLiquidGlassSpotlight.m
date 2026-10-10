#import "ApolloLiquidGlassSpotlight.h"
#import <stdint.h>

// Seeds for the two independent xorshift streams. The base stream keeps the
// pre-seasons seed so a day without seasonal picks reproduces the original
// lineup; seasonal picks draw from their own stream and never shift it.
static const uint64_t kApolloLGSpotlightBaseSalt     = UINT64_C(0xA90110DA17F34D6B);
static const uint64_t kApolloLGSpotlightSeasonalSalt = UINT64_C(0x5EA50A1DA7E5F00D);

// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's
// days_from_civil). Pure arithmetic, so no calendar or time zone is involved.
static NSInteger ApolloLGDaysFromCivil(NSInteger year, NSInteger month, NSInteger day) {
    year -= month <= 2;
    NSInteger era = (year >= 0 ? year : year - 399) / 400;
    NSInteger yearOfEra = year - era * 400;
    NSInteger dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
    NSInteger dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
    return era * 146097 + dayOfEra - 719468;
}

NSInteger ApolloLGSeasonDaysUntilEnd(NSInteger year, NSInteger month, NSInteger day,
                                     NSInteger startMonth, NSInteger startDay,
                                     NSInteger endMonth, NSInteger endDay) {
    NSInteger key = month * 100 + day;
    if (key < startMonth * 100 + startDay || key > endMonth * 100 + endDay) return NSNotFound;
    return ApolloLGDaysFromCivil(year, endMonth, endDay) - ApolloLGDaysFromCivil(year, month, day);
}

NSInteger ApolloLGSeasonalSlotCount(NSInteger daysUntilEnd) {
    if (daysUntilEnd == NSNotFound || daysUntilEnd < 0) return 0;
    if (daysUntilEnd < 7) return 3;
    if (daysUntilEnd < 14) return 2;
    return 1;
}

static uint64_t ApolloLGSpotlightRandomNext(uint64_t *state) {
    uint64_t value = *state;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    *state = value;
    return value * UINT64_C(2685821657736338717);
}

static void ApolloLGSpotlightShuffle(NSMutableArray *values, uint64_t *state) {
    for (NSInteger i = (NSInteger)values.count - 1; i > 0; i--) {
        NSInteger j = (NSInteger)(ApolloLGSpotlightRandomNext(state) % (uint64_t)(i + 1));
        [values exchangeObjectAtIndex:(NSUInteger)i withObjectAtIndex:(NSUInteger)j];
    }
}

NSArray<NSString *> *ApolloLGSpotlightLineup(NSArray<NSString *> *iconIDs,
                                             NSArray<NSNumber *> *groupIndexes,
                                             NSInteger groupCount,
                                             NSInteger lineupCount,
                                             NSInteger dayIdentifier,
                                             NSArray<NSString *> *previousLineup,
                                             NSString *activeIconID,
                                             NSArray<NSArray<NSString *> *> *seasonalTiers,
                                             NSDictionary<NSString *, NSNumber *> *seasonalOnlyGroups,
                                             NSInteger seasonalSlots) {
    if (iconIDs.count != groupIndexes.count || lineupCount <= 0 || groupCount < 0) return @[];

    NSMutableDictionary<NSString *, NSNumber *> *groupForIconID =
        [NSMutableDictionary dictionaryWithCapacity:iconIDs.count + seasonalOnlyGroups.count];
    [seasonalOnlyGroups enumerateKeysAndObjectsUsingBlock:^(NSString *iconID, NSNumber *group, __unused BOOL *stop) {
        groupForIconID[iconID] = group;
    }];
    for (NSUInteger i = 0; i < iconIDs.count; i++) groupForIconID[iconIDs[i]] = groupIndexes[i];
    NSSet<NSString *> *previous = [NSSet setWithArray:previousLineup];

    // Seasonal picks: tier by tier, today's shuffle with icons that were not
    // in yesterday's lineup first. Only the active icon is ruled out, so a
    // holiday set smaller than its slots still appears every day.
    NSMutableArray<NSString *> *seasonal = [NSMutableArray array];
    NSInteger seasonalLimit = MIN(MAX(seasonalSlots, 0), lineupCount);
    uint64_t seasonalState = ((uint64_t)dayIdentifier << 32) ^ kApolloLGSpotlightSeasonalSalt;
    for (NSArray<NSString *> *tier in seasonalTiers) {
        if ((NSInteger)seasonal.count >= seasonalLimit) break;
        NSMutableArray<NSString *> *fresh = [NSMutableArray array];
        NSMutableArray<NSString *> *repeated = [NSMutableArray array];
        for (NSString *iconID in tier) {
            if (!groupForIconID[iconID] || [iconID isEqualToString:activeIconID] ||
                [seasonal containsObject:iconID] || [fresh containsObject:iconID] ||
                [repeated containsObject:iconID]) continue;
            [([previous containsObject:iconID] ? repeated : fresh) addObject:iconID];
        }
        ApolloLGSpotlightShuffle(fresh, &seasonalState);
        ApolloLGSpotlightShuffle(repeated, &seasonalState);
        for (NSString *iconID in [fresh arrayByAddingObjectsFromArray:repeated]) {
            if ((NSInteger)seasonal.count >= seasonalLimit) break;
            [seasonal addObject:iconID];
        }
    }

    // Everything below is the original daily shuffle, minus the seasonal
    // picks: candidates and pack order from the base stream, one icon from
    // each not-yet-covered pack until three are represented, then fill.
    // Candidates come from `iconIDs` only, so holiday-only icons never appear
    // outside their season.
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray arrayWithCapacity:iconIDs.count];
    for (NSUInteger i = 0; i < iconIDs.count; i++) {
        NSString *iconID = iconIDs[i];
        if ([previous containsObject:iconID] || [iconID isEqualToString:activeIconID] ||
            [seasonal containsObject:iconID]) continue;
        [candidates addObject:@(i)];
    }

    uint64_t randomState = ((uint64_t)dayIdentifier << 32) ^ kApolloLGSpotlightBaseSalt;
    ApolloLGSpotlightShuffle(candidates, &randomState);
    NSMutableArray<NSNumber *> *groupOrder = [NSMutableArray arrayWithCapacity:(NSUInteger)groupCount];
    for (NSInteger gi = 0; gi < groupCount; gi++) [groupOrder addObject:@(gi)];
    ApolloLGSpotlightShuffle(groupOrder, &randomState);

    NSMutableIndexSet *coveredGroups = [NSMutableIndexSet indexSet];
    for (NSString *iconID in seasonal) [coveredGroups addIndex:groupForIconID[iconID].unsignedIntegerValue];

    NSMutableIndexSet *taken = [NSMutableIndexSet indexSet];
    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    NSInteger requiredGroups = MIN(3, groupCount);
    for (NSInteger orderIndex = 0;
         orderIndex < groupCount && (NSInteger)coveredGroups.count < requiredGroups;
         orderIndex++) {
        NSUInteger wantedGroup = groupOrder[(NSUInteger)orderIndex].unsignedIntegerValue;
        if ([coveredGroups containsIndex:wantedGroup]) continue;
        for (NSUInteger ci = 0; ci < candidates.count; ci++) {
            NSUInteger iconIndex = candidates[ci].unsignedIntegerValue;
            if ([taken containsIndex:ci] || groupIndexes[iconIndex].unsignedIntegerValue != wantedGroup) continue;
            [taken addIndex:ci];
            [picked addObject:iconIDs[iconIndex]];
            [coveredGroups addIndex:wantedGroup];
            break;
        }
    }
    for (NSUInteger ci = 0;
         ci < candidates.count && (NSInteger)(seasonal.count + picked.count) < lineupCount;
         ci++) {
        if ([taken containsIndex:ci]) continue;
        [taken addIndex:ci];
        [picked addObject:iconIDs[candidates[ci].unsignedIntegerValue]];
    }
    ApolloLGSpotlightShuffle(picked, &randomState);

    // Seasonal icons lead so the first cards on screen are the holiday ones.
    return [seasonal arrayByAddingObjectsFromArray:picked];
}
