#import <UIKit/UIKit.h>

// Live-geometry helpers for Dynamic Island / Pixel Pals chrome.
// Prefer the window's UIWindowScene screen over UIScreen.mainScreen so a
// foldable or multi-display scene is not measured against the wrong panel.

__BEGIN_DECLS

/// Screen that owns `window`, else the foreground-active scene's screen,
/// else `UIScreen.mainScreen`.
UIScreen *ApolloDeviceScreenForWindow(UIWindow *window);

/// Foreground-active `UIWindowScene.screen`, else `UIScreen.mainScreen`.
UIScreen *ApolloDevicePreferredScreen(void);

/// Physical Dynamic Island cutout in the screen's logical points, via
/// `-[UIScreen _exclusionArea]` — the same source UIKit's status bar uses.
/// Returns NO on notch / home-button hardware, or if the private API is
/// missing or the rect fails a pill-shaped sanity check.
BOOL ApolloDynamicIslandRectForScreen(UIScreen *screen, CGRect *outRect);
BOOL ApolloDynamicIslandRectForWindow(UIWindow *window, CGRect *outRect);

/// Vertical shift to add to Apollo's hardcoded 14 Pro DI element positions
/// so they line up with this window's actual island. 0 when no correction
/// applies (baseline 14 Pro, no island, or Display Zoom fallback bail).
CGFloat ApolloPixelPalShiftForWindow(UIWindow *window);

/// YES when Pixel Pals / FauxCutOutView should stay visible in `window`.
/// Missing `_exclusionArea` (pre-iOS 16) leaves Apollo's own decision
/// alone. When the API exists, chrome follows a live island on *this*
/// screen so an inner Duo panel without a cutout does not keep a 14 Pro pill.
BOOL ApolloShouldShowDynamicIslandChromeInWindow(UIWindow *window);

__END_DECLS
