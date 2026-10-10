// Native sidebar/detail containers for the opened Duo. The tab still owns its
// original ApolloNavigationController: URL routing, tab gestures and account
// switching can keep addressing that object. Only its visible contents change
// at an unfold/fold boundary. UIKit owns all column frames and transitions.
#import "ApolloDuoSplitView.h"
#import "ApolloMediaHinge.h"
#import "ApolloDuoSearchRecents.h"
#import "ApolloDuoAccount.h"
#import "ApolloDuoSubsChrome.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoUIKitCompatibility.h"
#import "ApolloSearchNativeBar.h"
#import "ApolloFeedShortcutsAppearance.h"
#import "ApolloFollowingSection.h"
#import "ApolloSwiftRuntime.h"
#import "settings/CustomAPIViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>

static UITableView *ApolloDuoSplitFindTable(UIView *view);
static void ApolloDuoPostsStopGeometry(UIView *feed);
@class ApolloDuoSplitHost;
static void ApolloDuoToggleFeedLayout(ApolloDuoSplitHost *host);
static void ApolloDuoToggleVisibleFeedLayout(UIViewController *controller, BOOL enabled);

@protocol ApolloDuoLayoutControl <NSObject>
- (void)updateFeedLayoutButton;
@end

static NSHashTable<id<ApolloDuoLayoutControl>> *sDuoLayoutControls;
static BOOL sDuoFeedLayoutChanging;

static void ApolloDuoRegisterLayoutControl(id<ApolloDuoLayoutControl> control) {
    if (!sDuoLayoutControls) sDuoLayoutControls = [NSHashTable weakObjectsHashTable];
    [sDuoLayoutControls addObject:control];
}

static UIImage *ApolloDuoFeedLayoutImage(void) {
    static UIImage *originalImage, *focusedImage;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        originalImage = [UIImage systemImageNamed:@"rectangle"];
        focusedImage = [UIImage systemImageNamed:@"rectangle.center.inset.filled"];
    });
    return sDuoLandscapeFeedLayout == 2 ? focusedImage : originalImage;
}

static void ApolloDuoRefreshLayoutButton(UIButton *button, UIBarButtonItem *item) {
    BOOL focused = sDuoLandscapeFeedLayout == 2;
    UIImage *image = ApolloDuoFeedLayoutImage();
    if (button.configuration.image != image) {
        UIButtonConfiguration *configuration = [button.configuration copy];
        configuration.image = image;
        button.configuration = configuration;
    }
    if (item.image != image) item.image = image;
    button.accessibilityValue = focused ? @"Focused feed" : @"Original";
    button.accessibilityHint = focused ? @"Switch to Original feed" : @"Switch to Focused feed";
    if (button.enabled == sDuoFeedLayoutChanging) button.enabled = !sDuoFeedLayoutChanging;
    item.accessibilityValue = button.accessibilityValue ?: (focused ? @"Focused feed" : @"Original");
    item.accessibilityHint = button.accessibilityHint ?: (focused ? @"Switch to Original feed" : @"Switch to Focused feed");
    if (item.enabled == sDuoFeedLayoutChanging) item.enabled = !sDuoFeedLayoutChanging;
}

static void ApolloDuoRefreshLayoutControls(void) {
    for (id<ApolloDuoLayoutControl> control in sDuoLayoutControls.allObjects)
        [control updateFeedLayoutButton];
}

// Each account column owns its vertical origin independently. Overview and
// the menu sit below the shared profile header; destinations use the entire
// secondary column without resizing or re-laying out that header.
@interface ApolloDuoAccountColumn : UIViewController
@property(nonatomic, strong) UINavigationController *navigation;
@property(nonatomic, strong) NSLayoutConstraint *topConstraint;
@property(nonatomic) CGFloat contentTop;
@property(nonatomic, copy) dispatch_block_t geometryDidChange;
@property(nonatomic) CGRect reportedFrame;
@property(nonatomic) UIEdgeInsets reportedMargins;
@property(nonatomic) BOOL hasReportedFrame;
@end
@implementation ApolloDuoAccountColumn
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    [self addChildViewController:self.navigation];
    UIView *content = self.navigation.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    self.topConstraint = [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:self.contentTop];
    [NSLayoutConstraint activateConstraints:@[
        self.topConstraint,
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.navigation didMoveToParentViewController:self];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self reportGeometryChange];
}
- (void)viewLayoutMarginsDidChange {
    [super viewLayoutMarginsDidChange];
    [self reportGeometryChange];
}
- (void)reportGeometryChange {
    // UISplitViewController can settle its column after the host's layout pass
    // when unfolding. Fold margins can settle later still, without changing
    // its frame. Notify for either change so the host's native button follows.
    CGRect frame = [self.view convertRect:self.view.bounds toView:self.splitViewController.view];
    UIEdgeInsets margins = self.view.layoutMargins;
    if (self.hasReportedFrame && CGRectEqualToRect(frame, self.reportedFrame)
        && UIEdgeInsetsEqualToEdgeInsets(margins, self.reportedMargins)) return;
    self.reportedFrame = frame;
    self.reportedMargins = margins;
    self.hasReportedFrame = YES;
    if (self.geometryDidChange) dispatch_async(dispatch_get_main_queue(), self.geometryDidChange);
}
- (void)setContentTop:(CGFloat)contentTop {
    _contentTop = contentTop;
    if (fabs(self.topConstraint.constant - contentTop) > 0.5) self.topConstraint.constant = contentTop;
}
@end

// The Overview caption is Texture content, not a UITableView section header.
// Find its already loaded title node without making offscreen nodes load views.
static UIView *ApolloDuoOverviewTitleView(id node) {
    if (!node) return nil;
    Ivar title = class_getInstanceVariable([node class], "titleTextNode");
    if (title) {
        UIView *view = ApolloDuoOverviewTitleView(object_getIvar(node, title));
        if (view) return view;
    }
    SEL textSelector = NSSelectorFromString(@"attributedText");
    if ([node respondsToSelector:textSelector]) {
        NSAttributedString *text = ((id (*)(id, SEL))objc_msgSend)(node, textSelector);
        SEL loadedSelector = NSSelectorFromString(@"isNodeLoaded");
        if ([text.string caseInsensitiveCompare:@"Overview"] == NSOrderedSame && text.length
            && [node respondsToSelector:loadedSelector]
            && ((BOOL (*)(id, SEL))objc_msgSend)(node, loadedSelector)) {
            return ((id (*)(id, SEL))objc_msgSend)(node, @selector(view));
        }
    }
    SEL children = NSSelectorFromString(@"subnodes");
    if ([node respondsToSelector:children]) {
        for (id child in ((id (*)(id, SEL))objc_msgSend)(node, children)) {
            UIView *view = ApolloDuoOverviewTitleView(child);
            if (view) return view;
        }
    }
    return nil;
}

// UINavigationController forbids a UISplitViewController as a stack entry.
// A plain containment host keeps Apollo's tab navigation identity intact while
// the split controller remains a proper child and owns its own column layout.
// UIKit can coalesce a newly revealed glass view's initial and final
// transforms in one transaction. Supply explicit endpoints so reveal and
// dismiss still travel across the screen on that first visible frame.
@interface ApolloDuoSlideCompletion : NSObject <CAAnimationDelegate>
@property(nonatomic, copy) dispatch_block_t completion;
@property(nonatomic) CFTimeInterval started;
@end
@implementation ApolloDuoSlideCompletion
- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
    ApolloLog(@"[DuoSplit] slide stopped finished=%d elapsed=%.3f", finished, CACurrentMediaTime() - self.started);
    if (finished && self.completion) self.completion();
}
@end

static void ApolloDuoSlideView(UIView *view, CGFloat from, CGFloat to, NSTimeInterval duration, dispatch_block_t completion) {
    [view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    view.transform = CGAffineTransformMakeTranslation(to, 0);
    if (duration <= 0) {
        if (completion) completion();
        return;
    }
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform"];
    slide.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(from, 0, 0)];
    slide.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(to, 0, 0)];
    slide.duration = duration;
    slide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    // Tie cleanup to this animation, not UIKit's surrounding transaction.
    // A disabled-action navigation transaction can finish before the explicit
    // slide and otherwise hide the drawer at the beginning of dismissal.
    ApolloDuoSlideCompletion *delegate = [ApolloDuoSlideCompletion new];
    delegate.completion = completion;
    delegate.started = CACurrentMediaTime();
    slide.delegate = delegate;
    ApolloLog(@"[DuoSplit] slide from=%.1f to=%.1f duration=%.2f", from, to, duration);
    [view.layer addAnimation:slide forKey:@"ApolloDuoSlide"];
}

