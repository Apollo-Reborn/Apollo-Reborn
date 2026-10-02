#import "ApolloGoogleSearchViewController.h"

#import <CoreText/CoreText.h>
#import <WebKit/WebKit.h>

#import "ApolloCommon.h"
#import "ApolloGoogleSearch.h"
#import "ApolloKagiSearch.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloKagiSessionLinkViewController.h"

static NSString *const ApolloSearchEngineDidChangeNotification = @"ApolloSearchEngineDidChangeNotification";
static NSString *const ApolloGoogleSearchFiltersDidChangeNotification = @"ApolloGoogleSearchFiltersDidChangeNotification";

// The Google list's chip row (time range, exact words), under the search bar.
static const CGFloat kFilterTopGap = 8.0;
static const CGFloat kFilterHeight = 30.0;
static const CGFloat kFilterBottomGap = 2.0;

// Result cards.
static const CGFloat kCardPadding = 14.0;
static const NSUInteger kExpandedBodyCharacterLimit = 1200;
static const NSUInteger kMaxPages = 10;
// A first page still loading after this long says so under the spinner (a
// normal Google page takes 2-4 s; the search itself gives up at 25 s).
static const NSTimeInterval kSlowSearchHintDelay = 8.0;

#pragma mark - Engine + filter state

ApolloSearchEngine ApolloSearchEngineCurrent(void) {
    NSInteger raw = [NSUserDefaults.standardUserDefaults integerForKey:UDKeySearchEngine];
    if (raw == ApolloSearchEngineGoogle) return ApolloSearchEngineGoogle;
    // Kagi needs the subscriber's Session Link; without one (removed in
    // Settings, a restore without it) the tab is back on Reddit.
    if (raw == ApolloSearchEngineKagi && ApolloKagiHasSessionToken()) return ApolloSearchEngineKagi;
    return ApolloSearchEngineReddit;
}

void ApolloSearchEngineSetCurrent(ApolloSearchEngine engine) {
    if (ApolloSearchEngineCurrent() == engine) return;
    [NSUserDefaults.standardUserDefaults setInteger:engine forKey:UDKeySearchEngine];
    ApolloLog(@"[GoogleSearch] search engine → %@", ApolloSearchEngineName(engine));
    [NSNotificationCenter.defaultCenter postNotificationName:ApolloSearchEngineDidChangeNotification object:nil];
}

BOOL ApolloSearchEngineIsExternal(ApolloSearchEngine engine) {
    return engine == ApolloSearchEngineGoogle || engine == ApolloSearchEngineKagi;
}

NSString *ApolloSearchEngineName(ApolloSearchEngine engine) {
    switch (engine) {
        case ApolloSearchEngineGoogle: return @"Google";
        case ApolloSearchEngineKagi: return @"Kagi";
        case ApolloSearchEngineReddit: default: return @"Reddit";
    }
}

NSString *ApolloSearchEnginePlaceholder(ApolloSearchEngine engine) {
    if (!ApolloSearchEngineIsExternal(engine)) return nil;
    return [@"Search Reddit with " stringByAppendingString:ApolloSearchEngineName(engine)];
}

static id<ApolloExternalSearchSession> ApolloSearchEngineMakeSession(ApolloSearchEngine engine) {
    if (engine == ApolloSearchEngineKagi) return [[ApolloKagiSearchSession alloc] init];
    return [[ApolloGoogleSearchSession alloc] init];
}

// The engine's suggestions endpoint. Both answer in the OpenSearch
// suggestions shape: ["query", ["suggestion", ...]]. Kagi's is the one its
// own OpenSearch description names, and needs no session.
static NSURL *ApolloSearchEngineSuggestURL(ApolloSearchEngine engine, NSString *text) {
    NSURLComponents *components;
    if (engine == ApolloSearchEngineKagi) {
        components = [NSURLComponents componentsWithString:@"https://kagisuggest.com/api/autosuggest"];
        components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:text]];
    } else {
        components = [NSURLComponents componentsWithString:@"https://suggestqueries.google.com/complete/search"];
        NSString *language = [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject ?: @"en";
        components.queryItems = @[[NSURLQueryItem queryItemWithName:@"client" value:@"firefox"],
                                  [NSURLQueryItem queryItemWithName:@"hl" value:language],
                                  [NSURLQueryItem queryItemWithName:@"q" value:text]];
    }
    components.percentEncodedQuery = [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    return components.URL;
}

static ApolloGoogleSearchOptions *ApolloGoogleSearchCurrentOptions(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    ApolloGoogleSearchOptions *options = [[ApolloGoogleSearchOptions alloc] init];
    NSInteger range = [defaults integerForKey:UDKeyGoogleSearchTimeRange];
    options.timeRange = (range >= ApolloGoogleSearchTimeRangeAny && range <= ApolloGoogleSearchTimeRangeYear)
        ? (ApolloGoogleSearchTimeRange)range : ApolloGoogleSearchTimeRangeAny;
    options.exactWords = [defaults boolForKey:UDKeyGoogleSearchExactWords];
    return options;
}

static NSString *ApolloGoogleTimeRangeTitle(ApolloGoogleSearchTimeRange range) {
    switch (range) {
        case ApolloGoogleSearchTimeRangeDay: return @"Past 24 Hours";
        case ApolloGoogleSearchTimeRangeWeek: return @"Past Week";
        case ApolloGoogleSearchTimeRangeMonth: return @"Past Month";
        case ApolloGoogleSearchTimeRangeYear: return @"Past Year";
        case ApolloGoogleSearchTimeRangeAny: default: return @"Any Time";
    }
}

#pragma mark - Theme

static UIColor *ApolloGoogleTextColor(void) {
    return ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
}

static UIColor *ApolloGoogleSecondaryTextColor(void) {
    return ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
}

static UIColor *ApolloGoogleCardColor(void) {
    return ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemGroupedBackgroundColor;
}

static UIColor *ApolloGoogleAccentColor(UIView *view) {
    return ApolloThemeAccentColor() ?: view.tintColor ?: UIColor.systemBlueColor;
}

static UIFont *ApolloGoogleFont(UIFontTextStyle style, CGFloat size, UIFontWeight weight) {
    UIFont *base = ApolloThemeRuntimeFont([UIFont systemFontOfSize:size weight:weight]);
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:base];
}

// The filter chips live in a fixed-height header; they follow Dynamic Type up
// to a size that still fits it (the cards below scale freely).
static UIFont *ApolloGoogleHeaderFont(UIFontTextStyle style, CGFloat size, UIFontWeight weight, CGFloat maximum) {
    UIFont *base = ApolloThemeRuntimeFont([UIFont systemFontOfSize:size weight:weight]);
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:base maximumPointSize:maximum];
}

#pragma mark - Formatting

static NSString *ApolloGoogleCompactCount(NSInteger value) {
    double magnitude = fabs((double)value);
    if (magnitude < 1000) return [NSString stringWithFormat:@"%ld", (long)value];
    double divisor = magnitude >= 1000000 ? 1000000.0 : 1000.0;
    NSString *number = [NSString stringWithFormat:@"%.1f", value / divisor];
    if ([number hasSuffix:@".0"]) number = [number substringToIndex:number.length - 2];
    return [number stringByAppendingString:divisor == 1000000.0 ? @"m" : @"k"];
}

// Apollo's own compact ages: 45m, 15h, 3d, 2mo, 1y.
static NSString *ApolloGoogleCompactAge(NSDate *date) {
    NSTimeInterval seconds = MAX(0, -date.timeIntervalSinceNow);
    if (seconds < 3600) return [NSString stringWithFormat:@"%ldm", (long)MAX(1, seconds / 60)];
    if (seconds < 86400) return [NSString stringWithFormat:@"%ldh", (long)(seconds / 3600)];
    if (seconds < 86400 * 30) return [NSString stringWithFormat:@"%ldd", (long)(seconds / 86400)];
    if (seconds < 86400 * 365) return [NSString stringWithFormat:@"%ldmo", (long)(seconds / (86400 * 30))];
    return [NSString stringWithFormat:@"%ldy", (long)(seconds / (86400 * 365))];
}

