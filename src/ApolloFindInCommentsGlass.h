// ApolloFindInCommentsGlass.h
//
// Native Liquid Glass "Find in Comments" (see ApolloFindInCommentsGlass.xm).
// The resting bar (attach, hide Apollo's toolbar, scroll-away, pull-reveal,
// continuous collapse) is shared with the feed in ApolloSearchNativeBar.xm;
// this module owns the comments-specific half: the UISearchBar delegate that
// drives Apollo's in-thread match pipeline, the match navigator in the nav
// bar's trailing group, and the session bookkeeping around them.

#import <UIKit/UIKit.h>

// The search-bar/controller delegate for one comments controller (created on
// first use, retained by the controller). ApolloSearchNativeBar.xm hands it to
// the UISearchController it attaches for comments screens.
id ApolloFindInCommentsGlassBridgeForController(UIViewController *vc);

// Placeholder for the comments search field ("Find in Comments").
NSString *ApolloFindInCommentsGlassPlaceholder(void);

// Appearance hooks, called from ApolloSearchNativeBar.xm's controller hooks
// for comments screens only.
void ApolloFindInCommentsGlassViewWillAppear(UIViewController *vc);
void ApolloFindInCommentsGlassViewDidAppear(UIViewController *vc);
void ApolloFindInCommentsGlassViewWillDisappear(UIViewController *vc);

// YES while the find navigator (count + up/down) owns this navigation item's
// rightBarButtonItems. ApolloTranslation.xm's globe merge stands down then, so
// it never treats the navigator as Apollo's trailing container.
BOOL ApolloFindInCommentsGlassOwnsRightItems(UINavigationItem *navItem);

// The navigator's trailing platter (or, before UIKit has laid one out, the slot it is
// about to take) in `view`'s coordinates while the navigator owns the trailing group;
// CGRectNull otherwise. The title layout fits the title to this edge instead of to
// whatever platter the bar is still fading out.
CGRect ApolloFindInCommentsGlassTrailingFrame(UINavigationItem *navItem, UIView *view);
