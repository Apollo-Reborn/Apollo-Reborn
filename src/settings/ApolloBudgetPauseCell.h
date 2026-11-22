#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Reduce Rate Limiting's "Pause Extras At" row: a title with the chosen stop
// beside it, a slider, what it does, and a line showing where the account
// stands with Reddit right now. Laid out by hand like the screen's switch
// cells, so the wrapped text measures at its real width.
//
// The slider moves in whole stops. The value text follows the thumb while it's
// dragged; `onCommit` runs once, when the finger lifts on a different stop.
@interface ApolloBudgetPauseCell : UITableViewCell

// The text beside the title for a stop ("70 of 100", "Only at the limit").
@property (nonatomic, copy, nullable) NSString *(^valueText)(NSInteger stop);
// The live line under the description, or nil to hide it. Asked again every
// few seconds while the cell is on screen.
@property (nonatomic, copy, nullable) NSString *_Nullable (^statusText)(void);
@property (nonatomic, copy, nullable) void (^onCommit)(NSInteger stop);

- (void)configureWithTitle:(NSString *)title
                    detail:(NSString *)detail
                      stop:(NSInteger)stop
                   minimum:(NSInteger)minimum
                   maximum:(NSInteger)maximum
                      step:(NSInteger)step
                    accent:(nullable UIColor *)accent;

@end

NS_ASSUME_NONNULL_END
