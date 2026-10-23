#import "ApolloSessionState.h"

NSString *const ApolloSessionStateFeedURLKey = @"feedURL";
NSString *const ApolloSessionStateFeedItemKey = @"feedItem";
NSString *const ApolloSessionStateFeedDeltaKey = @"feedDelta";
NSString *const ApolloSessionStateFeedOffsetKey = @"feedOffset";
NSString *const ApolloSessionStateFeedPageKey = @"feedPage";
NSString *const ApolloSessionStateFeedSortKey = @"feedSort";
NSString *const ApolloSessionStateFeedTimeSortKey = @"feedTimeSort";
NSString *const ApolloSessionStateDetailURLKey = @"detailURL";
NSString *const ApolloSessionStateDetailItemKey = @"detailItem";
NSString *const ApolloSessionStateDetailDeltaKey = @"detailDelta";
NSString *const ApolloSessionStateDetailOffsetKey = @"detailOffset";
NSString *const ApolloSessionStateDetailSortKey = @"detailSort";
NSString *const ApolloSessionStateDetailContextualKey = @"detailContextual";
NSString *const ApolloSessionStateSavedAtKey = @"savedAt";
NSString *const ApolloSessionStateAccountScopeKey = @"accountScope";

static const NSUInteger kApolloSessionMaximumStringLength = 2048;
static const double kApolloSessionMaximumCoordinate = 10000000.0;

static NSString *ApolloSessionBoundedString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *string = value;
    return string.length > 0 && string.length <= kApolloSessionMaximumStringLength ? string : nil;
}

static NSNumber *ApolloSessionBoundedNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    double number = [value doubleValue];
    return isfinite(number) && fabs(number) <= kApolloSessionMaximumCoordinate ? @(number) : nil;
}

static NSURLComponents *ApolloSessionRedditComponents(NSString *value) {
    NSString *string = ApolloSessionBoundedString(value);
    if (!string) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:string];
    if (![[components.scheme lowercaseString] isEqualToString:@"apollo"] ||
        ![[components.host lowercaseString] isEqualToString:@"reddit.com"] ||
        components.user.length || components.password.length || components.query.length ||
        components.fragment.length) return nil;
    NSString *path = components.path;
    if (![path hasPrefix:@"/"] || [path containsString:@".."] || path.length > 1024) return nil;
    return components;
}

BOOL ApolloSessionStateFeedURLIsAllowed(NSString *value) {
    if ([value isEqualToString:@"apollo-reborn://session/home"]) return YES;
    NSURLComponents *components = ApolloSessionRedditComponents(value);
    if (!components) return NO;
    NSString *path = components.path.lowercaseString;
    if ([path hasPrefix:@"/r/"]) return [path rangeOfString:@"/comments/"].location == NSNotFound;
    return [path hasPrefix:@"/user/"] || [path hasPrefix:@"/u/"];
}

BOOL ApolloSessionStateDetailURLIsAllowed(NSString *value) {
    NSURLComponents *components = ApolloSessionRedditComponents(value);
    if (!components) return NO;
    NSString *path = components.path.lowercaseString;
    return [path hasPrefix:@"/r/"] && [path rangeOfString:@"/comments/"].location != NSNotFound;
}

BOOL ApolloSessionStateFeedURLMatchesSavedRoute(NSString *candidateURL, NSString *savedURL) {
    return ApolloSessionStateFeedURLIsAllowed(candidateURL) &&
           ApolloSessionStateFeedURLIsAllowed(savedURL) &&
           [candidateURL caseInsensitiveCompare:savedURL] == NSOrderedSame;
}

NSString *ApolloSessionStatePreferredAccountScope(NSString *persistedScope,
                                                   NSString *liveScope,
                                                   BOOL preferLiveScope) {
    NSString *primary = preferLiveScope ? liveScope : persistedScope;
    return primary.length ? primary : (preferLiveScope ? persistedScope : liveScope);
}

