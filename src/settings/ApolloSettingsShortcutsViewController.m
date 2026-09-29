#import "ApolloSettingsShortcutsViewController.h"
#import "ApolloSettingsRouter.h"
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

NSArray<NSString *> *ApolloSettingsShortcutCatalog(void) {
    // Fixed discovery order mirrors Settings and the Reborn hub. Included
    // shortcuts use their separately persisted user order instead.
    return @[@"reborn", @"accounts-api-keys", @"posts-feeds", @"comments", @"media",
        @"subreddits", @"profile-layout", @"interface", @"rich-link-previews", @"apollo-ai",
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
                @"subreddits": @"person.3.fill", @"profile-layout": @"person.crop.circle.fill", @"interface": @"slider.horizontal.3", @"accounts-api-keys": @"key.fill", @"rich-link-previews": @"link", @"crash-reports": @"bandage"};
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
            else if ([identifier isEqualToString:@"profile-layout"]) color = UIColor.systemTealColor;
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
    return @[[ApolloSettingsSection sectionWithTitle:@"Enabled Shortcuts" footer:[NSString stringWithFormat:@"%lu of %lu shortcuts enabled. Press and hold the Settings tab to open them. Changes are saved automatically.", (unsigned long)self.included.count, (unsigned long)ApolloSettingsShortcutLimit] rows:includedRows],
        [ApolloSettingsSection sectionWithTitle:@"Available Shortcuts" footer:@"Tap Edit to add, remove, or reorder shortcuts." rows:availableRows]];
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
    UIView *departing = style == UITableViewCellEditingStyleDelete
        ? [[tableView cellForRowAtIndexPath:indexPath] snapshotViewAfterScreenUpdates:NO] : nil;
    CGRect departingFrame = [tableView rectForRowAtIndexPath:indexPath];
    NSMutableArray *sectionViews = [NSMutableArray array];
    for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
        for (UIView *view in @[[tableView headerViewForSection:section] ?: [NSNull null],
                              [tableView footerViewForSection:section] ?: [NSNull null]]) {
            if ([view isKindOfClass:UIView.class]) [sectionViews addObject:@[view, [NSValue valueWithCGRect:view.frame]]];
        }
    }
    CGPoint offset = tableView.contentOffset;
    if (style == UITableViewCellEditingStyleDelete) [self.included removeObject:identifier];
    else if (style == UITableViewCellEditingStyleInsert && ![self.included containsObject:identifier]) [self.included addObject:identifier];
    [self save];
    // Finish UIKit's edit-control action before replacing its snapshot.
    tableView.userInteractionEnabled = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView performWithoutAnimation:^{
            [self rebuildForm];
            [tableView setEditing:self.editing animated:NO];
            [tableView layoutIfNeeded];
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
        for (NSArray *entry in sectionViews) {
            UIView *view = entry[0];
            if (!view.superview) continue;
            view.transform = CGAffineTransformMakeTranslation(0,
                CGRectGetMidY([entry[1] CGRectValue]) - CGRectGetMidY(view.frame) + offsetDelta);
            [animatedViews addObject:view];
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
