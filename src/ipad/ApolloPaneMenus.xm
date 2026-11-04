// Main menus contain responder-chain commands, never blocks bound to a global
// selected tab. Each window therefore acts on its own focused column. The
// native composers and action handlers keep authentication, lock and draft rules.
#import "ApolloPaneMenus.h"
#import "ApolloPaneSplitViewController.h"
#import "ApolloPaneFocus.h"
#import "ApolloPaneSidebar.h"
#import "ApolloPaneChrome.h"
#import "ApolloPaneGallery.h"
#import "../ApolloCommon.h"
#import "../ApolloNativeActionMenus.h"
#import "../ApolloSwiftRuntime.h"
#import <objc/message.h>

extern NSString *ApolloSubredditNameFromViewController(UIViewController *controller);

typedef NS_ENUM(NSInteger, ApolloPaneMenuAction) {
    PanePosts, PaneInbox, PaneProfile, PaneSearch, PaneSettings, PaneSubreddits,
    PaneJump, PaneNewPost, PaneReply, PaneRefresh, PaneSidebar, PaneList, PaneDetail,
    PaneNarrow, PaneWiden, PaneFind, PanePrevious, PaneNext, PaneOpen, PaneBack,
    PaneForward, PaneDeselect, PaneMedia, PanePageUp, PanePageDown, PaneTop, PaneBottom,
    PaneNewWindow,
};

// One catalogue feeds both the menu bar and the pre-iPadOS-26 command HUD.
// Apollo's table selection uses its own navigation handlers. Browsing keys
// retain that priority, but validation removes them while editing or in sheets.
#define PANE_COMMANDS(X) \
    X(Posts, "Posts", @"1", UIKeyModifierCommand, PanePosts) \
    X(Inbox, "Inbox", @"2", UIKeyModifierCommand, PaneInbox) \
    X(Profile, "Profile", @"3", UIKeyModifierCommand, PaneProfile) \
    X(Search, "Search", @"4", UIKeyModifierCommand, PaneSearch) \
    X(Settings, "Settings", @"5", UIKeyModifierCommand, PaneSettings) \
    X(Subreddits, "Subreddits", @"l", UIKeyModifierCommand | UIKeyModifierShift, PaneSubreddits) \
    X(Jump, "Jump to Subreddit…", @"l", UIKeyModifierCommand, PaneJump) \
    X(NewPost, "New Post…", @"n", UIKeyModifierCommand, PaneNewPost) \
    X(Reply, "Reply to Selected Comment…", @"r", UIKeyModifierCommand, PaneReply) \
    X(Refresh, "Refresh", @"r", UIKeyModifierCommand | UIKeyModifierShift, PaneRefresh) \
    X(Sidebar, "Show Sidebar", @"s", UIKeyModifierCommand | UIKeyModifierControl, PaneSidebar) \
    X(List, "Focus List Column", @"1", UIKeyModifierCommand | UIKeyModifierAlternate, PaneList) \
    X(Detail, "Focus Detail Column", @"2", UIKeyModifierCommand | UIKeyModifierAlternate, PaneDetail) \
    X(Narrow, "Narrow List Column", UIKeyInputLeftArrow, UIKeyModifierControl | UIKeyModifierAlternate, PaneNarrow) \
    X(Widen, "Widen List Column", UIKeyInputRightArrow, UIKeyModifierControl | UIKeyModifierAlternate, PaneWiden) \
    X(Find, "Find in Current Column…", @"f", UIKeyModifierCommand, PaneFind) \
    X(Previous, "Previous Item", UIKeyInputUpArrow, 0, PanePrevious) \
    X(Next, "Next Item", UIKeyInputDownArrow, 0, PaneNext) \
    X(Open, "Open Selected Item", UIKeyInputRightArrow, 0, PaneOpen) \
    X(Back, "Back", @"[", UIKeyModifierCommand, PaneBack) \
    X(Forward, "Forward", @"]", UIKeyModifierCommand, PaneForward) \
    X(Deselect, "Deselect Item", UIKeyInputEscape, 0, PaneDeselect) \
    X(Media, "Open Selected Media", @"\r", 0, PaneMedia) \
    X(PageUp, "Page Up", @" ", UIKeyModifierShift, PanePageUp) \
    X(PageDown, "Page Down", @" ", 0, PanePageDown) \
    X(Top, "Scroll to Top", UIKeyInputUpArrow, UIKeyModifierCommand, PaneTop) \
    X(Bottom, "Scroll to Bottom", UIKeyInputDownArrow, UIKeyModifierCommand, PaneBottom) \
    X(NewWindow, "Open Detail in New Window", @"o", UIKeyModifierCommand | UIKeyModifierShift, PaneNewWindow)