@interface ApolloDuoSplitHost : UIViewController <UISplitViewControllerDelegate, ApolloDuoLayoutControl>
@property(nonatomic, strong) UISplitViewController *split;
@property(nonatomic, strong) UINavigationController *subredditList;
@property(nonatomic, weak) UINavigationController *postsNavigation;
@property(nonatomic, strong) UIView *listContainer;
@property(nonatomic, strong) UIVisualEffectView *listGlass;
@property(nonatomic, strong) UINavigationBar *listNavigationBar;
@property(nonatomic, strong) UIControl *listDismiss;
@property(nonatomic, strong) UIButton *listButton;
@property(nonatomic) BOOL listVisible;
@property(nonatomic) BOOL postsShowingDetail;
@property(nonatomic) BOOL postsSplitEnabled;
@property(nonatomic) BOOL postsColumnsPaired;
@property(nonatomic, strong) UIView *postsTransitionSnapshot;
@property(nonatomic, weak) UINavigationController *searchNavigation;
@property(nonatomic) NSUInteger listAnimationGeneration;
@property(nonatomic, strong) UIButton *splitButton;
@property(nonatomic, strong) UIButton *feedLayoutButton;
@property(nonatomic, strong) UIBarButtonItem *listBarItem;
@property(nonatomic, strong) UIBarButtonItem *splitBarItem;
@property(nonatomic, strong) UIBarButtonItem *feedLayoutBarItem;
@property(nonatomic, weak) UIViewController *feedControlsOwner;
@property(nonatomic) BOOL pendingFeedControlsReveal;
- (void)revealRestoredFeedControls;
@property(nonatomic, copy) void (^togglePostsSplit)(void);
@property(nonatomic, strong) NSMapTable *listBackgrounds;
@property(nonatomic) BOOL updatingListSurfaces;
@property(nonatomic) UIEdgeInsets originalListInsets;
@property(nonatomic) BOOL splitSafeAreaSyncScheduled;
@property(nonatomic) NSInteger splitSafeAreaAttempts;
- (void)scheduleSplitSafeAreaSync;
- (void)syncSplitSafeArea;
- (void)repairSplitSafeAreaNow;
- (void)restoreListBackgrounds;
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated;
@property(nonatomic, strong) UIView *accountHeader;
@property(nonatomic, strong) UIView *accountHeaderClip;
@property(nonatomic, strong) ApolloDuoAccountColumn *accountPrimary;
@property(nonatomic, strong) ApolloDuoAccountColumn *accountSecondary;
@property(nonatomic, strong) NSNumber *pendingAccountDetail;
@property(nonatomic, strong) NSNumber *accountDisplayMode;
@property(nonatomic) CGFloat overviewTopAdjustment;
@property(nonatomic) BOOL overviewAlignmentPending;
@property(nonatomic, copy) NSArray *overviewAlignmentGeometry;
- (void)scheduleOverviewAlignment;
@property(nonatomic, strong) NSLayoutConstraint *contentTopConstraint;
@property(nonatomic, strong) UIButton *accountsButton;
@property(nonatomic, strong) UIButton *moreButton;
@property(nonatomic, strong) UINavigationBar *sidebarNavigationBar;
@property(nonatomic, strong) UIButton *profileBackButton;
@end
@implementation ApolloDuoSplitHost
- (void)viewDidLoad {
    [super viewDidLoad];
    self.split.delegate = self;
    [self addChildViewController:self.split];
    UIView *content = self.split.view;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    self.contentTopConstraint = [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:0];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.contentTopConstraint,
        [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.split didMoveToParentViewController:self];
    if (self.subredditList) {
        self.listDismiss = [UIControl new];
        self.listDismiss.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.12];
        [self.listDismiss addTarget:self action:@selector(dismissList) forControlEvents:UIControlEventTouchUpInside];
        self.listDismiss.hidden = YES;
        [self.view addSubview:self.listDismiss];
        UIVisualEffect *effect;
        if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        else effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        self.listGlass = [[UIVisualEffectView alloc] initWithEffect:effect];
        self.listGlass.layer.cornerRadius = 28;
        self.listGlass.clipsToBounds = YES;
        // Move a plain container so the material and list travel together.
        // UIVisualEffectView manages its own compositor geometry.
        self.listContainer = [UIView new];
        self.listContainer.hidden = YES;
        [self.view addSubview:self.listContainer];
        self.listGlass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.listContainer addSubview:self.listGlass];
        // A managed bar joins Duo's global vertical navigation rail even
        // inside this narrow drawer. A standalone native bar keeps Apollo's
        // actual items horizontal and derives its height from UIKit.
        self.listNavigationBar = [UINavigationBar new];
        self.listNavigationBar.translatesAutoresizingMaskIntoConstraints = NO;
        self.listNavigationBar.tintColor = ApolloNavigationChromeColor();
        UINavigationBarAppearance *listAppearance = [UINavigationBarAppearance new];
        [listAppearance configureWithTransparentBackground];
        self.listNavigationBar.standardAppearance = listAppearance;
        self.listNavigationBar.scrollEdgeAppearance = listAppearance;
        self.listNavigationBar.compactAppearance = listAppearance;
        [self.listNavigationBar setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
        [self.listGlass.contentView addSubview:self.listNavigationBar];
        [self.subredditList setNavigationBarHidden:YES animated:NO];
        [self addChildViewController:self.subredditList];
        UIView *list = self.subredditList.view;
        list.translatesAutoresizingMaskIntoConstraints = NO;
        [self.listGlass.contentView addSubview:list];
        [NSLayoutConstraint activateConstraints:@[
            [self.listNavigationBar.topAnchor constraintEqualToAnchor:self.listGlass.contentView.topAnchor constant:12],
            // UIKit adds 8pt before the native Add platter but places Edit
            // flush with the bar's trailing edge. Both visible platters need
            // the same 20pt inset from the rounded drawer, including Done.
            [self.listNavigationBar.leadingAnchor constraintEqualToAnchor:self.listGlass.contentView.leadingAnchor constant:12],
            [self.listNavigationBar.trailingAnchor constraintEqualToAnchor:self.listGlass.contentView.trailingAnchor constant:-20],
            [list.topAnchor constraintEqualToAnchor:self.listNavigationBar.bottomAnchor constant:8],
            [list.bottomAnchor constraintEqualToAnchor:self.listGlass.contentView.bottomAnchor],
            [list.leadingAnchor constraintEqualToAnchor:self.listGlass.contentView.leadingAnchor],
            [list.trailingAnchor constraintEqualToAnchor:self.listGlass.contentView.trailingAnchor]
        ]];
        [self.subredditList didMoveToParentViewController:self];
        ApolloDuoSubsChromeSetPopupNavigationBar(self.subredditList.viewControllers.firstObject,
                                                self.listNavigationBar);
        const CGFloat controlSize = 48;
        self.listButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *configuration;
        if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
        else configuration = [UIButtonConfiguration tintedButtonConfiguration];
        configuration.image = [UIImage systemImageNamed:@"list.bullet"];
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        self.listButton.configuration = configuration;
        self.listButton.accessibilityLabel = @"Subreddit List";
        [self.listButton addTarget:self action:@selector(toggleList) forControlEvents:UIControlEventTouchUpInside];
        self.listButton.frame = CGRectMake(0, 0, controlSize, controlSize);
        self.listBarItem = [[UIBarButtonItem alloc] initWithCustomView:self.listButton];
        self.listBarItem.title = @"Subreddit List";
        self.listBarItem.image = configuration.image;
        self.listBarItem.target = self;
        self.listBarItem.action = @selector(toggleList);
        self.splitButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *splitConfiguration = [configuration copy];
        splitConfiguration.image = [UIImage systemImageNamed:@"rectangle.split.2x1"];
        self.splitButton.configuration = splitConfiguration;
        self.splitButton.accessibilityLabel = @"Toggle Feed and Comments Split";
        [self.splitButton addTarget:self action:@selector(toggleSplit) forControlEvents:UIControlEventTouchUpInside];
        self.splitButton.frame = CGRectMake(0, 0, controlSize, controlSize);
        self.splitBarItem = [[UIBarButtonItem alloc] initWithCustomView:self.splitButton];
        self.splitBarItem.title = @"Toggle Feed and Comments Split";
        self.splitBarItem.target = self;
        self.splitBarItem.action = @selector(toggleSplit);
        [self updateSplitButton];
        self.feedLayoutButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *layoutConfiguration = [configuration copy];
        self.feedLayoutButton.configuration = layoutConfiguration;
        self.feedLayoutButton.accessibilityLabel = @"Feed Layout";
        [self.feedLayoutButton addTarget:self action:@selector(toggleFeedLayout) forControlEvents:UIControlEventTouchUpInside];
        [self updateFeedLayoutButton];
        self.feedLayoutButton.frame = CGRectMake(0, 0, controlSize, controlSize);
        self.feedLayoutBarItem = [[UIBarButtonItem alloc] initWithCustomView:self.feedLayoutButton];
        self.feedLayoutBarItem.title = @"Feed Layout";
        self.feedLayoutBarItem.image = self.feedLayoutButton.configuration.image;
        self.feedLayoutBarItem.target = self;
        self.feedLayoutBarItem.action = @selector(toggleFeedLayout);
        if (@available(iOS 26.0, *)) {
            // Match each persistent control across native navigation changes.
            // The shared accessibility ID below identifies the whole family,
            // whereas UIKit needs a distinct transition identity for each role.
            self.listBarItem.identifier = @"ApolloReborn.duo-list";
            self.splitBarItem.identifier = @"ApolloReborn.duo-split";
            self.feedLayoutBarItem.identifier = @"ApolloReborn.duo-feed-layout";
        }
        for (UIBarButtonItem *item in @[self.listBarItem, self.splitBarItem, self.feedLayoutBarItem]) {
            // UIKit applies compact sizing directly to UIButton custom views
            // and gives these bar items a 48pt minimum width. Match that with
            // a square host so the glass background remains circular.
            UIView *button = item.customView;
            button.alpha = self.pendingFeedControlsReveal ? 0 : 1;
            UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, controlSize, controlSize)];
            button.translatesAutoresizingMaskIntoConstraints = NO;
            item.customView = container;
            [container addSubview:button];
            [NSLayoutConstraint activateConstraints:@[
                [container.widthAnchor constraintEqualToConstant:controlSize],
                [container.heightAnchor constraintEqualToConstant:controlSize],
                [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
                [button.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
                [button.topAnchor constraintEqualToAnchor:container.topAnchor],
                [button.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
            ]];
            if (@available(iOS 26.0, *)) item.hidesSharedBackground = YES;
            if (@available(iOS 27.1, *)) item.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
        }
        self.originalListInsets = self.subredditList.topViewController.additionalSafeAreaInsets;
        [self.subredditList setNavigationBarHidden:YES animated:NO];
    }
    if (self.accountHeader) {
        self.accountHeaderClip = [UIView new];
        self.accountHeaderClip.clipsToBounds = YES;
        [self.accountHeaderClip addSubview:self.accountHeader];
        [self.view addSubview:self.accountHeaderClip];
        [self.view addSubview:self.accountsButton];
        [self.view addSubview:self.moreButton];
        [self.view addSubview:self.sidebarNavigationBar];
        if (self.profileBackButton) [self.view addSubview:self.profileBackButton];
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    self.pendingFeedControlsReveal = NO;
    if (self.subredditList) {
        for (UIButton *button in @[self.listButton, self.splitButton, self.feedLayoutButton]) {
            button.alpha = 1;
            [button.layer removeAnimationForKey:@"ApolloDuoControlsReveal"];
        }
    }
    if (self.subredditList) [self setListVisible:NO animated:NO];
    [self.postsTransitionSnapshot removeFromSuperview];
    self.postsTransitionSnapshot = nil;
    ApolloDuoPostsStopGeometry(self.searchNavigation.viewIfLoaded);
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    ApolloDuoPostsStopGeometry(self.searchNavigation.viewIfLoaded);
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}
- (void)prepareListGlass {
    ApolloDuoSplitPrepareOverlaySurface(self.subredditList.view);
}
- (void)endListEditing {
    UIViewController *root = self.subredditList.viewControllers.firstObject;
    if (root.isEditing) [root setEditing:NO animated:NO];
}
- (void)restoreListBackgrounds {
    [self endListEditing];
    ApolloDuoSubsChromeSetPopupNavigationBar(self.subredditList.viewControllers.firstObject, nil);
    self.updatingListSurfaces = YES;
    for (UIView *view in self.listBackgrounds) {
        id color = [self.listBackgrounds objectForKey:view];
        view.backgroundColor = color == NSNull.null ? nil : color;
    }
    self.updatingListSurfaces = NO;
    self.listBackgrounds = nil;
    self.subredditList.viewControllers.firstObject.additionalSafeAreaInsets = self.originalListInsets;
    [self.subredditList setNavigationBarHidden:NO animated:NO];
}
- (void)updateSplitButton {
    UIImage *symbol = [UIImage systemImageNamed:@"rectangle.split.2x1"];
    if (!self.postsSplitEnabled) {
        // One template image lets the glass button resolve the slash and the
        // symbol together, including appearance and accessibility changes.
        // A separate CGColor layer captures the pre-window system-blue tint.
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:symbol.size];
        symbol = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[symbol imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal]
                drawAtPoint:CGPointZero];
            [UIColor.blackColor setStroke];
            UIBezierPath *slash = [UIBezierPath bezierPath];
            [slash moveToPoint:CGPointMake(1, symbol.size.height - 1)];
            [slash addLineToPoint:CGPointMake(symbol.size.width - 1, 1)];
            slash.lineWidth = 1.5;
            slash.lineCapStyle = kCGLineCapRound;
            [slash stroke];
        }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    UIButtonConfiguration *configuration = [self.splitButton.configuration copy];
    configuration.image = symbol;
    // The slashed state is a rendered template rather than an SF Symbol.
    // Give both states the navigation foreground so glass does not dim the
    // available toggle merely because its image representation changed.
    configuration.baseForegroundColor = ApolloNavigationChromeColor();
    self.splitButton.configuration = configuration;
    self.splitBarItem.image = symbol;
    self.splitButton.accessibilityValue = self.postsSplitEnabled ? @"On" : @"Off";
}
- (void)toggleSplit {
    if (self.togglePostsSplit) self.togglePostsSplit();
}
- (void)updateFeedLayoutButton {
    ApolloDuoRegisterLayoutControl(self);
    ApolloDuoRefreshLayoutButton(self.feedLayoutButton, self.feedLayoutBarItem);
}
- (void)toggleFeedLayout { ApolloDuoToggleFeedLayout(self); }
- (void)revealRestoredFeedControls {
    if (!self.pendingFeedControlsReveal) return;
    // Buttons start transparent before native item registration. Reveal after
    // the full split update (including idle tabs) has finished, so setup work
    // cannot consume the animation before the new navigation bar is visible.
    [self.view layoutIfNeeded];
    [self.feedControlsOwner.navigationController.navigationBar layoutIfNeeded];
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIButton *button in @[self.listButton, self.splitButton, self.feedLayoutButton]) {
        if (!button.hidden && button.window) [buttons addObject:button];
        else if (button.hidden) button.alpha = 1;
    }
    if (!buttons.count) return;
    self.pendingFeedControlsReveal = NO;
    BOOL visible = self.navigationController.topViewController == self
        && self.navigationController.tabBarController.selectedViewController == self.navigationController;
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    NSTimeInterval duration = reduceMotion ? 0.18 : 0.28;
    for (UIView *button in buttons) {
        button.alpha = 1;
        if (!visible) continue;
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0;
        fade.toValue = @1;
        fade.duration = duration;
        CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        scale.fromValue = @0.92;
        scale.toValue = @1;
        scale.duration = duration;
        CAAnimationGroup *reveal = [CAAnimationGroup animation];
        reveal.animations = reduceMotion ? @[fade] : @[fade, scale];
        reveal.duration = duration;
        reveal.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        // Explicit endpoints survive the nonanimated containment transaction.
        // Model alpha/transform stay final, so interruption or folding cannot
        // leave a retained control faded out or scaled down.
        [button.layer addAnimation:reveal forKey:@"ApolloDuoControlsReveal"];
    }
    ApolloLog(@"[DuoSplit] revealing %lu restored feed controls", (unsigned long)buttons.count);
}
- (void)toggleList { [self setListVisible:!self.listVisible animated:YES]; }
- (void)dismissList { [self setListVisible:NO animated:YES]; }
- (void)setListVisible:(BOOL)visible animated:(BOOL)animated {
    if (!self.subredditList) return;
    if (!visible) [self endListEditing];
    if (self.listVisible == visible) return;
    [self.view layoutIfNeeded];
    BOOL wasHidden = self.listContainer.hidden;
    CGFloat start = wasHidden ? -self.listGlass.bounds.size.width - 12
        : (self.listContainer.layer.presentationLayer ?: self.listContainer.layer).transform.m41;
    self.listVisible = visible;
    [self.view setNeedsLayout];
    if (visible) {
        // Material must be cleared after UIKit installs its initial light-mode
        // table background, before exposing the drawer.
        [self.subredditList.view layoutIfNeeded];
        UITableView *table = ApolloDuoSplitFindTable(self.subredditList.view);
        // Reset before the first reveal frame, after the drawer's safe-area
        // layout, so reopening always starts with the feed shortcuts.
        [table setContentOffset:CGPointMake(-table.adjustedContentInset.left,
                                           -table.adjustedContentInset.top) animated:NO];
        [table layoutIfNeeded];
        [self prepareListGlass];
    }
    self.listDismiss.hidden = NO;
    self.listContainer.hidden = NO;
    NSUInteger generation = ++self.listAnimationGeneration;
    NSTimeInterval duration = animated && !UIAccessibilityIsReduceMotionEnabled() ? 0.32 : 0;
    [UIView animateWithDuration:duration animations:^{ self.listDismiss.alpha = visible ? 1 : 0; }];
    __weak typeof(self) weakSelf = self;
    ApolloDuoSlideView(self.listContainer, start, visible ? 0 : -self.listGlass.bounds.size.width - 12, duration, ^{
        if (weakSelf.listAnimationGeneration != generation) return;
        weakSelf.listContainer.hidden = !weakSelf.listVisible;
        weakSelf.listDismiss.hidden = !weakSelf.listVisible;
    });
}
- (void)splitViewController:(UISplitViewController *)splitViewController willChangeToDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    if (!self.accountHeader) return;
    // The host is outside UIKit's column hierarchy, so a column-only change
    // need not lay it out. Use the announced mode (displayMode still reports
    // the old value here) to move the header mask and sidebar control with it.
    self.accountDisplayMode = @(displayMode);
    void (^layout)(void) = ^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    };
    id<UIViewControllerTransitionCoordinator> coordinator = splitViewController.transitionCoordinator;
    if (![coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        layout();
    } completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        self.accountDisplayMode = @(splitViewController.displayMode);
        layout();
    }]) layout();
}
- (void)scheduleOverviewAlignment {
    if (!self.accountHeader || self.overviewAlignmentPending) return;
    self.overviewAlignmentPending = YES;
    __weak ApolloDuoSplitHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDuoSplitHost *host = weakSelf;
        host.overviewAlignmentPending = NO;
        if (!host.viewIfLoaded.window || host.pendingAccountDetail.boolValue
            || host.accountSecondary.navigation.viewControllers.count != 1) return;
        UITableView *shortcuts = ApolloDuoSplitFindTable(host.accountPrimary.navigation.topViewController.viewIfLoaded);
        UITableView *overview = ApolloDuoSplitFindTable(host.accountSecondary.navigation.topViewController.viewIfLoaded);
        if (!shortcuts.window || !overview.window || !ApolloDuoAccountIsOverviewTable(overview)
            || shortcuts.numberOfSections == 0 || [shortcuts numberOfRowsInSection:0] == 0) return;
        SEL nodeSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
        if (![overview respondsToSelector:nodeSelector] || overview.numberOfSections == 0) return;
        NSArray *geometry = @[[NSValue valueWithCGSize:shortcuts.bounds.size],
                              [NSValue valueWithCGSize:overview.bounds.size],
                              [NSValue valueWithCGSize:shortcuts.contentSize],
                              [NSValue valueWithCGSize:overview.contentSize],
                              [NSValue valueWithUIEdgeInsets:shortcuts.adjustedContentInset],
                              [NSValue valueWithUIEdgeInsets:overview.adjustedContentInset],
                              @(sShowDetailedProfiles), @(sProfileHeaderImmersive)];
        if ([host.overviewAlignmentGeometry isEqual:geometry]) return;
        UIView *heading = nil;
        NSInteger count = MIN([overview numberOfRowsInSection:0], 50);
        for (NSInteger row = 0; row < count; row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
            if (ApolloDuoAccountHidesProfileRow(overview, path)) continue;
            id node = ((id (*)(id, SEL, id))objc_msgSend)(overview, nodeSelector, path);
            heading = ApolloDuoOverviewTitleView(node);
            // Only the first exposed row is the dashboard heading. Never
            // align a caption/title belonging to a later activity item.
            break;
        }
        if (!heading.window || ![heading isDescendantOfView:overview]) return;
        CGRect shortcut = [shortcuts rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIView *leftNavigation = host.accountPrimary.navigation.view;
        UIView *rightNavigation = host.accountSecondary.navigation.view;
        CGFloat leftOrigin = CGRectGetMinY([host.view convertRect:leftNavigation.bounds fromView:leftNavigation]);
        CGFloat rightOrigin = CGRectGetMinY([host.view convertRect:rightNavigation.bounds fromView:rightNavigation]);
        CGFloat left = CGRectGetMinY([host.view convertRect:shortcut fromView:shortcuts])
            + shortcuts.contentOffset.y + shortcuts.adjustedContentInset.top - leftOrigin;
        CGFloat right = CGRectGetMinY([host.view convertRect:heading.bounds fromView:heading])
            + overview.contentOffset.y + overview.adjustedContentInset.top - rightOrigin;
        // Remove each table's scrolling and current column origin before
        // comparing. The correction therefore cannot follow or undo a scroll.
        CGFloat adjustment = left - right;
        if (!isfinite(adjustment) || fabs(adjustment) > 150) return;
        host.overviewAlignmentGeometry = geometry;
        if (fabs(adjustment - host.overviewTopAdjustment) < 0.5) return;
        host.overviewTopAdjustment = adjustment;
        [host.view setNeedsLayout];
        ApolloLog(@"[DuoSplit] Overview top alignment left=%.1f right=%.1f adjustment=%.1f", left, right, adjustment);
    });
}
// The split fills this host, so its safe area must equal the host's. After a
// Closed portrait -> Open landscape -> portrait sequence UIKit can leave the
// split (and every page inside it) holding the landscape rail's {0,0,34,84}
// insets while the host and its bottom tab bar already report the portrait
// ones. Pages then reserve an 84pt trailing strip: posts are pushed left and
// the navigation pill lands under the status region. Bounded: at most a few
// attempts per stale episode, never a feedback loop.
- (void)scheduleSplitSafeAreaSync {
    if (self.splitSafeAreaSyncScheduled) return;
    self.splitSafeAreaSyncScheduled = YES;
    __weak ApolloDuoSplitHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloDuoSplitHost *host = weakSelf;
        if (!host) return;
        host.splitSafeAreaSyncScheduled = NO;
        [host syncSplitSafeArea];
    });
}
static BOOL ApolloDuoSafeAreaInsetsMatch(UIEdgeInsets a, UIEdgeInsets b) {
    return fabs(a.top - b.top) < 0.5 && fabs(a.left - b.left) < 0.5
        && fabs(a.bottom - b.bottom) < 0.5 && fabs(a.right - b.right) < 0.5;
}
- (void)syncSplitSafeArea {
    [self syncSplitSafeAreaWaiting:YES];
}
// A rotation or fold has just finished laying out: the host is settled, so a
// remaining mismatch is real and is repaired at once (no visible wrong frame).
- (void)repairSplitSafeAreaNow {
    [self syncSplitSafeAreaWaiting:NO];
}
- (void)syncSplitSafeAreaWaiting:(BOOL)waiting {
    UIView *hostView = self.viewIfLoaded;
    UIView *splitView = self.split.viewIfLoaded;
    if (!hostView.window || !splitView.window || (waiting && ApolloDuoSplitIsResizing())) return;
    // Only a split that fills the host inherits the host's safe area verbatim.
    if (fabs(splitView.frame.origin.x) > 1.0 || fabs(splitView.frame.origin.y) > 1.0
        || fabs(CGRectGetWidth(splitView.frame) - CGRectGetWidth(hostView.bounds)) > 1.0
        || fabs(CGRectGetHeight(splitView.frame) - CGRectGetHeight(hostView.bounds)) > 1.0) return;
    UIEdgeInsets want = hostView.safeAreaInsets;
    UIEdgeInsets have = splitView.safeAreaInsets;
    if (ApolloDuoSafeAreaInsetsMatch(want, have)) {
        self.splitSafeAreaAttempts = 0;
        return;
    }
    if (self.splitSafeAreaAttempts >= 3) return;
    self.splitSafeAreaAttempts++;
    // Host and split legitimately disagree for a moment during a rotation or
    // fold. Only intervene when the mismatch survives a full re-check.
    if (waiting && self.splitSafeAreaAttempts == 1) {
        __weak ApolloDuoSplitHost *weakFirst = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakFirst scheduleSplitSafeAreaSync]; });
        return;
    }
    ApolloLog(@"[DuoSplit] split safe area stale (attempt %ld): host=%@ split=%@",
              (long)self.splitSafeAreaAttempts, NSStringFromUIEdgeInsets(want), NSStringFromUIEdgeInsets(have));
    // Nothing writable recomputes the stale value: neither the split's nor the
    // host's additionalSafeAreaInsets moves it. Re-attaching the split's view
    // makes UIKit derive its safe area from the host afresh. Same frame, same
    // controller: scroll positions and navigation state are untouched.
    UIView *content = splitView;
    [UIView performWithoutAnimation:^{
        [content removeFromSuperview];
        [self.view insertSubview:content atIndex:0];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        self.contentTopConstraint = [content.topAnchor constraintEqualToAnchor:self.view.topAnchor
                                                                      constant:self.contentTopConstraint.constant];
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            self.contentTopConstraint,
            [content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
        [self.view layoutIfNeeded];
    }];
    ApolloLog(@"[DuoSplit] split safe area after remount: host=%@ split=%@",
              NSStringFromUIEdgeInsets(hostView.safeAreaInsets), NSStringFromUIEdgeInsets(splitView.safeAreaInsets));
    // Re-verify once UIKit has settled the transition.
    __weak ApolloDuoSplitHost *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf scheduleSplitSafeAreaSync]; });
}
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self scheduleSplitSafeAreaSync];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self scheduleSplitSafeAreaSync];
    if (self.subredditList) {
        CGFloat width = MIN(360, self.view.bounds.size.width - 96);
        self.listDismiss.frame = self.view.bounds;
        // Bounds/center stay independent of the presentation transform.
        self.listContainer.bounds = CGRectMake(0, 0, width, self.view.bounds.size.height - 24);
        self.listContainer.center = CGPointMake(12 + width / 2, self.view.bounds.size.height / 2);
        self.listGlass.frame = self.listContainer.bounds;
        BOOL portrait = self.view.bounds.size.width <= self.view.bounds.size.height;
        // The drawer covers/intercepts its underlying controls. Keep the
        // navigation items installed so opening it never reflows the bar.
        self.listButton.hidden = NO;
        self.splitButton.hidden = portrait;
        // UIKit lays out the real controls in the title row, above the search
        // field. They follow their content column and the bar's safe area.
        UINavigationController *navigation = self.postsNavigation;
        if (self.postsShowingDetail && !self.postsColumnsPaired) {
            UIViewController *secondary = [self.split viewControllerForColumn:UISplitViewControllerColumnSecondary];
            if ([secondary isKindOfClass:UINavigationController.class]) navigation = (id)secondary;
        }
        UIViewController *owner = navigation.topViewController;
        BOOL supportsLayout = [owner isKindOfClass:NSClassFromString(@"Apollo.PostsViewController")]
            || [owner isKindOfClass:NSClassFromString(@"Apollo.CommentsViewController")];
        // Carry the same control into full-width comments, just like List and
        // Split. Replacing it with the thread's standalone item makes its
        // glass and glyph disappear/reappear during the native push and Back.
        self.feedLayoutButton.hidden = portrait || !supportsLayout || self.postsColumnsPaired;
        if (self.feedControlsOwner != owner) {
            ApolloNativeFeedSearchSetDuoControls(self.feedControlsOwner, nil, nil, nil);
            self.feedControlsOwner = owner;
        }
        ApolloNativeFeedSearchSetDuoControls(owner,
            self.listButton.hidden ? nil : self.listBarItem,
            self.splitButton.hidden ? nil : self.splitBarItem,
            self.feedLayoutButton.hidden ? nil : self.feedLayoutBarItem);
    }
    if (!self.accountHeader) return;
    UISplitViewControllerDisplayMode displayMode = self.accountDisplayMode
        ? (UISplitViewControllerDisplayMode)self.accountDisplayMode.integerValue : self.split.displayMode;
    CGFloat headerHeight = ApolloDuoAccountHeaderHeight(self.accountHeader, self.view.bounds.size.width);
    UINavigationController *detail = self.accountSecondary.navigation;
    BOOL hasDetail = self.pendingAccountDetail ? self.pendingAccountDetail.boolValue : detail.viewControllers.count > 1;
    self.accountPrimary.contentTop = headerHeight;
    self.accountSecondary.contentTop = hasDetail ? 0
        : MAX(0, headerHeight + self.overviewTopAdjustment);
    if (!hasDetail) [self scheduleOverviewAlignment];
    UIView *primaryView = self.accountPrimary.viewIfLoaded;
    CGRect primaryFrame = [primaryView convertRect:primaryView.bounds toView:self.view];
    CGFloat sidebarRight = primaryView.superview && CGRectGetWidth(primaryFrame) > 0
        ? CGRectGetMaxX(primaryFrame) : self.split.primaryColumnWidth;
    CGFloat headerWidth = hasDetail ? sidebarRight : self.view.bounds.size.width;
    if (hasDetail && displayMode == UISplitViewControllerDisplayModeSecondaryOnly) headerWidth = 0;
    self.accountHeaderClip.frame = CGRectMake(0, 0, headerWidth, headerHeight);
    self.accountHeader.frame = CGRectMake(0, 0, self.view.bounds.size.width, headerHeight);
    // Follow the native primary column's trailing margin: it grows around an
    // active fold and returns to 20pt when flat. The native bar-item renderer
    // also supplies the same symbol size and vibrancy as Settings and Inbox.
    CGFloat sidebarTrailingMargin = MAX(20, primaryView.layoutMargins.right);
    CGFloat sidebarRightEdge = displayMode == UISplitViewControllerDisplayModeSecondaryOnly
        ? (self.profileBackButton ? 132 : 72) : MAX(72, sidebarRight - sidebarTrailingMargin);
    self.sidebarNavigationBar.frame = CGRectMake(sidebarRightEdge - 88,
        MAX(24, self.view.safeAreaInsets.top), 88, 58);
    self.profileBackButton.frame = CGRectMake(24, MAX(24, self.view.safeAreaInsets.top), 48, 48);
    self.moreButton.hidden = hasDetail;
    self.accountsButton.hidden = hasDetail;
    // Match the native rail's 48pt platter and 24pt physical edge inset.
    // The safe-area inset includes the rail and is not its visible center.
    CGFloat railX = self.view.bounds.size.width - 72;
    CGFloat statusBottom = CGRectGetMaxY(self.view.window.windowScene.statusBarManager.statusBarFrame);
    CGFloat railTop = MAX(124, statusBottom + 16);
    self.moreButton.frame = CGRectMake(railX, railTop, 48, 48);
    self.accountsButton.frame = CGRectMake(railX, railTop + 60, 48, 48);
}
@end

@interface ApolloDuoSplitState : NSObject
@property(nonatomic, weak) UINavigationController *outer;
@property(nonatomic, strong) UIViewController *root;
@property(nonatomic, strong) UISplitViewController *split;
@property(nonatomic, strong) ApolloDuoSplitHost *host;
@property(nonatomic, strong) UINavigationController *primary;
@property(nonatomic, strong) UINavigationController *secondary;
@property(nonatomic, strong) UINavigationController *feed;
@property(nonatomic, copy) NSArray *feedActions;
@property(nonatomic, strong) NSArray<UIViewController *> *lastSettings;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, copy) NSString *sidebarTitle;
// Pages preceding a visited profile stay in their original tab's Back stack.
@property(nonatomic, copy) NSArray<UIViewController *> *profilePrefix;
@property(nonatomic, strong) UIViewController *tabRoot;
@property(nonatomic, copy) NSString *tabKind;
@property(nonatomic) BOOL selectingAccountShortcut;
@property(nonatomic) BOOL changing;
@property(nonatomic) BOOL postsTogglingSplit;
@property(nonatomic) BOOL navigationBarWasHidden;
@property(nonatomic) BOOL needsDefault;
@property(nonatomic) BOOL halfWidthSidebar;
@property(nonatomic, weak) id<UIViewControllerTransitionCoordinator> pendingNavigationTransition;
@property(nonatomic, weak) UIViewController *searchBackPage;
@property(nonatomic, strong) UIBarButtonItem *searchBackItem;
@property(nonatomic) BOOL searchBackSupplementedNative;
@end
@implementation ApolloDuoSplitState @end

