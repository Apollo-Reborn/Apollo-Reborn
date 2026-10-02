#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#define ApolloLog(...) do {} while (0)

typedef NSInteger UITableViewRowAnimation;

@interface NSIndexPath (TableCoordinates)
@property (nonatomic, readonly) NSInteger row;
@property (nonatomic, readonly) NSInteger section;
+ (instancetype)indexPathForRow:(NSInteger)row inSection:(NSInteger)section;
@end
@implementation NSIndexPath (TableCoordinates)
- (NSInteger)row { return (NSInteger)[self indexAtPosition:1]; }
- (NSInteger)section { return (NSInteger)[self indexAtPosition:0]; }
+ (instancetype)indexPathForRow:(NSInteger)row inSection:(NSInteger)section {
    NSUInteger indexes[] = { (NSUInteger)section, (NSUInteger)row };
    return [self indexPathWithIndexes:indexes length:2];
}
@end

@class UITableView;
@protocol UITableViewDataSource <NSObject>
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section;
@optional
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView;
@end

// The list controller: its row count is whatever the model holds right now.
@interface UIViewController : NSObject <UITableViewDataSource>
@property (nonatomic) NSUInteger mapInvalidations;
@end

// This double enforces UIKit's row-count invariant, rather than implementing
// the production deferral. The real Logos hooks below decide what reaches it.
@interface UITableView : NSObject
@property (nonatomic, strong) UIViewController *dataSource;
@property (nonatomic) NSInteger modelRows;
@property (nonatomic) NSInteger presentedRows;
@property (nonatomic) NSInteger pendingDelta;
@property (nonatomic) NSUInteger batchDepth;
@property (nonatomic) NSUInteger begins;
@property (nonatomic) NSUInteger ends;
@property (nonatomic) NSUInteger batches;
@property (nonatomic) NSUInteger inserts;
@property (nonatomic) NSUInteger deletes;
@property (nonatomic) NSUInteger rowReloads;
@property (nonatomic) NSUInteger reloads;
- (NSInteger)numberOfSections;
- (NSInteger)numberOfRowsInSection:(NSInteger)section;
- (void)reloadData;
- (void)beginUpdates;
- (void)endUpdates;
- (void)performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL))completion;
- (void)insertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths withRowAnimation:(UITableViewRowAnimation)animation;
- (void)deleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths withRowAnimation:(UITableViewRowAnimation)animation;
- (void)reloadRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths withRowAnimation:(UITableViewRowAnimation)animation;
@end

@implementation UIViewController
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return tableView.modelRows;
}
@end

@implementation UITableView
// UIKit's cached layout: what it presented at the last reload or batch.
- (NSInteger)numberOfSections {
    return 1;
}
- (NSInteger)numberOfRowsInSection:(__unused NSInteger)section {
    return self.presentedRows;
}
- (void)reloadData {
    self.reloads++;
    self.presentedRows = self.modelRows;
}
- (void)beginUpdates {
    self.begins++;
    self.batchDepth++;
}
- (void)endUpdates {
    self.ends++;
    if (self.batchDepth == 0) {
        [NSException raise:NSInternalInconsistencyException format:@"Unbalanced table batch"];
    }
    self.batchDepth--;
    if (self.batchDepth > 0) return;
    if (self.presentedRows + self.pendingDelta != self.modelRows) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Before %ld + changes %ld != after %ld", self.presentedRows,
                           self.pendingDelta, self.modelRows];
    }
    self.presentedRows = self.modelRows;
    self.pendingDelta = 0;
}
// UIKit checks the counts after the block against the ones it presented before.
- (void)performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL))completion {
    self.batches++;
    self.batchDepth++;
    if (updates) updates();
    self.batchDepth--;
    if (self.presentedRows + self.pendingDelta != self.modelRows) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Invalid batch updates: before %ld + changes %ld != after %ld",
                           self.presentedRows, self.pendingDelta, self.modelRows];
    }
    self.presentedRows = self.modelRows;
    self.pendingDelta = 0;
    if (completion) completion(YES);
}
- (void)insertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths withRowAnimation:(__unused UITableViewRowAnimation)animation {
    self.inserts++;
    self.pendingDelta += (NSInteger)paths.count;
}
- (void)deleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)paths withRowAnimation:(__unused UITableViewRowAnimation)animation {
    self.deletes++;
    self.pendingDelta -= (NSInteger)paths.count;
}
- (void)reloadRowsAtIndexPaths:(__unused NSArray<NSIndexPath *> *)paths withRowAnimation:(__unused UITableViewRowAnimation)animation {
    self.rowReloads++;
}
@end

