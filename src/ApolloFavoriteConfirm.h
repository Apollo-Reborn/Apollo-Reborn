#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// YES when the Confirm Favorite Changes setting is on and this tap has not
// already been confirmed via ApolloFavoriteConfirmSuppressNextTap(). Main
// thread only.
BOOL ApolloFavoriteConfirmShouldPrompt(void);

// One-shot: the next ShouldPrompt check returns NO. Self-clears on the
// following main-runloop turn so a cancelled or lost re-entry cannot wedge
// the gate off permanently.
void ApolloFavoriteConfirmSuppressNextTap(void);

// Resolve the enclosing list cell / subreddit name / presenting VC from
// `sourceView`, then present an action sheet asking to Favorite or Unfavorite.
// `confirmed` runs only if the user confirms (and only after the sheet
// dismisses into the handler).
void ApolloFavoriteConfirmPresentForView(UIView *sourceView,
                                         dispatch_block_t confirmed);

__END_DECLS
NS_ASSUME_NONNULL_END
