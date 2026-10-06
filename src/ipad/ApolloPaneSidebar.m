#import "ApolloPaneSidebar.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "ApolloPaneGeometryPolicy.h"
#import <objc/message.h>
#import "../ApolloCommon.h"
#import "../ApolloThemeRuntime.h"
#import <objc/runtime.h>
#import "../UserDefaultConstants.h"
#import "../ApolloFavoritesSorting.h"
#import "../ApolloSubredditInfoCache.h"
#import "../ApolloSubredditCustomIconCache.h"
#import "../ApolloUserProfileCache.h"

static char kNavigationPresentation;
static char kSidebarDestinations;
static char kPendingSceneLink;
static NSString *const kPaneLinkActivity = @"app.apolloreborn.pane.open-link";

// Keep native iPad tab placement: hiding the sidebar must not turn a regular
// iPad window into a compact window. UIKit places regular-width tabs at the
// top and adapts genuinely compact windows itself. Pane content can still
// collapse independently below its two-column minimum.
API_AVAILABLE(ios(18.0))
@interface ApolloPaneNavigationPresentation : NSObject <UITabBarControllerSidebarDelegate>
@property (nonatomic, weak) id<UITabBarControllerSidebarDelegate> originalDelegate;
@property (nonatomic) BOOL applying;
@property (nonatomic) BOOL scheduled;
@property (nonatomic) BOOL initialized;
@property (nonatomic) CGFloat width;
@property (nonatomic) UIUserInterfaceSizeClass windowSizeClass;
@end
@implementation ApolloPaneNavigationPresentation
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.originalDelegate respondsToSelector:selector] ? self.originalDelegate : [super forwardingTargetForSelector:selector];
}
- (void)tabBarController:(UITabBarController *)tabs sidebarVisibilityWillChange:(UITabBarControllerSidebar *)sidebar
               animator:(id<UITabBarControllerSidebarAnimating>)animator {
    if ([self.originalDelegate respondsToSelector:_cmd]) {
        [self.originalDelegate tabBarController:tabs sidebarVisibilityWillChange:sidebar animator:animator];
    }
    // The content guide changes when a sidebar overlays a portrait window,
    // even if the split's bounds/safe area stay identical. Refit the columns
    // after UIKit settles that guide; never change mode, traits or visibility.
    __weak UITabBarController *weakTabs = tabs;
    [animator addCompletion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UITabBarController *owner = weakTabs;
            for (UIViewController *child in ApolloPaneSidebarRootControllers(owner) ?: owner.viewControllers) {
                if ([child isKindOfClass:ApolloPaneSplitViewController.class]) {
                    [(ApolloPaneSplitViewController *)child apollo_resolvedDisplayStateMayHaveChanged];
                }
            }
        });
    }];
}
@end

static BOOL ApolloPaneOwnsTabs(UITabBarController *tabs) {
    if (!tabs || !ApolloPaneLayoutActive()) return NO;
    return [tabs.selectedViewController isKindOfClass:ApolloPaneSplitViewController.class];
}

