// Capture UI policy before handing Apollo's original node factory to Texture.
// Background layout consumes immutable values and never walks UIKit objects.
#import "ApolloPaneContent.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "../ApolloTextureDecls.h"
#import "../ApolloThemeRuntime.h"
#import <objc/runtime.h>

static char kReadableWidth;
static char kSelectionColor;

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

%group ApolloPaneContentGroup
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
        ApolloPaneCommentCell=objc_getClass("_TtC6Apollo15CommentCellNode"),
        ApolloPaneCommentsHeader=objc_getClass("_TtC6Apollo22CommentsHeaderCellNode"),
        ApolloPaneCompactPost=objc_getClass("_TtC6Apollo19CompactPostCellNode"),
        ApolloPaneLargePost=objc_getClass("_TtC6Apollo17LargePostCellNode"));
}
