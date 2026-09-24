#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

// Exercise the shipping scheduling and reload code with deterministic time and
// UIKit doubles. Reloads intentionally retain the original node.
static double now;
static NSMutableArray *jobs, *immediateJobs;
static NSUInteger feedSizeUpdates;
static NSUInteger conversions, reloads, notes;
static BOOL measuring, throwReload;
static void Later(dispatch_time_t delay, dispatch_queue_t queue, dispatch_block_t block) {
    [jobs addObject:@{@"at" : @(now + 0.15), @"block" : [block copy]}];
}
#define dispatch_after Later
static void NextTurn(dispatch_queue_t queue, dispatch_block_t block) {
    [immediateJobs addObject:[block copy]];
}
#define dispatch_async NextTurn
static void RunImmediate(void) {
    NSArray *ready = [immediateJobs copy];
    [immediateJobs removeAllObjects];
    for (dispatch_block_t block in ready)
        block();
}
static double TestTime(void) {
    return now;
}
#define CACurrentMediaTime() TestTime()
#define ApolloLog(...) ((void)0)
@interface Layer : NSObject
@property NSArray *animationKeys;
@end
@implementation Layer
@end
@interface UIView : NSObject
@property CGRect frame;
@property CGRect bounds;
@property BOOL hidden;
@property CGFloat alpha;
@property id window;
@property UIView *superview;
@property NSArray<UIView *> *subviews;
@property Layer *layer;
- (BOOL)isDescendantOfView:(UIView *)view;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
@end
@implementation UIView
- (instancetype)init {
    if ((self = [super init])) {
        _alpha = 1;
        _subviews = @[];
        _layer = [Layer new];
    }
    return self;
}
- (BOOL)isDescendantOfView:(UIView *)view {
    for (UIView *v = self; v; v = v.superview)
        if (v == view)
            return YES;
    return NO;
}
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view {
    conversions++;
    for (UIView *v = self; v && v != view; v = v.superview) {
        rect.origin.x += v.frame.origin.x;
        rect.origin.y += v.frame.origin.y;
    }
    return rect;
}
@end
@interface UIScrollView : UIView
@property BOOL tracking, dragging, decelerating;
@end
@implementation UIScrollView
@end
@interface UITableViewCell : UIView
@end
@implementation UITableViewCell
@end
@interface UICollectionViewCell : UIView
@end
@implementation UICollectionViewCell
@end
@interface NSIndexPath (UI)
@property(readonly) NSInteger row;
@property(readonly) NSInteger item;
@end
@implementation NSIndexPath (UI)
- (NSInteger)row {
    return [self indexAtPosition:0];
}
- (NSInteger)item {
    return self.row;
}
@end
@interface UITableView : UIScrollView
@property UITableViewCell *cell;
@property NSIndexPath *path;
@property BOOL visible;
- (NSArray *)indexPathsForVisibleRows;
- (NSIndexPath *)indexPathForCell:(id)cell;
- (UITableViewCell *)cellForRowAtIndexPath:(id)path;
- (void)reloadRowsAtIndexPaths:(id)paths withRowAnimation:(NSInteger)animation;
@end
@implementation UITableView
- (NSArray *)indexPathsForVisibleRows {
    return self.visible ? @[ self.path ] : @[];
}
- (NSIndexPath *)indexPathForCell:(id)cell {
    return cell == self.cell ? self.path : nil;
}
- (UITableViewCell *)cellForRowAtIndexPath:(id)path {
    return self.visible ? self.cell : nil;
}
- (void)reloadRowsAtIndexPaths:(id)paths withRowAnimation:(NSInteger)animation {
    if (throwReload)
        @throw [NSException exceptionWithName:@"TestReload" reason:nil userInfo:nil];
    reloads++;
}
@end
static NSInteger UITableViewRowAnimationNone;
@interface UICollectionView : UIScrollView
@property UICollectionViewCell *cell;
@property NSIndexPath *path;
@property BOOL visible;
- (NSArray *)indexPathsForVisibleItems;
- (NSIndexPath *)indexPathForCell:(id)cell;
- (UICollectionViewCell *)cellForItemAtIndexPath:(id)path;
- (void)reloadItemsAtIndexPaths:(id)paths;
- (void)performBatchUpdates:(dispatch_block_t)updates completion:(void (^)(BOOL))completion;
@end
@implementation UICollectionView
- (NSArray *)indexPathsForVisibleItems {
    return self.visible ? @[ self.path ] : @[];
}
- (NSIndexPath *)indexPathForCell:(id)cell {
    return cell == self.cell ? self.path : nil;
}
- (UICollectionViewCell *)cellForItemAtIndexPath:(id)path {
    return self.visible ? self.cell : nil;
}
- (void)reloadItemsAtIndexPaths:(id)paths {
    reloads++;
}
- (void)performBatchUpdates:(dispatch_block_t)updates completion:(void (^)(BOOL))completion {
    updates();
    Later(0, nil, ^{
      completion(YES);
    });
}
@end
@interface ASDisplayNode : NSObject
@property BOOL isNodeLoaded, hidden;
@property UIView *view;
@property ASDisplayNode *owner;
@property NSDictionary *footers;
@end
@implementation ASDisplayNode
@end
@interface LargePost : ASDisplayNode
@end
@implementation LargePost
@end
static Class GetClass(const char *name) {
    return strcmp(name, "_TtC6Apollo17LargePostCellNode") == 0 ? LargePost.class : objc_getClass(name);
}
#define objc_getClass GetClass
static char kApolloLinkPreviewURLKey, kApolloLPPendingRowReloadHostKey;
static BOOL ApolloRowMeasureInProgress(void) {
    return measuring;
}
static UIView *ApolloLPViewForNode(ASDisplayNode *n) {
    return n.view;
}
static ASDisplayNode *ApolloLPFindOwningCellNode(ASDisplayNode *n) {
    return n.owner;
}
static id ApolloLPModelFromNodeIvar(ASDisplayNode *n, const char *name) {
    return n.footers[@(name)];
}
static void ApolloLPRenoteDroppedRowReload(ASDisplayNode *n, NSString *h, NSInteger row) {
    notes++;
}
static NSMutableDictionary *ApolloLPPendingCrossNodeRowReloads(void) {
    static NSMutableDictionary *d = [NSMutableDictionary new];
    return d;
}
static NSString *ApolloGetLinkButtonNodeURLString(ASDisplayNode *n) {
    return nil;
}
static BOOL ApolloLPShouldDeferToInlineMedia(NSURL *u) {
    return [u.path hasSuffix:@".jpg"];
}
static BOOL ApolloLPInvokeRowReloadIfPossible(ASDisplayNode *, ASDisplayNode *, NSString *,
                                              BOOL (^)(UIView *) = nil, void (^)(void) = nil);