void ApolloPaneUpdateNavigationPresentation(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        if (!ApolloPaneOwnsTabs(tabs) || !tabs.viewIfLoaded.window) return;
        ApolloPaneNavigationPresentation *state = objc_getAssociatedObject(tabs, &kNavigationPresentation);
        if (!state) {
            state = [ApolloPaneNavigationPresentation new];
            objc_setAssociatedObject(tabs, &kNavigationPresentation, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        state.scheduled = NO;
        if (state.applying) return;
        CGFloat width = tabs.view.bounds.size.width;
        if (!isfinite(width) || width <= 0) return;
        UIUserInterfaceSizeClass windowClass = tabs.view.window.traitCollection.horizontalSizeClass;
        if (state.initialized && fabs(state.width - width) < 0.5 && state.windowSizeClass == windowClass) return;
        BOOL initialSidebar = ApolloPaneHasRoomForSidebar(width) &&
            windowClass == UIUserInterfaceSizeClassRegular;
        state.applying = YES;
        @try {
            // Collapse pane content only when its columns cannot fit. The
            // tab container keeps UIKit's real window traits throughout.
            UIUserInterfaceSizeClass contentClass = ApolloPaneHasRoomForColumns(width)
                ? windowClass : UIUserInterfaceSizeClassCompact;
            for (UIViewController *child in ApolloPaneSidebarRootControllers(tabs) ?: tabs.viewControllers) {
                if ([child isKindOfClass:ApolloPaneSplitViewController.class] &&
                    (![child.traitOverrides containsTrait:UITraitHorizontalSizeClass.class] ||
                     child.traitOverrides.horizontalSizeClass != contentClass)) {
                    child.traitOverrides.horizontalSizeClass = contentClass;
                }
            }
            if (tabs.sidebar.delegate != state) {
                state.originalDelegate = tabs.sidebar.delegate;
                tabs.sidebar.delegate = state;
            }
            // Stay in native sidebar mode even when the sidebar is hidden.
            // Switching to TabBar after a collapse rebuilds UIKit's tab strip
            // and removes its built-in sidebar toggle. Visibility and adaptive
            // transitions belong to UIKit after this initial presentation.
            if (tabs.mode != UITabBarControllerModeTabSidebar) {
                tabs.mode = UITabBarControllerModeTabSidebar;
            }
            if (!state.initialized) tabs.sidebar.hidden = !initialSidebar;
            state.width = width;
            state.windowSizeClass = windowClass;
            state.initialized = YES;
            ApolloLog(@"[PaneNavigation] width=%.0f windowClass=%ld contentClass=%ld presentation=%@",
                      width, (long)windowClass, (long)contentClass, !tabs.sidebar.isHidden ? @"sidebar" : (windowClass == UIUserInterfaceSizeClassRegular ? @"top-tabs" : @"compact-tabs"));
        } @finally {
            state.applying = NO;
        }
    }
}

void ApolloPaneScheduleNavigationPresentation(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        if (!ApolloPaneOwnsTabs(tabs) || !tabs.viewIfLoaded.window) return;
        ApolloPaneNavigationPresentation *state = objc_getAssociatedObject(tabs, &kNavigationPresentation);
        if (state.applying || state.scheduled) return;
        // Layout callbacks only observe geometry and enqueue; no layout-driving
        // write occurs inside layout, and unchanged geometry enqueues nothing.
        if (state.initialized && fabs(state.width - tabs.view.bounds.size.width) < 0.5 &&
            state.windowSizeClass == tabs.view.window.traitCollection.horizontalSizeClass) return;
        if (!state) {
            state = [ApolloPaneNavigationPresentation new];
            objc_setAssociatedObject(tabs, &kNavigationPresentation, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        state.scheduled = YES;
        __weak UITabBarController *weakTabs = tabs;
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloPaneUpdateNavigationPresentation(weakTabs); });
    }
}

BOOL ApolloPaneCanShowNavigationSidebar(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        return ApolloPaneOwnsTabs(tabs) && ApolloPaneHasRoomForSidebar(tabs.view.bounds.size.width) &&
            tabs.view.window.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular &&
            (tabs.mode != UITabBarControllerModeTabSidebar || tabs.sidebar.isHidden);
    }
    return NO;
}

void ApolloPaneShowNavigationSidebar(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        if (!ApolloPaneCanShowNavigationSidebar(tabs)) return;
        tabs.sidebar.hidden = NO;
    }
}

