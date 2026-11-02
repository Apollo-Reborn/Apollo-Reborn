#import <UIKit/UIKit.h>

// Hidden & Deleted and Recently Read each share one table row with a native
// profile row (a wrapper ASCellNode tagged with apollo_profileShortcutChildren).

// Call where an injected row is built: how to open it when keyboard focus or a
// keyboard selection lands on it rather than a tap on its own gesture.
void ApolloProfileRowWrapperRegisterInjectedRow(id row, void (^open)(UIView *rowView));

// The touched half of a wrapper row, in the cell's coordinates, for focus
// effects that should outline one visible row instead of the whole cell.
BOOL ApolloProfileRowWrapperFocusRect(UITableViewCell *cell, CGRect *outRect);

// An injected row's tap gesture cancels the table's touch, so UIKit never moves
// focus to it. Call from that gesture to focus the row the gesture belongs to.
void ApolloProfileRowWrapperFocusRowView(UIView *rowView);
