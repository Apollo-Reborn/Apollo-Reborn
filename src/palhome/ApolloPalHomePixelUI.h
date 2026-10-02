#import <UIKit/UIKit.h>
#import "ApolloPixelCanvas.h"
#import "ApolloPalHomeChrome.h"

// UIKit chrome for Pal Home drawn in the same art pixels as the room: every
// view here is sized in art pixels × `pixelScale` points and shown with
// nearest-neighbour magnification. No system fonts or SF Symbols.

NS_ASSUME_NONNULL_BEGIN

UIImage *APUIImage(APCanvas *canvas);

// The chrome theme in use (follows the home style). Changing it posts
// APChromeDidChangeNotification; buttons and labels re-render themselves.
APChromeTheme APChromeCurrent(void);
void APChromeSetStyle(NSString *_Nullable styleID);
extern NSString *const APChromeDidChangeNotification;

// Panel (toolbar/drawer background) in the current material.
APCanvas *APPanelCanvas(int w, int h);

@interface ApolloPixelImageView : UIImageView
@property (nonatomic) CGFloat pixelScale;
// Takes a copy of the canvas's pixels; sizes itself to canvas × pixelScale.
- (void)setCanvas:(APCanvas *)canvas;
@end

@interface ApolloPixelLabel : ApolloPixelImageView
@property (nonatomic, copy) NSString *text;
@property (nonatomic) APFont font;
@property (nonatomic) uint32_t color, shadowColor;
@property (nonatomic) int maxWidth; // art px; 0 = unlimited (text is truncated with "…")
// Colours from the chrome theme: 0 = title text, 1 = secondary, 2 = accent.
@property (nonatomic) int themeRole;
// Body copy: a small rounded system font in sentence case, drawn at screen
// resolution, wrapping to maxWidth. The pixel font is for names, titles and
// buttons; long lines of it are tiring to read.
@property (nonatomic) BOOL smooth;
@property (nonatomic) NSTextAlignment smoothAlignment; // default centred
// Art-pixel height (rounded up) for laying out smooth text.
- (int)pixelHeight;
@end

// A wooden tile button with a pixel icon (or a thumbnail).
@interface ApolloPixelButton : UIControl
- (instancetype)initWithIcon:(NSString *)icon accessibilityLabel:(NSString *)label;
@property (nonatomic) CGFloat pixelScale;
@property (nonatomic) int tileWidth, tileHeight; // art px
@property (nonatomic, copy, nullable) NSString *iconName;
// Custom content instead of an icon (e.g. a furniture thumbnail).
@property (nonatomic, strong, nullable) APCanvasBox *content;
@property (nonatomic) BOOL toggled;  // selected tab / current wallpaper
@property (nonatomic) BOOL flat;     // content cell style (slot, not a raised tile)
- (CGSize)pixelSize;                  // points
- (void)shake;
@end

NS_ASSUME_NONNULL_END
