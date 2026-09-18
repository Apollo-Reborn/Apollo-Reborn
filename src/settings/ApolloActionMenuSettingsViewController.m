#import "settings/ApolloActionMenuSettingsViewController.h"

#import "ApolloActionMenuLayout.h"
#import "ApolloCommon.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloSettingsForm.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

#import <objc/runtime.h>

// Two screens. The hub (ApolloActionMenuSettingsViewController, at the end of
// this file) lists the menus: the ••• menus, the moderator menus and an All
// Menus overview, each row summarising how it differs from Apollo's default.
// The editor (ApolloActionMenuEditorViewController) lists one menu's items —
// drag to reorder, tap to check or uncheck — and the button in its top-right
// corner IS the preview (••• or the shield, whichever opens the menu being
// edited): tap it and it opens that menu as Apollo would open it right now,
// with the saved order and visibility applied. On Liquid Glass that is a real UIMenu
// (the same UIKit menu Apollo's own ••• buttons show); on earlier iOS it is a
// sheet styled after Apollo's classic action sheet. It is built fresh every
// time it opens, so every change shows the next time it is tapped — exactly as
// in the app. Rows the menu wouldn't offer right now (your own post's Edit, a
// feature row that's off) are dimmed rather than dropped, so a row you just
// moved is always where you put it.

NSString *const ApolloActionMenuEditorAllMenus = @"all";

static NSString *const kApolloAMRowReset = @"reset";
static NSString *const kApolloAMItemRowPrefix = @"item.";

// Rows the menu doesn't offer right now are drawn dimmed, not dropped.
static const CGFloat kApolloAMPreviewUnavailableAlpha = 0.4;

#pragma mark - Preview rows (what the ••• button shows)

@interface ApolloAMPreviewRow : NSObject
@property (nonatomic, strong) ApolloActionMenuItem *item;
@property (nonatomic) BOOL available;   // the menu offered it last time (or usually does)
@end

@implementation ApolloAMPreviewRow
@end

// The saved order with hidden items removed, each flagged with whether the
// menu offers it right now.
static NSArray<ApolloAMPreviewRow *> *ApolloAMPreviewRows(ApolloActionMenuContext context) {
    NSMutableArray<ApolloAMPreviewRow *> *rows = [NSMutableArray array];
    for (ApolloActionMenuItem *item in ApolloActionMenuPreviewItems(context)) {
        ApolloAMPreviewRow *row = [ApolloAMPreviewRow new];
        row.item = item;
        row.available = ApolloActionMenuItemWasOffered(context, item.itemID);
        [rows addObject:row];
    }
    return rows;
}

static BOOL ApolloAMItemIsSubmitPost(ApolloActionMenuItem *item) {
    return item.locked && [item.kinds containsObject:@51];
}

// The glass preview: a UIMenu mirroring what the glass renderer and the row
// registry produce for this layout — Apollo's rows in the saved order with its
// own option-* art (the Moderator row in its tint), the feed's locked Submit
// Post as the quick new-post buttons when those apply, Apollo Reborn's rows at
// their rank (Gallery View in its own inline section, as the real one is).
static UIMenu *ApolloAMBuildGlassPreviewMenu(ApolloActionMenuContext context) {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    for (ApolloAMPreviewRow *row in ApolloAMPreviewRows(context)) {
        ApolloActionMenuItem *item = row.item;
        UIMenuElement *element = nil;
        if (ApolloAMItemIsSubmitPost(item)) {
            // Polls on + signed in: the Photo/Link/Text/Poll row, else nil and
            // the plain row below — the same swap the renderer makes.
            element = ApolloSubmitPostTypesMenu(nil, ^{});
        }
        if (!element) {
            // The moderator menus draw every row in the mod tint, like the real ones.
            BOOL moderator = ApolloActionMenuContextIsModerator(context) || [item.itemID isEqualToString:@"moderator"];
            element = ApolloNativeActionMenuPreviewAction(item.title, [item icon], moderator, row.available);
        }
        if (!element) continue;
        // Gallery View's spec builds a section of its own on glass
        // (ApolloGalleryMenu.xm, inlineSection); mirror the separators.
        if ([item.specIdentifier isEqualToString:@"GalleryView"] && [element isKindOfClass:[UIAction class]]) {
            element = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                    options:UIMenuOptionsDisplayInline children:@[ element ]];
        }
        [children addObject:element];
    }
    return [UIMenu menuWithTitle:@"" children:children];
}

