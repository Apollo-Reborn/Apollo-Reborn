#import <UIKit/UIKit.h>

// "Try Pal Home": a small floating pixel card shown over Apollo's Classic
// Pixel Pals screens (the care sheet, the chooser) while Pal Home is off.
// At most about once a day, never again after ×, never once Pal Home is on.

NS_ASSUME_NONNULL_BEGIN

@interface ApolloPalHomePrompt : UIView
+ (BOOL)shouldShow;
// Floats the card at the bottom of `host` (above `bottomInset` points).
// `onTry` runs after the card has gone; Pal Home is already switched on.
+ (void)showInView:(UIView *)host bottomInset:(CGFloat)bottomInset onTry:(void (^)(void))onTry;
@end

NS_ASSUME_NONNULL_END
