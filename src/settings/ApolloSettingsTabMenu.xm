#import "ApolloSettingsShortcutsViewController.h"
#import "ApolloSettingsRouter.h"
#import "ApolloBuyUsACoffeeViewController.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloAutomaticBackupViewController.h"
#import "ApolloReportViewController.h"
#import "ApolloSettingsForm.h"
#import "SavedCategoriesViewController.h"
#import "ApolloThemeManagerViewController.h"

// Match the account switcher's medium impact for deliberate menu actions.
static void ApolloSettingsMenuHaptic(void) {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
}

// A recognized hold owns that touch through its release. Keep this marker
// until the next tab touch (or an explicit shortcut), since Glass can deliver
// its selection callback after the hold recognizer has already ended.
static char kApolloSettingsHoldConsumedTouch;
static char kApolloSettingsShortcutRoot;

static UIScrollView *ApolloShortcutScrollView(UIView *view) {
    if (view.hidden || view.alpha < 0.01) return nil;
    if ([view isKindOfClass:UIScrollView.class] && ((UIScrollView *)view).scrollEnabled) {
        return (UIScrollView *)view;
    }
    for (UIView *child in view.subviews) {
        UIScrollView *scroll = ApolloShortcutScrollView(child);
        if (scroll) return scroll;
    }
    return nil;
}

