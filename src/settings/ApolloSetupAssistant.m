#import "settings/ApolloSetupAssistant.h"
#import "settings/ApolloSetupPreset.h"
#import "settings/ApolloBackupDocument.h"
#import "settings/ApolloAutomaticBackupViewController.h"
#import "settings/CustomAPIViewController.h"
#import "ApolloAccountCredentials.h"
#import "ApolloAppIcon.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloUpdateManifest.h"
#import "ApolloUsageHeartbeat.h"
#import "ApolloWebSessionStore.h"
#import "ApolloWebSessionLoginViewController.h"
#import "UserDefaultConstants.h"
#import "../Version.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdlib.h>

static NSString *const kSetupGroup = @"group.com.christianselig.apollo";
static __weak UINavigationController *sSetupNavigation;
static BOOL sSetupPresentationPending;

// +load precedes all Logos constructors, including the sideload-unlock writes.
// Only the lifecycle stamp is written here; no user settings are applied.
@interface ApolloSetupBootstrap : NSObject
@end
@implementation ApolloSetupBootstrap
+ (void)load {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!bundleID.length) return;
        NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kSetupGroup];
        ApolloSetupState state = ApolloSetupInitialState(
            [defaults persistentDomainForName:bundleID] ?: @{},
            [group persistentDomainForName:kSetupGroup] ?: @{});
        [defaults setInteger:state forKey:UDKeySetupAssistantState];
    }
}
@end

BOOL ApolloSetupAssistantBlocksLaunchPrompts(void) {
    return [NSUserDefaults.standardUserDefaults integerForKey:UDKeySetupAssistantState] == ApolloSetupStatePending ||
        sSetupNavigation != nil || sSetupPresentationPending;
}

@interface ApolloSetupDraft : NSObject
@property (nonatomic, copy) NSString *presetIdentifier;
@property (nonatomic) ApolloSetupAppearance appearance;
@property (nonatomic) BOOL glass;
@property (nonatomic) BOOL installCount;
@property (nonatomic) BOOL crashCapture;
@property (nonatomic) BOOL firstRun;
@end
@implementation ApolloSetupDraft
@end

static UILabel *ApolloSetupLabel(NSString *text, UIFontTextStyle style, UIColor *color, UITraitCollection *traits) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = ApolloSettingsFont(style, traits);
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

// These cells use Auto Layout's self sizing and semantic fonts; no frame/index
// arithmetic in the assistant. Rebuild their content only when a draft changes.
static UITableViewCell *ApolloSetupStackCell(UIStackView *stack) {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-18],
    ]];
    return cell;
}

static UIStackView *ApolloSetupStack(NSArray<UIView *> *views, CGFloat spacing) {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = spacing;
    return stack;
}

static UIView *ApolloSetupPreviewChrome(UIStackView *content, BOOL glass) {
    UIView *surface = glass ? [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]] : [UIView new];
    if (!glass) surface.backgroundColor = UIColor.secondarySystemBackgroundColor;
    surface.layer.cornerRadius = glass ? 20 : 4;
    surface.clipsToBounds = YES;
    UIView *container = glass ? ((UIVisualEffectView *)surface).contentView : surface;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-14],
        [content.topAnchor constraintEqualToAnchor:container.topAnchor constant:10],
        [content.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10],
    ]];
    return surface;
}

@interface ApolloSetupAssistantViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) ApolloSetupDraft *draft;
@property (nonatomic) NSInteger step;
@property (nonatomic) BOOL showingDetails;
@property (nonatomic) BOOL showingPrivacy;
@property (nonatomic) BOOL finished;
@property (nonatomic, strong) UIView *actionBar;
@property (nonatomic, strong) UIButton *continueButton;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) NSLayoutConstraint *actionBarHeight;
- (instancetype)initWithDraft:(ApolloSetupDraft *)draft step:(NSInteger)step;
@end

@implementation ApolloSetupAssistantViewController

- (instancetype)init {
    ApolloSetupDraft *draft = [ApolloSetupDraft new];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    draft.firstRun = [defaults integerForKey:UDKeySetupAssistantState] == ApolloSetupStatePending;
    draft.presetIdentifier = draft.firstRun ? @"balanced" : nil;
    draft.appearance = draft.firstRun ? ApolloSetupAppearanceSystem : ApolloSetupAppearanceUnchanged;
    draft.glass = [defaults boolForKey:UDKeyLiquidGlassEnabled];
    draft.installCount = !ApolloUsageHeartbeatIsDisabled();
    draft.crashCapture = [defaults boolForKey:UDKeyCrashCaptureEnabled];
    return [self initWithDraft:draft step:0];
}

