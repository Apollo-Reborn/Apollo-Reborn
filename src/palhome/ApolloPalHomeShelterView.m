#import "ApolloPalHomeShelterView.h"
#import "ApolloPalHomeHaptics.h"
#import "ApolloPalHomePixelUI.h"
#import "ApolloPalHomeRenderer.h"
#import "ApolloPixelPalCoats.h"
#import "ApolloRebornPalSprites.h"
#import "ApolloPalSpecies.h"

#pragma mark - Sprites

CGImageRef APPalCreateSheetForUI(NSString *species, NSString *coat, NSString *action) {
    // Apollo's sheets via the *un*hooked selector, so we get the coat we ask
    // for (not whatever the island hook would substitute); Reborn species are
    // drawn. 14px-tall sheets of 32px frames only.
    CGImageRef sheet = APPalCreateSheet(species, coat, action, ^CGImageRef(NSString *assetName) {
        return [UIImage imageNamed:assetName inBundle:nil compatibleWithTraitCollection:nil].CGImage;
    });
    if (sheet && (CGImageGetHeight(sheet) != 14 || CGImageGetWidth(sheet) % 32 || !CGImageGetWidth(sheet))) {
        CGImageRelease(sheet);
        return NULL;
    }
    return sheet;
}

static APCanvas *APPalSpriteCanvas(NSString *species, NSString *coat, NSString *action, NSUInteger index) {
    CGImageRef sheet = APPalCreateSheetForUI(species, coat, action);
    if (!sheet) return NULL;
    NSUInteger frames = MAX(1, CGImageGetWidth(sheet) / 32);
    APCanvas *frame = APCanvasCreateFromCGImage(sheet, CGRectMake((index % frames) * 32, 0, 32, 14));
    CGImageRelease(sheet);
    return frame;
}

static APCanvas *APScaleCanvas(APCanvas *c, int scale) {
    APCanvas *big = APCanvasCreate(c->w * scale, c->h * scale);
    for (int y = 0; y < big->h; y++) for (int x = 0; x < big->w; x++) big->px[y * big->w + x] = c->px[(y / scale) * c->w + x / scale];
    return big;
}

UIImage *APPalSpriteImage(NSString *species, NSString *coat, NSString *action, NSUInteger index, int scale) {
    APCanvas *frame = APPalSpriteCanvas(species, coat, action, index);
    if (!frame) return nil;
    APCanvas *big = scale > 1 ? APScaleCanvas(frame, scale) : frame;
    UIImage *image = APUIImage(big);
    if (big != frame) APCanvasFree(big);
    APCanvasFree(frame);
    return image;
}

NSArray<UIImage *> *APPalSpriteFrames(NSString *species, NSString *coat, NSString *action, int scale) {
    CGImageRef sheet = APPalCreateSheetForUI(species, coat, action);
    NSUInteger count = sheet ? MAX(1, CGImageGetWidth(sheet) / 32) : 0;
    if (sheet) CGImageRelease(sheet);
    NSMutableArray *frames = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        UIImage *frame = APPalSpriteImage(species, coat, action, i, scale);
        if (frame) [frames addObject:frame];
    }
    return frames;
}

#pragma mark - View

typedef NS_ENUM(NSInteger, APShelterMode) { APShelterModeRoster, APShelterModeMeet, APShelterModeName, APShelterModeRehomed };

@interface ApolloPalHomeShelterView () <UITextFieldDelegate>
@property (nonatomic) APShelterMode mode;
@property (nonatomic, copy) NSArray<APShelterAnimal *> *animals;
@property (nonatomic) NSUInteger page; // the roster shows 8 at a time
@property (nonatomic, copy, nullable) NSString *keepName;
@property (nonatomic, strong, nullable) APShelterAnimal *chosen;
@property (nonatomic, copy, nullable) NSString *renameSpecies; // the resident id being renamed
@property (nonatomic, strong) UIControl *scrim;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong, nullable) ApolloPixelLabel *nameLabel;
@property (nonatomic, strong, nullable) UIView *cursor;
@property (nonatomic) CGSize builtSize;
@end

