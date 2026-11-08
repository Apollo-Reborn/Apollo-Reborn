#import <UIKit/UIKit.h>

__BEGIN_DECLS
void ApolloDuoInstallBackSwipe(UINavigationController *navigation);
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation);
/// Apollo's own interactive Back owns this pop and follows the finger, as on
/// a regular iPhone; the Duo pane drag stands down for it.
BOOL ApolloDuoPaneBackIsNative(UINavigationController *navigation);
/// Cancels every pane drag in flight (fold, rotation, hinge); each springs back.
void ApolloDuoCancelPaneDrags(void);
__END_DECLS
