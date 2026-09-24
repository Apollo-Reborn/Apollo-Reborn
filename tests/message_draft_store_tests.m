#import <Foundation/Foundation.h>

#import "ApolloMessageDraftStore.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"MessageDraftStoreTestFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

static void TestOpaqueKeyIsolation(void) {
    NSString *same = ApolloMessageDraftOpaqueKey(@"Alice", @"web:/chat/room/one");
    Require([same isEqualToString:ApolloMessageDraftOpaqueKey(@" alice ", @"web:/chat/room/one")],
            @"account normalization is stable");
    Require(![same isEqualToString:ApolloMessageDraftOpaqueKey(@"bob", @"web:/chat/room/one")],
            @"different accounts get different opaque keys");
    Require(![same isEqualToString:ApolloMessageDraftOpaqueKey(@"alice", @"web:/chat/room/two")],
            @"different conversations get different opaque keys");
    Require(ApolloMessageDraftOpaqueKey(@"", @"web:/chat/room/one") == nil,
            @"missing account is rejected rather than made shared");
    Require(ApolloMessageDraftOpaqueKey(@"alice", @"") == nil,
            @"missing conversation is rejected rather than made shared");
}

static void TestRestoreAndIsolation(void) {
    ApolloMessageDraftStoreResetForTesting();
    Require(ApolloMessageDraftStoreText(@"alice", @"native:t4_one", @"Alice one"), @"stores Alice's first thread");
    Require(ApolloMessageDraftStoreText(@"alice", @"native:t4_two", @"Alice two"), @"stores Alice's second thread");
    Require(ApolloMessageDraftStoreText(@"bob", @"native:t4_one", @"Bob one"), @"stores Bob's same-id thread separately");
    Require([(ApolloMessageDraftLoadText(@"alice", @"native:t4_one") ?: @"") isEqualToString:@"Alice one"],
            @"restores the exact account/thread draft");
    Require([(ApolloMessageDraftLoadText(@"alice", @"native:t4_two") ?: @"") isEqualToString:@"Alice two"],
            @"does not cross restore another conversation");
    Require([(ApolloMessageDraftLoadText(@"bob", @"native:t4_one") ?: @"") isEqualToString:@"Bob one"],
            @"does not cross restore another account");
}

static void TestEmptyDeletes(void) {
    ApolloMessageDraftStoreResetForTesting();
    Require(ApolloMessageDraftStoreText(@"alice", @"web:/chat/room/one", @"erase me"), @"stores draft before deletion");
    Require(ApolloMessageDraftStoreText(@"alice", @"web:/chat/room/one", @""), @"empty text deletes draft");
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/room/one") == nil,
            @"empty edit cannot restore stale text");
}

static void TestSendSuccessAndFailure(void) {
    ApolloMessageDraftStoreResetForTesting();
    Require(ApolloMessageDraftStoreText(@"alice", @"web:/chat/room/one", @"keep on failure"), @"stores send candidate");
    Require(!ApolloMessageDraftShouldClearForHTTPStatus(0), @"missing send status is not success");
    Require(!ApolloMessageDraftShouldClearForHTTPStatus(199), @"informational status is not success");
    Require(!ApolloMessageDraftShouldClearForHTTPStatus(500), @"server failure is not success");
    Require(!ApolloMessageDraftShouldClearForHTTPStatus(302), @"redirect is not a confirmed send");
    Require(!ApolloMessageDraftHandleSendHTTPStatus(@"alice", @"web:/chat/room/one", 500), @"failed send does not clear");
    Require([(ApolloMessageDraftLoadText(@"alice", @"web:/chat/room/one") ?: @"") isEqualToString:@"keep on failure"],
            @"failed send preserves draft");
    Require(ApolloMessageDraftShouldClearForHTTPStatus(200), @"200 send status is success");
    Require(ApolloMessageDraftShouldClearForHTTPStatus(204), @"204 send status is success");
    Require(ApolloMessageDraftHandleSendHTTPStatus(@"alice", @"web:/chat/room/one", 201), @"successful send clears draft");
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/room/one") == nil,
            @"successful send leaves no draft");
}

static void TestRapidSendThenTypeGeneration(void) {
    // Model a room where send A captures generation 1, the composer clears,
    // and the user types B before A's response arrives. A must never erase B.
    NSUInteger sentA = 1;
    NSUInteger typedB = 2;
    Require(!ApolloMessageDraftShouldClearForSendGeneration(200, sentA, typedB),
            @"A success cannot clear newer B typing");
    Require(!ApolloMessageDraftShouldClearForSendGeneration(500, sentA, typedB),
            @"A failure cannot clear newer B typing");
    // B may then be manually erased before A responds. The text generation is
    // still newer than A, so A must not cancel B's empty-delete timer.
    Require(!ApolloMessageDraftShouldInvalidateEmptyClearForSendGeneration(sentA, typedB),
            @"A response preserves B's manual-clear timer");
    Require(!ApolloMessageDraftSendOwnsContentGeneration(sentA, typedB),
            @"slow A does not block B's manual clear");
    Require(ApolloMessageDraftShouldClearForSendGeneration(200, sentA, sentA),
            @"a successful current generation clears its own draft");
    Require(ApolloMessageDraftShouldInvalidateEmptyClearForSendGeneration(sentA, sentA),
            @"current send response may cancel its own optimistic clear");
    Require(ApolloMessageDraftSendOwnsContentGeneration(sentA, sentA),
            @"a current send owns its own optimistic clear");
}

