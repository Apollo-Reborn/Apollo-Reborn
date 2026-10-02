#import <UIKit/UIKit.h>
#import "ApolloPalHomeStore.h"

NS_ASSUME_NONNULL_BEGIN

@class ApolloPalHomeWardrobe;

@protocol ApolloPalHomeWardrobeDelegate <NSObject>
- (void)wardrobeDidFinish:(ApolloPalHomeWardrobe *)wardrobe;
- (void)wardrobeWantsShelter:(ApolloPalHomeWardrobe *)wardrobe;
- (void)wardrobeWantsWidgetCode:(ApolloPalHomeWardrobe *)wardrobe;
- (void)wardrobe:(ApolloPalHomeWardrobe *)wardrobe wantsRename:(ApolloPalHomeResident *)resident;
- (void)wardrobe:(ApolloPalHomeWardrobe *)wardrobe switchTo:(ApolloPalHomeResident *)resident;
- (void)wardrobeToggledIsland:(ApolloPalHomeWardrobe *)wardrobe;
- (void)wardrobe:(ApolloPalHomeWardrobe *)wardrobe wantsGoodbye:(ApolloPalHomeResident *)resident;
@end

// The Pal card: who your Pal is (age, personality, quirk, hearts), the rest
// of your household to swap between, rename, and the way back to the shelter.
@interface ApolloPalHomeWardrobe : UIView
@property (nonatomic, weak, nullable) id<ApolloPalHomeWardrobeDelegate> delegate;
@property (nonatomic) CGFloat pixelScale;
@property (nonatomic, readonly) int pixelWidth, pixelHeight;
// Food in the pantry, shown on the card (set before -configureWithHousehold:).
@property (nonatomic) NSInteger foodTokens;
// Whether your Pal is on the Dynamic Island (Apollo's Enable Pixel Pals).
@property (nonatomic) BOOL islandEnabled;
- (void)configureWithHousehold:(NSArray<ApolloPalHomeResident *> *)household;
@end

NS_ASSUME_NONNULL_END
