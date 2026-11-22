#import "ApolloOfflineModeSettingsViewController.h"
#import "ApolloCommon.h"
#import "ApolloOfflineMode.h"
#import "UserDefaultConstants.h"

typedef NS_ENUM(NSInteger, ApolloOfflineSection) {
    ApolloOfflineSectionLibrary = 0,
    ApolloOfflineSectionUse,
    ApolloOfflineSectionAutomatic,
    ApolloOfflineSectionFeeds,
    ApolloOfflineSectionContent,
};

typedef NS_ENUM(NSInteger, ApolloOfflineLibraryRow) {
    ApolloOfflineLibraryRowStatus = 0,
    ApolloOfflineLibraryRowDownload,
    ApolloOfflineLibraryRowDelete,
};

typedef NS_ENUM(NSInteger, ApolloOfflineFeedRow) {
    ApolloOfflineFeedRowSaved = 0,
    ApolloOfflineFeedRowHome,
    ApolloOfflineFeedRowPopular,
    ApolloOfflineFeedRowSubreddits,
};

typedef NS_ENUM(NSInteger, ApolloOfflineContentRow) {
    ApolloOfflineContentRowComments = 0,
    ApolloOfflineContentRowImages,
    ApolloOfflineContentRowVideos,
    ApolloOfflineContentRowPages,
    ApolloOfflineContentRowSkipRead,
    ApolloOfflineContentRowBudget,
};

static NSArray<NSNumber *> *ApolloOfflineBudgetChoicesMB(void) {
    return @[ @25, @50, @100, @250, @500, @1000 ];
}

static NSString *ApolloOfflineBudgetText(NSInteger mb) {
    return mb >= 1000 ? [NSString stringWithFormat:@"%.0f GB", mb / 1000.0] : [NSString stringWithFormat:@"%ld MB", (long)mb];
}

@interface ApolloOfflineModeSettingsViewController ()
// The connection line last shown under Use Offline Library.
@property (nonatomic, copy) NSString *shownConnectionStatus;
@end

@implementation ApolloOfflineModeSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Offline Mode";
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(offlineStateChanged:)
                                               name:ApolloOfflineModeDidChangeNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)offlineStateChanged:(__unused NSNotification *)note {
    // Progress ticks often; refresh just the library rows' text in place, and
    // the "Online now." line under Use Offline Library when the connection
    // (or whether the library is showing) changed.
    if (!self.isViewLoaded || !self.view.window) return;
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:ApolloOfflineSectionLibrary];
    NSString *status = [self connectionStatusText];
    if (![status isEqualToString:self.shownConnectionStatus]) [sections addIndex:ApolloOfflineSectionUse];
    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (NSString *)connectionStatusText {
    ApolloOfflineModeController *controller = self.controller;
    return controller.serving ? @"Showing your offline library now."
         : (controller.networkAvailable ? @"Online now." : @"No connection right now.");
}

- (ApolloOfflineModeController *)controller {
    return [ApolloOfflineModeController sharedController];
}

- (NSUserDefaults *)defaults {
    return NSUserDefaults.standardUserDefaults;
}

