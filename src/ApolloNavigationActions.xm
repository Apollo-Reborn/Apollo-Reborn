#import "ApolloDuoSplitView.h"
#import "ApolloDuoUIKitCompatibility.h"
#import "ApolloNavigationActions.h"
#import "ApolloNavigationActionsDiscovery.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloCommon.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRail.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloSearchNativeBar.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

extern NSArray<UIBarButtonItem *> *ApolloDuoCommentsLayoutItems(UINavigationItem *item, NSArray<UIBarButtonItem *> *items);

// Use the pill's spring for glyphs without changing button frames,
// which translation measures when inserting its globe.
static const NSTimeInterval kActionsAnimationDuration = 0.36;
static CASpringAnimation *ApolloActionsSpring(NSString *keyPath) {
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:keyPath];
    spring.mass = 1;
    spring.stiffness = 644;
    spring.damping = 2 * 0.78 * sqrt(spring.stiffness);
    spring.duration = kActionsAnimationDuration;
    return spring;
}

// Each page owns one strip and glass surface. Never hide native ancestors,
// save their transient alpha, or duplicate the More glyph.
static char kActionsOwnerKey;
static char kActionsControllerKey;
static char kActionsRefreshKey;
static char kActionsStandardItemKey;
static char kActionsStandardMoreKey;
static char kActionsScrollOwnerKey;
static char kActionsChromeKey;
static char kActionsBlueDoneKey;
static char kActionsNativeEditAccentKey;
static char kActionsAccentSubmitKey;
static char kActionsApprovedLayoutKey;
static char kActionsDuoOriginalItemsKey;
static char kActionsDuoNativeItemsKey;
static char kActionsDuoSourceButtonKey;
static char kActionsDuoMirroredItemsKey;
static char kActionsDuoRefreshScheduledKey;
static char kActionsDuoProfileAppliedKey;
static char kActionsDuoProfileRefreshKey;
static char kActionsDuoProfileCellColorKey;
static char kActionsDuoProfileCellBackgroundKey;
static char kActionsDuoProfileBackgroundColorKey;
static char kActionsDuoProfileSelectionMaskKey;
static char kActionsDuoProfileOriginalSelectionMaskKey;
static char kActionsDuoBackItemKey;
static char kActionsDuoBackGlassKey;
static __thread NSUInteger sActionsBackMeasurementDepth;
static NSUInteger sActionsModelWriteDepth;
@class ApolloNavigationActionsOwner;
static void ApolloActionsResetBeforeNavigation(UIViewController *controller);

// The customization is glass-only, but public refresh helpers can still be
// called on the iOS 14 deployment floor. Keep newer item state access guarded.
static BOOL ApolloActionsItemHidden(UIBarButtonItem *item) {
    if (@available(iOS 16.0, *)) return item.hidden;
    return NO;
}

static void ApolloActionsSetItemHidden(UIBarButtonItem *item, BOOL hidden) {
    if (@available(iOS 16.0, *)) item.hidden = hidden;
}

// The post composer's Post and Done buttons keep Done's prominent style, whose
// tint is its fill: neutral chrome painted a labelColor (white in dark mode)
// pill. Fill it with the theme accent; UIKit picks a readable title for it.
// One provider for the process: dynamic colors compare by provider identity,
// so a fresh ApolloThemeAccentColor() per pass would never match the pin
// guards and would re-tint the button on every preparation.
static UIColor *ApolloActionsAccentSubmitColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            UIColor *accent = ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
            return [accent resolvedColorWithTraitCollection:traits];
        }];
    });
    return color;
}

// Keep right-item chrome neutral before it appears, including lone actions on
// profile feeds. Mark only the actual item content, never the whole nav bar.
static UIColor *ApolloActionsChromeColor(id object) {
    if ([objc_getAssociatedObject(object, &kActionsNativeEditAccentKey) boolValue]) {
        return ApolloActionsAccentSubmitColor();
    }
    if (@available(iOS 26.0, *)) {
        if ([object isKindOfClass:UIBarButtonItem.class]
            && [((UIBarButtonItem *)object).identifier isEqualToString:@"ApolloReborn.subreddits.edit"]
            && ((UIBarButtonItem *)object).style == UIBarButtonItemStyleProminent) {
            return UIColor.systemBlueColor;
        }
    }
    if ([objc_getAssociatedObject(object, &kActionsAccentSubmitKey) boolValue]) {
        return ApolloActionsAccentSubmitColor();
    }
    return [objc_getAssociatedObject(object, &kActionsBlueDoneKey) boolValue]
        ? UIColor.systemBlueColor : ApolloNavigationChromeColor();
}

