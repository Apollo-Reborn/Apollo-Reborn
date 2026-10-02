#import "ApolloPalHomeWardrobe.h"
#import "ApolloPalHomePixelUI.h"
#import "ApolloPalHomeRenderer.h"
#import "ApolloPalHomeShelter.h"
#import "ApolloPalHomeShelterView.h"
#import "ApolloPalHomeChrome.h"

static const int kWidth = 140, kPad = 6;

@interface ApolloPalHomeWardrobe ()
@property (nonatomic, copy) NSArray<ApolloPalHomeResident *> *household;
@property (nonatomic) int height;
@end

@implementation ApolloPalHomeWardrobe

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _pixelScale = 2;
        self.accessibilityViewIsModal = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rebuild) name:APChromeDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (int)pixelWidth { return kWidth; }
- (int)pixelHeight { return self.height ?: 120; }

- (void)setPixelScale:(CGFloat)pixelScale {
    if (_pixelScale == pixelScale) return;
    _pixelScale = pixelScale;
    [self rebuild];
}

- (void)configureWithHousehold:(NSArray<ApolloPalHomeResident *> *)household {
    self.household = household;
    [self rebuild];
}

- (ApolloPixelLabel *)label:(NSString *)text font:(APFont)font role:(int)role {
    ApolloPixelLabel *label = [ApolloPixelLabel new];
    label.pixelScale = self.pixelScale;
    label.font = font;
    label.maxWidth = kWidth - kPad * 2;
    label.themeRole = role;
    label.text = text;
    return label;
}

- (void)add:(UIView *)view x:(int)x y:(int)y {
    CGFloat p = self.pixelScale;
    CGSize size = [view isKindOfClass:ApolloPixelButton.class] ? [(ApolloPixelButton *)view pixelSize] : view.bounds.size;
    view.frame = CGRectMake(x * p, y * p, size.width, size.height);
    [self addSubview:view];
}

- (void)centre:(ApolloPixelLabel *)label y:(int)y {
    int w = (int)round(label.intrinsicContentSize.width / self.pixelScale);
    label.frame = CGRectMake((kWidth - w) / 2 * self.pixelScale, y * self.pixelScale, label.intrinsicContentSize.width, label.intrinsicContentSize.height);
    [self addSubview:label];
}