// The bar button's glyph: Apollo's ••• for the ••• menus, its moderator
// shield for the moderator menus (that is the button those menus open from).
static UIImage *ApolloAMPreviewButtonImage(ApolloActionMenuContext context) {
    if (ApolloActionMenuContextIsModerator(context)) {
        UIImage *shield = [[ApolloActionMenuCatalogItem(ApolloActionMenuContextPost, @"moderator") icon]
                           imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if (shield) return shield;
    }
    return [UIImage systemImageNamed:@"ellipsis"];
}

#pragma mark - Legacy preview sheet (pre-Liquid Glass)

// Apollo's classic ••• sheet, drawn by us for the preview: a bottom card of
// icon + title rows in the theme's accent, and a Cancel card beneath, dimming
// the screen behind. Tweak rows sit below Apollo's — the legacy sheet always
// appends them (ApolloActionMenu.h) — and rows the menu doesn't offer right
// now are dimmed.
// Geometry measured off the real sheet (non-glass sim, 2026-09-15): 10pt side
// insets, 13pt corners, 58pt rows, a 24pt icon centred 33pt in, the 20pt
// title (and the separator) starting 68pt in, a 6pt gap to the 57pt Cancel
// card, everything in the theme's accent.
static const CGFloat kApolloAMSheetRowHeight = 58.0;
static const CGFloat kApolloAMSheetCornerRadius = 13.0;
static const CGFloat kApolloAMSheetSideInset = 10.0;
static const CGFloat kApolloAMSheetGap = 6.0;
static const CGFloat kApolloAMSheetCancelHeight = 57.0;
static const CGFloat kApolloAMSheetIconSide = 24.0;
static const CGFloat kApolloAMSheetIconCenterX = 33.0;
static const CGFloat kApolloAMSheetTextX = 68.0;

@interface ApolloAMPreviewSheetCell : UITableViewCell
@end

@implementation ApolloAMPreviewSheetCell

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    self.imageView.frame = CGRectMake(kApolloAMSheetIconCenterX - kApolloAMSheetIconSide / 2.0,
                                      round((CGRectGetHeight(bounds) - kApolloAMSheetIconSide) / 2.0),
                                      kApolloAMSheetIconSide, kApolloAMSheetIconSide);
    CGFloat right = self.accessoryType == UITableViewCellAccessoryNone ? CGRectGetWidth(bounds) - 16.0 : CGRectGetWidth(bounds) - 8.0;
    self.textLabel.frame = CGRectMake(kApolloAMSheetTextX, 0.0, MAX(0.0, right - kApolloAMSheetTextX), CGRectGetHeight(bounds));
}

@end

@interface ApolloAMPreviewSheetViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<ApolloAMPreviewRow *> *rows;
// Every row pushes a screen (the subreddit moderator sheet): chevrons on all.
@property (nonatomic) BOOL chevronsOnEveryRow;
@property (nonatomic, strong) UIColor *accentColor;
@property (nonatomic, strong) UIColor *cardColor;
@property (nonatomic, strong) UIColor *separatorColor;
@end

