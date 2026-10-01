#import <Foundation/Foundation.h>
#import "ApolloICloudReadState.h"

static NSUInteger failures;
static void Check(BOOL condition, NSString *message) {
    printf("%s: %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition) failures++;
}

static NSDictionary *Journal(NSString *writer, double clearAt, NSDictionary *records) {
    return @{@"v": @1, @"w": writer, @"clear": @(clearAt), @"records": records};
}

static NSDictionary *Record(NSNumber *readAt, NSNumber *unreadAt, NSNumber *commentAt, NSNumber *count,
                            NSString *writer) {
    NSMutableDictionary *record = [@{@"w": writer} mutableCopy];
    if (readAt) record[@"r"] = readAt;
    if (unreadAt) record[@"u"] = unreadAt;
    if (commentAt) record[@"c"] = commentAt;
    if (count) record[@"n"] = count;
    return record;
}

int main(void) {
    @autoreleasepool {
        NSDictionary *first = Journal(@"writer-a", 0, @{
            @"abc": Record(@10, nil, @20, @4, @"writer-a"),
            @"gone": Record(@5, @12, nil, nil, @"writer-a"),
        });
        NSDictionary *second = Journal(@"writer-b", 0, @{
            @"abc": Record(@15, nil, @22, @7, @"writer-b"),
            @"fresh": Record(@30, nil, nil, nil, @"writer-b"),
        });

        Check(ApolloICloudReadStateValidatedJournal(first) != nil, @"valid journal is accepted");
        Check(ApolloICloudReadStateValidatedJournal(@{@"v": @2}) == nil, @"unknown schema is rejected");
        Check(ApolloICloudReadStateValidatedJournal(Journal(@"w", 0,
            @{@"bad id!": Record(@1, nil, nil, nil, @"w")})) == nil, @"invalid post ID is rejected");
        Check(ApolloICloudReadStateValidatedJournal(Journal(@"w", 0,
            @{@"abc": Record(@1, nil, @2, @1.5, @"w")})) == nil, @"fractional comment count is rejected");
        Check(ApolloICloudReadStateValidatedJournal(Journal(@"w", 0,
            @{@"abc": Record(@([NSDate date].timeIntervalSince1970 + 2 * 86400), nil, nil, nil, @"w")})) == nil,
            @"far-future clock poison is rejected");

        NSDictionary *mergedAB = ApolloICloudReadStateMergeJournals(@[first, second]);
        NSDictionary *mergedBA = ApolloICloudReadStateMergeJournals(@[second, first]);
        NSArray *expected = @[@"abc", @"fresh"];
        Check([ApolloICloudReadStateProjectedReadIDs(mergedAB, 5000) isEqual:expected],
              @"newer read wins and explicit unread remains unread");
        Check([ApolloICloudReadStateProjectedReadIDs(mergedAB, 5000)
            isEqual:ApolloICloudReadStateProjectedReadIDs(mergedBA, 5000)], @"merge is commutative");
        Check([[ApolloICloudReadStateMergeJournals(@[first, first]) objectForKey:@"records"]
            isEqual:[ApolloICloudReadStateMergeJournals(@[first]) objectForKey:@"records"]], @"merge is idempotent");
        NSDictionary *emptyDevice = Journal(@"new-device", 0, @{});
        Check([ApolloICloudReadStateMergeJournals(@[mergedAB, emptyDevice]) isEqual:mergedAB],
              @"receiving converged cloud state reaches a no-write fixed point");
        NSMutableDictionary *adopted = [mergedAB mutableCopy];
        adopted[@"w"] = @"device-b";
        NSDictionary *capturedAgain = ApolloICloudReadStateJournalByCapturing(adopted, expected,
            @{@"abc": @{@"timestamp": @22, @"totalComments": @7}}, expected, 999, NO);
        Check([capturedAgain isEqual:adopted],
              @"capturing a projected remote snapshot preserves timestamps and writer metadata");

        NSArray *historicalOrder = @[@"z-last-alphabetically", @"a-first-alphabetically", @"middle"];
        NSDictionary *historical = ApolloICloudReadStateJournalByCapturing(
            Journal(@"device", 0, @{}), historicalOrder, @{}, nil, 100, YES);
        Check([ApolloICloudReadStateProjectedReadIDs(historical, 5000) isEqual:historicalOrder],
              @"historical seed timestamps preserve native Recently Read order");
        NSArray *revisitedOrder = @[@"a-first-alphabetically", @"middle", @"z-last-alphabetically"];
        NSDictionary *revisited = ApolloICloudReadStateJournalByCapturing(
            historical, revisitedOrder, @{}, historicalOrder, 200, NO);
        Check([ApolloICloudReadStateProjectedReadIDs(revisited, 5000) isEqual:revisitedOrder] &&
              [revisited[@"records"][@"z-last-alphabetically"][@"r"] doubleValue] > 100,
              @"moving a previously read post toward the tail refreshes its ordering clock");
        NSDictionary *revisitedAgain = ApolloICloudReadStateJournalByCapturing(
            revisited, revisitedOrder, @{}, revisitedOrder, 300, NO);
        Check([revisitedAgain isEqual:revisited],
              @"capturing unchanged ordered history does not churn timestamps");

        NSDictionary *cleared = ApolloICloudReadStateMergeJournals(@[first, Journal(@"writer-c", 25, @{})]);
        Check(ApolloICloudReadStateProjectedReadIDs(cleared, 5000).count == 0,
              @"clear marker suppresses stale reads");

        NSData *comments = ApolloICloudReadStateProjectedCommentData(mergedAB, 1000);
        NSArray *native = [NSJSONSerialization JSONObjectWithData:comments options:0 error:nil];
        Check(native.count == 2 && [native[0] isEqual:@"abc"] && [native[1][@"timestamp"] isEqual:@22] &&
              [native[1][@"totalComments"] isEqual:@7], @"latest view timestamp and baseline are projected");

        NSDictionary *tie = ApolloICloudReadStateMergeJournals(@[
            Journal(@"a", 0, @{@"same": Record(nil, nil, @50, @8, @"a")}),
            Journal(@"b", 0, @{@"same": Record(nil, nil, @50, @9, @"b")}),
        ]);
        NSArray *tieNative = [NSJSONSerialization JSONObjectWithData:
            ApolloICloudReadStateProjectedCommentData(tie, 1000) options:0 error:nil];
        Check([tieNative[1][@"totalComments"] isEqual:@9], @"higher count deterministically wins equal timestamp");

        NSMutableDictionary *many = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 12; i++) {
            many[[NSString stringWithFormat:@"p%02lu", (unsigned long)i]] =
                Record(@(i + 1), nil, @(i + 1), @(i), @"cap");
        }
        NSDictionary *capped = ApolloICloudReadStateMergeJournals(@[Journal(@"cap", 0, many)]);
        NSArray *readCap = ApolloICloudReadStateProjectedReadIDs(capped, 5);
        Check(readCap.count == 5 && [readCap.firstObject isEqual:@"p07"] && [readCap.lastObject isEqual:@"p11"],
              @"read projection keeps newest entries at cap");
        NSArray *commentCap = [NSJSONSerialization JSONObjectWithData:
            ApolloICloudReadStateProjectedCommentData(capped, 3) options:0 error:nil];
        Check(commentCap.count == 6 && [commentCap[0] isEqual:@"p09"] && [commentCap[4] isEqual:@"p11"],
              @"comment projection keeps newest baselines at cap");

        NSMutableData *key = [NSMutableData dataWithLength:32];
        memset(key.mutableBytes, 0x5a, key.length);
        NSData *plain = [@"private post history" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *encrypted = ApolloICloudReadStateEncrypt(plain, key, nil);
        Check(encrypted.length > plain.length && [encrypted rangeOfData:plain options:0
            range:NSMakeRange(0, encrypted.length)].location == NSNotFound, @"cloud envelope does not expose plaintext");
        Check([ApolloICloudReadStateDecrypt(encrypted, key, nil) isEqual:plain], @"encrypted journal round trips");
        NSMutableData *tampered = [encrypted mutableCopy];
        ((uint8_t *)tampered.mutableBytes)[20] ^= 1;
        Check(ApolloICloudReadStateDecrypt(tampered, key, nil) == nil, @"tampered journal is rejected");

        NSMutableDictionary *restored = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 5000; i++) {
            restored[[NSString stringWithFormat:@"r%04lu", (unsigned long)i]] =
                Record(@1, nil, nil, nil, @"restore");
        }
        NSDictionary *restoredJournal = ApolloICloudReadStateMergeJournals(@[
            Journal(@"restore", 0, restored), Journal(@"remote", 100, @{})]);
        Check(ApolloICloudReadStateProjectedReadIDs(restoredJournal, 5000).count == 0,
              @"remote clear beats timestamp-less restored history");
        NSData *largePlain = [NSPropertyListSerialization dataWithPropertyList:restoredJournal
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        Check(largePlain.length < 900 * 1024, @"single bounded 5,000-record journal fits KVS quota budget");

        NSMutableDictionary *overflowA = [NSMutableDictionary dictionary];
        NSMutableDictionary *overflowB = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 4000; i++) {
            overflowA[[NSString stringWithFormat:@"a%04lu", (unsigned long)i]] = Record(@(i + 1), nil, nil, nil, @"a");
            overflowB[[NSString stringWithFormat:@"b%04lu", (unsigned long)i]] = Record(@(i + 4001), nil, nil, nil, @"b");
        }
        NSDictionary *compacted = ApolloICloudReadStateMergeJournals(@[
            Journal(@"a", 0, overflowA), Journal(@"b", 0, overflowB)]);
        Check([compacted[@"records"] count] == 6500 && [compacted[@"clear"] doubleValue] >= 1500,
              @"concurrent histories compact to one bounded journal with an anti-resurrection floor");
        NSMutableDictionary *generationOne = [first mutableCopy]; generationOne[@"g"] = @1;
        NSMutableDictionary *generationTwo = [second mutableCopy]; generationTwo[@"g"] = @2;
        Check([[ApolloICloudReadStateMergeJournals(@[generationOne, generationTwo]) objectForKey:@"g"] isEqual:@2],
              @"newer reset generation propagates across clients");
        long long parsedGeneration = 0;
        NSData *resetMarker = ApolloICloudReadStateResetMarker(3);
        Check(ApolloICloudReadStateParseResetMarker(resetMarker, &parsedGeneration) && parsedGeneration == 3,
              @"atomic reset marker carries the generation in the state key");
        Check(ApolloICloudReadStateDecrypt(resetMarker, key, nil) == nil,
              @"reset marker cannot be mistaken for an encrypted journal");

        printf("%lu failure(s)\n", (unsigned long)failures);
        return failures == 0 ? 0 : 1;
    }
}
