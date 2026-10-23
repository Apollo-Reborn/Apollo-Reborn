#import "ApolloSearchLandingViewController.h"
#import "ApolloThemeRuntime.h"
#import "ApolloSearchLandingPreferences.h"
#import "ApolloState.h"
@interface ApolloSearchLandingRow : UIControl
@property(nonatomic, strong) UILabel *primaryLabel;
@property(nonatomic, strong) UIImageView *symbolView;
@property(nonatomic, strong) UIImageView *chevronView;
@property(nonatomic, strong) UIColor *highlightColor;
@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic) BOOL randomSelection;
@property(nonatomic) BOOL randomNSFW;
- (instancetype)initWithTitle:(NSString *)title image:(UIImage *)image;
- (void)refreshTheme;
@end

@implementation ApolloSearchLandingRow
- (instancetype)initWithTitle:(NSString *)title image:(UIImage *)image {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityLabel = title;

    _primaryLabel = [[UILabel alloc] init];
    _primaryLabel.text = title;
    _primaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _primaryLabel.adjustsFontForContentSizeCategory = YES;
    _primaryLabel.numberOfLines = 0;
    _primaryLabel.lineBreakMode = NSLineBreakByCharWrapping;
    _symbolView = [[UIImageView alloc] initWithImage:image];
    _symbolView.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleTitle2];
    // Preserve Apollo's artwork at its native point size inside the icon slot.
    _symbolView.contentMode = UIViewContentModeCenter;
    _chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.forward"]];
    _chevronView.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote];
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;

    UIStackView *contents = [[UIStackView alloc] initWithArrangedSubviews:@[_symbolView, _primaryLabel, _chevronView]];
    contents.translatesAutoresizingMaskIntoConstraints = NO;
    contents.alignment = UIStackViewAlignmentCenter;
    contents.spacing = 12;
    // The entire row is one control, including its text and disclosure arrow.
    contents.userInteractionEnabled = NO;
    [self addSubview:contents];
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:56],
        [contents.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [contents.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [contents.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        [contents.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14],
        [_symbolView.widthAnchor constraintEqualToConstant:26],
        [_symbolView.heightAnchor constraintEqualToConstant:26],
        [_chevronView.widthAnchor constraintEqualToConstant:10],
        [_chevronView.heightAnchor constraintEqualToConstant:14]
    ]];
    [self refreshTheme];
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? self.highlightColor : UIColor.clearColor;
}

- (void)refreshTheme {
    self.primaryLabel.textColor = ApolloThemeSettingsTextColor() ?: UIColor.labelColor;
    self.symbolView.tintColor = ApolloThemeAccentColor() ?: self.tintColor;
    self.chevronView.tintColor = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    self.highlightColor = ApolloThemeRowHighlightColor() ?: UIColor.systemFillColor;
    self.backgroundColor = self.highlighted ? self.highlightColor : UIColor.clearColor;
}
@end

@interface ApolloSearchLandingSection : UIView
@property(nonatomic, strong) UILabel *heading;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIStackView *rowsStack;
@property(nonatomic, copy) NSArray<ApolloSearchLandingRow *> *rows;
@property(nonatomic, strong) NSMutableArray<UIView *> *separators;
@property(nonatomic, strong) UILabel *emptyLabel;
- (instancetype)initWithTitle:(NSString *)title;
- (void)setRows:(NSArray<ApolloSearchLandingRow *> *)rows emptyText:(NSString *)emptyText;
- (void)refreshTheme;
@end