- (instancetype)initWithDraft:(ApolloSetupDraft *)draft step:(NSInteger)step {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _draft = draft;
        _step = step;
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Setup Assistant";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:self.draft.firstRun ? @"Skip" : @"Cancel" style:UIBarButtonItemStylePlain
        target:self action:@selector(skipSetup)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 100;
    [self buildActionBar];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // A settings route pushes the assistant; the first-launch coordinator
    // presents it. Both keep automatic prompts out until it leaves the stack.
    sSetupNavigation = self.navigationController;
    [self.navigationController setToolbarHidden:YES animated:NO];
    [self updateActionBar];
}

- (void)buildActionBar {
    // Own this small surface instead of UINavigationController's floating
    // toolbar: form-sheet toolbars are hosted outside the controller on iOS 26+.
    // The frame guide pins it to the viewport while all form rows remain data.
    self.actionBar = [UIView new];
    self.actionBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView addSubview:self.actionBar];
    UILabel *progress = ApolloSetupLabel([NSString stringWithFormat:@"%ld of 4", (long)self.step + 1],
        UIFontTextStyleSubheadline, ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor, self.traitCollection);
    self.progressLabel = progress;
    progress.accessibilityLabel = [NSString stringWithFormat:@"Step %ld of 4", (long)self.step + 1];
    self.continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.continueButton setTitle:self.step == 3 ? @"Finish" : @"Continue" forState:UIControlStateNormal];
    self.continueButton.layer.cornerRadius = 22;
    [self.continueButton addTarget:self action:@selector(continueSetup) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[progress, self.continueButton]];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.distribution = UIStackViewDistributionEqualSpacing;
    controls.alignment = UIStackViewAlignmentCenter;
    controls.spacing = 20;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [self.actionBar addSubview:controls];
    self.actionBarHeight = [self.actionBar.heightAnchor constraintEqualToConstant:68];
    [NSLayoutConstraint activateConstraints:@[
        [self.actionBar.leadingAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.leadingAnchor],
        [self.actionBar.trailingAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.trailingAnchor],
        [self.actionBar.bottomAnchor constraintEqualToAnchor:self.tableView.frameLayoutGuide.bottomAnchor],
        self.actionBarHeight,
        [controls.leadingAnchor constraintEqualToAnchor:self.actionBar.safeAreaLayoutGuide.leadingAnchor constant:20],
        [controls.trailingAnchor constraintEqualToAnchor:self.actionBar.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [controls.topAnchor constraintEqualToAnchor:self.actionBar.topAnchor constant:12],
        [self.continueButton.widthAnchor constraintGreaterThanOrEqualToConstant:112],
        [self.continueButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    [self updateActionBar];
}

- (void)updateActionBar {
    if (!self.actionBar) return;
    UIFont *font = ApolloSettingsFont(UIFontTextStyleHeadline, self.traitCollection);
    self.progressLabel.font = ApolloSettingsFont(UIFontTextStyleSubheadline, self.traitCollection);
    self.progressLabel.textColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    self.continueButton.titleLabel.font = font;
    CGFloat controlsHeight = MAX(44, font.lineHeight + 16) + 24;
    self.actionBarHeight.constant = controlsHeight + self.view.safeAreaInsets.bottom;
    UIEdgeInsets inset = self.tableView.contentInset;
    inset.bottom = controlsHeight;
    self.tableView.contentInset = inset;
    self.tableView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(0, 0, controlsHeight, 0);
    self.actionBar.backgroundColor = self.tableView.backgroundColor ?: UIColor.systemGroupedBackgroundColor;
    UIColor *accent = ApolloThemeAccentColor() ?: self.view.tintColor ?: UIColor.systemBlueColor;
    self.continueButton.backgroundColor = accent;
    UIColor *resolved = [accent resolvedColorWithTraitCollection:self.view.traitCollection];
    [self.continueButton setTitleColor:ApolloColorIsLight(resolved) ? UIColor.blackColor : UIColor.whiteColor
                            forState:UIControlStateNormal];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateActionBar];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self updateActionBar];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tableView bringSubviewToFront:self.actionBar];
    // Update an account status in place after OAuth/credential setup. Reloading
    // in viewWillAppear breaks cancelled interactive pop scroll restoration.
    UITableViewCell *status = [self cellForRowID:@"setup.accountStatus"];
    status.detailTextLabel.text = [self accountSummary];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    UINavigationController *nav = self.navigationController ?: sSetupNavigation;
    BOOL hasAssistant = NO;
    for (UIViewController *controller in nav.viewControllers) {
        if ([controller isKindOfClass:ApolloSetupAssistantViewController.class]) hasAssistant = YES;
    }
    if (!hasAssistant || nav.isBeingDismissed) {
        [nav setToolbarHidden:YES animated:NO];
        if (sSetupNavigation == nav) sSetupNavigation = nil;
    }
}

