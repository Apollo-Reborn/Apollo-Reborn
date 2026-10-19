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

        Check([ApolloSessionStateDetailURLByAddingCommentID(
                   @"apollo://reddit.com/r/apolloapp/comments/abc/title/", @"t1_DeF")
                  isEqual:@"apollo://reddit.com/r/apolloapp/comments/abc/_/def/"],
              @"comment fullname creates canonical contextual route");
        Check([ApolloSessionStateDetailURLByAddingCommentID(
                   @"apollo://reddit.com/r/apolloapp/comments/abc/title/", @"bad/id")
                  isEqual:@"apollo://reddit.com/r/apolloapp/comments/abc/title/"],
              @"invalid comment id leaves post route unchanged");
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
        Check(ApolloSessionStateViewportRestoreIsEligible(NO, NO, NO, YES),
              @"feed restore remains eligible beneath pushed detail");
        Check(!ApolloSessionStateViewportRestoreIsEligible(YES, NO, NO, YES),
              @"detail restore requires visible top controller");
        Check(ApolloSessionStateViewportRestoreIsEligible(YES, YES, YES, YES),
              @"visible top detail remains eligible");
        Check(ApolloSessionStateViewportRestoreWasCancelled(YES, YES, NO),
              @"popped detail controller cancels its restore phase");
        Check(ApolloSessionStateViewportRestoreWasCancelled(YES, NO, YES),
              @"superseded detail controller cancels its restore phase");
        Check(!ApolloSessionStateViewportRestoreWasCancelled(YES, YES, YES),
              @"temporarily hidden top detail remains resumable");
        Check(ApolloSessionStateViewportRestoreWasCancelled(NO, NO, NO),
              @"removed feed controller cancels its restore phase");
        Check(ApolloSessionStateShouldRequestNextFeedPage(4, 1, NSNotFound),
              @"deep feed requests its next missing page");
        Check(!ApolloSessionStateShouldRequestNextFeedPage(4, 1, 1),
              @"same feed page is requested at most once");
        Check(!ApolloSessionStateShouldRequestNextFeedPage(4, 4, 3),
              @"caught-up feed does not request another page");

        NSMutableDictionary *excessivePage = [valid mutableCopy];
        excessivePage[ApolloSessionStateFeedPageKey] = @21;
        normalized = ApolloSessionStateNormalize(excessivePage, now, 7 * 86400);
        Check(normalized != nil && normalized[ApolloSessionStateFeedPageKey] == nil,
              @"excessive page depth discarded");

        NSLog(@"PASS: %lu session-state checks", (unsigned long)checks);
    }
}
