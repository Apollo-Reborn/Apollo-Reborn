#import "ApolloPalHomeDrawer.h"
#import "ApolloPalHomeHaptics.h"

static const int kHeaderY = 5, kTabsY = 24, kShelfY = 43, kShelfH = 60;

@interface ApolloPalHomeDrawer ()
@property (nonatomic, strong) ApolloPixelImageView *panel;
@property (nonatomic, strong) ApolloPixelLabel *titleLabel, *subtitleLabel;
@property (nonatomic, strong) ApolloPixelButton *doneButton, *flipButton, *variantButton, *toggleButton, *awayButton, *lightingButton, *undoButton;
@property (nonatomic, copy) NSArray<ApolloPixelButton *> *tabs;
@property (nonatomic, strong) UIScrollView *shelf;
@property (nonatomic) APCategory shelfCategory;
@property (nonatomic) BOOL shelfBuilt;
@property (nonatomic, strong, nullable) APStyleSpec *pendingStyle; // choosing how to apply it
@property (nonatomic) CGFloat styleListOffset;
// Actions for the selected piece float in a little wooden bubble above the
// drawer, so the header keeps room for the item's name.
@property (nonatomic, strong) UIView *actionBar;
@property (nonatomic, strong) ApolloPixelImageView *actionPanel;
@property (nonatomic, strong, nullable) APPlacedItem *selection;
@property (nonatomic, strong, nullable) APRoomLayout *layout;
@property (nonatomic, copy, nullable) NSString *flash;
@end

@implementation ApolloPalHomeDrawer

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _pixelScale = 2;
        _pixelWidth = 150;
        _panel = [ApolloPixelImageView new];
        [self addSubview:_panel];
        _titleLabel = [ApolloPixelLabel new];
        _subtitleLabel = [ApolloPixelLabel new];
        _subtitleLabel.themeRole = 1;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(setNeedsLayout) name:APChromeDidChangeNotification object:nil];
        [self addSubview:_titleLabel];
        [self addSubview:_subtitleLabel];
        _actionBar = [UIView new];
        _actionPanel = [ApolloPixelImageView new];
        [_actionBar addSubview:_actionPanel];
        [self addSubview:_actionBar];
        _doneButton = [self button:@"check" label:@"Done decorating" action:@selector(done)];
        _flipButton = [self button:@"flip" label:@"Flip" action:@selector(flip)];
        _variantButton = [self button:@"palette" label:@"Change colour" action:@selector(variant)];
        _toggleButton = [self button:@"bulb" label:@"Switch on or off" action:@selector(toggle)];
        _awayButton = [self button:@"box" label:@"Put away" action:@selector(putAway)];
        _lightingButton = [self button:@"sun" label:@"Room lighting" action:@selector(lighting)];
        _undoButton = [self button:@"undo" label:@"Undo style change" action:@selector(undo)];
        _undoButton.hidden = YES;
        NSArray *icons = @[@"house", @"sofa", @"candle", @"rug", @"window", @"art", @"wallpaper", @"floor"];
        NSMutableArray *tabs = [NSMutableArray array];
        for (NSInteger i = 0; i < APCategoryCount; i++) {
            ApolloPixelButton *tab = [self button:icons[i] label:[APCatalog titleForCategory:i] action:@selector(tabTapped:)];
            tab.tag = i;
            tab.tileWidth = 15;
            tab.tileHeight = 15;
            [tabs addObject:tab];
        }
        _tabs = tabs;
        _shelf = [UIScrollView new];
        _shelf.showsHorizontalScrollIndicator = NO;
        _shelf.showsVerticalScrollIndicator = NO;
        _shelf.alwaysBounceHorizontal = YES;
        [self addSubview:_shelf];
        self.accessibilityElements = nil;
    }
    return self;
}

- (ApolloPixelButton *)button:(NSString *)icon label:(NSString *)label action:(SEL)action {
    ApolloPixelButton *button = [[ApolloPixelButton alloc] initWithIcon:icon accessibilityLabel:label];
    button.tileWidth = 18;
    button.tileHeight = 16;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];
    return button;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (int)pixelHeight { return kShelfY + kShelfH + 4; }

