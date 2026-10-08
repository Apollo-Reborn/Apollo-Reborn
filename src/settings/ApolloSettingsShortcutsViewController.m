#import "ApolloSettingsShortcutsViewController.h"
#import "ApolloSettingsRouter.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

NSArray<NSString *> *ApolloSettingsShortcutCatalog(void) {
    // Fixed discovery order mirrors Settings and the Reborn hub. Included
    // shortcuts use their separately persisted user order instead.
    return @[@"reborn", @"accounts-api-keys", @"posts-feeds", @"comments", @"media",
        @"subreddits", @"user-profiles", @"interface", @"rich-link-previews", @"apollo-ai",
        @"theme-manager", @"open-in-app", @"picture-in-picture", @"translation", @"saved-categories", @"tag-filters",
        @"automatic-backups", @"crash-reports", @"feature-requests", @"bug-reports",
        @"buy-coffee", @"general", @"pixel-pals", @"appearance", @"app-icon", @"filters", @"gestures"];
}

NSArray<NSString *> *ApolloSettingsShortcutIDs(void) {
    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeySettingsTabShortcuts];
    if (![saved isKindOfClass:NSArray.class]) {
        return @[@"theme-manager", @"automatic-backups", @"feature-requests", @"bug-reports", @"buy-coffee"];
    }
    NSMutableArray *valid = [NSMutableArray array];
    for (id entry in saved) {
        id identifier = [entry isEqual:@"inline-media"] ? @"media" : entry;
        if ([identifier isEqual:@"profile-layout"]) identifier = @"user-profiles";
        if ([identifier isKindOfClass:NSString.class] && [ApolloSettingsShortcutCatalog() containsObject:identifier]
            && valid.count < ApolloSettingsShortcutLimit && ![valid containsObject:identifier]) [valid addObject:identifier];
    }
    return valid;
}

NSString *ApolloSettingsShortcutTitle(NSString *identifier) {
    if ([identifier isEqualToString:@"feature-requests"]) return @"Feature Requests";
    if ([identifier isEqualToString:@"bug-reports"]) return @"Bug Reports";
    if ([identifier isEqualToString:@"automatic-backups"]) return @"Backup Settings";
    NSDictionary *nativeTitles = @{@"buy-coffee": @"Buy Us a Coffee", @"appearance": @"Appearance",
        @"app-icon": @"App Icon", @"gestures": @"Gestures", @"filters": @"Filters & Blocks",
        @"pixel-pals": @"Pixel Pals", @"general": @"General"};
    return nativeTitles[identifier] ?: ApolloSettingsRouteTitle(identifier);
}

