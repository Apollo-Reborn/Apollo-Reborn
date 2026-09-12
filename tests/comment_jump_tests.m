#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <math.h>

typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
@interface UIScrollView : NSObject
@property CGRect bounds;
@property UIEdgeInsets contentInset;
@property UIEdgeInsets adjustedContentInset;
@end
@implementation UIScrollView
@end
@interface ASTableView : UIScrollView
@property CGFloat rowHeight;
@property CGPoint lastProbe;
- (NSIndexPath *)indexPathForRowAtPoint:(CGPoint)point;
@end
@implementation ASTableView
- (NSIndexPath *)indexPathForRowAtPoint:(CGPoint)point {
    self.lastProbe = point;
    if (point.y < 0) return nil;
    return [NSIndexPath indexPathWithIndex:(NSUInteger)floor(point.y / self.rowHeight)];
}
@end
@interface UIViewController : NSObject
@property ASTableView *table;
@property BOOL eligible;
@end
@implementation UIViewController
@end
@interface _TtC6Apollo22CommentsViewController : UIViewController
@property void (^duringJump)(void);
@property BOOL failJump;
@property NSInteger destination;
- (void)commentJumpButtonTappedWithSender:(id)sender;
- (void)commentJumpButtonLongPressedWithSender:(id)sender;
@end
@implementation _TtC6Apollo22CommentsViewController
- (void)jump:(NSInteger)direction {
    if (self.duringJump) self.duringJump();
    if (self.failJump) [NSException raise:@"JumpTest" format:@"test cleanup"];
    // Model the recovered native probe and UIKit's adjusted-inset landing.
    CGPoint probe = CGPointMake(0, self.table.bounds.origin.y + self.table.contentInset.top + 1);
    NSIndexPath *path = [self.table indexPathForRowAtPoint:probe];
    NSInteger current = path ? (NSInteger)[path indexAtPosition:0] : 0;
    self.destination = MAX(1, current + direction);
    CGRect bounds = self.table.bounds;
    bounds.origin.y = self.destination * self.table.rowHeight - self.table.adjustedContentInset.top;
    self.table.bounds = bounds;
}
- (void)commentJumpButtonTappedWithSender:(id)sender { (void)sender; [self jump:1]; }
- (void)commentJumpButtonLongPressedWithSender:(id)sender { (void)sender; [self jump:-1]; }
@end
static BOOL enabled = YES;
static char managedKey;
static const void *kNSBFeedTableKey = &managedKey;
static BOOL ApolloNativeFeedSearchEnabled(void) { return enabled; }
static BOOL NSBIsNativeSearchCommentsVC(UIViewController *vc) { return vc.eligible; }
static UIScrollView *NSBTableForVC(UIViewController *vc) { return vc.table; }
static BOOL NSBTraceEnabled(void) { return NO; }
#define ApolloLog(...) do {} while (0)

// PRODUCTION_HOOKS

