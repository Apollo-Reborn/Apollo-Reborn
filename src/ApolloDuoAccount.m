#import "ApolloDuoAccount.h"
#import "ApolloThemeRuntime.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

static void ApolloDuoAccountUpdateEmptyOverview(UITableView *table);

static void ApolloDuoCollectProfileIcons(id node, NSMutableDictionary *images) {
    Ivar titleIvar = class_getInstanceVariable([node class], "titleNode");
    Ivar iconIvar = class_getInstanceVariable([node class], "iconNode");
    if (titleIvar && iconIvar) {
        id titleNode = object_getIvar(node, titleIvar);
        id iconNode = object_getIvar(node, iconIvar);
        NSAttributedString *title = ((id (*)(id, SEL))objc_msgSend)(titleNode, NSSelectorFromString(@"attributedText"));
        UIImage *image = ((id (*)(id, SEL))objc_msgSend)(iconNode, @selector(image));
        if (title.length && image) images[title.string] = image;
    }
    NSArray *shortcutChildren = objc_getAssociatedObject(node, NSSelectorFromString(@"apollo_profileShortcutChildren"));
    if (shortcutChildren) {
        for (id child in shortcutChildren) ApolloDuoCollectProfileIcons(child, images);
        return;
    }
    if ([node respondsToSelector:NSSelectorFromString(@"subnodes")]) {
        for (id child in ((id (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"subnodes"))) ApolloDuoCollectProfileIcons(child, images);
    }
}


// A fixed icon column keeps Apollo's differently shaped assets from moving
// the label and separator horizontally from row to row.
@interface ApolloDuoAccountShortcutCell : UITableViewCell
@property(nonatomic, strong) UIImageView *shortcutIcon;
@property(nonatomic, strong) UILabel *shortcutLabel;
@end

@implementation ApolloDuoAccountShortcutCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:style reuseIdentifier:identifier];
    if (self) {
        _shortcutIcon = [UIImageView new];
        _shortcutIcon.contentMode = UIViewContentModeCenter;
        _shortcutLabel = [UILabel new];
        _shortcutLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _shortcutLabel.adjustsFontForContentSizeCategory = YES;
        _shortcutLabel.numberOfLines = 0;
        for (UIView *view in @[_shortcutIcon, _shortcutLabel]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [_shortcutIcon.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
            [_shortcutIcon.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_shortcutIcon.widthAnchor constraintEqualToConstant:60],
            [_shortcutIcon.heightAnchor constraintEqualToConstant:44],
            [_shortcutLabel.leadingAnchor constraintEqualToAnchor:_shortcutIcon.trailingAnchor constant:0],
            [_shortcutLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [_shortcutLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:50],
            [_shortcutLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8]
        ]];
        self.separatorInset = UIEdgeInsetsMake(0, 60, 0, 0);
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return self;
}
@end

@interface ApolloDuoAccountShortcuts () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation ApolloDuoAccountShortcuts {
    UITableView *_table;
    NSArray<NSString *> *_shortcuts;
    NSMutableDictionary<NSString *, UIImage *> *_images;
    __weak id _menuFirstNode;
    NSInteger _menuRowCount;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    _shortcuts = @[];
    _images = [NSMutableDictionary dictionary];
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.estimatedRowHeight = 50;
    _table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _table.sectionHeaderHeight = 16;
    _table.sectionFooterHeight = 0.01;
    if (@available(iOS 15.0, *)) _table.sectionHeaderTopPadding = 0;
    [self.view addSubview:_table];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:@"com.christianselig.ApolloSpecificThemeChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(profileMenuDidUpdate:) name:@"ApolloDuoProfileMenuUpdated" object:nil];
    [self updateTheme];
}
- (void)profileMenuDidUpdate:(NSNotification *)notification {
    if (notification.object != self.profileTable) return;
    _menuRowCount = -1;
    [self refreshProfileMenu];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _menuRowCount = -1;
    [self refreshProfileMenu];
}
- (void)refreshProfileMenu {
    if (!self.isViewLoaded) return;
    UITableView *table = self.profileTable;
    SEL selector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if ([table respondsToSelector:selector]) {
        NSInteger count = [table.dataSource tableView:table numberOfRowsInSection:0];
        id first = count ? ((id (*)(id, SEL, id))objc_msgSend)(table, selector, [NSIndexPath indexPathForRow:0 inSection:0]) : nil;
        if (_menuRowCount == count && _menuFirstNode == first && _images.count) return;
        _menuRowCount = count;
        _menuFirstNode = first;
        [_images removeAllObjects];
        for (NSInteger row = 0; row < MIN(count, 50); row++) {
            id node = ((id (*)(id, SEL, id))objc_msgSend)(table, selector, [NSIndexPath indexPathForRow:row inSection:0]);
            ApolloDuoCollectProfileIcons(node, _images);
        }
    }
    // Other profiles expose a different native menu (for example Multireddits
    // instead of private Saved/vote history). Keep only their real actions.
    NSArray *order = @[@"Posts", @"Comments", @"Saved", @"Hidden & Deleted", @"Upvoted", @"Downvoted", @"Friends", @"Hidden", @"Multireddits"];
    NSMutableArray *available = [NSMutableArray array];
    for (NSString *title in order) if (_images[title]) [available addObject:title];
    _shortcuts = available;
    ApolloDuoAccountUpdateEmptyOverview(self.profileTable);
    [self updateTheme];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)themeDidChange:(NSNotification *)notification {
    // Read the palette after Apollo's native theme observers finish.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateTheme]; });
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous]) [self themeDidChange:nil];
}
- (void)updateTheme {
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    _table.backgroundColor = self.view.backgroundColor;
    _table.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    [_table reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _images[@"Moderator Zone"] ? 3 : 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 1 ? _shortcuts.count : 1;
}
- (NSString *)titleAtIndexPath:(NSIndexPath *)path {
    return path.section == 0 ? @"Overview" : path.section == 2 ? @"Moderator Zone" : _shortcuts[path.row];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    ApolloDuoAccountShortcutCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AccountShortcut"];
    if (!cell) cell = [[ApolloDuoAccountShortcutCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AccountShortcut"];
    NSString *title = [self titleAtIndexPath:path];
    cell.shortcutLabel.text = title;
    cell.shortcutLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.shortcutLabel.textColor = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    cell.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemGroupedBackgroundColor;
    UIImage *image = _images[title];
    if (!image && path.section == 0) image = [UIImage systemImageNamed:@"rectangle.grid.1x2" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:25 weight:UIImageSymbolWeightRegular]];
    cell.shortcutIcon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    cell.shortcutIcon.tintColor = path.section == 2 ? UIColor.systemGreenColor : tableView.tintColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityLabel = title;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    if (self.selectShortcut) self.selectShortcut([self titleAtIndexPath:path]);
    [tableView deselectRowAtIndexPath:path animated:YES];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _table.frame = self.view.bounds;
}
@end

#import <objc/runtime.h>
#import <objc/message.h>
@interface ApolloDuoOverviewEmptyView : UIView
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, weak) UITableView *table;
@end

@implementation ApolloDuoOverviewEmptyView
- (void)layoutSubviews {
    [super layoutSubviews];
    UIViewController *owner = nil;
    for (UIResponder *responder = self.table.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) { owner = (id)responder; break; }
    }
    CGRect pane = ApolloDuoSplitContentFrame(owner, self);
    if (CGRectIsNull(pane)) pane = self.bounds;
    pane = CGRectIntersection(self.bounds, pane);
    self.label.frame = CGRectInset(pane, MIN(24, pane.size.width / 4), 0);
}
@end

