#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
static char kActionsDuoOverflowHiddenKey, kActionsDuoOverflowItemsKey;
static char kActionsDuoOverflowElementKey, kActionsDuoOverflowMenuKey;
static NSUInteger sActionsModelWriteDepth;
static char kActionsDuoSourceButtonKey, kActionsStandardItemKey;
static const NSUInteger UIMenuOptionsDisplayInline = 1;
static const NSUInteger UIControlEventTouchUpInside = 1;

@interface UIView : NSObject
@property (nonatomic, strong) id window;
@end
@implementation UIView
@end
@interface UIMenuElement : NSObject
@end
@implementation UIMenuElement
@end
@interface UIMenu : UIMenuElement
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) id image;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) NSUInteger options;
@property (nonatomic, copy) NSArray *children;
+ (instancetype)menuWithTitle:(NSString *)title image:(id)image identifier:(NSString *)identifier options:(NSUInteger)options children:(NSArray *)children;
@end
@implementation UIMenu
+ (instancetype)menuWithTitle:(NSString *)title image:(id)image identifier:(NSString *)identifier options:(NSUInteger)options children:(NSArray *)children {
    UIMenu *menu = [self new]; menu.title = title; menu.image = image; menu.identifier = identifier;
    menu.options = options; menu.children = children; return menu;
}
@end
@interface UIAction : UIMenuElement
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) void (^handler)(UIAction *);
+ (instancetype)actionWithTitle:(NSString *)title image:(id)image identifier:(NSString *)identifier handler:(void (^)(UIAction *))handler;
@property (nonatomic) NSUInteger performed;
@property (nonatomic, weak) id sender;
- (void)performWithSender:(id)sender target:(id)target;
@end
@implementation UIAction
+ (instancetype)actionWithTitle:(NSString *)title image:(__unused id)image identifier:(__unused NSString *)identifier handler:(void (^)(UIAction *))handler {
    UIAction *action = [self new]; action.title = title; action.handler = handler; return action;
}
- (void)performWithSender:(id)sender target:(__unused id)target { self.sender = sender; self.performed++; if (self.handler) self.handler(self); }
@end
@interface UIButton : UIView
@property (nonatomic, copy) NSString *accessibilityLabel;
@property (nonatomic, strong) UIMenu *menu;
@property (nonatomic) BOOL showsMenuAsPrimaryAction;
@property (nonatomic) NSUInteger taps;
- (void)sendActionsForControlEvents:(NSUInteger)events;
@end
@implementation UIButton
- (void)sendActionsForControlEvents:(__unused NSUInteger)events { self.taps++; }
@end
@interface UIBarButtonItem : NSObject { BOOL _hidden; }
@property (nonatomic) BOOL enabled;
@property (nonatomic, strong) id image;
@property (nonatomic, strong) UIView *view;
@property (nonatomic) BOOL hidden;
@property (nonatomic, copy) NSString *accessibilityLabel;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) UIMenu *menu;
@property (nonatomic, strong) UIAction *primaryAction;
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@end
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(id)event;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if (!app) app = [self new]; return app; }
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(__unused id)event {
    ((void (*)(id, SEL, id))objc_msgSend)(target, action, sender); return YES;
}
@end
@interface UINavigationItem : NSObject
@property (nonatomic, strong) id overflowPresentationSource;
@property (nonatomic, strong) id additionalOverflowItems;
@property (nonatomic, copy) NSArray<UIBarButtonItem *> *rightBarButtonItems;
@end
@implementation UINavigationItem
@end
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UINavigationItem *navigationItem;
@property (nonatomic, strong) UIViewController *presentedViewController;
@property (nonatomic, weak) UIViewController *presentingViewController;
@end
@implementation UIViewController
@end
@interface PostsViewController : UIViewController
@end
@implementation PostsViewController
@end
@interface UITabBarController : UIViewController
@end
@implementation UITabBarController
@end
static UITabBarController *tabs;
static BOOL rail, portrait, sidebar;
static BOOL ApolloActionsHasTrailingTabRail(void) { return rail; }
static BOOL ApolloDuoSplitIsUnfoldedPortrait(void) { return portrait; }
static BOOL ApolloDuoSplitIsSidebarController(__unused UIViewController *controller) { return sidebar; }
static BOOL sCollapseNavigationActions, duo;
static Class ApolloClassPostsViewController;
static BOOL ApolloDeviceIsDuo(void) { return duo; }
@interface ApolloNavigationActionsOwner : NSObject
@property (nonatomic, strong) UIViewController *controller;
@property (nonatomic, strong) UIBarButtonItem *inboxDisclosure;
@property (nonatomic) NSUInteger actions;
@property (nonatomic) BOOL expanded;
@property (nonatomic, weak) id sender;
- (BOOL)collapseEnabled;
- (void)fixtureMenuAction:(id)sender;
@end
@implementation ApolloNavigationActionsOwner
// INCLUDE_PRODUCTION_COLLAPSE_POLICY
- (void)fixtureMenuAction:(id)sender { self.sender = sender; self.actions++; }
@end
@interface ApolloNavigationActionsStandardItem : NSObject
@property (nonatomic) BOOL hidden;
@property (nonatomic, weak) ApolloNavigationActionsOwner *owner;
@end
@implementation ApolloNavigationActionsStandardItem
@end
@implementation UIBarButtonItem
- (instancetype)init { if ((self = [super init])) _enabled = YES; return self; }
- (BOOL)hidden { return _hidden; }
// INCLUDE_PRODUCTION_HIDDEN_SETTER
@end
// INCLUDE_PRODUCTION_OVERFLOW_VISIBILITY

