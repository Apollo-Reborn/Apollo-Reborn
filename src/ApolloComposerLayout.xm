// ApolloComposerLayout.xm — Liquid Glass layout for the comment composer's
// chrome around the editor, to match the glass formatting bar.
//
//  - Distinguish/Sticky (UpperModeratorToolbar) become equal capsules across
//    the safe area, lined up with Cancel and Post, instead of a gray band with
//    dividers. The buttons are configuration-based, so the capsule is their
//    configuration's background; on is a solid fill.
//  - The "replying to" block becomes an inset rounded card. Apollo frames the
//    block and its labels itself, so the card is a view of ours behind them,
//    the text view's container inset narrows by the card margin (Apollo's own
//    height measurement then stays right) and the header labels shift in
//    after Apollo lays them out.
// Post's accent fill lives in ApolloNavigationActions.xm.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloDuoRail.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"

static const CGFloat kApolloComposerLayoutMargin = 16.0;
static const CGFloat kApolloComposerLayoutChipHeight = 34.0;
static const CGFloat kApolloComposerLayoutChipSpacing = 8.0;
static const CGFloat kApolloComposerLayoutChipIconHeight = 18.0;
static const CGFloat kApolloComposerLayoutCardRadius = 22.0;
// Clears the glass bar's capsule, which overhangs the bar into the editor.
static const CGFloat kApolloComposerLayoutCardBottomGap = 10.0;

static char kApolloComposerLayoutSizedIconKey;
static char kApolloComposerLayoutThemeWatchKey;
static char kApolloComposerLayoutCardKey;
static char kApolloComposerLayoutBlockColorKey;
static char kApolloComposerLayoutTextInsetKey;
static char kApolloComposerLayoutShiftedXKey;

static BOOL ApolloComposerLayoutActive(void) {
    if (@available(iOS 26.0, *)) return IsLiquidGlass();
    return NO;
}

#pragma mark - Moderator capsules

// Apollo's shield and pin art is sized for the old 48pt band.
static UIImage *ApolloComposerLayoutChipIcon(UIImage *image) {
    if (!image || [objc_getAssociatedObject(image, &kApolloComposerLayoutSizedIconKey) boolValue]) return image;
    CGSize size = image.size;
    if (size.height <= kApolloComposerLayoutChipIconHeight || size.height <= 0.0) return image;
    CGFloat scale = kApolloComposerLayoutChipIconHeight / size.height;
    CGSize target = CGSizeMake(round(size.width * scale), kApolloComposerLayoutChipIconHeight);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target];
    UIImage *sized = [[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0.0, 0.0, target.width, target.height)];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    objc_setAssociatedObject(sized, &kApolloComposerLayoutSizedIconKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return sized;
}

static void ApolloComposerLayoutStyleChip(UIButton *button, BOOL on) API_AVAILABLE(ios(26.0)) {
    UIButtonConfiguration *configuration = button.configuration;
    if (!configuration) return;
    UIColor *green = ApolloModeratorColor() ?: UIColor.systemGreenColor;
    UIColor *fill = on ? green : [green colorWithAlphaComponent:0.16];
    UIColor *foreground = on ? (ApolloColorIsLight(green) ? UIColor.blackColor : UIColor.whiteColor) : green;
    UIImage *icon = ApolloComposerLayoutChipIcon(configuration.image);
    // Apollo restyles these buttons itself when they toggle or the theme
    // changes, sometimes keeping the capsule, so compare what is drawn.
    if (configuration.cornerStyle == UIButtonConfigurationCornerStyleCapsule &&
        [configuration.background.backgroundColor isEqual:fill] &&
        [configuration.baseForegroundColor isEqual:foreground] &&
        configuration.image == icon && configuration.imagePadding == 6.0) return;

    UIButtonConfiguration *updated = [configuration copy];
    updated.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    updated.background.backgroundColor = fill;
    updated.baseForegroundColor = foreground;
    updated.image = icon;
    updated.imagePadding = 6.0;
    updated.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary *styled = [attributes mutableCopy];
        styled[NSFontAttributeName] = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        return styled;
    };
    button.configuration = updated;
}