NSString *ApolloSessionStateDetailURLByAddingCommentID(NSString *detailURL,
                                                        NSString *commentID) {
    NSURLComponents *components = ApolloSessionRedditComponents(detailURL);
    if (!components || !ApolloSessionStateDetailURLIsAllowed(detailURL)) return detailURL;
    NSString *bare = ApolloSessionBoundedString(commentID).lowercaseString;
    if ([bare hasPrefix:@"t1_"]) bare = [bare substringFromIndex:3];
    NSCharacterSet *notBase36 = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefghijklmnopqrstuvwxyz"] invertedSet];
    if (!bare.length || [bare rangeOfCharacterFromSet:notBase36].location != NSNotFound) {
        return detailURL;
    }

    NSArray<NSString *> *parts = [components.path pathComponents];
    NSUInteger comments = [parts indexOfObjectPassingTest:^BOOL(NSString *part,
                                                                 __unused NSUInteger index,
                                                                 __unused BOOL *stop) {
        return [part.lowercaseString isEqualToString:@"comments"];
    }];
    if (comments == NSNotFound || comments + 1 >= parts.count) return detailURL;
    NSString *postID = parts[comments + 1];
    if (!postID.length) return detailURL;

    NSMutableArray<NSString *> *route = [NSMutableArray array];
    for (NSUInteger index = 1; index <= comments + 1; index++) [route addObject:parts[index]];
    [route addObject:@"_"];
    [route addObject:bare];
    components.path = [@"/" stringByAppendingString:[route componentsJoinedByString:@"/"]];
    components.path = [components.path stringByAppendingString:@"/"];
    return components.URL.absoluteString ?: detailURL;
}

NSString *ApolloSessionStateDetailURLByRemovingCommentID(NSString *detailURL) {
    NSURLComponents *components = ApolloSessionRedditComponents(detailURL);
    if (!components || !ApolloSessionStateDetailURLIsAllowed(detailURL)) return detailURL;
    NSArray<NSString *> *parts = components.path.pathComponents;
    NSUInteger comments = [parts indexOfObjectPassingTest:^BOOL(NSString *part,
                                                                 __unused NSUInteger index,
                                                                 __unused BOOL *stop) {
        return [part.lowercaseString isEqualToString:@"comments"];
    }];
    if (comments == NSNotFound || comments + 3 >= parts.count ||
        ![parts[comments + 2] isEqualToString:@"_"]) return detailURL;
    NSMutableArray<NSString *> *route = [NSMutableArray array];
    for (NSUInteger index = 1; index <= comments + 1; index++) [route addObject:parts[index]];
    [route addObject:@"restored"];
    components.path = [@"/" stringByAppendingString:[route componentsJoinedByString:@"/"]];
    components.path = [components.path stringByAppendingString:@"/"];
    return components.URL.absoluteString ?: detailURL;
}

static NSArray<NSString *> *ApolloSessionDetailRouteIdentity(NSString *value) {
    NSURLComponents *components = ApolloSessionRedditComponents(value);
    if (!components || !ApolloSessionStateDetailURLIsAllowed(value)) return nil;
    NSArray<NSString *> *parts = components.path.pathComponents;
    NSUInteger comments = [parts indexOfObjectPassingTest:^BOOL(NSString *part,
                                                                 __unused NSUInteger index,
                                                                 __unused BOOL *stop) {
        return [part.lowercaseString isEqualToString:@"comments"];
    }];
    if (comments == NSNotFound || comments < 1 || comments + 1 >= parts.count) return nil;
    NSString *subreddit = parts[comments - 1].lowercaseString;
    NSString *postID = parts[comments + 1].lowercaseString;
    if (!subreddit.length || !postID.length) return nil;
    NSString *commentID = @"";
    if (comments + 3 < parts.count && [parts[comments + 2] isEqualToString:@"_"]) {
        commentID = parts[comments + 3].lowercaseString;
    }
    return @[subreddit, postID, commentID];
}

