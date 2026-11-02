#import "ApolloHiddenContentViewController.h"
#import "ApolloDuoSplitView.h"
#import "ApolloHiddenContentNative.h"
#import "ApolloUpvotedPostsFeed.h"
#import <objc/runtime.h>
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"

// A split secondary can extend beneath the sidebar. Keep status text and
// progress inside the visible pane, including while its width changes.
@interface ApolloHiddenStatusContainer : UIView
@property(nonatomic, weak) UIViewController *owner;
@property(nonatomic, strong) UIView *contentView;
@end
@implementation ApolloHiddenStatusContainer
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _contentView = [[UIView alloc] initWithFrame:self.bounds];
        [self addSubview:_contentView];
    }
    return self;
}
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect frame = ApolloDuoSplitContentFrame(self.owner, self);
    CGRect contentFrame = self.bounds;
    if (!CGRectIsNull(frame)) {
        CGRect intersection = CGRectIntersection(self.bounds, frame);
        // A split transition can briefly leave the status view outside the
        // destination pane. CGRectNull has an infinite origin and cannot be
        // assigned as a UIView frame; use the native bounds until it settles.
        if (!CGRectIsNull(intersection) && !CGRectIsInfinite(intersection)) contentFrame = intersection;
    }
    if (!CGRectEqualToRect(self.contentView.frame, contentFrame)) self.contentView.frame = contentFrame;
}
@end

// Apollo's media loader uses this determinate clockwise ring.
@interface DACircularProgressView : UIView
@property (nonatomic, strong) UIColor *trackTintColor;
@property (nonatomic, strong) UIColor *progressTintColor;
@property (nonatomic) CGFloat thicknessRatio;
@property (nonatomic) NSInteger indeterminate;
@property (nonatomic) NSInteger clockwiseProgress;
@property (nonatomic) CGFloat progress;
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;
@end

// UIKit may report a compressed intrinsic width after a navigation handoff.
// Measure both full titles independently of the current frame/selected state.
@interface ApolloArchiveTabs : UISegmentedControl
@end
@implementation ApolloArchiveTabs
- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    UIFont *font = [self titleTextAttributesForState:UIControlStateNormal][NSFontAttributeName]
        ?: [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    CGFloat widest = 0;
    for (NSUInteger i = 0; i < self.numberOfSegments; i++) {
        widest = MAX(widest, [[self titleForSegmentAtIndex:i] sizeWithAttributes:@{NSFontAttributeName:font}].width);
    }
    size.width = ceil(widest + 24) * self.numberOfSegments;
    return size;
}
@end

#pragma mark - View controller

@interface ApolloHiddenContentViewController () <ApolloHiddenContentNativeListOwner>
@property (nonatomic, copy) NSString *username;
@property (nonatomic, strong) UISegmentedControl *contentTabs;
// Posts tab only: switches between compact posts and large thumbnails.
@property (nonatomic, strong) UIBarButtonItem *postSizeItem;
@property (nonatomic) NSInteger selectedTab;
// Apollo's own Posts and Comments lists, one per tab.
@property (nonatomic, copy) NSArray<UIViewController *> *lists;
@property (nonatomic, copy) NSArray<NSArray<ApolloHiddenContentItem *> *> *tabItems;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic) double progressTarget;
@property (nonatomic) double progressStart;
@property (nonatomic) CFTimeInterval progressStartedAt;

// Drawn over the lists; never takes touches, so pull to refresh still works.
@property (nonatomic, strong) UIView *statusContainerView;
@property (nonatomic, strong) DACircularProgressView *progressRing;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UIView *statusContentView;
@property (nonatomic, strong) UILabel *emptyStateLabel;
@end

@implementation ApolloHiddenContentViewController {
    // Per tab (0 posts, 1 comments): each loads and shows on its own.
    BOOL _tabLoading[2];
    BOOL _tabLoaded[2];
    // Shown once its first results (or an error) arrive: the progress ring
    // stands in for the list's own loading spinner until then.
    BOOL _tabRevealed[2];
    double _tabProgress[2];
    NSString *_tabStage[2];
}

