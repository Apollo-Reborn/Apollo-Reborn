#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface UIViewController : NSObject
@property (nonatomic, strong) id testTableNode;
@end
@implementation UIViewController
@end

static NSMutableSet<NSString *> *TestHideSubs(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static NSMutableSet<NSString *> *TestCollapsedSubs(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static id ApolloHLTypedIvar(id object, NSString *name, __unused Class expectedClass) {
    return [name isEqualToString:@"tableNode"] ? [(UIViewController *)object testTableNode] : nil;
}

static void ApolloHLHideSubsAdd(NSString *sub) { [TestHideSubs() addObject:sub]; }
static void ApolloHLHideSubsRemove(NSString *sub) { [TestHideSubs() removeObject:sub]; }
static void ApolloHLDidCollapseRemove(NSString *sub) { [TestCollapsedSubs() removeObject:sub]; }

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"CommunityHighlightsDeDupLifecycleFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

int main(void) {
    @autoreleasepool {
        UIViewController *controller = [UIViewController new];
        NSObject *tableNode = [NSObject new];
        controller.testTableNode = tableNode;

        ApolloHLPrepareDeDupForSubreddit(controller, @"SubA");
        Require([objc_getAssociatedObject(controller, kApolloHLActiveSubKey) isEqualToString:@"suba"],
                @"first prepare publishes normalized controller identity");
        Require([objc_getAssociatedObject(tableNode, &kApolloHLDeDupSubKey) isEqualToString:@"suba"],
                @"first prepare publishes normalized table identity");
        Require([TestHideSubs() containsObject:@"suba"], @"first prepare adds exact membership");

        NSMutableSet *rows = [NSMutableSet setWithObjects:@0, @2, nil];
        objc_setAssociatedObject(tableNode, &kApolloHLHiddenRowsKey, rows, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableNode, &kApolloHLStickyCountKey, @3, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableNode, &kApolloHLFeedOwnedMaskKey, @5, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [TestCollapsedSubs() addObject:@"suba"];

        // Models Headers-on A -> B reuse: the early header-substitute path calls
        // this before normal ApolloHLInstall. Every A-specific input must be gone
        // before B is published.
        ApolloHLPrepareDeDupForSubreddit(controller, @"SubB");
        Require(![TestHideSubs() containsObject:@"suba"] && [TestHideSubs() containsObject:@"subb"],
                @"switch removes old global membership before adding new");
        Require(![TestCollapsedSubs() containsObject:@"suba"],
                @"switch clears old did-collapse state");
        Require(rows.count == 0, @"switch empties table-local hidden rows");
        Require(objc_getAssociatedObject(tableNode, &kApolloHLStickyCountKey) == nil,
                @"switch clears cached sticky count");
        Require(objc_getAssociatedObject(tableNode, &kApolloHLFeedOwnedMaskKey) == nil,
                @"switch clears cached feed-owned mask");
        Require([objc_getAssociatedObject(tableNode, &kApolloHLDeDupSubKey) isEqualToString:@"subb"] &&
                [objc_getAssociatedObject(controller, kApolloHLActiveSubKey) isEqualToString:@"subb"],
                @"switch atomically publishes B identities");

        // Repeated layout/install passes for the same subreddit are idempotent
        // and must not discard the count that a REST fetch already published.
        objc_setAssociatedObject(tableNode, &kApolloHLStickyCountKey, @2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloHLPrepareDeDupForSubreddit(controller, @"SUBB");
        Require([objc_getAssociatedObject(tableNode, &kApolloHLStickyCountKey) isEqualToNumber:@2],
                @"same-subreddit prepare preserves current sticky inputs");

        puts("community_highlights_dedup_lifecycle_tests passed");
    }
    return 0;
}