void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}
static int checks;
static void Check(BOOL result, NSString *message) {
    checks++;
    if (!result) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static _TtC6Apollo22CommentsViewController *Fixture(CGFloat height, CGFloat inset) {
    _TtC6Apollo22CommentsViewController *vc = [_TtC6Apollo22CommentsViewController new];
    vc.eligible = YES;
    vc.table = [ASTableView new];
    vc.table.rowHeight = height;
    vc.table.bounds = CGRectMake(0, -inset, 400, 800);
    vc.table.adjustedContentInset = (UIEdgeInsets){inset, 0, 34, 0};
    objc_setAssociatedObject(vc.table, kNSBFeedTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return vc;
}
int main(void) {
    @autoreleasepool {
        InstallJumpHooks();
        for (NSNumber *height in @[@32, @80, @300]) {
            for (NSNumber *inset in @[@0, @62, @106, @176]) {
                _TtC6Apollo22CommentsViewController *vc = Fixture(height.doubleValue, inset.doubleValue);
                for (NSInteger parent = 1; parent <= 8; parent++) {
                    [vc commentJumpButtonTappedWithSender:nil];
                    Check(vc.destination == parent, @"repeated taps advance without manual scrolling");
                    Check(vc.table.contentInset.top == 0, @"raw insets remain untouched");
                }
                for (NSInteger parent = 7; parent >= 1; parent--) {
                    [vc commentJumpButtonLongPressedWithSender:nil];
                    Check(vc.destination == parent, @"long press returns to previous parent");
                }
                CGPoint point = CGPointMake(0, vc.table.bounds.origin.y + 1);
                [vc.table indexPathForRowAtPoint:point];
                Check(CGPointEqualToPoint(vc.table.lastProbe, point), @"ordinary lookup outside handler is untouched");
            }
        }
        _TtC6Apollo22CommentsViewController *vc = Fixture(80, 106);
        enabled = NO;
        [vc commentJumpButtonTappedWithSender:nil];
        [vc commentJumpButtonTappedWithSender:nil];
        Check(vc.destination == 1, @"unpatched calculation reproduces stuck first jump");
        enabled = YES;
        [vc commentJumpButtonTappedWithSender:nil];
        Check(vc.destination == 2, @"correction advances from reproduced failure");
        vc.table.adjustedContentInset = (UIEdgeInsets){176, 0, 34, 0};
        vc.table.bounds = CGRectMake(0, 160 - 176, 400, 800);
        [vc commentJumpButtonTappedWithSender:nil];
        Check(vc.destination == 3, @"uses current inset after search bar expands");
        ASTableView *other = Fixture(80, 106).table;
        vc.duringJump = ^{
            CGPoint unrelated = CGPointMake(0, other.bounds.origin.y + 1);
            [other indexPathForRowAtPoint:unrelated];
            Check(CGPointEqualToPoint(other.lastProbe, unrelated), @"other table inside handler is untouched");
        };
        [vc commentJumpButtonTappedWithSender:nil];
        Check(vc.destination == 4, @"other-table lookup does not consume scope");
        vc.duringJump = nil;
        vc.failJump = YES;
        @try { [vc commentJumpButtonTappedWithSender:nil]; } @catch (NSException *exception) { (void)exception; }
        Check(sNSBCommentJumpTable == NULL, @"exception restores scope");
        vc.failJump = NO;
        _TtC6Apollo22CommentsViewController *nested = Fixture(32, 176);
        vc.duringJump = ^{ [nested commentJumpButtonTappedWithSender:nil]; };
        [vc commentJumpButtonTappedWithSender:nil];
        Check(vc.destination == 5 && nested.destination == 1, @"nested jump restores outer table scope");
        vc.duringJump = nil;
        vc.eligible = NO;
        [vc commentJumpButtonTappedWithSender:nil];
        Check(vc.table.lastProbe.y == 5 * 80 - 176 + 1, @"pane/preview eligibility bypasses correction");
        vc.eligible = YES;
        objc_setAssociatedObject(vc.table, kNSBFeedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFloat before = vc.table.bounds.origin.y + 1;
        [vc commentJumpButtonTappedWithSender:nil];
        Check(vc.table.lastProbe.y == before, @"unmanaged table bypasses correction");
        _TtC6Apollo22CommentsViewController *residual = Fixture(80, 140);
        residual.table.contentInset = (UIEdgeInsets){24, 0, 0, 0};
        for (NSInteger parent = 1; parent <= 3; parent++) {
            [residual commentJumpButtonTappedWithSender:nil];
            Check(residual.destination == parent, @"nonzero raw inset is replaced, not added twice");
        }
        ASTableView *sameTable = residual.table;
        residual.duringJump = ^{
            CGPoint p = CGPointMake(12, sameTable.bounds.origin.y + sameTable.contentInset.top + 1);
            [sameTable indexPathForRowAtPoint:p];
            Check(CGPointEqualToPoint(sameTable.lastProbe, p), @"other x coordinate is untouched");
            p = CGPointMake(0, p.y + 20);
            [sameTable indexPathForRowAtPoint:p];
            Check(CGPointEqualToPoint(sameTable.lastProbe, p), @"other y coordinate is untouched");
        };
        [residual commentJumpButtonTappedWithSender:nil];
        Check(residual.destination == 4, @"unrelated lookups do not consume current-comment probe");
        residual.duringJump = nil;
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block BOOL backgroundScoped = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            backgroundScoped = NSBCommentJumpTableForController(residual) != NULL;
            dispatch_semaphore_signal(finished);
        });
        dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
        Check(!backgroundScoped, @"background work never enters jump scope");
        printf("PASS: %d comment jump checks\n", checks);
    }
    return 0;
}
