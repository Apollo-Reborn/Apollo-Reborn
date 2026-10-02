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
// Menus overview.
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

    // Mirror Apollo's real control: navigation-bar menus use the hollow dots;
    // inline post/comment menus use the filled dots.
    BOOL usesFilledMoreIcon =
        [context isEqualToString:ApolloActionMenuContextPost] ||
        [context isEqualToString:ApolloActionMenuContextComment];

    NSString *imageName =
        usesFilledMoreIcon ? @"inline-more-options" : @"option-more";

    UIImage *image = [[UIImage imageNamed:imageName
                                 inBundle:NSBundle.mainBundle
            compatibleWithTraitCollection:nil]
                      imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    return image ?: [UIImage systemImageNamed:@"ellipsis"];
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
    BOOL _dismissing;
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
    if (_dismissing) return;
    _dismissing = YES;

    UIWindow *window = self.view.window;
    if (!window) {
        [self dismissViewControllerAnimated:NO completion:nil];
        return;
    }

    // Keep the final visible state completely independent of the presented
    // controller while UIKit removes that controller underneath it.
    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.backgroundColor = UIColor.clearColor;
    overlay.userInteractionEnabled = NO;

    UIView *dimmingSnapshot = [_dimmingView snapshotViewAfterScreenUpdates:NO];
    UIView *cardSnapshot = [_card snapshotViewAfterScreenUpdates:NO];
    UIView *cancelSnapshot = [_cancelButton snapshotViewAfterScreenUpdates:NO];

    dimmingSnapshot.frame = [self.view convertRect:_dimmingView.frame toView:window];
    cardSnapshot.frame = [self.view convertRect:_card.frame toView:window];
    cancelSnapshot.frame = [self.view convertRect:_cancelButton.frame toView:window];

    [overlay addSubview:dimmingSnapshot];
    [overlay addSubview:cardSnapshot];
    [overlay addSubview:cancelSnapshot];
    [window addSubview:overlay];

    // The snapshots now exactly cover the live preview, so remove the real
    // controller without asking UIKit to animate either controller.
    _dimmingView.hidden = YES;
    _card.hidden = YES;
    _cancelButton.hidden = YES;

    [self dismissViewControllerAnimated:NO completion:^{
        CGFloat distance = CGRectGetHeight(overlay.bounds) -
                           MIN(CGRectGetMinY(cardSnapshot.frame),
                               CGRectGetMinY(cancelSnapshot.frame));

        CGAffineTransform offscreen =
            CGAffineTransformMakeTranslation(0.0, distance);

        [UIView animateWithDuration:0.22
                              delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            dimmingSnapshot.alpha = 0.0;
            cardSnapshot.transform = offscreen;
            cancelSnapshot.transform = offscreen;
        } completion:^(__unused BOOL finished) {
            [overlay removeFromSuperview];
        }];
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
        : [NSString stringWithFormat:@"%@, shown when relevant", row.item.title];
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
@property (nonatomic) BOOL reservesGripSpace;
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
    _reservesGripSpace = NO;
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

- (void)setReservesGripSpace:(BOOL)reservesGripSpace {
    if (_reservesGripSpace == reservesGripSpace) return;
    _reservesGripSpace = reservesGripSpace;
    [self layoutAccessory];
}

// The accessory view's bounds drive UIKit's trailing placement, so it is
// sized here (never from layoutSubviews) whenever the grip or its reserved
// space changes.
- (void)layoutAccessory {
    BOOL hasGripSlot = self.showsGrip || self.reservesGripSpace;
    CGFloat width = kApolloAMCheckmarkWidth + (hasGripSlot ? kApolloAMAccessoryGap + kApolloAMGripWidth : 0.0);
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
// Exact item-row heights (see itemRowHeightWithSubtitle:itemID:).
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
    } else if (!ApolloNativeActionMenusActive()) {
        // Classic always appends Apollo Reborn actions after Apollo's native
        // actions, regardless of the saved Liquid Glass ordering.
        NSMutableArray<ApolloActionMenuItem *> *native = [NSMutableArray array];
        NSMutableArray<ApolloActionMenuItem *> *tweak = [NSMutableArray array];

        for (ApolloActionMenuItem *item in items) {
            [(item.isTweakRow ? tweak : native) addObject:item];
        }

        items = [[native arrayByAddingObjectsFromArray:tweak] mutableCopy];
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
            ? [NSString stringWithFormat:@"%@ buttons stay at the top and can’t be hidden.", item.title]
            : [NSString stringWithFormat:@"%@ stays at the top and can’t be hidden.", item.title]];
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
        ApolloSettingsRow *row =
            [ApolloSettingsRow customRowWithID:[self itemRowIDForItemID:itemID]
                                          cell:^UITableViewCell *(UITableView *tableView,
                                                                  __unused ApolloSettingsRow *r) {
            return [weakSelf itemCellForItem:item
                                      hidden:[weakSelf itemIsHidden:item.itemID]
                                     inTable:tableView];
        }
                                      onSelect:^{
            [weakSelf toggleItemWithID:itemID];
        }];

        row.height = ^CGFloat {
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return UITableViewAutomaticDimension;

            BOOL subtitle = strongSelf.editingAllMenus ||
                !ApolloActionMenuItemWasOffered(strongSelf.context, itemID);

            CGFloat height = [strongSelf itemRowHeightWithSubtitle:subtitle
                                                       itemID:itemID];

            if (strongSelf.editingAllMenus) {
                UITableViewCell *cell =
                    [strongSelf cellForRowID:[strongSelf itemRowIDForItemID:itemID]];

                if ([cell isKindOfClass:[ApolloAMItemCell class]] &&
                    cell.detailTextLabel.text.length > 0) {
                    CGFloat width = CGRectGetWidth(cell.bounds);

                    [cell setNeedsLayout];
                    [cell layoutIfNeeded];

                    CGFloat required =
                        ceil([cell systemLayoutSizeFittingSize:
                                  CGSizeMake(width, UILayoutFittingCompressedSize.height)
                              withHorizontalFittingPriority:UILayoutPriorityRequired
                                    verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);

                    height = MAX(height, required);
                }
            }

            return height;
        };

        [itemRows addObject:row];
    }

    // ---- Reset ----

    ApolloSettingsRow *reset =
        [ApolloSettingsRow buttonRowWithID:kApolloAMRowReset
                                     title:self.editingAllMenus
                                         ? @"Reset All Menus…"
                                         : @"Reset Menu…"
                                    action:^{
            [weakSelf presentResetMenuSheet];
        }];

    reset.enabled = ^BOOL {
        return weakSelf.editingAllMenus
            ? ApolloActionMenuCustomizedContextCount() > 0
            : ApolloActionMenuContextIsCustomized(weakSelf.context);
    };

    NSString *menuFooter;
    NSString *itemsFooter;

    if (self.editingAllMenus) {
        menuFooter =
            @"\nShow or hide actions across all menus, including moderator menus. "
             "Actions enabled here appear in every menu that supports them.";

        itemsFooter =
            @"Tap an action to show or hide it across the menus that support it.";
    } else {
        if (ApolloActionMenuContextIsModerator(context)) {
            NSString *description = ApolloActionMenuContextDescription(context);
            description = [description stringByReplacingOccurrencesOfString:@"The shield menu"
                                                                  withString:@"The \uFFFC menu"];
            menuFooter = [description stringByAppendingString:@" Tap \uFFFC above to preview."];
        } else {
            NSString *description = ApolloActionMenuContextDescription(context);
            description = [description stringByReplacingOccurrencesOfString:@"•••"
                                                                  withString:@"\uFFFC"];
            menuFooter =
                [description stringByAppendingString:@" Tap \uFFFC above to preview."];
        }

        itemsFooter =
            @"Tap an action to show or hide it. Drag to reorder. "
             "Some actions are only available in certain contexts.";

        NSString *lockedNote = [self lockedItemsNote];
        if (lockedNote) {
            itemsFooter =
                [itemsFooter stringByAppendingFormat:@" %@", lockedNote];
        }

        if (!ApolloNativeActionMenusActive()) {
            NSString *note =
                @"Apollo Reborn actions stay below Apollo actions and "
                 "can’t be reordered.";

            itemsFooter =
                [itemsFooter stringByAppendingFormat:@"\n\n%@", note];
        }
    }

    ApolloSettingsSection *introSection =
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:menuFooter
                                           rows:@[]];

    ApolloSettingsSection *itemsSection =
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:itemsFooter
                                           rows:itemRows];

    ApolloSettingsSection *resetSection =
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:self.editingAllMenus ? menuFooter : nil
                                           rows:@[ reset ]];

    if (self.editingAllMenus) {
        // The introduction belongs to the Reset section here. Keeping it in a
        // separate empty section makes inset-grouped tables insert two normal
        // section gaps between Reset and the introductory text.
        return @[ resetSection, itemsSection ];
    }

    return @[ introSection, itemsSection, resetSection ];
}

