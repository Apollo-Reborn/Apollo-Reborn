#import "ApolloDuoSearchLandingViewController.h"
#import "ApolloThemeRuntime.h"
#import <objc/message.h>
#include <math.h>

// Query the physical fold before converting into this pane. The trailing rail
// reduces usable content width, but must not move the division between halves.
// Resolve the public 27.1 API dynamically for the device build's iOS 26 SDK.
static CGRect ApolloDuoSearchActiveFold(UIView *view) {
    if (@available(iOS 27.1, *)) {
        UIWindow *window = view.window;
        Class kindClass = NSClassFromString(@"UIViewReservedRegionKind");
        SEL query = NSSelectorFromString(@"reservedRegionsOfKind:");
        if (!window || !kindClass || ![window respondsToSelector:query]) return CGRectNull;
        id kind = ((id (*)(id, SEL))objc_msgSend)(kindClass, NSSelectorFromString(@"divisionRegionKind"));
        NSArray *regions = ((id (*)(id, SEL, id))objc_msgSend)(window, query, kind);
        for (id region in regions) {
            if (!((BOOL (*)(id, SEL))objc_msgSend)(region, NSSelectorFromString(@"isActive"))) continue;
            CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(region, NSSelectorFromString(@"frame"));
            // A portrait/tabletop fold is horizontal; this two-column landing
            // only moves its vertical gutter for the book arrangement.
            if (CGRectGetHeight(frame) <= CGRectGetWidth(frame)) continue;
            return [view convertRect:frame fromView:window];
        }
    }
    return CGRectNull;
}

@interface ApolloDuoSearchLandingRow : UIControl
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

@implementation ApolloDuoSearchLandingRow
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

@interface ApolloDuoSearchLandingSection : UIView
@property(nonatomic, strong) UILabel *heading;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIStackView *rowsStack;
@property(nonatomic, copy) NSArray<ApolloDuoSearchLandingRow *> *rows;
@property(nonatomic, strong) NSMutableArray<UIView *> *separators;
@property(nonatomic, strong) UILabel *emptyLabel;
- (instancetype)initWithTitle:(NSString *)title;
- (void)setRows:(NSArray<ApolloDuoSearchLandingRow *> *)rows emptyText:(NSString *)emptyText;
- (void)refreshTheme;
@end

@implementation ApolloDuoSearchLandingSection
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

