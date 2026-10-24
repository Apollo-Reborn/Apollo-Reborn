#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
static UIEdgeInsets UIEdgeInsetsMake(CGFloat top, CGFloat left, CGFloat bottom, CGFloat right) {
    return (UIEdgeInsets){top, left, bottom, right};
}
__attribute__((unused)) static CGRect UIEdgeInsetsInsetRect(CGRect rect, UIEdgeInsets insets) {
    return CGRectMake(rect.origin.x + insets.left, rect.origin.y + insets.top,
        rect.size.width - insets.left - insets.right, rect.size.height - insets.top - insets.bottom);
}

@interface UIView : NSObject
@property (nonatomic, weak) id window;
@property (nonatomic) BOOL hidden;
@property (nonatomic) CGFloat alpha;
@property (nonatomic) CGRect bounds;
@property (nonatomic) CGRect frame;
@property (nonatomic) UIEdgeInsets safeAreaInsets;
@property (nonatomic, weak) UIView *superview;
- (CGRect)convertRect:(CGRect)rect toView:(id)view;
@end
@implementation UIView
- (instancetype)init { if ((self = [super init])) _alpha = 1; return self; }
- (CGRect)convertRect:(CGRect)rect toView:(__unused id)view {
    return CGRectOffset(rect, self.frame.origin.x - self.bounds.origin.x, self.frame.origin.y - self.bounds.origin.y);
}
@end
@interface UIViewController : NSObject
@property (nonatomic, strong) UIView *viewIfLoaded;
@property (nonatomic, copy) NSArray *childViewControllers;
@end
@implementation UIViewController
@end
@interface UINavigationController : UIViewController
@property (nonatomic, strong) UIView *navigationBar;
@end
@implementation UINavigationController
@end
@interface UITabBarController : UIViewController
@property (nonatomic, strong) UIView *tabBar;
@property (nonatomic, strong) UIViewController *selectedViewController;
@end
@implementation UITabBarController
@end
@interface UIWindow : UIView
@property (nonatomic, strong) UIViewController *rootViewController;
@end
@implementation UIWindow
@end

// INCLUDE_PRODUCTION_VISIBILITY

static unsigned checks;
static void Check(BOOL condition, const char *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static UIView *View(UIWindow *window, CGRect frame) {
    UIView *view = [UIView new]; view.window = window; view.frame = frame; view.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height); return view;
}
static UINavigationController *Navigation(UIWindow *window, CGRect bar) {
    UINavigationController *nav = [UINavigationController new];
    nav.viewIfLoaded = View(window, window.bounds); nav.navigationBar = View(window, bar); return nav;
}
int main(void) {
    @autoreleasepool {
        UIWindow *window = [UIWindow new]; window.bounds = CGRectMake(0, 0, 1000, 700);
        UITabBarController *tabs = [UITabBarController new]; window.rootViewController = tabs;
        tabs.tabBar = View(window, CGRectMake(930, 0, 70, 700));
        UINavigationController *outer = Navigation(window, CGRectMake(0, 0, 930, 100));
        outer.navigationBar.hidden = YES; tabs.selectedViewController = outer;
        UIViewController *host = [UIViewController new]; host.viewIfLoaded = View(window, window.bounds);
        UINavigationController *feed = Navigation(window, CGRectMake(0, 0, 465, 80));
        UINavigationController *comments = Navigation(window, CGRectMake(465, 0, 465, 120));
        outer.childViewControllers = @[host]; host.childViewControllers = @[feed, comments];
        Check(!ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 60)), "split feed midpoint behind its visible column bar is rejected");
        Check(!ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 100)), "split comments midpoint behind its own bar is rejected");
        comments.navigationBar.frame = CGRectMake(0, 0, 1000, 120);
        comments.navigationBar.bounds = CGRectMake(0, 0, 1000, 120);
        comments.viewIfLoaded.safeAreaInsets = UIEdgeInsetsMake(0, 465, 0, 70);
        Check(!ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 100)), "inset secondary bar still occludes its own pane");
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 100)), "a taller overlapping secondary bar cannot occlude the feed column");
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 150)), "visible comments midpoint is accepted");
        Check(!ApolloVideoPointIsVisibleInWindow(window, CGPointMake(960, 300)), "side rail occludes its own horizontal span");
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 650)), "side rail does not subtract the entire window height");
        Check(!ApolloVideoPointIsVisibleInWindow(window, CGPointMake(-1, 200)), "points outside the window are rejected");
        Check(!ApolloVideoPointIsVisibleInWindow(nil, CGPointZero), "missing window is rejected");
        comments.navigationBar.hidden = YES;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 60)), "hidden column bar creates no phantom cutoff");
        comments.navigationBar.hidden = NO;
        UIView *plainWrapper = View(window, window.bounds); comments.navigationBar.superview = plainWrapper;
        plainWrapper.hidden = YES;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 60)), "hidden plain-view bar ancestors create no phantom cutoff");
        plainWrapper.hidden = NO; plainWrapper.alpha = 0;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 60)), "transparent plain-view bar ancestors create no phantom cutoff");
        plainWrapper.alpha = 1;
        comments.viewIfLoaded.hidden = YES;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 60)), "hidden content column is ignored");
        comments.viewIfLoaded.hidden = NO; comments.viewIfLoaded.alpha = 0;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 60)), "transparent content column is ignored");
        comments.viewIfLoaded.alpha = 1; host.viewIfLoaded.hidden = YES;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 60)), "hidden containment ancestors exclude their descendant bars");
        host.viewIfLoaded.hidden = NO; NSObject *otherWindow = [NSObject new]; comments.navigationBar.window = otherWindow;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(600, 60)), "bar in a different window cannot occlude content");
        outer.childViewControllers = @[]; outer.navigationBar.hidden = NO;
        tabs.tabBar.frame = CGRectMake(0, 650, 1000, 50); tabs.tabBar.bounds = CGRectMake(0, 0, 1000, 50);
        Check(!ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 60)), "ordinary phone navigation bar retains its top cutoff");
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 300)), "ordinary phone visible midpoint is accepted");
        Check(!ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 670)), "ordinary phone bottom bar occludes content");
        tabs.tabBar.hidden = YES;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 670)), "hidden bottom bar has no phantom occlusion");
        tabs.selectedViewController = nil;
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 60)), "empty selected tab is safe");
        window.rootViewController = [UIViewController new];
        Check(ApolloVideoPointIsVisibleInWindow(window, CGPointMake(200, 60)), "non-tab roots retain window-only visibility");
        printf("PASS: %u video visibility checks\n", checks);
    }
}
