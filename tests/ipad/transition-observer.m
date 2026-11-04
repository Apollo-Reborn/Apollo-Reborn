#import "../../src/ipad/ApolloPaneTransitionObserver.h"
#import <assert.h>
static void pump(NSTimeInterval seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
int main(void) { @autoreleasepool {
    NSObject *owner = [NSObject new];
    __block NSUInteger calls = 0;
    __block BOOL ready = NO;
    [ApolloPaneTransitionObserver observeOwner:owner key:@"route" timeout:1
        ready:^BOOL(id object) { return ready; }
        completion:^(id object, BOOL expired) { assert(!expired); calls++; }];
    pump(.07); assert(calls == 0);
    ready = YES; pump(.12); assert(calls == 1);
    assert([ApolloPaneTransitionObserver activeCountForOwner:owner] == 0);
    pump(.12); assert(calls == 1); // no duplicate settlement
    [ApolloPaneTransitionObserver observeOwner:owner key:@"route" timeout:1
        ready:^BOOL(id object) { return YES; }
        completion:^(id object, BOOL expired) { assert(false); }];
    [ApolloPaneTransitionObserver observeOwner:owner key:@"route" timeout:.1
        ready:^BOOL(id object) { return NO; }
        completion:^(id object, BOOL expired) { assert(expired); calls++; }];
    pump(.2); assert(calls == 2); // only newest route reaches its deadline
    [ApolloPaneTransitionObserver observeOwner:owner key:@"cancel" timeout:.1
        ready:^BOOL(id object) { return NO; }
        completion:^(id object, BOOL expired) { assert(false); }];
    [ApolloPaneTransitionObserver cancelOwner:owner];
    pump(.2); assert([ApolloPaneTransitionObserver activeCountForOwner:owner] == 0);
    __weak NSObject *weakOwner;
    @autoreleasepool {
        NSObject *temporary = [NSObject new]; weakOwner = temporary;
        [ApolloPaneTransitionObserver observeOwner:temporary key:@"lifetime" timeout:.1
            ready:^BOOL(id object) { return NO; }
            completion:^(id object, BOOL expired) { assert(false); }];
    }
    assert(!weakOwner); pump(.2);
    puts("Pane settlement: readiness, replacement, deadline, cancellation, deallocation passed");
} }