- (NSString *)accountSummary {
    NSString *username = ApolloActiveAccountUsername();
    if (username.length) return [@"Signed in as u/" stringByAppendingString:username];
    if (ApolloWebSessionUsernames().count) return @"Reddit sign-in saved; reopen Apollo to activate";
    if ([NSUserDefaults.standardUserDefaults stringForKey:UDKeyRedditClientId].length) return @"API key saved; ready to sign in";
    return @"You can set this up later in Accounts & API Keys";
}

- (ApolloSettingsRow *)heroRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    __weak typeof(self) weakSelf = self;
    return [ApolloSettingsRow customRowWithID:@"setup.hero"
        cell:^UITableViewCell *(__unused UITableView *table, __unused ApolloSettingsRow *row) {
            typeof(self) host = weakSelf;
            UIColor *text = ApolloSettingsPrimaryTextColor();
            UILabel *heading = ApolloSetupLabel(title, UIFontTextStyleTitle1, text, host.traitCollection);
            heading.accessibilityTraits |= UIAccessibilityTraitHeader;
            UILabel *body = ApolloSetupLabel(subtitle, UIFontTextStyleBody,
                ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor, host.traitCollection);
            UIStackView *stack = ApolloSetupStack(@[heading, body], 8);
            if (host.step == 0) {
                UIImageView *icon = [[UIImageView alloc] initWithImage:ApolloCurrentAppIcon()];
                icon.contentMode = UIViewContentModeScaleAspectFit;
                [icon.heightAnchor constraintEqualToConstant:64].active = YES;
                [stack insertArrangedSubview:icon atIndex:0];
                [stack setCustomSpacing:18 afterView:icon];
            }
            UITableViewCell *cell = ApolloSetupStackCell(stack);
            [host apollo_applyPrimaryTextColorToCell:cell];
            return cell;
        } onSelect:nil];
}

- (ApolloSettingsRow *)choiceRowWithID:(NSString *)rowID title:(NSString *)title
                            subtitle:(NSString *)subtitle selected:(BOOL (^)(void))selected
                              action:(void (^)(void))action {
    __weak typeof(self) weakSelf = self;
    return [ApolloSettingsRow customRowWithID:rowID
        cell:^UITableViewCell *(__unused UITableView *table, __unused ApolloSettingsRow *row) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            cell.textLabel.text = title;
            cell.textLabel.numberOfLines = 0;
            cell.detailTextLabel.text = subtitle;
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
            cell.accessoryType = selected && selected() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            cell.selectionStyle = action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
            cell.accessibilityTraits = (action ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText) |
                (selected && selected() ? UIAccessibilityTraitSelected : 0);
            [weakSelf apollo_applyPrimaryTextColorToCell:cell];
            return cell;
        } onSelect:action];
}