@implementation ApolloPalHomeShelterView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _pixelScale = 2;
        _scrim = [UIControl new];
        _scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        [self addSubview:_scrim];
        _panel = [UIView new];
        [self addSubview:_panel];
        _field = [UITextField new];
        _field.alpha = 0.02;
        _field.delegate = self;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeWords;
        _field.returnKeyType = UIReturnKeyDone;
        _field.accessibilityLabel = @"Name";
        [_field addTarget:self action:@selector(nameChanged) forControlEvents:UIControlEventEditingChanged];
        [self addSubview:_field];
        self.accessibilityViewIsModal = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rebuild) name:APChromeDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)showRoster:(NSArray<APShelterAnimal *> *)animals keepName:(NSString *)keepName {
    self.animals = animals;
    self.page = 0;
    self.keepName = keepName;
    self.renameSpecies = nil;
    self.mode = APShelterModeRoster;
    [self rebuild];
}

- (void)showRenameForResident:(NSString *)residentID species:(NSString *)species coat:(NSString *)coat currentName:(NSString *)name {
    APShelterAnimal *pal = [APShelterAnimal new];
    pal.species = species;
    pal.coat = coat;
    pal.name = name;
    self.chosen = pal;
    self.renameSpecies = residentID;
    self.mode = APShelterModeName;
    self.field.text = name;
    [self rebuild];
}

- (void)setKeyboardHeight:(CGFloat)keyboardHeight {
    if (_keyboardHeight == keyboardHeight) return;
    _keyboardHeight = keyboardHeight;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.scrim.frame = self.bounds;
    if (!CGSizeEqualToSize(self.builtSize, self.bounds.size)) [self rebuild];
    [self positionPanel];
}

- (int)panelWidth { return MIN(150, (int)floor(self.bounds.size.width / self.pixelScale) - 6); }

- (void)positionPanel {
    CGFloat p = self.pixelScale;
    CGSize size = self.panel.bounds.size;
    CGFloat x = round((self.bounds.size.width - size.width) / 2 / p) * p;
    CGFloat available = self.bounds.size.height - self.safeInsets.top - MAX(self.safeInsets.bottom, self.keyboardHeight);
    CGFloat y = self.safeInsets.top + MAX(4 * p, round((available - size.height) / 2 / p) * p);
    self.panel.frame = CGRectMake(x, y, size.width, size.height);
}

#pragma mark Building

- (ApolloPixelButton *)button:(NSString *)icon label:(NSString *)label action:(SEL)action {
    ApolloPixelButton *button = [[ApolloPixelButton alloc] initWithIcon:icon accessibilityLabel:label];
    button.tileWidth = 18;
    button.tileHeight = 16;
    button.pixelScale = self.pixelScale;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// A raised button with an icon and a pixel word, e.g. ♥ ADOPT.
- (ApolloPixelButton *)wordButton:(NSString *)icon word:(NSString *)word action:(SEL)action {
    APCanvas *icn = APIconCanvas(icon);
    int tw = APTextWidth(word.uppercaseString, APFontSmall);
    APCanvas *content = APCanvasCreate(icn->w + 3 + tw, MAX(icn->h, 6));
    // Forward arrows trail the word ("MORE ▸"); everything else leads.
    BOOL trailing = [icon isEqualToString:@"next"];
    APDraw(content, icn, trailing ? tw + 3 : 0, (content->h - icn->h) / 2, NO);
    APTextShadow(content, word.uppercaseString, trailing ? 0 : icn->w + 3, (content->h - 6) / 2, APFontSmall, APChromeCurrent().text, APChromeCurrent().shadow);
    ApolloPixelButton *button = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:word];
    button.iconName = nil;
    button.content = [APCanvasBox boxWithCanvas:content];
    button.tileWidth = content->w + 10;
    button.tileHeight = 16;
    button.pixelScale = self.pixelScale;
    APCanvasFree(icn);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)place:(UIView *)view x:(int)x y:(int)y {
    CGFloat p = self.pixelScale;
    CGSize size = [view isKindOfClass:ApolloPixelButton.class] ? [(ApolloPixelButton *)view pixelSize] : view.bounds.size;
    view.frame = CGRectMake(x * p, y * p, size.width, size.height);
    [self.panel addSubview:view];
}

- (ApolloPixelLabel *)label:(NSString *)text font:(APFont)font role:(int)role max:(int)max {
    ApolloPixelLabel *label = [ApolloPixelLabel new];
    label.pixelScale = self.pixelScale;
    label.font = font;
    label.maxWidth = max;
    label.themeRole = role;
    label.text = text;
    return label;
}

