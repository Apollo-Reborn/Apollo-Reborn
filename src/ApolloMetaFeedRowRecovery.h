// Included by the native RedditListViewController cell hook. Section zero is
// never remapped by FollowingSection. Account changes can remove Moderator
// Posts after UIKit cached the old row count but before it asks for the cell.
// Apollo builds a fresh feed array in cellForRow and traps on that stale row.
// Query the data source, not UITableView's cached numberOfRowsInSection:.
#import <objc/runtime.h>

static char kApolloMetaFeedRecoveryPendingKey;

static UITableViewCell *ApolloMetaFeedRecoverStaleRow(id<UITableViewDataSource> source,
                                                    UITableView *table,
                                                    NSIndexPath *path) {
    if (!table || !path || path.section != 0) return nil;
    NSInteger count = [source tableView:table numberOfRowsInSection:0];
    if (path.row >= 0 && path.row < count) return nil;

    // Do not call reloadData inside a cell/layout callback. Complete UIKit's
    // current pass with an inert cell, then let it request the new snapshot.
    // Coalesce repeated stale requests and never reload a reassigned table.
    if (![objc_getAssociatedObject(table, &kApolloMetaFeedRecoveryPendingKey) boolValue]) {
        objc_setAssociatedObject(table, &kApolloMetaFeedRecoveryPendingKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UITableView *weakTable = table;
        __weak id<UITableViewDataSource> weakSource = source;
        dispatch_async(dispatch_get_main_queue(), ^{
            UITableView *liveTable = weakTable;
            id<UITableViewDataSource> liveSource = weakSource;
            if (!liveTable) return;
            objc_setAssociatedObject(liveTable, &kApolloMetaFeedRecoveryPendingKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (liveSource && liveTable.dataSource == liveSource) [liveTable reloadData];
        });
        ApolloLog(@"[SubredditIndex] stale feed row %ld for current count %ld; scheduling refresh",
                  (long)path.row, (long)count);
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                reuseIdentifier:nil];
    cell.userInteractionEnabled = NO;
    cell.accessibilityElementsHidden = YES;
    return cell;
}
