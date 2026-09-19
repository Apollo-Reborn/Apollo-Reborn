#import "ApolloDuoSubsChrome.h"

#import "ApolloCommon.h"
#import "ApolloDeviceGeometry.h"
#import "ApolloDuoCompatibility.h"
#import "ApolloDuoRail.h"
#import "ApolloDuoRailLayout.h"
#import "ApolloThemeRuntime.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

// Completes RedditList chrome on Duo. Open Regular width otherwise
// leading-aligns the title and often hides the iPhone Edit / floating
// +. Closed Compact already has stock chrome — we only nudge the +
// off corners / the cover gear. Regular iPhone is a restore/no-op.
//
// Reuses Apollo's editButtonItem and tappedAddBarButtonItem:. Does
// not invent a second add-subreddit flow. Does not write
// layoutMargins or re-toggle constraints (25f8a7b hang).

static char kApolloDuoSubsChromeAppliedKey;
static char kApolloDuoSubsChromeFABKey;
static char kApolloDuoSubsChromeTitleViewKey;
static char kApolloDuoSubsChromeSavedRightItemsKey;
static char kApolloDuoSubsChromeSavedLargeTitleKey;
static char kApolloDuoSubsChromeSavedTitleKey;
static char kApolloDuoSubsChromeClaimedFABKey;

static BOOL ApolloDuoSubsChromeNameLooksLikeRedditList(const char *name) {
    return name && strstr(name, "RedditListViewController") != NULL;
}

BOOL ApolloDuoSubsChromeControllerIsRedditList(UIViewController *controller) {
    return controller && ApolloDuoSubsChromeNameLooksLikeRedditList(class_getName(controller.class));
}

static UIBarButtonItem *ApolloDuoSubsChromeAddBarButtonItem(UIViewController *controller) {
    Ivar ivar = class_getInstanceVariable(controller.class, "addBarButtonItem");
    if (!ivar) ivar = class_getInstanceVariable(controller.class, "_addBarButtonItem");
    id value = ivar ? object_getIvar(controller, ivar) : nil;
    return [value isKindOfClass:[UIBarButtonItem class]] ? value : nil;
}

static BOOL ApolloDuoSubsChromeItemLooksLikeEdit(UIBarButtonItem *item, UIBarButtonItem *editItem) {
    if (!item) return NO;
    if (editItem && item == editItem) return YES;
    NSString *title = item.title;
    return [title isEqualToString:@"Edit"] || [title isEqualToString:@"Done"];
}

static BOOL ApolloDuoSubsChromeItemLooksLikeAdd(UIBarButtonItem *item, UIBarButtonItem *addItem) {
    if (!item) return NO;
    if (addItem && item == addItem) return YES;
    if (item.action == NSSelectorFromString(@"tappedAddBarButtonItem:")) return YES;
    NSString *label = item.accessibilityLabel;
    return [label isEqualToString:@"Add"] || [label isEqualToString:@"New"];
}

static BOOL ApolloDuoSubsChromeViewLooksLikeFAB(UIView *view) {
    if (![view isKindOfClass:[UIControl class]]) return NO;
    CGFloat w = CGRectGetWidth(view.bounds);
    CGFloat h = CGRectGetHeight(view.bounds);
    if (w < 40.0 || w > 72.0 || h < 40.0 || h > 72.0) return NO;
    return fabs(w - h) <= 10.0;
}

static UIView *ApolloDuoSubsChromeFindNativeFAB(UIViewController *controller) {
    UIView *ours = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeFABKey);
    UIBarButtonItem *addItem = ApolloDuoSubsChromeAddBarButtonItem(controller);
    UIView *custom = addItem.customView;
    if (ApolloDuoSubsChromeViewLooksLikeFAB(custom) && custom.superview
        && custom != ours
        && custom.superview != controller.navigationController.navigationBar
        && ![custom isDescendantOfView:controller.navigationController.navigationBar]) {
        return custom;
    }

    UIView *root = controller.isViewLoaded ? controller.view : nil;
    if (!root) return nil;
    CGFloat rootW = CGRectGetWidth(root.bounds);
    CGFloat rootH = CGRectGetHeight(root.bounds);
    UIView *best = nil;
    CGFloat bestScore = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 80) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
        if (!ApolloDuoSubsChromeViewLooksLikeFAB(view)) continue;
        if (ours && view == ours) continue;
        if ([view isDescendantOfView:controller.navigationController.navigationBar]) continue;
        CGRect inRoot = [root convertRect:view.bounds fromView:view];
        if (CGRectGetMidX(inRoot) < rootW * 0.55) continue;
        if (CGRectGetMidY(inRoot) < rootH * 0.45) continue;
        CGFloat score = CGRectGetMaxX(inRoot) + CGRectGetMaxY(inRoot);
        if (score > bestScore) {
            bestScore = score;
            best = view;
        }
    }
    return best;
}