- (void)setPixelScale:(CGFloat)pixelScale { _pixelScale = pixelScale; [self setNeedsLayout]; [self rebuildShelf]; }
- (void)setPixelWidth:(int)pixelWidth { _pixelWidth = pixelWidth; [self setNeedsLayout]; }
- (void)setCategory:(APCategory)category { _category = category; self.pendingStyle = nil; [self refreshHeader]; [self rebuildShelf]; }
- (void)setCanUndo:(BOOL)canUndo { _canUndo = canUndo; [self refreshHeader]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat p = self.pixelScale;
    // The panel runs past the bottom edge (into the home-indicator area).
    int panelH = (int)ceil(self.bounds.size.height / p) + 4;
    APCanvas *panel = APPanelCanvas(self.pixelWidth, panelH);
    self.panel.pixelScale = p;
    [self.panel setCanvas:panel];
    APCanvasFree(panel);
    self.panel.frame = CGRectMake(0, 0, self.pixelWidth * p, panelH * p);
    [self layoutHeader];
    int x = 6;
    for (ApolloPixelButton *tab in self.tabs) {
        tab.pixelScale = p;
        tab.frame = CGRectMake(x * p, kTabsY * p, tab.tileWidth * p, tab.tileHeight * p);
        x += tab.tileWidth + 1;
    }
    self.shelf.frame = CGRectMake(3 * p, kShelfY * p, (self.pixelWidth - 6) * p, kShelfH * p);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // The action bubble sits above our bounds; still deliver its touches.
    if (!self.actionBar.hidden) {
        UIView *hit = [self.actionBar hitTest:[self convertPoint:point toView:self.actionBar] withEvent:event];
        if (hit) return hit;
    }
    return [super hitTest:point withEvent:event];
}

- (void)layoutHeader {
    CGFloat p = self.pixelScale;
    int right = self.pixelWidth - 6;
    APPlacedItem *item = self.selection;
    NSMutableArray *header = [NSMutableArray arrayWithObject:self.doneButton];
    if (!item) [header addObject:self.lightingButton];
    if (!item && self.canUndo) [header addObject:self.undoButton];
    self.lightingButton.hidden = item != nil;
    self.undoButton.hidden = ![header containsObject:self.undoButton];
    for (ApolloPixelButton *button in header) {
        button.pixelScale = p;
        right -= button.tileWidth;
        button.frame = CGRectMake(right * p, kHeaderY * p, button.tileWidth * p, button.tileHeight * p);
        right -= 2;
    }
    NSMutableArray *actions = [NSMutableArray array];
    if (item) {
        [actions addObject:self.flipButton];
        if (item.spec.variants.count > 1) [actions addObject:self.variantButton];
        if (item.spec.toggleable) [actions addObject:self.toggleButton];
        [actions addObject:self.awayButton];
    }
    for (ApolloPixelButton *button in @[self.flipButton, self.variantButton, self.toggleButton, self.awayButton]) {
        button.hidden = ![actions containsObject:button];
        if (!button.hidden && button.superview != self.actionBar) [self.actionBar addSubview:button];
    }
    self.actionBar.hidden = actions.count == 0;
    if (actions.count) {
        int pad = 3, barW = pad * 2 + (int)actions.count * 18 + ((int)actions.count - 1) * 2, barH = 16 + pad * 2;
        APCanvas *panel = APPanelCanvas(barW, barH);
        self.actionPanel.pixelScale = p;
        [self.actionPanel setCanvas:panel];
        APCanvasFree(panel);
        self.actionBar.frame = CGRectMake((self.pixelWidth - 4 - barW) * p, -(barH + 2) * p, barW * p, barH * p);
        self.actionPanel.frame = self.actionBar.bounds;
        int x = pad;
        for (ApolloPixelButton *button in actions) {
            button.pixelScale = p;
            button.frame = CGRectMake(x * p, pad * p, 18 * p, 16 * p);
            x += 20;
        }
    }
    int maxTitle = right - 8;
    self.titleLabel.pixelScale = self.subtitleLabel.pixelScale = p;
    self.titleLabel.maxWidth = self.subtitleLabel.maxWidth = maxTitle;
    CGSize t = self.titleLabel.intrinsicContentSize, s = self.subtitleLabel.intrinsicContentSize;
    self.titleLabel.frame = CGRectMake(7 * p, (kHeaderY + 2) * p, t.width, t.height);
    self.subtitleLabel.frame = CGRectMake(7 * p, (kHeaderY + 9) * p, s.width, s.height);
    // VoiceOver: move the selected piece from its name.
    if (item) {
        __weak typeof(self) weakSelf = self;
        UIAccessibilityCustomAction *(^move)(NSString *, int, int) = ^UIAccessibilityCustomAction *(NSString *name, int dx, int dy) {
            return [[UIAccessibilityCustomAction alloc] initWithName:name actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
                return [weakSelf.delegate drawer:weakSelf moveSelectionByX:dx y:dy];
            }];
        };
        self.titleLabel.accessibilityCustomActions = @[move(@"Move left", -1, 0), move(@"Move right", 1, 0),
                                                       move(@"Move back", 0, -1), move(@"Move forward", 0, 1)];
        self.titleLabel.accessibilityHint = @"Drag in the room to move it, or use the actions.";
    } else {
        self.titleLabel.accessibilityCustomActions = nil;
        self.titleLabel.accessibilityHint = nil;
    }
}