static NSAttributedString *ApolloGoogleSymbolRun(NSString *symbol, NSString *text, UIFont *font, UIColor *color) {
    NSMutableAttributedString *run = [[NSMutableAttributedString alloc] init];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithFont:font scale:UIImageSymbolScaleSmall];
    UIImage *image = [[UIImage systemImageNamed:symbol withConfiguration:config]
                      imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (image) {
        NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
        attachment.image = image;
        CGFloat y = (font.capHeight - image.size.height) / 2.0;
        attachment.bounds = CGRectMake(0, y, image.size.width, image.size.height);
        [run appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
        [run appendAttributedString:[[NSAttributedString alloc] initWithString:@" "
                                                                    attributes:@{NSFontAttributeName: font}]];
    }
    [run appendAttributedString:[[NSAttributedString alloc] initWithString:text
                                                                attributes:@{NSFontAttributeName: font,
                                                                             NSForegroundColorAttributeName: color}]];
    return run;
}

#pragma mark - Chips

// Small capsule buttons above the results. UIButtonConfiguration on iOS 15+;
// the iOS 14 floor gets the same look from plain UIButton properties.
static UIButton *ApolloGoogleMakeChip(void) {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.titleLabel.font = ApolloGoogleHeaderFont(UIFontTextStyleFootnote, 13, UIFontWeightSemibold, 16);
    return chip;
}

static void ApolloGoogleStyleChip(UIButton *chip, NSString *title, NSString *symbol, BOOL active, UIView *host) {
    UIColor *accent = ApolloGoogleAccentColor(host);
    UIColor *activeText = ApolloColorIsLight([accent resolvedColorWithTraitCollection:host.traitCollection])
        ? UIColor.blackColor : UIColor.whiteColor;
    UIColor *foreground = active ? activeText : ApolloGoogleTextColor();
    UIColor *background = active ? accent : ApolloGoogleCardColor();
    UIFont *font = ApolloGoogleHeaderFont(UIFontTextStyleFootnote, 13, UIFontWeightSemibold, 16);
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.baseBackgroundColor = background;
        config.baseForegroundColor = foreground;
        config.contentInsets = NSDirectionalEdgeInsetsMake(5, 11, 5, 11);
        config.imagePadding = 4;
        config.image = symbol ? [UIImage systemImageNamed:symbol
                                        withConfiguration:[UIImageSymbolConfiguration configurationWithFont:font
                                                                                                      scale:UIImageSymbolScaleSmall]] : nil;
        config.attributedTitle = [[NSAttributedString alloc] initWithString:title
                                                                 attributes:@{NSFontAttributeName: font}];
        chip.configuration = config;
    } else {
        [chip setTitle:title forState:UIControlStateNormal];
        [chip setTitleColor:foreground forState:UIControlStateNormal];
        [chip setImage:symbol ? [UIImage systemImageNamed:symbol] : nil forState:UIControlStateNormal];
        chip.tintColor = foreground;
        chip.backgroundColor = background;
        chip.contentEdgeInsets = UIEdgeInsetsMake(5, 11, 5, 11);
        chip.layer.cornerRadius = kFilterHeight / 2.0;
    }
    chip.accessibilityLabel = title;
    chip.accessibilityTraits = active ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
}

#pragma mark - Engine button (the search field's magnifier)

// The magnifier's slot, then the chevron, overlapping it by 1 pt.
static const CGFloat kEngineButtonWidth = 30.0;
static const CGFloat kEngineButtonHeight = 28.0;
static const CGFloat kEngineChevronWidth = 8.0;

// An external engine's mark: a plain capital letter ("G" for Google, "K" for
// Kagi), filled from the system font's own glyph outline so it draws like the
// magnifier symbol it replaces (a template image in the same tint). It keeps
// the default SF design whatever font the theme sets for text, as the
// magnifier symbol does: the theme runtime turns +systemFontOfSize:weight:
// calls from the tweak into the theme's design, so the design is set back
// explicitly. `inkHeight` is the letter's drawn height; it is centered
// vertically in a `canvas`-sized image, and horizontally too unless `right` >
// 0 puts its right edge there. nil only if the font has no such letter.
static UIImage *ApolloSearchEngineLetterMark(UniChar character, CGFloat inkHeight, CGSize canvas, CGFloat right) {
    UIFont *font = [UIFont systemFontOfSize:100 weight:UIFontWeightSemibold];
    UIFontDescriptor *plain = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignDefault];
    if (plain) font = [UIFont fontWithDescriptor:plain size:100];
    CTFontRef ctFont = (__bridge CTFontRef)font;
    CGGlyph glyph = 0;
    if (!CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1)) return nil;
    CGPathRef path = CTFontCreatePathForGlyph(ctFont, glyph, NULL);
    if (!path) return nil;
    CGRect ink = CGPathGetPathBoundingBox(path);
    CGFloat scale = inkHeight / CGRectGetHeight(ink);
    CGFloat width = CGRectGetWidth(ink) * scale;
    CGFloat left = right > 0 ? right - width : (canvas.width - width) / 2.0;
    CGFloat top = (canvas.height - inkHeight) / 2.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        // Glyph outlines are y-up: flip while mapping the ink box onto
        // (left, top, width, inkHeight).
        CGContextTranslateCTM(cg, left, top + inkHeight);
        CGContextScaleCTM(cg, scale, -scale);
        CGContextTranslateCTM(cg, -CGRectGetMinX(ink), -CGRectGetMinY(ink));
        CGContextAddPath(cg, path);
        CGContextFillPath(cg);
    }];
    CGPathRelease(path);
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// The letter in the search field, drawn into the magnifier's slot. The
// magnifier only reaches toward the chevron with its handle, below the
// chevron's height; level with the chevron its ring ends 5 pt before the
// chevron's ink. A "G" is widest at that height, so its right edge goes at
// that same x: 15.35 pt into the slot (the chevron's ink starts at 20.35 pt).
// Measured on device pixels, as is the 13 pt height that matches the
// magnifier's weight (the whole magnifier glyph is 15.7 pt). "K" uses the same
// box, so both marks sit the same distance from the chevron.
static const CGFloat kEngineGoogleMarkRight = 15.35;
static const CGFloat kEngineGoogleMarkHeight = 13.0;
// The menu draws this image at its own size, in the default magnifier
// symbol's box. At 0.72 of that box the menu's "G" is 13.3 pt tall beside the
// menu's 16.3 pt magnifier, about the field's 13.3 pt beside 15.7 pt
// (measured on screen).
static const CGFloat kEngineMenuMarkScale = 0.72;

static UniChar ApolloSearchEngineLetter(ApolloSearchEngine engine) {
    return engine == ApolloSearchEngineKagi ? 'K' : 'G';
}

// Fallback SF Symbols, if the system font ever lacks the letter.
static NSString *ApolloSearchEngineFallbackSymbol(ApolloSearchEngine engine) {
    return engine == ApolloSearchEngineKagi ? @"k.circle" : @"g.circle";
}

static UIImage *ApolloSearchEngineFieldMark(ApolloSearchEngine engine) {
    static NSMutableDictionary<NSNumber *, UIImage *> *marks;
    if (!marks) marks = [NSMutableDictionary dictionary];
    UIImage *mark = marks[@(engine)];
    if (!mark) {
        CGSize slot = CGSizeMake(kEngineButtonWidth - kEngineChevronWidth - 1, kEngineButtonHeight);
        mark = ApolloSearchEngineLetterMark(ApolloSearchEngineLetter(engine), kEngineGoogleMarkHeight, slot,
                                            kEngineGoogleMarkRight);
        if (mark) marks[@(engine)] = mark;
    }
    return mark;
}

// The same letter for the engine menu, in the box the menu's magnifier symbol
// gets, at the field mark's height relative to the magnifier.
static UIImage *ApolloSearchEngineMenuMark(ApolloSearchEngine engine) {
    static NSMutableDictionary<NSNumber *, UIImage *> *marks;
    if (!marks) marks = [NSMutableDictionary dictionary];
    UIImage *mark = marks[@(engine)];
    if (!mark) {
        CGSize box = [UIImage systemImageNamed:@"magnifyingglass"].size;
        if (box.width > 0 && box.height > 0) {
            mark = ApolloSearchEngineLetterMark(ApolloSearchEngineLetter(engine), box.height * kEngineMenuMarkScale, box, 0);
        }
        if (mark) marks[@(engine)] = mark;
    }
    return mark ?: [UIImage systemImageNamed:ApolloSearchEngineFallbackSymbol(engine)];
}

@implementation ApolloSearchEngineButton {
    UIImageView *_iconView;
    UIImageView *_chevronView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:CGRectMake(0, 0, kEngineButtonWidth, kEngineButtonHeight)])) {
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];
        // A small chevron says "this is a menu" without adding any chrome.
        _chevronView = [[UIImageView alloc] init];
        _chevronView.contentMode = UIViewContentModeCenter;
        _chevronView.userInteractionEnabled = NO;
        [self addSubview:_chevronView];
        self.showsMenuAsPrimaryAction = YES;   // tap opens it; press-and-hold does too
        self.accessibilityHint = @"Choose whether to search with Reddit, Google or Kagi.";
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadFromDefaults)
                                                   name:ApolloSearchEngineDidChangeNotification object:nil];
        // Saving or removing the Kagi Session Link changes the menu's Kagi row
        // (and, when removed, the engine itself).
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadFromDefaults)
                                                   name:ApolloKagiSessionTokenDidChangeNotification object:nil];
        [self reloadFromDefaults];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kEngineButtonWidth, kEngineButtonHeight);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return self.intrinsicContentSize;
}

- (void)setIconColor:(UIColor *)iconColor {
    _iconColor = iconColor;
    [self reloadFromDefaults];
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self reloadFromDefaults];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self reloadFromDefaults];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _iconView.frame = CGRectMake(0, 0, CGRectGetWidth(bounds) - kEngineChevronWidth - 1, CGRectGetHeight(bounds));
    _chevronView.frame = CGRectMake(CGRectGetMaxX(_iconView.frame) - 1, 1, kEngineChevronWidth, CGRectGetHeight(bounds));
}

- (void)reloadFromDefaults {
    ApolloSearchEngine engine = ApolloSearchEngineCurrent();
    BOOL external = ApolloSearchEngineIsExternal(engine);
    UIColor *iconColor = self.iconColor ?: UIColor.secondaryLabelColor;
    // Reddit keeps Apollo's magnifier exactly; Google and Kagi show a plain
    // capital "G" / "K" in the same color, as far from the chevron as the
    // magnifier is (ApolloSearchEngineFieldMark).
    UIImage *icon = external ? ApolloSearchEngineFieldMark(engine) : nil;
    if (!icon) {
        UIImageSymbolConfiguration *iconConfig =
            [UIImageSymbolConfiguration configurationWithPointSize:external ? 15 : 16 weight:UIImageSymbolWeightMedium];
        icon = [UIImage systemImageNamed:external ? ApolloSearchEngineFallbackSymbol(engine) : @"magnifyingglass"
                       withConfiguration:iconConfig];
    }
    _iconView.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _iconView.tintColor = iconColor;
    UIImageSymbolConfiguration *chevronConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:8 weight:UIImageSymbolWeightBold];
    _chevronView.image = [[UIImage systemImageNamed:@"chevron.down" withConfiguration:chevronConfig]
                          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    _chevronView.tintColor = [iconColor colorWithAlphaComponent:0.8];

    self.menu = [self apollo_engineMenu];
    self.accessibilityLabel = [@"Search with " stringByAppendingString:ApolloSearchEngineName(engine)];
}

