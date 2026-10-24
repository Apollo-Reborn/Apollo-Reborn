#import <UIKit/UIKit.h>

// Shared by native autoplay and PiP. Points are in the supplied window's coordinates.
FOUNDATION_EXPORT BOOL ApolloVideoPointIsVisibleInWindow(UIWindow *window, CGPoint point);
