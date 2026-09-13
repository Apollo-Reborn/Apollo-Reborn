#import "settings/ApolloLocalBackupsViewController.h"

#import <stdlib.h>

#import "settings/ApolloAutomaticBackup.h"
#import "settings/ApolloBackupActionsCell.h"
#import "settings/ApolloBackupRestore.h"

static NSString *const kLocalBackupsEmptyRowID = @"localBackups.empty";

static BOOL ApolloLocalBackupIsAutomatic(NSURL *url) {
    return [url.lastPathComponent hasPrefix:@"Apollo_Auto_Backup_"];
}

static NSString *ApolloLocalBackupRowID(NSString *filename) {
    return [@"localBackups.archive." stringByAppendingString:filename];
}

@interface ApolloLocalBackupsViewController () <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<NSURL *> *backups;
@property (nonatomic, copy) NSString *expandedFilename;
@property (nonatomic, strong) UISegmentedControl *backupTypeControl;
@property (nonatomic) BOOL showingManualBackups;
@property (nonatomic) BOOL backupsLoaded;
@property (nonatomic, strong) UIDocumentPickerViewController *exportPicker;
@end

@implementation ApolloLocalBackupsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Manage Backups";

    // The type picker is screen navigation. Archive rows themselves stay in
    // the form model, including each conditional expansion row.
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 68)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.preservesSuperviewLayoutMargins = YES;
    header.layoutMargins = UIEdgeInsetsMake(12, 20, 12, 20);
    self.backupTypeControl = [[UISegmentedControl alloc] initWithItems:@[@"Automatic", @"Manual"]];
    self.backupTypeControl.selectedSegmentIndex = 0;
    self.backupTypeControl.accessibilityLabel = @"Backup Type";
    self.backupTypeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backupTypeControl addTarget:self action:@selector(backupTypeChanged:)
        forControlEvents:UIControlEventValueChanged];
    [header addSubview:self.backupTypeControl];
    [NSLayoutConstraint activateConstraints:@[
        [self.backupTypeControl.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
        [self.backupTypeControl.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
        [self.backupTypeControl.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [self.backupTypeControl.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12]
    ]];
    self.tableView.tableHeaderView = header;

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadBackups)
        name:ApolloAutomaticBackupDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadBackups)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadBackups)
        name:NSCalendarDayChangedNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadBackups];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)reloadBackups {
    __weak typeof(self) weakSelf = self;
    [ApolloAutomaticBackup.sharedManager localBackupURLsWithCompletion:^(NSArray<NSURL *> *urls) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.backups = urls ?: @[];
        strongSelf.backupsLoaded = YES;
        // Retention can remove a backup while this screen is open. Expansion
        // follows the filename, never an index that a new archive can shift.
        BOOL expandedBackupExists = NO;
        for (NSURL *url in strongSelf.backups) {
            if ([url.lastPathComponent isEqualToString:strongSelf.expandedFilename]) {
                expandedBackupExists = YES;
                break;
            }
        }
        if (!expandedBackupExists) strongSelf.expandedFilename = nil;
        [strongSelf refreshBackupRows];
    }];
}

- (void)backupTypeChanged:(UISegmentedControl *)sender {
    // Remove the expansion from the OLD visibility snapshot before replacing
    // the archive list. A section reload alone can carry the expanded cell's
    // self-sizing/animation state into the other segment for a visible frame.
    [UIView performWithoutAnimation:^{
        if (self.expandedFilename) {
            self.expandedFilename = nil;
            [self visibilityDidChange];
            [self.tableView layoutIfNeeded];
        }
        self.showingManualBackups = sender.selectedSegmentIndex == 1;
        [self refreshBackupRows];
    }];
}

- (void)refreshBackupRows {
    NSUInteger automaticCount = 0;
    for (NSURL *url in self.backups) if (ApolloLocalBackupIsAutomatic(url)) automaticCount++;
    if (self.backupsLoaded) {
        [self.backupTypeControl setTitle:[NSString stringWithFormat:@"Automatic · %lu", (unsigned long)automaticCount]
            forSegmentAtIndex:0];
        [self.backupTypeControl setTitle:[NSString stringWithFormat:@"Manual · %lu", (unsigned long)(self.backups.count - automaticCount)]
            forSegmentAtIndex:1];
    }
    // RowAnimationNone does not suppress UIKit's implicit layout animations.
    // Finish sizing the replacement rows inside the suppression block too.
    [UIView performWithoutAnimation:^{
        [self rebuildSectionContainingRowID:kLocalBackupsEmptyRowID withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView layoutIfNeeded];
    }];
}

- (void)applyExpansionStateToCell:(UITableViewCell *)cell filename:(NSString *)filename {
    if (!cell) return;
    BOOL expanded = [self.expandedFilename isEqualToString:filename];
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:13
        weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:expanded ? @"chevron.up" : @"chevron.down"
        withConfiguration:configuration]];
    chevron.contentMode = UIViewContentModeCenter;
    chevron.frame = CGRectMake(0, 0, 20, 24);
    chevron.isAccessibilityElement = NO;
    cell.accessoryView = chevron;
    cell.accessibilityValue = expanded ? @"Expanded" : @"Collapsed";
    cell.accessibilityHint = expanded ? @"Hide backup actions" : @"Show backup actions";
}

