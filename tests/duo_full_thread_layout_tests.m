#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// Only UIKit's responder/coordinate plumbing is doubled. The complete shipping
// frame helper is extracted by the runner; no second layout policy lives here.
@interface UIResponder : NSObject
@property(nonatomic, strong) UIResponder *nextResponder;
@end
@implementation UIResponder @end
@interface UILayoutGuide : NSObject
@property(nonatomic) CGRect layoutFrame;
@end
@implementation UILayoutGuide @end
@interface UIView : UIResponder
@property(nonatomic, strong) UILayoutGuide *safeAreaLayoutGuide;
@property(nonatomic) CGPoint coordinateOrigin;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
@end
@implementation UIView
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view {
    return CGRectOffset(rect, self.coordinateOrigin.x - view.coordinateOrigin.x,
                        self.coordinateOrigin.y - view.coordinateOrigin.y);
}
@end
@interface UIViewController : UIResponder
@property(nonatomic, strong) UIView *view;
@property(nonatomic, strong) id fullThreadNode;
- (BOOL)isViewLoaded;
@end
@implementation UIViewController
- (BOOL)isViewLoaded { return self.view != nil; }
@end
@interface ASDisplayNode : NSObject
@property(nonatomic, strong) ASDisplayNode *supernode;
@property(nonatomic, strong) UIView *view;
@property(nonatomic) BOOL isNodeLoaded;
@end
@implementation ASDisplayNode @end
static BOOL duo = YES, rail = YES;
static Class ApolloClassCommentsViewController;
static BOOL ApolloDeviceIsDuo(void) { return duo; }
static BOOL ApolloDuoRailHasVisibleSideBar(void) { return rail; }
static id ApolloObjectIvar(UIViewController *vc, __unused const char *name) { return vc.fullThreadNode; }
// INCLUDE_PRODUCTION_FRAME_HELPER
static unsigned checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
int main(void) {
    @autoreleasepool {
        ApolloClassCommentsViewController = UIViewController.class;
        UIViewController *comments = [UIViewController new];
        comments.view = [UIView new];
        comments.view.nextResponder = comments;
        comments.view.safeAreaLayoutGuide = [UILayoutGuide new];
        ASDisplayNode *root = [ASDisplayNode new];
        root.view = comments.view; root.isNodeLoaded = YES;
        ASDisplayNode *node = [ASDisplayNode new]; node.supernode = root;
        comments.fullThreadNode = node;
        CGRect native = CGRectMake(650, 900 - 900 - 55 - 10, 528, 55);
        Check(CGRectGetMaxY(native) < 0, @"native tab-bar-height calculation puts the whole control above the screen");
        comments.view.safeAreaLayoutGuide.layoutFrame = CGRectMake(640, 110, 528, 790);
        CGRect result = ApolloDuoFullThreadFrame(node, native);
        Check(CGRectEqualToRect(result, CGRectMake(650, 835, 508, 55)), @"right pane pins full-thread control above its bottom, clear of rail");
        Check(CGRectContainsRect(comments.view.safeAreaLayoutGuide.layoutFrame, result), @"entire control and hit area lie inside visible pane");
        Check(CGRectEqualToRect(ApolloDuoFullThreadFrame(node, result), result), @"repeated native layout is stable");
        comments.view.safeAreaLayoutGuide.layoutFrame = CGRectMake(0, 110, 1168, 756);
        result = ApolloDuoFullThreadFrame(node, native);
        Check(CGRectEqualToRect(result, CGRectMake(10, 801, 1148, 55)), @"full-width unfolded pane respects bottom safe area");
        comments.view.safeAreaLayoutGuide.layoutFrame = CGRectMake(0, 64, 306, 780);
        result = ApolloDuoFullThreadFrame(node, native);
        Check(CGRectEqualToRect(result, CGRectMake(10, 779, 286, 55)), @"closed Duo rail leaves readable control inside narrow content");
        native.size.height = 72;
        result = ApolloDuoFullThreadFrame(node, native);
        Check(result.size.height == 72 && CGRectGetMaxY(result) == 834, @"preserves native control height");
        UIView *parent = [UIView new]; parent.nextResponder = comments.view;
        parent.coordinateOrigin = CGPointMake(-120, -500); root.view = parent;
        result = ApolloDuoFullThreadFrame(node, native);
        Check(CGRectEqualToRect(result, CGRectMake(130, 1262, 286, 72)), @"nested/scrolled parent uses converted coordinates");
        root.view = comments.view;
        rail = NO;
        Check(CGRectEqualToRect(ApolloDuoFullThreadFrame(node, native), native), @"bottom tab bar keeps native geometry");
        rail = YES; duo = NO;
        Check(CGRectEqualToRect(ApolloDuoFullThreadFrame(node, native), native), @"ordinary iPhone remains unchanged");
        duo = YES; root.isNodeLoaded = NO;
        Check(CGRectEqualToRect(ApolloDuoFullThreadFrame(node, native), native), @"does not load an offscreen Texture node");
        root.isNodeLoaded = YES; comments.fullThreadNode = nil;
        Check(CGRectEqualToRect(ApolloDuoFullThreadFrame(node, native), native), @"only controller-owned full-thread node is adjusted");
        comments.fullThreadNode = node; node.supernode = nil;
        Check(CGRectEqualToRect(ApolloDuoFullThreadFrame(node, native), native), @"unattached node remains native");
        node.supernode = root;
        for (NSValue *value in @[[NSValue valueWithBytes:&(CGRect){0} objCType:@encode(CGRect)],
                                 [NSValue valueWithBytes:&(CGRect){.origin={INFINITY,INFINITY}} objCType:@encode(CGRect)]]) {
            CGRect pane; [value getValue:&pane size:sizeof(pane)];
            comments.view.safeAreaLayoutGuide.layoutFrame = pane;
            Check(CGRectEqualToRect(ApolloDuoFullThreadFrame(node, native), native), @"unsettled/empty pane is not repositioned");
        }
        comments.view.safeAreaLayoutGuide.layoutFrame = CGRectMake(0, 64, 300, 40);
        Check(CGRectEqualToRect(ApolloDuoFullThreadFrame(node, native), native), @"insufficient vertical room leaves native sizing intact");
        comments.view.safeAreaLayoutGuide.layoutFrame = CGRectMake(0, 64, 300, 800);
        native.size.height = NAN;
        Check(isnan(ApolloDuoFullThreadFrame(node, native).size.height), @"invalid native height is passed through");
        printf("OK: %u checks\n", checks);
        // Break responder cycles in these doubles before sanitizer teardown.
        comments.view.nextResponder = nil;
    }
    return 0;
}
