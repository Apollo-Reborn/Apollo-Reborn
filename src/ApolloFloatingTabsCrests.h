#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Match-thread crest lookup for Floating Tabs (Foundation only, so it compiles
// into a host-side harness). Two pure steps:
//
//   1. ApolloFTCrestTeamsFromTitle — pulls the two sides out of a match-thread
//      style title ("Match Thread: FC Porto vs Manchester City | UEFA Champions
//      League", "Post Match Thread: Spain 1 - 0 Argentina | …", "GAME THREAD:
//      Lakers (10-5) @ Celtics (12-3) - (…)"). Gated on a "… Thread:" / "[…
//      Thread]" / "GDT:"-style prefix so ordinary posts never get parsed.
//   2. ApolloFTCrestURLForTeam — matches one side against the subreddit's
//      user-flair emoji catalogue (r/soccer's is the club crests: "FC_Porto",
//      "Manchester_City", …), returning the crest PNG URL, or nil when nothing
//      matches unambiguously. Never guesses: a tie between different crests is
//      a miss, so the caller falls back to the letter badge.

// Returns YES and the two trimmed side names when `title` reads as a match
// thread with two identifiable sides.
BOOL ApolloFTCrestTeamsFromTitle(NSString *title,
                                 NSString *_Nullable *_Nullable outHome,
                                 NSString *_Nullable *_Nullable outAway);

// `catalogue` is the subreddit's emoji list as @[ @{ @"name": token, @"url":
// png } ] (ApolloUserFlairCachedEmojisForSubreddit). The normalised index is
// cached per `subreddit` (bounded), so repeated lookups don't re-tokenise ~2k
// names. `outName` receives the matched catalogue token (for logs).
NSString *_Nullable ApolloFTCrestURLForTeam(NSString *team, NSString *subreddit,
                                            NSArray<NSDictionary<NSString *, NSString *> *> *catalogue,
                                            NSString *_Nullable *_Nullable outName);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
