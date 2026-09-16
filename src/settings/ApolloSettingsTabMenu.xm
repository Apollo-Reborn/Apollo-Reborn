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

static void ApolloPushSettingsShortcut(UITabBarController *controller, UIViewController *screen) {
    if (!controller) return;
    ApolloClearConsumedSettingsTouch(controller);
    // Push from the visible page so UIKit can perform its normal transition
    // without first revealing the Settings root underneath the destination.
    UIViewController *selected = controller.selectedViewController;
    UINavigationController *nav = [selected isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)selected : selected.navigationController;
    if (!nav) return;

    // Reuse a destination already in this navigation stack.
    UIViewController *destination = screen;
    for (UIViewController *existing in nav.viewControllers) {
        if ([existing isMemberOfClass:screen.class]) {
            destination = existing;
            break;
        }
    }
    if (nav.topViewController == destination) return;
    // Disabling the tab bar alone lets hit testing fall through to the page.
    // Consume touches at the window until the navigation transition finishes.
    UIWindow *window = controller.view.window;
    UIView *transitionShield = [[UIView alloc] initWithFrame:window.bounds];
    transitionShield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    transitionShield.accessibilityElementsHidden = YES;
    [window addSubview:transitionShield];
    if (destination != screen) {
        if (nav.topViewController != destination) [nav popToViewController:destination animated:YES];
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
@end
@implementation ApolloSettingsDismissSurface
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
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
@end
@implementation ApolloSettingsTabHold
- (void)prepareMenuImages {
    UITabBarController *controller = self.controller;
    UITraitCollection *traits = controller.traitCollection;
    if (self.menuImages && ![traits hasDifferentColorAppearanceComparedToTraitCollection:self.imageTraits]
        && traits.displayScale == self.imageTraits.displayScale) return;
    UIImage *backupTile = ApolloSettingsIconTileImage(@"square.and.arrow.up.fill", UIColor.systemBlueColor, controller.traitCollection);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(36, 36)];
    UIImage *backupImage = [[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [backupTile drawInRect:CGRectMake(0, 0, 36, 36)];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *categoriesTile = ApolloSettingsIconTileImage(@"apollo.saved-categories", UIColor.systemGreenColor, controller.traitCollection);
    UIImage *categoriesImage = [[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [categoriesTile drawInRect:CGRectMake(0, 0, 36, 36)];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *themeTile = ApolloSettingsIconTileImage(@"paintbrush.fill", ApolloThemeManagerIconColor(), controller.traitCollection);
    UIImage *themeImage = [[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [themeTile drawInRect:CGRectMake(0, 0, 36, 36)];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    self.menuImages = @{@"backup": backupImage, @"categories": categoriesImage, @"themes": themeImage,
        @"requests": ApolloEmojiSettingsIcon(@"💡", UIColor.systemYellowColor, 36),
        @"bugs": ApolloEmojiSettingsIcon(@"🐛", UIColor.systemRedColor, 36)};
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
        UIAction *backup = [UIAction actionWithTitle:@"Backup Settings"
            image:images[@"backup"]
            identifier:nil handler:^(__unused UIAction *action) {
                ApolloSettingsMenuHaptic();
                weakSelf.pendingAction = ^{
                    ApolloPushSettingsShortcut(weakController, [[ApolloAutomaticBackupViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]);
                };
            }];
        UIAction *requests = [UIAction actionWithTitle:@"Feature Requests"
            image:images[@"requests"]
            identifier:nil handler:^(__unused UIAction *action) {
                ApolloSettingsMenuHaptic();
                weakSelf.pendingAction = ^{
                    UIViewController *selected = weakController.selectedViewController;
                    UIViewController *presenter = [selected isKindOfClass:UINavigationController.class]
                        ? ((UINavigationController *)selected).topViewController : selected;
                    if (presenter) ApolloPresentWebURLFromViewController(presenter, [NSURL URLWithString:@"https://apolloreborn.fider.io/"]);
                };
            }];
        UIAction *bugs = [UIAction actionWithTitle:@"Bug Reports"
            image:images[@"bugs"]
            identifier:nil handler:^(__unused UIAction *action) {
                ApolloSettingsMenuHaptic();
                weakSelf.pendingAction = ^{
                    ApolloPushSettingsShortcut(weakController, [[ApolloReportViewController alloc] init]);
                };
            }];
        UIAction *categories = [UIAction actionWithTitle:@"Saved Categories"
            image:images[@"categories"] identifier:nil handler:^(__unused UIAction *action) {
                ApolloSettingsMenuHaptic();
                weakSelf.pendingAction = ^{
                    ApolloPushSettingsShortcut(weakController, [[SavedCategoriesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped]);
                };
            }];
        UIAction *themes = [UIAction actionWithTitle:@"Theme Manager"
            image:images[@"themes"] identifier:nil handler:^(__unused UIAction *action) {
                ApolloSettingsMenuHaptic();
                weakSelf.pendingAction = ^{
                    ApolloPushSettingsShortcut(weakController, [[ApolloThemeManagerViewController alloc] init]);
                };
            }];
        NSMutableArray<UIMenu *> *groups = [NSMutableArray array];
        for (UIAction *action in @[themes, categories, backup, requests, bugs]) {
            UIMenu *group = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                options:UIMenuOptionsDisplayInline children:@[action]];
            if (@available(iOS 16.0, *)) group.preferredElementSize = UIMenuElementSizeLarge;
            [groups addObject:group];
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
        ((void (*)(id, SEL, id))objc_msgSend)(style, containerSetter, self.menuContainer);
    }
    return style;
}
- (void)dismissFromBackdrop:(UITapGestureRecognizer *)gesture {
    if (self.animatingDismissal || !self.interaction) return;
    self.animatingDismissal = YES;
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
    return %orig(controller, viewController);
}
%end
