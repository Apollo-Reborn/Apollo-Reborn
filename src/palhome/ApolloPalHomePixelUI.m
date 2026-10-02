#import "ApolloPalHomePixelUI.h"
#import "ApolloPalHomeRenderer.h"
#import "ApolloPalHomeHaptics.h"

UIImage *APUIImage(APCanvas *canvas) {
    CGImageRef image = APCanvasCreateCGImage(canvas);
    UIImage *result = [UIImage imageWithCGImage:image scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(image);
    return result;
}

NSString *const APChromeDidChangeNotification = @"ApolloRebornPalHomeChromeDidChange";
static APChromeTheme sChrome;
static NSString *sChromeStyle;
static BOOL sChromeReady;

APChromeTheme APChromeCurrent(void) {
    if (!sChromeReady) { sChrome = APChromeThemeForStyle(nil); sChromeReady = YES; }
    return sChrome;
}

void APChromeSetStyle(NSString *styleID) {
    if (sChromeReady && (styleID == sChromeStyle || [styleID isEqualToString:sChromeStyle])) return;
    sChromeStyle = [styleID copy];
    sChrome = APChromeThemeForStyle(styleID);
    sChromeReady = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:APChromeDidChangeNotification object:nil];
}

APCanvas *APPanelCanvas(int w, int h) { return APChromePanel(APChromeCurrent(), w, h); }

@interface ApolloPixelImageView ()
- (void)sizeToPixels;
@end

@implementation ApolloPixelImageView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.minificationFilter = kCAFilterNearest;
        self.contentMode = UIViewContentModeScaleToFill;
        _pixelScale = 2;
    }
    return self;
}

- (void)setCanvas:(APCanvas *)canvas {
    self.image = APUIImage(canvas);
    [self sizeToPixels];
}

- (void)sizeToPixels {
    CGRect frame = self.frame;
    frame.size = CGSizeMake(self.image.size.width * self.pixelScale, self.image.size.height * self.pixelScale);
    self.frame = frame;
}

- (void)setPixelScale:(CGFloat)pixelScale {
    _pixelScale = pixelScale;
    [self sizeToPixels];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(self.image.size.width * self.pixelScale, self.image.size.height * self.pixelScale);
}

@end

@implementation ApolloPixelLabel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _color = APChromeCurrent().text;
        _shadowColor = APChromeCurrent().shadow;
        _text = @"";
        _smoothAlignment = NSTextAlignmentCenter;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(chromeChanged) name:APChromeDidChangeNotification object:nil];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitStaticText;
    }
    return self;
}

- (UIFont *)smoothFont {
    // Roughly the pixel font's cap height, a touch bigger for readability.
    CGFloat size = MAX(11, round(self.pixelScale * (self.font == APFontLarge ? 6.2 : 4.8)));
    UIFont *font = [UIFont systemFontOfSize:size weight:self.font == APFontLarge ? UIFontWeightBold : UIFontWeightSemibold];
    UIFontDescriptor *rounded = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rounded ? [UIFont fontWithDescriptor:rounded size:size] : font;
}

static UIColor *APColor(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

- (void)renderSmooth {
    NSString *text = self.text ?: @"";
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.alignment = self.smoothAlignment;
    para.lineBreakMode = NSLineBreakByWordWrapping;
    para.lineSpacing = 1;
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [APColor(self.shadowColor) colorWithAlphaComponent:0.45];
    shadow.shadowOffset = CGSizeMake(0, 1);
    NSDictionary *attrs = @{NSFontAttributeName: [self smoothFont], NSForegroundColorAttributeName: APColor(self.color),
                            NSParagraphStyleAttributeName: para, NSShadowAttributeName: shadow};
    CGFloat maxW = self.maxWidth > 0 ? self.maxWidth * self.pixelScale : 2000;
    CGRect bounds = [text boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs context:nil];
    // Centred text is laid out across the full width; others hug the text.
    CGSize size = CGSizeMake(ceil(self.smoothAlignment == NSTextAlignmentCenter && self.maxWidth > 0 ? maxW : bounds.size.width), ceil(bounds.size.height) + 1);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(MAX(1, size.width), MAX(1, size.height))];
    self.image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [text drawWithRect:CGRectMake(0, 0, size.width, size.height) options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs context:nil];
    }];
    self.layer.magnificationFilter = kCAFilterLinear;
    self.layer.minificationFilter = kCAFilterLinear;
    CGRect frame = self.frame;
    frame.size = self.image.size;
    self.frame = frame;
    self.accessibilityLabel = self.text;
}

- (int)pixelHeight {
    CGFloat h = self.smooth ? self.image.size.height : self.image.size.height * self.pixelScale;
    return (int)ceil(h / MAX(1, self.pixelScale));
}

- (CGSize)intrinsicContentSize {
    return self.smooth ? self.image.size : [super intrinsicContentSize];
}

- (void)sizeToPixels {
    if (self.smooth) {
        CGRect frame = self.frame;
        frame.size = self.image.size;
        self.frame = frame;
        return;
    }
    [super sizeToPixels];
}

- (void)setPixelScale:(CGFloat)pixelScale {
    [super setPixelScale:pixelScale];
    if (self.smooth) [self render];
}

- (void)setSmooth:(BOOL)smooth { _smooth = smooth; [self render]; }
- (void)setSmoothAlignment:(NSTextAlignment)alignment { _smoothAlignment = alignment; [self render]; }

