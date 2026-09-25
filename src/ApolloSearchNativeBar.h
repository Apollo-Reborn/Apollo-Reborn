// ApolloSearchNativeBar.h
//
// Native Liquid Glass feed search (see ApolloSearchNativeBar.xm). Exports the
// gates other modules key on so the legacy in-place machinery and the
// Community Highlights re-attach can defer to the native session.

#import <UIKit/UIKit.h>

// YES when the native nav-bar search system owns feed search (Liquid Glass).
BOOL ApolloNativeFeedSearchEnabled(void);

// YES while THIS feed table is mid-native-search with a non-empty query.
BOOL ApolloNativeFeedSearchActiveQuery(UIScrollView *tableView);

// Flush and restore an expanded feed search before a cancelled navigation is drawn.
void ApolloNativeFeedSearchRestoreCancelledNavigation(UIViewController *vc);

// A programmatic scroll to the top of a managed list is about to run (the
// status-bar tap's jump). The bar is revealed once the list lands at its rest;
// a collapsed bar reached by the user's own scrolling is left alone otherwise.
void ApolloNativeFeedSearchWillScrollToTop(UIScrollView *scrollView);