UIImage *ApolloSettingsShortcutImage(NSString *identifier, UITraitCollection *traits, CGFloat size) {
    __block UIImage *image;
    [traits performAsCurrentTraitCollection:^{
        if ([@[@"reborn", @"buy-coffee", @"appearance", @"app-icon", @"gestures", @"filters", @"pixel-pals", @"general"] containsObject:identifier]) {
            UIImage *native = ApolloSettingsNativeShortcutImage(ApolloSettingsShortcutTitle(identifier));
            if (native) image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)] imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [native drawInRect:CGRectMake(0, 0, size, size)];
            }];
        } else if ([identifier isEqualToString:@"feature-requests"] || [identifier isEqualToString:@"bug-reports"]) {
            BOOL requests = [identifier isEqualToString:@"feature-requests"];
            image = ApolloEmojiSettingsIcon(requests ? @"💡" : @"🐛", requests ? UIColor.systemYellowColor : UIColor.systemRedColor, size);
        } else {
            NSDictionary *symbols = @{@"theme-manager": @"paintbrush.fill", @"saved-categories": @"apollo.saved-categories",
                @"automatic-backups": @"square.and.arrow.up.fill", @"tag-filters": @"tag.fill", @"translation": @"character.bubble.fill",
                @"picture-in-picture": @"pip.fill", @"apollo-ai": @"sparkles", @"open-in-app": @"arrow.up.forward.app.fill",
                @"media": @"play.rectangle.fill", @"posts-feeds": @"newspaper.fill", @"comments": @"text.bubble.fill",
                @"subreddits": @"person.3.fill", @"user-profiles": @"person.crop.circle.fill", @"interface": @"slider.horizontal.3", @"accounts-api-keys": @"key.fill", @"rich-link-previews": @"link", @"crash-reports": @"bandage"};
            UIColor *color = UIColor.systemBlueColor;
            if ([identifier isEqualToString:@"theme-manager"]) color = ApolloThemeManagerIconColor();
            else if ([identifier isEqualToString:@"saved-categories"]) color = UIColor.systemGreenColor;
            else if ([identifier isEqualToString:@"picture-in-picture"]) color = UIColor.systemPurpleColor;
            else if ([identifier isEqualToString:@"translation"]) color = UIColor.systemTealColor;
            else if ([identifier isEqualToString:@"apollo-ai"]) color = UIColor.systemIndigoColor;
            else if ([identifier isEqualToString:@"media"]) color = UIColor.systemPinkColor;
            else if ([identifier isEqualToString:@"posts-feeds"]) color = UIColor.systemOrangeColor;
            else if ([identifier isEqualToString:@"comments"]) color = UIColor.systemGreenColor;
            else if ([identifier isEqualToString:@"subreddits"]) color = UIColor.systemRedColor;
            else if ([identifier isEqualToString:@"user-profiles"]) color = UIColor.systemTealColor;
            else if ([identifier isEqualToString:@"interface"]) color = UIColor.systemPurpleColor;
            else if ([identifier isEqualToString:@"accounts-api-keys"]) color = UIColor.systemGrayColor;
            else if ([identifier isEqualToString:@"tag-filters"] || [identifier isEqualToString:@"crash-reports"]) color = UIColor.systemOrangeColor;
            UIImage *tile = ApolloSettingsIconTileImage(symbols[identifier], color, traits);
            image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)] imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [tile drawInRect:CGRectMake(0, 0, size, size)];
            }];
        }
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

@interface ApolloSettingsShortcutsViewController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *included;
// Section header/footer heights held across the add/remove rebuild (see
// -holdSectionTitleHeightsInTableView:nextEnabledFooterText:).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *heldTitleHeights;
@end

@implementation ApolloSettingsShortcutsViewController
- (void)viewDidLoad {
    self.included = [ApolloSettingsShortcutIDs() mutableCopy];
    [super viewDidLoad];
    self.title = @"Shortcuts";
    [self updateEditButton];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appIconChanged:)
        name:@"com.christianselig.ChangedAppIcon" object:nil];
}

- (void)appIconChanged:(NSNotification *)notification {
    // Apollo refreshes its native App Icon row from the same notification.
    // Wait one queue turn so the shortcut reads the updated native artwork.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadRowWithID:@"app-icon"];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRowWithID:@"app-icon"];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateEditButton {
    UIBarButtonItem *button;
    if (self.editing) {
        button = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]
            style:UIBarButtonItemStyleDone target:self action:@selector(toggleEditing)];
        if (@available(iOS 26.0, *)) button.style = UIBarButtonItemStyleProminent;
        button.accessibilityLabel = @"Done editing shortcuts";
        button.tintColor = UIColor.systemBlueColor;
    } else {
        button = [[UIBarButtonItem alloc] initWithTitle:@"Edit" style:UIBarButtonItemStylePlain target:self action:@selector(toggleEditing)];
    }
    // Edit inherits the theme; the completion checkmark matches Subreddits.
    self.navigationItem.rightBarButtonItem = button;
}

- (void)toggleEditing {
    [self setEditing:!self.editing animated:YES];
    [self updateEditButton];
}