@interface ApolloDuoSplitReference : NSObject
@property(nonatomic, weak) ApolloDuoSplitState *state;
@end
@implementation ApolloDuoSplitReference @end

static char kDuoSplitState, kDuoSplitReference;
static char kDuoSplitHingeInteraction, kDuoSplitHingeStatus;
static BOOL sDuoSplitUpdateScheduled;
static BOOL sDuoSplitUpdating;
static NSHashTable<ApolloDuoSplitState *> *sDuoSplitDeferredPresentations;
static __weak UITabBarController *sDuoSplitKnownTabs;
static __weak UITabBarController *sDuoSplitResizingTabs;
static CGSize sDuoSplitTargetSize;
static __weak id<UIViewControllerTransitionCoordinator> sDuoSplitSizeCoordinator;

// Repair every Duo split host in this tab controller after its size change.
static void ApolloDuoSplitRepairSafeAreas(UITabBarController *tabs) {
    for (UIViewController *tab in tabs.viewControllers) {
        for (UIViewController *child in tab.childViewControllers) {
            if ([child isKindOfClass:ApolloDuoSplitHost.class]) [(ApolloDuoSplitHost *)child repairSplitSafeAreaNow];
        }
    }
}
BOOL ApolloDuoSplitIsResizing(void) {
    return sDuoSplitResizingTabs != nil;
}

BOOL ApolloDuoSplitIsUnfolded(void) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone
        || ![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return NO;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone) return NO;
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    return MIN(size.width, size.height) >= 600.0;
}

BOOL ApolloDuoSplitIsUnfoldedPortrait(void) {
    if (!ApolloDuoSplitIsUnfolded()) return NO;
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    return size.height > size.width;
}

// Apollo's native navigation delegate tests a 70pt edge band in its view.
// UIKit extends the secondary view under the sidebar and the trailing rail;
// translate only that delegate's location query into the visible pane's band.
static __thread void *sDuoSplitGesture;
static __thread void *sDuoSplitGestureView;
static __thread CGFloat sDuoSplitGestureOffset;

static NSString *ApolloDuoSplitKind(UIViewController *root) {
    NSString *name = NSStringFromClass(root.class);
    if ([name isEqualToString:@"Apollo.RedditListViewController"]) return @"subreddits";
    if ([name isEqualToString:@"Apollo.SettingsViewController"]) return @"settings";
    if ([name isEqualToString:@"Apollo.InboxListViewController"]) return @"inbox";
    if ([name isEqualToString:@"Apollo.ProfileViewController"]) return @"account";
    if ([name isEqualToString:@"Apollo.SearchViewController"]) return @"search";
    return nil;
}

static ApolloDuoSplitState *ApolloDuoSplitStateForNavigation(UINavigationController *nav, BOOL create) {
    ApolloDuoSplitReference *reference = objc_getAssociatedObject(nav, &kDuoSplitReference);
    if (reference.state) return reference.state;
    ApolloDuoSplitState *state = objc_getAssociatedObject(nav, &kDuoSplitState);
    if (!state && create && [nav.parentViewController isKindOfClass:UITabBarController.class]) {
        NSString *kind = ApolloDuoSplitKind(nav.viewControllers.firstObject);
        ApolloLog(@"[DuoSplit] tab root=%@ supported=%d", NSStringFromClass(nav.viewControllers.firstObject.class), kind != nil);
        if (kind) {
            state = [ApolloDuoSplitState new];
            state.outer = nav;
            state.root = nav.viewControllers.firstObject;
            state.kind = kind;
            objc_setAssociatedObject(nav, &kDuoSplitState, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return state;
}

// Node measurement can run while UIKit is moving the page between navigation
// controllers, before the new safe area exists. Use the destination column's
// width for that one transition, including offscreen rows measured by Texture.
CGFloat ApolloDuoSplitTransitionContentWidth(UIView *view, CGFloat trailingInset) {
    if (!sDuoSplitResizingTabs) return 0.0;
    UIViewController *owner = nil;
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            owner = (id)responder;
            break;
        }
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(owner.navigationController, NO);
    CGFloat width = sDuoSplitTargetSize.width;
    if (state.feed && state.split && MIN(sDuoSplitTargetSize.width, sDuoSplitTargetSize.height) >= 600) {
        if (owner.navigationController == state.primary) return MIN(360, width - 96);
        BOOL paired = state.host.postsSplitEnabled && sDuoSplitTargetSize.width > sDuoSplitTargetSize.height && (state.secondary.viewControllers.count > 1 || state.feed.viewControllers.count > 1);
        if (paired) width *= 0.5;
        BOOL feedColumn = paired && owner.navigationController == state.feed;
        return MAX(0, width - (!feedColumn && sDuoSplitTargetSize.width > sDuoSplitTargetSize.height ? trailingInset : 0));
    }
    if (state.split && width >= 800.0 && width > sDuoSplitTargetSize.height) {
        UISplitViewController *split = state.split;
        CGFloat primary = MIN(split.maximumPrimaryColumnWidth,
                              MAX(split.minimumPrimaryColumnWidth,
                                  width * split.preferredPrimaryColumnWidthFraction));
        // Ordinary tab roots live in the sidebar. Account's native profile
        // supplies Overview in the secondary pane beneath its shared header.
        if (owner == state.root && ![state.kind isEqualToString:@"account"]) return primary;
        width -= primary;
    }
    // The unfolded portrait layout uses a bottom tab bar. A narrow cover or
    // side window, and the unfolded landscape layout, use the trailing rail.
    BOOL trailingRail = sDuoSplitTargetSize.width > sDuoSplitTargetSize.height
        || sDuoSplitTargetSize.width < 600.0;
    return MAX(0.0, width - (trailingRail ? trailingInset : 0.0));
}

static void ApolloDuoSplitLink(UINavigationController *nav, ApolloDuoSplitState *state) {
    ApolloDuoSplitReference *reference = [ApolloDuoSplitReference new];
    reference.state = state;
    objc_setAssociatedObject(nav, &kDuoSplitReference, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UINavigationController *ApolloDuoSplitDetailNavigation(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    return state.split && !state.changing ? (state.feed && !state.host.postsShowingDetail ? state.feed : state.secondary) : nav;
}

UIViewController *ApolloDuoSplitRootController(UINavigationController *nav) {
    return ApolloDuoSplitStateForNavigation(nav, NO).root;
}

CGRect ApolloDuoSplitContentFrame(UIViewController *controller, UIView *coordinateView) {
    UINavigationController *nav = [controller isKindOfClass:UINavigationController.class] ? (id)controller : controller.navigationController;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    // Settings refreshes offscreen pages too. Their retained view hierarchy
    // still supplies the split geometry even while detached from the window.
    if (!state.split || (nav != state.secondary && nav != state.feed)) return CGRectNull;
    // Modern UIKit can extend the secondary surface beneath the sidebar. Its
    // safe-area guide, rather than its full bounds, is the visible column.
    UIView *view = nav.view;
    UIEdgeInsets insets = view.safeAreaInsets;
    // Center across the whole detail pane, including its trailing navigation
    // strip. Only the leading sidebar is excluded from this alignment band.
    insets.right = 0.0;
    CGRect content = UIEdgeInsetsInsetRect(view.bounds, insets);
    return [coordinateView convertRect:content fromView:view];
}

BOOL ApolloDuoSplitIsAccountFeedController(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || ![state.kind isEqualToString:@"account"]
        || ![state.secondary.viewControllers containsObject:controller]) return NO;
    // A real comment thread has depth and linked-comment highlight colors.
    // The profile and shortcut lists instead render independent feed cards.
    return ![NSStringFromClass(controller.class) isEqualToString:@"Apollo.CommentsViewController"];
}

BOOL ApolloDuoSplitIsOwnAccountController(UIViewController *controller) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !controller) return NO;
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *navigation = (id)child;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
        UIViewController *root = state.split ? (state.tabRoot ?: state.root) : navigation.viewControllers.firstObject;
        if (root == controller && [ApolloDuoSplitKind(root) isEqualToString:@"account"]) return YES;
    }
    return NO;
}

BOOL ApolloDuoSplitSuppressesFeedActions(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    // Portrait moves the comments stack onto this navigation controller.
    // Suppression belongs to its Posts root, not every page temporarily
    // sharing that controller during a rotation or fold transition.
    return state.feed && state.host.postsColumnsPaired
        && controller == state.feed.viewControllers.firstObject;
}

static ApolloDuoSplitHost *ApolloDuoSubredditOverlayHost(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIViewController *controller = (id)responder;
        UINavigationController *nav = [controller isKindOfClass:UINavigationController.class] ? (id)controller : controller.navigationController;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
        return state.feed && state.split && !state.changing && nav == state.primary ? state.host : nil;
    }
    return nil;
}

BOOL ApolloDuoSplitIsSubredditOverlayView(UIView *view) {
    return ApolloDuoSubredditOverlayHost(view) != nil;
}

// Only native list surfaces belong to the drawer material. Walking every
// descendant also erased the red removal badges and restored their old colors
// after folding. In particular, never traverse into controls or effect views.
static BOOL ApolloDuoListOwnsSurface(UIView *view, ApolloDuoSplitHost *host) {
    if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UILabel.class]
        || [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UIVisualEffectView.class]) return NO;
    UIView *list = host.subredditList.view;
    for (UIView *ancestor = view.superview; ancestor && ancestor != list; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UIControl.class] || [ancestor isKindOfClass:UIVisualEffectView.class]) return NO;
    }
    if (view == list || view == host.subredditList.viewControllers.firstObject.view
        || [view isKindOfClass:UITableView.class] || [view isKindOfClass:UITableViewCell.class]
        || [view isKindOfClass:UITableViewHeaderFooterView.class]) return YES;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"TableViewWrapper"] || [name containsString:@"TableViewCellContentView"]
        || [name containsString:@"SectionBackground"] || [name containsString:@"TableViewHeaderFooterContentView"]
        || [name isEqualToString:@"Apollo.RecreatedTableSectionHeaderView"]) return YES;
    UIView *parent = view.superview;
    if ([parent isKindOfClass:UITableView.class]) return ((UITableView *)parent).backgroundView == view;
    if ([parent isKindOfClass:UITableViewCell.class]) {
        UITableViewCell *cell = (id)parent;
        return cell.backgroundView == view || cell.selectedBackgroundView == view;
    }
    if ([parent isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (id)parent;
        return header.backgroundView == view || header.contentView == view;
    }
    return NO;
}

UIColor *ApolloDuoSplitOverlayBackground(UIView *view, UIColor *color) {
    if (!NSThread.isMainThread) return color;
    ApolloDuoSplitHost *host = ApolloDuoSubredditOverlayHost(view);
    if (!host || host.updatingListSurfaces || !ApolloDuoListOwnsSurface(view, host)) return color;
    if (!host.listBackgrounds) host.listBackgrounds = [NSMapTable weakToStrongObjectsMapTable];
    // Theme updates and reused cells may change while the drawer is hidden.
    // Preserve the latest requested native color, not the first light-mode one.
    [host.listBackgrounds setObject:color ?: (id)NSNull.null forKey:view];
    return UIColor.clearColor;
}

void ApolloDuoSplitPrepareOverlaySurface(UIView *surface) {
    ApolloDuoSplitHost *host = ApolloDuoSubredditOverlayHost(surface);
    if (!host || host.updatingListSurfaces) return;
    if (!host.listBackgrounds) host.listBackgrounds = [NSMapTable weakToStrongObjectsMapTable];
    host.updatingListSurfaces = YES;
    NSMutableArray *views = [NSMutableArray arrayWithObject:surface];
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        if ([view isKindOfClass:UIControl.class] || [view isKindOfClass:UIVisualEffectView.class]) continue;
        [views addObjectsFromArray:view.subviews];
        if (!ApolloDuoListOwnsSurface(view, host)) continue;
        if (![host.listBackgrounds objectForKey:view]) {
            [host.listBackgrounds setObject:view.backgroundColor ?: (id)NSNull.null forKey:view];
        }
        view.backgroundColor = UIColor.clearColor;
    }
    host.updatingListSurfaces = NO;
}

BOOL ApolloDuoSplitIsSidebarController(UIViewController *controller) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    return state.split && state.root == controller && ![state.kind isEqualToString:@"account"];
}

// A Posts-tab reselect at the feed root reveals the drawer without toggling it
// closed again. Other tabs and the cover display keep their native behavior.
BOOL ApolloDuoSplitRevealPostsList(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split || !state.feed || state.changing) return NO;
    [state.host setListVisible:YES animated:!UIAccessibilityIsReduceMotionEnabled()];
    return YES;
}

BOOL ApolloDuoSplitShowSidebar(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, NO);
    if (!state.split) return NO;
    if (state.feed) [state.host setListVisible:!state.host.listVisible animated:YES];
    else [state.split showColumn:UISplitViewControllerColumnPrimary];
    return YES;
}

// Never infer Duo merely from a landscape iPhone. Its native trailing tab bar
// or established Duo mode must be present, and two useful columns must fit.
static BOOL ApolloDuoSplitShouldOpen(UITabBarController *tabs) {
    CGSize size = tabs == sDuoSplitResizingTabs ? sDuoSplitTargetSize : tabs.view.bounds.size;
    if (ApolloDuoRailHasVisibleSideBar() || ApolloDuoCurrentMode() == ApolloDuoModeOpen) {
        sDuoSplitKnownTabs = tabs;
    }
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone
        && size.width >= 800.0 && size.width > size.height
        && tabs == sDuoSplitKnownTabs;
}

// Observe the public hinge interaction on the tab container, rather than
// inferring a book posture from window size. A side window can have the same
// aspect ratio as a cover display; neither should acquire a second column.
// Resolve the iOS 27.1 API dynamically so device builds using the 26 SDK keep
// working, as do older iPhones. UIHingeStatusPartiallyOpen is documented as 2.
static BOOL ApolloDuoSplitWantsHalfWidth(UITabBarController *tabs) {
    return [objc_getAssociatedObject(tabs, &kDuoSplitHingeStatus) integerValue] == 2;
}