static void ApolloActionsPinChrome(id object) {
    UIColor *chrome = ApolloActionsChromeColor(object);
    if (!objc_getAssociatedObject(object, &kActionsChromeKey) ||
        ![[object tintColor] isEqual:chrome]) {
        [object setTintColor:chrome];
        objc_setAssociatedObject(object, &kActionsChromeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

void ApolloNavigationActionsSetNativeEditingAccent(UIBarButtonItem *item, BOOL enabled) {
    if (!item) return;
    BOOL wasEnabled = [objc_getAssociatedObject(item, &kActionsNativeEditAccentKey) boolValue];
    if (!enabled && !wasEnabled) return;
    if (wasEnabled != enabled) {
        objc_setAssociatedObject(item, &kActionsNativeEditAccentKey,
                                 enabled ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Use the shared tint owner so later Apollo theme/chrome writes cannot
    // turn the native prominent Done circle back into a label-colored fill.
    ApolloActionsPinChrome(item);
}

static UIImage *ApolloActionsTemplateImage(UIImage *image) {
    return image && image.renderingMode != UIImageRenderingModeAlwaysTemplate
        ? [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : image;
}

static BOOL ApolloActionsIsAutoModClose(UIBarButtonItem *item) {
    return item.action == NSSelectorFromString(@"cancelBarButtonItemTappedWithSender:") &&
        [NSStringFromClass([item.target class]) isEqualToString:@"Apollo.AutoModeratorViewController"];
}

static BOOL ApolloActionsUsesPlainSubmitStyle(UIBarButtonItem *item) {
    NSString *targetClass = NSStringFromClass([item.target class]);
    return (item.action == NSSelectorFromString(@"submitBarButtonTapped:") &&
            [targetClass isEqualToString:@"Apollo.ComposeViewController"]) ||
           (item.action == NSSelectorFromString(@"updateBarButtonItemTappedWithSender:") &&
            [targetClass isEqualToString:@"Apollo.FlairSelectorViewController"]);
}

// The post composer's storyboard Post item (style Done), the Poll tab's
// replacement for it (ApolloPollCompose.xm), and the Done checkmark that
// replaces Post in its body editors (ApolloPhotoPostComposerScrollFix.xm).
static BOOL ApolloActionsUsesAccentSubmitStyle(UIBarButtonItem *item) {
    NSString *targetClass = NSStringFromClass([item.target class]);
    SEL action = item.action;
    if ([targetClass isEqualToString:@"Apollo.ComposePostViewController"]) {
        return action == NSSelectorFromString(@"postButtonTapped:");
    }
    if ([targetClass isEqualToString:@"Apollo.ComposeViewController"]) {
        return action == NSSelectorFromString(@"apollo_mediaBodyDoneButtonTapped:") ||
            action == NSSelectorFromString(@"apollo_textBodyDoneButtonTapped:");
    }
    return action == NSSelectorFromString(@"postTapped") &&
        [targetClass isEqualToString:@"ApolloPollComposeViewController"];
}

static void ApolloActionsPrepareApprovedContent(UIView *content) {
    if (!content || objc_getAssociatedObject(content, &kActionsApprovedLayoutKey)) return;
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (UIView *child in content.subviews) {
        if ([child isKindOfClass:UIButton.class]) [buttons addObject:(UIButton *)child];
    }
    if (buttons.count != 2) return;
    [buttons sortUsingComparator:^NSComparisonResult(UIButton *a, UIButton *b) {
        return CGRectGetMinX(a.frame) < CGRectGetMinX(b.frame) ? NSOrderedAscending : NSOrderedDescending;
    }];
    // Apollo's compact legacy frames put the plus below its 24pt container.
    // Keep the original controls/actions, with equal centered glass slots.
    const CGFloat slotWidth = 36.0;
    for (NSUInteger index = 0; index < buttons.count; index++) {
        UIButton *button = buttons[index];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        button.contentEdgeInsets = UIEdgeInsetsZero;
        button.imageEdgeInsets = UIEdgeInsetsZero;
        button.frame = CGRectMake(index * slotWidth, 0, slotWidth, 44);
    }
    CGRect frame = content.frame;
    frame.size = CGSizeMake(buttons.count * slotWidth, 44);
    content.frame = frame;
    content.bounds = CGRectMake(0, 0, frame.size.width, 44);
    objc_setAssociatedObject(content, &kActionsApprovedLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloActionsApplyChromeToView(UIView *view, BOOL blueDone) {
    if (!view) return;
    objc_setAssociatedObject(view, &kActionsBlueDoneKey, @(blueDone), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloActionsPinChrome(view);
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (id)view;
        const UIControlState states[] = { UIControlStateNormal, UIControlStateSelected,
            UIControlStateHighlighted, UIControlStateDisabled };
        for (NSUInteger i = 0; i < sizeof(states) / sizeof(states[0]); i++) {
            UIImage *image = [button imageForState:states[i]];
            UIImage *templated = ApolloActionsTemplateImage(image);
            if (templated != image) [button setImage:templated forState:states[i]];
        }
    }
    for (UIView *child in view.subviews) ApolloActionsApplyChromeToView(child, blueDone);
}

@interface ApolloNavigationActionsControllerBox : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end
@implementation ApolloNavigationActionsControllerBox
@end

@interface ApolloNavigationActionsScrollOwnerBox : NSObject
@property (nonatomic, weak) ApolloNavigationActionsOwner *owner;
@end
@implementation ApolloNavigationActionsScrollOwnerBox
@end

// The item's customView contains its glass and original buttons/targets/menus.
// Its trailing-anchored viewport resizes while More stays fixed in the window.
@interface ApolloNavigationActionsStrip : UIControl
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIVisualEffectView *surface;
@property (nonatomic, weak) UIButton *more;
@property (nonatomic, weak) ApolloNavigationActionsOwner *owner;
@property (nonatomic, weak) UIBarButtonItem *barItem;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@property (nonatomic) CGFloat expandedWidth;
@property (nonatomic) CGFloat moreMidX;
@property (nonatomic) BOOL expanded;
@property (nonatomic) BOOL originalAccessibilityHidden;
@property (nonatomic, strong) NSHashTable<CALayer *> *animatedIconLayers;
@property (nonatomic, copy) NSString *iconMotionKey;
@property (nonatomic, copy) NSString *iconOpacityKey;
- (instancetype)initWithContent:(UIView *)content more:(UIButton *)more;
- (void)remeasure;
- (void)applyExpanded:(BOOL)expanded;
- (void)publishSize;
- (void)displayExpanded:(BOOL)expanded;
- (void)animateIconsExpanded:(BOOL)expanded entering:(BOOL)entering;
- (void)removeIconAnimations;
@end

@interface ApolloNavigationActionsStandardItem : NSObject
@property (nonatomic, weak) UIBarButtonItem *item;
@property (nonatomic, weak) ApolloNavigationActionsOwner *owner;
@property (nonatomic) BOOL hidden;
@end
@implementation ApolloNavigationActionsStandardItem
@end

@interface ApolloNavigationActionsOwner : NSObject
@property (nonatomic, weak) UINavigationItem *item;
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, strong) NSArray<ApolloNavigationActionsStrip *> *strips;
@property (nonatomic, strong) NSMutableArray<ApolloNavigationActionsStandardItem *> *standardItems;
@property (nonatomic, weak) UIBarButtonItem *moreItem;
@property (nonatomic, strong) UIBarButtonItem *inboxDisclosure;
@property (nonatomic, strong) UIBarButtonItem *inboxCompactItem;
@property (nonatomic, copy) NSArray<UIBarButtonItem *> *inboxNativeItems;
@property (nonatomic, copy) UIAction *nativePrimaryAction;
@property (nonatomic, copy) UIMenu *nativeMenu;
@property (nonatomic, strong) UIViewPropertyAnimator *animator;
@property (nonatomic, strong) NSHashTable<UIPanGestureRecognizer *> *pans;
@property (nonatomic, weak) UIView *scrollRegistrationRoot;
@property (nonatomic, weak) UIGestureRecognizer *backGesture;
@property (nonatomic, strong) id resignObserver;
@property (nonatomic) BOOL expanded;
@property (nonatomic) BOOL preparing;
@property (nonatomic) BOOL collapsePreference;
@property (nonatomic) BOOL needsGeometryTransition;
@property (nonatomic) BOOL geometryDeferred;
@property (nonatomic) BOOL needsAnimationSettlement;
- (BOOL)collapseEnabled;
- (void)prepareItems:(NSArray<UIBarButtonItem *> *)items;
- (BOOL)deferGeometryUpdate;
- (void)publishExpandedState;
- (void)settleAnimationIfNeeded;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)watchScrollViews;
- (void)scrolled:(UIPanGestureRecognizer *)pan;
- (void)restoreStandardItems;
- (void)applyStandardExpanded:(BOOL)expanded;
- (NSArray<UIBarButtonItem *> *)duoStandardItemsForExpanded:(BOOL)expanded;
@end

static BOOL ApolloActionsMoreName(NSString *name) {
    NSString *lower = name.lowercaseString;
    // Matching "options" would mistake moderatorOptionsButtonTapped for More.
    return [lower containsString:@"more"] || [lower containsString:@"ellipsis"];
}

static BOOL ApolloActionsModeratorItem(UIBarButtonItem *item) {
    NSString *label = item.accessibilityLabel.lowercaseString;
    NSString *action = NSStringFromSelector(item.action).lowercaseString;
    return [label containsString:@"moderator"] || [action containsString:@"moderator"];
}

static UIButton *ApolloActionsFindMore(UIView *root) {
    if ([root isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)root;
        if (ApolloActionsMoreName(button.accessibilityLabel)) return button;
        for (id target in button.allTargets) {
            for (NSString *action in [button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]) {
                if (ApolloActionsMoreName(action)) return button;
            }
        }
    }
    for (UIView *child in root.subviews) {
        UIButton *more = ApolloActionsFindMore(child);
        if (more) return more;
    }
    return nil;
}

static NSUInteger ApolloActionsControlCount(UIView *root) {
    if ([root isKindOfClass:UIControl.class]) return 1;
    NSUInteger count = 0;
    for (UIView *child in root.subviews) count += ApolloActionsControlCount(child);
    return count;
}

static BOOL ApolloActionsIsPickerCancel(UIBarButtonItem *item) {
    SEL cancel = NSSelectorFromString(@"cancelBarButtonItemTappedWithSender:");
    if (item.action == cancel) return YES;
    UIView *view = item.customView;
    if (![view isKindOfClass:UIButton.class]) return NO;
    UIButton *button = (UIButton *)view;
    for (id target in button.allTargets) {
        if ([[button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]
                containsObject:NSStringFromSelector(cancel)]) return YES;
    }
    return NO;
}

static BOOL ApolloActionsHasStrip(NSArray<UIBarButtonItem *> *items) {
    for (UIBarButtonItem *item in items) {
        if ([item.customView isKindOfClass:ApolloNavigationActionsStrip.class]) return YES;
        UIView *content = item.customView;
        if (ApolloActionsFindMore(content) && ApolloActionsControlCount(content) > 1) return YES;
    }
    return NO;
}

static BOOL ApolloActionsHasPickerCancel(NSArray<UIBarButtonItem *> *items) {
    for (UIBarButtonItem *item in items) if (ApolloActionsIsPickerCancel(item)) return YES;
    return NO;
}

static BOOL ApolloActionsReplacingPickerControl(UINavigationItem *item,
                                                NSArray<UIBarButtonItem *> *incoming) {
    if (!IsLiquidGlass()) return NO;
    NSArray *outgoing = item.rightBarButtonItems;
    // The picker replaces our glass-owning custom view with UIKit's Cancel
    // item. UIKit's animated replacement snapshots/morphs both glass owners,
    // briefly drawing two lenses. Commit only this structural swap without
    // animation; normal pill expansion and page transitions retain animation.
    return (ApolloActionsHasStrip(outgoing) && ApolloActionsHasPickerCancel(incoming)) ||
           (ApolloActionsHasPickerCancel(outgoing) && ApolloActionsHasStrip(incoming));
}

static void ApolloActionsSetPrimaryAction(UIBarButtonItem *item, UIAction *action) {
    // Preserve Apollo's artwork/title when UIKit copies the action's metadata.
    UIImage *image = item.image;
    NSString *title = item.title;
    item.primaryAction = action;
    item.image = image;
    item.title = title;
}

UIView *ApolloNavigationActionsContentView(UIBarButtonItem *item) {
    UIView *view = item.customView;
    return [view isKindOfClass:ApolloNavigationActionsStrip.class]
        ? ((ApolloNavigationActionsStrip *)view).content : view;
}

UIView *ApolloNavigationActionsMenuSourceView(UIView *action) {
    for (UIView *view = action; view; view = view.superview) {
        if ([view isKindOfClass:ApolloNavigationActionsStrip.class]) {
            return ((ApolloNavigationActionsStrip *)view).surface;
        }
    }
    return nil;
}

@implementation ApolloNavigationActionsStrip
- (instancetype)initWithContent:(UIView *)content more:(UIButton *)more {
    self = [super initWithFrame:CGRectMake(0, 0, 44, 44)];
    if (!self) return nil;
    _content = content;
    _more = more;
    _originalAccessibilityHidden = content.accessibilityElementsHidden;
    _animatedIconLayers = [NSHashTable weakObjectsHashTable];
    _iconMotionKey = [NSString stringWithFormat:@"ApolloReborn.actions.motion.%p", self];
    _iconOpacityKey = [NSString stringWithFormat:@"ApolloReborn.actions.opacity.%p", self];
    self.clipsToBounds = NO;
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    UIVisualEffect *effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, NSSelectorFromString(@"effectWithStyle:"), 0);
    self.surface = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.surface.frame = self.bounds;
    self.surface.clipsToBounds = YES;
    self.surface.layer.cornerRadius = 22;
    Class cornerClass = NSClassFromString(@"UICornerConfiguration");
    SEL capsule = NSSelectorFromString(@"capsuleConfiguration");
    SEL setter = NSSelectorFromString(@"setCornerConfiguration:");
    if ([cornerClass respondsToSelector:capsule] && [self.surface respondsToSelector:setter]) {
        id configuration = ((id (*)(id, SEL))objc_msgSend)(cornerClass, capsule);
        ((void (*)(id, SEL, id))objc_msgSend)(self.surface, setter, configuration);
    }
    [self addSubview:self.surface];
    self.widthConstraint = [self.widthAnchor constraintEqualToConstant:44];
    self.widthConstraint.active = YES;
    [self addTarget:self action:@selector(reveal:) forControlEvents:UIControlEventTouchUpInside];
    self.accessibilityLabel = @"Show navigation actions";
    self.accessibilityHint = @"Expands the page's buttons. Scrolling closes them.";
    [self remeasure];
    [self applyExpanded:NO];
    return self;
}
- (BOOL)deferGeometryForNativeMenu {
    if (!ApolloNativeActionMenuOwnsNavigationSurface(self.surface)) return NO;
    [self.owner deferGeometryUpdate];
    return YES;
}
- (void)remeasure {
    if ([self deferGeometryForNativeMenu]) return;
    // Measure the full source, including late globes, not the clipped viewport.
    CGRect moreFrame = [self.more convertRect:self.more.bounds toView:self.content];
    BOOL changed = fabs(self.moreMidX - CGRectGetMidX(moreFrame)) > 0.01;
    self.moreMidX = CGRectGetMidX(moreFrame);
    self.expandedWidth = MAX(44, ceil(self.moreMidX + 22));
    CGFloat width = self.expanded ? self.expandedWidth : 44;
    if (fabs(self.widthConstraint.constant - width) > 0.01) {
        self.widthConstraint.constant = width;
        [self invalidateIntrinsicContentSize];
        changed = YES;
    }
    if (changed) [self setNeedsLayout];
}
- (CGSize)intrinsicContentSize {
    return CGSizeMake(self.expanded ? self.expandedWidth : 44, 44);
}
- (CGSize)sizeThatFits:(CGSize)size { return self.intrinsicContentSize; }
- (CGSize)systemLayoutSizeFittingSize:(CGSize)size { return self.intrinsicContentSize; }
- (CGSize)systemLayoutSizeFittingSize:(CGSize)size withHorizontalFittingPriority:(UILayoutPriority)horizontal verticalFittingPriority:(UILayoutPriority)vertical {
    return self.intrinsicContentSize;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if ([self deferGeometryForNativeMenu]) return;
    // Async host resizing must preserve the surface's right edge and animated width.
    CGRect glassFrame = self.surface.frame;
    glassFrame.origin = CGPointMake(self.bounds.size.width - glassFrame.size.width, (self.bounds.size.height - 44) / 2);
    if (!CGRectEqualToRect(self.surface.frame, glassFrame)) self.surface.frame = glassFrame;
    [self layoutContent];
}
- (void)layoutContent {
    if ([self deferGeometryForNativeMenu]) return;
    CGSize size = self.content.bounds.size;
    CGRect frame = CGRectMake(self.surface.bounds.size.width - 22 - self.moreMidX,
        (44 - size.height) / 2, size.width, size.height);
    if (!CGRectEqualToRect(self.content.frame, frame)) self.content.frame = frame;
}
- (void)publishSize {
    if ([self deferGeometryForNativeMenu]) return;
    self.barItem.width = self.intrinsicContentSize.width;
    CGRect frame = self.frame;
    frame.size = self.intrinsicContentSize;
    self.frame = frame;
    [self layoutIfNeeded];
}
- (void)displayExpanded:(BOOL)expanded {
    if ([self deferGeometryForNativeMenu]) return;
    CGFloat width = expanded ? self.expandedWidth : 44;
    self.surface.frame = CGRectMake(self.bounds.size.width - width, (self.bounds.size.height - 44) / 2, width, 44);
    [self layoutContent];
}
- (void)animateIconsExpanded:(BOOL)expanded entering:(BOOL)entering {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:self.content];
    NSHashTable<CALayer *> *liveLayers = [NSHashTable weakObjectsHashTable];
    for (NSUInteger i = 0; i < queue.count; i++) {
        UIView *view = queue[i];
        if (view == self.more) continue; // The one original More never animates.
        if (![view isKindOfClass:UIButton.class]) {
            [queue addObjectsFromArray:view.subviews];
            continue;
        }
        UIButton *button = (id)view;
        UIImageView *glyph = button.imageView;
        if (!glyph.image) continue;
        CALayer *layer = glyph.layer;
        [liveLayers addObject:layer];
        CGFloat distance = self.moreMidX - CGRectGetMidX([button convertRect:button.bounds toView:self.content]);
        // Drift from the disclosure side, but don't cross into the More glyph.
        CGFloat offset = MIN(18, MAX(0, distance - 32));
        BOOL continuing = [layer animationForKey:self.iconMotionKey] != nil;
        CALayer *presentation = layer.presentationLayer;
        CGFloat fromX = (expanded && entering) ? offset : 0;
        CGFloat fromOpacity = (expanded && entering) ? -1 : 0;
        if (continuing && presentation) {
            fromX = [[presentation valueForKeyPath:@"transform.translation.x"] doubleValue] -
                [[layer valueForKeyPath:@"transform.translation.x"] doubleValue];
            fromOpacity = presentation.opacity - layer.opacity;
        }
        CASpringAnimation *motion = ApolloActionsSpring(@"transform.translation.x");
        motion.additive = YES;
        motion.fromValue = @(fromX);
        motion.toValue = @(expanded ? 0 : offset);
        CASpringAnimation *opacity = ApolloActionsSpring(@"opacity");
        opacity.additive = YES;
        opacity.fromValue = @(fromOpacity);
        opacity.toValue = @(expanded ? 0 : -1);
        // Hold until completion clips the strip, then remove both animations.
        // Leave model visibility/transform untouched for navigation and app snapshots.
        for (CAAnimation *animation in @[motion, opacity]) {
            animation.fillMode = kCAFillModeForwards;
            animation.removedOnCompletion = NO;
        }
        [layer addAnimation:motion forKey:self.iconMotionKey];
        [layer addAnimation:opacity forKey:self.iconOpacityKey];
    }
    for (CALayer *layer in self.animatedIconLayers) {
        if ([liveLayers containsObject:layer]) continue;
        [layer removeAnimationForKey:self.iconMotionKey];
        [layer removeAnimationForKey:self.iconOpacityKey];
    }
    self.animatedIconLayers = liveLayers;
}
- (void)removeIconAnimations {
    for (CALayer *layer in self.animatedIconLayers) {
        [layer removeAnimationForKey:self.iconMotionKey];
        [layer removeAnimationForKey:self.iconOpacityKey];
    }
    [self.animatedIconLayers removeAllObjects];
}
- (void)applyExpanded:(BOOL)expanded {
    if ([self deferGeometryForNativeMenu]) return;
    self.expanded = expanded;
    self.isAccessibilityElement = !expanded;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.content.accessibilityElementsHidden = expanded ? self.originalAccessibilityHidden : YES;
    [self remeasure];
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Keep drawing the real More; route taps to Apollo only after expansion settles.
    return hit && (!self.expanded || self.owner.animator) ? self : hit;
}
- (BOOL)accessibilityActivate { [self.owner setExpanded:YES animated:YES]; return YES; }
- (void)reveal:(id)sender { [self.owner setExpanded:YES animated:YES]; }
- (void)dealloc {
    [self removeIconAnimations];
    if (self.content.superview == self.surface.contentView) self.content.accessibilityElementsHidden = self.originalAccessibilityHidden;
}
@end

static UINavigationController *ApolloActionsNavigation(UINavigationBar *bar) {
    for (UIResponder *responder = bar.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UINavigationController.class]) return (id)responder;
    }
    return nil;
}

static BOOL ApolloActionsAppController(UIViewController *controller) {
    return [NSStringFromClass(controller.class) hasPrefix:@"Apollo."] ||
        [NSStringFromClass(controller.navigationController.class) hasPrefix:@"Apollo."];
}

static ApolloNavigationActionsOwner *ApolloActionsOwner(UINavigationItem *item, BOOL create) {
    if (!item) return nil;
    ApolloNavigationActionsOwner *owner = objc_getAssociatedObject(item, &kActionsOwnerKey);
    ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
    if (!owner && create) {
        owner = [ApolloNavigationActionsOwner new];
        owner.item = item;
        owner.controller = box.controller;
        // Choose the initial state before native items are prepared. Applying
        // the global expanded default first briefly publishes the whole Inbox
        // group before the per-page disclosure policy can collapse it.
        owner.collapsePreference = [owner collapseEnabled];
        owner.expanded = !owner.collapsePreference;
        objc_setAssociatedObject(item, &kActionsOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (box.controller) owner.controller = box.controller;
    return owner;
}

static void ApolloActionsSetScrollOwner(UIPanGestureRecognizer *pan, ApolloNavigationActionsOwner *owner) {
    ApolloNavigationActionsScrollOwnerBox *box = objc_getAssociatedObject(pan, &kActionsScrollOwnerKey);
    ApolloNavigationActionsOwner *previous = box.owner;
    if (previous == owner) return;
    if (previous) {
        [pan removeTarget:previous action:@selector(scrolled:)];
        [previous.pans removeObject:pan];
    }
    if (owner) {
        if (!box) box = [ApolloNavigationActionsScrollOwnerBox new];
        box.owner = owner;
        [pan addTarget:owner action:@selector(scrolled:)];
        [owner.pans addObject:pan];
    }
    objc_setAssociatedObject(pan, &kActionsScrollOwnerKey, owner ? box : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloActionsUpdateScrollOwner(UIScrollView *scrollView) {
    ApolloNavigationActionsOwner *owner = nil;
    if (scrollView.window) {
        // Incoming pages can attach before becoming topViewController. Start
        // at the first owning controller, then follow containment to support
        // child pages without crossing a modal's responder chain into the
        // presenting feed and collapsing its navigation actions.
        for (UIResponder *responder = scrollView.nextResponder; responder; responder = responder.nextResponder) {
            if (![responder isKindOfClass:UIViewController.class]) continue;
            for (UIViewController *controller = (UIViewController *)responder;
                 controller; controller = controller.parentViewController) {
                owner = ApolloActionsOwner(controller.navigationItem, NO);
                if (owner) break;
            }
            break;
        }
    }
    ApolloActionsSetScrollOwner(scrollView.panGestureRecognizer, owner);
}

// Apollo's feed header exposes moderator, sort, and More as buttons inside one
// custom UIBarButtonItem. That works across a horizontal navigation bar, but
// UIKit cannot adapt the single 119pt custom view into Duo's vertical trailing
// platter. Inbox uses separate native items, which UIKit automatically moves
// above the right-side tab bar. Mirror that model on Closed Duo while retaining
// Apollo's original button targets, images, accessibility labels, and menus.
static void ApolloActionsCollectButtons(UIView *root, NSMutableArray<UIButton *> *buttons) {
    if ([root isKindOfClass:UIButton.class]) [buttons addObject:(UIButton *)root];
    for (UIView *child in root.subviews) ApolloActionsCollectButtons(child, buttons);
}

static BOOL ApolloActionsArraysIdentical(NSArray *a, NSArray *b) {
    if (a == b) return YES;
    if (a.count != b.count) return NO;
    for (NSUInteger index = 0; index < a.count; index++) {
        if (a[index] != b[index]) return NO;
    }
    return YES;
}

static BOOL ApolloActionsIsDuoFeedControl(UINavigationItem *item, UIBarButtonItem *candidate) {
    if ([candidate.accessibilityIdentifier isEqualToString:@"ApolloDuoFeedControl"] ||
        [candidate.accessibilityIdentifier isEqualToString:@"ApolloDuoCommentsLayoutControl"]) return YES;
    if (@available(iOS 27.0, *)) return candidate == item.searchBarPlacementBarButtonItem;
    return NO;
}

static NSArray<UIBarButtonItem *> *ApolloActionsWithoutDuoFeedControls(UINavigationItem *item, NSArray<UIBarButtonItem *> *items) {
    NSMutableArray *actions = [NSMutableArray array];
    for (UIBarButtonItem *candidate in items) {
        if (!ApolloActionsIsDuoFeedControl(item, candidate)) [actions addObject:candidate];
    }
    return actions;
}

static BOOL ApolloActionsHasTrailingTabRail(void) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    if (![tabs isKindOfClass:UITabBarController.class] || !tabs.isViewLoaded) return NO;
    UITabBar *bar = tabs.tabBar;
    CGRect frame = [bar convertRect:bar.bounds toView:tabs.view];
    return CGRectGetWidth(frame) < 100.0 && CGRectGetHeight(frame) > 400.0 &&
        CGRectGetMaxX(frame) >= CGRectGetWidth(tabs.view.bounds) - 2.0;
}

static UIBarButtonItem *ApolloActionsProfileItem(UIViewController *controller,
                                                  const char *name) {
    Ivar ivar = class_getInstanceVariable(controller.class, name);
    id value = ivar ? object_getIvar(controller, ivar) : nil;
    return [value isKindOfClass:UIBarButtonItem.class] ? value : nil;
}

static UIBarButtonItem *ApolloActionsProfileVisibleMoreItem(UIViewController *controller,
                                                             UIBarButtonItem *accounts) {
    // The signed-in profile installs Apollo Reborn's own UIMenu-backed
    // ellipsis; other profiles install Apollo's stored moreOptions item.
    // Prefer the live item already published by the navigation controller so
    // moving it into the Duo rail cannot replace a working menu with Apollo's
    // dormant own-profile item.
    NSArray *items = [(controller.navigationItem.rightBarButtonItems ?: @[])
        arrayByAddingObjectsFromArray:controller.navigationItem.leftBarButtonItems ?: @[]];
    for (UIBarButtonItem *item in items) {
        if (item == accounts) continue;
        NSString *label = item.accessibilityLabel.lowercaseString;
        BOOL looksLikeMore = item.menu != nil
            || [label containsString:@"more"]
            || item.action == NSSelectorFromString(@"moreOptionsBarButtonItemTappedWithSender:");
        if (looksLikeMore) return item;
    }
    return ApolloActionsProfileItem(controller, "moreOptionsBarButtonItem");
}

static void ApolloActionsApplyDuoProfileItems(UIViewController *controller) {
    if (!IsLiquidGlass() || !controller) return;
    // The Account sidebar has a horizontal bar of its own. Its controls do
    // not belong to the detail pane's trailing rail: keep Accounts on the
    // leading side so the scrolled profile title has room between the groups.
    BOOL sidebar = ApolloDuoSplitIsSidebarController(controller);
    BOOL trailingRail = ApolloActionsHasTrailingTabRail() && !ApolloDuoSplitIsUnfoldedPortrait() && !sidebar;
    BOOL previouslyApplied = [objc_getAssociatedObject(controller, &kActionsDuoProfileAppliedKey) boolValue];
    if (!trailingRail && !previouslyApplied && !sidebar) return;
    UIBarButtonItem *accounts = ApolloActionsProfileItem(controller, "accountsBarButtonItem");
    UIBarButtonItem *more = ApolloActionsProfileVisibleMoreItem(controller, accounts);
    if (!accounts || !more) return;

    // The rail moves Accounts to the right and replaces its text with a glyph.
    // Undo both changes when returning to a horizontal bar, including rotation
    // to unfolded portrait without another viewWillAppear callback.
    if (!trailingRail) {
        // The fully open sidebar is narrower than the half-fold column. Use
        // the existing Accounts glyph there, still on the leading side, so
        // the username fits in the title bar. Pair More with Accounts on the
        // leading side in this narrow column, balancing the sidebar toggle.
        BOOL compactSidebar = sidebar && CGRectGetWidth(controller.viewIfLoaded.bounds) < 380.0;
        UIImage *image = compactSidebar ? [UIImage systemImageNamed:@"person.2"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18.0
                weight:UIImageSymbolWeightRegular]] : nil;
        if (compactSidebar != (accounts.image != nil)) accounts.image = image;
        NSString *title = compactSidebar ? nil : @"Accounts";
        if (accounts.title != title && ![accounts.title isEqualToString:title]) accounts.title = title;
        accounts.accessibilityLabel = @"Accounts";
        if (@available(iOS 27.1, *)) {
            accounts.axisBehavior = UIBarButtonItemAxisBehaviorAutomatic;
            more.axisBehavior = UIBarButtonItemAxisBehaviorAutomatic;
        }
        if (@available(iOS 26.0, *)) {
            accounts.sharesBackground = compactSidebar;
            more.sharesBackground = compactSidebar;
        }
        NSMutableArray *right = [controller.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
        [right removeObjectIdenticalTo:accounts];
        [right removeObjectIdenticalTo:more];
        if (!compactSidebar) [right addObject:more];
        NSMutableArray *left = [controller.navigationItem.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
        [left removeObjectIdenticalTo:accounts];
        [left removeObjectIdenticalTo:more];
        [left insertObject:accounts atIndex:0];
        if (compactSidebar) [left insertObject:more atIndex:1];
        if (!ApolloActionsArraysIdentical(controller.navigationItem.leftBarButtonItems, left)) {
            [controller.navigationItem setLeftBarButtonItems:left animated:NO];
        }
        // Publish the leading placement first so the profile-menu normalizer
        // recognizes the move when the trailing array is updated.
        if (!ApolloActionsArraysIdentical(controller.navigationItem.rightBarButtonItems, right)) {
            [controller.navigationItem setRightBarButtonItems:right animated:NO];
        }
        objc_setAssociatedObject(controller, &kActionsDuoProfileAppliedKey, sidebar ? @YES : nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (previouslyApplied && accounts.image && accounts.title == nil &&
        ![controller.navigationItem.leftBarButtonItems containsObject:accounts] &&
        ApolloActionsArraysIdentical(controller.navigationItem.rightBarButtonItems, @[accounts, more])) return;

    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                        weight:UIImageSymbolWeightRegular];
    UIImage *icon = [[UIImage systemImageNamed:@"person.2"
                               withConfiguration:configuration]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    accounts.title = nil;
    accounts.image = icon;
    accounts.accessibilityLabel = @"Accounts";
    if (@available(iOS 26.0, *)) {
        accounts.identifier = @"ApolloReborn.duo-profile.accounts";
        more.identifier = @"ApolloReborn.duo-profile.more";
        accounts.hidesSharedBackground = NO;
        more.hidesSharedBackground = NO;
        accounts.sharesBackground = NO;
        more.sharesBackground = NO;
    }
    if (@available(iOS 27.1, *)) {
        accounts.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
        more.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
    }

    NSMutableArray<UIBarButtonItem *> *left =
        [controller.navigationItem.leftBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [left removeObjectIdenticalTo:accounts];
    [left removeObjectIdenticalTo:more];
    if (!ApolloActionsArraysIdentical(controller.navigationItem.leftBarButtonItems, left)) {
        controller.navigationItem.leftBarButtonItems = left;
    }

    // rightBarButtonItems[0] occupies the bottom of iOS 27's vertical group.
    // Accounts therefore comes first in the model so the visible order is
    // More, then Accounts, directly above the tab rail.
    NSArray<UIBarButtonItem *> *items = @[accounts, more];
    if (!ApolloActionsArraysIdentical(controller.navigationItem.rightBarButtonItems, items)) {
        [controller.navigationItem setRightBarButtonItems:items animated:NO];
    }
    objc_setAssociatedObject(controller, &kActionsDuoProfileAppliedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloActionsClearDuoProfileTrailingCells(UIViewController *controller);

static void ApolloActionsScheduleDuoProfileItems(UIViewController *controller) {
    if (!controller || [objc_getAssociatedObject(controller, &kActionsDuoProfileRefreshKey) boolValue]) return;
    objc_setAssociatedObject(controller, &kActionsDuoProfileRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        objc_setAssociatedObject(strongController, &kActionsDuoProfileRefreshKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloActionsApplyDuoProfileItems(strongController);
        ApolloActionsClearDuoProfileTrailingCells(strongController);
    });
}

static UITableView *ApolloActionsProfileTable(UIView *view, NSInteger depth) {
    if (!view || depth < 0) return nil;
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *table = ApolloActionsProfileTable(subview, depth - 1);
        if (table) return table;
    }
    return nil;
}

static void ApolloActionsRestoreProfileSelection(UITableViewCell *cell) {
    UIView *selection = cell.selectedBackgroundView;
    CALayer *mask = objc_getAssociatedObject(selection, &kActionsDuoProfileSelectionMaskKey);
    if (!mask) return;
    if (selection.layer.mask == mask) {
        id original = objc_getAssociatedObject(selection, &kActionsDuoProfileOriginalSelectionMaskKey);
        selection.layer.mask = original == NSNull.null ? nil : original;
    }
    objc_setAssociatedObject(selection, &kActionsDuoProfileSelectionMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(selection, &kActionsDuoProfileOriginalSelectionMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIColor *ApolloActionsProfileCellNativeColor(UITableViewCell *cell) {
    SEL nodeSelector = NSSelectorFromString(@"node");
    id node = [cell respondsToSelector:nodeSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector) : nil;
    if ([node respondsToSelector:@selector(backgroundColor)]) {
        // The UIKit wrapper is deliberately clear beside a Duo rail. Texture's
        // current node color remains the source of truth, also after reuse or a
        // theme change. Transparent headers must keep their transparency.
        return ((UIColor *(*)(id, SEL))objc_msgSend)(node, @selector(backgroundColor))
            ?: UIColor.clearColor;
    }
    return objc_getAssociatedObject(cell, &kActionsDuoProfileCellColorKey)
        ?: cell.backgroundColor ?: UIColor.clearColor;
}

static void ApolloActionsClipProfileSelection(UITableViewCell *cell) {
    UIView *selection = cell.selectedBackgroundView;
    if (!selection) return;
    SEL nodeSelector = NSSelectorFromString(@"node");
    id node = [cell respondsToSelector:nodeSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector) : nil;
    if (!IsLiquidGlass() || !ApolloActionsHasTrailingTabRail()
        || ![node isKindOfClass:NSClassFromString(@"Apollo.ProfileFeatureCellNode")]
        || CGRectGetWidth(cell.bounds) - CGRectGetWidth(cell.contentView.bounds) < 1.0) {
        ApolloActionsRestoreProfileSelection(cell);
        return;
    }

    // Apollo highlights the shortcut inside its narrowed content view, but
    // UIKit also paints a full-width selected background behind the rail.
    // Clip that background, retaining Apollo's highlight and touch handling.
    CAShapeLayer *mask = objc_getAssociatedObject(selection, &kActionsDuoProfileSelectionMaskKey);
    if (!mask) {
        objc_setAssociatedObject(selection, &kActionsDuoProfileOriginalSelectionMaskKey,
                                 selection.layer.mask ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        mask = [CAShapeLayer layer];
        objc_setAssociatedObject(selection, &kActionsDuoProfileSelectionMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGRect content = [selection convertRect:cell.contentView.bounds fromView:cell.contentView];
    CGRect clip = selection.bounds;
    clip.origin.x = CGRectGetMinX(content);
    clip.size.width = CGRectGetWidth(content);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = selection.bounds;
    mask.path = [UIBezierPath bezierPathWithRect:clip].CGPath;
    selection.layer.mask = mask;
    [CATransaction commit];
}

static void ApolloActionsRestoreProfileCellBackground(UITableViewCell *cell) {
    UIView *background = objc_getAssociatedObject(cell, &kActionsDuoProfileCellBackgroundKey);
    if (!background) return;
    cell.backgroundColor = ApolloActionsProfileCellNativeColor(cell);
    id original = objc_getAssociatedObject(cell, &kActionsDuoProfileBackgroundColorKey);
    cell.backgroundView.backgroundColor = original == NSNull.null ? nil : original;
    [background removeFromSuperview];
    objc_setAssociatedObject(cell, &kActionsDuoProfileCellBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kActionsDuoProfileCellColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kActionsDuoProfileBackgroundColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloActionsClearDuoProfileTrailingCells(UIViewController *controller) {
    if (!IsLiquidGlass() || !controller.isViewLoaded) return;
    UITableView *table = ApolloActionsProfileTable(controller.view, 5);
    for (UITableViewCell *cell in table.visibleCells) ApolloActionsClipProfileSelection(cell);
    BOOL trailingRail = ApolloActionsHasTrailingTabRail();
    BOOL sidebar = ApolloDuoSplitIsSidebarController(controller);
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    UITabBar *tabBar = [tabs isKindOfClass:UITabBarController.class] ? tabs.tabBar : nil;
    for (UITableViewCell *cell in table.visibleCells) {
        CGFloat cellWidth = CGRectGetWidth(cell.bounds);
        CGFloat contentWidth = CGRectGetMaxX(cell.contentView.frame);
        if (!trailingRail || cellWidth - contentWidth < 1.0 || contentWidth < 1.0) {
            ApolloActionsRestoreProfileCellBackground(cell);
            continue;
        }

        // Apollo's content view stops an extra grouped margin before the Duo
        // rail. That made this wrapper end 15 points before the stat cards.
        // Draw the wrapper to the same rail-relative edge as the header while
        // leaving Apollo's labels, chevrons, and hit testing untouched.
        CGFloat surfaceWidth = contentWidth;
        if (!sidebar && tabBar.window && cell.window) {
            CGRect tabBarFrame = [tabBar convertRect:tabBar.bounds toView:cell];
            CGFloat railRelativeWidth = CGRectGetMinX(tabBarFrame) - 15.0;
            if (railRelativeWidth > contentWidth && railRelativeWidth < cellWidth) {
                surfaceWidth = railRelativeWidth;
            }
        }

        UIColor *nativeColor = ApolloActionsProfileCellNativeColor(cell);
        if (!objc_getAssociatedObject(cell, &kActionsDuoProfileCellColorKey)) {
            objc_setAssociatedObject(cell, &kActionsDuoProfileCellColorKey, nativeColor,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(cell, &kActionsDuoProfileBackgroundColorKey,
                                     cell.backgroundView.backgroundColor ?: NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *background = objc_getAssociatedObject(cell, &kActionsDuoProfileCellBackgroundKey);
        if (!background) {
            background = [[UIView alloc] initWithFrame:CGRectZero];
            background.userInteractionEnabled = NO;
            objc_setAssociatedObject(cell, &kActionsDuoProfileCellBackgroundKey, background,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [cell insertSubview:background atIndex:0];
        }
        background.backgroundColor = nativeColor;
        background.frame = CGRectMake(0.0, 0.0, surfaceWidth, CGRectGetHeight(cell.bounds));
        background.layer.cornerRadius = 16.0;
        background.layer.masksToBounds = YES;
        if (@available(iOS 13.0, *)) {
            background.layer.cornerCurve = kCACornerCurveContinuous;
        }
        cell.backgroundColor = UIColor.clearColor;
        cell.backgroundView.backgroundColor = UIColor.clearColor;
    }
}

static UIBarButtonItem *ApolloActionsNativeItemForDuoButton(UIButton *button, NSUInteger index) {
    UIImage *image = [button imageForState:UIControlStateNormal] ?: button.currentImage;
    image = ApolloActionsTemplateImage(image);
    id target = nil;
    SEL action = NULL;
    for (id candidate in button.allTargets) {
        NSArray<NSString *> *actions = [button actionsForTarget:candidate
                                                forControlEvent:UIControlEventTouchUpInside];
        if (actions.count) {
            target = candidate;
            action = NSSelectorFromString(actions.firstObject);
            break;
        }
    }

    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:image
                                                               style:UIBarButtonItemStylePlain
                                                              target:target
                                                              action:action];
    if (!target || !action) {
        __weak UIButton *weakButton = button;
        item.primaryAction = [UIAction actionWithTitle:button.accessibilityLabel ?: @""
                                                image:image
                                           identifier:nil
                                              handler:^(__unused UIAction *nativeAction) {
            [weakButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        }];
    }
    if (button.menu && button.showsMenuAsPrimaryAction) {
        item.target = nil;
        item.action = nil;
        item.primaryAction = nil;
        item.menu = button.menu;
    }
    item.enabled = button.enabled;
    item.accessibilityLabel = button.accessibilityLabel;
    item.accessibilityHint = button.accessibilityHint;
    if (@available(iOS 26.0, *)) {
        item.identifier = [NSString stringWithFormat:@"ApolloReborn.duo-navigation-action.%lu",
                           (unsigned long)index];
        item.hidesSharedBackground = NO;
        item.sharesBackground = YES;
    }
    if (@available(iOS 27.1, *)) {
        item.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
    }
    // The original composite item retains the button as well, but holding it
    // here makes the forwarding relationship explicit across UIKit rebuilds.
    objc_setAssociatedObject(item, &kActionsDuoSourceButtonKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Apollo changes the original sort UIButton in place. The generated
    // native item must remain a live mirror, including while collapsed.
    // Weak destinations avoid a cycle with the item's retained source button.
    NSHashTable<UIBarButtonItem *> *mirrors = objc_getAssociatedObject(button, &kActionsDuoMirroredItemsKey);
    if (!mirrors) {
        mirrors = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(button, &kActionsDuoMirroredItemsKey, mirrors,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [mirrors addObject:item];
    return item;
}

static NSArray<UIBarButtonItem *> *ApolloActionsDuoNativeItems(UINavigationItem *item,
                                                               NSArray<UIBarButtonItem *> *items) {
    items = ApolloNativeFeedSearchDuoTrailingItems(item, items);
    items = ApolloDuoCommentsLayoutItems(item, items);
    ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
    // Inbox owns its reversible compact/native mapping below.
    if ([NSStringFromClass(box.controller.class) isEqualToString:@"Apollo.InboxViewController"]) return items;
    NSArray *generated = objc_getAssociatedObject(item, &kActionsDuoNativeItemsKey);
    NSArray *original = objc_getAssociatedObject(item, &kActionsDuoOriginalItemsKey);
    int duoMode = ApolloDuoCurrentMode();
    // UIKit briefly publishes Phone while replacing a feed's navigation model.
    // Keep native items across that transient. Portrait restores the compact
    // composite so its original glyph spacing survives the axis change.
    BOOL closedDuo = !ApolloDuoSplitIsUnfoldedPortrait()
        && (duoMode == ApolloDuoModeClosed || ApolloActionsHasTrailingTabRail()
            || (duoMode == ApolloDuoModePhone && generated != nil));
    if (!closedDuo) {
        ApolloNavigationActionsOwner *owner = ApolloActionsOwner(item, NO);
        // A collapsed rail publishes only its generated More item, retaining
        // the remaining actions in the owner. It is still our native model:
        // restore its compact composite before discarding the mapping, or
        // portrait keeps a VerticalPreferred rail item and loses the strip.
        NSArray *actions = ApolloActionsWithoutDuoFeedControls(item, items);
        NSArray *generatedActions = ApolloActionsWithoutDuoFeedControls(item, generated);
        BOOL collapsedGenerated = actions.count == 1 && owner.standardItems.count > 0
            && actions.firstObject == owner.moreItem && [generated containsObject:owner.moreItem];
        if (generated && original &&
            (ApolloActionsArraysIdentical(actions, generatedActions) || collapsedGenerated)) {
            // Layout disappears in portrait. Changes to the host
            // controls must not prevent restoring the composite,
            // or its separate rail items keep UIKit's wider horizontal slots.
            // Keep the live controls instead of resurrecting the cached ones.
            NSArray *originalActions = ApolloActionsWithoutDuoFeedControls(item, original);
            NSMutableArray *restored = [NSMutableArray array];
            BOOL insertedActions = NO;
            for (UIBarButtonItem *candidate in items) {
                if (ApolloActionsIsDuoFeedControl(item, candidate)) {
                    [restored addObject:candidate];
                } else if (!insertedActions) {
                    [restored addObjectsFromArray:originalActions];
                    insertedActions = YES;
                }
            }
            items = restored;
        }
        objc_setAssociatedObject(item, &kActionsDuoNativeItemsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, &kActionsDuoOriginalItemsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return items;
    }
    if (generated && ApolloActionsArraysIdentical(items, generated)) return items;

    NSMutableArray<UIBarButtonItem *> *result = [NSMutableArray array];
    BOOL converted = NO;
    for (UIBarButtonItem *barItem in items) {
        UIView *source = ApolloNavigationActionsContentView(barItem);
        UIButton *more = ApolloActionsFindMore(source);
        if (converted || !source || !more || ApolloActionsControlCount(source) < 2) {
            [result addObject:barItem];
            continue;
        }

        NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
        ApolloActionsCollectButtons(source, buttons);
        [buttons filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIButton *button,
                                                                          __unused NSDictionary *bindings) {
            return !button.hidden && button.alpha > 0.01 &&
                ([button imageForState:UIControlStateNormal] || button.currentImage);
        }]];
        [buttons sortUsingComparator:^NSComparisonResult(UIButton *left, UIButton *right) {
            CGFloat leftX = CGRectGetMidX([left convertRect:left.bounds toView:source]);
            CGFloat rightX = CGRectGetMidX([right convertRect:right.bounds toView:source]);
            if (leftX < rightX) return NSOrderedAscending;
            if (leftX > rightX) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        if (buttons.count < 2) {
            [result addObject:barItem];
            continue;
        }

        // rightBarButtonItems[0] is the trailing item. On a vertical platter
        // UIKit maps that edge to the bottom, so reverse the visual left-to-
        // right order to keep moderator/sort above More.
        for (NSUInteger reverse = buttons.count; reverse > 0; reverse--) {
            [result addObject:ApolloActionsNativeItemForDuoButton(buttons[reverse - 1], reverse - 1)];
        }
        converted = YES;
    }
    if (!converted) return items;

    NSArray *native = [result copy];
    objc_setAssociatedObject(item, &kActionsDuoOriginalItemsKey, [items copy],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(item, &kActionsDuoNativeItemsKey, native,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[NavigationActions] Split composite actions into %lu native Duo items on %@",
              (unsigned long)native.count,
              NSStringFromClass([objc_getAssociatedObject(item, &kActionsControllerKey) controller].class));
    return native;
}

static NSArray<UIBarButtonItem *> *ApolloActionsInboxItems(UINavigationItem *item, NSArray<UIBarButtonItem *> *items) {
    ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
    if (!IsLiquidGlass() || ![NSStringFromClass(box.controller.class) isEqual:@"Apollo.InboxViewController"]) return items;
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(item, YES);
    // The native Duo transition deliberately publishes @[More] while
    // collapsed. Do not strip that disclosure during our guarded model write.
    if (owner.preparing) return items;
    // The collapsed native model intentionally contains only the disclosure.
    // Preserve it during lifecycle refreshes instead of treating it as a lone
    // action to remove. Portrait reconstructs its compact group below.
    if (!ApolloDuoSplitIsUnfoldedPortrait() && items.count == 1 &&
        items.firstObject == owner.inboxDisclosure && owner.standardItems.count) return items;
    if (items.count == 1 && items.firstObject == owner.inboxCompactItem) items = owner.inboxNativeItems;
    // A rail collapse publishes only More, retaining the other native actions
    // in the owner. Recover them before rotating to the compact portrait pill.
    if (ApolloDuoSplitIsUnfoldedPortrait() && items.count == 1 &&
        items.firstObject == owner.inboxDisclosure && owner.standardItems.count) {
        NSMutableArray *restored = [NSMutableArray arrayWithObject:owner.inboxDisclosure];
        for (ApolloNavigationActionsStandardItem *entry in owner.standardItems) {
            if (entry.item) [restored addObject:entry.item];
        }
        items = restored;
    }
    NSMutableArray *native = [items mutableCopy] ?: [NSMutableArray array];
    if (owner.inboxDisclosure) [native removeObjectIdenticalTo:owner.inboxDisclosure];
    // Inbox compose/selection modes and lone actions need no added disclosure.
    if (box.controller.isEditing || native.count < 2) return native;
    NSUInteger actionable = 0;
    for (UIBarButtonItem *candidate in native) {
        if (ApolloActionsMoreName(candidate.accessibilityLabel) ||
            ApolloActionsMoreName(NSStringFromSelector(candidate.action))) return native;
        if (candidate.customView || [candidate.title isEqualToString:@"Cancel"] ||
            [candidate.title isEqualToString:@"Done"] || [candidate.title isEqualToString:@"Edit"]) return native;
        ApolloNavigationActionsStandardItem *state = objc_getAssociatedObject(candidate, &kActionsStandardItemKey);
        BOOL nativeHidden = state ? state.hidden : ApolloActionsItemHidden(candidate);
        if (!nativeHidden && (candidate.action || candidate.primaryAction || candidate.menu)) actionable++;
    }
    if (actionable < 2) return native;
    if (!owner.inboxDisclosure) {
        UIImage *image = [[UIImage imageNamed:@"option-more" inBundle:NSBundle.mainBundle compatibleWithTraitCollection:box.controller.traitCollection]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if (!image) return native;
        __weak ApolloNavigationActionsOwner *weakOwner = owner;
        owner.inboxDisclosure = [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain target:nil action:nil];
        owner.inboxDisclosure.accessibilityLabel = @"More Options";
        // Inbox has no native More menu; this button closes the expanded group.
        owner.inboxDisclosure.primaryAction = [UIAction actionWithTitle:@"" image:image identifier:nil handler:^(__unused UIAction *action) {
            [weakOwner setExpanded:NO animated:YES];
        }];
        if (@available(iOS 26.0, *)) {
            owner.inboxDisclosure.identifier = @"ApolloReborn.navigation-actions";
            owner.inboxDisclosure.hidesSharedBackground = NO;
            owner.inboxDisclosure.sharesBackground = YES;
        }
        if (@available(iOS 27.1, *)) {
            owner.inboxDisclosure.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
        }
    }
    [native insertObject:owner.inboxDisclosure atIndex:0];
    if (!ApolloDuoSplitIsUnfoldedPortrait()) return native;

    // Standard UIKit items add a 16pt gap between their 40pt slots. Use the
    // same 36pt slots and glass-owning strip as Apollo's composite post actions.
    // Keep native item identities/actions so editing and compose still go
    // through Apollo, and restore these items when the rail returns.
    [owner restoreStandardItems];
    if (!owner.inboxCompactItem || !ApolloActionsArraysIdentical(owner.inboxNativeItems, native)) {
        owner.inboxNativeItems = [native copy];
        UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, native.count * 36.0 + 8.0, 44)];
        NSUInteger slot = 0;
        for (UIBarButtonItem *source in native.reverseObjectEnumerator) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.frame = CGRectMake(4.0 + slot++ * 36.0, 0, 36, 44);
            if (source == owner.inboxDisclosure) {
                __weak ApolloNavigationActionsOwner *weakOwner = owner;
                [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
                    [weakOwner setExpanded:NO animated:YES];
                }] forControlEvents:UIControlEventTouchUpInside];
            } else if (source.primaryAction) {
                [button addAction:source.primaryAction forControlEvents:UIControlEventTouchUpInside];
            } else if (source.action) {
                [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
                    [UIApplication.sharedApplication sendAction:source.action to:source.target from:source forEvent:nil];
                }] forControlEvents:UIControlEventTouchUpInside];
            }
            button.menu = source.menu;
            button.showsMenuAsPrimaryAction = source.menu != nil && source.action == nil && source.primaryAction == nil;
            button.accessibilityLabel = source.accessibilityLabel ?: (
                [NSStringFromSelector(source.action) containsString:@"markAllRead"] ? @"Mark All Read" : @"New Message");
            [content addSubview:button];
        }
        owner.inboxCompactItem = [[UIBarButtonItem alloc] initWithCustomView:content];
    }
    UIView *content = ApolloNavigationActionsContentView(owner.inboxCompactItem);
    NSUInteger slot = 0;
    for (UIBarButtonItem *source in native.reverseObjectEnumerator) {
        UIButton *button = (UIButton *)content.subviews[slot++];
        [button setImage:source.image forState:UIControlStateNormal];
        button.enabled = source.enabled;
        button.hidden = ApolloActionsItemHidden(source);
    }
    return @[owner.inboxCompactItem];
}

@implementation ApolloNavigationActionsOwner
- (BOOL)collapseEnabled {
    // Inbox's added ellipsis is a disclosure, not an Apollo More menu. It must
    // remain toggleable even when other pages keep their actions expanded.
    return [NSStringFromClass(self.controller.class) isEqualToString:@"Apollo.InboxViewController"]
        || sCollapseNavigationActions;
}
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _collapsePreference = sCollapseNavigationActions;
    _expanded = !sCollapseNavigationActions;
    _standardItems = [NSMutableArray array];
    _pans = [NSHashTable weakObjectsHashTable];
    __weak typeof(self) weakSelf = self;
    _resignObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            // Finish our animation without retaining UIKit's transient hidden/alpha state.
            [weakSelf setExpanded:NO animated:NO];
        }];
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self.resignObserver];
    for (UIPanGestureRecognizer *pan in self.pans) [pan removeTarget:self action:@selector(scrolled:)];
    [self.backGesture removeTarget:self action:@selector(backGestureChanged:)];
    [self restoreStandardItems];
}
- (void)restoreStandardItems {
    sActionsModelWriteDepth++;
    for (ApolloNavigationActionsStandardItem *state in self.standardItems) {
        ApolloActionsSetItemHidden(state.item, state.hidden);
        objc_setAssociatedObject(state.item, &kActionsStandardItemKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self.standardItems removeAllObjects];
    if (self.moreItem) {
        objc_setAssociatedObject(self.moreItem, &kActionsStandardMoreKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloActionsSetPrimaryAction(self.moreItem, self.nativePrimaryAction);
        self.moreItem.menu = self.nativeMenu;
    }
    self.moreItem = nil;
    self.nativeMenu = nil;
    self.nativePrimaryAction = nil;
    sActionsModelWriteDepth--;
}
- (BOOL)deferGeometryUpdate {
    for (ApolloNavigationActionsStrip *strip in self.strips) {
        if (!ApolloNativeActionMenuOwnsNavigationSurface(strip.surface)) continue;
        if (!self.geometryDeferred) {
            self.geometryDeferred = YES;
            __weak typeof(self) weakSelf = self;
            ApolloNativeActionMenuDeferNavigationUpdate(strip.surface, @"navigation-actions.geometry", ^{
                ApolloNavigationActionsOwner *owner = weakSelf;
                if (!owner) return;
                owner.geometryDeferred = NO;
                // Setters may run during the menu; use the latest items on release.
                [owner prepareItems:owner.item.rightBarButtonItems];
                // A spring may have finished during native ownership; publish
                // its final width and remove held glyph animations as well.
                [owner settleAnimationIfNeeded];
            });
        }
        return YES;
    }
    return NO;
}
- (void)prepareItems:(NSArray<UIBarButtonItem *> *)items {
    if (self.preparing) return;
    // Search and the host's List/Split/Layout buttons are independent native
    // controls, never members of Apollo's expandable More action group.
    items = ApolloActionsWithoutDuoFeedControls(self.item, items);
    BOOL collapse = [self collapseEnabled];
    // Freeze all geometry and icon cleanup while UIKit owns the surface,
    // including late action insertion and overlapping menu sessions.
    if ([self deferGeometryUpdate]) return;
    // A collapsed native Duo group intentionally publishes only its More
    // item. Lifecycle refreshes must not mistake that presentation model for
    // a replacement and discard the retained actions needed to expand again.
    // The rail can be detached while a fold reparents this page. This is
    // still our collapsed model during that interval; testing rail geometry
    // here discarded the retained actions, then stripped the lone disclosure
    // on the next refresh, leaving Inbox with no buttons at all.
    if (self.moreItem && !self.expanded
        && self.standardItems.count > 0 && items.count == 1
        && items.firstObject == self.moreItem) {
        if (self.collapsePreference != collapse) {
            self.collapsePreference = collapse;
            [self setExpanded:!collapse animated:NO];
        }
        return;
    }
    self.preparing = YES;
    for (UIBarButtonItem *item in items) {
        if (item.action == NSSelectorFromString(@"cancelBarButtonItemTappedWithSender:") &&
            [NSStringFromClass(self.controller.class) isEqualToString:@"Apollo.PostsViewController"]) {
            // Search replaces these actions in the same update. Settle the old
            // strip now so dismissal restores it collapsed, without a second spring.
            [self setExpanded:NO animated:NO];
            break;
        }
    }
    BOOL retargetAnimation = NO;
    NSMutableArray *strips = [NSMutableArray array];
    ApolloNavigationActionsControllerBox *controllerBox = objc_getAssociatedObject(self.item, &kActionsControllerKey);
    BOOL approvedSubmitters = [NSStringFromClass(controllerBox.controller.class)
        isEqualToString:@"Apollo.ModeratorApprovedSubmittersViewController"];
    for (UIBarButtonItem *item in items) {
        // Legacy Done buttons become filled/prominent on Liquid Glass.
        if (ApolloActionsUsesPlainSubmitStyle(item) && item.style != UIBarButtonItemStylePlain) {
            item.style = UIBarButtonItemStylePlain;
        }
        if (ApolloActionsUsesPlainSubmitStyle(item)) {
            for (NSNumber *stateValue in @[@(UIControlStateNormal), @(UIControlStateDisabled)]) {
                UIControlState state = stateValue.unsignedIntegerValue;
                NSMutableDictionary *attributes = [[item titleTextAttributesForState:state] mutableCopy]
                    ?: [NSMutableDictionary dictionary];
                UIColor *color = ApolloNavigationChromeColor();
                if (state == UIControlStateDisabled) color = [color colorWithAlphaComponent:0.45];
                if (![attributes[NSForegroundColorAttributeName] isEqual:color]) {
                    attributes[NSForegroundColorAttributeName] = color;
                    [item setTitleTextAttributes:attributes forState:state];
                }
            }
        }
        BOOL duoSubredditsDone = NO;
        if (@available(iOS 26.0, *)) {
            duoSubredditsDone = controllerBox.controller.isEditing
                && [item.identifier isEqualToString:@"ApolloReborn.subreddits.edit"];
        }
        NSString *editingControllerClass = NSStringFromClass(controllerBox.controller.class);
        BOOL blueDone = duoSubredditsDone || (controllerBox.controller.isEditing &&
            ([editingControllerClass isEqualToString:@"Apollo.RedditListViewController"] ||
             [editingControllerClass isEqualToString:@"ApolloSettingsShortcutsViewController"]));
        objc_setAssociatedObject(item, &kActionsBlueDoneKey, @(blueDone), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL accentSubmit = ApolloActionsUsesAccentSubmitStyle(item);
        if (accentSubmit && !objc_getAssociatedObject(item, &kActionsAccentSubmitKey)) {
            ApolloLog(@"[NavigationActions] Accent-filled compose submit on %@ (target %@ action %@)",
                NSStringFromClass(self.controller.class), NSStringFromClass([item.target class]),
                NSStringFromSelector(item.action));
        }
        objc_setAssociatedObject(item, &kActionsAccentSubmitKey, @(accentSubmit), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloActionsPinChrome(item);
        UIImage *image = ApolloActionsTemplateImage(item.image);
        if (ApolloActionsHasTrailingTabRail() && ApolloActionsModeratorItem(item)
            && fabs(image.alignmentRectInsets.left - 2.0) > 0.1) {
            // Apollo's shield asset has slightly heavier transparent space on
            // its left edge. Center its visible artwork in the native pill.
            image = [image imageWithAlignmentRectInsets:UIEdgeInsetsMake(0.0, 2.0, 0.0, 0.0)];
        }
        if (image != item.image) item.image = image;
        UIView *source = ApolloNavigationActionsContentView(item);
        if (approvedSubmitters) ApolloActionsPrepareApprovedContent(source);
        ApolloActionsApplyChromeToView(source, blueDone);
        ApolloNavigationActionsStrip *strip = [item.customView isKindOfClass:ApolloNavigationActionsStrip.class]
            ? (id)item.customView : nil;
        UIButton *more = strip.more ?: ApolloActionsFindMore(source);
        if (!strip && more && ApolloActionsControlCount(source) > 1) {
            // Apollo rebuilds its container using the same buttons on return.
            // Keep the displayed surface alive while UIKit hands off the item.
            for (ApolloNavigationActionsStrip *existing in self.strips) {
                if (existing.more == more) { strip = existing; break; }
            }
            if (strip) {
                [strip removeIconAnimations];
                [strip.content removeFromSuperview];
                strip.content = source;
                strip.originalAccessibilityHidden = source.accessibilityElementsHidden;
            } else {
                strip = [[ApolloNavigationActionsStrip alloc] initWithContent:source more:more];
            }
            if (ApolloDuoSplitIsUnfoldedPortrait() && !self.animator) {
                // The constructor starts at the collapsed 44pt width. Publish
                // the actual width BEFORE UIKit adopts the custom view: the
                // Duo host caches that first size when reserving the trailing
                // status region. Expanding only the intrinsic constraint later
                // lets a wider capsule overflow its original host allocation.
                strip.owner = self;
                strip.barItem = item;
                [strip applyExpanded:self.expanded];
                [strip publishSize];
                if (@available(iOS 27.1, *)) {
                    item.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
                }
            }
            item.customView = strip;
            // setCustomView: detaches the old view even if reparented; adopt it afterward.
            [strip.surface.contentView addSubview:source];
            // Hide the item's default glass, not ancestor views, to avoid double glass.
            if (@available(iOS 26.0, *)) item.hidesSharedBackground = YES;
            // Match native transitions without sharing views between pages.
            if (@available(iOS 26.0, *)) {
                if (!item.identifier) item.identifier = @"ApolloReborn.navigation-actions";
            }
            ApolloLog(@"[NavigationActions] Installed native item strip on %@", NSStringFromClass(self.controller.class));
        }
        if (strip) {
            strip.owner = self;
            strip.barItem = item;
            if (ApolloDuoSplitIsUnfoldedPortrait()) {
                // Restoring an existing strip skips the constructor path
                // above. Normalize its axis before UIKit refits the group
                // beside the portrait status region as well.
                if (@available(iOS 27.1, *)) {
                    if (item.axisBehavior != UIBarButtonItemAxisBehaviorHorizontalOnly) {
                        item.axisBehavior = UIBarButtonItemAxisBehaviorHorizontalOnly;
                    }
                }
            }
            CGFloat previousWidth = strip.expandedWidth;
            CGFloat previousMoreMidX = strip.moreMidX;
            if (!self.animator) {
                [strip applyExpanded:self.expanded];
                // Animate late slots from the current pill/title presentation,
                // rather than publishing the new width immediately.
                if (self.expanded && fabs(previousWidth - strip.expandedWidth) > 0.01) {
                    self.needsGeometryTransition = YES;
                    retargetAnimation = YES;
                } else {
                    // Also settle an existing strip returning from the rail.
                    // Keep item.width, bounds and intrinsic size identical so
                    // UIKit positions the entire tight group before the status.
                    if (ApolloDuoSplitIsUnfoldedPortrait()) [strip publishSize];
                    [strip displayExpanded:self.expanded];
                }
            } else {
                [strip remeasure];
                retargetAnimation |= fabs(previousWidth - strip.expandedWidth) > 0.01 ||
                    fabs(previousMoreMidX - strip.moreMidX) > 0.01 || ![self.strips containsObject:strip];
            }
            [strips addObject:strip];
        }
    }
    retargetAnimation |= self.animator && self.strips.count != strips.count;
    // Buttons may move to a new container while UIKit retains the outgoing strip.
    // Remove their old effects immediately.
    for (ApolloNavigationActionsStrip *oldStrip in self.strips) {
        if (![strips containsObject:oldStrip]) [oldStrip removeIconAnimations];
    }
    self.strips = strips;
    // Non-custom items use item.hidden; lone actions and pages without More stay native.
    UIBarButtonItem *more = items.firstObject;
    BOOL standard = strips.count == 0 && items.count > 1 && !more.customView &&
        (ApolloActionsMoreName(more.accessibilityLabel) || ApolloActionsMoreName(NSStringFromSelector(more.action)));
    BOOL same = standard && more == self.moreItem && self.standardItems.count == items.count - 1;
    if (same) {
        for (NSUInteger i = 1; i < items.count; i++) if (self.standardItems[i - 1].item != items[i]) same = NO;
    }
    if (!same) {
        [self restoreStandardItems];
        if (standard) {
            self.moreItem = more;
            self.nativeMenu = more.menu;
            self.nativePrimaryAction = more.primaryAction;
            ApolloNavigationActionsStandardItem *moreState = [ApolloNavigationActionsStandardItem new];
            moreState.item = more; moreState.owner = self;
            objc_setAssociatedObject(more, &kActionsStandardMoreKey, moreState, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (NSUInteger i = 1; i < items.count; i++) {
                ApolloNavigationActionsStandardItem *state = [ApolloNavigationActionsStandardItem new];
                state.item = items[i]; state.owner = self; state.hidden = ApolloActionsItemHidden(items[i]);
                objc_setAssociatedObject(items[i], &kActionsStandardItemKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self.standardItems addObject:state];
            }
            if (@available(iOS 26.0, *)) {
                if (!more.identifier) more.identifier = @"ApolloReborn.navigation-actions";
                if (ApolloActionsHasTrailingTabRail()) {
                    more.hidesSharedBackground = NO;
                    more.sharesBackground = YES;
                    for (ApolloNavigationActionsStandardItem *state in self.standardItems) {
                        state.item.hidesSharedBackground = NO;
                        state.item.sharesBackground = YES;
                    }
                }
            }
            if (@available(iOS 27.1, *)) {
                if (ApolloActionsHasTrailingTabRail()) {
                    more.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
                    for (ApolloNavigationActionsStandardItem *state in self.standardItems) {
                        state.item.axisBehavior = UIBarButtonItemAxisBehaviorVerticalPreferred;
                    }
                }
            }
            [self applyStandardExpanded:self.expanded];
        }
    }
    // Keep preparation guarded while publishing size: UIKit synchronously
    // re-enters the item setters, which otherwise retarget the same expansion.
    if (self.collapsePreference != collapse) {
        self.collapsePreference = collapse;
        [self setExpanded:!collapse animated:NO];
    } else if (!collapse && !self.expanded) [self setExpanded:YES animated:NO];
    else if (retargetAnimation) [self setExpanded:self.expanded animated:YES];
    // prepareItems: runs both before and after UINavigationItem's original
    // setter. Publishing the collapsed model while handling the first call is
    // overwritten when that outer setter resumes. Reassert the desired model
    // here on the post-setter pass as well, so the final state is @[More]
    // whenever the collapse preference is enabled.
    NSArray<UIBarButtonItem *> *duoVisibleItems = nil;
    if (self.moreItem && self.strips.count == 0 && ApolloActionsHasTrailingTabRail()) {
        duoVisibleItems = [self duoStandardItemsForExpanded:self.expanded];
    }
    self.preparing = NO;
    if (duoVisibleItems &&
        !ApolloActionsArraysIdentical(self.item.rightBarButtonItems, duoVisibleItems)) {
        self.preparing = YES;
        [self.item setRightBarButtonItems:duoVisibleItems animated:NO];
        self.preparing = NO;
    }
    if (self.expanded) [self watchScrollViews];
}
- (void)applyStandardExpanded:(BOOL)expanded {
    sActionsModelWriteDepth++;
    BOOL nativeDuo = self.moreItem && self.strips.count == 0 && ApolloActionsHasTrailingTabRail();
    for (ApolloNavigationActionsStandardItem *state in self.standardItems) {
        // The native Duo path changes the navigation item's membership. Keep
        // included actions visible so UIKit can animate them into the shared
        // vertical glass; ordinary phones still collapse through item.hidden.
        ApolloActionsSetItemHidden(state.item, state.hidden || (!nativeDuo && !expanded));
    }
    UIBarButtonItem *more = self.moreItem;
    if (more) {
        if (expanded) {
            ApolloActionsSetPrimaryAction(more, self.nativePrimaryAction);
            more.menu = self.nativeMenu;
        } else {
            UIImage *image = more.image;
            NSString *title = more.title;
            __weak typeof(self) weakSelf = self;
            more.menu = nil;
            ApolloActionsSetPrimaryAction(more, [UIAction actionWithTitle:title ?: @"" image:image identifier:nil
                handler:^(__unused UIAction *action) { [weakSelf setExpanded:YES animated:YES]; }]);
        }
    }
    sActionsModelWriteDepth--;
}
- (NSArray<UIBarButtonItem *> *)duoStandardItemsForExpanded:(BOOL)expanded {
    if (!self.moreItem) return @[];
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    for (UIBarButtonItem *candidate in self.item.rightBarButtonItems) {
        if (ApolloActionsIsDuoFeedControl(self.item, candidate)) [items addObject:candidate];
    }
    [items addObject:self.moreItem];
    if (expanded) {
        for (ApolloNavigationActionsStandardItem *state in self.standardItems) {
            if (!state.hidden) [items addObject:state.item];
        }
    }
    return items;
}
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    // All collapse entry points share the per-page policy.
    if (![self collapseEnabled]) expanded = YES;
    if (self.expanded == expanded && !self.animator && !self.needsGeometryTransition &&
        !self.needsAnimationSettlement) return;
    if (!expanded) {
        __weak typeof(self) weakSelf = self;
        for (ApolloNavigationActionsStrip *strip in self.strips) {
            if (ApolloNativeActionMenuDeferNavigationCollapse(strip.surface, ^{
                ApolloNavigationActionsOwner *owner = weakSelf;
                BOOL visible = owner.controller.navigationController.navigationBar.topItem == owner.item;
                // A final pan Changed may already have started collapse; don't restart it.
                if (owner.expanded) [owner setExpanded:NO animated:animated && visible];
            })) return;
        }
    } else {
        for (ApolloNavigationActionsStrip *strip in self.strips) {
            __weak typeof(self) weakSelf = self;
            if (ApolloNativeActionMenuDeferNavigationUpdate(strip.surface, @"navigation-actions.expansion", ^{
                ApolloNavigationActionsOwner *owner = weakSelf;
                BOOL visible = owner.controller.navigationController.navigationBar.topItem == owner.item;
                [owner setExpanded:YES animated:animated && visible];
            })) return;
        }
    }
    self.needsGeometryTransition = NO;
    // Supersede deferred settlement so it cannot snap or clean up this new transition.
    self.needsAnimationSettlement = NO;
    // Reversals begin from presentation state, not a guessed endpoint.
    UIViewPropertyAnimator *previous = self.animator;
    BOOL entering = !self.expanded || previous != nil;
    self.animator = nil;
    [previous stopAnimation:NO];
    [previous finishAnimationAtPosition:UIViewAnimatingPositionCurrent];
    if (self.strips.count == 0 && !self.moreItem) {
        self.expanded = ![self collapseEnabled];
        return;
    }
    UINavigationBar *bar = self.controller.navigationController.navigationBar;
    // Resetting an outgoing item must not move or lay out the new page's title.
    if (bar.topItem != self.item) bar = nil;
    [bar layoutIfNeeded];
    BOOL nativeDuo = self.moreItem && self.strips.count == 0 && ApolloActionsHasTrailingTabRail();
    if (!nativeDuo) ApolloNavigationTitleActionsWillChange(bar);
    self.expanded = expanded;
    if (self.moreItem && self.strips.count == 0 && ApolloActionsHasTrailingTabRail()) {
        // These are native items in UIKit's trailing vertical bar. Change the
        // actual item membership, as Apollo's regular-phone Inbox does, so
        // UIKit owns the insertion/removal and stretches one shared glass pill
        // vertically. Re-publishing the same array with hidden flags does not
        // produce the native Liquid Glass morph.
        [self applyStandardExpanded:expanded];
        NSArray<UIBarButtonItem *> *items = [self duoStandardItemsForExpanded:expanded];
        self.preparing = YES;
        [self.item setRightBarButtonItems:items
                                animated:animated && bar.window &&
                                         !UIAccessibilityIsReduceMotionEnabled()];
        self.preparing = NO;
        [bar setNeedsLayout];
        // Do not call the horizontal title-centering completion here. It
        // forces the entire bar through layoutIfNeeded inside
        // performWithoutAnimation, swallowing UIKit's pending native glass
        // morph whenever the title is visible (the first, unscrolled load).
        // Duo's title stays centered independently of its vertical actions.
        if (expanded) [self watchScrollViews];
        ApolloLog(@"[NavigationActions] %@ %@ with native Duo glass transition",
                  NSStringFromClass(self.controller.class),
                  expanded ? @"expanded" : @"collapsed");
        return;
    }
    if (animated && bar.window && !UIAccessibilityIsReduceMotionEnabled()) {
        // Reserve hit-test space before reveal; shrink it only after collapse.
        // Glass and content share a lightly underdamped spring, keeping More
        // pinned throughout the bounce without exposing the host's width jump.
        CASpringAnimation *spring = ApolloActionsSpring(nil);
        UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithMass:spring.mass
            stiffness:spring.stiffness damping:spring.damping initialVelocity:CGVectorMake(0, 0)];
        UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:kActionsAnimationDuration
            timingParameters:timing];
        self.animator = animator;
        if (expanded) [UIView performWithoutAnimation:^{ [self publishExpandedState]; }];
        [animator addAnimations:^{
            for (ApolloNavigationActionsStrip *strip in self.strips) [strip displayExpanded:expanded];
            [self applyStandardExpanded:expanded];
        }];
        __weak typeof(self) weakSelf = self;
        __weak UIViewPropertyAnimator *weakAnimator = animator;
        [animator addCompletion:^(__unused UIViewAnimatingPosition position) {
            ApolloNavigationActionsOwner *owner = weakSelf;
            if (!owner || owner.animator != weakAnimator) return;
            owner.animator = nil;
            // A menu may acquire the source mid-spring; defer the entire settlement.
            owner.needsAnimationSettlement = YES;
            [owner settleAnimationIfNeeded];
        }];
        [animator startAnimation];
        for (ApolloNavigationActionsStrip *strip in self.strips) [strip animateIconsExpanded:expanded entering:entering];
        ApolloNavigationTitleActionsDidChange(bar, spring);
    } else {
        self.needsAnimationSettlement = YES;
        [UIView performWithoutAnimation:^{
            [self settleAnimationIfNeeded];
            [self applyStandardExpanded:expanded];
        }];
        ApolloNavigationTitleActionsDidChange(bar, nil);
    }
    if (expanded) [self watchScrollViews];
    ApolloLog(@"[NavigationActions] %@ %@", NSStringFromClass(self.controller.class), expanded ? @"expanded" : @"collapsed");
}
- (void)publishExpandedState {
    if ([self deferGeometryUpdate]) return;
    for (ApolloNavigationActionsStrip *strip in self.strips) {
        [strip applyExpanded:self.expanded];
        [strip publishSize];
    }
    // iOS 27's SwiftUI host caches custom-item width until the navigation model
    // changes. Reuse current identities, including any late native replacement.
    // During item replacement the caller is about to publish the new array.
    // Republishing the outgoing array here lets translation upkeep pull the
    // globe out of its new search host and merge it back into the old strip.
    if (!self.preparing) {
        [self.item setRightBarButtonItems:self.item.rightBarButtonItems animated:NO];
    }
    UINavigationBar *bar = self.controller.navigationController.navigationBar;
    if (bar.topItem != self.item) return; // Never drive the page we navigated to.
    [bar setNeedsLayout];
    [bar layoutIfNeeded];
}
- (void)settleAnimationIfNeeded {
    if (!self.needsAnimationSettlement || self.animator || [self deferGeometryUpdate]) return;
    self.needsAnimationSettlement = NO;
    [UIView performWithoutAnimation:^{
        // Queued updates may replace items or start a spring; use live state.
        [self publishExpandedState];
        if (self.animator) return;
        // Publishing can synchronously open another menu; defer cleanup again.
        if ([self deferGeometryUpdate]) {
            self.needsAnimationSettlement = YES;
            return;
        }
        for (ApolloNavigationActionsStrip *strip in self.strips) {
            [strip displayExpanded:self.expanded];
            [strip removeIconAnimations];
        }
    }];
}
- (void)watchScrollViews {
    if (!self.controller.isViewLoaded) return;
    UIGestureRecognizer *backGesture = self.controller.navigationController.interactivePopGestureRecognizer;
    if (backGesture != self.backGesture) {
        [self.backGesture removeTarget:self action:@selector(backGestureChanged:)];
        self.backGesture = backGesture;
        [backGesture addTarget:self action:@selector(backGestureChanged:)];
    }
    UIView *root = self.controller.view;
    if (root == self.scrollRegistrationRoot) return;
    // Scan once per page; attachment hooks register later scroll views.
    // Expanding must not rescan loaded post/comment cells.
    for (UIPanGestureRecognizer *pan in self.pans.allObjects) {
        ApolloActionsSetScrollOwner(pan, nil);
    }
    [self.pans removeAllObjects];
    self.scrollRegistrationRoot = root;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count; i++) {
        UIView *view = queue[i];
        if ([view isKindOfClass:UIScrollView.class]) {
            ApolloActionsUpdateScrollOwner((UIScrollView *)view);
        }
        [queue addObjectsFromArray:view.subviews];
    }
}
- (void)scrolled:(UIPanGestureRecognizer *)pan {
    if (self.expanded && (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged)) {
        [self setExpanded:NO animated:YES];
    }
}
- (void)backGestureChanged:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) ApolloActionsResetBeforeNavigation(self.controller);
}
@end

static void ApolloActionsPrepare(UINavigationItem *item, NSArray *items) {
    if (!IsLiquidGlass()) return;
    ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
    if (!box.controller || !ApolloActionsAppController(box.controller)) return;
    if (ApolloDuoSplitSuppressesFeedActions(box.controller)) return;
    NSArray *nativeItems = ApolloActionsDuoNativeItems(item, items);
    nativeItems = ApolloActionsInboxItems(item, nativeItems);
    if (!ApolloActionsArraysIdentical(items, nativeItems)) {
        [item setRightBarButtonItems:nativeItems animated:NO];
        return;
    }
    [ApolloActionsOwner(item, YES) prepareItems:items];
}

// Settle Inbox's native floating group before UIKit captures the outgoing
// navigation chrome. The item setter's animated:NO alone does not suppress
// the SwiftUI host's pending glass/layout animation on the Duo.
static void ApolloActionsResetBeforeNavigation(UIViewController *controller) {
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(controller.navigationItem, NO);
    if (owner.expanded && owner.inboxDisclosure && owner.strips.count == 0 &&
        ApolloActionsHasTrailingTabRail()) {
        [UIView performWithoutAnimation:^{
            [owner setExpanded:NO animated:NO];
            [controller.tabBarController.view layoutIfNeeded];
            [controller.navigationController.view layoutIfNeeded];
        }];
    } else {
        [owner setExpanded:NO animated:NO];
    }
}

static NSArray<UIBarButtonItem *> *ApolloActionsPresentedItems(UINavigationItem *item, NSArray<UIBarButtonItem *> *items) {
    ApolloNavigationActionsControllerBox *feedBox = objc_getAssociatedObject(item, &kActionsControllerKey);
    if (ApolloDuoSplitSuppressesFeedActions(feedBox.controller)) {
        // Duo hides Apollo's feed actions while comments share the display,
        // while keeping the host's independent feed controls available.
        NSMutableArray<UIBarButtonItem *> *searchItems = [NSMutableArray array];
        if (@available(iOS 27.0, *)) {
            UIBarButtonItem *search = item.searchBarPlacementBarButtonItem;
            for (UIBarButtonItem *candidate in items) {
                if (candidate == search || ApolloActionsIsDuoFeedControl(item, candidate))
                    [searchItems addObject:candidate];
            }
        }
        return searchItems;
    }
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(item, NO);
    if (owner.moreItem == owner.inboxDisclosure && owner.standardItems.count &&
        [items containsObject:owner.moreItem] && ApolloActionsHasTrailingTabRail()) {
        // Pass the final collapsed model through the outer UIKit setter too.
        // A reentrant correction alone can leave its first rendered snapshot
        // showing the expanded array supplied by Apollo.
        return [owner duoStandardItemsForExpanded:owner.expanded];
    }
    return items;
}

void ApolloNavigationActionsRefresh(UINavigationBar *bar) {
    if (!bar || !IsLiquidGlass() || [objc_getAssociatedObject(bar, &kActionsRefreshKey) boolValue]) return;
    objc_setAssociatedObject(bar, &kActionsRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UINavigationBar *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationBar *bar = weakBar;
        if (!bar) return;
        objc_setAssociatedObject(bar, &kActionsRefreshKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIViewController *top = ApolloActionsNavigation(bar).topViewController;
        if (!top || bar.topItem != top.navigationItem) return;
        ApolloActionsPrepare(top.navigationItem, top.navigationItem.rightBarButtonItems);
    });
}

void ApolloNavigationActionsCollapse(UINavigationItem *item) {
    [ApolloActionsOwner(item, NO) setExpanded:NO animated:NO];
}

CGRect ApolloNavigationActionsCollapsedFrame(UINavigationBar *bar) {
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(bar.topItem, NO);
    for (ApolloNavigationActionsStrip *strip in owner.strips) {
        if (![strip isDescendantOfView:bar]) continue;
        CGRect rect = [strip convertRect:strip.bounds toView:bar];
        return CGRectMake(CGRectGetMaxX(rect) - 44, CGRectGetMidY(rect) - 22, 44, 44);
    }
    if (owner.moreItem) {
        UIView *view = ApolloNavigationActionsItemViewCandidates(owner.moreItem).lastObject;
        if ([view isDescendantOfView:bar]) {
            CGRect rect = [view convertRect:view.bounds toView:bar];
            return CGRectMake(CGRectGetMidX(rect) - 22, CGRectGetMidY(rect) - 22, 44, 44);
        }
    }
    return CGRectNull;
}

CGRect ApolloNavigationActionsExpandedFrame(UINavigationBar *bar) {
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(bar.topItem, NO);
    if (!owner.expanded) return CGRectNull;
    CGRect result = CGRectNull;
    for (ApolloNavigationActionsStrip *strip in owner.strips) {
        if (![strip isDescendantOfView:bar]) continue;
        CGRect rect = [strip convertRect:strip.bounds toView:bar];
        // Model endpoint, not the spring's per-frame glass width. More is
        // trailing-anchored in either state, including interrupted collapse.
        rect = CGRectMake(CGRectGetMaxX(rect) - strip.expandedWidth,
            CGRectGetMidY(rect) - 22, strip.expandedWidth, 44);
        result = CGRectIsNull(result) ? rect : CGRectUnion(result, rect);
    }
    if (owner.moreItem) {
        for (UIBarButtonItem *item in owner.item.rightBarButtonItems) {
            if (ApolloActionsItemHidden(item)) continue;
            UIView *view = ApolloNavigationActionsItemViewCandidates(item).lastObject;
            if (![view isDescendantOfView:bar]) continue;
            CGRect rect = [view convertRect:view.bounds toView:bar];
            if (CGRectIsEmpty(rect)) continue;
            result = CGRectIsNull(result) ? rect : CGRectUnion(result, rect);
        }
    }
    return result;
}

NSArray<UIView *> *ApolloNavigationActionsManagedRoots(UINavigationBar *bar) {
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(bar.topItem, NO);
    if (owner.strips.count == 0 && !owner.moreItem) return @[];
    return ApolloNavigationActionsDiscoverGroups(bar, bar.topItem);
}

// UIKit puts the Back bubble and the vertical actions in one SwiftUI glass
// container. Its collapse spring briefly joins those two surfaces even though
// Back never changes. Give the existing native Back control its own native
// glass surface; keep its chevron, target, accessibility and history menu.
// Nothing in the Moderator / Sort / More group changes for this fix.
static void ApolloActionsUpdateBackGlass(UIView *button, UIBarButtonItem *item) {
    UIVisualEffectView *surface = objc_getAssociatedObject(button, &kActionsDuoBackGlassKey);
    BOOL isolated = [objc_getAssociatedObject(item, &kActionsDuoBackItemKey) boolValue];
    if (!isolated) {
        [surface removeFromSuperview];
        objc_setAssociatedObject(button, &kActionsDuoBackGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (surface) {
        [button sendSubviewToBack:surface];
        return;
    }
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        effect.interactive = YES;
        surface = [[UIVisualEffectView alloc] initWithEffect:effect];
        surface.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
        surface.userInteractionEnabled = NO;
        surface.accessibilityElementsHidden = YES;
        // The native rail has 48pt bubbles around 38pt button content. Use
        // autoresizing margins so the surface cannot affect button fitting.
        // Keep this decoration out of the control's Auto Layout fitting size.
        surface.frame = CGRectMake((button.bounds.size.width - 48.0) / 2.0,
                                   (button.bounds.size.height - 48.0) / 2.0, 48.0, 48.0);
        surface.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                   UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [button insertSubview:surface atIndex:0];
        objc_setAssociatedObject(button, &kActionsDuoBackGlassKey, surface, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[NavigationActions] Isolated native Duo Back glass");
    }
}

@interface _UIButtonBarButtonVisualProviderIOS : NSObject
@property (nonatomic, readonly) UIBarButtonItem *barButtonItem;
@end
@interface _UIButtonBarButton : UIView
@property (nonatomic, readonly) _UIButtonBarButtonVisualProviderIOS *visualProvider;
@end

%group ApolloNavigationActionsBackGlassHooks
%hook _UIButtonBarButton
- (void)_configureFromBarItem:(UIBarButtonItem *)item appearanceDelegate:(id)delegate isBackButton:(BOOL)back useBreadcrumbStyle:(BOOL)breadcrumb {
    UITabBarController *tabs = (UITabBarController *)ApolloMainTabBarController();
    BOOL isolate = back && IsLiquidGlass() && sCollapseNavigationActions &&
        ApolloActionsHasTrailingTabRail() && !tabs.presentedViewController;
    BOOL managed = [objc_getAssociatedObject(item, &kActionsDuoBackItemKey) boolValue];
    // Mark UIKit's generated Back item, rather than supplying a replacement
    // navigation item (which would lose its native title/history behavior).
    if (@available(iOS 26.0, *)) {
        if (isolate && (managed || !item.hidesSharedBackground)) {
            objc_setAssociatedObject(item, &kActionsDuoBackItemKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!item.hidesSharedBackground) item.hidesSharedBackground = YES;
        } else if (managed) {
            objc_setAssociatedObject(item, &kActionsDuoBackItemKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            item.hidesSharedBackground = NO;
        }
    }
    %orig(item, delegate, back, breadcrumb);
    ApolloActionsUpdateBackGlass((UIView *)self, item);
}
- (void)willMoveToWindow:(UIWindow *)window {
    %orig(window);
    // UIKit finishes installing its chevron/mask after initial configuration.
    // Put the decoration behind those native subviews when the control mounts.
    ApolloActionsUpdateBackGlass((UIView *)self, self.visualProvider.barButtonItem);
}
%end

%hook _UIButtonBarButtonVisualProviderIOS
- (CGFloat)_defaultHeightFromDelegate {
    if (![objc_getAssociatedObject(self.barButtonItem, &kActionsDuoBackItemKey) boolValue]) return %orig;
    // UIKit's delegate stops subtracting the glass padding when a shared
    // background is hidden (38pt becomes 48pt on Duo). We still have that
    // glass, just on a separate surface. Measure with the original native
    // background metrics so all three actions fit, without hard-coding a
    // replacement height or changing constraints during layout.
    sActionsBackMeasurementDepth++;
    CGFloat height = %orig;
    sActionsBackMeasurementDepth--;
    return height;
}
%end

%hook UIBarButtonItem
- (BOOL)hidesSharedBackground {
    if (sActionsBackMeasurementDepth &&
        [objc_getAssociatedObject(self, &kActionsDuoBackItemKey) boolValue]) return NO;
    return %orig;
}
%end
%end

%group ApolloNavigationActionsHooks
%hook _ASTableViewCell
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig(highlighted, animated);
    ApolloActionsClipProfileSelection((UITableViewCell *)self);
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig(selected, animated);
    ApolloActionsClipProfileSelection((UITableViewCell *)self);
}
- (void)prepareForReuse {
    ApolloActionsRestoreProfileSelection((UITableViewCell *)self);
    ApolloActionsRestoreProfileCellBackground((UITableViewCell *)self);
    %orig;
}
%end

%hook UIViewController
- (UINavigationItem *)navigationItem {
    UINavigationItem *item = %orig;
    if (IsLiquidGlass() && ApolloActionsAppController(self)) {
        ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
        if (!box) {
            box = [ApolloNavigationActionsControllerBox new];
            objc_setAssociatedObject(item, &kActionsControllerKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        box.controller = self;
    }
    return item;
}
- (void)viewWillAppear:(BOOL)animated {
    ApolloActionsPrepare(self.navigationItem, self.navigationItem.rightBarButtonItems);
    %orig(animated);
    ApolloActionsPrepare(self.navigationItem, self.navigationItem.rightBarButtonItems);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloActionsPrepare(self.navigationItem, self.navigationItem.rightBarButtonItems);
}
- (void)viewWillDisappear:(BOOL)animated {
    ApolloActionsResetBeforeNavigation(self);
    %orig(animated);
}
%end

%hook _TtC6Apollo21ProfileViewController
- (void)viewDidLoad {
    %orig;
    __weak UIViewController *weakController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        ApolloActionsApplyDuoProfileItems(controller);
        ApolloActionsClearDuoProfileTrailingCells(controller);
    });
}
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloActionsApplyDuoProfileItems((UIViewController *)self);
    ApolloActionsClearDuoProfileTrailingCells((UIViewController *)self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloActionsApplyDuoProfileItems((UIViewController *)self);
    ApolloActionsClearDuoProfileTrailingCells((UIViewController *)self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    ApolloActionsScheduleDuoProfileItems((UIViewController *)self);
}
- (void)scrollViewDidScroll:(id)scrollView {
    %orig(scrollView);
    ApolloActionsClearDuoProfileTrailingCells((UIViewController *)self);
}
- (void)redditAccountChangedWithNotification:(id)notification {
    %orig(notification);
    __weak UIViewController *weakController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        ApolloActionsApplyDuoProfileItems(controller);
        ApolloActionsClearDuoProfileTrailingCells(controller);
    });
}
%end

%hook UINavigationItem
- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items {
    items = ApolloActionsDuoNativeItems(self, items);
    items = ApolloActionsInboxItems(self, items);
    BOOL pickerSwap = ApolloActionsReplacingPickerControl(self, items);
    void (^apply)(void) = ^{
        ApolloActionsPrepare(self, items);
        %orig(ApolloActionsPresentedItems(self, items));
        ApolloActionsPrepare(self, self.rightBarButtonItems);
    };
    if (pickerSwap) [UIView performWithoutAnimation:apply]; else apply();
}
- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)animated {
    items = ApolloActionsDuoNativeItems(self, items);
    items = ApolloActionsInboxItems(self, items);
    BOOL pickerSwap = ApolloActionsReplacingPickerControl(self, items);
    void (^apply)(void) = ^{
        ApolloActionsPrepare(self, items);
        %orig(ApolloActionsPresentedItems(self, items), pickerSwap ? NO : animated);
        ApolloActionsPrepare(self, self.rightBarButtonItems);
    };
    if (pickerSwap) [UIView performWithoutAnimation:apply]; else apply();
}
- (void)setRightBarButtonItem:(UIBarButtonItem *)item {
    NSArray *items = ApolloActionsDuoNativeItems(self, item ? @[item] : @[]);
    if (items.count != (item ? 1 : 0)) {
        [self setRightBarButtonItems:items];
        return;
    }
    item = items.firstObject;
    BOOL pickerSwap = ApolloActionsReplacingPickerControl(self, items);
    void (^apply)(void) = ^{
        ApolloActionsPrepare(self, items);
        %orig(item);
        ApolloActionsPrepare(self, self.rightBarButtonItems);
    };
    if (pickerSwap) [UIView performWithoutAnimation:apply]; else apply();
}
- (void)setRightBarButtonItem:(UIBarButtonItem *)item animated:(BOOL)animated {
    NSArray *items = ApolloActionsDuoNativeItems(self, item ? @[item] : @[]);
    if (items.count != (item ? 1 : 0)) {
        [self setRightBarButtonItems:items animated:animated];
        return;
    }
    item = items.firstObject;
    BOOL pickerSwap = ApolloActionsReplacingPickerControl(self, items);
    void (^apply)(void) = ^{
        ApolloActionsPrepare(self, items);
        %orig(item, pickerSwap ? NO : animated);
        ApolloActionsPrepare(self, self.rightBarButtonItems);
    };
    if (pickerSwap) [UIView performWithoutAnimation:apply]; else apply();
}
%end

%hook UIBarButtonItem
- (void)setMenu:(UIMenu *)menu {
    ApolloNavigationActionsStandardItem *state = sActionsModelWriteDepth ? nil : objc_getAssociatedObject(self, &kActionsStandardMoreKey);
    if (state.owner) {
        state.owner.nativeMenu = menu;
        UIMenu *effectiveMenu = state.owner.expanded ? menu : nil;
        %orig(effectiveMenu);
    } else {
        %orig(menu);
    }
}
- (void)setPrimaryAction:(UIAction *)action {
    ApolloNavigationActionsStandardItem *state = sActionsModelWriteDepth ? nil : objc_getAssociatedObject(self, &kActionsStandardMoreKey);
    if (state.owner) state.owner.nativePrimaryAction = action;
    %orig(action);
    if (state.owner && !state.owner.expanded) [state.owner applyStandardExpanded:NO];
}
- (void)setHidden:(BOOL)hidden {
    ApolloNavigationActionsStandardItem *state = sActionsModelWriteDepth ? nil : objc_getAssociatedObject(self, &kActionsStandardItemKey);
    if (state) {
        state.hidden = hidden;
        BOOL effectiveHidden = hidden || !state.owner.expanded;
        %orig(effectiveHidden);
    } else {
        %orig(hidden);
    }
}
%end

%hook UIScrollView
- (void)didMoveToWindow {
    %orig;
    if (IsLiquidGlass()) ApolloActionsUpdateScrollOwner(self);
}
- (void)didMoveToSuperview {
    %orig;
    // Reparenting inside the same window need not change window membership.
    if (IsLiquidGlass()) ApolloActionsUpdateScrollOwner(self);
}
%end

%hook UINavigationController
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    ApolloActionsResetBeforeNavigation(self.topViewController);
    ApolloActionsPrepare(controller.navigationItem, controller.navigationItem.rightBarButtonItems);
    %orig(controller, animated);
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    ApolloActionsResetBeforeNavigation(self.topViewController);
    return %orig(animated);
}
- (NSArray *)popToViewController:(UIViewController *)controller animated:(BOOL)animated {
    ApolloActionsResetBeforeNavigation(self.topViewController);
    return %orig(controller, animated);
}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated {
    ApolloActionsResetBeforeNavigation(self.topViewController);
    return %orig(animated);
}
- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated {
    ApolloActionsResetBeforeNavigation(self.topViewController);
    for (UIViewController *controller in controllers) ApolloActionsPrepare(controller.navigationItem, controller.navigationItem.rightBarButtonItems);
    %orig(controllers, animated);
}
%end

%hook UITabBarController
- (void)viewDidLayoutSubviews {
    %orig;
    if (self != (id)ApolloMainTabBarController() ||
        (ApolloDuoCurrentMode() != ApolloDuoModeClosed && !ApolloActionsHasTrailingTabRail()) ||
        objc_getAssociatedObject(self, &kActionsDuoRefreshScheduledKey)) return;
    objc_setAssociatedObject(self, &kActionsDuoRefreshScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UITabBarController *weakTabs = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITabBarController *tabs = weakTabs;
        if (!tabs) return;
        objc_setAssociatedObject(tabs, &kActionsDuoRefreshScheduledKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIViewController *selected = tabs.selectedViewController;
        UINavigationController *navigation = [selected isKindOfClass:UINavigationController.class]
            ? (UINavigationController *)selected : selected.navigationController;
        // The selected tab owns a containment host after unfolding. Refresh
        // the actual detail page, where the retained Inbox disclosure lives.
        navigation = ApolloDuoSplitDetailNavigation(navigation);
        UIViewController *top = navigation.topViewController;
        if (top) ApolloActionsPrepare(top.navigationItem, top.navigationItem.rightBarButtonItems);
    });
}
%end
%end

// Apollo can retint existing controls without replacing their navigation item.
// Reject those accent writes at the setter, rather than correcting a visible
// frame later. Menu elements and unrelated content remain untouched.
%group ApolloNavigationActionsChromeHooks
%hook UIView
- (void)setTintColor:(UIColor *)color {
    if (objc_getAssociatedObject(self, &kActionsChromeKey)) {
        color = ApolloActionsChromeColor(self);
        if ([self.tintColor isEqual:color]) return;
    }
    %orig(color);
}
%end

%hook UIButton
- (void)setImage:(UIImage *)image forState:(UIControlState)state {
    if (objc_getAssociatedObject(self, &kActionsChromeKey)) image = ApolloActionsTemplateImage(image);
    %orig(image, state);
    NSHashTable<UIBarButtonItem *> *mirrors = objc_getAssociatedObject(self, &kActionsDuoMirroredItemsKey);
    if (mirrors.count) {
        UIImage *current = ApolloActionsTemplateImage([self imageForState:UIControlStateNormal] ?: self.currentImage);
        for (UIBarButtonItem *item in mirrors) item.image = current;
    }
}
%end

%hook UIBarButtonItem
- (void)setTintColor:(UIColor *)color {
    if (objc_getAssociatedObject(self, &kActionsChromeKey) || ApolloActionsIsAutoModClose(self)) {
        color = ApolloActionsChromeColor(self);
        if ([self.tintColor isEqual:color]) return;
    }
    %orig(color);
}
- (void)setImage:(UIImage *)image {
    if (objc_getAssociatedObject(self, &kActionsChromeKey) || ApolloActionsIsAutoModClose(self)) image = ApolloActionsTemplateImage(image);
    %orig(image);
}
%end
%end

%ctor {
    if (@available(iOS 26.0, *)) {
        %init(ApolloNavigationActionsHooks);
        if (@available(iOS 27.1, *)) {
            if (IsLiquidGlass()) %init(ApolloNavigationActionsBackGlassHooks);
        }
        if (IsLiquidGlass()) {
            %init(ApolloNavigationActionsChromeHooks);
        }
        ApolloLog(@"[NavigationActions] Page-owned native strip hooks installed");
    }
}
