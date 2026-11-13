#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Stand-ins for the UIKit responder chain, just enough for the lookup.
@interface UIResponder : NSObject
@property(nonatomic, unsafe_unretained) UIResponder *next;
- (UIResponder *)nextResponder;
@end
@implementation UIResponder
- (UIResponder *)nextResponder { return self.next; }
@end
@interface UIView : UIResponder
@end
@implementation UIView
@end
@interface UIViewController : UIResponder
@property(nonatomic, strong) UIView *view;
@end

// PRODUCTION_SOURCE

static int gFailures;
static BOOL gDeallocLookupWasNil;
static BOOL gDeallocLookupRan;

#define CHECK(cond, name) do { \
    if (cond) printf("ok: %s\n", name); \
    else { printf("FAIL: %s\n", name); gFailures++; } \
} while (0)

@implementation UIViewController
- (void)dealloc {
    // Texture's last batch update reaches the reveal check while the screen is
    // torn down: the lookup runs from the screen's own view, and the caller
    // then takes a weak reference to whatever it returns.
    UIViewController *found = NSBFeedVCForView(self.view);
    gDeallocLookupRan = YES;
    gDeallocLookupWasNil = (found == nil);
    __weak UIViewController *weak = found;
    (void)weak;
}
@end

// A screen that cannot report its teardown state is treated as live.
@interface OpaqueViewController : UIViewController
@end
@implementation OpaqueViewController
- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(_isDeallocating)) return NO;
    return [super respondsToSelector:selector];
}
@end

int main(void) {
    @autoreleasepool {
        UIViewController *live = [UIViewController new];
        live.view = [UIView new];
        live.view.next = live;
        UIView *cell = [UIView new];
        cell.next = live.view;
        CHECK(NSBFeedVCForView(cell) == live, "live screen is found through a non-controller responder");
        CHECK(NSBFeedVCForView(live.view) == live, "live screen is found from its own view");
        live.view.next = nil;

        OpaqueViewController *opaque = [OpaqueViewController new];
        opaque.view = [UIView new];
        opaque.view.next = opaque;
        CHECK(NSBFeedVCForView(opaque.view) == opaque, "screen without _isDeallocating is treated as live");
        opaque.view.next = nil;

        @autoreleasepool {
            UIViewController *dying = [UIViewController new];
            dying.view = [UIView new];
            dying.view.next = dying;
            dying = nil;
        }
        CHECK(gDeallocLookupRan, "deallocating screen ran its lookup");
        CHECK(gDeallocLookupWasNil, "deallocating screen is not returned, so no weak reference is formed to it");
    }
    return gFailures ? 1 : 0;
}
