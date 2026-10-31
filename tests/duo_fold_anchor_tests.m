#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Only UIKit's table and pan plumbing is doubled. The runner inserts the
// shipping fold-anchor capture/restore code from src/ApolloDuoRail.xm.
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
typedef NS_ENUM(NSInteger, UIGestureRecognizerState) {
    UIGestureRecognizerStatePossible,
    UIGestureRecognizerStateBegan,
    UIGestureRecognizerStateChanged,
    UIGestureRecognizerStateEnded,
    UIGestureRecognizerStateCancelled,
    UIGestureRecognizerStateFailed,
};

@interface NSIndexPath (DuoFoldAnchorTests)
+ (instancetype)indexPathForRow:(NSInteger)row inSection:(NSInteger)section;
@property(nonatomic, readonly) NSInteger row;
@property(nonatomic, readonly) NSInteger section;
@end
@implementation NSIndexPath (DuoFoldAnchorTests)
+ (instancetype)indexPathForRow:(NSInteger)row inSection:(NSInteger)section {
    NSUInteger indexes[2] = {(NSUInteger)section, (NSUInteger)row};
    return [self indexPathWithIndexes:indexes length:2];
}
- (NSInteger)section { return (NSInteger)[self indexAtPosition:0]; }
- (NSInteger)row { return (NSInteger)[self indexAtPosition:1]; }
@end

@interface UIView : NSObject @end
@implementation UIView @end

@interface UIPanGestureRecognizer : NSObject
@property(nonatomic) UIGestureRecognizerState state;
@property(nonatomic, weak) UIView *view;
@property(nonatomic, strong) NSMutableArray<NSArray *> *targets;
- (void)addTarget:(id)target action:(SEL)action;
- (void)deliver:(UIGestureRecognizerState)state;
@end
@implementation UIPanGestureRecognizer
- (void)addTarget:(id)target action:(SEL)action {
    if (!self.targets) self.targets = [NSMutableArray array];
    NSArray *pair = @[target, NSStringFromSelector(action)];
    // UIKit ignores a target-action pair that was already added.
    if (![self.targets containsObject:pair]) [self.targets addObject:pair];
}
- (void)deliver:(UIGestureRecognizerState)state {
    self.state = state;
    for (NSArray *pair in [self.targets copy]) {
        ((void (*)(id, SEL, id))objc_msgSend)(pair[0], NSSelectorFromString(pair[1]), self);
    }
}
@end

@interface UITableView : UIView
@property(nonatomic, strong) id window;
@property(nonatomic) CGPoint contentOffset;
@property(nonatomic) UIEdgeInsets adjustedContentInset;
@property(nonatomic) CGRect bounds;
@property(nonatomic, copy) NSArray<NSNumber *> *rowHeights;
@property(nonatomic, getter=isDragging) BOOL dragging;
@property(nonatomic, getter=isDecelerating) BOOL decelerating;
@property(nonatomic, getter=isTracking) BOOL tracking;
@property(nonatomic, strong) UIPanGestureRecognizer *panGestureRecognizer;
@end
@implementation UITableView
- (instancetype)init {
    if ((self = [super init])) {
        _panGestureRecognizer = [UIPanGestureRecognizer new];
        _panGestureRecognizer.view = self;
        _bounds = CGRectMake(0, 0, 400, 800);
    }
    return self;
}
- (CGRect)rectForRowAtIndexPath:(NSIndexPath *)path {
    CGFloat y = 0;
    for (NSInteger row = 0; row < path.row; row++) y += self.rowHeights[(NSUInteger)row].doubleValue;
    return CGRectMake(0, y, CGRectGetWidth(self.bounds), self.rowHeights[(NSUInteger)path.row].doubleValue);
}
- (NSArray<NSIndexPath *> *)indexPathsForVisibleRows {
    CGFloat top = self.contentOffset.y + self.adjustedContentInset.top;
    CGFloat bottom = self.contentOffset.y + CGRectGetHeight(self.bounds);
    NSMutableArray *rows = [NSMutableArray array];
    for (NSInteger row = 0; row < (NSInteger)self.rowHeights.count; row++) {
        CGRect rect = [self rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        if (CGRectGetMaxY(rect) > top && CGRectGetMinY(rect) < bottom)
            [rows addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    }
    return rows;
}
- (NSInteger)numberOfSections { return 1; }
- (NSInteger)numberOfRowsInSection:(__unused NSInteger)section { return (NSInteger)self.rowHeights.count; }
- (CGSize)contentSize {
    CGFloat height = 0;
    for (NSNumber *value in self.rowHeights) height += value.doubleValue;
    return CGSizeMake(CGRectGetWidth(self.bounds), height);
}
- (void)setContentOffset:(CGPoint)offset animated:(__unused BOOL)animated { self.contentOffset = offset; }
- (void)layoutIfNeeded {}
- (void)waitUntilAllUpdatesAreCommitted {}
@end

#define ApolloLog(...) ((void)0)

// INCLUDE_PRODUCTION_FOLD_ANCHOR

static unsigned checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static NSArray<NSNumber *> *Rows(CGFloat height) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger index = 0; index < 200; index++) [rows addObject:@(height)];
    return rows;
}

