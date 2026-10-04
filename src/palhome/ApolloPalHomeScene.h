#import <SpriteKit/SpriteKit.h>
#import "ApolloPalHomeStore.h"
#import "ApolloPalHomeRenderer.h"

NS_ASSUME_NONNULL_BEGIN

@class ApolloPalHomeScene;

@protocol ApolloPalHomeSceneDelegate <NSObject>
// The room document changed (an edit or a lamp switched); persist it.
- (void)palHomeSceneDidChangeRoom:(ApolloPalHomeScene *)scene;
- (void)palHomeSceneSelectionDidChange:(ApolloPalHomeScene *)scene;
- (void)palHomeScene:(ApolloPalHomeScene *)scene announce:(NSString *)message;
@optional
// The moving boxes were unpacked: time to decorate.
- (void)palHomeSceneDidUnpack:(ApolloPalHomeScene *)scene;
// Furniture asked for care (the bowls: "feed", the yarn basket: "play"), so
// it goes through the same rules as the toolbar buttons.
- (void)palHomeScene:(ApolloPalHomeScene *)scene wantsCare:(NSString *)action;
// A species moment wants a sting (APJingle): the goose's honk, the ghost's boo.
- (void)palHomeScene:(ApolloPalHomeScene *)scene wantsJingle:(NSInteger)jingle;
// A toy game ended ("ball" / "wand"), with how many bonks or pounces.
- (void)palHomeScene:(ApolloPalHomeScene *)scene gameEnded:(NSString *)toy score:(NSInteger)score;
@end

// The room, drawn at true art resolution: one scene unit = one art pixel. The
// owning view sizes the scene to (view size ÷ pixel scale) so pixels map to
// whole device pixels. Animal Crossing-style editing happens in place.
@interface ApolloPalHomeScene : SKScene
@property (nonatomic, weak, nullable) id<ApolloPalHomeSceneDelegate> homeDelegate;
@property (nonatomic, readonly) BOOL hasPalArtwork;
@property (nonatomic, strong, readonly) APRoomLayout *layout;
@property (nonatomic, copy, readonly) NSDictionary *roomDocument;

- (void)configureWithRoom:(NSDictionary *)room residents:(NSArray<ApolloPalHomeResident *> *)residents;
// Same Pal, fresh stats (hearts after a meal): updates the sign only.
- (void)refreshResidents:(NSArray<ApolloPalHomeResident *> *)residents;
// Space kept clear for UI, in art pixels (safe areas, toolbar, drawer).
- (void)setTopReserve:(CGFloat)top bottomReserve:(CGFloat)bottom animated:(BOOL)animated;
- (void)setMotionReduced:(BOOL)reduced;
// Where the room sits in scene coordinates (for placing UIKit chrome).
@property (nonatomic, readonly) CGRect roomFrame;
// The room plus its name sign, for postcards (scene coordinates).
@property (nonatomic, readonly) CGRect postcardFrame;
@property (nonatomic, copy, readonly, nullable) NSString *signTitle;

// Interactions.
- (void)petResident;
- (void)playWithResident;
// Toys: Beacon Ball (tap the room to throw; the Pal chases and bonks it back)
// and the Wand (drag to wave it; the Pal chases it and pounces). They run
// until -stopGame or a while without you.
- (void)startBallGame;
- (void)startWandGame;
- (void)stopGame;
@property (nonatomic, copy, readonly, nullable) NSString *toy;
// The Pal goes to eat: at `feedingSpot` if set (cleared afterwards), else the
// Food & Water bowls, else a candy bowl, else a dish appears. Returns YES when
// it's a treat from the candy bowl (trick or treat!).
- (BOOL)feedResident;
@property (nonatomic, weak, nullable) APPlacedItem *feedingSpot;
- (void)restResident;
// A new (or newly chosen) Pal trots in from the door with hearts.
- (void)welcomeHome;
// Goodbye: the Pal waves (a heart) and trots out through the front.
- (void)waveGoodbye:(void (^)(void))completion;
// Moving-in day: the boxes thump down in puffs of dust, a "Moving Day!" sign
// swings in, and the Pal hops in through the front. Any tap skips it.
- (void)playMovingInDay:(nullable void (^)(void))completion;

// Decorating.
@property (nonatomic, getter=isEditing) BOOL editing;
// A saved home in a format this build can't write: look, don't touch.
@property (nonatomic) BOOL readOnly;
@property (nonatomic, strong, readonly, nullable) APPlacedItem *selectedItem;
- (BOOL)addItem:(APItemSpec *)spec;
- (void)flipSelected;
- (void)cycleSelectedVariant;
- (void)toggleSelected;
- (void)removeSelected;
- (BOOL)moveSelectedByX:(int)dx y:(int)dy;
- (void)deselect;
- (void)setWallpaper:(NSString *)identifier;
- (void)setFloor:(NSString *)identifier;
- (void)cycleLighting;
// Replace the whole room (style templates, undo). Saves via the delegate.
- (void)replaceRoom:(NSDictionary *)room;
// Show a room without saving it (a style preview); nil puts the saved room
// back. Committing anything ends the preview.
- (void)previewRoom:(nullable NSDictionary *)room;
// The saved room, even while a preview is showing.
@property (nonatomic, copy, readonly, nullable) NSDictionary *committedRoomDocument;
@end

NS_ASSUME_NONNULL_END
