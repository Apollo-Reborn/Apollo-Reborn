#import <Foundation/Foundation.h>

// Decision logic for Apollo's Random and Random NSFW feeds. Foundation-only so
// tests/run_random_subreddit_tests.sh compiles it on the host; the UIKit side
// (pull-to-refresh arming, the title guard, the request rewrite) lives in
// ApolloRandomFeed.xm.
//
// Background. Reddit no longer serves /r/random or /r/randnsfw, so the tweak
// rewrites those requests to a community from the configured list. Apollo
// renames a random feed only from the posts in the listing it lands on. A
// banned or private community returns no posts, so the title stays on the
// previous community and the failure is shown against that name. Apollo's next
// pull-to-refresh then requests the community it resolved (/r/<shown>/hot), not
// /r/random, which pins the feed there. A pull-to-refresh therefore arms a
// pending roll (ApolloRandomPendingRoll) that names the communities being left
// and the community picked in their place; the listing and about requests of
// that gesture are rewritten to the pick.

// How a random feed chooses its next community. /r/random and /r/randnsfw keep
// their own lists; a pull-to-refresh must not draw from the other one.
typedef NS_ENUM(NSInteger, ApolloRandomFeedKind) {
    ApolloRandomFeedKindNone = 0,
    ApolloRandomFeedKindSafe,
    ApolloRandomFeedKindNSFW,
};

// A subreddit posts listing, or the community's own about document. Other
// routes (comments, search, wiki, about/moderators) are not part of a roll.
typedef NS_ENUM(NSInteger, ApolloRandomRequestRole) {
    ApolloRandomRequestRoleNone = 0,
    ApolloRandomRequestRolePosts,
    ApolloRandomRequestRoleAbout,
};

// Where a rewritten request's community came from.
typedef NS_ENUM(NSInteger, ApolloRandomRouteSource) {
    // The pull-to-refresh roll armed on a feed.
    ApolloRandomRouteSourcePending = 1,
    // An explicit /r/random or /r/randnsfw request with no matching roll: a
    // plain pick from the list, touching no feed state. Works on any thread.
    ApolloRandomRouteSourceStateless,
};

// What a write to a guarded feed title should do.
typedef NS_ENUM(NSInteger, ApolloRandomTitleVerdict) {
    // Pass the write through; the guard stays.
    ApolloRandomTitleVerdictKeep = 0,
    // Write the rolled community instead of a community being left.
    ApolloRandomTitleVerdictRewrite,
    // Pass the write through; Apollo has moved on (another community, or a
    // fresh random load), so the guard ends.
    ApolloRandomTitleVerdictRelease,
    // Pass the write through: Apollo itself wrote the rolled community, so the
    // pick loaded and Apollo's own state names it. The guard is confirmed.
    ApolloRandomTitleVerdictConfirm,
};

// Why a pull-to-refresh did or did not arm a roll.
typedef NS_ENUM(NSInteger, ApolloRandomArmOutcome) {
    ApolloRandomArmOutcomeArmed = 0,
    // Neither the feed, the record of earlier picks, nor the two lists can say
    // whether this is a safe or an NSFW feed. Guessing could move an NSFW feed
    // onto the safe list or the reverse, so the refresh goes out unchanged.
    ApolloRandomArmOutcomeKindUnknown,
    // The feed's list is empty or not loaded.
    ApolloRandomArmOutcomeNoCandidate,
};

// `randomBound` returns a value in [0, bound). Used so tests can pin the pick.
typedef uint32_t (*ApolloRandomBoundFunction)(uint32_t bound);

// An armed roll stays usable this long before its first request goes out.
extern const NSTimeInterval kApolloRandomArmWindow;
// After its first request, later requests of the same gesture (the about that
// Apollo may chain after a slow listing) join the roll for this long.
extern const NSTimeInterval kApolloRandomReuseWindow;
// After its first request, an explicit /r/random (or /r/randnsfw) LISTING
// joins the roll only this long: a duplicate or retried listing of the same
// gesture. A later one is a new load (the jump bar's "Random" tapped after a
// pull). An explicit random about keeps joining for the reuse window.
extern const NSTimeInterval kApolloRandomListingGrace;
// A stateless explicit-random listing and its about (or an about and then its
// listing) arriving within this long of each other share one community.
extern const NSTimeInterval kApolloRandomStatelessPairWindow;

