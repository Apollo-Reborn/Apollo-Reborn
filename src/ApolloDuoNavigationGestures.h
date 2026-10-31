#import <UIKit/UIKit.h>

__BEGIN_DECLS
void ApolloDuoInstallBackSwipe(UINavigationController *navigation);
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation);
/// The Duo pane Back pan (ApolloReborn.Duo.PaneBack). Feed galleries, which
/// make ancestor pans wait for their own drag, leave this one out.
BOOL ApolloDuoIsPaneBackPan(UIGestureRecognizer *gesture);
/// Any Duo pane gesture: the pane Back, its highlight guard, or the drag
/// claim. Row content that makes ancestor gestures wait for its own press
/// (the info-row loupe) leaves these out.
BOOL ApolloDuoIsPaneGesture(UIGestureRecognizer *gesture);
/// Apollo's own interactive Back pan on `navigation`, or nil.
UIGestureRecognizer *ApolloDuoNativeBackPan(UINavigationController *navigation);
/// Apollo's own interactive Back owns this pop; the Duo pane swipe stands down.
BOOL ApolloDuoNativeBackPanOwns(UINavigationController *navigation);
/// A pop Apollo's own Back pan drives is still running (dragging or settling).
BOOL ApolloDuoNativeBackInFlight(UINavigationController *navigation);
/// Called when Apollo's own Back pan is allowed to begin, and when a page shows.
void ApolloDuoNoteNativeBackBegan(UINavigationController *navigation);
void ApolloDuoNoteNativeBackShown(UINavigationController *navigation);
__END_DECLS
