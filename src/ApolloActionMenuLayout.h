// ApolloActionMenuLayout — the model behind Settings → Interface → Action Menus:
// which of Apollo's "•••" menus can be customised, the catalogue of items each
// one can show, and the per-menu order + hidden set the user saved.
//
// A MENU CONTEXT is one of Apollo's "•••" sheets, identified by where it was
// opened from (the tap entry point arms it — see ApolloActionMenuArmContext /
// the hooks in ApolloActionMenu.xm), never by its contents: the same context
// shows different rows for a moderator, for your own post, for a subreddit you
// left, and so on.
//
// An ITEM is one row the user can move or hide. Apollo's native rows are
// matched by their Action KIND (ApolloNativeActionMetadata.h); an item groups
// the state variants of one row (Save/Unsave, Subscribe/Unsubscribe, …) so the
// user only ever sees one entry. Apollo Reborn's own rows (Keep in Floating
// Tab, Show Deleted Comments, Gallery View) are items too, keyed by their
// ApolloActionMenuSpec identifier.
//
// Storage is one dictionary in standardUserDefaults (UDKeyActionMenuLayouts):
//   { "<context>": { "order": [itemID…], "hidden": [itemID…] } }
// A context with no entry is untouched: Apollo's own order, nothing hidden,
// and the owner (ApolloActionMenu.xm) never mutates that sheet at all. Items
// added to the catalogue in later releases append after the saved order in
// their catalogue position, visible, so an old layout never drops a new row.
// A locked item (ApolloActionMenuItem.locked) always heads the order and is
// never hidden, whatever a stored layout says.
//
// Foundation/UIKit only (no Logos) so the settings screen can compile it.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: the model is a plain .m consumed by the ObjC++ Logos owner.
__BEGIN_DECLS

typedef NSString *ApolloActionMenuContext NS_TYPED_ENUM;

// The ••• in a subreddit / Home / Popular / All / multireddit feed's nav bar.
extern ApolloActionMenuContext const ApolloActionMenuContextFeed;
// A post's ••• on a feed cell (also the post header's media ••• in comments).
extern ApolloActionMenuContext const ApolloActionMenuContextPost;
// The nav-bar ••• while reading a post's comments.
extern ApolloActionMenuContext const ApolloActionMenuContextPostDetail;
// A comment's •••.
extern ApolloActionMenuContext const ApolloActionMenuContextComment;
// A moderator's menus (Apollo flags these sheets isShowingOnlyModeratorActions):
// the shield at the top of a subreddit you moderate; a post's — its cell's
// shield, the Moderator row of its ••• menus and the shield at the top of its
// comments; a comment's — its shield and the Moderator row of its •••.
extern ApolloActionMenuContext const ApolloActionMenuContextModeratorSubreddit;
extern ApolloActionMenuContext const ApolloActionMenuContextModeratorPost;
extern ApolloActionMenuContext const ApolloActionMenuContextModeratorComment;

// Presentation order for pickers.
NSArray<ApolloActionMenuContext> *ApolloActionMenuAllContexts(void);
// Short picker title ("Feed", "Post", "Post (Comments)", "Comment").
NSString *ApolloActionMenuContextTitle(ApolloActionMenuContext context);
// One sentence saying where that menu is opened from.
NSString *ApolloActionMenuContextDescription(ApolloActionMenuContext context);
// Recognises stored ids (defensive: an unknown string in defaults is ignored).
BOOL ApolloActionMenuContextIsValid(NSString *_Nullable context);
// One of the moderator menus (drawn in the moderator tint, no locked rows).
BOOL ApolloActionMenuContextIsModerator(ApolloActionMenuContext _Nullable context);
// The moderator menu that `context`'s Moderator row opens: the post's for
// post and post-detail, the comment's for comment, nil for the rest.
ApolloActionMenuContext _Nullable ApolloActionMenuModeratorContextFollowing(ApolloActionMenuContext _Nullable context);

@interface ApolloActionMenuItem : NSObject
@property (nonatomic, copy, readonly) NSString *itemID;
@property (nonatomic, copy, readonly) NSString *title;
// Apollo's own option-* asset (native rows) or an SF Symbol (tweak rows).
@property (nonatomic, copy, readonly, nullable) NSString *assetName;
@property (nonatomic, copy, readonly, nullable) NSString *symbolName;
// Every Action kind that renders as this item (state variants included).
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *kinds;
// ApolloActionMenuSpec.identifier for an Apollo Reborn row; nil for native.
@property (nonatomic, copy, readonly, nullable) NSString *specIdentifier;
@property (nonatomic, readonly) BOOL isTweakRow;
// YES for rows Apollo shows in that menu as a matter of course; NO for rows
// it only adds sometimes (your own post's Edit/Delete, moderator tools, a
// tweak row whose feature is off by default). The preview leans on this until
// the menu has been opened once (see ApolloActionMenuPreviewItems).
@property (nonatomic, readonly) BOOL usuallyShown;
// YES for a row that always keeps Apollo's place at the head of the menu and
// can be neither moved nor hidden: the feed's Submit Post row, which Liquid
// Glass draws as the quick new-post buttons (Photo/Link/Text/Poll) while the
// Polls feature is on. Never listed for editing; a saved order always starts
// with the locked rows and the hidden set never contains one.
@property (nonatomic, readonly) BOOL locked;
// 24pt template icon for settings/preview use (nil if the asset is missing).
- (nullable UIImage *)icon;
@end

