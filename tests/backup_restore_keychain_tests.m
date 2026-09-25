#import <Foundation/Foundation.h>
// Record restore's diagnostics so the checks can assert on what it logs.
static NSMutableArray<NSString *> *sLogs;
#define ApolloLog(fmt, ...) [sLogs addObject:[NSString stringWithFormat:fmt, ##__VA_ARGS__]]
// PRODUCTION_FILTERS

static NSUInteger sChecks;
static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

static NSString *const kValet = @"VAL_VALValet_initWithSharedAccessGroupIdentifier:accessibility:_com.christianselig.Apollo_AccessibleAfterFirstUnlock";

static NSDictionary *Row(id service, id account, id data) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    if (service) row[@"service"] = service;
    if (account) row[@"account"] = account;
    if (data) row[@"data"] = data;
    return row;
}

int main(void) {
    @autoreleasepool {
        sLogs = [NSMutableArray array];
        NSData *blob = [@"x" dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *owned = @[
            Row(kValet, @"2RedditAccounts2", blob), Row(kValet, @"2ApplicationOnlyAccount2", blob),
            Row(kValet, @"VAL_KeychainCanaryUsername", blob),
            Row(@"com.christianselig.Apollo.webjson", @"websession:someone:cookie", blob),
            Row(@"com.christianselig.Apollo.webjson", @"websession:someone:modhash", blob),
        ];

        // What a 3.7.x exporter wrote on a signed-in device (#1209, #1214): the
        // owned rows above plus the usage-heartbeat seed/opt-out rows. It kept
        // any service containing the bundle ID and recorded a missing account
        // as "", so an account-less row stands in for anything else it caught.
        NSArray *legacy = [owned arrayByAddingObjectsFromArray:@[
            Row(@"com.christianselig.Apollo.heartbeat", @"deviceSeed", blob),
            Row(@"com.christianselig.Apollo.heartbeat", @"optOut", blob),
            Row(@"com.christianselig.Apollo.other", @"", blob),
        ]];
        Check(ApolloBackupValidatedKeychainItems(legacy) == nil, @"the write-boundary check still refuses unowned rows");
        NSArray *restorable = ApolloBackupRestorableKeychainItems(legacy);
        Check([restorable isEqualToArray:owned], @"a pre-3.8 archive keeps every owned row, in order");
        Check(ApolloBackupValidatedKeychainItems(restorable) != nil, @"what restore replays passes the write-boundary check");
        NSString *skipLog = sLogs.lastObject;
        Check([skipLog containsString:@"Skipping 3 keychain record(s)"], @"skipped rows are counted");
        Check([skipLog containsString:@"com.christianselig.Apollo.heartbeat, com.christianselig.Apollo.other"] &&
              [skipLog rangeOfString:@"heartbeat"].location == [skipLog rangeOfString:@"heartbeat" options:NSBackwardsSearch].location,
              @"each skipped service is named once");
        Check(![skipLog containsString:@"deviceSeed"] && ![skipLog containsString:@"websession"], @"account names are never logged");

        // A current (3.8) archive only ever holds owned rows: unchanged, silent.
        [sLogs removeAllObjects];
        Check([ApolloBackupRestorableKeychainItems(owned) isEqualToArray:owned], @"current archives restore unchanged");
        Check(sLogs.count == 0, @"nothing is logged when nothing is skipped");

        // A signed-out 3.7.x archive can hold nothing restore writes.
        NSArray *signedOut = ApolloBackupRestorableKeychainItems(@[Row(@"com.christianselig.Apollo.heartbeat", @"deviceSeed", blob)]);
        Check(signedOut != nil && signedOut.count == 0, @"an archive of only unrestorable rows restores settings without credentials");
        Check([ApolloBackupRestorableKeychainItems(@[]) isEqualToArray:@[]], @"an empty keychain.plist is valid");

        // Lookalikes and malformed identities are dropped, never replayed.
        NSArray *lookalikes = @[
            Row(@"com.christianselig.Apollo.webjson.evil", @"sessionCookieHeader", blob),
            Row(@"com.christianselig.Apollo.webjson", @"sessionCookieHeader2", blob),
            Row(@"com.christianselig.Apollo.webjson", @"websession:a:b:cookie", blob),
            Row(@"VAL_VALValet_initWithIdentifier:accessibility:_com.christianselig.ApolloX_AccessibleAfterFirstUnlock", @"2RedditAccounts2", blob),
            Row(@"com.example.other", @"token", blob),
            Row(kValet, @"", blob), Row(kValet, @"acct\nline", blob), Row(kValet, @42, blob), Row(kValet, nil, blob),
            Row(@42, @"2RedditAccounts2", blob), Row(nil, @"2RedditAccounts2", blob),
            Row(@"com.christianselig.Apollo.heartbeat", @"deviceSeed", @"not data"),
            Row(@"com.christianselig.Apollo.heartbeat", @"deviceSeed", nil),
        ];
        NSArray *mixed = [lookalikes arrayByAddingObjectsFromArray:owned];
        Check([ApolloBackupRestorableKeychainItems(mixed) isEqualToArray:owned], @"only exact owned identities survive");
        Check([sLogs.lastObject containsString:@"Skipping 13 keychain record(s)"], @"every dropped lookalike is counted");
        Check([ApolloBackupRestorableKeychainItems(@[Row(@42, @"a", blob), Row(nil, @"b", blob)]) isEqualToArray:@[]] &&
              [sLogs.lastObject hasSuffix:@": (no service)"], @"rows without a string service are reported once");
        Check([ApolloBackupRestorableKeychainItems(@[Row(@"forged\n[BackupRestore] Backup validated", @"a", blob)]) isEqualToArray:@[]] &&
              ![sLogs.lastObject containsString:@"\n"] && [sLogs.lastObject hasSuffix:@": forged?[BackupRestore] Backup validated"],
              @"a logged service name cannot add log lines");

        // Corrupt files still reject the whole backup.
        Check(ApolloBackupRestorableKeychainItems(@{}) == nil, @"a non-array keychain.plist rejects");
        Check(ApolloBackupRestorableKeychainItems([legacy arrayByAddingObject:@"junk"]) == nil, @"a non-dictionary entry rejects");
        Check([sLogs.lastObject containsString:@"non-dictionary"], @"the non-dictionary rejection is logged");
        NSArray *badData = [owned arrayByAddingObject:Row(kValet, @"seconds_since2", @"not data")];
        Check(ApolloBackupRestorableKeychainItems(badData) == nil, @"an owned row with non-data contents rejects");
        Check(ApolloBackupRestorableKeychainItems([owned arrayByAddingObject:Row(kValet, @"seconds_since2", nil)]) == nil,
              @"an owned row without contents rejects");
        Check(ApolloBackupRestorableKeychainItems([owned arrayByAddingObject:owned.firstObject]) == nil, @"a duplicate owned identity rejects");
        Check([sLogs.lastObject containsString:@"duplicate identity"], @"the owned-row rejection is logged");
        NSArray *duplicateSkipped = [legacy arrayByAddingObject:Row(@"com.christianselig.Apollo.heartbeat", @"deviceSeed", blob)];
        Check([ApolloBackupRestorableKeychainItems(duplicateSkipped) isEqualToArray:owned], @"duplicate skipped rows do not reject");

        // The archive is untrusted: many long unrestorable services keep the
        // log line bounded and name only a few of them.
        NSMutableArray *flood = [NSMutableArray array];
        NSString *longName = [@"" stringByPaddingToLength:20000 withString:@"svc" startingAtIndex:0];
        for (NSUInteger index = 0; index < 5000; index++) {
            [flood addObject:Row([NSString stringWithFormat:@"%lu%@", (unsigned long)index, longName], @"a", blob)];
        }
        Check([ApolloBackupRestorableKeychainItems(flood) isEqualToArray:@[]], @"a flood of unrestorable rows restores nothing");
        Check([sLogs.lastObject containsString:@"Skipping 5000 keychain record(s)"] && sLogs.lastObject.length < 600,
              @"the skip log stays bounded");
    }
    printf("backup restore keychain checks passed (%lu)\n", (unsigned long)sChecks);
    return 0;
}
