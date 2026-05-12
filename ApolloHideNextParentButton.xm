#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

// MARK: - Hide Next Parent Comment Button
//
// Apollo draws the next-parent-comment jump control as a floating circular
// overlay in the bottom-right of CommentsViewController. The implementation is
// Texture/AsyncDisplayKit-backed, so the visible circle is not necessarily a
// UIView with a matching cornerRadius. Use geometry instead: find the best
// small square-ish floating view near the bottom-right of the comments UI, skip
// tab bars/table cells, and keep it hidden while the preference is enabled.

static NSString *const kApolloHideNextParentButtonNotification = @"ApolloHideNextParentButtonChanged";
static const void *kApolloHiddenViewKey = &kApolloHiddenViewKey;

static NSHashTable<UIViewController *> *ApolloVisibleCommentsVCs(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static BOOL ApolloShouldHideNextParentButton(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyHideNextParentButton];
}

static BOOL ApolloViewHasAncestorOfClass(UIView *view, Class klass) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:klass]) return YES;
    }
    return NO;
}

static BOOL ApolloViewLooksLikeTabChrome(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        NSString *className = NSStringFromClass([ancestor class]);
        if ([ancestor isKindOfClass:[UITabBar class]] ||
            [className containsString:@"TabBar"] ||
            [className containsString:@"UITab"] ||
            [className containsString:@"TabButton"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL ApolloViewLooksLikeCommentCellContent(UIView *view) {
    return ApolloViewHasAncestorOfClass(view, [UITableViewCell class]) ||
           ApolloViewHasAncestorOfClass(view, NSClassFromString(@"_UITableViewCellContentView"));
}

static CGFloat ApolloFloatingButtonScore(UIView *view, UIView *container) {
    if (!view || view == container || view.hidden || view.alpha < 0.1) return -CGFLOAT_MAX;

    CGFloat width = view.bounds.size.width;
    CGFloat height = view.bounds.size.height;
    if (width < 28.0 || width > 96.0 || height < 28.0 || height > 96.0) return -CGFLOAT_MAX;
    if (fabs(width - height) > 16.0) return -CGFLOAT_MAX;
    if (ApolloViewLooksLikeTabChrome(view) || ApolloViewLooksLikeCommentCellContent(view)) return -CGFLOAT_MAX;

    CGRect frameInContainer = [view.superview convertRect:view.frame toView:container];
    CGFloat centerX = CGRectGetMidX(frameInContainer);
    CGFloat centerY = CGRectGetMidY(frameInContainer);
    if (centerX < container.bounds.size.width * 0.55) return -CGFLOAT_MAX;
    if (centerY < container.bounds.size.height * 0.50) return -CGFLOAT_MAX;

    CGFloat rightDistance = fabs(container.bounds.size.width - centerX);
    CGFloat bottomDistance = fabs(container.bounds.size.height - centerY);
    CGFloat sizeBonus = 80.0 - fabs(width - 56.0) - fabs(height - 56.0);
    return 1000.0 - rightDistance - (bottomDistance * 0.65) + sizeBonus;
}

static UIView *ApolloFindBestFloatingButtonInContainer(UIView *container, BOOL verbose) {
    if (!container) return nil;

    UIView *bestView = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    NSInteger loggedCandidates = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:container];

    while (queue.count > 0) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];

        CGFloat score = ApolloFloatingButtonScore(candidate, container);
        if (score > bestScore) {
            bestScore = score;
            bestView = candidate;
        }
        if (verbose && score > -CGFLOAT_MAX && loggedCandidates < 12) {
            CGRect frame = [candidate.superview convertRect:candidate.frame toView:container];
            ApolloLog(@"[HideNextParentBtn] candidate class=%@ frame=%@ score=%.1f alpha=%.2f corner=%g",
                      NSStringFromClass([candidate class]), NSStringFromCGRect(frame), score,
                      candidate.alpha, candidate.layer.cornerRadius);
            loggedCandidates++;
        }

        for (UIView *subview in candidate.subviews) {
            [queue addObject:subview];
        }
    }

    return bestScore > -CGFLOAT_MAX ? bestView : nil;
}