- (UIMenu *)apollo_engineMenu {
    ApolloSearchEngine current = ApolloSearchEngineCurrent();
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (ApolloSearchEngine engine = ApolloSearchEngineReddit; engine <= ApolloSearchEngineKagi; engine++) {
        UIImage *image = ApolloSearchEngineIsExternal(engine) ? ApolloSearchEngineMenuMark(engine)
                                                              : [UIImage systemImageNamed:@"magnifyingglass"];
        UIAction *action = [UIAction actionWithTitle:ApolloSearchEngineName(engine)
                                               image:image
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) { [weakSelf apollo_choose:engine]; }];
        if (@available(iOS 15.0, *)) {
            switch (engine) {
                case ApolloSearchEngineReddit: action.subtitle = @"Posts, subreddits and users"; break;
                case ApolloSearchEngineGoogle: action.subtitle = @"Reddit threads, found with Google"; break;
                case ApolloSearchEngineKagi:
                    // Picking it without a link asks for one first. Kept to one
                    // line: the pre-glass menu caps subtitles at two.
                    action.subtitle = ApolloKagiHasSessionToken() ? @"Reddit threads, found with Kagi"
                                                                  : @"Needs your Session Link";
                    break;
            }
        }
        action.state = current == engine ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"Search With" children:actions];
}

- (void)apollo_choose:(ApolloSearchEngine)engine {
    if (self.engineChanged) self.engineChanged(engine);
}

@end

#pragma mark - Filter chips (Google list header)

@interface ApolloGoogleSearchFiltersView : UIView
@property (nonatomic, readonly) CGFloat preferredHeight;
@property (nonatomic, copy, nullable) void (^filtersChanged)(void);
- (void)reloadFromDefaults;
@end

@implementation ApolloGoogleSearchFiltersView {
    UIButton *_timeChip;
    UIButton *_exactChip;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        _timeChip = ApolloGoogleMakeChip();
        _timeChip.showsMenuAsPrimaryAction = YES;
        [self addSubview:_timeChip];
        _exactChip = ApolloGoogleMakeChip();
        [_exactChip addTarget:self action:@selector(apollo_exactChipTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_exactChip];
        CGRect bounds = self.frame;
        bounds.size.height = self.preferredHeight;
        self.frame = bounds;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadFromDefaults)
                                                   name:ApolloGoogleSearchFiltersDidChangeNotification object:nil];
        [self reloadFromDefaults];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (CGFloat)preferredHeight {
    return kFilterTopGap + kFilterHeight + kFilterBottomGap;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self reloadFromDefaults];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self reloadFromDefaults];
}

- (void)reloadFromDefaults {
    ApolloGoogleSearchOptions *options = ApolloGoogleSearchCurrentOptions();
    ApolloGoogleStyleChip(_timeChip, ApolloGoogleTimeRangeTitle(options.timeRange), @"clock",
                          options.timeRange != ApolloGoogleSearchTimeRangeAny, self);
    _timeChip.menu = [self apollo_timeMenuFor:options.timeRange];
    NSString *exactSymbol = @"text.quote";   // quote.opening only exists from iOS 15
    if (@available(iOS 15.0, *)) exactSymbol = @"quote.opening";
    ApolloGoogleStyleChip(_exactChip, @"Exact Words", exactSymbol, options.exactWords, self);
    _exactChip.accessibilityHint = @"Match the words as typed: no synonyms or spelling fixes.";
    [self setNeedsLayout];
}

- (UIMenu *)apollo_timeMenuFor:(ApolloGoogleSearchTimeRange)current {
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (NSInteger range = ApolloGoogleSearchTimeRangeAny; range <= ApolloGoogleSearchTimeRangeYear; range++) {
        UIAction *action = [UIAction actionWithTitle:ApolloGoogleTimeRangeTitle((ApolloGoogleSearchTimeRange)range)
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction *a) {
            [NSUserDefaults.standardUserDefaults setInteger:range forKey:UDKeyGoogleSearchTimeRange];
            [weakSelf apollo_filtersDidChange];
        }];
        action.state = range == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:action];
    }
    return [UIMenu menuWithTitle:@"Posted" children:items];
}

- (void)apollo_exactChipTapped {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:UDKeyGoogleSearchExactWords] forKey:UDKeyGoogleSearchExactWords];
    [self apollo_filtersDidChange];
}

- (void)apollo_filtersDidChange {
    [NSNotificationCenter.defaultCenter postNotificationName:ApolloGoogleSearchFiltersDidChangeNotification object:nil];
    if (self.filtersChanged) self.filtersChanged();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Line up with the cards: the host is a standard inset-grouped table,
    // whose layout margins are the card inset.
    UIEdgeInsets margins = self.superview ? self.superview.layoutMargins : UIEdgeInsetsMake(0, 16, 0, 16);
    CGFloat maxX = self.bounds.size.width - margins.right;
    CGFloat x = margins.left;
    for (UIButton *chip in @[_timeChip, _exactChip]) {
        CGSize size = [chip sizeThatFits:CGSizeMake(maxX - margins.left, kFilterHeight)];
        CGFloat width = MIN(ceil(size.width), MAX(0, maxX - x));
        chip.frame = CGRectMake(x, kFilterTopGap, width, kFilterHeight);
        x += width + 8;
    }
}

@end

#pragma mark - Result cell

@interface ApolloGoogleResultCell : UITableViewCell
@property (nonatomic, copy) void (^readMoreTapped)(void);
@property (nonatomic, weak, readonly) ApolloGoogleSearchResult *result;
// `canFetchMore`: Read More can still load the post from Reddit (its link
// hasn't been followed yet). `loading`: that load is in flight.
- (void)configureWithResult:(ApolloGoogleSearchResult *)result
                   expanded:(BOOL)expanded
               canFetchMore:(BOOL)canFetchMore
                    loading:(BOOL)loading
                  textWidth:(CGFloat)textWidth;
@end

@implementation ApolloGoogleResultCell {
    UILabel *_metaLabel;
    UILabel *_titleLabel;
    UILabel *_snippetLabel;
    UIView *_bodyContainer;
    UIView *_bodyBar;
    UILabel *_bodyLabel;
    UILabel *_statsLabel;
    UIButton *_readMoreButton;
    UIStackView *_stack;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _metaLabel = [[UILabel alloc] init];
        _metaLabel.numberOfLines = 1;
        _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.numberOfLines = 4;

        _snippetLabel = [[UILabel alloc] init];

        _bodyBar = [[UIView alloc] init];
        _bodyBar.layer.cornerRadius = 1.5;
        _bodyLabel = [[UILabel alloc] init];
        _bodyLabel.numberOfLines = 0;
        _bodyContainer = [[UIView alloc] init];
        _bodyBar.translatesAutoresizingMaskIntoConstraints = NO;
        _bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_bodyContainer addSubview:_bodyBar];
        [_bodyContainer addSubview:_bodyLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_bodyBar.leadingAnchor constraintEqualToAnchor:_bodyContainer.leadingAnchor],
            [_bodyBar.topAnchor constraintEqualToAnchor:_bodyContainer.topAnchor constant:2],
            [_bodyBar.bottomAnchor constraintEqualToAnchor:_bodyContainer.bottomAnchor constant:-2],
            [_bodyBar.widthAnchor constraintEqualToConstant:3],
            [_bodyLabel.leadingAnchor constraintEqualToAnchor:_bodyBar.trailingAnchor constant:10],
            [_bodyLabel.trailingAnchor constraintEqualToAnchor:_bodyContainer.trailingAnchor],
            [_bodyLabel.topAnchor constraintEqualToAnchor:_bodyContainer.topAnchor],
            [_bodyLabel.bottomAnchor constraintEqualToAnchor:_bodyContainer.bottomAnchor],
        ]];

        _statsLabel = [[UILabel alloc] init];
        _statsLabel.numberOfLines = 1;
        [_statsLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        _readMoreButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_readMoreButton addTarget:self action:@selector(apollo_readMore) forControlEvents:UIControlEventTouchUpInside];
        [_readMoreButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_readMoreButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *footer = [[UIStackView alloc] initWithArrangedSubviews:@[_statsLabel, _readMoreButton]];
        footer.axis = UILayoutConstraintAxisHorizontal;
        footer.alignment = UIStackViewAlignmentCenter;
        footer.spacing = 12;

        _stack = [[UIStackView alloc] initWithArrangedSubviews:@[_metaLabel, _titleLabel, _snippetLabel, _bodyContainer, footer]];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 6;
        [_stack setCustomSpacing:4 afterView:_metaLabel];
        [_stack setCustomSpacing:8 afterView:_snippetLabel];
        [_stack setCustomSpacing:8 afterView:_bodyContainer];
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kCardPadding],
            [_stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kCardPadding],
            [_stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [_stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        ]];
        self.selectedBackgroundView = [[UIView alloc] init];
        // One element per card (label built in -configure…); Read More is a
        // custom action on it.
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (void)apollo_readMore {
    if (self.readMoreTapped) self.readMoreTapped();
}