- (void)render {
    if (self.smooth) { [self renderSmooth]; return; }
    self.layer.magnificationFilter = kCAFilterNearest;
    self.layer.minificationFilter = kCAFilterNearest;
    NSString *text = self.text.uppercaseString ?: @"";
    if (self.maxWidth > 0 && APTextWidth(text, self.font) > self.maxWidth) {
        while (text.length > 1 && APTextWidth([text stringByAppendingString:@".."], self.font) > self.maxWidth) {
            text = [text substringToIndex:text.length - 1];
        }
        text = [text stringByAppendingString:@".."];
    }
    int w = MAX(1, APTextWidth(text, self.font)), h = APTextHeight(self.font) + 1;
    APCanvas *c = APCanvasCreate(w, h + (self.font == APFontSmall ? 0 : 0));
    APTextShadow(c, text, 0, 0, self.font, self.color, self.shadowColor);
    [self setCanvas:c];
    APCanvasFree(c);
    self.accessibilityLabel = self.text;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)chromeChanged {
    APChromeTheme t = APChromeCurrent();
    _color = self.themeRole == 2 ? t.accent : self.themeRole == 1 ? t.subtext : t.text;
    _shadowColor = t.shadow;
    [self render];
}

- (void)setThemeRole:(int)themeRole { _themeRole = themeRole; [self chromeChanged]; }
- (void)setText:(NSString *)text { _text = [text copy] ?: @""; [self render]; }
- (void)setFont:(APFont)font { _font = font; [self render]; }
- (void)setColor:(uint32_t)color { _color = color; [self render]; }
- (void)setMaxWidth:(int)maxWidth { _maxWidth = maxWidth; [self render]; }

@end

@interface ApolloPixelButton ()
@property (nonatomic, strong) ApolloPixelImageView *imageView;
@end

@implementation ApolloPixelButton

- (void)touchedDown { if (self.enabled) APHapticPlay(APHapticTap); }

- (instancetype)initWithIcon:(NSString *)icon accessibilityLabel:(NSString *)label {
    if ((self = [super initWithFrame:CGRectZero])) {
        _iconName = [icon copy];
        _tileWidth = 22;
        _tileHeight = 20;
        _pixelScale = 2;
        _imageView = [ApolloPixelImageView new];
        _imageView.userInteractionEnabled = NO;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(render) name:APChromeDidChangeNotification object:nil];
        [self addSubview:_imageView];
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = label;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        // Every pixel button answers the finger as it lands.
        [self addTarget:self action:@selector(touchedDown) forControlEvents:UIControlEventTouchDown];
        [self render];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (CGSize)pixelSize { return CGSizeMake(self.tileWidth * self.pixelScale, self.tileHeight * self.pixelScale); }
- (CGSize)intrinsicContentSize { return self.pixelSize; }
- (CGSize)sizeThatFits:(CGSize)size { return self.pixelSize; }

- (void)setPixelScale:(CGFloat)pixelScale { _pixelScale = pixelScale; [self render]; }
- (void)setTileWidth:(int)tileWidth { _tileWidth = tileWidth; [self render]; }
- (void)setTileHeight:(int)tileHeight { _tileHeight = tileHeight; [self render]; }
- (void)setIconName:(NSString *)iconName { _iconName = [iconName copy]; [self render]; }
- (void)setContent:(APCanvasBox *)content { _content = content; [self render]; }
- (void)setToggled:(BOOL)toggled {
    _toggled = toggled;
    if (toggled) self.accessibilityTraits |= UIAccessibilityTraitSelected;
    else self.accessibilityTraits &= ~UIAccessibilityTraitSelected;
    [self render];
}
- (void)setFlat:(BOOL)flat { _flat = flat; [self render]; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; [self render]; }
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alpha = enabled ? 1 : 0.4;
    if (enabled) self.accessibilityTraits &= ~UIAccessibilityTraitNotEnabled;
    else self.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
}

- (void)render {
    int w = self.tileWidth, h = self.tileHeight;
    BOOL down = self.highlighted;
    APCanvas *c = self.flat ? APChromeSlot(APChromeCurrent(), w, h, down, self.toggled)
                            : APChromeTile(APChromeCurrent(), w, h, down, self.toggled);
    APCanvas *content = nil;
    if (self.content) content = APCanvasCopy(self.content.canvas);
    else if (self.iconName) content = APIconCanvas(self.iconName);
    if (content) {
        int ox = (w - content->w) / 2;
        int oy = self.flat ? h - content->h - 3 : (h - 2 - content->h) / 2 + (down ? 1 : 0);
        APDraw(c, content, ox, MAX(1, oy), NO);
        APCanvasFree(content);
    }
    self.imageView.pixelScale = self.pixelScale;
    [self.imageView setCanvas:c];
    APCanvasFree(c);
    self.imageView.frame = CGRectMake(0, 0, w * self.pixelScale, h * self.pixelScale);
    [self invalidateIntrinsicContentSize];
}

- (void)shake {
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    CGFloat p = self.pixelScale;
    shake.values = @[@0, @(-2 * p), @(2 * p), @(-p), @(p), @0];
    shake.duration = 0.3;
    [self.layer addAnimation:shake forKey:@"shake"];
}

@end