- (ApolloSettingsRow *)previewRow {
    __weak typeof(self) weakSelf = self;
    return [ApolloSettingsRow customRowWithID:@"setup.preview"
        cell:^UITableViewCell *(__unused UITableView *table, __unused ApolloSettingsRow *row) {
            typeof(self) host = weakSelf;
            ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:host.draft.presetIdentifier];
            NSDictionary *values = preset.values ?: NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
            BOOL inlineImages = [values[UDKeyEnableInlineImages] boolValue];
            BOOL avatars = [values[UDKeyShowUserAvatars] boolValue];
            BOOL gallery = [values[UDKeyFeedGalleryCarousel] boolValue];
            UIColor *accent = ApolloThemeAccentColor() ?: host.view.tintColor ?: UIColor.systemBlueColor;
            UIColor *text = ApolloSettingsPrimaryTextColor();
            UIColor *secondary = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
            UILabel *caption = ApolloSetupLabel(@"SAMPLE POST & COMMENT", UIFontTextStyleCaption2, secondary, host.traitCollection);
            UILabel *community = ApolloSetupLabel(@"r/photography", UIFontTextStyleSubheadline, accent, host.traitCollection);
            UILabel *title = ApolloSetupLabel(@"A little escape for the weekend", UIFontTextStyleHeadline, text, host.traitCollection);
            NSString *path = ApolloBundledResourcePath(@"ApolloRebornPreviewBanner", @"jpg");
            UIImageView *photo = [[UIImageView alloc] initWithImage:path ? [UIImage imageWithContentsOfFile:path] : nil];
            photo.contentMode = UIViewContentModeScaleAspectFill;
            photo.clipsToBounds = YES;
            photo.layer.cornerRadius = 10;
            [photo.heightAnchor constraintEqualToConstant:94].active = YES;
            UILabel *galleryLabel = ApolloSetupLabel(gallery ? @"●  ○  ○    Swipe through 3 photos" : @"3 photos · Tap to open",
                UIFontTextStyleCaption1, secondary, host.traitCollection);
            UILabel *info = ApolloSetupLabel(@"↑ 128     ◇ 24 comments", UIFontTextStyleCaption1, secondary, host.traitCollection);
            UILabel *author = ApolloSetupLabel(avatars ? @"◉  weekendexplorer · 2h" : @"weekendexplorer · 2h",
                UIFontTextStyleCaption1, secondary, host.traitCollection);
            UILabel *comment = ApolloSetupLabel(@"What a view! Here’s another angle.", UIFontTextStyleBody, text, host.traitCollection);
            UIStackView *stack = ApolloSetupStack(@[caption, community, title, photo, galleryLabel, info, author, comment], 8);
            if (inlineImages) {
                UIImageView *inlinePhoto = [[UIImageView alloc] initWithImage:photo.image];
                inlinePhoto.contentMode = UIViewContentModeScaleAspectFill;
                inlinePhoto.clipsToBounds = YES;
                inlinePhoto.layer.cornerRadius = 8;
                [inlinePhoto.heightAnchor constraintEqualToConstant:60].active = YES;
                [stack addArrangedSubview:inlinePhoto];
            } else {
                [stack addArrangedSubview:ApolloSetupLabel(@"View image", UIFontTextStyleBody, accent, host.traitCollection)];
            }
            NSInteger links = [values[UDKeyLinkPreviewCommentsMode] integerValue];
            UILabel *link = ApolloSetupLabel(links == 0 ? @"example.com/weekend" : @"↗  Weekend walks · example.com",
                UIFontTextStyleSubheadline, accent, host.traitCollection);
            [stack addArrangedSubview:link];
            if (links == 2) [stack addArrangedSubview:ApolloSetupLabel(@"A collection of favourite routes and places to explore.",
                UIFontTextStyleFootnote, secondary, host.traitCollection)];
            UITableViewCell *cell = ApolloSetupStackCell(stack);
            [host apollo_applyPrimaryTextColorToCell:cell];
            cell.userInteractionEnabled = NO;
            return cell;
        } onSelect:nil];
}

- (NSArray<ApolloSettingsSection *> *)buildForm {
    switch (self.step) {
        case 0: return [self welcomeForm];
        case 1: return [self presetForm];
        case 2: return [self appearanceForm];
        default: return [self finishForm];
    }
}

- (NSArray<ApolloSettingsSection *> *)welcomeForm {
    __weak typeof(self) weakSelf = self;
    ApolloSettingsRow *status = [ApolloSettingsRow valueRowWithID:@"setup.accountStatus" title:@"Reddit Account"
        detail:^NSString *{ return [weakSelf accountSummary]; } onSelect:nil];
    status.configure = ^(UITableViewCell *cell) {
        cell.detailTextLabel.numberOfLines = 0;
    };
    ApolloSettingsRow *signIn = [ApolloSettingsRow buttonRowWithID:@"setup.signIn" title:@"Set Up Reddit"
        action:^{
            ApolloWebSessionPresentSignInChooser(weakSelf, ^{
                ApolloSetupAPIKeyViewController *keys = [[ApolloSetupAPIKeyViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
                [weakSelf.navigationController pushViewController:keys animated:YES];
            });
        }];
    ApolloSettingsRow *restore = [ApolloSettingsRow buttonRowWithID:@"setup.restore" title:@"Restore an Apollo Backup"
        action:^{ [weakSelf restoreBackup]; }];
    return @[
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[
            [self heroRowWithTitle:@"Welcome to Apollo Reborn"
                         subtitle:@"Choose a starting point and make Apollo yours. Everything can be customised later."]]],
        [ApolloSettingsSection sectionWithTitle:@"Get Connected"
            footer:@"Use a Reddit API key, or choose experimental sign-in without one. Optional upload and GIF keys can be added later. Continue to set up your preferences even if you’re not ready to sign in."
            rows:@[status, signIn]],
        [ApolloSettingsSection sectionWithTitle:@"Already Used Apollo?"
            footer:@"A backup restores your settings and saved accounts. You’ll keep that setup and skip the remaining choices."
            rows:@[restore]],
    ];
}

- (NSArray<ApolloSettingsSection *> *)presetForm {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *choices = [NSMutableArray array];
    if (!self.draft.firstRun) {
        [choices addObject:[self choiceRowWithID:@"setup.keep" title:@"Keep My Settings"
            subtitle:@"Keep your current preferences and customise appearance on the next page."
            selected:^BOOL { return weakSelf.draft.presetIdentifier == nil; }
            action:^{ weakSelf.draft.presetIdentifier = nil; [weakSelf refreshPreset]; }]];
    }
    for (ApolloSetupPreset *preset in ApolloSetupPreset.allPresets) {
        [choices addObject:[self choiceRowWithID:[@"setup.preset." stringByAppendingString:preset.identifier]
            title:[preset.identifier isEqualToString:@"balanced"] ? @"Balanced · Recommended" : preset.title
            subtitle:preset.subtitle
            selected:^BOOL { return [weakSelf.draft.presetIdentifier isEqualToString:preset.identifier]; }
            action:^{ weakSelf.draft.presetIdentifier = preset.identifier; [weakSelf refreshPreset]; }]];
    }
    ApolloSettingsRow *details = [ApolloSettingsRow buttonRowWithID:@"setup.details" title:@"Included Features"
        action:^{ weakSelf.showingDetails = !weakSelf.showingDetails; [weakSelf visibilityDidChange]; }];
    ApolloSettingsRow *included = [ApolloSettingsRow customRowWithID:@"setup.included"
        cell:^UITableViewCell *(__unused UITableView *table, __unused ApolloSettingsRow *row) {
            ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:weakSelf.draft.presetIdentifier];
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = preset.title ?: @"Keep My Settings";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n\nCompatibility fixes stay active in every preset. AI, translation, deleted-comment recovery, experimental services, sound, filters, gestures and privacy keep their current settings.",
                preset ? [preset.highlights componentsJoinedByString:@"\n"] : @"Your feature preferences will stay as they are."];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.textColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
            [weakSelf apollo_applyPrimaryTextColorToCell:cell];
            return cell;
        } onSelect:nil];
    included.visible = ^BOOL { return weakSelf.showingDetails; };
    return @[
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[
            [self heroRowWithTitle:@"Choose Your Apollo" subtitle:@"Pick the experience that feels right. These are starting points, not permanent modes."]]],
        [ApolloSettingsSection sectionWithTitle:@"Your Starting Point" footer:nil rows:choices],
        [ApolloSettingsSection sectionWithTitle:@"Preview" footer:@"Illustrative preview. Your real posts, theme and preferences may look different." rows:@[[self previewRow]]],
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[details, included]],
    ];
}

