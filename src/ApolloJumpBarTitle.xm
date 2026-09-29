// The subreddit title remains Apollo's native quick-switcher control, without
// its decorative drop-down triangle. This applies to every device and theme.

#import <UIKit/UIKit.h>

@interface _TtC6Apollo7JumpBar : UIControl
@end

static void ApolloJumpBarRemoveTitleArrow(UIView *jumpBar) {
    // Identify the arrow through its native left-to-title-right constraint instead
    // of reading Swift Optional ivars. The search field and suggestion label
    // have their own constraints and are deliberately left alone.
    UIImageView *arrow = nil;
    UILabel *title = nil;
    for (NSLayoutConstraint *constraint in jumpBar.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeLeft &&
            constraint.secondAttribute == NSLayoutAttributeRight &&
            [constraint.firstItem isKindOfClass:UIImageView.class] &&
            [constraint.secondItem isKindOfClass:UILabel.class]) {
            arrow = constraint.firstItem;
            title = constraint.secondItem;
            break;
        }
    }
    if (!arrow || arrow.superview != jumpBar || title.superview != jumpBar) return;

    // Apollo offsets the name by five points to center the name + triangle.
    // Recenter the name alone as the control joins the view hierarchy.
    for (NSLayoutConstraint *constraint in jumpBar.constraints) {
        if (constraint.firstItem == title && constraint.secondItem == jumpBar &&
            constraint.firstAttribute == NSLayoutAttributeCenterX &&
            constraint.secondAttribute == NSLayoutAttributeCenterX) {
            constraint.constant = 0.0;
        }
    }

    // Detach rather than hide: native quick-switcher state changes toggle the
    // arrow's hidden/alpha properties. Apollo keeps its own reference, so those
    // updates remain safe, but cannot show it or reserve space in the capsule.
    [arrow removeFromSuperview];
}

%hook _TtC6Apollo7JumpBar

- (void)didMoveToWindow {
    %orig;
    // Swift can call the initializer directly, bypassing its Objective-C entry
    // point. UIKit always delivers this lifecycle callback before display.
    if (self.window) ApolloJumpBarRemoveTitleArrow(self);
}

%end

%ctor {
    %init;
}