static UIButton *ApolloDuoSubsChromeMakeFAB(UIViewController *controller) {
    SEL addSel = NSSelectorFromString(@"tappedAddBarButtonItem:");
    if (![controller respondsToSelector:addSel]) return nil;

    const CGFloat size = (CGFloat)ApolloDuoSubsChromeFABSize;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0.0, 0.0, size, size);
    button.accessibilityLabel = @"Add";
    button.adjustsImageWhenHighlighted = YES;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightSemibold];
    UIImage *plus = [UIImage systemImageNamed:@"plus" withConfiguration:config];
    if (plus) {
        [button setImage:[plus imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                forState:UIControlStateNormal];
    } else {
        [button setTitle:@"+" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightMedium];
    }
    [button addTarget:controller action:addSel forControlEvents:UIControlEventTouchUpInside];
    button.layer.cornerRadius = size * 0.5;
    button.clipsToBounds = NO;
    button.layer.shadowColor = [UIColor blackColor].CGColor;
    button.layer.shadowOpacity = 0.22;
    button.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    button.layer.shadowRadius = 6.0;
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeFABKey, button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

static void ApolloDuoSubsChromePaintFAB(UIButton *button, UIView *host) {
    if (!button) return;
    UIColor *accent = ApolloThemeAccentColor() ?: button.tintColor ?: [UIColor systemBlueColor];
    UIColor *resolved = accent;
    if (host && [accent respondsToSelector:@selector(resolvedColorWithTraitCollection:)]) {
        resolved = [accent resolvedColorWithTraitCollection:host.traitCollection];
    }
    BOOL light = ApolloColorIsLight(resolved);
    button.backgroundColor = resolved;
    UIColor *glyph = light ? [UIColor blackColor] : [UIColor whiteColor];
    button.tintColor = glyph;
    [button setTitleColor:glyph forState:UIControlStateNormal];
}

static void ApolloDuoSubsChromeClaimFABLayout(UIView *button) {
    if (!button || objc_getAssociatedObject(button, &kApolloDuoSubsChromeClaimedFABKey)) return;
    NSArray<NSLayoutConstraint *> *constraints = button.constraints;
    NSMutableArray<NSLayoutConstraint *> *disabled = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in constraints) {
        if (constraint.active) {
            constraint.active = NO;
            [disabled addObject:constraint];
        }
    }
    UIView *superview = button.superview;
    if (superview) {
        for (NSLayoutConstraint *constraint in superview.constraints) {
            if ((constraint.firstItem == button || constraint.secondItem == button)
                && constraint.active) {
                constraint.active = NO;
                [disabled addObject:constraint];
            }
        }
    }
    button.translatesAutoresizingMaskIntoConstraints = YES;
    objc_setAssociatedObject(button, &kApolloDuoSubsChromeClaimedFABKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    (void)disabled;
}

static void ApolloDuoSubsChromePositionFAB(UIView *button,
                                           UIView *container,
                                           UIEdgeInsets chrome,
                                           BOOL coverLift) {
    if (!button || !container) return;
    CGFloat width = CGRectGetWidth(button.bounds);
    CGFloat height = CGRectGetHeight(button.bounds);
    if (width < 1.0) width = (CGFloat)ApolloDuoSubsChromeFABSize;
    if (height < 1.0) height = (CGFloat)ApolloDuoSubsChromeFABSize;
    double bottom = (double)chrome.bottom;
    if (coverLift && bottom < (double)ApolloDuoCoverPillBottom) {
        bottom = (double)ApolloDuoCoverPillBottom;
    }
    double right = (double)chrome.right;
    if (coverLift && right < (double)ApolloDuoCoverPillWidth) {
        right = (double)ApolloDuoCoverPillWidth;
    }
    ApolloDuoRailRect want = ApolloDuoSubsChromeFABFrame(CGRectGetWidth(container.bounds),
                                                         CGRectGetHeight(container.bounds),
                                                         right,
                                                         bottom,
                                                         (double)width,
                                                         (double)height);
    if (!ApolloDuoSubsChromeShouldNudgeFrame(button.frame.origin.x,
                                            button.frame.origin.y,
                                            want.x,
                                            want.y)
        && fabs(button.frame.size.width - want.width) < 0.5
        && fabs(button.frame.size.height - want.height) < 0.5) {
        return;
    }
    ApolloDuoSubsChromeClaimFABLayout(button);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin
        | UIViewAutoresizingFlexibleTopMargin;
    button.frame = CGRectMake(want.x, want.y, want.width, want.height);
}

static void ApolloDuoSubsChromeRestore(UIViewController *controller) {
    if (!controller || !objc_getAssociatedObject(controller, &kApolloDuoSubsChromeAppliedKey)) {
        return;
    }

    NSNumber *savedMode = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedLargeTitleKey);
    if (savedMode) {
        controller.navigationItem.largeTitleDisplayMode = (UINavigationItemLargeTitleDisplayMode)savedMode.integerValue;
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedLargeTitleKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *savedTitle = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedTitleKey);
    if (savedTitle) {
        controller.navigationItem.title = savedTitle.length ? savedTitle : nil;
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedTitleKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *titleView = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey);
    if (titleView && controller.navigationItem.titleView == titleView) {
        controller.navigationItem.titleView = nil;
    }
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray *savedItems = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedRightItemsKey);
    if (savedItems) {
        controller.navigationItem.rightBarButtonItems =
            savedItems.count ? savedItems : nil;
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedRightItemsKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *ours = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeFABKey);
    if (ours.superview) [ours removeFromSuperview];
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeFABKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, &kApolloDuoSubsChromeAppliedKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDuoSubsChromeEnsureTitle(UIViewController *controller, int mode, BOOL regularWidth) {
    NSString *current = controller.navigationItem.title.length
        ? controller.navigationItem.title
        : controller.title;
    if (![current isEqualToString:@"Subreddits"]) {
        if (!objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedTitleKey)) {
            objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedTitleKey,
                                     current ?: @"",
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        controller.navigationItem.title = @"Subreddits";
        if (controller.title.length == 0) controller.title = @"Subreddits";
    }

    if (ApolloDuoSubsChromeShouldForceInlineTitle(mode, regularWidth)) {
        UINavigationItemLargeTitleDisplayMode currentMode =
            controller.navigationItem.largeTitleDisplayMode;
        if (currentMode != UINavigationItemLargeTitleDisplayModeNever) {
            if (!objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedLargeTitleKey)) {
                objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedLargeTitleKey,
                                         @(currentMode),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            controller.navigationItem.largeTitleDisplayMode =
                UINavigationItemLargeTitleDisplayModeNever;
        }
    }

    // Non-glass Regular width leading-aligns the native title. A
    // full-band titleView with a centered label is the stock look
    // without fighting Liquid Glass capsules (--glass uses the
    // existing title recenterer plus content-band math).
    if (IsLiquidGlass()) {
        UIView *ours = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey);
        if (ours && controller.navigationItem.titleView == ours) {
            controller.navigationItem.titleView = nil;
        }
        return;
    }
    if (!ApolloDuoSubsChromeShouldForceInlineTitle(mode, regularWidth)) return;
    if (controller.navigationItem.titleView
        && controller.navigationItem.titleView
            != objc_getAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey)) {
        return;
    }

    UIView *host = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey);
    UILabel *label = nil;
    if ([host isKindOfClass:[UIView class]]) {
        for (UIView *child in host.subviews) {
            if ([child isKindOfClass:[UILabel class]]) { label = (UILabel *)child; break; }
        }
    }
    if (!host) {
        host = [[UIView alloc] initWithFrame:CGRectZero];
        host.userInteractionEnabled = NO;
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontForContentSizeCategory = YES;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.75;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:label];
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeTitleViewKey, host,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    label.text = @"Subreddits";
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    if ([UIFont respondsToSelector:@selector(systemFontOfSize:weight:)]) {
        font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    }
    label.font = font;
    UIColor *chrome = ApolloNavigationChromeColor() ?: label.textColor ?: [UIColor labelColor];
    label.textColor = chrome;

    UINavigationBar *bar = controller.navigationController.navigationBar;
    CGFloat barWidth = bar ? CGRectGetWidth(bar.bounds) : CGRectGetWidth(controller.view.bounds);
    UIEdgeInsets chromeInsets = ApolloDeviceChromeInsetsForView(bar ?: controller.view);
    CGFloat lead = (CGFloat)ApolloDuoSubsChromeTitleLeading(mode, (double)chromeInsets.left);
    CGFloat trail = (CGFloat)ApolloDuoSubsChromeTitleTrailing((double)chromeInsets.right);
    CGFloat width = (CGFloat)ApolloDuoSubsChromeTitleMaxWidth(lead, barWidth - trail, 0.0);
    if (width < 80.0) width = 80.0;
    CGRect frame = host.frame;
    if (ApolloDuoSubsChromeShouldNudgeFrame(frame.origin.x, frame.size.width, 0.0, (double)width)
        || fabs(frame.size.height - 44.0) > 0.5) {
        host.frame = CGRectMake(0.0, 0.0, width, 44.0);
        label.frame = host.bounds;
    }
    if (controller.navigationItem.titleView != host) {
        controller.navigationItem.titleView = host;
    }
}

