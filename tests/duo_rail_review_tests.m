#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#define CGSize NSSize
@interface TestView : NSObject
@property NSRect bounds;
@end
@implementation TestView @end
@interface UIViewController : NSObject
@property(strong) TestView *view;
@property(strong) id transitionCoordinator;
@property(strong) UIViewController *navigationController;
@end
@implementation UIViewController @end
@interface UINavigationItem : NSObject @end
@implementation UINavigationItem @end
@interface ControllerBox : NSObject
@property(weak) UIViewController *controller;
@end
@implementation ControllerBox @end
static char kActionsControllerKey;
static UIViewController *tabs;
static int mode;
static id ApolloMainTabBarController(void) { return tabs; }
static int ApolloDuoCurrentMode(void) { return mode; }
// INCLUDE_PRODUCTION_HELPERS
static unsigned checks;
static void Check(BOOL ok, NSString *message) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
int main(void) { @autoreleasepool {
    tabs = [UIViewController new]; tabs.view = [TestView new];
    mode = 1; tabs.view.bounds = NSMakeRect(0, 0, 466, 678);
    Check(ApolloActionsDuoRememberedTop() == -1, @"unseen cover is unmeasured");
    ApolloActionsDuoRememberTop(120);
    mode = 2; tabs.view.bounds = NSMakeRect(0, 0, 951, 692);
    Check(ApolloActionsDuoRememberedTop() == -1, @"inner display does not borrow cover top");
    ApolloActionsDuoRememberTop(80);
    mode = 1; tabs.view.bounds = NSMakeRect(0, 0, 466, 678);
    Check(ApolloActionsDuoRememberedTop() == 120, @"fold reuses settled cover top before scanning");
    ApolloActionsDuoRememberTop(200);
    mode = 2; tabs.view.bounds = NSMakeRect(0, 0, 951, 692);
    Check(ApolloActionsDuoRememberedTop() == 80, @"unfold retains its own settled top");
    tabs.view.bounds = NSMakeRect(0, 0, 692, 951);
    Check(ApolloActionsDuoRememberedTop() == -1, @"portrait does not borrow landscape top");
    mode = 1; tabs.view.bounds = NSMakeRect(0, 0, 466, 678);
    Check(ApolloActionsDuoRememberedTop() == 200, @"new settled system reservation updates the pose");
    mode = 2;
    Check(ApolloActionsDuoRememberedTop() == -1, @"transitional equal sizes cannot cross display modes");
    UIViewController *page = [UIViewController new], *nav = [UIViewController new];
    page.navigationController = nav;
    ControllerBox *box = [ControllerBox new]; box.controller = page;
    UINavigationItem *item = [UINavigationItem new];
    objc_setAssociatedObject(item, &kActionsControllerKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Check(!ApolloActionsDuoRailIsTransitioning(tabs, @[item]), @"settled page can be measured");
    nav.transitionCoordinator = [NSObject new];
    Check(ApolloActionsDuoRailIsTransitioning(tabs, @[item]), @"child push blocks scan even when tabs coordinator is nil");
    nav.transitionCoordinator = nil;
    Check(!ApolloActionsDuoRailIsTransitioning(tabs, @[item]), @"completed or cancelled transition allows settling");
    page.transitionCoordinator = [NSObject new];
    Check(ApolloActionsDuoRailIsTransitioning(tabs, @[item]), @"page transition blocks scan");
    page.transitionCoordinator = nil; tabs.transitionCoordinator = [NSObject new];
    Check(ApolloActionsDuoRailIsTransitioning(tabs, @[item]), @"tab transition blocks scan");
    tabs.transitionCoordinator = nil;
    Check(!ApolloActionsDuoRailIsTransitioning(tabs, @[[UINavigationItem new]]), @"missing owner is harmless");
    printf("Duo review regressions: %u checks passed\n", checks);
} }