@implementation ApolloAMPreviewSheetViewController {
    UIView *_dimmingView;
    UIView *_card;
    UITableView *_table;
    UIButton *_cancelButton;
    BOOL _shown;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _dimmingView = [[UIView alloc] initWithFrame:self.view.bounds];
    _dimmingView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
    _dimmingView.alpha = 0.0;
    _dimmingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_dimmingView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSheet)]];
    [self.view addSubview:_dimmingView];

    _card = [UIView new];
    _card.backgroundColor = self.cardColor ?: UIColor.systemBackgroundColor;
    _card.layer.cornerRadius = kApolloAMSheetCornerRadius;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self.view addSubview:_card];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorColor = self.separatorColor ?: UIColor.separatorColor;
    _table.separatorInset = UIEdgeInsetsMake(0.0, kApolloAMSheetTextX, 0.0, 0.0);
    _table.rowHeight = kApolloAMSheetRowHeight;
    _table.tableFooterView = [UIView new];
    _table.alwaysBounceVertical = NO;
    [_card addSubview:_table];

    _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    _cancelButton.titleLabel.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightSemibold];
    [_cancelButton setTitleColor:(self.accentColor ?: self.view.tintColor) forState:UIControlStateNormal];
    _cancelButton.backgroundColor = self.cardColor ?: UIColor.systemBackgroundColor;
    _cancelButton.layer.cornerRadius = kApolloAMSheetCornerRadius;
    _cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    [_cancelButton addTarget:self action:@selector(dismissSheet) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_cancelButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = CGRectGetWidth(bounds) - 2.0 * kApolloAMSheetSideInset;
    CGFloat cancelHeight = kApolloAMSheetCancelHeight;
    CGFloat cancelY = CGRectGetHeight(bounds) - safe.bottom - 12.0 - cancelHeight;
    _cancelButton.frame = CGRectMake(kApolloAMSheetSideInset, cancelY, width, cancelHeight);

    CGFloat available = cancelY - kApolloAMSheetGap - safe.top - 44.0;
    CGFloat wanted = (CGFloat)self.rows.count * kApolloAMSheetRowHeight;
    CGFloat cardHeight = MIN(wanted, available);
    _card.frame = CGRectMake(kApolloAMSheetSideInset, cancelY - kApolloAMSheetGap - cardHeight, width, cardHeight);
    _table.frame = _card.bounds;
    _table.scrollEnabled = wanted > available + 0.5;
    if (!_shown) {
        // Slide in from below on first appearance, the way the real sheet does.
        _shown = YES;
        CGAffineTransform offscreen = CGAffineTransformMakeTranslation(0.0, CGRectGetHeight(bounds) - CGRectGetMinY(_card.frame));
        _card.transform = offscreen;
        _cancelButton.transform = offscreen;
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                            options:UIViewAnimationOptionCurveEaseOut animations:^{
            self->_dimmingView.alpha = 1.0;
            self->_card.transform = CGAffineTransformIdentity;
            self->_cancelButton.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)dismissSheet {
    CGAffineTransform offscreen = CGAffineTransformMakeTranslation(0.0, CGRectGetHeight(self.view.bounds) - CGRectGetMinY(_card.frame));
    [UIView animateWithDuration:0.22 animations:^{
        self->_dimmingView.alpha = 0.0;
        self->_card.transform = offscreen;
        self->_cancelButton.transform = offscreen;
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const reuseID = @"Cell_ActionMenuPreviewSheet";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID]
        ?: [[ApolloAMPreviewSheetCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
    ApolloAMPreviewRow *row = self.rows[(NSUInteger)indexPath.row];
    UIColor *ink = self.accentColor ?: tableView.tintColor;
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.tintColor = ink;
    cell.textLabel.text = row.item.title;
    cell.textLabel.font = [UIFont systemFontOfSize:20.0];
    cell.textLabel.textColor = ink;
    cell.imageView.image = [row.item icon];
    cell.imageView.tintColor = ink;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
    // Submit Post opens the post-type list on the classic sheet — chevron;
    // the subreddit moderator sheet's rows all push a screen — chevrons.
    cell.accessoryType = (self.chevronsOnEveryRow || ApolloAMItemIsSubmitPost(row.item))
        ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.contentView.alpha = row.available ? 1.0 : kApolloAMPreviewUnavailableAlpha;
    cell.accessibilityLabel = row.available ? row.item.title
        : [NSString stringWithFormat:@"%@, shown when available", row.item.title];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self dismissSheet]; // a preview row does nothing but close, like tapping Cancel
}

@end

// Legacy order: Apollo's rows in the saved order, then Apollo Reborn's rows —
// the legacy sheet always appends injected rows after the native ones.
static NSArray<ApolloAMPreviewRow *> *ApolloAMLegacyPreviewRows(ApolloActionMenuContext context) {
    NSMutableArray<ApolloAMPreviewRow *> *native = [NSMutableArray array];
    NSMutableArray<ApolloAMPreviewRow *> *tweak = [NSMutableArray array];
    for (ApolloAMPreviewRow *row in ApolloAMPreviewRows(context)) {
        [(row.item.isTweakRow ? tweak : native) addObject:row];
    }
    return [native arrayByAddingObjectsFromArray:tweak];
}

#pragma mark - Item row cell

// One catalogue item: its menu icon, its title, and at the trailing edge a
// checkmark (checked = shown; tap the row to flip it) with the drag grip to
// its right. Both sit in one accessory view so UIKit keeps their native
// trailing placement; the All overview, which never reorders, drops the grip
// from it. A hidden item dims its icon and title and loses its checkmark but
// stays in the list, so it can be dragged and checked again any time.
@interface ApolloAMItemCell : UITableViewCell
@property (nonatomic, copy) NSString *itemID;
@property (nonatomic, strong, readonly) UIImageView *checkmark;
@property (nonatomic, strong, readonly) UIImageView *grip;
@property (nonatomic) BOOL showsGrip;
@end

static const CGFloat kApolloAMCheckmarkWidth = 22.0;
static const CGFloat kApolloAMGripWidth = 24.0;
static const CGFloat kApolloAMAccessoryGap = 14.0;
static const CGFloat kApolloAMAccessoryHeight = 28.0;

@implementation ApolloAMItemCell {
    UIView *_accessory;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
    UIImageSymbolConfiguration *checkConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
    _checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:checkConfiguration]];
    _checkmark.contentMode = UIViewContentModeCenter;
    UIImageSymbolConfiguration *gripConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium];
    _grip = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.horizontal.3" withConfiguration:gripConfiguration]];
    _grip.tintColor = UIColor.tertiaryLabelColor;
    _grip.contentMode = UIViewContentModeCenter;
    _accessory = [[UIView alloc] initWithFrame:CGRectZero];
    [_accessory addSubview:_checkmark];
    [_accessory addSubview:_grip];
    self.accessoryView = _accessory;
    _showsGrip = YES;
    [self layoutAccessory];
    self.imageView.contentMode = UIViewContentModeCenter;
    self.textLabel.numberOfLines = 1;
    self.textLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    return self;
}

- (void)setShowsGrip:(BOOL)showsGrip {
    if (_showsGrip == showsGrip) return;
    _showsGrip = showsGrip;
    [self layoutAccessory];
}

// The accessory view's bounds drive UIKit's trailing placement, so it is
// sized here (never from layoutSubviews) whenever the grip comes or goes.
- (void)layoutAccessory {
    CGFloat width = kApolloAMCheckmarkWidth + (self.showsGrip ? kApolloAMAccessoryGap + kApolloAMGripWidth : 0.0);
    _accessory.bounds = CGRectMake(0.0, 0.0, width, kApolloAMAccessoryHeight);
    self.checkmark.frame = CGRectMake(0.0, 0.0, kApolloAMCheckmarkWidth, kApolloAMAccessoryHeight);
    self.grip.frame = CGRectMake(width - kApolloAMGripWidth, 0.0, kApolloAMGripWidth, kApolloAMAccessoryHeight);
    self.grip.hidden = !self.showsGrip;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect content = self.contentView.bounds;
    // Apollo's option-* art is a mixed bag of shapes; a fixed 28pt box keeps
    // every title on the same column.
    CGRect imageFrame = self.imageView.frame;
    imageFrame.size = CGSizeMake(28.0, 28.0);
    imageFrame.origin.y = round((CGRectGetHeight(content) - 28.0) / 2.0);
    self.imageView.frame = imageFrame;
    // UIKit already keeps the content area clear of the accessory view.
    CGRect textFrame = self.textLabel.frame;
    textFrame.origin.x = CGRectGetMaxX(imageFrame) + 12.0;
    textFrame.size.width = MAX(0.0, CGRectGetMaxX(content) - 8.0 - CGRectGetMinX(textFrame));
    self.textLabel.frame = textFrame;
    CGRect detailFrame = self.detailTextLabel.frame;
    detailFrame.origin.x = textFrame.origin.x;
    detailFrame.size.width = textFrame.size.width;
    self.detailTextLabel.frame = detailFrame;
    // The theme pass tints every image view in the cell with the accent; the
    // grip is chrome, not content (the checkmark IS accent-coloured).
    self.grip.tintColor = UIColor.tertiaryLabelColor;
}

@end

#pragma mark - The screen

@interface ApolloActionMenuEditorViewController () <UITableViewDragDelegate, UITableViewDropDelegate>
@property (nonatomic, copy) ApolloActionMenuContext context;
@property (nonatomic, strong) UIBarButtonItem *previewButton;
// Exact item-row heights (see itemRowHeightWithSubtitle:).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *itemRowHeights;
@property (nonatomic, strong) ApolloAMItemCell *measuringItemCell;
@end

@implementation ApolloActionMenuEditorViewController

- (instancetype)initWithContext:(NSString *)context {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _context = [context copy];
    return self;
}

- (void)viewDidLoad {
    if (!self.context) self.context = ApolloActionMenuContextPost;
    [super viewDidLoad];
    self.title = self.editingAllMenus ? @"All Menus" : ApolloActionMenuContextTitle(self.context);
    ApolloLog(@"[ActionMenuSettings] editing %@", self.context);

    // Drag & drop powers the item rows' reordering (touch and hold a row, then
    // drag). Scoped hard to that section by the drag delegate + drop proposal;
    // every other row refuses to lift. The rows stay plain tappable rows
    // (a persistent editing mode would put its own controls on them).
    self.tableView.dragInteractionEnabled = YES;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;

    // The preview: a ••• button like Apollo's own, top-right (a shield while a
    // moderator menu is being edited — that is that menu's button). On glass
    // it carries the preview UIMenu (built fresh on every tap); before glass
    // it presents the classic-sheet preview.
    UIImage *glyph = ApolloAMPreviewButtonImage(self.context);
    UIBarButtonItem *preview;
    if (ApolloNativeActionMenusActive()) {
        preview = [[UIBarButtonItem alloc] initWithImage:glyph menu:nil];
    } else {
        preview = [[UIBarButtonItem alloc] initWithImage:glyph style:UIBarButtonItemStylePlain
                                                  target:self action:@selector(presentLegacyPreview)];
    }
    preview.accessibilityLabel = @"Preview this menu";
    self.previewButton = preview;
    [self refreshPreviewButton];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // A real ••• opened since (recording what it offered) changes the dimming;
    // the glass menu is built on tap anyway, this keeps the button state right.
    [self refreshPreviewButton];
}

#pragma mark - The ••• preview

// Glass: hand the button a menu whose content is produced the moment it opens
// (UIDeferredMenuElement's uncached provider), so the preview never lags a
// change. Legacy: the button just presents the sheet.
- (void)refreshPreviewButton {
    UIBarButtonItem *button = self.previewButton;
    if (!button) return;
    // All Menus is an overview, not a menu: nothing to preview.
    self.navigationItem.rightBarButtonItem = self.editingAllMenus ? nil : button;
    if (self.editingAllMenus) return;
    button.image = ApolloAMPreviewButtonImage(self.context);
    if (!ApolloNativeActionMenusActive()) return;
    if (@available(iOS 15.0, *)) {
        __weak __typeof(self) weakSelf = self;
        UIDeferredMenuElement *deferred =
            [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            ApolloActionMenuContext context = strongSelf.context;
            completion(context && !strongSelf.editingAllMenus ? ApolloAMBuildGlassPreviewMenu(context).children : @[]);
        }];
        button.menu = [UIMenu menuWithTitle:@"" children:@[ deferred ]];
    } else {
        // Glass never runs below iOS 26, so this is only reached in theory.
        button.menu = self.editingAllMenus ? nil : ApolloAMBuildGlassPreviewMenu(self.context);
    }
}