BOOL ApolloPaneReceiveSceneActivity(UIWindowScene *scene, NSUserActivity *activity) {
    if (![activity.activityType isEqualToString:kPaneLinkActivity]) return NO;
    NSURL *url = ApolloURLByConvertingResolvedURLToApolloScheme(activity.webpageURL);
    if (scene && url) objc_setAssociatedObject(scene, &kPendingSceneLink, url, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return YES;
}
void ApolloPaneOpenPendingSceneLink(UIWindowScene *scene) {
    if (!scene || scene.activationState != UISceneActivationStateForegroundActive) return;
    NSURL *url = objc_getAssociatedObject(scene, &kPendingSceneLink);
    if (!url) return;
    // Claim once before entering native code. Scene activation can be reentrant;
    // a second activation must not duplicate the route or keep a stale link.
    objc_setAssociatedObject(scene, &kPendingSceneLink, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    BOOL routed = ApolloRouteURLThroughAppInScene(url, scene);
    ApolloLog(@"[PaneSidebar] receiving scene link routed=%d", routed);
}

static NSString *ApolloPaneCommunityName(NSString *input) {
    NSString *name = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([name hasPrefix:@"r/"]) name = [name substringFromIndex:2];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    if (name.length == 0 || name.length > 21 || [name rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return name;
}

// FavoriteSubreddits is Apollo's live projection, including the optional
// per-account favourites and sorting features. Preserve its order and spelling;
// never maintain a second list or write favourites from this sidebar.
static NSArray<NSString *> *ApolloPaneFavorites(void) {
    NSMutableArray<NSString *> *favorites = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id candidate in [NSUserDefaults.standardUserDefaults arrayForKey:UDKeyApolloFavoriteSubreddits]) {
        NSString *name = [candidate isKindOfClass:NSString.class] ? ApolloPaneCommunityName(candidate) : nil;
        if (!name || [seen containsObject:name.lowercaseString]) continue;
        [seen addObject:name.lowercaseString];
        [favorites addObject:name];
    }
    return favorites;
}

static NSURL *ApolloPaneCommunityURL(NSString *name) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.reddit.com/r/%@/", name]];
}

static ApolloPaneSplitViewController *ApolloPanePostsPane(UITabBarController *tabs) {
    UIViewController *first = (ApolloPaneSidebarRootControllers(tabs) ?: tabs.viewControllers).firstObject;
    return [first isKindOfClass:ApolloPaneSplitViewController.class] ? (id)first : nil;
}

static void ApolloPaneOpenCommunity(UITabBarController *tabs, NSString *name, BOOL newWindow) {
    UIWindowScene *scene = tabs.viewIfLoaded.window.windowScene;
    if (!scene) return;
    NSURL *url = ApolloPaneCommunityURL(name);
    if (newWindow) {
        NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:kPaneLinkActivity];
        activity.webpageURL = url;
        activity.title = [@"r/" stringByAppendingString:name];
        [UIApplication.sharedApplication requestSceneSessionActivation:nil userActivity:activity options:nil
            errorHandler:^(__unused NSError *error) {
                ApolloLog(@"[PaneSidebar] new-window activation unavailable");
            }];
    } else {
        // Community shortcuts always belong to Posts. Apollo otherwise opens
        // a URL in whichever tab is current (including Settings or Inbox).
        if (!ApolloPaneSidebarSelectIndex(tabs, 0)) tabs.selectedIndex = 0;
        ApolloRouteURLThroughAppInScene(ApolloURLByConvertingResolvedURLToApolloScheme(url),
                                       scene);
    }
}

@class ApolloPaneSidebarView;
API_AVAILABLE(ios(18.0))
@interface ApolloPaneSidebarConfiguration : NSObject <UIContentConfiguration>
@property (nonatomic, weak) UITabBarController *tabs;
@end

// The name and generation guard asynchronous icon loads against cell reuse,
// account changes and custom-icon changes while a request is in flight.
@interface ApolloPaneFavoriteCell : UITableViewCell
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic) NSUInteger iconGeneration;
@end
@implementation ApolloPaneFavoriteCell
- (void)prepareForReuse {
    [super prepareForReuse];
    self.subredditName = nil;
    self.iconGeneration++;
}
@end

