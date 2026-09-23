#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#define ApolloLog(...) do {} while (0)

@class UITableView;
@protocol UITableViewDataSource <NSObject>
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section;
@end
@interface UITableView : NSObject
@property (nonatomic, weak) id<UITableViewDataSource> dataSource;
@property (nonatomic) NSUInteger reloads;
@property (nonatomic) NSInteger cachedRows;
- (void)reloadData;
@end
@implementation UITableView
- (void)reloadData {
    self.reloads++;
    self.cachedRows = [self.dataSource tableView:self numberOfRowsInSection:0];
}
@end
enum { UITableViewCellStyleDefault = 0 };
@interface UITableViewCell : NSObject
@property (nonatomic) BOOL userInteractionEnabled;
@property (nonatomic) BOOL accessibilityElementsHidden;
- (instancetype)initWithStyle:(NSInteger)style reuseIdentifier:(NSString *)identifier;
@end
@implementation UITableViewCell
- (instancetype)initWithStyle:(NSInteger)style reuseIdentifier:(NSString *)identifier {
    self = [super init];
    if (self) self.userInteractionEnabled = YES;
    return self;
}
@end
@interface NSIndexPath (TableTest)
@property (nonatomic, readonly) NSInteger section;
@property (nonatomic, readonly) NSInteger row;
@end
@implementation NSIndexPath (TableTest)
- (NSInteger)section { return [self indexAtPosition:0]; }
- (NSInteger)row { return [self indexAtPosition:1]; }
@end
#import "ApolloMetaFeedRowRecovery.h"

@interface FeedSource : NSObject <UITableViewDataSource>
@property (nonatomic, copy) NSArray *feeds;
@end
@implementation FeedSource
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return self.feeds.count;
}
@end
static NSIndexPath *Path(NSUInteger section, NSUInteger row) {
    NSUInteger indexes[] = {section, row};
    return [NSIndexPath indexPathWithIndexes:indexes length:2];
}
static void Drain(void) {
    __block BOOL done = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
    while (!done) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}
static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        FeedSource *source = [FeedSource new];
        source.feeds = @[@"home", @"popular", @"all", @"moderator"];
        UITableView *table = [UITableView new];
        table.dataSource = source;
        [table reloadData];
        Check(!ApolloMetaFeedRecoverStaleRow(source, table, Path(0, 3)), @"valid moderator passes through");
        source.feeds = @[@"home", @"popular", @"all"];
        Check(table.cachedRows == 4, @"account switch leaves UIKit's old snapshot");
        BOOL baselineFailed = NO;
        @try { (void)source.feeds[3]; } @catch (NSException *exception) { baselineFailed = YES; }
        Check(baselineFailed, @"unprotected stale request exceeds new account's array");
        UITableViewCell *cell = ApolloMetaFeedRecoverStaleRow(source, table, Path(0, 3));
        Check(cell != nil, @"stale moderator intercepted before native call");
        Check(!cell.userInteractionEnabled && cell.accessibilityElementsHidden, @"temporary cell inert");
        Check(table.reloads == 1, @"no synchronous reload inside layout");
        Check(ApolloMetaFeedRecoverStaleRow(source, table, Path(0, 3)) != nil, @"repeated stale callback safe");
        Drain();
        Check(table.reloads == 2 && table.cachedRows == 3, @"one deferred refresh reconciles account");
        Check(!ApolloMetaFeedRecoverStaleRow(source, table, Path(0, 2)), @"remaining feeds still native");
        Check(!ApolloMetaFeedRecoverStaleRow(source, table, Path(1, 99)), @"other sections untouched");
        Check(!ApolloMetaFeedRecoverStaleRow(source, nil, Path(0, 3)), @"nil table passes through");
        Check(!ApolloMetaFeedRecoverStaleRow(source, table, nil), @"nil path passes through");
        ApolloMetaFeedRecoverStaleRow(source, table, Path(0, 3));
        FeedSource *replacement = [FeedSource new];
        replacement.feeds = @[@"home"];
        table.dataSource = replacement;
        Drain();
        Check(table.reloads == 2, @"reassigned table not reloaded by old source");
        table.dataSource = source;
        ApolloMetaFeedRecoverStaleRow(source, table, Path(0, 3));
        source.feeds = @[@"home", @"popular", @"all", @"moderator"];
        Drain();
        Check(table.cachedRows == 4, @"rapid switch back refreshes latest account");
        Check(!ApolloMetaFeedRecoverStaleRow(source, table, Path(0, 3)), @"restored moderator passes through");
        NSLog(@"PASS: %lu meta-feed recovery checks", (unsigned long)checks);
    }
}
