#import <Foundation/Foundation.h>

// Every Pal species, keyed by a stable string id: Reborn's own "enum".
//
// Apollo's species are a closed Swift enum (`Apollo.PixelPal`, 16 no-payload
// cases stored in one byte; Optional's nil is tag 16 and its switch jump
// tables have no bounds check), so we never extend it. Instead this table is
// the source of truth for Pal Home, the shelter and the widget. The first 16
// rows mirror Apollo's cases (`apolloCase` = their rawValue); Reborn species
// have no case and reach Apollo's island through the store's island channel
// (see ApolloPalHomeStore). Ids are plain strings so a species this build
// doesn't know (from a newer build, or a visiting Pal) round-trips untouched.
// Foundation only.

NS_ASSUME_NONNULL_BEGIN

@interface APSpecies : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
// Apollo's PixelPal rawValue, or nil for a Reborn species.
@property (nonatomic, copy, readonly, nullable) NSString *apolloCase;
@property (nonatomic, readonly, getter=isReborn) BOOL reborn;
@property (nonatomic, readonly) double weightInLbs;
@property (nonatomic, readonly) BOOL genderless;
// Thought-bubble snack: "t.bone", "t.fish", "t.yuzu".
@property (nonatomic, copy, readonly) NSString *snackThought;
// Apollo's per-species weight gain per meal multiplier (Hopper: table at
// 0x100ac0da8, used by the feed handler sub_10004fd34).
@property (nonatomic, readonly) double feedWeightFactor;
// "Kitten", "Puppy"… for the very young; nil to use months.
@property (nonatomic, copy, readonly, nullable) NSString *babyWord;

+ (NSArray<APSpecies *> *)all;
+ (nullable APSpecies *)speciesWithID:(nullable NSString *)identifier;
+ (NSArray<NSString *> *)allIDs;
// Apollo's own 16, in its declaration order.
+ (NSArray<NSString *> *)apolloIDs;
+ (BOOL)isApolloSpecies:(nullable NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