- (void)refreshPreset {
    [self performUpdateKeepingVisibleRowsInPlace:^{
        [self reloadRowWithID:@"setup.keep"];
        for (ApolloSetupPreset *preset in ApolloSetupPreset.allPresets) {
            [self reloadRowWithID:[@"setup.preset." stringByAppendingString:preset.identifier]];
        }
        [self reloadRowWithID:@"setup.preview"];
        [self reloadRowWithID:@"setup.included"];
    }];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
        [ApolloSetupPreset presetWithIdentifier:self.draft.presetIdentifier].title ?: @"Keep My Settings");
}

- (NSArray<ApolloSettingsSection *> *)appearanceForm {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *modes = [NSMutableArray array];
    NSArray *titles = @[@"Keep Current Appearance", @"System", @"Light", @"Dark"];
    for (NSInteger index = self.draft.firstRun ? 1 : 0; index < (NSInteger)titles.count; index++) {
        ApolloSetupAppearance mode = index - 1;
        [modes addObject:[self choiceRowWithID:[NSString stringWithFormat:@"setup.mode.%ld", (long)mode]
            title:titles[index] subtitle:mode == ApolloSetupAppearanceSystem ? @"Follow your device’s appearance." : nil
            selected:^BOOL { return weakSelf.draft.appearance == mode; }
            action:^{
                weakSelf.draft.appearance = mode;
                [weakSelf performUpdateKeepingVisibleRowsInPlace:^{ [weakSelf rebuildForm]; }];
            }]];
    }
    NSMutableArray *styles = [NSMutableArray array];
    for (NSNumber *glass in @[@NO, @YES]) {
        [styles addObject:[self choiceRowWithID:glass.boolValue ? @"setup.glass" : @"setup.classicChrome"
            title:glass.boolValue ? @"Liquid Glass" : @"Classic"
            subtitle:glass.boolValue ? @"Translucent navigation and floating controls." : @"Apollo’s familiar navigation and tab bar."
            selected:^BOOL { return weakSelf.draft.glass == glass.boolValue; }
            action:^{
                weakSelf.draft.glass = glass.boolValue;
                [weakSelf reloadRowWithID:@"setup.glass"];
                [weakSelf reloadRowWithID:@"setup.classicChrome"];
                [weakSelf reloadRowWithID:@"setup.chromePreview"];
            }]];
    }
    ApolloSettingsSection *chrome = [ApolloSettingsSection sectionWithTitle:@"Interface Style"
        footer:@"Independent of your feature preset. A change takes effect after you finish and reopen Apollo."
        rows:styles];
    chrome.visible = ^BOOL { return ApolloLiquidGlassCanToggle(); };
    ApolloSettingsRow *preview = [self appearancePreviewRow];
    return @[
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[
            [self heroRowWithTitle:@"Make It Yours" subtitle:@"Choose the look you prefer. Themes, icons and text size are waiting in Settings whenever you want them."]]],
        chrome,
        [ApolloSettingsSection sectionWithTitle:@"Light & Dark" footer:nil rows:modes],
        [ApolloSettingsSection sectionWithTitle:@"Preview" footer:!ApolloLiquidGlassCanToggle()
            ? @"This build uses its installed interface style. Liquid Glass switching requires a supported Liquid Glass build."
            : @"A simplified preview. Your chosen interface style takes effect when you reopen Apollo." rows:@[preview]],
    ];
}

