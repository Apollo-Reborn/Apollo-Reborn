#import <Foundation/Foundation.h>
#import "settings/ApolloICloudBackupStore.h"
#import "settings/ApolloICloudBackupSupport.h"

@interface ApolloICloudBackupStore (Testing)
@property (atomic, readwrite, copy, nullable) NSString *scopeIdentifier;
- (NSURL *)resolveDirectoryWithError:(NSError **)error
                          accessRoot:(NSURL **)accessRoot
                              scoped:(BOOL *)scoped;
@end

@interface ApolloTestICloudBackupStore : ApolloICloudBackupStore
@property (nonatomic, strong) NSURL *testDirectory;
@end

@implementation ApolloTestICloudBackupStore
- (NSURL *)resolveDirectoryWithError:(NSError **)error
                          accessRoot:(NSURL **)accessRoot
                              scoped:(BOOL *)scoped {
    if (error) *error = nil;
    if (accessRoot) *accessRoot = self.testDirectory;
    if (scoped) *scoped = NO;
    self.scopeIdentifier = @"test-scope";
    return self.testDirectory;
}
@end

static NSUInteger failures = 0;

static void Check(BOOL condition, NSString *label) {
    NSLog(@"%@ %@", condition ? @"PASS" : @"FAIL", label);
    if (!condition) failures++;
}

static NSURL *Write(NSURL *directory, NSString *name, NSString *contents) {
    NSURL *url = [directory URLByAppendingPathComponent:name isDirectory:NO];
    [[contents dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES];
    return url;
}

static NSURL *Upload(ApolloICloudBackupStore *store, NSURL *localURL,
                     NSString *identityToken, NSError **uploadError) {
    __block NSURL *published = nil;
    __block NSError *error = nil;
    __block BOOL finished = NO;
    [store uploadLocalBackupURL:localURL expectedScope:@"test-scope" identityToken:identityToken
        completion:^(NSURL *url, NSError *completionError) {
            published = url;
            error = completionError;
            finished = YES;
        }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (!finished && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    if (uploadError) *uploadError = error;
    Check(finished, @"upload completion returns");
    return published;
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSURL *local = [root URLByAppendingPathComponent:@"local" isDirectory:YES];
        NSURL *cloud = [root URLByAppendingPathComponent:@"cloud" isDirectory:YES];
        [fm createDirectoryAtURL:local withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtURL:cloud withIntermediateDirectories:YES attributes:nil error:nil];

        ApolloTestICloudBackupStore *store = [ApolloTestICloudBackupStore new];
        store.testDirectory = cloud;
        NSString *identity = @"12345678-ABCD-1234-ABCD-1234567890AB";
        NSString *filename = @"Apollo_Manual_Backup_2026-10-01_006.apollobackup";
        NSURL *localURL = Write(local, filename, @"new bytes");
        NSString *originalName = ApolloICloudBackupUniqueFilename(filename, identity);
        NSURL *originalCloudURL = Write(cloud, originalName, @"old bytes");

        NSError *error = nil;
        NSURL *published = Upload(store, localURL, identity, &error);
        Check(error == nil && published != nil, @"different-content collision publishes successfully");
        Check(![published.lastPathComponent isEqualToString:originalName],
              @"different-content collision publishes under a fresh name");
        Check([fm contentsEqualAtPath:localURL.path andPath:published.path],
              @"fresh collision destination contains the new archive");
        NSData *oldData = [NSData dataWithContentsOfURL:originalCloudURL];
        Check([[[NSString alloc] initWithData:oldData encoding:NSUTF8StringEncoding] isEqualToString:@"old bytes"],
              @"existing cloud archive remains unchanged");

        NSURL *laterLocalURL = Write(local, @"Apollo_Manual_Backup_2026-10-01_007.apollobackup", @"later bytes");
        NSURL *laterPublished = Upload(store, laterLocalURL, identity, &error);
        Check(error == nil && laterPublished != nil,
              @"a later backup publishes after the collision");

        NSArray<NSURL *> *contents = [fm contentsOfDirectoryAtURL:cloud
            includingPropertiesForKeys:nil options:0 error:nil];
        NSPredicate *pending = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
            (void)bindings;
            return [url.lastPathComponent hasSuffix:@".pending"];
        }];
        Check([[contents filteredArrayUsingPredicate:pending] count] == 0,
              @"collision publication leaves no pending files");
        [fm removeItemAtURL:root error:nil];
    }
    return failures == 0 ? 0 : 1;
}