static UIView *sApolloNativeActionMenuSourceView;
static UIView *ApolloNativeActionMenuViewForObject(id object) {
    if ([object isKindOfClass:UIView.class]) return object;
    return [object respondsToSelector:@selector(view)] ? [object view] : nil;
}
// INCLUDE_PRODUCTION_SOURCE_RESOLVER
static UIButton *ApolloActionsFindMore(UIView *root) { return [root isKindOfClass:UIButton.class] ? (UIButton *)root : nil; }
static UIView *ApolloNavigationActionsContentView(UIBarButtonItem *item) { return item.view; }
static id capturedController;
static UIMenu *capturedMenu;
static id ApolloNativeActionMenuCaptureController(UIView *source, dispatch_block_t build) {
    if (!source.window) return nil;
    build(); return capturedController;
}
static UIMenu *ApolloNativeActionMenuBuildCaptured(__unused id controller) { return capturedMenu; }
// INCLUDE_PRODUCTION_ITEM_DISPATCH
static NSArray *ApolloActionsWithoutDuoFeedControls(__unused UINavigationItem *item, NSArray *items) { return items; }
// INCLUDE_PRODUCTION_OVERFLOW_ELEMENTS
// INCLUDE_PRODUCTION_RAIL_POLICY

static unsigned checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}
int main(void) {
    @autoreleasepool {
        UIView *detached = [UIView new], *overflow = [UIView new], *page = [UIView new];
        overflow.window = [NSObject new]; page.window = overflow.window;
        UIBarButtonItem *item = [UIBarButtonItem new]; item.view = detached;
        UIViewController *owner = [UIViewController new]; owner.view = page;
        owner.navigationItem = [UINavigationItem new];
        owner.navigationItem.overflowPresentationSource = overflow;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == overflow,
              @"a displaced rail item anchors its menu to the live overflow control");
        item.view = overflow;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == overflow,
              @"an attached sender remains the preferred anchor");
        item.view = detached;
        owner.navigationItem.overflowPresentationSource = nil;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == page,
              @"a detached item without overflow uses its visible owning page");
        Check(ApolloNativeActionMenuResolveSourceView(detached, owner) == page,
              @"a detached UIView sender does not hide a valid owner anchor");
        Check(ApolloNativeActionMenuResolveSourceView(overflow, nil) == overflow,
              @"view-backed media and ordinary phone controls keep their anchor");
        owner.view = detached; sApolloNativeActionMenuSourceView = overflow;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == overflow,
              @"nested capture retains a window-backed primed source");
        sApolloNativeActionMenuSourceView = detached;
        Check(ApolloNativeActionMenuResolveSourceView(item, owner) == nil,
              @"an entirely detached capture cannot claim an anchor");
        Check(ApolloNativeActionMenuResolveSourceView(nil, nil) == nil,
              @"absent inputs are safe");
        ApolloClassPostsViewController = PostsViewController.class;
        ApolloNavigationActionsOwner *actions = [ApolloNavigationActionsOwner new];
        actions.controller = [PostsViewController new];
        duo = YES; sCollapseNavigationActions = YES;
        Check(!actions.collapseEnabled, @"Duo feed More must not require an expansion tap");
        duo = NO;
        Check(actions.collapseEnabled, @"ordinary phones retain the collapse preference");
        sCollapseNavigationActions = NO;
        Check(!actions.collapseEnabled, @"ordinary phones can still keep actions expanded");
        duo = YES; actions.controller = owner;
        Check(!actions.collapseEnabled, @"Duo pages stay expanded when the collapse preference is off");
        sCollapseNavigationActions = YES;
        Check(!actions.collapseEnabled, @"non-feed Duo More menus must also open on the first tap");
        UIBarButtonItem *more = [UIBarButtonItem new], *hiddenAction = [UIBarButtonItem new];
        hiddenAction.hidden = YES;
        NSArray *controls = @[more, hiddenAction];
        owner.navigationItem.rightBarButtonItems = controls;
        ApolloTestHideOverflowControls(controls);
        Check(more.hidden && hiddenAction.hidden, @"rendered originals are removed from UIKit's icon picker");
        Check(!ApolloActionsBarItemHidden(more) && ApolloActionsBarItemHidden(hiddenAction),
              @"logical availability remains separate from overflow-only rendering");
        ApolloTestHideOverflowControls(controls);
        Check(!ApolloActionsBarItemHidden(more) && sActionsModelWriteDepth == 0,
              @"repeated preparation preserves the original visibility and balanced model guard");
        Check(owner.navigationItem.rightBarButtonItems == controls,
              @"direct overflow does not replace Apollo's legacy item model");
        id deferred = [NSObject new]; owner.navigationItem.additionalOverflowItems = deferred;
        objc_setAssociatedObject(owner.navigationItem, &kActionsDuoOverflowItemsKey, controls, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(owner.navigationItem, &kActionsDuoOverflowElementKey, deferred, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloActionsRestoreDuoOverflow(owner.navigationItem);
        Check(!more.hidden && hiddenAction.hidden, @"leaving the rail restores each original visibility");
        Check(!owner.navigationItem.additionalOverflowItems, @"leaving the rail removes the owned overflow provider");
        Check(!objc_getAssociatedObject(more, &kActionsDuoOverflowHiddenKey) && sActionsModelWriteDepth == 0,
              @"restoration releases rendering overrides and balances the model guard");
        owner.navigationItem.additionalOverflowItems = [NSObject new];
        ApolloActionsRestoreDuoOverflow(owner.navigationItem);
        Check(owner.navigationItem.additionalOverflowItems != nil, @"cleanup preserves another owner's overflow provider");
        UIBarButtonItem *command = [UIBarButtonItem new];
        command.target = actions; command.action = @selector(fixtureMenuAction:);
        ApolloActionsInvokeItem(command);
        Check(actions.actions == 1 && actions.sender == command,
              @"native targets and arbitrary selectors receive their own item as sender");
        command.primaryAction = [UIAction new];
        ApolloActionsInvokeItem(command);
        Check(command.primaryAction.performed == 1 && command.primaryAction.sender == command && actions.actions == 1,
              @"primary actions use UIKit dispatch rather than a feed callback");
        UIButton *sourceButton = [UIButton new];
        objc_setAssociatedObject(command, &kActionsDuoSourceButtonKey, sourceButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloActionsInvokeItem(command);
        Check(sourceButton.taps == 1 && command.primaryAction.performed == 1,
              @"mirrored controls forward through the original button");
        capturedController = [NSObject new]; capturedMenu = [UIMenu new];
        Check(ApolloActionsMenuForItem(command, page) == capturedMenu && sourceButton.taps == 2,
              @"captured menus use the same generic item dispatcher");
        command.menu = [UIMenu new];
        Check(ApolloActionsMenuForItem(command, page) == command.menu && sourceButton.taps == 2,
              @"existing UIMenu-backed controls are reused without invoking their callback");
        command.menu = nil; sourceButton.menu = [UIMenu new]; sourceButton.showsMenuAsPrimaryAction = YES;
        Check(ApolloActionsMenuForItem(command, page) == sourceButton.menu && sourceButton.taps == 2,
              @"button-owned primary menus retain their original content");
        UIBarButtonItem *custom = [UIBarButtonItem new]; custom.view = [UIButton new];
        ApolloActionsInvokeItem(custom);
        Check(((UIButton *)custom.view).taps == 1, @"standalone custom More controls use the same dispatch path");
        capturedController = nil; sourceButton.menu = nil;
        Check(ApolloActionsMenuForItem(command, page) == nil, @"unavailable capture does not invent a menu");
        UIBarButtonItem *filterMenu = [UIBarButtonItem new]; filterMenu.menu = [UIMenu new];
        filterMenu.accessibilityLabel = @"Sort";
        UIBarButtonItem *namedMore = [UIBarButtonItem new]; namedMore.accessibilityLabel = @"More actions";
        Check(ApolloActionsFindMoreItem(@[filterMenu, namedMore]) == namedMore,
              @"a sibling Sort menu cannot displace the actual More item");
        Check(ApolloActionsFindMoreItem(@[filterMenu]) == filterMenu,
              @"standalone native menu controls are supported without a controller-class list");
        Check(ApolloActionsFindMoreItem(@[]) == nil, @"pages without menu controls remain unchanged");
        actions.inboxDisclosure = command;
        owner.navigationItem.rightBarButtonItems = @[command];
        NSUInteger previousTaps = sourceButton.taps;
        Check(ApolloActionsOverflowElements(owner.navigationItem, command, page, actions).count == 0 && sourceButton.taps == previousTaps,
              @"synthetic disclosures expose sibling commands without invoking their old expansion action");
        actions.inboxDisclosure = nil; capturedController = [NSObject new];
        capturedMenu.children = @[[UIAction new]];
        Check(ApolloActionsOverflowElements(owner.navigationItem, command, page, actions).firstObject == capturedMenu.children.firstObject,
              @"real More controls still use their native menu factory");

        UIBarButtonItem *mark = [UIBarButtonItem new], *compose = [UIBarButtonItem new];
        mark.action = @selector(markAllReadBarButtonItemTappedWithSender:);
        compose.action = @selector(newMessageBarButtonItemTappedWithSender:);
        Check([ApolloActionsItemTitle(mark) isEqual:@"Mark All Read"] && [ApolloActionsItemTitle(compose) isEqual:@"New Message"],
              @"native Inbox selectors supply accessible row titles");
        mark.accessibilityLabel = @""; mark.title = @"Localized title";
        Check([ApolloActionsItemTitle(mark) isEqual:@"Localized title"], @"empty accessibility labels do not hide existing titles");
        mark.accessibilityLabel = @"Localized label";
        Check([ApolloActionsItemTitle(mark) isEqual:@"Localized label"], @"existing accessible names take priority");
        mark.accessibilityLabel = nil; mark.title = nil;
        actions.inboxDisclosure = command;
        UIBarButtonItem *disabled = [UIBarButtonItem new]; disabled.enabled = NO;
        UIBarButtonItem *hidden = [UIBarButtonItem new]; hidden.hidden = YES;
        owner.navigationItem.rightBarButtonItems = @[command, mark, compose, disabled, hidden];
        NSArray *rows = ((UIMenu *)ApolloActionsOverflowElements(owner.navigationItem, command, page, actions).firstObject).children;
        Check(rows.count == 2 && [[rows[0] title] isEqual:@"Mark All Read"] && [[rows[1] title] isEqual:@"New Message"],
              @"provider builds named Inbox rows and filters disabled and logically hidden commands");
        mark.menu = [UIMenu menuWithTitle:@"" image:nil identifier:@"mark" options:0 children:@[[UIAction new]]];
        rows = ((UIMenu *)ApolloActionsOverflowElements(owner.navigationItem, command, page, actions).firstObject).children;
        UIMenu *wrapped = rows.firstObject;
        Check([wrapped.title isEqual:@"Mark All Read"] && wrapped.children == mark.menu.children && [wrapped.identifier isEqual:@"mark"],
              @"untitled submenu keeps its contents and identity under the command's accessible title");
        mark.menu.options = UIMenuOptionsDisplayInline;
        rows = ((UIMenu *)ApolloActionsOverflowElements(owner.navigationItem, command, page, actions).firstObject).children;
        Check(rows.firstObject == mark.menu, @"inline menus retain their existing grouping");

        duo = YES; rail = YES; tabs = [UITabBarController new];
        Check(ApolloActionsUsesDuoOverflow(owner), @"Duo detail rail uses direct overflow");
        portrait = YES;
        Check(!ApolloActionsUsesDuoOverflow(owner), @"target portrait pose wins over stale live rail geometry");
        portrait = NO; sidebar = YES;
        Check(!ApolloActionsUsesDuoOverflow(owner), @"sidebar navigation retains its own actions");
        sidebar = NO; tabs.presentedViewController = [UIViewController new];
        Check(ApolloActionsUsesDuoOverflow(owner), @"presenting a sheet preserves the underlying page's overflow");
        UIViewController *presenter = [UIViewController new]; owner.presentingViewController = presenter;
        Check(!ApolloActionsUsesDuoOverflow(owner), @"a presented controller does not inherit the underlying rail");
        owner.presentingViewController = nil; tabs.presentedViewController = nil;
        Check(ApolloActionsUsesDuoOverflow(owner), @"sheet dismissal leaves the presenter's overflow policy unchanged");
        rail = NO;
        Check(!ApolloActionsUsesDuoOverflow(owner), @"Duo without a rail needs no synthetic collapse disclosure");
        rail = YES; duo = NO;
        Check(!ApolloActionsUsesDuoOverflow(owner), @"ordinary phones never use the Duo overflow adapter");

        NSArray *retained = @[more];
        ApolloTestHideOverflowControls(retained);
        more.hidden = YES;
        Check(more.hidden && ApolloActionsBarItemHidden(more), @"native hide writes update the logical model while rendering remains hidden");
        more.hidden = NO;
        Check(more.hidden && !ApolloActionsBarItemHidden(more), @"native show writes keep the render override and update logical visibility");
        ApolloNavigationActionsStandardItem *state = [ApolloNavigationActionsStandardItem new];
        state.owner = actions; actions.expanded = YES;
        objc_setAssociatedObject(more, &kActionsStandardItemKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        more.hidden = YES;
        Check(state.hidden && ApolloActionsBarItemHidden(more), @"standard item state follows native writes under overflow");
        more.hidden = NO;
        Check(!state.hidden && more.hidden && !ApolloActionsBarItemHidden(more), @"standard state and overflow rendering remain independent");
        objc_setAssociatedObject(owner.navigationItem, &kActionsDuoOverflowItemsKey, retained, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloActionsRestoreDuoOverflow(owner.navigationItem);
        Check(!more.hidden && !state.hidden && sActionsModelWriteDepth == 0, @"restoration applies the latest native visibility through the real setter");
        namedMore.hidden = YES;
        Check(ApolloActionsFindMoreItem(@[namedMore]) == nil, @"hidden More actions cannot be exposed by the adapter");
        namedMore.hidden = NO; namedMore.enabled = NO;
        Check(ApolloActionsFindMoreItem(@[namedMore]) == nil, @"disabled More actions cannot be invoked by the adapter");
        printf("PASS: %u native menu source checks\n", checks);
    }
}
