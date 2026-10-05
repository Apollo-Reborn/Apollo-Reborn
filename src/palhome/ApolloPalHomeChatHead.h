#import <UIKit/UIKit.h>

// The floating Pal: your island Pal in a little pixel bubble that floats over
// Apollo, chat-head style. Drag it anywhere (it snaps to the nearest side),
// tap it to go to Pal Home. It reacts as you scroll (trots, then runs, facing
// the way the feed moves; a bounce on a big fling), and between scrolls keeps
// its own routine (looking about, trotting, lounging, naps, likelier late).
//
// Shown when Pal Home's "Show your Pal" is Bubble (instead of the island or
// the tab bar). Lives
// in its own pass-through window (like Floating Post Tabs), so only touches on
// the bubble are its own and it never becomes key.

NS_ASSUME_NONNULL_BEGIN

// Show, hide or redraw it to match the settings and the current island Pal.
FOUNDATION_EXTERN void ApolloPalChatHeadRefresh(void);
// Hidden while Pal Home itself is on screen.
FOUNDATION_EXTERN void ApolloPalChatHeadSetSuppressed(BOOL suppressed);
// A scroll view in Apollo moved by `dy` points (the scroll hook calls this).
FOUNDATION_EXTERN void ApolloPalChatHeadNoteScroll(UIScrollView *scrollView, CGFloat dy);
// Leaving Pal Home with the Pal asleep: the bubble carries on the nap.
FOUNDATION_EXTERN void ApolloPalChatHeadSetNapping(BOOL napping);
// Back in the app: ears up (unless it's napping).
FOUNDATION_EXTERN void ApolloPalChatHeadWelcomeBack(void);
// Cheap check for the scroll hook.
FOUNDATION_EXTERN BOOL ApolloPalChatHeadIsShowing(void);

// Opens Pal Home from anywhere in the app (ApolloPixelPals.xm).
FOUNDATION_EXTERN void ApolloPalHomeOpenFromAnywhere(BOOL animated);
// Hides or shows Apollo's own Pal to match "Show your Pal" (ApolloPixelPals.xm).
FOUNDATION_EXTERN void ApolloPixelPalsApplyDisplay(void);
// Pal Home is on screen (hides the hearts/food Apollo drops by its own Pal).
FOUNDATION_EXTERN void ApolloPixelPalsSetPalHomeCovering(BOOL covering);

NS_ASSUME_NONNULL_END
