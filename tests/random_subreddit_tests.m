#import <Foundation/Foundation.h>
#import "ApolloRandomSubreddit.h"

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

static uint32_t First(uint32_t bound) {
    Check(bound > 0, @"pick must not ask for an empty range");
    return 0;
}

static uint32_t Last(uint32_t bound) {
    return bound - 1;
}

static uint32_t Middle(uint32_t bound) {
    return bound / 2;
}

static ApolloRandomPendingRoll *Pending(ApolloRandomFeedKind kind,
                                        NSArray<NSString *> *leaving,
                                        NSString *picked,
                                        NSTimeInterval armedAt,
                                        NSTimeInterval consumedAt) {
    ApolloRandomPendingRoll *pending = [ApolloRandomPendingRoll new];
    pending.kind = kind;
    pending.hardNames = leaving;
    pending.leavingNames = leaving;
    pending.pickedName = picked;
    pending.armedAt = armedAt;
    pending.consumedAt = consumedAt;
    return pending;
}

static ApolloRandomRoute *Route(NSString *path, NSString *query,
                                ApolloRandomPendingRoll *pending, NSTimeInterval now,
                                NSArray *safe, NSArray *nsfw, ApolloRandomBoundFunction bound) {
    ApolloRandomRequestRole role = ApolloRandomRequestRoleNone;
    ApolloRandomFeedKind kind = ApolloRandomFeedKindNone;
    NSString *community = nil;
    if (!ApolloRandomMatchSubredditPath(path, &role, &kind, &community)) return nil;
    NSString *string = [@"https://oauth.reddit.com" stringByAppendingString:path];
    if (query.length > 0) string = [string stringByAppendingFormat:@"?%@", query];
    BOOL cursor = ApolloRandomPostsListingHasCursor([NSURL URLWithString:string]);
    return ApolloRandomRouteRequest(role, kind, community, cursor, pending, nil, now, safe, nsfw, nil, nil, bound);
}

