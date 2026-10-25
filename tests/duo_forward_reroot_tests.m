#import <Foundation/Foundation.h>

// Apollo's navigation controller, reduced to what the split's forward
// bookkeeping reads: its stack, its queued forward pages, and the native wipe.
@interface UIViewController : NSObject @end
@implementation UIViewController @end
@interface UINavigationController : UIViewController
@property(nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property(nonatomic, strong) NSMutableArray<UIViewController *> *popped;
@property(nonatomic) NSUInteger wipes;
- (UIViewController *)topViewController;
- (void)didReceiveMemoryWarning;
@end
@implementation UINavigationController
- (UIViewController *)topViewController { return self.viewControllers.lastObject; }
- (void)didReceiveMemoryWarning { self.wipes++; [self.popped removeAllObjects]; }
@end
static UIViewController *ApolloDuoSplitForwardPage(UINavigationController *nav) { return nav.popped.firstObject; }
#define ApolloLog(...) ((void)0)
// INCLUDE_PRODUCTION_FORWARD_HELPERS
static NSUInteger checks;
static void Check(BOOL valid, NSString *message) {
    checks++;
    if (!valid) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static UINavigationController *Navigation(NSArray *pages, NSArray *forward) {
    UINavigationController *nav = [UINavigationController new];
    nav.viewControllers = pages;
    nav.popped = [forward mutableCopy];
    return nav;
}
int main(void) {
    @autoreleasepool {
        UIViewController *home = [UIViewController new], *old = [UIViewController new], *picked = [UIViewController new];
        Check(ApolloDuoSplitStackMovesForward(@[home], @[picked]), @"replacing the feed root with a new subreddit moves forward");
        Check(ApolloDuoSplitStackMovesForward(@[home], @[home, picked]), @"a new page on top moves forward");
        Check(!ApolloDuoSplitStackMovesForward(@[home, old], @[home]), @"returning to a page already in the stack is a Back");
        Check(!ApolloDuoSplitStackMovesForward(@[home], @[home]), @"an unchanged stack does not move");
        Check(!ApolloDuoSplitStackMovesForward(@[home], @[]), @"an emptied stack does not move forward");
        Check(ApolloDuoSplitStackMovesForward(@[[UIViewController new]], @[[UIViewController new]]),
              @"identity, not equality, decides (a fresh instance of the same subreddit is new)");

        // The reported case: a Back queued r/X, then r/X was picked again
        // from the list. The old r/X must not come back on a left swipe.
        UINavigationController *feed = Navigation(@[home], @[old]);
        NSArray *before = feed.viewControllers;
        feed.viewControllers = @[picked];
        ApolloDuoSplitForgetForward(feed, before);
        Check(feed.wipes == 1 && !ApolloDuoSplitForwardPage(feed), @"a list pick forgets the forward page");

        // A Back by the split itself keeps what a user Back queued.
        feed = Navigation(@[home, picked], @[old]);
        before = feed.viewControllers;
        feed.viewControllers = @[home];
        ApolloDuoSplitForgetForward(feed, before);
        Check(feed.wipes == 0 && ApolloDuoSplitForwardPage(feed) == old, @"a Back re-root keeps the forward page");

        // Nothing queued: no native call at all.
        feed = Navigation(@[home], @[]);
        before = feed.viewControllers;
        feed.viewControllers = @[picked];
        ApolloDuoSplitForgetForward(feed, before);
        Check(feed.wipes == 0, @"an empty forward stack is left alone");

        // Without a before-stack the caller has already decided (a thread
        // opening beside the feed, or a reselection's popToRoot).
        UINavigationController *other = Navigation(@[home], @[old]);
        ApolloDuoSplitForgetForward(other, nil);
        Check(other.wipes == 1 && !ApolloDuoSplitForwardPage(other), @"an explicit forget wipes unconditionally");
        printf("OK: %lu checks\n", (unsigned long)checks);
    }
    return 0;
}
