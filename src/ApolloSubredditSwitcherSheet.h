#import <UIKit/UIKit.h>

// Opens the Posts tab's subreddit switcher: the shared sheet (Modern) or
// Apollo's inline jump bar popup (Classic). Returns YES only when one opens.
BOOL ApolloPresentPostsTabSubredditSheet(UIWindow *sourceWindow);

// YES from a Duo rail Posts hold opening the switcher until its finger lifts.
// The rail delivers that lift as a tap on the selected Posts tab, which must
// not scroll or go back a page the way a real tap does.
extern BOOL ApolloPostsTabHoldConsumesTap;