- (void)save {
    [[NSUserDefaults standardUserDefaults] setObject:self.included forKey:UDKeySettingsTabShortcuts];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *includedRows = [NSMutableArray array];
    NSMutableArray *availableRows = [NSMutableArray array];
    NSMutableArray *ordered = [self.included mutableCopy];
    for (NSString *identifier in ApolloSettingsShortcutCatalog()) {
        if (![ordered containsObject:identifier]) [ordered addObject:identifier];
    }
    for (NSString *identifier in ordered) {
        ApolloSettingsRow *row = [ApolloSettingsRow valueRowWithID:identifier title:ApolloSettingsShortcutTitle(identifier) detail:nil onSelect:nil];
        row.enabled = ^BOOL { return [weakSelf.included containsObject:identifier] || weakSelf.included.count < ApolloSettingsShortcutLimit; };
        row.configure = ^(UITableViewCell *cell) {
            cell.imageView.image = ApolloSettingsShortcutImage(identifier, weakSelf.traitCollection, 29);
            BOOL included = [weakSelf.included containsObject:identifier];
            BOOL available = included || weakSelf.included.count < ApolloSettingsShortcutLimit;
            cell.showsReorderControl = included;
            // UILabel's enabled flag does not consistently dim an explicitly
            // themed textColor after reuse. Dim the entire content uniformly,
            // and reset both states each time a row is configured.
            cell.textLabel.enabled = YES;
            cell.contentView.alpha = available ? 1.0 : 0.4;
            if (available) cell.accessibilityTraits &= ~UIAccessibilityTraitNotEnabled;
            else cell.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
        };
        NSMutableArray *rows = [self.included containsObject:identifier] ? includedRows : availableRows;
        [rows addObject:row];
    }
    return @[[ApolloSettingsSection sectionWithTitle:@"Enabled Shortcuts" footer:[self enabledFooterText] rows:includedRows],
        [ApolloSettingsSection sectionWithTitle:@"Available Shortcuts" footer:@"Tap Edit to add, remove, or reorder shortcuts." rows:availableRows]];
}

- (NSString *)enabledFooterText {
    return [NSString stringWithFormat:@"%lu of %lu shortcuts enabled. Press and hold the Settings tab to open them. Changes are saved automatically.", (unsigned long)self.included.count, (unsigned long)ApolloSettingsShortcutLimit];
}

// Adding or removing a shortcut rebuilds the form with reloadData, and the
// section titles came back at other heights, so they and every row below them
// moved a few points during the animation and again after it:
//  - Headers self-size, and the settings styling sets their font in
//    willDisplayHeaderView, after UIKit has measured them: a re-dequeued
//    header that was already styled measured 55pt where the shown one was
//    69pt (Available: 59pt -> 38pt), and stayed that way.
//  - The Enabled footer's new count text had no measured height yet, so it
//    took the estimate until the form's footer check adopted it a turn later.
// Hold the heights the shown titles have now, and measure the Enabled
// footer's next text on its own view, so the rebuild lays them out unchanged.
// The key carries the width and the settings fonts, so a rotation, a text
// size or a theme font change never reads a height held for another layout.
- (NSString *)heldHeightKeyForTitle:(NSString *)title kind:(NSString *)kind inTableView:(UITableView *)tableView {
    CGFloat width = CGRectGetWidth(tableView.bounds);
    if (title.length == 0 || width <= 0.0) return nil;
    UIFont *body = ApolloSettingsFont(UIFontTextStyleBody, self.traitCollection);
    UIFont *footnote = ApolloSettingsFont(UIFontTextStyleFootnote, self.traitCollection);
    return [NSString stringWithFormat:@"%@|%.0f|%@ %.2f|%@ %.2f|%@", kind, width,
            body.fontName, body.pointSize, footnote.fontName, footnote.pointSize, title];
}

