#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// ProMotion for motion the tweak drives itself. Even with
// CADisableMinimumFrameDurationOnPhone set (patch.sh), a view moved from touch
// events or an explicit CAAnimation can run at 60 Hz. These ask for the full
// rate; on a 60 Hz display or before iOS 15 they do nothing.

__BEGIN_DECLS

/// Holds the full rate until `tail` seconds after the last End. One End per
/// Begin; main thread.
void ApolloFullFrameRateBegin(void);
void ApolloFullFrameRateEnd(NSTimeInterval tail);

/// Begin and End from a gesture's states, once per gesture however many of
/// its handlers call it.
void ApolloFullFrameRateFollowGesture(UIGestureRecognizer *gesture, NSTimeInterval tail);

/// Asks for the display's full rate for one explicit animation.
void ApolloAnimationUsesFullFrameRate(CAAnimation *animation);

__END_DECLS