static UIView *ApolloFindNextParentButton(UIViewController *commentsVC, BOOL verbose) {
    NSArray<UIView *> *containers = @[
        commentsVC.view ?: (UIView *)[NSNull null],
        commentsVC.navigationController.view ?: (UIView *)[NSNull null],
        commentsVC.view.window ?: (UIView *)[NSNull null]
    ];

    for (UIView *container in containers) {
        if (![container isKindOfClass:[UIView class]]) continue;
        UIView *button = ApolloFindBestFloatingButtonInContainer(container, verbose);
        if (button) {
            if (verbose) {
                CGRect frame = [button.superview convertRect:button.frame toView:container];
                ApolloLog(@"[HideNextParentBtn] best container=%@ buttonClass=%@ frame=%@",
                          NSStringFromClass([container class]), NSStringFromClass([button class]),
                          NSStringFromCGRect(frame));
            }
            return button;
        }
    }

    if (verbose) {
        ApolloLog(@"[HideNextParentBtn] no floating button candidate found; vc=%@ loaded=%d window=%@",
                  NSStringFromClass([commentsVC class]), commentsVC.isViewLoaded,
                  commentsVC.view.window ? @"YES" : @"NO");
    }
    return nil;
}

static void ApolloApplyNextParentButtonVisibility(UIViewController *commentsVC, BOOL verbose) {
    if (!commentsVC.isViewLoaded) return;

    BOOL shouldHide = ApolloShouldHideNextParentButton();
    UIView *previouslyHidden = objc_getAssociatedObject(commentsVC, kApolloHiddenViewKey);

    if (!shouldHide) {
        if (previouslyHidden) {
            previouslyHidden.hidden = NO;
            objc_setAssociatedObject(commentsVC, kApolloHiddenViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (verbose) ApolloLog(@"[HideNextParentBtn] restored class=%@", NSStringFromClass([previouslyHidden class]));
        }
        return;
    }

    // shouldHide: always re-scan. Apollo may recreate the button after we
    // hid an earlier instance, so we cannot trust the cached reference.
    UIView *button = ApolloFindNextParentButton(commentsVC, verbose);
    if (!button) return;

    if (!button.hidden) {
        button.hidden = YES;
        if (verbose) ApolloLog(@"[HideNextParentBtn] hid class=%@", NSStringFromClass([button class]));
    }
    if (button != previouslyHidden) {
        objc_setAssociatedObject(commentsVC, kApolloHiddenViewKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    [ApolloVisibleCommentsVCs() addObject:(UIViewController *)self];
    ApolloLog(@"[HideNextParentBtn] CommentsVC viewDidAppear pref=%d", ApolloShouldHideNextParentButton());
    ApolloApplyNextParentButtonVisibility((UIViewController *)self, YES);
    // Apollo creates / re-shows the next-parent button asynchronously after
    // viewDidAppear (and again after the first user scroll). Schedule a few
    // delayed re-scans so we catch it without having to bounce screens.
    if (ApolloShouldHideNextParentButton()) {
        __weak UIViewController *weakSelf = (UIViewController *)self;
        NSArray<NSNumber *> *delays = @[@0.05, @0.2, @0.6, @1.2];
        for (NSNumber *delayNum in delays) {
            NSTimeInterval delay = [delayNum doubleValue];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *strong = weakSelf;
                if (!strong || !ApolloShouldHideNextParentButton()) return;
                ApolloApplyNextParentButtonVisibility(strong, NO);
            });
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [ApolloVisibleCommentsVCs() removeObject:(UIViewController *)self];
    %orig(animated);
}

- (void)viewDidLayoutSubviews {
    %orig;
    // Always run when the pref is on (Apollo can recreate the button after
    // we hid the previous instance). Also run if we previously hid one and
    // the pref just turned off so we restore it.
    if (!ApolloShouldHideNextParentButton() &&
        !objc_getAssociatedObject(self, kApolloHiddenViewKey)) return;
    ApolloApplyNextParentButtonVisibility((UIViewController *)self, NO);
}

%end

%ctor {
    ApolloLog(@"[HideNextParentBtn] ctor initialized");
    [[NSNotificationCenter defaultCenter]
        addObserverForName:kApolloHideNextParentButtonNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        ApolloLog(@"[HideNextParentBtn] preference changed pref=%d", ApolloShouldHideNextParentButton());
        for (UIViewController *commentsVC in ApolloVisibleCommentsVCs().allObjects) {
            ApolloApplyNextParentButtonVisibility(commentsVC, YES);
            // Force a layout pass; if the button isn't found right now (e.g.
            // because Apollo recreates it lazily), viewDidLayoutSubviews will
            // try again.
            [commentsVC.view setNeedsLayout];
        }
    }];
}
