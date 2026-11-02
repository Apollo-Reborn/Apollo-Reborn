// Capture UI policy before handing Apollo's original node factory to Texture.
// Background layout consumes immutable values and never walks UIKit objects.
#import "ApolloPaneContent.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "../ApolloCommon.h"
#import "../ApolloProfileRowWrapper.h"
#import "../ApolloTextureDecls.h"
#import "../ApolloThemeRuntime.h"
#import <objc/runtime.h>

static char kReadableWidth;
static char kSelectionColor;
static char kTableSafeAreaWidth;
static char kCellHaloRect;
static char kSplashFollowsSafeArea;

@interface NSObject (ApolloPaneTextureTable)
- (void)relayoutItems;
@end

id ApolloPanePrepareNodeFactory(id factory, UIViewController *controller) {
    if (!factory || !NSThread.isMainThread) return factory;
    ApolloPaneSplitViewController *pane = (id)ApolloPaneSplitControllerFor(controller);
    if (!pane) return factory;
    Class comments = objc_getClass("_TtC6Apollo22CommentsViewController");
    BOOL prose = comments && [controller isKindOfClass:comments];
    UINavigationController *primary = [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
    BOOL master = controller.navigationController == primary;
    if (!prose && !master) return factory;
    NSNumber *measure = @(UIContentSizeCategoryIsAccessibilityCategory(
        controller.traitCollection.preferredContentSizeCategory) ? 760.0 : 680.0);
    UIColor *accent = ApolloThemeAccentColor() ?: UIColor.systemBlueColor;
    UIColor *selection = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        CGFloat opacity = traits.accessibilityContrast == UIAccessibilityContrastHigh ? 0.18 : 0.09;
        return [[accent resolvedColorWithTraitCollection:traits] colorWithAlphaComponent:opacity];
    }];
    id (^nativeFactory)(void) = factory;
    return [^id {
        id node = nativeFactory();
        if (prose) objc_setAssociatedObject(node, &kReadableWidth, measure, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (master) objc_setAssociatedObject(node, &kSelectionColor, selection, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return node;
    } copy];
}

static CGFloat ApolloPaneProseInset(id node, struct ApolloTextureSizeRange range) {
    NSNumber *measure = objc_getAssociatedObject(node, &kReadableWidth);
    if (!measure || !isfinite(range.max.width)) return 0.0;
    return MAX(0.0, floor((range.max.width - measure.doubleValue) / 2.0));
}

// On iOS 26 the list column runs underneath the floating sidebar, which hands
// the column a 280pt left safe area instead of a narrower frame. UIKit insets
// cell content views by that amount, but cell bounds stay full width, so the
// selection fill and the focus halo (the blue outline on the open post) were
// drawn under the sidebar. Keep both to the visible part of the row.
static void ApolloPaneInsetSelectionChrome(UITableViewCell *cell) {
    UIEdgeInsets safe = cell.safeAreaInsets;
    // A profile cell that holds two rows outlines only the one that was touched.
    CGRect row = CGRectNull;
    BOOL partialRow = ApolloProfileRowWrapperFocusRect(cell, &row);
    BOOL inset = safe.left > 0.5 || safe.right > 0.5;
    NSValue *applied = objc_getAssociatedObject(cell, &kCellHaloRect);
    if (!inset && !partialRow && !applied) return;

    CGRect bounds = cell.bounds;
    CGRect visible = CGRectMake(safe.left, partialRow ? CGRectGetMinY(row) : 0.0,
                                MAX(0.0, CGRectGetWidth(bounds) - safe.left - safe.right),
                                partialRow ? CGRectGetHeight(row) : CGRectGetHeight(bounds));
    UIView *selection = cell.selectedBackgroundView;
    if (inset && selection.superview == cell) {
        // UITableViewCell has just sized this to the cell's bounds in %orig.
        CGRect frame = selection.frame;
        frame.origin.x = CGRectGetMinX(visible);
        frame.size.width = CGRectGetWidth(visible);
        selection.frame = frame;
    }

    if (@available(iOS 15.0, *)) {
        if (!inset && !partialRow) {
            cell.focusEffect = nil;
            objc_setAssociatedObject(cell, &kCellHaloRect, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        if (applied && CGRectEqualToRect(applied.CGRectValue, visible)) return;
        cell.focusEffect = [UIFocusHaloEffect effectWithRect:visible];
        objc_setAssociatedObject(cell, &kCellHaloRect, [NSValue valueWithCGRect:visible],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%group ApolloPaneContentGroup
%hook UITableViewCell
- (void)layoutSubviews {
    %orig;
    if (ApolloPaneLayoutActive()) ApolloPaneInsetSelectionChrome(self);
}
%end

// Texture measures every row at the table's full width and never subtracts the
// safe area, but _ASTableViewCell lays its node out in the inset content view.
// Beside the sidebar that measured rows 280pt wider than they render, so text
// wrapped onto more lines than the row height allowed and the author line was
// clipped. Measure at the content view's width instead. The inset is cached on
// the main thread because Texture can ask for sizes from a background queue.
%hook ApolloPaneTextureTable
- (void)safeAreaInsetsDidChange {
    %orig;
    if (!ApolloPaneLayoutActive()) return;
    UITableView *table = (UITableView *)self;
    UIEdgeInsets safe = table.safeAreaInsets;
    CGFloat inset = table.insetsContentViewsToSafeArea ? safe.left + safe.right : 0.0;
    NSNumber *previous = objc_getAssociatedObject(self, &kTableSafeAreaWidth);
    if (fabs(previous.doubleValue - inset) < 0.5) return;
    objc_setAssociatedObject(self, &kTableSafeAreaWidth, @(inset), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[PaneContent] Texture table safe-area width %.0f -> %.0f; remeasuring rows",
              previous.doubleValue, inset);
    // Remeasure outside the layout pass that delivered the new insets.
    __weak UITableView *weakTable = table;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *strongTable = weakTable;
        if ([strongTable respondsToSelector:@selector(relayoutItems)]) [(id)strongTable relayoutItems];
    });
}

- (struct ApolloTextureSizeRange)dataController:(id)dataController
             constrainedSizeForNodeAtIndexPath:(NSIndexPath *)indexPath {
    struct ApolloTextureSizeRange range = %orig;
    CGFloat inset = [objc_getAssociatedObject(self, &kTableSafeAreaWidth) doubleValue];
    if (inset <= 0.0 || !isfinite(range.max.width)) return range;
    range.max.width = MAX(0.0, range.max.width - inset);
    range.min.width = MIN(range.min.width, range.max.width);
    return range;
}
%end

// The signed-out Account/Inbox notice centers its content on the full view and
// sizes it to the full width, so beside the sidebar it was centered 140pt too
// far left and clipped under it. Re-anchor Apollo's horizontal constraints to
// the safe area once, keeping every multiplier, constant and priority.
%hook ApolloPaneSignInSplash
- (void)didMoveToWindow {
    %orig;
    UIView *splash = (UIView *)self;
    if (!splash.window || !ApolloPaneLayoutActive() ||
        objc_getAssociatedObject(self, &kSplashFollowsSafeArea)) return;
    objc_setAssociatedObject(self, &kSplashFollowsSafeArea, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UILayoutGuide *safe = splash.safeAreaLayoutGuide;
    NSMutableArray<NSLayoutConstraint *> *native = [NSMutableArray array];
    NSMutableArray<NSLayoutConstraint *> *replacements = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in splash.constraints) {
        NSLayoutAttribute attribute = constraint.firstItem == splash ? constraint.firstAttribute
            : constraint.secondItem == splash ? constraint.secondAttribute : NSLayoutAttributeNotAnAttribute;
        if (attribute != NSLayoutAttributeCenterX && attribute != NSLayoutAttributeWidth &&
            attribute != NSLayoutAttributeLeading && attribute != NSLayoutAttributeTrailing) continue;
        NSLayoutConstraint *replacement = [NSLayoutConstraint
            constraintWithItem:constraint.firstItem == splash ? safe : constraint.firstItem
                     attribute:constraint.firstAttribute
                     relatedBy:constraint.relation
                        toItem:constraint.secondItem == splash ? safe : constraint.secondItem
                     attribute:constraint.secondAttribute
                    multiplier:constraint.multiplier
                      constant:constraint.constant];
        replacement.priority = constraint.priority;
        [native addObject:constraint];
        [replacements addObject:replacement];
    }
    [NSLayoutConstraint deactivateConstraints:native];
    // Apollo re-activates these when the tab reappears. Demote them while they
    // are inactive (a required priority can't change while installed) so the
    // safe-area copies keep winning whenever that happens.
    for (NSLayoutConstraint *constraint in native) {
        constraint.priority = MIN(constraint.priority, UILayoutPriorityDefaultLow);
    }
    [NSLayoutConstraint activateConstraints:replacements];
    ApolloLog(@"[PaneContent] sign-in notice follows the safe area (%lu constraints)",
              (unsigned long)replacements.count);
}
%end

%hook ApolloPaneCommentCell
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat inset = ApolloPaneProseInset(self, range);
    if (inset <= 0.0) return %orig;
    range.min.width = MAX(0, range.min.width - 2 * inset);
    range.max.width -= 2 * inset;
    id content = %orig(range);
    return [objc_getClass("ASInsetLayoutSpec") insetLayoutSpecWithInsets:UIEdgeInsetsMake(0, inset, 0, inset) child:content];
}
%end

%hook ApolloPaneCommentsHeader
- (id)layoutSpecThatFits:(struct ApolloTextureSizeRange)range {
    CGFloat inset = ApolloPaneProseInset(self, range);
    if (inset <= 0.0) return %orig;
    range.min.width = MAX(0, range.min.width - 2 * inset);
    range.max.width -= 2 * inset;
    id content = %orig(range);
    return [objc_getClass("ASInsetLayoutSpec") insetLayoutSpecWithInsets:UIEdgeInsetsMake(0, inset, 0, inset) child:content];
}
%end

%hook ApolloPaneCompactPost
- (UIView *)selectedBackgroundView {
    UIView *view = %orig;
    UIColor *color = objc_getAssociatedObject(self, &kSelectionColor);
    if (color) view.backgroundColor = color;
    return view;
}
%end

%hook ApolloPaneLargePost
- (UIView *)selectedBackgroundView {
    UIView *view = %orig;
    UIColor *color = objc_getAssociatedObject(self, &kSelectionColor);
    if (color) view.backgroundColor = color;
    return view;
}
%end
%end

%ctor {
    if (!ApolloPaneLayoutEnabled()) return;
    %init(ApolloPaneContentGroup,
        ApolloPaneTextureTable=objc_getClass("ASTableView"),
        ApolloPaneSignInSplash=objc_getClass("_TtC6Apollo16SignInSplashView"),
        ApolloPaneCommentCell=objc_getClass("_TtC6Apollo15CommentCellNode"),
        ApolloPaneCommentsHeader=objc_getClass("_TtC6Apollo22CommentsHeaderCellNode"),
        ApolloPaneCompactPost=objc_getClass("_TtC6Apollo19CompactPostCellNode"),
        ApolloPaneLargePost=objc_getClass("_TtC6Apollo17LargePostCellNode"));
}
