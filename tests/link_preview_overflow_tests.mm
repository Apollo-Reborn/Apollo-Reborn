#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Exercise the shipping scheduling and reload code with deterministic time and
// UIKit/Texture doubles. Reloads intentionally retain the original node.
// Container queuing is modeled here; real layout and scroll performance need simulator/device checks.
static double now;
static NSMutableArray *jobs, *immediateJobs;
static NSUInteger nativeSizeUpdates, membershipQueries;
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
@property ASDisplayNode *owner, *supernode;
@property NSDictionary *footers;
@property NSUInteger layoutInvalidations;
- (void)invalidateCalculatedLayout;
@end
@implementation ASDisplayNode
- (void)invalidateCalculatedLayout {
    self.layoutInvalidations++;
}
@end
@protocol NodeSizeDelegate <NSObject>
- (NSIndexPath *)indexPathForNode:(ASDisplayNode *)node;
- (void)nodeDidInvalidateSize:(ASDisplayNode *)node;
@end
@interface ASCellNode : ASDisplayNode
@property id<NodeSizeDelegate> interactionDelegate;
@property SEL unavailableSelector;
- (void)_rootNodeDidInvalidateSize;
@end
@implementation ASCellNode
- (BOOL)respondsToSelector:(SEL)selector {
    return selector != self.unavailableSelector && [super respondsToSelector:selector];
}
- (void)_rootNodeDidInvalidateSize {
    nativeSizeUpdates++;
    [self.interactionDelegate nodeDidInvalidateSize:self];
}
@end
@interface ASTableView : UITableView <NodeSizeDelegate>
@property SEL unavailableSelector;
@property NSMutableSet *hostedNodes, *sizeQueue;
@end
@implementation ASTableView
- (BOOL)respondsToSelector:(SEL)selector {
    return selector != self.unavailableSelector && [super respondsToSelector:selector];
}
- (instancetype)init {
    if ((self = [super init])) {
        _hostedNodes = [NSMutableSet new];
        _sizeQueue = [NSMutableSet new];
    }
    return self;
}
- (NSIndexPath *)indexPathForNode:(ASDisplayNode *)node {
    membershipQueries++;
    return [self.hostedNodes containsObject:node] ? self.path : nil;
}
- (void)nodeDidInvalidateSize:(ASDisplayNode *)node {
    [self.sizeQueue addObject:node];
}
@end
@interface ASCollectionView : UICollectionView <NodeSizeDelegate>
@property NSMutableSet *hostedNodes, *sizeQueue;
@end
@implementation ASCollectionView
- (instancetype)init {
    if ((self = [super init])) {
        _hostedNodes = [NSMutableSet new];
        _sizeQueue = [NSMutableSet new];
    }
    return self;
}
- (NSIndexPath *)indexPathForNode:(ASDisplayNode *)node {
    membershipQueries++;
    return [self.hostedNodes containsObject:node] ? self.path : nil;
}
- (void)nodeDidInvalidateSize:(ASDisplayNode *)node {
    [self.sizeQueue addObject:node];
}
@end
// Matching selectors alone must not qualify a non-Texture owner.
@interface OtherSizeDelegate : NSObject <NodeSizeDelegate>
@end
@implementation OtherSizeDelegate
- (NSIndexPath *)indexPathForNode:(ASDisplayNode *)node {
    return [NSIndexPath indexPathWithIndex:0];
}
- (void)nodeDidInvalidateSize:(ASDisplayNode *)node {}
@end
@interface LargePost : ASCellNode
@end
@implementation LargePost
@end
@interface CommentCellNode : ASCellNode
@end
@implementation CommentCellNode
@end
@interface CommentsHeaderCellNode : ASCellNode
@end
@implementation CommentsHeaderCellNode
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
    UITableView *t = [ASTableView new];
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
static ASDisplayNode *HostedFixture(Class cellClass, BOOL collection, UIScrollView **out) {
    UITableView *table;
    ASDisplayNode *node = Fixture(&table);
    ASCellNode *cell = [cellClass new];
    ASDisplayNode *container = [ASDisplayNode new];
    node.owner = cell;
    node.supernode = container;
    container.supernode = cell;
    cell.supernode = [ASDisplayNode new];
    if (collection) {
        ASCollectionView *host = [ASCollectionView new];
        host.window = @YES;
        host.path = table.path;
        host.visible = YES;
        UICollectionViewCell *view = [UICollectionViewCell new];
        view.bounds = table.cell.bounds;
        view.superview = host;
        view.window = @YES;
        host.cell = view;
        node.view.superview = view;
        cell.view = view;
        cell.interactionDelegate = host;
        [host.hostedNodes addObject:cell];
        *out = host;
    } else {
        ASTableView *host = (ASTableView *)table;
        cell.view = table.cell;
        cell.interactionDelegate = host;
        [host.hostedNodes addObject:cell];
        *out = host;
    }
    return node;
}
static void FinishFixture(ASDisplayNode *node) {
    node.view.window = nil;
    Tick();
}
static void RunHostedSizeTests(void) {
    UIScrollView *host;
    for (Class cellClass in @[ LargePost.class, CommentCellNode.class, CommentsHeaderCellNode.class ]) {
        for (int hostKind = 0; hostKind < 2; hostKind++) {
            BOOL collection = hostKind != 0;
            ASDisplayNode *node = HostedFixture(cellClass, collection, &host);
            ASCellNode *cell = (ASCellNode *)node.owner;
            NSString *context = [NSString stringWithFormat:@"%@ in %@", NSStringFromClass(cellClass),
                                 collection ? @"collection" : @"table"];
            Check(ApolloLPHostedCellForSizeUpdate(node) == cell,
                  [context stringByAppendingString:@": hosted cell qualifies"]);
            host.dragging = YES;
            NSUInteger sizeBefore = nativeSizeUpdates, reloadBefore = reloads, geometryBefore = conversions;
            NSUInteger membershipBefore = membershipQueries;
            Grow(node, 320);
            for (int i = 0; i < 1000; i++)
                Grow(node, 320);
            Check(nativeSizeUpdates == sizeBefore && immediateJobs.count == 1 && membershipQueries == membershipBefore,
                  [context stringByAppendingString:@": layouts coalesce without querying container membership"]);
            RunImmediate();
            Check(nativeSizeUpdates == sizeBefore + 1 && reloads == reloadBefore && conversions == geometryBefore &&
                  membershipQueries == membershipBefore + 1,
                  [context stringByAppendingString:@": resize while scrolling avoids reload and rectangle conversion"]);
            Check(node.layoutInvalidations == 1 && node.supernode.layoutInvalidations == 1 &&
                  cell.layoutInvalidations == 1 && cell.supernode.layoutInvalidations == 0,
                  [context stringByAppendingString:@": invalidation stops at the owning cell"]);
            for (int i = 0; i < 1000; i++)
                Grow(node, 320);
            Check(immediateJobs.count == 0,
                  [context stringByAppendingString:@": unchanged overflow cannot loop size updates"]);
            FinishFixture(node);
        }
    }

    ASDisplayNode *node = HostedFixture(CommentCellNode.class, NO, &host);
    ASCellNode *cell = (ASCellNode *)node.owner;
    id<NodeSizeDelegate> delegate = cell.interactionDelegate;
    NSUInteger before = nativeSizeUpdates;
    cell.interactionDelegate = nil;
    Check(!ApolloLPHostedCellForSizeUpdate(node) && !ApolloLPInvalidateHostedCell(node) &&
          nativeSizeUpdates == before && node.layoutInvalidations == 0,
          @"unhosted cells never enter ASCellNode's immediate measurement fallback");
    cell.interactionDelegate = [OtherSizeDelegate new];
    Check(!ApolloLPHostedCellForSizeUpdate(node) && !ApolloLPInvalidateHostedCell(node),
          @"matching delegate selectors do not qualify a non-Texture container");
    cell.interactionDelegate = delegate;
    cell.unavailableSelector = @selector(interactionDelegate);
    Check(!ApolloLPHostedCellForSizeUpdate(node), @"missing interaction delegate accessor is rejected");
    cell.unavailableSelector = @selector(_rootNodeDidInvalidateSize);
    Check(!ApolloLPHostedCellForSizeUpdate(node), @"missing cell size invalidation method is rejected");
    cell.unavailableSelector = NULL;
    ((ASTableView *)host).unavailableSelector = @selector(indexPathForNode:);
    Check(!ApolloLPHostedCellForSizeUpdate(node), @"container without node lookup is rejected");
    ((ASTableView *)host).unavailableSelector = @selector(nodeDidInvalidateSize:);
    Check(!ApolloLPHostedCellForSizeUpdate(node), @"container without queued invalidation is rejected");
    ((ASTableView *)host).unavailableSelector = NULL;
    [[(ASTableView *)host hostedNodes] removeAllObjects];
    Check(!ApolloLPInvalidateHostedCell(node) && nativeSizeUpdates == before,
          @"delegate must still own an index path before invalidation");
    [[(ASTableView *)host hostedNodes] addObject:cell];
    ASDisplayNode *nonCell = [ASDisplayNode new];
    node.owner = nonCell;
    Check(!ApolloLPHostedCellForSizeUpdate(node) && !ApolloLPInvalidateHostedCell(node),
          @"an ordinary display node cannot qualify as a hosted cell");
    node.owner = cell;
    FinishFixture(node);

    node = HostedFixture(CommentCellNode.class, NO, &host);
    cell = (ASCellNode *)node.owner;
    host.dragging = YES;
    before = nativeSizeUpdates;
    Grow(node, 320);
    node.view.window = nil;
    RunImmediate();
    Check(nativeSizeUpdates == before && !ApolloLPOverflowStateForNode(node).sizeUpdatePending,
          @"detaching before the callback cancels the native update");
    Tick();
    Check(jobs.count == 0 && immediateJobs.count == 0,
          @"detachment leaves no queued callbacks");
    node.view.window = @YES;
    Grow(node, 320);
    RunImmediate();
    Check(nativeSizeUpdates == before + 1, @"reattachment can retry the same content size");
    Grow(node, 360);
    delegate = cell.interactionDelegate;
    cell.interactionDelegate = nil;
    RunImmediate();
    Check(nativeSizeUpdates == before + 1, @"losing the delegate cancels a queued update");
    cell.interactionDelegate = delegate;
    Grow(node, 360);
    RunImmediate();
    Check(nativeSizeUpdates == before + 2, @"restoring the delegate rearms cancelled growth");
    Grow(node, 400);
    [[(ASTableView *)host hostedNodes] removeObject:cell];
    RunImmediate();
    Check(nativeSizeUpdates == before + 2, @"losing membership cancels a queued update");
    [[(ASTableView *)host hostedNodes] addObject:cell];
    Grow(node, 400);
    RunImmediate();
    Check(nativeSizeUpdates == before + 3, @"restoring membership rearms cancelled growth");
    FinishFixture(node);

    node = HostedFixture(CommentsHeaderCellNode.class, YES, &host);
    cell = (ASCellNode *)node.owner;
    before = nativeSizeUpdates;
    Grow(node, 320);
    ASCellNode *replacement = [CommentsHeaderCellNode new];
    replacement.interactionDelegate = cell.interactionDelegate;
    replacement.view = cell.view;
    [[(ASCollectionView *)host hostedNodes] removeObject:cell];
    [[(ASCollectionView *)host hostedNodes] addObject:replacement];
    node.owner = replacement;
    node.supernode = replacement;
    RunImmediate();
    Check(nativeSizeUpdates == before && replacement.layoutInvalidations == 0,
          @"reparenting cannot apply the queued request to a different cell");
    Grow(node, 320);
    RunImmediate();
    Check(nativeSizeUpdates == before + 1 && replacement.layoutInvalidations == 1,
          @"reparented card can schedule a fresh request for its current cell");
    FinishFixture(node);

    node = HostedFixture(CommentCellNode.class, NO, &host);
    before = nativeSizeUpdates;
    Grow(node, 320);
    node.view.subviews[0].frame = CGRectMake(0, 0, 300, 100);
    RunImmediate();
    Check(nativeSizeUpdates == before && CGSizeEqualToSize(ApolloLPOverflowStateForNode(node).requestedContentSize, CGSizeZero),
          @"collapse before callback cancels obsolete growth and clears its request");
    Grow(node, 320);
    RunImmediate();
    Check(nativeSizeUpdates == before + 1, @"expansion after cancelled collapse remains eligible");
    Grow(node, 360);
    RunImmediate();
    Check(nativeSizeUpdates == before + 2, @"later content growth remains eligible");
    node.view.bounds = CGRectMake(0, 0, 300, 360);
    Grow(node, 360);
    node.view.bounds = CGRectMake(0, 0, 300, 100);
    Grow(node, 360);
    RunImmediate();
    Check(nativeSizeUpdates == before + 3,
          @"a corrected card can repair the same size after its allocation shrinks");
    FinishFixture(node);

    node = HostedFixture(CommentCellNode.class, NO, &host);
    before = nativeSizeUpdates;
    Grow(node, 320);
    Grow(node, 360);
    RunImmediate();
    Check(nativeSizeUpdates == before + 1 &&
          CGSizeEqualToSize(ApolloLPOverflowStateForNode(node).requestedContentSize, CGSizeMake(300, 360)),
          @"growth during a pending request uses fresh content geometry");
    Grow(node, 360);
    Check(immediateJobs.count == 0, @"the pending request does not re-request its updated content size");
    FinishFixture(node);

    node = HostedFixture(CommentCellNode.class, NO, &host);
    ASDisplayNode *second = HostedFixture(CommentCellNode.class, NO, &host);
    ASCellNode *sharedCell = (ASCellNode *)second.owner;
    node.owner = sharedCell;
    node.supernode.supernode = sharedCell;
    node.view.superview = second.view.superview;
    host.dragging = YES;
    before = nativeSizeUpdates;
    Grow(node, 320);
    Grow(second, 360);
    RunImmediate();
    Check(nativeSizeUpdates == before + 2 && node.layoutInvalidations == 1 && second.layoutInvalidations == 1 &&
          [(ASTableView *)host sizeQueue].count == 1,
          @"multiple links dirty both paths and notify the same queued cell");
    for (int i = 0; i < 1000; i++) {
        Grow(node, 320);
        Grow(second, 360);
    }
    Check(immediateJobs.count == 0 && nativeSizeUpdates == before + 2,
          @"repeated multi-link layouts do not generate another size update");
    node.view.window = nil;
    FinishFixture(second);
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
        RunHostedSizeTests();
        printf("PASS: %lu overflow lifecycle checks\n", (unsigned long)checks);
    }
}
