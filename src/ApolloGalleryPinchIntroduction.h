#import <UIKit/UIKit.h>

// A first-use guide. Only its delayed acknowledgement button dismisses it.
@interface ApolloGalleryPinchIntroduction : UIViewController
+ (BOOL)hasBeenAcknowledged;
@property (nonatomic, copy) dispatch_block_t dismissalCompletion;
@end