- (ApolloSettingsRow *)appearancePreviewRow {
    __weak typeof(self) weakSelf = self;
    return [ApolloSettingsRow customRowWithID:@"setup.chromePreview"
        cell:^UITableViewCell *(__unused UITableView *table, __unused ApolloSettingsRow *row) {
            typeof(self) host = weakSelf;
            BOOL glass = ApolloLiquidGlassCanToggle() ? host.draft.glass : IsLiquidGlass();
            NSArray *modes = @[@"Current Appearance", @"System", @"Light", @"Dark"];
            UILabel *caption = ApolloSetupLabel([NSString stringWithFormat:@"%@ · %@",
                glass ? @"Liquid Glass" : @"Classic", modes[host.draft.appearance + 1]],
                UIFontTextStyleCaption1, UIColor.secondaryLabelColor, host.traitCollection);
            UILabel *navTitle = ApolloSetupLabel(@"Posts", UIFontTextStyleHeadline, UIColor.labelColor, host.traitCollection);
            UIColor *accent = ApolloThemeAccentColor() ?: host.view.tintColor ?: UIColor.systemBlueColor;
            UILabel *navAction = ApolloSetupLabel(@"•••", UIFontTextStyleHeadline, accent, host.traitCollection);
            UIStackView *nav = [[UIStackView alloc] initWithArrangedSubviews:@[navTitle, navAction]];
            nav.axis = UILayoutConstraintAxisHorizontal;
            nav.spacing = 12;
            [navAction setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            UILabel *community = ApolloSetupLabel(@"r/photography", UIFontTextStyleCaption1, UIColor.secondaryLabelColor, host.traitCollection);
            UILabel *post = ApolloSetupLabel(@"A little escape for the weekend", UIFontTextStyleHeadline, UIColor.labelColor, host.traitCollection);
            UILabel *info = ApolloSetupLabel(@"↑ 128     ◇ 24 comments", UIFontTextStyleCaption1, UIColor.secondaryLabelColor, host.traitCollection);
            NSMutableArray *tabs = [NSMutableArray array];
            NSArray *symbols = @[@"house.fill", @"envelope", @"gearshape"];
            NSArray *labels = @[@"Posts", @"Inbox", @"Settings"];
            for (NSUInteger index = 0; index < symbols.count; index++) {
                UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbols[index]]];
                icon.contentMode = UIViewContentModeScaleAspectFit;
                icon.tintColor = index == 0 ? accent : UIColor.secondaryLabelColor;
                [icon.heightAnchor constraintEqualToConstant:18].active = YES;
                UILabel *label = ApolloSetupLabel(labels[index], UIFontTextStyleCaption2, icon.tintColor, host.traitCollection);
                label.textAlignment = NSTextAlignmentCenter;
                [tabs addObject:ApolloSetupStack(@[icon, label], 3)];
            }
            UIStackView *tabBar = [[UIStackView alloc] initWithArrangedSubviews:tabs];
            tabBar.axis = UILayoutConstraintAxisHorizontal;
            tabBar.distribution = UIStackViewDistributionFillEqually;
            UIStackView *stack = ApolloSetupStack(@[caption, ApolloSetupPreviewChrome(nav, glass),
                ApolloSetupStack(@[community, post, info], 6), ApolloSetupPreviewChrome(tabBar, glass)], 14);
            UITableViewCell *cell = ApolloSetupStackCell(stack);
            [host apollo_applyPrimaryTextColorToCell:cell];
            cell.backgroundColor = UIColor.systemGroupedBackgroundColor;
            // Only this sample changes style. UIKit's real design is latched
            // at launch, so changing it live would mix incompatible hook sets.
            ApolloSetupAppearance mode = host.draft.appearance;
            cell.overrideUserInterfaceStyle = mode == ApolloSetupAppearanceDark ? UIUserInterfaceStyleDark
                : mode == ApolloSetupAppearanceLight ? UIUserInterfaceStyleLight
                // The window can have Apollo's manual appearance override;
                // the scene still describes the device's system appearance.
                : mode == ApolloSetupAppearanceSystem ? host.view.window.windowScene.traitCollection.userInterfaceStyle
                : UIUserInterfaceStyleUnspecified;
            return cell;
        } onSelect:nil];
}

