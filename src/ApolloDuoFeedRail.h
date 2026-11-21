#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Duo, flat, landscape: the leading column beside the Posts feed. A
// full-height glass panel, inset like the subreddit drawer, on a plain
// backdrop that ends in a divider where the feed begins: the feed shortcuts
// the subreddit list shows (Home, Popular, All, Moderator, in its icon style)
// and Subreddits, which opens the drawer beside it, at the top, then the
// account's favorite subreddits and followed users. The host sizes the view to
// the column's reserved width and shows it.
@interface ApolloDuoFeedRail : UIView
/// Width the feed reserves for the column: the panel, its 12pt inset from
/// the display edge and a 12pt gap before the feed.
@property(class, nonatomic, readonly) CGFloat reservedWidth;
/// 0 Home, 1 Popular, 2 All, 3 Moderator; -1 when the feed is none of them.
@property(nonatomic) NSInteger selectedFeed;
/// Whether Moderator is among the shortcuts: Settings shows it and the
/// subreddit list has its row (the account moderates). Set before
/// -reloadShortcuts.
@property(nonatomic) BOOL showsModerator;
/// The subreddit the feed shows, matched against the favorites; nil for none.
@property(nonatomic, copy, nullable) NSString *selectedSubreddit;
@property(nonatomic) BOOL subredditsSelected;
@property(nonatomic, copy, nullable) void (^selectFeed)(NSInteger feed);
@property(nonatomic, copy, nullable) void (^selectSubreddit)(NSString *subreddit);
@property(nonatomic, copy, nullable) void (^toggleSubreddits)(void);
/// Rebuilds the buttons when the shortcuts (Popular and All can be hidden in
/// Settings) or the favorites changed.
- (void)reloadShortcuts;
- (void)refreshColors;
@end

NS_ASSUME_NONNULL_END