- (void)centerLabel:(ApolloPixelLabel *)label y:(int)y width:(int)W {
    CGSize s = label.intrinsicContentSize;
    int w = (int)round(s.width / self.pixelScale);
    label.frame = CGRectMake((W - w) / 2 * self.pixelScale, y * self.pixelScale, s.width, s.height);
    [self.panel addSubview:label];
}

- (void)setPanelBackgroundWidth:(int)W height:(int)H {
    CGFloat p = self.pixelScale;
    for (UIView *view in self.panel.subviews) [view removeFromSuperview];
    ApolloPixelImageView *back = [ApolloPixelImageView new];
    back.pixelScale = p;
    APCanvas *panel = APPanelCanvas(W, H);
    [back setCanvas:panel];
    APCanvasFree(panel);
    back.frame = CGRectMake(0, 0, W * p, H * p);
    [self.panel addSubview:back];
    self.panel.bounds = CGRectMake(0, 0, W * p, H * p);
}

- (void)rebuild {
    if (self.bounds.size.width < 1) return;
    self.builtSize = self.bounds.size;
    self.nameLabel = nil;
    self.cursor = nil;
    switch (self.mode) {
        case APShelterModeRoster: [self buildRoster]; break;
        case APShelterModeMeet: [self buildMeet]; break;
        case APShelterModeName: [self buildName]; break;
        case APShelterModeRehomed: [self buildRehomed]; break;
    }
    [self positionPanel];
}

static const NSUInteger kRosterPageSize = 8;

- (NSUInteger)pageCount { return MAX(1, (self.animals.count + kRosterPageSize - 1) / kRosterPageSize); }

- (void)nextPage {
    self.page = (self.page + 1) % self.pageCount;
    [self rebuild];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.panel);
}