static char kOverviewTable, kOverviewBoundary, kOverviewEmptyView;

BOOL ApolloDuoAccountIsOverviewTable(UITableView *table) {
    return [objc_getAssociatedObject(table, &kOverviewTable) boolValue];
}

static BOOL ApolloDuoAccountNodeIsMenu(id node) {
    NSString *name = NSStringFromClass([node class]);
    return [name hasSuffix:@"ProfileHeaderCellNode"]
        || [name hasSuffix:@"ProfileFeatureCellNode"]
        || [name hasSuffix:@"SeparatorCellNode"]
        || [name hasSuffix:@"SectionHeaderCellNode"]
        || objc_getAssociatedObject(node, NSSelectorFromString(@"apollo_profileShortcutChildren")) != nil;
}

static void ApolloDuoAccountUpdateEmptyOverview(UITableView *table) {
    ApolloDuoOverviewEmptyView *emptyView = objc_getAssociatedObject(table, &kOverviewEmptyView);
    BOOL empty = NO;
    if (objc_getAssociatedObject(table, &kOverviewTable)) {
        NSInteger count = [table.dataSource tableView:table numberOfRowsInSection:0];
        if (count > 1 && ApolloDuoAccountHidesProfileRow(table, [NSIndexPath indexPathForRow:count - 1 inSection:0])) empty = YES;
    }
    if (!empty) {
        if (table.backgroundView == emptyView) table.backgroundView = nil;
        return;
    }
    if (!emptyView) {
        emptyView = [[ApolloDuoOverviewEmptyView alloc] init];
        emptyView.table = table;
        UILabel *label = [[UILabel alloc] init];
        emptyView.label = label;
        [emptyView addSubview:label];
        label.text = @"This profile’s activity is hidden or unavailable.";
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.adjustsFontForContentSizeCategory = YES;
        objc_setAssociatedObject(table, &kOverviewEmptyView, emptyView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    emptyView.label.textColor = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    table.backgroundView = emptyView;
    [emptyView setNeedsLayout];
}

void ApolloDuoAccountConfigureOverviewTable(UITableView *table, BOOL hosted) {
    objc_setAssociatedObject(table, &kOverviewBoundary, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(table, &kOverviewTable, hosted ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Native Texture indices stay intact, including offscreen shortcut actions.
    // Only UITableView's displayed heights change while this profile is hosted.
    [table beginUpdates];
    [table endUpdates];
    [table setContentOffset:CGPointMake(0, -table.adjustedContentInset.top) animated:NO];
    ApolloDuoAccountUpdateEmptyOverview(table);
}

static BOOL ApolloDuoAccountNodeIsOverview(id node) {
    // Section header subnodes are attached lazily by Texture. Its stored text
    // node is already populated before the offscreen row receives a view.
    Ivar titleIvar = class_getInstanceVariable([node class], "titleTextNode");
    if (titleIvar && ApolloDuoAccountNodeIsOverview(object_getIvar(node, titleIvar))) return YES;
    SEL textSelector = NSSelectorFromString(@"attributedText");
    if ([node respondsToSelector:textSelector]) {
        NSAttributedString *text = ((id (*)(id, SEL))objc_msgSend)(node, textSelector);
        if ([text.string caseInsensitiveCompare:@"Overview"] == NSOrderedSame && text.length) return YES;
    }
    SEL childrenSelector = NSSelectorFromString(@"subnodes");
    if ([node respondsToSelector:childrenSelector]) {
        for (id child in ((id (*)(id, SEL))objc_msgSend)(node, childrenSelector)) {
            if (ApolloDuoAccountNodeIsOverview(child)) return YES;
        }
    }
    return NO;
}

BOOL ApolloDuoAccountHidesProfileRow(UITableView *table, NSIndexPath *path) {
    if (!objc_getAssociatedObject(table, &kOverviewTable) || path.section != 0) return NO;
    SEL nodeSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (![table respondsToSelector:nodeSelector]) return NO;
    // Ask the data source, not UITableView's geometry cache: asking the latter
    // from a row-height callback recursively starts the same measurement pass.
    NSInteger count = [table.dataSource tableView:table numberOfRowsInSection:0];
    id first = count ? ((id (*)(id, SEL, id))objc_msgSend)(table, nodeSelector, [NSIndexPath indexPathForRow:0 inSection:0]) : nil;
    NSArray *cached = objc_getAssociatedObject(table, &kOverviewBoundary);
    if (cached && [cached[0] integerValue] == count && [cached[1] pointerValue] == (__bridge void *)first) return path.row < [cached[2] integerValue];
    // Menu size varies with account capabilities. Find the semantic boundary,
    // never a fixed row number, and leave content intact before it has loaded.
    BOOL menuOnly = count > 1 && count <= 50;
    NSInteger menuPrefix = 0;
    for (NSInteger row = 0; row < MIN(count, 50); row++) {
        id node = ((id (*)(id, SEL, id))objc_msgSend)(table, nodeSelector, [NSIndexPath indexPathForRow:row inSection:0]);
        BOOL menuNode = ApolloDuoAccountNodeIsMenu(node);
        if (menuPrefix == row && menuNode) menuPrefix++;
        menuOnly = menuOnly && menuNode;
        if (ApolloDuoAccountNodeIsOverview(node)) {
            objc_setAssociatedObject(table, &kOverviewBoundary, @[@(count), [NSValue valueWithPointer:(__bridge void *)first], @(row)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return path.row < row;
        }
    }
    // A hidden/empty activity response can contain only the native profile menu,
    // with no Overview header. Those rows already live in the left pane.
    if (menuOnly) {
        objc_setAssociatedObject(table, &kOverviewBoundary, @[@(count), [NSValue valueWithPointer:(__bridge void *)first], @(count)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    // Keep any native loading/error/empty-state node, but never repeat the
    // leading menu while that state is visible.
    return path.row < menuPrefix;
}

// MARK: - Open portrait shortcut grid
//
// On the unfolded portrait display the Account tab keeps its native header,
// statistics and Overview, but presents the native shortcut rows as one
// two-column rounded group. Native rows stay in the table (hidden at zero
// height) so their availability, order of creation and tap handling remain
// Apollo's: the grid only mirrors their titles/icons and forwards each tap to
// the matching native row. The first shortcut row hosts the grid.

// Left-to-right reading order of the approved layout. Shortcuts Apollo does
// not offer for this account are skipped; unknown native ones are appended.
static NSArray<NSString *> *ApolloDuoAccountGridOrder(void) {
    return @[@"Posts", @"Saved", @"Comments", @"Hidden", @"Upvoted", @"Hidden & Deleted",
             @"Downvoted", @"Friends", @"Trophies", @"Moderator Zone"];
}

// Matches the native ProfileFeatureCellNode card: 15pt side insets, 10pt
// corners, a 60pt icon column and a 44pt minimum row.
static const CGFloat kApolloDuoGridInset = 15.0;
static const CGFloat kApolloDuoGridIconColumn = 60.0;
static const CGFloat kApolloDuoGridMinRow = 44.0;
static const CGFloat kApolloDuoGridTextPadding = 11.0;
static const CGFloat kApolloDuoGridTrailing = 12.0;

static void ApolloDuoCollectOrderedShortcuts(id node, NSMutableArray<NSString *> *titles,
                                             NSMutableDictionary<NSString *, UIImage *> *images,
                                             NSDictionary **attributes) {
    Ivar titleIvar = class_getInstanceVariable([node class], "titleNode");
    Ivar iconIvar = class_getInstanceVariable([node class], "iconNode");
    if (titleIvar && iconIvar) {
        id titleNode = object_getIvar(node, titleIvar);
        id iconNode = object_getIvar(node, iconIvar);
        NSAttributedString *title = ((id (*)(id, SEL))objc_msgSend)(titleNode, NSSelectorFromString(@"attributedText"));
        UIImage *image = ((id (*)(id, SEL))objc_msgSend)(iconNode, @selector(image));
        if (title.length && image && !images[title.string]) {
            images[title.string] = image;
            [titles addObject:title.string];
            if (attributes && !*attributes) *attributes = [title attributesAtIndex:0 effectiveRange:NULL];
        }
    }
    NSArray *shortcutChildren = objc_getAssociatedObject(node, NSSelectorFromString(@"apollo_profileShortcutChildren"));
    for (id child in shortcutChildren) ApolloDuoCollectOrderedShortcuts(child, titles, images, attributes);
}

static BOOL ApolloDuoAccountNodeIsShortcut(id node) {
    return [NSStringFromClass([node class]) hasSuffix:@"ProfileFeatureCellNode"]
        || objc_getAssociatedObject(node, NSSelectorFromString(@"apollo_profileShortcutChildren")) != nil;
}

@interface ApolloDuoAccountGridLayout : NSObject
@property(nonatomic) NSInteger rowCount;
@property(nonatomic) NSUInteger firstNode;
@property(nonatomic) NSInteger anchorRow;
@property(nonatomic) NSInteger endRow;          // first row after the shortcut block
@property(nonatomic, copy) NSArray<NSString *> *titles;
@property(nonatomic, copy) NSDictionary<NSString *, UIImage *> *images;
@property(nonatomic, strong) UIFont *font;
@property(nonatomic) CGFloat width;
@property(nonatomic, copy) NSString *contentSize;
@property(nonatomic) CGFloat height;
@end
@implementation ApolloDuoAccountGridLayout @end

static NSArray<NSNumber *> *ApolloDuoGridRowHeights(NSArray<NSString *> *titles, UIFont *font, CGFloat width) {
    CGFloat card = MAX(0, width - 2 * kApolloDuoGridInset);
    CGFloat column = floor(card / 2);
    CGFloat textWidth = MAX(20, column - kApolloDuoGridIconColumn - kApolloDuoGridTrailing);
    NSMutableArray *heights = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i += 2) {
        CGFloat row = kApolloDuoGridMinRow;
        for (NSUInteger j = i; j < MIN(i + 2, titles.count); j++) {
            CGRect bounds = [titles[j] boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                                    options:NSStringDrawingUsesLineFragmentOrigin
                                                 attributes:@{NSFontAttributeName: font} context:nil];
            row = MAX(row, ceil(bounds.size.height) + 2 * kApolloDuoGridTextPadding);
        }
        [heights addObject:@(row)];
    }
    return heights;
}

static char kApolloDuoGridLayoutKey, kApolloDuoGridAppliedKey, kApolloDuoGridViewKey;

static UIViewController *ApolloDuoAccountTableOwner(UITableView *table) {
    for (UIResponder *responder = table.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
    }
    return nil;
}

// Whether this table is the Account tab's own profile on the open portrait
// display. Closed, landscape (hosted dashboard) and regular phones return NO.
static BOOL ApolloDuoAccountGridApplies(UITableView *table) {
    if (!NSThread.isMainThread || !ApolloDuoSplitIsUnfoldedPortrait()) return NO;
    if (ApolloDuoAccountIsOverviewTable(table)) return NO;
    if (![table respondsToSelector:NSSelectorFromString(@"nodeForRowAtIndexPath:")]) return NO;
    UIViewController *owner = ApolloDuoAccountTableOwner(table);
    return [NSStringFromClass(owner.class) isEqualToString:@"Apollo.ProfileViewController"]
        && ApolloDuoSplitIsOwnAccountController(owner);
}

static ApolloDuoAccountGridLayout *ApolloDuoAccountGridLayoutForTable(UITableView *table) {
    if (!ApolloDuoAccountGridApplies(table)) return nil;
    SEL nodeSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    NSInteger count = [table.dataSource tableView:table numberOfRowsInSection:0];
    if (count < 2) return nil;
    id first = ((id (*)(id, SEL, id))objc_msgSend)(table, nodeSelector, [NSIndexPath indexPathForRow:0 inSection:0]);
    CGFloat width = CGRectGetWidth(table.bounds);
    NSString *contentSize = table.traitCollection.preferredContentSizeCategory;
    ApolloDuoAccountGridLayout *cached = objc_getAssociatedObject(table, &kApolloDuoGridLayoutKey);
    if (cached && cached.rowCount == count && cached.firstNode == (NSUInteger)(__bridge void *)first
        && fabs(cached.width - width) < 0.5 && [cached.contentSize isEqualToString:contentSize ?: @""]) {
        return cached.anchorRow >= 0 ? cached : nil;
    }
    ApolloDuoAccountGridLayout *layout = [ApolloDuoAccountGridLayout new];
    layout.rowCount = count;
    layout.firstNode = (NSUInteger)(__bridge void *)first;
    layout.width = width;
    layout.contentSize = contentSize ?: @"";
    layout.anchorRow = -1;
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableDictionary *images = [NSMutableDictionary dictionary];
    NSDictionary *attributes = nil;
    // The block runs from the first shortcut to the Overview header (or the
    // last menu node when the activity section has not loaded yet).
    for (NSInteger row = 0; row < MIN(count, 60); row++) {
        id node = ((id (*)(id, SEL, id))objc_msgSend)(table, nodeSelector, [NSIndexPath indexPathForRow:row inSection:0]);
        if (layout.anchorRow < 0) {
            if (ApolloDuoAccountNodeIsShortcut(node)) layout.anchorRow = row;
            else continue;
        }
        if (ApolloDuoAccountNodeIsOverview(node) || !ApolloDuoAccountNodeIsMenu(node)) {
            layout.endRow = row;
            break;
        }
        ApolloDuoCollectOrderedShortcuts(node, titles, images, &attributes);
        layout.endRow = row + 1;
    }
    if (layout.anchorRow >= 0 && titles.count) {
        NSMutableArray *ordered = [NSMutableArray array];
        for (NSString *title in ApolloDuoAccountGridOrder()) if (images[title]) [ordered addObject:title];
        for (NSString *title in titles) if (![ordered containsObject:title]) [ordered addObject:title];
        layout.titles = ordered;
        layout.images = images;
        layout.font = attributes[NSFontAttributeName] ?: [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        CGFloat height = 0;
        for (NSNumber *row in ApolloDuoGridRowHeights(ordered, layout.font, width)) height += row.doubleValue;
        layout.height = height;
    } else {
        layout.anchorRow = -1;
    }
    objc_setAssociatedObject(table, &kApolloDuoGridLayoutKey, layout, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (layout.anchorRow >= 0) {
        ApolloLog(@"[DuoAccount] portrait shortcut grid rows %ld..%ld items=%lu height=%.1f",
                  (long)layout.anchorRow, (long)layout.endRow, (unsigned long)layout.titles.count, layout.height);
    }
    return layout.anchorRow >= 0 ? layout : nil;
}

CGFloat ApolloDuoAccountGridRowHeight(UITableView *table, NSIndexPath *path) {
    if (path.section != 0) return -1;
    ApolloDuoAccountGridLayout *layout = ApolloDuoAccountGridLayoutForTable(table);
    if (!layout || path.row < layout.anchorRow || path.row >= layout.endRow) return -1;
    return path.row == layout.anchorRow ? layout.height : 0;
}

@interface ApolloDuoAccountGridButton : UIControl
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIView *separator;
@property(nonatomic, strong) UIColor *highlightColor;
@end
@implementation ApolloDuoAccountGridButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeCenter;
        _label = [UILabel new];
        _label.numberOfLines = 0;
        _separator = [UIView new];
        for (UIView *view in @[_icon, _label, _separator]) {
            view.userInteractionEnabled = NO;
            [self addSubview:view];
        }
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? self.highlightColor : UIColor.clearColor;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    self.icon.frame = CGRectMake(0, 0, kApolloDuoGridIconColumn, size.height);
    CGFloat textX = kApolloDuoGridIconColumn;
    self.label.frame = CGRectMake(textX, 0, MAX(0, size.width - textX - kApolloDuoGridTrailing), size.height);
    CGFloat hairline = 1.0 / MAX(1.0, self.traitCollection.displayScale);
    self.separator.frame = CGRectMake(textX, size.height - hairline,
                                      MAX(0, size.width - textX - kApolloDuoGridTrailing), hairline);
}
@end

@interface ApolloDuoAccountShortcutGrid : UIView
@property(nonatomic, weak) UITableView *table;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) NSArray<ApolloDuoAccountGridButton *> *buttons;
@property(nonatomic, strong) ApolloDuoAccountGridLayout *layout;
@end

@implementation ApolloDuoAccountShortcutGrid
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _card = [UIView new];
        _card.layer.cornerRadius = 10.0;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        _card.clipsToBounds = YES;
        [self addSubview:_card];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}
- (void)applyLayout:(ApolloDuoAccountGridLayout *)layout {
    BOOL sameItems = [self.layout.titles isEqualToArray:layout.titles] && self.buttons.count == layout.titles.count;
    self.layout = layout;
    if (!sameItems) {
        for (UIView *button in self.buttons) [button removeFromSuperview];
        NSMutableArray *buttons = [NSMutableArray array];
        for (NSString *title in layout.titles) {
            ApolloDuoAccountGridButton *button = [ApolloDuoAccountGridButton new];
            button.title = title;
            button.accessibilityLabel = title;
            [button addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
            [self.card addSubview:button];
            [buttons addObject:button];
        }
        self.buttons = buttons;
    }
    [self applyTheme];
    [self setNeedsLayout];
}
- (void)applyTheme {
    UIColor *page = ApolloThemePageBackgroundColor() ?: self.table.backgroundColor ?: UIColor.systemBackgroundColor;
    self.backgroundColor = page;
    self.card.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemGroupedBackgroundColor;
    // Resolve the text color live (as the landscape dashboard does). The
    // native title color captured at layout time belongs to the appearance
    // that was active then and would stay gray after a light/dark switch.
    UIColor *text = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    UIColor *accent = ApolloThemeAccentColor() ?: self.table.tintColor ?: UIColor.systemBlueColor;
    for (ApolloDuoAccountGridButton *button in self.buttons) {
        UIImage *image = self.layout.images[button.title];
        button.icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        button.icon.tintColor = [button.title isEqualToString:@"Moderator Zone"] ? UIColor.systemGreenColor : accent;
        button.label.text = button.title;
        button.label.font = self.layout.font;
        button.label.textColor = text;
        button.separator.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.6];
        button.highlightColor = [text colorWithAlphaComponent:0.08];
    }
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyTheme];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect card = CGRectInset(self.bounds, kApolloDuoGridInset, 0);
    self.card.frame = card;
    CGFloat column = floor(card.size.width / 2);
    NSArray<NSNumber *> *heights = ApolloDuoGridRowHeights(self.layout.titles, self.layout.font, self.bounds.size.width);
    CGFloat y = 0;
    for (NSUInteger row = 0; row < heights.count; row++) {
        CGFloat height = heights[row].doubleValue;
        for (NSUInteger col = 0; col < 2; col++) {
            NSUInteger index = row * 2 + col;
            if (index >= self.buttons.count) break;
            ApolloDuoAccountGridButton *button = self.buttons[index];
            CGFloat x = col * column;
            CGFloat w = col == 0 ? column : card.size.width - column;
            button.frame = CGRectMake(x, y, w, height);
            // Each column draws its own separators; the final row has none.
            button.separator.hidden = row + 1 >= heights.count;
        }
        y += height;
    }
}
- (void)open:(ApolloDuoAccountGridButton *)sender {
    UIViewController *owner = ApolloDuoAccountTableOwner(self.table);
    if (!owner) return;
    ApolloLog(@"[DuoAccount] portrait grid opens %@", sender.title);
    ApolloDuoAccountOpenShortcut(owner, sender.title);
}
@end

// Attach the grid to the anchor cell, and remove it from any other (reused)
// cell. Called from willDisplayCell, never from a layout pass.
void ApolloDuoAccountGridDisplayCell(UITableView *table, UITableViewCell *cell, NSIndexPath *path) {
    ApolloDuoAccountShortcutGrid *grid = objc_getAssociatedObject(cell, &kApolloDuoGridViewKey);
    ApolloDuoAccountGridLayout *layout = path.section == 0 ? ApolloDuoAccountGridLayoutForTable(table) : nil;
    BOOL anchor = layout && path.row == layout.anchorRow;
    UIView *nativeView = [cell respondsToSelector:NSSelectorFromString(@"node")]
        ? ((UIView *(*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"node")), @selector(view)) : nil;
    if (!anchor) {
        if (grid) {
            [grid removeFromSuperview];
            objc_setAssociatedObject(cell, &kApolloDuoGridViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            nativeView.accessibilityElementsHidden = NO;
        }
        return;
    }
    if (!grid) {
        grid = [[ApolloDuoAccountShortcutGrid alloc] initWithFrame:cell.contentView.bounds];
        objc_setAssociatedObject(cell, &kApolloDuoGridViewKey, grid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    grid.table = table;
    grid.frame = cell.contentView.bounds;
    [cell.contentView addSubview:grid];
    [cell.contentView bringSubviewToFront:grid];
    // The native first row remains beneath the opaque grid; keep it out of
    // VoiceOver so each shortcut is announced once.
    nativeView.accessibilityElementsHidden = YES;
    [grid applyLayout:layout];
}

// Re-evaluate after a rotation or fold: heights change only when the grid
// starts or stops applying, so this is a no-op otherwise.
void ApolloDuoAccountGridRefresh(UITableView *table) {
    if (!table.window && !ApolloDuoAccountTableOwner(table)) return;
    BOOL applies = ApolloDuoAccountGridLayoutForTable(table) != nil;
    BOOL applied = [objc_getAssociatedObject(table, &kApolloDuoGridAppliedKey) boolValue];
    for (UITableViewCell *cell in table.visibleCells) {
        NSIndexPath *path = [table indexPathForCell:cell];
        if (path) ApolloDuoAccountGridDisplayCell(table, cell, path);
    }
    if (applies == applied) return;
    objc_setAssociatedObject(table, &kApolloDuoGridAppliedKey, @(applies), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[DuoAccount] portrait shortcut grid %@", applies ? @"on" : @"off");
    [table beginUpdates];
    [table endUpdates];
    for (UITableViewCell *cell in table.visibleCells) {
        NSIndexPath *path = [table indexPathForCell:cell];
        if (path) ApolloDuoAccountGridDisplayCell(table, cell, path);
    }
}
