#import <UIKit/UIKit.h>
__BEGIN_DECLS
BOOL ApolloPaneUsesUnifiedChrome(UIView *view);
CGFloat ApolloPaneContextBottomInView(UIView *view);
// Header content follows the native sidebar's unobscured column, while its
// table-owned wrapper keeps the table's full width.
CGRect ApolloPaneHeaderContentRect(UITableView *table, UIViewController *controller, CGFloat width);
// Refit existing identity content and its independent table background after
// UIKit settles sidebar/column geometry. Does not reload data or images.
void ApolloPaneRefreshIdentityHeaderGeometry(UIViewController *pane);
dispatch_block_t ApolloPaneCaptureIdentityHeaderScrollAnchors(UIViewController *pane);
BOOL ApolloPaneRefitSubredditHeaderGeometry(UIViewController *controller);
BOOL ApolloPaneRefitProfileHeaderGeometry(UIViewController *controller);
// A continuous, opaque identity plane prevents feed rows leaking above the
// toolbar. Optional hero artwork hands off as the large identity collapses.
void ApolloPaneUpdateHeaderBackdrop(UIViewController *controller, UIImage *artwork, CGFloat progress);
void ApolloPaneHideHeaderBackdrop(UIViewController *controller);
void ApolloPaneRefreshHeaderBackdrop(UIViewController *controller);
BOOL ApolloPanePrefersCompactFeed(UIViewController *controller);
void ApolloPaneSetComfortableFeed(UIViewController *controller, BOOL comfortable);
void ApolloPaneInstallChromeForController(UIViewController *controller);
void ApolloPaneApplySearchPlacement(UIViewController *controller);
BOOL ApolloPanePrepareCommentsFind(UIViewController *controller);
BOOL ApolloPanePresentCommentsFind(UIViewController *controller);
// Scoped to the native nav-bar More entry points, never a cell/moderator menu.
UIViewController *ApolloPaneSetMenuOwner(UIViewController *controller);
void ApolloPaneCaptureMenuOwner(id actionController);
void ApolloPaneRegisterViewOptions(void);
__END_DECLS
