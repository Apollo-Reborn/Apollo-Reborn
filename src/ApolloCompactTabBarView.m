#import "ApolloCompactTabBarView.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

UIView *ApolloExpandedTabBarPlatter(UITabBar *tabBar) {
    // iOS 27 uses _UITabBarItemPlatterView, a subclass of the iOS 26 platter.
    // Matching an exact class name silently rejected Minimize on iOS 27. Resolve
    // the shared base once and accept its subclasses in both consumers, so
    // reading and animating the geometry cannot disagree about the owner.
    static Class platterClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        platterClass = NSClassFromString(@"UIKit._UITabBarPlatterView");
    });
    for (UIView *child in tabBar.subviews) {
        if ([child isKindOfClass:platterClass]) return child;
    }
    return nil;
}

static void ApolloCollectNativeForeground(UIView *view, NSMutableArray<UIView *> *views,
                                          NSMutableArray<NSNumber *> *alphas) {
    if ([view isKindOfClass:UIControl.class] ||
        [NSStringFromClass(view.class) containsString:@"BadgeView"]) {
        [views addObject:view];
        // UIKit briefly zeroes an individual tab button while rebuilding its
        // image view. The profile-avatar item does this asynchronously, so a
        // Minimize transition can begin inside that window and otherwise capture
        // zero as the native value, permanently hiding the button on restore.
        // Resting tab controls are opaque; badge views retain their real alpha.
        CGFloat nativeAlpha = view.alpha;
        if ([view isKindOfClass:UIControl.class]) nativeAlpha = 1.0;
        [alphas addObject:@(nativeAlpha)];
        return;
    }
    for (UIView *child in view.subviews) ApolloCollectNativeForeground(child, views, alphas);
}

// The actual platter, selected lens, icons and labels stay in UIKit's
// hierarchy. Only their presentation geometry and visibility are owned here.
@class ApolloCompactItemGeometry;
@interface ApolloCompactTabBarView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, weak) UITabBar *nativeTabBar;
@property (nonatomic, weak) UIView *nativePlatter;
@property (nonatomic, copy) NSArray<UIView *> *foregroundViews;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *foregroundAlphas;
@property (nonatomic, copy) NSArray<UIView *> *contentOwners;
@property (nonatomic, copy) NSArray<UIView *> *selectionViews;
@property (nonatomic, copy) NSArray<NSNumber *> *selectionHidden;
@property (nonatomic, weak) UIView *selectionLens;
@property (nonatomic, assign) CGFloat selectionLensAlpha;
@property (nonatomic, assign) CGRect nativeExpandedFrame;
@property (nonatomic, assign) CGRect nativeBarBounds;
@property (nonatomic, assign) BOOL applyingNativeFrame;
@property (nonatomic, assign) BOOL applyingNativeForeground;
@property (nonatomic, copy) NSArray<ApolloCompactItemGeometry *> *itemGeometry;
@property (nonatomic, assign) CGSize itemLayoutSize;
- (CGRect)nativeBoundsForProposedBounds:(CGRect)bounds;
- (CGPoint)nativeCenterForProposedCenter:(CGPoint)center;
- (CGRect)foregroundFrameInTabBar;
- (CGFloat)foregroundProgress;
- (CGFloat)nativeAlphaForView:(UIView *)view proposedAlpha:(CGFloat)alpha;
@end

@interface ApolloCompactPlatterOwner : NSObject
@property (nonatomic, weak) ApolloCompactTabBarView *view;
@end
@implementation ApolloCompactPlatterOwner
@end
static char ApolloCompactPlatterOwnerKey;

