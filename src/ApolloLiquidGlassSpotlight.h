#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Daily Spotlight lineup selection for the App Icon picker. Foundation-only so
// tests/run_liquid_glass_spotlight_tests.sh can run it on the host; the picker
// (ApolloLiquidGlassIconPicker.xm) feeds it the registered icons and the
// icons.json "seasons" table.

// Days from year/month/day to the end of an inclusive month/day window in the
// same Gregorian year: 0 on the end date, NSNotFound outside the window.
FOUNDATION_EXPORT NSInteger ApolloLGSeasonDaysUntilEnd(NSInteger year, NSInteger month, NSInteger day,
                                                       NSInteger startMonth, NSInteger startDay,
                                                       NSInteger endMonth, NSInteger endDay);

// Spotlight slots a season claims with `daysUntilEnd` days left: 2 while the
// holiday is two weeks or more away, 3 when it is 7-13 days away, and the whole
// lineup (`lineupCount`) in the final week (0-6 days). 0 outside the window
// (NSNotFound or negative). A holiday with fewer icons fills what it can.
FOUNDATION_EXPORT NSInteger ApolloLGSeasonalSlotCount(NSInteger daysUntilEnd, NSInteger lineupCount);

// Builds one day's lineup of `lineupCount` icon IDs.
//
// `iconIDs` lists every registered icon in registry order and `groupIndexes`
// gives each one's pack (0..<groupCount). Icons in `previousLineup` and
// `activeIconID` are left out, and the lineup spans at least three packs when
// that many exist.
//
// `seasonalTiers` is the active season's icons in priority order (made for the
// holiday, then color matches). Up to `seasonalSlots` of them lead the lineup.
// Unlike the other picks they may repeat yesterday's lineup, so a small
// holiday set keeps showing all season; icons not shown yesterday still go
// first within a tier. With no seasonal picks the result matches the original
// non-seasonal shuffle for the same inputs.
//
// `seasonalOnlyGroups` maps holiday-only icons (Standard-pack icons, which are
// not in `iconIDs`) to a pack index of their own (>= groupCount). They can be
// seasonal picks and count as a pack for the three-pack rule, but never join
// the everyday rotation. `everydayExcluded` keeps more icons out of the
// everyday picks (the picker passes other holidays' icons while one is on).
// When holiday picks fill the lineup, the three-pack rule gives way.
FOUNDATION_EXPORT NSArray<NSString *> *ApolloLGSpotlightLineup(NSArray<NSString *> *iconIDs,
                                                                NSArray<NSNumber *> *groupIndexes,
                                                                NSInteger groupCount,
                                                                NSInteger lineupCount,
                                                                NSInteger dayIdentifier,
                                                                NSArray<NSString *> *previousLineup,
                                                                NSString * _Nullable activeIconID,
                                                                NSArray<NSArray<NSString *> *> *seasonalTiers,
                                                                NSDictionary<NSString *, NSNumber *> *seasonalOnlyGroups,
                                                                NSSet<NSString *> *everydayExcluded,
                                                                NSInteger seasonalSlots);

NS_ASSUME_NONNULL_END
