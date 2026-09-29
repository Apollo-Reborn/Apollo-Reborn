#import "ApolloSettingsForm.h"

#import <objc/runtime.h>

#import "ApolloCommon.h"

typedef NS_ENUM(NSInteger, ApolloSFRowKind) {
    ApolloSFRowKindSwitch = 0,
    ApolloSFRowKindValue,
    ApolloSFRowKindDisclosure,
    ApolloSFRowKindButton,
    ApolloSFRowKindCustom,
};

@interface ApolloSettingsRow ()
@property (nonatomic) ApolloSFRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) BOOL (^isOn)(void);
@property (nonatomic, copy) void (^onToggle)(UISwitch *sender);
@property (nonatomic, copy) NSString * (^detail)(void);
@property (nonatomic, copy) void (^onSelect)(void);
@property (nonatomic, copy) UIViewController * (^push)(void);
@property (nonatomic, copy) ApolloSettingsCellBlock cellBlock;
@end

@implementation ApolloSettingsRow

- (instancetype)initWithID:(NSString *)rowID kind:(ApolloSFRowKind)kind {
    if ((self = [super init])) {
        _rowID = [rowID copy];
        _kind = kind;
        _showHideAnimation = UITableViewRowAnimationFade;
    }
    return self;
}

+ (instancetype)switchRowWithID:(NSString *)rowID title:(NSString *)title
                           isOn:(BOOL (^)(void))isOn onToggle:(void (^)(UISwitch *))onToggle {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindSwitch];
    row.title = title;
    row.isOn = isOn;
    row.onToggle = onToggle;
    return row;
}

+ (instancetype)valueRowWithID:(NSString *)rowID title:(NSString *)title
                        detail:(NSString * (^)(void))detail onSelect:(void (^)(void))onSelect {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindValue];
    row.title = title;
    row.detail = detail;
    row.onSelect = onSelect;
    return row;
}

+ (instancetype)disclosureRowWithID:(NSString *)rowID title:(NSString *)title
                             detail:(NSString * (^)(void))detail push:(UIViewController * (^)(void))push {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindDisclosure];
    row.title = title;
    row.detail = detail;
    row.push = push;
    return row;
}

+ (instancetype)buttonRowWithID:(NSString *)rowID title:(NSString *)title action:(void (^)(void))action {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindButton];
    row.title = title;
    row.onSelect = action;
    return row;
}

+ (instancetype)customRowWithID:(NSString *)rowID cell:(ApolloSettingsCellBlock)cell
                       onSelect:(void (^)(void))onSelect {
    ApolloSettingsRow *row = [[self alloc] initWithID:rowID kind:ApolloSFRowKindCustom];
    row.cellBlock = cell;
    row.onSelect = onSelect;
    return row;
}

- (BOOL)isVisible {
    return self.visible ? self.visible() : YES;
}

- (BOOL)isSelectable {
    switch (self.kind) {
        case ApolloSFRowKindSwitch: return NO;
        case ApolloSFRowKindDisclosure: return YES;
        case ApolloSFRowKindButton: return YES;
        case ApolloSFRowKindValue:
        case ApolloSFRowKindCustom: return self.onSelect != nil;
    }
    return NO;
}

@end

@interface ApolloSettingsSection ()
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSArray<ApolloSettingsRow *> *rows;
@property (nonatomic, readonly) BOOL isVisible;
@end

@implementation ApolloSettingsSection

+ (instancetype)sectionWithTitle:(NSString *)title footer:(NSString *)footer
                            rows:(NSArray<ApolloSettingsRow *> *)rows {
    ApolloSettingsSection *section = [self new];
    section.title = title;
    section.footer = footer;
    section.rows = rows;
    return section;
}

- (BOOL)isVisible {
    return self.visible ? self.visible() : YES;
}

@end

#pragma mark - Icon tiles

// Settings-app-style icon tile: a white SF symbol centered on a colored 29pt
// rounded square. Cached per symbol + resolved color; the color is resolved
// against the presenting view's traits because system colors differ slightly
// between light and dark. Unknown symbol names fail soft to a plain tile.
UIColor *ApolloThemeManagerIconColor(void) {
    return UIColor.systemIndigoColor;
}

