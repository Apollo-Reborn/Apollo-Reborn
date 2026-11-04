#import <Foundation/Foundation.h>
#import "ApolloSessionState.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSDate *now = [NSDate dateWithTimeIntervalSince1970:100000];
        NSDictionary *valid = @{
            ApolloSessionStateSavedAtKey: [now dateByAddingTimeInterval:-3600],
            ApolloSessionStateAccountScopeKey:
                @"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            ApolloSessionStateFeedURLKey: @"apollo-reborn://session/home",
            ApolloSessionStateFeedItemKey: @"t3_feed",
            ApolloSessionStateFeedDeltaKey: @42.5,
            ApolloSessionStateFeedOffsetKey: @9001,
            ApolloSessionStateFeedPageKey: @4,
            ApolloSessionStateFeedSortKey: @3,
            ApolloSessionStateFeedTimeSortKey: @2,
            ApolloSessionStateDetailURLKey: @"apollo://reddit.com/r/apolloapp/comments/abc/title/",
            ApolloSessionStateDetailItemKey: @"t1_comment",
            ApolloSessionStateDetailDeltaKey: @12,
            ApolloSessionStateDetailSortKey: @6,
            ApolloSessionStateDetailContextualKey: @NO,
            @"unrecognized": @"discard me",
        };
        NSDictionary *normalized = ApolloSessionStateNormalize(valid, now, 7 * 86400);
        Check(normalized != nil, @"recent valid session accepted");
        Check([normalized[ApolloSessionStateFeedItemKey] isEqual:@"t3_feed"], @"feed anchor retained");
        Check([normalized[ApolloSessionStateDetailURLKey] hasPrefix:@"apollo://reddit.com/r/"],
              @"post route retained");
        Check(normalized[@"unrecognized"] == nil, @"unknown fields discarded");
        Check([normalized[ApolloSessionStateFeedPageKey] isEqual:@4], @"feed page retained");
        Check([normalized[ApolloSessionStateFeedSortKey] isEqual:@3], @"feed sort retained");
        Check([normalized[ApolloSessionStateDetailSortKey] isEqual:@6], @"comment sort retained");

        NSMutableDictionary *unscoped = [valid mutableCopy];
        [unscoped removeObjectForKey:ApolloSessionStateAccountScopeKey];
        Check(ApolloSessionStateNormalize(unscoped, now, 7 * 86400) == nil,
              @"unscoped session rejected");

        NSMutableDictionary *badScope = [valid mutableCopy];
        badScope[ApolloSessionStateAccountScopeKey] = @"not-a-valid-account-scope";
        Check(ApolloSessionStateNormalize(badScope, now, 7 * 86400) == nil,
              @"malformed account scope rejected");

        NSMutableDictionary *expired = [valid mutableCopy];
        expired[ApolloSessionStateSavedAtKey] = [now dateByAddingTimeInterval:-(8 * 86400)];
        Check(ApolloSessionStateNormalize(expired, now, 7 * 86400) == nil,
              @"expired session rejected");

        NSMutableDictionary *external = [valid mutableCopy];
        external[ApolloSessionStateFeedURLKey] = @"https://reddit.com/r/apolloapp";
        Check(ApolloSessionStateNormalize(external, now, 7 * 86400) == nil,
              @"external URL rejected");
        NSMutableDictionary *lookalike = [valid mutableCopy];
        lookalike[ApolloSessionStateFeedURLKey] = @"apollo://notreddit.com/r/apolloapp";
        Check(ApolloSessionStateNormalize(lookalike, now, 7 * 86400) == nil,
              @"lookalike host rejected");
        NSMutableDictionary *traversal = [valid mutableCopy];
        traversal[ApolloSessionStateFeedURLKey] = @"apollo://reddit.com/r/../settings";
        Check(ApolloSessionStateNormalize(traversal, now, 7 * 86400) == nil,
              @"path traversal rejected");

        NSMutableDictionary *badDetail = [valid mutableCopy];
        badDetail[ApolloSessionStateDetailURLKey] = @"apollo://reborn/settings";
        normalized = ApolloSessionStateNormalize(badDetail, now, 7 * 86400);
        Check(normalized != nil && normalized[ApolloSessionStateDetailURLKey] == nil,
              @"invalid optional detail route discarded");

        NSMutableDictionary *huge = [valid mutableCopy];
        huge[ApolloSessionStateFeedOffsetKey] = @(INFINITY);
        normalized = ApolloSessionStateNormalize(huge, now, 7 * 86400);
        Check(normalized != nil && normalized[ApolloSessionStateFeedOffsetKey] == nil,
              @"non-finite viewport discarded");
        Check(ApolloSessionStateFeedURLIsAllowed(@"apollo://reddit.com/user/me/m/favorites"),
              @"multireddit route accepted");
        Check(!ApolloSessionStateFeedURLIsAllowed(@"apollo://reddit.com/settings"),
              @"unrelated Apollo route rejected");
        Check(!ApolloSessionStateFeedURLIsAllowed(
                  @"apollo://reddit.com/r/apolloapp/comments/abc/title/"),
              @"post route rejected as feed");
        Check(ApolloSessionStateDetailURLIsAllowed(
                  @"apollo://reddit.com/r/apolloapp/comments/abc/title/"),
              @"post route accepted as detail");
        Check(!ApolloSessionStateDetailURLIsAllowed(@"apollo://reddit.com/r/apolloapp"),
              @"feed route rejected as detail");
        Check(!ApolloSessionStateFeedURLIsAllowed(@"apollo://reddit.com/r/all?sort=new"),
              @"query-bearing route rejected");
        Check(ApolloSessionStateFeedURLMatchesSavedRoute(
                  @"apollo://reddit.com/r/ApolloApp", @"apollo://reddit.com/r/apolloapp"),
              @"saved feed route matches case-insensitively");
        Check(!ApolloSessionStateFeedURLMatchesSavedRoute(
                   @"apollo://reddit.com/r/apolloapp", @"apollo://reddit.com/r/ios"),
              @"unrelated feed cannot receive saved sort state");
        Check(ApolloSessionStateBuiltInFeedIndex(@"apollo://reddit.com/r/all") == 2,
              @"saved r/all restores Apollo's built-in All feed");
        Check(ApolloSessionStateBuiltInFeedIndex(@"apollo://reddit.com/r/All") == 2,
              @"built-in All matches case-insensitively");
        Check(ApolloSessionStateBuiltInFeedIndex(@"apollo://reddit.com/r/popular") == 1,
              @"saved r/popular restores Apollo's built-in Popular feed");
        Check(ApolloSessionStateBuiltInFeedIndex(@"apollo://reddit.com/r/allthingsapple") == NSNotFound,
              @"a subreddit merely starting with all is not the All feed");
        Check(ApolloSessionStateBuiltInFeedIndex(@"apollo://reddit.com/r/all/comments/abc/x") == NSNotFound,
              @"an r/all post route is not the All feed");
        Check(ApolloSessionStateBuiltInFeedIndex(@"apollo://reddit.com/r/apolloapp") == NSNotFound,
              @"ordinary subreddits keep URL routing");
        Check(ApolloSessionStateBuiltInFeedIndex(nil) == NSNotFound,
              @"missing route is not a built-in feed");
        Check([ApolloSessionStatePreferredAccountScope(@"persisted-a", @"live-b", YES)
                  isEqual:@"live-b"],
              @"account-ready retry prefers coherent live identity");
        Check([ApolloSessionStatePreferredAccountScope(@"persisted-a", @"live-b", NO)
                  isEqual:@"persisted-a"],
              @"lifecycle retry retains persisted identity preference");

        Check([ApolloSessionStateDetailURLByAddingCommentID(
                   @"apollo://reddit.com/r/apolloapp/comments/abc/title/", @"t1_DeF")
                  isEqual:@"apollo://reddit.com/r/apolloapp/comments/abc/_/def/"],
              @"comment fullname creates canonical contextual route");
        Check([ApolloSessionStateDetailURLByAddingCommentID(
                   @"apollo://reddit.com/r/apolloapp/comments/abc/title/", @"bad/id")
                  isEqual:@"apollo://reddit.com/r/apolloapp/comments/abc/title/"],
              @"invalid comment id leaves post route unchanged");
        Check([ApolloSessionStateDetailURLByRemovingCommentID(
                   @"apollo://reddit.com/r/apolloapp/comments/abc/_/def/")
                  isEqual:@"apollo://reddit.com/r/apolloapp/comments/abc/restored/"],
              @"contextual route can return to the full post");

        NSMutableDictionary *legacyContext = [valid mutableCopy];
        [legacyContext removeObjectForKey:ApolloSessionStateDetailContextualKey];
        legacyContext[ApolloSessionStateDetailURLKey] =
            @"apollo://reddit.com/r/apolloapp/comments/abc/_/def/";
        NSDictionary *legacyNormalized = ApolloSessionStateNormalize(
            legacyContext, now, 7 * 86400);
        Check([legacyNormalized[ApolloSessionStateDetailURLKey]
                  isEqual:@"apollo://reddit.com/r/apolloapp/comments/abc/restored/"],
              @"legacy visible-anchor routes migrate to full post context");
        Check([legacyNormalized[ApolloSessionStateDetailItemKey] isEqual:@"t1_comment"],
              @"legacy migration keeps the viewport anchor separate from its route");

        NSMutableDictionary *fullThread = [legacyContext mutableCopy];
        fullThread[ApolloSessionStateDetailContextualKey] = @NO;
        NSDictionary *fullThreadNormalized = ApolloSessionStateNormalize(
            fullThread, now, 7 * 86400);
        Check([fullThreadNormalized[ApolloSessionStateDetailURLKey]
                  isEqual:@"apollo://reddit.com/r/apolloapp/comments/abc/restored/"],
              @"explicit full-thread state never reopens as a single-comment thread");

        NSMutableDictionary *explicitContext = [legacyContext mutableCopy];
        explicitContext[ApolloSessionStateDetailContextualKey] = @YES;
        NSDictionary *explicitNormalized = ApolloSessionStateNormalize(
            explicitContext, now, 7 * 86400);
        Check([explicitNormalized[ApolloSessionStateDetailURLKey]
                  isEqual:@"apollo://reddit.com/r/apolloapp/comments/abc/_/def/"],
              @"genuine single-comment context remains contextual");
        Check(ApolloSessionStateDetailURLMatchesSavedRoute(
                  @"apollo://reddit.com/r/apolloapp/comments/abc/new-title/",
                  @"apollo://reddit.com/r/apolloapp/comments/abc/old-title/"),
              @"detail matching ignores a changed title slug");
        Check(!ApolloSessionStateDetailURLMatchesSavedRoute(
                   @"apollo://reddit.com/r/apolloapp/comments/abc/_/one/",
                   @"apollo://reddit.com/r/apolloapp/comments/abc/_/two/"),
              @"detail matching rejects another contextual comment");
        Check(!ApolloSessionStateDetailURLMatchesSavedRoute(
                   @"apollo://reddit.com/r/apolloapp/comments/def/title/",
                   @"apollo://reddit.com/r/apolloapp/comments/abc/title/"),
              @"detail matching rejects another post");
        Check(ApolloSessionStateDetailIdentifiersMatchSavedRoute(
                  @"t3_AbC", @"t1_DeF",
                  @"apollo://reddit.com/r/apolloapp/comments/abc/_/def/"),
              @"pre-fetch controller IDs match a contextual saved route");
        Check(!ApolloSessionStateDetailIdentifiersMatchSavedRoute(
                   @"t3_abc", nil,
                   @"apollo://reddit.com/r/apolloapp/comments/abc/_/def/"),
              @"contextual saved route requires its comment ID");
        Check(ApolloSessionStateDetailIdentifiersMatchSavedRoute(
                  @"abc", nil,
                  @"apollo://reddit.com/r/apolloapp/comments/abc/title/"),
              @"bare pre-fetch post ID matches a non-contextual saved route");
        Check(ApolloSessionStateLaunchHasExplicitDestination(1, NO, 0, NO),
              @"URL cold launch takes navigation precedence");
        Check(ApolloSessionStateLaunchHasExplicitDestination(0, YES, 0, NO),
              @"notification cold launch takes navigation precedence");
        Check(ApolloSessionStateLaunchHasExplicitDestination(0, NO, 1, NO),
              @"activity cold launch takes navigation precedence");
        Check(!ApolloSessionStateLaunchHasExplicitDestination(0, NO, 0, NO),
              @"ordinary launch remains eligible for session restore");
        Check(ApolloSessionStateShouldDeferPersistence(YES, YES, NO),
              @"pending detail restore preserves complete disk snapshot");
        Check(ApolloSessionStateShouldDeferPersistence(YES, NO, YES),
              @"pending feed restore preserves complete disk snapshot");
        Check(!ApolloSessionStateShouldDeferPersistence(YES, YES, YES),
              @"completed restore permits a fresh snapshot");
        Check(ApolloSessionStateShouldDeferPersistence(YES, NO, NO),
              @"both unfinished phases preserve the sole disk snapshot");
        Check(!ApolloSessionStateShouldDeferPersistence(NO, NO, NO),
              @"no pending restore permits ordinary persistence");
        Check(ApolloSessionStateViewportRestoreIsEligible(NO, NO, NO, YES, YES, YES),
              @"feed restore remains eligible beneath pushed detail");
        Check(!ApolloSessionStateViewportRestoreIsEligible(YES, NO, NO, YES, NO, YES),
              @"detail restore requires visible top controller");
        Check(ApolloSessionStateViewportRestoreIsEligible(YES, YES, YES, YES, NO, YES),
              @"visible top detail remains eligible");
        Check(ApolloSessionStateViewportRestoreWasCancelled(YES, YES, YES, NO, NO, YES),
              @"popped detail controller cancels its restore phase");
        Check(ApolloSessionStateViewportRestoreWasCancelled(YES, NO, NO, YES, NO, YES),
              @"superseded detail controller cancels its restore phase");
        Check(!ApolloSessionStateViewportRestoreWasCancelled(YES, NO, YES, YES, NO, NO),
              @"temporarily hidden top detail remains resumable");
        Check(ApolloSessionStateViewportRestoreWasCancelled(NO, NO, NO, NO, NO, YES),
              @"removed feed controller cancels its restore phase");
        Check(ApolloSessionStateViewportRestoreWasCancelled(NO, NO, YES, YES, NO, YES),
              @"active tab switch cancels an invisible feed restore");
        Check(ApolloSessionStateViewportRestoreWasCancelled(NO, NO, NO, YES, NO, YES),
              @"unrelated pushed controller cancels an invisible feed restore");
        Check(!ApolloSessionStateViewportRestoreWasCancelled(NO, NO, NO, YES, YES, YES),
              @"specific restored detail keeps its underlying feed phase alive");
        Check(!ApolloSessionStateViewportRestoreWasCancelled(NO, NO, YES, YES, NO, NO),
              @"background detachment does not cancel a feed restore");
        Check(ApolloSessionStateViewportRestoreIsEligible(NO, NO, YES, YES, NO, NO),
              @"backgrounded feed remains resumable through queued retries");
        Check(ApolloSessionStateShouldCancelForReaderScroll(YES, YES, YES, NO, YES),
              @"reader drag cancels an active unfinished restore phase");
        Check(!ApolloSessionStateShouldCancelForReaderScroll(NO, YES, YES, NO, YES),
              @"reader drag cannot cancel without a pending restore");
        Check(!ApolloSessionStateShouldCancelForReaderScroll(YES, NO, YES, NO, YES),
              @"reader drag in another controller cannot cancel this restore");
        Check(!ApolloSessionStateShouldCancelForReaderScroll(YES, YES, NO, NO, YES),
              @"reader drag cannot cancel a phase before it starts");
        Check(!ApolloSessionStateShouldCancelForReaderScroll(YES, YES, YES, YES, YES),
              @"reader drag cannot reopen a finished restore phase");
        Check(!ApolloSessionStateShouldCancelForReaderScroll(YES, YES, YES, NO, NO),
              @"settled polling without a new drag does not cancel restore");
        Check(ApolloSessionStateQueuedPhaseWorkShouldRun(YES, YES, NO),
              @"queued work runs for its active unfinished restore phase");
        Check(!ApolloSessionStateQueuedPhaseWorkShouldRun(YES, YES, YES),
              @"finished detail stays terminal while feed remains pending");
        Check(!ApolloSessionStateQueuedPhaseWorkShouldRun(YES, YES, YES),
              @"finished feed stays terminal while detail remains pending");
        Check(!ApolloSessionStateQueuedPhaseWorkShouldRun(NO, YES, NO),
              @"queued work stops after the shared restore completes");
        Check(!ApolloSessionStateQueuedPhaseWorkShouldRun(YES, NO, NO),
              @"queued work stops when it belongs to an older generation");
        Check(ApolloSessionStateDetailRouteDeadlineShouldFinish(NO, NO),
              @"detail route deadline finishes when no controller appeared");
        Check(!ApolloSessionStateDetailRouteDeadlineShouldFinish(YES, NO),
              @"backgrounded appeared detail remains resumable past route deadline");
        Check(!ApolloSessionStateDetailRouteDeadlineShouldFinish(NO, YES),
              @"completed detail ignores a later route deadline");
        Check(!ApolloSessionStateSortedFeedReloadHasProducedRows(@"old", @"old", NO, NO),
              @"old pre-reload rows cannot complete viewport restoration");
        Check(ApolloSessionStateSortedFeedReloadHasProducedRows(@"old", @"new", NO, NO),
              @"changed sorted rows permit viewport restoration");
        Check(ApolloSessionStateSortedFeedReloadHasProducedRows(nil, @"new", NO, NO),
              @"initially empty feed accepts newly produced sorted rows");
        Check(ApolloSessionStateSortedFeedReloadHasProducedRows(@"same", @"same", YES, NO),
              @"transient content replacement accepts an identical final page");
        Check(ApolloSessionStateSortedFeedReloadHasProducedRows(@"same", @"same", NO, YES),
              @"identical sorted rows remain restorable after the reload wait expires");
        Check(!ApolloSessionStateShouldDeleteSnapshotAfterDetailFailure(NO, YES),
              @"detail failure retains snapshot while feed is unfinished");
        Check(ApolloSessionStateShouldDeleteSnapshotAfterDetailFailure(YES, YES),
              @"detail failure deletes snapshot only after both phases finish");
        Check(!ApolloSessionStateShouldDeleteSnapshotAfterDetailFailure(YES, NO),
              @"unfinished detail cannot delete snapshot");
        Check(!ApolloSessionStateShouldDeleteSnapshotAfterDetailFailure(NO, NO),
              @"two unfinished phases cannot delete snapshot");
        Check(ApolloSessionStateShouldCancelUnstartedDetail(NO, NO),
              @"feed cancellation suppresses a detail route Apollo has not opened");
        Check(!ApolloSessionStateShouldCancelUnstartedDetail(YES, NO),
              @"opened detail phase remains independent from feed cancellation");
        Check(!ApolloSessionStateShouldCancelUnstartedDetail(NO, YES),
              @"finished detail phase is not cancelled twice");
        Check(ApolloSessionStateDetailPostIdentifierMatchesSavedRoute(
                  @"t3_abc123", @"apollo://reddit.com/r/test/comments/abc123/title/def456"),
              @"saved contextual route still owns its post sort");
        Check(!ApolloSessionStateDetailPostIdentifierMatchesSavedRoute(
                   @"t3_other", @"apollo://reddit.com/r/test/comments/abc123/title/def456"),
              @"saved detail sort cannot leak to another post");
        Check(ApolloSessionStateShouldFinishAbandonedDetail(YES, YES, NO, NO),
              @"popped restored detail finishes before background persistence");
        Check(!ApolloSessionStateShouldFinishAbandonedDetail(YES, YES, NO, YES),
              @"visible restored detail keeps its anchor retry alive");
        Check(!ApolloSessionStateShouldFinishAbandonedDetail(YES, NO, NO, NO),
              @"unseen routed detail remains governed by its route deadline");
        Check(!ApolloSessionStateShouldFinishAbandonedDetail(YES, YES, YES, NO),
              @"finished detail is not completed twice");
        Check(ApolloSessionStateShouldCancelForAccountChange(
                  YES, @"account-a", @"account-b"),
              @"live account change cancels an active restore");
        Check(!ApolloSessionStateShouldCancelForAccountChange(
                   YES, @"account-a", @"account-a"),
              @"matching live account keeps an active restore");
        Check(!ApolloSessionStateShouldCancelForAccountChange(
                   YES, @"account-a", nil),
              @"unknown live identity waits rather than cancelling");
        Check(!ApolloSessionStateShouldCancelForAccountChange(
                   NO, @"account-a", @"account-b"),
              @"account notification without a pending restore is not a cancellation");
        Check(ApolloSessionStateAccountReadyMayRetry(NO, NO, NO),
              @"unconsidered lifecycle path may attempt initial restoration");
        Check(ApolloSessionStateAccountReadyMayRetry(YES, YES, YES),
              @"account-ready callback retries a stale persisted mismatch");
        Check(!ApolloSessionStateAccountReadyMayRetry(YES, YES, NO),
              @"lifecycle callback cannot consume an account-ready retry");
        Check(!ApolloSessionStateAccountReadyMayRetry(YES, NO, YES),
              @"completed initial consideration remains one-shot");
        Check(ApolloSessionStateFeedOwnsSelectedNavigation(YES, YES, NO),
              @"selected feed on top owns background persistence");
        Check(ApolloSessionStateFeedOwnsSelectedNavigation(YES, NO, YES),
              @"matching restored detail owns its selected feed stack");
        Check(!ApolloSessionStateFeedOwnsSelectedNavigation(NO, YES, NO),
              @"tab switch invalidates the hidden restore stack");
        Check(!ApolloSessionStateFeedOwnsSelectedNavigation(YES, NO, NO),
              @"unrelated pushed controller invalidates the restore stack");
        Check(ApolloSessionStateControllerSceneOwnsRestore(NO, NO, NO),
              @"ordinary capture remains scene-agnostic without a pending restore");
        Check(ApolloSessionStateControllerSceneOwnsRestore(YES, YES, YES),
              @"originating scene controller may consume a pending restore");
        Check(!ApolloSessionStateControllerSceneOwnsRestore(YES, YES, NO),
              @"another window cannot consume a pending restore");
        Check(!ApolloSessionStateControllerSceneOwnsRestore(YES, NO, NO),
              @"missing originating scene cannot route a pending restore");
        Check(ApolloSessionStateShouldRequestNextFeedPage(4, 1, NSNotFound),
              @"deep feed requests its next missing page");
        Check(!ApolloSessionStateShouldRequestNextFeedPage(4, 1, 1),
              @"same feed page is requested at most once");
        Check(!ApolloSessionStateShouldRequestNextFeedPage(4, 4, 3),
              @"caught-up feed does not request another page");
        Check(ApolloSessionStateMoreCommentsChildrenContainIdentifier(
                  @[@"abc", @"Def"], @"t1_def"),
              @"saved fullname selects its exact bare more-comments child");
        Check(ApolloSessionStateMoreCommentsChildrenContainIdentifier(
                  @[@"t1_abc"], @"ABC"),
              @"more-comments matching accepts either fullname representation");
        Check(!ApolloSessionStateMoreCommentsChildrenContainIdentifier(
                   @[@"abc", @"def"], @"t1_other"),
              @"unrelated more-comments branches are not expanded during restore");

        NSMutableDictionary *excessivePage = [valid mutableCopy];
        excessivePage[ApolloSessionStateFeedPageKey] = @6;
        normalized = ApolloSessionStateNormalize(excessivePage, now, 7 * 86400);
        Check(normalized != nil && normalized[ApolloSessionStateFeedPageKey] == nil,
              @"page depth past the five-page replay cap is discarded");

        NSLog(@"PASS: %lu session-state checks", (unsigned long)checks);
    }
}
