#import "ApolloPalHomePrompt.h"
#import "ApolloPalHomePixelUI.h"
#import "ApolloPalHomeRenderer.h"
#import "ApolloPalHomeStore.h"
#import "ApolloPalHomeHaptics.h"
#import "UserDefaultConstants.h"

static const NSTimeInterval kPromptInterval = 20 * 3600;

@interface ApolloPalHomePrompt ()
@property (nonatomic, copy) void (^onTry)(void);
@end

@implementation ApolloPalHomePrompt

+ (BOOL)shouldShow {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (ApolloPalHomeStore.isPalHomeEnabled || [defaults boolForKey:UDKeyPalHomePromptDismissed]) return NO;
    double last = [defaults doubleForKey:UDKeyPalHomePromptLastShown];
    return NSDate.date.timeIntervalSince1970 - last > kPromptInterval;
}

+ (void)showInView:(UIView *)host bottomInset:(CGFloat)bottomInset onTry:(void (^)(void))onTry {
    if (!host || ![self shouldShow]) return;
    for (UIView *view in host.subviews) if ([view isKindOfClass:self]) return;
    [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:UDKeyPalHomePromptLastShown];
    APChromeSetStyle(@"cottage");
    // Whole points per art pixel, so the pixel art stays crisp.
    CGFloat p = MAX(2, floor(MIN(host.bounds.size.width - 32, 380) / 150));
    ApolloPalHomePrompt *card = [[self alloc] initWithPixelScale:p width:(int)floor(MIN(host.bounds.size.width - 32, 380) / p)];
    card.onTry = onTry;
    CGSize size = card.bounds.size;
    card.frame = CGRectMake(round((host.bounds.size.width - size.width) / 2), host.bounds.size.height - bottomInset - size.height - 12,
                            size.width, size.height);
    card.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [host addSubview:card];
    card.transform = CGAffineTransformMakeTranslation(0, size.height + 40);
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    [UIView animateWithDuration:still ? 0 : 0.5 delay:0.35 usingSpringWithDamping:0.75 initialSpringVelocity:0.4 options:0 animations:^{
        card.transform = CGAffineTransformIdentity;
    } completion:nil];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, card);
}

- (instancetype)initWithPixelScale:(CGFloat)p width:(int)W {
    if ((self = [super initWithFrame:CGRectZero])) {
        // A little house, a headline, a sentence, two buttons.
        ApolloPixelLabel *title = [ApolloPixelLabel new];
        title.pixelScale = p; title.font = APFontSmall; title.themeRole = 2; title.text = @"Try Pal Home";
        ApolloPixelLabel *body = [ApolloPixelLabel new];
        body.pixelScale = p; body.font = APFontSmall; body.themeRole = 0; body.maxWidth = W - 34; body.smooth = YES;
        body.smoothAlignment = NSTextAlignmentLeft;
        body.text = @"A cosy home for your Pals, with feeding, play and a room to decorate. Switch back any time.";
        int textH = 6 + 8 + body.pixelHeight + 3;
        int H = textH + 18; // room for the button row
        APCanvas *panelCanvas = APPanelCanvas(W, H);
        APCanvas *house = APIconCanvas(@"house");
        if (house) { APDraw(panelCanvas, house, 6, 7, NO); APCanvasFree(house); }
        ApolloPixelImageView *panel = [ApolloPixelImageView new];
        panel.pixelScale = p;
        [panel setCanvas:panelCanvas];
        APCanvasFree(panelCanvas);
        [self addSubview:panel];
        title.frame = CGRectMake(18 * p, 6 * p, title.intrinsicContentSize.width, title.intrinsicContentSize.height);
        body.frame = CGRectMake(18 * p, 14 * p, body.intrinsicContentSize.width, body.intrinsicContentSize.height);
        [self addSubview:title];
        [self addSubview:body];
        ApolloPixelButton *close = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:@"Not now"];
        close.iconName = nil;
        APCanvas *x = APCanvasCreate(5, 5);
        for (int i = 0; i < 5; i++) { APPx(x, i, i, APChromeCurrent().text); APPx(x, 4 - i, i, APChromeCurrent().text); }
        close.content = [APCanvasBox boxWithCanvas:x];
        close.flat = YES;
        close.tileWidth = 11; close.tileHeight = 11;
        close.pixelScale = p;
        close.accessibilityHint = @"Hides this for good. Pal Home is always in Apollo Reborn → Features.";
        close.frame = CGRectMake((W - 13) * p, 2 * p, 11 * p, 11 * p);
        [close addTarget:self action:@selector(notNow) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:close];
        // "Try it", bottom-right.
        APCanvas *word = APCanvasCreate(APTextWidth(@"TRY IT", APFontSmall), 6);
        APTextShadow(word, @"TRY IT", 0, 0, APFontSmall, APChromeCurrent().text, APChromeCurrent().shadow);
        ApolloPixelButton *tryIt = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:@"Try Pal Home"];
        tryIt.iconName = nil;
        tryIt.content = [APCanvasBox boxWithCanvas:word];
        tryIt.tileWidth = word->w + 10; tryIt.tileHeight = 14;
        tryIt.pixelScale = p;
        tryIt.frame = CGRectMake((W - tryIt.tileWidth - 5) * p, (H - 18) * p, tryIt.tileWidth * p, 14 * p);
        [tryIt addTarget:self action:@selector(tryIt) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:tryIt];
        self.bounds = CGRectMake(0, 0, W * p, H * p);
        self.accessibilityViewIsModal = NO;
        self.accessibilityLabel = @"Try Pal Home";
    }
    return self;
}

- (void)go:(void (^)(void))then {
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.25 animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeTranslation(0, 30);
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
        if (then) then();
    }];
}

- (void)notNow {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:UDKeyPalHomePromptDismissed];
    [self go:nil];
}

- (void)tryIt {
    APHapticPlay(APHapticSuccess);
    ApolloPalHomeStore.palHomeEnabled = YES;
    void (^onTry)(void) = self.onTry;
    [self go:onTry];
}

@end