// Apollo's tab reselection only knows its own controllers. Limit our handling
// to the shortcut portion of the stack, including pages opened inside it.
static BOOL ApolloHandleShortcutTabReselection(UITabBarController *controller, UIViewController *selected) {
    if (controller.selectedViewController != selected ||
        ![selected isKindOfClass:UINavigationController.class]) return NO;
    UINavigationController *nav = (UINavigationController *)selected;
    BOOL inShortcut = NO;
    for (UIViewController *screen in nav.viewControllers) {
        if ([objc_getAssociatedObject(screen, &kApolloSettingsShortcutRoot) boolValue]) {
            inShortcut = YES;
            break;
        }
    }
    if (!inShortcut) return NO;
    if (nav.transitionCoordinator) return YES;
    UIScrollView *scroll = ApolloShortcutScrollView(nav.topViewController.view);
    CGFloat top = -scroll.adjustedContentInset.top;
    if (scroll && scroll.contentOffset.y > top + 1.0) {
        [scroll setContentOffset:CGPointMake(scroll.contentOffset.x, top) animated:YES];
        ApolloLog(@"[SettingsTabMenu] Reselected tab: scroll shortcut to top");
    } else if (nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:YES];
        ApolloLog(@"[SettingsTabMenu] Reselected tab: return to previous page");
    }
    return YES;
}
static void ApolloClearConsumedSettingsTouch(UITabBarController *controller) {
    if (controller) objc_setAssociatedObject(controller, &kApolloSettingsHoldConsumedTouch, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Identify the native item rather than waiting for Glass's normal and lens
// copies to finish animating into matching positions after the bar expands.
static id ApolloSettingsObjectForSelector(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static UIView *ApolloFindSettingsItemView(UIView *view, UITabBarItem *settingsItem) {
    if (view.hidden || view.alpha <= 0.01) return nil;
    id item = ApolloSettingsObjectForSelector(view, @"item");
    if (item == settingsItem || ApolloSettingsObjectForSelector(item, @"_linkedTabBarItem") == settingsItem) return view;
    for (UIView *child in view.subviews) {
        UIView *match = ApolloFindSettingsItemView(child, settingsItem);
        if (match) return match;
    }
    return nil;
}

static UIView *ApolloSettingsTabView(UITabBarController *controller) {
    UITabBarItem *settingsItem = nil;
    for (UIViewController *child in controller.viewControllers) {
        UIViewController *root = [child isKindOfClass:UINavigationController.class]
            ? ((UINavigationController *)child).viewControllers.firstObject : child;
        if ([NSStringFromClass(root.class) containsString:@"SettingsViewController"]) {
            NSUInteger index = [controller.viewControllers indexOfObjectIdenticalTo:child];
            settingsItem = index < controller.tabBar.items.count ? controller.tabBar.items[index] : child.tabBarItem;
            break;
        }
    }
    if (!settingsItem) return nil;
    UIView *button = ApolloSettingsObjectForSelector(settingsItem, @"_tabBarButton");
    if ([button isKindOfClass:UIView.class] && [button isDescendantOfView:controller.tabBar] &&
        !button.hidden && button.alpha > 0.01) return button;
    Ivar viewIvar = class_getInstanceVariable(settingsItem.class, "_view");
    UIView *itemView = viewIvar ? object_getIvar(settingsItem, viewIvar) : nil;
    if ([itemView isKindOfClass:UIView.class] && [itemView isDescendantOfView:controller.tabBar] &&
        !itemView.hidden && itemView.alpha > 0.01) return itemView;
    return ApolloFindSettingsItemView(controller.tabBar, settingsItem);
}

// All shortcut destinations belong to one stack, regardless of the tab
// where the menu was opened. This also gives the editor a single owner.
static UINavigationController *ApolloSettingsShortcutNavigation(UITabBarController *controller) {
    for (UIViewController *child in controller.viewControllers) {
        if (![child isKindOfClass:UINavigationController.class]) continue;
        UINavigationController *nav = (UINavigationController *)child;
        if ([nav.viewControllers.firstObject isKindOfClass:NSClassFromString(@"_TtC6Apollo22SettingsViewController")]) return nav;
    }
    return nil;
}

static void ApolloPushSettingsShortcut(UITabBarController *controller, UIViewController *screen) {
    if (!controller) return;
    ApolloClearConsumedSettingsTouch(controller);
    UINavigationController *nav = ApolloSettingsShortcutNavigation(controller);
    if (!nav || !screen) return;
    BOOL switchingTabs = controller.selectedViewController != nav;

    // Reuse a destination already in this navigation stack.
    UIViewController *destination = screen;
    for (UIViewController *existing in nav.viewControllers) {
        if ([existing isMemberOfClass:screen.class]) {
            destination = existing;
            break;
        }
    }
    objc_setAssociatedObject(destination, &kApolloSettingsShortcutRoot, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (nav.topViewController == destination && !switchingTabs) return;
    // Disabling the tab bar alone lets hit testing fall through to the page.
    // Consume touches at the window until the navigation transition finishes.
    UIWindow *window = controller.view.window;
    UIView *transitionShield = [[UIView alloc] initWithFrame:window.bounds];
    transitionShield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    transitionShield.accessibilityElementsHidden = YES;
    [window addSubview:transitionShield];
    if (switchingTabs) {
        // Select the owning stack and start its normal navigation transition
        // in the same run-loop turn. UIKit owns the page animation, just as
        // when a shortcut is opened while Settings is already selected.
        controller.selectedViewController = nav;
        [nav.view layoutIfNeeded];
        if (nav.topViewController == destination) {
            [transitionShield removeFromSuperview];
            return;
        }
    }
    if (destination != screen) {
        [nav popToViewController:destination animated:YES];
    } else {
        [nav pushViewController:destination animated:YES];
    }
    id<UIViewControllerTransitionCoordinator> transition = nav.transitionCoordinator;
    BOOL observing = [transition animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [transitionShield removeFromSuperview];
    }];
    if (!observing) {
        // UIKit may not expose the coordinator until the push commits.
        dispatch_async(dispatch_get_main_queue(), ^{
            id<UIViewControllerTransitionCoordinator> committed = nav.transitionCoordinator;
            BOOL attached = [committed animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                [transitionShield removeFromSuperview];
            }];
            if (!attached) [transitionShield removeFromSuperview];
        });
    }
    ApolloLog(@"[SettingsTabMenu] Opened directly %@ reused=%d", NSStringFromClass(destination.class), destination != screen);
}

// UIKit owns the context menu's layout, separators, backdrop and animation.
// Limit native menu placement without intercepting the underlying page.
static UIView *ApolloSettingsMenuList(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"_UIContextMenuListView"]) return view;
    for (UIView *child in view.subviews) {
        UIView *list = ApolloSettingsMenuList(child);
        if (list) return list;
    }
    return nil;
}
@interface ApolloSettingsDismissSurface : UIView
@property (nonatomic, weak) UIView *menuContainer;
@property (nonatomic, weak) UIButton *editButton;
@end
@implementation ApolloSettingsDismissSurface
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIButton *button = self.editButton;
    if (button && !button.hidden && [button pointInside:[self convertPoint:point toView:button] withEvent:event]) return nil;
    UIView *list = ApolloSettingsMenuList(self.menuContainer);
    if (list && [list pointInside:[self convertPoint:point toView:list] withEvent:event]) return nil;
    return [super hitTest:point withEvent:event];
}
@end
@interface ApolloSettingsMenuContainer : UIView
@end
@implementation ApolloSettingsMenuContainer
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

