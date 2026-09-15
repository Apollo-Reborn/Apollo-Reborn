#import "settings/ApolloAutomaticBackupViewController.h"

#import "settings/ApolloAutomaticBackup.h"
#import "settings/ApolloLocalBackupsViewController.h"

static NSString *ApolloBackupDateDescription(NSDate *date) {
    if (!date) return @"Never";
    return [NSDateFormatter localizedStringFromDate:date
        dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
}

@interface ApolloAutomaticBackupViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSNumber *backupCount;
@property (nonatomic) BOOL countRequestInFlight;
@property (nonatomic) BOOL refreshScheduled;
@property (nonatomic, strong) UIDocumentPickerViewController *manualExportPicker;
@property (nonatomic, strong) NSURL *manualExportURL;
@end

@implementation ApolloAutomaticBackupViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Backup Settings";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backupStateDidChange)
        name:ApolloAutomaticBackupDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backupStateDidChange)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self refreshBackupCount];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshBackupCount];
    [self scheduleRefresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (BOOL)canPerformBackupAction {
    return !ApolloAutomaticBackup.sharedManager.isBackingUp && !self.presentedViewController;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    BOOL (^canConfigure)(void) = ^BOOL { return !manager.isBackingUp; };
    BOOL (^automaticVisible)(void) = ^BOOL { return manager.enabled; };

    ApolloSettingsRow *enabled = [ApolloSettingsRow switchRowWithID:@"automatic.enabled"
        title:@"Automatic Backups" isOn:^BOOL { return manager.enabled; }
        onToggle:^(UISwitch *sender) {
            [manager setEnabled:sender.isOn];
            [weakSelf scheduleRefresh];
        }];
    enabled.enabled = canConfigure;

    ApolloSettingsRow *backupNow = [ApolloSettingsRow buttonRowWithID:@"automatic.backupNow"
        title:@"Back Up Now" action:^{ [weakSelf backUpNow]; }];
    backupNow.enabled = canConfigure;

    ApolloSettingsRow *interval = [ApolloSettingsRow valueRowWithID:@"automatic.interval"
        title:@"Backup Interval" detail:^NSString * {
            return manager.intervalDays == 0 ? @"Every Minute (Testing)" : manager.intervalDays == 1
                ? @"Every Day" : [NSString stringWithFormat:@"Every %ld Days", (long)manager.intervalDays];
        } onSelect:^{ [weakSelf chooseInterval]; }];
    interval.enabled = canConfigure;
    interval.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 1; };

    ApolloSettingsRow *last = [ApolloSettingsRow valueRowWithID:@"automatic.last"
        title:@"Last Backup" detail:^NSString * { return ApolloBackupDateDescription(manager.lastBackupDate); }
        onSelect:nil];

    ApolloSettingsRow *next = [ApolloSettingsRow valueRowWithID:@"automatic.next"
        title:@"Next Backup" detail:^NSString * {
            if (manager.isBackingUp) return @"Backing Up…";
            NSDate *retry = manager.nextRetryDate;
            if (retry) return [@"Retry: " stringByAppendingString:ApolloBackupDateDescription(retry)];
            return ApolloBackupDateDescription(manager.nextBackupDate);
        } onSelect:nil];

    ApolloSettingsRow *error = [ApolloSettingsRow customRowWithID:@"automatic.error"
        cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AutomaticBackupError"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                reuseIdentifier:@"AutomaticBackupError"];
            cell.textLabel.text = @"Backup Failed";
            cell.detailTextLabel.text = manager.lastErrorMessage;
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            [weakSelf apollo_applyPrimaryTextColorToCell:cell];
            return cell;
        } onSelect:^{ [weakSelf showBackupFailure]; }];
    error.visible = ^BOOL { return manager.enabled && manager.lastErrorMessage.length > 0; };

    ApolloSettingsRow *manage = [ApolloSettingsRow disclosureRowWithID:@"automatic.manage"
        title:@"Manage Backups" detail:^NSString * {
            return weakSelf.backupCount ? weakSelf.backupCount.stringValue : nil;
        } push:^UIViewController * {
            return [[ApolloLocalBackupsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        }];

    ApolloSettingsSection *schedule = [ApolloSettingsSection sectionWithTitle:@"Backup Schedule"
        footer:@"Automatic backups are stored inside Apollo. The latest 10 automatic backups are kept; manual backups remain until you delete them."
        rows:@[interval]];
    schedule.visible = automaticVisible;

    ApolloSettingsSection *activity = [ApolloSettingsSection sectionWithTitle:@"Backup Activity"
        footer:nil rows:@[last, next, error]];
    activity.visible = automaticVisible;

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
            footer:@"Backups include settings, API keys, and login credentials. Keep them private."
            rows:@[enabled, backupNow]],
        schedule,
        activity,
        [ApolloSettingsSection sectionWithTitle:@"Backups"
            footer:@"Manual backups are kept locally and immediately open Files so you can save another copy in iCloud Drive or elsewhere. Export any backup again from Manage Backups."
            rows:@[manage]],
    ];
}