+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter {
    if (username.length == 0 || !presenter.navigationController) return;
    ApolloHiddenContentViewController *list = [ApolloHiddenContentViewController new];
    list.username = username;
    UIViewController *posts = ApolloHiddenContentMakeNativeList(ApolloHiddenContentKindPost, list);
    UIViewController *comments = ApolloHiddenContentMakeNativeList(ApolloHiddenContentKindComment, list);
    if (!posts || !comments) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hidden & Deleted Unavailable"
                                                                       message:@"This version of Apollo isn't supported."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }
    list.lists = @[posts, comments];
    [presenter.navigationController pushViewController:list animated:YES];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = nil;
    self.tabItems = @[@[], @[]];
    self.view.backgroundColor = ApolloThemePageBackgroundColor() ?: UIColor.systemBackgroundColor;
    for (NSUInteger tab = 0; tab < self.lists.count; tab++) {
        UIViewController *list = self.lists[tab];
        [self addChildViewController:list];
        list.view.frame = self.view.bounds;
        list.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:list.view];
        [list didMoveToParentViewController:self];
        list.view.hidden = YES;
        ApolloHiddenContentNativeListScrollView(list).scrollsToTop = tab == 0;
    }

    self.contentTabs = [[ApolloArchiveTabs alloc] initWithItems:@[@"Posts", @"Comments"]];
    self.contentTabs.selectedSegmentIndex = 0;
    // UIKit owns the complete interactive-glass animation timeline.
    self.contentTabs.accessibilityLabel = @"Hidden and deleted content";
    [self.contentTabs addTarget:self action:@selector(apollo_contentTabChanged) forControlEvents:UIControlEventValueChanged];
    // Use Apollo's shared navigation-title presentation and glass lifecycle.
    // The shared owner handles Hard/Soft/Blur/Automatic, scrolling and pushes.
    [self apollo_applyTabTheme];
    [self.contentTabs sizeToFit];
    [self.contentTabs layoutIfNeeded];
    self.navigationItem.titleView = self.contentTabs;

    self.postSizeItem = [[UIBarButtonItem alloc] initWithImage:nil style:UIBarButtonItemStylePlain
                                                        target:self action:@selector(apollo_togglePostSize)];
    [self apollo_updatePostSizeItem];

    ApolloHiddenStatusContainer *statusContainer = [[ApolloHiddenStatusContainer alloc] initWithFrame:self.view.bounds];
    statusContainer.owner = self;
    self.statusContainerView = statusContainer;
    self.statusContentView = statusContainer.contentView;
    self.statusContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.statusContainerView.userInteractionEnabled = NO;
    [self.view addSubview:self.statusContainerView];

    self.progressRing = [[objc_getClass("DACircularProgressView") alloc] init];
    // Keep archive loading neutral and readable against the active system
    // appearance: black in light mode, white in dark mode.
    self.progressRing.trackTintColor = [UIColor.labelColor colorWithAlphaComponent:0.16];
    self.progressRing.progressTintColor = UIColor.labelColor;
    self.progressRing.thicknessRatio = 0.08;
    self.progressRing.clockwiseProgress = 1;
    self.progressRing.indeterminate = 0;
    self.progressRing.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressRing.isAccessibilityElement = YES;
    self.progressRing.accessibilityLabel = @"Archive loading progress";
    self.progressLabel = [UILabel new];
    self.progressLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.progressLabel.textColor = UIColor.secondaryLabelColor;
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.numberOfLines = 0;
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusContentView addSubview:self.progressRing];
    [self.statusContentView addSubview:self.progressLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.progressRing.centerXAnchor constraintEqualToAnchor:self.statusContentView.centerXAnchor],
        [self.progressRing.centerYAnchor constraintEqualToAnchor:self.statusContentView.centerYAnchor constant:-12],
        [self.progressRing.widthAnchor constraintEqualToConstant:56],
        [self.progressRing.heightAnchor constraintEqualToConstant:56],
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.progressRing.bottomAnchor constant:12],
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.statusContentView.leadingAnchor constant:20],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.statusContentView.trailingAnchor constant:-20],
    ]];

    // Both tabs load at once, and each shows as soon as its own results are in.
    [self apollo_fetchTab:0 forceRefresh:NO];
    [self apollo_fetchTab:1 forceRefresh:NO];
}