UIImage *ApolloSettingsIconTileImage(NSString *symbolName, UIColor *tileColor, UITraitCollection *traits) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });

    UIColor *resolved = [(tileColor ?: UIColor.systemGrayColor) resolvedColorWithTraitCollection:traits];
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0.5;
        [resolved getWhite:&w alpha:&a];
        r = g = b = w;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%.3f|%.3f|%.3f|%.3f", symbolName, r, g, b, a];
    UIImage *cached = [cache objectForKey:key];
    if (cached) return cached;

    static const CGFloat side = 29.0;
    UIImage *glyph = [[UIImage systemImageNamed:symbolName
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15
                                                                                                weight:UIImageSymbolWeightMedium]]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *tile = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [resolved setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side) cornerRadius:6.5] fill];
        if ([symbolName isEqualToString:@"apollo.saved-categories"]) {
            CGContextSaveGState(ctx.CGContext);
            CGContextScaleCTM(ctx.CGContext, side / 36.0, side / 36.0);
        // Two outlined bookmarks, matching the Saved Categories shortcut.
        [UIColor.whiteColor setStroke];
        UIBezierPath *rear = [UIBezierPath bezierPath];
        [rear moveToPoint:CGPointMake(16, 9)];
        [rear addLineToPoint:CGPointMake(16, 7)];
        [rear addLineToPoint:CGPointMake(27, 7)];
        [rear addLineToPoint:CGPointMake(27, 25)];
        rear.lineWidth = 1.8;
        rear.lineJoinStyle = kCGLineJoinRound;
        rear.lineCapStyle = kCGLineCapRound;
        [rear stroke];
        UIBezierPath *front = [UIBezierPath bezierPath];
        [front moveToPoint:CGPointMake(10, 11)];
        [front addLineToPoint:CGPointMake(21, 11)];
        [front addLineToPoint:CGPointMake(21, 29)];
        [front addLineToPoint:CGPointMake(15.5, 24)];
        [front addLineToPoint:CGPointMake(10, 29)];
        [front closePath];
        front.lineWidth = 1.8;
        front.lineJoinStyle = kCGLineJoinRound;
        [front stroke];
            CGContextRestoreGState(ctx.CGContext);
            return;
        }
        CGSize gs = glyph.size;
        if (gs.width > 0 && gs.height > 0) {
            // Symbols vary in aspect ratio; cap the longer side so wide glyphs
            // (person.3.fill) don't touch the tile edges.
            CGFloat scale = MIN(1.0, MIN(19.0 / gs.width, 19.0 / gs.height));
            gs = CGSizeMake(gs.width * scale, gs.height * scale);
            [glyph drawInRect:CGRectMake((side - gs.width) / 2.0, (side - gs.height) / 2.0, gs.width, gs.height)];
        }
    }];
    tile = [tile imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    [cache setObject:tile forKey:key];
    return tile;
}

#pragma mark - Form view controller

// Associates the model row with its live UISwitch so one shared valueChanged
// target can dispatch to the row's block across cell reuse.
static const void *kApolloSFSwitchRowKey = &kApolloSFSwitchRowKey;

@implementation ApolloSettingsFormViewController {
    NSArray<ApolloSettingsSection *> *_sections;
    // The visibility snapshot the dataSource serves. Rebuilt only in
    // -rebuildForm and -visibilityDidChange, never during enumeration — the
    // table's counts and our answers must agree for the whole layout pass.
    NSArray<ApolloSettingsSection *> *_visibleSections;
    NSArray<NSArray<ApolloSettingsRow *> *> *_visibleRows;
    // A footer-height check is already queued for the next runloop turn
    // (see -tableView:willDisplayFooterView:forSection:).
    BOOL _footerHeightCheckPending;
    // The height each plain-string footer's own view asked for, keyed by
    // "table geometry|footer text" and served from
    // -tableView:heightForFooterInSection:. See "section footer heights".
    NSMutableDictionary<NSString *, NSNumber *> *_footerMeasuredHeights;
    // How often each footer's measurement has changed, keyed by
    // "label point size|geometry|text" — the bound on the adopting pass.
    NSMutableDictionary<NSString *, NSNumber *> *_footerMeasureChanges;
    // A check is parked on the running navigation transition's completion.
    BOOL _footerHeightCheckDeferred;
    NSString *_lastSectionGeometry;
    BOOL _sectionGeometryNeedsUpdate;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    return @[];   // subclass responsibility
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Let standard cells grow for Dynamic Type and long localized labels.
    // Returning UITableViewAutomaticDimension from the delegate below keeps
    // explicit row.height blocks authoritative while avoiding 44pt clipping.
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52.0;
    [self rebuildForm];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UITableView *table = self.tableView;
    // Duo can change column width by moving the safe area while the table's
    // bounds stay full-screen. Cached row/footer heights must follow both.
    NSString *geometry = [self apollo_sf_footerHeightKeyForText:@"" inTableView:table];
    if (!geometry || [geometry isEqualToString:_lastSectionGeometry]) return;
    _sectionGeometryNeedsUpdate = _lastSectionGeometry != nil;
    _lastSectionGeometry = geometry;
    [self apollo_sf_scheduleFooterHeightCheck];
}

