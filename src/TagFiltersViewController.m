#import "TagFiltersViewController.h"

#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsForm.h"

NSString *const ApolloTagFiltersChangedNotification = @"ApolloTagFiltersChangedNotification";

typedef NS_ENUM(NSInteger, TagFiltersSection) {
    TagFiltersSectionGeneral = 0,    // Enable / Mode / NSFW / Spoiler
    TagFiltersSectionOverrides,      // Per-subreddit list + "Add Subreddit…"
    TagFiltersSectionCount,
};

#pragma mark - Per-subreddit detail VC

static NSString *const TagFilterRowNSFW = @"tag-filter.nsfw";
static NSString *const TagFilterRowSpoilers = @"tag-filter.spoilers";
static NSString *const TagFilterRowReset = @"tag-filter.reset";
static NSString *const TagFilterRowRemove = @"tag-filter.remove";

@interface TagFilterSubredditDetailViewController : ApolloSettingsFormViewController
@property (nonatomic, copy) NSString *subredditName;   // lowercased
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation TagFilterSubredditDetailViewController

- (instancetype)initWithSubreddit:(NSString *)subreddit {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _subredditName = [[subreddit stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"r/%@", self.subredditName];
}

- (NSDictionary *)currentOverride {
    NSDictionary *all = sTagFilterSubredditOverrides;
    NSDictionary *o = all[self.subredditName];
    return [o isKindOfClass:[NSDictionary class]] ? o : @{};
}

- (void)updateOverrideWithBlock:(void (^)(NSMutableDictionary *override))block {
    NSMutableDictionary *all =
        [(sTagFilterSubredditOverrides ?: @{}) mutableCopy];
    NSMutableDictionary *o =
        [([self currentOverride] ?: @{}) mutableCopy];

    if (block) block(o);

    // Subreddit entries are explicit overrides. Older saved entries may be
    // empty or partial; missing keys continue to follow the effective global
    // settings until the override is changed or reset.
    // Only Remove Override removes the subreddit from this list.
    all[self.subredditName] = [o copy];

    sTagFilterSubredditOverrides = [all copy];
    [[NSUserDefaults standardUserDefaults]
        setObject:sTagFilterSubredditOverrides
           forKey:UDKeyTagFilterSubredditOverrides];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloTagFiltersChangedNotification
                      object:nil];

    if (self.onChange) self.onChange();
}

- (BOOL)effectiveBoolForKey:(NSString *)key globalDefault:(BOOL)globalDefault {
    NSDictionary *o = [self currentOverride];
    id value = o[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue];
    }
    return globalDefault;
}

