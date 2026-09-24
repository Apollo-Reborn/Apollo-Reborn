#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// YES when the Confirm Favorite Changes setting is on and this call is not
// already inside an ApolloFavoriteConfirmRun perform scope. Main thread only.
BOOL ApolloFavoriteConfirmShouldPrompt(void);

// Shared confirmation flow for the Subreddits-list star (native control and
// polish star-hit proxy). Presents an action sheet; only after the sheet has
// fully dismissed does it re-check nameProvider and run `perform` inside a
// bypass scope so the nested favoriteSubredditButtonTapped: re-entry skips
// the prompt. `nameProvider` is called at present time (for the title) and
// again just before perform (stale-row guard). Pass nil-returning provider
// when the name is unknown — the sheet falls back to neutral wording.
void ApolloFavoriteConfirmRun(UIView *sourceView,
                              NSString *_Nullable (^nameProvider)(void),
                              dispatch_block_t perform);

__END_DECLS
NS_ASSUME_NONNULL_END
