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
    // text; ApolloUnreadBadgeUpdateDot then turns that blank badge into the
    // dot on the icon's corner whenever UIKit lays it out.
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
// (18pt), not a dot. Rather than add views of our own next to every copy of
// the Inbox tab (iOS 26 keeps badges inside each _UITabButton, iOS 27 in the
// platter's badge container, Classic inside UITabBarButton, plus the Duo
// rail), the dot lives inside UIKit's blank badge, so UIKit still owns when
// it shows, where it goes with the tab, its fill (red, or the theme accent
// swapped in below) and its teardown. The dot is centered on the tab icon's
// top-trailing corner (the corner of the envelope), the spot AcornElf tuned
// in #1332. That corner is outside the blank badge's circle on most layouts,
// so the dot is a subview carrying the badge's fill (neither badge class
// clips; both draw their fill as the view's backgroundColor), and a mask the
// size of the dot trims the blank circle away around it.
static const CGFloat kApolloUnreadTabDotSize = 8.0;
// How far the icon's corner may be from the badge's center and still be this
// badge's icon. The Inbox icon's corner is under 15pt away on every layout;
// the neighbouring tabs' icons are 40pt and more.
static const CGFloat kApolloUnreadDotIconReach = 24.0;
static NSString *const kApolloUnreadDotMaskName = @"ApolloUnreadBadgeDot";
static char kApolloUnreadDotViewKey;

static NSString *ApolloUnreadBadgeText(UIView *badge) {
    return [badge respondsToSelector:@selector(text)]
        ? ((NSString *(*)(id, SEL))objc_msgSend)(badge, @selector(text)) : nil;
}

// Visible icons under `view`, skipping the badge itself and hidden subtrees
// (iOS 27 keeps a hidden spare platter and fades some tab copies to 0).
static void ApolloUnreadBadgeCollectIcons(UIView *view, UIView *badge, NSInteger depth,
                                          NSMutableArray<UIImageView *> *icons) {
    if (view == badge || view.hidden || view.alpha < 0.01) return;
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) {
        [icons addObject:(UIImageView *)view];
        return;
    }
    if (depth <= 0) return;
    for (UIView *subview in view.subviews) ApolloUnreadBadgeCollectIcons(subview, badge, depth - 1, icons);
}

// The top-trailing corner of the icon this badge belongs to, in the badge's
// coordinates. Classic and iOS 26 Liquid Glass keep the icon next to the badge
// in the tab button; iOS 27 keeps it in the platter's content view while the
// badge sits in a sibling badge container. So look under the badge's
// superview, then one level up, and take the nearest icon corner. Duplicate
// copies of a tab (the selection lens) sit at the same spot, so any of them
// gives the same corner.
static BOOL ApolloUnreadBadgeIconCorner(UIView *badge, CGPoint *corner) {
    BOOL rtl = badge.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGPoint badgeCenter = CGPointMake(CGRectGetMidX(badge.bounds), CGRectGetMidY(badge.bounds));
    UIView *root = badge.superview;
    for (NSInteger level = 0; level < 2 && root; level++, root = root.superview) {
        NSMutableArray<UIImageView *> *icons = [NSMutableArray array];
        ApolloUnreadBadgeCollectIcons(root, badge, 4, icons);
        CGFloat best = kApolloUnreadDotIconReach;
        BOOL found = NO;
        for (UIImageView *icon in icons) {
            CGRect frame = [badge convertRect:icon.bounds fromView:icon];
            CGPoint point = CGPointMake(rtl ? CGRectGetMinX(frame) : CGRectGetMaxX(frame), CGRectGetMinY(frame));
            CGFloat distance = hypot(point.x - badgeCenter.x, point.y - badgeCenter.y);
            if (distance < best) {
                best = distance;
                *corner = point;
                found = YES;
            }
        }
        if (found) return YES;
    }
    return NO;
}

