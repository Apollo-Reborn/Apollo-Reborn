#import <UIKit/UIKit.h>
__BEGIN_DECLS
BOOL ApolloPaneUsesUnifiedChrome(UIView *view);
CGFloat ApolloPaneContextBottomInView(UIView *view);
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