- (void)refreshHeader {
    APPlacedItem *item = self.selection;
    if (self.flash) {
        self.titleLabel.text = self.flash;
        self.subtitleLabel.text = @"";
    } else if (item) {
        self.titleLabel.text = item.spec.title;
        NSString *variant = item.spec.variants.count > 1 ? item.spec.variants[item.variant] : @"";
        self.subtitleLabel.text = item.spec.toggleable && !item.on ? [variant stringByAppendingString:variant.length ? @" · Off" : @"Off"] : variant;
    } else {
        self.titleLabel.text = [APCatalog titleForCategory:self.category];
        self.subtitleLabel.text = self.category == APCategoryStyles ? (self.pendingStyle ? self.pendingStyle.title
                                                                       : [self isFreshRoom] ? @"Moving day" : self.layout.style.title ?: @"Pick a whole new home")
            : self.category >= APCategoryWallpaper ? @"Tap to redecorate" : @"Tap an item to add it";
    }
    for (ApolloPixelButton *tab in self.tabs) tab.toggled = tab.tag == self.category;
    [self layoutHeader];
}

- (void)updateWithSelection:(APPlacedItem *)item layout:(APRoomLayout *)layout {
    BOOL surfacesChanged = self.layout.wallpaper != layout.wallpaper || self.layout.floor != layout.floor || self.layout.style != layout.style;
    self.selection = item;
    self.layout = layout;
    [self refreshHeader];
    if (surfacesChanged && (self.category >= APCategoryWallpaper || self.category == APCategoryStyles)) [self rebuildShelf];
}

- (void)flashTitle:(NSString *)title {
    self.flash = title;
    [self refreshHeader];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, title);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![weakSelf.flash isEqual:title]) return;
        weakSelf.flash = nil;
        [weakSelf refreshHeader];
    });
}

// Still moving-in day: the boxes, and at most the window.
- (BOOL)isFreshRoom {
    if (self.layout.items.count > 2) return NO;
    BOOL boxes = NO;
    for (APPlacedItem *item in self.layout.items) {
        if ([item.spec.identifier isEqualToString:@"boxes"]) boxes = YES;
        else if (![item.spec.identifier isEqualToString:@"window"]) return NO;
    }
    return boxes;
}