- (void)refreshFormAfterRowMove {
    _sections = [self buildForm] ?: @[];
    _visibleSections = [self computeVisibleSections];
    _visibleRows = [self computeVisibleRowsForSections:_visibleSections];
}

- (void)rebuildForm {
    // Measured footer heights stay (they are keyed by text and width, so the
    // reload below gets them straight away); only the change budget restarts.
    [_footerMeasureChanges removeAllObjects];
    _sections = [self buildForm] ?: @[];
    _visibleSections = [self computeVisibleSections];
    _visibleRows = [self computeVisibleRowsForSections:_visibleSections];
    [self.tableView reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // Icon tiles bake a trait-resolved fill color at render time (see
    // ApolloSettingsIconTileImage). apollo_applyTheme restyles visible cells in
    // place but does not re-run cellForRow, so on a light<->dark flip the tiles
    // would keep the previous appearance's resolved color until reuse. Reload
    // to re-render them for the new appearance.
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [self.tableView reloadData];
    }
    // Footer heights were measured at the previous text size.
    if (previousTraitCollection &&
        ![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [_footerMeasuredHeights removeAllObjects];
        [_footerMeasureChanges removeAllObjects];
    }
}

- (NSArray<ApolloSettingsSection *> *)computeVisibleSections {
    NSMutableArray *visible = [NSMutableArray arrayWithCapacity:_sections.count];
    for (ApolloSettingsSection *section in _sections) {
        if (section.isVisible) [visible addObject:section];
    }
    return visible;
}

- (NSArray<NSArray<ApolloSettingsRow *> *> *)computeVisibleRowsForSections:(NSArray<ApolloSettingsSection *> *)sections {
    NSMutableArray *all = [NSMutableArray arrayWithCapacity:sections.count];
    for (ApolloSettingsSection *section in sections) {
        NSMutableArray *visible = [NSMutableArray arrayWithCapacity:section.rows.count];
        for (ApolloSettingsRow *row in section.rows) {
            if (row.isVisible) [visible addObject:row];
        }
        [all addObject:visible];
    }
    return all;
}

// Buckets index paths by their row's showHideAnimation so each row animates as
// documented even when several rows with different animations flip in one pass
// (review finding: a single last-write-wins animation broke the per-row contract).
static void ApolloSFAddPath(NSMutableDictionary<NSNumber *, NSMutableArray<NSIndexPath *> *> *buckets,
                            UITableViewRowAnimation animation, NSIndexPath *path) {
    NSMutableArray *list = buckets[@(animation)];
    if (!list) {
        list = [NSMutableArray array];
        buckets[@(animation)] = list;
    }
    [list addObject:path];
}

- (void)visibilityDidChange {
    if (!_visibleSections || !_visibleRows) return;
    NSArray<ApolloSettingsSection *> *oldSections = _visibleSections;
    NSArray<NSArray<ApolloSettingsRow *> *> *oldRowsBySection = _visibleRows;
    NSArray<ApolloSettingsSection *> *newSections = [self computeVisibleSections];
    NSArray<NSArray<ApolloSettingsRow *> *> *newRowsBySection =
        [self computeVisibleRowsForSections:newSections];

    NSMutableDictionary<NSNumber *, NSMutableArray<NSIndexPath *> *> *deletes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSIndexPath *> *> *inserts = [NSMutableDictionary dictionary];
    NSMutableIndexSet *deletedSections = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *insertedSections = [NSMutableIndexSet indexSet];
    for (NSUInteger s = 0; s < oldSections.count; s++) {
        if (![newSections containsObject:oldSections[s]]) [deletedSections addIndex:s];
    }
    for (NSUInteger s = 0; s < newSections.count; s++) {
        if (![oldSections containsObject:newSections[s]]) [insertedSections addIndex:s];
    }

    // Row deletions use the section's old index while insertions use its new
    // index, matching UITableView's batch-update coordinate spaces when a
    // conditional section elsewhere is inserted or removed at the same time.
    for (NSUInteger newSectionIndex = 0; newSectionIndex < newSections.count; newSectionIndex++) {
        ApolloSettingsSection *section = newSections[newSectionIndex];
        NSUInteger oldSectionIndex = [oldSections indexOfObjectIdenticalTo:section];
        if (oldSectionIndex == NSNotFound) continue;
        NSArray<ApolloSettingsRow *> *oldRows = oldRowsBySection[oldSectionIndex];
        NSArray<ApolloSettingsRow *> *newRows = newRowsBySection[newSectionIndex];
        for (NSUInteger r = 0; r < oldRows.count; r++) {
            if (![newRows containsObject:oldRows[r]]) {
                ApolloSFAddPath(deletes, oldRows[r].showHideAnimation,
                                [NSIndexPath indexPathForRow:(NSInteger)r
                                                 inSection:(NSInteger)oldSectionIndex]);
            }
        }
        for (NSUInteger r = 0; r < newRows.count; r++) {
            if (![oldRows containsObject:newRows[r]]) {
                ApolloSFAddPath(inserts, newRows[r].showHideAnimation,
                                [NSIndexPath indexPathForRow:(NSInteger)r
                                                 inSection:(NSInteger)newSectionIndex]);
            }
        }
    }

    _visibleSections = newSections;
    _visibleRows = newRowsBySection;
    if (deletes.count == 0 && inserts.count == 0 &&
        deletedSections.count == 0 && insertedSections.count == 0) return;
    [self.tableView beginUpdates];
    if (deletedSections.count > 0) {
        [self.tableView deleteSections:deletedSections withRowAnimation:UITableViewRowAnimationFade];
    }
    if (insertedSections.count > 0) {
        [self.tableView insertSections:insertedSections withRowAnimation:UITableViewRowAnimationFade];
    }
    for (NSNumber *animation in deletes) {
        [self.tableView deleteRowsAtIndexPaths:deletes[animation]
                              withRowAnimation:(UITableViewRowAnimation)animation.integerValue];
    }
    for (NSNumber *animation in inserts) {
        [self.tableView insertRowsAtIndexPaths:inserts[animation]
                              withRowAnimation:(UITableViewRowAnimation)animation.integerValue];
    }
    [self.tableView endUpdates];
}

// Rebuild the model (re-runs -buildForm) but reload ONLY the section containing
// rowID — for dynamic sections whose row lists are generated inside buildForm,
// where a full reloadData would disturb unrelated sections' cells (e.g. tear
// down an active text-field first responder; review finding on the Translation
// skip-language list). The section layout itself must be stable across rebuilds
// (it is: buildForm returns a fixed section list). CAUTION: this refreshes the
// visibility snapshot for EVERY section while reloading just one — only call it
// when no OTHER section's .visible answers changed since the last snapshot, or
// the table's counts desync and the next batch update throws. If other sections
// may have changed, use -rebuildForm or follow with -visibilityDidChange.
// Falls back to a full reload when the row ID isn't found in the rebuilt model.
- (void)rebuildSectionContainingRowID:(NSString *)rowID withRowAnimation:(UITableViewRowAnimation)animation {
    _sections = [self buildForm] ?: @[];
    _visibleSections = [self computeVisibleSections];
    _visibleRows = [self computeVisibleRowsForSections:_visibleSections];
    for (ApolloSettingsSection *section in _sections) {
        for (ApolloSettingsRow *row in section.rows) {
            if ([row.rowID isEqualToString:rowID]) {
                NSUInteger visibleIndex = [_visibleSections indexOfObjectIdenticalTo:section];
                if (visibleIndex == NSNotFound) break;
                [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:visibleIndex]
                              withRowAnimation:animation];
                return;
            }
        }
    }
    [self.tableView reloadData];
}

