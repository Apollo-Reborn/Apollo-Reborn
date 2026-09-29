// Give every native media share its own file (#1182).
//
// Apollo's ShareMediaManager hands the share sheet one of two FIXED temp paths:
//
//   NSTemporaryDirectory()/Video.mov  "Download Video…": shareDownloadedVideo()
//                                     (0x1004b5920) and the v.redd.it audio merge
//                                     (0x1004ba594) both export here, deleting the
//                                     previous file first.
//   NSTemporaryDirectory()/Image.gif  "Download GIF…": the MP4 -> GIF conversion
//                                     (0x1004b1998) and shareOldSchoolGIF
//                                     (0x1004a81f8) both write here.
//
// So every share offers the receiving app the exact same file URL with
// different bytes. Messages reuses what it built for that file the first time:
// its compose sheet previews the new video, but the text that goes out carries
// the FIRST one, until the device reboots. Killing Apollo doesn't help, so the
// stale copy lives on the Messages side. Mail and Copy read the bytes fresh,
// which is why only Messages misbehaves.
//
// Swap that one activity item for an APFS clone with a per-share name
// (tmp/ApolloShareMedia/Video-1A2B3C4D.mov). The clone is instant and shares
// blocks with the original until Apollo replaces it. Apollo's own Copy Video /
// Save Video read the Swift-captured Video.mov URL in the sheet's completion
// handler (0x1004b73d8), not the items, so they are unaffected.
//
// Three other modules hook this initializer (ApolloShareAsImageLink rewrites
// reddit.com web URLs only, ApolloSaveAllMediaMenus adds an activity when
// Apollo's SaveMediaActivity is present, ApolloGIFSaveActivity records the .gif
// URL for Save GIF and copies it when the action is picked). None of them
// depends on the exact file path, so the Logos install order doesn't matter.
#import <UIKit/UIKit.h>
#import <errno.h>
#import <sys/clonefile.h>
#import <unistd.h>
#import "ApolloCommon.h"

static NSString *const kApolloShareHandoffFolder = @"ApolloShareMedia";

// Only the two names ShareMediaManager writes straight into tmp/. This is the
// caller gate: in the Apollo binary those two literals exist only in the
// ShareMediaManager functions above, the tweak's own exports use unique names,
// and ApolloGIFSaveActivity keeps its Image.gif in its own UUID folder. A
// return-address check would break as soon as another module's hook wraps
// this one.
static BOOL ApolloShareHandoffIsFixedNativeFile(id item) {
    if (![item isKindOfClass:NSURL.class]) return NO;
    NSURL *url = item;
    if (!url.isFileURL) return NO;
    NSString *name = url.lastPathComponent;
    if (![name isEqualToString:@"Video.mov"] && ![name isEqualToString:@"Image.gif"]) return NO;
    NSString *parent = url.URLByDeletingLastPathComponent.path.stringByStandardizingPath;
    return [parent isEqualToString:NSTemporaryDirectory().stringByStandardizingPath];
}

static NSURL *ApolloShareHandoffUniqueCopy(NSURL *source) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:kApolloShareHandoffFolder];
    // Keep one handoff at a time, like Apollo's own fixed file: the next share
    // replaces it. Deleting on sheet completion instead could pull the file out
    // from under Messages while it is still sending.
    [fileManager removeItemAtPath:folder error:nil];
    NSError *error = nil;
    if (![fileManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error]) {
        ApolloLog(@"[ShareMediaHandoff] couldn't create handoff folder: %@", error.localizedDescription);
        return nil;
    }
    // A unique NAME, not just a unique folder: whatever Messages keys its reuse
    // on (path or filename), each share now looks new to it.
    NSString *token = [NSUUID.UUID.UUIDString substringToIndex:8];
    NSString *name = [NSString stringWithFormat:@"%@-%@.%@",
        source.lastPathComponent.stringByDeletingPathExtension, token, source.pathExtension];
    NSString *destination = [folder stringByAppendingPathComponent:name];
    // Both are O(1) on the same volume, so nothing is copied on the main thread.
    // A hard link is only the fallback: Apollo deletes and re-exports these
    // files, but shareOldSchoolGIF may rewrite Image.gif in place.
    if (clonefile(source.path.fileSystemRepresentation, destination.fileSystemRepresentation, 0) != 0) {
        int cloneErrno = errno;
        if (link(source.path.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) {
            ApolloLog(@"[ShareMediaHandoff] clone and link failed for %@ (errno %d/%d); sharing the fixed file",
                      source.lastPathComponent, cloneErrno, errno);
            return nil;
        }
        ApolloLog(@"[ShareMediaHandoff] clone failed (errno %d); hard-linked instead", cloneErrno);
    }
    return [NSURL fileURLWithPath:destination isDirectory:NO];
}

%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)applicationActivities {
    // Process-wide initializer: bail unless an item is one of the fixed files.
    if (![activityItems isKindOfClass:NSArray.class]) return %orig;
    NSUInteger index = [activityItems indexOfObjectPassingTest:^BOOL(id item, __unused NSUInteger i, __unused BOOL *stop) {
        return ApolloShareHandoffIsFixedNativeFile(item);
    }];
    if (index == NSNotFound) return %orig;

    NSURL *source = activityItems[index];
    NSURL *handoff = ApolloShareHandoffUniqueCopy(source);
    if (!handoff) return %orig;
    NSMutableArray *items = [activityItems mutableCopy];
    items[index] = handoff;
    ApolloLog(@"[ShareMediaHandoff] %@ -> %@/%@", source.lastPathComponent,
              kApolloShareHandoffFolder, handoff.lastPathComponent);
    return %orig(items, applicationActivities);
}

%end

%ctor {
    %init;
    ApolloLog(@"[ShareMediaHandoff] share sheet file handoff hook installed");
}