int main(void) {
    @autoreleasepool {
        ApolloRandomRequestRole role = ApolloRandomRequestRoleNone;
        ApolloRandomFeedKind kind = ApolloRandomFeedKindNone;
        NSString *community = nil;

        Check(ApolloRandomMatchSubredditPath(@"/r/random/hot.json", &role, &kind, &community) &&
              role == ApolloRandomRequestRolePosts && kind == ApolloRandomFeedKindSafe &&
              [community isEqualToString:@"random"],
              @"/r/random/hot.json is a safe random listing");
        Check(ApolloRandomMatchSubredditPath(@"/r/RandNSFW/new", &role, &kind, &community) &&
              role == ApolloRandomRequestRolePosts && kind == ApolloRandomFeedKindNSFW &&
              [community isEqualToString:@"RandNSFW"],
              @"randnsfw listings are matched case-insensitively");
        Check(ApolloRandomMatchSubredditPath(@"/r/random.json", &role, &kind, &community) &&
              role == ApolloRandomRequestRolePosts && kind == ApolloRandomFeedKindSafe,
              @"a bare /r/random.json listing still rolls");
        Check(ApolloRandomMatchSubredditPath(@"/r/aww/about.json", &role, &kind, &community) &&
              role == ApolloRandomRequestRoleAbout && kind == ApolloRandomFeedKindNone &&
              [community isEqualToString:@"aww"],
              @"about.json is the community document, not a listing");
        Check(!ApolloRandomMatchSubredditPath(@"/r/aww/about/moderators.json", &role, &kind, &community),
              @"moderator lists are not part of a roll");
        Check(!ApolloRandomMatchSubredditPath(@"/r/aww/comments/abc", &role, &kind, &community),
              @"a comment thread is not a roll");
        Check(!ApolloRandomMatchSubredditPath(@"/r/a+b/hot", &role, &kind, &community),
              @"a multireddit is not a single community");
        Check(ApolloRandomMatchSubredditPath(@"/r/aww/hot", &role, &kind, &community) &&
              kind == ApolloRandomFeedKindNone && [community isEqualToString:@"aww"],
              @"a resolved community listing is recognized but is not itself random");

        NSURL *page = [NSURL URLWithString:@"https://oauth.reddit.com/r/random/hot.json?limit=25&raw_json=1&after=t3_abc"];
        Check(ApolloRandomPostsListingHasCursor(page), @"after= is a later page");
        NSURL *first = [NSURL URLWithString:@"https://oauth.reddit.com/r/random/hot.json?limit=25&after="];
        Check(!ApolloRandomPostsListingHasCursor(first), @"an empty cursor is still the first page");

        NSArray *safe = @[@"aww", @"pics", @"games"];
        NSArray *nsfw = @[@"nsfw1", @"nsfw2"];
        Check([ApolloRandomPickSubreddit(safe, @[@"aww"], nil, Last) isEqualToString:@"games"],
              @"the pick skips the community on screen");
        Check([ApolloRandomPickSubreddit(@[@"aww"], @[@"aww"], nil, First) isEqualToString:@"aww"],
              @"a list of one community still returns it");
        Check([ApolloRandomPickSubreddit(@[@"aww", @"pics"], @[@"r/AWW", @"pics"], nil, First) length] > 0,
              @"a list whose every entry is excluded still returns one");
        ApolloRandomBoundFunction bounds[] = {First, Middle, Last};
        for (size_t index = 0; index < sizeof(bounds) / sizeof(bounds[0]); index++) {
            Check([ApolloRandomPickSubreddit(safe, @[@"pics", @"aww"], nil, bounds[index]) isEqualToString:@"games"],
                  @"the pick excludes every leaving community");
        }
        Check(ApolloRandomNamesContain(@[@"aww"], @"r/AWW") &&
              ApolloRandomNamesContain(@[@"/r/Pics"], @"pics") &&
              !ApolloRandomNamesContain(@[@"aww"], @"awww"),
              @"leaving names compare as normalized subreddit names");

        NSURL *rewritten = ApolloRandomURLByReplacingCommunity(
            [NSURL URLWithString:@"https://oauth.reddit.com/r/random/hot.json?limit=25&raw_json=1"],
            @"random", @"pics");
        Check([rewritten.absoluteString isEqualToString:
               @"https://oauth.reddit.com/r/pics/hot.json?limit=25&raw_json=1"],
              @"replacing the community keeps the sort and query");
        Check(ApolloRandomURLByReplacingCommunity(rewritten, @"random", @"games") == nil,
              @"a URL that no longer names the old community is left alone");

        // Kind inference: stored kind, then the record of picks, then the one
        // list that holds the community. Undecidable is None, never a guess.
        Check(ApolloRandomInferKind(nil, nil, @[@"nsfw1"], ApolloRandomFeedKindNone, nil, safe, nsfw) == ApolloRandomFeedKindNSFW,
              @"a community only on the NSFW list is an NSFW feed");
        Check(ApolloRandomInferKind(nil, nil, @[@"r/Pics"], ApolloRandomFeedKindNone, nil, safe, nsfw) == ApolloRandomFeedKindSafe,
              @"a community only on the safe list is a safe feed");
        Check(ApolloRandomInferKind(nil, nil, @[@"both"], ApolloRandomFeedKindNone, nil, @[@"both"], @[@"both"]) == ApolloRandomFeedKindNone,
              @"a community on both lists is undecidable");
        Check(ApolloRandomInferKind(nil, nil, @[@"elsewhere"], ApolloRandomFeedKindNone, nil, safe, nsfw) == ApolloRandomFeedKindNone,
              @"a community on neither list is undecidable, never safe by default");
        Check(ApolloRandomInferKind(nil, nil, @[@"pics"], ApolloRandomFeedKindNone, nil, safe, nil) == ApolloRandomFeedKindNone,
              @"an unloaded (evicted) NSFW list cannot rule NSFW out");
        Check(ApolloRandomInferKind(nil, nil, @[@"pics"], ApolloRandomFeedKindNone, nil, safe, @[]) == ApolloRandomFeedKindSafe,
              @"an unconfigured (empty) NSFW list is known to hold nothing");
        Check(ApolloRandomInferKind(nil, @"randnsfw", @[@"aww"], ApolloRandomFeedKindNone, @{@"aww": @(ApolloRandomFeedKindSafe)}, safe, nsfw) ==
                  ApolloRandomFeedKindNSFW &&
              ApolloRandomInferKind(nil, @" r/Random", @[], ApolloRandomFeedKindNone, nil, nil, nil) == ApolloRandomFeedKindNone,
              @"an NSFW placeholder title names the kind; \"Random\" (written for both feeds) names none");
        Check(ApolloRandomInferKind(nil, nil, @[@"aww", @"nsfw1"], ApolloRandomFeedKindNone, nil, safe, nsfw) == ApolloRandomFeedKindNone,
              @"names spread over both lists are undecidable");
        Check(ApolloRandomInferKind(nil, nil, @[@"r/Pics"], ApolloRandomFeedKindNone, @{@"pics": @(ApolloRandomFeedKindNSFW)},
                                    nil, nil) == ApolloRandomFeedKindNSFW,
              @"the record of picks decides when the lists are gone");
        Check(ApolloRandomInferKind(nil, @"pics", @[@"pics"], ApolloRandomFeedKindNone, @{@"pics": @(ApolloRandomFeedKindNSFW)},
                                    safe, nsfw) == ApolloRandomFeedKindNSFW,
              @"the record of picks wins over list membership");
        Check(ApolloRandomInferKind(nil, nil, @[@"shown", @"requested"], ApolloRandomFeedKindNone,
                                    @{@"shown": @(ApolloRandomFeedKindNSFW), @"requested": @(ApolloRandomFeedKindSafe)},
                                    nil, nil) == ApolloRandomFeedKindNSFW,
              @"the shown name's record wins over the requested name's");

        // The record of picks is bounded, oldest first, and refreshes a re-pick.
        NSMutableDictionary *kinds = [NSMutableDictionary dictionary];
        NSMutableArray *order = [NSMutableArray array];
        ApolloRandomRememberPickedKind(kinds, order, @"a1", ApolloRandomFeedKindSafe, 2);
        ApolloRandomRememberPickedKind(kinds, order, @"a2", ApolloRandomFeedKindNSFW, 2);
        ApolloRandomRememberPickedKind(kinds, order, @"R/A1", ApolloRandomFeedKindSafe, 2);
        ApolloRandomRememberPickedKind(kinds, order, @"a3", ApolloRandomFeedKindNSFW, 2);
        ApolloRandomRememberPickedKind(kinds, order, @"a4", ApolloRandomFeedKindNone, 2);
        Check(kinds.count == 2 && kinds[@"a1"] && kinds[@"a3"] && !kinds[@"a2"] && !kinds[@"a4"] &&
              [order isEqualToArray:(@[@"a1", @"a3"])],
              @"the record keeps the newest picks and ignores an unknown kind");

        // Arm planning.
        ApolloRandomArmInput *firstPull = [ApolloRandomArmInput new];
        firstPull.title = @"pics";
        firstPull.requestedNames = @[@"pics"];
        ApolloRandomArmPlan *firstPlan = ApolloRandomPlanArm(firstPull, nil, safe, nsfw, First);
        Check(firstPlan.outcome == ApolloRandomArmOutcomeArmed && firstPlan.kind == ApolloRandomFeedKindSafe &&
              [firstPlan.shownName isEqualToString:@"pics"] && [firstPlan.leavingNames isEqualToArray:(@[@"pics"])] &&
              [firstPlan.pickedName isEqualToString:@"aww"],
              @"a pull on a resolved community leaves it");

        // Banned pick B ("games") is shown, Apollo's model still requests A
        // ("aww") and its Swift randomSubredditName may name yet another.
        ApolloRandomArmInput *afterBan = [ApolloRandomArmInput new];
        afterBan.previousActive = YES;
        afterBan.previousRolledName = @"games";
        afterBan.previousLeavingNames = @[@"aww"];
        afterBan.title = @"games";
        afterBan.requestedNames = @[@"aww", @"r/pics"];
        ApolloRandomArmPlan *afterBanPlan = ApolloRandomPlanArm(afterBan, @{@"games": @(ApolloRandomFeedKindSafe)},
                                                                @[@"aww", @"pics", @"games", @"tea"],
                                                                nil, First);
        Check(afterBanPlan.outcome == ApolloRandomArmOutcomeArmed &&
              [afterBanPlan.shownName isEqualToString:@"games"] &&
              ApolloRandomNamesContain(afterBanPlan.leavingNames, @"games") &&
              ApolloRandomNamesContain(afterBanPlan.leavingNames, @"aww") &&
              ApolloRandomNamesContain(afterBanPlan.leavingNames, @"pics") &&
              [afterBanPlan.pickedName isEqualToString:@"tea"],
              @"after a banned roll the pull leaves shown, requested and the Swift name");

        // Consecutive banned rolls never go back: the unconfirmed guard's own
        // leaving names stay excluded even when the model has moved on.
        ApolloRandomArmInput *secondBan = [ApolloRandomArmInput new];
        secondBan.previousActive = YES;
        secondBan.previousRolledName = @"tea";
        secondBan.previousLeavingNames = @[@"games", @"aww", @"pics"];
        secondBan.title = @"tea";
        secondBan.requestedNames = @[@"aww"];
        NSDictionary *teaSafe = @{@"tea": @(ApolloRandomFeedKindSafe)};
        ApolloRandomArmPlan *secondBanPlan = ApolloRandomPlanArm(secondBan, teaSafe, @[@"aww", @"pics", @"games", @"tea", @"zoo"],
                                                                 nil, First);
        Check([secondBanPlan.pickedName isEqualToString:@"zoo"],
              @"a second banned roll excludes every earlier leaving community");
        secondBan.previousConfirmed = YES;
        ApolloRandomArmPlan *confirmedPlan = ApolloRandomPlanArm(secondBan, teaSafe, @[@"aww", @"pics", @"games", @"tea", @"zoo"],
                                                                 nil, First);
        Check([confirmedPlan.shownName isEqualToString:@"tea"] &&
              !ApolloRandomNamesContain(confirmedPlan.leavingNames, @"games") &&
              [confirmedPlan.pickedName isEqualToString:@"pics"],
              @"a confirmed guard's old leaving names are not carried forward");

        // A banned first pick left the placeholder title: the pick record knows
        // the kind even though the title names no community.
        ApolloRandomArmInput *placeholder = [ApolloRandomArmInput new];
        placeholder.title = @"randnsfw";
        placeholder.requestedNames = @[@"nsfw1"];
        ApolloRandomArmPlan *placeholderPlan = ApolloRandomPlanArm(placeholder, @{@"nsfw1": @(ApolloRandomFeedKindNSFW)},
                                                                   safe, nil, First);
        Check(placeholderPlan.outcome == ApolloRandomArmOutcomeNoCandidate && placeholderPlan.kind == ApolloRandomFeedKindNSFW,
              @"an NSFW feed whose list is not loaded does not arm, and never draws from the safe list");
        placeholderPlan = ApolloRandomPlanArm(placeholder, @{@"nsfw1": @(ApolloRandomFeedKindNSFW)}, safe, nsfw, First);
        Check(placeholderPlan.outcome == ApolloRandomArmOutcomeArmed && !placeholderPlan.shownName &&
              [placeholderPlan.pickedName isEqualToString:@"nsfw2"],
              @"a placeholder title still arms from the requested community");
        ApolloRandomArmInput *unknown = [ApolloRandomArmInput new];
        unknown.title = @"elsewhere";
        Check(ApolloRandomPlanArm(unknown, nil, safe, nsfw, First).outcome == ApolloRandomArmOutcomeKindUnknown &&
              ApolloRandomPlanArm(unknown, nil, safe, nsfw, First).pickedName == nil,
              @"an undecidable kind does not arm");

        // Hard and soft exclusions: [A,B,C], A shown first, B then C banned.
        NSArray *abc = @[@"A", @"B", @"C"];
        ApolloRandomArmInput *pullA = [ApolloRandomArmInput new];
        pullA.title = @"A";
        pullA.requestedNames = @[@"A"];
        ApolloRandomArmPlan *pickB = ApolloRandomPlanArm(pullA, nil, abc, @[], First);
        Check([pickB.pickedName isEqualToString:@"B"], @"the first pull leaves A");
        ApolloRandomArmInput *pullB = [ApolloRandomArmInput new];
        pullB.previousActive = YES;
        pullB.previousRolledName = pickB.pickedName;
        pullB.previousLeavingNames = pickB.leavingNames;
        pullB.title = @"B";
        pullB.requestedNames = @[@"A"];
        ApolloRandomArmPlan *pickC = ApolloRandomPlanArm(pullB, nil, abc, @[], First);
        Check([pickC.pickedName isEqualToString:@"C"], @"B was banned: the second pull leaves B and A");
        ApolloRandomArmInput *pullC = [ApolloRandomArmInput new];
        pullC.previousActive = YES;
        pullC.previousRolledName = pickC.pickedName;
        pullC.previousLeavingNames = pickC.leavingNames;
        pullC.title = @"C";
        pullC.requestedNames = @[@"A"];
        for (size_t index = 0; index < sizeof(bounds) / sizeof(bounds[0]); index++) {
            ApolloRandomArmPlan *third = ApolloRandomPlanArm(pullC, nil, abc, @[], bounds[index]);
            Check([third.pickedName isEqualToString:@"B"] && third.kind == ApolloRandomFeedKindSafe,
                  @"when history runs out an earlier roll comes back, never the shown or requested community");
        }
        Check([ApolloRandomPickSubreddit(@[@"A", @"B"], @[@"A", @"B"], @[@"A"], First) length] > 0 &&
              [ApolloRandomPickSubreddit(@[@"A"], @[@"A"], nil, Last) isEqualToString:@"A"],
              @"a list with nothing but hard names still loads");
        Check([ApolloRandomPickSubreddit(@[@"A", @"B", @"C"], @[@"A"], @[@"B"], First) isEqualToString:@"C"] &&
              [ApolloRandomPickSubreddit(@[@"A", @"B"], @[@"A"], @[@"B"], First) isEqualToString:@"B"],
              @"soft names give way only when nothing else is left");

        // The kind is read from the screen, not remembered on the controller:
        // a jump-bar switch from Random to Random NSFW in the same feed.
        ApolloRandomArmInput *switched = [ApolloRandomArmInput new];
        switched.previousActive = NO;
        switched.previousRolledName = @"pics";
        switched.previousLeavingNames = @[@"aww"];
        switched.title = @"nsfw1";
        switched.requestedNames = @[@"nsfw1"];
        ApolloRandomArmPlan *switchedPlan = ApolloRandomPlanArm(switched,
            @{@"pics": @(ApolloRandomFeedKindSafe), @"nsfw1": @(ApolloRandomFeedKindNSFW)}, safe, nsfw, First);
        Check(switchedPlan.outcome == ApolloRandomArmOutcomeArmed && switchedPlan.kind == ApolloRandomFeedKindNSFW &&
              [switchedPlan.pickedName isEqualToString:@"nsfw2"],
              @"after switching the feed to Random NSFW the pull draws from the NSFW list");

        // A banned NSFW first pick left the "randnsfw" placeholder, the record
        // is empty (relaunch), and Apollo's model names nothing useful.
        ApolloRandomArmInput *bannedNSFW = [ApolloRandomArmInput new];
        bannedNSFW.title = @"randnsfw";
        ApolloRandomArmPlan *bannedNSFWPlan = ApolloRandomPlanArm(bannedNSFW, @{}, safe, nsfw, Last);
        Check(bannedNSFWPlan.outcome == ApolloRandomArmOutcomeArmed && bannedNSFWPlan.kind == ApolloRandomFeedKindNSFW &&
              ApolloRandomNamesContain(nsfw, bannedNSFWPlan.pickedName),
              @"the randnsfw placeholder alone arms an NSFW roll");

        // Sticky route predicate.
        Check(ApolloRandomRequestNamesLeaving(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNone, @"aww", NO, @[@"aww"]) &&
              ApolloRandomRequestNamesLeaving(ApolloRandomRequestRoleAbout, ApolloRandomFeedKindNone, @"AWW", NO, @[@"aww"]),
              @"a first-page listing or about of a leaving community takes the sticky route");
        Check(!ApolloRandomRequestNamesLeaving(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNone, @"aww", YES, @[@"aww"]) &&
              !ApolloRandomRequestNamesLeaving(ApolloRandomRequestRolePosts, ApolloRandomFeedKindSafe, @"random", NO, @[@"aww"]) &&
              !ApolloRandomRequestNamesLeaving(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNone, @"games", NO, @[@"aww"]),
              @"later pages, explicit random and other communities do not");

        // Without an armed pull-to-refresh nothing but an explicit random rolls:
        // a sort change, a filter toggle or an Apollo-internal reload of the
        // shown community goes out unchanged.
        Check(Route(@"/r/games/top.json", @"t=day", nil, 10, safe, nsfw, First) == nil,
              @"a sort change without an armed refresh does not roll");
        Check(Route(@"/r/games/hot.json", nil, nil, 10, safe, nsfw, First) == nil,
              @"a reload without an armed refresh does not roll");
        Check(Route(@"/r/games/about.json", nil, nil, 10, safe, nsfw, First) == nil,
              @"an about without an armed refresh does not roll");

        // Explicit random requests always get a pick, even with no feed state
        // (off the main thread, or before the feed is visible).
        ApolloRandomRoute *stateless = Route(@"/r/random/hot.json", @"limit=25", nil, 10, safe, nsfw, Last);
        Check(stateless.source == ApolloRandomRouteSourceStateless &&
              stateless.kind == ApolloRandomFeedKindSafe && [stateless.name isEqualToString:@"games"],
              @"an explicit /r/random gets a stateless pick from the safe list");
        ApolloRandomRoute *statelessNSFW = Route(@"/r/randnsfw.json", nil, nil, 10, safe, nsfw, Last);
        Check(statelessNSFW.source == ApolloRandomRouteSourceStateless &&
              statelessNSFW.kind == ApolloRandomFeedKindNSFW && [statelessNSFW.name isEqualToString:@"nsfw2"],
              @"an explicit /r/randnsfw gets a stateless pick from the NSFW list");
        Check(Route(@"/r/random/about.json", nil, nil, 10, safe, nsfw, First).source == ApolloRandomRouteSourceStateless,
              @"an explicit random about is rewritten too, as before");
        Check(Route(@"/r/random/hot.json", nil, nil, 10, nil, nsfw, First) == nil,
              @"an explicit random with no cached list goes out unchanged");
        Check(Route(@"/r/random/hot.json", @"after=t3_abc", nil, 10, safe, nsfw, First) == nil,
              @"a later page of an explicit random is not rewritten");

        // A banned roll left the screen on B while Apollo's model still says A,
        // so its refresh asks for /r/A/hot. The armed roll leaves both.
        ApolloRandomPendingRoll *armed = Pending(ApolloRandomFeedKindSafe, @[@"pics", @"aww"],
                                                 ApolloRandomPickSubreddit(safe, @[@"pics", @"aww"], nil, Middle),
                                                 100, 0);
        Check([armed.pickedName isEqualToString:@"games"], @"the armed pick is neither shown nor requested");
        ApolloRandomRoute *listing = Route(@"/r/aww/hot.json", @"limit=25", armed, 101, safe, nsfw, First);
        Check(listing.source == ApolloRandomRouteSourcePending && [listing.name isEqualToString:@"games"],
              @"an armed refresh of the requested community uses the pick");
        Check(Route(@"/r/aww/hot.json", @"after=t3_x", armed, 101, safe, nsfw, First) == nil,
              @"a later page is not part of the roll");
        armed.consumedAt = 101;

        // The about of either leaving name joins the same pick, even after a
        // slow listing, while the reuse window lasts.
        ApolloRandomRoute *aboutShown = Route(@"/r/Pics/about.json", nil, armed, 108, safe, nsfw, Last);
        ApolloRandomRoute *aboutRequested = Route(@"/r/aww/about.json", nil, armed, 110, safe, nsfw, Last);
        Check(aboutShown.source == ApolloRandomRouteSourcePending && [aboutShown.name isEqualToString:@"games"] &&
              aboutRequested.source == ApolloRandomRouteSourcePending && [aboutRequested.name isEqualToString:@"games"],
              @"the about of either leaving community shares the pick");
        Check(Route(@"/r/games/about.json", nil, armed, 102, safe, nsfw, Last) == nil,
              @"the about of the picked community already names it");
        ApolloRandomRoute *explicitDuringRoll = Route(@"/r/random/hot.json", nil, armed, 102, safe, nsfw, First);
        Check(explicitDuringRoll.source == ApolloRandomRouteSourcePending &&
              [explicitDuringRoll.name isEqualToString:@"games"],
              @"an explicit random listing of the roll's kind within the grace joins the roll");
        ApolloRandomRoute *explicitAfterGrace = Route(@"/r/random/hot.json", nil, armed, 101 + kApolloRandomListingGrace,
                                                      safe, nsfw, First);
        Check(explicitAfterGrace.source == ApolloRandomRouteSourceStateless &&
              explicitAfterGrace.kind == ApolloRandomFeedKindSafe && explicitAfterGrace.supersedesPending,
              @"an explicit random listing after the grace is a new stateless load that replaces the roll");
        ApolloRandomRoute *explicitAboutLate = Route(@"/r/random/about.json", nil, armed, 109, safe, nsfw, Last);
        Check(explicitAboutLate.source == ApolloRandomRouteSourcePending && [explicitAboutLate.name isEqualToString:@"games"] &&
              !explicitAboutLate.supersedesPending,
              @"an explicit random about keeps joining the roll for the whole reuse window");
        ApolloRandomPendingRoll *fresh = Pending(ApolloRandomFeedKindSafe, @[@"pics"], @"games", 100, 0);
        ApolloRandomRoute *beforeUse = Route(@"/r/random/hot.json", nil, fresh, 104, safe, nsfw, First);
        Check(beforeUse.source == ApolloRandomRouteSourcePending && [beforeUse.name isEqualToString:@"games"],
              @"an explicit random listing joins a roll no request has used yet, whatever its age in the arm window");
        ApolloRandomRoute *otherKind = Route(@"/r/randnsfw/hot.json", nil, armed, 102, safe, nsfw, First);
        Check(otherKind.source == ApolloRandomRouteSourceStateless && otherKind.kind == ApolloRandomFeedKindNSFW &&
              [otherKind.name isEqualToString:@"nsfw1"],
              @"an explicit random of the other kind never uses the roll");
        Check(Route(@"/r/elsewhere/hot.json", nil, armed, 102, safe, nsfw, First) == nil,
              @"an unrelated community is never rerolled");

        // Expiry.
        Check(Route(@"/r/aww/about.json", nil, armed, 101 + kApolloRandomReuseWindow + 1, safe, nsfw, First) == nil,
              @"after the reuse window the leaving community loads normally");
        Check(!ApolloRandomPendingRollIsLive(armed, 101 + kApolloRandomReuseWindow + 1),
              @"a used roll expires after the reuse window");
        ApolloRandomPendingRoll *stale = Pending(ApolloRandomFeedKindSafe, @[@"aww"], @"games", 100, 0);
        Check(Route(@"/r/aww/hot.json", nil, stale, 100 + kApolloRandomArmWindow + 1, safe, nsfw, First) == nil,
              @"an armed roll no request used expires after the arm window");
        Check(Route(@"/r/aww/hot.json", nil, stale, 99, safe, nsfw, First) == nil,
              @"a clock that went backwards does not keep a roll alive");

        // Title guard verdicts.
        NSString *title = nil;
        Check(ApolloRandomJudgeTitle(@"aww", @[@"pics", @"aww"], @"games", NO, &title) == ApolloRandomTitleVerdictRewrite &&
              [title isEqualToString:@"games"],
              @"a write of a leaving community becomes the rolled one");
        Check(ApolloRandomJudgeTitle(@"r/AWW", @[@"aww"], @"games", NO, &title) == ApolloRandomTitleVerdictRewrite &&
              [title isEqualToString:@"r/games"],
              @"the r/ prefix survives the rewrite");
        Check(ApolloRandomJudgeTitle(@"aww", @[@"aww"], @"games", YES, &title) == ApolloRandomTitleVerdictRelease && !title,
              @"once confirmed, a leaving community is a genuine write");
        Check(ApolloRandomJudgeTitle(@"Games", @[@"aww"], @"games", NO, &title) == ApolloRandomTitleVerdictConfirm && !title,
              @"Apollo writing the rolled community confirms the guard");
        Check(ApolloRandomJudgeTitle(@"science", @[@"aww"], @"games", NO, &title) == ApolloRandomTitleVerdictRelease,
              @"another community ends the guard");
        Check(ApolloRandomJudgeTitle(@"Random", @[@"aww"], @"games", NO, &title) == ApolloRandomTitleVerdictRewrite &&
              [title isEqualToString:@"games"],
              @"an unconfirmed guard replaces the random placeholder");
        Check(ApolloRandomJudgeTitle(@"r/randnsfw", @[], @"nsfw2", NO, &title) == ApolloRandomTitleVerdictRewrite &&
              [title isEqualToString:@"r/nsfw2"],
              @"the randnsfw placeholder keeps its prefix");
        Check(ApolloRandomJudgeTitle(@"Random", @[@"aww"], @"games", YES, &title) == ApolloRandomTitleVerdictRelease,
              @"after confirmation a placeholder is a new random load");
        Check(ApolloRandomJudgeTitle(@"Modded Subs", @[@"aww"], @"games", NO, &title) == ApolloRandomTitleVerdictKeep &&
              ApolloRandomJudgeTitle(nil, @[@"aww"], @"games", NO, &title) == ApolloRandomTitleVerdictKeep,
              @"text that is not one community is left alone");

        // Kind from the JumpBar label: Apollo writes navigationItem.title =
        // "Random" on both feeds, while the label shows "Random" / "RandNSFW".
        Check(ApolloRandomInferKind(@"RandNSFW", @"Random", @[], ApolloRandomFeedKindNone, nil, nil, nil) ==
                  ApolloRandomFeedKindNSFW,
              @"a RandNSFW label beats the Random title");
        Check(ApolloRandomInferKind(@"Random", @"Random", @[], ApolloRandomFeedKindNone, nil, nil, nil) ==
                  ApolloRandomFeedKindSafe,
              @"a Random label is a safe feed");
        Check(ApolloRandomInferKind(nil, @"Random", @[], ApolloRandomFeedKindNone, nil, safe, nsfw) ==
                  ApolloRandomFeedKindNone,
              @"a Random title alone cannot tell safe from NSFW");
        Check(ApolloRandomInferKind(nil, @"randnsfw", @[], ApolloRandomFeedKindNone, nil, nil, nil) ==
                  ApolloRandomFeedKindNSFW,
              @"a randnsfw title still names NSFW");
        Check(ApolloRandomInferKind(nil, @"Random", @[@"x"], ApolloRandomFeedKindNSFW, nil, nil, nil) ==
                  ApolloRandomFeedKindNSFW,
              @"the feed's routed kind decides when nothing else can");
        Check(ApolloRandomInferKind(@"Random", @"Random", @[@"x"], ApolloRandomFeedKindNSFW,
                                    @{@"x": @(ApolloRandomFeedKindNSFW)}, nil, nil) == ApolloRandomFeedKindSafe,
              @"a label placeholder beats the routed kind and the record of picks");
        Check(ApolloRandomInferKind(nil, nil, @[@"x"], ApolloRandomFeedKindSafe,
                                    @{@"x": @(ApolloRandomFeedKindNSFW)}, nil, nil) == ApolloRandomFeedKindNSFW,
              @"the record of the shown pick beats a routed kind");

        // A failed first load: Random NSFW landed on banned X, Apollo's model
        // names nothing, the title reads "Random" and the label "RandNSFW" (or
        // X, once the claimed guard rewrote it).
        NSArray *bannedNSFWList = @[@"n1", @"n2", @"n3", @"n4", @"n5", @"n6"];
        for (size_t index = 0; index < sizeof(bounds) / sizeof(bounds[0]); index++) {
            ApolloRandomArmInput *failed = [ApolloRandomArmInput new];
            failed.title = @"Random";
            failed.labelText = @"RandNSFW";
            failed.routedName = @"n1";
            failed.routedKind = ApolloRandomFeedKindNSFW;
            ApolloRandomArmPlan *failedPlan = ApolloRandomPlanArm(failed, nil, safe, bannedNSFWList, bounds[index]);
            Check(failedPlan.outcome == ApolloRandomArmOutcomeArmed && failedPlan.kind == ApolloRandomFeedKindNSFW &&
                      ApolloRandomNamesContain(failedPlan.leavingNames, @"n1") &&
                      ApolloRandomNamesContain(bannedNSFWList, failedPlan.pickedName) &&
                      ![failedPlan.pickedName isEqualToString:@"n1"],
                  @"a failed-load arm draws NSFW and leaves the feed's routed community");
        }
        ApolloRandomArmInput *noLabel = [ApolloRandomArmInput new];
        noLabel.title = @"Random";
        noLabel.routedName = @"n1";
        noLabel.routedKind = ApolloRandomFeedKindNSFW;
        ApolloRandomArmPlan *noLabelPlan = ApolloRandomPlanArm(noLabel, nil, safe, bannedNSFWList, First);
        Check(noLabelPlan.outcome == ApolloRandomArmOutcomeArmed && noLabelPlan.kind == ApolloRandomFeedKindNSFW &&
                  [noLabelPlan.pickedName isEqualToString:@"n2"],
              @"without a label the routed kind still keeps the feed on the NSFW list");

        // Recent picks of one kind, newest first.
        NSDictionary *recentKinds = @{@"n1": @(ApolloRandomFeedKindNSFW), @"aww": @(ApolloRandomFeedKindSafe),
                                      @"n2": @(ApolloRandomFeedKindNSFW)};
        NSArray *recentOrder = @[@"n1", @"aww", @"n2"];
        Check([ApolloRandomRecentPicks(recentKinds, recentOrder, ApolloRandomFeedKindNSFW)
                  isEqualToArray:(@[@"n2", @"n1"])] &&
                  [ApolloRandomRecentPicks(recentKinds, recentOrder, ApolloRandomFeedKindSafe) isEqualToArray:(@[@"aww"])] &&
                  ApolloRandomRecentPicks(recentKinds, recentOrder, ApolloRandomFeedKindNone).count == 0,
              @"recent picks are filtered by kind, newest first");

        // The recency-aware picker.
        NSArray *abcd = @[@"A", @"B", @"C", @"D"];
        for (size_t index = 0; index < sizeof(bounds) / sizeof(bounds[0]); index++) {
            NSString *pick = ApolloRandomPickSubredditAvoidingRecent(abcd, nil, @[@"B", @"a"], bounds[index]);
            Check([pick isEqualToString:@"C"] || [pick isEqualToString:@"D"], @"recent picks are avoided while others remain");
            Check([ApolloRandomPickSubredditAvoidingRecent(abcd, nil, @[@"D", @"C", @"B", @"A"], bounds[index])
                      isEqualToString:@"A"],
                  @"when every entry is recent, the least recent comes back, never the last pick");
            Check([ApolloRandomPickSubredditAvoidingRecent(abcd, @[@"A"], @[@"D", @"C", @"B", @"A"], bounds[index])
                      isEqualToString:@"B"],
                  @"a hard name stays out even when it is the least recent");
        }
        Check([ApolloRandomPickSubredditAvoidingRecent(@[@"A"], @[@"A"], @[@"A"], First) isEqualToString:@"A"] &&
                  ApolloRandomPickSubredditAvoidingRecent(@[], nil, nil, First) == nil,
              @"a one-entry list still loads; an empty one gives nothing");

        // Stateless picks avoid recent picks of their own kind only.
        for (size_t index = 0; index < sizeof(bounds) / sizeof(bounds[0]); index++) {
            ApolloRandomRoute *fresh = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNSFW,
                                                                @"randnsfw", NO, nil, nil, 10, safe, @[@"n1", @"n2", @"n3"],
                                                                recentKinds, recentOrder, bounds[index]);
            Check(fresh.source == ApolloRandomRouteSourceStateless && !fresh.repicked &&
                      [fresh.name isEqualToString:@"n3"],
                  @"a stateless NSFW pick skips recent NSFW picks");
            ApolloRandomRoute *safeFresh = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindSafe,
                                                                    @"random", NO, nil, nil, 10, @[@"aww", @"pics"], nsfw,
                                                                    recentKinds, recentOrder, bounds[index]);
            Check([safeFresh.name isEqualToString:@"pics"], @"a stateless safe pick skips only recent safe picks");
        }
        ApolloRandomRoute *cycled = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNSFW,
                                                             @"randnsfw", NO, nil, nil, 10, safe, @[@"n1", @"n2"],
                                                             recentKinds, recentOrder, Last);
        Check([cycled.name isEqualToString:@"n1"], @"a stateless pick over an exhausted list takes the least recent");

        // A roll armed with the wrong kind meets the pull's own refresh of the
        // other kind: it is re-picked from the path kind's list.
        for (size_t index = 0; index < sizeof(bounds) / sizeof(bounds[0]); index++) {
            ApolloRandomPendingRoll *wrongKind = Pending(ApolloRandomFeedKindSafe, @[@"n1"], @"aww", 100, 0);
            ApolloRandomRoute *repick = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNSFW,
                                                                 @"randnsfw", NO, wrongKind, nil, 101, safe, bannedNSFWList,
                                                                 @{@"n2": @(ApolloRandomFeedKindNSFW)}, @[@"n2"],
                                                                 bounds[index]);
            Check(repick.source == ApolloRandomRouteSourcePending && repick.repicked &&
                      repick.kind == ApolloRandomFeedKindNSFW && ApolloRandomNamesContain(bannedNSFWList, repick.name) &&
                      ![repick.name isEqualToString:@"n1"] && ![repick.name isEqualToString:@"n2"],
                  @"a kind mismatch re-picks from the path kind's list, leaving the roll's names and recent picks");
        }
        ApolloRandomPendingRoll *usedWrongKind = Pending(ApolloRandomFeedKindSafe, @[@"n1"], @"aww", 100, 101);
        ApolloRandomRoute *afterUse = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNSFW,
                                                               @"randnsfw", NO, usedWrongKind, nil, 102, safe, bannedNSFWList,
                                                               nil, nil, First);
        Check(afterUse.source == ApolloRandomRouteSourceStateless && !afterUse.repicked,
              @"a roll a request already used never takes the other kind");

        // Which on-screen random feed a stateless listing belongs to.
        Check(ApolloRandomFeedTakesRoute(@"RandNSFW", @"Random", @[], nil, ApolloRandomFeedKindNSFW) &&
                  !ApolloRandomFeedTakesRoute(@"RandNSFW", @"Random", @[], nil, ApolloRandomFeedKindSafe) &&
                  ApolloRandomFeedTakesRoute(@"Random", @"Random", @[], nil, ApolloRandomFeedKindSafe),
              @"a placeholder label takes a route of its own kind only");
        Check(ApolloRandomFeedTakesRoute(nil, @"Random", @[], nil, ApolloRandomFeedKindNSFW) &&
                  ApolloRandomFeedTakesRoute(@"", @"randnsfw", @[], nil, ApolloRandomFeedKindSafe),
              @"without a label any placeholder title takes the route");
        Check(ApolloRandomFeedTakesRoute(@"n1", @"n1", @[], @"r/n1", ApolloRandomFeedKindNSFW) &&
                  ApolloRandomFeedTakesRoute(nil, @"n1", @[], @"n1", ApolloRandomFeedKindSafe),
              @"a feed showing its own failed route takes the next one");
        Check(!ApolloRandomFeedTakesRoute(@"n1", @"n1", @[@"N1"], @"n1", ApolloRandomFeedKindNSFW),
              @"a feed whose route loaded (the model names it) does not");
        Check(!ApolloRandomFeedTakesRoute(@"pics", @"pics", @[], @"n1", ApolloRandomFeedKindNSFW) &&
                  !ApolloRandomFeedTakesRoute(@"pics", @"pics", @[], nil, ApolloRandomFeedKindNSFW) &&
                  !ApolloRandomFeedTakesRoute(@"RandNSFW", nil, @[], nil, ApolloRandomFeedKindNone),
              @"an unrelated community, or no kind, takes nothing");

        // A pending roll matches a named request by its hard names only: a
        // soft name (left by an earlier banned roll) is kept out of picks but
        // another feed asking for it is not rerolled.
        ApolloRandomPendingRoll *withSoft = Pending(ApolloRandomFeedKindSafe, @[@"pics"], @"games", 100, 0);
        withSoft.leavingNames = @[@"pics", @"aww"];
        Check(Route(@"/r/aww/hot.json", nil, withSoft, 101, safe, nsfw, First) == nil &&
                  Route(@"/r/aww/about.json", nil, withSoft, 101, safe, nsfw, First) == nil,
              @"a request naming a soft leaving community goes out unchanged");
        Check(Route(@"/r/pics/hot.json", nil, withSoft, 101, safe, nsfw, First).source == ApolloRandomRouteSourcePending,
              @"a request naming a hard leaving community takes the roll");
        ApolloRandomArmInput *softInput = [ApolloRandomArmInput new];
        softInput.previousActive = YES;
        softInput.previousRolledName = @"games";
        softInput.previousLeavingNames = @[@"aww"];
        softInput.title = @"games";
        softInput.requestedNames = @[@"pics"];
        ApolloRandomArmPlan *softPlan = ApolloRandomPlanArm(softInput, @{@"games": @(ApolloRandomFeedKindSafe)},
                                                            @[@"aww", @"pics", @"games", @"tea"], @[], First);
        Check([softPlan.hardNames isEqualToArray:(@[@"games", @"pics"])] &&
                  [softPlan.leavingNames isEqualToArray:(@[@"games", @"pics", @"aww"])] &&
                  [softPlan.pickedName isEqualToString:@"tea"],
              @"the plan keeps hard names apart from soft ones and still avoids both");

        // Stateless listing/about pairs share one community.
        NSArray *pairList = @[@"p1", @"p2", @"p3", @"p4"];
        ApolloRandomRoute *pairListing = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindSafe,
                                                                  @"random", NO, nil, nil, 50, pairList, nsfw,
                                                                  nil, nil, First);
        ApolloRandomStatelessMemo *memo = ApolloRandomStatelessMemoAfterRoute(nil, pairListing, ApolloRandomRequestRolePosts, 50);
        ApolloRandomRoute *pairAbout = ApolloRandomRouteRequest(ApolloRandomRequestRoleAbout, ApolloRandomFeedKindSafe,
                                                                @"random", NO, nil, memo, 52, pairList, nsfw,
                                                                @{@"p1": @(ApolloRandomFeedKindSafe)}, @[@"p1"], Last);
        Check([pairListing.name isEqualToString:@"p1"] && pairAbout.source == ApolloRandomRouteSourceStateless &&
                  pairAbout.reusedStateless && [pairAbout.name isEqualToString:@"p1"],
              @"listing then about: the about reuses the listing's community");
        memo = ApolloRandomStatelessMemoAfterRoute(memo, pairAbout, ApolloRandomRequestRoleAbout, 52);
        Check(memo.servedPosts && memo.servedAbout && memo.routedAt == 50,
              @"a reuse marks the role served without refreshing the memo's time");
        ApolloRandomRoute *secondListing = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindSafe,
                                                                    @"random", NO, nil, memo, 53, pairList, nsfw,
                                                                    @{@"p1": @(ApolloRandomFeedKindSafe)}, @[@"p1"], First);
        Check(!secondListing.reusedStateless && [secondListing.name isEqualToString:@"p2"],
              @"listing then listing: the second listing is a new load and draws again");

        ApolloRandomRoute *aboutFirst = ApolloRandomRouteRequest(ApolloRandomRequestRoleAbout, ApolloRandomFeedKindNSFW,
                                                                 @"randnsfw", NO, nil, nil, 60, safe, pairList, nil, nil, Last);
        ApolloRandomStatelessMemo *nsfwMemo = ApolloRandomStatelessMemoAfterRoute(nil, aboutFirst, ApolloRandomRequestRoleAbout, 60);
        ApolloRandomRoute *thenListing = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNSFW,
                                                                  @"randnsfw", NO, nil, nsfwMemo, 61, safe, pairList,
                                                                  @{@"p4": @(ApolloRandomFeedKindNSFW)}, @[@"p4"], First);
        Check([aboutFirst.name isEqualToString:@"p4"] && thenListing.reusedStateless &&
                  [thenListing.name isEqualToString:@"p4"],
              @"about then listing: the listing reuses the about's community");
        nsfwMemo = ApolloRandomStatelessMemoAfterRoute(nsfwMemo, thenListing, ApolloRandomRequestRolePosts, 61);
        ApolloRandomRoute *againListing = ApolloRandomRouteRequest(ApolloRandomRequestRolePosts, ApolloRandomFeedKindNSFW,
                                                                   @"randnsfw", NO, nil, nsfwMemo, 62, safe, pairList,
                                                                   @{@"p4": @(ApolloRandomFeedKindNSFW)}, @[@"p4"], Last);
        Check(!againListing.reusedStateless && ![againListing.name isEqualToString:@"p4"],
              @"about, listing, listing: the third request is a new load");

        ApolloRandomStatelessMemo *safeMemo = ApolloRandomStatelessMemoAfterRoute(nil, pairListing, ApolloRandomRequestRolePosts, 50);
        ApolloRandomRoute *otherKindAbout = ApolloRandomRouteRequest(ApolloRandomRequestRoleAbout, ApolloRandomFeedKindNSFW,
                                                                     @"randnsfw", NO, nil, safeMemo, 51, safe, @[@"n9"],
                                                                     nil, nil, First);
        Check(!otherKindAbout.reusedStateless && [otherKindAbout.name isEqualToString:@"n9"],
              @"a memo of the other kind is never reused");
        ApolloRandomRoute *expiredAbout = ApolloRandomRouteRequest(ApolloRandomRequestRoleAbout, ApolloRandomFeedKindSafe,
                                                                   @"random", NO, nil, safeMemo,
                                                                   50 + kApolloRandomStatelessPairWindow, pairList, nsfw,
                                                                   @{@"p1": @(ApolloRandomFeedKindSafe)}, @[@"p1"], First);
        Check(!expiredAbout.reusedStateless && [expiredAbout.name isEqualToString:@"p2"],
              @"after the pair window the about draws again");
        ApolloRandomRoute *backwardsAbout = ApolloRandomRouteRequest(ApolloRandomRequestRoleAbout, ApolloRandomFeedKindSafe,
                                                                     @"random", NO, nil, safeMemo, 49, pairList, nsfw,
                                                                     nil, nil, Last);
        Check(!backwardsAbout.reusedStateless, @"a clock that went backwards does not reuse the memo");
        Check(ApolloRandomStatelessMemoAfterRoute(safeMemo, nil, ApolloRandomRequestRoleAbout, 55) == safeMemo &&
                  ApolloRandomStatelessMemoAfterRoute(safeMemo, listing, ApolloRandomRequestRolePosts, 55) == safeMemo,
              @"no route or a pending route leaves the memo alone");
        ApolloRandomPendingRoll *livePending = Pending(ApolloRandomFeedKindSafe, @[@"pics"], @"games", 100, 0);
        ApolloRandomStatelessMemo *gamesMemo = ApolloRandomStatelessMemoAfterRoute(nil, pairListing, ApolloRandomRequestRolePosts, 100);
        Check(ApolloRandomRouteRequest(ApolloRandomRequestRoleAbout, ApolloRandomFeedKindSafe, @"random", NO, livePending,
                                       gamesMemo, 101, pairList, nsfw, nil, nil, First).source ==
                  ApolloRandomRouteSourcePending,
              @"a live roll's explicit about still takes the roll before any memo");

        // Kind inference: unambiguous list membership outranks a stale routed
        // kind; the routed kind decides only when membership cannot.
        Check(ApolloRandomInferKind(nil, nil, @[@"pics"], ApolloRandomFeedKindNSFW, nil, safe, nsfw) == ApolloRandomFeedKindSafe,
              @"a community only on the safe list beats a stale NSFW routed kind");
        Check(ApolloRandomInferKind(nil, nil, @[@"nsfw1"], ApolloRandomFeedKindSafe, nil, safe, nsfw) == ApolloRandomFeedKindNSFW,
              @"a community only on the NSFW list beats a stale safe routed kind");
        Check(ApolloRandomInferKind(nil, nil, @[@"both"], ApolloRandomFeedKindNSFW, nil, @[@"both"], @[@"both"]) ==
                  ApolloRandomFeedKindNSFW &&
              ApolloRandomInferKind(nil, nil, @[@"elsewhere"], ApolloRandomFeedKindSafe, nil, safe, nsfw) ==
                  ApolloRandomFeedKindSafe &&
              ApolloRandomInferKind(nil, nil, @[@"pics"], ApolloRandomFeedKindNSFW, nil, safe, nil) == ApolloRandomFeedKindNSFW,
              @"ambiguous or unknown membership falls back to the routed kind");
        // Failed load seen in the simulator: label, title and routed name all
        // the banned community, Apollo's model names nothing.
        ApolloRandomArmInput *bannedLoad = [ApolloRandomArmInput new];
        bannedLoad.labelText = @"bannedsub";
        bannedLoad.title = @"bannedsub";
        bannedLoad.routedName = @"bannedsub";
        bannedLoad.routedKind = ApolloRandomFeedKindNSFW;
        ApolloRandomArmPlan *bannedLoadPlan = ApolloRandomPlanArm(bannedLoad, nil, safe, @[@"bannedsub", @"n7", @"n8"], First);
        Check(bannedLoadPlan.outcome == ApolloRandomArmOutcomeArmed && bannedLoadPlan.kind == ApolloRandomFeedKindNSFW &&
                  [bannedLoadPlan.pickedName isEqualToString:@"n7"],
              @"a failed NSFW load arms an NSFW roll away from the banned community");
        NSArray *sameList = @[@"bannedsub", @"s1", @"s2"];
        ApolloRandomArmPlan *sameListPlan = ApolloRandomPlanArm(bannedLoad, nil, sameList, sameList, First);
        Check(sameListPlan.outcome == ApolloRandomArmOutcomeArmed && sameListPlan.kind == ApolloRandomFeedKindNSFW &&
                  [sameListPlan.pickedName isEqualToString:@"s1"],
              @"identical safe and NSFW lists: the routed kind decides");
        ApolloRandomArmPlan *sameListPicked = ApolloRandomPlanArm(bannedLoad, @{@"bannedsub": @(ApolloRandomFeedKindSafe)},
                                                                  sameList, sameList, First);
        Check(sameListPicked.kind == ApolloRandomFeedKindSafe,
              @"identical lists: the record of picks decides before the routed kind");

        // Pinned path decisions.
        Check(!ApolloRandomMatchSubredditPath(@"/r/random/.json", &role, &kind, &community),
              @"/r/random/.json is not a listing");
        Check(!ApolloRandomMatchSubredditPath(@"/r/random/weird.json", &role, &kind, &community),
              @"an unknown sort is not rewritten");
        NSURL *bare = ApolloRandomURLByReplacingCommunity([NSURL URLWithString:@"https://oauth.reddit.com/r/random.json?limit=1"],
                                                          @"random", @"pics");
        Check([bare.absoluteString isEqualToString:@"https://oauth.reddit.com/r/pics.json?limit=1"],
              @"a bare /r/random.json rewrite keeps the suffix and query");
        Check(ApolloRandomPostsListingHasCursor([NSURL URLWithString:@"https://oauth.reddit.com/r/random/hot.json?before=t3_x"]) &&
                  Route(@"/r/random/hot.json", @"before=t3_x", nil, 10, safe, nsfw, First) == nil,
              @"a before= cursor is a later page and is not rewritten");
        Check(ApolloRandomInferKind(@"Random NSFW", nil, @[], ApolloRandomFeedKindNone, nil, nil, nil) == ApolloRandomFeedKindNone,
              @"a \"Random NSFW\" label (with a space) is not a placeholder and names no kind");

        // Name keys: the fast slug path agrees with full normalization.
        Check(ApolloRandomNamesContain(@[@"AskReddit"], @"r/askreddit") &&
                  ApolloRandomNamesContain(@[@" aww\u00a0"], @"AWW") &&
                  !ApolloRandomNamesContain(@[@"Random"], @"random") &&
                  !ApolloRandomNamesContain(@[@"ALL"], @"all") &&
                  !ApolloRandomNamesContain(@[@"a-b"], @"a-b"),
              @"special feeds and non-slugs never match; prefixes, case and Unicode spaces are normalized");
        Check([ApolloRandomPickSubreddit(@[@"Popular", @"aww", @"PICS"], @[@"r/pics"], @[@"AWW"], First) isEqualToString:@"Popular"],
              @"a list entry that is not one community is never excluded, as before");
        NSMutableArray *mutableList = [@[@"m1", @"m2"] mutableCopy];
        Check([ApolloRandomPickSubreddit(mutableList, @[@"m1"], nil, First) isEqualToString:@"m2"], @"mutable list");
        mutableList[1] = @"m3";
        Check([ApolloRandomPickSubreddit(mutableList, @[@"m1"], nil, First) isEqualToString:@"m3"],
              @"a mutable list is never served stale cached keys");

        NSLog(@"PASS: random subreddit rolls");
    }
    return 0;
}
