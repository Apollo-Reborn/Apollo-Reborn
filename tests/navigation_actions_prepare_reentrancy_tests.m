#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static char kActionsControllerKey;
static NSUInteger setterCalls;
static NSUInteger preparedCalls;

@interface ApolloNavigationActionsControllerBox : NSObject
@property (nonatomic, strong) id controller;
@end
@implementation ApolloNavigationActionsControllerBox
@end

@interface UINavigationItem : NSObject
@property (nonatomic, copy) NSArray *rightBarButtonItems;
- (void)setRightBarButtonItems:(NSArray *)items animated:(BOOL)animated;
@end

@interface ApolloNavigationActionsOwner : NSObject
- (void)prepareItems:(NSArray *)items;
@end

static void ApolloActionsPrepare(UINavigationItem *item, NSArray *items);
static BOOL IsLiquidGlass(void) { return YES; }
static BOOL ApolloActionsAppController(id controller) { return controller != nil; }
static BOOL ApolloDuoSplitSuppressesFeedActions(id controller) { return NO; }
static NSArray *ApolloActionsDuoNativeItems(UINavigationItem *item, NSArray *items) {
    // Model another hook replacing a bar item with a fresh native mirror on
    // every pass. Identity comparison can never make this converge by itself.
    return @[ [NSObject new] ];
}
static NSArray *ApolloActionsInboxItems(UINavigationItem *item, NSArray *items) { return items; }
static BOOL ApolloActionsArraysIdentical(NSArray *left, NSArray *right) {
    if (left.count != right.count) return NO;
    for (NSUInteger i = 0; i < left.count; i++) if (left[i] != right[i]) return NO;
    return YES;
}
static ApolloNavigationActionsOwner *ApolloActionsOwner(UINavigationItem *item, BOOL create) {
    static ApolloNavigationActionsOwner *owner;
    if (!owner) owner = [ApolloNavigationActionsOwner new];
    return owner;
}

@implementation UINavigationItem
- (void)setRightBarButtonItems:(NSArray *)items animated:(BOOL)animated {
    setterCalls++;
    if (setterCalls > 12) {
        @throw [NSException exceptionWithName:@"ReentrantSetterLimit"
                                       reason:@"navigation item setter did not converge"
                                     userInfo:nil];
    }
    _rightBarButtonItems = [items copy];
    ApolloActionsPrepare(self, items);
}
@end

@implementation ApolloNavigationActionsOwner
- (void)prepareItems:(NSArray *)items {
    if (items.count) preparedCalls++;
}
@end

// INCLUDE_PRODUCTION_APOLLO_ACTIONS_PREPARE

int main(void) {
    @autoreleasepool {
        UINavigationItem *item = [UINavigationItem new];
        ApolloNavigationActionsControllerBox *box = [ApolloNavigationActionsControllerBox new];
        box.controller = [NSObject new];
        objc_setAssociatedObject(item, &kActionsControllerKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            ApolloActionsPrepare(item, @[ [NSObject new] ]);
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL %s: setter calls=%lu, prepare calls=%lu\n",
                    exception.name.UTF8String, (unsigned long)setterCalls, (unsigned long)preparedCalls);
            return 1;
        }
        if (setterCalls != 1 || preparedCalls != 1 || item.rightBarButtonItems.count != 1) {
            fprintf(stderr, "FAIL setter calls=%lu, prepare calls=%lu\n",
                    (unsigned long)setterCalls, (unsigned long)preparedCalls);
            return 1;
        }
        printf("PASS setter calls=%lu, prepare calls=%lu\n",
               (unsigned long)setterCalls, (unsigned long)preparedCalls);
    }
    return 0;
}