- (void)noteRowMovedFromIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
    if (!_visibleRows || !_visibleSections) return;
    if (fromIndexPath.section != toIndexPath.section) return;
    NSUInteger s = (NSUInteger)fromIndexPath.section;
    if (s >= _visibleRows.count || s >= _visibleSections.count) return;
    NSMutableArray<ApolloSettingsRow *> *visible = [_visibleRows[s] mutableCopy];
    NSUInteger from = (NSUInteger)fromIndexPath.row, to = (NSUInteger)toIndexPath.row;
    if (from >= visible.count || to >= visible.count || from == to) return;
    ApolloSettingsRow *moved = visible[from];
    [visible removeObjectAtIndex:from];
    [visible insertObject:moved atIndex:to];
    NSMutableArray *rowsBySection = [_visibleRows mutableCopy];
    rowsBySection[s] = [visible copy];
    _visibleRows = [rowsBySection copy];
    // The section's full row list (hidden rows included) follows: the moved
    // row goes right before the row that now follows it on screen, or last.
    ApolloSettingsSection *section = _visibleSections[s];
    NSMutableArray<ApolloSettingsRow *> *all = [section.rows mutableCopy];
    [all removeObjectIdenticalTo:moved];
    ApolloSettingsRow *next = to + 1 < visible.count ? visible[to + 1] : nil;
    NSUInteger insertAt = next ? [all indexOfObjectIdenticalTo:next] : NSNotFound;
    if (insertAt == NSNotFound) insertAt = all.count;
    [all insertObject:moved atIndex:insertAt];
    section.rows = all;
}

