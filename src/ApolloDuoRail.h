#import <UIKit/UIKit.h>

// Logos compiles .xm as ObjC++. These helpers are defined in ApolloDuoRail.m
// (C linkage). extern "C" so the C++ callers see _ApolloDuoRailSync rather
// than a mangled name (same convention as ApolloDeviceGeometry.h).

__BEGIN_DECLS

/// YES while the open-Duo trailing rail is installed and the stock tab bar
/// should stay hidden. Compact / ordinary iPhone keep the tab bar.
BOOL ApolloDuoRailIsActive(void);

/// YES while My Subreddits is the selected rail item (stock RedditList
/// root). Compact / cover never set this — the rail is hidden there.
BOOL ApolloDuoRailIsPickingSubreddits(void);
void ApolloDuoRailSetPickingSubreddits(BOOL picking);

/// Attach / hide / resize the rail on the main tab controller. Safe on
/// iOS 14 (missing tab-hide selectors are skipped).
void ApolloDuoRailSync(void);

/// How far the A–Z index must sit in from table.bounds.maxX while the
/// rail is shown (rail + gutter + window safe.right). 0 when hidden.
CGFloat ApolloDuoRailSectionIndexTrailingForTable(UITableView *tableView);

/// Keep UITableView's native A–Z index on the list, left of the rail —
/// never in the far-right status gutter beside the time/Wi-Fi pill.
void ApolloDuoRailPinSectionIndex(UITableView *tableView);

__END_DECLS
