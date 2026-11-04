#import <Foundation/Foundation.h>

__BEGIN_DECLS
// Opt-in on device and simulator: APOLLO_PANE_TRACE=1. Metadata is enumerated
// operation names only; no route, query, model, title or account data.
BOOL ApolloPaneTraceEnabled(void);
void ApolloPaneTraceBegin(id owner, NSString *operation);
void ApolloPaneTraceEnd(id owner, NSString *operation);
void ApolloPaneTraceCancel(id owner);
__END_DECLS