- (void)holdSectionTitleHeightsInTableView:(UITableView *)tableView nextEnabledFooterText:(NSString *)nextFooter {
    if (!self.heldTitleHeights) self.heldTitleHeights = [NSMutableDictionary dictionary];
    for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
        UITableViewHeaderFooterView *header = [tableView headerViewForSection:section];
        UITableViewHeaderFooterView *footer = [tableView footerViewForSection:section];
        NSString *headerKey = [self heldHeightKeyForTitle:[self tableView:tableView titleForHeaderInSection:section] kind:@"h" inTableView:tableView];
        NSString *footerKey = [self heldHeightKeyForTitle:[self tableView:tableView titleForFooterInSection:section] kind:@"f" inTableView:tableView];
        // A header keeps the first height it was shown at; the ones UIKit
        // measures after a reload are the ones that drift.
        if (headerKey && !self.heldTitleHeights[headerKey] && CGRectGetHeight(header.bounds) > 0.0) {
            self.heldTitleHeights[headerKey] = @(CGRectGetHeight(header.bounds));
        }
        if (footerKey && CGRectGetHeight(footer.bounds) > 0.0) self.heldTitleHeights[footerKey] = @(CGRectGetHeight(footer.bounds));
    }
    // The Enabled footer's count changes with this edit. Measure the new text
    // on the footer view the table built and styled for the old one (same
    // font, width and insets; UIKit's own title footer, as the form's footer
    // check requires), then put its text back within this runloop turn.
    UITableViewHeaderFooterView *footer = [tableView footerViewForSection:0];
    UILabel *label = footer.textLabel;
    NSString *ownText = label.text;
    NSString *nextKey = [self heldHeightKeyForTitle:nextFooter kind:@"f" inTableView:tableView];
    if (!nextKey || ![ownText isEqualToString:[self tableView:tableView titleForFooterInSection:0]]) return;
    label.text = nextFooter;
    [footer setNeedsLayout];
    CGFloat fitted = [footer sizeThatFits:CGSizeMake(CGRectGetWidth(tableView.bounds), 0.0)].height;
    label.text = ownText;
    [footer setNeedsLayout];
    [footer layoutIfNeeded];
    if (fitted > 0.0) self.heldTitleHeights[nextKey] = @(fitted);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *key = [self heldHeightKeyForTitle:[self tableView:tableView titleForHeaderInSection:section] kind:@"h" inTableView:tableView];
    NSNumber *held = key ? self.heldTitleHeights[key] : nil;
    // Not held: what the table uses when no delegate answers.
    return held ? (CGFloat)held.doubleValue : tableView.sectionHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    NSString *key = [self heldHeightKeyForTitle:[self tableView:tableView titleForFooterInSection:section] kind:@"f" inTableView:tableView];
    NSNumber *held = key ? self.heldTitleHeights[key] : nil;
    return held ? (CGFloat)held.doubleValue : [super tableView:tableView heightForFooterInSection:section];
}

