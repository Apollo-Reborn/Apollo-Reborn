#import <UIKit/UIKit.h>
#import "ApolloHiddenContentData.h"

// Combined chronological archive list pushed onto the profile's navigation stack.
@interface ApolloHiddenContentViewController : UITableViewController
+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter;
@end