// Folded rows are 100pt; 520pt down shows 20% of row 5. Unfolding rewraps
// them to 60pt, and media then settles them to 50pt a beat later.
static UITableView *FoldedTable(void) {
    UITableView *table = [UITableView new];
    table.window = NSNull.null;
    table.rowHeights = Rows(100);
    table.contentOffset = CGPointMake(0, 520);
    ApolloDuoCaptureFoldAnchor(table);
    table.rowHeights = Rows(60);
    return table;
}

int main(void) {
    @autoreleasepool {
        UITableView *table = FoldedTable();
        ApolloDuoRestoreFoldAnchor(table, NO);
        Check(fabs(table.contentOffset.y - 312) < 0.01, @"first pass keeps the same row in view after the fold");
        table.rowHeights = Rows(50);
        ApolloDuoRestoreFoldAnchor(table, YES);
        Check(fabs(table.contentOffset.y - 260) < 0.01, @"final pass follows rows that settled a beat later");

        table = FoldedTable();
        ApolloDuoRestoreFoldAnchor(table, NO);
        // The reader scrolls before the settle pass and lifts without a fling.
        [table.panGestureRecognizer deliver:UIGestureRecognizerStateBegan];
        table.contentOffset = CGPointMake(0, 700);
        [table.panGestureRecognizer deliver:UIGestureRecognizerStateEnded];
        table.rowHeights = Rows(50);
        ApolloDuoRestoreFoldAnchor(table, YES);
        Check(fabs(table.contentOffset.y - 700) < 0.01, @"a finished scroll inside the settle window is not undone");

        table = FoldedTable();
        // A scroll that starts while UIKit is still resizing also wins.
        [table.panGestureRecognizer deliver:UIGestureRecognizerStateBegan];
        table.contentOffset = CGPointMake(0, 640);
        [table.panGestureRecognizer deliver:UIGestureRecognizerStateEnded];
        ApolloDuoRestoreFoldAnchor(table, NO);
        ApolloDuoRestoreFoldAnchor(table, YES);
        Check(fabs(table.contentOffset.y - 640) < 0.01, @"a scroll during the transition is not undone by either pass");

        table = FoldedTable();
        // Gesture changes other than a new scroll leave the anchor in place.
        [table.panGestureRecognizer deliver:UIGestureRecognizerStateFailed];
        ApolloDuoRestoreFoldAnchor(table, NO);
        Check(fabs(table.contentOffset.y - 312) < 0.01, @"a pan that never began does not drop the anchor");

        table = FoldedTable();
        table.rowHeights = Rows(100);
        table.contentOffset = CGPointMake(0, 520);
        ApolloDuoCaptureFoldAnchor(table);
        Check(table.panGestureRecognizer.targets.count <= 1, @"repeated folds observe the pan once");
        table.rowHeights = Rows(60);
        ApolloDuoRestoreFoldAnchor(table, NO);
        Check(fabs(table.contentOffset.y - 312) < 0.01, @"a repeated capture still restores");
    }
    printf("duo fold anchor tests: %u checks passed\n", checks);
    return 0;
}