API_AVAILABLE(ios(18.0))
@interface ApolloPaneSidebarView : UIView <UIContentView, UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate>
@property (nonatomic, copy) id<UIContentConfiguration> configuration;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSLayoutConstraint *tableHeight;
@property (nonatomic, copy) NSArray<NSString *> *favorites;
@property (nonatomic) BOOL refreshScheduled;
@end

@implementation ApolloPaneSidebarConfiguration
- (id)copyWithZone:(NSZone *)zone {
    ApolloPaneSidebarConfiguration *copy = [ApolloPaneSidebarConfiguration new];
    copy.tabs = self.tabs;
    return copy;
}
- (id<UIContentConfiguration>)updatedConfigurationForState:(id<UIConfigurationState>)state { return self; }
- (UIView<UIContentView> *)makeContentView {
    ApolloPaneSidebarView *view = [ApolloPaneSidebarView new];
    view.configuration = self;
    return view;
}
@end

@implementation ApolloPaneSidebarView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIStackView *stack = [UIStackView new];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12]
        ]];

        UILabel *heading = [UILabel new];
        heading.text = @"Favourites";
        heading.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        heading.adjustsFontForContentSizeCategory = YES;
        heading.textColor = UIColor.secondaryLabelColor;
        heading.accessibilityTraits |= UIAccessibilityTraitHeader;
        [stack addArrangedSubview:heading];

        _emptyLabel = [UILabel new];
        _emptyLabel.text = @"Star subreddits to add them here.";
        _emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _emptyLabel.adjustsFontForContentSizeCategory = YES;
        _emptyLabel.textColor = UIColor.secondaryLabelColor;
        _emptyLabel.numberOfLines = 0;
        [stack addArrangedSubview:_emptyLabel];

        _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _table.backgroundColor = UIColor.clearColor;
        _table.separatorStyle = UITableViewCellSeparatorStyleNone;
        _table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        _table.dataSource = self;
        _table.delegate = self;
        _table.dragDelegate = self;
        _table.dragInteractionEnabled = YES;
        _table.accessibilityLabel = @"Favourite subreddits";
        [_table registerClass:ApolloPaneFavoriteCell.class forCellReuseIdentifier:@"favorite"];
        [stack addArrangedSubview:_table];
        _tableHeight = [_table.heightAnchor constraintEqualToConstant:0];
        _tableHeight.active = YES;

        // Notifications may precede account projection/sorting completion. Read
        // the final live list on the next main-queue turn. Defaults observation
        // also catches native drag-reordering, which need not post a star event.
        for (NSString *name in @[ApolloFavoriteSubredditsUpdatedNotification,
                                  ApolloFavoritesSortingStateDidChangeNotification,
                                  NSUserDefaultsDidChangeNotification,
                                  ApolloSubredditCustomIconChangedNotification,
                                  UIContentSizeCategoryDidChangeNotification,
                                  @"com.christianselig.ApolloSpecificThemeChanged"]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleRefresh:)
                                                       name:name object:nil];
        }
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)setConfiguration:(id<UIContentConfiguration>)configuration {
    _configuration = [(id)configuration copy];
    [self refreshFavorites];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self refreshFavorites];
}
- (void)scheduleRefresh:(NSNotification *)notification {
    __weak ApolloPaneSidebarView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloPaneSidebarView *view = weakSelf;
        if (!view || !view.window || view.refreshScheduled) return;
        BOOL contentChanged = ![notification.name isEqualToString:NSUserDefaultsDidChangeNotification] ||
            ![view.favorites isEqualToArray:ApolloPaneFavorites()];
        if (!contentChanged) return;
        view.refreshScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloPaneSidebarView *strongView = weakSelf;
            strongView.refreshScheduled = NO;
            if (strongView.window) [strongView refreshFavorites];
        });
    });
}
- (void)refreshFavorites {
    self.favorites = ApolloPaneFavorites();
    self.emptyLabel.hidden = self.favorites.count != 0;
    self.table.hidden = self.favorites.count == 0;
    CGFloat rowHeight = MAX(44, [UIFont preferredFontForTextStyle:UIFontTextStyleBody].lineHeight + 20);
    self.table.rowHeight = rowHeight;
    // Keep navigation reachable even with hundreds of favourites. The native
    // footer has a bounded scrolling table, so only visible icons are requested.
    self.tableHeight.constant = MIN(self.favorites.count, (NSUInteger)5) * rowHeight;
    self.table.scrollEnabled = self.favorites.count > 5;
    [self.table reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.favorites.count;
}
- (void)applyImage:(UIImage *)image toCell:(ApolloPaneFavoriteCell *)cell {
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = cell.subredditName;
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    content.textProperties.color = ApolloThemeSubredditListTextColor() ?: UIColor.labelColor;
    content.image = image ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                          : [UIImage systemImageNamed:@"number.circle.fill"];
    content.imageProperties.maximumSize = CGSizeMake(28, 28);
    content.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
    content.imageProperties.cornerRadius = 14;
    content.imageProperties.tintColor = ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(8, 8, 8, 8);
    cell.contentConfiguration = content;
}
- (void)loadIconForCell:(ApolloPaneFavoriteCell *)cell {
    NSString *name = cell.subredditName;
    NSUInteger generation = ++cell.iconGeneration;
    UIImage *custom = [[ApolloSubredditCustomIconCache sharedCache] cachedIconForSubreddit:name];
    ApolloSubredditInfo *cached = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:name];
    UIImage *image = custom ?: (cached.iconURL ? [[ApolloUserProfileCache sharedCache] cachedImageForURL:cached.iconURL] : nil);
    [self applyImage:image toCell:cell];
    if (custom || image || !self.window) return;
    __weak ApolloPaneSidebarView *weakSelf = self;
    __weak ApolloPaneFavoriteCell *weakCell = cell;
    [[ApolloSubredditInfoCache sharedCache] requestInfoForSubreddit:name completion:^(ApolloSubredditInfo *info) {
        if (!info.iconURL) return;
        [[ApolloUserProfileCache sharedCache] requestImageForURL:info.iconURL completion:^(UIImage *loaded) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ApolloPaneFavoriteCell *strongCell = weakCell;
                if (!strongCell || strongCell.iconGeneration != generation ||
                    ![strongCell.subredditName isEqualToString:name]) return;
                UIImage *override = [[ApolloSubredditCustomIconCache sharedCache] cachedIconForSubreddit:name];
                [weakSelf applyImage:override ?: loaded toCell:strongCell];
            });
        }];
    }];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloPaneFavoriteCell *cell = [tableView dequeueReusableCellWithIdentifier:@"favorite" forIndexPath:indexPath];
    cell.subredditName = self.favorites[indexPath.row];
    cell.backgroundColor = UIColor.clearColor;
    cell.accessibilityLabel = [@"r/" stringByAppendingString:cell.subredditName];
    [self loadIconForCell:cell];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ApolloPaneOpenCommunity(((ApolloPaneSidebarConfiguration *)self.configuration).tabs,
                           self.favorites[indexPath.row], NO);
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSString *name = self.favorites[indexPath.row];
    __weak UITabBarController *weakTabs = ((ApolloPaneSidebarConfiguration *)self.configuration).tabs;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            UIAction *window = [UIAction actionWithTitle:@"Open in new window"
                image:[UIImage systemImageNamed:@"plus.rectangle.on.rectangle"] identifier:nil
                handler:^(__unused UIAction *action) { ApolloPaneOpenCommunity(weakTabs, name, YES); }];
            return [UIMenu menuWithTitle:@"" children:@[window]];
        }];
}
- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session
                       atIndexPath:(NSIndexPath *)indexPath {
    NSURL *url = ApolloPaneCommunityURL(self.favorites[indexPath.row]);
    return @[[[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:url]]];
}
@end

