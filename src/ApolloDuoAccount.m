#import "ApolloDuoAccount.h"
#import "ApolloThemeRuntime.h"
#import "ApolloDuoSplitView.h"
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
