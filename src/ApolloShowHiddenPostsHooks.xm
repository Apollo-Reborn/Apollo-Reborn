// Show Hidden Posts: subreddit feeds keep the posts the account has hidden.
//
// Reddit leaves hidden posts out of every listing unless the request carries
// show=all, which turns its per-account hide rules off for that listing (the
// same rule also covers the account's "hide posts I voted on" preferences).
// Every post listing Apollo loads goes through RDKClient's listing method, first
// pages and later pages alike, so the parameter is added there, for single
// subreddits only. Home, Popular, All and multireddits keep hiding.
//
// Settings > Features > Subreddits sets the default. A subreddit's ••• menu
// flips it for that subreddit until the app quits, or for good with Remember
// Per Subreddit (choices are kept in ApolloShowHiddenPosts.m).

#import <UIKit/UIKit.h>
#import <objc/message.h>

#import "ApolloAccountCredentials.h"
#import "ApolloActionMenu.h"
#import "ApolloActionMenuLayout.h"
#import "ApolloCommon.h"
#import "ApolloShowHiddenPosts.h"
#import "ApolloState.h"
#import "ApolloSwiftRuntime.h"

// Defined in ApolloSubredditHeaders.xm: the feed's PostsType case (0 is a
// single subreddit; -1 when unreadable) and the slug it shows.
extern NSInteger ApolloPostsTypeTagFromViewController(UIViewController *viewController);
extern NSString *ApolloSubredditNameFromViewController(UIViewController *viewController);

@interface RDKClient : NSObject
@end

static BOOL ApolloShowHiddenPostsEnabledForSubreddit(NSString *subreddit) {
    if (subreddit.length == 0) return NO;
    NSNumber *choice = ApolloShowHiddenChoiceForSubreddit(subreddit, sShowHiddenPostsRememberPerSubreddit,
                                                          [NSUserDefaults standardUserDefaults]);
    return choice ? choice.boolValue : sShowHiddenPostsInSubreddits;
}

// ApolloListEmptyState.xm hooks the same method and sends a Random feed's
// r/random to a subreddit it picks. Keep this file after it in the Makefile:
// this hook then runs first and sees r/random, which gets no show=all.
%hook RDKClient

- (id)listingTaskWithPath:(NSString *)path parameters:(id)parameters pagination:(id)pagination completion:(id)completion {
    NSString *subreddit = ApolloShowHiddenSubredditForListingPath(path);
    if (!ApolloShowHiddenPostsEnabledForSubreddit(subreddit)) return %orig;
    ApolloLog(@"[ShowHidden] r/%@: listing includes hidden posts", subreddit);
    return %orig(path, ApolloShowHiddenListingParameters(parameters), pagination, completion);
}

%end

#pragma mark - ••• menu

// The subreddit a feed's ••• sheet belongs to, when it is a single subreddit
// and an account is signed in (signed out, nothing is hidden). Nil otherwise.
static NSString *ApolloShowHiddenMenuSubreddit(id actionController) {
    if (![ApolloActionMenuContextForController(actionController) isEqualToString:ApolloActionMenuContextFeed]) return nil;
    if (ApolloActiveAccountUsername().length == 0) return nil;
    UIViewController *feed = ApolloActionMenuOwnerForController(actionController);
    // A Random feed names the community it shows, but loads r/random, which
    // the request hook leaves alone.
    if (ApolloPostsTypeTagFromViewController(feed) != 0) return nil;
    NSString *name = ApolloSubredditNameFromViewController(feed);
    // Same exclusions as the request hook (Popular and All are subreddit-typed feeds).
    return name.length > 0 ? ApolloShowHiddenSubredditForListingPath([@"r/" stringByAppendingString:name]) : nil;
}

static void ApolloShowHiddenMenuToggle(id actionController) {
    NSString *subreddit = ApolloShowHiddenMenuSubreddit(actionController);
    UIViewController *feed = ApolloActionMenuOwnerForController(actionController);
    if (!subreddit || !feed) return;

    BOOL show = !ApolloShowHiddenPostsEnabledForSubreddit(subreddit);
    ApolloShowHiddenSetChoiceForSubreddit(subreddit, show, sShowHiddenPostsRememberPerSubreddit,
                                          [NSUserDefaults standardUserDefaults]);
    ApolloLog(@"[ShowHidden] r/%@: hidden posts %@ from the ••• menu%@", subreddit, show ? @"shown" : @"hidden",
              sShowHiddenPostsRememberPerSubreddit ? @" (saved)" : @"");

    SEL refresh = @selector(refreshControlActivatedWithSender:);
    if ([feed respondsToSelector:refresh]) {
        ((void (*)(id, SEL, id))objc_msgSend)(feed, refresh, ApolloReadObjectIvar(feed, "refreshControl"));
    }
}

%ctor {
    %init;

    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"ShowHiddenPosts";
    spec.legacyDismissesSheet = YES;
    spec.matches = ^BOOL(id actionController, NSString *menuTitle) {
        (void)menuTitle;
        return ApolloShowHiddenMenuSubreddit(actionController) != nil;
    };
    spec.title = ^NSString *(id actionController, UITableViewCell *donor) {
        (void)donor;
        return ApolloShowHiddenPostsEnabledForSubreddit(ApolloShowHiddenMenuSubreddit(actionController))
            ? @"Hide Hidden Posts" : @"Show Hidden Posts";
    };
    spec.image = ^UIImage *(id actionController, UITableViewCell *donor) {
        (void)donor;
        NSString *symbol = ApolloShowHiddenPostsEnabledForSubreddit(ApolloShowHiddenMenuSubreddit(actionController))
            ? @"eye.slash" : @"eye";
        return ApolloActionMenuSymbolIcon(symbol) ?: [UIImage systemImageNamed:symbol];
    };
    spec.perform = ^(id actionController) {
        ApolloShowHiddenMenuToggle(actionController);
    };
    ApolloActionMenuRegister(spec);
}