- (void)rebuildShelf {
    // Rebuilding the same tab (a pick, a style swap) keeps your place in it.
    BOOL sameTab = self.shelfCategory == self.category && self.shelfBuilt;
    CGPoint keep = self.shelf.contentOffset;
    self.shelfCategory = self.category;
    self.shelfBuilt = YES;
    for (UIView *view in self.shelf.subviews) [view removeFromSuperview];
    CGFloat p = self.pixelScale;
    int x = 2;
    if (self.category == APCategoryStyles && self.pendingStyle) {
        // How to apply the chosen style.
        APCanvas *thumb = APStyleThumbnail(self.pendingStyle);
        ApolloPixelButton *preview = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:self.pendingStyle.title];
        preview.iconName = nil;
        preview.flat = YES;
        preview.toggled = YES;
        preview.tileWidth = thumb->w + 6;
        preview.tileHeight = kShelfH;
        preview.content = [APCanvasBox boxWithCanvas:thumb];
        preview.pixelScale = p;
        preview.userInteractionEnabled = NO;
        preview.frame = CGRectMake(x * p, 0, preview.tileWidth * p, preview.tileHeight * p);
        [self.shelf addSubview:preview];
        x += preview.tileWidth + 6;
        NSArray *choices = @[@[@"sofa", @"Furnished", @"Their furnished room."],
                             @[@"brush", @"Bare room", @"Just their walls and floor, nothing in it."],
                             @[@"box", @"Keep my things", @"Their walls and floor around your furniture."]];
        int columnW = 0;
        for (NSUInteger i = 0; i < choices.count; i++) {
            ApolloPixelButton *button = [self wordButton:choices[i][0] word:choices[i][1]];
            button.accessibilityHint = choices[i][2];
            button.tag = (NSInteger)i;
            button.frame = CGRectMake(x * p, (i * 20) * p, button.tileWidth * p, button.tileHeight * p);
            [button addTarget:self action:@selector(applyStyleTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.shelf addSubview:button];
            columnW = MAX(columnW, button.tileWidth);
        }
        x += columnW + 4;
        ApolloPixelButton *back = [[ApolloPixelButton alloc] initWithIcon:@"back" accessibilityLabel:@"Back to styles"];
        back.tileWidth = 18;
        back.tileHeight = 16;
        back.pixelScale = p;
        back.frame = CGRectMake(x * p, 0, 18 * p, 16 * p);
        [back addTarget:self action:@selector(cancelStyleChoice) forControlEvents:UIControlEventTouchUpInside];
        [self.shelf addSubview:back];
        x += 20;
    } else if (self.category == APCategoryStyles) {
        // Each style is a little painting of its furnished room.
        static NSMutableDictionary<NSString *, APCanvasBox *> *thumbs;
        if (!thumbs) thumbs = [NSMutableDictionary dictionary];
        NSArray<APStyleSpec *> *styles = [APCatalog styles];
        // First: Start Fresh, the empty moving-in room.
        APCanvasBox *fresh = thumbs[@"__fresh"];
        if (!fresh) thumbs[@"__fresh"] = fresh = [APCanvasBox boxWithCanvas:APRoomThumbnail([APCatalog starterRoom])];
        ApolloPixelButton *freshCell = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:@"Start Fresh"];
        freshCell.iconName = nil;
        freshCell.flat = YES;
        freshCell.tileWidth = fresh.canvas->w + 6;
        freshCell.tileHeight = kShelfH;
        APCanvas *freshArt = APCanvasCopy(fresh.canvas);
        // A little "NEW START" tag over the painting.
        APChromeTheme t = APChromeCurrent();
        int tw = APTextWidth(@"FRESH", APFontSmall) + 4;
        APRect(freshArt, (freshArt->w - tw) / 2, freshArt->h - 9, tw, 7, t.accent);
        APText(freshArt, @"FRESH", (freshArt->w - tw) / 2 + 2, freshArt->h - 8, APFontSmall, 0x1A1410);
        freshCell.content = [APCanvasBox boxWithCanvas:freshArt];
        freshCell.accessibilityHint = @"Clears the room back to moving-in day. You can undo it.";
        BOOL isFresh = [self isFreshRoom];
        freshCell.toggled = isFresh;
        freshCell.pixelScale = p;
        freshCell.tag = -1;
        freshCell.frame = CGRectMake(x * p, 0, freshCell.tileWidth * p, freshCell.tileHeight * p);
        [freshCell addTarget:self action:@selector(styleTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.shelf addSubview:freshCell];
        x += freshCell.tileWidth + 2;
        for (NSUInteger i = 0; i < styles.count; i++) {
            APStyleSpec *style = styles[i];
            APCanvasBox *thumb = thumbs[style.identifier];
            if (!thumb) thumbs[style.identifier] = thumb = [APCanvasBox boxWithCanvas:APStyleThumbnail(style)];
            ApolloPixelButton *cell = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:style.title];
            cell.iconName = nil;
            cell.flat = YES;
            cell.tileWidth = thumb.canvas->w + 6;
            cell.tileHeight = kShelfH;
            cell.content = [APCanvasBox boxWithCanvas:APCanvasCopy(thumb.canvas)];
            cell.toggled = !isFresh && [style.identifier isEqual:self.layout.style.identifier];
            cell.accessibilityHint = @"Replaces your room with this furnished style. You can undo it.";
            cell.pixelScale = p;
            cell.tag = (NSInteger)i;
            cell.frame = CGRectMake(x * p, 0, cell.tileWidth * p, cell.tileHeight * p);
            [cell addTarget:self action:@selector(styleTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.shelf addSubview:cell];
            x += cell.tileWidth + 2;
        }
    } else if (self.category >= APCategoryWallpaper) {
        BOOL floor = self.category == APCategoryFlooring;
        NSArray<APSurfaceSpec *> *surfaces = floor ? [APCatalog floors] : [APCatalog wallpapers];
        NSString *current = floor ? self.layout.floor.identifier : self.layout.wallpaper.identifier;
        for (NSUInteger i = 0; i < surfaces.count; i++) {
            APSurfaceSpec *surface = surfaces[i];
            ApolloPixelButton *cell = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:surface.title];
            cell.iconName = nil;
            cell.flat = YES;
            cell.tileWidth = 30;
            cell.tileHeight = 29;
            cell.content = [APCanvasBox boxWithCanvas:APSurfaceThumbnail(surface, floor, 24)];
            cell.toggled = [surface.identifier isEqual:current];
            cell.pixelScale = p;
            cell.tag = (NSInteger)i;
            cell.frame = CGRectMake((2 + (i / 2) * 32) * p, (i % 2) * 30 * p, 30 * p, 29 * p);
            [cell addTarget:self action:@selector(surfaceTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.shelf addSubview:cell];
            x = 2 + (int)(i / 2 + 1) * 32;
        }
    } else {
        NSArray<APItemSpec *> *items = [APCatalog itemsInCategory:self.category];
        for (NSUInteger i = 0; i < items.count; i++) {
            APItemSpec *spec = items[i];
            ApolloPixelButton *cell = [[ApolloPixelButton alloc] initWithIcon:@"" accessibilityLabel:spec.title];
            cell.iconName = nil;
            cell.flat = YES;
            APCanvas *thumb = APItemThumbnail(spec, 0);
            cell.tileWidth = MAX(thumb->w + 6, 22);
            cell.tileHeight = kShelfH;
            cell.content = [APCanvasBox boxWithCanvas:thumb];
            cell.pixelScale = p;
            cell.tag = (NSInteger)i;
            cell.accessibilityHint = @"Adds it to your room.";
            cell.frame = CGRectMake(x * p, 0, cell.tileWidth * p, cell.tileHeight * p);
            [cell addTarget:self action:@selector(itemTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.shelf addSubview:cell];
            x += cell.tileWidth + 2;
        }
    }
    self.shelf.contentSize = CGSizeMake((x + 2) * p, kShelfH * p);
    CGFloat maxX = MAX(0, self.shelf.contentSize.width - self.shelf.bounds.size.width);
    self.shelf.contentOffset = sameTab ? CGPointMake(MIN(MAX(0, keep.x), maxX), 0) : CGPointZero;
}

#pragma mark Actions

- (void)tabTapped:(ApolloPixelButton *)sender {
    APHapticPlay(APHapticSelect);
    self.category = sender.tag;
}

- (void)itemTapped:(ApolloPixelButton *)sender {
    NSArray<APItemSpec *> *items = [APCatalog itemsInCategory:self.category];
    if (sender.tag < (NSInteger)items.count) [self.delegate drawer:self didPickItem:items[sender.tag] sender:sender];
}

- (void)surfaceTapped:(ApolloPixelButton *)sender {
    BOOL floor = self.category == APCategoryFlooring;
    NSArray<APSurfaceSpec *> *surfaces = floor ? [APCatalog floors] : [APCatalog wallpapers];
    if (sender.tag >= (NSInteger)surfaces.count) return;
    for (ApolloPixelButton *cell in self.shelf.subviews) if ([cell isKindOfClass:ApolloPixelButton.class]) cell.toggled = cell == sender;
    [self.delegate drawer:self didPickSurface:surfaces[sender.tag] isFloor:floor];
}

- (void)styleTapped:(ApolloPixelButton *)sender {
    NSArray<APStyleSpec *> *styles = [APCatalog styles];
    if (sender.tag == -1) {
        for (ApolloPixelButton *cell in self.shelf.subviews) if ([cell isKindOfClass:ApolloPixelButton.class]) cell.toggled = cell == sender;
        [self.delegate drawerStartFresh:self];
        return;
    }
    if (sender.tag < 0 || sender.tag >= (NSInteger)styles.count) return;
    // Ask how: furnished, bare, or around your things.
    self.styleListOffset = self.shelf.contentOffset.x;
    self.pendingStyle = styles[sender.tag];
    [self refreshHeader];
    self.shelfBuilt = NO; // the choice row starts at its beginning
    [self rebuildShelf];
}

- (void)applyStyleTapped:(ApolloPixelButton *)sender {
    APStyleSpec *style = self.pendingStyle;
    if (!style) return;
    [self leaveStyleChoice];
    [self.delegate drawer:self didPickStyle:style apply:(APStyleApply)sender.tag];
}

- (void)cancelStyleChoice { [self leaveStyleChoice]; }

- (void)leaveStyleChoice {
    self.pendingStyle = nil;
    [self refreshHeader];
    [self rebuildShelf];
    // Back where you were in the list of styles.
    CGFloat maxX = MAX(0, self.shelf.contentSize.width - self.shelf.bounds.size.width);
    self.shelf.contentOffset = CGPointMake(MIN(self.styleListOffset, maxX), 0);
}

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

- (void)undo { [self.delegate drawerUndo:self]; }
- (void)done { [self.delegate drawerDidFinish:self]; }
- (void)flip { [self.delegate drawerFlip:self]; }
- (void)variant { [self.delegate drawerCycleVariant:self]; }
- (void)toggle { [self.delegate drawerToggle:self]; }
- (void)putAway { [self.delegate drawerPutAway:self]; }
- (void)lighting { [self.delegate drawerCycleLighting:self]; }

@end