// The settings base re-measures every title after a theme font change; let it.
- (void)apollo_takeSectionTitleHeights {
    [self.heldTitleHeights removeAllObjects];
    [super apollo_takeSectionTitleHeights];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = [self rowAtIndexPath:indexPath].rowID;
    return identifier && ([self.included containsObject:identifier] || self.included.count < ApolloSettingsShortcutLimit);
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self.included containsObject:[self rowAtIndexPath:indexPath].rowID] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleInsert;
}
- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"Remove";
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = [self rowAtIndexPath:indexPath].rowID;
    if (!identifier || (style == UITableViewCellEditingStyleInsert && self.included.count >= ApolloSettingsShortcutLimit)) return;
    // Capture stable row identities before rebuilding the declarative form.
    // This matches the subreddit editor's removal spring without animating a
    // native swipe container or changing the row's left edge.
    NSMutableDictionary *frames = [NSMutableDictionary dictionary];
    for (NSIndexPath *visible in tableView.indexPathsForVisibleRows) {
        NSString *rowID = [self rowAtIndexPath:visible].rowID;
        if (rowID) frames[rowID] = [NSValue valueWithCGRect:[tableView rectForRowAtIndexPath:visible]];
    }
    UITableViewCell *swipedCell = style == UITableViewCellEditingStyleDelete ? [tableView cellForRowAtIndexPath:indexPath] : nil;
    UIView *departing = [swipedCell snapshotViewAfterScreenUpdates:NO];
    CGRect departingFrame = [tableView rectForRowAtIndexPath:indexPath];
    // Key header/footer frames by section and kind, not by view: reloadData
    // re-dequeues the reusable title views, and UIKit can hand the Enabled
    // header's view to Available (and back), which sent each title flying in
    // from the other section's old position.
    NSMutableDictionary<NSString *, NSValue *> *sectionFrames = [NSMutableDictionary dictionary];
    for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
        UIView *header = [tableView headerViewForSection:section];
        UIView *footer = [tableView footerViewForSection:section];
        if (header) sectionFrames[[NSString stringWithFormat:@"h%ld", (long)section]] = [NSValue valueWithCGRect:header.frame];
        if (footer) sectionFrames[[NSString stringWithFormat:@"f%ld", (long)section]] = [NSValue valueWithCGRect:footer.frame];
    }
    CGPoint offset = tableView.contentOffset;
    if (style == UITableViewCellEditingStyleDelete) [self.included removeObject:identifier];
    else if (style == UITableViewCellEditingStyleInsert && ![self.included containsObject:identifier]) [self.included addObject:identifier];
    [self save];
    [self holdSectionTitleHeightsInTableView:tableView nextEnabledFooterText:[self enabledFooterText]];
    // Finish UIKit's edit-control action before replacing its snapshot.
    tableView.userInteractionEnabled = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView performWithoutAnimation:^{
            [self rebuildForm];
            [tableView setEditing:self.editing animated:NO];
            [tableView layoutIfNeeded];
            // UIKit is still running its Remove animation on the swiped cell
            // (layout skipped), and the reload can hand that cell to another
            // row, which then measures nothing and falls back to 44pt: the
            // last Enabled row came back 8pt short on the non-glass build.
            // Give that row a fresh cell.
            NSIndexPath *reused = swipedCell ? [tableView indexPathForCell:swipedCell] : nil;
            if (reused) {
                ApolloLog(@"[SettingsShortcuts] swiped cell reused for row %ld/%ld; reloading it", (long)reused.section, (long)reused.row);
                [self performUpdateKeepingVisibleRowsInPlace:^{
                    [tableView reloadRowsAtIndexPaths:@[reused] withRowAnimation:UITableViewRowAnimationNone];
                }];
            }
        }];
        CGFloat offsetDelta = tableView.contentOffset.y - offset.y;
        CGRect adjustedFrame = departingFrame;
        adjustedFrame.origin.y += offsetDelta;
        departing.frame = adjustedFrame;
        if (departing) [tableView addSubview:departing];
        NSMutableArray<UIView *> *animatedViews = [NSMutableArray array];
        for (NSIndexPath *visible in tableView.indexPathsForVisibleRows) {
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:visible];
            NSString *rowID = [self rowAtIndexPath:visible].rowID;
            NSValue *old = frames[rowID];
            if (old && ![rowID isEqualToString:identifier]) {
                cell.transform = CGAffineTransformMakeTranslation(0,
                    CGRectGetMidY(old.CGRectValue) - CGRectGetMidY(cell.frame) + offsetDelta);
            } else {
                cell.alpha = 0;
                cell.transform = CGAffineTransformMakeScale(0.88, 0.88);
            }
            [animatedViews addObject:cell];
        }
        // Headers and footers move with the rows instead of jumping ahead.
        for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
            for (NSString *kind in @[@"h", @"f"]) {
                UIView *view = [kind isEqualToString:@"h"] ? [tableView headerViewForSection:section] : [tableView footerViewForSection:section];
                NSValue *old = sectionFrames[[NSString stringWithFormat:@"%@%ld", kind, (long)section]];
                if (!view || !old) continue;
                view.transform = CGAffineTransformMakeTranslation(0,
                    CGRectGetMidY(old.CGRectValue) - CGRectGetMidY(view.frame) + offsetDelta);
                [animatedViews addObject:view];
            }
        }
        [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.34 delay:0
            usingSpringWithDamping:0.88 initialSpringVelocity:0
            options:UIViewAnimationOptionBeginFromCurrentState animations:^{
                for (UIView *view in animatedViews) {
                    view.transform = CGAffineTransformIdentity;
                    view.alpha = 1;
                }
                departing.alpha = 0;
                departing.transform = CGAffineTransformMakeScale(0.88, 0.88);
            } completion:^(__unused BOOL finished) {
                [departing removeFromSuperview];
                tableView.userInteractionEnabled = YES;
            }];
    });
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self.included containsObject:[self rowAtIndexPath:indexPath].rowID];
}
- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)proposed {
    return [self.included containsObject:[self rowAtIndexPath:proposed].rowID] ? proposed : source;
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    NSString *identifier = [self rowAtIndexPath:source].rowID;
    NSString *target = [self rowAtIndexPath:destination].rowID;
    NSUInteger index = [self.included indexOfObject:target];
    if (!identifier || index == NSNotFound) return;
    [self.included removeObject:identifier];
    [self.included insertObject:identifier atIndex:index];
    [self save];
    // UIKit already moved the visible row. Reloading here destroys its drop
    // animation and recalculates estimated heights, jumping the scroll offset.
    [self refreshFormAfterRowMove];
}
@end
