#import <UIKit/UIKit.h>

// Search tab "Google" mode glue (ApolloGoogleSearchTab.m). Apollo's
// SearchViewController is hooked in exactly one place, ApolloSearchTabFixes.xm;
// those hooks call these entry points.

#ifdef __cplusplus
extern "C" {
#endif

// After Apollo's viewDidLoad: install the engine button (the field's magnifier) + the Google list.
void ApolloGoogleSearchTabViewDidLoad(UIViewController *searchVC);
// After Apollo's viewDidAppear: re-apply the engine button, placeholder and theme.
void ApolloGoogleSearchTabViewDidAppear(UIViewController *searchVC);
// After Apollo's searchBar:textDidChange: (Apollo's own handling always runs).
void ApolloGoogleSearchTabTextDidChange(UIViewController *searchVC, NSString *text);
// Before Apollo's searchBarSearchButtonClicked:. YES = Google mode took it;
// the caller then skips Apollo's (Reddit) search.
BOOL ApolloGoogleSearchTabHandleSearchButton(UIViewController *searchVC, UISearchBar *bar);
// After Apollo's searchBarCancelButtonClicked:.
void ApolloGoogleSearchTabDidCancel(UIViewController *searchVC);
// Search tab re-selected: with the Google list up, scroll it to the top (or
// focus the field when already there) and return YES. NO = Apollo's table is
// showing; the caller handles it.
BOOL ApolloGoogleSearchTabHandleReselect(UIViewController *searchVC);
#ifdef __cplusplus
}
#endif
