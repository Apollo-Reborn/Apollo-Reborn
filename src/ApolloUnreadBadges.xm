#import "ApolloUnreadBadges.h"

#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

NSString *const ApolloUnreadBadgeStyleDidChangeNotification = @"ApolloUnreadBadgeStyleDidChangeNotification";

// Set on an item once this module has written its badge color (or spoken
// value), so turning the options back off clears exactly what was written and
// an item it never touched keeps UIKit's untouched state.
static char kApolloUnreadBadgeColorStyledKey;
static char kApolloUnreadBadgeSpokenValueKey;
// The count behind a dot (ApolloUnreadBadgeCountValue).
static char kApolloUnreadBadgeCountKey;

static void ApolloUnreadBadgesStore(BOOL *global, NSString *key, BOOL enabled) {
    if (*global == enabled) return;
    *global = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:key];
    ApolloLog(@"[UnreadBadges] %@ -> %@", key, enabled ? @"on" : @"off");
    [NSNotificationCenter.defaultCenter postNotificationName:ApolloUnreadBadgeStyleDidChangeNotification
                                                      object:nil];
}

void ApolloUnreadBadgesSetCompactTabBar(BOOL enabled) {
    ApolloUnreadBadgesStore(&sUnreadBadgeCompactTabBar, UDKeyUnreadBadgeCompactTabBar, enabled);
}

void ApolloUnreadBadgesSetCompactInbox(BOOL enabled) {
    ApolloUnreadBadgesStore(&sUnreadBadgeCompactInbox, UDKeyUnreadBadgeCompactInbox, enabled);
}

void ApolloUnreadBadgesSetThemeColor(BOOL enabled) {
    ApolloUnreadBadgesStore(&sUnreadBadgeThemeColor, UDKeyUnreadBadgeThemeColor, enabled);
}

UIColor *ApolloUnreadBadgeFillColor(void) {
    if (sUnreadBadgeThemeColor) {
        // Custom theme accent when one is active, else the stock theme's.
        UIColor *accent = ApolloThemeAccentColor();
        if (accent) return accent;
    }
    return UIColor.systemRedColor;
}

UIColor *ApolloUnreadBadgeTextColor(void) {
    if (!sUnreadBadgeThemeColor) return UIColor.whiteColor;
    // Stock Monochromatic (dark) and Chumbus (light) accents are near-white,
    // so the text color has to follow the fill per appearance. Resolve the fill
    // with the badge's own traits: ApolloColorIsLight reads raw components.
    UIColor *fill = ApolloUnreadBadgeFillColor();
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return ApolloColorIsLight([fill resolvedColorWithTraitCollection:traits])
            ? UIColor.blackColor : UIColor.whiteColor;
    }];
}

NSString *ApolloUnreadBadgeTabBarDisplayValue(NSString *value) {
    if (!sUnreadBadgeCompactTabBar || value.length == 0) return value;
    // An empty string keeps UIKit's badge (nil would remove it) but with no
    // text; ApolloUnreadBadgeUpdateDotMask then trims that blank badge to the
    // dot whenever UIKit lays it out.
    return @"";
}