static void ApolloDuoSplitObserveHinge(UITabBarController *tabs) {
    if (objc_getAssociatedObject(tabs, &kDuoSplitHingeInteraction)) return;
    if (@available(iOS 27.1, *)) {
        Class cls = NSClassFromString(@"UIHingeInteraction");
        if (!cls) return;
        __weak UITabBarController *weakTabs = tabs;
        void (^handler)(id, id) = ^(__unused id interaction, id update) {
            UITabBarController *owner = weakTabs;
            if (!owner) return;
            id hinge = ((id (*)(id, SEL))objc_msgSend)(update, NSSelectorFromString(@"hinge"));
            NSInteger status = hinge ? ((NSInteger (*)(id, SEL))objc_msgSend)(hinge, NSSelectorFromString(@"status")) : 0;
            NSInteger previous = [objc_getAssociatedObject(owner, &kDuoSplitHingeStatus) integerValue];
            if (previous == status) return;
            objc_setAssociatedObject(owner, &kDuoSplitHingeStatus, @(status), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[DuoSplit] hinge status %ld -> %ld", (long)previous, (long)status);
            // Defer containment work out of UIKit's interaction delivery. The
            // normal update also prepares the tabs that are not selected.
            ApolloDuoSplitScheduleUpdate();
        };
        id<UIInteraction> interaction = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithUpdateHandler:"), handler);
        objc_setAssociatedObject(tabs, &kDuoSplitHingeInteraction, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [tabs.view addInteraction:interaction];
    }
}

static void ApolloDuoSplitApplySidebarWidth(ApolloDuoSplitState *state, BOOL halfWidth) {
    UISplitViewController *split = state.split;
    if (!split) return;
    state.halfWidthSidebar = halfWidth;
    // Lift the ordinary sidebar cap in book posture: half of a 951pt inner
    // display is 475.5pt, and retaining the 420pt cap misses the hinge.
    CGSize canvas = sDuoSplitResizingTabs ? sDuoSplitTargetSize : state.host.view.bounds.size;
    BOOL postsLandscape = state.feed && canvas.width > canvas.height;
    CGFloat half = canvas.width * 0.5;
    // UIKit may keep an earlier sidebar width across column replacement.
    // Bound both ends for Posts so its actual divider stays at the midpoint.
    CGFloat maximum = postsLandscape ? half : (state.feed || halfWidth ? CGFLOAT_MAX : 420.0);
    CGFloat minimum = postsLandscape ? half : 240.0;
    if (split.maximumPrimaryColumnWidth != maximum) split.maximumPrimaryColumnWidth = maximum;
    if (split.minimumPrimaryColumnWidth != minimum) split.minimumPrimaryColumnWidth = minimum;
    CGFloat fraction = halfWidth || state.feed ? 0.5 : 1.0 / 3.0;
    if (split.preferredPrimaryColumnWidthFraction != fraction) split.preferredPrimaryColumnWidthFraction = fraction;
    if (@available(iOS 26.0, *)) {
        // UIKit's default secondary minimum (532pt on this inner display)
        // otherwise caps the primary at 419pt even with a 50% preference.
        CGFloat secondaryMinimum = state.feed || halfWidth ? 240.0 : UISplitViewControllerAutomaticDimension;
        if (split.minimumSecondaryColumnWidth != secondaryMinimum) split.minimumSecondaryColumnWidth = secondaryMinimum;
    }
    if (halfWidth && !state.feed) {
        split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
        [split showColumn:UISplitViewControllerColumnPrimary];
    }
}

BOOL ApolloDuoRequiresSubredditEnhancements(void) {
    return ApolloDuoCurrentMode() != ApolloDuoModePhone || ApolloDuoSplitIsUnfolded();
}

static BOOL ApolloDuoPostsHasLandscapeColumns(ApolloDuoSplitState *state) {
    CGSize size = sDuoSplitResizingTabs ? sDuoSplitTargetSize : state.host.view.bounds.size;
    return size.width > size.height;
}

static BOOL ApolloDuoPostsUsesSplit(ApolloDuoSplitState *state) {
    return state.host.postsSplitEnabled && ApolloDuoPostsHasLandscapeColumns(state);
}

static void ApolloDuoPostsSyncColumnsWithAnimation(ApolloDuoSplitState *state, BOOL animateDisplayMode) {
    if (!state.feed || !state.split || state.changing) return;
    if (sDuoSplitResizingTabs || !ApolloDuoPostsHasLandscapeColumns(state)) {
        ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
        ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    }
    ApolloDuoSplitApplySidebarWidth(state, state.halfWidthSidebar);
    if (!state.primary.navigationBarHidden) [state.primary setNavigationBarHidden:YES animated:NO];
    UIViewController *listRoot = state.primary.viewControllers.firstObject;
    UIEdgeInsets currentInsets = listRoot.additionalSafeAreaInsets;
    CGFloat inheritedRight = listRoot.view.safeAreaInsets.right - currentInsets.right;
    UIEdgeInsets desiredInsets = state.host.originalListInsets;
    desiredInsets.right = -inheritedRight;
    if (!UIEdgeInsetsEqualToEdgeInsets(currentInsets, desiredInsets)) listRoot.additionalSafeAreaInsets = desiredInsets;
    if (state.host.listVisible) [state.host prepareListGlass];
    // Full-width comments stay on Apollo's native feed navigation stack.
    // Only a real split (or its width-toggle preparation) needs two stacks.
    // Never migrate a page while Apollo's native push/pop owns its transition.
    BOOL separateComments = ApolloDuoPostsHasLandscapeColumns(state)
        && (state.host.postsSplitEnabled || state.postsTogglingSplit);
    if (separateComments && state.feed.viewControllers.count > 1 && !state.feed.transitionCoordinator) {
        NSArray *pushed = [state.feed.viewControllers subarrayWithRange:NSMakeRange(1, state.feed.viewControllers.count - 1)];
        state.changing = YES;
        [state.feed setViewControllers:@[state.feed.viewControllers.firstObject] animated:NO];
        [state.secondary setViewControllers:[@[state.secondary.viewControllers.firstObject] arrayByAddingObjectsFromArray:pushed] animated:NO];
        state.changing = NO;
    }
    // Keep the live comments column throughout a split width animation, then
    // restore native full-screen push/Back ownership once it has finished.
    if (!separateComments && state.secondary.viewControllers.count > 1
        && !state.secondary.transitionCoordinator) {
        NSArray *destinations = [state.secondary.viewControllers subarrayWithRange:NSMakeRange(1, state.secondary.viewControllers.count - 1)];
        state.changing = YES;
        [state.secondary setViewControllers:@[state.secondary.viewControllers.firstObject] animated:NO];
        [state.feed setViewControllers:[@[state.feed.viewControllers.firstObject] arrayByAddingObjectsFromArray:destinations] animated:NO];
        state.changing = NO;
    }
    [state.host.viewIfLoaded setNeedsLayout];
    BOOL detail = state.secondary.viewControllers.count > 1;
    BOOL paired = detail && ApolloDuoPostsUsesSplit(state);
    UISplitViewController *split = state.split;
    // A hidden primary can lose its parent while UIKit still retains it as
    // the configured column. Check column ownership, not visibility, so a
    // queued sync cannot interrupt show/hide by recommitting the display mode.
    BOOL columnsMatch = [split viewControllerForColumn:UISplitViewControllerColumnPrimary] == (detail ? state.feed : nil)
        && [split viewControllerForColumn:UISplitViewControllerColumnSecondary] == (detail ? state.secondary : state.feed);
    BOOL unchanged = state.host.postsShowingDetail == detail && state.host.postsColumnsPaired == paired && columnsMatch;
    if (unchanged) return;
    state.changing = YES;
    state.host.postsShowingDetail = detail;
    state.host.postsColumnsPaired = paired;
    // The stack was just merged in portrait, so its top item can now belong
    // to comments. Restore the cached trophy/feed actions only to the Posts
    // root; assigning them to the top item replaces the thread's own actions.
    UINavigationItem *feedItem = state.feed.viewControllers.firstObject.navigationItem;
    if (paired) {
        if (!state.feedActions) {
            // Cache Apollo's actions only. Host controls are owned by the
            // current presentation and must not return after it is folded.
            NSMutableArray *actions = [NSMutableArray array];
            for (UIBarButtonItem *item in feedItem.rightBarButtonItems) {
                if ([item.accessibilityIdentifier isEqualToString:@"ApolloDuoFeedControl"]) continue;
                if (@available(iOS 27.0, *)) {
                    if (item == feedItem.searchBarPlacementBarButtonItem) continue;
                }
                [actions addObject:item];
            }
            state.feedActions = actions;
        }
        feedItem.rightBarButtonItems = @[];
    } else if (state.feedActions) {
        feedItem.rightBarButtonItems = state.feedActions;
        state.feedActions = nil;
    }
    if (detail) {
        BOOL retainedColumns = [split viewControllerForColumn:UISplitViewControllerColumnPrimary] == state.feed
            && [split viewControllerForColumn:UISplitViewControllerColumnSecondary] == state.secondary;
        if (!retainedColumns) {
            [split setViewController:nil forColumn:UISplitViewControllerColumnSecondary];
            [split setViewController:state.feed forColumn:UISplitViewControllerColumnPrimary];
            [split setViewController:state.secondary forColumn:UISplitViewControllerColumnSecondary];
        }
        // A width toggle retains both controllers. Let UIKit's show/hide
        // transition move the divider and cover/reveal the primary column.
        // Assigning the endpoint display mode first hides it immediately;
        // reattaching the same columns also destroys the native transition.
        if (!animateDisplayMode || !retainedColumns)
            split.preferredDisplayMode = paired ? UISplitViewControllerDisplayModeOneBesideSecondary : UISplitViewControllerDisplayModeSecondaryOnly;
        if (paired) [split showColumn:UISplitViewControllerColumnPrimary];
        else [split hideColumn:UISplitViewControllerColumnPrimary];
    } else {
        [split setViewController:nil forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:state.feed forColumn:UISplitViewControllerColumnSecondary];
        split.preferredDisplayMode = UISplitViewControllerDisplayModeSecondaryOnly;
        [split hideColumn:UISplitViewControllerColumnPrimary];
    }
    [state.host.view setNeedsLayout];
    state.changing = NO;
}

static void ApolloDuoPostsSyncColumns(ApolloDuoSplitState *state) {
    ApolloDuoPostsSyncColumnsWithAnimation(state, NO);
}

static CGRect ApolloDuoPostsDetailPane(ApolloDuoSplitState *state) {
    UIView *surface = state.host.view;
    UIView *detail = state.secondary.view;
    // The secondary navigation surface may extend underneath the primary.
    // Its leading safe area identifies the actual comments pane, including
    // its navigation chrome and trailing rail.
    CGRect pane = UIEdgeInsetsInsetRect(detail.bounds,
        UIEdgeInsetsMake(0, detail.safeAreaInsets.left, 0, 0));
    return CGRectIntersection(surface.bounds, [surface convertRect:pane fromView:detail]);
}

@interface ApolloDuoPostsGeometry : NSObject
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) UIView *parent;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGPoint position;
@property(nonatomic) CGRect surfaceFrame;
@end
@implementation ApolloDuoPostsGeometry @end

static void ApolloDuoPostsStopGeometry(UIView *feed) {
    if (!feed) return;
    [feed.layer removeAnimationForKey:@"ApolloDuoPostsGeometry"];
    for (UIView *child in feed.subviews) ApolloDuoPostsStopGeometry(child);
}

static NSArray<ApolloDuoPostsGeometry *> *ApolloDuoPostsCaptureGeometry(UIView *feed, UIView *surface) {
    NSMutableArray *geometry = [NSMutableArray array];
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:feed];
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        if (view.hidden || view.alpha < 0.01) continue;
        CALayer *layer = view.layer.presentationLayer ?: view.layer;
        ApolloDuoPostsGeometry *item = [ApolloDuoPostsGeometry new];
        item.view = view;
        item.parent = view.superview;
        item.bounds = layer.bounds;
        item.position = layer.position;
        item.surfaceFrame = [view.superview.layer convertRect:layer.frame toLayer:surface.layer];
        [geometry addObject:item];
        // The effect's compositor owns its internal backdrop geometry. Move
        // its public surface, just as UIKit does during a window resize.
        if (![view isKindOfClass:UIVisualEffectView.class]) [views addObjectsFromArray:view.subviews];
    }
    return geometry;
}

static void ApolloDuoAnimateRetainedGeometry(NSArray<ApolloDuoPostsGeometry *> *geometry,
                                             UIView *feed, UIView *surface, NSTimeInterval duration,
                                             BOOL convertReparentedDescendants) {
    NSUInteger count = 0;
    for (ApolloDuoPostsGeometry *item in geometry) {
        UIView *view = item.view;
        if (!view || (view != feed && ![view isDescendantOfView:feed])) continue;
        CALayer *layer = view.layer;
        CGPoint position = item.position;
        if (view == feed || item.parent != view.superview) {
            // A container can keep its direct wrapper while its ancestors
            // move between column coordinate spaces, so convert the root
            // unconditionally. Search also reparents its retained page and
            // search-bar surfaces into a newly created navigation controller.
            if (!view.superview || (view != feed && !convertReparentedDescendants)) continue;
            CGRect frame = [view.superview.layer convertRect:item.surfaceFrame fromLayer:surface.layer];
            position = CGPointMake(CGRectGetMinX(frame) + CGRectGetWidth(frame) * layer.anchorPoint.x,
                                   CGRectGetMinY(frame) + CGRectGetHeight(frame) * layer.anchorPoint.y);
        }
        NSMutableArray<CAAnimation *> *animations = [NSMutableArray array];
        if (!CGRectEqualToRect(item.bounds, layer.bounds)) {
            CABasicAnimation *bounds = [CABasicAnimation animationWithKeyPath:@"bounds"];
            bounds.fromValue = [NSValue valueWithCGRect:item.bounds];
            bounds.toValue = [NSValue valueWithCGRect:layer.bounds];
            bounds.duration = duration;
            [animations addObject:bounds];
        }
        if (!CGPointEqualToPoint(position, layer.position)) {
            CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position"];
            move.fromValue = [NSValue valueWithCGPoint:position];
            move.toValue = [NSValue valueWithCGPoint:layer.position];
            move.duration = duration;
            [animations addObject:move];
        }
        if (!animations.count) continue;
        CAAnimationGroup *resize = [CAAnimationGroup animation];
        resize.animations = animations;
        resize.duration = duration;
        resize.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [layer addAnimation:resize forKey:@"ApolloDuoPostsGeometry"];
        count++;
    }
    ApolloLog(@"[DuoSplit] animating %lu retained surfaces", (unsigned long)count);
}

static void ApolloDuoPostsAnimateGeometry(NSArray<ApolloDuoPostsGeometry *> *geometry,
                                         UIView *feed, UIView *surface, NSTimeInterval duration) {
    ApolloDuoAnimateRetainedGeometry(geometry, feed, surface, duration, NO);
}

@interface ApolloDuoLayoutTransition : NSObject
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, strong) UIView *surface;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) NSIndexPath *anchor;
@property(nonatomic) CGFloat anchorOffset;
@property(nonatomic) CGSize size;
@property(nonatomic, copy) NSArray<ApolloDuoPostsGeometry *> *geometry;
@property(nonatomic, strong) UIView *cover;
@end
@implementation ApolloDuoLayoutTransition @end

// One preference affects both the feed and the thread beside it. Capture every
// visible native Posts/Comments table before invalidating any of their nodes.
static void ApolloDuoToggleVisibleFeedLayout(UIViewController *controller, BOOL enabled) {
    UIWindow *window = controller.viewIfLoaded.window;
    if (!window || !enabled || sDuoFeedLayoutChanging || ApolloDuoSplitIsResizing()
        || !ApolloDuoSplitIsUnfolded() || ApolloDuoSplitIsUnfoldedPortrait()) return;
    [window layoutIfNeeded];
    BOOL animate = !UIAccessibilityIsReduceMotionEnabled();
    NSMutableArray<ApolloDuoLayoutTransition *> *transitions = [NSMutableArray array];
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:window];
    for (NSUInteger i = 0; i < views.count; i++) {
        UIView *view = views[i];
        if (view.hidden || view.alpha < 0.01) continue;
        if (![view isKindOfClass:UITableView.class]) {
            [views addObjectsFromArray:view.subviews];
            continue;
        }
        UIViewController *page = nil;
        for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
            if ([responder isKindOfClass:UIViewController.class]) { page = (id)responder; break; }
        }
        NSString *name = NSStringFromClass(page.class);
        if ((![name isEqualToString:@"Apollo.PostsViewController"] && ![name isEqualToString:@"Apollo.CommentsViewController"])
            || page.navigationController.topViewController != page
            || !CGRectIntersectsRect(window.bounds, [view convertRect:view.bounds toView:window])) continue;
        ApolloDuoLayoutTransition *transition = [ApolloDuoLayoutTransition new];
        transition.controller = page;
        transition.surface = page.view;
        transition.table = (id)view;
        transition.size = page.view.bounds.size;
        transition.anchor = [[transition.table.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)] firstObject];
        transition.anchorOffset = transition.anchor
            ? CGRectGetMinY([transition.table rectForRowAtIndexPath:transition.anchor]) - transition.table.contentOffset.y : 0;
        transition.geometry = animate ? ApolloDuoPostsCaptureGeometry(page.view, page.view) : nil;
        // Cover only the queued measurement, then animate retained live views.
        transition.cover = animate ? [view snapshotViewAfterScreenUpdates:NO] : nil;
        if (transition.cover) {
            transition.cover.frame = [view convertRect:view.bounds toView:page.view];
            transition.cover.userInteractionEnabled = NO;
            [page.view addSubview:transition.cover];
        }
        ApolloDuoPostsStopGeometry(page.view);
        [transitions addObject:transition];
    }
    if (!transitions.count) return;
    sDuoFeedLayoutChanging = YES;
    sDuoLandscapeFeedLayout = sDuoLandscapeFeedLayout == 2 ? 0 : 2;
    [NSUserDefaults.standardUserDefaults setInteger:sDuoLandscapeFeedLayout forKey:UDKeyDuoLandscapeFeedLayout];
    ApolloDuoRefreshLayoutControls();
    [NSNotificationCenter.defaultCenter postNotificationName:@"ApolloDuoFeedLayoutDidChange" object:nil];
    // Media invalidation queues first. Finish Texture's transaction before
    // reading final frames, preserving each pane's own visible row anchor.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (ApolloDuoLayoutTransition *transition in transitions) {
            UIViewController *page = transition.controller;
            UIView *surface = transition.surface;
            UITableView *table = transition.table;
            if (page.viewIfLoaded != surface || surface.window != window
                || page.navigationController.topViewController != page) {
                [transition.cover removeFromSuperview];
                continue;
            }
            [UIView performWithoutAnimation:^{
                [surface layoutIfNeeded];
                [table layoutIfNeeded];
                SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
                if ([table respondsToSelector:commit]) ((void (*)(id, SEL))objc_msgSend)(table, commit);
                [table layoutIfNeeded];
                NSIndexPath *anchor = transition.anchor;
                if (anchor && anchor.section < table.numberOfSections
                    && anchor.row < [table numberOfRowsInSection:anchor.section]) {
                    CGFloat minimum = -table.adjustedContentInset.top;
                    CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
                    CGFloat offset = CGRectGetMinY([table rectForRowAtIndexPath:anchor]) - transition.anchorOffset;
                    [table setContentOffset:CGPointMake(table.contentOffset.x, MIN(maximum, MAX(minimum, offset))) animated:NO];
                    [table layoutIfNeeded];
                }
            }];
            [transition.cover removeFromSuperview];
            if (animate && CGSizeEqualToSize(transition.size, surface.bounds.size)
                && ApolloDuoSplitIsUnfolded() && !ApolloDuoSplitIsUnfoldedPortrait())
                ApolloDuoPostsAnimateGeometry(transition.geometry, surface, surface, 0.32);
        }
        sDuoFeedLayoutChanging = NO;
        ApolloDuoRefreshLayoutControls();
    });
}

static void ApolloDuoToggleFeedLayout(ApolloDuoSplitHost *host) {
    ApolloDuoToggleVisibleFeedLayout(host.feedControlsOwner, host.feedLayoutButton.enabled);
}

// Threads outside Posts need their own control. Inside Posts, the host carries
// its retained layout item between the feed and comments with List and Split.
static NSString *const kApolloDuoCommentsLayoutID = @"ApolloDuoCommentsLayoutControl";
static char kApolloDuoCommentsLayoutKey, kApolloDuoCommentsLayoutPendingKey;
@interface ApolloDuoCommentsLayoutControl : NSObject <ApolloDuoLayoutControl>
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, strong) UIBarButtonItem *item;
- (void)update;
- (void)toggle;
@end
static NSMapTable<UINavigationItem *, ApolloDuoCommentsLayoutControl *> *sDuoCommentsLayoutOwners;

static BOOL ApolloDuoCommentsShowsLayoutControl(UIViewController *controller) {
    if (!ApolloDuoSplitIsUnfolded() || ApolloDuoSplitIsUnfoldedPortrait()) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    return !state.feed;
}

// NavigationActions calls this before normalizing native items, so an async
// Apollo action refresh cannot remove the independent layout control.
NSArray<UIBarButtonItem *> *ApolloDuoCommentsLayoutItems(UINavigationItem *item, NSArray<UIBarButtonItem *> *items) {
    ApolloDuoCommentsLayoutControl *control = [sDuoCommentsLayoutOwners objectForKey:item];
    if (!control) return items;
    NSMutableArray *result = [NSMutableArray array];
    if (ApolloDuoCommentsShowsLayoutControl(control.controller)) [result addObject:control.item];
    for (UIBarButtonItem *candidate in items)
        if (![candidate.accessibilityIdentifier isEqualToString:kApolloDuoCommentsLayoutID]) [result addObject:candidate];
    return result;
}

@implementation ApolloDuoCommentsLayoutControl
- (void)updateFeedLayoutButton { ApolloDuoRefreshLayoutButton(nil, self.item); }
- (void)toggle {
    if (ApolloDuoCommentsShowsLayoutControl(self.controller))
        ApolloDuoToggleVisibleFeedLayout(self.controller, self.item.enabled);
}
- (void)update {
    [self updateFeedLayoutButton];
    UINavigationItem *navigationItem = self.controller.navigationItem;
    NSArray *items = ApolloDuoCommentsLayoutItems(navigationItem, navigationItem.rightBarButtonItems);
    if (![(navigationItem.rightBarButtonItems ?: @[]) isEqualToArray:items])
        [navigationItem setRightBarButtonItems:items animated:NO];
}
@end

static void ApolloDuoCommentsUpdateLayoutControl(UIViewController *controller) {
    ApolloDuoCommentsLayoutControl *control = objc_getAssociatedObject(controller, &kApolloDuoCommentsLayoutKey);
    if (!control && !ApolloDuoCommentsShowsLayoutControl(controller)) return;
    if (!control) {
        control = [ApolloDuoCommentsLayoutControl new];
        control.controller = controller;
        // A native image item lets UIKit own glyph visibility, accessibility,
        // sizing and glass. No configured UIButton or custom wrapper is needed.
        control.item = [[UIBarButtonItem alloc] initWithImage:ApolloDuoFeedLayoutImage()
            style:UIBarButtonItemStylePlain target:control action:@selector(toggle)];
        control.item.title = @"Feed Layout";
        control.item.accessibilityLabel = @"Feed Layout";
        control.item.accessibilityIdentifier = kApolloDuoCommentsLayoutID;
        control.item.tintColor = ApolloNavigationChromeColor();
        if (@available(iOS 26.0, *)) {
            control.item.hidesSharedBackground = NO;
            control.item.sharesBackground = NO;
        }
        if (@available(iOS 27.1, *)) control.item.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
        objc_setAssociatedObject(controller, &kApolloDuoCommentsLayoutKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sDuoCommentsLayoutOwners) sDuoCommentsLayoutOwners = [NSMapTable weakToWeakObjectsMapTable];
        [sDuoCommentsLayoutOwners setObject:control forKey:controller.navigationItem];
        ApolloDuoRegisterLayoutControl(control);
    }
    [control update];
}

static void ApolloDuoCommentsScheduleLayoutControl(UIViewController *controller) {
    ApolloDuoCommentsLayoutControl *control = objc_getAssociatedObject(controller, &kApolloDuoCommentsLayoutKey);
    if (objc_getAssociatedObject(controller, &kApolloDuoCommentsLayoutPendingKey)
        || (!control && !ApolloDuoCommentsShowsLayoutControl(controller))) return;
    objc_setAssociatedObject(controller, &kApolloDuoCommentsLayoutPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *page = weakController;
        if (!page) return;
        objc_setAssociatedObject(page, &kApolloDuoCommentsLayoutPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloDuoCommentsUpdateLayoutControl(page);
    });
}