BOOL ApolloSessionStateDetailURLMatchesSavedRoute(NSString *candidateURL, NSString *savedURL) {
    NSArray<NSString *> *candidate = ApolloSessionDetailRouteIdentity(candidateURL);
    NSArray<NSString *> *saved = ApolloSessionDetailRouteIdentity(savedURL);
    return candidate && saved && [candidate isEqualToArray:saved];
}

static NSString *ApolloSessionBareFullname(NSString *value, NSString *prefix) {
    NSString *bare = ApolloSessionBoundedString(value).lowercaseString;
    if ([bare hasPrefix:prefix]) bare = [bare substringFromIndex:prefix.length];
    NSCharacterSet *notBase36 = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefghijklmnopqrstuvwxyz"] invertedSet];
    return bare.length && [bare rangeOfCharacterFromSet:notBase36].location == NSNotFound
        ? bare : nil;
}

BOOL ApolloSessionStateDetailIdentifiersMatchSavedRoute(NSString *postID, NSString *commentID,
                                                        NSString *savedURL) {
    NSArray<NSString *> *saved = ApolloSessionDetailRouteIdentity(savedURL);
    NSString *barePost = ApolloSessionBareFullname(postID, @"t3_");
    if (!saved || ![barePost isEqualToString:saved[1]]) return NO;
    NSString *bareComment = commentID.length
        ? ApolloSessionBareFullname(commentID, @"t1_") : @"";
    return bareComment && [bareComment isEqualToString:saved[2]];
}

BOOL ApolloSessionStateDetailPostIdentifierMatchesSavedRoute(NSString *postID,
                                                             NSString *savedURL) {
    NSArray<NSString *> *saved = ApolloSessionDetailRouteIdentity(savedURL);
    NSString *barePost = ApolloSessionBareFullname(postID, @"t3_");
    return saved && [barePost isEqualToString:saved[1]];
}

BOOL ApolloSessionStateLaunchHasExplicitDestination(NSUInteger URLContextCount,
                                                     BOOL hasNotificationResponse,
                                                     NSUInteger userActivityCount,
                                                     BOOL hasShortcutItem) {
    return URLContextCount > 0 || hasNotificationResponse || userActivityCount > 0 ||
           hasShortcutItem;
}

BOOL ApolloSessionStateShouldDeferPersistence(BOOL hasPendingRestore, BOOL feedFinished,
                                              BOOL detailFinished) {
    return hasPendingRestore && (!feedFinished || !detailFinished);
}

BOOL ApolloSessionStateViewportRestoreIsEligible(BOOL detail, BOOL visible, BOOL top,
                                                  BOOL inNavigationStack,
                                                  BOOL underRestoredDetail,
                                                  BOOL applicationActive) {
    if (detail) return visible && top;
    return (visible && top) || (inNavigationStack && underRestoredDetail) ||
           (inNavigationStack && !applicationActive);
}

BOOL ApolloSessionStateViewportRestoreWasCancelled(BOOL detail, BOOL visible, BOOL top,
                                                   BOOL inNavigationStack,
                                                   BOOL underRestoredDetail,
                                                   BOOL applicationActive) {
    if (!inNavigationStack || (detail && !top)) return YES;
    return !detail && applicationActive && !visible && !underRestoredDetail;
}

BOOL ApolloSessionStateShouldCancelForReaderScroll(BOOL hasPendingRestore,
                                                   BOOL controllerOwnsRestore,
                                                   BOOL phaseStarted,
                                                   BOOL phaseFinished,
                                                   BOOL panBegan) {
    return hasPendingRestore && controllerOwnsRestore && phaseStarted &&
           !phaseFinished && panBegan;
}

