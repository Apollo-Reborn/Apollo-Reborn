// Inbox-only presentation. Apollo remains the sole owner of unread state.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

static char kInboxBadgeDotViewKey;
static NSHashTable<UITabBarController *> *sInboxBadgeControllers;
static BOOL sInboxBadgeApplying;
static void ApolloInboxBadgeCollectViews(UIView *root, Class cls, NSMutableArray<UIView *> *result);

static void ApolloInboxBadgeCollectViews(UIView *root, Class cls, NSMutableArray<UIView *> *result) {
    if (!cls) return;
    for (UIView *view in root.subviews) {
        if ([view isKindOfClass:cls]) {
            [result addObject:view];
        } else {
            ApolloInboxBadgeCollectViews(view, cls, result);
        }
    }
}

static UIImageView *ApolloInboxBadgeIconView(UIView *root) {
    UIImageView *fallback = nil;

    for (UIView *view in root.subviews) {
        if ([view isKindOfClass:NSClassFromString(@"_UIBadgeView")]) continue;
        if ([view isKindOfClass:UIImageView.class]) {
            UIImageView *imageView = (UIImageView *)view;
            if (imageView.image) return imageView;
            fallback = imageView;
        }

        UIImageView *nested = ApolloInboxBadgeIconView(view);
        if (nested) return nested;
    }

    return fallback;
}

static void ApolloInboxBadgePositionCustomDot(UIView *button, UIView *icon) {
    UIView *dot = objc_getAssociatedObject(button, &kInboxBadgeDotViewKey);
    if (!dot || !icon) return;

    CGRect iconFrame = [button convertRect:icon.bounds fromView:icon];

    // Keep the dot anchored to the icon as the tab layout changes.
    dot.frame = CGRectMake(CGRectGetMaxX(iconFrame) - 4.0,
                           CGRectGetMinY(iconFrame) - 4.0,
                           8.0,
                           8.0);
}

static void ApolloInboxBadgeSetCustomDot(UIView *button,
                                         UIView *icon,
                                         BOOL visible,
                                         UIColor *color) {
    UIView *dot = objc_getAssociatedObject(button, &kInboxBadgeDotViewKey);

    if (!visible || !icon) {
        dot.hidden = YES;
        return;
    }

    if (!dot) {
        dot = [[UIView alloc] initWithFrame:CGRectZero];
        dot.userInteractionEnabled = NO;
        dot.layer.cornerRadius = 4.0;
        dot.layer.zPosition = 1000.0;
        objc_setAssociatedObject(button,
                                 &kInboxBadgeDotViewKey,
                                 dot,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button addSubview:dot];
    }

    ApolloInboxBadgePositionCustomDot(button, icon);
    dot.backgroundColor = color;
    dot.hidden = NO;
    [button bringSubviewToFront:dot];
}

static void ApolloInboxBadgeSetGlassDot(UITabBar *tabBar,
                                        UIView *icon,
                                        BOOL visible,
                                        UIColor *color) {
    UIView *dot = objc_getAssociatedObject(tabBar, &kInboxBadgeDotViewKey);

    if (!visible || !icon) {
        dot.hidden = YES;
        return;
    }

    if (!dot) {
        dot = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 8.0, 8.0)];
        dot.userInteractionEnabled = NO;
        dot.layer.cornerRadius = 4.0;
        dot.layer.zPosition = 1000.0;
        objc_setAssociatedObject(tabBar,
                                 &kInboxBadgeDotViewKey,
                                 dot,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [tabBar addSubview:dot];
    }

    CGRect iconFrame = [tabBar convertRect:icon.bounds fromView:icon];

    // Follow the icon itself so the dot moves with Apollo's label setting.
    dot.center = CGPointMake(CGRectGetMaxX(iconFrame),
                             CGRectGetMinY(iconFrame));
    dot.backgroundColor = color;
    dot.hidden = NO;
    [tabBar bringSubviewToFront:dot];
}