@implementation ApolloSearchLandingSection
- (instancetype)initWithTitle:(NSString *)title {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    _heading = [[UILabel alloc] init];
    _heading.translatesAutoresizingMaskIntoConstraints = NO;
    _heading.text = title;
    _heading.hidden = !title.length;
    _heading.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _heading.adjustsFontForContentSizeCategory = YES;
    _heading.numberOfLines = 0;
    _heading.accessibilityTraits |= UIAccessibilityTraitHeader;
    _card = [[UIView alloc] init];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.layer.cornerRadius = 20;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    _rowsStack = [[UIStackView alloc] init];
    _rowsStack.translatesAutoresizingMaskIntoConstraints = NO;
    _rowsStack.axis = UILayoutConstraintAxisVertical;
    _separators = [NSMutableArray array];
    [self addSubview:_heading];
    [self addSubview:_card];
    [_card addSubview:_rowsStack];
    [NSLayoutConstraint activateConstraints:@[
        [_heading.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_heading.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_heading.topAnchor constraintEqualToAnchor:self.topAnchor],
        title.length ? [_card.topAnchor constraintEqualToAnchor:_heading.bottomAnchor constant:8]
                     : [_card.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_card.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_card.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_card.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_rowsStack.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor],
        [_rowsStack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor],
        [_rowsStack.topAnchor constraintEqualToAnchor:_card.topAnchor],
        [_rowsStack.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor]
    ]];
    return self;
}

- (void)setRows:(NSArray<ApolloSearchLandingRow *> *)rows emptyText:(NSString *)emptyText {
    for (UIView *view in self.rowsStack.arrangedSubviews) [view removeFromSuperview];
    self.rows = rows;
    self.emptyLabel = nil;
    [self.separators removeAllObjects];
    for (ApolloSearchLandingRow *row in rows) {
        if (self.rowsStack.arrangedSubviews.count) {
            UIView *separatorContainer = [[UIView alloc] init];
            UIView *separator = [[UIView alloc] init];
            separator.translatesAutoresizingMaskIntoConstraints = NO;
            [separatorContainer addSubview:separator];
            [NSLayoutConstraint activateConstraints:@[
                [separatorContainer.heightAnchor constraintEqualToConstant:0.5],
                [separator.leadingAnchor constraintEqualToAnchor:separatorContainer.leadingAnchor constant:54],
                [separator.trailingAnchor constraintEqualToAnchor:separatorContainer.trailingAnchor constant:-16],
                [separator.topAnchor constraintEqualToAnchor:separatorContainer.topAnchor],
                [separator.bottomAnchor constraintEqualToAnchor:separatorContainer.bottomAnchor]
            ]];
            [self.separators addObject:separator];
            [self.rowsStack addArrangedSubview:separatorContainer];
        }
        [self.rowsStack addArrangedSubview:row];
    }
    if (!rows.count) {
        UIView *container = [[UIView alloc] init];
        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = emptyText;
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.adjustsFontForContentSizeCategory = YES;
        label.numberOfLines = 0;
        [container addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
            [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
            [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:18],
            [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-18],
            [container.heightAnchor constraintGreaterThanOrEqualToConstant:56]
        ]];
        self.emptyLabel = label;
        [self.rowsStack addArrangedSubview:container];
    }
    [self refreshTheme];
}

- (void)refreshTheme {
    UIColor *secondary = ApolloThemeSettingsSecondaryTextColor() ?: UIColor.secondaryLabelColor;
    self.heading.textColor = secondary;
    self.emptyLabel.textColor = secondary;
    self.card.backgroundColor = ApolloThemeCardBackgroundColor() ?: UIColor.secondarySystemGroupedBackgroundColor;
    UIColor *separatorColor = ApolloThemeSeparatorColor() ?: UIColor.separatorColor;
    for (UIView *separator in self.separators) separator.backgroundColor = separatorColor;
    for (ApolloSearchLandingRow *row in self.rows) [row refreshTheme];
}
@end

@interface ApolloSearchLandingViewController ()
@property(nonatomic, strong, readwrite) UIScrollView *scrollView;
@property(nonatomic, strong, readwrite) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIStackView *sectionsStack;
@property(nonatomic, copy) NSArray<NSString *> *arrangedSectionOrder;
@property(nonatomic, strong) ApolloSearchLandingSection *trendingSection;
@property(nonatomic, strong) ApolloSearchLandingSection *recentSection;
@property(nonatomic, strong) ApolloSearchLandingSection *randomSection;
@property(nonatomic, strong) UIImage *trendingIcon;
@property(nonatomic, strong) UIImage *randomIcon;
@property(nonatomic, copy) NSArray<NSString *> *trendingNames;
@property(nonatomic, copy) NSArray<NSString *> *recentNames;
@property(nonatomic) BOOL showsRandomNSFW;
- (NSArray<NSString *> *)visibleSectionOrder;
- (void)arrangeSections:(NSArray<NSString *> *)order;
@end

