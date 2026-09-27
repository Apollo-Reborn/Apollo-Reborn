#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloDuoUIKitCompatibility.h"

@interface _TtC6Apollo7JumpBar : UIControl
- (void)searchTextFieldChanged:(UITextField *)field;
- (BOOL)textFieldShouldReturn:(UITextField *)field;
@end

// Keep Apollo's search model and its feed-switching delegate. Only replace the
// old floating table/editor presentation; no Swift storage or URL routing is
// synthesized here. The hidden native table receives local and remote results.
@interface ApolloSubredditSwitcherSheet : UITableViewController <UISearchBarDelegate>
@property(nonatomic, weak) _TtC6Apollo7JumpBar *jumpBar;
@property(nonatomic, weak) UITableView *nativeTable;
@property(nonatomic, strong) UITextField *queryField;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, copy) NSArray<NSArray<NSString *> *> *sections;
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

@implementation ApolloSubredditSwitcherSheet

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Subreddits";
    self.queryField = [UITextField new];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeSheet)];
    if (@available(iOS 27.1, *)) {
        self.navigationItem.rightBarButtonItem.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
    }

    UISearchBar *search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 540, 56)];
    search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    search.searchBarStyle = UISearchBarStyleMinimal;
    search.placeholder = @"Subreddit";
    search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.autocorrectionType = UITextAutocorrectionTypeNo;
    search.returnKeyType = UIReturnKeyGo;
    search.delegate = self;
    self.searchBar = search;
    self.tableView.tableHeaderView = search;
    self.tableView.rowHeight = 52.0;
    self.tableView.estimatedRowHeight = 0.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
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

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Wait for the sheet to enter its window before requesting text input;
    // UIKit then presents and positions the keyboard with the sheet itself.
    if (!self.choosing) [self.searchBar.searchTextField becomeFirstResponder];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
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
    CGFloat contentHeight = ceil(self.tableView.contentSize.height + chromeHeight);
    CGFloat height = MIN(availableHeight, MAX(200.0, contentHeight));
    CGSize size = CGSizeMake(540.0, height);
    if (!CGSizeEqualToSize(self.preferredContentSize, size)) self.preferredContentSize = size;
    if (!CGSizeEqualToSize(navigation.preferredContentSize, size)) navigation.preferredContentSize = size;
}

- (void)applyTheme {
    UIColor *page = ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
    self.view.backgroundColor = page;
    self.navigationController.view.backgroundColor = page;
    self.view.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    self.navigationController.view.tintColor = self.view.tintColor;
    self.tableView.separatorColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    self.searchBar.searchTextField.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenLabel) ?: UIColor.labelColor;
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
    for (NSInteger section = 0; section < count; section++) {
        NSMutableArray *names = [NSMutableArray array];
        NSInteger rows = [source tableView:native numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows; row++) {
            UITableViewCell *cell = [source tableView:native cellForRowAtIndexPath:
                [NSIndexPath indexPathForRow:row inSection:section]];
            NSString *name = cell.textLabel.text;
            if (name.length) [names addObject:name];
        }
        NSString *title = [source respondsToSelector:@selector(tableView:titleForHeaderInSection:)]
            ? [source tableView:native titleForHeaderInSection:section] : nil;
        [sections addObject:names.copy];
        [titles addObject:title ?: @""];
    }
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

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sectionTitles[section];
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
    [self chooseName:self.sections[indexPath.section][indexPath.row]];
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
    UITextField *field = [UITextField new];
    field.text = name;
    // Native Return handles both subreddit and multireddit titles and performs
    // the normal in-place feed switch. Wait until the sheet is out of the way.
    [self dismissViewControllerAnimated:YES completion:^{ [jump textFieldShouldReturn:field]; }];
}

- (void)closeSheet {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static BOOL ApolloPresentSubredditSheet(_TtC6Apollo7JumpBar *jump) {
    if (@available(iOS 15.0, *)) {
        UINavigationBar *bar = nil;
        for (UIView *view = jump.superview; view; view = view.superview) {
            if ([view isKindOfClass:UINavigationBar.class]) { bar = (id)view; break; }
        }
        UINavigationController *navigation = nil;
        for (UIResponder *responder = bar; responder; responder = responder.nextResponder) {
            if ([responder isKindOfClass:UINavigationController.class]) { navigation = (id)responder; break; }
        }
        UIViewController *owner = navigation.topViewController;
        if (![NSStringFromClass(owner.class) isEqualToString:@"Apollo.PostsViewController"]) return NO;
        if (owner.presentedViewController || navigation.presentedViewController) return YES;
        UITableView *native = nil;
        for (UIView *view in owner.view.subviews) {
            if ([view isKindOfClass:UITableView.class] &&
                [NSStringFromClass([(NSObject *)[(UITableView *)view dataSource] class]) isEqualToString:@"Apollo.DropDownDataSource"]) {
                native = (id)view;
                break;
            }
        }
        if (!native) return NO;
        ApolloSubredditSwitcherSheet *picker = [ApolloSubredditSwitcherSheet new];
        picker.jumpBar = jump;
        picker.nativeTable = native;
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
        [owner presentViewController:sheetNavigation animated:YES completion:nil];
        return YES;
    }
    return NO;
}

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