static void ApolloComposerLayoutStyleModeratorToolbar(UIView *toolbar) API_AVAILABLE(ios(26.0)) {
    UIButton *distinguish = ApolloObjectIvar(toolbar, "distinguishButton");
    UIButton *sticky = ApolloObjectIvar(toolbar, "stickyButton");
    if (![distinguish isKindOfClass:[UIButton class]]) return;

    toolbar.backgroundColor = UIColor.clearColor;
    for (UIView *divider in @[ApolloObjectIvar(toolbar, "middleDivider") ?: NSNull.null,
                              ApolloObjectIvar(toolbar, "bottomDivider") ?: NSNull.null]) {
        if ([divider isKindOfClass:[UIView class]]) divider.hidden = YES;
    }

    NSMutableArray<UIButton *> *buttons = [NSMutableArray arrayWithObject:distinguish];
    if (ApolloReadBoolIvar(toolbar, "showStickyButton", NO) && [sticky isKindOfClass:[UIButton class]] && !sticky.hidden) {
        [buttons addObject:sticky];
    }

    // Cancel and Post sit at the margins. On the closed Duo the bar already
    // stops at the status column, where Post's trailing edge is too.
    CGRect bounds = toolbar.bounds;
    UIEdgeInsets safe = toolbar.safeAreaInsets;
    CGFloat left = kApolloComposerLayoutMargin + safe.left;
    CGFloat right = CGRectGetWidth(bounds) - safe.right
        - (ApolloDuoUsesCoverContentInsets() ? 0.0 : kApolloComposerLayoutMargin);
    NSUInteger count = buttons.count;
    CGFloat width = floor((right - left - kApolloComposerLayoutChipSpacing * (count - 1)) / count);
    CGFloat y = floor((CGRectGetHeight(bounds) - kApolloComposerLayoutChipHeight) / 2.0);
    BOOL distinguished = ApolloReadBoolIvar(toolbar, "distinguished", NO);
    BOOL stickied = ApolloReadBoolIvar(toolbar, "stickied", NO);
    for (NSUInteger index = 0; index < count; index++) {
        UIButton *button = buttons[index];
        button.frame = CGRectMake(left + index * (width + kApolloComposerLayoutChipSpacing), y,
                                  width, kApolloComposerLayoutChipHeight);
        ApolloComposerLayoutStyleChip(button, button == distinguish ? distinguished : stickied);
    }
}

// Removes its notification observer when the toolbar that owns it goes away.
@interface ApolloComposerLayoutThemeWatch : NSObject
@property (nonatomic, strong) id observer;
@end

@implementation ApolloComposerLayoutThemeWatch
- (void)dealloc {
    if (self.observer) [NSNotificationCenter.defaultCenter removeObserver:self.observer];
}
@end

