#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdbool.h>

// Platform rendering, catalog inputs and native storage are fixtures. Capture,
// context lifetime, slot preparation, native permutation and menu building are
// extracted unchanged from production, unlike the dispatch-only menu fixture.
typedef NSString *ApolloActionMenuContext;
@interface UIView : NSObject
@property (nonatomic, strong) id window;
@end
@implementation UIView
@end
@interface UIViewController : NSObject
@end
@implementation UIViewController
@end
@class UIImage, UIColor, UITableViewCell;
@interface UIMenuElement : NSObject
@end
@implementation UIMenuElement
@end
@interface UIAction : UIMenuElement
@property (nonatomic, copy) NSString *title;
@end
@implementation UIAction
@end
@interface UIMenu : UIMenuElement
@property (nonatomic, copy) NSArray *children;
+ (instancetype)menuWithTitle:(NSString *)title children:(NSArray *)children;
+ (instancetype)menuWithTitle:(NSString *)title image:(id)image identifier:(id)identifier options:(NSUInteger)options children:(NSArray *)children;
@end
@implementation UIMenu
+ (instancetype)menuWithTitle:(__unused NSString *)title children:(NSArray *)children {
    UIMenu *menu = [self new]; menu.children = children; return menu;
}
+ (instancetype)menuWithTitle:(NSString *)title image:(__unused id)image identifier:(__unused id)identifier options:(__unused NSUInteger)options children:(NSArray *)children {
    return [self menuWithTitle:title children:children];
}
@end
static const NSUInteger UIMenuOptionsDisplayInline = 1;
@interface FixtureActionController : NSObject {
@public
    void *actions;
    BOOL isShowingOnlyModeratorActions;
    BOOL actionsEnabled;
}
@end
@implementation FixtureActionController
- (instancetype)init {
    if ((self = [super init])) {
        actions = calloc(1, 0x20 + 3 * 0x30);
        *(int64_t *)((uint8_t *)actions + 0x10) = 3;
        for (uint16_t i = 0; i < 3; i++) *(uint16_t *)((uint8_t *)actions + 0x20 + i * 0x30) = i + 1;
        actionsEnabled = YES;
    }
    return self;
}
- (void)dealloc { free(actions); }
@end
static Class ApolloClassActionController;
static char kApolloNativeActionMenuSourceViewKey, kApolloNativeActionMenuModeratorSelectionKey;
static char kApolloActionMenuElementKindKey;
static UIViewController *sApolloNativeDirectActionOwner;
static UIView *sApolloNativeDirectActionSourceView;
static uint16_t sApolloNativeDirectActionKind;
#define ApolloLog(...) ((void)[NSString stringWithFormat:__VA_ARGS__])
#define ApolloLogError(...) ApolloLog(__VA_ARGS__)