// Every supported item for this context; usual rows followed by conditional rows.
NSArray<ApolloActionMenuItem *> *ApolloActionMenuCatalog(ApolloActionMenuContext context);
ApolloActionMenuItem *_Nullable ApolloActionMenuCatalogItem(ApolloActionMenuContext context, NSString *itemID);
// The item a native row of `kind` belongs to in this context, or nil when the
// context doesn't catalogue that kind (such rows are left alone: shown, after
// every catalogued item, in Apollo's own relative order).
NSString *_Nullable ApolloActionMenuItemIDForKind(ApolloActionMenuContext context, NSUInteger kind);
// The item id a tweak row (ApolloActionMenuSpec) is stored under.
NSString *ApolloActionMenuItemIDForSpec(NSString *specIdentifier);

#pragma mark - Saved layout

// The saved order, with any catalogue item missing from it (a row added after
// the layout was saved, or never saved) appended in catalogue order. Never
// contains ids outside the catalogue.
NSArray<NSString *> *ApolloActionMenuResolvedOrder(ApolloActionMenuContext context);
NSSet<NSString *> *ApolloActionMenuHiddenItemIDs(ApolloActionMenuContext context);
BOOL ApolloActionMenuIsItemHidden(ApolloActionMenuContext context, NSString *itemID);
// Position of an item in the resolved order, NSNotFound when it isn't one.
NSUInteger ApolloActionMenuRankForItemID(ApolloActionMenuContext context, NSString *itemID);
// YES while any item is hidden or an explicit drag order has been saved.
// Visibility changes never opt a menu into sorting. Only an explicit drag does.
BOOL ApolloActionMenuHasCustomOrder(ApolloActionMenuContext context);
BOOL ApolloActionMenuContextIsCustomized(ApolloActionMenuContext context);
NSUInteger ApolloActionMenuCustomizedContextCount(void);

void ApolloActionMenuSetOrder(ApolloActionMenuContext context, NSArray<NSString *> *order);
void ApolloActionMenuSetItemHidden(ApolloActionMenuContext context, NSString *itemID, BOOL hidden);
void ApolloActionMenuResetContext(ApolloActionMenuContext context);

#pragma mark - What the menu actually offered

// The owner records, every time a customisable sheet is built, which
// catalogue items Apollo (and the registered tweak rows) actually put in it —
// before the saved layout is applied, so hidden rows are included. The
// settings preview then shows exactly the rows this user's menu has, instead
// of every row the catalogue knows.
void ApolloActionMenuRecordPresentedItemIDs(ApolloActionMenuContext context, NSArray<NSString *> *itemIDs);
NSArray<NSString *> *_Nullable ApolloActionMenuLastPresentedItemIDs(ApolloActionMenuContext context);
// The rows the preview should draw: the saved order with hidden items removed
// — every remaining catalogue item, so a row the user just moved or switched
// on is always where they put it. Whether the menu actually offered a row
// the last time it opened (or usually does, before it was ever opened) is
// ApolloActionMenuItemWasOffered; the preview fades the rows it doesn't.
NSArray<ApolloActionMenuItem *> *ApolloActionMenuPreviewItems(ApolloActionMenuContext context);
BOOL ApolloActionMenuItemWasOffered(ApolloActionMenuContext context, NSString *itemID);

#pragma mark - Runtime: which context a sheet belongs to

// Called by the ••• tap entry points before Apollo builds/presents a sheet.
// The presentation owner attaches it to that exact ActionController before
// UIKit defers legacy layout. Tap hooks clear any unclaimed context in @finally.
void ApolloActionMenuArmContext(ApolloActionMenuContext context);
// Clear an unclaimed tap when its handler returns (including exceptions).
void ApolloActionMenuDisarmContext(void);
// The armed context if it is still fresh, consuming it; nil otherwise.
ApolloActionMenuContext _Nullable ApolloActionMenuTakeArmedContext(void);

__END_DECLS

NS_ASSUME_NONNULL_END
