#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloClasses.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloState.h"
#import "ApolloSubredditSwitcherSheet.h"
#import "ApolloThemeRuntime.h"
#import "settings/ApolloSettingsTableViewController.h"
#import "ApolloDuoUIKitCompatibility.h"

@interface _TtC6Apollo7JumpBar : UIControl
- (void)searchTextFieldChanged:(UITextField *)field;
- (BOOL)textFieldShouldReturn:(UITextField *)field;
@end

// ApolloNavigationController's "Go to Jump Bar" key command.
@interface UINavigationController (ApolloJumpBarCommand)
- (void)goToJumpBar;
@end

static const CGFloat ApolloSubredditSearchBarHeight = 56.0;

// Keep Apollo's search model and its feed-switching delegate. Only replace the
// old floating table/editor presentation; no Swift storage or URL routing is
// synthesized here. The hidden native table receives local and remote results.
@interface ApolloSubredditSwitcherSheet : UIViewController <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, weak) _TtC6Apollo7JumpBar *jumpBar;
@property(nonatomic, weak) UITableView *nativeTable;
@property(nonatomic, weak) UIViewController *feedToRestore;
@property(nonatomic, strong) UITextField *queryField;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, copy) NSArray<NSArray<NSString *> *> *sections;
// Native table index path of each row, for Classic's own row selection.
@property(nonatomic, copy) NSArray<NSArray<NSIndexPath *> *> *nativePaths;
@property(nonatomic, copy) NSArray<NSString *> *sectionTitles;
@property(nonatomic, copy) NSString *selectedName;
@property(nonatomic) BOOL refreshScheduled;
@property(nonatomic) BOOL contentSizeUpdateScheduled;
@property(nonatomic) BOOL choosing;
- (void)scheduleResultsRefresh;
- (void)updatePreferredContentSize;
@end

@interface ApolloSubredditSheetReference : NSObject
@property(nonatomic, weak) ApolloSubredditSwitcherSheet *sheet;
@end
@implementation ApolloSubredditSheetReference @end
static char kApolloSubredditSheetReference;
static char kApolloActiveSubredditSheetReference;

static BOOL ApolloSubredditSheetIsActive(UITabBarController *tabs) {
    ApolloSubredditSheetReference *reference = objc_getAssociatedObject(tabs, &kApolloActiveSubredditSheetReference);
    return reference.sheet != nil;
}

