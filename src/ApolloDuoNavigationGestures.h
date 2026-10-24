#import <UIKit/UIKit.h>

__BEGIN_DECLS
void ApolloDuoInstallBackSwipe(UINavigationController *navigation);
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation);
// YES when the edge-strip Back swipe claimed the current touch (see .m).
BOOL ApolloDuoBackSwipeClaimedCurrentTouch(UINavigationController *navigation);
__END_DECLS