// A split toggle changes only the width of an already open comments page.
// Both native column controllers stay attached; UIKit owns their divider,
// clipping, safe areas, and the disappearance/reappearance of the feed.
static void ApolloDuoPostsToggleSplit(ApolloDuoSplitState *state) {
    if (!state.feed || state.changing || state.postsTogglingSplit
        || state.feed.transitionCoordinator || state.secondary.transitionCoordinator) return;
    UIView *surface = state.host.view;
    [surface layoutIfNeeded];
    BOOL hasComments = state.secondary.viewControllers.count > 1 || state.feed.viewControllers.count > 1;
    BOOL animate = surface.window && ApolloDuoPostsHasLandscapeColumns(state)
        && hasComments && !UIAccessibilityIsReduceMotionEnabled();
    ApolloLogDebug(@"[DuoSplit] toggle enabled=%d animated=%d reduceMotion=%d",
        !state.host.postsSplitEnabled, animate, UIAccessibilityIsReduceMotionEnabled());
    ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
    ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    [state.host.postsTransitionSnapshot removeFromSuperview];
    state.host.postsTransitionSnapshot = nil;
    [state.secondary.view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    state.postsTogglingSplit = YES;
    void (^commitTables)(void) = ^{
        [surface layoutIfNeeded];
        for (UINavigationController *navigation in @[state.feed, state.secondary]) {
            UITableView *table = ApolloDuoSplitFindTable(navigation.topViewController.viewIfLoaded);
            ApolloDuoMediaPrepareTableForTransition(table);
            SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
            if ([table respondsToSelector:commit]) ((void (*)(id, SEL))objc_msgSend)(table, commit);
            [table layoutIfNeeded];
        }
    };
    if (!state.host.postsSplitEnabled && state.feed.viewControllers.count > 1) {
        // Move the SAME comments page to a full-width secondary first. Its
        // appearance and geometry stay fixed; UIKit can then animate the
        // retained columns to 50/50 without a pop/re-push or an empty surface.
        [UIView performWithoutAnimation:^{
            ApolloDuoPostsSyncColumns(state);
            commitTables();
        }];
    }
    state.host.postsSplitEnabled = !state.host.postsSplitEnabled;
    [NSUserDefaults.standardUserDefaults setBool:!state.host.postsSplitEnabled forKey:@"ApolloDuoPostsSplitDisabled"];
    [state.host updateSplitButton];
    void (^updateColumns)(void) = ^{
        ApolloDuoPostsSyncColumnsWithAnimation(state, animate);
        commitTables();
    };
    void (^finish)(void) = ^{
        state.postsTogglingSplit = NO;
        // Hiding the primary has completed. Rejoin the stacks at the same
        // full-width geometry so subsequent Back uses Apollo's own animator.
        if (state.feed && state.split) {
            [UIView performWithoutAnimation:^{
                ApolloDuoPostsSyncColumns(state);
                commitTables();
            }];
        }
        ApolloDuoSplitScheduleUpdate();
    };
    if (animate) {
        [UIView animateWithDuration:0.32 delay:0
                           options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                        animations:updateColumns completion:^(__unused BOOL finished) {
            finish();
        }];
    } else {
        [UIView performWithoutAnimation:updateColumns];
        finish();
    }
}

// Read the model identity without loading the new controller's view. Feed
// selections seed link immediately; URL-created controllers seed linkID.
static NSString *ApolloDuoCommentsPostID(UIViewController *page) {
    if (![NSStringFromClass(page.class) isEqualToString:@"Apollo.CommentsViewController"]) return nil;
    id link = ApolloReadObjectIvar(page, "link");
    id value = [link respondsToSelector:@selector(fullName)]
        ? ((id (*)(id, SEL))objc_msgSend)(link, @selector(fullName)) : nil;
    NSString *identifier = [value isKindOfClass:NSString.class] ? value : nil;
    if (!identifier.length) identifier = ApolloReadSwiftStringIvar(page, "linkID");
    if ([identifier hasPrefix:@"t3_"]) identifier = [identifier substringFromIndex:3];
    return identifier.length ? identifier.lowercaseString : nil;
}

// Creating/removing the comments column is a containment transition. Animate
// that layout together with the page: the retained live feed must resize as
// comments enter/leave, not jump to its final width before a snapshot slides.
// Once both columns exist, Apollo's native navigation animator owns pushes.
static void ApolloDuoPostsSetDetail(ApolloDuoSplitState *state, UIViewController *page, BOOL animated) {
    UIView *surface = state.host.view;
    BOOL entering = page != nil;
    BOOL animate = animated && surface.window && !UIAccessibilityIsReduceMotionEnabled();
    if (!animate) {
        ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
        ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    }
    UIViewController *backstop = state.secondary.viewControllers.firstObject;
    [state.host.postsTransitionSnapshot removeFromSuperview];
    state.host.postsTransitionSnapshot = nil;
    [state.secondary.view.layer removeAnimationForKey:@"ApolloDuoSlide"];
    if (entering && state.host.postsShowingDetail) {
        [surface layoutIfNeeded];
        [state.secondary setViewControllers:@[backstop, page] animated:animate];
        return;
    }

    [surface layoutIfNeeded];
    NSArray<ApolloDuoPostsGeometry *> *feedGeometry = animate
        ? ApolloDuoPostsCaptureGeometry(state.feed.view, surface) : nil;
    CGRect pane = !entering ? ApolloDuoPostsDetailPane(state) : CGRectNull;
    UIView *snapshot = !entering && animate && !CGRectIsNull(pane) && !CGRectIsEmpty(pane)
        ? [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;
    if (snapshot) {
        snapshot.frame = pane;
        snapshot.userInteractionEnabled = NO;
        [surface insertSubview:snapshot belowSubview:state.host.listDismiss];
        state.host.postsTransitionSnapshot = snapshot;
    }
    ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
    ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
    void (^updateColumns)(void) = ^{
        state.changing = YES;
        [state.secondary setViewControllers:page ? @[backstop, page] : @[backstop] animated:NO];
        state.changing = NO;
        ApolloDuoPostsSyncColumns(state);
        [surface layoutIfNeeded];
        // Texture schedules its row geometry separately from UIKit's column
        // layout. Commit the existing measurement before taking endpoints so
        // cell/media widths participate in the same resize as their live nav.
        UITableView *table = ApolloDuoSplitFindTable(state.feed.topViewController.viewIfLoaded);
        ApolloDuoMediaPrepareTableForTransition(table);
        SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
        if ([table respondsToSelector:commit]) ((void (*)(id, SEL))objc_msgSend)(table, commit);
        [table layoutIfNeeded];
    };
    if (!animate) {
        [UIView performWithoutAnimation:updateColumns];
        return;
    }
    // Finish containment with UIKit animation disabled. Running this inside
    // a UIView animation also animates UIKit's column wrappers, which moves
    // the whole feed a second time on top of its explicit geometry replay.
    // Model geometry remains UIKit-owned; only presentation endpoints below
    // animate from the captured full-width/half-width live view hierarchy.
    [UIView performWithoutAnimation:updateColumns];
    __weak ApolloDuoSplitHost *weakHost = state.host;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{ ApolloDuoSplitScheduleUpdate(); }];
    ApolloDuoPostsAnimateGeometry(feedGeometry, state.feed.view, surface, 0.32);
    if (entering) {
        // Use the live navigation surface so async comment/media updates
        // remain visible throughout the first push.
        CGRect incomingPane = ApolloDuoPostsDetailPane(state);
        CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(incomingPane);
        if (!CGRectIsNull(incomingPane) && travel > 0)
            ApolloDuoSlideView(state.secondary.view, travel, 0, 0.32, nil);
    } else if (snapshot) {
        CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane);
        ApolloDuoSlideView(snapshot, 0, travel, 0.32, ^{
            [snapshot removeFromSuperview];
            if (weakHost.postsTransitionSnapshot == snapshot) weakHost.postsTransitionSnapshot = nil;
            ApolloDuoSplitScheduleUpdate();
        });
    }
    [CATransaction commit];
}

static UITableView *ApolloDuoSplitFindTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (id)view;
    for (UIView *child in view.subviews) {
        UITableView *table = ApolloDuoSplitFindTable(child);
        if (table) return table;
    }
    return nil;
}

static BOOL ApolloDuoSplitViewHasLabel(UIView *view, NSSet<NSString *> *labels) {
    if ([view isKindOfClass:UILabel.class] && [labels containsObject:((UILabel *)view).text]) return YES;
    if (view.accessibilityLabel && [labels containsObject:view.accessibilityLabel]) return YES;
    for (UIView *child in view.subviews) {
        if (ApolloDuoSplitViewHasLabel(child, labels)) return YES;
    }
    return NO;
}

static BOOL ApolloDuoSplitSelectRow(UIViewController *root, NSSet<NSString *> *labels) {
    [root loadViewIfNeeded];
    UITableView *table = ApolloDuoSplitFindTable(root.view);
    if (!table || ![table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    [table layoutIfNeeded];
    for (NSInteger section = 0; section < MIN(table.numberOfSections, 40); section++) {
        for (NSInteger row = 0; row < MIN([table numberOfRowsInSection:section], 40); row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
            UIView *content = [table cellForRowAtIndexPath:path];
            BOOL matches = NO;
            if ([table respondsToSelector:NSSelectorFromString(@"nodeForRowAtIndexPath:")]) {
                id node = ((id (*)(id, SEL, id))objc_msgSend)(table, NSSelectorFromString(@"nodeForRowAtIndexPath:"), path);
                // Texture's offscreen shortcut nodes expose their label on
                // the node; their backing views have no accessibility label.
                if ([node respondsToSelector:@selector(accessibilityLabel)]) {
                    matches = [labels containsObject:[node accessibilityLabel] ?: @""];
                }
                if (!content && [node respondsToSelector:@selector(view)]) content = [node view];
            } else if (!content) {
                content = [table.dataSource tableView:table cellForRowAtIndexPath:path];
            }
            if (matches || (content && ApolloDuoSplitViewHasLabel(content, labels))) {
                [table.delegate tableView:table didSelectRowAtIndexPath:path];
                return YES;
            }
        }
    }
    return NO;
}

extern void ApolloHiddenContentPresentFromProfile(UIViewController *profile);
void ApolloDuoAccountOpenShortcut(UIViewController *profile, NSString *title) {
    if (!profile || !title.length) return;
    // Hidden & Deleted is a tweak-owned row nested beside Saved; every other
    // shortcut is the native row with this label, selected through Apollo.
    if ([title isEqualToString:@"Hidden & Deleted"]) {
        ApolloHiddenContentPresentFromProfile(profile);
        return;
    }
    // Match the native Texture node's own label. The visible anchor cell also
    // hosts the portrait grid, so a cell-text search would find the grid's
    // copy of every title on the first shortcut row.
    UITableView *table = ApolloDuoSplitFindTable(profile.view);
    SEL nodeSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if ([table respondsToSelector:nodeSelector]
        && [table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        NSInteger count = [table.dataSource tableView:table numberOfRowsInSection:0];
        for (NSInteger row = 0; row < MIN(count, 60); row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
            id node = ((id (*)(id, SEL, id))objc_msgSend)(table, nodeSelector, path);
            if (![node respondsToSelector:@selector(accessibilityLabel)]) continue;
            if (![[node accessibilityLabel] isEqualToString:title]) continue;
            [table.delegate tableView:table didSelectRowAtIndexPath:path];
            return;
        }
    }
    if (!ApolloDuoSplitSelectRow(profile, [NSSet setWithObject:title])) {
        ApolloLog(@"[DuoAccount] no native row for shortcut %@", title);
    }
}

// The Account tab profile, when its view exists (portrait or closed layout).
static void ApolloDuoAccountRefreshPortraitGrid(UITabBarController *tabs) {
    for (UIViewController *tab in tabs.viewControllers) {
        if (![tab isKindOfClass:UINavigationController.class]) continue;
        UIViewController *root = ((UINavigationController *)tab).viewControllers.firstObject;
        if (!root.isViewLoaded || !ApolloDuoSplitIsOwnAccountController(root)) continue;
        UITableView *table = ApolloDuoSplitFindTable(root.view);
        if (table) ApolloDuoAccountGridRefresh(table);
    }
}

static UIViewController *ApolloDuoSplitForwardPage(UINavigationController *nav) {
    // Read-only native Swift storage, as used by ForwardSwipeExpiry. Let
    // Apollo's native push bookkeeping consume it; never mutate the array.
    Ivar ivar = class_getInstanceVariable(nav.class, "poppedViewControllers");
    if (!ivar) return nil;
    uintptr_t word = 0;
    memcpy(&word, (const uint8_t *)(__bridge const void *)nav + ivar_getOffset(ivar), sizeof(word));
    if (!word || (word & 0xC000000000000007ull)) return nil;
    id storage = (__bridge id)(void *)word;
    if (![storage respondsToSelector:@selector(firstObject)]) return nil;
    id page = [storage firstObject];
    return [page isKindOfClass:UIViewController.class] ? page : nil;
}

static BOOL ApolloDuoSplitOpenStartupFeed(ApolloDuoSplitState *state) {
    // Native General stores ["subreddit", name], ["multireddit", user, name],
    // or a one-element built-in-feed choice (verified in Apollo's setter).
    NSArray *choice = [NSUserDefaults.standardUserDefaults arrayForKey:@"DefaultRedditToLoad"];
    NSString *kind = [choice.firstObject isKindOfClass:NSString.class] ? [choice.firstObject lowercaseString] : @"home";
    NSString *path = @"/";
    if ([kind isEqualToString:@"subreddit"] && choice.count >= 2 && [choice[1] isKindOfClass:NSString.class]) {
        path = [@"/r/" stringByAppendingString:choice[1]];
    } else if ([kind isEqualToString:@"multireddit"] && choice.count >= 3 &&
               [choice[1] isKindOfClass:NSString.class] && [choice[2] isKindOfClass:NSString.class]) {
        path = [NSString stringWithFormat:@"/user/%@/m/%@", choice[1], choice[2]];
    } else if ([kind containsString:@"popular"]) {
        path = @"/r/popular";
    } else if ([kind isEqualToString:@"all"]) {
        path = @"/r/all";
    }
    if ([path isEqualToString:@"/"]) {
        // Home is a native feed row, but the enhanced list presents it in a
        // separate shortcut control. Searching visible row labels misses it.
        // Use the same visible-index mapping as the shortcut's tap handler.
        UITableView *table = ApolloDuoSplitFindTable(state.root.view);
        NSUInteger row = [ApolloFeedShortcutVisibleIndexes() indexOfObject:@0];
        if (row == NSNotFound || table.numberOfSections == 0 ||
            row >= (NSUInteger)[table numberOfRowsInSection:0] ||
            ![table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
        [table.delegate tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        return (state.feed ?: state.secondary).viewControllers.firstObject.class != UIViewController.class;
    }
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://www.reddit.com"];
    url.path = path;
    return ApolloRouteURLThroughApp(url.URL);
}

static void ApolloDuoSplitOpenDefault(ApolloDuoSplitState *state) {
    if (!state.needsDefault || state.changing || !state.split || state.outer.presentedViewController) return;
    state.needsDefault = NO;
    if ([state.kind isEqualToString:@"settings"]) {
        NSArray *saved = state.lastSettings;
        if (saved.count && ![saved.firstObject parentViewController]) {
            [state.secondary setViewControllers:saved animated:NO];
        } else {
            [state.secondary setViewControllers:@[[[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]] animated:NO];
        }
    } else if ([state.kind isEqualToString:@"subreddits"]) {
        state.needsDefault = !ApolloDuoSplitOpenStartupFeed(state);
    } else if ([state.kind isEqualToString:@"account"]) {
        // The native profile is already installed as the initial Overview.
    } else if (![state.kind isEqualToString:@"search"]) {
        NSSet *labels = [state.kind isEqualToString:@"inbox"]
            ? [NSSet setWithObjects:@"Inbox (All)", @"Inbox", nil] : [NSSet setWithObject:@"Posts"];
        // A profile may still be fetching its menu. Leave the default pending
        // until its table reloads; do not invent a Posts controller or row index.
        state.needsDefault = !ApolloDuoSplitSelectRow(state.root, labels);
    }
}

extern void ApolloHiddenContentPresentFromProfile(UIViewController *profile);

static void ApolloDuoAccountSetPages(ApolloDuoSplitState *state, NSArray<UIViewController *> *pages) {
    UIView *surface = state.host.view;
    if ([state.secondary.viewControllers isEqualToArray:pages]) return;
    // Size the destination column before Apollo's navigation controller takes
    // its transition snapshots. Only the secondary stack slides; the shared
    // header and shortcuts keep their existing geometry.
    state.host.pendingAccountDetail = @(pages.count > 1);
    [UIView performWithoutAnimation:^{
        [surface setNeedsLayout];
        [surface layoutIfNeeded];
    }];
    // UINavigationController selects a pop when the destination is already in
    // the stack and a push for a new shortcut. Keep Apollo's animator/delegate.
    BOOL animated = surface.window && !UIAccessibilityIsReduceMotionEnabled();
    [state.secondary setViewControllers:pages animated:animated];
    state.host.pendingAccountDetail = nil;
    [state.secondary setNavigationBarHidden:pages.count == 1 animated:animated];

}

static void ApolloDuoAccountSelect(ApolloDuoSplitState *state, NSString *title) {
    if (!state.split || state.changing) return;
    if ([title isEqualToString:@"Overview"]) {
        ApolloDuoAccountSetPages(state, @[state.root]);
        return;
    }
    state.selectingAccountShortcut = YES;
    if ([title isEqualToString:@"Hidden & Deleted"]) ApolloHiddenContentPresentFromProfile(state.root);
    else ApolloDuoSplitSelectRow(state.root, [NSSet setWithObject:title]);
    state.selectingAccountShortcut = NO;
    [state.host.view setNeedsLayout];
}

static void ApolloDuoSplitClose(ApolloDuoSplitState *state, BOOL preserveDetail);
static void ApolloDuoSplitNavigateProfile(ApolloDuoSplitState *state, UIViewController *profile, BOOL forward);

static void ApolloDuoSearchRestoreBackItem(ApolloDuoSplitState *state) {
    UIViewController *page = state.searchBackPage;
    if (page && state.searchBackItem) {
        NSMutableArray *items = [page.navigationItem.leftBarButtonItems mutableCopy];
        [items removeObjectIdenticalTo:state.searchBackItem];
        page.navigationItem.leftBarButtonItems = items.count ? items : nil;
        page.navigationItem.leftItemsSupplementBackButton = state.searchBackSupplementedNative;
    }
    state.searchBackPage = nil;
    state.searchBackItem = nil;
}

static void ApolloDuoSearchReturnToSearch(ApolloDuoSplitState *state) {
    if (!state.split || state.changing || ![state.kind isEqualToString:@"search"]) return;
    UINavigationController *outer = state.outer;
    UIViewController *search = state.root;
    UIView *surface = outer.view;
    UIView *detail = state.secondary.view;
    // The secondary controller can extend beneath the sidebar. Capture only
    // its visible pane, retaining its navigation chrome and trailing rail.
    // Top/bottom safe areas describe those controls, not obscured content.
    CGRect pane = UIEdgeInsetsInsetRect(detail.bounds,
        UIEdgeInsetsMake(0, detail.safeAreaInsets.left, 0, 0));
    pane = CGRectIntersection(surface.bounds, [surface convertRect:pane fromView:detail]);
    BOOL animate = surface.window && !UIAccessibilityIsReduceMotionEnabled()
        && !CGRectIsNull(pane) && !CGRectIsEmpty(pane);
    UIView *snapshot = animate
        ? [surface resizableSnapshotViewFromRect:pane afterScreenUpdates:NO withCapInsets:UIEdgeInsetsZero] : nil;

    // Commit the real native Back beneath the captured outgoing page. A pop
    // after reparenting cannot animate the old split hierarchy; it otherwise
    // reveals Search immediately and loses the visible subreddit transition.
    // The retained Search controller keeps its query, results and scroll.
    [UIView performWithoutAnimation:^{
        ApolloDuoSplitClose(state, YES);
        [outer popToViewController:search animated:NO];
        [surface layoutIfNeeded];
        if (snapshot) {
            snapshot.frame = pane;
            snapshot.userInteractionEnabled = NO;
            [surface addSubview:snapshot];
        }
    }];
    if (snapshot) {
        CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane);
        ApolloDuoSlideView(snapshot, 0, travel, 0.32, ^{ [snapshot removeFromSuperview]; });
    }
    ApolloDuoSplitScheduleUpdate();
}

static void ApolloDuoSearchUpdateBackItem(ApolloDuoSplitState *state) {
    UIViewController *page = state.secondary.viewControllers.firstObject;
    BOOL needsBack = state.split && [state.kind isEqualToString:@"search"]
        && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"];
    if (!needsBack || state.searchBackPage != page) ApolloDuoSearchRestoreBackItem(state);
    if (!needsBack || state.searchBackItem) return;

    // Search remains in the primary column, so this subreddit is a secondary
    // root with no generated Back item. Supply a native leading navigation
    // action; UIKit places it above the other actions in Duo's side rail.
    __weak ApolloDuoSplitState *weakState = state;
    UIAction *action = [UIAction actionWithTitle:@"Back to Search"
                                         image:[UIImage systemImageNamed:@"chevron.left"]
                                    identifier:nil handler:^(__unused UIAction *sender) {
        ApolloDuoSearchReturnToSearch(weakState);
    }];
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithPrimaryAction:action];
    back.accessibilityLabel = @"Back to Search";
    back.tintColor = ApolloNavigationChromeColor();
    if (@available(iOS 26.0, *)) {
        back.identifier = @"ApolloReborn.duo-search.back";
        back.sharesBackground = NO;
    }
    if (@available(iOS 27.1, *)) back.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
    state.searchBackPage = page;
    state.searchBackItem = back;
    state.searchBackSupplementedNative = page.navigationItem.leftItemsSupplementBackButton;
    page.navigationItem.leftItemsSupplementBackButton = NO;
    page.navigationItem.leftBarButtonItems = [@[back] arrayByAddingObjectsFromArray:page.navigationItem.leftBarButtonItems ?: @[]];
}

static void ApolloDuoAccountPrepareHost(ApolloDuoSplitState *state, ApolloDuoSplitHost *host) {
    UIViewController *profile = state.root;
    host.accountHeader = ApolloDuoAccountProfileHeader(profile);
    UINavigationBar *sidebarBar = [[UINavigationBar alloc] init];
    UINavigationBarAppearance *sidebarAppearance = [UINavigationBarAppearance new];
    [sidebarAppearance configureWithTransparentBackground];
    sidebarBar.standardAppearance = sidebarAppearance;
    sidebarBar.scrollEdgeAppearance = sidebarAppearance;
    sidebarBar.compactAppearance = sidebarAppearance;
    sidebarBar.tintColor = ApolloNavigationChromeColor();
    UINavigationItem *sidebarItem = [[UINavigationItem alloc] initWithTitle:@""];
    // Use the same native bar-item renderer and sidebar symbol as the other
    // primary columns. UIKit clears displayModeButtonItem's image when its
    // managed column bars are hidden, so this item owns only the toggle action.
    __weak ApolloDuoSplitHost *weakHost = host;
    UIAction *toggleSidebar = [UIAction actionWithTitle:@"Toggle Sidebar"
        image:[UIImage systemImageNamed:@"sidebar.left"] identifier:nil
        handler:^(__unused UIAction *action) {
            UISplitViewController *split = weakHost.split;
            if (split.displayMode == UISplitViewControllerDisplayModeSecondaryOnly)
                [split showColumn:UISplitViewControllerColumnPrimary];
            else
                [split hideColumn:UISplitViewControllerColumnPrimary];
        }];
    UIBarButtonItem *sidebar = [[UIBarButtonItem alloc] initWithPrimaryAction:toggleSidebar];
    if (@available(iOS 27.1, *)) sidebar.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
    sidebarItem.rightBarButtonItem = sidebar;
    [sidebarBar setItems:@[sidebarItem] animated:NO];
    host.sidebarNavigationBar = sidebarBar;
    host.split.displayModeButtonVisibility = UISplitViewControllerDisplayModeButtonVisibilityNever;
    UIButtonConfiguration *sidebarConfiguration;
    if (@available(iOS 26.0, *)) sidebarConfiguration = [UIButtonConfiguration glassButtonConfiguration];
    else sidebarConfiguration = [UIButtonConfiguration tintedButtonConfiguration];
    sidebarConfiguration.baseForegroundColor = UIColor.labelColor;
    sidebarConfiguration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    if (state.profilePrefix.count) {
        UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *backConfiguration = [sidebarConfiguration copy];
        backConfiguration.image = [UIImage systemImageNamed:@"chevron.left"];
        back.configuration = backConfiguration;
        back.accessibilityLabel = @"Back";
        __weak ApolloDuoSplitState *weakProfileState = state;
        [back addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            ApolloDuoSplitState *current = weakProfileState;
            if (!current || current.changing) return;
            ApolloDuoSplitNavigateProfile(current, nil, NO);
        }] forControlEvents:UIControlEventTouchUpInside];
        host.profileBackButton = back;
    }
    __weak ApolloDuoSplitState *weakState = state;
    UIButton *accounts = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration;
    if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
    else configuration = [UIButtonConfiguration tintedButtonConfiguration];
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.image = [UIImage systemImageNamed:@"person.2" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular]];
    configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    accounts.accessibilityLabel = @"Accounts";
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    accounts.configuration = configuration;
    [accounts addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        UIViewController *root = weakState.root;
        SEL selector = NSSelectorFromString(@"accountsBarButtonItemTappedWithSender:");
        if ([root respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(root, selector, nil);
    }] forControlEvents:UIControlEventTouchUpInside];
    host.accountsButton = accounts;
    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 26.0, *)) configuration = [UIButtonConfiguration glassButtonConfiguration];
    else configuration = [UIButtonConfiguration tintedButtonConfiguration];
    Ivar moreIvar = class_getInstanceVariable([profile class], "moreOptionsBarButtonItem");
    UIBarButtonItem *nativeMore = moreIvar ? object_getIvar(profile, moreIvar) : nil;
    configuration.image = nativeMore.image ?: [UIImage systemImageNamed:@"ellipsis"];
    configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    more.configuration = configuration;
    more.accessibilityLabel = @"More Options";
    UIAction *trophies = [UIAction actionWithTitle:@"Trophies" image:[UIImage systemImageNamed:@"trophy"] identifier:nil handler:^(__unused UIAction *action) {
        ApolloDuoAccountSelect(weakState, @"Trophies");
    }];
    UIMenu *nativeMenu = ApolloProfileMoreMenuForController(profile);
    more.menu = [UIMenu menuWithTitle:@"" children:[(nativeMenu.children ?: @[]) arrayByAddingObject:trophies]];
    more.showsMenuAsPrimaryAction = YES;
    host.moreButton = more;
    accounts.tintColor = UIColor.labelColor;
    more.tintColor = ApolloNavigationChromeColor();
}