static CGFloat ApolloInboxBadgePerceptualLightness(UIColor *color) {
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        return 0.0;
    }

    CGFloat (^linearize)(CGFloat) = ^CGFloat(CGFloat component) {
        return component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4);
    };

    r = linearize(r);
    g = linearize(g);
    b = linearize(b);

    CGFloat l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    CGFloat m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    CGFloat s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    CGFloat lRoot = cbrt(l);
    CGFloat mRoot = cbrt(m);
    CGFloat sRoot = cbrt(s);

    return 0.2104542553 * lRoot
         + 0.7936177850 * mRoot
         - 0.0040720468 * sRoot;
}

static UIColor *ApolloInboxBadgeTextColor(UIColor *backgroundColor) {
    return ApolloInboxBadgePerceptualLightness(backgroundColor) >= 0.65
        ? UIColor.blackColor
        : UIColor.whiteColor;
}

static void ApolloInboxBadgeApply(UITabBarController *controller) {
    UITabBar *tabBar = controller.tabBar;
    if (tabBar.items.count < 2) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

    UITabBarItem *inbox = tabBar.items[1];
    // nil selects UIKit's native red. Use the public item API so number mode
    // keeps its native background rendering, geometry, and label untouched.
    UIColor *color = [defaults boolForKey:UDKeyInboxBadgeUseThemeAccent]
        ? [(ApolloThemeAccentColor() ?: tabBar.tintColor) resolvedColorWithTraitCollection:tabBar.traitCollection]
        : nil;
    if (inbox.badgeColor != color && ![inbox.badgeColor isEqual:color]) {
        sInboxBadgeApplying = YES;
        inbox.badgeColor = color;
        sInboxBadgeApplying = NO;
    }

    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    ApolloInboxBadgeCollectViews(tabBar, NSClassFromString(@"UITabBarButton"), buttons);

    // Liquid Glass uses _UITabButton rather than UITabBarButton. Preserve
    // UIKit's native badge geometry in numbered mode; in dot mode, hide the
    // native badge and anchor an 8pt dot to the Inbox icon.
    if (IsLiquidGlass()) {
        BOOL dotMode =
            ![defaults boolForKey:UDKeyInboxBadgeShowUnreadCount];

        UIColor *renderedColor =
            color ?: [UIColor colorWithRed:1.0
                                    green:0.231
                                    blue:0.188
                                    alpha:1.0];

        // Badge colour is a tab-bar presentation choice, so keep every
        // Liquid Glass badge visually consistent.
        NSMutableArray<UIView *> *glassBadges = [NSMutableArray array];
        ApolloInboxBadgeCollectViews(tabBar,
                                     NSClassFromString(@"_UIBarBadgeView"),
                                     glassBadges);

        for (UIView *badge in glassBadges) {
            badge.backgroundColor = renderedColor;
            badge.tintColor = renderedColor;
            badge.layer.backgroundColor = renderedColor.CGColor;

            if (color && !dotMode) {
                UIColor *textColor =
                    ApolloInboxBadgeTextColor(renderedColor);
                NSMutableArray<UIView *> *labels = [NSMutableArray array];
                ApolloInboxBadgeCollectViews(badge, UILabel.class, labels);
                for (UILabel *label in labels) {
                    ApolloThemeRuntimePerformTextSinkBypass(^{
                        label.textColor = textColor;
                    });
                }
            }
        }

        // Liquid Glass exposes two _UITabButton representations for each
        // tab. Sort them by visual position; the first two entries at the
        // second position are Inbox, and either has the same icon geometry.
        NSMutableArray<UIView *> *glassButtons = [NSMutableArray array];
        ApolloInboxBadgeCollectViews(tabBar,
                                     NSClassFromString(@"_UITabButton"),
                                     glassButtons);

        BOOL rtl =
            tabBar.effectiveUserInterfaceLayoutDirection ==
            UIUserInterfaceLayoutDirectionRightToLeft;

        [glassButtons sortUsingComparator:^NSComparisonResult(UIView *a,
                                                               UIView *b) {
            CGFloat ax = CGRectGetMidX([a convertRect:a.bounds toView:tabBar]);
            CGFloat bx = CGRectGetMidX([b convertRect:b.bounds toView:tabBar]);
            if (ax == bx) return NSOrderedSame;
            return (ax < bx) != rtl
                ? NSOrderedAscending
                : NSOrderedDescending;
        }];

        UIView *inboxIcon = nil;
        if (glassButtons.count >= tabBar.items.count * 2) {
            // Two representations share each horizontal position, so
            // indices 2 and 3 correspond to the second tab (Inbox).
            UIView *inboxButton = glassButtons[2];
            NSMutableArray<UIView *> *images = [NSMutableArray array];
            ApolloInboxBadgeCollectViews(inboxButton,
                                         UIImageView.class,
                                         images);
            inboxIcon = images.firstObject;
        }

        BOOL hasUnreadBadge = glassBadges.count > 0;
        BOOL showDot = dotMode && hasUnreadBadge && inboxIcon != nil;

        ApolloInboxBadgeSetGlassDot(tabBar,
                                    inboxIcon,
                                    showDot,
                                    renderedColor);

        // Hide UIKit's native badge only while the replacement dot is shown.
        // Explicitly restore it when returning to numbered mode.
        for (UIView *badge in glassBadges) {
            badge.hidden = showDot;
        }

        return;
    }

    // Classic fails closed if UIKit presents an unexpected hierarchy.
    if (buttons.count != tabBar.items.count) return;

    BOOL rtl = tabBar.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = CGRectGetMidX([a convertRect:a.bounds toView:tabBar]);
        CGFloat bx = CGRectGetMidX([b convertRect:b.bounds toView:tabBar]);
        if (ax == bx) return NSOrderedSame;
        return (ax < bx) != rtl ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSMutableArray<UIView *> *badges = [NSMutableArray array];
    ApolloInboxBadgeCollectViews(buttons[1], NSClassFromString(@"_UIBadgeView"), badges);

    BOOL dotMode = ![defaults boolForKey:UDKeyInboxBadgeShowUnreadCount];
    UIColor *renderedColor =
        color ?: [UIColor colorWithRed:1.0
                                green:0.231
                                blue:0.188
                                alpha:1.0];
    UIImageView *icon = ApolloInboxBadgeIconView(buttons[1]);

    for (UIView *badge in badges) {
        // Number mode keeps UIKit's native badge geometry. When using the theme
        // accent, choose black or white text to remain readable over the fill.
        badge.backgroundColor = renderedColor;
        badge.tintColor = renderedColor;
        badge.layer.backgroundColor = renderedColor.CGColor;

        if (color && !dotMode) {
            NSMutableArray<UIView *> *labels = [NSMutableArray array];
            ApolloInboxBadgeCollectViews(badge, UILabel.class, labels);
            UIColor *textColor = ApolloInboxBadgeTextColor(renderedColor);
            for (UILabel *label in labels) {
                ApolloThemeRuntimePerformTextSinkBypass(^{
                    label.textColor = textColor;
                });
            }
        }

        // Fail safe: if UIKit changes its icon hierarchy, leave the native
        // badge visible rather than hiding it without a replacement dot.
        badge.hidden = dotMode && icon != nil;
    }

    BOOL hasUnreadBadge = badges.count > 0;

    ApolloInboxBadgeSetCustomDot(buttons[1],
                                icon,
                                dotMode && hasUnreadBadge,
                                renderedColor);
}