// The Reddit text (post body, or the comment itself) to show under "Read
// more", or nil. When Google's snippet is simply the start of that same text,
// the body replaces the snippet rather than repeating it.
static NSString *ApolloGoogleExpandedBody(ApolloGoogleSearchResult *result, BOOL *replacesSnippet) {
    NSString *body = ApolloGoogleSearchPlainTextFromMarkdown(result.bodyText ?: @"");
    if (body.length == 0) return nil;
    if (body.length > kExpandedBodyCharacterLimit) {
        NSRange cut = [body rangeOfString:@" " options:NSBackwardsSearch
                                    range:NSMakeRange(0, kExpandedBodyCharacterLimit)];
        NSUInteger end = cut.location != NSNotFound && cut.location > kExpandedBodyCharacterLimit - 200
            ? cut.location : kExpandedBodyCharacterLimit;
        body = [[body substringToIndex:end] stringByAppendingString:@"…"];
    }
    NSString *snippet = result.snippet ?: @"";
    NSString *probe = snippet.length > 48 ? [snippet substringToIndex:48] : snippet;
    probe = [probe stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@". …"]];
    NSString *flatBody = [[body componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                          componentsJoinedByString:@" "];
    // Only when the snippet IS the opening of the body. A snippet Google took
    // from further down (often the exact line that matched) stays on top.
    NSUInteger found = probe.length >= 12 ? [flatBody rangeOfString:probe].location : NSNotFound;
    if (replacesSnippet) *replacesSnippet = found != NSNotFound && found < 40;
    return body;
}

- (void)configureWithResult:(ApolloGoogleSearchResult *)result
                   expanded:(BOOL)expanded
               canFetchMore:(BOOL)canFetchMore
                    loading:(BOOL)loading
                  textWidth:(CGFloat)textWidth {
    _result = result;
    UIColor *text = ApolloGoogleTextColor();
    UIColor *secondary = ApolloGoogleSecondaryTextColor();
    UIColor *accent = ApolloGoogleAccentColor(self);
    self.backgroundColor = ApolloGoogleCardColor();
    self.selectedBackgroundView.backgroundColor = ApolloThemeRowHighlightColor() ?: UIColor.systemFillColor;

    // Where it's from: r/sub (accent) · u/author · NSFW / Spoiler.
    UIFont *metaFont = ApolloGoogleFont(UIFontTextStyleFootnote, 13, UIFontWeightRegular);
    UIFont *metaBold = ApolloGoogleFont(UIFontTextStyleFootnote, 13, UIFontWeightSemibold);
    NSMutableAttributedString *meta = [[NSMutableAttributedString alloc] init];
    NSString *place = result.subreddit.length ? [@"r/" stringByAppendingString:result.subreddit]
        : result.username.length ? [@"u/" stringByAppendingString:result.username] : @"Reddit";
    [meta appendAttributedString:[[NSAttributedString alloc] initWithString:place
                                                                 attributes:@{NSFontAttributeName: metaBold,
                                                                              NSForegroundColorAttributeName: accent}]];
    NSMutableArray<NSString *> *extras = [NSMutableArray array];
    if (result.kind == ApolloGoogleResultKindComment) {
        [extras addObject:result.author.length ? [NSString stringWithFormat:@"Comment by u/%@", result.author] : @"Comment"];
    } else if (result.kind == ApolloGoogleResultKindSubreddit) {
        [extras addObject:@"Subreddit"];
    } else if (result.kind == ApolloGoogleResultKindUser) {
        [extras addObject:@"Profile"];
    } else if (result.author.length && result.subreddit.length) {
        [extras addObject:[@"u/" stringByAppendingString:result.author]];
    }
    for (NSString *extra in extras) {
        [meta appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  ·  " stringByAppendingString:extra]
                                                                     attributes:@{NSFontAttributeName: metaFont,
                                                                                  NSForegroundColorAttributeName: secondary}]];
    }
    if (result.over18 || result.spoiler) {
        NSString *tag = result.over18 ? @"NSFW" : @"Spoiler";
        UIColor *tagColor = result.over18 ? UIColor.systemRedColor : secondary;
        [meta appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  ·  " stringByAppendingString:tag]
                                                                     attributes:@{NSFontAttributeName: metaBold,
                                                                                  NSForegroundColorAttributeName: tagColor}]];
    }
    _metaLabel.attributedText = meta;

    _titleLabel.font = ApolloGoogleFont(UIFontTextStyleHeadline, 16.5, UIFontWeightSemibold);
    _titleLabel.textColor = text;
    _titleLabel.text = result.redditTitle.length ? result.redditTitle : result.title;
    _titleLabel.numberOfLines = expanded ? 0 : 4;

    // Snippet, with Google's highlighted words kept bold.
    UIFont *snippetFont = ApolloGoogleFont(UIFontTextStyleSubheadline, 15, UIFontWeightRegular);
    UIFont *snippetBold = ApolloGoogleFont(UIFontTextStyleSubheadline, 15, UIFontWeightSemibold);
    NSString *snippetText = result.snippet.length ? result.snippet : @"";
    NSMutableAttributedString *snippet = [[NSMutableAttributedString alloc]
        initWithString:snippetText attributes:@{NSFontAttributeName: snippetFont, NSForegroundColorAttributeName: secondary}];
    for (NSValue *value in result.snippetBoldRanges) {
        NSRange range = value.rangeValue;
        if (NSMaxRange(range) > snippet.length) continue;
        [snippet addAttributes:@{NSFontAttributeName: snippetBold, NSForegroundColorAttributeName: text} range:range];
    }

    BOOL replacesSnippet = NO;
    NSString *body = ApolloGoogleExpandedBody(result, &replacesSnippet);
    CGFloat measureWidth = MAX(120, textWidth);
    // Multi-line labels inside a self-sizing cell measure against their
    // preferred width; without one the first measure is a single line and the
    // expanded text gets clipped to it.
    _titleLabel.preferredMaxLayoutWidth = measureWidth;
    _snippetLabel.preferredMaxLayoutWidth = measureWidth;
    _bodyLabel.preferredMaxLayoutWidth = MAX(60, measureWidth - 13);
    CGFloat fullHeight = [snippet boundingRectWithSize:CGSizeMake(measureWidth, CGFLOAT_MAX)
                                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                               context:nil].size.height;
    BOOL snippetTruncates = fullHeight > snippetFont.lineHeight * 3.0 + 2.0;
    BOOL hasMore = body.length > 0 || snippetTruncates || canFetchMore;

    _snippetLabel.attributedText = snippet;
    _snippetLabel.numberOfLines = expanded ? 0 : 3;
    _snippetLabel.hidden = snippetText.length == 0 || (expanded && replacesSnippet);

    _bodyContainer.hidden = !(expanded && body.length);
    _bodyBar.backgroundColor = [accent colorWithAlphaComponent:0.55];
    _bodyLabel.font = snippetFont;
    _bodyLabel.textColor = text;
    _bodyLabel.text = body;

    // Stats: Reddit's numbers when we have them, else Google's own line.
    UIFont *statsFont = ApolloGoogleFont(UIFontTextStyleFootnote, 13, UIFontWeightRegular);
    NSMutableAttributedString *stats = [[NSMutableAttributedString alloc] init];
    NSAttributedString *gap = [[NSAttributedString alloc] initWithString:@"    " attributes:@{NSFontAttributeName: statsFont}];
    if (result.hasRedditInfo) {
        [stats appendAttributedString:ApolloGoogleSymbolRun(@"arrow.up", ApolloGoogleCompactCount(result.score), statsFont, secondary)];
        if (result.kind != ApolloGoogleResultKindComment || result.commentCount > 0) {
            [stats appendAttributedString:gap];
            [stats appendAttributedString:ApolloGoogleSymbolRun(@"bubble.left", ApolloGoogleCompactCount(result.commentCount), statsFont, secondary)];
        }
        if (result.created) {
            [stats appendAttributedString:gap];
            [stats appendAttributedString:ApolloGoogleSymbolRun(@"clock", ApolloGoogleCompactAge(result.created), statsFont, secondary)];
        }
        NSString *mediaSymbol = nil, *mediaText = nil;
        switch (result.kind == ApolloGoogleResultKindPost ? result.media : ApolloGoogleResultMediaNone) {
            case ApolloGoogleResultMediaImage: mediaSymbol = @"photo"; mediaText = @"Image"; break;
            case ApolloGoogleResultMediaGallery: mediaSymbol = @"photo.on.rectangle"; mediaText = @"Gallery"; break;
            case ApolloGoogleResultMediaVideo: mediaSymbol = @"play.rectangle"; mediaText = @"Video"; break;
            case ApolloGoogleResultMediaLink: mediaSymbol = @"link"; mediaText = result.linkDomain; break;
            case ApolloGoogleResultMediaNone: default: break;
        }
        if (mediaText.length) {
            [stats appendAttributedString:gap];
            [stats appendAttributedString:ApolloGoogleSymbolRun(mediaSymbol, mediaText, statsFont, secondary)];
        }
    } else if (result.engineMeta.length) {
        [stats appendAttributedString:[[NSAttributedString alloc] initWithString:result.engineMeta
                                                                      attributes:@{NSFontAttributeName: statsFont,
                                                                                   NSForegroundColorAttributeName: secondary}]];
    }
    _statsLabel.attributedText = stats;

    NSString *buttonTitle = loading ? @"Loading…" : expanded ? @"Show Less" : @"Read More";
    UIFont *buttonFont = ApolloGoogleFont(UIFontTextStyleFootnote, 14, UIFontWeightSemibold);
    [_readMoreButton setAttributedTitle:[[NSAttributedString alloc] initWithString:buttonTitle
                                                                        attributes:@{NSFontAttributeName: buttonFont,
                                                                                     NSForegroundColorAttributeName: accent}]
                               forState:UIControlStateNormal];
    _readMoreButton.hidden = !(hasMore || expanded);
    _readMoreButton.enabled = !loading;
    _statsLabel.superview.hidden = stats.length == 0 && !hasMore;

    NSMutableArray<NSString *> *spoken = [NSMutableArray array];
    [spoken addObject:_titleLabel.text ?: @""];
    [spoken addObject:place];
    if (!_snippetLabel.hidden && snippetText.length) [spoken addObject:snippetText];
    if (!_bodyContainer.hidden && body.length) [spoken addObject:body];
    if (stats.length) [spoken addObject:stats.string];
    self.accessibilityLabel = [spoken componentsJoinedByString:@", "];
    // The card reads as one element; Read More stays reachable as an action.
    if ((hasMore || expanded) && !loading) {
        __weak typeof(self) weakSelf = self;
        UIAccessibilityCustomAction *action =
            [[UIAccessibilityCustomAction alloc] initWithName:buttonTitle
                                                actionHandler:^BOOL(UIAccessibilityCustomAction *a) {
                [weakSelf apollo_readMore];
                return YES;
            }];
        self.accessibilityCustomActions = @[action];
    } else {
        self.accessibilityCustomActions = @[];
    }
}

