#import <UIKit/UIKit.h>

@class ApolloGiphyGIF;

NS_ASSUME_NONNULL_BEGIN

@interface GiphyPickerViewController : UIViewController

@property (nonatomic, copy, nullable) void (^onSelectGIF)(ApolloGiphyGIF *gif);
@property (nonatomic, weak, nullable) UIViewController *themeSourceViewController;

@end

NS_ASSUME_NONNULL_END
