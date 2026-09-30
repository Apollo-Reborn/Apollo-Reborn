#import "settings/ApolloICloudBackupSupport.h"
#import <CommonCrypto/CommonDigest.h>

BOOL ApolloICloudBackupEntitlementsAllowDocuments(NSDictionary *entitlements) {
    id identifiers = entitlements[@"com.apple.developer.ubiquity-container-identifiers"];
    if (![identifiers isKindOfClass:NSArray.class] || [identifiers count] == 0) return NO;
    for (id identifier in identifiers) {
        if (![identifier isKindOfClass:NSString.class] || [identifier length] == 0) return NO;
    }

    // Older profiles can omit icloud-services while still carrying a valid
    // ubiquity-container entitlement. When present, it must authorize documents.
    id services = entitlements[@"com.apple.developer.icloud-services"];
    return !services || ([services isKindOfClass:NSArray.class] &&
        [services containsObject:@"CloudDocuments"]);
}

BOOL ApolloICloudBackupArchiveNameIsSupported(NSString *name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSString *pattern = @"^Apollo_(Auto|Manual)_Backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{3,}(?:_[0-9A-Fa-f-]{8,})?\\.(?:zip|apollobackup)$";
    NSRange match = [name rangeOfString:pattern options:NSRegularExpressionSearch];
    return match.location == 0 && NSMaxRange(match) == name.length;
}

BOOL ApolloICloudBackupArchiveNameIsAutomatic(NSString *name) {
    return [name hasPrefix:@"Apollo_Auto_Backup_"] && ApolloICloudBackupArchiveNameIsSupported(name);
}

NSString *ApolloICloudBackupUniqueFilename(NSString *localFilename, NSString *uniqueToken) {
    NSString *extension = localFilename.pathExtension.length ? localFilename.pathExtension : @"apollobackup";
    NSString *stem = localFilename.stringByDeletingPathExtension;
    NSString *token = [[uniqueToken componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"]
        .invertedSet] componentsJoinedByString:@""];
    if (token.length < 8) token = NSUUID.UUID.UUIDString;
    return [NSString stringWithFormat:@"%@_%@.%@", stem, token, extension];
}

NSArray<NSURL *> *ApolloICloudBackupSortURLsNewestFirst(NSArray<NSURL *> *urls) {
    return [urls sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *aDate = nil, *bDate = nil;
        [a getResourceValue:&aDate forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&bDate forKey:NSURLContentModificationDateKey error:nil];
        NSComparisonResult dateOrder = [(bDate ?: NSDate.distantPast) compare:(aDate ?: NSDate.distantPast)];
        return dateOrder != NSOrderedSame ? dateOrder
            : [b.lastPathComponent compare:a.lastPathComponent options:NSNumericSearch];
    }];
}

NSString *ApolloICloudBackupScopeIdentifier(NSData *scopeData) {
    if (scopeData.length == 0) return @"";
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(scopeData.bytes, (CC_LONG)scopeData.length, digest);
    NSMutableString *value = [NSMutableString stringWithCapacity:sizeof(digest) * 2];
    for (NSUInteger index = 0; index < sizeof(digest); index++) [value appendFormat:@"%02x", digest[index]];
    return value;
}
