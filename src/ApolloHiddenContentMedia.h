#import <UIKit/UIKit.h>

// Present archived URLs in Apollo's own zoomable, swipeable media pager.
BOOL ApolloHiddenContentPresentMedia(NSArray<NSURL *> *urls, NSUInteger initialIndex, UIImageView *sourceView, UIViewController *presenter, void (^selectionChanged)(NSUInteger));