- (void)removeOverride {
    NSMutableDictionary *all =
        [(sTagFilterSubredditOverrides ?: @{}) mutableCopy];

    [all removeObjectForKey:self.subredditName];

    sTagFilterSubredditOverrides = [all copy];
    [[NSUserDefaults standardUserDefaults]
        setObject:sTagFilterSubredditOverrides
           forKey:UDKeyTagFilterSubredditOverrides];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloTagFiltersChangedNotification
                      object:nil];

    if (self.onChange) self.onChange();

    [self.navigationController popViewControllerAnimated:YES];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak __typeof(self) weakSelf = self;

    ApolloSettingsRow *nsfw =
        [ApolloSettingsRow switchRowWithID:TagFilterRowNSFW
                                     title:@"NSFW"
                                      isOn:^BOOL {
            return [weakSelf effectiveBoolForKey:@"nsfw"
                                   globalDefault:(sTagFilterEnabled && sTagFilterNSFW)];
        }
                                  onToggle:^(UISwitch *sender) {
            [weakSelf updateOverrideWithBlock:^(NSMutableDictionary *o) {
                o[@"nsfw"] = @(sender.isOn);
            }];
            [weakSelf reloadRowWithID:TagFilterRowReset];
        }];

    ApolloSettingsRow *spoilers =
        [ApolloSettingsRow switchRowWithID:TagFilterRowSpoilers
                                     title:@"Spoilers"
                                      isOn:^BOOL {
            return [weakSelf effectiveBoolForKey:@"spoiler"
                                   globalDefault:(sTagFilterEnabled && sTagFilterSpoiler)];
        }
                                  onToggle:^(UISwitch *sender) {
            [weakSelf updateOverrideWithBlock:^(NSMutableDictionary *o) {
                o[@"spoiler"] = @(sender.isOn);
            }];
            [weakSelf reloadRowWithID:TagFilterRowReset];
        }];

    ApolloSettingsRow *reset =
        [ApolloSettingsRow buttonRowWithID:TagFilterRowReset
                                     title:@"Reset to Global Settings"
                                    action:^{
            [weakSelf updateOverrideWithBlock:^(NSMutableDictionary *o) {
                o[@"nsfw"] = @(sTagFilterEnabled && sTagFilterNSFW);
                o[@"spoiler"] = @(sTagFilterEnabled && sTagFilterSpoiler);
            }];

            // Re-read the reset values and the Reset enabled state.
            [weakSelf reloadRowWithID:TagFilterRowNSFW];
            [weakSelf reloadRowWithID:TagFilterRowSpoilers];
            [weakSelf reloadRowWithID:TagFilterRowReset];
        }];

    reset.enabled = ^BOOL {
        NSDictionary *o = [weakSelf currentOverride];

        BOOL globalNSFW = sTagFilterEnabled && sTagFilterNSFW;
        BOOL globalSpoiler = sTagFilterEnabled && sTagFilterSpoiler;

        BOOL nsfw = [o[@"nsfw"] isKindOfClass:[NSNumber class]]
            ? [o[@"nsfw"] boolValue]
            : globalNSFW;
        BOOL spoiler = [o[@"spoiler"] isKindOfClass:[NSNumber class]]
            ? [o[@"spoiler"] boolValue]
            : globalSpoiler;

        return nsfw != globalNSFW || spoiler != globalSpoiler;
    };
    reset.configure = ^(UITableViewCell *cell) {
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
    };

    ApolloSettingsRow *remove =
        [ApolloSettingsRow customRowWithID:TagFilterRowRemove
                                      cell:^UITableViewCell *(
                                          UITableView *tableView,
                                          __unused ApolloSettingsRow *row) {
            static NSString *const reuseID = @"TagFilterRemoveOverride";
            UITableViewCell *cell =
                [tableView dequeueReusableCellWithIdentifier:reuseID];

            if (!cell) {
                cell = [[UITableViewCell alloc]
                    initWithStyle:UITableViewCellStyleDefault
                  reuseIdentifier:reuseID];
            }

            cell.textLabel.text = @"Remove Override";
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryNone;

            return cell;
        }
                                  onSelect:^{
            [weakSelf removeOverride];
        }];

    return @[
        [ApolloSettingsSection
            sectionWithTitle:@"Cover Tagged Posts"
                       footer:@"These take priority over your global settings for this subreddit."
                         rows:@[ nsfw, spoilers ]],

        [ApolloSettingsSection
            sectionWithTitle:nil
                       footer:nil
                         rows:@[ reset ]],

        [ApolloSettingsSection
            sectionWithTitle:nil
                       footer:nil
                         rows:@[ remove ]],
    ];
}

@end

#pragma mark - Main TagFiltersViewController

@interface TagFiltersViewController () <UITextFieldDelegate>
@end

@implementation TagFiltersViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.overridesOnly ? @"Customize by Subreddit" : @"Tag Filters";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}



// In overrides-only mode, an introductory section appears when the master
// switch is disabled; the remaining section contains subreddit overrides.
- (NSInteger)modelSectionFor:(NSInteger)section {
    if (self.overridesOnly) {
        return (!sTagFilterEnabled && section == 0)
            ? -1
            : TagFiltersSectionOverrides;
    }
    return section;
}

#pragma mark - Helpers