- (ApolloPixelButton *)button:(NSString *)icon label:(NSString *)label action:(SEL)action {
    ApolloPixelButton *button = [[ApolloPixelButton alloc] initWithIcon:icon accessibilityLabel:label];
    button.tileWidth = 18;
    button.tileHeight = 16;
    button.pixelScale = self.pixelScale;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (ApolloPixelLabel *)body:(NSString *)text role:(int)role {
    ApolloPixelLabel *label = [self label:text font:APFontSmall role:role];
    label.smooth = YES;
    return label;
}

- (void)rebuild {
    for (UIView *view in self.subviews) [view removeFromSuperview];
    ApolloPalHomeResident *pal = self.household.firstObject;
    if (!pal) return;
    CGFloat p = self.pixelScale;

    // Body copy first (smooth text), so the card can be measured.
    // Apollo's stats (age is in the summary line): weight, how far you've
    // scrolled together; then the pantry and when they'll next want a meal.
    NSMutableArray *stats = [NSMutableArray array];
    if (pal.weightInLbs) [stats addObject:APWardrobeWeight(pal.weightInLbs.doubleValue)];
    [stats addObject:[APWardrobeDistance(pal.kilometersScrolled) stringByAppendingString:@" scrolled together"]];
    NSTimeInterval wait = pal.lastFed ? APCareCooldown + pal.lastFed.timeIntervalSinceNow : 0;
    NSString *meal = wait > 60 ? [NSString stringWithFormat:@" · hungry in %dh %02dm", (int)(wait / 3600), (int)fmod(wait / 60, 60)]
                                                   : @" · ready for a snack";
    NSString *pantry = [NSString stringWithFormat:@"%ld food in the pantry%@", (long)self.foodTokens, meal];
    NSArray<NSArray *> *copy = @[
        @[[self body:[APShelter summaryForSpecies:pal.species gender:pal.gender ageMonths:pal.ageMonths] role:1], @0],
        @[[self body:[stats componentsJoinedByString:@" · "] role:1], @1],
        @[[self body:pantry role:2], @2],
        @[[self label:[APShelter titleForPersonality:pal.personality] font:APFontSmall role:2], @3],
        @[[self body:[APShelter blurbForPersonality:pal.personality] role:0], @4],
        @[[self body:pal.quirk role:1], @5],
    ];
    ApolloPixelLabel *(^text)(int) = ^ApolloPixelLabel *(int i) { return copy[i][0]; };
    int summaryY = 15;
    int sy = 22, heartsY = 51;
    int ty = heartsY + 8;
    // On the island, or just visiting (with a way to put them up there).
    BOOL onIsland = [pal.identifier isEqual:self.islandResidentID];
    ApolloPixelLabel *islandNote = nil;
    ApolloPixelButton *putOnIsland = nil;
    if (onIsland) {
        islandNote = [self body:self.islandEnabled ? @"On your Dynamic Island" : @"Your island Pal (the island is off)" role:2];
    } else {
        putOnIsland = [self wordButton:@"island" word:@"Put on the island"];
        putOnIsland.accessibilityHint = [NSString stringWithFormat:@"%@ takes over the Dynamic Island.", pal.name];
        [putOnIsland addTarget:self action:@selector(putOnIsland) forControlEvents:UIControlEventTouchUpInside];
    }
    int islandY = ty; ty += islandNote ? islandNote.pixelHeight + 1 : putOnIsland ? 18 : 0;
    int statsY = ty; ty += text(1).pixelHeight;
    int pantryY = ty; ty += text(2).pixelHeight + 4;
    int titleY = ty; ty += 8;
    int blurbY = ty; ty += text(4).pixelHeight + 1;
    int quirkY = ty; ty += text(5).pixelHeight;

    BOOL household = self.household.count > 1;
    int y = ty + 8;
    int householdY = y;
    // Everyone gets a tile: rows of as many as fit.
    int perRow = MAX(1, (kWidth - kPad * 2 + 2) / 26);
    int householdRows = household ? ((int)self.household.count - 1 + perRow - 1) / perRow : 0;
    if (household) y += 8 + householdRows * 19 - 1;
    self.height = y + 22;

    ApolloPixelImageView *panel = [ApolloPixelImageView new];
    panel.pixelScale = p;
    APCanvas *panelCanvas = APPanelCanvas(kWidth, self.height);
    [panel setCanvas:panelCanvas];
    APCanvasFree(panelCanvas);
    [self add:panel x:0 y:0];

    [self centre:[self label:pal.name font:APFontLarge role:0] y:5];
    [self centre:text(0) y:summaryY];
    // The Pal, pacing.
    ApolloPixelImageView *sprite = [ApolloPixelImageView new];
    sprite.pixelScale = p;
    NSArray *frames = APPalSpriteFrames(pal.species, pal.coat, @"walk", 2);
    sprite.image = frames.firstObject ?: APPalSpriteImage(pal.species, pal.coat, @"sit", 0, 2);
    sprite.frame = CGRectMake(0, 0, 64 * p, 28 * p);
    if (frames.count > 1 && !UIAccessibilityIsReduceMotionEnabled()) {
        sprite.animationImages = frames;
        sprite.animationDuration = 0.9;
        [sprite startAnimating];
    }
    sprite.isAccessibilityElement = YES;
    sprite.accessibilityLabel = pal.name;
    [self add:sprite x:(kWidth - 64) / 2 y:sy];
    // Friendship hearts (Apollo's own).
    if (pal.hearts) {
        double hearts = pal.hearts.doubleValue;
        APCanvas *row = APCanvasCreate(35, 5);
        for (int i = 0; i < 6; i++) {
            APChromeHeart(row, i * 6, 0, hearts >= i + 1 ? 1 : hearts >= i + 0.5 ? 0.5f : 0, APShade(APChromeCurrent().panel.d, 0.8f), 0);
        }
        ApolloPixelImageView *heartsView = [ApolloPixelImageView new];
        heartsView.pixelScale = p;
        [heartsView setCanvas:row];
        APCanvasFree(row);
        heartsView.isAccessibilityElement = YES;
        heartsView.accessibilityLabel = [NSString stringWithFormat:@"%g of 6 friendship hearts", floor(hearts * 4) / 4];
        [self add:heartsView x:(kWidth - 35) / 2 y:heartsY];
    }
    if (islandNote) [self centre:islandNote y:islandY];
    if (putOnIsland) [self add:putOnIsland x:(kWidth - putOnIsland.tileWidth) / 2 y:islandY];
    [self centre:text(1) y:statsY];
    [self centre:text(2) y:pantryY];
    [self centre:text(3) y:titleY];
    [self centre:text(4) y:blurbY];
    [self centre:text(5) y:quirkY];

    if (household) {
        // The rest of the household: tap to swap who's home.
        [self add:[self label:@"Household" font:APFontSmall role:2] x:kPad y:householdY];
        for (NSUInteger i = 1; i < self.household.count; i++) {
            int slot = (int)i - 1, x = kPad + (slot % perRow) * 26, rowY = householdY + 7 + (slot / perRow) * 19;
            ApolloPalHomeResident *other = self.household[i];
            BOOL otherOnIsland = [other.identifier isEqual:self.islandResidentID];
            ApolloPixelButton *cell = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:[NSString stringWithFormat:@"Visit %@", other.name]];
            if (otherOnIsland) cell.accessibilityValue = @"On the Dynamic Island";
            cell.iconName = nil;
            cell.flat = YES;
            cell.tileWidth = 24;
            cell.tileHeight = 17;
            UIImage *face = APPalSpriteImage(other.species, other.coat, @"sit", 0, 1);
            if (face.CGImage) {
                // A 24px window centred on the Pal itself (some, like the
                // capybara, fill more of the 32px frame than others).
                APCanvas *whole = APCanvasCreateFromCGImage(face.CGImage, CGRectMake(0, 0, 32, 14));
                int minX = 32, maxX = -1;
                for (int y = 0; y < whole->h; y++) for (int x = 0; x < whole->w; x++) {
                    if (APOpaqueAt(whole, x, y)) { minX = MIN(minX, x); maxX = MAX(maxX, x); }
                }
                APCanvasFree(whole);
                int left = maxX >= minX ? MAX(0, MIN(8, (minX + maxX + 1) / 2 - 12)) : 4;
                APCanvas *full = APCanvasCreateFromCGImage(face.CGImage, CGRectMake(left, 0, 24, 14));
                if (otherOnIsland) {
                    // A tiny island pill in the corner: this one's up there.
                    APRect(full, 17, 0, 6, 3, 0x1A1A1E);
                    APPx(full, 16, 1, 0x1A1A1E); APPx(full, 23, 1, 0x1A1A1E);
                }
                cell.content = [APCanvasBox boxWithCanvas:full];
            }
            cell.pixelScale = p;
            cell.tag = (NSInteger)i;
            [cell addTarget:self action:@selector(switchPal:) forControlEvents:UIControlEventTouchUpInside];
            [self add:cell x:x y:rowY];
        }
    }
    int fy = self.height - 21;
    ApolloPixelButton *rename = [self button:@"pencil" label:[NSString stringWithFormat:@"Rename %@", pal.name] action:@selector(rename)];
    ApolloPixelButton *shelter = [self button:@"shelter" label:@"Visit the shelter" action:@selector(shelter)];
    shelter.accessibilityHint = @"Adopt another Pal.";
    ApolloPixelButton *widget = [self button:@"widget" label:@"Copy Pal code for the widget" action:@selector(widget)];
    widget.accessibilityHint = @"Paste it into the Pal Home widget on your Home Screen.";
    ApolloPixelButton *island = [self button:self.islandEnabled ? @"island" : @"island.off" label:@"Show on the Dynamic Island" action:@selector(island)];
    island.accessibilityValue = self.islandEnabled ? @"On" : @"Off";
    island.accessibilityHint = @"Your Pal lives up on the Dynamic Island while you browse.";
    ApolloPixelButton *goodbye = [self button:@"wave" label:[NSString stringWithFormat:@"Say goodbye to %@", pal.name] action:@selector(goodbye)];
    goodbye.accessibilityHint = household ? @"Rehome them with a loving new family." : @"They're your only Pal.";
    goodbye.alpha = household ? 1 : 0.45;
    ApolloPixelButton *done = [self button:@"check" label:@"Done" action:@selector(done)];
    [self add:rename x:kPad y:fy];
    [self add:shelter x:kPad + 20 y:fy];
    [self add:widget x:kPad + 40 y:fy];
    [self add:island x:kPad + 60 y:fy];
    [self add:goodbye x:kPad + 80 y:fy];
    [self add:done x:kWidth - kPad - 18 y:fy];
    self.bounds = CGRectMake(0, 0, kWidth * p, self.height * p);
}