- (void)backupStateDidChange { [self scheduleRefresh]; [self refreshBackupCount]; }

- (void)scheduleRefresh {
    if (self.refreshScheduled) return;
    self.refreshScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.refreshScheduled = NO;
        [weakSelf refreshRows];
    });
}

- (void)refreshRows {
    if (!self.isViewLoaded) return;
    [self visibilityDidChange];
    for (NSString *rowID in @[@"automatic.enabled", @"automatic.backupNow", @"automatic.interval",
                              @"automatic.last", @"automatic.next", @"automatic.error", @"automatic.manage"]) {
        [self reloadRowWithID:rowID];
    }
}

- (void)refreshBackupCount {
    if (self.countRequestInFlight) return;
    self.countRequestInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [ApolloAutomaticBackup.sharedManager localBackupURLsWithCompletion:^(NSArray<NSURL *> *urls) {
        weakSelf.countRequestInFlight = NO;
        weakSelf.backupCount = @(urls.count);
        [weakSelf scheduleRefresh];
    }];
}

- (void)chooseInterval {
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    NSArray<NSString *> *titles = @[@"Every Minute (Testing)", @"Every Day", @"Every 3 Days", @"Every 7 Days"];
    NSArray<NSNumber *> *values = @[@0, @1, @3, @7];
    NSUInteger current = [values indexOfObject:@(manager.intervalDays)];
    if (current == NSNotFound) current = 2;
    __weak typeof(self) weakSelf = self;
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"automatic.interval"], nil, titles, (NSInteger)current,
        ^(NSInteger pickedIndex) {
            [manager setIntervalDays:values[(NSUInteger)pickedIndex].integerValue];
            [weakSelf scheduleRefresh];
        });
}

- (void)backUpNow {
    if (![self canPerformBackupAction]) return;
    __weak typeof(self) weakSelf = self;
    [ApolloAutomaticBackup.sharedManager backUpNowWithCompletion:^(NSString *filename, NSError *error) {
        if (error) [weakSelf showAlertWithTitle:@"Backup Failed" message:error.localizedDescription];
        else [weakSelf exportManualBackupNamed:filename];
    }];
}

- (void)exportManualBackupNamed:(NSString *)filename {
    __weak typeof(self) weakSelf = self;
    [ApolloAutomaticBackup.sharedManager localBackupURLsWithCompletion:^(NSArray<NSURL *> *urls) {
        NSURL *backupURL = nil;
        for (NSURL *url in urls) {
            if ([url.lastPathComponent isEqualToString:filename]) {
                backupURL = url;
                break;
            }
        }
        if (!backupURL) {
            [weakSelf showAlertWithTitle:@"Backup Saved Locally"
                message:@"Apollo created the manual backup, but could not open it for export. You can export it from Manage Backups."];
            return;
        }
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForExportingURLs:@[backupURL] asCopy:YES];
        picker.delegate = weakSelf;
        picker.allowsMultipleSelection = NO;
        picker.modalPresentationStyle = UIModalPresentationFormSheet;
        weakSelf.manualExportURL = backupURL;
        weakSelf.manualExportPicker = picker;
        [weakSelf presentViewController:picker animated:YES completion:nil];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (controller != self.manualExportPicker) return;
    NSString *filename = self.manualExportURL.lastPathComponent ?: @"Apollo backup";
    self.manualExportPicker = nil;
    self.manualExportURL = nil;
    [self showAlertWithTitle:@"Backup Complete" message:[NSString stringWithFormat:
        @"%@ was saved locally and exported to Files. It contains your logged-in account credentials. Keep it private.",
        filename]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (controller != self.manualExportPicker) return;
    NSString *filename = self.manualExportURL.lastPathComponent ?: @"The manual backup";
    self.manualExportPicker = nil;
    self.manualExportURL = nil;
    [self showAlertWithTitle:@"Backup Saved Locally" message:[NSString stringWithFormat:
        @"%@ remains in Manage Backups. Export it before deleting Apollo.", filename]];
}

- (void)showBackupFailure {
    NSString *message = ApolloAutomaticBackup.sharedManager.lastErrorMessage ?: @"The backup could not be completed.";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Backup Failed" message:message
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Try Again" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf backUpNow]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *source = [self cellForRowID:@"automatic.error"];
    sheet.popoverPresentationController.sourceView = source ?: self.view;
    sheet.popoverPresentationController.sourceRect = source ? source.bounds
        : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