// A native inline tab group gives Posts and Subreddits real sidebar rows,
// backed by the same Posts pane. The five root controllers and their index
// space remain intact; UIKit owns row styling and selected destination state.
API_AVAILABLE(ios(18.0))
@interface ApolloPaneSidebarDestinations : NSObject <UITabBarControllerDelegate>
@property(nonatomic, weak) id<UITabBarControllerDelegate> originalDelegate;
@property(nonatomic, weak) UITabBarController *tabs;
@property(nonatomic, strong) UITabGroup *postsGroup;
@property(nonatomic, strong) ApolloPaneSplitViewController *postsPane;
@property(nonatomic, copy) NSArray<UIViewController *> *rootControllers;
@property(nonatomic, copy) NSArray<UITab *> *rootTabs;
@property(nonatomic, strong) UITab *posts;
@property(nonatomic, strong) UITab *subreddits;
@end
@implementation ApolloPaneSidebarDestinations
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.originalDelegate respondsToSelector:selector] ? self.originalDelegate : [super forwardingTargetForSelector:selector];
}
- (BOOL)tabBarController:(UITabBarController *)tabs shouldSelectTab:(UITab *)tab {
    ApolloLog(@"[PaneSidebar] selecting destination %@", tab.identifier);
    if (tab == self.subreddits) {
        [self.postsPane apollo_showSidebarSubreddits];
        return YES;
    }
    if (tab == self.postsGroup) self.postsGroup.selectedChild = self.posts;
    UIViewController *controller = (tab == self.posts || tab == self.postsGroup) ? self.postsPane : tab.viewController;
    if ([self.originalDelegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)]) {
        BOOL allowed = [self.originalDelegate tabBarController:tabs shouldSelectViewController:controller];
        ApolloLog(@"[PaneSidebar] destination %@ controller=%@ allowed=%d index=%lu children=%lu", tab.identifier, NSStringFromClass(controller.class), allowed, (unsigned long)tabs.selectedIndex, (unsigned long)tabs.viewControllers.count);
        return allowed;
    }
    return YES;
}
- (void)tabBarController:(UITabBarController *)tabs didSelectTab:(UITab *)tab previousTab:(UITab *)previousTab {
    UIViewController *controller = (tab == self.posts || tab == self.postsGroup) ? self.postsPane : tab.viewController;
    if ([self.originalDelegate respondsToSelector:@selector(tabBarController:didSelectViewController:)]) {
        [self.originalDelegate tabBarController:tabs didSelectViewController:controller];
    }
}
@end

