#import "ApolloPaneSidebar.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import <objc/message.h>
#import "../ApolloCommon.h"
#import "../ApolloThemeRuntime.h"
#import <objc/runtime.h>

static NSString *const kPins = @"ApolloPanePinnedCommunities";
static char kFirstSidebarAppearance;
static char kPendingSceneLink;
static NSString *const kPaneLinkActivity = @"app.apolloreborn.pane.open-link";

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

static NSArray<NSString *> *ApolloPanePins(void) {
    NSMutableArray *pins = [NSMutableArray array];
    for (id candidate in [NSUserDefaults.standardUserDefaults arrayForKey:kPins]) {
        NSString *name = [candidate isKindOfClass:NSString.class] ? ApolloPaneCommunityName(candidate) : nil;
        if (name && ![pins containsObject:name.lowercaseString] && pins.count < 12) [pins addObject:name.lowercaseString];
    }
    return pins;
}

static NSURL *ApolloPaneCommunityURL(NSString *name) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.reddit.com/r/%@/", name]];
}

static void ApolloPaneChangePin(UITabBarController *tabs, NSString *name, BOOL remove) {
    if (!tabs) return;
    name = ApolloPaneCommunityName(name).lowercaseString;
    if (!name) return;
    NSMutableArray *pins = [ApolloPanePins() mutableCopy];
    [pins removeObject:name];
    if (!remove && pins.count < 12) [pins addObject:name];
    [NSUserDefaults.standardUserDefaults setObject:pins forKey:kPins];
    NSMutableSet *owners = [NSMutableSet setWithObject:tabs];
    for (UISplitViewController *pane in ApolloPaneRegisteredSplits()) if (pane.tabBarController) [owners addObject:pane.tabBarController];
    for (UITabBarController *owner in owners) ApolloPaneInstallSidebar(owner);
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
        ApolloRouteURLThroughAppInScene(ApolloURLByConvertingResolvedURLToApolloScheme(url),
                                       scene);
    }
}

@class ApolloPaneSidebarView;
API_AVAILABLE(ios(18.0))
@interface ApolloPaneSidebarConfiguration : NSObject <UIContentConfiguration>
@property (nonatomic, weak) UITabBarController *tabs;
@property (nonatomic, copy) NSArray<NSString *> *communities;
@end

API_AVAILABLE(ios(18.0))
@interface ApolloPaneSidebarView : UIView <UIContentView, UIDragInteractionDelegate, UIDropInteractionDelegate>
@property (nonatomic, copy) id<UIContentConfiguration> configuration;
@property (nonatomic, strong) UIStackView *stack;
@end