static void TestExpiryAndCleanup(void) {
    ApolloMessageDraftStoreResetForTesting();
    ApolloMessageDraftStoreSetTestingNow(100.0);
    Require(ApolloMessageDraftStoreText(@"alice", @"web:/chat/room/one", @"old"), @"stores expiring draft");
    ApolloMessageDraftStoreSetTestingNow(100.0 + 31.0 * 24.0 * 60.0 * 60.0);
    ApolloMessageDraftStorePruneExpired();
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/room/one") == nil, @"prunes expired draft");
    Require(ApolloMessageDraftStoreText(@"alice", @"web:/chat/room/one", @"alice"), @"stores Alice cleanup draft");
    Require(ApolloMessageDraftStoreText(@"bob", @"web:/chat/room/one", @"bob"), @"stores Bob cleanup draft");
    ApolloMessageDraftStoreRemoveAccount(@"alice");
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/room/one") == nil, @"removes deleted account drafts");
    Require([(ApolloMessageDraftLoadText(@"bob", @"web:/chat/room/one") ?: @"") isEqualToString:@"bob"], @"preserves other account drafts");
    ApolloMessageDraftStoreClearAll();
    Require(ApolloMessageDraftLoadText(@"bob", @"web:/chat/room/one") == nil, @"clears drafts when modern chat is disabled");
}

static void DrainStoreQueue(void) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    ApolloMessageDraftStoreAsync(^{ dispatch_semaphore_signal(done); });
    Require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"store queue drains");
}

static void TestMaintenanceOrdering(void) {
    ApolloMessageDraftStoreResetForTesting();
    ApolloMessageDraftStoreAsync(^{ ApolloMessageDraftStoreText(@"alice", @"web:/chat/one", @"one"); });
    ApolloMessageDraftStoreAsync(^{ ApolloMessageDraftStoreClearAll(); });
    DrainStoreQueue();
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/one") == nil, @"save then clear-all stays cleared");
    ApolloMessageDraftStoreAsync(^{ ApolloMessageDraftStoreText(@"alice", @"web:/chat/one", @"one"); });
    ApolloMessageDraftStoreAsync(^{ ApolloMessageDraftStoreRemoveAccount(@"alice"); });
    DrainStoreQueue();
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/one") == nil, @"save then remove-account stays removed");
    ApolloMessageDraftStoreAsync(^{ ApolloMessageDraftStoreText(@"alice", @"web:/chat/one", @"one"); });
    ApolloMessageDraftStoreAsync(^{ ApolloMessageDraftClear(@"alice", @"web:/chat/one"); });
    DrainStoreQueue();
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/one") == nil, @"save then clear stays cleared");
    NSUInteger oldGeneration = ApolloMessageDraftStoreInvalidationGeneration();
    NSUInteger oldAccountGeneration = ApolloMessageDraftStoreAccountGeneration(@"alice");
    ApolloMessageDraftStoreClearAll();
    Require(!ApolloMessageDraftStoreTextIfCurrent(@"alice", @"web:/chat/one", @"stale", oldGeneration, oldAccountGeneration), @"pre-clear token cannot resurrect after re-enable");
    NSUInteger bGlobal = ApolloMessageDraftStoreInvalidationGeneration();
    NSUInteger bAccount = ApolloMessageDraftStoreAccountGeneration(@"bob");
    ApolloMessageDraftStoreRemoveAccount(@"alice");
    Require(ApolloMessageDraftStoreTextIfCurrent(@"bob", @"web:/chat/one", @"b", bGlobal, bAccount), @"removing A does not invalidate B");
}

static void TestPendingDeleteFailClosed(void) {
    ApolloMessageDraftStoreResetForTesting();
    ApolloMessageDraftStoreText(@"alice", @"web:/chat/one", @"draft");
    ApolloMessageDraftStoreSetTestingDeleteFailure(YES);
    ApolloMessageDraftStoreMarkAccountPendingDelete(@"alice");
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/one") == nil, @"pending delete denies load before cleanup runs");
    DrainStoreQueue();
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/one") == nil, @"failed delete remains fail closed for retry");
    ApolloMessageDraftStoreSetTestingDeleteFailure(NO);
    ApolloMessageDraftStorePruneExpired();
    Require(ApolloMessageDraftLoadText(@"alice", @"web:/chat/one") == nil, @"prune retries pending delete");
}

int main(void) {
    @autoreleasepool {
        TestOpaqueKeyIsolation();
        TestRestoreAndIsolation();
        TestEmptyDeletes();
        TestSendSuccessAndFailure();
        TestRapidSendThenTypeGeneration();
        TestExpiryAndCleanup();
        TestMaintenanceOrdering();
        TestPendingDeleteFailClosed();
    }
    puts("message_draft_store_tests: all 8 tests passed");
    return 0;
}