static void *ApolloReadRawIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable([object class], name);
    return ivar ? *(void **)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar)) : NULL;
}
static BOOL ApolloReadBoolIvar(id object, const char *name, BOOL fallback) {
    Ivar ivar = class_getInstanceVariable([object class], name);
    return ivar ? *(BOOL *)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar)) : fallback;
}
static int64_t ApolloSwiftArrayCount(void *buffer) { return buffer ? *(int64_t *)((uint8_t *)buffer + 0x10) : 0; }
static NSString *ApolloReadSwiftStringIvar(__unused id object, __unused const char *name) { return @"Fixture"; }
static NSString *ApolloDecodeSwiftString(__unused uint64_t lo, __unused uint64_t hi) { return nil; }
static bool FixtureUnique(void *buffer) { return buffer != NULL; }
static void FixtureRelease(void *word) { NSCAssert(!word, @"fixture rows have zero Swift string words"); }
static void *FixtureDlsym(__unused void *handle, const char *name) {
    if (!strcmp(name, "swift_isUniquelyReferenced_nonNull_native")) return (void *)FixtureUnique;
    if (!strcmp(name, "swift_bridgeObjectRelease")) return (void *)FixtureRelease;
    return NULL;
}
static NSMutableDictionary *orders, *hiddenItems, *presentedItems;
static NSArray *ApolloActionMenuResolvedOrder(NSString *context) { return context ? orders[context] ?: @[] : @[]; }
static BOOL ApolloActionMenuHasCustomOrder(NSString *context) { return ApolloActionMenuResolvedOrder(context).count > 0; }
static NSSet *ApolloActionMenuHiddenItemIDs(NSString *context) { return context ? hiddenItems[context] ?: [NSSet set] : [NSSet set]; }
static NSString *ApolloActionMenuItemIDForKind(__unused NSString *context, uint16_t kind) { return [NSString stringWithFormat:@"%u", kind]; }
static NSString *ApolloActionMenuItemIDForSpec(NSString *identifier) { return [@"spec." stringByAppendingString:identifier]; }
static NSUInteger ApolloActionMenuRankForItemID(NSString *context, NSString *itemID) { return [ApolloActionMenuResolvedOrder(context) indexOfObject:itemID]; }
static BOOL ApolloActionMenuIsItemHidden(NSString *context, NSString *itemID) { return [ApolloActionMenuHiddenItemIDs(context) containsObject:itemID]; }
static void ApolloActionMenuRecordPresentedItemIDs(NSString *context, NSArray *items) { presentedItems[context] = [items copy]; }
static BOOL IsLiquidGlass(void) { return YES; }
@interface ApolloActionMenuSpec : NSObject
@property (nonatomic, copy) BOOL (^matches)(id, NSString *);
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) NSInteger order;
@property (nonatomic) NSInteger placement;
@end
@implementation ApolloActionMenuSpec
@end
static NSArray<ApolloActionMenuSpec *> *sApolloActionMenuRegistry;
static const NSInteger ApolloActionMenuPlacementAfterLeadingSubmitAffordance = 1;
static NSString *ApolloActionMenuTitleForController(__unused id controller) { return @"Fixture"; }

// INCLUDE_PRODUCTION_CONTEXT_AND_PREPARATION

static void ApolloNativeActionMenuSelectRow(__unused id controller, __unused NSInteger row) {}
static UIColor *ApolloModeratorColor(void) { return nil; }
static NSArray *ApolloNativeActionMenuBuildModeratorReportSections(__unused id controller) { return nil; }
static NSString *ApolloNativeActionDefaultTitle(uint16_t kind) { return [NSString stringWithFormat:@"%u", kind]; }
static UIImage *ApolloNativeActionDefaultImage(__unused uint16_t kind) { return nil; }
static BOOL ApolloNativeActionKindOpensModeratorMenu(uint16_t kind) { return kind == 3; }
static BOOL ApolloNativeActionMenuTitleIsDestructive(__unused NSString *title) { return NO; }
static UIAction *ApolloNativeActionMenuAction(NSString *title, __unused NSString *subtitle, __unused UIImage *image,
        __unused UIColor *tint, __unused BOOL opensModerator, __unused BOOL destructive, __unused BOOL checked,
        __unused BOOL enabled, __unused id controller, __unused NSInteger row) {
    UIAction *action = [UIAction new]; action.title = title; return action;
}
static UIMenu *ApolloSubmitPostTypesMenu(__unused id controller, __unused dispatch_block_t completion) { return nil; }
static void ApolloActionMenuInjectMenuElements(__unused NSMutableArray *children, __unused NSString *title, __unused id controller) {}

// INCLUDE_PRODUCTION_CAPTURE_AND_BUILD

