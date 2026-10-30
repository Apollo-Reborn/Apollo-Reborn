#import <UIKit/UIKit.h>

// Opens the Posts tab's subreddit switcher: the shared sheet (Modern) or
// Apollo's inline jump bar popup (Classic). Returns YES only when one opens.
BOOL ApolloPresentPostsTabSubredditSheet(UIWindow *sourceWindow);