- (NSArray<NSString *> *)overrideSubreddits {
    NSDictionary *all = sTagFilterSubredditOverrides ?: @{};
    return [[all allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)postChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
}

#pragma mark - Section / row counts

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.overridesOnly
        ? (sTagFilterEnabled ? 1 : 2)
        : TagFiltersSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    section = [self modelSectionFor:section];
    if (section == TagFiltersSectionGeneral) return 3;  // Enable / NSFW / Spoiler
    if (section == TagFiltersSectionOverrides) return [self overrideSubreddits].count + 1; // + "Add"
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    section = [self modelSectionFor:section];
    if (self.overridesOnly) return nil;
    if (section == TagFiltersSectionGeneral) return @"General";
    if (section == TagFiltersSectionOverrides) return @"Per-Subreddit Overrides";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    section = [self modelSectionFor:section];
    if (section == TagFiltersSectionGeneral) {
        return @"Filtered posts are covered with a frosted blur over the post's title and thumbnail. Tap the blur to confirm and reveal the post. Brand Affiliate is unavailable because Apollo does not store that tag.";
    }
    if (section == TagFiltersSectionOverrides) {
        return nil; // supplied by viewForFooterInSection:
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForFooterInSection:(NSInteger)section {
    if (self.overridesOnly && !sTagFilterEnabled && section == 0) {
        NSString *message =
            @"Enable Cover Tagged Posts to apply customizations.";

        UIFont *font =
            ApolloSettingsFont(UIFontTextStyleBody, tableView.traitCollection);

        CGFloat width = MAX(1.0, CGRectGetWidth(tableView.bounds) - 40.0);

        CGRect bounds = [message boundingRectWithSize:
            CGSizeMake(width, CGFLOAT_MAX)
            options:NSStringDrawingUsesLineFragmentOrigin |
                    NSStringDrawingUsesFontLeading
            attributes:@{NSFontAttributeName: font}
            context:nil];

        return ceil(bounds.size.height);
    }

    return UITableViewAutomaticDimension;
}

- (UIView *)tableView:(UITableView *)tableView
    viewForFooterInSection:(NSInteger)section {
    NSInteger modelSection = [self modelSectionFor:section];
    if (self.overridesOnly && !sTagFilterEnabled && section == 0) {
        UIView *container = [[UIView alloc] init];
        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = @"Enable Cover Tagged Posts to apply customizations.";
        label.font =
            ApolloSettingsFont(UIFontTextStyleBody, label.traitCollection);
        label.adjustsFontForContentSizeCategory = NO;
        label.textColor = [UIColor secondaryLabelColor];
        label.numberOfLines = 0;

        [container addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
            [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
            [label.topAnchor constraintEqualToAnchor:container.topAnchor
                                             constant:0.0],
            [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor
                                                constant:0.0],
        ]];

        return container;
    }

    if (modelSection != TagFiltersSectionOverrides) return nil;

    UIView *container = [[UIView alloc] init];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text =
        @"Choose which tagged posts are covered in specific subreddits.";
    label.font =
        ApolloSettingsFont(UIFontTextStyleFootnote, label.traitCollection);
    label.adjustsFontForContentSizeCategory = NO;
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;

    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                            constant:20.0],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                             constant:-20.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor
                                         constant:6.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor
                                            constant:-6.0],
    ]];

    return container;
}

#pragma mark - Cells

- (UITableViewCell *)switchCellLabel:(NSString *)label on:(BOOL)on enabled:(BOOL)enabled action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.enabled = enabled;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    if (enabled) [self apollo_applyPrimaryTextColorToCell:cell];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger section = [self modelSectionFor:indexPath.section];
    if (section == TagFiltersSectionGeneral) {
        switch (indexPath.row) {
            case 0:
                return [self switchCellLabel:@"Enable Tag Filters" on:sTagFilterEnabled enabled:YES action:@selector(enableChanged:)];
            case 1: return [self switchCellLabel:@"NSFW" on:sTagFilterNSFW enabled:sTagFilterEnabled action:@selector(nsfwChanged:)];
            case 2: return [self switchCellLabel:@"Spoiler" on:sTagFilterSpoiler enabled:sTagFilterEnabled action:@selector(spoilerChanged:)];
        }
    }

    if (section == TagFiltersSectionOverrides) {
        NSArray<NSString *> *subs = [self overrideSubreddits];
        if ((NSUInteger)indexPath.row < subs.count) {
            NSString *sub = subs[indexPath.row];
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            cell.textLabel.text = [NSString stringWithFormat:@"r/%@", sub];
            cell.detailTextLabel.text = [self summaryForOverride:sub];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            [self apollo_applyPrimaryTextColorToCell:cell];
            return cell;
        }
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Add Subreddit…";
        [self apollo_applyAccentActionTextColorToCell:cell];
        return cell;
    }

    return [[UITableViewCell alloc] init];
}