void ApolloUnreadBadgeStyleTabBarItem(UITabBarItem *item, NSString *countValue) {
    if (!item) return;

    // The item-level badge color is what a tab bar without a UITabBarAppearance
    // uses. Apollo's bars have one, which wins over it, so here it mostly acts
    // as the nudge that makes UIKit re-push the badge's appearance through the
    // _UIBadgeView / _UIBarBadgeView setters below, where Theme Color applies.
    BOOL colorStyled = [objc_getAssociatedObject(item, &kApolloUnreadBadgeColorStyledKey) boolValue];
    if (sUnreadBadgeThemeColor) {
        item.badgeColor = ApolloUnreadBadgeFillColor();
        NSDictionary *attributes = @{ NSForegroundColorAttributeName: ApolloUnreadBadgeTextColor() };
        [item setBadgeTextAttributes:attributes forState:UIControlStateNormal];
        [item setBadgeTextAttributes:attributes forState:UIControlStateSelected];
        if (!colorStyled) {
            objc_setAssociatedObject(item, &kApolloUnreadBadgeColorStyledKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } else if (colorStyled) {
        // Back to UIKit's default red badge with white text.
        item.badgeColor = nil;
        [item setBadgeTextAttributes:nil forState:UIControlStateNormal];
        [item setBadgeTextAttributes:nil forState:UIControlStateSelected];
        objc_setAssociatedObject(item, &kApolloUnreadBadgeColorStyledKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(item, &kApolloUnreadBadgeCountKey,
                             sUnreadBadgeCompactTabBar ? countValue : nil, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // The dot drops the number from the screen, not from VoiceOver: speak the
    // count the badge would have shown. Only a value this module wrote is ever
    // cleared again, so Apollo's own accessibility value (none today) survives.
    NSString *spoken = nil;
    if (sUnreadBadgeCompactTabBar && countValue.length > 0) {
        NSInteger count = countValue.integerValue;
        spoken = count > 0 ? [NSString stringWithFormat:@"%@ unread", countValue] : @"Unread";
    }
    NSString *written = objc_getAssociatedObject(item, &kApolloUnreadBadgeSpokenValueKey);
    if (spoken) {
        if (![item.accessibilityValue isEqualToString:spoken]) item.accessibilityValue = spoken;
        objc_setAssociatedObject(item, &kApolloUnreadBadgeSpokenValueKey, spoken,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    } else if (written) {
        if ([item.accessibilityValue isEqualToString:written]) item.accessibilityValue = nil;
        objc_setAssociatedObject(item, &kApolloUnreadBadgeSpokenValueKey, nil,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

NSString *ApolloUnreadBadgeCountValue(UITabBarItem *item) {
    NSString *shown = item.badgeValue;
    if (shown && shown.length == 0) {
        NSString *count = objc_getAssociatedObject(item, &kApolloUnreadBadgeCountKey);
        if (count.length > 0) return count;
    }
    return shown;
}

#pragma mark - Tab bar dot

// UIKit draws an empty badge as a blank circle the size of a one-digit count
// (18pt), not a dot. Rather than place a view of our own next to every copy
// of the Inbox tab (iOS 26 keeps badges inside each _UITabButton, iOS 27 in
// the platter's badge container, Classic inside UITabBarButton, plus the Duo
// rail), the blank badge itself is masked down to a dot from its own
// -layoutSubviews. UIKit still owns where it is, when it shows, and its fill
// (red, or the theme accent swapped in below); the mask only trims it.
static const CGFloat kApolloUnreadTabDotSize = 10.0;
static NSString *const kApolloUnreadDotMaskName = @"ApolloUnreadBadgeDot";

static void ApolloUnreadBadgeUpdateDotMask(UIView *badge) {
    CALayer *mask = badge.layer.mask;
    BOOL ours = [mask.name isEqualToString:kApolloUnreadDotMaskName];
    if (!sUnreadBadgeCompactTabBar && !ours) return;   // main's path: nothing to do

    // Only the blank badge ApolloUnreadBadgeTabBarDisplayValue produced; a
    // count badge (any tab, or compact turned off) gets its full shape back.
    NSString *text = [badge respondsToSelector:@selector(text)]
        ? ((NSString *(*)(id, SEL))objc_msgSend)(badge, @selector(text)) : nil;
    BOOL wantsDot = sUnreadBadgeCompactTabBar && text.length == 0 &&
        CGRectGetHeight(badge.bounds) > kApolloUnreadTabDotSize;
    if (!wantsDot) {
        if (ours) badge.layer.mask = nil;
        return;
    }
    if (mask && !ours) return;   // UIKit's own mask: leave the badge alone

    // The count badge overlaps the icon's top-trailing corner by a different
    // amount on each layout (iOS 26 vs 27 Liquid Glass, Classic, the Duo rail,
    // labeled vs icon-only tabs), so the dot takes the part of the badge
    // farthest from the icon: its top-trailing edge along the diagonal. It then
    // sits just outside the icon's corner without touching the glyph, which
    // also keeps a Theme Color dot from merging into a selected, accent-tinted
    // icon. The badge clips to its own circle, so the dot stays inside it (half
    // a point short of the edge, where UIKit's continuous corner runs inside a
    // true circle), which also means it never reaches past the count badge.
    CGRect bounds = badge.bounds;
    BOOL rtl = badge.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat inset = MAX(0.0, MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds)) / 2.0 -
                             kApolloUnreadTabDotSize / 2.0 - 0.5) / M_SQRT2;
    CGPoint center = CGPointMake(CGRectGetMidX(bounds) + (rtl ? -inset : inset), CGRectGetMidY(bounds) - inset);
    CGRect dot = CGRectMake(center.x - kApolloUnreadTabDotSize / 2.0, center.y - kApolloUnreadTabDotSize / 2.0,
                            kApolloUnreadTabDotSize, kApolloUnreadTabDotSize);
    CAShapeLayer *shape = ours ? (CAShapeLayer *)mask : [CAShapeLayer layer];
    if (!ours) {
        shape.name = kApolloUnreadDotMaskName;
        badge.layer.mask = shape;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shape.frame = bounds;
    shape.path = [UIBezierPath bezierPathWithOvalInRect:dot].CGPath;
    [CATransaction commit];
}

// Whether a badge view is a tab's. Classic _UIBadgeView is also UIKit's
// table-cell badge, so it must sit in a UITabBarButton. _UIBarBadgeView only
// badges bar items, and Apollo only ever badges its Inbox tab.
static BOOL ApolloUnreadBadgeViewIsTabBadge(UIView *badge, BOOL classic) {
    if (!classic) return YES;
    static Class tabBarButton;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tabBarButton = NSClassFromString(@"UITabBarButton"); });
    return tabBarButton && [badge.superview isKindOfClass:tabBarButton];
}

// Theme Color. Both tab bars ignore UITabBarItem.badgeColor and badge text
// attributes once the bar has a UITabBarAppearance (Apollo sets one): Classic
// UITabBarButton and Liquid Glass _UITabButton read the appearance's
// badgeBackgroundColor (system red) and badge text attributes and push them
// into the badge view each time they reapply it, which setting
// item.badgeColor triggers (ApolloUnreadBadgeStyleTabBarItem). So the theme
// color is swapped in here, at the badge view; with it off this passes through.
static UIColor *ApolloUnreadBadgeThemedFill(UIView *badge, BOOL classic, UIColor *color) {
    if (!sUnreadBadgeThemeColor || !ApolloUnreadBadgeViewIsTabBadge(badge, classic)) return color;
    return ApolloUnreadBadgeFillColor();
}

static NSDictionary *ApolloUnreadBadgeThemedTextAttributes(UIView *badge, BOOL classic, NSDictionary *attributes) {
    if (!sUnreadBadgeThemeColor || !ApolloUnreadBadgeViewIsTabBadge(badge, classic)) return attributes;
    NSMutableDictionary *themed = [attributes isKindOfClass:NSDictionary.class]
        ? [attributes mutableCopy] : [NSMutableDictionary dictionary];
    themed[NSForegroundColorAttributeName] = ApolloUnreadBadgeTextColor();
    return themed;
}

// Classic badges (UITabBarButton) are _UIBadgeView; Liquid Glass and the Duo
// rail use _UIBarBadgeView (iOS 26+). Both re-run -layoutSubviews when their
// text or size changes, which is exactly when the dot mask needs updating.
%group ApolloUnreadBadgeClassic
%hook _UIBadgeView
- (void)layoutSubviews {
    %orig;
    if (ApolloUnreadBadgeViewIsTabBadge((UIView *)self, YES)) ApolloUnreadBadgeUpdateDotMask((UIView *)self);
}

- (void)setBadgeColor:(UIColor *)color {
    %orig(ApolloUnreadBadgeThemedFill((UIView *)self, YES, color));
}

- (void)setTextAttributes:(NSDictionary *)attributes {
    %orig(ApolloUnreadBadgeThemedTextAttributes((UIView *)self, YES, attributes));
}
%end
%end

%group ApolloUnreadBadgeGlass
%hook _UIBarBadgeView
- (void)layoutSubviews {
    %orig;
    ApolloUnreadBadgeUpdateDotMask((UIView *)self);
}

- (void)setBadgeColor:(UIColor *)color {
    %orig(ApolloUnreadBadgeThemedFill((UIView *)self, NO, color));
}

- (void)setTextAttributes:(NSDictionary *)attributes {
    %orig(ApolloUnreadBadgeThemedTextAttributes((UIView *)self, NO, attributes));
}
%end
%end

%ctor {
    Class classic = objc_getClass("_UIBadgeView");
    Class glass = objc_getClass("_UIBarBadgeView");
    if (classic) %init(ApolloUnreadBadgeClassic);
    if (glass) %init(ApolloUnreadBadgeGlass);
    // A missing class only means that tab bar keeps UIKit's blank 18pt circle
    // for the dot and red for Theme Color; nothing else depends on it.
    ApolloLog(@"[UnreadBadges] dot/color hook installed: classic(_UIBadgeView)=%@ glass(_UIBarBadgeView)=%@",
              classic ? @"yes" : @"NOT INSTALLED", glass ? @"yes" : @"NOT INSTALLED (pre-iOS 26)");
}