static void ApolloDuoSplitOpen(ApolloDuoSplitState *state) {
    UINavigationController *outer = state.outer;
    id<UIViewControllerTransitionCoordinator> transition = outer.transitionCoordinator;
    if (state.split || state.changing) {
        [sDuoSplitDeferredPresentations removeObject:state];
        return;
    }
    if (outer.presentedViewController) {
        // An over-fullscreen modal such as Pixel Pals can stay open through
        // unfolding without another appearance callback on its presenter.
        // Keep reparenting out of that presentation, but remember to install
        // the columns when dismissal releases the native navigation stack.
        if (!sDuoSplitDeferredPresentations) sDuoSplitDeferredPresentations = [NSHashTable weakObjectsHashTable];
        if (![sDuoSplitDeferredPresentations containsObject:state])
            ApolloLog(@"[DuoSplit] deferring %@ columns until modal dismissal", state.kind);
        [sDuoSplitDeferredPresentations addObject:state];
        return;
    }
    if (transition && transition != sDuoSplitSizeCoordinator) {
        // A native push/pop may still own the stack when unfolding begins.
        // Retry at its completion; a layout pass during that transition is
        // too early, and the idle tab may never produce another one.
        if (state.pendingNavigationTransition != transition) {
            state.pendingNavigationTransition = transition;
            __weak ApolloDuoSplitState *weakState = state;
            [transition animateAlongsideTransition:nil
                                       completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                weakState.pendingNavigationTransition = nil;
                ApolloDuoSplitScheduleUpdate();
            }];
        }
        return;
    }
    state.changing = YES;
    if ([state.kind isEqualToString:@"subreddits"] && outer.viewControllers.count == 1) {
        UIViewController *forward = ApolloDuoSplitForwardPage(outer);
        if (forward) {
            // goForward calls Apollo's Swift push helper directly with
            // animated:YES. performWithoutAnimation does not change that
            // navigation operation, nor does it reach our ObjC push hook.
            // Reparenting its pages immediately leaves the pending transition
            // owning the outer stack: its completion removes our split host
            // and the tab ends up with no controllers at all.
            // Consume the same forward entry through a genuinely nonanimated
            // push, then build the columns on the next main-queue turn, after
            // native didShow/history bookkeeping has finished.
            [outer pushViewController:forward animated:NO];
            if (outer.topViewController == forward) {
                state.changing = NO;
                ApolloLog(@"[DuoSplit] restored forward page before installing columns");
                ApolloDuoSplitScheduleUpdate();
                return;
            }
        }
    }
    // Retain the deferred marker through the early navigation/forward-page
    // retries above. Consume it only when we can actually install the host.
    BOOL revealFeedControls = [sDuoSplitDeferredPresentations containsObject:state]
        && outer.tabBarController.selectedViewController == outer && outer.viewIfLoaded.window;
    [sDuoSplitDeferredPresentations removeObject:state];
    NSArray *stack = [outer.viewControllers copy];
    NSUInteger rootIndex = 0;
    // Only landscape has a profile dashboard. Portrait keeps visited profiles
    // on the Posts navigation stack; promoting one to Account here would make
    // the next update collapse it, then reopen Posts and repeat indefinitely.
    if (ApolloDuoSplitShouldOpen((id)outer.tabBarController)) {
        for (NSUInteger index = 1; index < stack.count; index++) {
            if ([ApolloDuoSplitKind(stack[index]) isEqualToString:@"account"]) rootIndex = index;
        }
    }
    if (rootIndex) {
        state.tabRoot = state.root;
        state.tabKind = state.kind;
        state.profilePrefix = [stack subarrayWithRange:NSMakeRange(0, rootIndex)];
        state.root = stack[rootIndex];
        state.kind = @"account";
    }
    NSArray *detail = stack.count > rootIndex + 1
        ? [stack subarrayWithRange:NSMakeRange(rootIndex + 1, stack.count - rootIndex - 1)] : @[];
    state.navigationBarWasHidden = outer.navigationBarHidden;
    state.sidebarTitle = state.root.navigationItem.title;
    UISplitViewController *split = [[UISplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    // An unfold starts while the outer controller still has the cover
    // display's compact traits. Pin the split itself before attaching either
    // column: a parent override applied afterward is too late and UIKit starts
    // a compact-column merge during viewWillTransitionToSize:.
    if (@available(iOS 17.0, *)) {
        split.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassRegular;
    }
    split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    split.preferredPrimaryColumnWidthFraction = 1.0 / 3.0;
    split.minimumPrimaryColumnWidth = 240.0;
    split.maximumPrimaryColumnWidth = 420.0;
    split.primaryEdge = UISplitViewControllerPrimaryEdgeLeading;
    split.presentsWithGesture = YES;
    // Release native ownership before reparenting. No view/frame stealing,
    // layout-loop repinning, or replacement of the tab's navigation object.
    ApolloDuoSplitHost *host = [ApolloDuoSplitHost new];
    // Dark/opaque themes make the native tab bar nontranslucent. A plain
    // controller's default layout then subtracts the vertical rail's entire
    // height as though it were a bottom bar, collapsing this host to zero.
    // Match Apollo's native pages and let the split's safe areas own the inset.
    host.extendedLayoutIncludesOpaqueBars = YES;
    host.split = split;
    state.host = host;
    BOOL account = [state.kind isEqualToString:@"account"];
    if (account) ApolloDuoAccountPrepareHost(state, host);
    BOOL posts = [state.kind isEqualToString:@"subreddits"];
    [outer setViewControllers:@[host] animated:NO];
    state.split = split;
    state.root.extendedLayoutIncludesOpaqueBars = YES;
    ApolloDuoAccountShortcuts *shortcuts = account ? [ApolloDuoAccountShortcuts new] : nil;
    shortcuts.profileTable = account ? ApolloDuoSplitFindTable(state.root.view) : nil;
    state.primary = [[outer.class alloc] initWithRootViewController:shortcuts ?: state.root];
    state.secondary = [[outer.class alloc] init];
    if ([state.kind isEqualToString:@"search"]) host.searchNavigation = state.primary;
    ApolloDuoSplitLink(state.primary, state);
    ApolloDuoSplitLink(state.secondary, state);
    if (account) {
        [state.primary setNavigationBarHidden:YES animated:NO];
        [state.secondary setViewControllers:[@[state.root] arrayByAddingObjectsFromArray:detail] animated:NO];
        [state.secondary setNavigationBarHidden:detail.count == 0 animated:NO];
        __weak ApolloDuoSplitState *weakState = state;
        shortcuts.selectShortcut = ^(NSString *title) { ApolloDuoAccountSelect(weakState, title); };
        ApolloDuoAccountConfigureOverviewTable(ApolloDuoSplitFindTable(state.root.view), YES);
    } else if (detail.count) [state.secondary setViewControllers:detail animated:NO];
    else {
        UIViewController *placeholder = [UIViewController new];
        placeholder.view.backgroundColor = UIColor.systemBackgroundColor;
        [state.secondary setViewControllers:@[placeholder] animated:NO];
    }
    if (posts) {
        state.feed = [[outer.class alloc] init];
        ApolloDuoSplitLink(state.feed, state);
        NSArray *feedPages = detail.count ? @[detail.firstObject] : @[[UIViewController new]];
        [state.secondary setViewControllers:@[] animated:NO];
        [state.feed setViewControllers:feedPages animated:NO];
        UIViewController *backstop = [UIViewController new];
        backstop.title = @"Feed";
        NSArray *comments = detail.count > 1 ? [detail subarrayWithRange:NSMakeRange(1, detail.count - 1)] : @[];
        [state.secondary setViewControllers:[@[backstop] arrayByAddingObjectsFromArray:comments] animated:NO];
        // The host may already have loaded while the outer stack was changed.
        // Recreate it with the overlay configured before viewDidLoad.
        ApolloDuoSplitHost *postsHost = [ApolloDuoSplitHost new];
        postsHost.extendedLayoutIncludesOpaqueBars = YES;
        postsHost.split = split;
        postsHost.subredditList = state.primary;
        postsHost.postsNavigation = state.feed;
        postsHost.pendingFeedControlsReveal = revealFeedControls;
        postsHost.postsSplitEnabled = ![NSUserDefaults.standardUserDefaults boolForKey:@"ApolloDuoPostsSplitDisabled"];
        split.displayModeButtonVisibility = UISplitViewControllerDisplayModeButtonVisibilityNever;
        split.presentsWithGesture = NO;
        __weak ApolloDuoSplitState *weakPostsState = state;
        postsHost.togglePostsSplit = ^{
            ApolloDuoSplitState *live = weakPostsState;
            ApolloDuoPostsToggleSplit(live);
        };
        if (split.parentViewController) {
            [split willMoveToParentViewController:nil];
            [split.view removeFromSuperview];
            [split removeFromParentViewController];
        }
        state.host = postsHost;
        host = postsHost;
        [outer setViewControllers:@[host] animated:NO];
        state.changing = NO;
        ApolloDuoPostsSyncColumns(state);
        state.changing = YES;
    } else if (account) {
        host.accountPrimary = [ApolloDuoAccountColumn new];
        host.accountPrimary.extendedLayoutIncludesOpaqueBars = YES;
        host.accountPrimary.navigation = state.primary;
        __weak ApolloDuoSplitHost *weakAccountHost = host;
        host.accountPrimary.geometryDidChange = ^{
            ApolloDuoSplitHost *liveHost = weakAccountHost;
            [liveHost.view setNeedsLayout];
            [liveHost.accountHeader setNeedsLayout];
        };
        host.accountSecondary = [ApolloDuoAccountColumn new];
        host.accountSecondary.extendedLayoutIncludesOpaqueBars = YES;
        host.accountSecondary.navigation = state.secondary;
        CGFloat height = ApolloDuoAccountHeaderHeight(host.accountHeader, outer.view.bounds.size.width);
        host.accountPrimary.contentTop = height;
        host.accountSecondary.contentTop = detail.count ? 0 : height;
        [split setViewController:host.accountPrimary forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:host.accountSecondary forColumn:UISplitViewControllerColumnSecondary];
        // UISplitViewController wraps non-navigation columns in its own
        // navigation controllers. Their bars would duplicate the native page
        // bar (and consume the entire vertical rail under opaque themes).
        [(UINavigationController *)host.accountPrimary.parentViewController setNavigationBarHidden:YES animated:NO];
        [(UINavigationController *)host.accountSecondary.parentViewController setNavigationBarHidden:YES animated:NO];
    } else {
        [split setViewController:state.primary forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:state.secondary forColumn:UISplitViewControllerColumnSecondary];
    }
    ApolloDuoSplitApplySidebarWidth(state, ApolloDuoSplitWantsHalfWidth((id)outer.tabBarController));
    [outer setNavigationBarHidden:YES animated:NO];
    // The compatibility phone can retain a compact horizontal size class on
    // its wide inner display. The width/rail gate above is authoritative.
    [outer setOverrideTraitCollection:[UITraitCollection traitCollectionWithHorizontalSizeClass:UIUserInterfaceSizeClassRegular]
              forChildViewController:host];
    state.needsDefault = detail.count == 0;
    state.changing = NO;
    ApolloDuoSearchUpdateBackItem(state);
    ApolloLog(@"[DuoSplit] opened native %@ sidebar/detail", state.kind);
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloDuoSplitOpenDefault(state); });
}

static void ApolloDuoSplitClose(ApolloDuoSplitState *state, BOOL preserveDetail) {
    [sDuoSplitDeferredPresentations removeObject:state];
    if (!state.split || state.changing) return;
    state.changing = YES;
    ApolloDuoPostsStopGeometry(state.host.searchNavigation.viewIfLoaded);
    ApolloDuoSearchRestoreBackItem(state);
    NSArray *detail = [state.secondary.viewControllers copy];
    if (state.feed) {
        ApolloNativeFeedSearchSetDuoControls(state.host.feedControlsOwner, nil, nil, nil);
        state.host.feedControlsOwner = nil;
        ApolloDuoPostsStopGeometry(state.feed.viewIfLoaded);
        ApolloDuoPostsStopGeometry(state.secondary.viewIfLoaded);
        [state.host.postsTransitionSnapshot removeFromSuperview];
        state.host.postsTransitionSnapshot = nil;
        [state.secondary.view.layer removeAnimationForKey:@"ApolloDuoSlide"];
        [state.host restoreListBackgrounds];
        // Stop suppressing the feed before its item setter runs, then discard
        // this presentation's snapshot so reopening cannot reuse stale items.
        state.host.postsColumnsPaired = NO;
        if (state.feedActions) state.feed.viewControllers.firstObject.navigationItem.rightBarButtonItems = state.feedActions;
        state.feedActions = nil;
        NSArray *comments = detail.count > 1 ? [detail subarrayWithRange:NSMakeRange(1, detail.count - 1)] : @[];
        detail = [state.feed.viewControllers arrayByAddingObjectsFromArray:comments];
        [state.feed setViewControllers:@[] animated:NO];
    }
    if ([state.kind isEqualToString:@"account"]) {
        NSMutableArray *pages = [detail mutableCopy];
        [pages removeObjectIdenticalTo:state.root];
        detail = pages;
        ApolloDuoAccountRestoreProfile(state.root);
        ApolloDuoAccountConfigureOverviewTable(ApolloDuoSplitFindTable(state.root.view), NO);
    }
    if (detail.count && [detail.firstObject class] == UIViewController.class) detail = @[];
    if ([state.kind isEqualToString:@"settings"] && detail.count) state.lastSettings = detail;
    [state.primary setViewControllers:@[] animated:NO];
    [state.secondary setViewControllers:@[] animated:NO];
    [state.outer setOverrideTraitCollection:nil forChildViewController:state.host];
    // Settings and Inbox have automatically selected detail pages. Account
    // starts at Overview, so any remaining detail was opened by the user and
    // must stay on top when the split collapses to the cover display.
    BOOL overviewOnCover = !preserveDetail && !state.profilePrefix.count && !ApolloDuoSplitIsUnfolded()
        && ([state.kind isEqualToString:@"settings"] || [state.kind isEqualToString:@"inbox"]);
    NSArray *restored = overviewOnCover ? @[state.root] : [@[state.root] arrayByAddingObjectsFromArray:detail];
    if (state.profilePrefix.count) restored = [state.profilePrefix arrayByAddingObjectsFromArray:restored];
    [state.outer setViewControllers:restored animated:NO];
    [state.outer setNavigationBarHidden:state.navigationBarWasHidden animated:NO];
    // Account switches update the native profile title while the split is open.
    // Restoring its entry-time title would repoint the cover header at the old user.
    if (![state.kind isEqualToString:@"account"]) state.root.navigationItem.title = state.sidebarTitle;
    if (state.profilePrefix.count) {
        state.root = state.tabRoot;
        state.kind = state.tabKind;
        state.tabRoot = nil;
        state.tabKind = nil;
        state.profilePrefix = nil;
    }
    state.split = nil;
    state.host = nil;
    state.primary = nil;
    state.secondary = nil;
    state.feed = nil;
    state.needsDefault = NO;
    state.changing = NO;
    ApolloLog(@"[DuoSplit] restored single-column %@ stack", state.kind);
}

// Reparent the live pages under one visual transition. A snapshot covers the
// intermediate single-column stack, so UIKit cannot flash that layout first.
static void ApolloDuoSplitNavigateProfile(ApolloDuoSplitState *state, UIViewController *profile, BOOL forward) {
    if (!state.split || state.changing) return;
    UINavigationController *outer = state.outer;
    UIView *oldView = state.host.view;
    UIView *snapshot = [oldView snapshotViewAfterScreenUpdates:NO];
    CGRect frame = [oldView convertRect:oldView.bounds toView:outer.view];
    NSArray *prefix = state.profilePrefix;
    [UIView performWithoutAnimation:^{
        ApolloDuoSplitClose(state, YES);
        NSArray *stack = forward ? [outer.viewControllers arrayByAddingObject:profile] : prefix;
        [outer setViewControllers:stack animated:NO];
        ApolloDuoSplitOpen(state);
        [outer.view layoutIfNeeded];
    }];
    UIView *destination = state.host.view;
    if (!snapshot || !destination || UIAccessibilityIsReduceMotionEnabled()) return;
    snapshot.frame = frame;
    snapshot.userInteractionEnabled = NO;
    [outer.view addSubview:snapshot];
    CGFloat direction = forward ? 1 : -1;
    CGFloat width = CGRectGetWidth(frame);
    destination.transform = CGAffineTransformMakeTranslation(direction * width, 0);
    [outer.view bringSubviewToFront:destination];
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        destination.transform = CGAffineTransformIdentity;
        snapshot.transform = CGAffineTransformMakeTranslation(-direction * width, 0);
    } completion:^(__unused BOOL finished) {
        [snapshot removeFromSuperview];
        destination.transform = CGAffineTransformIdentity;
    }];
}

