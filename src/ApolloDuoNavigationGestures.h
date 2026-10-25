#import <UIKit/UIKit.h>

__BEGIN_DECLS
void ApolloDuoInstallBackSwipe(UINavigationController *navigation);
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation);
/// Apollo's own interactive Back pan on `navigation`, or nil.
UIGestureRecognizer *ApolloDuoNativeBackPan(UINavigationController *navigation);
/// Apollo's own interactive Back owns this pop; the Duo pane swipe stands down.
BOOL ApolloDuoNativeBackPanOwns(UINavigationController *navigation);
__END_DECLS