static NSString *APWardrobeWeight(double lbs) {
    if (NSLocale.currentLocale.usesMetricSystem) {
        double kg = lbs * 0.45359237;
        return kg < 1 ? [NSString stringWithFormat:@"%.0f g", MAX(1, kg * 1000)] : [NSString stringWithFormat:@"%.1f kg", kg];
    }
    return lbs < 1 ? [NSString stringWithFormat:@"%.0f oz", MAX(1, lbs * 16)] : [NSString stringWithFormat:@"%.1f lbs", lbs];
}

static NSString *APWardrobeDistance(double km) {
    if (NSLocale.currentLocale.usesMetricSystem) {
        return km < 1 ? [NSString stringWithFormat:@"%.0f m", km * 1000] : [NSString stringWithFormat:@"%.1f km", km];
    }
    double miles = km * 0.621371;
    return miles < 0.5 ? [NSString stringWithFormat:@"%.0f ft", km * 3280.84] : [NSString stringWithFormat:@"%.1f mi", miles];
}

- (void)switchPal:(ApolloPixelButton *)sender {
    if (sender.tag < (NSInteger)self.household.count) [self.delegate wardrobe:self switchTo:self.household[sender.tag]];
}
- (void)rename { [self.delegate wardrobe:self wantsRename:self.household.firstObject]; }
- (void)shelter { [self.delegate wardrobeWantsShelter:self]; }
- (void)widget { [self.delegate wardrobeWantsWidgetCode:self]; }
- (void)done { [self.delegate wardrobeDidFinish:self]; }
- (void)island { [self.delegate wardrobeToggledIsland:self]; }
- (void)putOnIsland { [self.delegate wardrobe:self putOnIsland:self.household.firstObject]; }

- (ApolloPixelButton *)wordButton:(NSString *)icon word:(NSString *)word {
    APCanvas *icn = APIconCanvas(icon);
    int tw = APTextWidth(word.uppercaseString, APFontSmall);
    APCanvas *content = APCanvasCreate(icn->w + 3 + tw, MAX(icn->h, 6));
    APDraw(content, icn, 0, (content->h - icn->h) / 2, NO);
    APTextShadow(content, word.uppercaseString, icn->w + 3, (content->h - 6) / 2, APFontSmall, APChromeCurrent().text, APChromeCurrent().shadow);
    APCanvasFree(icn);
    ApolloPixelButton *button = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:word];
    button.iconName = nil;
    button.content = [APCanvasBox boxWithCanvas:content];
    button.tileWidth = content->w + 10;
    button.tileHeight = 16;
    button.pixelScale = self.pixelScale;
    return button;
}

- (void)goodbye { [self.delegate wardrobe:self wantsGoodbye:self.household.firstObject]; }

@end