@implementation ApolloSubredditSwitcherSheet

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Subreddits";
    self.queryField = [UITextField new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeSheet)];
    if (@available(iOS 27.1, *)) {
        self.navigationItem.rightBarButtonItem.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
    }

    UISearchBar *search = [UISearchBar new];
    search.translatesAutoresizingMaskIntoConstraints = NO;
    search.searchBarStyle = UISearchBarStyleMinimal;
    search.placeholder = @"Subreddit";
    search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.autocorrectionType = UITextAutocorrectionTypeNo;
    search.returnKeyType = UIReturnKeyGo;
    search.delegate = self;
    self.searchBar = search;
    [self.view addSubview:search];

    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    table.translatesAutoresizingMaskIntoConstraints = NO;
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = 52.0;
    table.estimatedRowHeight = 0.0;
    table.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    if (@available(iOS 15.0, *)) table.sectionHeaderTopPadding = 0.0;
    self.tableView = table;
    [self.view addSubview:table];

    // Search stays above the scrolling results. UIKit moves only the list's
    // bottom edge with the keyboard, including interactive dismissal.
    NSLayoutYAxisAnchor *bottom = self.view.safeAreaLayoutGuide.bottomAnchor;
    if (@available(iOS 15.0, *)) bottom = self.view.keyboardLayoutGuide.topAnchor;
    [NSLayoutConstraint activateConstraints:@[
        [search.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [search.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [search.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [search.heightAnchor constraintEqualToConstant:ApolloSubredditSearchBarHeight],
        [table.topAnchor constraintEqualToAnchor:search.bottomAnchor],
        [table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [table.bottomAnchor constraintEqualToAnchor:bottom]
    ]];
    [self applyTheme];

    ApolloSubredditSheetReference *reference = [ApolloSubredditSheetReference new];
    reference.sheet = self;
    objc_setAssociatedObject(self.nativeTable, &kApolloSubredditSheetReference, reference,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Empty-query search restores Apollo's favorites, including on reopening
    // after an earlier query. It does not enter the old popup presentation.
    self.queryField.text = @"";
    [self.jumpBar searchTextFieldChanged:self.queryField];
    [self refreshResults];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UISearchTextField *field = self.searchBar.searchTextField;
    CGFloat radius = CGRectGetHeight(field.bounds) / 2.0;
    if (field.layer.cornerRadius != radius) field.layer.cornerRadius = radius;
    if (self.contentSizeUpdateScheduled) return;
    self.contentSizeUpdateScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSubredditSwitcherSheet *sheet = weakSelf;
        sheet.contentSizeUpdateScheduled = NO;
        if (sheet.viewIfLoaded.window) [sheet updatePreferredContentSize];
    });
}

- (void)updatePreferredContentSize {
    // Size the centered form to the actual favorites/results. UIKit still owns
    // its placement and keyboard avoidance; keyboard insets must not become
    // part of the requested content height.
    UIWindow *window = self.viewIfLoaded.window ?: self.jumpBar.window;
    if (!window || !self.isViewLoaded) return;
    UINavigationController *navigation = self.navigationController;
    CGFloat availableHeight = CGRectGetHeight(window.bounds) - window.safeAreaInsets.top
        - window.safeAreaInsets.bottom - 32.0;
    if (availableHeight <= 0.0) return;
    CGFloat navigationHeight = CGRectGetHeight(navigation.navigationBar.bounds);
    CGFloat chromeHeight = navigationHeight + navigation.view.safeAreaInsets.top
        + navigation.view.safeAreaInsets.bottom;
    CGFloat contentHeight = ceil(self.tableView.contentSize.height + ApolloSubredditSearchBarHeight + chromeHeight);
    CGFloat height = MIN(availableHeight, MAX(200.0, contentHeight));
    CGSize size = CGSizeMake(540.0, height);
    if (!CGSizeEqualToSize(self.preferredContentSize, size)) self.preferredContentSize = size;
    if (!CGSizeEqualToSize(navigation.preferredContentSize, size)) navigation.preferredContentSize = size;
}

- (void)applyTheme {
    UIColor *page = ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
    self.view.backgroundColor = page;
    self.tableView.backgroundColor = page;
    self.navigationController.view.backgroundColor = page;
    self.view.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    self.navigationController.view.tintColor = self.view.tintColor;
    self.tableView.separatorColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    UISearchTextField *field = self.searchBar.searchTextField;
    field.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor;
    // UIKit's glass border draws a darker rim just outside a 44pt field, which
    // shows past the theme's pill at both ends. Draw the field's own capsule.
    field.borderStyle = UITextBorderStyleNone;
    UIColor *fill = ApolloThemeRuntimeColor(ApolloThemeTokenElevatedBackground)
        ?: UIColor.secondarySystemGroupedBackgroundColor;
    field.backgroundColor = [fill resolvedColorWithTraitCollection:self.traitCollection];
    field.layer.cornerCurve = kCACornerCurveCircular;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithTransparentBackground];
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName:
        ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor};
    self.navigationController.navigationBar.standardAppearance = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.compactAppearance = appearance;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (self.isViewLoaded) [self applyTheme];
}

- (void)scheduleResultsRefresh {
    if (self.refreshScheduled || self.choosing) return;
    self.refreshScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSubredditSwitcherSheet *sheet = weakSelf;
        sheet.refreshScheduled = NO;
        if (sheet.isViewLoaded && !sheet.choosing) [sheet refreshResults];
    });
}