// UITab-based controllers intentionally report nil for the legacy viewControllers
// property. Apollo and the pane router still use their original five-root index
// space. Keep that compatibility projection stable; Subreddits belongs to Posts.
NSArray<UIViewController *> *ApolloPaneSidebarRootControllers(UITabBarController *tabs) {
    ApolloPaneSidebarDestinations *state = objc_getAssociatedObject(tabs, &kSidebarDestinations);
    return state.rootControllers;
}
NSUInteger ApolloPaneSidebarSelectedIndex(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        ApolloPaneSidebarDestinations *state = objc_getAssociatedObject(tabs, &kSidebarDestinations);
        if (state) {
            UITab *root = tabs.selectedTab;
            while (root.parent) root = root.parent;
            return [state.rootTabs indexOfObjectIdenticalTo:root];
        }
    }
    return NSNotFound;
}
BOOL ApolloPaneSidebarSelectIndex(UITabBarController *tabs, NSUInteger index) {
    if (@available(iOS 18.0, *)) {
        ApolloPaneSidebarDestinations *state = objc_getAssociatedObject(tabs, &kSidebarDestinations);
        if (state && index < state.rootTabs.count) {
            UITab *target = index == 0 ? state.posts : state.rootTabs[index];
            if (tabs.selectedTab != target) tabs.selectedTab = target;
            return YES;
        }
    }
    return NO;
}

void ApolloPaneSidebarSelectPosts(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        ApolloPaneSidebarDestinations *state = objc_getAssociatedObject(tabs, &kSidebarDestinations);
        if (state && tabs.selectedViewController == state.postsGroup.viewController && tabs.selectedTab != state.posts) {
            tabs.selectedTab = state.posts;
        }
    }
}

