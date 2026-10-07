#import <UIKit/UIKit.h>
__BEGIN_DECLS
void ApolloPaneInstallSidebar(UITabBarController *tabs);
void ApolloPaneSidebarTabBadgeDidChange(UITabBarItem *item);
NSArray<UIViewController *> *ApolloPaneSidebarRootControllers(UITabBarController *tabs);
NSUInteger ApolloPaneSidebarSelectedIndex(UITabBarController *tabs);
BOOL ApolloPaneSidebarSelectIndex(UITabBarController *tabs, NSUInteger index);
void ApolloPaneSidebarSelectPosts(UITabBarController *tabs);
void ApolloPaneSidebarFirstAppearance(UITabBarController *tabs);
void ApolloPaneUpdateNavigationPresentation(UITabBarController *tabs);
void ApolloPaneScheduleNavigationPresentation(UITabBarController *tabs);
BOOL ApolloPaneCanShowNavigationSidebar(UITabBarController *tabs);
void ApolloPaneShowNavigationSidebar(UITabBarController *tabs);
BOOL ApolloPaneCanOpenDetailInNewWindow(UISplitViewController *pane);
void ApolloPaneOpenDetailInNewWindow(UISplitViewController *pane);
void ApolloPaneInstallLinkInteractions(UISplitViewController *pane);
BOOL ApolloPaneReceiveSceneActivity(UIWindowScene *scene, NSUserActivity *activity);
void ApolloPaneOpenPendingSceneLink(UIWindowScene *scene);
__END_DECLS