- (UITableViewCell *)itemCellForItem:(ApolloActionMenuItem *)item hidden:(BOOL)hidden inTable:(UITableView *)tableView {
    static NSString *const reuseID = @"Cell_ActionMenuItem";
    ApolloAMItemCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) cell = [[ApolloAMItemCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
    cell.itemID = item.itemID;
    cell.textLabel.text = item.title;
    cell.imageView.image = [item icon];
    BOOL fixedTweakRow =
        !self.editingAllMenus &&
        !ApolloNativeActionMenusActive() &&
        item.isTweakRow;

    cell.showsGrip = !self.editingAllMenus && !fixedTweakRow;
    cell.reservesGripSpace = fixedTweakRow;
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
- (CGFloat)itemRowHeightWithSubtitle:(BOOL)subtitle
                              itemID:(NSString *)itemID {
    UITableView *table = self.tableView;
    CGFloat width = CGRectGetWidth(table.bounds) - table.layoutMargins.left - table.layoutMargins.right;
    UITableViewCell *sample = table.visibleCells.firstObject;
    if (sample && sample.superview) width = CGRectGetWidth([sample.superview convertRect:sample.frame toView:table]);
    if (width <= 0.0) return UITableViewAutomaticDimension;
    NSString *key = [NSString stringWithFormat:@"%d|%@|%.0f|%@",
                     subtitle,
                     itemID ?: @"",
                     width,
                     table.traitCollection.preferredContentSizeCategory ?: @""];
    NSNumber *cached = self.itemRowHeights[key];
    if (cached) return cached.doubleValue;

    if (!self.measuringItemCell) {
        self.measuringItemCell = [[ApolloAMItemCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    }
    ApolloAMItemCell *cell = self.measuringItemCell;
    cell.textLabel.text = @"Measure";
    if (!subtitle) {
        cell.detailTextLabel.text = nil;
    } else if ([itemID isEqualToString:@"moderator"]) {
        cell.detailTextLabel.text = @"Shown in subreddits you moderate";
    } else {
        cell.detailTextLabel.text = @"Shown when relevant";
    }
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
    if (offered) {
        cell.detailTextLabel.text = nil;
    } else if ([item.itemID isEqualToString:@"moderator"]) {
        cell.detailTextLabel.text = @"Shown in subreddits you moderate";
    } else {
        cell.detailTextLabel.text = @"Shown when relevant";
    }
    if (self.editingAllMenus) {
        NSArray *contexts = [self contextsForItem:item.itemID];

        NSUInteger hiddenCount = 0;
        for (NSString *context in contexts) {
            if (ApolloActionMenuIsItemHidden(context, item.itemID)) {
                hiddenCount++;
            }
        }

        if (hiddenCount == 0) {
            cell.detailTextLabel.text = nil;
        } else {
            NSMutableArray<NSString *> *names = [NSMutableArray array];

            for (NSString *context in contexts) {
                if (!ApolloActionMenuIsItemHidden(context, item.itemID)) {
                    continue;
                }

                NSString *name = ApolloActionMenuContextTitle(context);

                if (ApolloActionMenuContextIsModerator(context)) {
                    name = [@"Moderator " stringByAppendingString:name];
                }

                [names addObject:name];
            }

            NSString *menuList;
            if (names.count == 1) {
                menuList = names[0];
            } else if (names.count == 2) {
                menuList = [names componentsJoinedByString:@" and "];
            } else {
                NSArray<NSString *> *leading =
                    [names subarrayWithRange:NSMakeRange(0, names.count - 1)];

                menuList = [NSString stringWithFormat:@"%@ and %@",
                    [leading componentsJoinedByString:@", "],
                    names.lastObject];
            }

            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"Hidden in %@", menuList];
        }
    }
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
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
    cell.accessibilityLabel = offered ? item.title : [NSString stringWithFormat:@"%@, shown when relevant", item.title];
    if (self.editingAllMenus) {
        cell.accessibilityValue = cell.detailTextLabel.text ?: @"Shown";
    } else {
        cell.accessibilityValue = hidden ? @"Hidden" : @"Shown";
    }
    cell.accessibilityHint = self.editingAllMenus
        ? (hidden ? @"Double tap to show in all menus." : @"Double tap to hide in all menus.")
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
    [self refreshResetRow];
    [self refreshPreviewButton];
}

- (void)refreshResetRow {
    [self reloadRowWithID:kApolloAMRowReset];
}

- (void)presentResetMenuSheet {
    if (self.presentedViewController) return;

    if (self.editingAllMenus) {
        UIAlertController *sheet =
            [UIAlertController alertControllerWithTitle:@"Reset All Menus"
                                                message:@"This restores the default order and visibility in every menu."
                                         preferredStyle:UIAlertControllerStyleActionSheet];

        __weak __typeof(self) weakSelf = self;

        [sheet addAction:
            [UIAlertAction actionWithTitle:@"Reset All Menus"
                                     style:UIAlertActionStyleDestructive
                                   handler:^(__unused UIAlertAction *action) {
                [weakSelf resetCurrentMenuOrderOnly:NO];
            }]];

        [sheet addAction:
            [UIAlertAction actionWithTitle:@"Cancel"
                                     style:UIAlertActionStyleCancel
                                   handler:nil]];

        UITableViewCell *cell = [self cellForRowID:kApolloAMRowReset];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect =
            cell ? cell.bounds : CGRectZero;

        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Reset Menu"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak __typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Reset Order Only"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf resetCurrentMenuOrderOnly:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Reset Order and Visibility"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf resetCurrentMenuOrderOnly:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UITableViewCell *cell = [self cellForRowID:kApolloAMRowReset];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectZero;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)resetCurrentMenuOrderOnly:(BOOL)orderOnly {
    for (NSString *context in (self.editingAllMenus ? ApolloActionMenuAllContexts() : @[ self.context ])) {
        if (orderOnly) ApolloActionMenuResetOrder(context);
        else ApolloActionMenuResetContext(context);
    }

    // Rebuild the items first, then refresh the Reset row's final enabled state.
    NSString *firstItemRowID = [self firstItemRowID];
    if (firstItemRowID) {
        [self rebuildSectionContainingRowID:firstItemRowID withRowAnimation:UITableViewRowAnimationFade];
    }
    [self refreshResetRow];
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
    if (![self indexPathIsItemRow:indexPath]) return NO;

    NSArray<ApolloActionMenuItem *> *items = [self editableItems];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)items.count) return NO;

    ApolloActionMenuItem *item = items[(NSUInteger)indexPath.row];
    return ApolloNativeActionMenusActive() || !item.isTweakRow;
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

    // UIKit has already moved the cell: bring the form model in line WITHOUT
    // any table update. Reloading the items section here (even a turn later,
    // without animation) replaced the cells under the still-settling drop
    // preview — the moved row drawn twice, its neighbours re-laid out
    // mid-animation (device recording, 2026-09-24). The reset row and the
    // preview button follow once the drop session has ended.
    [self noteRowMovedFromIndexPath:fromIndexPath toIndexPath:toIndexPath];
    ApolloLog(@"[ActionMenuSettings] row %ld -> %ld noted in the model, no reload", (long)fromIndexPath.row, (long)toIndexPath.row);
}

- (void)tableView:(UITableView *)tableView dropSessionDidEnd:(id<UIDropSession>)session {
    // The drop is over (animation included): now refresh the Reset row's
    // enabled state and update the preview. Kept off the drop's own turn so
    // this work never overlaps the settle.
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refreshResetRow];
        [strongSelf refreshPreviewButton];
    });
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    if (![self indexPathIsItemRow:sourceIndexPath]) return sourceIndexPath;

    NSInteger itemsSection = [self itemsSectionIndex];
    NSInteger lastRow = MAX([tableView numberOfRowsInSection:itemsSection] - 1, 0);

    // Classic keeps Apollo Reborn actions in a fixed tail. Native actions may
    // be reordered within their own block, but cannot be dropped into that tail.
    if (!ApolloNativeActionMenusActive()) {
        NSArray<ApolloActionMenuItem *> *items = [self editableItems];
        for (NSUInteger i = 0; i < items.count; i++) {
            if (items[i].isTweakRow) {
                if (i == 0) return sourceIndexPath;
                lastRow = (NSInteger)i - 1;
                break;
            }
        }
    }

    if ([self indexPathIsItemRow:proposedDestinationIndexPath]) {
        NSInteger row = MIN(proposedDestinationIndexPath.row, lastRow);
        return [NSIndexPath indexPathForRow:row inSection:itemsSection];
    }

    NSInteger row = proposedDestinationIndexPath.section < itemsSection ? 0 : lastRow;
    return [NSIndexPath indexPathForRow:row inSection:itemsSection];
}

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    BOOL movable = [self tableView:tableView canMoveRowAtIndexPath:indexPath];
    ApolloLog(@"[ActionMenuSettings] drag begin asked for %ld/%ld (movable: %d)",
              (long)indexPath.section, (long)indexPath.row, movable);
    if (!movable) return @[];
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