- (NSString *)summaryForOverride:(NSString *)sub {
    NSDictionary *o = sTagFilterSubredditOverrides[sub];
    if (![o isKindOfClass:[NSDictionary class]]) o = @{};

    BOOL nsfw = [o[@"nsfw"] isKindOfClass:[NSNumber class]]
        ? [o[@"nsfw"] boolValue]
        : sTagFilterNSFW;

    BOOL spoiler = [o[@"spoiler"] isKindOfClass:[NSNumber class]]
        ? [o[@"spoiler"] boolValue]
        : sTagFilterSpoiler;

    NSString *summary;
    if (nsfw == spoiler) {
        summary = nsfw
            ? @"Cover NSFW and spoilers"
            : @"Show NSFW and spoilers";
    } else {
        summary = [NSString stringWithFormat:@"%@ NSFW · %@ spoilers",
            nsfw ? @"Cover" : @"Show",
            spoiler ? @"Cover" : @"Show"];
    }

    return summary;
}

#pragma mark - Switch handlers

- (void)enableChanged:(UISwitch *)sw {
    sTagFilterEnabled = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterEnabled];
    [self postChange];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:TagFiltersSectionGeneral] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)nsfwChanged:(UISwitch *)sw {
    sTagFilterNSFW = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterNSFW];
    [self postChange];
}

- (void)spoilerChanged:(UISwitch *)sw {
    sTagFilterSpoiler = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterSpoiler];
    [self postChange];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if ([self modelSectionFor:indexPath.section] == TagFiltersSectionOverrides) {
        NSArray<NSString *> *subs = [self overrideSubreddits];
        if ((NSUInteger)indexPath.row < subs.count) {
            TagFilterSubredditDetailViewController *detail = [[TagFilterSubredditDetailViewController alloc] initWithSubreddit:subs[indexPath.row]];
            [self.navigationController pushViewController:detail animated:YES];
        } else {
            [self presentAddSubredditPrompt];
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self modelSectionFor:indexPath.section] != TagFiltersSectionOverrides) return NO;
    return (NSUInteger)indexPath.row < [self overrideSubreddits].count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSArray<NSString *> *subs = [self overrideSubreddits];
    if ((NSUInteger)indexPath.row >= subs.count) return;
    NSString *sub = subs[indexPath.row];
    NSMutableDictionary *all = [(sTagFilterSubredditOverrides ?: @{}) mutableCopy];
    [all removeObjectForKey:sub];
    sTagFilterSubredditOverrides = [all copy];
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:UDKeyTagFilterSubredditOverrides];
    [self postChange];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)presentAddSubredditPrompt {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Subreddit"
                                                                   message:@"Enter the name of the subreddit you want to customize. Then choose which tagged posts are covered."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Subreddit name";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIAlertAction *addAction =
        [UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UITextField *tf = weakAlert.textFields.firstObject;
        NSString *raw = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([raw hasPrefix:@"/"]) raw = [raw substringFromIndex:1];
        if ([raw hasPrefix:@"r/"] || [raw hasPrefix:@"R/"]) raw = [raw substringFromIndex:2];
        NSString *sub = raw.lowercaseString;
        if (sub.length == 0) return;
        NSMutableDictionary *all = [(sTagFilterSubredditOverrides ?: @{}) mutableCopy];
        if (!all[sub]) {
            all[sub] = @{
                @"nsfw": @YES,
                @"spoiler": @YES,
            };
        }
        sTagFilterSubredditOverrides = [all copy];
        [[NSUserDefaults standardUserDefaults] setObject:all forKey:UDKeyTagFilterSubredditOverrides];
        [self postChange];
        [self.tableView reloadData];
        TagFilterSubredditDetailViewController *detail = [[TagFilterSubredditDetailViewController alloc] initWithSubreddit:sub];
        __weak typeof(self) wself = self;
        detail.onChange = ^{ [wself.tableView reloadData]; };
        [self.navigationController pushViewController:detail animated:YES];
    }];

    addAction.enabled = NO;
    [alert addAction:addAction];
    alert.preferredAction = addAction;

    UITextField *field = alert.textFields.firstObject;
    [field addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        NSString *text = ((UITextField *)action.sender).text ?: @"";
        addAction.enabled =
            [text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0;
    }] forControlEvents:UIControlEventEditingChanged];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