static UITabBarController *ApolloInboxBadgeOwnerOfTabBar(UITabBar *tabBar) {
    UIResponder *responder = tabBar.nextResponder;
    while (responder) {
        if ([responder isKindOfClass:UITabBarController.class]) {
            return (UITabBarController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

// ApolloTabBarController is Swift, so its runtime name is the mangled class
// name below. Hooking the unmangled spelling silently matches nothing.
%hook _TtC6Apollo22ApolloTabBarController

- (void)viewDidLoad {
    %orig;
    [sInboxBadgeControllers addObject:(UITabBarController *)self];
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloInboxBadgeApply((UITabBarController *)self);
    // Theme changes can rebuild the badge after this layout callback returns.
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloInboxBadgeApply((UITabBarController *)self);
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Stock theme changes can finish after the theme notification. Reapply
    // when Apollo presents the tab controller with its final themed views.
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloInboxBadgeApply((UITabBarController *)self);
    });
}

%end

%hook UITabBarButton

- (void)layoutSubviews {
    %orig;

    BOOL isInboxButton = NO;
    for (UITabBarController *controller in sInboxBadgeControllers) {
        if (controller.tabBar.items.count > 1 &&
            [controller.tabBar.subviews containsObject:(UIView *)self]) {
            NSMutableArray *buttons = [NSMutableArray array];
            ApolloInboxBadgeCollectViews(controller.tabBar, NSClassFromString(@"UITabBarButton"), buttons);
            isInboxButton = buttons.count > 1 && buttons[1] == (UIView *)self;
            break;
        }
    }

    if (isInboxButton) {
        UIView *button = (UIView *)self;
        UIImageView *icon = ApolloInboxBadgeIconView(button);
        ApolloInboxBadgePositionCustomDot(button, icon);
    }
}

%end

// Apollo replaces the tab items while applying a stock theme. Reapply after
// that replacement so the new item receives the user's badge configuration.
%hook UITabBar

- (void)setItems:(NSArray<UITabBarItem *> *)items animated:(BOOL)animated {
    %orig;
    UITabBarController *controller = ApolloInboxBadgeOwnerOfTabBar(self);
    if (!controller) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloInboxBadgeApply(controller);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloInboxBadgeApply(controller);
        });
    });
}

