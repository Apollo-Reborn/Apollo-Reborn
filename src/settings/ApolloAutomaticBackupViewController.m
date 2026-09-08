#import "settings/ApolloAutomaticBackupViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>

#import "ApolloCommon.h"
#import "settings/ApolloAutomaticBackup.h"

static NSString *ApolloBackupDateDescription(NSDate *date) {
    if (!date) return @"Never";
    return [NSDateFormatter localizedStringFromDate:date
                                          dateStyle:NSDateFormatterMediumStyle
                                          timeStyle:NSDateFormatterShortStyle];
}

static void ApolloBackupShowAlert(UIViewController *presenter, NSString *title, NSString *message) {
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

typedef NS_ENUM(NSUInteger, ApolloBackupPickerPurpose) {
    ApolloBackupPickerNone,
    ApolloBackupPickerSelectFolder,
    ApolloBackupPickerBrowse,
};

@interface ApolloAutomaticBackupViewController () <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic) BOOL refreshScheduled;
@property (nonatomic) BOOL refreshingRows;
@property (nonatomic) BOOL refreshRequested;
@property (nonatomic) BOOL preparingPicker;
@property (nonatomic) BOOL acceptingFolderSelection;
@property (nonatomic) BOOL backupAfterFolderSelection;
@property (nonatomic) ApolloBackupPickerPurpose pickerPurpose;
@property (nonatomic, strong) UIDocumentPickerViewController *activePicker;
@property (nonatomic, strong) NSURL *folderExportTemplateURL;
@property (nonatomic) BOOL folderUnavailable;
@property (nonatomic) BOOL folderValidationInFlight;
@property (nonatomic) NSUInteger folderValidationGeneration;
@property (nonatomic, copy) NSString *resolvedFolderName;
@end

@implementation ApolloAutomaticBackupViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Backup Settings";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backupStateDidChange:)
        name:ApolloAutomaticBackupDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backupStateDidChange:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshBackupRows];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self validateBackupFolder];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_folderExportTemplateURL) [NSFileManager.defaultManager removeItemAtURL:_folderExportTemplateURL.URLByDeletingLastPathComponent error:nil];
}

