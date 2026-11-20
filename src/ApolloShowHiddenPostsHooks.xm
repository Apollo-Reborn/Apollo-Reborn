// Show Hidden Posts: subreddit feeds keep the posts the account has hidden.
//
// Reddit leaves hidden posts out of every listing unless the request carries
// show=all, which turns its per-account hide rules off for that listing (the
// same rule also covers the account's "hide posts I voted on" preferences).
// Every post listing Apollo loads goes through RDKClient's listing method, first
// pages and later pages alike, so the parameter is added there, for single
// subreddits only. Home, Popular, All and multireddits keep hiding.
//
// Settings > Features > Subreddits turns it on.

#import <Foundation/Foundation.h>

#import "ApolloCommon.h"
#import "ApolloShowHiddenPosts.h"
#import "ApolloState.h"

@interface RDKClient : NSObject
@end

static BOOL ApolloShowHiddenPostsEnabledForSubreddit(NSString *subreddit) {
    return subreddit.length > 0 && sShowHiddenPostsInSubreddits;
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