BOOL ApolloSessionStateQueuedPhaseWorkShouldRun(BOOL hasPendingRestore,
                                                BOOL generationMatches,
                                                BOOL phaseFinished) {
    return hasPendingRestore && generationMatches && !phaseFinished;
}

BOOL ApolloSessionStateDetailRouteDeadlineShouldFinish(BOOL detailControllerSeen,
                                                       BOOL detailFinished) {
    return !detailControllerSeen && !detailFinished;
}

BOOL ApolloSessionStateSortedFeedReloadHasProducedRows(NSString *initialFingerprint,
                                                       NSString *currentFingerprint,
                                                       BOOL observedContentChange,
                                                       BOOL reloadWaitExpired) {
    if (!currentFingerprint.length) return NO;
    return observedContentChange || reloadWaitExpired ||
        ![currentFingerprint isEqualToString:initialFingerprint];
}

BOOL ApolloSessionStateShouldDeleteSnapshotAfterDetailFailure(BOOL feedFinished,
                                                              BOOL detailFinished) {
    return feedFinished && detailFinished;
}

BOOL ApolloSessionStateShouldCancelUnstartedDetail(BOOL detailRouteOpened,
                                                   BOOL detailFinished) {
    return !detailRouteOpened && !detailFinished;
}

BOOL ApolloSessionStateShouldFinishAbandonedDetail(BOOL detailRouteOpened,
                                                   BOOL detailControllerSeen,
                                                   BOOL detailFinished,
                                                   BOOL restoredDetailOnTop) {
    return detailRouteOpened && detailControllerSeen && !detailFinished &&
           !restoredDetailOnTop;
}

BOOL ApolloSessionStateShouldCancelForAccountChange(BOOL hasPendingRestore,
                                                    NSString *savedScope,
                                                    NSString *liveScope) {
    return hasPendingRestore && savedScope.length && liveScope.length &&
           ![savedScope isEqualToString:liveScope];
}

BOOL ApolloSessionStateAccountReadyMayRetry(BOOL initialRestoreConsidered,
                                            BOOL accountReadyRetryPending,
                                            BOOL preferLiveScope) {
    return !initialRestoreConsidered || (accountReadyRetryPending && preferLiveScope);
}

BOOL ApolloSessionStateFeedOwnsSelectedNavigation(BOOL feedNavigationSelected,
                                                  BOOL topIsFeed,
                                                  BOOL topIsRestoredDetail) {
    return feedNavigationSelected && (topIsFeed || topIsRestoredDetail);
}

BOOL ApolloSessionStateControllerSceneOwnsRestore(BOOL hasPendingRestore,
                                                  BOOL restoreSceneAvailable,
                                                  BOOL controllerSceneMatches) {
    return !hasPendingRestore || (restoreSceneAvailable && controllerSceneMatches);
}

BOOL ApolloSessionStateShouldRequestNextFeedPage(NSInteger savedPage, NSInteger currentPage,
                                                 NSInteger lastRequestedPage) {
    return savedPage > currentPage && currentPage != lastRequestedPage;
}

BOOL ApolloSessionStateMoreCommentsChildrenContainIdentifier(NSArray *children,
                                                              NSString *identifier) {
    if (![children isKindOfClass:NSArray.class] || ![identifier isKindOfClass:NSString.class]) {
        return NO;
    }
    NSString *bareIdentifier = [identifier hasPrefix:@"t1_"]
        ? [identifier substringFromIndex:3] : identifier;
    if (bareIdentifier.length == 0) return NO;
    for (id child in children) {
        if (![child isKindOfClass:NSString.class]) continue;
        NSString *bareChild = [child hasPrefix:@"t1_"] ? [child substringFromIndex:3] : child;
        if ([bareChild caseInsensitiveCompare:bareIdentifier] == NSOrderedSame) return YES;
    }
    return NO;
}