@end

#pragma mark - Status cell (loading / empty / error)

@interface ApolloGoogleStatusCell : UITableViewCell
@property (nonatomic, readonly) UIActivityIndicatorView *spinner;
@property (nonatomic, readonly) UILabel *statusTitleLabel;
@property (nonatomic, readonly) UILabel *statusDetailLabel;
@property (nonatomic, readonly) UIButton *actionButton;
@property (nonatomic, copy) void (^action)(void);
@end

@implementation ApolloGoogleStatusCell {
    UIStackView *_stack;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _statusTitleLabel = [[UILabel alloc] init];
        _statusTitleLabel.numberOfLines = 0;
        _statusTitleLabel.textAlignment = NSTextAlignmentCenter;
        _statusDetailLabel = [[UILabel alloc] init];
        _statusDetailLabel.numberOfLines = 0;
        _statusDetailLabel.textAlignment = NSTextAlignmentCenter;
        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_actionButton addTarget:self action:@selector(apollo_action) forControlEvents:UIControlEventTouchUpInside];
        _stack = [[UIStackView alloc] initWithArrangedSubviews:@[_spinner, _statusTitleLabel, _statusDetailLabel, _actionButton]];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.alignment = UIStackViewAlignmentCenter;
        _stack.spacing = 8;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:18],
            [_stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-18],
            [_stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:22],
            [_stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-22],
        ]];
    }
    return self;
}

- (void)apollo_action {
    if (self.action) self.action();
}

- (void)configureSpinning:(BOOL)spinning title:(NSString *)title detail:(NSString *)detail action:(NSString *)actionTitle {
    self.backgroundColor = ApolloGoogleCardColor();
    _spinner.hidden = !spinning;
    _spinner.color = ApolloGoogleSecondaryTextColor();
    if (spinning) [_spinner startAnimating]; else [_spinner stopAnimating];
    _statusTitleLabel.hidden = title.length == 0;
    _statusTitleLabel.text = title;
    _statusTitleLabel.font = ApolloGoogleFont(UIFontTextStyleHeadline, 16, UIFontWeightSemibold);
    _statusTitleLabel.textColor = spinning ? ApolloGoogleSecondaryTextColor() : ApolloGoogleTextColor();
    _statusDetailLabel.hidden = detail.length == 0;
    _statusDetailLabel.text = detail;
    _statusDetailLabel.font = ApolloGoogleFont(UIFontTextStyleSubheadline, 14, UIFontWeightRegular);
    _statusDetailLabel.textColor = ApolloGoogleSecondaryTextColor();
    _actionButton.hidden = actionTitle.length == 0;
    if (actionTitle.length) {
        [_actionButton setAttributedTitle:[[NSAttributedString alloc] initWithString:actionTitle
            attributes:@{NSFontAttributeName: ApolloGoogleFont(UIFontTextStyleSubheadline, 15, UIFontWeightSemibold),
                         NSForegroundColorAttributeName: ApolloGoogleAccentColor(self)}] forState:UIControlStateNormal];
    }
}

@end

#pragma mark - Verification sheet

// Hosts Google's own challenge / consent page so the user can answer it. The
// web view belongs to the search session; this only shows it.
@interface ApolloGoogleVerificationViewController : UIViewController <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) void (^cancelled)(void);
@property (nonatomic) BOOL finishing;
@end

@implementation ApolloGoogleVerificationViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Google";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self
                                                                                          action:@selector(apollo_cancel)];
    UILabel *prompt = [[UILabel alloc] init];
    prompt.numberOfLines = 0;
    prompt.textAlignment = NSTextAlignmentCenter;
    prompt.font = ApolloGoogleFont(UIFontTextStyleFootnote, 13, UIFontWeightRegular);
    prompt.textColor = UIColor.secondaryLabelColor;
    prompt.text = @"Google wants to check this search before showing results. Finish the check below and your results will load.";
    prompt.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:prompt];

    WKWebView *web = self.webView;
    [web removeFromSuperview];
    web.alpha = 1.0;
    web.userInteractionEnabled = YES;
    web.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:web];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [prompt.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [prompt.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [prompt.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [web.topAnchor constraintEqualToAnchor:prompt.bottomAnchor constant:10],
        [web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)apollo_cancel {
    if (self.finishing) return;
    self.finishing = YES;
    void (^cancelled)(void) = self.cancelled;
    self.cancelled = nil;
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    if (cancelled) cancelled();
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (self.finishing) return;
    self.finishing = YES;
    void (^cancelled)(void) = self.cancelled;
    self.cancelled = nil;
    if (cancelled) cancelled();
}

@end

#pragma mark - Results controller

typedef NS_ENUM(NSInteger, ApolloGooglePhase) {
    ApolloGooglePhaseIdle = 0,
    ApolloGooglePhaseSuggestions,
    ApolloGooglePhaseResults,
};

static NSString *const kResultCellID = @"ApolloGoogleResultCell";
static NSString *const kStatusCellID = @"ApolloGoogleStatusCell";
static NSString *const kSuggestionCellID = @"ApolloGoogleSuggestionCell";

@interface ApolloGoogleSearchResultsViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation ApolloGoogleSearchResultsViewController {
    UITableView *_tableView;
    ApolloGoogleSearchFiltersView *_filtersView;
    ApolloGooglePhase _phase;
    NSString *_typedText;
    NSArray<NSString *> *_autocomplete;
    NSURLSessionDataTask *_autocompleteTask;
    NSUInteger _autocompleteGeneration;
    // The engine the list is serving and its session (Google or Kagi),
    // swapped by -apollo_syncEngine when the Search With choice changes.
    ApolloSearchEngine _engine;
    id<ApolloExternalSearchSession> _session;
    NSString *_submittedQuery;
    NSMutableArray<ApolloGoogleSearchResult *> *_results;
    NSMutableSet<NSString *> *_resultKeys;
    // Per result object (identity; a result's dedupe key changes once its
    // link is followed).
    NSMutableSet<ApolloGoogleSearchResult *> *_expanded;
    NSMutableSet<ApolloGoogleSearchResult *> *_readMoreLoading;   // Read More in flight
    NSMutableSet<ApolloGoogleSearchResult *> *_fetchAttempted;    // Read More already tried Reddit
    NSMapTable<ApolloGoogleSearchResult *, NSNumber *> *_rowHeights;   // last laid-out card heights
    __weak ApolloGoogleSearchResult *_opening;
    NSUInteger _nextPage;
    BOOL _mayHaveMore;
    BOOL _loadingFirstPage;
    BOOL _slowFirstPage;          // the first page passed kSlowSearchHintDelay
    NSUInteger _searchGeneration;
    BOOL _loadingMore;
    NSError *_error;
    NSError *_moreError;
    __weak UINavigationController *_verificationNav;
}

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _results = [NSMutableArray array];
        _resultKeys = [NSMutableSet set];
        _expanded = [NSMutableSet set];
        _readMoreLoading = [NSMutableSet set];
        _fetchAttempted = [NSMutableSet set];
        _rowHeights = [NSMapTable strongToStrongObjectsMapTable];
        _autocomplete = @[];
        ApolloSearchEngine engine = ApolloSearchEngineCurrent();
        [self apollo_useEngine:ApolloSearchEngineIsExternal(engine) ? engine : ApolloSearchEngineGoogle];
    }
    return self;
}

- (void)apollo_useEngine:(ApolloSearchEngine)engine {
    [_session cancel];
    _engine = engine;
    _session = ApolloSearchEngineMakeSession(engine);
    if ([_session isKindOfClass:ApolloGoogleSearchSession.class]) {
        // Only Google ever asks the user to answer a check.
        ApolloGoogleSearchSession *google = (ApolloGoogleSearchSession *)_session;
        __weak typeof(self) weakSelf = self;
        google.presentVerification = ^(WKWebView *webView) { [weakSelf apollo_presentVerification:webView]; };
        google.dismissVerification = ^{ [weakSelf apollo_dismissVerification]; };
    }
}

// Follows the Search With choice. YES when the engine changed (anything the
// list showed came from the other engine).
- (BOOL)apollo_syncEngine {
    ApolloSearchEngine engine = ApolloSearchEngineCurrent();
    if (!ApolloSearchEngineIsExternal(engine) || engine == _engine) return NO;
    ApolloLog(@"[GoogleSearch] list switches to %@", ApolloSearchEngineName(engine));
    [self apollo_stopSearch];
    [self apollo_useEngine:engine];
    return YES;
}

- (void)dealloc {
    [_session cancel];
    [_autocompleteTask cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (UITableView *)tableView {
    [self loadViewIfNeeded];
    return _tableView;
}

- (NSString *)submittedQuery {
    return _phase == ApolloGooglePhaseResults ? _submittedQuery : nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 150;
    _tableView.estimatedSectionHeaderHeight = 0;
    _tableView.estimatedSectionFooterHeight = 0;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableView.separatorInset = UIEdgeInsetsMake(0, 54, 0, 0);
    if (@available(iOS 15.0, *)) _tableView.sectionHeaderTopPadding = 0;
    [_tableView registerClass:ApolloGoogleResultCell.class forCellReuseIdentifier:kResultCellID];
    [_tableView registerClass:ApolloGoogleStatusCell.class forCellReuseIdentifier:kStatusCellID];
    [_tableView registerClass:UITableViewCell.class forCellReuseIdentifier:kSuggestionCellID];
    [self.view addSubview:_tableView];

    _filtersView = [[ApolloGoogleSearchFiltersView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 42)];
    __weak typeof(self) weakSelf = self;
    _filtersView.filtersChanged = ^{ [weakSelf apollo_filtersChanged]; };
    _tableView.tableHeaderView = _filtersView;

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(apollo_keyboardWillChange:)
                                               name:UIKeyboardWillChangeFrameNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(apollo_keyboardWillChange:)
                                               name:UIKeyboardWillHideNotification object:nil];
    [self apollo_applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTheme];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_applyTheme];
    [_rowHeights removeAllObjects];   // text size may have changed
    [_tableView reloadData];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [_rowHeights removeAllObjects];   // cards rewrap at the new width
}

- (void)setPageBackgroundColor:(UIColor *)pageBackgroundColor {
    _pageBackgroundColor = pageBackgroundColor;
    if (self.isViewLoaded) [self apollo_applyTheme];
}

- (void)apollo_applyTheme {
    _tableView.backgroundColor = self.pageBackgroundColor ?: ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
    _tableView.separatorColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    _tableView.tintColor = ApolloGoogleAccentColor(_tableView);
    [_filtersView reloadFromDefaults];
}

#pragma mark Keyboard

- (void)apollo_keyboardWillChange:(NSNotification *)note {
    if (!self.isViewLoaded || !self.view.window) return;
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:end fromView:nil];
    CGFloat overlap = [note.name isEqualToString:UIKeyboardWillHideNotification]
        ? 0 : MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(local));
    CGFloat inset = MAX(0, overlap - self.view.safeAreaInsets.bottom);
    UIEdgeInsets content = _tableView.contentInset;
    content.bottom = inset;
    _tableView.contentInset = content;
    UIEdgeInsets indicators = _tableView.verticalScrollIndicatorInsets;
    indicators.bottom = inset;
    _tableView.verticalScrollIndicatorInsets = indicators;
}

