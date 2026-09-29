#import <UIKit/UIKit.h>

__BEGIN_DECLS

/// YES when UIKit visibly presents Apollo's tab bar as a trailing side rail.
BOOL ApolloDuoRailHasVisibleSideBar(void);

/// Live Duo mode for the app window: Phone / Closed / Open.
int ApolloDuoCurrentMode(void);

/// Refresh the cached window mode without changing UIKit's tab bar.
void ApolloDuoRailSync(void);

/// Mark Apollo's Texture feed tables before a navigation push measures them.
void ApolloDuoRailPrepareFeedContent(UIViewController *controller);
CGFloat ApolloDuoRailFeedContentWidth(UITableView *table);

/// Refresh native tab layout after Apollo replaces or retints its glyphs.
void ApolloDuoRailRefreshGlyphs(void);

/// Keep the feed scroll indicator at the physical trailing screen edge.
void ApolloDuoRailAlignFeedScrollIndicator(UIScrollView *scrollView);

/// Pin the closed-display alphabet index beside the native trailing rail.
void ApolloDuoRailPinSectionIndex(UITableView *tableView);

/// YES on the compact Duo cover display. Regular iPhones return NO.
BOOL ApolloDuoCoverChromeIsActive(void);

/// Keep the comments jump button clear of Duo's system chrome and tab rail.
void ApolloDuoCoverAdjustJumpButton(UIViewController *comments);

__END_DECLS