// The roll a pull-to-refresh armed. `hardNames` are normalized community
// names the feed shows or will request (on screen, title, Apollo's model, the
// last routed community), which differ after a banned roll; a request naming
// one of them takes the roll. `leavingNames` are those plus the soft names
// carried from earlier unconfirmed rolls, only kept out of picks.
// `consumedAt` is 0 until a request uses the roll. Times are any monotonic
// clock, in seconds.
@interface ApolloRandomPendingRoll : NSObject
@property(nonatomic) ApolloRandomFeedKind kind;
@property(nonatomic, copy) NSArray<NSString *> *hardNames;
@property(nonatomic, copy) NSArray<NSString *> *leavingNames;
@property(nonatomic, copy) NSString *pickedName;
@property(nonatomic) NSTimeInterval armedAt;
@property(nonatomic) NSTimeInterval consumedAt;
@end

// The last stateless route of one kind, so the other half of the same load (a
// listing's about, or an about's listing) gets the same community. Each role
// is served once: a second listing is a new load and draws again.
@interface ApolloRandomStatelessMemo : NSObject
@property(nonatomic) ApolloRandomFeedKind kind;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) NSTimeInterval routedAt;
@property(nonatomic) BOOL servedPosts;
@property(nonatomic) BOOL servedAbout;
@end

// What ApolloRandomPlanArm needs to know about the feed being refreshed.
// `previous*` describe the feed's last title guard, if any. There is no
// previous kind: Random and Random NSFW share one PostsType tag and the jump
// bar switches between them in the same controller, so the kind is read from
// what is on screen now (ApolloRandomInferKind). `title` is the raw navigation
// title. `requestedNames` are the communities Apollo's model will request
// (currentSubreddit.name, the Swift randomSubredditName).
@interface ApolloRandomArmInput : NSObject
@property(nonatomic) BOOL previousActive;
@property(nonatomic) BOOL previousConfirmed;
@property(nonatomic, copy) NSString *previousRolledName;
@property(nonatomic, copy) NSArray<NSString *> *previousLeavingNames;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSArray<NSString *> *requestedNames;
// The JumpBar name label's text. Unlike the navigation title (Apollo writes
// "Random" there for both feeds), its placeholder tells Random ("Random") from
// Random NSFW ("RandNSFW").
@property(nonatomic, copy) NSString *labelText;
// The community and kind of the last random route served to this feed (a
// claimed stateless pick or a used roll). On a failed load it is what the
// feed shows while Apollo's model names nothing.
@property(nonatomic, copy) NSString *routedName;
@property(nonatomic) ApolloRandomFeedKind routedKind;
@end

@interface ApolloRandomArmPlan : NSObject
@property(nonatomic) ApolloRandomArmOutcome outcome;
@property(nonatomic) ApolloRandomFeedKind kind;
// The community on screen: the previous guard's pick while it is still
// unconfirmed, otherwise the title's community. Nil for a placeholder title.
@property(nonatomic, copy) NSString *shownName;
// The hard leaving names (see ApolloRandomPendingRoll), and those plus soft.
@property(nonatomic, copy) NSArray<NSString *> *hardNames;
@property(nonatomic, copy) NSArray<NSString *> *leavingNames;
// Nil unless `outcome` is Armed.
@property(nonatomic, copy) NSString *pickedName;
@end

@interface ApolloRandomRoute : NSObject
@property(nonatomic) ApolloRandomRouteSource source;
@property(nonatomic) ApolloRandomFeedKind kind;
@property(nonatomic, copy) NSString *name;
// A Pending route whose roll had the other kind: `kind` and `name` replace the
// roll's kind and pick (see ApolloRandomRouteRequest).
@property(nonatomic) BOOL repicked;
// A Stateless route that reused `statelessMemo`'s community (the other half
// of a listing/about pair) instead of drawing.
@property(nonatomic) BOOL reusedStateless;
// A Stateless listing of the live roll's kind: a new load that replaces the
// roll, which the caller should drop.
@property(nonatomic) BOOL supersedesPending;
@end

