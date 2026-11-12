#import <UIKit/UIKit.h>

__BEGIN_DECLS
void ApolloDuoInstallBackSwipe(UINavigationController *navigation);
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation);
/// Apollo's own interactive Back owns this pop and follows the finger, as on
/// a regular iPhone; the Duo pane drag stands down for it.
BOOL ApolloDuoPaneBackIsNative(UINavigationController *navigation);
/// Cancels every pane drag in flight (fold, rotation, hinge); each springs back.
void ApolloDuoCancelPaneDrags(void);
/// Swipe Tab Bar to Navigate while the tab shows columns. Send every state of
/// Apollo's tab bar pan; NO when the tab shows no columns (Apollo's handler runs).
BOOL ApolloDuoTabBarSwipePanned(UINavigationController *outer, UIPanGestureRecognizer *pan);
/// The visible tab bar's length; half of it completes a held release.
CGFloat ApolloDuoTabBarSwipeLength(UIGestureRecognizer *pan);
__END_DECLS