- (BOOL)canPerformBackupAction {
    return !ApolloAutomaticBackup.sharedManager.isBackingUp && !self.preparingPicker &&
        !self.acceptingFolderSelection && !self.activePicker;
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    BOOL (^canConfigure)(void) = ^BOOL { return [weakSelf canPerformBackupAction]; };
    BOOL (^automaticVisible)(void) = ^BOOL { return manager.enabled; };

    ApolloSettingsRow *enabled = [ApolloSettingsRow switchRowWithID:@"automatic.enabled"
        title:@"Automatic Backups" isOn:^BOOL { return manager.enabled; }
        onToggle:^(UISwitch *sender) { [manager setEnabled:sender.isOn]; }];
    enabled.enabled = canConfigure;

    ApolloSettingsRow *backupNow = [ApolloSettingsRow buttonRowWithID:@"automatic.backupNow"
        title:@"Back Up Now" action:^{ [weakSelf backUpNow]; }];
    backupNow.enabled = canConfigure;

    ApolloSettingsRow *interval = [ApolloSettingsRow valueRowWithID:@"automatic.interval"
        title:@"Backup Interval" detail:^NSString * {
        return manager.intervalDays == 1 ? @"Every Day"
            : [NSString stringWithFormat:@"Every %ld Days", (long)manager.intervalDays];
    } onSelect:^{ [weakSelf chooseInterval]; }];
    interval.enabled = canConfigure;
    interval.visible = automaticVisible;
    interval.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 1; };

    // The folder row also communicates setup and access state.
    ApolloSettingsRow *folder = [ApolloSettingsRow customRowWithID:@"automatic.folder"
        cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        BOOL hasFolder = manager.hasSavedFolder;
        NSString *reuseID = @"AutomaticBackupFolderValue";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                              reuseIdentifier:reuseID];
        cell.textLabel.text = @"Backup Folder";
        cell.detailTextLabel.text = !hasFolder ? @"Set Up Folder"
            : (weakSelf.folderUnavailable ? @"Folder Unavailable — Tap to Reconnect"
                : (weakSelf.resolvedFolderName ?: manager.savedFolderName));
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryType = hasFolder && !weakSelf.folderUnavailable
            ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
        // Presenting Files should not flash the row's highlight or dim its text
        // while the folder permission check finishes. The enabled predicate
        // still prevents another tap during preparation and presentation.
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.contentView.alpha = manager.isBackingUp || weakSelf.acceptingFolderSelection ? 0.4 : 1.0;
        [weakSelf apollo_applyPrimaryTextColorToCell:cell];
        return cell;
    } onSelect:^{
        if (!manager.hasSavedFolder || weakSelf.folderUnavailable) [weakSelf chooseFilesFolder];
        else [weakSelf viewSelectedFolder];
    }];
    folder.enabled = canConfigure;
    folder.visible = automaticVisible;

    ApolloSettingsRow *lastBackup = [ApolloSettingsRow valueRowWithID:@"automatic.lastBackup"
        title:@"Last Backup" detail:^NSString * { return ApolloBackupDateDescription(manager.lastBackupDate); } onSelect:nil];
    lastBackup.visible = automaticVisible;
    lastBackup.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 0; };

    ApolloSettingsRow *nextBackup = [ApolloSettingsRow valueRowWithID:@"automatic.nextBackup"
        title:@"Next Backup" detail:^NSString * {
        if (!manager.hasSavedFolder) return @"Setup Required";
        if (manager.isBackingUp) return @"Backing Up…";
        NSDate *retry = manager.nextRetryDate;
        if (retry) return [@"Retry: " stringByAppendingString:ApolloBackupDateDescription(retry)];
        NSDate *next = manager.nextBackupDate;
        if (!next || next.timeIntervalSinceNow <= 0) {
            return manager.lastErrorMessage.length ? @"Retry Pending" : @"When Apollo Is Open";
        }
        return ApolloBackupDateDescription(next);
    } onSelect:nil];
    nextBackup.visible = automaticVisible;
    nextBackup.configure = ^(UITableViewCell *cell) { cell.detailTextLabel.numberOfLines = 0; };

    ApolloSettingsRow *lastError = [ApolloSettingsRow customRowWithID:@"automatic.lastError"
        cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
        NSString *reuseID = @"AutomaticBackupFailure";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                              reuseIdentifier:reuseID];
        cell.textLabel.text = @"Backup Failed";
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.text = manager.lastErrorMessage;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.contentView.alpha = canConfigure() ? 1.0 : 0.4;
        [weakSelf apollo_applyPrimaryTextColorToCell:cell];
        return cell;
    } onSelect:^{ [weakSelf showBackupFailureActions:manager.lastErrorMessage]; }];
    lastError.enabled = canConfigure;
    lastError.visible = ^BOOL { return manager.enabled && manager.lastErrorMessage.length > 0; };

    return @[
        [ApolloSettingsSection sectionWithTitle:nil
            footer:@"Backups include settings, API keys, and login credentials. Keep them private."
            rows:@[enabled, backupNow]],
        [ApolloSettingsSection sectionWithTitle:@"Backup Setup"
            footer:@"Automatic backups require a backup folder. The latest 10 automatic backups from this installation are kept. Manual backups stay until you delete them."
            rows:@[interval, folder]],
        [ApolloSettingsSection sectionWithTitle:@"Backup Activity"
            footer:@"Automatic backups run while Apollo is open, or the next time you open it after the interval has passed."
            rows:@[lastBackup, nextBackup, lastError]],
    ];
}

// The form retains section identities when its conditional rows are hidden.
// Collapse empty sections while retaining their titles for the next toggle.
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [super tableView:tableView numberOfRowsInSection:section] ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return [super tableView:tableView numberOfRowsInSection:section] ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}

- (void)backupStateDidChange:(__unused NSNotification *)notification {
    if (self.refreshScheduled) return;
    self.refreshScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.refreshScheduled = NO;
        [weakSelf refreshBackupRows];
        [weakSelf validateBackupFolder];
    });
}

- (void)updateFolderUnavailable:(BOOL)unavailable name:(NSString *)name {
    // A successful selection/save/browser read supersedes any older check.
    self.folderValidationGeneration++;
    BOOL changed = self.folderUnavailable != unavailable ||
        !(self.resolvedFolderName == name || [self.resolvedFolderName isEqualToString:name]);
    self.folderUnavailable = unavailable;
    self.resolvedFolderName = name;
    if (changed) [self refreshBackupRows];
}