#pragma mark identity lookups

- (ApolloSettingsRow *)rowWithID:(NSString *)rowID {
    for (ApolloSettingsSection *section in _sections) {
        for (ApolloSettingsRow *row in section.rows) {
            if ([row.rowID isEqualToString:rowID]) return row;
        }
    }
    return nil;
}

- (NSIndexPath *)indexPathForRowID:(NSString *)rowID {
    for (NSUInteger s = 0; s < _visibleRows.count; s++) {
        NSArray<ApolloSettingsRow *> *rows = _visibleRows[s];
        for (NSUInteger r = 0; r < rows.count; r++) {
            if ([rows[r].rowID isEqualToString:rowID]) {
                return [NSIndexPath indexPathForRow:(NSInteger)r inSection:(NSInteger)s];
            }
        }
    }
    return nil;
}

- (void)reloadRowWithID:(NSString *)rowID {
    NSIndexPath *indexPath = [self indexPathForRowID:rowID];
    if (!indexPath) return;
    // UITableViewRowAnimationNone only suppresses the EXPLICIT animation: the
    // reload still swaps in a replacement cell whose frame settles on the next
    // layout pass, and when that pass runs inside an animated context — e.g.
    // viewWillAppear during a nav-pop transition — the settle is captured and
    // the cell visibly slides in from the table's top. Suppress implicit
    // animations AND complete the layout inside the suppression block so
    // nothing is left for an enclosing transition to animate.
    [UIView performWithoutAnimation:^{
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView layoutIfNeeded];
    }];
}

- (UITableViewCell *)cellForRowID:(NSString *)rowID {
    NSIndexPath *indexPath = [self indexPathForRowID:rowID];
    return indexPath ? [self.tableView cellForRowAtIndexPath:indexPath] : nil;
}

- (ApolloSettingsRow *)rowAtIndexPath:(NSIndexPath *)indexPath {
    return [self apollo_sf_rowAtIndexPath:indexPath];
}

- (ApolloSettingsRow *)apollo_sf_rowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < 0 || (NSUInteger)indexPath.section >= _visibleRows.count) return nil;
    NSArray<ApolloSettingsRow *> *rows = _visibleRows[(NSUInteger)indexPath.section];
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

