#import "ApolloDuoSubsChrome.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>

static char kApolloDuoSubsChromeScrollAnchorKey;

static UITableView *ApolloDuoSubsChromeFindTableView(UIView *view) {
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *tableView = ApolloDuoSubsChromeFindTableView(subview);
        if (tableView) return tableView;
    }
    return nil;
}

// Editing can temporarily expose Apollo's hidden Moderator shortcut above the
// alphabetic rows. Preserve a visible row by identity, rather than by index
// path, because every later index path changes while that row is present.
static NSDictionary *ApolloDuoSubsChromeCaptureScrollAnchor(UITableView *tableView) {
    if (!tableView || tableView.safeAreaInsets.right < 40.0 || tableView.visibleCells.count == 0) return nil;

    CGFloat viewportMidY = CGRectGetMidY(tableView.bounds);
    UITableViewCell *anchorCell = nil;
    NSIndexPath *anchorPath = nil;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (UITableViewCell *cell in tableView.visibleCells) {
        NSIndexPath *path = [tableView indexPathForCell:cell];
        NSString *title = cell.textLabel.text;
        if (!path || title.length == 0 || path.section == 0) continue;
        CGRect rect = [tableView rectForRowAtIndexPath:path];
        CGFloat distance = fabs(CGRectGetMidY(rect) - viewportMidY);
        if (distance < nearestDistance) {
            nearestDistance = distance;
            anchorCell = cell;
            anchorPath = path;
        }
    }
    if (!anchorCell || !anchorPath) return nil;

    CGRect rect = [tableView rectForRowAtIndexPath:anchorPath];
    return @{
        @"title": anchorCell.textLabel.text,
        @"section": @(anchorPath.section),
        @"delta": @(CGRectGetMinY(rect) - tableView.contentOffset.y),
    };
}

static void ApolloDuoSubsChromeRestoreScrollAnchor(UITableView *tableView, NSDictionary *anchor) {
    if (!tableView || !anchor || !tableView.window || tableView.dragging
        || tableView.tracking || tableView.decelerating) return;
    NSString *title = anchor[@"title"];
    NSInteger section = [anchor[@"section"] integerValue];
    UITableViewCell *fallback = nil;
    for (UITableViewCell *cell in tableView.visibleCells) {
        if (![cell.textLabel.text isEqualToString:title]) continue;
        NSIndexPath *path = [tableView indexPathForCell:cell];
        if (!path) continue;
        if (!fallback) fallback = cell;
        if (path.section == section) {
            fallback = cell;
            break;
        }
    }
    NSIndexPath *path = fallback ? [tableView indexPathForCell:fallback] : nil;
    if (!path) return;

    CGRect rect = [tableView rectForRowAtIndexPath:path];
    CGFloat minY = -tableView.adjustedContentInset.top;
    CGFloat maxY = MAX(minY, tableView.contentSize.height - CGRectGetHeight(tableView.bounds)
                       + tableView.adjustedContentInset.bottom);
    CGFloat desiredY = CGRectGetMinY(rect) - [anchor[@"delta"] doubleValue];
    [tableView setContentOffset:CGPointMake(tableView.contentOffset.x,
                                            MIN(MAX(desiredY, minY), maxY))
                       animated:NO];
}

static void ApolloDuoSubsChromeRestoreScrollAnchorAfterEditing(UITableView *tableView,
                                                                NSDictionary *anchor) {
    if (!tableView || !anchor) return;
    NSObject *token = [NSObject new];
    objc_setAssociatedObject(tableView, &kApolloDuoSubsChromeScrollAnchorKey, token,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UITableView *weakTable = tableView;
    void (^restore)(void) = ^{
        UITableView *strongTable = weakTable;
        if (!strongTable || objc_getAssociatedObject(strongTable,
                                                       &kApolloDuoSubsChromeScrollAnchorKey) != token) return;
        [strongTable layoutIfNeeded];
        ApolloDuoSubsChromeRestoreScrollAnchor(strongTable, anchor);
    };
    dispatch_async(dispatch_get_main_queue(), restore);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.36 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), restore);
}

// RedditList-only hooks. Do not attach chrome writes to UIView or
// UITableView layoutSubviews — those paths already hung the Duo sim
// when they wrote layout inputs. viewDidLayout is idempotent.

%group ApolloDuoSubsChromeList

%hook _TtC6Apollo24RedditListViewController

- (void)viewDidLoad {
    %orig;
    // Give the destination navigation item its complete button set before a
    // push or pop starts. UIKit can then build both glass transition views as
    // part of the navigation transition instead of inserting Edit afterward.
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    // Refresh before UIKit snapshots the destination bar. The item normally
    // already exists from viewDidLoad; this only updates its edit state.
    ApolloDuoSubsChromeApply((UIViewController *)self);
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

- (void)viewWillDisappear:(BOOL)animated {
    ApolloDuoSubsChromeRemoveFloatingEdit((UIViewController *)self);
    %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    %orig;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoSubsChromeApply((UIViewController *)self);
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        ApolloDuoSubsChromeApply((UIViewController *)self);
    }];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    UITableView *tableView = ApolloDuoSubsChromeFindTableView(((UIViewController *)self).view);
    objc_setAssociatedObject(tableView, &kApolloDuoSubsChromeScrollAnchorKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSDictionary *scrollAnchor = ApolloDuoSubsChromeCaptureScrollAnchor(tableView);
    %orig;
    ApolloDuoSubsChromeRestoreScrollAnchorAfterEditing(tableView, scrollAnchor);
    ApolloDuoSubsChromeApply((UIViewController *)self);
}

%end

%end

%group ApolloDuoFiltersChrome

%hook _TtC6Apollo29SettingsFiltersViewController

- (void)viewDidLoad {
    %orig;
    ApolloDuoChromeApplyEditButton((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    ApolloDuoChromeApplyEditButton((UIViewController *)self);
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloDuoChromeApplyEditButton((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloDuoChromeApplyEditButton((UIViewController *)self);
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    %orig;
    ApolloDuoChromeApplyEditButton((UIViewController *)self);
}

%end

%end

%ctor {
    Class list = objc_getClass("_TtC6Apollo24RedditListViewController");
    if (!list) {
        ApolloLog(@"[DuoSubsChrome] RedditListViewController missing; chrome inactive");
        return;
    }
    %init(ApolloDuoSubsChromeList);
    %init(ApolloDuoFiltersChrome);
    ApolloLog(@"[DuoSubsChrome] hook installed (Duo title/Edit/+ only)");
}
