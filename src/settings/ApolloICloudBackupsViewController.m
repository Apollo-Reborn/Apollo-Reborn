#import "settings/ApolloICloudBackupsViewController.h"

#import "settings/ApolloBackupActionsCell.h"
#import "settings/ApolloBackupDocument.h"
#import "settings/ApolloICloudBackupStore.h"
#import "settings/ApolloICloudBackupSupport.h"

static NSString *const kICloudBackupsEmptyRowID = @"icloudBackups.empty";

static NSString *ApolloICloudBackupRowID(NSString *filename) {
    return [@"icloudBackups.archive." stringByAppendingString:filename];
}

@interface ApolloICloudBackupsViewController ()
@property (nonatomic, copy) NSArray<NSURL *> *backups;
@property (nonatomic, copy) NSString *expandedFilename;
@property (nonatomic) BOOL loaded;
@property (nonatomic) BOOL loading;
@end

@implementation ApolloICloudBackupsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"iCloud Backups";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange)
        name:ApolloICloudBackupStoreDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadBackups];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)storeDidChange {
    if (!ApolloICloudBackupStore.sharedStore.isWorking && !self.loading) [self reloadBackups];
}

- (void)reloadBackups {
    if (self.loading || ApolloICloudBackupStore.sharedStore.isWorking) return;
    self.loading = YES;
    __weak typeof(self) weakSelf = self;
    [ApolloICloudBackupStore.sharedStore backupURLsWithCompletion:^(NSArray<NSURL *> *urls, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.loading = NO;
        strongSelf.backups = urls ?: @[];
        strongSelf.loaded = YES;
        BOOL expandedStillExists = NO;
        for (NSURL *url in strongSelf.backups) {
            if ([url.lastPathComponent isEqualToString:strongSelf.expandedFilename]) {
                expandedStillExists = YES;
                break;
            }
        }
        if (!expandedStillExists) strongSelf.expandedFilename = nil;
        [strongSelf rebuildSectionContainingRowID:kICloudBackupsEmptyRowID
                                  withRowAnimation:UITableViewRowAnimationNone];
        if (error && strongSelf.viewIfLoaded.window) {
            [strongSelf showAlertWithTitle:@"iCloud Backups Unavailable" message:error.localizedDescription];
        }
    }];
}

- (void)applyExpansionStateToCell:(UITableViewCell *)cell filename:(NSString *)filename {
    BOOL expanded = [self.expandedFilename isEqualToString:filename];
    cell.accessoryType = expanded ? UITableViewCellAccessoryDetailDisclosureButton
        : UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityValue = expanded ? @"Expanded" : @"Collapsed";
}