- (void)presentLegacyPreview {
    if (self.editingAllMenus) return;
    ApolloAMPreviewSheetViewController *sheet = [[ApolloAMPreviewSheetViewController alloc] init];
    sheet.rows = ApolloAMLegacyPreviewRows(self.context);
    sheet.chevronsOnEveryRow = [self.context isEqualToString:ApolloActionMenuContextModeratorSubreddit];
    // Apollo colours its classic moderator sheet in the mod tint.
    sheet.accentColor = ApolloActionMenuContextIsModerator(self.context) ? ApolloModeratorColor()
        : ([self apollo_themeAccentColor] ?: ApolloThemeAccentColor() ?: self.view.tintColor);
    sheet.cardColor = [self apollo_themeCellBackgroundColor] ?: UIColor.systemBackgroundColor;
    sheet.separatorColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    [self presentViewController:sheet animated:NO completion:nil];
}

#pragma mark - Form

- (NSString *)itemRowIDForItemID:(NSString *)itemID {
    return [NSString stringWithFormat:@"%@%@.%@", kApolloAMItemRowPrefix, self.context, itemID];
}

- (NSString *)firstItemRowID {
    NSString *first = [self editableItems].firstObject.itemID;
    return first ? [self itemRowIDForItemID:first] : nil;
}

