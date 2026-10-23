#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface UIViewController : NSObject
@property (nonatomic, strong) id tableNode;
@end
@implementation UIViewController
@end

@interface TestCellNode : NSObject
@property (nonatomic, strong) id owningNode;
@property (nonatomic, strong) NSIndexPath *indexPath;
@end
@implementation TestCellNode
@end

// The host supplies only the UIKit/Texture surface used by the real helpers.
@interface NSIndexPath (TestTableRow)
@property (nonatomic, readonly) NSInteger row;
@end
@implementation NSIndexPath (TestTableRow)
- (NSInteger)row { return (NSInteger)[self indexAtPosition:1]; }
@end

static Class ApolloClassASTableNode;
static BOOL sCommunityHighlights = YES;
static const void *kApolloHLActiveSubKey = &kApolloHLActiveSubKey;
static const void *kApolloHLContainerKey = &kApolloHLContainerKey;
static char kApolloHLHiddenRowsKey, kApolloHLDeDupSubKey;
static char kApolloHLStickyCountKey, kApolloHLFeedOwnedMaskKey, kApolloHLSepCollapseKey;

static id ApolloHLTypedIvar(id object, NSString *name, Class expectedClass) {
    id value = [name isEqualToString:@"tableNode"] ? [(UIViewController *)object tableNode] : nil;
    return [value isKindOfClass:expectedClass] ? value : nil;
}
static void ApolloHLRestoreStandaloneHeader(__unused UIViewController *controller) {}

// PRODUCTION_HELPERS

static void Require(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"HighlightsSeparatorFailure" reason:message userInfo:nil];
}

static UIViewController *Feed(void) {
    UIViewController *controller = [UIViewController new];
    controller.tableNode = [NSObject new];
    return controller;
}

static TestCellNode *Node(UIViewController *controller, NSUInteger row) {
    TestCellNode *node = [TestCellNode new];
    node.owningNode = controller.tableNode;
    NSUInteger indexes[] = {0, row};
    node.indexPath = [NSIndexPath indexPathWithIndexes:indexes length:2];
    return node;
}

static void PublishStickyInputs(UIViewController *controller, NSNumber *count, NSNumber *mask) {
    @synchronized(controller.tableNode) {
        objc_setAssociatedObject(controller.tableNode, &kApolloHLStickyCountKey, count, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller.tableNode, &kApolloHLFeedOwnedMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

int main(void) {
    @autoreleasepool {
        ApolloClassASTableNode = NSObject.class;
        UIViewController *searchGifs = Feed();
        ApolloHLPrepareDeDupForSubreddit(searchGifs, @"GIFs");
        Require(ApolloHLSeparatorShouldCollapse(Node(searchGifs, 1)), @"Search r/gifs de-duplicates its first separator");
        UIViewController *home = Feed();
        Require(!ApolloHLSeparatorShouldCollapse(Node(home, 1)), @"Home retains row 1 while Search is active");
        PublishStickyInputs(home, @3, @0);
        Require(!ApolloHLSeparatorShouldCollapse(Node(home, 1)), @"Home's cached count cannot confer ownership");

        UIViewController *controller = Feed();
        ApolloHLPrepareDeDupForSubreddit(controller, @"SubA");
        ApolloHLRecordHiddenStickyRow(Node(controller, 0));
        NSMutableSet *rows = objc_getAssociatedObject(controller.tableNode, &kApolloHLHiddenRowsKey);
        PublishStickyInputs(controller, @3, @5);
        Require(ApolloHLHideAndMarkCollapsed(@"suba"), @"A is actively de-duplicating");

        // Headers can prepare B before normal install; none of A's inputs survive.
        ApolloHLPrepareDeDupForSubreddit(controller, @"SubB");
        Require(!ApolloHLHideSubsContains(@"suba") && ApolloHLHideSubsContains(@"subb"), @"switch replaces exact membership");
        Require(!ApolloHLDidCollapseContains(@"suba") && rows.count == 0, @"switch clears A's hidden-row history");
        Require(objc_getAssociatedObject(controller.tableNode, &kApolloHLStickyCountKey) == nil &&
                objc_getAssociatedObject(controller.tableNode, &kApolloHLFeedOwnedMaskKey) == nil, @"switch clears A's count and mask");
        Require([objc_getAssociatedObject(controller.tableNode, &kApolloHLDeDupSubKey) isEqualToString:@"subb"] &&
                [objc_getAssociatedObject(controller, kApolloHLActiveSubKey) isEqualToString:@"subb"], @"both owners identify B");
        Require(ApolloHLSeparatorShouldCollapse(Node(controller, 1)) &&
                !ApolloHLSeparatorShouldCollapse(Node(controller, 3)), @"B uses its own cold separator policy");

        PublishStickyInputs(controller, @2, @1);
        ApolloHLPrepareDeDupForSubreddit(controller, @"SUBB");
        Require(!ApolloHLSeparatorShouldCollapse(Node(controller, 1)) &&
                ApolloHLSeparatorShouldCollapse(Node(controller, 3)), @"same-subreddit install preserves count and feed-owned mask");
        TestCellNode *stale = Node(controller, 3);
        objc_setAssociatedObject(stale, &kApolloHLSepCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sCommunityHighlights = NO;
        Require(!ApolloHLSeparatorShouldCollapse(stale), @"Highlights Off ignores the old reactive flag");
        sCommunityHighlights = YES;
        ApolloHLTeardown(controller, YES);
        Require(!ApolloHLHideSubsContains(@"subb") &&
                objc_getAssociatedObject(controller, kApolloHLActiveSubKey) == nil &&
                objc_getAssociatedObject(controller.tableNode, &kApolloHLDeDupSubKey) == nil, @"teardown clears B's ownership");
        Require(!ApolloHLSeparatorShouldCollapse(stale), @"teardown rejects a stale flag while Search remains active");
        Require(ApolloHLSeparatorShouldCollapse(Node(searchGifs, 1)), @"teardown preserves Search's policy");
        ApolloHLTeardown(searchGifs, YES);
        Require(ApolloHLHideSubsIsEmpty(), @"last teardown leaves no active membership");
        puts("community_highlights_separator_tests passed");
    }
    return 0;
}