- (void)tableView:(UITableView *)tableView
willDisplayFooterView:(UIView *)view
       forSection:(NSInteger)section {
    [super tableView:tableView willDisplayFooterView:view forSection:section];

    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) {
        return;
    }

    UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;

    UILabel *label = footer.textLabel;

    if (self.editingAllMenus) {
        return;
    }

    if (section != 0) {
        // Footer views are reused. Give non-intro footers their own current
        // text so an accessibility label from the intro cannot carry over.
        footer.isAccessibilityElement = YES;
        footer.accessibilityLabel = label.text;
        return;
    }
    if (!label || [label.text rangeOfString:@"\uFFFC"].location == NSNotFound) return;

    NSString *iconName;
    if (ApolloActionMenuContextIsModerator(self.context)) {
        iconName = @"option-moderator";
    } else if (self.context == ApolloActionMenuContextFeed ||
               self.context == ApolloActionMenuContextPostDetail) {
        iconName = @"option-more";
    } else {
        iconName = @"inline-more-options";
    }

    UIImage *icon =
        [[UIImage imageNamed:iconName
                    inBundle:NSBundle.mainBundle
   compatibleWithTraitCollection:view.traitCollection]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    if (!icon) return;

    NSString *source = label.text;
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];

    NSArray<NSString *> *parts = [source componentsSeparatedByString:@"\uFFFC"];

    for (NSUInteger i = 0; i < parts.count; i++) {
        [result appendAttributedString:
            [[NSAttributedString alloc] initWithString:parts[i]]];

        if (i + 1 < parts.count) {
            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            attachment.image = icon;

            CGFloat iconWidth = label.font.capHeight * 1.8;
            CGFloat aspect = icon.size.width / icon.size.height;
            CGFloat iconHeight = iconWidth / aspect;
            CGFloat yOffset;
            if (ApolloActionMenuContextIsModerator(self.context)) {
                // Tuned for the taller shield asset.
                yOffset = 1.5 - (iconHeight * 0.33);
            } else {
                // The shallow dots assets need to sit higher on the text baseline.
                yOffset = [iconName isEqualToString:@"inline-more-options"] ? 3.0 : 2.0;
            }

            attachment.bounds =
                CGRectMake(0.0, yOffset, iconWidth, iconHeight);

            [result appendAttributedString:
                [NSAttributedString attributedStringWithAttachment:attachment]];
        }
    }

    [result addAttribute:NSForegroundColorAttributeName
                   value:label.textColor
                   range:NSMakeRange(0, result.length)];

    label.attributedText = result;

    NSString *actionName = ApolloActionMenuContextIsModerator(self.context)
        ? @"Moderator Actions"
        : @"More Actions";

    NSString *description = ApolloActionMenuContextDescription(self.context);
    if (ApolloActionMenuContextIsModerator(self.context)) {
        description =
            [description stringByReplacingOccurrencesOfString:@"The shield menu"
                                                   withString:
                [NSString stringWithFormat:@"The %@ menu", actionName]];
    } else {
        description =
            [description stringByReplacingOccurrencesOfString:@"•••"
                                                   withString:actionName];
    }

    NSString *accessibilityText =
        [description stringByAppendingString:@" Tap above to preview this menu."];

    label.accessibilityLabel = accessibilityText;
    footer.isAccessibilityElement = YES;
    footer.accessibilityLabel = accessibilityText;
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    // Local same-table reorders with a .move/insertAtDestination proposal are
    // committed by UIKit through tableView:moveRowAtIndexPath:toIndexPath:
    // before this is called; nothing else can be dropped here.
}

