#import <Foundation/Foundation.h>

#import "ApolloLocalFilterTransfer.h"

static void AssertEqual(id actual, id expected) {
    NSCAssert([actual isEqual:expected], @"%@ != %@", actual, expected);
}

int main(void) {
    @autoreleasepool {
        AssertEqual(ApolloLocalFilterExportText(@[@"Apple", @"r/Banana", @"apple",
                                                  @"xy", @"Keep-legacy-value"]),
                    @"apple\nbanana\nxy\nKeep-legacy-value");

        NSUInteger added = 99;
        NSUInteger invalid = 99;
        ApolloLocalFilterImportStatus status = ApolloLocalFilterImportStatusTooManyBytes;
        NSArray *merged = ApolloLocalFilterMergeImportText(
            @[@"Existing", @"Keep-legacy-value", @42],
            @"r/existing\nNew_Sub\nhttps://www.reddit.com/r/ThirdSub/\n"
             "bad!name\nxy\nnew_sub,FourthSub;fourthsub",
            &added, &invalid, &status);
        AssertEqual(merged, (@[@"Existing", @"Keep-legacy-value", @42, @"new_sub",
                               @"thirdsub", @"xy", @"fourthsub"]));
        NSCAssert(added == 4, @"unexpected added count: %lu", (unsigned long)added);
        NSCAssert(invalid == 1, @"unexpected invalid count: %lu", (unsigned long)invalid);
        NSCAssert(status == ApolloLocalFilterImportStatusSuccess, @"unexpected import status");

        NSString *legacyExport = ApolloLocalFilterExportText(@[@"xy", @"Keep-legacy-value"]);
        NSArray *legacyRoundTrip = ApolloLocalFilterMergeImportText(
            @[], legacyExport, &added, &invalid, &status);
        AssertEqual(legacyRoundTrip, (@[@"xy", @"Keep-legacy-value"]));
        NSCAssert(added == 2 && invalid == 0 && status == ApolloLocalFilterImportStatusSuccess,
                  @"legacy round trip failed");

        // Import is merge-only: an empty or duplicate-only payload cannot
        // remove, rewrite, or reorder existing archive values.
        NSArray *unchanged = ApolloLocalFilterMergeImportText(
            @[@"MixedCase", @"legacy-value", @42], @"r/mixedcase", &added, &invalid, &status);
        AssertEqual(unchanged, (@[@"MixedCase", @"legacy-value", @42]));
        NSCAssert(added == 0 && invalid == 0, @"duplicate-only import changed counts");

        NSMutableArray<NSString *> *bulkNames = [NSMutableArray array];
        for (NSUInteger index = 0; index < 500; index++) {
            [bulkNames addObject:[NSString stringWithFormat:@"filter_%03lu", (unsigned long)index]];
        }
        NSArray *bulkMerged = ApolloLocalFilterMergeImportText(
            @[], [bulkNames componentsJoinedByString:@"\n"], &added, &invalid, &status);
        NSCAssert(bulkMerged.count == 500 && added == 500 && invalid == 0 &&
                  status == ApolloLocalFilterImportStatusSuccess, @"bulk import failed");

        NSString *oversized = [@"a" stringByPaddingToLength:256 * 1024 + 1
                                                withString:@"a"
                                           startingAtIndex:0];
        NSArray *byteRejected = ApolloLocalFilterMergeImportText(
            @[@"existing"], oversized, &added, &invalid, &status);
        AssertEqual(byteRejected, (@[@"existing"]));
        NSCAssert(added == 0 && invalid == 0 &&
                  status == ApolloLocalFilterImportStatusTooManyBytes,
                  @"oversized byte payload was not rejected");

        NSMutableArray<NSString *> *tooManyNames = [NSMutableArray array];
        for (NSUInteger index = 0; index < 4097; index++) {
            [tooManyNames addObject:[NSString stringWithFormat:@"s%04lu", (unsigned long)index]];
        }
        NSArray *entryRejected = ApolloLocalFilterMergeImportText(
            @[@"existing"], [tooManyNames componentsJoinedByString:@" "],
            &added, &invalid, &status);
        AssertEqual(entryRejected, (@[@"existing"]));
        NSCAssert(added == 0 && invalid == 0 &&
                  status == ApolloLocalFilterImportStatusTooManyEntries,
                  @"oversized entry payload was not rejected");

        // Model the account archive as a keyed Foundation object. A transfer
        // must survive a full archive round trip without changing unrelated
        // account fields or rewriting the existing filter entries.
        NSDictionary *account = @{
            @"username": @"fixture-account",
            @"credentialMarker": [@"opaque-account-data" dataUsingEncoding:NSUTF8StringEncoding],
            @"locallyFilteredSubreddits": @[@"MixedCase", @"legacy-value"],
        };
        NSError *archiveError = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:account
                                                requiringSecureCoding:YES
                                                                error:&archiveError];
        NSCAssert(archive && !archiveError, @"initial archive failed: %@", archiveError);
        NSSet *classes = [NSSet setWithObjects:NSDictionary.class, NSArray.class,
                          NSString.class, NSData.class, nil];
        NSDictionary *decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                     fromData:archive
                                                                        error:&archiveError];
        NSCAssert(decoded && !archiveError, @"initial unarchive failed: %@", archiveError);
        NSArray *roundTripFilters = ApolloLocalFilterMergeImportText(
            decoded[@"locallyFilteredSubreddits"], @"r/New_Sub", &added, &invalid, &status);
        NSMutableDictionary *updated = [decoded mutableCopy];
        updated[@"locallyFilteredSubreddits"] = roundTripFilters;
        NSData *updatedArchive = [NSKeyedArchiver archivedDataWithRootObject:updated
                                                       requiringSecureCoding:YES
                                                                       error:&archiveError];
        NSDictionary *roundTrip = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                       fromData:updatedArchive
                                                                          error:&archiveError];
        NSCAssert(roundTrip && !archiveError, @"updated round trip failed: %@", archiveError);
        AssertEqual(roundTrip[@"username"], account[@"username"]);
        AssertEqual(roundTrip[@"credentialMarker"], account[@"credentialMarker"]);
        AssertEqual(roundTrip[@"locallyFilteredSubreddits"],
                    (@[@"MixedCase", @"legacy-value", @"new_sub"]));

        puts("local_filter_transfer_tests passed");
    }
    return 0;
}