static void ApolloDuoSubsChromeEnsureEdit(UIViewController *controller) {
    UIBarButtonItem *editItem = controller.editButtonItem;
    UIBarButtonItem *addItem = ApolloDuoSubsChromeAddBarButtonItem(controller);
    NSArray<UIBarButtonItem *> *items = controller.navigationItem.rightBarButtonItems ?: @[];
    BOOL hasEdit = NO;
    BOOL hasAdd = NO;
    for (UIBarButtonItem *item in items) {
        if (ApolloDuoSubsChromeItemLooksLikeEdit(item, editItem)) hasEdit = YES;
        if (ApolloDuoSubsChromeItemLooksLikeAdd(item, addItem)) hasAdd = YES;
    }
    if (hasEdit && !hasAdd) return;

    if (!objc_getAssociatedObject(controller, &kApolloDuoSubsChromeSavedRightItemsKey)) {
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeSavedRightItemsKey,
                                 items,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    NSMutableArray<UIBarButtonItem *> *next = [NSMutableArray array];
    for (UIBarButtonItem *item in items) {
        if (ApolloDuoSubsChromeItemLooksLikeAdd(item, addItem)) continue;
        [next addObject:item];
    }
    if (!hasEdit && editItem) {
        // index 0 is the trailing-most item — Edit sits at the top right.
        [next insertObject:editItem atIndex:0];
    }
    if (next.count != items.count || !hasEdit) {
        controller.navigationItem.rightBarButtonItems = next.count ? next : @[editItem];
    }
}

static void ApolloDuoSubsChromeEnsureFAB(UIViewController *controller,
                                         UIEdgeInsets chrome,
                                         BOOL coverLift) {
    if (!controller.isViewLoaded) return;
    UIView *container = controller.view;
    UIView *ours = objc_getAssociatedObject(controller, &kApolloDuoSubsChromeFABKey);
    UIView *button = ApolloDuoSubsChromeFindNativeFAB(controller);
    if (button && ours && button != ours && ours.superview) {
        [ours removeFromSuperview];
    }
    if (!button) {
        button = ours ?: ApolloDuoSubsChromeMakeFAB(controller);
        if (!button) return;
        if (!ours) {
            ApolloLog(@"[DuoSubsChrome] installed floating + on RedditList");
        }
        [container addSubview:button];
    } else if (!button.superview) {
        [container addSubview:button];
    }
    if (button.superview != container && button.superview) {
        container = button.superview;
    }
    BOOL editing = controller.isEditing;
    if (button.hidden != editing) button.hidden = editing;
    if (button == ours && [button isKindOfClass:[UIButton class]]) {
        ApolloDuoSubsChromePaintFAB((UIButton *)button, container);
    }
    if (!editing) {
        ApolloDuoSubsChromePositionFAB(button, container, chrome, coverLift);
        if (button == ours) [container bringSubviewToFront:button];
    }
}

void ApolloDuoSubsChromeApply(UIViewController *controller) {
    if (!ApolloDuoSubsChromeControllerIsRedditList(controller)) return;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        ApolloDuoSubsChromeRestore(controller);
        return;
    }

    int mode = ApolloDuoCurrentMode();
    if (!ApolloDuoSubsChromeShouldApply(mode)) {
        ApolloDuoSubsChromeRestore(controller);
        return;
    }

    BOOL regularWidth = controller.traitCollection.horizontalSizeClass
        == UIUserInterfaceSizeClassRegular;
    UIEdgeInsets chrome = ApolloDeviceChromeInsetsForView(controller.view);
    BOOL coverLift = ApolloDuoCoverChromeIsActive();

    ApolloDuoSubsChromeEnsureTitle(controller, mode, regularWidth);
    ApolloDuoSubsChromeEnsureEdit(controller);
    ApolloDuoSubsChromeEnsureFAB(controller, chrome, coverLift);

    if (!objc_getAssociatedObject(controller, &kApolloDuoSubsChromeAppliedKey)) {
        objc_setAssociatedObject(controller, &kApolloDuoSubsChromeAppliedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[DuoSubsChrome] applied mode=%d regular=%d cover=%d editing=%d",
                  mode, regularWidth ? 1 : 0, coverLift ? 1 : 0,
                  controller.isEditing ? 1 : 0);
    }
}