- (NSArray<NSString *> *)subreddits {
    id value = [self.defaults objectForKey:UDKeyOfflineSubreddits];
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

#pragma mark - Structure

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == ApolloOfflineSectionLibrary) {
        // Delete only appears once there's something to delete.
        BOOL canDelete = [ApolloOfflineLibrary sharedLibrary].hasContent && !self.controller.downloading;
        return canDelete ? 3 : 2;
    }
    if (section == ApolloOfflineSectionAutomatic) return 2;
    if (section == ApolloOfflineSectionContent) return 6;
    if (section == ApolloOfflineSectionFeeds) return 4;
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloOfflineSectionLibrary: return @"Offline Library";
        case ApolloOfflineSectionUse: return @"Use Offline Library";
        case ApolloOfflineSectionAutomatic: return @"Automatic";
        case ApolloOfflineSectionFeeds: return @"Feeds to Download";
        case ApolloOfflineSectionContent: return @"Download Options";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    ApolloOfflineModeController *controller = self.controller;
    switch (section) {
        case ApolloOfflineSectionLibrary:
            return @"Download a batch of posts while you have a connection, then scroll it on a flight or "
                    "anywhere without signal. Each download replaces the last one. Keep Apollo open until it "
                    "finishes. Videos play offline with sound in the same player as always, and links to articles "
                    "open the saved page.";
        case ApolloOfflineSectionUse: {
            NSString *now = [self connectionStatusText];
            self.shownConnectionStatus = now;
            return [NSString stringWithFormat:@"Automatic uses the library only when you have no connection. "
                    "Always shows it even online, which helps on plane Wi-Fi that's connected but doesn't load "
                    "anything. Anything you didn't download loads from the internet as usual.\n\n%@", now];
        }
        case ApolloOfflineSectionAutomatic:
            return [NSString stringWithFormat:@"While Apollo is open, your offline posts top themselves up: a fresh "
                    "batch every hour, or sooner once you've read half of them. Wi-Fi only, unless you turn on Use "
                    "Cellular Data. On cellular each batch can use up to your data limit (%@), so it counts against "
                    "your plan. Never in Low Power Mode or Low Data Mode, and only after you've downloaded once "
                    "yourself. Download Now works on any connection.",
                    ApolloOfflineBudgetText((NSInteger)(controller.budgetBytes / (1000 * 1000)))];
        case ApolloOfflineSectionFeeds:
            return @"Saved Posts works as your offline archive: save a post in Apollo (swipe or the post menu) and "
                    "every download keeps it, with its comments, images and video, even after you've read it. "
                    "Unsave it to let it go. Offline, each feed shows the posts that were downloaded, whatever "
                    "sort you pick.";
        case ApolloOfflineSectionContent:
            return @"Skipping read posts means a new batch is all posts you haven't seen. The download stops once "
                    "it reaches the data limit. Images are saved at your screen's size, along with the profile pictures of the people in each thread. Videos from Reddit, imgur, "
                    "Streamable and RedGIFs are saved at up to 720p with sound (over 5 minutes are skipped); they "
                    "use the most data, so turn Videos off to fit more posts in the same limit. Linked Web Pages "
                    "keeps the article behind each link post, so it opens offline too.";
    }
    return nil;
}

#pragma mark - Cells

- (UITableViewCell *)valueCellWithTitle:(NSString *)title detail:(NSString *)detail {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    [self apollo_applyPrimaryTextColorToCell:cell];
    return cell;
}

