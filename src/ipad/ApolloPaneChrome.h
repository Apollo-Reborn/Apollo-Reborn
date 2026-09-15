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
__END_DECLS