@interface ApolloSettingsTabHold : NSObject <UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate>
@property (nonatomic, weak) UITabBarController *controller;
@property (nonatomic, copy) NSDictionary<NSString *, UIImage *> *menuImages;
@property (nonatomic, strong) UITraitCollection *imageTraits;
@property (nonatomic, strong) UILongPressGestureRecognizer *gesture;
@property (nonatomic, strong) UIContextMenuInteraction *interaction;
@property (nonatomic, copy) void (^pendingAction)(void);
@property (nonatomic, strong) UIView *anchor;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic) BOOL animatingDismissal;
@property (nonatomic, strong) UIView *dismissSurface;
@property (nonatomic, strong) UIView *menuContainer;
@property (nonatomic, strong) UIView *menuLayoutContainer;
@property (nonatomic, strong) UIButton *editButton;
@property (nonatomic, strong) CADisplayLink *editPositionLink;
@end
@implementation ApolloSettingsTabHold
- (void)positionEditButton {
    UIView *list = ApolloSettingsMenuList(self.menuContainer);
    if (!list.window || !self.editButton) return;
    CGRect frame = [list convertRect:list.bounds toView:self.menuContainer];
    if (CGRectIsEmpty(frame)) return;
    // Position independently of the native platter's internals; never change
    // UIKit's menu layout or animation to make room for our accessory.
    CGRect target = CGRectMake(CGRectGetMaxX(frame) - 44, CGRectGetMinY(frame) - 52, 44, 44);
    target.origin.y = MAX(self.menuContainer.safeAreaInsets.top, target.origin.y);
    if (!CGRectEqualToRect(self.editButton.frame, target)) self.editButton.frame = target;
    [self.menuContainer bringSubviewToFront:self.editButton];
    if (self.editButton.hidden) {
        self.editButton.hidden = NO;
        [UIView animateWithDuration:0.18 animations:^{ self.editButton.alpha = 1; }];
    }
}
- (void)editShortcuts {
    if (self.animatingDismissal || !self.interaction) return;
    ApolloSettingsMenuHaptic();
    __weak UITabBarController *controller = self.controller;
    self.pendingAction = ^{
        ApolloPushSettingsShortcut(controller, [[ApolloSettingsShortcutsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]);
    };
    self.editButton.userInteractionEnabled = NO;
    [self.interaction dismissMenu];
}

- (void)prepareMenuImages {
    UITabBarController *controller = self.controller;
    UITraitCollection *traits = controller.traitCollection;
    if (self.menuImages && ![traits hasDifferentColorAppearanceComparedToTraitCollection:self.imageTraits]
        && traits.displayScale == self.imageTraits.displayScale) {
        // Unlike the other tiles, App Icon is user-selected artwork. Read the
        // native row again on every presentation instead of freezing it in
        // the appearance cache for the lifetime of the tab controller.
        NSMutableDictionary *images = [self.menuImages mutableCopy];
        UIImage *currentIcon = ApolloSettingsShortcutImage(@"app-icon", traits, 36);
        if (currentIcon) images[@"app-icon"] = currentIcon;
        else [images removeObjectForKey:@"app-icon"];
        self.menuImages = images;
        return;
    }
    NSMutableDictionary *images = [NSMutableDictionary dictionary];
    for (NSString *identifier in ApolloSettingsShortcutCatalog()) {
        UIImage *image = ApolloSettingsShortcutImage(identifier, traits, 36);
        if (image) images[identifier] = image;
    }
    self.menuImages = images;
    self.imageTraits = traits;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    ApolloClearConsumedSettingsTouch(self.controller);
    UIView *tab = ApolloSettingsTabView(self.controller);
    BOOL onSettings = tab.window && CGRectContainsPoint(tab.bounds, [touch locationInView:tab]);
    // Do glyph drawing during the hold threshold, not while UIKit opens the menu.
    if (onSettings) [self prepareMenuImages];
    return onSettings;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)held:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || self.anchor || self.controller.presentedViewController) return;
    UIView *tab = ApolloSettingsTabView(self.controller);
    UIWindow *window = tab.window;
    if (!window) return;
    ApolloLog(@"[SettingsTabMenu] Recognized Settings hold");
    // Present from a proxy so the tab bar's glass selection gesture cannot
    // cancel the native menu on finger-up or lift the entire tab bar as a preview.
    self.interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    SEL present = NSSelectorFromString(@"_presentMenuAtLocation:");
    if (![self.interaction respondsToSelector:present]) return;
    UIView *container = self.controller.view;
    CGRect sourceFrame = [tab convertRect:tab.bounds toView:container];
    CGRect barFrame = [self.controller.tabBar convertRect:self.controller.tabBar.bounds toView:container];
    self.menuContainer = [[ApolloSettingsMenuContainer alloc] initWithFrame:CGRectMake(0, 0, container.bounds.size.width, MAX(1, CGRectGetMinY(barFrame) - 12))];
    self.menuContainer.userInteractionEnabled = YES;
    self.menuContainer.accessibilityViewIsModal = YES;
    [container addSubview:self.menuContainer];
    // Keep a full 44pt customization button above even a scrolling 15-row
    // menu. UIKit sizes its platter within this inset host; the outer view
    // still owns our existing entrance/dismissal and the button.
    CGFloat menuTop = container.safeAreaInsets.top + 52;
    self.menuLayoutContainer = [[ApolloSettingsMenuContainer alloc] initWithFrame:CGRectMake(0, menuTop,
        self.menuContainer.bounds.size.width, MAX(1, self.menuContainer.bounds.size.height - menuTop))];
    [self.menuContainer addSubview:self.menuLayoutContainer];
    self.anchor = [[UIView alloc] initWithFrame:CGRectMake(CGRectGetMidX(sourceFrame) - 0.5,
        CGRectGetMidY(sourceFrame) - 0.5, 1.0, 1.0)];
    self.anchor.userInteractionEnabled = YES;
    [container addSubview:self.anchor];
    [self.anchor addInteraction:self.interaction];
    SEL driver = NSSelectorFromString(@"_setFallbackDriverStyle:");
    if ([self.interaction respondsToSelector:driver]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(self.interaction, driver, 1);
    }
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(self.interaction, present,
        CGPointMake(CGRectGetMidX(self.anchor.bounds), CGRectGetMidY(self.anchor.bounds)));
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UITabBarController *controller = self.controller;
    if (controller.presentedViewController || !self.anchor.window) return nil;
    objc_setAssociatedObject(controller, &kApolloSettingsHoldConsumedTouch, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak typeof(self) weakSelf = self;
    __weak UITabBarController *weakController = controller;
    [self prepareMenuImages];
    NSDictionary<NSString *, UIImage *> *images = self.menuImages;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenu *> *groups = [NSMutableArray array];
        for (NSString *identifier in ApolloSettingsShortcutIDs()) {
            UIAction *action = [UIAction actionWithTitle:ApolloSettingsShortcutTitle(identifier)
                image:images[identifier] identifier:nil handler:^(__unused UIAction *action) {
                    ApolloSettingsMenuHaptic();
                    weakSelf.pendingAction = ^{
                        if ([identifier isEqualToString:@"feature-requests"]) {
                            UINavigationController *nav = ApolloSettingsShortcutNavigation(weakController);
                            if (!nav) return;
                            ApolloClearConsumedSettingsTouch(weakController);
                            weakController.selectedViewController = nav;
                            UIViewController *presenter = nav.topViewController;
                            if (presenter) ApolloPresentWebURLFromViewController(presenter, [NSURL URLWithString:@"https://apolloreborn.fider.io/"]);
                        } else {
                            UIViewController *screen = [identifier isEqualToString:@"bug-reports"]
                                ? [[ApolloReportViewController alloc] init] : ApolloSettingsRouteInstantiate(identifier);
                            if ([identifier isEqualToString:@"buy-coffee"]) screen = [[ApolloBuyUsACoffeeViewController alloc] init];
                            if (!screen) screen = ApolloSettingsNativeShortcutScreen(ApolloSettingsShortcutTitle(identifier));
                            if (screen) ApolloPushSettingsShortcut(weakController, screen);
                        }
                    };
                }];
            UIMenu *group = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                options:UIMenuOptionsDisplayInline children:@[action]];
            if (@available(iOS 16.0, *)) group.preferredElementSize = UIMenuElementSizeLarge;
            [groups addObject:group];
        }
        if (groups.count == 0) {
            // UIKit will not present an empty context menu. Keep a passive
            // empty state so the existing customize button and dismissal
            // lifecycle remain available even after the last shortcut is removed.
            UIAction *empty = [UIAction actionWithTitle:@"No Shortcuts Enabled" image:nil identifier:nil
                handler:^(__unused UIAction *action) {}];
            empty.attributes = UIMenuElementAttributesDisabled;
            [groups addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                options:UIMenuOptionsDisplayInline children:@[empty]]];
        }
        UIMenu *menu = [UIMenu menuWithTitle:@"" children:groups];
        if (@available(iOS 16.0, *)) menu.preferredElementSize = UIMenuElementSizeLarge;
        return menu;
    }];
}
- (UITargetedPreview *)menuAnchorPreview {
    UIView *anchor = self.anchor;
    if (!anchor.window) return nil;
    UIPreviewParameters *parameters = [UIPreviewParameters new];
    parameters.backgroundColor = UIColor.clearColor;
    parameters.visiblePath = [UIBezierPath bezierPathWithRect:anchor.bounds];
    UIPreviewTarget *target = [[UIPreviewTarget alloc] initWithContainer:anchor.superview center:anchor.center];
    return [[UITargetedPreview alloc] initWithView:anchor parameters:parameters target:target];
}
- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForHighlightingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self menuAnchorPreview];
}
- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction previewForDismissingMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    return [self menuAnchorPreview];
}
// Match UIKit's button-menu presentation: actions only, anchored bloom.
- (id)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    Class cls = NSClassFromString(@"_UIContextMenuStyle");
    SEL factory = NSSelectorFromString(@"defaultStyle");
    if (![cls respondsToSelector:factory]) return nil;
    id style = ((id (*)(id, SEL))objc_msgSend)(cls, factory);
    SEL layout = NSSelectorFromString(@"setPreferredLayout:");
    SEL overlap = NSSelectorFromString(@"setShouldMenuOverlapSourcePreview:");
    if ([style respondsToSelector:layout]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(style, layout, 3);
    // Avoid morphing the full menu through the tiny transparent preview,
    // which stretches the rows into a bubble during the glass entrance.
    if ([style respondsToSelector:overlap]) ((void (*)(id, SEL, BOOL))objc_msgSend)(style, overlap, NO);
    SEL containerSetter = NSSelectorFromString(@"setContainerView:");
    if ([style respondsToSelector:containerSetter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(style, containerSetter, self.menuLayoutContainer);
    }
    return style;
}
- (void)dismissFromBackdrop:(UITapGestureRecognizer *)gesture {
    if (self.animatingDismissal || !self.interaction) return;
    self.animatingDismissal = YES;
    [self.editPositionLink invalidate];
    self.editPositionLink = nil;
    self.dismissSurface.userInteractionEnabled = NO;
    ApolloLog(@"[SettingsTabMenu] Returning live menu to Settings");
    UIView *container = self.menuContainer;
    UIView *backdrop = self.backdrop;
    UIContextMenuInteraction *interaction = self.interaction;
    UIView *settingsTab = ApolloSettingsTabView(self.controller);
    CGPoint source = [settingsTab convertPoint:CGPointMake(CGRectGetMidX(settingsTab.bounds),
        CGRectGetMidY(settingsTab.bounds)) toView:container.superview];
    // Use the real tab item: UIKit can reposition the temporary preview anchor.
    // Finish our return motion before asking UIKit to remove the live platter.
    // Release hit testing immediately so another hold can begin during the fade.
    container.userInteractionEnabled = NO;
    backdrop.userInteractionEnabled = NO;
    self.anchor.userInteractionEnabled = NO;
    [UIView animateWithDuration:0.22 delay:0
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionAllowUserInteraction
        animations:^{
            backdrop.alpha = 0;
            container.alpha = 0;
            if (!UIAccessibilityIsReduceMotionEnabled()) {
                CGFloat scale = 0.08;
                container.transform = CGAffineTransformMake(scale, 0, 0, scale,
                    (source.x - container.center.x) * (1 - scale),
                    (source.y - container.center.y) * (1 - scale));
            }
        } completion:^(__unused BOOL finished) {
            [interaction dismissMenu];
        }];
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    // Keep dimming below UIKit's menu while consuming taps on the page and tab bar.
    UIView *container = self.controller.view;
    UIView *backdrop = [[UIView alloc] initWithFrame:container.bounds];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // The account-switcher redesign retains Apollo’s native 40% black dimming.
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    backdrop.userInteractionEnabled = YES;
    [backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissFromBackdrop:)]];
    backdrop.alpha = 0;
    [container insertSubview:backdrop belowSubview:self.menuContainer];
    self.backdrop = backdrop;
    ApolloSettingsDismissSurface *surface = [[ApolloSettingsDismissSurface alloc] initWithFrame:container.window.bounds];
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.menuContainer = self.menuContainer;
    [surface addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissFromBackdrop:)]];
    [container.window addSubview:surface];
    self.dismissSurface = surface;
    UIButton *edit = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 26.0, *)) {
        UIButtonConfiguration *configuration = [UIButtonConfiguration glassButtonConfiguration];
        configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        configuration.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
        edit.configuration = configuration;
    } else {
        [edit setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
        edit.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        edit.layer.cornerRadius = 22;
    }
    edit.tintColor = UIColor.labelColor;
    edit.accessibilityLabel = @"Edit shortcuts";
    edit.accessibilityHint = @"Choose and reorder Settings tab shortcuts";
    edit.hidden = YES;
    edit.alpha = 0;
    [edit addTarget:self action:@selector(editShortcuts) forControlEvents:UIControlEventTouchUpInside];
    [self.menuContainer addSubview:edit];
    self.editButton = edit;
    surface.editButton = edit;
    self.editPositionLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(positionEditButton)];
    [self.editPositionLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self positionEditButton];
    CADisplayLink *positionLink = self.editPositionLink;
    __weak typeof(self) weakSelf = self;
    void (^finishPositioning)(void) = ^{
        [positionLink invalidate];
        if (weakSelf.interaction == interaction) {
            weakSelf.editPositionLink = nil;
            [weakSelf positionEditButton];
        }
    };
    if (animator) [animator addCompletion:finishPositioning];
    else dispatch_async(dispatch_get_main_queue(), finishPositioning);
    // UIKit handles the entrance; a second parent scale competes with its bloom.
    self.menuContainer.alpha = 1;
    self.menuContainer.transform = CGAffineTransformIdentity;
    [UIView animateWithDuration:0.22 delay:0
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:^{ backdrop.alpha = 1; } completion:nil];
    ApolloSettingsMenuHaptic();
    ApolloLog(@"[SettingsTabMenu] Presented native shortcuts");
}
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction willEndForConfiguration:(UIContextMenuConfiguration *)configuration animator:(id<UIContextMenuInteractionAnimating>)animator {
    [self.editPositionLink invalidate];
    self.editPositionLink = nil;
    UIButton *edit = self.editButton;
    edit.userInteractionEnabled = NO;
    self.editButton = nil;
    [UIView animateWithDuration:0.18 animations:^{ edit.alpha = 0; } completion:^(__unused BOOL finished) { [edit removeFromSuperview]; }];
    UIView *handoffSurface = self.dismissSurface;
    ((ApolloSettingsDismissSurface *)handoffSurface).menuContainer = nil;
    self.dismissSurface = nil;
    if (!self.pendingAction) [handoffSurface removeFromSuperview];
    UIView *backdrop = self.backdrop;
    UIView *menuContainer = self.menuContainer;
    UIView *anchor = self.anchor;
    // Stop intercepting the next touch as soon as dismissal begins. A touch
    // that starts on the fading overlay never reaches the tab's recognizer,
    // even if the overlay disappears before that hold finishes.
    backdrop.userInteractionEnabled = NO;
    menuContainer.userInteractionEnabled = NO;
    anchor.userInteractionEnabled = NO;
    menuContainer.accessibilityViewIsModal = NO;
    self.backdrop = nil;
    self.menuContainer = nil;
    self.menuLayoutContainer = nil;
    self.anchor = nil;
    self.interaction = nil;
    self.animatingDismissal = NO;
    // Outside taps have already animated the live menu. For a selection,
    // UIKit owns dismissal while the destination begins its navigation push.
    backdrop.alpha = 0;
    // Start navigation on the next main-loop turn, after UIKit has processed
    // selection, rather than waiting for its potentially long platter animation.
    void (^action)(void) = self.pendingAction;
    self.pendingAction = nil;
    if (action) dispatch_async(dispatch_get_main_queue(), ^{
        action();
        // The page transition has installed its own shield before this one
        // leaves, so there is no hit-testing gap between menu and navigation.
        [handoffSurface removeFromSuperview];
    });
    void (^finish)(void) = ^{
        // Cleanup belongs only to this outgoing presentation; never a reopened menu.
        [backdrop removeFromSuperview];
        [menuContainer removeFromSuperview];
        [anchor removeFromSuperview];
    };
    if (animator) [animator addCompletion:finish];
    else finish();
}
@end

