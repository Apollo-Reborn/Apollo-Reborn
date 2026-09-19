#import <UIKit/UIKit.h>

// Logos compiles .xm as ObjC++. These helpers are defined in ApolloDuoRail.m
// (C linkage). extern "C" so the C++ callers see _ApolloDuoRailSync rather
// than a mangled name (same convention as ApolloDeviceGeometry.h).

__BEGIN_DECLS

/// YES while the open-Duo leading rail is installed and the stock tab bar
/// should stay hidden. Compact / ordinary iPhone keep the tab bar.
BOOL ApolloDuoRailIsActive(void);

/// YES while My Subreddits is the selected rail item (stock RedditList
/// root). Compact / cover never set this — the rail is hidden there.
BOOL ApolloDuoRailIsPickingSubreddits(void);
void ApolloDuoRailSetPickingSubreddits(BOOL picking);

/// Attach / hide / resize the rail on the main tab controller. Safe on
/// iOS 14 (missing tab-hide selectors are skipped).
void ApolloDuoRailSync(void);

/// Expand a letterboxed stock-nav column to the usable width right of
/// the leading rail, starting at ContentLeftInset (80) so feed chrome
/// and headers cannot sit under Subs. No midX clamp and no dual-VC hosting.
void ApolloDuoRailFillOpenContent(void);

/// Restore full-bleed frames / insets when the rail hides. Walks every
/// tab nav stack so a leftover leading strip cannot survive Compact
/// / portrait. Also restores preferredContentSize fill hacks.
void ApolloDuoRailClearOpenContent(void);

/// Inset RedditList / ASTableView content so it starts after the rail.
/// Favorite/sub rows get rail clearance only — no wide-row star cluster.
void ApolloDuoRailApplyListInsets(UIScrollView *scrollView);

/// Portrait organization on open Duo: one leading column. Favorite /
/// A–Z titles share the Home / Popular shortcut-row leading via a
/// single idempotent stack-frame nudge (no layoutMargins / constraint
/// writes — those re-entered layoutSubviews and hung 25f8a7b). Stars
/// hug the drawn text. Shortcut rows are left alone. No-op when the
/// rail is hidden or the title is already on the lead.
void ApolloDuoRailTightenSubredditRow(UITableViewCell *cell);

/// Always 0 while the rail is leading — stock A–Z stays on the list.
CGFloat ApolloDuoRailSectionIndexTrailingForTable(UITableView *tableView);

/// No-op pin while the rail is leading (stock A–Z). Kept so callers
/// do not need a cover/inner branch.
void ApolloDuoRailPinSectionIndex(UITableView *tableView);

/// YES on Compact + dual displays (cover/front). Never YES when the
/// open-inner rail is shown. Ordinary single-screen iPhone is NO.
BOOL ApolloDuoCoverChromeIsActive(void);

/// Nudge the comments jump FAB off Duo's cover pill. Safe for any
/// CommentsViewController-named class; no-ops when cover chrome is off.
void ApolloDuoCoverAdjustJumpButton(UIViewController *comments);

__END_DECLS
