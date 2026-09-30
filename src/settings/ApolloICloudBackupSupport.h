#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__BEGIN_DECLS

// Pure helpers shared by the iCloud store and its host-side tests.
BOOL ApolloICloudBackupEntitlementsAllowDocuments(NSDictionary *entitlements);
BOOL ApolloICloudBackupArchiveNameIsSupported(NSString *name);
BOOL ApolloICloudBackupArchiveNameIsAutomatic(NSString *name);
NSString *ApolloICloudBackupUniqueFilename(NSString *localFilename, NSString *uniqueToken);
NSArray<NSURL *> *ApolloICloudBackupSortURLsNewestFirst(NSArray<NSURL *> *urls);
NSString *ApolloICloudBackupScopeIdentifier(NSData *scopeData);

__END_DECLS

NS_ASSUME_NONNULL_END