// All is a settings overview, never a runtime menu context. Each tap
// updates only the contexts whose catalogue contains the item. A mixed state
// remains visible in the subtitle; selecting a menu exposes its own override.
- (BOOL)editingAllMenus {
    return [self.context isEqualToString:ApolloActionMenuEditorAllMenus];
}

- (NSArray<ApolloActionMenuItem *> *)editableItems {
    NSMutableArray<ApolloActionMenuItem *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    NSArray *contexts = self.editingAllMenus ? ApolloActionMenuAllContexts() : @[ self.context ];
    for (ApolloActionMenuContext context in contexts) {
        for (NSString *itemID in ApolloActionMenuResolvedOrder(context)) {
            ApolloActionMenuItem *item = ApolloActionMenuCatalogItem(context, itemID);
            // A locked row (the feed's Submit Post) is not the user's to move or hide.
            if (!item || item.locked || [ids containsObject:itemID]) continue;
            [ids addObject:itemID];
            [items addObject:item];
        }
    }
    if (self.editingAllMenus) {
        [items sortUsingComparator:^NSComparisonResult(ApolloActionMenuItem *a, ApolloActionMenuItem *b) {
            return [a.title localizedStandardCompare:b.title];
        }];
    }
    return items;
}

- (NSArray<NSString *> *)contextsForItem:(NSString *)itemID {
    if (!self.editingAllMenus) return @[ self.context ];
    NSMutableArray *contexts = [NSMutableArray array];
    for (NSString *context in ApolloActionMenuAllContexts()) {
        if (ApolloActionMenuCatalogItem(context, itemID)) [contexts addObject:context];
    }
    return contexts;
}

- (BOOL)itemIsHidden:(NSString *)itemID {
    for (NSString *context in [self contextsForItem:itemID]) {
        if (!ApolloActionMenuIsItemHidden(context, itemID)) return NO;
    }
    return YES;
}

// The selected menu's locked rows are absent from the list; the footer says
// where they are instead (nil when the menu has none).
- (NSString *)lockedItemsNote {
    if (self.editingAllMenus) return nil;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    BOOL buttons = ApolloNativeActionMenusActive() && ApolloPollsFeatureEnabled();
    for (ApolloActionMenuItem *item in ApolloActionMenuCatalog(self.context)) {
        if (!item.locked) continue;
        [notes addObject:(buttons && ApolloAMItemIsSubmitPost(item))
            ? [NSString stringWithFormat:@"The new-post buttons (%@) always stay at the top of this menu and can’t be hidden.", item.title]
            : [NSString stringWithFormat:@"%@ always stays at the top of this menu and can’t be hidden.", item.title]];
    }
    return notes.count > 0 ? [notes componentsJoinedByString:@" "] : nil;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;
    ApolloActionMenuContext context = self.context;

    // ---- Items (drag to reorder, tap to show/hide) ----

    NSMutableArray<ApolloSettingsRow *> *itemRows = [NSMutableArray array];
    for (ApolloActionMenuItem *item in [self editableItems]) {
        NSString *itemID = item.itemID;
        // Hidden state is read live on every configure (a tap restyles the
        // cell in place), never captured at build time.
        ApolloSettingsRow *row =
            [ApolloSettingsRow customRowWithID:[self itemRowIDForItemID:itemID]
                                          cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *r) {
            return [weakSelf itemCellForItem:item
                                      hidden:[weakSelf itemIsHidden:item.itemID]
                                     inTable:tableView];
        }
                                      onSelect:^{ [weakSelf toggleItemWithID:itemID]; }];
        // An exact height, never UIKit's estimate (see itemRowHeightWithSubtitle:).
        row.height = ^CGFloat {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return UITableViewAutomaticDimension;
            BOOL subtitle = strongSelf.editingAllMenus || !ApolloActionMenuItemWasOffered(strongSelf.context, itemID);
            return [strongSelf itemRowHeightWithSubtitle:subtitle];
        };
        [itemRows addObject:row];
    }

    // ---- Reset (only while this menu differs from Apollo's default) ----

    ApolloSettingsRow *reset =
        [ApolloSettingsRow buttonRowWithID:kApolloAMRowReset
                                     title:self.editingAllMenus ? @"Reset All Menus" : @"Reset This Menu"
                                    action:^{ [weakSelf resetCurrentMenu]; }];
    reset.visible = ^BOOL { return weakSelf.editingAllMenus ? ApolloActionMenuCustomizedContextCount() > 0 : ApolloActionMenuContextIsCustomized(weakSelf.context); };

    NSString *menuFooter;
    NSString *itemsFooter;
    if (self.editingAllMenus) {
        menuFooter = @"Visibility across every menu, the moderator menus included. Open a menu from the previous screen to reorder its actions or preview it.";
        itemsFooter = @"Tap an action to show or hide it across the menus that support it. Shown in Some Menus means your per-menu choices differ. Select a menu to adjust its choices and order.";
    } else {
        menuFooter = [ApolloActionMenuContextDescription(context)
                      stringByAppendingString:ApolloActionMenuContextIsModerator(context)
                          ? @" Tap the shield at the top to see this menu as it opens right now, with your order and visibility applied."
                          : @" Tap ••• at the top to see this menu as it opens right now, with your order and visibility applied."];
        itemsFooter = @"Only actions supported by this menu are listed. Some appear only for your own content or when a feature is enabled; the preview at the top dims those. Tap an action to show or hide it; touch and hold to reorder. Hiding keeps Apollo’s order.";
        NSString *lockedNote = [self lockedItemsNote];
        if (lockedNote) itemsFooter = [itemsFooter stringByAppendingFormat:@" %@", lockedNote];
        if (!ApolloNativeActionMenusActive()) {
            itemsFooter = [itemsFooter stringByAppendingString:@"\n\nOn this version of iOS, Apollo Reborn's own items always sit below Apollo's."];
        }
    }

    return @[
        // Where this menu opens from, and how to preview it — text only.
        [ApolloSettingsSection sectionWithTitle:nil footer:menuFooter rows:@[]],
        [ApolloSettingsSection sectionWithTitle:@"Items" footer:itemsFooter rows:itemRows],
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[ reset ]],
    ];
}

