// Spelling style for UI text: American (default, Apollo's own spelling) or British.
//
// Tweak strings are written in American spelling to match Apollo's binary. When British is
// picked, ApolloSpelling.xm rewrites UI chrome text (labels, titles, menus, alerts) as it is set,
// so Apollo's native strings and the tweak's follow the same choice.
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, ApolloSpellingStyle) {
    ApolloSpellingStyleAmerican = 0,
    ApolloSpellingStyleBritish = 1,
};

ApolloSpellingStyle ApolloSpellingCurrentStyle(void);
// Saves the style; text set from now on follows it. Text already on screen keeps its spelling.
void ApolloSpellingSetStyle(ApolloSpellingStyle style);
// Returns `text` in the current style (unchanged in American mode or when nothing matches).
NSString *ApolloSpellingApply(NSString *text);
// Returns `text` with British spellings turned back into American, whatever the current style.
// Use it before matching text read back from on-screen labels against American literals.
NSString *ApolloSpellingCanonical(NSString *text);
// Reloads the loaded UIKit table views (not Texture lists) in every window so their cells and
// section titles pick up a style change. `except` (and its subviews) is skipped.
void ApolloSpellingReloadLoadedTables(UIView *except);

#ifdef __cplusplus
}
#endif