- (void)buildRoster {
    int W = self.panelWidth, cardW = (W - 12 - 3) / 2, cardH = 36, gap = 3;
    // Two pages of eight: Reborn species lead the first. Both pages are laid
    // out at full height so the panel doesn't jump when paging.
    self.page = MIN(self.page, self.pageCount - 1);
    NSUInteger first = self.page * kRosterPageSize, shown = MIN(kRosterPageSize, self.animals.count - MIN(first, self.animals.count));
    int rows = MAX(1, (int)(self.pageCount > 1 ? kRosterPageSize : shown + 1) / 2);
    // Pals you said goodbye to get their own row up top, so it's always there.
    BOOL oldFriends = self.rehomed.count > 0;
    int gridY = 24 + (oldFriends ? 19 : 0), H = gridY + rows * cardH + (rows - 1) * gap + 26;
    [self setPanelBackgroundWidth:W height:H];
    [self centerLabel:[self label:@"Paws & Claws" font:APFontLarge role:0 max:W - 8] y:5 width:W];
    if (oldFriends) {
        NSString *word = [NSString stringWithFormat:@"Old friends (%lu): welcome back", (unsigned long)self.rehomed.count];
        ApolloPixelButton *home = [self wordButton:@"house" word:word action:@selector(showRehomed)];
        if (home.tileWidth > W - 12) home = [self wordButton:@"house" word:[NSString stringWithFormat:@"Old friends (%lu)", (unsigned long)self.rehomed.count]
                                                      action:@selector(showRehomed)];
        home.accessibilityLabel = [NSString stringWithFormat:@"Old friends, %lu", (unsigned long)self.rehomed.count];
        home.accessibilityHint = @"Pals you said goodbye to. Tap to welcome one back home.";
        [self place:home x:(W - home.tileWidth) / 2 y:23];
    }
    [self centerLabel:[self label:self.full ? @"Your home is full · just looking" : @"Shelter · new faces every day"
                                 font:APFontSmall role:self.full ? 2 : 1 max:W - 8] y:14 width:W];
    if (!self.animals.count) {
        [self centerLabel:[self label:@"Everyone found a home!" font:APFontSmall role:2 max:W - 8] y:gridY + 14 width:W];
    }
    for (NSUInteger slot = 0; slot < shown; slot++) {
        NSUInteger i = first + slot;
        APShelterAnimal *a = self.animals[i];
        APCanvas *content = APCanvasCreate(cardW - 4, cardH - 5);
        APCanvas *sprite = APPalSpriteCanvas(a.species, a.coat, @"sit", 0);
        if (sprite) { APDraw(content, sprite, (content->w - 32) / 2, 0, NO); APCanvasFree(sprite); }
        APChromeTheme t = APChromeCurrent();
        BOOL isNew = [APSpecies speciesWithID:a.species].reborn;
        if (isNew) {
            // A little tag for species Apollo never had.
            int tw = APTextWidth(@"NEW", APFontSmall) + 4;
            APRect(content, 1, 1, tw, 7, t.accent);
            uint32_t c = t.accent;
            int luma = (int)(((c >> 16) & 255) * 299 + ((c >> 8) & 255) * 587 + (c & 255) * 114) / 1000;
            APText(content, @"NEW", 3, 2, APFontSmall, luma > 150 ? 0x1A1410 : 0xFFFFFF);
        }
        NSString *name = a.name.uppercaseString;
        while (name.length > 1 && APTextWidth(name, APFontSmall) > content->w - 2) name = [name substringToIndex:name.length - 1];
        APTextShadow(content, name, (content->w - APTextWidth(name, APFontSmall)) / 2, 16, APFontSmall, t.text, t.shadow);
        // Age and species, dropping the species (never chopping words) if it won't fit.
        NSString *age = [APShelter ageTextForMonths:a.ageMonths species:a.species].uppercaseString;
        NSString *line = [NSString stringWithFormat:@"%@ %@", age, [APShelter titleForSpecies:a.species].uppercaseString];
        if (APTextWidth(line, APFontSmall) > content->w - 9) line = age;
        int lw = APTextWidth(line, APFontSmall) + (a.gender.length ? 7 : 0), lx = (content->w - lw) / 2;
        if (a.gender.length) { APCanvas *g = APIconCanvas(a.gender); APDraw(content, g, lx, 23, NO); APCanvasFree(g); lx += 7; }
        APText(content, line, lx, 24, APFontSmall, t.subtext);
        ApolloPixelButton *card = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:a.name];
        card.iconName = nil;
        card.flat = YES;
        card.tileWidth = cardW;
        card.tileHeight = cardH;
        card.content = [APCanvasBox boxWithCanvas:content];
        card.pixelScale = self.pixelScale;
        card.tag = (NSInteger)i;
        card.accessibilityValue = [APShelter summaryForSpecies:a.species gender:a.gender ageMonths:a.ageMonths];
        if (isNew) card.accessibilityValue = [@"New species. " stringByAppendingString:card.accessibilityValue];
        card.accessibilityHint = @"Meet them.";
        [card addTarget:self action:@selector(meet:) forControlEvents:UIControlEventTouchUpInside];
        [self place:card x:6 + (int)(slot % 2) * (cardW + gap) y:gridY + (int)(slot / 2) * (cardH + gap)];
    }
    int footY = H - 21;
    ApolloPixelButton *close = self.keepName ? [self wordButton:@"back" word:[NSString stringWithFormat:@"Keep %@", self.keepName] action:@selector(close)]
                                             : [self wordButton:@"back" word:@"Maybe later" action:@selector(close)];
    ApolloPixelButton *more = nil;
    if (self.pageCount > 1) {
        more = self.page + 1 < self.pageCount ? [self wordButton:@"next" word:@"More" action:@selector(nextPage)]
                                              : [self wordButton:@"back" word:@"First page" action:@selector(nextPage)];
        more.accessibilityValue = [NSString stringWithFormat:@"Page %lu of %lu", (unsigned long)self.page + 1, (unsigned long)self.pageCount];
        [self place:more x:W - 6 - more.tileWidth y:footY];
    }
    int room = W - 12 - (more ? more.tileWidth + 3 : 0);
    if (close.tileWidth > room) close = [self wordButton:@"back" word:@"Not now" action:@selector(close)];
    [self place:close x:6 y:footY];
}

- (void)showRehomed {
    self.mode = APShelterModeRehomed;
    [self rebuild];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.panel);
}

