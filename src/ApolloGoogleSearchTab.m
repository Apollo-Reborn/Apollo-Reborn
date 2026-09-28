// ApolloGoogleSearchTab.m
//
// Search tab: search Reddit directly or through Google, picked from the search
// field's magnifier (feature request "In-app Google Search").
//
// Reddit mode is Apollo's own search, untouched. Google mode searches Reddit
// through Google (ApolloGoogleSearch.{h,m}) and lists the results in the same
// tab (ApolloGoogleSearchViewController.{h,m}); tapping one opens the post or
// comment natively through Apollo's router.
//
// How it attaches to Apollo's SearchViewController (the hooks themselves live
// in ApolloSearchTabFixes.xm, the Search tab's one hook module; it calls the
// entry points at the bottom of this file):
//   * The engine picker is the search field's own magnifier: its leftView
//     becomes an ApolloSearchEngineButton (tap or press-and-hold → Reddit /
//     Google).
//     Nothing is added to Apollo's table, so Reddit mode looks exactly as
//     before apart from a small chevron next to the magnifier.
//   * The Google list is a child view controller laid over Apollo's table
//     while Google mode has text.
//   * Apollo's own text handling keeps running underneath in Google mode, so
//     its suggestions are current the moment the engine goes back to Reddit
//     (and ApolloSearchTabFixes' row bookkeeping, which wraps Apollo's text
//     changes, never sees a skipped update).
//   * The keyboard's Search button runs the Google search in Google mode; in
//     Reddit mode it is Apollo's as before.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloGoogleSearchTab.h"

#import "ApolloCommon.h"
#import "ApolloGoogleSearchViewController.h"

@interface _TtC6Apollo20SearchViewController : UIViewController
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText;
@end

static const void *kApolloGSOverlayKey = &kApolloGSOverlayKey;
static const void *kApolloGSButtonKey = &kApolloGSButtonKey;
static const void *kApolloGSPlaceholderKey = &kApolloGSPlaceholderKey;

static NSString *const kApolloGSGooglePlaceholder = @"Search Reddit with Google";

static UITableView *ApolloGSApolloTable(UIViewController *vc) {
    for (Class cls = object_getClass(vc); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, "tableView");
        if (!ivar) continue;
        id table = object_getIvar(vc, ivar);
        return [table isKindOfClass:UITableView.class] ? table : nil;
    }
    return nil;
}

static UISearchBar *ApolloGSSearchBar(UIViewController *vc) {
    UIView *titleView = vc.navigationItem.titleView;
    if ([titleView isKindOfClass:UISearchBar.class]) return (UISearchBar *)titleView;
    for (Class cls = object_getClass(vc); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, "searchBar");
        if (!ivar) continue;
        id bar = object_getIvar(vc, ivar);
        return [bar isKindOfClass:UISearchBar.class] ? bar : nil;
    }
    return nil;
}

static ApolloGoogleSearchResultsViewController *ApolloGSOverlay(UIViewController *vc) {
    return objc_getAssociatedObject(vc, kApolloGSOverlayKey);
}

static BOOL ApolloGSGoogleMode(void) {
    return ApolloSearchEngineCurrent() == ApolloSearchEngineGoogle;
}