static BOOL ApolloSessionAccountScopeIsAllowed(NSString *scope) {
    if ([scope isEqualToString:@"signed-out"]) return YES;
    if (scope.length != 64) return NO;
    NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet];
    return [scope rangeOfCharacterFromSet:notHex].location == NSNotFound;
}

NSDictionary<NSString *, id> *ApolloSessionStateNormalize(NSDictionary *candidate,
                                                           NSDate *now,
                                                           NSTimeInterval maximumAge) {
    if (![candidate isKindOfClass:NSDictionary.class] || ![now isKindOfClass:NSDate.class] ||
        maximumAge <= 0 || !isfinite(maximumAge)) return nil;
    NSDate *savedAt = [candidate[ApolloSessionStateSavedAtKey] isKindOfClass:NSDate.class]
        ? candidate[ApolloSessionStateSavedAtKey] : nil;
    if (!savedAt) return nil;
    NSTimeInterval age = [now timeIntervalSinceDate:savedAt];
    if (!isfinite(age) || age < -300.0 || age > maximumAge) return nil;

    NSString *feedURL = ApolloSessionBoundedString(candidate[ApolloSessionStateFeedURLKey]);
    NSString *accountScope = ApolloSessionBoundedString(candidate[ApolloSessionStateAccountScopeKey]);
    if (!ApolloSessionStateFeedURLIsAllowed(feedURL) ||
        !ApolloSessionAccountScopeIsAllowed(accountScope)) return nil;

    NSMutableDictionary *normalized = [@{
        ApolloSessionStateSavedAtKey: savedAt,
        ApolloSessionStateFeedURLKey: feedURL,
        ApolloSessionStateAccountScopeKey: accountScope,
    } mutableCopy];
    NSArray<NSString *> *stringKeys = @[
        ApolloSessionStateFeedItemKey, ApolloSessionStateDetailItemKey,
    ];
    for (NSString *key in stringKeys) {
        NSString *value = ApolloSessionBoundedString(candidate[key]);
        if (value) normalized[key] = value;
    }
    NSArray<NSString *> *numberKeys = @[
        ApolloSessionStateFeedDeltaKey, ApolloSessionStateFeedOffsetKey,
        ApolloSessionStateDetailDeltaKey, ApolloSessionStateDetailOffsetKey,
    ];
    for (NSString *key in numberKeys) {
        NSNumber *value = ApolloSessionBoundedNumber(candidate[key]);
        if (value) normalized[key] = value;
    }
    NSDictionary<NSString *, NSArray<NSNumber *> *> *integerRanges = @{
        ApolloSessionStateFeedPageKey: @[@0, @5],
        ApolloSessionStateFeedSortKey: @[@1, @6],
        ApolloSessionStateFeedTimeSortKey: @[@1, @7],
        ApolloSessionStateDetailSortKey: @[@1, @7],
    };
    [integerRanges enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray<NSNumber *> *range,
                                                       __unused BOOL *stop) {
        id raw = candidate[key];
        if (![raw isKindOfClass:NSNumber.class]) return;
        double value = [raw doubleValue];
        NSInteger integer = [raw integerValue];
        if (isfinite(value) && value == (double)integer && integer >= range[0].integerValue &&
            integer <= range[1].integerValue) normalized[key] = @(integer);
    }];
    NSString *detailURL = ApolloSessionBoundedString(candidate[ApolloSessionStateDetailURLKey]);
    if (detailURL && ApolloSessionStateDetailURLIsAllowed(detailURL)) {
        id contextual = candidate[ApolloSessionStateDetailContextualKey];
        BOOL keepsContext = [contextual isKindOfClass:NSNumber.class] &&
            [contextual integerValue] == 1;
        normalized[ApolloSessionStateDetailContextualKey] = @(keepsContext);
        if (!keepsContext) detailURL = ApolloSessionStateDetailURLByRemovingCommentID(detailURL);
        normalized[ApolloSessionStateDetailURLKey] = detailURL;
    }
    return normalized;
}