#pragma mark Public

- (void)showSuggestionsForText:(NSString *)text {
    [self loadViewIfNeeded];
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL engineChanged = [self apollo_syncEngine];
    if (!engineChanged && _phase == ApolloGooglePhaseResults && [trimmed isEqualToString:_submittedQuery]) return;
    if (_phase == ApolloGooglePhaseResults) [self apollo_stopSearch];
    _phase = ApolloGooglePhaseSuggestions;
    _typedText = trimmed;
    if (trimmed.length == 0) _autocomplete = @[];
    [_tableView reloadData];
    [self apollo_fetchAutocompleteFor:trimmed];
}

- (void)searchForQuery:(NSString *)query {
    [self loadViewIfNeeded];
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return;
    _autocompleteGeneration++;
    [_autocompleteTask cancel];
    [self apollo_syncEngine];
    [self apollo_stopSearch];
    _phase = ApolloGooglePhaseResults;
    _submittedQuery = trimmed;
    _typedText = trimmed;
    _loadingFirstPage = YES;
    NSUInteger generation = ++_searchGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSlowSearchHintDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_searchGeneration || !strongSelf->_loadingFirstPage) return;
        strongSelf->_slowFirstPage = YES;
        [strongSelf->_tableView reloadData];
    });
    [_tableView reloadData];
    [self scrollToTopAnimated:NO];
    [self apollo_loadPage:0];
}

- (void)reset {
    _autocompleteGeneration++;
    [_autocompleteTask cancel];
    [self apollo_stopSearch];
    _phase = ApolloGooglePhaseIdle;
    _typedText = nil;
    _submittedQuery = nil;
    _autocomplete = @[];
    if (self.isViewLoaded) [_tableView reloadData];
}

- (void)scrollToTopAnimated:(BOOL)animated {
    if (!self.isViewLoaded) return;
    [_tableView setContentOffset:CGPointMake(0, -_tableView.adjustedContentInset.top) animated:animated];
}

- (BOOL)isScrolledToTop {
    return !self.isViewLoaded || _tableView.contentOffset.y <= -_tableView.adjustedContentInset.top + 1.0;
}

#pragma mark Searching

- (void)apollo_stopSearch {
    [_session cancel];
    [_results removeAllObjects];
    [_resultKeys removeAllObjects];
    [_expanded removeAllObjects];
    [_readMoreLoading removeAllObjects];
    [_fetchAttempted removeAllObjects];
    [_rowHeights removeAllObjects];
    _nextPage = 0;
    _mayHaveMore = NO;
    _loadingFirstPage = NO;
    _slowFirstPage = NO;
    _loadingMore = NO;
    _error = nil;
    _moreError = nil;
}

- (void)apollo_filtersChanged {
    if (_phase == ApolloGooglePhaseResults && _submittedQuery.length) {
        [self searchForQuery:_submittedQuery];
    }
}

- (void)apollo_loadPage:(NSUInteger)page {
    NSString *query = _submittedQuery;
    if (!query.length) return;
    if (page > 0) {
        _loadingMore = YES;
        _moreError = nil;
    }
    __weak typeof(self) weakSelf = self;
    [_session searchQuery:query options:ApolloGoogleSearchCurrentOptions() page:page
               completion:^(NSArray<ApolloGoogleSearchResult *> *results, BOOL mayHaveMore, NSError *error) {
        [weakSelf apollo_page:page ofQuery:query finishedWith:results mayHaveMore:mayHaveMore error:error];
    }];
}

- (void)apollo_page:(NSUInteger)page
            ofQuery:(NSString *)query
       finishedWith:(NSArray<ApolloGoogleSearchResult *> *)results
        mayHaveMore:(BOOL)mayHaveMore
              error:(NSError *)error {
    if (_phase != ApolloGooglePhaseResults || ![query isEqualToString:_submittedQuery]) return;
    _loadingFirstPage = NO;
    _loadingMore = NO;
    if (error) {
        if (page == 0) _error = error;
        else _moreError = error;
        [_tableView reloadData];
        return;
    }
    NSUInteger added = 0;
    for (ApolloGoogleSearchResult *result in results) {
        NSString *key = result.dedupeKey;
        if (key.length && [_resultKeys containsObject:key]) continue;
        if (key.length) [_resultKeys addObject:key];
        [_results addObject:result];
        added++;
    }
    _nextPage = page + 1;
    // A page that added nothing new means Google is repeating itself: stop.
    _mayHaveMore = mayHaveMore && (page == 0 || added > 0) && _nextPage < kMaxPages;
    [_tableView reloadData];
}

#pragma mark Autocomplete

- (void)apollo_fetchAutocompleteFor:(NSString *)text {
    NSUInteger generation = ++_autocompleteGeneration;
    [_autocompleteTask cancel];
    if (text.length == 0) return;
    ApolloSearchEngine engine = _engine;
    __weak typeof(self) weakSelf = self;
    // Debounce: only the text the user pauses on goes out.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_autocompleteGeneration) return;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ApolloSearchEngineSuggestURL(engine, text)
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:6];
        strongSelf->_autocompleteTask = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                                      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (!json && data) {
                // A few locales answer in Latin-1 rather than UTF-8.
                NSString *latin = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                NSData *utf8 = [latin dataUsingEncoding:NSUTF8StringEncoding];
                json = utf8 ? [NSJSONSerialization JSONObjectWithData:utf8 options:0 error:nil] : nil;
            }
            NSMutableArray<NSString *> *suggestions = [NSMutableArray array];
            if ([json isKindOfClass:[NSArray class]] && [json count] > 1 && [json[1] isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)json[1]) {
                    if (![item isKindOfClass:[NSString class]]) continue;
                    NSString *suggestion = [(NSString *)item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if (suggestion.length == 0 || [suggestion caseInsensitiveCompare:text] == NSOrderedSame) continue;
                    [suggestions addObject:suggestion];
                    if (suggestions.count >= 6) break;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) innerSelf = weakSelf;
                if (!innerSelf || generation != innerSelf->_autocompleteGeneration ||
                    innerSelf->_phase != ApolloGooglePhaseSuggestions) return;
                innerSelf->_autocomplete = suggestions;
                [innerSelf->_tableView reloadData];
            });
        }];
        [strongSelf->_autocompleteTask resume];
    });
}