- (void)apollo_applyTabTheme {
    self.contentTabs.tintColor = ApolloThemeAccentColor() ?: self.viewIfLoaded.tintColor;
    // A restrained resting highlight, while retaining UIKit's glass interaction.
    self.contentTabs.selectedSegmentTintColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor.whiteColor colorWithAlphaComponent:0.12]
            : [UIColor.blackColor colorWithAlphaComponent:0.06];
    }];
    // Let UIKit own label contrast during the glass selector's transition.
    // Forcing foreground colors fights its temporary vibrancy/legibility state.
    NSDictionary *attributes = @{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline compatibleWithTraitCollection:self.traitCollection]};
    for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateSelected),
                             @(UIControlStateHighlighted), @(UIControlStateSelected | UIControlStateHighlighted)]) {
        [self.contentTabs setTitleTextAttributes:attributes forState:state.unsignedIntegerValue];
    }
}

- (UIScrollView *)scrollView {
    return ApolloHiddenContentNativeListScrollView(self.lists[self.selectedTab]);
}

- (void)apollo_contentTabChanged {
    // Each list keeps its own offset and rows; switching only shows the other.
    UIViewController *previous = self.lists[self.selectedTab];
    ApolloHiddenContentNativeListScrollView(previous).scrollsToTop = NO;
    previous.view.hidden = YES;
    self.selectedTab = self.contentTabs.selectedSegmentIndex;
    UIViewController *current = self.lists[self.selectedTab];
    [self apollo_updatePostSizeItem];
    ApolloHiddenContentNativeListScrollView(current).scrollsToTop = YES;
    [self apollo_updateTabStatus];
}

- (void)apollo_updatePostSizeItem {
    BOOL compact = ApolloHiddenContentNativePostsCompact();
    self.postSizeItem.image = ApolloPostsFeedSizeImage(compact);
    self.postSizeItem.accessibilityLabel = compact ? @"Large Thumbnails" : @"Compact Posts";
    self.navigationItem.rightBarButtonItem = self.selectedTab == 0 ? self.postSizeItem : nil;
}

- (void)apollo_togglePostSize {
    ApolloHiddenContentNativePostsSetCompact(self.lists[0], !ApolloHiddenContentNativePostsCompact());
    [self apollo_updatePostSizeItem];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_applyTabTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTabTheme];
}

- (void)apollo_fetchTab:(NSInteger)tab forceRefresh:(BOOL)forceRefresh {
    if (_tabLoading[tab]) return;
    _tabLoading[tab] = YES;
    _tabProgress[tab] = 0;
    _tabStage[tab] = nil;
    if (tab == self.selectedTab) [self apollo_updateTabStatus];
    ApolloLog(@"[HiddenContent] Fetching %@%@", tab == 0 ? @"posts" : @"comments", forceRefresh ? @" (refresh)" : @"");
    ApolloHiddenContentKind kind = tab == 0 ? ApolloHiddenContentKindPost : ApolloHiddenContentKindComment;
    __weak __typeof(self) weakSelf = self;
    ApolloHiddenContentFetchWithProgress(self.username, kind, forceRefresh, ^(double fraction, NSString *stage) {
        [weakSelf apollo_tab:tab progress:fraction stage:stage];
    }, ^(NSArray *items, NSString *error) {
        [weakSelf apollo_finishTab:tab items:items error:error];
    });
}

- (void)apollo_tab:(NSInteger)tab progress:(double)fraction stage:(NSString *)stage {
    // Updates arrive only when network work completes, and never go backwards.
    _tabProgress[tab] = MAX(_tabProgress[tab], MIN(1, fraction));
    _tabStage[tab] = stage;
    if (tab == self.selectedTab) [self apollo_updateProgress:_tabProgress[tab] stage:stage];
}

- (void)apollo_updateProgress:(double)progress stage:(NSString *)stage {
    // Never advance a timer toward an invented completion percentage while a
    // request is stalled; only ease toward the progress actually reported.
    self.progressStart = self.progressRing.progress;
    self.progressTarget = progress;
    self.progressStartedAt = CACurrentMediaTime();
    if (!self.progressTimer) {
        __weak typeof(self) weakSelf = self;
        self.progressTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer *timer) {
            typeof(self) owner = weakSelf;
            if (!owner) { [timer invalidate]; return; }
            double t = MIN(1, (CACurrentMediaTime() - owner.progressStartedAt) / 0.25);
            double eased = t * t * (3 - 2 * t);
            [owner.progressRing setProgress:owner.progressStart + (owner.progressTarget - owner.progressStart) * eased animated:NO];
            if (t >= 1) { [timer invalidate]; owner.progressTimer = nil; }
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.progressTimer forMode:NSRunLoopCommonModes];
    }
    self.progressRing.accessibilityValue = [NSString stringWithFormat:@"%.0f%%", progress * 100];
    self.progressLabel.text = stage;
}

