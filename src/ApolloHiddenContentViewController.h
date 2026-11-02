#import <UIKit/UIKit.h>
#import "ApolloHiddenContentData.h"

// Independent Posts and Comments archive lists on the profile navigation stack,
// each one Apollo's own list (see ApolloHiddenContentNative.h).
@interface ApolloHiddenContentViewController : UIViewController
// The visible tab's list.
@property (nonatomic, readonly) UIScrollView *scrollView;
+ (void)presentForUsername:(NSString *)username fromViewController:(UIViewController *)presenter;
@end