#pragma mark dataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)_visibleRows.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || (NSUInteger)section >= _visibleRows.count) return 0;
    return (NSInteger)_visibleRows[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ((NSUInteger)section >= _visibleSections.count) return nil;
    return _visibleSections[(NSUInteger)section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ((NSUInteger)section >= _visibleSections.count) return nil;
    ApolloSettingsSection *model = _visibleSections[(NSUInteger)section];
    return model.footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloSettingsRow *row = [self apollo_sf_rowAtIndexPath:indexPath];
    if (!row) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

    UITableViewCell *cell = nil;
    switch (row.kind) {
        case ApolloSFRowKindSwitch: {
            static NSString *const reuseID = @"ApolloSFSwitch";
            cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
            UISwitch *toggle = (UISwitch *)cell.accessoryView;
            if (!cell || ![toggle isKindOfClass:[UISwitch class]]) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                toggle = [[UISwitch alloc] init];
                [toggle addTarget:self action:@selector(apollo_sf_switchToggled:)
                 forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
            }
            cell.textLabel.text = row.title;
            cell.textLabel.numberOfLines = 0;
            toggle.on = row.isOn ? row.isOn() : NO;
            BOOL enabled = row.enabled ? row.enabled() : YES;
            toggle.enabled = enabled;
            toggle.accessibilityLabel = row.title;
            cell.textLabel.enabled = enabled;
            objc_setAssociatedObject(toggle, kApolloSFSwitchRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            break;
        }
        case ApolloSFRowKindValue:
        case ApolloSFRowKindDisclosure: {
            // A disclosure row may carry its detail as a subtitle under the
            // title (wraps, never truncates) rather than as a trailing value;
            // that variant gets its own reuse pool since the cell style differs.
            BOOL subtitle = row.kind == ApolloSFRowKindDisclosure && row.detailAsSubtitle;
            NSString *reuseID = subtitle ? @"ApolloSFDisclosureSubtitle" : @"ApolloSFValue";
            cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:subtitle ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1
                                                  reuseIdentifier:reuseID];
            BOOL enabled = row.enabled ? row.enabled() : YES;
            cell.textLabel.text = row.title;
            cell.textLabel.numberOfLines = 0;
            cell.textLabel.enabled = enabled;
            cell.detailTextLabel.text = row.detail ? row.detail() : nil;
            cell.detailTextLabel.numberOfLines = subtitle ? 0 : 1;
            cell.detailTextLabel.textColor = enabled
                ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
            cell.accessoryType = (enabled && row.kind == ApolloSFRowKindDisclosure)
                ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
            cell.selectionStyle = (enabled && row.isSelectable)
                ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
            break;
        }
        case ApolloSFRowKindButton: {
            static NSString *const reuseID = @"ApolloSFButton";
            cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
            cell.textLabel.text = row.title;
            cell.textLabel.numberOfLines = 0;
            // Shared pool: reset what a sibling's configure block may have added
            // (e.g. Translation's "Add Language…" disclosure chevron).
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            [self apollo_applyAccentActionTextColorToCell:cell];
            break;
        }
        case ApolloSFRowKindCustom: {
            cell = row.cellBlock(tableView, row);
            break;
        }
    }
    // Icon tile (see header): reset for icon-less built-in rows because their
    // reuse pools are shared; leave custom rows' imageView alone unless opted in.
    if (row.iconSystemName) {
        cell.imageView.image = ApolloSettingsIconTileImage(row.iconSystemName, row.iconTileColor, self.traitCollection);
    } else if (row.kind != ApolloSFRowKindCustom) {
        cell.imageView.image = nil;
    }
    if (row.kind != ApolloSFRowKindButton && row.kind != ApolloSFRowKindCustom) {
        [self apollo_applyPrimaryTextColorToCell:cell];
    }
    if (row.configure) row.configure(cell);
    ApolloSettingsApplyCellTypography(cell);
    return cell;
}

- (void)apollo_sf_switchToggled:(UISwitch *)sender {
    ApolloSettingsRow *row = objc_getAssociatedObject(sender, kApolloSFSwitchRowKey);
    if (row.onToggle) row.onToggle(sender);
}

#pragma mark delegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloSettingsRow *row = [self apollo_sf_rowAtIndexPath:indexPath];
    return row.isSelectable && (!row.enabled || row.enabled());
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloSettingsRow *row = [self apollo_sf_rowAtIndexPath:indexPath];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!row) return;
    if (row.enabled && !row.enabled()) return;
    if (row.kind == ApolloSFRowKindDisclosure && row.push) {
        UIViewController *destination = row.push();
        if (destination) [self.navigationController pushViewController:destination animated:YES];
        return;
    }
    if (row.onSelect) row.onSelect();
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloSettingsRow *row = [self apollo_sf_rowAtIndexPath:indexPath];
    return row.height ? row.height() : tableView.rowHeight;
}

#pragma mark section footer heights