#ifdef __cplusplus
extern "C" {
#endif

// Posts listing or about root under /r/<community>. `kind` is safe or NSFW when
// that community is random or randnsfw. `community` is the path's name without
// a .json suffix. NO for every other Reddit path.
BOOL ApolloRandomMatchSubredditPath(NSString *path,
                                    ApolloRandomRequestRole *role,
                                    ApolloRandomFeedKind *kind,
                                    NSString *__autoreleasing *community);

// YES when a posts listing carries an after/before cursor. Later pages stay on
// the community the first page landed on.
BOOL ApolloRandomPostsListingHasCursor(NSURL *url);

// YES when `names` holds `name`, compared as normalized subreddit names
// (case-insensitive, "r/" prefix ignored).
BOOL ApolloRandomNamesContain(NSArray<NSString *> *names, NSString *name);

// A name from `subreddits`, tried in this order:
//   1. not in `hardExcluding` and not in `softExcluding`;
//   2. not in `hardExcluding` (history ran out: an earlier roll's community
//      may come back, but never the one on screen or the one requested);
//   3. any entry, so a one-entry list still loads.
NSString *ApolloRandomPickSubreddit(NSArray<NSString *> *subreddits,
                                    NSArray<NSString *> *hardExcluding,
                                    NSArray<NSString *> *softExcluding,
                                    ApolloRandomBoundFunction randomBound);

// A name from `subreddits` for a stateless or re-picked route, tried in this
// order:
//   1. not in `hardExcluding` and not in `recentNewestFirst`;
//   2. not in `hardExcluding`, the least recently picked (so a small list
//      cycles instead of repeating the last pick);
//   3. any entry.
NSString *ApolloRandomPickSubredditAvoidingRecent(NSArray<NSString *> *subreddits,
                                                  NSArray<NSString *> *hardExcluding,
                                                  NSArray<NSString *> *recentNewestFirst,
                                                  ApolloRandomBoundFunction randomBound);

// The names in the record of picks (ApolloRandomRememberPickedKind) drawn for
// `kind`, newest first.
NSArray<NSString *> *ApolloRandomRecentPicks(NSDictionary<NSString *, NSNumber *> *kinds,
                                             NSArray<NSString *> *order,
                                             ApolloRandomFeedKind kind);

// Replaces the /r/<community> path component, keeping the sort, .json suffix,
// host and query. Nil when `url` does not name `community`.
NSURL *ApolloRandomURLByReplacingCommunity(NSURL *url,
                                           NSString *community,
                                           NSString *replacement);

// Which list a feed draws from, or None when that cannot be decided (the
// caller then does not arm).
//   1. A placeholder `labelText` (the JumpBar label) says it directly:
//      "random" is safe, "randnsfw" is NSFW (a banned pick never replaces it).
//   2. A "randnsfw" placeholder `title`. A "Random" title decides nothing:
//      Apollo writes it for both feeds.
//   3. `pickedKinds` (ApolloRandomRememberPickedKind), the kind each recent
//      pick was drawn for, looked up over `names` in order (the shown name
//      first, then the requested and routed names): whatever is on screen was
//      recorded with its kind when it was picked.
//   4. List membership: the one list that holds one of `names`. A nil list is
//      unknown (configured but not loaded, or evicted from the cache), so it
//      cannot rule anything out; an empty array is a list with no entries.
//      Names on neither list, on both, or a list that is unknown is ambiguous.
//   5. `routedKind`, the kind of the last random route served to this feed:
//      only when membership is ambiguous, since a jump-bar switch can leave
//      it stale.
// Otherwise None.
ApolloRandomFeedKind ApolloRandomInferKind(NSString *labelText,
                                           NSString *title,
                                           NSArray<NSString *> *names,
                                           ApolloRandomFeedKind routedKind,
                                           NSDictionary<NSString *, NSNumber *> *pickedKinds,
                                           NSArray<NSString *> *safeSubreddits,
                                           NSArray<NSString *> *nsfwSubreddits);

// Records that `name` was picked for a `kind` feed. `kinds` maps a lowercased
// normalized name to the kind; `order` holds keys oldest first. At most `limit`
// names are kept, the oldest dropped first.
void ApolloRandomRememberPickedKind(NSMutableDictionary<NSString *, NSNumber *> *kinds,
                                    NSMutableArray<NSString *> *order,
                                    NSString *name,
                                    ApolloRandomFeedKind kind,
                                    NSUInteger limit);

// The roll a pull-to-refresh should arm.
//   - Leaving: hard names (the community on screen, the title's community,
//     every name in `requestedNames`, the feed's `routedName`) and, while the previous guard is still
//     unconfirmed (its pick never loaded, e.g. it was banned), soft names
//     carried from that guard, so consecutive banned rolls do not go back.
//   - Kind: ApolloRandomInferKind over the label, the title, the hard names
//     and the routed kind.
//   - Pick: ApolloRandomPickSubreddit from that kind's list, hard and soft.
ApolloRandomArmPlan *ApolloRandomPlanArm(ApolloRandomArmInput *input,
                                         NSDictionary<NSString *, NSNumber *> *pickedKinds,
                                         NSArray<NSString *> *safeSubreddits,
                                         NSArray<NSString *> *nsfwSubreddits,
                                         ApolloRandomBoundFunction randomBound);

// YES while `pending` may still be used at `now`: within the arm window before
// its first request, within the reuse window after it.
BOOL ApolloRandomPendingRollIsLive(ApolloRandomPendingRoll *pending, NSTimeInterval now);

// Nil when the request must go out unchanged. Otherwise the community to send.
//   - A later listing page (`hasCursor`) is never rewritten.
//   - A live `pending` roll takes a request that names one of its hard names,
//     an explicit random about of its kind, and an explicit random listing of
//     its kind until kApolloRandomListingGrace after its first request.
//   - A roll no request has used yet that meets an explicit random of the
//     other kind (the pull's own refresh, armed with the wrong kind) takes it
//     too, re-picked (`repicked`) from the path kind's list, never one of the
//     roll's leaving names and preferring no recent pick of that kind.
//   - Any other explicit random request is stateless: the community of
//     `statelessMemo` (the last stateless route of that kind) when it is the
//     other half of the same load (ApolloRandomStatelessMemo), else a pick
//     from its list preferring no recent pick of its kind. A stateless listing
//     of the live roll's kind sets `supersedesPending`.
//   - Every other request (a sort change, a filter toggle, a reload Apollo
//     starts itself) is left alone: only an armed pull-to-refresh rolls.
// `pickedKinds` and `pickedOrder` are the record of picks
// (ApolloRandomRememberPickedKind); either may be nil.
ApolloRandomRoute *ApolloRandomRouteRequest(ApolloRandomRequestRole role,
                                            ApolloRandomFeedKind pathKind,
                                            NSString *community,
                                            BOOL hasCursor,
                                            ApolloRandomPendingRoll *pending,
                                            ApolloRandomStatelessMemo *statelessMemo,
                                            NSTimeInterval now,
                                            NSArray<NSString *> *safeSubreddits,
                                            NSArray<NSString *> *nsfwSubreddits,
                                            NSDictionary<NSString *, NSNumber *> *pickedKinds,
                                            NSArray<NSString *> *pickedOrder,
                                            ApolloRandomBoundFunction randomBound);

// The memo to keep for the route's kind after `route` went out for a request
// of `role` at `now`: unchanged for a non-stateless route, marked served for a
// reused one, a new memo for a fresh draw.
ApolloRandomStatelessMemo *ApolloRandomStatelessMemoAfterRoute(ApolloRandomStatelessMemo *memo,
                                                               ApolloRandomRoute *route,
                                                               ApolloRandomRequestRole role,
                                                               NSTimeInterval now);

// YES when a request is one the feed's current (rolled) community stands in
// for: a first-page listing or about, not an explicit random, that names one
// of `leavingNames`. Used for the title guard's sticky route.
BOOL ApolloRandomRequestNamesLeaving(ApolloRandomRequestRole role,
                                     ApolloRandomFeedKind pathKind,
                                     NSString *community,
                                     BOOL hasCursor,
                                     NSArray<NSString *> *leavingNames);

// How a guarded feed treats a title write after rolling from `leavingNames` to
// `rolledName`. `confirmed` is YES once Apollo itself wrote the rolled name.
//   - The rolled community: Confirm.
//   - A leaving community: Rewrite while unconfirmed; Release once confirmed
//     (Apollo's own state has moved, so the write is genuine).
//   - The "Random"/"randnsfw" placeholder: Rewrite while unconfirmed (a banned
//     first pick never replaces it); Release once confirmed (a new random load).
//   - Another community: Release. Anything else (a display name): Keep.
// On Rewrite, `*rewritten` is `title` with the slug replaced and any "r/"
// prefix or surrounding whitespace kept.
ApolloRandomTitleVerdict ApolloRandomJudgeTitle(NSString *title,
                                                NSArray<NSString *> *leavingNames,
                                                NSString *rolledName,
                                                BOOL confirmed,
                                                NSString *__autoreleasing *rewritten);

// YES when a stateless random listing of `routeKind` belongs to a random feed
// on screen, so its title should name the routed community:
//   - its JumpBar label (`labelText`) is the placeholder of `routeKind`; or
//   - it has no label and its navigation `title` is either placeholder (Apollo
//     writes "Random" for both kinds); or
//   - its label (or, without one, its title) shows the feed's own `routedName`
//     while Apollo's model (`modelNames`) does not name it: the feed sits on a
//     failed route, so a new random load there is its own.
BOOL ApolloRandomFeedTakesRoute(NSString *labelText,
                                NSString *title,
                                NSArray<NSString *> *modelNames,
                                NSString *routedName,
                                ApolloRandomFeedKind routeKind);

#ifdef __cplusplus
}
#endif
