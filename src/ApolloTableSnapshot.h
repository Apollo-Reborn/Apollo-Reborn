#ifndef APOLLO_TABLE_SNAPSHOT_H
#define APOLLO_TABLE_SNAPSHOT_H

// UIKit checks every UITableView batch against the section and row counts it
// cached at the table's last reload. That includes performBatchUpdates: and an
// empty beginUpdates/endUpdates height pass. If the data source changed since
// that reload without telling the table, the batch throws
// NSInternalInconsistencyException ("Invalid batch updates detected" or
// "invalid number of sections/rows") whatever it names. Use this before
// submitting a batch to a table whose model Apollo changes on its own.
// UITableView and Foundation must be declared by the caller (host tests
// provide a small table double).
static inline BOOL ApolloTableSnapshotIsStale(UITableView *table) {
    id<UITableViewDataSource> source = table.dataSource;
    if (!source) return NO;
    NSInteger sections = [source respondsToSelector:@selector(numberOfSectionsInTableView:)]
        ? [source numberOfSectionsInTableView:table] : 1;
    if (sections != table.numberOfSections) return YES;
    for (NSInteger section = 0; section < sections; section++) {
        if ([source tableView:table numberOfRowsInSection:section] != [table numberOfRowsInSection:section]) {
            return YES;
        }
    }
    return NO;
}

#endif