- (NSArray<ApolloSettingsSection *> *)finishForm {
    __weak typeof(self) weakSelf = self;
    ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:self.draft.presetIdentifier];
    NSArray *modes = @[@"Current", @"System", @"Light", @"Dark"];
    ApolloSettingsRow *summary = [self choiceRowWithID:@"setup.summary" title:preset.title ?: @"Keep My Settings"
        subtitle:[NSString stringWithFormat:@"%@\nAppearance: %@%@", [self accountSummary], modes[self.draft.appearance + 1],
            ApolloLiquidGlassCanToggle() ? [NSString stringWithFormat:@" · %@", self.draft.glass ? @"Liquid Glass" : @"Classic"] : @""]
        selected:nil action:nil];
    ApolloSettingsRow *privacy = [ApolloSettingsRow buttonRowWithID:@"setup.privacy" title:@"Privacy & Diagnostics"
        action:^{ weakSelf.showingPrivacy = !weakSelf.showingPrivacy; [weakSelf visibilityDidChange]; }];
    ApolloSettingsRow *count = [ApolloSettingsRow switchRowWithID:@"setup.installCount" title:@"Anonymous Install Count"
        isOn:^BOOL { return weakSelf.draft.installCount; }
        onToggle:^(UISwitch *sender) { weakSelf.draft.installCount = sender.isOn; }];
    ApolloSettingsRow *crashes = [ApolloSettingsRow switchRowWithID:@"setup.crashes" title:@"Local Crash Reports"
        isOn:^BOOL { return weakSelf.draft.crashCapture; }
        onToggle:^(UISwitch *sender) { weakSelf.draft.crashCapture = sender.isOn; }];
    ApolloSettingsSection *diagnostics = [ApolloSettingsSection sectionWithTitle:nil
        footer:@"Install counting sends an anonymous monthly identifier and basic app/build information. Local crash reports stay on this device; nothing is shared unless you review and submit it. Crash recording changes take effect next launch."
        rows:@[count, crashes]];
    diagnostics.visible = ^BOOL { return weakSelf.showingPrivacy; };
    ApolloSettingsRow *backups = [ApolloSettingsRow disclosureRowWithID:@"setup.backups" title:@"Set Up Automatic Backups"
        detail:nil push:^UIViewController *{ return [[ApolloAutomaticBackupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]; }];
    return @[
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[
            [self heroRowWithTitle:@"Ready to Go" subtitle:@"Your choices are ready. Search Settings whenever you want to change an option or discover something new."]]],
        [ApolloSettingsSection sectionWithTitle:@"Your Setup" footer:@"Finish saves your choices. If a restart is needed, you’ll close and reopen Apollo once to apply them all." rows:@[summary]],
        [ApolloSettingsSection sectionWithTitle:nil footer:nil rows:@[privacy]], diagnostics,
        [ApolloSettingsSection sectionWithTitle:@"Optional" footer:@"Choose a folder for automatic backups whenever you’re ready. Backup files include account credentials; keep them private." rows:@[backups]],
    ];
}

- (void)continueSetup {
    [self.view endEditing:YES];
    if (self.step < 3) {
        ApolloSetupAssistantViewController *next = [[ApolloSetupAssistantViewController alloc] initWithDraft:self.draft step:self.step + 1];
        [self.navigationController pushViewController:next animated:YES];
    } else {
        [self finishSetup];
    }
}