// Apollo repaints the toolbar band and the reply block with its theme colors
// when the theme or appearance changes (the app switcher's snapshots flip the
// appearance), outside a layout pass. Lay both out again after it.
static void ApolloComposerLayoutWatchTheme(UIView *toolbar) API_AVAILABLE(ios(26.0)) {
    if (objc_getAssociatedObject(toolbar, &kApolloComposerLayoutThemeWatchKey)) return;
    __weak UIView *weakToolbar = toolbar;
    void (^relayout)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *strongToolbar = weakToolbar;
            if (!strongToolbar.window) return;
            [strongToolbar setNeedsLayout];
            for (UIResponder *responder = strongToolbar.nextResponder; responder; responder = responder.nextResponder) {
                if ([responder isKindOfClass:[UIViewController class]]) {
                    [((UIViewController *)responder).viewIfLoaded setNeedsLayout];
                    break;
                }
            }
        });
    };
    ApolloComposerLayoutThemeWatch *watch = [ApolloComposerLayoutThemeWatch new];
    watch.observer = [NSNotificationCenter.defaultCenter addObserverForName:@"com.christianselig.ApolloSpecificThemeChanged"
                                                                     object:nil
                                                                      queue:NSOperationQueue.mainQueue
                                                                 usingBlock:^(__unused NSNotification *notification) {
        relayout();
    }];
    [toolbar registerForTraitChanges:@[UITraitUserInterfaceStyle.class]
                         withHandler:^(__unused id<UITraitEnvironment> environment, __unused UITraitCollection *previous) {
        relayout();
    }];
    objc_setAssociatedObject(toolbar, &kApolloComposerLayoutThemeWatchKey, watch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _TtC6Apollo21UpperModeratorToolbar

// Apollo frames the buttons here; the capsules replace that geometry.
- (void)layoutSubviews {
    %orig;
    if (@available(iOS 26.0, *)) {
        if (!ApolloComposerLayoutActive()) return;
        ApolloComposerLayoutStyleModeratorToolbar((UIView *)self);
        ApolloComposerLayoutWatchTheme((UIView *)self);
    }
}

// A toggle flips Apollo's flags (both, when sticky needs distinguish) and
// restyles its buttons. Restyle in the same turn, so the toggle fades once to
// the capsule, and again after layout in case Apollo restyles later.
- (void)distinguishButtonTapped:(id)sender {
    %orig;
    if (@available(iOS 26.0, *)) {
        if (!ApolloComposerLayoutActive()) return;
        ApolloComposerLayoutStyleModeratorToolbar((UIView *)self);
        [(UIView *)self setNeedsLayout];
    }
}

- (void)stickyButtonTapped:(id)sender {
    %orig;
    if (@available(iOS 26.0, *)) {
        if (!ApolloComposerLayoutActive()) return;
        ApolloComposerLayoutStyleModeratorToolbar((UIView *)self);
        [(UIView *)self setNeedsLayout];
    }
}

%end

#pragma mark - Reply card

static BOOL ApolloComposerLayoutColorsMatch(UIColor *lhs, UIColor *rhs, UITraitCollection *traits) {
    if (!lhs || !rhs) return NO;
    CGFloat ar = 0, ag = 0, ab = 0, aa = 0, br = 0, bg = 0, bb = 0, ba = 0;
    if (![[lhs resolvedColorWithTraitCollection:traits] getRed:&ar green:&ag blue:&ab alpha:&aa]) return NO;
    if (![[rhs resolvedColorWithTraitCollection:traits] getRed:&br green:&bg blue:&bb alpha:&ba]) return NO;
    return fabs(ar - br) < 0.02 && fabs(ag - bg) < 0.02 && fabs(ab - bb) < 0.02;
}

// Before Apollo measures and frames the block: narrow its text by the card's
// margins. Apollo may reset the inset; anything but our own value is its new base.
static void ApolloComposerLayoutInsetReplyText(UIViewController *composer) {
    UITextView *textView = ApolloObjectIvar(composer, "replyingToTextView");
    if (![textView isKindOfClass:[UITextView class]]) return;
    NSValue *applied = objc_getAssociatedObject(textView, &kApolloComposerLayoutTextInsetKey);
    UIEdgeInsets inset = textView.textContainerInset;
    if (applied && UIEdgeInsetsEqualToEdgeInsets(inset, applied.UIEdgeInsetsValue)) return;
    inset.left += kApolloComposerLayoutMargin;
    inset.right += kApolloComposerLayoutMargin;
    textView.textContainerInset = inset;
    objc_setAssociatedObject(textView, &kApolloComposerLayoutTextInsetKey, [NSValue valueWithUIEdgeInsets:inset],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// After Apollo frames the block: draw the card and move the header in.
static void ApolloComposerLayoutStyleReplyCard(UIViewController *composer) {
    UIView *wrapper = ApolloObjectIvar(composer, "replyingToWrapperView");
    if (![wrapper isKindOfClass:[UIView class]] || wrapper.hidden) return;
    CGFloat width = CGRectGetWidth(wrapper.bounds);
    if (width <= 4.0 * kApolloComposerLayoutMargin) return;
    UIView *textView = ApolloObjectIvar(composer, "replyingToTextView");
    UIView *topSeparator = ApolloObjectIvar(composer, "replyingToTopSeparator");
    UIView *bottomSeparator = ApolloObjectIvar(composer, "replyingToBottomSeparator");
    topSeparator.hidden = YES;
    bottomSeparator.hidden = YES;

    UIView *card = objc_getAssociatedObject(wrapper, &kApolloComposerLayoutCardKey);
    if (!card) {
        card = [[UIView alloc] init];
        card.userInteractionEnabled = NO;
        card.layer.cornerRadius = kApolloComposerLayoutCardRadius;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(wrapper, &kApolloComposerLayoutCardKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (wrapper.subviews.firstObject != card) [wrapper insertSubview:card atIndex:0];

    // The card takes Apollo's block color, re-read whenever its theme sets one.
    // A block colored like the editor (true black) gets the system grouped fill.
    UIColor *block = wrapper.backgroundColor;
    if (block && CGColorGetAlpha(block.CGColor) > 0.01) {
        objc_setAssociatedObject(wrapper, &kApolloComposerLayoutBlockColorKey, block, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        wrapper.backgroundColor = UIColor.clearColor;
    }
    block = objc_getAssociatedObject(wrapper, &kApolloComposerLayoutBlockColorKey);
    UIColor *editor = composer.view.backgroundColor;
    BOOL blendsIn = !block || ApolloComposerLayoutColorsMatch(block, editor, wrapper.traitCollection);
    card.backgroundColor = blendsIn ? UIColor.secondarySystemBackgroundColor : block;
    if (textView.backgroundColor && CGColorGetAlpha(textView.backgroundColor.CGColor) > 0.01) {
        textView.backgroundColor = UIColor.clearColor;
    }
    card.frame = CGRectMake(kApolloComposerLayoutMargin, 0.0, width - 2.0 * kApolloComposerLayoutMargin,
                            MAX(0.0, CGRectGetHeight(wrapper.bounds) - kApolloComposerLayoutCardBottomGap));

    // Apollo frames the header from the block's edges: arrow, username and
    // points from the left, age from the right. Move each in by the margin,
    // once per frame Apollo sets.
    for (UIView *subview in wrapper.subviews) {
        if (subview == card || subview == textView || subview == topSeparator || subview == bottomSeparator) continue;
        CGRect frame = subview.frame;
        NSNumber *shifted = objc_getAssociatedObject(subview, &kApolloComposerLayoutShiftedXKey);
        if (shifted && fabs(shifted.doubleValue - frame.origin.x) < 0.5) continue;
        frame.origin.x += CGRectGetMidX(frame) > width / 2.0 ? -kApolloComposerLayoutMargin : kApolloComposerLayoutMargin;
        subview.frame = frame;
        objc_setAssociatedObject(subview, &kApolloComposerLayoutShiftedXKey, @(frame.origin.x), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Apollo re-frames the header a main-queue turn after its layout pass, so the
// card is applied now and again once that has run.
static void ApolloComposerLayoutStyleReplyCardNowAndLater(UIViewController *composer) {
    ApolloComposerLayoutStyleReplyCard(composer);
    __weak UIViewController *weakComposer = composer;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongComposer = weakComposer;
        if (strongComposer) ApolloComposerLayoutStyleReplyCard(strongComposer);
    });
}

%hook _TtC6Apollo21ComposeViewController

- (void)viewWillLayoutSubviews {
    if (ApolloComposerLayoutActive()) ApolloComposerLayoutInsetReplyText((UIViewController *)self);
    %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (ApolloComposerLayoutActive()) ApolloComposerLayoutStyleReplyCardNowAndLater((UIViewController *)self);
}

// Apollo re-frames the block when the keyboard moves, outside a layout pass.
- (void)keyboardDidChangeFrame:(id)notification {
    %orig;
    if (ApolloComposerLayoutActive()) ApolloComposerLayoutStyleReplyCardNowAndLater((UIViewController *)self);
}

%end