// The form owns the height of its plain-string section footers, because
// UITableView's own number for them cannot be trusted:
//
//  - A footer that is off screen is sized by UIKit from the title alone, on a
//    private sizing view with UIKit's default footer font. That under-measures
//    long multi-paragraph text (the Apollo AI Summaries footer on iOS 26: 254pt
//    where the real view's sizeThatFits: says 258.7), and it is far off as soon
//    as anything gives the real label another font (62pt for a footer whose
//    view needs 96pt, measured with a settings-wide text-size pass that
//    re-fonts footers in willDisplayFooterView:).
//  - UITableViewHeaderFooterView anchors its label to the BOTTOM of the view,
//    so a footer that is sized short does not clip: its text rides UP, over the
//    rows of the section above it.
//  - An empty beginUpdates/endUpdates pass re-measures the footers that are ON
//    screen from their real views, and puts every footer that is OFF screen
//    back on the title estimate. So a pass alone can never settle a table
//    taller than the screen: healing the footers at the bottom un-heals the
//    ones at the top, which then come back short when the user scrolls up.
//
// So: once a footer's view has been displayed, take the height that view asks
// for (on the next runloop turn — by then the label has its final font),
// remember it by table geometry and text, and answer heightForFooterInSection:
// with it from then on. Whatever the table rebuilds later, that footer keeps
// the measured height whether it is on screen or not, and one updates pass is
// enough for the table to adopt a new measurement. A footer that has not been
// displayed yet still gets UIKit's estimate (UITableViewAutomaticDimension);
// it is measured as it scrolls in, which for a first visit is from the bottom
// edge, below the rows it could otherwise cover.
//
// Subclasses that override heightForFooterInSection: call super for their
// plain-string footers.
- (CGFloat)apollo_sf_fittedHeightForFooterView:(UIView *)view inTableView:(UITableView *)tableView {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return 0.0;
    if (((UITableViewHeaderFooterView *)view).textLabel.text.length == 0) return 0.0;
    CGFloat width = CGRectGetWidth(view.bounds);
    if (width <= 0.0) return 0.0;
    return [view sizeThatFits:CGSizeMake(width, 0.0)].height;
}

- (NSString *)apollo_sf_footerHeightKeyForText:(NSString *)text inTableView:(UITableView *)tableView {
    CGFloat width = CGRectGetWidth(tableView.bounds);
    if (width <= 0.0) return nil;
    UIEdgeInsets safe = tableView.safeAreaInsets;
    UIEdgeInsets margins = tableView.layoutMargins;
    return [NSString stringWithFormat:@"%.1f|%.1f|%.1f|%.1f|%.1f|%@",
            width, safe.left, safe.right, margins.left, margins.right, text];
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    NSString *text = [self tableView:tableView titleForFooterInSection:section];
    // No footer text: answer what the table would have used had this method
    // not existed (a subclass may have set a fixed sectionFooterHeight).
    if (text.length == 0) return tableView.sectionFooterHeight;
    NSString *key = [self apollo_sf_footerHeightKeyForText:text inTableView:tableView];
    NSNumber *measured = key ? _footerMeasuredHeights[key] : nil;
    return measured ? (CGFloat)measured.doubleValue : UITableViewAutomaticDimension;
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    [super tableView:tableView willDisplayFooterView:view forSection:section];
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    [self apollo_sf_scheduleFooterHeightCheck];
}

- (void)apollo_sf_scheduleFooterHeightCheck {
    if (_footerHeightCheckPending) return;
    _footerHeightCheckPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_footerHeightCheckPending = NO;
        [strongSelf apollo_sf_adoptMeasuredFooterHeights];
    });
}

// The adopting pass runs ONLY when a footer's measurement is new or changed,
// never merely because the table and a footer's view disagree: endUpdates puts
// the footers on screen again, which calls willDisplayFooterView: again, so a
// pass keyed on disagreement re-runs on every runloop turn for as long as the
// two cannot be reconciled (2,293 passes in ~10s in a device log), and an
// updates pass per frame stalls a scroll. A measurement that keeps changing is
// capped per label font, so a label whose font flips cannot drive a loop either.
static const NSUInteger kApolloSFMaxFooterMeasureChanges = 4;