@implementation ApolloPaneSidebarConfiguration
- (id)copyWithZone:(NSZone *)zone {
    ApolloPaneSidebarConfiguration *copy = [ApolloPaneSidebarConfiguration new];
    copy.tabs = self.tabs;
    copy.communities = self.communities;
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
        _stack = [UIStackView new];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 4;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.leadingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor],
            [_stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
            [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12]
        ]];
        [self addInteraction:[[UIDropInteraction alloc] initWithDelegate:self]];
    }
    return self;
}
- (void)setConfiguration:(id<UIContentConfiguration>)configuration {
    _configuration = [(id)configuration copy];
    for (UIView *view in self.stack.arrangedSubviews) [view removeFromSuperview];
    ApolloPaneSidebarConfiguration *config = (id)_configuration;
    __weak UITabBarController *weakTabs = config.tabs;
    UILabel *heading = [UILabel new];
    heading.text = @"Communities";
    heading.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    heading.adjustsFontForContentSizeCategory = YES;
    heading.textColor = UIColor.secondaryLabelColor;
    [self.stack addArrangedSubview:heading];
    [config.communities enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
        UIAction *open = [UIAction actionWithTitle:[@"r/" stringByAppendingString:name]
            image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(__unused UIAction *action) {
                ApolloPaneOpenCommunity(weakTabs, name, NO);
            }];
        UIButton *button = [UIButton buttonWithConfiguration:UIButtonConfiguration.plainButtonConfiguration primaryAction:open];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        button.tintColor = ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
        button.tag = (NSInteger)index;
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        UIAction *window = [UIAction actionWithTitle:@"Open in new window" image:[UIImage systemImageNamed:@"plus.rectangle.on.rectangle"]
            identifier:nil handler:^(__unused UIAction *action) { ApolloPaneOpenCommunity(weakTabs, name, YES); }];
        UIAction *remove = [UIAction actionWithTitle:@"Unpin community" image:[UIImage systemImageNamed:@"pin.slash"]
            identifier:nil handler:^(__unused UIAction *action) { ApolloPaneChangePin(weakTabs, name, YES); }];
        button.menu = [UIMenu menuWithTitle:@"" children:UIApplication.sharedApplication.supportsMultipleScenes
            ? @[window, remove] : @[remove]];
        [button addInteraction:[[UIDragInteraction alloc] initWithDelegate:self]];
        [self.stack addArrangedSubview:button];
    }];
    UIAction *add = [UIAction actionWithTitle:@"Pin community" image:[UIImage systemImageNamed:@"plus"]
        identifier:nil handler:^(__unused UIAction *action) {
            UITabBarController *tabs = weakTabs;
            if (!tabs.view.window) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Pin community" message:@"Enter a subreddit name."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
                field.placeholder = @"subreddit";
                field.autocapitalizationType = UITextAutocapitalizationTypeNone;
                field.autocorrectionType = UITextAutocorrectionTypeNo;
            }];
            __weak UIAlertController *weakAlert = alert;
            UIAlertAction *pin = [UIAlertAction actionWithTitle:@"Pin" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                ApolloPaneChangePin(weakTabs, weakAlert.textFields.firstObject.text, NO);
            }];
            pin.enabled = NO;
            __weak UIAlertAction *weakPin = pin;
            [alert.textFields.firstObject addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
                weakPin.enabled = ApolloPaneCommunityName(weakAlert.textFields.firstObject.text) != nil;
            }] forControlEvents:UIControlEventEditingChanged];
            [alert addAction:pin];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            UIViewController *presenter = tabs;
            while (presenter.presentedViewController) presenter = presenter.presentedViewController;
            [presenter presentViewController:alert animated:YES completion:nil];
        }];
    UIButton *addButton = [UIButton buttonWithConfiguration:UIButtonConfiguration.plainButtonConfiguration primaryAction:add];
    addButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    addButton.enabled = config.communities.count < 12;
    [addButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.stack addArrangedSubview:addButton];
}
- (NSArray<UIDragItem *> *)dragInteraction:(UIDragInteraction *)interaction itemsForBeginningSession:(id<UIDragSession>)session {
    ApolloPaneSidebarConfiguration *config = (id)self.configuration;
    NSInteger index = interaction.view.tag;
    if (index < 0 || index >= (NSInteger)config.communities.count) return @[];
    NSURL *url = ApolloPaneCommunityURL(config.communities[index]);
    return @[[[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:url]]];
}
- (BOOL)dropInteraction:(UIDropInteraction *)interaction canHandleSession:(id<UIDropSession>)session {
    return [session canLoadObjectsOfClass:NSURL.class];
}
- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction sessionDidUpdate:(id<UIDropSession>)session {
    return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}
- (void)dropInteraction:(UIDropInteraction *)interaction performDrop:(id<UIDropSession>)session {
    __weak UITabBarController *weakTabs = ((ApolloPaneSidebarConfiguration *)self.configuration).tabs;
    [session loadObjectsOfClass:NSURL.class completion:^(NSArray<id<NSItemProviderReading>> *objects) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSURL *url in objects) {
                NSString *host = url.host.lowercaseString;
                NSArray *parts = url.pathComponents;
                if (([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) &&
                    parts.count >= 3 && [parts[1] isEqualToString:@"r"]) {
                    ApolloPaneChangePin(weakTabs, parts[2], NO);
                }
            }
        });
    }];
}
@end

void ApolloPaneInstallSidebar(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        if (!tabs || !ApolloPaneLayoutActive()) return;
        // Use the public footer slot: native tab identities and indices stay
        // intact, and Apollo's existing sidebar delegate remains installed.
        id existing = tabs.sidebar.footerContentConfiguration;
        if (existing && ![existing isKindOfClass:ApolloPaneSidebarConfiguration.class]) return;
        ApolloPaneSidebarConfiguration *configuration = [ApolloPaneSidebarConfiguration new];
        configuration.tabs = tabs;
        configuration.communities = ApolloPanePins();
        tabs.sidebar.footerContentConfiguration = configuration;
    }
}

void ApolloPaneSidebarFirstAppearance(UITabBarController *tabs) {
    if (@available(iOS 18.0, *)) {
        UIWindowScene *scene = tabs.viewIfLoaded.window.windowScene;
        if (!scene || objc_getAssociatedObject(scene, &kFirstSidebarAppearance)) return;
        objc_setAssociatedObject(scene, &kFirstSidebarAppearance, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // A single initial preference, never a resize/selection enforcement.
        // UIKit owns subsequent visibility and the user's collapse choice.
        if (CGRectGetWidth(tabs.view.bounds) >= 1100.0 &&
            tabs.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) tabs.sidebar.hidden = NO;
    }
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
    return UIApplication.sharedApplication.supportsMultipleScenes &&
        ApolloPanePostURL([pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary].topViewController) != nil;
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