// The captured crash took the normal-layout path, with no active Following
// map. The table identity and map invalidation remain observable in this test.
typedef NSObject ApolloFollowingMap;
static NSInteger sApolloFollowingWindowDepth;
static UITableView *sApolloFollowingWindowTable;
static NSString *sApolloFollowingWindowTappedName;
static NSArray<NSString *> *sApolloFollowingWindowFavorites;
static const NSInteger kApolloNativeSectionFavorites = 1;
static BOOL ApolloFollowingTableIsList(UITableView *table) { return table.dataSource != nil; }
static void ApolloFollowingInvalidateMap(UIViewController *controller) { controller.mapInvalidations++; }
static ApolloFollowingMap *ApolloFollowingPresentedMapForTable(__unused UITableView *table) { return nil; }
static ApolloFollowingMap *ApolloFollowingActiveMapForTable(__unused UITableView *table) { return nil; }
static NSIndexPath *ApolloFollowingVisiblePathForNative(__unused ApolloFollowingMap *map, NSIndexPath *path) { return path; }
static BOOL ApolloFollowingCallerIsApolloBinary(__unused void *address) { return NO; }
// The list-editing removal spring (#1174) is idle throughout these checks.
static char kApolloRemovalTransition;
static UITableView *sApolloVisibleRemovalTable;
static BOOL ApolloFollowingApplyRemovalAnimation(__unused UITableView *table) { return NO; }

#include "ApolloMultiredditExpansion.h"

// INCLUDE_PRODUCTION_TABLE_HOOKS

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}
static UITableView *Table(NSInteger rows) {
    UITableView *table = [UITableView new];
    table.dataSource = [UIViewController new];
    table.modelRows = rows;
    table.presentedRows = rows;
    return table;
}
static NSArray<NSIndexPath *> *ChildPaths(NSUInteger count) {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [paths addObject:[NSIndexPath indexPathForRow:(NSInteger)i + 1 inSection:2]];
    }
    return paths;
}

// Apollo's favorite star (#1335): the FavoriteSubreddits change and its one
// row registration both happen INSIDE performBatchUpdates:.
static NSUInteger favoriteCompletions;
static BOOL favoriteFinished;
static void NativeFavoriteToggle(UITableView *table, BOOL add) {
    [table performBatchUpdates:^{
        table.modelRows += add ? 1 : -1;
        NSArray<NSIndexPath *> *row = @[[NSIndexPath indexPathForRow:0 inSection:1]];
        if (add) [table insertRowsAtIndexPaths:row withRowAnimation:0];
        else [table deleteRowsAtIndexPaths:row withRowAnimation:0];
    } completion:^(BOOL finished) {
        favoriteCompletions++;
        favoriteFinished = finished;
    }];
}
static void DrainMainQueue(void) {
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    while (!drained) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}

// Native Apollo's shared name key can expand both parents, while the tapped
// model provides only its own two child paths to the table animation.
static void NativeToggle(UITableView *table, NSInteger resultingRows,
                         NSUInteger tappedChildren, BOOL expand) {
    [table beginUpdates];
    table.modelRows = resultingRows;
    if (expand) [table insertRowsAtIndexPaths:ChildPaths(tappedChildren) withRowAnimation:0];
    else [table deleteRowsAtIndexPaths:ChildPaths(tappedChildren) withRowAnimation:0];
    [table endUpdates];
}