- (void)apollo_sf_adoptMeasuredFooterHeights {
    UITableView *tableView = self.tableView;
    if (!tableView.window) return;

    // Not inside a navigation transition: an updates pass run while the
    // transition's animations are open gets its settle captured, so the rows
    // visibly slide into place as the screen comes back. Look again once the
    // transition is over.
    // Footers keep appearing while the transition runs, so park one check,
    // not one per appearance. The completion also fires for a cancelled
    // interactive pop; the screen that stays then simply gets its check late.
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (coordinator) {
        if (_footerHeightCheckDeferred) return;
        __weak typeof(self) weakSelf = self;
        BOOL queued = [coordinator animateAlongsideTransition:nil
                                                   completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_footerHeightCheckDeferred = NO;
            [strongSelf apollo_sf_scheduleFooterHeightCheck];
        }];
        if (queued) {
            _footerHeightCheckDeferred = YES;
            return;
        }
    }

    NSInteger sections = MIN(tableView.numberOfSections, (NSInteger)_visibleSections.count);
    BOOL needsPass = _sectionGeometryNeedsUpdate;
    _sectionGeometryNeedsUpdate = NO;
    for (NSInteger section = 0; section < sections; section++) {
        UITableViewHeaderFooterView *footer = [tableView footerViewForSection:section];
        CGFloat fitted = [self apollo_sf_fittedHeightForFooterView:footer inTableView:tableView];
        if (fitted <= 0.0) continue;
        NSString *key = [self apollo_sf_footerHeightKeyForText:footer.textLabel.text inTableView:tableView];
        if (!key) continue;
        NSNumber *known = _footerMeasuredHeights[key];
        if (known && fabs(known.doubleValue - fitted) < 0.5) continue;

        NSString *budgetKey = [NSString stringWithFormat:@"%.1f|%@", footer.textLabel.font.pointSize, key];
        NSUInteger changes = _footerMeasureChanges[budgetKey].unsignedIntegerValue;
        if (changes >= kApolloSFMaxFooterMeasureChanges) {
            if (changes == kApolloSFMaxFooterMeasureChanges) {
                if (!_footerMeasureChanges) _footerMeasureChanges = [NSMutableDictionary dictionary];
                _footerMeasureChanges[budgetKey] = @(changes + 1);
                ApolloLog(@"[SettingsForm] footer %ld keeps changing its fitted height (%.1fpt, now %.1fpt) — leaving it at %.1fpt",
                          (long)section, known.doubleValue, fitted, known.doubleValue);
            }
            continue;
        }
        if (!_footerMeasuredHeights) _footerMeasuredHeights = [NSMutableDictionary dictionary];
        if (!_footerMeasureChanges) _footerMeasureChanges = [NSMutableDictionary dictionary];
        _footerMeasuredHeights[key] = @(fitted);
        _footerMeasureChanges[budgetKey] = @(changes + 1);

        CGFloat height = CGRectGetHeight(footer.bounds);
        if (fabs(fitted - height) < 0.5) continue;
        needsPass = YES;
        ApolloLog(@"[SettingsForm] footer %ld is %.1fpt tall but its view fits %.1fpt — adopting the measured height",
                  (long)section, height, fitted);
    }
    if (!needsPass) return;
    // Adopting footer measurements must not move the reader. UITableView may
    // compensate its offset when estimates below the viewport become exact,
    // which otherwise makes a newly pushed settings page snap upward.
    __block CGPoint offset = tableView.contentOffset;
    CGFloat distanceFromTop = offset.y + tableView.adjustedContentInset.top;
    [UIView performWithoutAnimation:^{
        [tableView beginUpdates];
        [tableView endUpdates];
        [tableView layoutIfNeeded];
        if (!tableView.dragging && !tableView.decelerating) {
            CGFloat minimum = -tableView.adjustedContentInset.top;
            CGFloat maximum = MAX(minimum, tableView.contentSize.height - tableView.bounds.size.height + tableView.adjustedContentInset.bottom);
            offset.y = MIN(maximum, MAX(minimum, distanceFromTop + minimum));
            [tableView setContentOffset:offset animated:NO];
        }
    }];
}

@end

#pragma mark - Shared picker

void ApolloSettingsPresentPicker(UIViewController *presenter,
                                 UIView *sourceView,
                                 NSString *title,
                                 NSArray<NSString *> *optionTitles,
                                 NSInteger currentIndex,
                                 void (^apply)(NSInteger pickedIndex)) {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)optionTitles.count; i++) {
        NSString *optionTitle = (i == currentIndex)
            ? [optionTitles[(NSUInteger)i] stringByAppendingString:@" (Current)"]
            : optionTitles[(NSUInteger)i];
        [sheet addAction:[UIAlertAction actionWithTitle:optionTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            // Fires even when the current option is re-picked: every legacy sheet
            // did (their handlers re-write + re-notify, and some rely on it — e.g.
            // re-picking the current provider still marks it user-selected), so
            // apply blocks must be idempotent.
            if (apply) apply(i);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    // Anchor to the screen, not a reusable cell: row reloads can recycle the
    // source cell for a different row while the picker is still open.
    UIView *anchor = presenter.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = sourceView ? [sourceView convertRect:sourceView.bounds toView:anchor]
        : CGRectMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds), 1, 1);
    [presenter presentViewController:sheet animated:YES completion:nil];
}
