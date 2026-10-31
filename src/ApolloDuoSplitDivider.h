#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ApolloDuoSplitPosition.h"

@class UIView;

__BEGIN_DECLS
/// A still press on the Posts divider: the adjustable split is on, a thread
/// is open beside the feed in the unfolded landscape split, the touch is
/// within 12pt of the divider and has moved less than a tap's 10pt jitter.
BOOL ApolloDuoSplitDividerShouldBegin(BOOL adjustable, BOOL postsLandscapeWithThread, CGFloat touchX,
                                      CGFloat dividerX, CGFloat movedDistance);

/// UIKit's context menu (a row's touch and hold: its driver
/// com.apple.UIKit.longPressClickDriver... and the click presentation's
/// com.apple.UIKit.clickPresentation... relationships): held off on a touch
/// in the divider's band until it ends. No other gesture is.
BOOL ApolloDuoSplitDividerOutranks(NSString *gestureName);

/// Adds the divider's press and hold (ApolloReborn.Duo.SplitDivider) to the
/// Posts split host's view, once.
void ApolloDuoSplitDividerInstall(UIView *host);
/// The split let the drag go (a fold, a tab switch, a sheet, the thread
/// closing): the grabber goes and the press ends without a release.
void ApolloDuoSplitDividerLetGo(UIView *host);
/// The divider's press on `host` still holds its drag: begun and not yet
/// released, cancelled or let go.
BOOL ApolloDuoSplitDividerHolding(UIView *host);
__END_DECLS
