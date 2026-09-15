#import <UIKit/UIKit.h>
__BEGIN_DECLS
void ApolloPaneInstallSidebar(UITabBarController *tabs);
void ApolloPaneSidebarFirstAppearance(UITabBarController *tabs);
BOOL ApolloPaneCanOpenDetailInNewWindow(UISplitViewController *pane);
void ApolloPaneOpenDetailInNewWindow(UISplitViewController *pane);
void ApolloPaneInstallLinkInteractions(UISplitViewController *pane);
BOOL ApolloPaneReceiveSceneActivity(UIWindowScene *scene, NSUserActivity *activity);
void ApolloPaneOpenPendingSceneLink(UIWindowScene *scene);
__END_DECLS
