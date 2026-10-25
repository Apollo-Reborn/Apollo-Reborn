#import "ApolloHiddenContentViewController.h"
#import "ApolloDuoSplitView.h"
#import "ApolloHiddenContentNative.h"
#import "ApolloUpvotedPostsFeed.h"
#import <objc/runtime.h>
#import "ApolloThemeRuntime.h"

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
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL loaded;
@property (nonatomic) BOOL listsRevealed;
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

@implementation ApolloHiddenContentViewController

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
        // Shown once the first results (or an error) arrive: the progress ring
        // stands in for the list's own loading spinner until then.
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

    [self apollo_fetchForceRefresh:NO];
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
    current.view.hidden = !self.listsRevealed;
    [self apollo_updatePostSizeItem];
    ApolloHiddenContentNativeListScrollView(current).scrollsToTop = YES;
    [self apollo_updateEmptyState];
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

- (void)apollo_fetchForceRefresh:(BOOL)forceRefresh {
    if (self.loading) return;
    self.loading = YES;
    [self.progressTimer invalidate];
    self.progressTimer = nil;
    self.progressTarget = 0;
    self.progressRing.progress = 0;
    // A refresh shows the lists' own pull-to-refresh spinner instead.
    self.progressRing.hidden = self.loaded;
    self.progressLabel.hidden = self.loaded;
    [self.emptyStateLabel removeFromSuperview];
    __weak __typeof(self) weakSelf = self;
    // Fetch sequentially: the shared archive service rate-limits concurrent
    // posts/comments requests. Commit one complete snapshot, preserving the
    // previous results if either request fails.
    ApolloHiddenContentFetchWithProgress(self.username, ApolloHiddenContentKindPost, forceRefresh, ^(double fraction, NSString *stage) {
        [weakSelf apollo_updateProgress:fraction * 0.5 stage:[@"Posts: " stringByAppendingString:stage]];
    }, ^(NSArray *posts, NSString *postError) {
        __strong __typeof(weakSelf) owner = weakSelf;
        if (!owner) return;
        if (postError) {
            [owner apollo_finishWithPosts:nil comments:nil error:postError];
            return;
        }
        ApolloHiddenContentFetchWithProgress(owner.username, ApolloHiddenContentKindComment, forceRefresh, ^(double fraction, NSString *stage) {
            [weakSelf apollo_updateProgress:0.5 + fraction * 0.5 stage:[@"Comments: " stringByAppendingString:stage]];
        }, ^(NSArray *comments, NSString *commentError) {
            [weakSelf apollo_finishWithPosts:posts comments:comments error:commentError];
        });
    });
}

- (void)apollo_updateProgress:(double)fraction stage:(NSString *)stage {
    // Updates arrive only when network work completes; never advance a timer
    // toward an invented completion percentage while a request is stalled.
    double progress = MAX(self.progressTarget, MIN(1, fraction));
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

- (void)apollo_finishWithPosts:(NSArray *)posts comments:(NSArray *)comments error:(NSString *)error {
    self.loading = NO;
    if (error) {
        [self.progressTimer invalidate];
        self.progressTimer = nil;
        self.progressRing.hidden = YES;
        self.progressLabel.hidden = YES;
        for (UIViewController *list in self.lists) ApolloHiddenContentNativeListEndRefresh(list);
        [self apollo_revealLists];
        [self apollo_showError:error];
        return;
    }
    [self apollo_updateProgress:1 stage:@"Loaded"];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakSelf.loading) {
            weakSelf.progressRing.hidden = YES;
            weakSelf.progressLabel.hidden = YES;
        }
    });
    self.loaded = YES;
    self.tabItems = @[posts ?: @[], comments ?: @[]];
    for (NSUInteger tab = 0; tab < self.lists.count; tab++) {
        ApolloHiddenContentNativeListSetItems(self.lists[tab], self.tabItems[tab]);
    }
    [self apollo_revealLists];
    [self apollo_updateEmptyState];
}

- (void)apollo_revealLists {
    if (self.listsRevealed) return;
    self.listsRevealed = YES;
    self.lists[self.selectedTab].view.hidden = NO;
}

- (void)apollo_updateEmptyState {
    [self.emptyStateLabel removeFromSuperview];
    // An empty list shows only the message (Apollo's list would keep its
    // loading spinner under it).
    BOOL empty = self.loaded && !self.loading && self.tabItems[self.selectedTab].count == 0;
    if (self.listsRevealed) self.lists[self.selectedTab].view.hidden = empty;
    if (!empty) return;
    NSString *kind = self.selectedTab == 0 ? @"posts" : @"comments";
    [self apollo_showStatusText:[NSString stringWithFormat:@"No hidden or deleted %@ found in the archive for this account.", kind]];
}

// Preserve loaded results on refresh failure; an empty list offers retry.
- (void)apollo_showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Fetch Hidden Content"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    if (!self.loaded) {
        [self apollo_showStatusText:@"Couldn't load results. Pull down to try again."];
    }
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
    [self apollo_fetchForceRefresh:YES];
}

@end
