#import <UIKit/UIKit.h>

// ApolloUnreadBadges: how the tweak's unread badges look (Interface → Unread
// Badges). Apollo and the Chat poller stay the only sources of WHETHER
// something is unread and how much; this module changes the presentation only.
//
// Two surfaces read it:
//   - The Inbox tab. Apollo sets that item's badgeValue to the unread count
//     (InboxViewController, FUN_10019b920: String(count), or nil once read),
//     and ApolloChatsFilter.xm's UITabBarItem -setBadgeValue: hook folds the
//     modern Chat count in. That hook (the only one on the item) runs its final
//     value through ApolloUnreadBadgeTabBarDisplayValue() and
//     ApolloUnreadBadgeStyleTabBarItem(), so the dot and the color ride UIKit's
//     own badge: its visibility, both Liquid Glass copies of a tab, Minimize,
//     icon-only tabs and the Duo rail keep working with no view of ours
//     beside it. The dot sits inside UIKit's blank badge, centered on the
//     icon's top-trailing corner, with the blank circle masked away.
//   - The Notifications / Chat switcher at the top of the Inbox
//     (ApolloInboxModeSwitcherView), which draws its own Chat pill and asks
//     for the colors and the compact flag here.
//
// With all three settings off (the default) nothing is written to UIKit, so
// the badges are exactly Apollo's.

extern NSString *const ApolloUnreadBadgeStyleDidChangeNotification;

__BEGIN_DECLS

// Settings setters: persist, update the s* global, and post
// ApolloUnreadBadgeStyleDidChangeNotification so every badge restyles now.
void ApolloUnreadBadgesSetCompactTabBar(BOOL enabled);
void ApolloUnreadBadgesSetCompactInbox(BOOL enabled);
void ApolloUnreadBadgesSetThemeColor(BOOL enabled);

// The badge fill: the theme accent (custom or stock theme) when Theme Color is
// on, else system red, Apollo's default. A dynamic color; resolve it against a
// view's traits before any CGColor use.
UIColor *ApolloUnreadBadgeFillColor(void);
// Text and dots drawn ON that fill: black or white, by the fill's luminance in
// each appearance (dynamic). White on the default red.
UIColor *ApolloUnreadBadgeTextColor(void);

// The Inbox tab's displayed value for `value` (Apollo's count, already
// combined with Chat): @"" when Compact Dot on Tab Bar is on and there is
// something unread (a blank UIKit badge, masked to a dot), else `value`.
NSString *ApolloUnreadBadgeTabBarDisplayValue(NSString *value);

// Writes the Inbox tab item's badge color and text color for the current
// style (which makes UIKit restyle the badge view, where Theme Color is
// applied), plus the spoken unread count while the dot hides it. Never touches
// an item it has not styled before while every option is off.
void ApolloUnreadBadgeStyleTabBarItem(UITabBarItem *item, NSString *countValue);

// The item's badge as a count: its badgeValue, or the count behind the dot
// while Compact Dot shows one. For mirrors that can't draw a dot (the iPad
// pane sidebar's UITab rows), which would otherwise read @"" as no badge.
NSString *ApolloUnreadBadgeCountValue(UITabBarItem *item);

__END_DECLS