BOOL ApolloDuoSplitReturnFromVisitedProfile(UINavigationController *navigation) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    if (!state.split || state.changing || !state.profilePrefix.count
        || ![state.kind isEqualToString:@"account"]
        || ![state.tabKind isEqualToString:@"subreddits"]
        || state.secondary.viewControllers.count != 1
        || state.secondary.topViewController != state.root) return NO;
    // An unfolded visited profile is the dashboard's detail root. Its native
    // Back pages are retained outside that one-page navigation stack, so use
    // the same transition as the profile's Back button. The Account tab has
    // no Posts prefix and must retain its own profile at the top.
    ApolloDuoSplitNavigateProfile(state, nil, NO);
    return YES;
}

static void ApolloDuoSplitUpdate(void) {
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (sDuoSplitUpdating || ![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone
        && !ApolloDuoRailHasVisibleSideBar()) return;
    sDuoSplitUpdating = YES;
    ApolloDuoSplitObserveHinge(tabs);
    BOOL open = ApolloDuoSplitShouldOpen(tabs);
    for (UIViewController *child in tabs.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *nav = (id)child;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, open || child == tabs.selectedViewController);
        if (!state) continue;
        BOOL postsOpen = [state.kind isEqualToString:@"subreddits"] && ApolloDuoSplitIsUnfolded();
        if (!open && !postsOpen) ApolloDuoSplitClose(state, NO);
        else {
            // Native Swift pushes can bypass the ObjC push hook. On rotation
            // into landscape, a profile may also still be on the portrait feed
            // stack. Normalize either path before installing its dashboard.
            if (open) {
                NSArray *pages = [(state.feed.viewControllers ?: @[])
                    arrayByAddingObjectsFromArray:state.secondary.viewControllers ?: @[]];
                for (UIViewController *page in pages) {
                    if (page != state.root && [ApolloDuoSplitKind(page) isEqualToString:@"account"]) {
                        ApolloDuoSplitClose(state, YES);
                        break;
                    }
                }
            }
            // Search stays full-width until a result is opened. Once it has
            // a detail page, retain the query/results in the sidebar.
            if ([state.kind isEqualToString:@"search"] && !state.split && nav.viewControllers.count < 2) continue;
            ApolloDuoSplitOpen(state);
            BOOL halfWidth = ApolloDuoSplitWantsHalfWidth(tabs);
            if (state.split && state.halfWidthSidebar != halfWidth) {
                // UIKit animates the same column containers; content and
                // navigation chrome move with the divider in both directions.
                [UIView animateWithDuration:0.25 animations:^{
                    ApolloDuoSplitApplySidebarWidth(state, halfWidth);
                    [state.split.view layoutIfNeeded];
                }];
            }
            ApolloDuoSplitOpenDefault(state);
            ApolloDuoPostsSyncColumns(state);
            ApolloDuoSearchUpdateBackItem(state);
            if ([state.kind isEqualToString:@"account"] && state.split) {
                BOOL overview = state.secondary.topViewController == state.root;
                if (!state.secondary.transitionCoordinator && state.secondary.navigationBarHidden != overview) {
                    [state.secondary setNavigationBarHidden:overview animated:NO];
                }
                if (state.host.moreButton.hidden == overview) [state.host.view setNeedsLayout];
            }
            if ([state.primary.viewControllers.firstObject isKindOfClass:ApolloDuoAccountShortcuts.class]) {
                [(ApolloDuoAccountShortcuts *)state.primary.viewControllers.firstObject refreshProfileMenu];
            }
        }
    }
    sDuoSplitUpdating = NO;
    if ([tabs.selectedViewController isKindOfClass:UINavigationController.class]) {
        ApolloDuoSplitHost *host = ApolloDuoSplitStateForNavigation((id)tabs.selectedViewController, NO).host;
        if (host.pendingFeedControlsReveal) {
            __weak ApolloDuoSplitHost *weakHost = host;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakHost revealRestoredFeedControls]; });
        }
    }
}

void ApolloDuoSplitScheduleUpdate(void) {
    if (sDuoSplitUpdateScheduled) return;
    UITabBarController *tabs = (id)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return;
    if (tabs != sDuoSplitKnownTabs && ApolloDuoCurrentMode() == ApolloDuoModePhone
        && !ApolloDuoRailHasVisibleSideBar()) return;
    sDuoSplitUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sDuoSplitUpdateScheduled = NO;
        ApolloDuoSplitUpdate();
    });
}

static BOOL ApolloDuoSplitHasDeferredPresentationInWindow(UIWindow *window) {
    if (!window) return NO;
    for (ApolloDuoSplitState *state in sDuoSplitDeferredPresentations.allObjects) {
        if (state.outer.viewIfLoaded.window == window) return YES;
    }
    return NO;
}

%hook UIViewController
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    UIWindow *window = ((UIViewController *)self).viewIfLoaded.window
        ?: ((UIViewController *)self).presentingViewController.viewIfLoaded.window;
    if (!ApolloDuoSplitHasDeferredPresentationInWindow(window)) {
        %orig(animated, completion);
        return;
    }
    void (^duoCompletion)(void) = ^{
        if (completion) completion();
        // Dismissal may not relayout the tab controller behind an overlay.
        // Refresh its cached mode before the existing coalesced update reads
        // the now-current canvas and restores the host's List/Layout/Split UI.
        ApolloLog(@"[DuoSplit] retrying deferred columns after modal dismissal");
        ApolloDuoRailSync();
        ApolloDuoSplitScheduleUpdate();
    };
    %orig(animated, duoCompletion);
}
%end

static BOOL ApolloDuoSplitRoutePush(UINavigationController *nav, UIViewController *page, BOOL animated) {
    // UIKit pushes column containers while adapting a split. Those are native
    // containment operations, not sidebar selections. Redirecting the secondary
    // navigation controller into its own stack raises a UIKit assertion.
    if ([page isKindOfClass:UINavigationController.class] ||
        [page isKindOfClass:UISplitViewController.class]) return NO;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, YES);
    if (state.split && !state.changing && [ApolloDuoSplitKind(page) isEqualToString:@"account"]) {
        if (ApolloDuoSplitShouldOpen((id)state.outer.tabBarController)) {
            ApolloDuoSplitNavigateProfile(state, page, YES);
            return YES;
        }
        // The portrait drawer is an overlay, not a profile sidebar. Push onto
        // the retained feed so native Back returns to the previous page.
        if (state.feed && (nav == state.primary || nav == state.outer)) {
            [state.feed pushViewController:page animated:animated];
            [state.host setListVisible:NO animated:animated];
            return YES;
        }
    }
    if (state.feed && !state.changing) {
        if (state.host.postsColumnsPaired && (nav == state.feed || nav == state.outer)) {
            NSString *incomingPost = ApolloDuoCommentsPostID(page);
            NSString *visiblePost = ApolloDuoCommentsPostID(state.secondary.topViewController);
            // A comment permalink is a deliberate jump within a post, not a
            // feed re-selection. Keep those native navigations available.
            if (incomingPost.length && [incomingPost isEqualToString:visiblePost]
                && !ApolloReadSwiftStringIvar(page, "commentID").length) {
                ApolloLog(@"[DuoSplit] current post reselected; keeping comments and scroll position");
                return YES;
            }
        }
        state.needsDefault = NO;
        if (nav == state.primary || (nav == state.outer && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"])) {
            // Apollo may wait for subreddit data before pushing. The drawer
            // has already dismissed by then, so its visibility is not an
            // animation gate; preserve the originating navigation request.
            BOOL animate = animated && !UIAccessibilityIsReduceMotionEnabled();
            [state.secondary setViewControllers:@[state.secondary.viewControllers.firstObject] animated:NO];
            ApolloDuoPostsSyncColumns(state);
            [state.host.view layoutIfNeeded];
            // Let Apollo's navigation controller/delegate perform its normal
            // forward transition. Replacing the root with animation avoids
            // accumulating old subreddit pages in the comments Back stack.
            [state.feed setViewControllers:@[page] animated:animate];
            ApolloLog(@"[DuoSplit] subreddit forward transition animated=%d", animate);
            [state.host setListVisible:NO animated:YES];
        } else if (nav == state.feed || nav == state.outer) {
            if (!ApolloDuoPostsUsesSplit(state)) {
                // A single page needs no column replacement or custom slide.
                // Apollo's native animator keeps the outgoing Focused feed
                // visible underneath the arriving thread (and on Back).
                if (nav == state.feed) return NO;
                [state.feed pushViewController:page animated:animated];
                return YES;
            }
            ApolloDuoPostsSetDetail(state, page, animated);
        } else return NO;
        ApolloDuoPostsSyncColumns(state);
        return YES;
    }
    NSArray<ApolloDuoPostsGeometry *> *searchGeometry = nil;
    CGRect searchViewport = CGRectZero;
    if ([state.kind isEqualToString:@"search"] && nav == state.outer && !state.split
        && ApolloDuoSplitShouldOpen((id)nav.tabBarController)) {
        if (state.outer.view.window && !UIAccessibilityIsReduceMotionEnabled()
            && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"]) {
            // Capture the live Search hierarchy before its controller moves
            // into the new primary navigation container. Retained search-bar
            // and row views will resize with the incoming page, not snap to
            // the narrow column before that page reaches it.
            UIView *oldSurface = state.outer.view;
            [oldSurface layoutIfNeeded];
            searchGeometry = ApolloDuoPostsCaptureGeometry(oldSurface, oldSurface);
            searchViewport = oldSurface.bounds;
        }
        ApolloDuoSplitOpen(state);
    }
    if (state.split && !state.changing && [state.kind isEqualToString:@"account"]
        && nav == state.secondary && !state.selectingAccountShortcut) {
        // Content links are pushes, not menu replacements. Commit the stack
        // and full-height geometry together before fading in the destination.
        ApolloDuoAccountSetPages(state, [state.secondary.viewControllers arrayByAddingObject:page]);
        return YES;
    }
    if (!state.split || state.changing || (nav != state.primary && nav != state.outer && !state.selectingAccountShortcut)) return NO;
    if ([state.kind isEqualToString:@"settings"] && page.class != UIViewController.class
        && page.class == state.secondary.viewControllers.firstObject.class) {
        // Each native Settings root row constructs its own destination class.
        // Re-selecting the row returns to its retained first page. Keeping
        // that controller preserves its scroll position and live controls;
        // an already visible first page needs no navigation at all.
        // Only root/sidebar pushes reach this branch; detail-page navigation
        // remains Apollo's normal push path.
        if (state.secondary.viewControllers.count > 1) {
            [state.secondary popToRootViewControllerAnimated:animated && !UIAccessibilityIsReduceMotionEnabled()];
        }
        ApolloLog(@"[DuoSplit] current Settings destination reselected; keeping root page");
        return YES;
    }
    state.needsDefault = NO;
    if ([state.kind isEqualToString:@"account"]) {
        ApolloDuoAccountSetPages(state, @[state.root, page]);
    } else {
        BOOL searchSubreddit = [state.kind isEqualToString:@"search"]
            && [NSStringFromClass(page.class) isEqualToString:@"Apollo.PostsViewController"];
        // A new Search detail may still be loading when UIKit performs the
        // root replacement. Animate its entire live navigation pane, including
        // chrome, rather than a blank page whose content appears afterward.
        // This mirrors the explicit rightward Back across the split boundary.
        [state.secondary setViewControllers:@[page] animated:NO];
        if (searchSubreddit) {
            ApolloDuoSearchUpdateBackItem(state);
            // The host was just installed as the outer navigation root.
            // Layout the outer container first so UIKit attaches and sizes
            // its child before checking visibility or reading the pane.
            UIView *surface = state.host.view;
            [UIView performWithoutAnimation:^{
                [state.outer.view layoutIfNeeded];
                [surface layoutIfNeeded];
                [state.secondary.view layoutIfNeeded];
            }];
            CGRect pane = ApolloDuoPostsDetailPane(state);
            BOOL animate = state.outer.view.window && !UIAccessibilityIsReduceMotionEnabled()
                && !CGRectIsNull(pane) && !CGRectIsEmpty(pane);
            if (animate) {
                CGFloat travel = CGRectGetMaxX(surface.bounds) - CGRectGetMinX(pane);
                if (searchGeometry.count) {
                    // The primary navigation controller is new, but Search's
                    // content is retained. Give its clipping viewport the old
                    // full-width endpoint so its live children remain visible
                    // throughout their coordinated resize into the sidebar.
                    ApolloDuoPostsGeometry *viewport = [ApolloDuoPostsGeometry new];
                    viewport.view = state.primary.view;
                    viewport.bounds = searchViewport;
                    viewport.surfaceFrame = [surface convertRect:searchViewport fromView:state.outer.view];
                    NSMutableArray *geometry = [searchGeometry mutableCopy];
                    [geometry insertObject:viewport atIndex:0];
                    NSHashTable *retained = [NSHashTable weakObjectsHashTable];
                    for (ApolloDuoPostsGeometry *item in geometry) if (item.view) [retained addObject:item.view];
                    CGFloat expansion = CGRectGetWidth(searchViewport) - CGRectGetWidth(state.primary.view.bounds);
                    // UIKit may create new clipping wrappers around the
                    // retained page. Their leading edges stay fixed, and their
                    // widths follow the new navigation viewport as well.
                    for (UIView *wrapper = state.root.view.superview;
                         wrapper && wrapper != state.primary.view;
                         wrapper = wrapper.superview) {
                        if ([retained containsObject:wrapper]) continue;
                        ApolloDuoPostsGeometry *item = [ApolloDuoPostsGeometry new];
                        item.view = wrapper;
                        item.parent = wrapper.superview;
                        CGRect bounds = wrapper.bounds;
                        bounds.size.width += expansion;
                        item.bounds = bounds;
                        item.position = CGPointMake(wrapper.layer.position.x + expansion * wrapper.layer.anchorPoint.x,
                                                    wrapper.layer.position.y);
                        [geometry addObject:item];
                    }
                    ApolloDuoAnimateRetainedGeometry(geometry, state.primary.view, surface, 0.32, YES);
                }
                if (travel > 0) ApolloDuoSlideView(state.secondary.view, travel, 0, 0.32, nil);
            }
        }
    }
    ApolloDuoSearchUpdateBackItem(state);
    if ([state.kind isEqualToString:@"subreddits"]) {
        // A sidebar selection no longer pushes the list off screen, so its
        // usual viewWillAppear deselection never runs. End the tap feedback
        // after UIKit finishes selecting the row; otherwise Home/subreddits
        // retain a solid highlight until the list disappears or is reused.
        __weak UIViewController *weakRoot = state.root;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *root = weakRoot;
            if (!root || root.isEditing) return;
            UITableView *table = ApolloDuoSplitFindTable(root.viewIfLoaded);
            for (NSIndexPath *path in table.indexPathsForSelectedRows) {
                [table deselectRowAtIndexPath:path animated:YES];
            }
        });
    }
    // The detail column is already present. showColumn:Secondary is not a
    // harmless reveal while an offscreen tab is adapting: UIKit changes its
    // preferredDisplayMode to SecondaryOnly, so Account/Inbox lose their
    // sidebar when the tab next appears. Keep the user's display mode intact.
    ApolloLog(@"[DuoSplit] %@ selection replaced detail with %@", state.kind, NSStringFromClass(page.class));
    return YES;
}

static void ApolloDuoSplitRememberSettings(UINavigationController *nav) {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(nav, YES);
    if (state.changing || ![state.kind isEqualToString:@"settings"]) return;
    NSArray *stack = nav.viewControllers;
    if (!state.split && stack.count > 1) state.lastSettings = [stack subarrayWithRange:NSMakeRange(1, stack.count - 1)];
    else if (nav == state.secondary && stack.count) state.lastSettings = [stack copy];
}

// Read the synchronous model identity, never the title pill: titles may be
// localized or temporarily describe the prior page during an asynchronous load.
// PostsType.subreddit stores its Swift String in the first two words and tag 0
// at +0x20 (the same native layout used by SubredditHeaders/AutoHideMetaFeeds).
static NSString *ApolloDuoNamedSubredditForPostsController(UIViewController *controller) {
    Class postsClass = NSClassFromString(@"Apollo.PostsViewController");
    if (!postsClass || ![controller isKindOfClass:postsClass]) return nil;
    Ivar type = class_getInstanceVariable(controller.class, "currentPostsType");
    if (!type) return nil;
    ptrdiff_t offset = ivar_getOffset(type);
    if (offset < 0 || (size_t)offset + 0x21 > class_getInstanceSize(controller.class)) return nil;
    const uint8_t *storage = (const uint8_t *)(__bridge const void *)controller + offset;
    if (storage[0x20] != 0) return nil;
    uint64_t words[2] = {0, 0};
    memcpy(words, storage, sizeof(words));
    NSString *name = ApolloDecodeSwiftString(words[0], words[1]);
    if (name.length == 0) return nil;
    // Apollo encodes these built-in feeds as the same enum case. They retain
    // their native reselect behavior; this guard is only for subreddit rows.
    if ([@[@"all", @"popular", @"mod", @"random", @"randnsfw"] containsObject:name.lowercaseString]) return nil;
    return name;
}

static NSIndexPath *(*sApolloDuoListWillSelectOriginal)(id, SEL, UITableView *, NSIndexPath *);
static NSIndexPath *ApolloDuoListWillSelect(id controller, SEL selector, UITableView *table, NSIndexPath *path) {
    NSIndexPath *candidate = sApolloDuoListWillSelectOriginal
        ? sApolloDuoListWillSelectOriginal(controller, selector, table, path) : path;
    if (!candidate) return nil;
    UIViewController *list = (UIViewController *)controller;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(list.navigationController, NO);
    if (!state.split || !state.feed || state.changing || !state.host.listVisible
        || list.navigationController != state.primary || list.isEditing || table.isEditing) return candidate;

    // willSelect still has UIKit's VISIBLE path. The Following module maps
    // didSelect into native section space later, so resolving a row there would
    // double-map reordered/FOLLOWING sections and could suppress the wrong row.
    NSString *target = ApolloSubredditListNameAtIndexPath(table, candidate);
    NSString *current = ApolloDuoNamedSubredditForPostsController(state.feed.viewControllers.firstObject);
    if (target.length == 0 || current.length == 0
        || [target caseInsensitiveCompare:current] != NSOrderedSame) return candidate;

    __weak ApolloDuoSplitHost *weakHost = state.host;
    __weak UITableView *weakTable = table;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *liveTable = weakTable;
        [[liveTable cellForRowAtIndexPath:candidate] setHighlighted:NO animated:YES];
        for (NSIndexPath *selected in liveTable.indexPathsForSelectedRows) {
            [liveTable deselectRowAtIndexPath:selected animated:YES];
        }
        [weakHost setListVisible:NO animated:YES];
    });
    ApolloLog(@"[DuoSplit] current subreddit reselected; dismissing drawer without navigation");
    // Cancel before Apollo fetches or replaces the feed. In particular, retain
    // both its scroll position and any currently open comments navigation stack.
    return nil;
}

static void ApolloDuoInstallListReselectionGuard(Class listClass) {
    SEL selector = @selector(tableView:willSelectRowAtIndexPath:);
    Method existing = class_getInstanceMethod(listClass, selector);
    sApolloDuoListWillSelectOriginal = existing
        ? (NSIndexPath *(*)(id, SEL, UITableView *, NSIndexPath *))method_getImplementation(existing) : NULL;
    const char *types = existing ? method_getTypeEncoding(existing) : "@@:@@";
    // Prefer an override on this class, preserving any inherited delegate method.
    if (!class_addMethod(listClass, selector, (IMP)ApolloDuoListWillSelect, types)) {
        class_replaceMethod(listClass, selector, (IMP)ApolloDuoListWillSelect, types);
    }
}