static char kApolloSettingsTabHold;
%hook _TtC6Apollo22ApolloTabBarController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    // Close the anchored menu before the bar moves; the next hold computes
    // fresh geometry, including landscape safe areas and the current tab position.
    ApolloSettingsTabHold *hold = objc_getAssociatedObject(self, &kApolloSettingsTabHold);
    [hold.interaction dismissMenu];
    %orig(size, coordinator);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UITabBarController *controller = (UITabBarController *)self;
    ApolloLog(@"[SettingsTabMenu] Installing hold on %@", controller.tabBar);
    ApolloSettingsTabHold *hold = objc_getAssociatedObject(self, &kApolloSettingsTabHold);
    if (!hold) {
        hold = [ApolloSettingsTabHold new];
        hold.controller = controller;
        hold.gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:hold action:@selector(held:)];
        hold.gesture.minimumPressDuration = 0.5;
        hold.gesture.delegate = hold;
        objc_setAssociatedObject(self, &kApolloSettingsTabHold, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hold.gesture.view != controller.tabBar) [controller.tabBar addGestureRecognizer:hold.gesture];
}
%end

// Veto the release before Apollo's delegate can switch tabs or pop an already
// selected Settings stack. Ordinary taps and intentional menu navigation pass.
%hook _TtC6Apollo13SceneDelegate
- (BOOL)tabBarController:(UITabBarController *)controller shouldSelectViewController:(UIViewController *)viewController {
    UIViewController *root = [viewController isKindOfClass:UINavigationController.class]
        ? ((UINavigationController *)viewController).viewControllers.firstObject : viewController;
    if ([objc_getAssociatedObject(controller, &kApolloSettingsHoldConsumedTouch) boolValue]
        && [NSStringFromClass(root.class) containsString:@"SettingsViewController"]) {
        ApolloLog(@"[SettingsTabMenu] Consumed hold release without selecting Settings");
        return NO;
    }
    if (ApolloHandleShortcutTabReselection(controller, viewController)) return NO;
    return %orig(controller, viewController);
}
%end