static NSInteger ApolloPaneMenuKind(SEL action) {
#define MATCH(name, title, input, flags, kind) if (action == NSSelectorFromString(@"apollo_menu" #name ":")) return kind;
    PANE_COMMANDS(MATCH)
#undef MATCH
    return NSNotFound;
}

BOOL ApolloPaneMenuOwnsAction(SEL action) { return ApolloPaneMenuKind(action) != NSNotFound; }

NSArray<UIKeyCommand *> *ApolloPaneMenuKeyCommands(void) {
    if (!ApolloPaneLayoutEnabled()) return @[];
    NSMutableArray *commands = [NSMutableArray array];
#define COMMAND(name, label, key, modifiers, kind) { \
    UIKeyCommand *command = [UIKeyCommand commandWithTitle:@label image:nil \
        action:NSSelectorFromString(@"apollo_menu" #name ":") input:key modifierFlags:modifiers propertyList:@(kind)]; \
    command.discoverabilityTitle = @label; \
    if (@available(iOS 15.0, *)) command.wantsPriorityOverSystemBehavior = \
        (kind == PanePrevious || kind == PaneNext || kind == PaneOpen || kind == PaneDeselect || \
         kind == PaneMedia || kind == PanePageUp || kind == PanePageDown || kind == PaneTop || kind == PaneBottom); \
    if (@available(iOS 26.0, *)) command.repeatBehavior = \
        (kind == PanePrevious || kind == PaneNext || kind == PaneNarrow || kind == PaneWiden || \
         kind == PanePageUp || kind == PanePageDown) ? UIMenuElementRepeatBehaviorRepeatable : UIMenuElementRepeatBehaviorNonRepeatable; \
    [commands addObject:command]; \
}
    PANE_COMMANDS(COMMAND)
#undef COMMAND
    UIKeyCommand *back = [UIKeyCommand commandWithTitle:@"Back" image:nil
        action:NSSelectorFromString(@"apollo_menuBack:") input:UIKeyInputLeftArrow modifierFlags:0 propertyList:nil];
    if (@available(iOS 15.0, *)) back.wantsPriorityOverSystemBehavior = YES;
    [commands addObject:back];
    return commands;
}

static BOOL ApolloPaneMenuIsClass(id object, const char *name) {
    Class cls = objc_lookUpClass(name);
    return cls && [object isKindOfClass:cls];
}

static UINavigationController *ApolloPaneMenuNavigation(ApolloPaneSplitViewController *pane) {
    UIViewController *focused = ApolloPaneFocusedController(pane);
    return focused.navigationController;
}

static id ApolloPaneMenuTableNode(UIViewController *controller) {
    if (!ApolloPaneMenuIsClass(controller, "_TtC6Apollo19PostsViewController") &&
        !ApolloPaneMenuIsClass(controller, "_TtC6Apollo22CommentsViewController")) return nil;
    return ApolloReadObjectIvar(controller, "tableNode");
}

static id ApolloPaneMenuSelectedNode(UIViewController *controller) {
    id table = ApolloPaneMenuTableNode(controller);
    SEL selection = NSSelectorFromString(@"indexPathForSelectedRow");
    SEL cell = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (![table respondsToSelector:selection] || ![table respondsToSelector:cell]) return nil;
    NSIndexPath *path = ((id (*)(id, SEL))objc_msgSend)(table, selection);
    return path ? ((id (*)(id, SEL, id))objc_msgSend)(table, cell, path) : nil;
}

static UIViewController *ApolloPaneMenuPostingContext(ApolloPaneSplitViewController *pane) {
    UIViewController *focused = ApolloPaneFocusedController(pane);
    if (ApolloPaneMenuIsClass(focused, "_TtC6Apollo19PostsViewController")) return focused;
    // A reader (including an empty reader after launch) belongs to its primary
    // feed. Keep New Post available for that visible subreddit regardless of
    // which reader view is focused, without borrowing another tab/window.
    UIViewController *primary = pane.apollo_primaryContextViewController;
    UINavigationController *reader = [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
    BOOL reading = focused.navigationController == reader ||
        ApolloPaneMenuIsClass(focused, "_TtC6Apollo22CommentsViewController");
    return reading && ApolloPaneMenuIsClass(primary, "_TtC6Apollo19PostsViewController") ? primary : nil;
}

static UIResponder *ApolloPaneMenuFirstResponder(UIView *view) {
    if (view.isFirstResponder) return view;
    for (UIView *child in view.subviews) {
        UIResponder *responder = ApolloPaneMenuFirstResponder(child);
        if (responder) return responder;
    }
    return nil;
}

static BOOL ApolloPaneMenuContextAvailable(ApolloPaneSplitViewController *pane) {
    if (!ApolloPaneLayoutActive() || !pane.viewIfLoaded.window ||
        pane.view.window.windowScene.activationState != UISceneActivationStateForegroundActive) return NO;
    UITabBarController *tabs = pane.tabBarController;
    if (ApolloPaneSidebarSelectedIndex(tabs) != (NSUInteger)pane.apollo_tabIndex) return NO;
    // Do not switch tabs, scroll background columns or steal keys from a draft,
    // media viewer, account chooser, sheet, or an in-progress navigation gesture.
    for (UIViewController *owner = pane; owner; owner = owner.parentViewController) {
        if (owner.presentedViewController) return NO;
    }
    for (NSNumber *column in @[@(ApolloPaneColumnPrimary), @(ApolloPaneColumnSecondary)]) {
        UINavigationController *nav = [pane apollo_navigationControllerForColumn:(ApolloPaneColumn)column.integerValue];
        if (nav.presentedViewController || nav.topViewController.presentedViewController ||
            nav.transitionCoordinator) return NO;
    }
    UIResponder *first = ApolloPaneMenuFirstResponder(pane.view.window);
    return ![first conformsToProtocol:@protocol(UITextInput)];
}

BOOL ApolloPaneMenuCanPerform(ApolloPaneSplitViewController *pane, SEL action) {
    NSInteger kind = ApolloPaneMenuKind(action);
    if (kind == NSNotFound || !ApolloPaneMenuContextAvailable(pane)) return NO;
    UIViewController *focused = ApolloPaneFocusedController(pane);
    UINavigationController *nav = ApolloPaneMenuNavigation(pane);
    if (ApolloPaneGalleryIsPresented(pane) && kind != PaneBack && kind != PaneSidebar &&
        kind != PaneJump && kind != PaneSubreddits && kind > PaneSettings) return NO;
    switch (kind) {
        case PaneNewPost:
            return ApolloSubredditNameFromViewController(ApolloPaneMenuPostingContext(pane)).length > 0;
        case PaneReply: {
            id node = ApolloPaneMenuSelectedNode(focused);
            id comment = ApolloReadObjectIvar(node, "comment");
            id link = ApolloReadObjectIvar(focused, "link");
            if ([comment respondsToSelector:@selector(archived)] &&
                ((BOOL (*)(id, SEL))objc_msgSend)(comment, @selector(archived))) return NO;
            if ([link respondsToSelector:@selector(locked)] &&
                ((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(locked))) return NO;
            return ApolloPaneMenuIsClass(focused, "_TtC6Apollo22CommentsViewController") &&
                ApolloPaneMenuIsClass(node, "_TtC6Apollo15CommentCellNode") &&
                [node respondsToSelector:NSSelectorFromString(@"moreOptionsTappedWithSender:")];
        }
        case PaneRefresh: return [focused respondsToSelector:NSSelectorFromString(@"refreshControlActivatedWithSender:")];
        case PaneList: return !pane.isCollapsed && [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary].viewIfLoaded.window != nil;
        case PaneDetail: return !pane.isCollapsed && !pane.apollo_detailIsEmpty && [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary].viewIfLoaded.window != nil;
        case PaneNarrow: case PaneWiden: return !pane.isCollapsed && pane.displayMode == UISplitViewControllerDisplayModeOneBesideSecondary;
        case PaneSidebar:
            if (@available(iOS 18.0, *)) return !pane.tabBarController.sidebar.isHidden || ApolloPaneCanShowNavigationSidebar(pane.tabBarController);
            return NO;
        case PaneFind: return focused.navigationItem.searchController != nil || ApolloPaneMenuIsClass(focused, "_TtC6Apollo22CommentsViewController");
        case PaneNext: case PanePrevious: return ApolloPaneMenuTableNode(focused) != nil;
        case PaneOpen: case PaneDeselect: return ApolloPaneMenuSelectedNode(focused) != nil;
        case PaneMedia: return ApolloReadObjectIvar(ApolloPaneMenuSelectedNode(focused), "link") != nil;
        case PaneBack: return ApolloPaneGalleryIsPresented(pane) || nav.viewControllers.count > 1;
        case PaneForward: return ApolloSwiftArrayCount(ApolloReadRawIvar(nav, "poppedViewControllers")) > 0;
        case PanePageUp: case PanePageDown: case PaneTop: case PaneBottom: return ApolloPaneMenuTableNode(focused) != nil;
        case PaneNewWindow: return ApolloPaneCanOpenDetailInNewWindow(pane);
        default: return YES;
    }
}

void ApolloPaneMenuValidate(ApolloPaneSplitViewController *pane, UICommand *command) {
    command.attributes = ApolloPaneMenuCanPerform(pane, command.action) ? 0 : UIMenuElementAttributesDisabled;
    if (ApolloPaneMenuKind(command.action) == PaneSidebar) {
        if (@available(iOS 18.0, *)) command.title = pane.tabBarController.sidebar.isHidden ? @"Show Sidebar" : @"Hide Sidebar";
    }
}

static void ApolloPaneMenuInvokeNative(UINavigationController *nav, NSString *selector) {
    SEL action = NSSelectorFromString(selector);
    if ([nav respondsToSelector:action]) ((void (*)(id, SEL))objc_msgSend)(nav, action);
}

static NSString *ApolloPaneMenuSubredditName(NSString *text) {
    NSString *name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([name.lowercaseString hasPrefix:@"/r/"]) name = [name substringFromIndex:3];
    else if ([name.lowercaseString hasPrefix:@"r/"]) name = [name substringFromIndex:2];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
    return name.length && name.length <= 21 && [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound ? name : nil;
}

static void ApolloPaneMenuJump(ApolloPaneSplitViewController *pane) {
    // This prompt works from every tab, including a fresh directory-only launch.
    // It accepts the familiar r/ prefix, and routes to Posts in the same scene.
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Jump to Subreddit"
        message:@"Enter a subreddit name." preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"r/subreddit";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.returnKeyType = UIReturnKeyGo;
        [field addTarget:pane action:NSSelectorFromString(@"apollo_menuJumpTextChanged:") forControlEvents:UIControlEventEditingChanged];
    }];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak ApolloPaneSplitViewController *weakPane = pane;
    __weak UIAlertController *weakPrompt = prompt;
    UIAlertAction *go = [UIAlertAction actionWithTitle:@"Go" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        ApolloPaneSplitViewController *owner = weakPane;
        if (!owner.viewIfLoaded.window) return;
        NSString *name = ApolloPaneMenuSubredditName(weakPrompt.textFields.firstObject.text);
        if (!name) return;
        UIWindowScene *scene = owner.view.window.windowScene;
        UITabBarController *tabs = owner.tabBarController;
        if (!ApolloPaneSidebarSelectIndex(tabs, 0)) return;
        ApolloPaneDismissGalleryForController(tabs.selectedViewController);
        NSURLComponents *url = [NSURLComponents new];
        url.scheme = @"apollo"; url.host = @"reddit.com"; url.path = [NSString stringWithFormat:@"/r/%@/", name];
        ApolloRouteURLThroughAppInScene(url.URL, scene);
    }];
    [prompt addAction:go];
    go.enabled = NO;
    prompt.preferredAction = go;
    [pane presentViewController:prompt animated:YES completion:nil];
}

static void ApolloPaneMenuPerform(ApolloPaneSplitViewController *pane, SEL action) {
    if (!ApolloPaneMenuCanPerform(pane, action)) return;
    NSInteger kind = ApolloPaneMenuKind(action);
    UIViewController *focused = ApolloPaneFocusedController(pane);
    UINavigationController *nav = ApolloPaneMenuNavigation(pane);
    switch (kind) {
        case PanePosts: case PaneInbox: case PaneProfile: case PaneSearch: case PaneSettings:
            if (ApolloPaneSidebarSelectIndex(pane.tabBarController, kind) && kind == PanePosts) {
                UIViewController *posts = ApolloPaneSidebarRootControllers(pane.tabBarController).firstObject;
                if ([posts isKindOfClass:ApolloPaneSplitViewController.class])
                    [(ApolloPaneSplitViewController *)posts apollo_restoreSidebarPostsIfNeeded];
            }
            break;
        case PaneSubreddits: ApolloPaneSidebarSelectSubreddits(pane.tabBarController); break;
        case PaneJump: ApolloPaneMenuJump(pane); break;
        case PaneNewPost: {
            UIViewController *posts = ApolloPaneMenuPostingContext(pane);
            ApolloNativeActionMenuInvokePostsAction(posts, focused.view, 51);
            break;
        }
        case PaneReply: {
            id node = ApolloPaneMenuSelectedNode(focused);
            UIView *source = [node respondsToSelector:@selector(view)] ? [node view] : nil;
            id sheet = ApolloNativeActionMenuCaptureController(source, ^{
                ((void (*)(id, SEL, id))objc_msgSend)(node, NSSelectorFromString(@"moreOptionsTappedWithSender:"), source);
            });
            if (ApolloNativeActionMenuHasAction(sheet, 12)) ApolloNativeActionMenuInvokeAction(sheet, 12);
            break;
        }
        case PaneRefresh:
            ((void (*)(id, SEL, id))objc_msgSend)(focused, NSSelectorFromString(@"refreshControlActivatedWithSender:"), ApolloReadObjectIvar(focused, "refreshControl")); break;
        case PaneSidebar:
            if (@available(iOS 18.0, *)) pane.tabBarController.sidebar.hidden = !pane.tabBarController.sidebar.isHidden;
            break;
        case PaneList: ApolloPaneFocusColumn(pane, NO, YES); break;
        case PaneDetail: ApolloPaneFocusColumn(pane, YES, YES); break;
        case PaneNarrow: ((void (*)(id, SEL, id))objc_msgSend)(pane, NSSelectorFromString(@"apollo_narrowPrimaryColumn:"), nil); break;
        case PaneWiden: ((void (*)(id, SEL, id))objc_msgSend)(pane, NSSelectorFromString(@"apollo_widenPrimaryColumn:"), nil); break;
        case PaneFind: ((void (*)(id, SEL, id))objc_msgSend)(pane, NSSelectorFromString(@"apollo_findInFocusedPane:"), nil); break;
        case PanePrevious: ApolloPaneMenuInvokeNative(nav, @"selectPreviousCell"); break;
        case PaneNext: ApolloPaneMenuInvokeNative(nav, @"selectNextCell"); break;
        case PaneOpen: ApolloPaneMenuInvokeNative(nav, @"goIntoCell"); break;
        case PaneBack:
            if (ApolloPaneGalleryIsPresented(pane)) ApolloPaneDismissGalleryForController(pane);
            else ApolloPaneMenuInvokeNative(nav, @"goBack");
            break;
        case PaneForward: ApolloPaneMenuInvokeNative(nav, @"goForward"); break;
        case PaneDeselect: ApolloPaneMenuInvokeNative(nav, @"deselect"); break;
        case PaneMedia: ApolloPaneMenuInvokeNative(nav, @"openMedia"); break;
        case PanePageUp: ApolloPaneMenuInvokeNative(nav, @"pageUp"); break;
        case PanePageDown: ApolloPaneMenuInvokeNative(nav, @"pageDown"); break;
        case PaneTop: ApolloPaneMenuInvokeNative(nav, @"scrollToTop"); break;
        case PaneBottom: ApolloPaneMenuInvokeNative(nav, @"scrollToBottom"); break;
        case PaneNewWindow: ApolloPaneOpenDetailInNewWindow(pane); break;
    }
    [UIMenuSystem.mainSystem setNeedsRevalidate];
}

@implementation ApolloPaneSplitViewController (ApolloMainMenus)
#define HANDLER(name, title, input, flags, kind) - (void)apollo_menu##name:(id)sender { ApolloPaneMenuPerform(self, _cmd); }
    PANE_COMMANDS(HANDLER)
#undef HANDLER
- (void)apollo_menuJumpTextChanged:(UITextField *)field {
    UIAlertController *prompt = (id)self.presentedViewController;
    if ([prompt isKindOfClass:UIAlertController.class] && prompt.textFields.firstObject == field)
        prompt.preferredAction.enabled = ApolloPaneMenuSubredditName(field.text) != nil;
}
@end

static UIMenu *ApolloPaneMenuSection(NSString *identifier, NSArray *commands, NSRange range) {
    return [UIMenu menuWithTitle:@"" image:nil identifier:identifier options:UIMenuOptionsDisplayInline children:[commands subarrayWithRange:range]];
}

static void ApolloPaneBuildMainMenu(id<UIMenuBuilder> builder) {
    if (!ApolloPaneLayoutEnabled() || builder.system != UIMenuSystem.mainSystem) return;
    if (@available(iOS 26.0, *)) {
        // UIKit supplies Cmd-N for New Window. Apollo's primary creation action
        // is a post; keep the system window command with Cmd-Option-N instead
        // of registering two owners for the same key (undefined in UIKit).
        SEL newScene = NSSelectorFromString(@"requestNewScene:");
        UICommand *original = [builder commandForAction:newScene propertyList:nil];
        if (original) {
            UIKeyCommand *window = [UIKeyCommand commandWithTitle:original.title image:original.image
                action:original.action input:@"n" modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate
                propertyList:original.propertyList];
            window.attributes = original.attributes;
            window.repeatBehavior = UIMenuElementRepeatBehaviorNonRepeatable;
            [builder replaceCommandForAction:newScene propertyList:original.propertyList withElements:@[window]];
        }
    }
    NSArray *commands = ApolloPaneMenuKeyCommands();
    UIMenu *newPost = ApolloPaneMenuSection(@"app.apolloreborn.ipad.new", commands, NSMakeRange(PaneNewPost, 1));
    [builder insertChildMenu:newPost atStartOfMenuForIdentifier:UIMenuFile];
    UIMenu *navigate = [UIMenu menuWithTitle:@"Navigate" image:nil identifier:@"app.apolloreborn.ipad.navigate" options:0 children:@[
        ApolloPaneMenuSection(@"app.apolloreborn.ipad.tabs", commands, NSMakeRange(PanePosts, 7)),
        ApolloPaneMenuSection(@"app.apolloreborn.ipad.history", commands, NSMakeRange(PaneBack, 2)),
        ApolloPaneMenuSection(@"app.apolloreborn.ipad.selection",
            @[[commands objectAtIndex:PanePrevious], [commands objectAtIndex:PaneNext],
              [commands objectAtIndex:PaneOpen], [commands objectAtIndex:PaneDeselect]], NSMakeRange(0, 4))]];
    [builder insertSiblingMenu:navigate afterMenuForIdentifier:UIMenuView];
    UIMenu *post = [UIMenu menuWithTitle:@"Post" image:nil identifier:@"app.apolloreborn.ipad.post" options:0 children:@[commands[PaneReply], commands[PaneRefresh], commands[PaneMedia]]];
    [builder insertSiblingMenu:post afterMenuForIdentifier:navigate.identifier];
    [builder insertChildMenu:ApolloPaneMenuSection(@"app.apolloreborn.ipad.columns", commands, NSMakeRange(PaneSidebar, 5)) atStartOfMenuForIdentifier:UIMenuView];
    [builder insertChildMenu:ApolloPaneMenuSection(@"app.apolloreborn.ipad.scrolling", commands, NSMakeRange(PanePageUp, 4)) atEndOfMenuForIdentifier:UIMenuView];
    [builder insertChildMenu:ApolloPaneMenuSection(@"app.apolloreborn.ipad.find", commands, NSMakeRange(PaneFind, 1)) atEndOfMenuForIdentifier:UIMenuEdit];
    [builder insertChildMenu:ApolloPaneMenuSection(@"app.apolloreborn.ipad.window", commands, NSMakeRange(PaneNewWindow, 1)) atStartOfMenuForIdentifier:UIMenuWindow];
    ApolloLog(@"[PaneMenu] installed native main menu (%lu commands), file=%d view=%d navigate=%d post=%d",
        (unsigned long)commands.count, [builder menuForIdentifier:UIMenuFile] != nil,
        [builder menuForIdentifier:UIMenuView] != nil, [builder menuForIdentifier:navigate.identifier] != nil,
        [builder menuForIdentifier:post.identifier] != nil);
}

%group ApolloPaneMenusGroup
%hook _TtC6Apollo11AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    BOOL result = %orig(application, options);
    if (@available(iOS 26.0, *)) {
        UIMainMenuSystemConfiguration *configuration = [UIMainMenuSystemConfiguration new];
        // Apollo's find and sidebar actions have explicit column ownership.
        // Keep standard Edit and Window commands, omit duplicate system groups.
        configuration.findingPreference = UIMenuSystemElementGroupPreferenceRemoved;
        configuration.sidebarPreference = UIMenuSystemElementGroupPreferenceRemoved;
        configuration.inspectorPreference = UIMenuSystemElementGroupPreferenceRemoved;
        [UIMainMenuSystem.sharedSystem setBuildConfiguration:configuration buildHandler:nil];
    } else {
        [UIMenuSystem.mainSystem setNeedsRebuild];
    }
    return result;
}
- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder {
    %orig(builder);
    ApolloPaneBuildMainMenu(builder);
}
%end