// List navigation can reuse the current feed without calling push. Finish
// the row interaction here so both that path and ordinary pushes dismiss.
@interface ApolloDuoSubredditList : UIViewController @end
%group ApolloDuoSubredditListHooks
%hook ApolloDuoSubredditList
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig(tableView, indexPath);
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(((UIViewController *)self).navigationController, NO);
    if (!state.feed || state.changing || ((UIViewController *)self).isEditing) return;
    __weak ApolloDuoSplitHost *host = state.host;
    __weak UITableView *table = tableView;
    dispatch_async(dispatch_get_main_queue(), ^{
        // UIKit marks selection after the delegate returns.
        for (NSIndexPath *path in table.indexPathsForSelectedRows) {
            [table deselectRowAtIndexPath:path animated:YES];
        }
        [host setListVisible:NO animated:YES];
    });
}
%end
%end

@interface ApolloDuoSplitNavigation : UINavigationController @end
%group ApolloDuoSplitNavigationHooks
%hook ApolloDuoSplitNavigation
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)controller animated:(BOOL)animated {
    %orig(navigation, controller, animated);
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(navigation, NO);
    // Native didShow finalizes the bar after push/pop and column migration.
    // Relayout the host then so it does not keep the outgoing Back reservation.
    if (navigation == state.feed) [state.host.viewIfLoaded setNeedsLayout];
}
- (void)setNavigationBarHidden:(BOOL)hidden animated:(BOOL)animated {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.feed && !state.changing && self == state.primary) hidden = YES;
    if (state.split && !state.changing && self == state.secondary &&
        [state.kind isEqualToString:@"account"] && state.secondary.topViewController == state.root) {
        hidden = YES;
    }
    %orig(hidden, animated);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    UINavigationController *nav = (id)self;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (!state.split || state.changing) return %orig(gesture);
    Ivar leftIvar = class_getInstanceVariable(nav.class, "leftScreenEdgePanGestureRecognizer");
    Ivar rightIvar = class_getInstanceVariable(nav.class, "rightScreenEdgePanGestureRecognizer");
    BOOL back = leftIvar && object_getIvar(self, leftIvar) == gesture;
    BOOL forward = rightIvar && object_getIvar(self, rightIvar) == gesture;
    if (!back && !forward) return %orig(gesture);
    // The outer controller now contains a host, not a browsable page. Its
    // recognizers must not compete with the detail controller's native pans.
    if ((self != state.secondary && !(self == state.feed && !state.host.postsShowingDetail)) || (back && nav.viewControllers.count < 2) ||
        (forward && !ApolloDuoSplitForwardPage(self))) return NO;
    UIView *view = nav.view;
    CGRect pane = UIEdgeInsetsInsetRect(view.bounds, view.safeAreaInsets);
    CGPoint point = [gesture locationInView:view];
    if (!CGRectContainsPoint(pane, point)) return NO;
    sDuoSplitGesture = (__bridge void *)gesture;
    sDuoSplitGestureView = (__bridge void *)view;
    sDuoSplitGestureOffset = back ? -view.safeAreaInsets.left : view.safeAreaInsets.right;
    BOOL result = %orig(gesture);
    sDuoSplitGesture = NULL;
    sDuoSplitGestureView = NULL;
    sDuoSplitGestureOffset = 0.0;
    return result;
}
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    // Record the completed navigation request using its synchronous PostsType
    // slug. Split replacement may lay out before window attachment and omit
    // appearance callbacks; titles/about models can also arrive later.
    NSString *visited = ApolloDuoSplitIsUnfolded() && ((UINavigationController *)self).viewIfLoaded.window
        ? ApolloDuoNamedSubredditForPostsController(controller) : nil;
    if (ApolloDuoSplitRoutePush(self, controller, animated)) {
        if (visited.length) ApolloDuoSearchRecordVisit(visited);
        return;
    }
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.split && (self == state.primary || self == state.secondary || self == state.feed)) {
        controller.extendedLayoutIncludesOpaqueBars = YES;
    }
    if (state.split && [state.kind isEqualToString:@"account"] && self == state.secondary) {
        [state.secondary setNavigationBarHidden:NO animated:NO];
    }
    %orig(controller, state.changing ? NO : animated);
    if (visited.length) ApolloDuoSearchRecordVisit(visited);
    [state.host.viewIfLoaded setNeedsLayout];
    ApolloDuoSplitRememberSettings(self);
}
- (void)setViewControllers:(NSArray<UIViewController *> *)controllers animated:(BOOL)animated {
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.split && (self == state.primary || self == state.secondary || self == state.feed)) {
        // New detail pages default to NO even when existing Apollo pages use
        // YES. Prepare them before UIKit installs the stack, so an opaque
        // theme cannot deduct the vertical tab rail's height from their view.
        // Safe areas already describe the sidebar, navigation bar, and rail.
        for (UIViewController *controller in controllers) {
            controller.extendedLayoutIncludesOpaqueBars = YES;
        }
    }
    %orig(controllers, animated);
    [state.host.viewIfLoaded setNeedsLayout];
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    ApolloDuoSplitRememberSettings(self);
    UINavigationController *detail = ApolloDuoSplitDetailNavigation(self);
    if (detail != self) return [detail popViewControllerAnimated:animated];
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(self, NO);
    if (state.feed && !state.changing && self == state.secondary && state.secondary.viewControllers.count == 2) {
        UIViewController *page = state.secondary.topViewController;
        ApolloDuoPostsSetDetail(state, nil, animated);
        return page;
    }
    if (state.split && !state.changing && [state.kind isEqualToString:@"account"]
        && self == state.secondary && detail.viewControllers.count > 1
        && detail.interactivePopGestureRecognizer.state != UIGestureRecognizerStateBegan
        && detail.interactivePopGestureRecognizer.state != UIGestureRecognizerStateChanged) {
        UIViewController *page = detail.topViewController;
        ApolloDuoAccountSetPages(state, [detail.viewControllers subarrayWithRange:NSMakeRange(0, detail.viewControllers.count - 1)]);
        return page;
    }
    UIViewController *page = %orig(animated);
    [state.host.viewIfLoaded setNeedsLayout];
    ApolloDuoSplitScheduleUpdate();
    return page;
}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated {
    ApolloDuoSplitRememberSettings(self);
    UINavigationController *detail = ApolloDuoSplitDetailNavigation(self);
    if (detail != self) return [detail popToRootViewControllerAnimated:animated];
    NSArray *pages = %orig(animated);
    ApolloDuoSplitScheduleUpdate();
    return pages;
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoSplitScheduleUpdate();
}
%end
%end

%hook UITabBarController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    if (self != (id)ApolloMainTabBarController() ||
        (self != sDuoSplitKnownTabs && !ApolloDuoRailHasVisibleSideBar() && ApolloDuoCurrentMode() == ApolloDuoModePhone)) {
        %orig(size, coordinator);
        return;
    }
    UINavigationController *selectedNavigation = (id)self.selectedViewController;
    UINavigationController *detailNavigation = [selectedNavigation isKindOfClass:UINavigationController.class]
        ? ApolloDuoSplitDetailNavigation(selectedNavigation) : nil;
    UIViewController *selectedPage = detailNavigation.topViewController;
    BOOL profileSection = NO;
    for (UIViewController *page in detailNavigation.viewControllers) {
        if ([ApolloDuoSplitKind(page) isEqualToString:@"account"] && page != selectedPage) profileSection = YES;
    }
    UITableView *sectionTable = profileSection ? ApolloDuoSplitFindTable(selectedPage.viewIfLoaded) : nil;
    NSIndexPath *anchor = sectionTable.indexPathsForVisibleRows.firstObject;
    CGFloat anchorOffset = anchor ? CGRectGetMinY([sectionTable rectForRowAtIndexPath:anchor])
        - sectionTable.contentOffset.y - sectionTable.adjustedContentInset.top : 0;
    __weak UITableView *weakSectionTable = sectionTable;
    void (^restoreSectionPosition)(void) = ^{
        UITableView *table = weakSectionTable;
        if (!anchor || !table.window || table.dragging || table.decelerating
            || anchor.section >= table.numberOfSections
            || anchor.row >= [table numberOfRowsInSection:anchor.section]) return;
        CGFloat y = CGRectGetMinY([table rectForRowAtIndexPath:anchor])
            - anchorOffset - table.adjustedContentInset.top;
        CGFloat minimum = -table.adjustedContentInset.top;
        CGFloat maximum = MAX(minimum, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
        [table setContentOffset:CGPointMake(table.contentOffset.x, MIN(maximum, MAX(minimum, y))) animated:NO];
    };
    // Install/remove column containers before UIKit forwards the new size to
    // children. Waiting for viewDidLayoutSubviews exposed one full-width frame
    // and the old transition guard then delayed splitting until animation end.
    sDuoSplitResizingTabs = self;
    sDuoSplitTargetSize = size;
    sDuoSplitSizeCoordinator = coordinator;
    ApolloLog(@"[DuoSplit] preparing all tabs for %.0fx%.0f", size.width, size.height);
    [UIView performWithoutAnimation:^{ ApolloDuoSplitUpdate(); }];
    %orig(size, coordinator);
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        ApolloDuoSplitUpdate();
        // Texture enqueues row-height updates when the table's width changes.
        // Commit that existing measurement during UIKit's size animation, so
        // the old wrapping does not remain until a second row animation runs.
        [self.view layoutIfNeeded];
        // The split can keep the previous orientation's rail insets through
        // this animation; correct them inside it so the navigation pill never
        // renders under the status region.
        ApolloDuoSplitRepairSafeAreas(self);
        ApolloDuoAccountRefreshPortraitGrid(self);
        UINavigationController *selected = (id)self.selectedViewController;
        if ([selected isKindOfClass:UINavigationController.class]) {
            UIViewController *page = ApolloDuoSplitDetailNavigation(selected).topViewController;
            UITableView *table = page.isViewLoaded ? ApolloDuoSplitFindTable(page.view) : nil;
            SEL commit = NSSelectorFromString(@"waitUntilAllUpdatesAreCommitted");
            if ([table respondsToSelector:commit]) {
                ((void (*)(id, SEL))objc_msgSend)(table, commit);
                [table layoutIfNeeded];
            }
        }
        restoreSectionPosition();
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (sDuoSplitSizeCoordinator != coordinator) return;
        restoreSectionPosition();
        sDuoSplitResizingTabs = nil;
        sDuoSplitSizeCoordinator = nil;
        ApolloDuoSplitRepairSafeAreas(self);
        ApolloDuoAccountRefreshPortraitGrid(self);
        ApolloDuoSplitScheduleUpdate();
    }];
}
- (void)viewDidLayoutSubviews {
    %orig;
    if (self == (id)ApolloMainTabBarController()) ApolloDuoSplitScheduleUpdate();
}
- (void)setSelectedViewController:(UIViewController *)controller {
    BOOL mainTabs = self == (id)ApolloMainTabBarController();
    if (mainTabs) ApolloDuoSplitUpdate();
    %orig(controller);
    if (mainTabs) ApolloDuoSplitScheduleUpdate();
}
- (void)setSelectedIndex:(NSUInteger)index {
    BOOL mainTabs = self == (id)ApolloMainTabBarController();
    if (mainTabs) ApolloDuoSplitUpdate();
    %orig(index);
    if (mainTabs) ApolloDuoSplitScheduleUpdate();
}
%end

%hook UIPanGestureRecognizer
- (CGPoint)locationInView:(UIView *)view {
    CGPoint point = %orig(view);
    if ((__bridge void *)self == sDuoSplitGesture && (__bridge void *)view == sDuoSplitGestureView) {
        point.x += sDuoSplitGestureOffset;
    }
    return point;
}
%end

// Apollo manually centers its EmptyStateLabel in ASTableView's full bounds.
// In a modern split those bounds extend behind the primary column. Adjust the
// native geometry at its setter, and on safe-area changes (including hinge-only
// changes with no window resize). Keep native vertical placement and sizing.
static char kDuoEmptyStateAdjusted;
static CGFloat ApolloDuoEmptyStateCenterX(UILabel *label, CGFloat nativeX) {
    UIView *parent = label.superview;
    if (!parent) return nativeX;
    UIViewController *owner = nil;
    for (UIResponder *responder = parent; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            owner = (id)responder;
            break;
        }
    }
    CGRect pane = ApolloDuoSplitContentFrame(owner, parent);
    if (!CGRectIsNull(pane) && CGRectGetWidth(pane) > 0.0) {
        objc_setAssociatedObject(label, &kDuoEmptyStateAdjusted, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return CGRectGetMidX(pane);
    }
    if ([objc_getAssociatedObject(label, &kDuoEmptyStateAdjusted) boolValue]) {
        objc_setAssociatedObject(label, &kDuoEmptyStateAdjusted, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return CGRectGetMidX(parent.bounds);
    }
    return nativeX;
}

@interface ApolloDuoEmptyStateLabel : UILabel @end
@interface ApolloDuoEmptyStateTable : UITableView @end
%group ApolloDuoEmptyStateHooks
%hook ApolloDuoEmptyStateLabel
- (void)setCenter:(CGPoint)center {
    center.x = ApolloDuoEmptyStateCenterX(self, center.x);
    %orig(center);
}
- (void)setFrame:(CGRect)frame {
    frame.origin.x = ApolloDuoEmptyStateCenterX(self, CGRectGetMidX(frame)) - frame.size.width / 2.0;
    %orig(frame);
}
- (void)safeAreaInsetsDidChange {
    %orig;
    CGPoint center = [(UILabel *)self center];
    CGFloat x = ApolloDuoEmptyStateCenterX(self, center.x);
    if (fabs(center.x - x) > 0.1) [(UILabel *)self setCenter:CGPointMake(x, center.y)];
}
- (void)didMoveToWindow {
    %orig;
    CGPoint center = [(UILabel *)self center];
    CGFloat x = ApolloDuoEmptyStateCenterX(self, center.x);
    if (fabs(center.x - x) > 0.1) [(UILabel *)self setCenter:CGPointMake(x, center.y)];
}
%end
%hook ApolloDuoEmptyStateTable
- (void)layoutSubviews {
    %orig;
    if (!ApolloDuoAccountIsOverviewTable((UITableView *)self)) return;
    for (UIResponder *responder = self; responder; responder = responder.nextResponder) {
        if (![responder isKindOfClass:UIViewController.class]) continue;
        ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(((UIViewController *)responder).navigationController, NO);
        if (!state.changing) [state.host scheduleOverviewAlignment];
        break;
    }
}
- (void)safeAreaInsetsDidChange {
    %orig;
    // A label already inside the old safe area does not necessarily receive
    // its own notification when only the sidebar width changes. The table
    // does; refresh the existing label without waiting for another selection.
    Class emptyLabel = NSClassFromString(@"Apollo.EmptyStateLabel");
    for (UIView *view in [(UITableView *)self subviews]) {
        if (![view isKindOfClass:emptyLabel]) continue;
        CGPoint center = view.center;
        CGFloat x = ApolloDuoEmptyStateCenterX((id)view, center.x);
        if (fabs(center.x - x) > 0.1) view.center = CGPointMake(x, center.y);
    }
}
%end
%end

@interface ApolloDuoTabSceneDelegate : NSObject @end
%group ApolloDuoTabSelectionHooks
%hook ApolloDuoTabSceneDelegate
- (BOOL)tabBarController:(UITabBarController *)tabs
 shouldSelectViewController:(UIViewController *)page {
    BOOL allowed = %orig(tabs, page);
    if (!allowed || tabs != (id)ApolloMainTabBarController()
        || ApolloDuoSplitIsUnfolded() || !ApolloDuoCoverChromeIsActive()
        || ![page isKindOfClass:UINavigationController.class]) return allowed;
    UINavigationController *nav = (id)page;
    NSString *kind = ApolloDuoSplitKind(nav.viewControllers.firstObject);
    if (([kind isEqualToString:@"account"] || [kind isEqualToString:@"settings"]
         || [kind isEqualToString:@"inbox"])
        && nav.viewControllers.count > 1 && !nav.transitionCoordinator
        && !tabs.presentedViewController && !nav.presentedViewController) {
        // Only a tab tap returns to the overview. Programmatic selection
        // (including deep links) keeps its requested destination.
        [nav popToRootViewControllerAnimated:NO];
    }
    return allowed;
}
%end
%end

// Friends uses manually positioned tables and a toolbar, rather than a native
// table-controller header. Its original layout assumes the whole window width.
%hook _TtC6Apollo21FriendsViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *controller = (id)self;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || controller.navigationController != state.secondary) return;
    UIView *view = controller.view;
    CGRect pane = UIEdgeInsetsInsetRect(view.bounds, view.safeAreaInsets);
    if (pane.size.width <= 0 || pane.size.height <= 44) return;
    Ivar toolbarIvar = class_getInstanceVariable([controller class], "segmentedControlToolbar");
    UIToolbar *toolbar = toolbarIvar ? object_getIvar(self, toolbarIvar) : nil;
    CGRect toolbarFrame = CGRectMake(pane.origin.x, pane.origin.y, pane.size.width, 44);
    if (toolbar && !CGRectEqualToRect(toolbar.frame, toolbarFrame)) toolbar.frame = toolbarFrame;
    Ivar segmentIvar = class_getInstanceVariable([controller class], "typeSegmentedControl");
    UISegmentedControl *segments = segmentIvar ? object_getIvar(self, segmentIvar) : nil;
    if (segments) {
        CGRect frame = segments.frame;
        frame.size.width = MAX(0, pane.size.width - 32);
        if (!CGRectEqualToRect(segments.frame, frame)) segments.frame = frame;
    }

}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    UIViewController *controller = (id)self;
    ApolloDuoSplitState *state = ApolloDuoSplitStateForNavigation(controller.navigationController, NO);
    if (!state.split || controller.navigationController != state.secondary) return;
    Ivar toolbarIvar = class_getInstanceVariable(controller.class, "segmentedControlToolbar");
    UIView *toolbar = toolbarIvar ? object_getIvar(self, toolbarIvar) : nil;
    CGFloat top = CGRectGetMaxY(toolbar.frame) + 8;
    for (UIView *child in controller.view.subviews) {
        if (![child isKindOfClass:UITableView.class]) continue;
        UITableView *table = (id)child;
        UIEdgeInsets inset = table.contentInset;
        inset.top = MAX(0, top - (table.adjustedContentInset.top - inset.top));
        if (UIEdgeInsetsEqualToEdgeInsets(inset, table.contentInset)) continue;
        // Returning from a friend's profile runs viewDidAppear again. Keep
        // the existing reading position rather than resetting the list on
        // every return; only translate it by an actual toolbar-inset change.
        CGPoint offset = table.contentOffset;
        CGFloat previousTop = table.adjustedContentInset.top;
        table.contentInset = inset;
        offset.y += previousTop - table.adjustedContentInset.top;
        [table setContentOffset:offset animated:NO];
    }
}

%end

@interface ApolloDuoCommentsPage : UIViewController @end
%group ApolloDuoCommentsLayoutHooks
%hook ApolloDuoCommentsPage
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloDuoCommentsUpdateLayoutControl((UIViewController *)self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoCommentsScheduleLayoutControl((UIViewController *)self);
}
- (void)viewWillDisappear:(BOOL)animated {
    if (objc_getAssociatedObject(self, &kApolloDuoCommentsLayoutKey)
        || ApolloDuoSplitStateForNavigation(((UIViewController *)self).navigationController, NO).feed)
        ApolloDuoPostsStopGeometry(((UIViewController *)self).viewIfLoaded);
    %orig(animated);
}
%end
%end

%ctor {
    Class comments = NSClassFromString(@"Apollo.CommentsViewController");
    if (comments) %init(ApolloDuoCommentsLayoutHooks, ApolloDuoCommentsPage = comments);
    [NSNotificationCenter.defaultCenter addObserverForName:@"ApolloDuoFeedLayoutDidChange"
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            ApolloDuoRefreshLayoutControls();
        }];
    Class subredditList = NSClassFromString(@"Apollo.RedditListViewController");
    if (subredditList) {
        %init(ApolloDuoSubredditListHooks, ApolloDuoSubredditList = subredditList);
        ApolloDuoInstallListReselectionGuard(subredditList);
    }
    Class sceneDelegate = NSClassFromString(@"Apollo.SceneDelegate");
    if (sceneDelegate) %init(ApolloDuoTabSelectionHooks, ApolloDuoTabSceneDelegate = sceneDelegate);
    Class navigation = NSClassFromString(@"Apollo.ApolloNavigationController");
    if (navigation) %init(ApolloDuoSplitNavigationHooks, ApolloDuoSplitNavigation = navigation);
    Class emptyLabel = NSClassFromString(@"Apollo.EmptyStateLabel");
    if (emptyLabel) %init(ApolloDuoEmptyStateHooks, ApolloDuoEmptyStateLabel = emptyLabel,
                         ApolloDuoEmptyStateTable = NSClassFromString(@"ASTableView"));
    %init;
}
