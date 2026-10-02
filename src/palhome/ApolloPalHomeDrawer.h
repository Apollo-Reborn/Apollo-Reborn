#import <UIKit/UIKit.h>
#import "ApolloPalHomeRenderer.h"
#import "ApolloPalHomePixelUI.h"

NS_ASSUME_NONNULL_BEGIN

@class ApolloPalHomeDrawer;

@protocol ApolloPalHomeDrawerDelegate <NSObject>
- (void)drawer:(ApolloPalHomeDrawer *)drawer didPickItem:(APItemSpec *)spec sender:(ApolloPixelButton *)sender;
- (void)drawer:(ApolloPalHomeDrawer *)drawer didPickSurface:(APSurfaceSpec *)surface isFloor:(BOOL)isFloor;
// How to move into a style: its furnished template, just its walls and floor,
// or its walls and floor around the furniture you already have.
typedef NS_ENUM(NSInteger, APStyleApply) { APStyleFurnished = 0, APStyleBare, APStyleKeepThings };
- (void)drawer:(ApolloPalHomeDrawer *)drawer didPickStyle:(APStyleSpec *)style apply:(APStyleApply)apply;
- (void)drawerUndo:(ApolloPalHomeDrawer *)drawer;
// "Start Fresh": back to moving-in day (an empty room and the boxes).
- (void)drawerStartFresh:(ApolloPalHomeDrawer *)drawer;
- (void)drawerDidFinish:(ApolloPalHomeDrawer *)drawer;
- (void)drawerFlip:(ApolloPalHomeDrawer *)drawer;
- (void)drawerCycleVariant:(ApolloPalHomeDrawer *)drawer;
- (void)drawerToggle:(ApolloPalHomeDrawer *)drawer;
- (void)drawerPutAway:(ApolloPalHomeDrawer *)drawer;
- (void)drawerCycleLighting:(ApolloPalHomeDrawer *)drawer;
- (BOOL)drawer:(ApolloPalHomeDrawer *)drawer moveSelectionByX:(int)dx y:(int)dy;
@end

// The Animal Crossing-style catalogue drawer shown while decorating: category
// tabs, a scrolling shelf of furniture thumbnails, and actions for the
// selected piece. Everything is laid out in art pixels.
@interface ApolloPalHomeDrawer : UIView
@property (nonatomic, weak, nullable) id<ApolloPalHomeDrawerDelegate> delegate;
@property (nonatomic) CGFloat pixelScale;
@property (nonatomic) int pixelWidth;        // art px
@property (nonatomic, readonly) int pixelHeight;
@property (nonatomic) APCategory category;
@property (nonatomic) BOOL canUndo; // shows the Undo button after a style swap
- (void)updateWithSelection:(nullable APPlacedItem *)item layout:(APRoomLayout *)layout;
- (void)flashTitle:(NSString *)title;
@end

NS_ASSUME_NONNULL_END
