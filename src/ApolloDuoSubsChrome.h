#import <UIKit/UIKit.h>

// Duo-only Subreddits nav chrome: centered title, Edit beside the
// Closed right rail, and floating + wired to Apollo's tappedAddBarButtonItem:. Completes the
// existing rail / Liquid Glass title path — does not retile the list,
// move stars, or pin the A–Z overlay.

__BEGIN_DECLS

/// Install / refresh / restore RedditList chrome for the current Duo
/// mode. No-op on regular iPhone (Phone mode) and on non-RedditList
/// controllers. Safe from viewDidLayoutSubviews: frame writes are
/// guarded and never re-toggle constraints.
void ApolloDuoSubsChromeApply(UIViewController *controller);
void ApolloDuoSubsChromeRemoveFloatingEdit(UIViewController *controller);

/// Put a controller's native editing action in the Duo navigation rail using
/// the same glass pencil / blue Done treatment as the subreddit list.
void ApolloDuoChromeApplyEditButton(UIViewController *controller);

/// YES when the visible screen is Apollo's Subreddits list.
BOOL ApolloDuoSubsChromeControllerIsRedditList(UIViewController *controller);

__END_DECLS