- (UITableViewCell *)itemCellForItem:(ApolloActionMenuItem *)item hidden:(BOOL)hidden inTable:(UITableView *)tableView {
    static NSString *const reuseID = @"Cell_ActionMenuItem";
    ApolloAMItemCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[ApolloAMItemCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
    cell.itemID = item.itemID;
    cell.textLabel.text = item.title;
    cell.imageView.image = [item icon];
    cell.showsGrip = !self.editingAllMenus;
    [self styleItemCell:cell forItem:item hidden:hidden];
    return cell;
}

// UIKit sizes the item cells itself (rowHeight automatic, estimated 52 pt),
// and a subtitled row is taller than the estimate. Rows above the viewport
// keep the estimate until they are displayed, and any batch update — the
// reset row appearing, the section rebuild after a drag — re-resolves them,
// which jumped the list several rows whenever it was scrolled down (sim
// recording, 2026-09-15). So hand UIKit exact heights: one template cell
// measured per variant (subtitle or not), cached per cell width and content
// size category.
- (CGFloat)itemRowHeightWithSubtitle:(BOOL)subtitle {
    UITableView *table = self.tableView;
    CGFloat width = CGRectGetWidth(table.bounds) - table.layoutMargins.left - table.layoutMargins.right;
    UITableViewCell *sample = table.visibleCells.firstObject;
    if (sample && sample.superview) width = CGRectGetWidth([sample.superview convertRect:sample.frame toView:table]);
    if (width <= 0.0) return UITableViewAutomaticDimension;
    NSString *key = [NSString stringWithFormat:@"%d|%.0f|%@", subtitle, width,
                     table.traitCollection.preferredContentSizeCategory ?: @""];
    NSNumber *cached = self.itemRowHeights[key];
    if (cached) return cached.doubleValue;

    if (!self.measuringItemCell) {
        self.measuringItemCell = [[ApolloAMItemCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    }
    ApolloAMItemCell *cell = self.measuringItemCell;
    cell.textLabel.text = @"Measure";
    cell.detailTextLabel.text = subtitle ? @"Shown when available" : nil;
    // Representative icon: the catalogue's are 24 pt boxes / 19 pt symbols,
    // which never exceed the label stack, so any such glyph will do.
    cell.imageView.image = [UIImage systemImageNamed:@"square"
                                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19.0
                                                                                                   weight:UIImageSymbolWeightRegular]];
    cell.bounds = CGRectMake(0.0, 0.0, width, 100.0);
    [cell setNeedsLayout];
    [cell layoutIfNeeded];
    CGFloat height = ceil([cell systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                  withHorizontalFittingPriority:UILayoutPriorityRequired
                                        verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
    if (height <= 0.0) return UITableViewAutomaticDimension;
    if (!self.itemRowHeights) self.itemRowHeights = [NSMutableDictionary dictionary];
    self.itemRowHeights[key] = @(height);
    return height;
}

// The look that follows the hidden state: the checkmark, dimmed icon and
// title, the All overview's per-menu subtitle, accessibility. Kept apart from
// the cell's creation so a tap can restyle the cell IN PLACE — reloading the
// row instead swaps the cell out under the finger and, with self-sized rows,
// re-resolves estimates above the viewport (both seen in device recordings of
// the earlier switch rows, 2026-09-14/15). Animatable, so a caller may wrap it
// in a UIView animation: the checkmark fades, the rest applies at once.
- (void)styleItemCell:(ApolloAMItemCell *)cell forItem:(ApolloActionMenuItem *)item hidden:(BOOL)hidden {
    // A row Apollo only offers sometimes says so — unless this user's menu
    // offered it last time (a moderator's Moderator row, say). Same rule the
    // ••• preview dims by.
    BOOL offered = self.editingAllMenus || ApolloActionMenuItemWasOffered(self.context, item.itemID);
    cell.detailTextLabel.text = offered ? nil : @"Shown when available";
    if (self.editingAllMenus) {
        NSArray *contexts = [self contextsForItem:item.itemID];
        NSUInteger hiddenCount = 0;
        for (NSString *context in contexts) {
            if (ApolloActionMenuIsItemHidden(context, item.itemID)) hiddenCount++;
        }
        cell.detailTextLabel.text = hiddenCount == 0 ? @"Shown in All Supported Menus" :
            (hiddenCount == contexts.count ? @"Hidden in All Supported Menus" : @"Shown in Some Menus");
    }
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    UIColor *accent = [self apollo_themeAccentColor] ?: ApolloThemeAccentColor() ?: self.view.tintColor;
    cell.checkmark.tintColor = accent;
    cell.checkmark.alpha = hidden ? 0.0 : 1.0;
    // Reuse pool: set BOTH states explicitly. A hidden row's label is disabled
    // (the theme pass leaves disabled labels alone, so the dim survives it);
    // a shown row is re-enabled, reset to the plain label colour and marked
    // for the theme's primary text like every other settings row.
    cell.imageView.tintColor = hidden ? UIColor.tertiaryLabelColor : accent;
    cell.textLabel.enabled = !hidden;
    cell.textLabel.textColor = hidden ? UIColor.secondaryLabelColor : UIColor.labelColor;
    if (!hidden) [self apollo_applyPrimaryTextColorToCell:cell];
    cell.textLabel.alpha = 1.0;
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    cell.accessibilityLabel = offered ? item.title : [NSString stringWithFormat:@"%@, shown when available", item.title];
    cell.accessibilityValue = hidden ? @"Hidden" : @"Shown";
    cell.accessibilityHint = self.editingAllMenus
        ? (hidden ? @"Double tap to show it in the menus that support it." : @"Double tap to hide it from the menus that support it.")
        : (hidden ? @"Double tap to show it in this menu." : @"Double tap to hide it from this menu.");
}

#pragma mark - Actions

// A tap on an item row: flip its visibility (across every supporting menu in
// the All overview) and restyle that very cell in place — no row reload, so
// nothing moves under the finger; the checkmark fades in or out.
- (void)toggleItemWithID:(NSString *)itemID {
    if (itemID.length == 0) return;
    BOOL hide = ![self itemIsHidden:itemID];
    for (NSString *context in [self contextsForItem:itemID]) {
        ApolloActionMenuSetItemHidden(context, itemID, hide);
    }
    ApolloActionMenuItem *item = nil;
    for (ApolloActionMenuItem *candidate in [self editableItems]) {
        if ([candidate.itemID isEqualToString:itemID]) { item = candidate; break; }
    }
    UITableViewCell *cell = [self cellForRowID:[self itemRowIDForItemID:itemID]];
    if (item && [cell isKindOfClass:[ApolloAMItemCell class]]) {
        BOOL nowHidden = [self itemIsHidden:itemID];
        [UIView animateWithDuration:0.2 animations:^{
            [self styleItemCell:(ApolloAMItemCell *)cell forItem:item hidden:nowHidden];
        }];
    }
    [self visibilityDidChange]; // the reset row
    [self refreshPreviewButton];
}

- (void)resetCurrentMenu {
    for (NSString *context in (self.editingAllMenus ? ApolloActionMenuAllContexts() : @[ self.context ])) {
        ApolloActionMenuResetContext(context);
    }
    // Visibility first (this very row disappears), then the items section:
    // rebuildSectionContainingRowID re-snapshots every section's visibility
    // while reloading one, so the reset row must already be gone from the
    // table or UIKit's batch-update check trips on that section's count.
    [self visibilityDidChange];
    NSString *firstItemRowID = [self firstItemRowID];
    if (firstItemRowID) {
        [self rebuildSectionContainingRowID:firstItemRowID withRowAnimation:UITableViewRowAnimationFade];
    }
    [self refreshPreviewButton];
}

#pragma mark - Reordering (drag & drop)

// The item rows' section index, derived by identity (never hardcoded).
- (NSInteger)itemsSectionIndex {
    NSString *firstItemRowID = [self firstItemRowID];
    NSIndexPath *anyItemRow = firstItemRowID ? [self indexPathForRowID:firstItemRowID] : nil;
    return anyItemRow ? anyItemRow.section : NSNotFound;
}

- (BOOL)indexPathIsItemRow:(NSIndexPath *)indexPath {
    return !self.editingAllMenus && indexPath && indexPath.section == [self itemsSectionIndex];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self indexPathIsItemRow:indexPath];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
    if (![self indexPathIsItemRow:fromIndexPath] || ![self indexPathIsItemRow:toIndexPath]) return;
    NSMutableArray<NSString *> *order = [[[self editableItems] valueForKey:@"itemID"] mutableCopy];
    if (fromIndexPath.row < 0 || fromIndexPath.row >= (NSInteger)order.count ||
        toIndexPath.row < 0 || toIndexPath.row >= (NSInteger)order.count) return;
    NSString *moved = order[(NSUInteger)fromIndexPath.row];
    [order removeObjectAtIndex:(NSUInteger)fromIndexPath.row];
    [order insertObject:moved atIndex:(NSUInteger)toIndexPath.row];
    ApolloActionMenuSetOrder(self.context, order);

    // Re-sync the form model with the moved rows (UIKit already animated the
    // move; rebuilding on the next runloop turn keeps the drop animation
    // intact) and show the reset row. The reset row comes FIRST: an untouched
    // menu's first drag makes it appear, and rebuildSectionContainingRowID
    // re-snapshots every section's visibility while reloading only the items
    // section — with the reset row not yet inserted, UIKit's batch-update
    // check trips on that section's count. Diffing the visibility in first
    // inserts the row, so the rebuild's snapshot matches.
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf visibilityDidChange];
        NSString *firstItemRowID = [strongSelf firstItemRowID];
        if (firstItemRowID) {
            [strongSelf rebuildSectionContainingRowID:firstItemRowID withRowAnimation:UITableViewRowAnimationNone];
        }
        [strongSelf refreshPreviewButton];
    });
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    if (![self indexPathIsItemRow:sourceIndexPath]) return sourceIndexPath;
    if ([self indexPathIsItemRow:proposedDestinationIndexPath]) return proposedDestinationIndexPath;
    NSInteger itemsSection = [self itemsSectionIndex];
    NSInteger lastRow = MAX([tableView numberOfRowsInSection:itemsSection] - 1, 0);
    NSInteger row = proposedDestinationIndexPath.section < itemsSection ? 0 : lastRow;
    return [NSIndexPath indexPathForRow:row inSection:itemsSection];
}

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    ApolloLog(@"[ActionMenuSettings] drag begin asked for %ld/%ld (item row: %d)",
              (long)indexPath.section, (long)indexPath.row, [self indexPathIsItemRow:indexPath]);
    if (![self indexPathIsItemRow:indexPath]) return @[];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[NSItemProvider new]];
    item.localObject = indexPath;
    return @[ item ];
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if (session.localDragSession) {
        // Keep the move alive wherever the finger is: a lifted item row can sit
        // over the Menu row after the list auto-scrolled home under it, and
        // targetIndexPathForMove… clamps such a destination into the items
        // section. (Only item rows ever lift, so a local session is always ours.)
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
                                                               intent:UITableViewDropIntentInsertAtDestinationIndexPath];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    // Local same-table reorders with a .move/insertAtDestination proposal are
    // committed by UIKit through tableView:moveRowAtIndexPath:toIndexPath:
    // before this is called; nothing else can be dropped here.
}