#pragma mark Kagi Session Link

// The "Kagi Session Expired" card's button: ask for a new link, then run the
// search again with it.
- (void)apollo_updateKagiSessionLink {
    __weak typeof(self) weakSelf = self;
    ApolloKagiPresentSessionLinkSheet(self.parentViewController ?: self, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *query = strongSelf->_submittedQuery;
        if (strongSelf->_phase != ApolloGooglePhaseResults || !query.length) return;
        if (strongSelf->_results.count == 0) {
            [strongSelf searchForQuery:query];
        } else {
            // Mid-list: pick up where the next page left off.
            strongSelf->_moreError = nil;
            [strongSelf apollo_loadPage:strongSelf->_nextPage];
            [strongSelf->_tableView reloadData];
        }
    });
}

#pragma mark Verification

- (void)apollo_presentVerification:(WKWebView *)webView {
    UIViewController *presenter = self.parentViewController ?: self;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter.view.window) {
        [self apollo_verificationCancelled];
        return;
    }
    ApolloGoogleVerificationViewController *controller = [[ApolloGoogleVerificationViewController alloc] init];
    controller.webView = webView;
    __weak typeof(self) weakSelf = self;
    controller.cancelled = ^{
        [weakSelf apollo_verificationCancelled];
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.presentationController.delegate = controller;
    _verificationNav = navigation;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)apollo_verificationCancelled {
    if ([_session isKindOfClass:ApolloGoogleSearchSession.class]) {
        [(ApolloGoogleSearchSession *)_session verificationCancelledByUser];
    }
}

- (void)apollo_dismissVerification {
    UINavigationController *navigation = _verificationNav;
    _verificationNav = nil;
    ApolloGoogleVerificationViewController *controller =
        (ApolloGoogleVerificationViewController *)navigation.viewControllers.firstObject;
    if (![controller isKindOfClass:ApolloGoogleVerificationViewController.class] || controller.finishing) return;
    controller.finishing = YES;
    [navigation dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Table layout helpers

- (BOOL)apollo_showsStatus {
    return _phase == ApolloGooglePhaseResults && _results.count == 0;
}

- (BOOL)apollo_showsMoreRow {
    return _phase == ApolloGooglePhaseResults && _results.count > 0 && (_loadingMore || _moreError || _mayHaveMore);
}

- (CGFloat)apollo_textWidth {
    UIEdgeInsets margins = _tableView.layoutMargins;
    return _tableView.bounds.size.width - margins.left - margins.right - 2 * kCardPadding;
}

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    switch (_phase) {
        case ApolloGooglePhaseIdle: return 0;
        case ApolloGooglePhaseSuggestions: return _typedText.length ? 1 : 0;
        case ApolloGooglePhaseResults:
            if ([self apollo_showsStatus]) return 1;
            return (NSInteger)_results.count + ([self apollo_showsMoreRow] ? 1 : 0);
    }
    return 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_phase == ApolloGooglePhaseSuggestions) return 1 + (NSInteger)_autocomplete.count;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_phase == ApolloGooglePhaseSuggestions) return [self apollo_suggestionCellAt:indexPath];

    if ([self apollo_showsStatus]) {
        ApolloGoogleStatusCell *cell = [tableView dequeueReusableCellWithIdentifier:kStatusCellID forIndexPath:indexPath];
        __weak typeof(self) weakSelf = self;
        NSString *engine = ApolloSearchEngineName(_engine);
        if (_loadingFirstPage) {
            [cell configureSpinning:YES title:[NSString stringWithFormat:@"Searching %@…", engine]
                             detail:_slowFirstPage ? [engine stringByAppendingString:@" is taking longer than usual."] : nil
                             action:nil];
            cell.action = nil;
        } else if (_error.code == ApolloGoogleSearchErrorSessionExpired) {
            // Kagi turned the saved Session Link away: only a new one helps.
            [cell configureSpinning:NO
                              title:@"Kagi Session Expired"
                             detail:@"Paste a new Session Link to keep searching with Kagi."
                             action:@"Update Session Link"];
            cell.action = ^{ [weakSelf apollo_updateKagiSessionLink]; };
        } else if (_error) {
            BOOL cancelled = _error.code == ApolloGoogleSearchErrorVerificationCancelled;
            [cell configureSpinning:NO
                              title:cancelled ? @"Google Check Not Finished" : [@"Couldn't Search " stringByAppendingString:engine]
                             detail:cancelled ? @"Google wanted to check this search first." : _error.localizedDescription
                             action:@"Try Again"];
            cell.action = ^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf.submittedQuery.length) [strongSelf searchForQuery:strongSelf.submittedQuery];
            };
        } else {
            ApolloGoogleSearchOptions *options = ApolloGoogleSearchCurrentOptions();
            NSMutableArray<NSString *> *tips = [NSMutableArray arrayWithObject:@"Try fewer or different words"];
            if (options.exactWords) [tips addObject:@"turn off Exact Words"];
            if (options.timeRange != ApolloGoogleSearchTimeRangeAny) [tips addObject:@"pick a longer time range"];
            NSString *detail = [[tips componentsJoinedByString:@", "] stringByAppendingString:@"."];
            [cell configureSpinning:NO title:[@"No Reddit Results on " stringByAppendingString:engine] detail:detail action:nil];
            cell.action = nil;
        }
        return cell;
    }

    if (indexPath.section >= (NSInteger)_results.count) {
        ApolloGoogleStatusCell *cell = [tableView dequeueReusableCellWithIdentifier:kStatusCellID forIndexPath:indexPath];
        __weak typeof(self) weakSelf = self;
        if (_moreError.code == ApolloGoogleSearchErrorSessionExpired) {
            [cell configureSpinning:NO title:nil detail:@"Kagi didn't accept the saved Session Link."
                             action:@"Update Session Link"];
            cell.action = ^{ [weakSelf apollo_updateKagiSessionLink]; };
        } else if (_moreError) {
            [cell configureSpinning:NO title:nil detail:@"Couldn't load more results." action:@"Try Again"];
            cell.action = ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_loadingMore) return;
                [strongSelf apollo_loadPage:strongSelf->_nextPage];
                [strongSelf->_tableView reloadData];
            };
        } else {
            [cell configureSpinning:YES title:nil detail:nil action:nil];
            cell.action = nil;
        }
        return cell;
    }

    ApolloGoogleSearchResult *result = _results[(NSUInteger)indexPath.section];
    ApolloGoogleResultCell *cell = [tableView dequeueReusableCellWithIdentifier:kResultCellID forIndexPath:indexPath];
    [self apollo_configureCell:cell forResult:result];
    __weak typeof(self) weakSelf = self;
    __weak ApolloGoogleResultCell *weakCell = cell;
    cell.readMoreTapped = ^{
        [weakSelf apollo_toggleExpanded:result cell:weakCell];
    };
    return cell;
}

- (UITableViewCell *)apollo_suggestionCellAt:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [_tableView dequeueReusableCellWithIdentifier:kSuggestionCellID forIndexPath:indexPath];
    cell.backgroundColor = ApolloGoogleCardColor();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = ApolloThemeRowHighlightColor() ?: UIColor.systemFillColor;
    UIFont *font = ApolloGoogleFont(UIFontTextStyleBody, 17, UIFontWeightRegular);
    UIFont *bold = ApolloGoogleFont(UIFontTextStyleBody, 17, UIFontWeightSemibold);
    UIColor *text = ApolloGoogleTextColor();
    cell.textLabel.numberOfLines = 2;
    if (indexPath.row == 0) {
        NSString *prefix = [NSString stringWithFormat:@"Search %@ for “", ApolloSearchEngineName(_engine)];
        NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:prefix
                                                                                  attributes:@{NSFontAttributeName: font,
                                                                                               NSForegroundColorAttributeName: text}];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:_typedText ?: @""
                                                                      attributes:@{NSFontAttributeName: bold,
                                                                                   NSForegroundColorAttributeName: text}]];
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"”"
                                                                      attributes:@{NSFontAttributeName: font,
                                                                                   NSForegroundColorAttributeName: text}]];
        cell.textLabel.attributedText = title;
        cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
    } else {
        cell.textLabel.attributedText = [[NSAttributedString alloc] initWithString:_autocomplete[(NSUInteger)indexPath.row - 1]
                                                                        attributes:@{NSFontAttributeName: font,
                                                                                     NSForegroundColorAttributeName: text}];
        cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
    }
    cell.imageView.tintColor = ApolloGoogleAccentColor(cell);
    cell.accessibilityLabel = cell.textLabel.attributedText.string;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (_phase != ApolloGooglePhaseSuggestions) return nil;
    return [NSString stringWithFormat:@"Searches Reddit through %@. Add r/name to search one subreddit, put a phrase in \"quotes\" to match it exactly, or add -word to leave a word out.",
            ApolloSearchEngineName(_engine)];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
    footer.textLabel.textColor = ApolloGoogleSecondaryTextColor();
}

#pragma mark UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (_phase == ApolloGooglePhaseResults && section > 0) return 5;
    return 12;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (_phase == ApolloGooglePhaseSuggestions) return UITableViewAutomaticDimension;
    return 5;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init];
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (_phase == ApolloGooglePhaseSuggestions) return nil;
    return [[UIView alloc] init];
}