- (void)refreshResults {
    UITableView *native = self.nativeTable;
    id<UITableViewDataSource> source = native.dataSource;
    if (!source) return;
    NSInteger count = [source respondsToSelector:@selector(numberOfSectionsInTableView:)]
        ? [source numberOfSectionsInTableView:native] : 1;
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSInteger section = 0; section < count; section++) {
        NSMutableArray *names = [NSMutableArray array];
        NSMutableArray *sectionPaths = [NSMutableArray array];
        NSInteger rows = [source tableView:native numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows; row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
            UITableViewCell *cell = [source tableView:native cellForRowAtIndexPath:path];
            NSString *name = cell.textLabel.text;
            if (!name.length) continue;
            [names addObject:name];
            [sectionPaths addObject:path];
        }
        // Apollo keeps empty sections while searching; they only add space here.
        if (!names.count) continue;
        NSString *title = [source respondsToSelector:@selector(tableView:titleForHeaderInSection:)]
            ? [source tableView:native titleForHeaderInSection:section] : nil;
        [sections addObject:names.copy];
        [paths addObject:sectionPaths.copy];
        // Apollo titles its results section with blank text; treat it as untitled.
        title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [titles addObject:title ?: @""];
    }
    self.nativePaths = paths;
    if ([self.sections isEqualToArray:sections] && [self.sectionTitles isEqualToArray:titles]) return;
    self.sections = sections;
    self.sectionTitles = titles;
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    [self updatePreferredContentSize];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // Compact titles; the grouped default leaves a wide gap under the search bar.
    return self.sectionTitles[section].length ? 32.0 : 8.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 12.0;
}

// Search results have no title. Without a header view UIKit keeps its 35pt
// grouped top gap there and ignores the height above.
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return self.sectionTitles[section].length ? nil : [UIView new];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sectionTitles[section];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    // Same section-header size, case and color as the Apollo Reborn settings screens.
    ApolloSettingsApplySectionHeaderTypography(view);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Subreddit"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Subreddit"];
    NSString *name = self.sections[indexPath.section][indexPath.row];
    cell.textLabel.text = name;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor;
    cell.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemGroupedBackgroundColor;
    cell.tintColor = ApolloThemeAccentColor() ?: cell.tintColor;
    cell.accessoryType = [name caseInsensitiveCompare:self.selectedName ?: @""] == NSOrderedSame
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = self.sections[indexPath.section][indexPath.row];
    if ([self selectNativeRowForName:name atIndexPath:indexPath]) return;
    [self chooseName:name];
}

