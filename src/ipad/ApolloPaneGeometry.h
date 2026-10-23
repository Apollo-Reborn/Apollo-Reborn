#import <UIKit/UIKit.h>

__BEGIN_DECLS
BOOL ApolloPaneSplitShowsPrimary(UISplitViewController *split);
BOOL ApolloPaneSplitShowsTiledPrimary(UISplitViewController *split);
__END_DECLS

// One pending update per owner, weak lifetime, bounded coordinator wait.
// The update receives the owner instead of capturing it in a retained block.
@interface ApolloPaneGeometryScheduler : NSObject
@property (nonatomic, readonly, getter=isPending) BOOL pending;
- (instancetype)initWithOwner:(UIViewController *)owner update:(void (^)(id owner))update;
- (void)requestAfterCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator;
- (void)cancel;
@end

// One write on the next display frame. The link exists only while a write is
// pending; the owner stays weak even when UIKit retains the display link.
@interface ApolloPaneFrameScheduler : NSObject
- (instancetype)initWithOwner:(UIViewController *)owner update:(void (^)(id owner))update;
- (void)request;
- (void)cancel;
@end