@end

#pragma mark - The hub

// A menu row's detail: how the menu differs from Apollo's default.
static NSString *ApolloAMMenuSummary(NSString *context) {
    if ([context isEqualToString:ApolloActionMenuEditorAllMenus]) {
        NSUInteger customized = ApolloActionMenuCustomizedContextCount();
        return customized == 0 ? @"Default" : [NSString stringWithFormat:@"%lu customized", (unsigned long)customized];
    }
    BOOL order = ApolloActionMenuHasCustomOrder(context);
    NSUInteger hidden = ApolloActionMenuHiddenItemIDs(context).count;
    if (!order && hidden == 0) return @"Default";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (order) [parts addObject:@"Custom order"];
    if (hidden > 0) [parts addObject:[NSString stringWithFormat:@"%lu hidden", (unsigned long)hidden]];
    return [parts componentsJoinedByString:@" · "];
}

// "Moderator (Post)" → "Post": the section header already says Moderator.
static NSString *ApolloAMModeratorShortTitle(ApolloActionMenuContext context) {
    NSString *title = ApolloActionMenuContextTitle(context);
    NSRange open = [title rangeOfString:@"("], close = [title rangeOfString:@")" options:NSBackwardsSearch];
    if (open.location == NSNotFound || close.location == NSNotFound || close.location <= open.location) return title;
    return [title substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
}

@implementation ApolloActionMenuSettingsViewController {
    BOOL _appeared;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Action Menus";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Back from an editor: the rows' summaries may have changed.
    if (_appeared) [self rebuildForm];
    _appeared = YES;
}

// One menu: its glyph (••• or the shield — the button it opens from), its
// name, how it differs from the default, and its editor behind the chevron.
- (ApolloSettingsRow *)menuRowForContext:(NSString *)context title:(NSString *)title {
    BOOL all = [context isEqualToString:ApolloActionMenuEditorAllMenus];
    UIImage *glyph = all ? [UIImage systemImageNamed:@"list.bullet"] : ApolloAMPreviewButtonImage(context);
    ApolloSettingsRow *row =
        [ApolloSettingsRow disclosureRowWithID:[@"menu." stringByAppendingString:context]
                                         title:title
                                        detail:^NSString * { return ApolloAMMenuSummary(context); }
                                          push:^UIViewController * {
            return [[ApolloActionMenuEditorViewController alloc] initWithContext:context];
        }];
    row.detailAsSubtitle = YES; // "Custom order · 2 hidden" beside "Post (Comments)" truncated
    row.configure = ^(UITableViewCell *cell) {
        cell.imageView.image = glyph; // the theme pass tints it with the accent
    };
    return row;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    NSMutableArray<ApolloSettingsRow *> *regular = [NSMutableArray array];
    NSMutableArray<ApolloSettingsRow *> *moderator = [NSMutableArray array];
    for (ApolloActionMenuContext context in ApolloActionMenuAllContexts()) {
        BOOL mod = ApolloActionMenuContextIsModerator(context);
        [(mod ? moderator : regular) addObject:[self menuRowForContext:context
                                                                 title:mod ? ApolloAMModeratorShortTitle(context) : ApolloActionMenuContextTitle(context)]];
    }
    ApolloSettingsRow *all = [self menuRowForContext:ApolloActionMenuEditorAllMenus title:@"All Menus"];
    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Show or hide actions across every menu at once."
                                           rows:@[ all ]],
        [ApolloSettingsSection sectionWithTitle:@"••• Menus"
                                         footer:@"The ••• button’s menu in each place. Open one to reorder its actions or hide some, and to preview it."
                                           rows:regular],
        [ApolloSettingsSection sectionWithTitle:@"Moderator Menus"
                                         footer:@"The moderator shield’s menus. They only appear in subreddits you moderate."
                                           rows:moderator],
    ];
}

@end
