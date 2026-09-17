#import <UIKit/UIKit.h>
#import "ApolloHiddenContentData.h"

// Independent Posts and Comments archive lists on the profile navigation stack.
@interface ApolloHiddenContentViewController : UIViewController
@property (nonatomic, readonly) UITableView *tableView;
+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter;
@end
