#import <UIKit/UIKit.h>
#import "ApolloPalHomeShelter.h"

NS_ASSUME_NONNULL_BEGIN

@class ApolloPalHomeShelterView;

@protocol ApolloPalHomeShelterDelegate <NSObject>
- (void)shelter:(ApolloPalHomeShelterView *)shelter adopt:(APShelterAnimal *)animal name:(NSString *)name;
- (void)shelter:(ApolloPalHomeShelterView *)shelter rename:(NSString *)residentID name:(NSString *)name;
- (void)shelterDidClose:(ApolloPalHomeShelterView *)shelter;
@end

// The Paws & Claws Shelter: browse today's animals, meet one, adopt and name
// them. Also hosts the rename flow for a Pal already at home. Pixel art only;
// typing goes through an invisible text field drawn as a pixel text box.
@interface ApolloPalHomeShelterView : UIView
@property (nonatomic, weak, nullable) id<ApolloPalHomeShelterDelegate> delegate;
@property (nonatomic) CGFloat pixelScale;
@property (nonatomic) UIEdgeInsets safeInsets;
@property (nonatomic) CGFloat keyboardHeight; // points; lifts the name editor
- (void)showRoster:(NSArray<APShelterAnimal *> *)animals keepName:(nullable NSString *)keepName;
- (void)showRenameForResident:(NSString *)residentID species:(NSString *)species coat:(NSString *)coat currentName:(NSString *)name;
@end

// Any Pal's sheet (Apollo's or a Reborn species'), in `coat`. Ignores the
// global coat/island hook. Caller releases.
FOUNDATION_EXTERN CGImageRef _Nullable APPalCreateSheetForUI(NSString *species, NSString *_Nullable coat, NSString *action) CF_RETURNS_RETAINED;
// The sprite for a species in a coat, frame `index` of `action` (32×14),
// optionally scaled up by an integer factor.
UIImage *_Nullable APPalSpriteImage(NSString *species, NSString *coat, NSString *action, NSUInteger index, int scale);
NSArray<UIImage *> *APPalSpriteFrames(NSString *species, NSString *coat, NSString *action, int scale);

NS_ASSUME_NONNULL_END
