#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

static char kApolloPhotoComposerLoggedControllerKey;
static char kApolloPhotoComposerScrollFixAppliedKey;

static BOOL ApolloPhotoComposerStringContains(NSString *haystack, NSString *needle) {
    return [haystack isKindOfClass:[NSString class]] && needle.length > 0 &&
        [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *ApolloPhotoComposerTextForView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text;
    if ([view isKindOfClass:[UITextField class]]) return ((UITextField *)view).text;
    if ([view isKindOfClass:[UITextView class]]) return ((UITextView *)view).text;
    if ([view isKindOfClass:[UIButton class]]) return [(UIButton *)view currentTitle];
    NSString *accessibilityLabel = view.accessibilityLabel;
    return accessibilityLabel.length > 0 ? accessibilityLabel : nil;
}

static BOOL ApolloPhotoComposerViewContainsText(UIView *rootView, NSString *needle) {
    if (!rootView || needle.length == 0) return NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rootView];
    NSUInteger inspected = 0;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;
        if (ApolloPhotoComposerStringContains(ApolloPhotoComposerTextForView(view), needle)) return YES;
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return NO;
}

static BOOL ApolloPhotoComposerControllerIsInScope(UIViewController *controller) {
    if (!controller.isViewLoaded || !controller.view.window) return NO;

    NSString *title = controller.navigationItem.title ?: controller.title;
    if (ApolloPhotoComposerStringContains(title, @"Photo Post")) return YES;

    UIView *view = controller.view;
    BOOL hasPhotoChooser = ApolloPhotoComposerViewContainsText(view, @"Choose from Photos");
    if (!hasPhotoChooser) return NO;

    BOOL hasPostingContext = ApolloPhotoComposerViewContainsText(view, @"Posting in") ||
        ApolloPhotoComposerViewContainsText(view, @"Set Flair") ||
        ApolloPhotoComposerViewContainsText(view, @"Flair");
    BOOL hasPostMode = ApolloPhotoComposerViewContainsText(view, @"Photo") &&
        ApolloPhotoComposerViewContainsText(view, @"Link") &&
        ApolloPhotoComposerViewContainsText(view, @"Text");
    return hasPostingContext || hasPostMode;
}

static UICollectionView *ApolloPhotoComposerFindImageStrip(UIViewController *controller) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:controller.view];
    NSUInteger inspected = 0;
    UICollectionView *fallback = nil;
    while (stack.count > 0 && inspected++ < 900) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.01) continue;

        if ([view isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)view;
            CGRect bounds = collectionView.bounds;
            BOOL hasStripShape = bounds.size.width >= 220.0 && bounds.size.height >= 70.0 && bounds.size.height <= 340.0;
            BOOL hasHorizontalOverflow = collectionView.contentSize.width > bounds.size.width + 8.0;
            if (hasStripShape && hasHorizontalOverflow) {
                NSString *delegateClass = collectionView.delegate ? NSStringFromClass([collectionView.delegate class]) : @"";
                if (ApolloPhotoComposerStringContains(delegateClass, @"ImageSlider")) return collectionView;
                if (!fallback) fallback = collectionView;
            }
        }

        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return fallback;
}

static BOOL ApolloPhotoComposerStripShouldCancelContentTouch(id self, SEL _cmd, UIView *view) {
    return YES;
}

static BOOL ApolloPhotoComposerRecognizerCompetesWithStripPan(UIGestureRecognizer *recognizer) {
    NSString *className = NSStringFromClass(recognizer.class);
    return [className isEqualToString:@"UIPanGestureRecognizer"] ||
        [className isEqualToString:@"_UISwipeActionPanGestureRecognizer"] ||
        [className isEqualToString:@"_UIParallaxTransitionPanGestureRecognizer"];
}

static NSUInteger ApolloPhotoComposerPreferStripPan(UIScrollView *scrollView) {
    UIPanGestureRecognizer *stripPan = scrollView.panGestureRecognizer;
    if (!stripPan) return 0;

    NSUInteger requiredCount = 0;
    for (UIView *ancestor = scrollView.superview; ancestor; ancestor = ancestor.superview) {
        for (UIGestureRecognizer *recognizer in ancestor.gestureRecognizers) {
            if (recognizer == stripPan || !ApolloPhotoComposerRecognizerCompetesWithStripPan(recognizer)) continue;
            [recognizer requireGestureRecognizerToFail:stripPan];
            requiredCount++;
        }
    }
    return requiredCount;
}

static void ApolloPhotoComposerApplyScrollFix(UICollectionView *collectionView) {
    if (!collectionView) return;
    if (objc_getAssociatedObject(collectionView, &kApolloPhotoComposerScrollFixAppliedKey)) return;

    collectionView.delaysContentTouches = NO;
    collectionView.canCancelContentTouches = YES;
    collectionView.alwaysBounceHorizontal = YES;

    Class originalClass = object_getClass(collectionView);
    NSString *subclassName = [NSString stringWithFormat:@"ApolloComposerStripScrollFix_%@", NSStringFromClass(originalClass)];
    Class subclass = objc_getClass(subclassName.UTF8String);
    if (!subclass) {
        subclass = objc_allocateClassPair(originalClass, subclassName.UTF8String, 0);
        if (subclass) {
            SEL selector = @selector(touchesShouldCancelInContentView:);
            Method method = class_getInstanceMethod([UIScrollView class], selector);
            const char *types = method ? method_getTypeEncoding(method) : "c@:@";
            class_addMethod(subclass, selector, (IMP)ApolloPhotoComposerStripShouldCancelContentTouch, types);
            objc_registerClassPair(subclass);
        }
    }
    if (subclass && object_getClass(collectionView) != subclass) {
        object_setClass(collectionView, subclass);
    }

    NSUInteger requiredCount = ApolloPhotoComposerPreferStripPan(collectionView);
    objc_setAssociatedObject(collectionView, &kApolloPhotoComposerScrollFixAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[PhotoComposerScroll] enabled selected-photo strip horizontal scrolling (ancestor recognizers=%lu)", (unsigned long)requiredCount);
}

static void ApolloPhotoComposerRepairController(UIViewController *controller, NSString *reason) {
    if (!ApolloPhotoComposerControllerIsInScope(controller)) return;

    NSNumber *logged = objc_getAssociatedObject(controller, &kApolloPhotoComposerLoggedControllerKey);
    if (![logged boolValue]) {
        ApolloLog(@"[PhotoComposerScroll] composer in scope controller=%@ reason=%@ title=%@",
            NSStringFromClass(controller.class), reason ?: @"(unknown)",
            controller.navigationItem.title ?: controller.title ?: @"(none)");
        objc_setAssociatedObject(controller, &kApolloPhotoComposerLoggedControllerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloPhotoComposerApplyScrollFix(ApolloPhotoComposerFindImageStrip(controller));
}

static void ApolloPhotoComposerRepairControllerSoon(UIViewController *controller, NSString *reason) {
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (strongController) ApolloPhotoComposerRepairController(strongController, reason);
    });
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloPhotoComposerRepairControllerSoon(self, @"viewDidAppear");
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloPhotoComposerRepairController(self, @"viewDidLayoutSubviews");
}

%end