@end

#pragma mark - The hub

// A menu row's detail: how the menu has been customized.
static NSString *ApolloAMMenuSummary(NSString *context) {
    if ([context isEqualToString:ApolloActionMenuEditorAllMenus]) {
        NSMutableSet<NSString *> *hiddenActions = [NSMutableSet set];

        for (NSString *menuContext in ApolloActionMenuAllContexts()) {
            [hiddenActions unionSet:ApolloActionMenuHiddenItemIDs(menuContext)];
        }

        NSUInteger hidden = hiddenActions.count;
        if (hidden == 0) return nil;

        return [NSString stringWithFormat:@"%lu action%@ hidden",
            (unsigned long)hidden,
            hidden == 1 ? @"" : @"s"];
    }

    BOOL order = ApolloActionMenuHasCustomOrder(context);
    NSUInteger hidden = ApolloActionMenuHiddenItemIDs(context).count;

    if (!order && hidden == 0) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (order) [parts addObject:@"Custom order"];
    if (hidden > 0) {
        [parts addObject:[NSString stringWithFormat:@"%lu action%@ hidden",
            (unsigned long)hidden,
            hidden == 1 ? @"" : @"s"]];
    }

    return [parts componentsJoinedByString:@" · "];
}

@implementation ApolloActionMenuSettingsViewController {
    BOOL _appeared;
    NSMutableDictionary<NSString *, NSNumber *> *_menuRowHeights;
    UITableViewCell *_measuringMenuCell;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Customize Action Menus";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Back from an editor: the rows' summaries may have changed. Refresh them
    // in place rather than reloading the form during the navigation transition.
    if (_appeared) [self refreshSummaries];
    _appeared = YES;
}

