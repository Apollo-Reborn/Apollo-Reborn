#import <UIKit/UIKit.h>

// An interactive feature screen; preferences live in the form-based decorator.
NS_ASSUME_NONNULL_BEGIN

@interface ApolloPalHomeViewController : UIViewController
// The next Pal Home to open visits this resident's home: the widget's link (apollo://reborn/settings/pal-home?pal=<id>).
+ (void)visitResidentOnOpen:(nullable NSString *)residentID;
@end

NS_ASSUME_NONNULL_END
