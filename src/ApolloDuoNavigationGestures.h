#import <UIKit/UIKit.h>

__BEGIN_DECLS
void ApolloDuoInstallBackSwipe(UINavigationController *navigation);
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation);
/// YES while the pane swipe can go Back here, so Apollo's own edge pan steps aside.
BOOL ApolloDuoBackSwipeOwnsBack(UINavigationController *navigation);
__END_DECLS