- (void)setRows:(NSArray<ApolloDuoSearchLandingRow *> *)rows emptyText:(NSString *)emptyText {
    for (UIView *view in self.rowsStack.arrangedSubviews) [view removeFromSuperview];
    self.rows = rows;
    self.emptyLabel = nil;
    [self.separators removeAllObjects];
    for (ApolloDuoSearchLandingRow *row in rows) {
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
    for (ApolloDuoSearchLandingRow *row in self.rows) [row refreshTheme];
}
@end

@interface ApolloDuoSearchLandingViewController ()
@property(nonatomic, strong, readwrite) UIScrollView *scrollView;
@property(nonatomic, strong, readwrite) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIStackView *columns;
@property(nonatomic, strong) ApolloDuoSearchLandingSection *trendingSection;
@property(nonatomic, strong) ApolloDuoSearchLandingSection *recentSection;
@property(nonatomic, strong) ApolloDuoSearchLandingSection *randomSection;
@property(nonatomic, strong) UIImage *trendingIcon;
@property(nonatomic, strong) UIImage *randomIcon;
@property(nonatomic, strong) NSLayoutConstraint *equalColumnWidths;
@property(nonatomic, strong) NSLayoutConstraint *contentLeading;
@property(nonatomic, strong) NSLayoutConstraint *contentTrailing;
@property(nonatomic, strong) NSLayoutConstraint *contentWidth;
@property(nonatomic, copy) NSArray<NSString *> *trendingNames;
@property(nonatomic, copy) NSArray<NSString *> *recentNames;
@property(nonatomic) BOOL showsRandomNSFW;
@property(nonatomic) BOOL configuredColumns;
@property(nonatomic) BOOL usesTwoColumns;
@property(nonatomic) BOOL columnUpdatePending;
- (void)scheduleColumnArrangement;
@end

@implementation ApolloDuoSearchLandingViewController
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
    // would count the native navigation/status/side-rail reservation twice.
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.accessibilityIdentifier = @"ApolloDuoSearchLanding.Scroll";
    _refreshControl = [[UIRefreshControl alloc] init];
    [_refreshControl addTarget:self action:@selector(requestRefresh:) forControlEvents:UIControlEventValueChanged];
    _scrollView.refreshControl = _refreshControl;
    [self.view addSubview:_scrollView];

    self.trendingSection = [[ApolloDuoSearchLandingSection alloc] initWithTitle:NSLocalizedString(@"TRENDING SUBREDDITS", nil)];
    self.recentSection = [[ApolloDuoSearchLandingSection alloc] initWithTitle:NSLocalizedString(@"RECENTLY VISITED", nil)];
    self.randomSection = [[ApolloDuoSearchLandingSection alloc] initWithTitle:nil];
    UIStackView *leftColumn = [[UIStackView alloc] initWithArrangedSubviews:@[self.trendingSection, self.randomSection]];
    leftColumn.axis = UILayoutConstraintAxisVertical;
    leftColumn.spacing = 24;
    self.columns = [[UIStackView alloc] initWithArrangedSubviews:@[leftColumn, self.recentSection]];
    self.columns.translatesAutoresizingMaskIntoConstraints = NO;
    self.columns.axis = UILayoutConstraintAxisVertical;
    self.columns.spacing = 20;
    [_scrollView addSubview:self.columns];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    UILayoutGuide *content = _scrollView.contentLayoutGuide;
    self.contentLeading = [self.columns.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20];
    self.contentTrailing = [self.columns.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20];
    self.contentWidth = [self.columns.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor constant:-40];
    self.equalColumnWidths = [leftColumn.widthAnchor constraintEqualToAnchor:self.recentSection.widthAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [_scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
        self.contentLeading, self.contentTrailing, self.contentWidth,
        [self.columns.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
        [self.columns.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24]
    ]];
    [self refreshTrendingSection];
    [self refreshRecentSection];
    [self refreshRandomSection];
    [self refreshTheme];
    if (@available(iOS 27.1, *)) {
        Class interactionClass = NSClassFromString(@"UIHingeInteraction");
        if (interactionClass) {
            __weak ApolloDuoSearchLandingViewController *weakSelf = self;
            void (^handler)(id, id) = ^(__unused id interaction, __unused id update) {
                // Read reserved geometry after UIKit delivers the pose update;
                // hinge angle itself never drives column widths.
                [weakSelf scheduleColumnArrangement];
            };
            id<UIInteraction> interaction = ((id (*)(id, SEL, id))objc_msgSend)([interactionClass alloc],
                NSSelectorFromString(@"initWithUpdateHandler:"), handler);
            [self.view addInteraction:interaction];
        }
    }
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

- (NSArray<ApolloDuoSearchLandingRow *> *)rowsForNames:(NSArray<NSString *> *)names image:(UIImage *)image {
    NSMutableArray<ApolloDuoSearchLandingRow *> *rows = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        ApolloDuoSearchLandingRow *row = [[ApolloDuoSearchLandingRow alloc] initWithTitle:name image:image];
        row.subredditName = name;
        row.accessibilityIdentifier = [@"ApolloDuoSearchLanding.Subreddit." stringByAppendingString:name];
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
    ApolloDuoSearchLandingRow *random = [[ApolloDuoSearchLandingRow alloc]
        initWithTitle:NSLocalizedString(@"Random Subreddit", nil) image:self.randomIcon];
    random.randomSelection = YES;
    random.accessibilityIdentifier = @"ApolloDuoSearchLanding.Random";
    [random addTarget:self action:@selector(selectRow:) forControlEvents:UIControlEventTouchUpInside];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:random];
    if (self.showsRandomNSFW) {
        ApolloDuoSearchLandingRow *nsfw = [[ApolloDuoSearchLandingRow alloc]
            initWithTitle:NSLocalizedString(@"Random NSFW Subreddit", nil) image:self.randomIcon];
        nsfw.randomSelection = YES;
        nsfw.randomNSFW = YES;
        nsfw.accessibilityIdentifier = @"ApolloDuoSearchLanding.RandomNSFW";
        [nsfw addTarget:self action:@selector(selectRow:) forControlEvents:UIControlEventTouchUpInside];
        [rows addObject:nsfw];
    }
    [self.randomSection setRows:rows emptyText:nil];
}

- (void)selectRow:(ApolloDuoSearchLandingRow *)row {
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

- (void)updateColumnArrangement {
    if (!self.columns) return;
    CGRect safeFrame = self.view.safeAreaLayoutGuide.layoutFrame;
    CGFloat safeWidth = CGRectGetWidth(safeFrame);
    if (safeWidth <= 0) return;
    BOOL twoColumns = safeWidth >= 560 && !UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    CGFloat margin = twoColumns ? 24 : 20;
    CGFloat widthDifference = 0;
    CGFloat gutter = 20;
    CGRect fold = twoColumns ? ApolloDuoSearchActiveFold(self.view) : CGRectNull;
    if (!CGRectIsNull(fold)) {
        CGFloat center = CGRectGetMidX(fold);
        CGFloat foldGutter = MAX(gutter, CGRectGetWidth(fold));
        CGFloat leftWidth = center - foldGutter / 2 - CGRectGetMinX(safeFrame) - margin;
        CGFloat rightWidth = CGRectGetMaxX(safeFrame) - margin - center - foldGutter / 2;
        // A Search sidebar can occupy only one half of an existing split.
        // Rebalance only when both fold-separated columns actually fit here.
        if (leftWidth >= 220 && rightWidth >= 220 && CGRectGetMaxY(fold) > CGRectGetMinY(safeFrame)
            && CGRectGetMinY(fold) < CGRectGetMaxY(safeFrame)) {
            widthDifference = leftWidth - rightWidth;
            if (self.columns.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft)
                widthDifference = -widthDifference;
            gutter = foldGutter;
        }
    }
    // Layout callbacks only schedule this pass. Change Auto Layout inputs once
    // per arrangement/geometry change, leaving normal scrolling untouched.
    if (!self.configuredColumns || self.usesTwoColumns != twoColumns) {
        self.configuredColumns = YES;
        self.usesTwoColumns = twoColumns;
        self.equalColumnWidths.active = NO;
        self.columns.axis = twoColumns ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
        self.columns.alignment = twoColumns ? UIStackViewAlignmentTop : UIStackViewAlignmentFill;
        self.equalColumnWidths.constant = widthDifference;
        self.equalColumnWidths.active = twoColumns;
    } else if (fabs(self.equalColumnWidths.constant - widthDifference) > 0.5) {
        self.equalColumnWidths.constant = widthDifference;
    }
    if (fabs(self.columns.spacing - gutter) > 0.5) self.columns.spacing = gutter;
    if (self.contentLeading.constant != margin) self.contentLeading.constant = margin;
    if (self.contentTrailing.constant != -margin) self.contentTrailing.constant = -margin;
    if (self.contentWidth.constant != -2 * margin) self.contentWidth.constant = -2 * margin;
}

- (void)scheduleColumnArrangement {
    if (self.columnUpdatePending) return;
    self.columnUpdatePending = YES;
    __weak ApolloDuoSearchLandingViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDuoSearchLandingViewController *controller = weakSelf;
        if (!controller) return;
        controller.columnUpdatePending = NO;
        [controller updateColumnArrangement];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self scheduleColumnArrangement];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshTheme];
    [self scheduleColumnArrangement];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self scheduleColumnArrangement];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) [self refreshTheme];
    if (![self.traitCollection.preferredContentSizeCategory isEqualToString:previousTraitCollection.preferredContentSizeCategory]) [self scheduleColumnArrangement];
}

- (void)scrollToTopAnimated:(BOOL)animated {
    if (!self.isViewLoaded) return;
    UIEdgeInsets insets = _scrollView.adjustedContentInset;
    [_scrollView setContentOffset:CGPointMake(-insets.left, -insets.top) animated:animated];
}
@end