// Keep the real buttons at their expanded layout size. Resizing them makes
// UIKit change its spacing recipe near full width and re-round glyphs by a
// physical pixel throughout the glass spring's sub-point settling tail.
@interface ApolloCompactItemGeometry : NSObject
@property (nonatomic, weak) ApolloCompactTabBarView *owner;
@property (nonatomic, weak) UIView *view;
@property (nonatomic) CGRect expandedBounds;
@property (nonatomic) BOOL selection;
@property (nonatomic) BOOL lens;
@property (nonatomic) CGPoint expandedCenter;
- (CGRect)presentationBounds;
- (CGPoint)center;
@end
@implementation ApolloCompactItemGeometry
- (CGRect)presentationBounds {
    CGRect bounds = self.expandedBounds;
    if (self.selection) {
        // The highlight must fit inside the still-growing glass. Its capture
        // source keeps fixed glyph geometry; only this material's box grows.
        CGFloat height = MAX(1.0, self.owner.nativePlatter.bounds.size.height - 8.0);
        CGFloat scale = MIN(1.0, height / bounds.size.height);
        bounds.size.width *= scale;
        bounds.size.height *= scale;
    }
    return bounds;
}
- (CGPoint)center {
    ApolloCompactTabBarView *owner = self.owner;
    CGRect expanded = owner.nativeExpandedFrame;
    CGRect foreground = [owner foregroundFrameInTabBar];
    CGFloat spacingScale = foreground.size.width / expanded.size.width;
    CGPoint center = CGPointMake(CGRectGetMidX(foreground) +
        (self.expandedCenter.x - CGRectGetMidX(expanded)) * spacingScale,
        CGRectGetMidY(foreground) + self.expandedCenter.y - CGRectGetMidY(expanded));
    if (self.lens) {
        CGRect glass = owner.nativePlatter.frame;
        CGSize size = self.presentationBounds.size;
        center.x = MIN(CGRectGetMaxX(glass) - 4.0 - size.width * 0.5,
            MAX(CGRectGetMinX(glass) + 4.0 + size.width * 0.5, center.x));
        center.y = MIN(CGRectGetMaxY(glass) - 4.0 - size.height * 0.5,
            MAX(CGRectGetMinY(glass) + 4.0 + size.height * 0.5, center.y));
    }
    return [self.view.superview convertPoint:center fromView:owner.nativeTabBar];
}
@end
static char ApolloCompactItemGeometryKey;

CGRect ApolloCompactNativeItemBounds(UIView *view, CGRect proposedBounds) {
    ApolloCompactItemGeometry *geometry = objc_getAssociatedObject(view, &ApolloCompactItemGeometryKey);
    return geometry.owner ? geometry.presentationBounds : proposedBounds;
}
CGPoint ApolloCompactNativeItemCenter(UIView *view, CGPoint proposedCenter) {
    ApolloCompactItemGeometry *geometry = objc_getAssociatedObject(view, &ApolloCompactItemGeometryKey);
    return geometry.owner ? geometry.center : proposedCenter;
}
CGRect ApolloCompactNativeItemFrame(UIView *view, CGRect proposedFrame) {
    ApolloCompactItemGeometry *geometry = objc_getAssociatedObject(view, &ApolloCompactItemGeometryKey);
    if (!geometry.owner) return proposedFrame;
    CGPoint center = geometry.center;
    CGSize size = geometry.presentationBounds.size;
    return CGRectMake(center.x - size.width * 0.5, center.y - size.height * 0.5, size.width, size.height);
}

CGFloat ApolloCompactNativeItemAlpha(UIView *view, CGFloat proposedAlpha) {
    ApolloCompactItemGeometry *geometry = objc_getAssociatedObject(view, &ApolloCompactItemGeometryKey);
    return geometry.owner ? [geometry.owner nativeAlphaForView:view proposedAlpha:proposedAlpha] : proposedAlpha;
}

CGRect ApolloCompactNativePlatterBounds(UIView *platter, CGRect proposedBounds) {
    ApolloCompactPlatterOwner *owner = objc_getAssociatedObject(platter, &ApolloCompactPlatterOwnerKey);
    return owner.view ? [owner.view nativeBoundsForProposedBounds:proposedBounds] : proposedBounds;
}
CGPoint ApolloCompactNativePlatterCenter(UIView *platter, CGPoint proposedCenter) {
    ApolloCompactPlatterOwner *owner = objc_getAssociatedObject(platter, &ApolloCompactPlatterOwnerKey);
    return owner.view ? [owner.view nativeCenterForProposedCenter:proposedCenter] : proposedCenter;
}

@implementation ApolloCompactTabBarView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.accessibilityHint = @"Expand tab bar";
    _title = @"";
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:[UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium]
        maximumPointSize:17.0];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.numberOfLines = 1;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.isAccessibilityElement = NO;
    _titleLabel.alpha = 0.0;
    [self addSubview:_titleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18.0],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy] ?: @"";
    self.titleLabel.text = _title;
    self.accessibilityLabel = _title;
}
- (BOOL)accessibilityActivate {
    if (!self.enabled) return NO;
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}
- (CGFloat)titleAlpha { return self.titleLabel.alpha; }
- (void)setTitleAlpha:(CGFloat)alpha { self.titleLabel.alpha = alpha; }
- (void)setExpansionProgress:(CGFloat)progress {
    _expansionProgress = progress;
    self.titleAlpha = MIN(1.0, MAX(0.0, (0.35 - progress) / 0.25));
}

