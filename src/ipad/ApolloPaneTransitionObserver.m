#import "ApolloPaneTransitionObserver.h"
#import "ApolloPaneDiagnostics.h"
#import <objc/runtime.h>
#import <os/signpost.h>

static char kObservers;
static os_log_t ApolloPaneTransitionLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("apollofix", "PaneTransitions"); });
    return log;
}

@implementation ApolloPaneTransitionObserver {
    __weak id _owner;
    NSString *_key;
    BOOL (^_ready)(id);
    void (^_completion)(id, BOOL);
    NSTimeInterval _deadline;
    BOOL _finished;
    os_signpost_id_t _signpost;
}
+ (void)observeOwner:(id)owner key:(NSString *)key timeout:(NSTimeInterval)timeout
              ready:(BOOL (^)(id))ready completion:(void (^)(id, BOOL))completion {
    NSAssert(NSThread.isMainThread, @"Pane transitions are main-thread owned");
    if (!owner) return;
    NSMutableDictionary *observers = objc_getAssociatedObject(owner, &kObservers);
    if (!observers) {
        observers = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(owner, &kObservers, observers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [observers[key] cancel];
    ApolloPaneTransitionObserver *observer = [self new];
    observer->_owner = owner;
    observer->_key = [key copy];
    observer->_ready = [ready copy];
    observer->_completion = [completion copy];
    observer->_deadline = NSProcessInfo.processInfo.systemUptime + MAX(0.1, MIN(timeout, 10.0));
    if (ApolloPaneTraceEnabled()) {
        observer->_signpost = os_signpost_id_generate(ApolloPaneTransitionLog());
        os_signpost_interval_begin(ApolloPaneTransitionLog(), observer->_signpost, "PaneSettlement");
    }
    observers[key] = observer;
    [observer scheduleTick];
}
- (void)cancel {
    if (_finished) return;
    _finished = YES;
    _ready = nil;
    _completion = nil;
    if (_signpost) os_signpost_interval_end(ApolloPaneTransitionLog(), _signpost, "PaneSettlement");
}
+ (void)cancelOwner:(id)owner {
    NSDictionary *observers = objc_getAssociatedObject(owner, &kObservers);
    for (ApolloPaneTransitionObserver *observer in observers.allValues) [observer cancel];
    objc_setAssociatedObject(owner, &kObservers, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
+ (NSUInteger)activeCountForOwner:(id)owner {
    NSDictionary *observers = objc_getAssociatedObject(owner, &kObservers);
    return observers.count;
}
- (void)scheduleTick {
    __weak ApolloPaneTransitionObserver *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [weakSelf tick];
    });
}
- (void)tick {
    if (_finished) return;
    id owner = _owner;
    if (!owner) { [self cancel]; return; }
    BOOL expired = NSProcessInfo.processInfo.systemUptime >= _deadline;
    if (!expired && !_ready(owner)) { [self scheduleTick]; return; }
    void (^completion)(id, BOOL) = _completion;
    [self cancel];
    NSMutableDictionary *observers = objc_getAssociatedObject(owner, &kObservers);
    if (observers[_key] == self) [observers removeObjectForKey:_key];
    completion(owner, expired);
}
- (void)dealloc { [self cancel]; }
@end