static unsigned checks;
static void Check(BOOL condition, const char *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static id CaptureMore(UIView *source, FixtureActionController *controller, NSString *context) {
    return ApolloNativeActionMenuCaptureController(source, ^{
        ApolloActionMenuArmContext(context);
        @try { Check(ApolloNativeActionMenuPerformPendingDirectAction(controller), "native presentation is intercepted by the real capture path"); }
        @finally { ApolloActionMenuDisarmContext(); }
    });
}
int main(void) {
    @autoreleasepool {
        ApolloClassActionController = FixtureActionController.class;
        orders = [NSMutableDictionary dictionary]; hiddenItems = [NSMutableDictionary dictionary];
        presentedItems = [NSMutableDictionary dictionary]; sApolloActionMenuRegistry = @[];
        UIView *source = [UIView new]; source.window = [NSObject new];
        for (NSString *context in @[ApolloActionMenuContextFeed, ApolloActionMenuContextPost,
                                   ApolloActionMenuContextPostDetail, ApolloActionMenuContextComment]) {
            orders[context] = @[@"3", @"1", @"2"]; hiddenItems[context] = [NSSet setWithObject:@"2"];
            FixtureActionController *native = [FixtureActionController new];
            id captured = CaptureMore(source, native, context);
            Check(captured == native, "capture retains the originating native controller");
            Check(ApolloActionMenuTakeArmedContext() == nil, "More callback finally has cleared the transient context before building");
            UIMenu *menu = ApolloNativeActionMenuBuildCaptured(captured);
            Check([[menu.children valueForKey:@"title"] isEqual:@[@"3", @"1"]],
                  "deferred native build must preserve saved ordering and hidden rows after callback disarms");
            Check([objc_getAssociatedObject(captured, &kApolloActionMenuControllerContextKey) isEqual:context],
                  "captured native menu retains its own customization context");
            Check(ApolloSwiftArrayCount(native->actions) == 2, "the real native permutation removes the hidden row");
            Check([presentedItems[context] isEqual:@[@"1", @"2", @"3"]], "preparation records original native items before customization");
            Check([ApolloNativeActionMenuBuildCaptured(captured).children count] == 2, "deferred preparation is idempotent");
            Check(objc_getAssociatedObject(captured, &kApolloNativeActionMenuSourceViewKey) == source, "captured actions retain their source anchor");

            NSString *moderator = ApolloActionMenuModeratorContextFollowing(context);
            if (!moderator) continue;
            orders[moderator] = @[@"2", @"3", @"1"]; hiddenItems[moderator] = [NSSet setWithObject:@"1"];
            ApolloActionMenuArmModeratorFollowUp(captured);
            FixtureActionController *followUp = [FixtureActionController new]; followUp->isShowingOnlyModeratorActions = YES;
            id capturedFollowUp = ApolloNativeActionMenuCaptureController(source, ^{
                @try { Check(ApolloNativeActionMenuPerformPendingDirectAction(followUp), "moderator follow-up presentation is captured"); }
                @finally { ApolloActionMenuDisarmContext(); }
            });
            UIMenu *followUpMenu = ApolloNativeActionMenuBuildCaptured(capturedFollowUp);
            Check([objc_getAssociatedObject(followUp, &kApolloActionMenuControllerContextKey) isEqual:moderator], "moderator follow-up retains the corresponding context");
            Check([[followUpMenu.children valueForKey:@"title"] isEqual:@[@"2", @"3"]], "moderator follow-up applies its own saved layout after disarm");
        }
        FixtureActionController *unscoped = [FixtureActionController new];
        id captured = ApolloNativeActionMenuCaptureController(source, ^{ ApolloNativeActionMenuPerformPendingDirectAction(unscoped); });
        Check([[ApolloNativeActionMenuBuildCaptured(captured).children valueForKey:@"title"] isEqual:@[@"1", @"2", @"3"]], "an unrelated capture does not inherit the preceding menu context");
        FixtureActionController *normal = [FixtureActionController new];
        ApolloActionMenuArmContext(ApolloActionMenuContextPostDetail);
        ApolloActionMenuCaptureContextForController(normal);
        ApolloActionMenuDisarmContext();
        Check([[ApolloNativeActionMenuBuildCaptured(normal).children valueForKey:@"title"] isEqual:@[@"3", @"1"]], "ordinary presentation retains its existing customization behavior");
        Check(!sApolloNativeCapturingController, "capture guard is balanced after all calls");
        printf("PASS: %u native capture/context/build checks\n", checks);
    }
}
