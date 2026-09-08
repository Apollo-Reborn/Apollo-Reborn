#import "ApolloPaneFocus.h"
#import "ApolloPaneSplitViewController.h"
#import <objc/runtime.h>

@interface ApolloPaneFocusOwner : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) ApolloPaneSplitViewController *pane;
@property (nonatomic) BOOL detail;
@property (nonatomic, strong) NSMapTable<UIScrollView *, NSNumber *> *originalScrollPolicy;
@end

static char kFocusOwner;
static UIScrollView *ApolloPaneScrollView(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return nil;
    if ([view isKindOfClass:UITableView.class]) return (id)view;
    for (UIView *child in view.subviews) {
        UIScrollView *scroll = ApolloPaneScrollView(child, depth + 1);
        if (scroll) return scroll;
    }
    return nil;
}

@implementation ApolloPaneFocusOwner
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other { return YES; }
- (void)tapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    UINavigationController *detail = [self.pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
    UIView *view = detail.viewIfLoaded;
    BOOL inside = view.window && CGRectContainsPoint(view.bounds, [gesture locationInView:view]);
    ApolloPaneFocusColumn(self.pane, inside, NO);
}
@end

void ApolloPaneInstallFocus(ApolloPaneSplitViewController *pane) {
    if (objc_getAssociatedObject(pane, &kFocusOwner)) return;
    ApolloPaneFocusOwner *owner = [ApolloPaneFocusOwner new];
    owner.pane = pane;
    owner.originalScrollPolicy = [NSMapTable weakToStrongObjectsMapTable];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:owner action:@selector(tapped:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = owner;
    [pane.view addGestureRecognizer:tap];
    objc_setAssociatedObject(pane, &kFocusOwner, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UIViewController *ApolloPaneFocusedController(ApolloPaneSplitViewController *pane) {
    ApolloPaneFocusOwner *owner = objc_getAssociatedObject(pane, &kFocusOwner);
    UINavigationController *nav = [pane apollo_navigationControllerForColumn:
        owner.detail ? ApolloPaneColumnSecondary : ApolloPaneColumnPrimary];
    if (!nav.viewIfLoaded.window) nav = (id)[pane apollo_preferredContentColumnController];
    return nav.topViewController;
}

void ApolloPaneRefreshFocus(ApolloPaneSplitViewController *pane) {
    ApolloPaneFocusOwner *owner = objc_getAssociatedObject(pane, &kFocusOwner);
    UIViewController *focused = ApolloPaneFocusedController(pane);
    for (NSNumber *column in @[@(ApolloPaneColumnPrimary), @(ApolloPaneColumnSecondary)]) {
        UINavigationController *nav = [pane apollo_navigationControllerForColumn:column.integerValue];
        UIScrollView *table = ApolloPaneScrollView(nav.topViewController.viewIfLoaded, 0);
        if (table && ![owner.originalScrollPolicy objectForKey:table])
            [owner.originalScrollPolicy setObject:@(table.scrollsToTop) forKey:table];
        table.scrollsToTop = nav.topViewController == focused && table.window != nil;
    }
}

void ApolloPaneFocusColumn(ApolloPaneSplitViewController *pane, BOOL detail, BOOL announce) {
    ApolloPaneFocusOwner *owner = objc_getAssociatedObject(pane, &kFocusOwner);
    owner.detail = detail;
    ApolloPaneRefreshFocus(pane);
    if (announce) {
        [pane becomeFirstResponder];
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,
                                        ApolloPaneFocusedController(pane).viewIfLoaded);
    }
}

void ApolloPaneRestoreFocusPolicy(ApolloPaneSplitViewController *pane) {
    ApolloPaneFocusOwner *owner = objc_getAssociatedObject(pane, &kFocusOwner);
    for (UIScrollView *table in owner.originalScrollPolicy.keyEnumerator)
        table.scrollsToTop = [[owner.originalScrollPolicy objectForKey:table] boolValue];
    [owner.originalScrollPolicy removeAllObjects];
}
