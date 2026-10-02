#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Sprite sheets for Reborn species (ones Apollo's asset catalogue doesn't
// have), drawn in code in Apollo's exact sheet format so they animate
// anywhere an Apollo Pal does: the island, Pal Home, the shelter, the widget.
// Foundation/CoreGraphics only.

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN BOOL APRebornHasSprites(NSString *species);
// The sheet for "<species>-<action>" (32×14 frames), or NULL. Caller releases.
FOUNDATION_EXTERN CGImageRef _Nullable APRebornCreateSheet(NSString *species, NSString *action) CF_RETURNS_RETAINED;
// Top-of-head pixel in a frame (top-left origin), for things that sit on it;
// (-1, -1) when unknown.
FOUNDATION_EXTERN CGPoint APRebornHeadTop(NSString *species, NSString *action);

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN

// Apollo's own sheet for an asset name like "dog-walk" (borrowed, not retained).
typedef CGImageRef _Nullable (^APNativeSheetLoader)(NSString *assetName);

// The one way to get any Pal's sheet: Reborn species are drawn, Apollo's come
// from `native`; either way recoloured to `coat`. Caller releases.
FOUNDATION_EXTERN CGImageRef _Nullable APPalCreateSheet(NSString *species, NSString *_Nullable coat, NSString *action,
                                      APNativeSheetLoader _Nullable native) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