- (void)refreshSummaries {
    NSArray<NSString *> *contexts =
        [@[ ApolloActionMenuEditorAllMenus ]
            arrayByAddingObjectsFromArray:ApolloActionMenuAllContexts()];

    for (NSString *context in contexts) {
        UITableViewCell *cell =
            [self cellForRowID:[@"menu." stringByAppendingString:context]];

        if (cell) {
            cell.detailTextLabel.text = ApolloAMMenuSummary(context);
        }
    }

    // The summary can add or remove a subtitle, so let the table ask each
    // affected row for its new measured height without reloading the cells.
    [UIView performWithoutAnimation:^{
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
        [self.tableView layoutIfNeeded];
    }];
}

- (void)tableView:(UITableView *)tableView
willDisplayHeaderView:(UIView *)view
       forSection:(NSInteger)section {
    [super tableView:tableView willDisplayHeaderView:view forSection:section];

    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    if (section != 1 && section != 2) return;

    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    UILabel *label = header.textLabel;

    NSString *imageName = section == 1 ? @"option-more" : @"option-moderator";
    NSString *title = section == 1 ? @"Menus" : @"Moderator Menus";

    if (@available(iOS 18.0, *)) {
        // Modern Settings-style section headings use sentence case.
    } else {
        title = title.uppercaseString;
    }

    UIImage *image = [[UIImage imageNamed:imageName
                                 inBundle:NSBundle.mainBundle
            compatibleWithTraitCollection:view.traitCollection]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    if (!image) return;

    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = image;

    // Give both header glyphs the same optical width. Apollo's source PDFs
    // have quite different proportions and vertical centres.
    CGFloat iconWidth = label.font.capHeight * 1.8;
    CGFloat aspectRatio = image.size.width / image.size.height;
    CGFloat iconHeight = iconWidth / aspectRatio;
    CGFloat yOffset = section == 1 ? 2.0 : -2.5;

    attachment.bounds = CGRectMake(0.0,
                                   yOffset,
                                   iconWidth,
                                   iconHeight);

    NSMutableAttributedString *text =
        [[NSMutableAttributedString alloc] initWithAttributedString:
            [NSAttributedString attributedStringWithAttachment:attachment]];

    [text appendAttributedString:
        [[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:title]]];

    label.attributedText = text;

    NSString *accessibilityTitle =
        section == 1 ? @"Action Menus" : @"Moderator Action Menus";

    label.accessibilityLabel = accessibilityTitle;
    header.isAccessibilityElement = YES;
    header.accessibilityLabel = accessibilityTitle;
}

// Measure the two hub-row variants once per width and Dynamic Type size.
// A customized menu uses a subtitle cell and should grow to fit that second line.
- (CGFloat)menuRowHeightWithSubtitle:(BOOL)subtitle {
    UITableView *table = self.tableView;
    CGFloat width = CGRectGetWidth(table.bounds);
    if (width <= 0.0) return UITableViewAutomaticDimension;

    NSString *key = [NSString stringWithFormat:@"%d|%.0f|%@",
                     subtitle,
                     width,
                     table.traitCollection.preferredContentSizeCategory ?: @""];
    NSNumber *cached = _menuRowHeights[key];
    if (cached) return cached.doubleValue;

    if (!_measuringMenuCell) {
        _measuringMenuCell =
            [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                   reuseIdentifier:nil];
    }

    UITableViewCell *cell = _measuringMenuCell;
    cell.textLabel.text = @"Post";
    cell.detailTextLabel.text = subtitle ? @"Custom order · 2 actions hidden" : nil;
    cell.bounds = CGRectMake(0.0, 0.0, width, 100.0);
    ApolloSettingsApplyCellTypography(cell);

    [cell setNeedsLayout];
    [cell layoutIfNeeded];

    CGFloat height =
        ceil([cell systemLayoutSizeFittingSize:
                  CGSizeMake(width, UILayoutFittingCompressedSize.height)
              withHorizontalFittingPriority:UILayoutPriorityRequired
                    verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);

    if (height <= 0.0) return UITableViewAutomaticDimension;
    if (!_menuRowHeights) _menuRowHeights = [NSMutableDictionary dictionary];
    _menuRowHeights[key] = @(height);
    return height;
}

// One menu: its name, customization status, and editor behind the chevron.
- (ApolloSettingsRow *)menuRowForContext:(NSString *)context title:(NSString *)title {
    ApolloSettingsRow *row =
        [ApolloSettingsRow disclosureRowWithID:[@"menu." stringByAppendingString:context]
                                         title:title
                                        detail:^NSString * {
        return ApolloAMMenuSummary(context);
    }
                                          push:^UIViewController * {
        return [[ApolloActionMenuEditorViewController alloc] initWithContext:context];
    }];

    row.detailAsSubtitle = YES;

    __weak __typeof(self) weakSelf = self;
    row.height = ^CGFloat {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return UITableViewAutomaticDimension;

        return [strongSelf menuRowHeightWithSubtitle:
            ApolloAMMenuSummary(context).length > 0];
    };

    return row;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    NSMutableArray<ApolloSettingsRow *> *regular = [NSMutableArray array];
    NSMutableArray<ApolloSettingsRow *> *moderator = [NSMutableArray array];
    for (ApolloActionMenuContext context in ApolloActionMenuAllContexts()) {
        BOOL mod = ApolloActionMenuContextIsModerator(context);
        [(mod ? moderator : regular) addObject:[self menuRowForContext:context
                                                                 title:ApolloActionMenuContextTitle(context)]];
    }
    ApolloSettingsRow *all = [self menuRowForContext:ApolloActionMenuEditorAllMenus title:@"All Menus"];
    return @[
        [ApolloSettingsSection sectionWithTitle:nil
                                         footer:@"Show or hide actions across every menu at once."
                                           rows:@[ all ]],
        [ApolloSettingsSection sectionWithTitle:@"Menus"
                                         footer:nil
                                           rows:regular],
        [ApolloSettingsSection sectionWithTitle:@"Moderator Menus"
                                         footer:@"Shown in subreddits you moderate."
                                           rows:moderator],
    ];
}

@end