@implementation ApolloSearchLandingViewController
@synthesize scrollView = _scrollView;
@synthesize refreshControl = _refreshControl;

- (instancetype)initWithTrendingIcon:(UIImage *)trendingIcon randomIcon:(UIImage *)randomIcon {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _trendingIcon = trendingIcon;
    _randomIcon = randomIcon;
    return self;
}

- (UIScrollView *)scrollView {
    [self loadViewIfNeeded];
    return _scrollView;
}

- (UIRefreshControl *)refreshControl {
    [self loadViewIfNeeded];
    return _refreshControl;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _scrollView = [[UIScrollView alloc] init];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    // Pin the viewport to safe area once. Automatic scroll inset adjustment
    // would count the native navigation/status reservation twice.
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.accessibilityIdentifier = @"ApolloSearchLanding.Scroll";
    _refreshControl = [[UIRefreshControl alloc] init];
    [_refreshControl addTarget:self action:@selector(requestRefresh:) forControlEvents:UIControlEventValueChanged];
    _scrollView.refreshControl = _refreshControl;
    [self.view addSubview:_scrollView];

    self.trendingSection = [[ApolloSearchLandingSection alloc] initWithTitle:NSLocalizedString(@"TRENDING SUBREDDITS", nil)];
    self.recentSection = [[ApolloSearchLandingSection alloc] initWithTitle:NSLocalizedString(@"RECENTLY VISITED", nil)];
    self.randomSection = [[ApolloSearchLandingSection alloc] initWithTitle:nil];
    self.sectionsStack = [[UIStackView alloc] init];
    self.sectionsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.sectionsStack.axis = UILayoutConstraintAxisVertical;
    self.sectionsStack.spacing = 24;
    [_scrollView addSubview:self.sectionsStack];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    UILayoutGuide *content = _scrollView.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [_scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
        [self.sectionsStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [self.sectionsStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.sectionsStack.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor constant:-40],
        [self.sectionsStack.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
        [self.sectionsStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24]
    ]];
    [self refreshTrendingSection];
    [self refreshRecentSection];
    [self refreshRandomSection];
    [self refreshTheme];
    [self arrangeSections:[self visibleSectionOrder]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(searchSettingsChanged:)
        name:ApolloSearchLandingSettingsDidChangeNotification object:nil];
}

- (void)updateTrending:(NSArray<NSString *> *)trending recent:(NSArray<NSString *> *)recent randomNSFW:(BOOL)show {
    NSArray<NSString *> *newTrending = trending ?: @[];
    NSArray<NSString *> *newRecent = recent ?: @[];
    BOOL trendingChanged = ![self.trendingNames isEqualToArray:newTrending];
    BOOL recentChanged = ![self.recentNames isEqualToArray:newRecent];
    BOOL randomChanged = self.showsRandomNSFW != show;
    if (!trendingChanged && !recentChanged && !randomChanged) return;
    self.trendingNames = newTrending;
    self.recentNames = newRecent;
    self.showsRandomNSFW = show;
    if (!self.isViewLoaded) return;
    if (trendingChanged) [self refreshTrendingSection];
    if (recentChanged) [self refreshRecentSection];
    if (randomChanged) [self refreshRandomSection];
}

- (NSArray<ApolloSearchLandingRow *> *)rowsForNames:(NSArray<NSString *> *)names image:(UIImage *)image {
    NSMutableArray<ApolloSearchLandingRow *> *rows = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        ApolloSearchLandingRow *row = [[ApolloSearchLandingRow alloc] initWithTitle:name image:image];
        row.subredditName = name;
        row.accessibilityIdentifier = [@"ApolloSearchLanding.Subreddit." stringByAppendingString:name];
        [row addTarget:self action:@selector(selectRow:) forControlEvents:UIControlEventTouchUpInside];
        [rows addObject:row];
    }
    return rows;
}

- (void)refreshTrendingSection {
    [self.trendingSection setRows:[self rowsForNames:self.trendingNames image:self.trendingIcon]
                        emptyText:NSLocalizedString(@"No trending subreddits right now", nil)];
}

