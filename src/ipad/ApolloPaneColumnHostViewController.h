#import <UIKit/UIKit.h>

@interface ApolloPaneColumnHostViewController : UIViewController
- (instancetype)initWithNavigationController:(UINavigationController *)navigationController;
@property (nonatomic, strong, readonly) UINavigationController *hostedNavigationController;
- (void)apollo_scheduleListColumnGeometryRefresh;
- (void)apollo_prepareReadableWidthForTopController;
#if APOLLO_SIM_BUILD
- (NSString *)apollo_simLayoutPassStateReset:(BOOL)reset;
#endif
@end