// The pane owns the same native browsing keys once columns exist. Removing
// only these duplicates prevents an unfocused sibling nav handling the event.
%hook _TtC6Apollo26ApolloNavigationController
- (NSArray *)keyCommands {
    NSArray *original = %orig;
    ApolloPaneSplitViewController *pane = (id)ApolloPaneSplitControllerFor((UIViewController *)self);
    if (!ApolloPaneLayoutActive() || !pane ||
        ((id)self != [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary] &&
         (id)self != [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary])) return original;
    NSSet *routed = [NSSet setWithArray:@[@"deselect", @"selectPreviousCell", @"selectNextCell", @"goIntoCell", @"goBack", @"goForward", @"goToJumpBar", @"pageUp", @"pageDown", @"scrollToTop", @"scrollToBottom", @"openMedia"]];
    NSMutableArray *kept = [NSMutableArray array];
    for (UIKeyCommand *command in original) if (![routed containsObject:NSStringFromSelector(command.action)]) [kept addObject:command];
    return kept;
}
%end
%hook _TtC6Apollo22ApolloTabBarController
- (NSArray *)keyCommands {
    NSArray *original = %orig;
    if (!ApolloPaneLayoutActive()) return original;
    NSMutableArray *kept = [NSMutableArray array];
    for (UIKeyCommand *command in original) if (![NSStringFromSelector(command.action) hasPrefix:@"goTo"]) [kept addObject:command];
    return kept;
}
%end
%hook _TtC6Apollo22CommentsViewController
- (NSArray *)keyCommands {
    NSArray *original = %orig;
    if (!ApolloPaneLayoutActive() || !ApolloPaneSplitControllerFor((UIViewController *)self)) return original;
    NSMutableArray *kept = [NSMutableArray array];
    for (UIKeyCommand *command in original) if (command.action != NSSelectorFromString(@"searchCommentsKeyCommandSelected")) [kept addObject:command];
    return kept;
}
%end
%end

%ctor {
    if (ApolloPaneLayoutEnabled()) { %init(ApolloPaneMenusGroup); }
}