- (void)refreshRecentSection {
    [self.recentSection setRows:[self rowsForNames:self.recentNames image:[UIImage systemImageNamed:@"clock.arrow.circlepath"]]
                      emptyText:NSLocalizedString(@"Subreddits you open appear here.", nil)];
}

- (void)refreshRandomSection {
    ApolloSearchLandingRow *random = [[ApolloSearchLandingRow alloc]
        initWithTitle:NSLocalizedString(@"Random Subreddit", nil) image:self.randomIcon];
    random.randomSelection = YES;
    random.accessibilityIdentifier = @"ApolloSearchLanding.Random";
    [random addTarget:self action:@selector(selectRow:) forControlEvents:UIControlEventTouchUpInside];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:random];
    if (self.showsRandomNSFW) {
        ApolloSearchLandingRow *nsfw = [[ApolloSearchLandingRow alloc]
            initWithTitle:NSLocalizedString(@"Random NSFW Subreddit", nil) image:self.randomIcon];
        nsfw.randomSelection = YES;
        nsfw.randomNSFW = YES;
        nsfw.accessibilityIdentifier = @"ApolloSearchLanding.RandomNSFW";
        [nsfw addTarget:self action:@selector(selectRow:) forControlEvents:UIControlEventTouchUpInside];
        [rows addObject:nsfw];
    }
    [self.randomSection setRows:rows emptyText:nil];
}

- (void)selectRow:(ApolloSearchLandingRow *)row {
    if (row.randomSelection) {
        if (self.selectRandom) self.selectRandom(row.randomNSFW);
    } else if (self.selectSubreddit) {
        self.selectSubreddit(row.subredditName);
    }
}

- (void)requestRefresh:(UIRefreshControl *)control {
    if (self.refreshRequested) self.refreshRequested(control);
    else [control endRefreshing];
}

- (void)refreshTheme {
    if (!self.isViewLoaded) return;
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemGroupedBackgroundColor;
    _scrollView.backgroundColor = self.view.backgroundColor;
    _refreshControl.tintColor = ApolloThemeAccentColor() ?: self.view.tintColor;
    [self.trendingSection refreshTheme];
    [self.recentSection refreshTheme];
    [self.randomSection refreshTheme];
}

- (NSArray<NSString *> *)visibleSectionOrder {
    NSMutableArray<NSString *> *order = [ApolloSearchLandingSectionOrder() mutableCopy];
    if (sTrendingSubredditsLimit.length && sTrendingSubredditsLimit.integerValue == 0)
        [order removeObject:ApolloSearchLandingSectionTrending];
    if (ApolloSearchLandingRecentlyVisitedLimit() == 0) [order removeObject:ApolloSearchLandingSectionRecent];
    return order;
}

- (void)arrangeSections:(NSArray<NSString *> *)order {
    if ([self.arrangedSectionOrder isEqualToArray:order]) return;
    // Reuse the sections when the order or visibility changes. Updating Search
    // preferences should not recreate rows or reset the current scroll position.
    for (UIView *section in self.sectionsStack.arrangedSubviews) [section removeFromSuperview];
    NSDictionary<NSString *, UIView *> *sections = @{
        ApolloSearchLandingSectionTrending: self.trendingSection,
        ApolloSearchLandingSectionRandom: self.randomSection,
        ApolloSearchLandingSectionRecent: self.recentSection
    };
    for (NSString *identifier in order) {
        UIView *section = sections[identifier];
        if (section) [self.sectionsStack addArrangedSubview:section];
    }
    self.arrangedSectionOrder = order;
}

- (void)searchSettingsChanged:(NSNotification *)notification {
    [self arrangeSections:[self visibleSectionOrder]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshTheme];
    [self arrangeSections:[self visibleSectionOrder]];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) [self refreshTheme];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)scrollToTopAnimated:(BOOL)animated {
    if (!self.isViewLoaded) return;
    UIEdgeInsets insets = _scrollView.adjustedContentInset;
    [_scrollView setContentOffset:CGPointMake(-insets.left, -insets.top) animated:animated];
}
@end