- (void)toggleBackupURL:(NSURL *)url {
    if (self.presentedViewController || ApolloICloudBackupStore.sharedStore.isWorking) return;
    NSString *previous = self.expandedFilename;
    self.expandedFilename = [previous isEqualToString:url.lastPathComponent] ? nil : url.lastPathComponent;
    [self visibilityDidChange];
    if (previous) [self applyExpansionStateToCell:[self cellForRowID:ApolloICloudBackupRowID(previous)] filename:previous];
    [self applyExpansionStateToCell:[self cellForRowID:ApolloICloudBackupRowID(url.lastPathComponent)]
        filename:url.lastPathComponent];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<ApolloSettingsRow *> *rows = [NSMutableArray array];
    ApolloSettingsRow *empty = [ApolloSettingsRow customRowWithID:kICloudBackupsEmptyRowID
        cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EmptyICloudBackup"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                reuseIdentifier:@"EmptyICloudBackup"];
            cell.textLabel.text = weakSelf.loaded ? @"No iCloud Backups Yet" : @"Loading iCloud Backups…";
            cell.textLabel.numberOfLines = 0;
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
            return cell;
        } onSelect:nil];
    empty.visible = ^BOOL { return weakSelf.backups.count == 0; };
    [rows addObject:empty];

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    formatter.doesRelativeDateFormatting = YES;
    for (NSURL *url in self.backups) {
        NSDate *date = nil;
        NSNumber *size = nil;
        NSString *downloadStatus = nil;
        [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [url getResourceValue:&downloadStatus forKey:NSURLUbiquitousItemDownloadingStatusKey error:nil];
        NSString *dateText = date ? [formatter stringFromDate:date] : @"Date Unavailable";
        NSString *kind = ApolloICloudBackupArchiveNameIsAutomatic(url.lastPathComponent) ? @"Automatic" : @"Manual";
        NSString *availability = [downloadStatus isEqualToString:NSURLUbiquitousItemDownloadingStatusCurrent]
            ? @"Downloaded" : @"In iCloud";
        NSString *detail = size ? [NSString stringWithFormat:@"%@ · %@ · %@", kind,
            [NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile], availability]
            : [NSString stringWithFormat:@"%@ · %@", kind, availability];
        NSString *rowID = ApolloICloudBackupRowID(url.lastPathComponent);
        ApolloSettingsRow *summary = [ApolloSettingsRow customRowWithID:rowID
            cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ICloudBackup"];
                if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ICloudBackup"];
                cell.textLabel.text = dateText;
                cell.textLabel.numberOfLines = 0;
                cell.detailTextLabel.text = detail;
                cell.detailTextLabel.numberOfLines = 0;
                cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
                [weakSelf applyExpansionStateToCell:cell filename:url.lastPathComponent];
                [weakSelf apollo_applyPrimaryTextColorToCell:cell];
                return cell;
            } onSelect:^{ [weakSelf toggleBackupURL:url]; }];
        [rows addObject:summary];

        ApolloSettingsRow *actions = [ApolloSettingsRow customRowWithID:[rowID stringByAppendingString:@".actions"]
            cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
                ApolloBackupActionsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ICloudBackupActions"];
                if (!cell) cell = [[ApolloBackupActionsCell alloc] initWithStyle:UITableViewCellStyleDefault
                    reuseIdentifier:@"ICloudBackupActions"];
                [cell configureWithBackupURL:url
                    restoreAction:^(NSURL *backupURL) { [weakSelf restoreURL:backupURL]; }
                    exportAction:nil
                    deleteAction:^(NSURL *backupURL) { [weakSelf confirmDeleteURL:backupURL]; }];
                return cell;
            } onSelect:nil];
        actions.visible = ^BOOL { return [weakSelf.expandedFilename isEqualToString:url.lastPathComponent]; };
        [rows addObject:actions];
    }

    return @[[ApolloSettingsSection sectionWithTitle:nil
        footer:@"Backups from devices using this same signed iCloud container appear here. Restores are always downloaded and validated before anything changes."
        rows:rows]];
}

- (void)restoreURL:(NSURL *)url {
    if (self.presentedViewController || ApolloICloudBackupStore.sharedStore.isWorking) return;
    __weak typeof(self) weakSelf = self;
    [ApolloICloudBackupStore.sharedStore prepareLocalCopyOfBackupURL:url
        completion:^(NSURL *localURL, NSError *error) {
            typeof(self) strongSelf = weakSelf;
            if (error || !localURL) {
                [strongSelf showAlertWithTitle:@"Download Failed" message:error.localizedDescription ?: @"Could not download the backup."];
                return;
            }
            if (!strongSelf || !strongSelf.viewIfLoaded.window) {
                [NSFileManager.defaultManager removeItemAtURL:localURL.URLByDeletingLastPathComponent error:nil];
                return;
            }
            ApolloBackupPresentRestoreConfirmation(strongSelf, localURL, ^{
                [NSFileManager.defaultManager removeItemAtURL:localURL.URLByDeletingLastPathComponent error:nil];
            });
        }];
}

- (void)confirmDeleteURL:(NSURL *)url {
    if (self.presentedViewController || ApolloICloudBackupStore.sharedStore.isWorking) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete iCloud Backup?"
        message:@"This removes the backup from iCloud Drive on every connected device."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [ApolloICloudBackupStore.sharedStore deleteBackupURL:url completion:^(NSError *error) {
                if (error) [weakSelf showAlertWithTitle:@"Delete Failed" message:error.localizedDescription];
                else [weakSelf reloadBackups];
            }];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