- (void)validateBackupFolder {
    if (!self.isViewLoaded || !self.view.window) return;
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    if (!manager.hasSavedFolder) {
        [self updateFolderUnavailable:NO name:nil];
        return;
    }
    if (self.folderValidationInFlight || manager.isBackingUp) return;
    self.folderValidationInFlight = YES;
    NSUInteger generation = self.folderValidationGeneration;
    __weak typeof(self) weakSelf = self;
    // Check actual directory access: a failed archive or full disk does not mean
    // the selected folder is missing. This read never changes the schedule.
    [manager selectedFolderURLWithCompletion:^(NSURL *folderURL, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.folderValidationInFlight = NO;
        if (generation != strongSelf.folderValidationGeneration) {
            [strongSelf validateBackupFolder];
            return;
        }
        [strongSelf updateFolderUnavailable:error != nil || !folderURL name:folderURL.lastPathComponent];
    }];
}

- (void)refreshBackupRows {
    if (!self.isViewLoaded) return;
    if (self.refreshingRows) {
        self.refreshRequested = YES;
        return;
    }
    self.refreshingRows = YES;
    __weak typeof(self) weakSelf = self;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            for (NSString *rowID in @[@"automatic.enabled", @"automatic.backupNow",
                                      @"automatic.interval", @"automatic.folder", @"automatic.lastBackup",
                                      @"automatic.nextBackup", @"automatic.lastError"]) {
                [strongSelf reloadRowWithID:rowID];
            }
            strongSelf.refreshingRows = NO;
            if (strongSelf.refreshRequested) {
                strongSelf.refreshRequested = NO;
                [strongSelf refreshBackupRows];
            }
        });
    }];
    [self visibilityDidChange];
    [CATransaction commit];
}

- (void)chooseInterval {
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    if (manager.isBackingUp) return;
    NSArray<NSNumber *> *days = @[@1, @3, @7];
    NSUInteger current = [days indexOfObject:@(manager.intervalDays)];
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"automatic.interval"], nil,
                                @[@"Every Day", @"Every 3 Days", @"Every 7 Days"],
                                current == NSNotFound ? 1 : (NSInteger)current, ^(NSInteger pickedIndex) {
        if (!manager.isBackingUp) [manager setIntervalDays:days[(NSUInteger)pickedIndex].integerValue];
    });
}

- (void)showBackupFailureActions:(NSString *)message {
    if (![self canPerformBackupAction] || self.presentedViewController || !self.viewIfLoaded.window) return;
    NSString *details = [NSString stringWithFormat:@"%@\n\nUse a new folder name to keep existing backups.",
        message.length ? message : @"The backup could not be completed."];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Backup Failed" message:details
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Retry Now" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf backUpNow]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Set Up Another Folder" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf chooseFilesFolder]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = self.view;
    UITableViewCell *source = [self cellForRowID:@"automatic.lastError"] ?: [self cellForRowID:@"automatic.backupNow"];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = source ? [source convertRect:source.bounds toView:anchor]
        : CGRectMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentBackupPicker:(UIDocumentPickerViewController *)picker purpose:(ApolloBackupPickerPurpose)purpose {
    self.preparingPicker = NO;
    self.pickerPurpose = purpose;
    self.activePicker = picker;
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
    picker.presentationController.delegate = self;
    [self refreshBackupRows];
}

- (void)chooseFilesFolder {
    if (![self canPerformBackupAction]) return;
    // A unique staging parent prevents cleanup from touching any saved backups.
    NSURL *staging = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL *templateURL = [staging URLByAppendingPathComponent:@"Apollo Reborn Backups" isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:templateURL withIntermediateDirectories:YES
        attributes:@{NSFileProtectionKey: NSFileProtectionComplete, NSFilePosixPermissions: @0700} error:&error]) {
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        self.backupAfterFolderSelection = NO;
        ApolloBackupShowAlert(self, @"Unable to Open Files", error.localizedDescription);
        return;
    }
    self.folderExportTemplateURL = templateURL;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForExportingURLs:@[templateURL] asCopy:YES];
    [self presentBackupPicker:picker purpose:ApolloBackupPickerSelectFolder];
}

- (void)showFolderUnavailable:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Folder Unavailable"
        message:error.localizedDescription ?: @"Select a backup folder in Files to continue."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Select Folder" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf chooseFilesFolder]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewSelectedFolder {
    if (![self canPerformBackupAction]) return;
    self.preparingPicker = YES;
    [self refreshBackupRows];
    __weak typeof(self) weakSelf = self;
    void (^presentBrowser)(NSURL *, NSError *) = ^(NSURL *folderURL, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.preparingPicker = NO;
        if (!strongSelf.view.window) return;
        if (error) {
            [strongSelf updateFolderUnavailable:YES name:nil];
            [strongSelf refreshBackupRows];
            [strongSelf showFolderUnavailable:error];
            return;
        }
        [strongSelf updateFolderUnavailable:NO name:folderURL.lastPathComponent];
        // Browsing never changes the saved destination.
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeZIP] asCopy:NO];
        picker.directoryURL = folderURL;
        [strongSelf presentBackupPicker:picker purpose:ApolloBackupPickerBrowse];
    };
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    if (manager.hasSavedFolder) [manager selectedFolderURLWithCompletion:presentBrowser];
    else presentBrowser(nil, nil);
}