- (UITableViewCell *)switchCellWithTitle:(NSString *)title key:(NSString *)key {
    UITableViewCell *cell = [self valueCellWithTitle:title detail:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [UISwitch new];
    toggle.on = [self.defaults boolForKey:key];
    toggle.accessibilityIdentifier = key;
    toggle.accessibilityLabel = title;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloOfflineModeController *controller = self.controller;
    switch (indexPath.section) {
        case ApolloOfflineSectionLibrary: {
            if (indexPath.row == ApolloOfflineLibraryRowStatus) {
                // What's saved on the first line; roughly how long it lasts and
                // when it was fetched on the second.
                NSArray<NSString *> *lines = [[controller librarySummary] componentsSeparatedByString:@"\n"];
                UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
                cell.textLabel.text = lines.firstObject;
                cell.detailTextLabel.text = lines.count > 1 ? lines[1] : nil;
                cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
                cell.detailTextLabel.numberOfLines = 0;
                [self apollo_applyPrimaryTextColorToCell:cell];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                return cell;
            }
            if (indexPath.row == ApolloOfflineLibraryRowDownload) {
                UITableViewCell *cell;
                if (controller.downloading) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
                    cell.textLabel.text = controller.downloadingAutomatically ? @"Cancel Automatic Refresh" : @"Cancel Download";
                    cell.detailTextLabel.text = controller.progressText;
                    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
                    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                    [spinner startAnimating];
                    cell.accessoryView = spinner;
                } else {
                    cell = [self valueCellWithTitle:@"Download Now" detail:ApolloOfflineBudgetText((NSInteger)(controller.budgetBytes / (1000 * 1000)))];
                }
                [self apollo_applyAccentActionTextColorToCell:cell];
                return cell;
            }
            UITableViewCell *cell = [self valueCellWithTitle:@"Delete Offline Library" detail:nil];
            cell.textLabel.textColor = UIColor.systemRedColor;
            return cell;
        }
        case ApolloOfflineSectionUse: {
            NSArray *titles = @[ @"Automatic", @"Always", @"Never" ];
            UITableViewCell *cell = [self valueCellWithTitle:titles[indexPath.row] detail:nil];
            cell.accessoryType = (NSInteger)controller.useMode == indexPath.row ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            return cell;
        }
        case ApolloOfflineSectionAutomatic: {
            if (indexPath.row == 0) return [self switchCellWithTitle:@"Keep Fresh" key:UDKeyOfflineAutoRefresh];
            // Only matters while Keep Fresh is on.
            UITableViewCell *cell = [self switchCellWithTitle:@"Use Cellular Data" key:UDKeyOfflineAutoRefreshCellular];
            BOOL keepFresh = [self.defaults boolForKey:UDKeyOfflineAutoRefresh];
            ((UISwitch *)cell.accessoryView).enabled = keepFresh;
            cell.textLabel.enabled = keepFresh;
            return cell;
        }
        case ApolloOfflineSectionFeeds: {
            if (indexPath.row == ApolloOfflineFeedRowSaved) return [self switchCellWithTitle:@"Saved Posts" key:UDKeyOfflineIncludeSaved];
            if (indexPath.row == ApolloOfflineFeedRowHome) return [self switchCellWithTitle:@"Home" key:UDKeyOfflineIncludeHome];
            if (indexPath.row == ApolloOfflineFeedRowPopular) return [self switchCellWithTitle:@"Popular" key:UDKeyOfflineIncludePopular];
            NSArray *subs = [self subreddits];
            NSString *detail = subs.count == 0 ? @"None" : [subs componentsJoinedByString:@", "];
            UITableViewCell *cell = [self valueCellWithTitle:@"Subreddits" detail:detail];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case ApolloOfflineSectionContent: {
            if (indexPath.row == ApolloOfflineContentRowComments) return [self switchCellWithTitle:@"Comments" key:UDKeyOfflineIncludeComments];
            if (indexPath.row == ApolloOfflineContentRowImages) return [self switchCellWithTitle:@"Images" key:UDKeyOfflineIncludeImages];
            if (indexPath.row == ApolloOfflineContentRowVideos) return [self switchCellWithTitle:@"Videos" key:UDKeyOfflineIncludeVideos];
            if (indexPath.row == ApolloOfflineContentRowPages) return [self switchCellWithTitle:@"Linked Web Pages" key:UDKeyOfflineIncludePages];
            if (indexPath.row == ApolloOfflineContentRowSkipRead) return [self switchCellWithTitle:@"Skip Posts I've Read" key:UDKeyOfflineSkipRead];
            UITableViewCell *cell = [self valueCellWithTitle:@"Data Limit"
                                                      detail:ApolloOfflineBudgetText((NSInteger)(controller.budgetBytes / (1000 * 1000)))];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
    }
    return [UITableViewCell new];
}

#pragma mark - Actions

- (void)switchChanged:(UISwitch *)toggle {
    NSString *key = toggle.accessibilityIdentifier;
    [self.defaults setBool:toggle.on forKey:key];
    if ([key isEqualToString:UDKeyOfflineAutoRefresh] || [key isEqualToString:UDKeyOfflineAutoRefreshCellular]) {
        if ([key isEqualToString:UDKeyOfflineAutoRefresh]) {
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloOfflineSectionAutomatic]
                          withRowAnimation:UITableViewRowAnimationNone];
        }
        [self.controller stopKeepFreshIfNotAllowed:@"setting"];
        [self.controller considerKeepFresh:@"setting"];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    ApolloOfflineModeController *controller = self.controller;
    switch (indexPath.section) {
        case ApolloOfflineSectionLibrary:
            if (indexPath.row == ApolloOfflineLibraryRowDownload) {
                if (controller.downloading) [controller cancelDownload];
                else [self startDownload];
            } else if (indexPath.row == ApolloOfflineLibraryRowDelete) {
                [self confirmDeleteFromCell:cell];
            }
            break;
        case ApolloOfflineSectionUse:
            [controller setUseMode:(ApolloOfflineUseMode)indexPath.row];
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloOfflineSectionUse] withRowAnimation:UITableViewRowAnimationNone];
            break;
        case ApolloOfflineSectionFeeds:
            if (indexPath.row == ApolloOfflineFeedRowSubreddits) [self editSubreddits];
            break;
        case ApolloOfflineSectionContent:
            if (indexPath.row == ApolloOfflineContentRowBudget) [self chooseBudgetFromCell:cell];
            break;
    }
}

