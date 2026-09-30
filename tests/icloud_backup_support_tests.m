#import <Foundation/Foundation.h>
#import "settings/ApolloICloudBackupSupport.h"

static NSUInteger failures = 0;

static void Check(BOOL condition, NSString *label) {
    NSLog(@"%@ %@", condition ? @"PASS" : @"FAIL", label);
    if (!condition) failures++;
}

int main(void) {
    @autoreleasepool {
        Check(!ApolloICloudBackupEntitlementsAllowDocuments(@{}), @"missing entitlement is unsupported");
        Check(!ApolloICloudBackupEntitlementsAllowDocuments(@{
            @"com.apple.developer.ubiquity-container-identifiers": @[]
        }), @"empty container list is unsupported");
        Check(ApolloICloudBackupEntitlementsAllowDocuments(@{
            @"com.apple.developer.ubiquity-container-identifiers": @[@"iCloud.example"]
        }), @"legacy documents entitlement is accepted");
        Check(ApolloICloudBackupEntitlementsAllowDocuments(@{
            @"com.apple.developer.ubiquity-container-identifiers": @[@"iCloud.example"],
            @"com.apple.developer.icloud-services": @[@"CloudDocuments"]
        }), @"CloudDocuments entitlement is accepted");
        Check(!ApolloICloudBackupEntitlementsAllowDocuments(@{
            @"com.apple.developer.ubiquity-container-identifiers": @[@"iCloud.example"],
            @"com.apple.developer.icloud-services": @[@"CloudKit"]
        }), @"CloudKit alone is not document access");

        NSString *manual = @"Apollo_Manual_Backup_2026-09-30_001.apollobackup";
        NSString *automatic = @"Apollo_Auto_Backup_2026-09-30_002.zip";
        Check(ApolloICloudBackupArchiveNameIsSupported(manual), @"current manual name is accepted");
        Check(ApolloICloudBackupArchiveNameIsAutomatic(automatic), @"legacy automatic ZIP is accepted");
        Check(!ApolloICloudBackupArchiveNameIsSupported(@"../../account.apollobackup"), @"path traversal name is rejected");
        Check(!ApolloICloudBackupArchiveNameIsSupported(@"Apollo_Auto_Backup_2026-09-30_001.exe"), @"unexpected extension is rejected");

        NSString *unique = ApolloICloudBackupUniqueFilename(manual, @"12345678-ABCD-1234-ABCD-1234567890AB");
        Check(![unique isEqualToString:manual], @"cloud filename is collision resistant");
        Check(ApolloICloudBackupArchiveNameIsSupported(unique), @"unique cloud filename remains discoverable");
        Check([unique.pathExtension isEqualToString:@"apollobackup"], @"custom backup extension is preserved");
        NSData *scopeA = [@"team.container.a" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *scopeB = [@"team.container.b" dataUsingEncoding:NSUTF8StringEncoding];
        Check(ApolloICloudBackupScopeIdentifier(scopeA).length == 64,
              @"consent scope is a non-secret SHA-256 identifier");
        Check([ApolloICloudBackupScopeIdentifier(scopeA) isEqual:ApolloICloudBackupScopeIdentifier(scopeA)] &&
              ![ApolloICloudBackupScopeIdentifier(scopeA) isEqual:ApolloICloudBackupScopeIdentifier(scopeB)],
              @"consent scope is stable and changes with destination identity");

        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *older = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:manual]];
        NSURL *newer = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:automatic]];
        [NSData.data writeToURL:older atomically:YES];
        [NSData.data writeToURL:newer atomically:YES];
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:1]}
            ofItemAtPath:older.path error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:2]}
            ofItemAtPath:newer.path error:nil];
        NSArray<NSURL *> *sorted = ApolloICloudBackupSortURLsNewestFirst(@[older, newer]);
        Check([sorted.firstObject isEqual:newer], @"cross-device listing is newest first");
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }
    return failures == 0 ? 0 : 1;
}