static void ApolloPaneInstallSidebarDestinations(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        if (objc_getAssociatedObject(tabs, &kSidebarDestinations)) return;
        NSArray<UIViewController *> *controllers = [tabs.viewControllers copy];
        ApolloPaneSplitViewController *pane = ApolloPanePostsPane(tabs);
        if (!pane || controllers.count != 5) return;
        UIViewController *selected = tabs.selectedViewController;
        NSMutableArray<UITab *> *roots = [NSMutableArray array];
        for (NSUInteger i = 0; i < controllers.count; i++) {
            UIViewController *controller = controllers[i];
            UITabBarItem *item = controller.tabBarItem;
            UITab *tab = [[UITab alloc] initWithTitle:item.title ?: @"" image:item.image
                identifier:[NSString stringWithFormat:@"ApolloPane.root.%lu", (unsigned long)i]
                viewControllerProvider:^UIViewController *(UITab *sender) { return controller; }];
            tab.badgeValue = item.badgeValue;
            [roots addObject:tab];
        }
        ApolloPaneSidebarDestinations *state = [ApolloPaneSidebarDestinations new];
        state.tabs = tabs;
        state.postsPane = pane;
        state.originalDelegate = tabs.delegate;
        state.posts = [[UITab alloc] initWithTitle:@"Posts" image:pane.tabBarItem.image
            identifier:@"ApolloPane.posts" viewControllerProvider:nil];
        state.subreddits = [[UITab alloc] initWithTitle:@"Subreddits" image:[UIImage systemImageNamed:@"list.bullet"]
            identifier:@"ApolloPane.subreddits" viewControllerProvider:nil];
        state.subreddits.preferredPlacement = UITabPlacementSidebarOnly;
        state.postsGroup = [[UITabGroup alloc] initWithTitle:@"Posts" image:pane.tabBarItem.image
            identifier:@"ApolloPane.root.0" children:@[state.posts, state.subreddits]
            viewControllerProvider:^UIViewController *(UITab *sender) { return pane; }];
        state.postsGroup.sidebarAppearance = UITabGroupSidebarAppearanceInline;
        state.postsGroup.selectedChild = state.posts;
        roots[0] = state.postsGroup;
        state.rootControllers = controllers;
        state.rootTabs = roots;
        objc_setAssociatedObject(tabs, &kSidebarDestinations, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tabs.delegate = state;
        [tabs setTabs:roots animated:NO];
        NSUInteger selectedIndex = [controllers indexOfObjectIdenticalTo:selected];
        tabs.selectedTab = selectedIndex == 0 ? state.posts : roots[MIN(selectedIndex, roots.count - 1)];
        ApolloLog(@"[PaneSidebar] installed native Posts and Subreddits destinations");
    }
}

void ApolloPaneInstallSidebar(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        if (!tabs || !ApolloPaneLayoutActive()) return;
        ApolloPaneInstallSidebarDestinations(tabs);
        // Favourites occupy the footer; navigation destinations are native rows.
        id existing = tabs.sidebar.footerContentConfiguration;
        if (existing && ![existing isKindOfClass:ApolloPaneSidebarConfiguration.class]) return;
        ApolloPaneSidebarConfiguration *configuration = [ApolloPaneSidebarConfiguration new];
        configuration.tabs = tabs;
        tabs.sidebar.footerContentConfiguration = configuration;
    }
}

void ApolloPaneSidebarFirstAppearance(UITabBarController *tabs) {
    ApolloPaneUpdateNavigationPresentation(tabs);
}