%end

// Apollo changes Inbox unread state by updating the tab item's badgeValue.
// Refresh after UIKit has created or removed the corresponding badge view.
%hook UITabBarItem

- (void)setBadgeValue:(NSString *)badgeValue {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UITabBarController *controller in sInboxBadgeControllers) {
            if (controller.tabBar.items.count > 1) {
                [controller.tabBar layoutIfNeeded];
                ApolloInboxBadgeApply(controller);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [controller.tabBar layoutIfNeeded];
                    ApolloInboxBadgeApply(controller);
                });
            }
        }
    });
}

- (void)setBadgeColor:(UIColor *)badgeColor {
    %orig;
    if (sInboxBadgeApplying) return;
    // Theme code may set the item color before the replacement item is put in
    // the tab bar. Refresh all tracked controllers after that transaction.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UITabBarController *controller in sInboxBadgeControllers) {
            ApolloInboxBadgeApply(controller);
        }
    });
}

%end

// UIKit can replace the native badge while Apollo applies a theme. Reapply
// after a newly created badge joins the window so the user's presentation wins.
%hook _UIBarBadgeView

- (void)layoutSubviews {
    %orig;

    if (!IsLiquidGlass() || !((UIView *)self).window) return;

    // Liquid Glass maintains normal and selected-content copies of tab items.
    // UIKit can restyle the selected badge during its layout transition, so
    // reapply the Inbox presentation immediately after that layout pass.
    for (UITabBarController *controller in sInboxBadgeControllers) {
        if ([(UIView *)self isDescendantOfView:controller.tabBar]) {
            ApolloInboxBadgeApply(controller);
            break;
        }
    }
}

%end

%hook _UIBadgeView

- (void)didMoveToWindow {
    %orig;

    UIView *view = (UIView *)self;
    if (!view.window) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        for (UITabBarController *controller in sInboxBadgeControllers) {
            ApolloInboxBadgeApply(controller);
        }
    });
}

%end

%ctor {
    sInboxBadgeControllers = [NSHashTable weakObjectsHashTable];
    for (NSString *name in @[ApolloInboxBadgeChangedNotification,
                             ApolloTabBarTitlesChangedNotification,
                             @"com.christianselig.ApolloSpecificThemeChanged"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            // Let Apollo finish any native theme updates before refreshing.
            dispatch_async(dispatch_get_main_queue(), ^{
                for (UITabBarController *controller in sInboxBadgeControllers) {
                    [controller.tabBar layoutIfNeeded];
                    ApolloInboxBadgeApply(controller);
                }
                // Apollo may rebuild the tab bar after the theme notification;
                // apply once more after that rebuild has settled.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    for (UITabBarController *controller in sInboxBadgeControllers) {
                        [controller.tabBar layoutIfNeeded];
                        ApolloInboxBadgeApply(controller);
                    }
                });
            });
        }];
    }
}
