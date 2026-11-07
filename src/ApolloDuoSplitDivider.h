#import <UIKit/UIKit.h>

// An owned grip, independent of UIKit's private separator recognizers.
@interface ApolloDuoSplitDivider : UIView
@property(nonatomic, readonly) BOOL dragging;
@property(nonatomic, copy) BOOL (^canBegin)(void);
@property(nonatomic, copy) void (^changeWidth)(CGFloat width, BOOL commit);
- (void)updateWithDivider:(CGFloat)x trailingInset:(CGFloat)inset enabled:(BOOL)enabled;
- (void)cancel;
@end