// The Pals you've said goodbye to, newest first: tap one to welcome them back
// (with their room and memories).
- (void)buildRehomed {
    int W = self.panelWidth, cardW = (W - 12 - 3) / 2, cardH = 36, gap = 3;
    NSArray<NSDictionary *> *entries = self.rehomed.count > 8 ? [self.rehomed subarrayWithRange:NSMakeRange(0, 8)] : self.rehomed;
    ApolloPixelLabel *intro = [self label:@"Pals you said goodbye to. Tap one to welcome them back." font:APFontSmall role:1 max:W - 12];
    intro.smooth = YES;
    int gridY = 16 + intro.pixelHeight + 4;
    int rows = MAX(1, ((int)entries.count + 1) / 2);
    int H = gridY + rows * cardH + (rows - 1) * gap + 26;
    [self setPanelBackgroundWidth:W height:H];
    [self centerLabel:[self label:@"Old friends" font:APFontLarge role:0 max:W - 8] y:5 width:W];
    [self centerLabel:intro y:15 width:W];
    APChromeTheme t = APChromeCurrent();
    for (NSUInteger i = 0; i < entries.count; i++) {
        NSDictionary *entry = entries[i];
        APCanvas *content = APCanvasCreate(cardW - 4, cardH - 5);
        APCanvas *sprite = APPalSpriteCanvas(entry[@"species"], [entry[@"coat"] isKindOfClass:NSString.class] ? entry[@"coat"] : @"original", @"sit", 0);
        if (sprite) { APDraw(content, sprite, (content->w - 32) / 2, 0, NO); APCanvasFree(sprite); }
        NSString *name = [entry[@"name"] uppercaseString];
        while (name.length > 1 && APTextWidth(name, APFontSmall) > content->w - 2) name = [name substringToIndex:name.length - 1];
        APTextShadow(content, name, (content->w - APTextWidth(name, APFontSmall)) / 2, 16, APFontSmall, t.text, t.shadow);
        double at = [entry[@"at"] isKindOfClass:NSNumber.class] ? [entry[@"at"] doubleValue] : NSDate.date.timeIntervalSinceReferenceDate;
        int days = MAX(0, (int)((NSDate.date.timeIntervalSinceReferenceDate - at) / 86400));
        NSString *when = days == 0 ? @"TODAY" : days == 1 ? @"YESTERDAY" : [NSString stringWithFormat:@"%d DAYS AGO", days];
        APText(content, when, (content->w - APTextWidth(when, APFontSmall)) / 2, 24, APFontSmall, t.subtext);
        ApolloPixelButton *card = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:entry[@"name"]];
        card.iconName = nil;
        card.flat = YES;
        card.tileWidth = cardW;
        card.tileHeight = cardH;
        card.content = [APCanvasBox boxWithCanvas:content];
        card.pixelScale = self.pixelScale;
        card.tag = (NSInteger)i;
        card.accessibilityValue = [NSString stringWithFormat:@"%@, rehomed %@", [APShelter titleForSpecies:entry[@"species"]], when.lowercaseString];
        card.accessibilityHint = @"Welcome them back home.";
        [card addTarget:self action:@selector(bringBack:) forControlEvents:UIControlEventTouchUpInside];
        [self place:card x:6 + (int)(i % 2) * (cardW + gap) y:gridY + (int)(i / 2) * (cardH + gap)];
    }
    [self place:[self wordButton:@"back" word:@"Back to the shelter" action:@selector(backToRoster)] x:6 y:H - 21];
}

- (void)homeIsFull {
    [self.delegate shelterHomeIsFull:self];
}

- (void)bringBack:(ApolloPixelButton *)sender {
    if (self.full) { [self homeIsFull]; return; }
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.rehomed.count) return;
    [self.delegate shelter:self bringBack:self.rehomed[sender.tag][@"id"]];
}