- (BOOL)prepareNativeTabBar:(UITabBar *)tabBar {
    UIView *platter = ApolloExpandedTabBarPlatter(tabBar);
    if (!platter || !tabBar.superview) return NO;
    if (self.nativePlatter == platter) return YES;
    [self restoreNativeTabBar];
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSMutableArray<NSNumber *> *alphas = [NSMutableArray array];
    NSMutableArray<UIView *> *contentOwners = [NSMutableArray array];
    NSMutableArray<UIView *> *selection = [NSMutableArray array];
    NSMutableArray<NSNumber *> *hidden = [NSMutableArray array];
    NSMutableArray<UIView *> *geometryViews = [NSMutableArray array];
    Class maskClass = Nil;
    BOOL foundContent = NO;
    for (UIView *child in platter.subviews) {
        NSString *name = NSStringFromClass(child.class);
        BOOL content = [name hasSuffix:@"ContentView"];
        if ([name isEqualToString:@"_UILiquidLensView"] || [name hasSuffix:@"DestOutView"]) {
            [selection addObject:child];
            [hidden addObject:@(child.hidden)];
            [geometryViews addObject:child];
            if ([name isEqualToString:@"_UILiquidLensView"]) {
                self.selectionLens = child;
                self.selectionLensAlpha = child.alpha;
            } else {
                maskClass = child.class;
            }
        } else if (content || [name hasSuffix:@"BadgeContainerView"]) {
            [contentOwners addObject:child];
            if (content) {
                for (UIView *item in child.subviews) {
                    if ([item isKindOfClass:UIControl.class]) [geometryViews addObject:item];
                }
            }
            // SelectedContentView is a capture source for the lens, not a
            // second visible row. Fade its lens once, keeping that source
            // intact. For normal items fade the button, not its vibrant
            // image/label: UIKit renders those leaves at full strength for
            // every nonzero alpha (verified on iOS 27).
            if ([name hasSuffix:@"BadgeContainerView"]) {
                // Badges may arrive asynchronously while compact. Owning
                // their container also fades badges added after capture.
                [views addObject:child];
                [alphas addObject:@(child.alpha)];
            } else if (![name hasSuffix:@"SelectedContentView"]) {
                ApolloCollectNativeForeground(child, views, alphas);
            }
            foundContent |= content;
        }
    }
    if (!foundContent || views.count == 0) return NO;
    self.nativeTabBar = tabBar;
    self.nativePlatter = platter;
    self.nativeExpandedFrame = platter.frame;
    self.nativeBarBounds = tabBar.bounds;
    self.foregroundViews = views;
    self.foregroundAlphas = alphas;
    self.contentOwners = contentOwners;
    self.selectionViews = selection;
    self.selectionHidden = hidden;
    Class buttonClass = NSClassFromString(@"_UITabButton");
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    if (!buttonClass || !lensClass || !maskClass) {
        [self restoreNativeTabBar];
        return NO;
    }
    ApolloInstallMinimizeItemGeometryHooks(buttonClass, lensClass, maskClass);
    NSMutableArray<ApolloCompactItemGeometry *> *geometry = [NSMutableArray array];
    for (UIView *view in geometryViews) {
        ApolloCompactItemGeometry *item = [ApolloCompactItemGeometry new];
        item.owner = self;
        item.view = view;
        item.expandedBounds = view.bounds;
        item.selection = [selection containsObject:view];
        item.lens = view == self.selectionLens;
        item.expandedCenter = [tabBar convertPoint:view.center fromView:view.superview];
        [geometry addObject:item];
        objc_setAssociatedObject(view, &ApolloCompactItemGeometryKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    self.itemGeometry = geometry;
    self.itemLayoutSize = self.nativeExpandedFrame.size;
    ApolloCompactPlatterOwner *owner = [ApolloCompactPlatterOwner new];
    owner.view = self;
    objc_setAssociatedObject(platter, &ApolloCompactPlatterOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

- (BOOL)ownsNativeTabBar:(UITabBar *)tabBar {
    UIView *platter = self.nativePlatter;
    if (self.nativeTabBar != tabBar || !platter || platter.superview != tabBar ||
        platter != ApolloExpandedTabBarPlatter(tabBar) ||
        !CGSizeEqualToSize(self.nativeExpandedFrame.size, self.itemLayoutSize)) return NO;
    for (UIView *view in self.foregroundViews) {
        if (![view isDescendantOfView:platter]) return NO;
    }
    for (UIView *view in self.contentOwners) {
        if (view.superview != platter) return NO;
    }
    for (UIView *view in self.selectionViews) {
        if (view.superview != platter) return NO;
    }
    for (ApolloCompactItemGeometry *item in self.itemGeometry) {
        if (![item.view isDescendantOfView:platter]) return NO;
    }
    return self.foregroundViews.count > 0;
}

- (CGRect)nativeBoundsForProposedBounds:(CGRect)bounds {
    if (self.applyingNativeFrame) return bounds;
    CGRect expanded = self.nativeExpandedFrame;
    CGPoint center = CGPointMake(CGRectGetMidX(expanded), CGRectGetMidY(expanded));
    expanded.size = bounds.size;
    expanded.origin = CGPointMake(center.x - bounds.size.width * 0.5, center.y - bounds.size.height * 0.5);
    self.nativeExpandedFrame = expanded;
    self.nativeBarBounds = self.nativeTabBar.bounds;
    return (CGRect){bounds.origin, self.bounds.size};
}

- (CGPoint)nativeCenterForProposedCenter:(CGPoint)center {
    if (self.applyingNativeFrame) return center;
    CGRect expanded = self.nativeExpandedFrame;
    expanded.origin = CGPointMake(center.x - expanded.size.width * 0.5, center.y - expanded.size.height * 0.5);
    self.nativeExpandedFrame = expanded;
    return [self.nativeTabBar convertPoint:self.center fromView:self.superview];
}

- (CGRect)expandedFrame {
    UITabBar *bar = self.nativeTabBar;
    CGRect frame = self.nativeExpandedFrame;
    // Preserve native side margins when the containing bar changes size.
    frame.size.width += bar.bounds.size.width - self.nativeBarBounds.size.width;
    return bar.superview ? [bar.superview convertRect:frame fromView:bar] : CGRectNull;
}

- (CGRect)foregroundFrameInTabBar {
    CGRect expanded = self.nativeExpandedFrame;
    CGFloat progress = MAX(0.0, self.expansionProgress);
    // Foreground reaches its canonical position when its fade completes.
    // The glass alone continues Safari's overshoot/settling curve. In
    // particular, the later 0.997 undershoot cannot re-round the icons.
    if (progress >= 0.95) return expanded;
    CGRect frame = [self.nativeTabBar convertRect:self.frame fromView:self.superview];
    CGFloat correction = (progress / 0.95 - progress) / (1.0 - progress);
    frame.origin.x += (expanded.origin.x - frame.origin.x) * correction;
    frame.origin.y += (expanded.origin.y - frame.origin.y) * correction;
    frame.size.width += (expanded.size.width - frame.size.width) * correction;
    frame.size.height += (expanded.size.height - frame.size.height) * correction;
    return frame;
}

- (CGFloat)foregroundProgress {
    return MIN(1.0, MAX(0.0, (self.expansionProgress - 0.70) / 0.25));
}

- (CGFloat)nativeAlphaForView:(UIView *)view proposedAlpha:(CGFloat)alpha {
    if (self.applyingNativeForeground) return alpha;
    NSUInteger index = [self.foregroundViews indexOfObjectIdenticalTo:view];
    // SelectedContentView's buttons are capture sources for the lens, not
    // visible foreground. Their native opacity must remain untouched.
    if (index == NSNotFound) return alpha;
    // Gallery's media dismissal refreshes tab images during viewWillAppear.
    // UIKit's item refresh (and didMoveToWindow) resets button opacity even
    // when the platter has not moved. Compose those updates with the owned
    // fade before they render, and preserve native intent for restoration.
    //
    // UIKit fades an individual _UITabButton while rebuilding its image view.
    // The profile-avatar item does that asynchronously and may write any
    // intermediate alpha, not only zero. Native tab controls are opaque at
    // rest, with selection/disabled appearance drawn by their descendants, so
    // never adopt those lifecycle fades as a restoration baseline. Badge
    // containers are not controls and continue to preserve their native alpha.
    if ([view isKindOfClass:UIControl.class]) {
        return self.foregroundAlphas[index].doubleValue * self.foregroundProgress;
    }
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        self.foregroundAlphas[index] = @(alpha);
    }
    return alpha * self.foregroundProgress;
}

- (void)applyNativeFrame:(CGRect)frame expansionProgress:(CGFloat)progress {
    self.expansionProgress = progress;
    self.frame = frame;
    self.applyingNativeFrame = YES;
    self.nativePlatter.frame = [self.nativeTabBar convertRect:frame fromView:self.nativeTabBar.superview];
    self.applyingNativeFrame = NO;
    [self.nativePlatter layoutIfNeeded];
    for (ApolloCompactItemGeometry *item in self.itemGeometry) {
        item.view.bounds = item.presentationBounds;
        item.view.center = item.center;
    }
    // Native labels keep their font size as the items redistribute. Wait for
    // sufficient width before revealing them, avoiding crowded glyphs during
    // the narrow part of the morph. They are fully visible before settling.
    CGFloat foreground = self.foregroundProgress;
    // Keep the destination-out mask opaque: fading it exposes the normal
    // selected item underneath the lens. Only the lens and normal buttons
    // dissolve; the selected capture source stays at native opacity.
    for (NSUInteger i = 0; i < self.selectionViews.count; i++) {
        self.selectionViews[i].hidden = self.selectionHidden[i].boolValue || foreground == 0.0;
    }
    self.selectionLens.alpha = self.selectionLensAlpha * foreground;
    self.applyingNativeForeground = YES;
    for (NSUInteger i = 0; i < self.foregroundViews.count; i++) {
        self.foregroundViews[i].alpha = self.foregroundAlphas[i].doubleValue * foreground;
    }
    self.applyingNativeForeground = NO;
    [self layoutIfNeeded];
}

- (void)restoreNativeTabBar {
    UIView *platter = self.nativePlatter;
    UITabBar *bar = self.nativeTabBar;
    if (platter) {
        objc_setAssociatedObject(platter, &ApolloCompactPlatterOwnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Remove guards before restoring native geometry, including interrupted
    // collapse, navigation, rotation, and setting changes.
    for (ApolloCompactItemGeometry *item in self.itemGeometry) {
        objc_setAssociatedObject(item.view, &ApolloCompactItemGeometryKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (bar && platter.superview == bar) {
        CGRect frame = self.nativeExpandedFrame;
        frame.size.width += bar.bounds.size.width - self.nativeBarBounds.size.width;
        platter.frame = frame;
    }
    for (ApolloCompactItemGeometry *item in self.itemGeometry) {
        item.view.bounds = item.expandedBounds;
        item.view.center = [item.view.superview convertPoint:item.expandedCenter fromView:bar];
    }
    for (NSUInteger i = 0; i < self.foregroundViews.count; i++) {
        self.foregroundViews[i].alpha = self.foregroundAlphas[i].doubleValue;
    }
    for (NSUInteger i = 0; i < self.selectionViews.count; i++) {
        self.selectionViews[i].hidden = self.selectionHidden[i].boolValue;
    }
    self.selectionLens.alpha = self.selectionLensAlpha;
    self.nativePlatter = nil;
    self.nativeTabBar = nil;
    self.foregroundViews = nil;
    self.foregroundAlphas = nil;
    self.contentOwners = nil;
    self.selectionViews = nil;
    self.selectionHidden = nil;
    self.selectionLens = nil;
    self.itemGeometry = nil;
}

- (void)dealloc {
    // The owner reference is weak, but release any remaining geometry guard
    // when the containing controller disappears without another layout pass.
    [self restoreNativeTabBar];
}

- (CGSize)compactSize {
    CGSize text = [self.titleLabel sizeThatFits:CGSizeMake(240.0, 44.0)];
    return CGSizeMake(MAX(96.0, ceil(text.width) + 36.0), MAX(32.0, ceil(text.height) + 14.0));
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect hitRect = CGRectInset(self.bounds, 0.0, -MAX(0.0, (44.0 - self.bounds.size.height) / 2.0));
    return CGRectContainsPoint(hitRect, point);
}
@end