// Shows the selected tab's state: its progress while its first results load
// (a refresh shows the list's own pull-to-refresh spinner instead), then its
// list or a message.
- (void)apollo_updateTabStatus {
    NSInteger tab = self.selectedTab;
    BOOL showProgress = _tabLoading[tab] && !_tabLoaded[tab];
    [self.progressTimer invalidate];
    self.progressTimer = nil;
    self.progressTarget = _tabProgress[tab];
    self.progressRing.progress = _tabProgress[tab];
    self.progressRing.accessibilityValue = [NSString stringWithFormat:@"%.0f%%", _tabProgress[tab] * 100];
    self.progressLabel.text = _tabStage[tab];
    self.progressRing.hidden = !showProgress;
    self.progressLabel.hidden = !showProgress;
    [self apollo_updateEmptyState];
}

- (void)apollo_finishTab:(NSInteger)tab items:(NSArray *)items error:(NSString *)error {
    _tabLoading[tab] = NO;
    _tabRevealed[tab] = YES;
    UIViewController *list = self.lists[tab];
    if (error) {
        // Keeps the results already shown; a tab that never loaded offers a retry.
        ApolloLog(@"[HiddenContent] %@ failed: %@", tab == 0 ? @"Posts" : @"Comments", error);
        ApolloHiddenContentNativeListEndRefresh(list);
        if (tab == self.selectedTab) [self apollo_updateTabStatus];
        [self apollo_showError:error];
        return;
    }
    BOOL firstLoad = !_tabLoaded[tab];
    _tabLoaded[tab] = YES;
    NSMutableArray *tabItems = [self.tabItems mutableCopy];
    tabItems[tab] = items ?: @[];
    self.tabItems = tabItems;
    ApolloHiddenContentNativeListSetItems(list, self.tabItems[tab]);
    if (tab != self.selectedTab) return;
    [self apollo_updateEmptyState];
    if (!firstLoad) return;
    // Let the ring reach full before it goes.
    [self apollo_updateProgress:1 stage:@"Loaded"];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) owner = weakSelf;
        if (owner && owner.selectedTab == tab) [owner apollo_updateTabStatus];
    });
}

- (void)apollo_updateEmptyState {
    [self.emptyStateLabel removeFromSuperview];
    NSInteger tab = self.selectedTab;
    UIViewController *list = self.lists[tab];
    if (!_tabRevealed[tab]) {
        list.view.hidden = YES;
        return;
    }
    BOOL failed = !_tabLoaded[tab] && !_tabLoading[tab];
    BOOL empty = _tabLoaded[tab] && !_tabLoading[tab] && self.tabItems[tab].count == 0;
    // An empty list shows only the message (Apollo's list would keep its
    // loading spinner under it).
    list.view.hidden = empty;
    if (failed) {
        [self apollo_showStatusText:@"Couldn't load results. Pull down to try again."];
    } else if (empty) {
        NSString *kind = tab == 0 ? @"posts" : @"comments";
        [self apollo_showStatusText:[NSString stringWithFormat:@"No hidden or deleted %@ found in the archive for this account.", kind]];
    }
}

- (void)apollo_showError:(NSString *)message {
    // Both tabs can fail together (no session yet); one alert covers it.
    if ([self.presentedViewController isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Fetch Hidden Content"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)apollo_showStatusText:(NSString *)text {
    if (!self.emptyStateLabel) {
        self.emptyStateLabel = [[UILabel alloc] init];
        self.emptyStateLabel.numberOfLines = 0;
        self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
        self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
        self.emptyStateLabel.font = [UIFont systemFontOfSize:15.0];
        // Full-height inset frame + flexible width/height (UILabel centers its
        // text vertically), so the text re-flows on rotation instead of keeping
        // its creation-time width.
        self.emptyStateLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    self.emptyStateLabel.text = text;
    self.emptyStateLabel.frame = CGRectInset(self.statusContentView.bounds, 32.0, 0);
    [self.statusContentView addSubview:self.emptyStateLabel];
}

#pragma mark - ApolloHiddenContentNativeListOwner

- (void)apollo_nativeListRequestedRefresh:(UIViewController *)list {
    // Refreshes only the tab that was pulled.
    NSUInteger tab = [self.lists indexOfObjectIdenticalTo:list];
    if (tab != NSNotFound) [self apollo_fetchTab:(NSInteger)tab forceRefresh:YES];
}

@end