- (void)closeSetup {
    UINavigationController *nav = self.navigationController;
    sSetupNavigation = nil;
    [nav setToolbarHidden:YES animated:NO];
    // A manually opened route is inside Settings' existing navigation stack.
    NSUInteger rootIndex = [nav.viewControllers indexOfObjectPassingTest:^BOOL(UIViewController *controller, NSUInteger index, BOOL *stop) {
        return [controller isKindOfClass:ApolloSetupAssistantViewController.class];
    }];
    if (rootIndex != NSNotFound && rootIndex > 0) {
        [nav popToViewController:nav.viewControllers[rootIndex - 1] animated:YES];
    } else {
        [nav dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)skipSetup {
    if (self.draft.firstRun) {
        [NSUserDefaults.standardUserDefaults setInteger:ApolloSetupStateSkipped forKey:UDKeySetupAssistantState];
        [self markCurrentReleaseSeen];
    }
    // Only staged preset/appearance/privacy changes are discarded. A completed
    // sign-in or backup operation is a separate explicit user action.
    ApolloLog(@"[SetupAssistant] Dismissed without applying a preset");
    [self closeSetup];
}

- (void)markCurrentReleaseSeen {
    if (!self.draft.firstRun) return;
    [NSUserDefaults.standardUserDefaults setObject:ApolloUpdateNormalizedVersion(@(TWEAK_VERSION))
                                           forKey:UDKeyLastSeenWhatsNewVersion];
}

- (void)finishSetup {
    if (self.finished) return;
    self.finished = YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:kSetupGroup];
    ApolloSetupPreset *preset = [ApolloSetupPreset presetWithIdentifier:self.draft.presetIdentifier];
    BOOL restart = ApolloSetupWriteValues(defaults, preset.values ?: @{});
    restart |= ApolloSetupWriteValues(defaults, ApolloSetupMainAppearanceValues(self.draft.appearance));
    restart |= ApolloSetupWriteValues(group, ApolloSetupGroupAppearanceValues(self.draft.appearance));
    if (ApolloLiquidGlassCanToggle()) {
        restart |= self.draft.glass != sLiquidGlassEnabled;
        [defaults setBool:self.draft.glass forKey:UDKeyLiquidGlassEnabled];
    }
    restart |= self.draft.crashCapture != [defaults boolForKey:UDKeyCrashCaptureEnabled];
    [defaults setBool:self.draft.crashCapture forKey:UDKeyCrashCaptureEnabled];
    ApolloSetUsageHeartbeatDisabled(!self.draft.installCount);
    if (preset) [defaults setObject:preset.identifier forKey:UDKeySetupPreset];
    [defaults setInteger:ApolloSetupStateCompleted forKey:UDKeySetupAssistantState];
    [self markCurrentReleaseSeen];
    restart |= [defaults boolForKey:UDKeyWebJSONPendingRestart];
    [group synchronize];
    [defaults synchronize];
    ApolloLog(@"[SetupAssistant] Finished (preset=%@, restart=%d)", preset.identifier ?: @"keep", restart);
    if (!restart) {
        [self closeSetup];
        return;
    }
    // Do not try to resynchronise dozens of globals or rebuild Apollo's native
    // controllers. A single clean launch picks up every setting and UIKit design.
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Your Setup Is Saved"
        message:@"Quit and reopen Apollo to apply your choices. You won’t need to run setup again."
        preferredStyle:UIAlertControllerStyleAlert];
    alert.modalInPresentation = YES;
    [alert addAction:[UIAlertAction actionWithTitle:@"Quit & Reopen" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [defaults synchronize]; [group synchronize]; exit(0); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreBackup {
    UTType *backup = [UTType typeWithFilenameExtension:@"apollobackup"];
    NSArray *types = backup ? @[backup, UTTypeZIP] : @[UTTypeZIP];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    // asCopy:YES imports into our sandbox. Confirm only after the picker has
    // finished dismissing; keep the existing validated restore/restart flow.
    __weak typeof(self) weakSelf = self;
    [controller dismissViewControllerAnimated:YES completion:^{
        ApolloBackupPresentRestoreConfirmation(weakSelf, url, nil);
    }];
}

@end

static void ApolloSetupAttemptPresentation(NSUInteger attempt) {
    if ([NSUserDefaults.standardUserDefaults integerForKey:UDKeySetupAssistantState] != ApolloSetupStatePending || sSetupNavigation) {
        sSetupPresentationPending = NO;
        return;
    }
    UIViewController *presenter = ApolloMainTabBarController();
    if (!presenter.view.window || presenter.presentedViewController || presenter.isBeingPresented || presenter.transitionCoordinator) {
        if (attempt < 12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ApolloSetupAttemptPresentation(attempt + 1);
            });
        } else {
            sSetupPresentationPending = NO;
        }
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[ApolloSetupAssistantViewController new]];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.modalInPresentation = YES;
    nav.preferredContentSize = CGSizeMake(540, 760);
    sSetupNavigation = nav;
    sSetupPresentationPending = NO;
    [presenter presentViewController:nav animated:YES completion:nil];
    ApolloLog(@"[SetupAssistant] Presented first-run setup");
}

static void ApolloSetupPresentIfNeeded(void) {
    if ([NSUserDefaults.standardUserDefaults integerForKey:UDKeySetupAssistantState] != ApolloSetupStatePending ||
        sSetupNavigation || sSetupPresentationPending) return;
    sSetupPresentationPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloSetupAttemptPresentation(0); });
}

void ApolloSetupAssistantStart(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { ApolloSetupPresentIfNeeded(); }];
    ApolloSetupPresentIfNeeded();
}
