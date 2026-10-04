#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Presentation only. The host supplies native Search data and performs routes.
@interface ApolloDuoSearchLandingViewController : UIViewController
- (instancetype)initWithTrendingIcon:(UIImage *)trendingIcon randomIcon:(UIImage *)randomIcon;
@property(nonatomic, strong, readonly) UIScrollView *scrollView;
@property(nonatomic, strong, readonly) UIRefreshControl *refreshControl;
@property(nonatomic, copy, nullable) void (^selectSubreddit)(NSString *subreddit);
@property(nonatomic, copy, nullable) void (^selectRandom)(BOOL nsfw);
@property(nonatomic, copy, nullable) void (^refreshRequested)(UIRefreshControl *control);

- (void)updateTrending:(NSArray<NSString *> *)trending
               recent:(NSArray<NSString *> *)recent
           randomNSFW:(BOOL)show;
- (void)refreshTheme;
- (void)scrollToTopAnimated:(BOOL)animated;
@end

NS_ASSUME_NONNULL_END
