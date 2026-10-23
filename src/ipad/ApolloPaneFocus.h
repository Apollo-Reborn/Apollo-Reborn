#import <UIKit/UIKit.h>
@class ApolloPaneSplitViewController;
__BEGIN_DECLS
void ApolloPaneInstallFocus(ApolloPaneSplitViewController *pane);
UIViewController *ApolloPaneFocusedController(ApolloPaneSplitViewController *pane);
void ApolloPaneFocusColumn(ApolloPaneSplitViewController *pane, BOOL detail, BOOL announce);
void ApolloPaneRefreshFocus(ApolloPaneSplitViewController *pane);
void ApolloPaneRestoreFocusPolicy(ApolloPaneSplitViewController *pane);
__END_DECLS