static BOOL ApolloLPInvalidateFeedRow(ASDisplayNode *node) {
    feedSizeUpdates++;
    return YES;
}
#import "Overflow.inc"

static NSUInteger checks;
static void Check(BOOL ok, NSString *why) {
    checks++;
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", why.UTF8String);
        exit(1);
    }
}
static void Tick(void) {
    RunImmediate();
    now += 0.151;
    NSArray *ready = [jobs copy];
    [jobs removeAllObjects];
    for (NSDictionary *j in ready) {
        dispatch_block_t b = j[@"block"];
        b();
    }
}
static ASDisplayNode *Fixture(UITableView **out) {
    UITableView *t = [UITableView new];
    t.window = @YES;
    t.visible = YES;
    t.path = [NSIndexPath indexPathWithIndex:0];
    UITableViewCell *c = [UITableViewCell new];
    c.bounds = CGRectMake(0, 0, 300, 300);
    c.window = @YES;
    c.superview = t;
    t.cell = c;
    ASDisplayNode *n = [ASDisplayNode new];
    n.isNodeLoaded = YES;
    n.view = [UIView new];
    n.view.window = @YES;
    n.view.superview = c;
    n.view.frame = CGRectMake(0, 50, 300, 100);
    n.view.bounds = CGRectMake(0, 0, 300, 100);
    UIView *child = [UIView new];
    child.frame = CGRectMake(0, 0, 300, 100);
    n.view.subviews = @[ child ];
    objc_setAssociatedObject(
        n, &kApolloLinkPreviewURLKey,
        [NSURL URLWithString:[@"https://example.com/" stringByAppendingString:NSUUID.UUID.UUIDString]],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    *out = t;
    return n;
}
static void Grow(ASDisplayNode *n, CGFloat height) {
    n.view.subviews[0].frame = CGRectMake(0, 0, 300, height);
    ApolloLPScheduleOverflowHeightCheck(n, @"test", YES);
}
int main(void) {
    @autoreleasepool {
        jobs = [NSMutableArray new];
        immediateJobs = [NSMutableArray new];
        UITableView *t;
        ASDisplayNode *n = Fixture(&t);
        ApolloLPScheduleOverflowHeightCheck(n, @"visible");
        Tick();
        NSUInteger baseline = conversions;
        for (int i = 0; i < 1000; i++)
            ApolloLPScheduleOverflowHeightCheck(n, @"layout", YES);
        Check(jobs.count == 0 && conversions == baseline, @"1000 unchanged layouts schedule no work");
        Grow(n, 400);
        Tick();
        Check(ApolloLPOverflowStateForNode(n).reloadPending,
              @"child growth schedules recovery with unchanged host");
        Tick();
        Check(reloads == 1 && !ApolloLPOverflowStateForNode(n).reloadPending,
              @"retained node clears pending after reload");
        Grow(n, 420);
        Tick();
        Tick();
        Check(reloads == 2, @"same node can recover later growth");
        Grow(n, 440);
        Tick();
        Tick();
        Grow(n, 460);
        Tick();
        Check(reloads == 3 && !ApolloLPOverflowStateForNode(n).reloadPending,
              @"exhausted budget does not latch node");
        now += 61;
        Grow(n, 480);
        Tick();
        Tick();
        Check(reloads == 4, @"recovery works after budget expires");
        n = Fixture(&t);
        NSUInteger before = reloads;
        Grow(n, 400);
        Tick();
        t.cell.bounds = CGRectMake(0, 0, 300, 600);
        Tick();
        Check(reloads == before, @"overlap corrected before deferred reload cancels it");
        n = Fixture(&t);
        Grow(n, 400);
        Tick();
        t.visible = NO;
        Tick();
        Check(!ApolloLPOverflowStateForNode(n).reloadPending, @"offscreen cancellation clears pending");
        t.visible = YES;
        ApolloLPScheduleOverflowHeightCheck(n, @"visible");
        Tick();
        Tick();
        Check(reloads == before + 1, @"visibility re-arms cancelled check");
        n = Fixture(&t);
        Grow(n, 400);
        Tick();
        throwReload = YES;
        Tick();
        throwReload = NO;
        Check(!ApolloLPOverflowStateForNode(n).reloadPending, @"exception clears pending");
        n = Fixture(&t);
        t.dragging = YES;
        baseline = conversions;
        Grow(n, 400);
        for (int i = 0; i < 20; i++)
            Tick();
        Check(conversions == baseline && jobs.count == 1,
              @"scrolling keeps one pending check without geometry conversion");
        t.dragging = NO;
        Tick();
        Tick();
        Check(!ApolloLPOverflowStateForNode(n).reloadPending, @"scroll end allows recovery");
        n = Fixture(&t);
        n.view.layer.animationKeys = @[ @"bounds" ];
        before = reloads;
        Grow(n, 400);
        Tick();
        Check(reloads == before, @"animation defers recovery");
        n.view.layer.animationKeys = @[];
        Tick();
        Tick();
        Check(reloads == before + 1, @"settled animation allows recovery");
        n = Fixture(&t);
        before = reloads;
        Grow(n, 400);
        Tick();
        Grow(n, 450);
        Tick();
        Tick();
        Tick();
        Check(reloads == before + 1, @"growth during pending reload is rechecked after settling");
        n = Fixture(&t);
        before = reloads;
        Grow(n, 400);
        Tick();
        UITableViewCell *replacement = [UITableViewCell new];
        t.cell = replacement;
        Tick();
        Check(reloads == before, @"reused index path cannot reload another cell");
        n = Fixture(&t);
        before = reloads;
        Grow(n, 400);
        Tick();
        n.view.layer.animationKeys = @[ @"bounds" ];
        Tick();
        Check(reloads == before && jobs.count == 1,
              @"animation starting after detection cancels and re-arms validation");
        n.view.layer.animationKeys = @[];
        Tick();
        Tick();
        Check(reloads == before + 1, @"cancelled animated reload eventually completes");
        n = Fixture(&t);
        LargePost *owner = [LargePost new];
        n.owner = owner;
        ASDisplayNode *footer = [ASDisplayNode new];
        footer.isNodeLoaded = YES;
        footer.view = [UIView new];
        footer.view.bounds = CGRectMake(0, 0, 300, 40);
        footer.view.frame = CGRectMake(0, 180, 300, 40);
        footer.view.superview = t.cell;
        owner.footers = @{@"postInfoNode" : footer};
        before = reloads;
        Grow(n, 160);
        Tick();
        Tick();
        Check(reloads == before + 1, @"footer intersection detected even when card stays inside cell");
        n = Fixture(&t);
        before = reloads;
        objc_setAssociatedObject(n, &kApolloLinkPreviewURLKey,
                                 [NSURL URLWithString:@"https://example.com/photo.jpg"],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Grow(n, 400);
        Tick();
        Check(reloads == before && jobs.count == 0, @"inline media stays outside recovery ownership");
        n = Fixture(&t);
        UICollectionView *collection = [UICollectionView new];
        collection.window = @YES;
        collection.visible = YES;
        collection.path = t.path;
        UICollectionViewCell *cc = [UICollectionViewCell new];
        cc.bounds = t.cell.bounds;
        cc.superview = collection;
        cc.window = @YES;
        collection.cell = cc;
        n.view.superview = cc;
        before = reloads;
        Grow(n, 400);
        Tick();
        Tick();
        Check(reloads == before + 1 && ApolloLPOverflowStateForNode(n).reloadPending,
              @"collection keeps pending until batch completion");
        Tick();
        Check(!ApolloLPOverflowStateForNode(n).reloadPending,
              @"collection completion releases retained node");
        Check(jobs.count == 0, @"no callbacks left after completion");
        n = Fixture(&t);
        n.owner = [LargePost new];
        t.dragging = YES;
        NSUInteger feedBefore = feedSizeUpdates;
        NSUInteger conversionsBefore = conversions;
        before = reloads;
        Grow(n, 320);
        Check(feedSizeUpdates == feedBefore && immediateJobs.count == 1,
              @"feed correction waits until outside the layout stack");
        for (int i = 0; i < 1000; i++)
            Grow(n, 320);
        Check(immediateJobs.count == 1, @"repeated feed layouts coalesce before correction");
        RunImmediate();
        Check(feedSizeUpdates == feedBefore + 1 && reloads == before && conversions == conversionsBefore,
              @"feed size correction runs during scrolling without row reload or rectangle conversion");
        for (int i = 0; i < 1000; i++)
            Grow(n, 320);
        Check(immediateJobs.count == 0, @"unchanged broken geometry cannot loop native size updates");
        Grow(n, 360);
        RunImmediate();
        Check(feedSizeUpdates == feedBefore + 2, @"later content growth remains eligible for correction");
        Grow(n, 400);
        n.view.window = nil;
        RunImmediate();
        Check(feedSizeUpdates == feedBefore + 2, @"detached card cancels queued size correction");
        Tick();
        Check(jobs.count == 0 && immediateJobs.count == 0,
              @"feed correction leaves no callbacks after detach");
        n.view.window = @YES;
        Grow(n, 400);
        RunImmediate();
        Check(feedSizeUpdates == feedBefore + 3, @"reattached card can retry cancelled size correction");
        n.view.bounds = CGRectMake(0, 0, 300, 400);
        Grow(n, 400);
        n.view.bounds = CGRectMake(0, 0, 300, 100);
        Grow(n, 400);
        RunImmediate();
        Check(feedSizeUpdates == feedBefore + 4,
              @"a corrected card can repair the same size after later shrink");
        n.view.window = nil;
        Tick();
        printf("PASS: %lu overflow lifecycle checks\n", (unsigned long)checks);
    }
}
