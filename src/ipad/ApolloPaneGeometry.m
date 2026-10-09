#import "ApolloPaneGeometry.h"
#import "ApolloPaneDiagnostics.h"

BOOL ApolloPaneSplitShowsPrimary(UISplitViewController *split) {
    if (!split) return NO;
    if (@available(iOS 26.0, *)) {
        return [split isShowingColumn:UISplitViewControllerColumnPrimary];
    }
    if (split.isCollapsed) {
        UIView *view = [split viewControllerForColumn:UISplitViewControllerColumnPrimary].viewIfLoaded;
        return view.window != nil && !view.hidden;
    }
    return split.displayMode == UISplitViewControllerDisplayModeOneBesideSecondary ||
        split.displayMode == UISplitViewControllerDisplayModeOneOverSecondary;
}

BOOL ApolloPaneSplitShowsTiledPrimary(UISplitViewController *split) {
    return split && !split.isCollapsed && ApolloPaneSplitShowsPrimary(split) &&
        split.displayMode == UISplitViewControllerDisplayModeOneBesideSecondary &&
        split.splitBehavior == UISplitViewControllerSplitBehaviorTile &&
        split.transitionCoordinator == nil;
}

@implementation ApolloPaneGeometryScheduler {
    __weak UIViewController *_owner;
    void (^_update)(id);
    NSUInteger _generation;
    BOOL _pending;
}
- (instancetype)initWithOwner:(UIViewController *)owner update:(void (^)(id))update {
    if ((self = [super init])) { _owner = owner; _update = [update copy]; }
    return self;
}
- (void)cancel { _generation++; _pending = NO; }
- (BOOL)isPending { return _pending; }
- (void)deliverGeneration:(NSUInteger)generation {
    if (!_pending || generation != _generation) return;
    _pending = NO;
    UIViewController *owner = _owner;
    if (owner.viewIfLoaded.window) {
        ApolloPaneTraceBegin(owner, @"geometry");
        _update(owner);
        ApolloPaneTraceEnd(owner, @"geometry");
    }
}
- (void)requestAfterCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    NSAssert(NSThread.isMainThread, @"Pane geometry is main-thread owned");
    if (_pending || !_owner.isViewLoaded) return;
    _pending = YES;
    NSUInteger generation = ++_generation;
    __weak ApolloPaneGeometryScheduler *weakSelf = self;
    void (^deliver)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf deliverGeneration:generation];
        });
    };
    if (!coordinator) { deliver(); return; }
    BOOL accepted = [coordinator animateAlongsideTransition:nil completion:^(__unused id context) {
        deliver();
    }];
    // UIKit can call completion even when registration returns NO. Generation
    // gating makes those two delivery paths idempotent.
    if (!accepted) { deliver(); return; }
    __weak id<UIViewControllerTransitionCoordinator> weakCoordinator = coordinator;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ApolloPaneGeometryScheduler *scheduler = weakSelf;
        if (!scheduler || generation != scheduler->_generation || !scheduler->_pending) return;
        // A disappearing scene must not leave an owner latched forever. If a
        // transition is still active, the next lifecycle event requests anew.
        if (weakCoordinator && scheduler->_owner.transitionCoordinator == weakCoordinator) {
            [scheduler cancel];
        } else {
            [scheduler deliverGeneration:generation];
        }
    });
}
@end

@implementation ApolloPaneFrameScheduler {
    __weak UIViewController *_owner;
    void (^_update)(id);
    CADisplayLink *_link;
}
- (instancetype)initWithOwner:(UIViewController *)owner update:(void (^)(id))update {
    if ((self = [super init])) { _owner = owner; _update = [update copy]; }
    return self;
}
- (void)request {
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(deliver:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)deliver:(CADisplayLink *)link {
    [self cancel];
    UIViewController *owner = _owner;
    if (owner.viewIfLoaded.window.windowScene.activationState == UISceneActivationStateForegroundActive)
        _update(owner);
}
- (void)cancel { [_link invalidate]; _link = nil; }
- (void)dealloc { [self cancel]; }
@end