int main(void) {
    @autoreleasepool {
        UITableView *broken = Table(2);
        BOOL caught = NO;
        @try { NativeToggle(broken, 7, 2, YES); }
        @catch (NSException *exception) { caught = [exception.name isEqualToString:NSInternalInconsistencyException]; }
        Check(caught, @"negative control: duplicate-name expansion fails the native row-count invariant");

        UITableView *duplicate = Table(2);
        __block NSUInteger originals = 0;
        ApolloPerformMultiredditExpansion(duplicate, ^{
            originals++;
            NativeToggle(duplicate, 7, 2, YES);
        });
        Check(originals == 1 && duplicate.modelRows == 7, @"original state mutation still runs exactly once");
        Check(duplicate.presentedRows == 7 && duplicate.reloads == 1, @"duplicate-name expansion displays every resulting child");
        Check(duplicate.begins == 0 && duplicate.ends == 0 && duplicate.inserts == 0,
              @"no part of the invalid expansion batch reaches UIKit");
        Check(duplicate.dataSource.mapInvalidations == 1, @"final reload invalidates the Following map once");
        ApolloPerformMultiredditExpansion(duplicate, ^{ NativeToggle(duplicate, 2, 2, NO); });
        Check(duplicate.presentedRows == 2 && duplicate.reloads == 2 && duplicate.deletes == 0,
              @"shared-name collapse also reconciles every removed child");

        UITableView *ordinary = Table(1);
        ApolloPerformMultiredditExpansion(ordinary, ^{ NativeToggle(ordinary, 4, 3, YES); });
        Check(ordinary.presentedRows == 4 && ordinary.reloads == 1, @"ordinary multireddit expansion still works");
        ApolloPerformMultiredditExpansion(ordinary, ^{ originals++; });
        Check(originals == 2 && ordinary.reloads == 1, @"a no-op handler is preserved without an unnecessary reload");

        // Cover each shipping hook independently, including a native reload
        // and a row refresh without a begin/end pair.
        NSArray<dispatch_block_t> *mutations = @[
            ^{ [ordinary reloadData]; },
            ^{ [ordinary beginUpdates]; },
            ^{ [ordinary endUpdates]; },
            ^{ [ordinary insertRowsAtIndexPaths:ChildPaths(1) withRowAnimation:0]; },
            ^{ [ordinary deleteRowsAtIndexPaths:ChildPaths(1) withRowAnimation:0]; },
            ^{ [ordinary reloadRowsAtIndexPaths:ChildPaths(1) withRowAnimation:0]; },
            ^{ [ordinary performBatchUpdates:nil completion:nil]; }
        ];
        for (dispatch_block_t mutation in mutations) {
            NSUInteger beforeReloads = ordinary.reloads;
            ApolloPerformMultiredditExpansion(ordinary, mutation);
            Check(ordinary.reloads == beforeReloads + 1, @"every deferred table API triggers one completed reload");
        }
        Check(ordinary.begins == 0 && ordinary.ends == 0 && ordinary.batches == 0 && ordinary.inserts == 0 &&
              ordinary.deletes == 0 && ordinary.rowReloads == 0,
              @"all seven production hooks defer their scoped native work");

        UITableView *other = Table(1);
        NSUInteger beforeReloads = ordinary.reloads;
        ApolloPerformMultiredditExpansion(ordinary, ^{
            NativeToggle(other, 3, 2, YES);
            [other reloadRowsAtIndexPaths:ChildPaths(1) withRowAnimation:0];
            [ordinary reloadData];
            [ordinary reloadData];
            [ordinary reloadRowsAtIndexPaths:ChildPaths(1) withRowAnimation:0];
        });
        Check(other.begins == 1 && other.ends == 1 && other.inserts == 1 && other.rowReloads == 1 && other.reloads == 0,
              @"another table retains ordinary batch and row refresh behavior");
        Check(ordinary.reloads == beforeReloads + 1, @"multiple scoped reload requests coalesce");

        beforeReloads = ordinary.reloads;
        ApolloPerformMultiredditExpansion(ordinary, ^{
            ApolloPerformMultiredditExpansion(ordinary, ^{ [ordinary reloadData]; });
            Check(ordinary.reloads == beforeReloads, @"nested same-table expansion does not reload early");
            [ordinary reloadData];
        });
        Check(ordinary.reloads == beforeReloads + 1, @"nested same-table expansion reloads once at its outer boundary");

        NSUInteger otherReloads = other.reloads;
        beforeReloads = ordinary.reloads;
        ApolloPerformMultiredditExpansion(ordinary, ^{
            ApolloPerformMultiredditExpansion(other, ^{
                [ordinary reloadData];
                [other reloadData];
                ApolloPerformMultiredditExpansion(ordinary, ^{ [ordinary reloadData]; });
            });
            Check(other.reloads == otherReloads + 1 && ordinary.reloads == beforeReloads,
                  @"nested different tables complete at their own outer boundaries");
        });
        Check(ordinary.reloads == beforeReloads + 1, @"a nested table does not hide its parent's scope");

        NSException *sentinel = [NSException exceptionWithName:@"TestOriginalFailure" reason:nil userInfo:nil];
        beforeReloads = ordinary.reloads;
        caught = NO;
        @try {
            ApolloPerformMultiredditExpansion(ordinary, ^{
                [ordinary reloadData];
                @throw sentinel;
            });
        } @catch (NSException *exception) { caught = exception == sentinel; }
        Check(caught && ordinary.reloads == beforeReloads, @"original exceptions propagate without a successful-completion reload");
        Check(!ApolloDeferMultiredditTableUpdate(ordinary), @"throwing original cannot leak its scope");
        [ordinary reloadData];
        Check(ordinary.reloads == beforeReloads + 1, @"table reloads work normally after exception cleanup");

        beforeReloads = ordinary.reloads;
        ApolloPerformMultiredditExpansion(ordinary, ^{
            @try {
                ApolloPerformMultiredditExpansion(ordinary, ^{
                    [ordinary reloadData];
                    @throw sentinel;
                });
            } @catch (NSException *exception) {
                Check(exception == sentinel, @"a caller can catch its nested original exception");
            }
        });
        Check(ordinary.reloads == beforeReloads + 1, @"successful outer caller reconciles mutations from its caught nested failure");

        __block BOOL nilOriginalRan = NO;
        ApolloPerformMultiredditExpansion(nil, ^{ nilOriginalRan = YES; });
        Check(nilOriginalRan && !ApolloDeferMultiredditTableUpdate(nil), @"missing table still runs original without deferral");

        UITableView *background = Table(1);
        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        __block BOOL backgroundDeferred = YES;
        ApolloPerformMultiredditExpansion(ordinary, ^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                @autoreleasepool {
                    backgroundDeferred = ApolloDeferMultiredditTableUpdate(ordinary);
                    ApolloPerformMultiredditExpansion(background, ^{ [background reloadData]; });
                    dispatch_semaphore_signal(completed);
                }
            });
            Check(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
                  @"background passthrough does not block on the main scope");
        });
        Check(!backgroundDeferred && background.reloads == 1,
              @"background calls neither join nor replace a main-thread expansion scope");
        Check(!ApolloDeferMultiredditTableUpdate(ordinary) && !ApolloDeferMultiredditTableUpdate(other),
              @"all successful scopes are removed before returning");

        // #1335: the favorite star's batch when another section changed since
        // the last reload (e.g. Moderator Posts dropped by an account refresh).
        UITableView *unlisted = Table(4);
        unlisted.dataSource = nil;
        unlisted.modelRows = 3;
        caught = NO;
        @try { NativeFavoriteToggle(unlisted, NO); }
        @catch (NSException *exception) { caught = [exception.name isEqualToString:NSInternalInconsistencyException]; }
        Check(caught && unlisted.batches == 1, @"negative control: UIKit rejects a batch over a stale snapshot");

        UITableView *stale = Table(4);
        stale.modelRows = 3;
        favoriteCompletions = 0;
        NativeFavoriteToggle(stale, NO);
        Check(stale.modelRows == 2, @"stale list: the favorite change itself still lands");
        Check(stale.batches == 0 && stale.deletes == 0, @"stale list: no part of the doomed batch reaches UIKit");
        Check(stale.reloads == 1 && stale.presentedRows == 2, @"stale list: one reload presents the new model");
        Check(stale.dataSource.mapInvalidations == 1, @"stale list: that reload invalidates the Following map once");
        Check(favoriteCompletions == 0, @"stale list: completion is delivered asynchronously, like UIKit's");
        DrainMainQueue();
        Check(favoriteCompletions == 1 && favoriteFinished, @"stale list: completion runs once, finished");
        Check(!ApolloDeferMultiredditTableUpdate(stale), @"stale list: the deferral scope does not leak");

        UITableView *staleAdd = Table(2);
        staleAdd.modelRows = 3;
        NativeFavoriteToggle(staleAdd, YES);
        Check(staleAdd.batches == 0 && staleAdd.inserts == 0 && staleAdd.reloads == 1 && staleAdd.presentedRows == 4,
              @"stale list: favoriting (an insert) also presents through one reload");

        UITableView *staleEmpty = Table(4);
        staleEmpty.modelRows = 3;
        [staleEmpty performBatchUpdates:nil completion:nil];
        Check(staleEmpty.reloads == 1 && staleEmpty.presentedRows == 3,
              @"stale list: a batch that registers no rows still resyncs the table");

        UITableView *current = Table(4);
        favoriteCompletions = 0;
        NativeFavoriteToggle(current, NO);
        Check(current.batches == 1 && current.deletes == 1 && current.reloads == 0 && current.presentedRows == 3,
              @"current list: Apollo's own row batch runs unchanged");
        Check(favoriteCompletions == 1, @"current list: UIKit's completion still runs");

        UITableView *scoped = Table(2);
        ApolloPerformMultiredditExpansion(scoped, ^{
            [scoped performBatchUpdates:^{
                scoped.modelRows += 2;
                [scoped insertRowsAtIndexPaths:ChildPaths(2) withRowAnimation:0];
            } completion:nil];
        });
        Check(scoped.batches == 0 && scoped.inserts == 0 && scoped.reloads == 1 && scoped.presentedRows == 4,
              @"inside an expansion scope a batch defers like the other table APIs");
        DrainMainQueue();
        printf("PASS: %lu multireddit expansion checks (production scope and seven table hooks)\n", (unsigned long)checks);
    }
    return 0;
}