// Swap the field's placeholder text. Set through UISearchBar.placeholder, the
// same path Apollo uses, so it is drawn exactly like Apollo's own (an
// attributedPlaceholder written from the tweak would be recolored by a custom
// theme's text sink and come out brighter than Apollo's).
static void ApolloGSApplyPlaceholder(UIViewController *vc) {
    UISearchBar *bar = ApolloGSSearchBar(vc);
    if (!bar) return;
    NSString *current = bar.placeholder;
    NSString *apolloPlaceholder = objc_getAssociatedObject(vc, kApolloGSPlaceholderKey);
    if (current.length && ![current isEqualToString:kApolloGSGooglePlaceholder] &&
        ![current isEqualToString:apolloPlaceholder]) {
        // First sighting, or Apollo rewrote its placeholder since: remember Apollo's.
        apolloPlaceholder = [current copy];
        objc_setAssociatedObject(vc, kApolloGSPlaceholderKey, apolloPlaceholder, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    NSString *wanted = ApolloGSGoogleMode() ? kApolloGSGooglePlaceholder : apolloPlaceholder;
    if (wanted.length && ![current isEqualToString:wanted]) bar.placeholder = wanted;
}

// While the Google list covers Apollo's table, the navigation bar's top edge
// (Liquid Glass scroll-edge effect) should follow the list. Apollo registers
// no content scroll view of its own (UIKit finds its table by itself), so
// hiding the list restores exactly what was there — normally nil — rather
// than registering Apollo's table explicitly.
static const void *kApolloGSPriorScrollViewKey = &kApolloGSPriorScrollViewKey;

static void ApolloGSClaimTopEdge(UIViewController *vc, UIScrollView *scrollView, BOOL claim) {
    if (@available(iOS 15.0, *)) {
        if (claim) {
            UIScrollView *current = [vc contentScrollViewForEdge:NSDirectionalRectEdgeTop];
            if (current == scrollView) return;
            objc_setAssociatedObject(vc, kApolloGSPriorScrollViewKey, current ?: (id)NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [vc setContentScrollView:scrollView forEdge:NSDirectionalRectEdgeTop];
        } else {
            id prior = objc_getAssociatedObject(vc, kApolloGSPriorScrollViewKey);
            if (!prior) return;   // never claimed
            objc_setAssociatedObject(vc, kApolloGSPriorScrollViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if ([vc contentScrollViewForEdge:NSDirectionalRectEdgeTop] != scrollView) return;   // someone else took it since
            [vc setContentScrollView:prior == NSNull.null ? nil : prior forEdge:NSDirectionalRectEdgeTop];
        }
    }
}

// The Google list shows while Google mode has text; otherwise Apollo's table does.
static void ApolloGSUpdateOverlay(UIViewController *vc, BOOL animated) {
    ApolloGoogleSearchResultsViewController *overlay = ApolloGSOverlay(vc);
    if (!overlay) return;
    UISearchBar *bar = ApolloGSSearchBar(vc);
    UITableView *apolloTable = ApolloGSApolloTable(vc);
    BOOL show = ApolloGSGoogleMode() && bar.text.length > 0;
    UIView *view = overlay.view;
    BOOL shown = !view.hidden && view.alpha > 0.01;
    if (show == shown) return;

    NSTimeInterval duration = (animated && !UIAccessibilityIsReduceMotionEnabled()) ? 0.18 : 0;
    if (show) {
        overlay.pageBackgroundColor = apolloTable.backgroundColor;
        [vc.view bringSubviewToFront:view];
        view.hidden = NO;
        view.alpha = duration > 0 ? 0 : 1;
        ApolloGSClaimTopEdge(vc, overlay.tableView, YES);
        // Start flush with the top edge (the list's top inset can change while
        // it is hidden), unless it is showing results the user scrolled.
        if (overlay.isScrolledToTop || overlay.submittedQuery.length == 0) [overlay scrollToTopAnimated:NO];
        [UIView animateWithDuration:duration animations:^{ view.alpha = 1; }];
        ApolloLog(@"[GoogleSearch] Google list shown");
    } else {
        ApolloGSClaimTopEdge(vc, overlay.tableView, NO);
        [UIView animateWithDuration:duration animations:^{ view.alpha = 0; } completion:^(BOOL finished) {
            if (view.alpha < 0.01) view.hidden = YES;
        }];
        ApolloLog(@"[GoogleSearch] Google list hidden");
    }
}

static void ApolloGSSubmit(UIViewController *vc, NSString *text) {
    UISearchBar *bar = ApolloGSSearchBar(vc);
    ApolloGoogleSearchResultsViewController *overlay = ApolloGSOverlay(vc);
    if (!bar || !overlay || text.length == 0) return;
    if (![bar.text isEqualToString:text]) {
        // Setting .text doesn't call the delegate; run Apollo's own text
        // handling so its (hidden) suggestions stay in step with the field.
        bar.text = text;
        if ([vc respondsToSelector:@selector(searchBar:textDidChange:)]) {
            [(_TtC6Apollo20SearchViewController *)vc searchBar:bar textDidChange:text];
        }
    }
    [bar resignFirstResponder];
    [overlay searchForQuery:text];
    ApolloGSUpdateOverlay(vc, YES);
}

static void ApolloGSSetEngine(UIViewController *vc, ApolloSearchEngine engine) {
    ApolloSearchEngineSetCurrent(engine);   // the button re-reads it
    ApolloGSApplyPlaceholder(vc);
    UISearchBar *bar = ApolloGSSearchBar(vc);
    ApolloGoogleSearchResultsViewController *overlay = ApolloGSOverlay(vc);
    if (engine == ApolloSearchEngineGoogle && bar.text.length) {
        // Still typing: suggest. Query already entered: run it on Google.
        if (bar.isFirstResponder) [overlay showSuggestionsForText:bar.text];
        else [overlay searchForQuery:bar.text];
    } else if (engine == ApolloSearchEngineReddit) {
        [overlay reset];
    }
    ApolloGSUpdateOverlay(vc, YES);
}

// Puts the engine button where the search field's magnifier was. Also re-run
// on every appearance: if Apollo (or a theme change) ever rebuilds the field's
// leftView, the button goes back, keeping the magnifier's tint.
static void ApolloGSInstallEngineButton(UIViewController *vc) {
    UITextField *field = ApolloGSSearchBar(vc).searchTextField;
    if (!field) return;
    ApolloSearchEngineButton *button = objc_getAssociatedObject(vc, kApolloGSButtonKey);
    if (button && field.leftView == button) return;
    if (!button) {
        button = [[ApolloSearchEngineButton alloc] initWithFrame:CGRectZero];
        __weak UIViewController *weakVC = vc;
        button.engineChanged = ^(ApolloSearchEngine engine) {
            UIViewController *strongVC = weakVC;
            if (strongVC) ApolloGSSetEngine(strongVC, engine);
        };
        objc_setAssociatedObject(vc, kApolloGSButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *magnifier = field.leftView;
    if (magnifier && magnifier != button) button.iconColor = magnifier.tintColor;
    field.leftView = button;
    field.leftViewMode = UITextFieldViewModeAlways;
    ApolloLog(@"[GoogleSearch] engine button installed in the search field (engine %@)",
              ApolloGSGoogleMode() ? @"Google" : @"Reddit");
}

static void ApolloGSInstall(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, kApolloGSOverlayKey)) return;
    UITableView *table = ApolloGSApolloTable(vc);
    if (!table || !vc.isViewLoaded) {
        ApolloLog(@"[GoogleSearch] Search tab table not found; Google mode not installed");
        return;
    }
    __weak UIViewController *weakVC = vc;

    ApolloGoogleSearchResultsViewController *overlay = [[ApolloGoogleSearchResultsViewController alloc] init];
    overlay.submitText = ^(NSString *text) {
        UIViewController *strongVC = weakVC;
        if (strongVC) ApolloGSSubmit(strongVC, text);
    };
    overlay.willOpenResult = ^{
        [ApolloGSSearchBar(weakVC) resignFirstResponder];
    };
    [vc addChildViewController:overlay];
    overlay.view.frame = vc.view.bounds;
    overlay.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.view.hidden = YES;
    overlay.view.alpha = 0;
    [vc.view addSubview:overlay.view];
    [overlay didMoveToParentViewController:vc];
    objc_setAssociatedObject(vc, kApolloGSOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloGSInstallEngineButton(vc);
    ApolloGSApplyPlaceholder(vc);
    ApolloLog(@"[GoogleSearch] Search tab Google mode installed (engine %@)", ApolloGSGoogleMode() ? @"Google" : @"Reddit");
}

#pragma mark - Entry points (called from ApolloSearchTabFixes.xm's hooks)

void ApolloGoogleSearchTabViewDidLoad(UIViewController *searchVC) {
    ApolloGSInstall(searchVC);
}

void ApolloGoogleSearchTabViewDidAppear(UIViewController *searchVC) {
    ApolloGSInstall(searchVC);
    ApolloGSInstallEngineButton(searchVC);
    ApolloGSApplyPlaceholder(searchVC);
    ApolloGoogleSearchResultsViewController *overlay = ApolloGSOverlay(searchVC);
    if (overlay && !overlay.view.hidden) {
        overlay.pageBackgroundColor = ApolloGSApolloTable(searchVC).backgroundColor;
        [overlay.tableView reloadData];   // the theme may have changed while away
    }
}

void ApolloGoogleSearchTabTextDidChange(UIViewController *searchVC, NSString *text) {
    if (!ApolloGSGoogleMode()) return;
    ApolloGoogleSearchResultsViewController *overlay = ApolloGSOverlay(searchVC);
    if (!overlay) return;
    if (text.length == 0) [overlay reset];
    else [overlay showSuggestionsForText:text];
    ApolloGSUpdateOverlay(searchVC, YES);
}

BOOL ApolloGoogleSearchTabHandleSearchButton(UIViewController *searchVC, UISearchBar *bar) {
    if (!ApolloGSGoogleMode() || bar.text.length == 0 || !ApolloGSOverlay(searchVC)) return NO;
    ApolloGSSubmit(searchVC, bar.text);
    return YES;
}

void ApolloGoogleSearchTabDidCancel(UIViewController *searchVC) {
    ApolloGoogleSearchResultsViewController *overlay = ApolloGSOverlay(searchVC);
    if (!overlay) return;
    [overlay reset];
    ApolloGSUpdateOverlay(searchVC, YES);
}

BOOL ApolloGoogleSearchTabHandleReselect(UIViewController *searchVC) {
    ApolloGoogleSearchResultsViewController *overlay = ApolloGSOverlay(searchVC);
    if (!overlay || overlay.view.hidden) return NO;
    if (!overlay.isScrolledToTop) {
        [overlay scrollToTopAnimated:!UIAccessibilityIsReduceMotionEnabled()];
    } else {
        [ApolloGSSearchBar(searchVC) becomeFirstResponder];
    }
    return YES;
}