// Classic's row tap: Apollo's own dropdown selection switches the feed with the
// row's model directly, so the load starts now instead of after the dismissal
// and a typed-name lookup. Only used while the native row still holds the name.
- (BOOL)selectNativeRowForName:(NSString *)name atIndexPath:(NSIndexPath *)indexPath {
    if (self.choosing) return YES;
    UITableView *native = self.nativeTable;
    UIViewController *feed = self.feedToRestore;
    id<UITableViewDelegate> delegate = native.delegate;
    if (!native || !feed || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    if (indexPath.section >= (NSInteger)self.nativePaths.count) return NO;
    NSArray<NSIndexPath *> *paths = self.nativePaths[indexPath.section];
    if (indexPath.row >= (NSInteger)paths.count) return NO;
    NSIndexPath *nativePath = paths[indexPath.row];
    id<UITableViewDataSource> source = native.dataSource;
    if (nativePath.section >= [native numberOfSections] ||
        nativePath.row >= [native numberOfRowsInSection:nativePath.section]) return NO;
    NSString *current = [source tableView:native cellForRowAtIndexPath:nativePath].textLabel.text;
    if (![current isEqualToString:name]) return NO;

    self.choosing = YES;
    [self.view endEditing:YES];
    if (feed.navigationController.topViewController != feed) {
        [feed.navigationController popToViewController:feed animated:NO];
    }
    [delegate tableView:native didSelectRowAtIndexPath:nativePath];
    ApolloLog(@"[SubredditSheet] selected native row %ld.%ld", (long)nativePath.section, (long)nativePath.row);
    [self dismissViewControllerAnimated:YES completion:nil];
    return YES;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.queryField.text = searchText;
    [self.jumpBar searchTextFieldChanged:self.queryField];
    [self scheduleResultsRefresh];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self chooseName:[searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
}

- (void)chooseName:(NSString *)name {
    if (!name.length || self.choosing) return;
    self.choosing = YES;
    [self.view endEditing:YES];
    _TtC6Apollo7JumpBar *jump = self.jumpBar;
    UIViewController *feed = self.feedToRestore;
    UITextField *field = [UITextField new];
    field.text = name;
    // Native Return handles both subreddit and multireddit titles and performs
    // the normal in-place feed switch. Start it now so the feed loads during
    // the dismissal rather than after it.
    if (feed && feed.navigationController.topViewController != feed) {
        [feed.navigationController popToViewController:feed animated:NO];
    }
    [jump textFieldShouldReturn:field];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)closeSheet {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static BOOL ApolloPresentSubredditSheetForFeed(UIViewController *owner, UIViewController *presenter) {
    if (@available(iOS 15.0, *)) {
        if (![owner isKindOfClass:ApolloClassPostsViewController] || !presenter) return NO;
        if (presenter.presentedViewController || presenter.navigationController.presentedViewController ||
            presenter.tabBarController.presentedViewController) return NO;
        [owner loadViewIfNeeded];
        _TtC6Apollo7JumpBar *jump = ApolloObjectIvar(owner, "jumpBar");
        UITableView *native = ApolloObjectIvar(owner, "dropDownTableView");
        if (![jump isKindOfClass:ApolloClassJumpBar] || ![native isKindOfClass:UITableView.class]) return NO;
        ApolloSubredditSwitcherSheet *picker = [ApolloSubredditSwitcherSheet new];
        picker.jumpBar = jump;
        picker.nativeTable = native;
        picker.feedToRestore = owner;
        picker.selectedName = owner.navigationItem.title;
        UINavigationController *sheetNavigation = [[UINavigationController alloc] initWithRootViewController:picker];
        // Keep UIKit's centered, content-sized form on the unfolded display.
        sheetNavigation.modalPresentationStyle = UIModalPresentationFormSheet;
        sheetNavigation.preferredContentSize = CGSizeMake(540.0, 480.0);
        UISheetPresentationController *sheet = sheetNavigation.sheetPresentationController;
        // Let the favorites fit instead of initially hiding the lower rows in
        // a medium sheet. UIKit still limits the form to its content height.
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
        sheet.prefersGrabberVisible = YES;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;
        // Resolve the initial favorites height before the presentation starts.
        [picker loadViewIfNeeded];
        [picker updatePreferredContentSize];
        // The tab button and bar can both recognize the same hold. Register
        // before presentation starts; the weak reference clears on dismissal.
        UITabBarController *tabs = owner.tabBarController;
        if (tabs) {
            ApolloSubredditSheetReference *reference = [ApolloSubredditSheetReference new];
            reference.sheet = picker;
            objc_setAssociatedObject(tabs, &kApolloActiveSubredditSheetReference,
                                     reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [presenter presentViewController:sheetNavigation animated:YES completion:nil];
        ApolloLog(@"[SubredditSheet] presented from %@", NSStringFromClass(presenter.class));
        return YES;
    }
    return NO;
}

static BOOL ApolloPresentSubredditSheet(_TtC6Apollo7JumpBar *jump) {
    // Classic: fall through to Apollo's own inline popup.
    if (!sSubredditSwitcherSheetEnabled) return NO;
    UIViewController *owner = ApolloReadSwiftWeakObjectIvar(jump, "delegate");
    if (![owner isKindOfClass:ApolloClassPostsViewController]) return NO;
    if (owner.presentedViewController || owner.navigationController.presentedViewController) return YES;
    return ApolloPresentSubredditSheetForFeed(owner, owner);
}

static UITabBarController *ApolloSubredditTabsInController(UIViewController *controller) {
    if ([controller isKindOfClass:UITabBarController.class]) return (id)controller;
    for (UIViewController *child in controller.childViewControllers) {
        UITabBarController *tabs = ApolloSubredditTabsInController(child);
        if (tabs) return tabs;
    }
    return nil;
}

BOOL ApolloPresentPostsTabSubredditSheet(UIWindow *sourceWindow) {
    UITabBarController *tabs = ApolloSubredditTabsInController((sourceWindow ?: ApolloKeyWindow()).rootViewController);
    if (!tabs || ApolloSubredditSheetIsActive(tabs) || tabs.presentedViewController) return NO;
    UIViewController *postsTab = tabs.viewControllers.firstObject;
    if (![postsTab isKindOfClass:UINavigationController.class]) return NO;
    UINavigationController *navigation = (id)postsTab;
    if (navigation.presentedViewController || navigation.topViewController.presentedViewController) return NO;
    // Preserve the active feed when the tab is showing comments. Cancel keeps
    // that stack intact; choosing a subreddit returns to the feed first.
    UIViewController *feed = nil;
    for (UIViewController *candidate in navigation.viewControllers.reverseObjectEnumerator) {
        if ([candidate isKindOfClass:ApolloClassPostsViewController]) { feed = candidate; break; }
    }
    if (!feed) return NO;
    tabs.selectedViewController = navigation;
    if (!sSubredditSwitcherSheetEnabled) {
        // Classic: open Apollo's inline popup through its own Go to Jump Bar
        // key command. The popup lives in the feed's title, so the feed has
        // to be on top first.
        if (![navigation respondsToSelector:@selector(goToJumpBar)]) return NO;
        if (navigation.topViewController != feed) [navigation popToViewController:feed animated:NO];
        [navigation goToJumpBar];
        ApolloLog(@"[SubredditSheet] classic: opened native jump bar from Posts tab");
        return YES;
    }
    return ApolloPresentSubredditSheetForFeed(feed, navigation.topViewController);
}

@interface _TtC6Apollo22ApolloTabBarController : UITabBarController
@end

%hook _TtC6Apollo22ApolloTabBarController
- (void)tabBarLongPressedWithLongPressGestureRecognizer:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        UITabBarItem *posts = self.tabBar.items.firstObject;
        UIView *button = ApolloObjectIvar(posts, "_view") ?: ApolloSendObject(posts, @selector(_tabBarButton));
        if ([button isKindOfClass:UIView.class] &&
            [button pointInside:[recognizer locationInView:button] withEvent:nil] &&
            (ApolloSubredditSheetIsActive(self) || ApolloPresentPostsTabSubredditSheet(self.view.window))) return;
    }
    %orig(recognizer);
}
%end

%hook _TtC6Apollo7JumpBar
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    // A press dragged out of the title is cancelled, just like a normal
    // control. UIKit still calls endTracking for that outside release.
    BOOL releasedInside = !touch || [self pointInside:[touch locationInView:self] withEvent:event];
    if (!releasedInside || ApolloPresentSubredditSheet(self)) {
        // beginTracking dims Apollo's name label directly (alpha 0.25), rather
        // than through UIControl.highlighted. We bypass native endTracking to
        // avoid opening its old inline popup, so use its cancellation path to
        // restore the label and finish the press without starting that popup.
        [self cancelTrackingWithEvent:event];
        self.highlighted = NO;
        return;
    }
    %orig(touch, event);
}
%end

%hook UITableView
- (void)reloadData {
    %orig;
    ApolloSubredditSheetReference *reference = objc_getAssociatedObject(self, &kApolloSubredditSheetReference);
    [reference.sheet scheduleResultsRefresh];
}
%end

%ctor {
    %init;
    ApolloLog(@"[SubredditSheet] native search sheet hooks installed");
}