static void ApolloUnreadBadgeRemoveDot(UIView *badge) {
    if ([badge.layer.mask.name isEqualToString:kApolloUnreadDotMaskName]) badge.layer.mask = nil;
    UIView *dot = objc_getAssociatedObject(badge, &kApolloUnreadDotViewKey);
    [dot removeFromSuperview];
    objc_setAssociatedObject(badge, &kApolloUnreadDotViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloUnreadBadgeUpdateDot(UIView *badge) {
    CALayer *mask = badge.layer.mask;
    BOOL ours = [mask.name isEqualToString:kApolloUnreadDotMaskName];
    if (!sUnreadBadgeCompactTabBar && !ours) return;   // main's path: nothing to do

    // Only the blank badge ApolloUnreadBadgeTabBarDisplayValue produced; a
    // count badge (any tab, or compact turned off) gets its full shape back.
    BOOL wantsDot = sUnreadBadgeCompactTabBar && ApolloUnreadBadgeText(badge).length == 0 &&
        CGRectGetHeight(badge.bounds) > kApolloUnreadTabDotSize;
    if (!wantsDot) {
        if (ours) ApolloUnreadBadgeRemoveDot(badge);
        return;
    }
    if (mask && !ours) return;   // UIKit's own mask: leave the badge alone

    CGPoint center;
    if (!ApolloUnreadBadgeIconCorner(badge, &center)) {
        // Unknown tab layout: the dot takes the badge's own spot instead.
        center = CGPointMake(CGRectGetMidX(badge.bounds), CGRectGetMidY(badge.bounds));
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            ApolloLog(@"[UnreadBadges] no tab icon near the %@ (in %@); the dot stays at the badge's center",
                      NSStringFromClass(badge.class), NSStringFromClass(badge.superview.class));
        });
    }
    CGFloat scale = MAX(badge.traitCollection.displayScale, 1.0);
    CGFloat half = kApolloUnreadTabDotSize / 2.0;
    CGRect dotRect = CGRectMake(round((center.x - half) * scale) / scale, round((center.y - half) * scale) / scale,
                                kApolloUnreadTabDotSize, kApolloUnreadTabDotSize);

    UIView *dot = objc_getAssociatedObject(badge, &kApolloUnreadDotViewKey);
    if (!dot) {
        dot = [[UIView alloc] initWithFrame:dotRect];
        dot.userInteractionEnabled = NO;
        dot.layer.cornerRadius = half;
        objc_setAssociatedObject(badge, &kApolloUnreadDotViewKey, dot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (dot.superview != badge) [badge addSubview:dot];
    else if (badge.subviews.lastObject != dot) [badge bringSubviewToFront:dot];
    // The badge's fill as UIKit set it (already themed by -setBadgeColor:
    // below); a dynamic color, so the dot follows light/dark on its own.
    dot.backgroundColor = badge.backgroundColor;

    CAShapeLayer *shape = ours ? (CAShapeLayer *)mask : [CAShapeLayer layer];
    if (!ours) {
        shape.name = kApolloUnreadDotMaskName;
        badge.layer.mask = shape;
    }
    // Dot and mask move together, without UIKit's or Core Animation's
    // implicit animations pulling them apart.
    [UIView performWithoutAnimation:^{ dot.frame = dotRect; }];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shape.frame = dotRect;
    shape.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, kApolloUnreadTabDotSize,
                                                                   kApolloUnreadTabDotSize)].CGPath;
    [CATransaction commit];
}

// UIKit moves a badge with its tab (Minimize, Icon-Only Tab Bar, rotation, a
// Duo pose) without resizing it, which doesn't lay it out again. Re-place the
// dot on the next layout pass, after the icons have moved too. First line
// bails unless this badge shows a dot.
static void ApolloUnreadBadgeDotBadgeMoved(UIView *badge) {
    // Off: nothing to follow. A dot left from turning it off goes away in the
    // layout the restored count triggers (ApolloUnreadBadgeUpdateDot).
    if (!sUnreadBadgeCompactTabBar) return;
    if (objc_getAssociatedObject(badge, &kApolloUnreadDotViewKey)) [badge setNeedsLayout];
}

static void ApolloUnreadBadgeDotFillChanged(UIView *badge) {
    if (!sUnreadBadgeCompactTabBar) return;
    UIView *dot = objc_getAssociatedObject(badge, &kApolloUnreadDotViewKey);
    if (dot) dot.backgroundColor = badge.backgroundColor;
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
// text or size changes; a move alone is caught by -setCenter:/-setFrame:.
%group ApolloUnreadBadgeClassic
%hook _UIBadgeView
- (void)layoutSubviews {
    %orig;
    if (ApolloUnreadBadgeViewIsTabBadge((UIView *)self, YES)) ApolloUnreadBadgeUpdateDot((UIView *)self);
}

- (void)setCenter:(CGPoint)center {
    %orig;
    ApolloUnreadBadgeDotBadgeMoved((UIView *)self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    ApolloUnreadBadgeDotBadgeMoved((UIView *)self);
}

// Classic applies the color in -layoutSubviews (setBadgeColor: only marks it
// for layout), so the dot picks it up there.
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
    ApolloUnreadBadgeUpdateDot((UIView *)self);
}

- (void)setCenter:(CGPoint)center {
    %orig;
    ApolloUnreadBadgeDotBadgeMoved((UIView *)self);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    ApolloUnreadBadgeDotBadgeMoved((UIView *)self);
}

// Liquid Glass sets the fill (backgroundColor) right here, not in layout.
- (void)setBadgeColor:(UIColor *)color {
    %orig(ApolloUnreadBadgeThemedFill((UIView *)self, NO, color));
    ApolloUnreadBadgeDotFillChanged((UIView *)self);
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