- (void)cleanupFolderTemplate {
    if (self.folderExportTemplateURL) {
        [NSFileManager.defaultManager removeItemAtURL:self.folderExportTemplateURL.URLByDeletingLastPathComponent error:nil];
        self.folderExportTemplateURL = nil;
    }
}

- (void)handlePickedURLs:(NSArray<NSURL *> *)urls fromPicker:(UIDocumentPickerViewController *)picker {
    if (picker != self.activePicker) return;
    ApolloBackupPickerPurpose purpose = self.pickerPurpose;
    self.activePicker = nil;
    self.pickerPurpose = ApolloBackupPickerNone;
    NSURL *url = urls.firstObject;
    if (!url) {
        self.backupAfterFolderSelection = NO;
        [self cleanupFolderTemplate];
        [picker dismissViewControllerAnimated:YES completion:^{ [self validateBackupFolder]; }];
        [self refreshBackupRows];
        return;
    }
    if (purpose == ApolloBackupPickerSelectFolder) {
        self.acceptingFolderSelection = YES;
        BOOL backupAfterSelection = self.backupAfterFolderSelection;
        self.backupAfterFolderSelection = NO;
        __weak typeof(self) weakSelf = self;
        // Capture the permission bookmark during the Files callback. Present
        // errors only after the sheet finishes dismissing.
        __block BOOL dismissed = NO;
        __block BOOL finished = NO;
        __block NSError *selectionError = nil;
        void (^finishSelection)(void) = ^{
            if (!dismissed || !finished) return;
            typeof(self) strongSelf = weakSelf;
            strongSelf.acceptingFolderSelection = NO;
            [strongSelf cleanupFolderTemplate];
            [strongSelf refreshBackupRows];
            if (selectionError) [strongSelf showFolderUnavailable:selectionError];
            else {
                [strongSelf updateFolderUnavailable:NO name:url.lastPathComponent];
                if (backupAfterSelection) [strongSelf backUpNow];
            }
        };
        [ApolloAutomaticBackup.sharedManager selectFolderURL:url completion:^(NSError *error) {
            selectionError = error;
            finished = YES;
            finishSelection();
        }];
        [picker dismissViewControllerAnimated:YES completion:^{ dismissed = YES; finishSelection(); }];
    } else {
        [picker dismissViewControllerAnimated:YES completion:^{ [self validateBackupFolder]; }];
    }
    [self refreshBackupRows];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self handlePickedURLs:urls fromPicker:controller];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self handlePickedURLs:url ? @[url] : @[] fromPicker:controller];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (controller != self.activePicker) return;
    self.activePicker = nil;
    self.pickerPurpose = ApolloBackupPickerNone;
    self.backupAfterFolderSelection = NO;
    [self cleanupFolderTemplate];
    [controller dismissViewControllerAnimated:YES completion:^{ [self validateBackupFolder]; }];
    [self refreshBackupRows];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    if (presentationController.presentedViewController == self.activePicker) {
        self.activePicker = nil;
        self.pickerPurpose = ApolloBackupPickerNone;
        self.backupAfterFolderSelection = NO;
        [self cleanupFolderTemplate];
        [self refreshBackupRows];
        [self validateBackupFolder];
    }
}

- (void)backUpNow {
    if (![self canPerformBackupAction]) return;
    ApolloAutomaticBackup *manager = ApolloAutomaticBackup.sharedManager;
    if (!manager.hasSavedFolder) {
        self.backupAfterFolderSelection = YES;
        [self chooseFilesFolder];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [manager backUpNowWithCompletion:^(NSString *filename, NSError *error) {
        if (error) {
            [weakSelf validateBackupFolder];
            [weakSelf showBackupFailureActions:error.localizedDescription];
        }
        else {
            [weakSelf updateFolderUnavailable:NO name:weakSelf.resolvedFolderName ?: manager.savedFolderName];
            NSString *message = [NSString stringWithFormat:@"Settings saved as:\n%@\n\nThis file contains your logged-in account credentials. Keep it private.", filename];
            ApolloBackupShowAlert(weakSelf, @"Backup Complete", message);
        }
    }];
}

@end