- (void)buildMeet {
    APShelterAnimal *a = self.chosen;
    int W = self.panelWidth;
    APChromeTheme t = APChromeCurrent();
    // Body copy in the smooth style (see ApolloPixelLabel.smooth); measured
    // first so the panel fits it.
    ApolloPixelLabel *(^body)(NSString *, int) = ^ApolloPixelLabel *(NSString *text, int role) {
        ApolloPixelLabel *label = [self label:text font:APFontSmall role:role max:W - 12];
        label.smooth = YES;
        return label;
    };
    NSString *coatTitle = @"Original";
    for (APCoat *coat in [APPixelPalCoats coatsForSpecies:a.species]) if ([coat.identifier isEqual:a.coat]) coatTitle = coat.title;
    ApolloPixelLabel *summary = body([APShelter summaryForSpecies:a.species gender:a.gender ageMonths:a.ageMonths], 1);
    ApolloPixelLabel *blurb = body([APShelter blurbForPersonality:a.personality], 0);
    ApolloPixelLabel *quirk = body(a.quirk, 0);
    ApolloPixelLabel *coat = body([NSString stringWithFormat:@"%@ coat", coatTitle], 1);
    int y = 60;
    int titleY = y; y += 8;
    int blurbY = y; y += blurb.pixelHeight + 3;
    int quirkTitleY = y; y += 8;
    int quirkY = y; y += quirk.pixelHeight + 2;
    int coatY = y; y += coat.pixelHeight;
    int H = y + 28;
    [self setPanelBackgroundWidth:W height:H];
    [self centerLabel:[self label:a.name font:APFontLarge role:0 max:W - 8] y:5 width:W];
    [self centerLabel:summary y:15 width:W];
    // Big sprite pacing on a cushion.
    APCanvas *cushion = APCanvasCreate(72, 34);
    APEllipse(cushion, 4, 22, 64, 11, APShade(t.panel.d, 0.8f));
    APEllipse(cushion, 6, 22, 60, 8, t.toggled.m);
    APHLine(cushion, 14, 23, 44, t.toggled.l);
    ApolloPixelImageView *base = [ApolloPixelImageView new];
    base.pixelScale = self.pixelScale;
    [base setCanvas:cushion];
    APCanvasFree(cushion);
    [self place:base x:(W - 72) / 2 y:24];
    ApolloPixelImageView *sprite = [ApolloPixelImageView new];
    sprite.pixelScale = self.pixelScale;
    NSArray *frames = APPalSpriteFrames(a.species, a.coat, @"walk", 2);
    sprite.image = frames.firstObject ?: APPalSpriteImage(a.species, a.coat, @"sit", 0, 2);
    sprite.frame = CGRectMake(0, 0, 64 * self.pixelScale, 28 * self.pixelScale);
    if (frames.count > 1 && !UIAccessibilityIsReduceMotionEnabled()) {
        sprite.animationImages = frames;
        sprite.animationDuration = 0.9;
        [sprite startAnimating];
    }
    sprite.isAccessibilityElement = YES;
    sprite.accessibilityLabel = [NSString stringWithFormat:@"%@, a %@", a.name, [APShelter titleForSpecies:a.species]];
    [self place:sprite x:(W - 64) / 2 y:26];
    [self centerLabel:[self label:[APShelter titleForPersonality:a.personality] font:APFontSmall role:2 max:W - 8] y:titleY width:W];
    [self centerLabel:blurb y:blurbY width:W];
    [self centerLabel:[self label:@"Quirk" font:APFontSmall role:2 max:W - 8] y:quirkTitleY width:W];
    [self centerLabel:quirk y:quirkY width:W];
    [self centerLabel:coat y:coatY width:W];
    ApolloPixelButton *back = [self button:@"back" label:@"Back to the shelter" action:@selector(backToRoster)];
    ApolloPixelButton *adopt = [self wordButton:@"heart" word:@"Adopt" action:self.full ? @selector(homeIsFull) : @selector(startNaming)];
    adopt.accessibilityHint = self.full ? @"Your home is full. Say goodbye to a Pal to make room."
                                        : [NSString stringWithFormat:@"Bring %@ home.", a.name];
    if (self.full) adopt.alpha = 0.45;
    [self place:back x:6 y:H - 21];
    [self place:adopt x:W - 6 - adopt.tileWidth y:H - 21];
}