// Use the actual Settings row factory for storyboard/Swift-native destinations.
// Capturing the synchronous push avoids switching to Settings first, and keeps
// all native initializer arguments and row-specific setup intact.
static UINavigationController *sShortcutCaptureNavigation;
static UIViewController *sShortcutCapturedScreen;

static UIViewController *ApolloFindNativeSettingsRoot(UIViewController *controller) {
    if ([controller isKindOfClass:NSClassFromString(@"_TtC6Apollo22SettingsViewController")]) return controller;
    NSArray *children = [controller isKindOfClass:UITabBarController.class] ? ((UITabBarController *)controller).viewControllers
        : [controller isKindOfClass:UINavigationController.class] ? ((UINavigationController *)controller).viewControllers : controller.childViewControllers;
    for (UIViewController *child in children) {
        UIViewController *found = ApolloFindNativeSettingsRoot(child);
        if (found) return found;
    }
    return nil;
}
static UITableViewCell *ApolloNativeSettingsRow(NSString *title, UIViewController **owner, UITableView **sourceTable, NSIndexPath **path) {
    for (UIWindow *window in ApolloAllWindows()) {
        UIViewController *root = ApolloFindNativeSettingsRoot(window.rootViewController);
        if (!root) continue;
        [root loadViewIfNeeded];
        Ivar tableIvar = class_getInstanceVariable(root.class, "tableView");
        UITableView *table = tableIvar ? object_getIvar(root, tableIvar) : nil;
        if (![table isKindOfClass:UITableView.class]) continue;
        id<UITableViewDataSource> dataSource = table.dataSource;
        NSInteger sections = [dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)] ? [dataSource numberOfSectionsInTableView:table] : 1;
        for (NSInteger section = 0; section < sections; section++) {
            for (NSInteger row = 0; row < [dataSource tableView:table numberOfRowsInSection:section]; row++) {
                NSIndexPath *index = [NSIndexPath indexPathForRow:row inSection:section];
                UITableViewCell *cell = [dataSource tableView:table cellForRowAtIndexPath:index];
                if ([cell.textLabel.text isEqualToString:title]) {
                    if (owner) *owner = root;
                    if (sourceTable) *sourceTable = table;
                    if (path) *path = index;
                    return cell;
                }
            }
        }
    }
    return nil;
}
UIImage *ApolloSettingsNativeShortcutImage(NSString *title) {
    return ApolloNativeSettingsRow(title, NULL, NULL, NULL).imageView.image;
}
UIViewController *ApolloSettingsNativeShortcutScreen(NSString *title) {
    UIViewController *root = nil;
    UITableView *table = nil;
    NSIndexPath *path = nil;
    if (!ApolloNativeSettingsRow(title, &root, &table, &path) || !root.navigationController) return nil;
    sShortcutCaptureNavigation = root.navigationController;
    sShortcutCapturedScreen = nil;
    @try {
        [table.delegate tableView:table didSelectRowAtIndexPath:path];
    } @finally {
        sShortcutCaptureNavigation = nil;
    }
    UIViewController *screen = sShortcutCapturedScreen;
    sShortcutCapturedScreen = nil;
    return screen;
}
%hook _TtC6Apollo26ApolloNavigationController
- (void)pushViewController:(UIViewController *)screen animated:(BOOL)animated {
    if ((id)self == sShortcutCaptureNavigation) {
        sShortcutCapturedScreen = screen;
        return;
    }
    %orig(screen, animated);
}
%end