// URL-only window workflows. Native controllers/models remain in their scene;
// the receiving scene enters through Apollo's existing universal-link adapter.
static NSURL *ApolloPanePostURL(UIViewController *controller) {
    Class comments = objc_getClass("_TtC6Apollo22CommentsViewController");
    if (!comments || ![controller isKindOfClass:comments]) return nil;
    Ivar linkIvar = class_getInstanceVariable(controller.class, "link");
    id link = linkIvar ? object_getIvar(controller, linkIvar) : nil;
    SEL selector = NSSelectorFromString(@"permalink");
    id value = [link respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(link, selector) : nil;
    NSString *path = [value isKindOfClass:NSString.class] ? value : ([value isKindOfClass:NSURL.class] ? [value path] : nil);
    if (![path hasPrefix:@"/"]) return nil;
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = @"www.reddit.com";
    components.path = path;
    return components.URL;
}
BOOL ApolloPaneCanOpenDetailInNewWindow(UISplitViewController *split) {
    ApolloPaneSplitViewController *pane = (id)split;
    return ApolloPanePostURL([pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary].topViewController) != nil;
}
void ApolloPaneOpenDetailInNewWindow(UISplitViewController *split) {
    ApolloPaneSplitViewController *pane = (id)split;
    NSURL *url = ApolloPanePostURL([pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary].topViewController);
    if (!url || !pane.viewIfLoaded.window) return;
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:kPaneLinkActivity];
    activity.webpageURL = url;
    [UIApplication.sharedApplication requestSceneSessionActivation:nil userActivity:activity options:nil errorHandler:^(NSError *error) {
        ApolloLog(@"[PaneSidebar] detail new-window activation unavailable");
    }];
}
@interface ApolloPaneLinkInteraction : NSObject <UIDropInteractionDelegate, UIDragInteractionDelegate>
@property (nonatomic, weak) ApolloPaneSplitViewController *pane;
@end
@implementation ApolloPaneLinkInteraction
- (BOOL)dropInteraction:(UIDropInteraction *)interaction canHandleSession:(id<UIDropSession>)session {
    return session.items.count == 1 && [session canLoadObjectsOfClass:NSURL.class];
}
- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction sessionDidUpdate:(id<UIDropSession>)session {
    return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}
- (void)dropInteraction:(UIDropInteraction *)interaction performDrop:(id<UIDropSession>)session {
    __weak UIWindowScene *weakScene = self.pane.viewIfLoaded.window.windowScene;
    [session loadObjectsOfClass:NSURL.class completion:^(NSArray<id<NSItemProviderReading>> *objects) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindowScene *scene = weakScene;
            if (!scene || scene.activationState != UISceneActivationStateForegroundActive || objects.count != 1) return;
            NSURL *url = ApolloURLByConvertingResolvedURLToApolloScheme((id)objects.firstObject);
            if (url) ApolloRouteURLThroughAppInScene(url, scene);
        });
    }];
}
- (NSArray<UIDragItem *> *)dragInteraction:(UIDragInteraction *)interaction itemsForBeginningSession:(id<UIDragSession>)session {
    UIView *bar = interaction.view;
    UIView *hit = [bar hitTest:[session locationInView:bar] withEvent:nil];
    // Title-region dragging must never steal a native action or text field.
    for (UIView *view = hit; view && view != bar; view = view.superview)
        if ([view isKindOfClass:UIControl.class]) return @[];
    NSURL *url = ApolloPanePostURL([self.pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary].topViewController);
    return url ? @[[[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:url]]] : @[];
}
@end
static char kLinkInteraction;
void ApolloPaneInstallLinkInteractions(UISplitViewController *split) {
    ApolloPaneSplitViewController *pane = (id)split;
    if (!pane.isViewLoaded || objc_getAssociatedObject(pane, &kLinkInteraction)) return;
    ApolloPaneLinkInteraction *owner = [ApolloPaneLinkInteraction new];
    owner.pane = pane;
    [pane.view addInteraction:[[UIDropInteraction alloc] initWithDelegate:owner]];
    UINavigationController *detail = [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
    // Installation occurs on the visible pane; never materialize hidden tabs.
    [detail.navigationBar addInteraction:[[UIDragInteraction alloc] initWithDelegate:owner]];
    objc_setAssociatedObject(pane, &kLinkInteraction, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
