#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ApolloPalHomeStore.h"

// Pal Home on the Home Screen. A sideloaded app and its widget extension
// can't share an App Group, so the app hands the widget a compact "Pal code"
// (the Pal's identity + the whole room document, zlib + base64) through the
// same paste-once setup code channel the other Reborn widgets use. The widget
// links this file and the room renderer and draws the very same room.
// Foundation/CoreGraphics only: tests/run_pal_home_render.sh previews every
// size on a Mac.

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, APPalWidgetFamily) {
    APPalWidgetSmall = 0,
    APPalWidgetMedium,
    APPalWidgetLarge,
    APPalWidgetExtraLarge,         // iPad landscape
    APPalWidgetExtraLargePortrait, // iOS 27
};

// Returns the sprite sheet image for an asset name like "dog-sit".
typedef CGImageRef _Nullable (^APSpriteSheetProvider)(NSString *assetName);

@interface APPalWidget : NSObject
// "PAL1:" + base64(zlib(JSON {v, issued, pal:{species, coat, name, gender,
// ageMonths, personality, quirk, hearts}, room})).
+ (nullable NSString *)encodePal:(NSDictionary *)pal room:(NSDictionary *)room;
+ (nullable NSDictionary *)decode:(NSString *)code; // {pal, room, issued}
// The widget's own interactive state: pose ("idle", "pet", "sleep"),
// lightsOff, and a seed that moves the Pal around between refreshes.
+ (CGImageRef)renderPayload:(NSDictionary *)payload family:(APPalWidgetFamily)family minute:(int)minuteOfDay
                       state:(NSDictionary *)state sprites:(APSpriteSheetProvider)sprites CF_RETURNS_RETAINED;
// Art-pixel size of each family's canvas (the view scales it, nearest-neighbour).
+ (CGSize)canvasSizeForFamily:(APPalWidgetFamily)family;
// A pixel tile button image (heart/moon/bulb…) in the room style's chrome.
+ (CGImageRef)buttonImageForIcon:(NSString *)icon style:(nullable NSString *)style toggled:(BOOL)toggled CF_RETURNS_RETAINED;
// A pixel "paste your Pal code" card, for a widget with no code yet.
+ (CGImageRef)setupImageForFamily:(APPalWidgetFamily)family CF_RETURNS_RETAINED;
// A sample Pal (a ginger cat) in the cottage, for the widget gallery.
+ (NSDictionary *)samplePayload;
// The backdrop colour behind the canvas (WidgetKit container background).
+ (uint32_t)backgroundColorForStyle:(nullable NSString *)style;
@end

@interface ApolloPalHomeStore (PalHomeWidget)
// The Pal code for the Pal Home widget: the active Pal and the room
// (`room`, or the saved one, or the starter room when nil).
- (nullable NSString *)widgetCodeWithRoom:(nullable NSDictionary *)room;
// Any Pal's code (whoever you're visiting), with their room (or `room`).
- (nullable NSString *)widgetCodeForResident:(nullable NSString *)identifier room:(nullable NSDictionary *)room;
@end

NS_ASSUME_NONNULL_END