// Cards that have been on screen estimate at their real height, so a jump back
// to the top (Search tab re-tap, status bar) lands exactly there instead of
// stopping short by the estimate error of every card above.
- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_phase == ApolloGooglePhaseResults && ![self apollo_showsStatus] && indexPath.section < (NSInteger)_results.count) {
        NSNumber *height = [_rowHeights objectForKey:_results[(NSUInteger)indexPath.section]];
        if (height) return height.doubleValue;
    }
    return tableView.estimatedRowHeight;
}

// Keyed by the cell's own result, not the index path: after a reload the
// ending cells still carry their old index paths.
- (void)apollo_rememberHeightOfCell:(UITableViewCell *)cell {
    if (![cell isKindOfClass:ApolloGoogleResultCell.class]) return;
    ApolloGoogleSearchResult *result = ((ApolloGoogleResultCell *)cell).result;
    if (!result || [_results indexOfObjectIdenticalTo:result] == NSNotFound) return;
    CGFloat height = CGRectGetHeight(cell.bounds);
    if (height > 1) [_rowHeights setObject:@(height) forKey:result];
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    [self apollo_rememberHeightOfCell:cell];   // includes a Read More / Show Less since it appeared
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    [self apollo_rememberHeightOfCell:cell];
    // Infinite scroll: ask for the next page while the last few are still on their way in.
    if (_phase != ApolloGooglePhaseResults || !_mayHaveMore || _loadingMore || _moreError || _loadingFirstPage) return;
    // The spinner row is already there while more may exist.
    if (indexPath.section + 3 >= (NSInteger)_results.count) [self apollo_loadPage:_nextPage];
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_phase == ApolloGooglePhaseSuggestions) return YES;
    return _phase == ApolloGooglePhaseResults && ![self apollo_showsStatus] && indexPath.section < (NSInteger)_results.count;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_phase == ApolloGooglePhaseSuggestions) {
        NSString *text = indexPath.row == 0 ? _typedText : _autocomplete[(NSUInteger)indexPath.row - 1];
        if (text.length && self.submitText) self.submitText(text);
        return;
    }
    if (indexPath.section >= (NSInteger)_results.count) return;
    [self apollo_openResult:_results[(NSUInteger)indexPath.section]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point {
    if (_phase != ApolloGooglePhaseResults || indexPath.section >= (NSInteger)_results.count) return nil;
    ApolloGoogleSearchResult *result = _results[(NSUInteger)indexPath.section];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *open = [UIAction actionWithTitle:@"Open" image:[UIImage systemImageNamed:@"arrow.up.forward.app"]
                                        identifier:nil handler:^(__kindof UIAction *a) { [weakSelf apollo_openResult:result]; }];
        UIAction *browser = [UIAction actionWithTitle:@"Open in Browser" image:[UIImage systemImageNamed:@"safari"]
                                           identifier:nil handler:^(__kindof UIAction *a) {
            [weakSelf apollo_withURLForResult:result then:^(NSURL *url, BOOL isReddit) {
                typeof(self) strongSelf = weakSelf;
                if (strongSelf) ApolloPresentWebURLFromViewController(strongSelf.parentViewController ?: strongSelf, url);
            }];
        }];
        UIAction *copy = [UIAction actionWithTitle:@"Copy Link" image:[UIImage systemImageNamed:@"doc.on.doc"]
                                        identifier:nil handler:^(__kindof UIAction *a) {
            [weakSelf apollo_withURLForResult:result then:^(NSURL *url, BOOL isReddit) {
                UIPasteboard.generalPasteboard.URL = url;
            }];
        }];
        UIAction *share = [UIAction actionWithTitle:@"Share…" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                         identifier:nil handler:^(__kindof UIAction *a) {
            [weakSelf apollo_share:result atIndexPath:indexPath];
        }];
        return [UIMenu menuWithTitle:@"" children:@[open, browser, copy, share]];
    }];
}

#pragma mark Actions

- (BOOL)apollo_canFetchMore:(ApolloGoogleSearchResult *)result {
    return !result.hasRedditInfo && ![_fetchAttempted containsObject:result] &&
           (result.URL != nil || result.googleLinkURL != nil);
}

- (void)apollo_configureCell:(ApolloGoogleResultCell *)cell forResult:(ApolloGoogleSearchResult *)result {
    [cell configureWithResult:result
                     expanded:[_expanded containsObject:result]
                 canFetchMore:[self apollo_canFetchMore:result]
                      loading:[_readMoreLoading containsObject:result]
                    textWidth:[self apollo_textWidth]];
}

- (ApolloGoogleResultCell *)apollo_visibleCellForResult:(ApolloGoogleSearchResult *)result {
    NSUInteger index = [_results indexOfObjectIdenticalTo:result];
    if (index == NSNotFound) return nil;
    UITableViewCell *cell = [_tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:(NSInteger)index]];
    return [cell isKindOfClass:ApolloGoogleResultCell.class] ? (ApolloGoogleResultCell *)cell : nil;
}

- (void)apollo_toggleExpanded:(ApolloGoogleSearchResult *)result cell:(ApolloGoogleResultCell *)cell {
    if ([_readMoreLoading containsObject:result]) return;
    BOOL expand = ![_expanded containsObject:result];
    if (expand && [self apollo_canFetchMore:result]) {
        // First Read More on this result: follow its Google link (the one
        // "click" this result costs) and read the post from Reddit, then open
        // the card with the post text and Reddit's own numbers.
        [_readMoreLoading addObject:result];
        [self apollo_configureCell:cell forResult:result];
        __weak typeof(self) weakSelf = self;
        [_session resolveResult:result withRedditInfo:YES completion:^(NSError *error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_readMoreLoading removeObject:result];
            // Final unless only the Reddit read failed (offline, rate limited):
            // then the next Read More tries again. A link that couldn't be
            // followed, or a result with nothing to read, stays as it is.
            if (error || result.hasRedditInfo || !result.postID) [strongSelf->_fetchAttempted addObject:result];
            if ([strongSelf->_results indexOfObjectIdenticalTo:result] == NSNotFound) return;   // results changed meanwhile
            [strongSelf apollo_setExpanded:YES result:result];
        }];
        return;
    }
    [self apollo_setExpanded:expand result:result];
}

- (void)apollo_setExpanded:(BOOL)expanded result:(ApolloGoogleSearchResult *)result {
    if (expanded) [_expanded addObject:result];
    else [_expanded removeObject:result];
    ApolloGoogleResultCell *cell = [self apollo_visibleCellForResult:result];
    NSIndexPath *indexPath = cell ? [_tableView indexPathForCell:cell] : nil;
    if (!cell || !indexPath) {
        [_tableView reloadData];
        return;
    }
    [self apollo_configureCell:cell forResult:result];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.25 animations:^{
        [self->_tableView performBatchUpdates:nil completion:nil];
        [cell layoutIfNeeded];
    }];
    if (!expanded) {
        // Collapsing a long card can leave its top far above the screen.
        CGRect rect = [_tableView rectForRowAtIndexPath:indexPath];
        CGFloat visibleTop = _tableView.contentOffset.y + _tableView.adjustedContentInset.top;
        if (CGRectGetMinY(rect) < visibleTop) {
            [_tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionTop animated:YES];
        }
    }
}

// Runs `then` with the result's Reddit URL, following its Google link first
// if needed. Falls back to Google's own link (which redirects to the thread)
// when the Reddit URL can't be recovered.
- (void)apollo_withURLForResult:(ApolloGoogleSearchResult *)result then:(void (^)(NSURL *url, BOOL isReddit))then {
    if (result.URL) {
        then(result.URL, YES);
        return;
    }
    [_session resolveResult:result withRedditInfo:NO completion:^(NSError *error) {
        if (result.URL) then(result.URL, YES);
        else if (result.googleLinkURL) then(result.googleLinkURL, NO);
    }];
}

- (void)apollo_openResult:(ApolloGoogleSearchResult *)result {
    if (self.willOpenResult) self.willOpenResult();
    if (_opening == result) return;   // a second tap while its link is being followed
    _opening = result;
    __weak typeof(self) weakSelf = self;
    [self apollo_withURLForResult:result then:^(NSURL *url, BOOL isReddit) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_opening = nil;
        // The list moved on while the link was being followed (new search,
        // cleared field, switched to Reddit, left the tab): don't push a
        // thread into whatever is on screen now.
        if ([strongSelf->_results indexOfObjectIdenticalTo:result] == NSNotFound || !strongSelf.view.window) {
            ApolloLog(@"[GoogleSearch] result opened after the list changed; not pushing it");
            return;
        }
        ApolloLog(@"[GoogleSearch] opening a result (%@)", isReddit ? @"native" : @"browser, link not followed");
        if (isReddit && ApolloRouteResolvedURLViaApolloScheme(url)) return;
        ApolloPresentWebURLFromViewController(strongSelf.parentViewController ?: strongSelf, url);
    }];
}

- (void)apollo_share:(ApolloGoogleSearchResult *)result atIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    [self apollo_withURLForResult:result then:^(NSURL *url, BOOL isReddit) {
        [weakSelf apollo_presentShareForURL:url atIndexPath:indexPath];
    }];
}

- (void)apollo_presentShareForURL:(NSURL *)url atIndexPath:(NSIndexPath *)indexPath {
    if (!url || !self.view.window) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                        applicationActivities:nil];
    UITableViewCell *cell = [_tableView cellForRowAtIndexPath:indexPath];
    share.popoverPresentationController.sourceView = cell ?: _tableView;
    share.popoverPresentationController.sourceRect = cell ? cell.bounds : _tableView.bounds;
    UIViewController *presenter = self.parentViewController ?: self;
    [presenter presentViewController:share animated:YES completion:nil];
}

@end
