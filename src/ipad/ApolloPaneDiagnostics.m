#import "ApolloPaneDiagnostics.h"
#import <objc/runtime.h>
#import <os/signpost.h>

static char kIntervals;
BOOL ApolloPaneTraceEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = [NSProcessInfo.processInfo.environment[@"APOLLO_PANE_TRACE"] boolValue]; });
    return enabled;
}
static os_log_t ApolloPaneLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("apollofix", "PaneOperations"); });
    return log;
}
void ApolloPaneTraceBegin(id owner, NSString *operation) {
    if (!ApolloPaneTraceEnabled() || !owner) return;
    ApolloPaneTraceEnd(owner, operation);
    NSMutableDictionary *intervals = objc_getAssociatedObject(owner, &kIntervals);
    if (!intervals) {
        intervals = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(owner, &kIntervals, intervals, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_signpost_id_t token = os_signpost_id_generate(ApolloPaneLog());
    intervals[operation] = @(token);
    os_signpost_interval_begin(ApolloPaneLog(), token, "PaneOperation", "%{public}@", operation);
}
void ApolloPaneTraceEnd(id owner, NSString *operation) {
    if (!ApolloPaneTraceEnabled() || !owner) return;
    NSMutableDictionary *intervals = objc_getAssociatedObject(owner, &kIntervals);
    NSNumber *token = intervals[operation];
    if (!token) return;
    os_signpost_interval_end(ApolloPaneLog(), token.unsignedLongLongValue, "PaneOperation", "%{public}@", operation);
    [intervals removeObjectForKey:operation];
}
void ApolloPaneTraceCancel(id owner) {
    if (!ApolloPaneTraceEnabled() || !owner) return;
    NSDictionary *intervals = objc_getAssociatedObject(owner, &kIntervals);
    for (NSString *operation in intervals.allKeys) ApolloPaneTraceEnd(owner, operation);
    objc_setAssociatedObject(owner, &kIntervals, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
