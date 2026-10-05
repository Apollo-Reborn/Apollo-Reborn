#import <UIKit/UIKit.h>

// The floating Pal: your island Pal in a little pixel bubble that floats over
// Apollo, chat-head style. Drag it anywhere (it snaps to the nearest side),
// drop it on the ✕ to put it away, tap it to go to Pal Home. It reacts as you
// scroll (trots, then runs, facing the way the feed moves; a bounce on a big
// fling), naps when you've been still a while, and sleeps at night.
//
// Opt-in (Pal Home settings → Floating Pal); only while Pal Home is on. Lives
// in its own pass-through window (like Floating Post Tabs), so only touches on
// the bubble are its own and it never becomes key.

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXTERN NSString *const ApolloPalChatHeadEnabledKey;

// Show, hide or redraw it to match the settings and the current island Pal.
FOUNDATION_EXTERN void ApolloPalChatHeadRefresh(void);
// Hidden while Pal Home itself is on screen.
FOUNDATION_EXTERN void ApolloPalChatHeadSetSuppressed(BOOL suppressed);
// A scroll view in Apollo moved by `dy` points (the scroll hook calls this).
FOUNDATION_EXTERN void ApolloPalChatHeadNoteScroll(UIScrollView *scrollView, CGFloat dy);
// Cheap check for the scroll hook.
FOUNDATION_EXTERN BOOL ApolloPalChatHeadIsShowing(void);

// Opens Pal Home from anywhere in the app (ApolloPixelPals.xm).
FOUNDATION_EXTERN void ApolloPalHomeOpenFromAnywhere(void);

NS_ASSUME_NONNULL_END