- (void)startDownload {
    __weak typeof(self) weakSelf = self;
    [self.controller startDownloadWithCompletion:^(BOOL success, NSString *message) {
        ApolloOfflineModeSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.tableView reloadData];
        // A cancel the user asked for needs no alert.
        if (!success && [message isEqualToString:@"Download cancelled."]) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:success ? @"Ready for Offline" : @"Download Didn't Finish"
                                                                       message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        if (strongSelf.view.window) [strongSelf presentViewController:alert animated:YES completion:nil];
    }];
    [self.tableView reloadData];
}

- (void)presentSheet:(UIAlertController *)sheet fromCell:(UITableViewCell *)cell {
    UIView *anchor = cell ?: self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmDeleteFromCell:(UITableViewCell *)cell {
    if (![ApolloOfflineLibrary sharedLibrary].hasContent || self.controller.downloading) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
        message:@"Delete the downloaded posts, comments and images?" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete Offline Library" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf.controller deleteLibrary];
        [weakSelf.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet fromCell:cell];
}

- (void)chooseBudgetFromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Data Limit"
        message:@"The most one download can use. Comments are small; images take most of it."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    NSInteger current = (NSInteger)(self.controller.budgetBytes / (1000 * 1000));
    for (NSNumber *mb in ApolloOfflineBudgetChoicesMB()) {
        NSString *title = ApolloOfflineBudgetText(mb.integerValue);
        if (mb.integerValue == current) title = [title stringByAppendingString:@" (Current)"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf.defaults setInteger:mb.integerValue forKey:UDKeyOfflineBudgetMB];
            [weakSelf.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet fromCell:cell];
}

- (void)editSubreddits {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Subreddits"
        message:@"Subreddits to download too, separated by commas (up to 10)." preferredStyle:UIAlertControllerStyleAlert];
    NSString *existing = [[self subreddits] componentsJoinedByString:@", "];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"pics, aviation, AskReddit";
        field.text = existing;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = weakAlert.textFields.firstObject.text ?: @"";
        NSMutableArray<NSString *> *subs = [NSMutableArray array];
        NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@", \n"];
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
        for (NSString *raw in [text componentsSeparatedByCharactersInSet:separators]) {
            NSString *name = raw;
            if ([name.lowercaseString hasPrefix:@"/r/"]) name = [name substringFromIndex:3];
            else if ([name.lowercaseString hasPrefix:@"r/"]) name = [name substringFromIndex:2];
            if (name.length == 0 || name.length > 21) continue;
            if ([name rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) continue;
            if (![subs containsObject:name] && subs.count < 10) [subs addObject:name];
        }
        [weakSelf.defaults setObject:subs forKey:UDKeyOfflineSubreddits];
        [weakSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