- (void)buildName {
    APShelterAnimal *a = self.chosen;
    int W = self.panelWidth, H = 78;
    [self setPanelBackgroundWidth:W height:H];
    [self centerLabel:[self label:self.renameSpecies ? @"A new name?" : @"Name your new Pal" font:APFontLarge role:0 max:W - 8] y:5 width:W];
    ApolloPixelImageView *sprite = [ApolloPixelImageView new];
    sprite.pixelScale = self.pixelScale;
    sprite.image = APPalSpriteImage(a.species, a.coat, @"sit", 0, 1);
    sprite.frame = CGRectMake(0, 0, 32 * self.pixelScale, 14 * self.pixelScale);
    [self place:sprite x:(W - 32) / 2 y:15];
    // The text box: a slot with pixel text and a blinking cursor.
    int boxW = W - 12, boxH = 14;
    ApolloPixelImageView *box = [ApolloPixelImageView new];
    box.pixelScale = self.pixelScale;
    APCanvas *slot = APChromeSlot(APChromeCurrent(), boxW, boxH, NO, YES);
    [box setCanvas:slot];
    APCanvasFree(slot);
    [self place:box x:6 y:33];
    self.nameLabel = [self label:self.field.text ?: @"" font:APFontLarge role:0 max:boxW - 8];
    [self.panel addSubview:self.nameLabel];
    self.cursor = [UIView new];
    self.cursor.backgroundColor = [UIColor colorWithRed:((APChromeCurrent().accent >> 16) & 255) / 255.0 green:((APChromeCurrent().accent >> 8) & 255) / 255.0 blue:(APChromeCurrent().accent & 255) / 255.0 alpha:1];
    [self.panel addSubview:self.cursor];
    [self layoutName];
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        CABasicAnimation *blink = [CABasicAnimation animationWithKeyPath:@"opacity"];
        blink.fromValue = @1; blink.toValue = @0; blink.duration = 0.5; blink.autoreverses = YES; blink.repeatCount = HUGE_VALF;
        [self.cursor.layer addAnimation:blink forKey:@"blink"];
    }
    UITapGestureRecognizer *focus = [[UITapGestureRecognizer alloc] initWithTarget:self.field action:@selector(becomeFirstResponder)];
    box.userInteractionEnabled = YES;
    [box addGestureRecognizer:focus];
    ApolloPixelButton *back = [self button:@"back" label:@"Back" action:@selector(nameBack)];
    ApolloPixelButton *dice = [self button:@"dice" label:@"Random name" action:@selector(randomName)];
    ApolloPixelButton *done = [self wordButton:@"check" word:self.renameSpecies ? @"Save" : @"Welcome home" action:@selector(confirmName)];
    [self place:back x:6 y:H - 21];
    [self place:dice x:26 y:H - 21];
    [self place:done x:W - 6 - done.tileWidth y:H - 21];
    self.field.frame = CGRectMake(0, 0, 1, 1);
    dispatch_async(dispatch_get_main_queue(), ^{ [self.field becomeFirstResponder]; });
}

- (void)layoutName {
    if (!self.nameLabel) return;
    CGFloat p = self.pixelScale;
    self.nameLabel.text = self.field.text.length ? self.field.text : @" ";
    CGSize s = self.nameLabel.intrinsicContentSize;
    int boxW = self.panelWidth - 12;
    int textW = (int)round(s.width / p);
    int x = 6 + MAX(4, (boxW - textW) / 2);
    self.nameLabel.frame = CGRectMake(x * p, 37 * p, s.width, s.height);
    self.cursor.frame = CGRectMake((x + textW + 1) * p, 36 * p, p, 9 * p);
    self.nameLabel.accessibilityLabel = [NSString stringWithFormat:@"Name: %@", self.field.text];
}

#pragma mark Actions

- (void)meet:(ApolloPixelButton *)sender {
    if (sender.tag >= (NSInteger)self.animals.count) return;
    self.chosen = self.animals[sender.tag];
    self.mode = APShelterModeMeet;
    [self rebuild];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.panel);
}

- (void)backToRoster {
    self.mode = APShelterModeRoster;
    [self rebuild];
}

- (void)startNaming {
    self.field.text = self.chosen.name;
    self.mode = APShelterModeName;
    [self rebuild];
}

- (void)nameBack {
    [self.field resignFirstResponder];
    if (self.renameSpecies) { [self.delegate shelterDidClose:self]; return; }
    self.mode = APShelterModeMeet;
    [self rebuild];
}

- (void)randomName {
    NSString *name = [APShelter randomNameForSpecies:self.chosen.species];
    for (int i = 0; i < 4 && [name isEqualToString:self.field.text]; i++) name = [APShelter randomNameForSpecies:self.chosen.species];
    self.field.text = name;
    [self layoutName];
    APHapticPlay(APHapticSelect);
}

- (void)nameChanged {
    if (self.field.text.length > 20) self.field.text = [self.field.text substringToIndex:20];
    [self layoutName];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self confirmName];
    return NO;
}

- (void)confirmName {
    NSString *name = [self.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) {
        [self randomName];
        return;
    }
    [self.field resignFirstResponder];
    if (self.renameSpecies) [self.delegate shelter:self rename:self.renameSpecies name:name];
    else [self.delegate shelter:self adopt:self.chosen name:name];
}

- (void)close {
    [self.field resignFirstResponder];
    [self.delegate shelterDidClose:self];
}

@end
