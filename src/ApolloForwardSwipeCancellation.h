#import <UIKit/UIKit.h>

__BEGIN_DECLS
/// Call when a swipe other than Apollo's edge pans starts its interactive
/// Back/Forward on `navigation`, so a cancelled forward push keeps its history.
void ApolloForwardSwipeNoteSource(UINavigationController *navigation);
__END_DECLS
