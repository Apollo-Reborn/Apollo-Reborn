#import <UIKit/UIKit.h>

// The native profile owns its data and actions; the landscape dashboard only
// changes their presentation. Removing the dashboard restores the normal table.
__BEGIN_DECLS
UIView *ApolloDuoAccountProfileHeader(UIViewController *profile);
CGFloat ApolloDuoAccountHeaderHeight(UIView *header, CGFloat width);
void ApolloDuoAccountRestoreProfile(UIViewController *profile);
BOOL ApolloDuoAccountProfileIsHosted(UIViewController *profile);
UIMenu *ApolloProfileMoreMenuForController(UIViewController *profile);

__END_DECLS

@interface ApolloDuoAccountShortcuts : UIViewController
@property(nonatomic, weak) UITableView *profileTable;
- (void)refreshProfileMenu;
@property(nonatomic, copy) void (^selectShortcut)(NSString *title);
@end
__BEGIN_DECLS
void ApolloDuoAccountConfigureOverviewTable(UITableView *table, BOOL hosted);
BOOL ApolloDuoAccountIsOverviewTable(UITableView *table);
BOOL ApolloDuoAccountHidesProfileRow(UITableView *table, NSIndexPath *path);
// Open portrait Account tab: two-column shortcut group. Height is -1 when the
// row is not affected.
CGFloat ApolloDuoAccountGridRowHeight(UITableView *table, NSIndexPath *path);
void ApolloDuoAccountGridDisplayCell(UITableView *table, UITableViewCell *cell, NSIndexPath *path);
void ApolloDuoAccountGridRefresh(UITableView *table);
// Performs a profile shortcut exactly as its native row would.
void ApolloDuoAccountOpenShortcut(UIViewController *profile, NSString *title);

__END_DECLS