- (void)toggleBackupURL:(NSURL *)url {
    if (self.presentedViewController) return;
    NSString *previous = self.expandedFilename;
    self.expandedFilename = [previous isEqualToString:url.lastPathComponent] ? nil : url.lastPathComponent;
    [self visibilityDidChange];
    // Updating just the disclosure state avoids replacing the tapped cell
    // during the form's insertion/deletion animation.
    if (previous) [self applyExpansionStateToCell:[self cellForRowID:ApolloLocalBackupRowID(previous)] filename:previous];
    [self applyExpansionStateToCell:[self cellForRowID:ApolloLocalBackupRowID(url.lastPathComponent)]
        filename:url.lastPathComponent];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<NSURL *> *filtered = [NSMutableArray array];
    for (NSURL *url in self.backups) {
        if (ApolloLocalBackupIsAutomatic(url) != self.showingManualBackups) [filtered addObject:url];
    }

    NSMutableArray<ApolloSettingsRow *> *rows = [NSMutableArray array];
    // Keep this identity in the model even when hidden, so a refresh always
    // targets this section across empty/nonempty and Automatic/Manual changes.
    ApolloSettingsRow *empty = [ApolloSettingsRow customRowWithID:kLocalBackupsEmptyRowID
        cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EmptyBackup"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"EmptyBackup"];
            cell.textLabel.text = !weakSelf.backupsLoaded ? @"Loading Backups…" : weakSelf.showingManualBackups
                ? @"No Manual Backups Yet" : @"No Automatic Backups Yet";
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            cell.textLabel.adjustsFontForContentSizeCategory = YES;
            cell.textLabel.numberOfLines = 0;
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        } onSelect:nil];
    empty.visible = ^BOOL { return filtered.count == 0; };
    [rows addObject:empty];

    NSDateFormatter *dateFormatter = [NSDateFormatter new];
    dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    dateFormatter.timeStyle = NSDateFormatterShortStyle;
    dateFormatter.doesRelativeDateFormatting = YES;
    for (NSURL *url in filtered) {
        NSDate *date = nil;
        NSNumber *size = nil;
        [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSString *dateText = date ? [dateFormatter stringFromDate:date] : @"Date Unavailable";
        NSString *kind = ApolloLocalBackupIsAutomatic(url) ? @"Automatic" : @"Manual";
        NSString *detail = size ? [NSString stringWithFormat:@"%@ · %@", kind,
            [NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile]] : kind;
        NSString *rowID = ApolloLocalBackupRowID(url.lastPathComponent);
        ApolloSettingsRow *summary = [ApolloSettingsRow customRowWithID:rowID
            cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LocalBackup"];
                if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LocalBackup"];
                cell.textLabel.text = dateText;
                cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
                cell.textLabel.numberOfLines = 0;
                cell.textLabel.adjustsFontForContentSizeCategory = YES;
                cell.detailTextLabel.text = detail;
                cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
                cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
                cell.detailTextLabel.numberOfLines = 0;
                cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.accessibilityTraits = UIAccessibilityTraitButton;
                cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", dateText, detail];
                [weakSelf applyExpansionStateToCell:cell filename:url.lastPathComponent];
                [weakSelf apollo_applyPrimaryTextColorToCell:cell];
                return cell;
            } onSelect:^{ [weakSelf toggleBackupURL:url]; }];
        summary.enabled = ^BOOL { return !weakSelf.presentedViewController; };
        [rows addObject:summary];

        ApolloSettingsRow *actions = [ApolloSettingsRow customRowWithID:[rowID stringByAppendingString:@".actions"]
            cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
                ApolloBackupActionsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LocalBackupActions"];
                if (!cell) cell = [[ApolloBackupActionsCell alloc] initWithStyle:UITableViewCellStyleDefault
                    reuseIdentifier:@"LocalBackupActions"];
                [cell configureWithBackupURL:url
                    restoreAction:^(NSURL *backupURL) { [weakSelf confirmRestoreURL:backupURL]; }
                    exportAction:^(NSURL *backupURL) { [weakSelf exportURL:backupURL]; }
                    deleteAction:^(NSURL *backupURL) { [weakSelf confirmDeleteURL:backupURL]; }];
                return cell;
            } onSelect:nil];
        actions.visible = ^BOOL { return [weakSelf.expandedFilename isEqualToString:url.lastPathComponent]; };
        [rows addObject:actions];
    }
    NSString *retention = self.showingManualBackups ? @"Manual backups stay until you delete them."
        : @"Keeps the newest 10 automatic backups.";
    NSString *footer = [retention stringByAppendingString:@"\n\nExport a backup to Files before deleting Apollo or installing it with a different app identifier."];
    return @[[ApolloSettingsSection sectionWithTitle:nil footer:footer rows:rows]];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmRestoreURL:(NSURL *)url {
    if (self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Confirm Restore"
        message:[NSString stringWithFormat:@"%@\n\nThis will replace all existing settings and logged-in accounts with the backup. This cannot be undone.", url.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { [weakSelf restoreURL:url]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreURL:(NSURL *)url {
    NSString *errorTitle = nil, *errorMessage = nil;
    if (!ApolloBackupRestoreRestoreFromZipURL(url, &errorTitle, &errorMessage)) {
        [self showAlertWithTitle:errorTitle ?: @"Restore Failed" message:errorMessage ?: @"Could not restore backup."];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restore Complete"
        message:@"Settings successfully restored. Apollo needs to restart to apply changes."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close App" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { exit(0); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportURL:(NSURL *)url {
    if (self.presentedViewController) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        [self showAlertWithTitle:@"Backup Unavailable" message:@"This backup is no longer stored in Apollo."];
        [self reloadBackups];
        return;
    }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForExportingURLs:@[url] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    self.exportPicker = picker;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)confirmDeleteURL:(NSURL *)url {
    if (self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete Backup?"
        message:url.lastPathComponent preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [ApolloAutomaticBackup.sharedManager deleteLocalBackupURL:url completion:^(NSError *error) {
                if (error) [weakSelf showAlertWithTitle:@"Delete Failed" message:error.localizedDescription];
            }];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (controller == self.exportPicker) self.exportPicker = nil;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (controller == self.exportPicker) self.exportPicker = nil;
}

@end
