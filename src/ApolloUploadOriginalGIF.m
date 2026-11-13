#import "ApolloUploadOriginalGIF.h"

#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

#import "ApolloCommon.h"
#import "ApolloMarkdownToolbarGif.h"
#import "fishhook.h"

// BEGIN_ORIGINAL_GIF_STORE (tests/run_upload_original_gif_tests.sh compiles from
// here to END_ORIGINAL_GIF_STORE on the Mac, with stubs for ApolloLog and the
// active-composer lookup).

// Reddit's native image limit is about 20 MB, and Imgur and Image Chest take at
// least that. A bigger GIF keeps Apollo's still rather than failing the upload.
static const unsigned long long kApolloOriginalGIFMaxBytes = 20ULL * 1024ULL * 1024ULL;
// A picker session takes up to 10 photos. An upload consumes its entry, so the
// cap and lifetime only bound picks whose upload never ran.
static const NSUInteger kApolloOriginalGIFMaxEntries = 20;
static const NSTimeInterval kApolloOriginalGIFLifetime = 60.0 * 60.0;
static NSString *const kApolloOriginalGIFCaptureKey = @"ApolloUploadOriginalGIFCapture";

// One pass of Apollo's prep chain on the current thread (the item provider's
// completion queue). Pointers are compared, never dereferenced.
@interface ApolloOriginalGIFCapture : NSObject
@property (nonatomic, strong) NSURL *gifURL;   // nil: a still (or one-frame GIF) pick
@property (nonatomic) size_t frameCount;
@property (nonatomic) const void *destination;
@property (nonatomic, strong) NSMutableData *destinationData;
@end

@implementation ApolloOriginalGIFCapture
@end

// One pick in a comment/reply composer, filed under the digest of the JPEG
// Apollo made from it. Stills are filed too (no GIF kept): a still whose JPEG
// matches a kept GIF's must not be able to claim that GIF.
@interface ApolloOriginalGIFEntry : NSObject
@property (nonatomic, copy) NSData *jpegDigest;
@property (nonatomic, copy) NSData *gifDigest;     // nil for a still
@property (nonatomic, strong) NSURL *gifFileURL;   // nil for a still
@property (nonatomic, weak) id composer;           // the composer it was picked in
@property (nonatomic, strong) NSDate *createdAt;
// Another pick in the same composer made the same JPEG from different content,
// so the uploads can't be told apart (see ApolloOriginalGIFTakeEntryForDigest).
@property (nonatomic) BOOL ambiguous;
@end

@implementation ApolloOriginalGIFEntry
@end

static NSMutableArray<ApolloOriginalGIFEntry *> *sApolloOriginalGIFEntries = nil;

BOOL ApolloUploadDataIsGIF(NSData *data) {
    if (data.length < 6) return NO;
    const char *bytes = (const char *)data.bytes;
    return memcmp(bytes, "GIF87a", 6) == 0 || memcmp(bytes, "GIF89a", 6) == 0;
}

static NSData *ApolloOriginalGIFDigest(NSData *data) {
    if (data.length == 0) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSURL *ApolloOriginalGIFRootDirectory(void) {
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ApolloReborn-OriginalGIFs"] isDirectory:YES];
}

// This launch's copies live in their own folder, so clearing earlier launches'
// folders at startup can't race a GIF picked right after launch.
static NSURL *ApolloOriginalGIFDirectory(void) {
    static NSURL *directory;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        directory = [ApolloOriginalGIFRootDirectory() URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    });
    return directory;
}

// Caller holds the entries lock. Drops entries that expired, whose composer is
// gone (the draft was posted or discarded), or that belong to an earlier
// composer once a different one is active, and deletes their kept files. So a
// GIF from a draft that never uploaded can't be matched by a later composer.
static void ApolloOriginalGIFPruneLocked(id currentComposer) {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kApolloOriginalGIFLifetime];
    NSMutableIndexSet *stale = [NSMutableIndexSet indexSet];
    __block NSUInteger closedComposerEntries = 0;
    [sApolloOriginalGIFEntries enumerateObjectsUsingBlock:^(ApolloOriginalGIFEntry *entry, NSUInteger idx, __unused BOOL *stop) {
        id owner = entry.composer;
        if (!owner || (currentComposer && owner != currentComposer)) {
            [stale addIndex:idx];
            closedComposerEntries++;
        } else if ([entry.createdAt compare:cutoff] == NSOrderedAscending) {
            [stale addIndex:idx];
        }
    }];
    NSUInteger live = sApolloOriginalGIFEntries.count - stale.count;
    for (NSUInteger idx = 0; idx < sApolloOriginalGIFEntries.count && live > kApolloOriginalGIFMaxEntries; idx++) {
        if ([stale containsIndex:idx]) continue;
        [stale addIndex:idx];   // oldest first
        live--;
    }
    if (stale.count == 0) return;
    [[sApolloOriginalGIFEntries objectsAtIndexes:stale] enumerateObjectsUsingBlock:^(ApolloOriginalGIFEntry *entry, __unused NSUInteger idx, __unused BOOL *stop) {
        if (entry.gifFileURL) [[NSFileManager defaultManager] removeItemAtURL:entry.gifFileURL error:nil];
    }];
    [sApolloOriginalGIFEntries removeObjectsAtIndexes:stale];
    if (closedComposerEntries > 0) {
        ApolloLog(@"[OriginalGIF] Dropped %lu kept pick(s) from a composer that's no longer open", (unsigned long)closedComposerEntries);
    }
}

// Apollo's JPEG is final: copy the GIF out of the item provider's temporary file
// (deleted once its completion returns) and file it under the JPEG's digest. A
// still (gifURL nil) is filed with no GIF.
static void ApolloOriginalGIFRemember(NSData *jpegData, NSURL *gifURL, size_t frameCount) {
    // Comments only: the post composer (galleries, video posters) and chat keep
    // Apollo's still for now.
    id composer = ApolloActiveCommentComposer();
    if (!composer) return;
    NSData *digest = ApolloOriginalGIFDigest(jpegData);
    if (!digest) return;

    NSURL *copyURL = nil;
    NSData *gifDigest = nil;
    NSNumber *size = nil;
    if (gifURL) {
        [gifURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > kApolloOriginalGIFMaxBytes) {
            ApolloLog(@"[OriginalGIF] GIF is %@ bytes (limit %llu); uploading Apollo's still instead", size ?: @"?", kApolloOriginalGIFMaxBytes);
        } else {
            NSURL *directory = ApolloOriginalGIFDirectory();
            [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
            copyURL = [directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"gif"]];
            NSError *copyError = nil;
            if ([[NSFileManager defaultManager] copyItemAtURL:gifURL toURL:copyURL error:&copyError]) {
                gifDigest = ApolloOriginalGIFDigest([NSData dataWithContentsOfURL:copyURL options:NSDataReadingMappedIfSafe error:nil]);
            } else {
                ApolloLog(@"[OriginalGIF] Could not keep the picked GIF (%@); uploading Apollo's still", copyError.localizedDescription ?: @"copy failed");
            }
            if (!gifDigest) {
                [[NSFileManager defaultManager] removeItemAtURL:copyURL error:nil];
                copyURL = nil;
            }
        }
    }

    ApolloOriginalGIFEntry *entry = [ApolloOriginalGIFEntry new];
    entry.jpegDigest = digest;
    entry.gifDigest = gifDigest;
    entry.gifFileURL = copyURL;
    entry.composer = composer;
    entry.createdAt = [NSDate date];
    @synchronized([ApolloOriginalGIFEntry class]) {
        if (!sApolloOriginalGIFEntries) sApolloOriginalGIFEntries = [NSMutableArray array];
        ApolloOriginalGIFPruneLocked(composer);
        [sApolloOriginalGIFEntries addObject:entry];
    }
    if (copyURL) {
        ApolloLog(@"[OriginalGIF] Kept picked GIF (%zu frames, %@ bytes) behind Apollo's %lu-byte still",
                  frameCount, size, (unsigned long)jpegData.length);
    } else {
        ApolloLog(@"[OriginalGIF] Noted a still pick (%lu-byte JPEG)", (unsigned long)jpegData.length);
    }
}

// The kept GIF for an upload of this JPEG, removed from the store; nil uploads
// Apollo's still.
//
// The JPEG is the only thing the upload carries back, and two picks can make the
// same one: GIFs that share a first frame, or a still of that frame. Apollo
// prepares every photo of a pick before uploading any of them (the picker's
// completion counter, FUN_1001ce750, starts the uploads once all are done), but
// it prepares them in parallel, so the order they reach the store isn't the
// order they upload in. So a JPEG matched by picks with different content is
// ambiguous: that upload and every later one for the same JPEG in this composer
// get Apollo's still instead of a guess. Picks of the same GIF are
// interchangeable and keep their animation.
static ApolloOriginalGIFEntry *ApolloOriginalGIFTakeEntryForDigest(NSData *digest) {
    if (!digest) return nil;
    id composer = ApolloActiveCommentComposer();
    if (!composer) return nil;
    @synchronized([ApolloOriginalGIFEntry class]) {
        ApolloOriginalGIFPruneLocked(composer);
        NSIndexSet *matches = [sApolloOriginalGIFEntries indexesOfObjectsPassingTest:^BOOL(ApolloOriginalGIFEntry *entry, __unused NSUInteger idx, __unused BOOL *stop) {
            return entry.composer == composer && [entry.jpegDigest isEqualToData:digest];
        }];
        if (matches.count == 0) return nil;

        __block BOOL ambiguous = NO;
        __block NSData *firstGIFDigest = nil;
        [[sApolloOriginalGIFEntries objectsAtIndexes:matches] enumerateObjectsUsingBlock:^(ApolloOriginalGIFEntry *entry, __unused NSUInteger idx, __unused BOOL *stop) {
            if (entry.ambiguous || !entry.gifDigest) {
                ambiguous = YES;
            } else if (!firstGIFDigest) {
                firstGIFDigest = entry.gifDigest;
            } else if (![firstGIFDigest isEqualToData:entry.gifDigest]) {
                ambiguous = YES;
            }
        }];

        // Hold it strongly before the array lets go.
        ApolloOriginalGIFEntry *entry = sApolloOriginalGIFEntries[matches.firstIndex];
        [sApolloOriginalGIFEntries removeObjectAtIndex:matches.firstIndex];
        if (!ambiguous) return entry;

        // Every pick still waiting on this JPEG uploads as a still too, even once
        // only one is left: it may be the other pick's upload that's next.
        for (ApolloOriginalGIFEntry *other in sApolloOriginalGIFEntries) {
            if (other.composer == composer && [other.jpegDigest isEqualToData:digest]) other.ambiguous = YES;
        }
        if (entry.gifFileURL) [[NSFileManager defaultManager] removeItemAtURL:entry.gifFileURL error:nil];
        if (matches.count > 1 || entry.ambiguous) {
            ApolloLog(@"[OriginalGIF] Picks in this composer made the same still from different images (%lu still waiting); uploading Apollo's still",
                      (unsigned long)(matches.count - 1));
        }
        return nil;
    }
}

static BOOL ApolloOriginalGIFHasEntries(void) {
    @synchronized([ApolloOriginalGIFEntry class]) {
        return sApolloOriginalGIFEntries.count > 0;
    }
}

NSData *ApolloUploadOriginalGIFDataForBody(NSData *body) {
    if (body.length == 0 || !ApolloOriginalGIFHasEntries() || ApolloUploadDataIsGIF(body)) return nil;
    ApolloOriginalGIFEntry *entry = ApolloOriginalGIFTakeEntryForDigest(ApolloOriginalGIFDigest(body));
    if (!entry) return nil;
    NSData *gif = [NSData dataWithContentsOfURL:entry.gifFileURL];
    [[NSFileManager defaultManager] removeItemAtURL:entry.gifFileURL error:nil];
    return ApolloUploadDataIsGIF(gif) ? gif : nil;
}

NSURL *ApolloUploadOriginalGIFFileForBodyFile(NSURL *fileURL) {
    if (!fileURL.isFileURL || !ApolloOriginalGIFHasEntries()) return nil;
    NSNumber *size = nil;
    [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > kApolloOriginalGIFMaxBytes) return nil;
    NSData *body = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:nil];
    if (ApolloUploadDataIsGIF(body)) return nil;
    // The file has to outlive the upload task, so the caller owns it from here and
    // releases it when the upload finishes (ApolloUploadOriginalGIFReleaseFile).
    // Only a task that is never resumed leaves it for the next launch's cleanup.
    ApolloOriginalGIFEntry *entry = ApolloOriginalGIFTakeEntryForDigest(ApolloOriginalGIFDigest(body));
    if (!entry || ![[NSFileManager defaultManager] fileExistsAtPath:entry.gifFileURL.path]) return nil;
    return entry.gifFileURL;
}

void ApolloUploadOriginalGIFReleaseFile(NSURL *gifFile) {
    if (!gifFile.isFileURL) return;
    NSString *folder = ApolloOriginalGIFDirectory().URLByStandardizingPath.path;
    NSString *parent = gifFile.URLByStandardizingPath.URLByDeletingLastPathComponent.path;
    if (![parent isEqualToString:folder]) return;   // never delete anything the store didn't create
    [[NSFileManager defaultManager] removeItemAtURL:gifFile error:nil];
}

#pragma mark - Rebound ImageIO calls (Apollo's image only)

static CGImageSourceRef (*orig_CGImageSourceCreateWithURL)(CFURLRef, CFDictionaryRef) = NULL;
static CGImageDestinationRef (*orig_CGImageDestinationCreateWithData)(CFMutableDataRef, CFStringRef, size_t, CFDictionaryRef) = NULL;
static bool (*orig_CGImageDestinationFinalize)(CGImageDestinationRef) = NULL;

// Start of a pass: a picked file opened for upload prep (Apollo's three photo
// pickers are the only callers in its image). Every pass starts a capture, which
// clears a stale one on this thread; only an animated GIF carries its file.
static CGImageSourceRef hooked_CGImageSourceCreateWithURL(CFURLRef url, CFDictionaryRef options) {
    CGImageSourceRef source = orig_CGImageSourceCreateWithURL(url, options);
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    [threadState removeObjectForKey:kApolloOriginalGIFCaptureKey];
    if (!source || !url) return source;

    ApolloOriginalGIFCapture *capture = [ApolloOriginalGIFCapture new];
    CFStringRef type = CGImageSourceGetType(source);
    if (type && CFEqual(type, CFSTR("com.compuserve.gif"))) {
        size_t frames = CGImageSourceGetCount(source);
        if (frames >= 2) {   // a single-frame GIF loses nothing as a JPEG
            capture.gifURL = (__bridge NSURL *)url;
            capture.frameCount = frames;
        }
    }
    threadState[kApolloOriginalGIFCaptureKey] = capture;
    return source;
}

// Apollo's one-image JPEG destination for that pass. Every Apollo call site of
// this function opens its source with CGImageSourceCreateWithURL first (which
// resets the capture), so a capture left behind by an aborted pass can't attach
// to an unrelated destination.
static CGImageDestinationRef hooked_CGImageDestinationCreateWithData(CFMutableDataRef data, CFStringRef type, size_t count, CFDictionaryRef options) {
    CGImageDestinationRef destination = orig_CGImageDestinationCreateWithData(data, type, count, options);
    ApolloOriginalGIFCapture *capture = NSThread.currentThread.threadDictionary[kApolloOriginalGIFCaptureKey];
    if (capture && destination && data && count == 1 && type && CFEqual(type, CFSTR("public.jpeg"))) {
        capture.destination = destination;
        capture.destinationData = (__bridge NSMutableData *)data;
    }
    return destination;
}

static bool hooked_CGImageDestinationFinalize(CGImageDestinationRef destination) {
    bool finalized = orig_CGImageDestinationFinalize(destination);
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    ApolloOriginalGIFCapture *capture = threadState[kApolloOriginalGIFCaptureKey];
    if (capture && capture.destination == destination) {
        [threadState removeObjectForKey:kApolloOriginalGIFCaptureKey];
        if (finalized && capture.destinationData.length > 0) {
            ApolloOriginalGIFRemember([capture.destinationData copy], capture.gifURL, capture.frameCount);
        }
    }
    return finalized;
}

// END_ORIGINAL_GIF_STORE

void ApolloUploadOriginalGIFInstallRebindings(const struct mach_header *header, intptr_t slide) {
    if (!header) return;
    // Copies left in tmp by earlier launches can't match anything now.
    NSString *currentFolder = ApolloOriginalGIFDirectory().lastPathComponent;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *root = ApolloOriginalGIFRootDirectory();
        for (NSURL *folder in [fileManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![folder.lastPathComponent isEqualToString:currentFolder]) [fileManager removeItemAtURL:folder error:nil];
        }
    });
    rebind_symbols_image((void *)header, slide, (struct rebinding[3]){
        {"CGImageSourceCreateWithURL", (void *)hooked_CGImageSourceCreateWithURL, (void **)&orig_CGImageSourceCreateWithURL},
        {"CGImageDestinationCreateWithData", (void *)hooked_CGImageDestinationCreateWithData, (void **)&orig_CGImageDestinationCreateWithData},
        {"CGImageDestinationFinalize", (void *)hooked_CGImageDestinationFinalize, (void **)&orig_CGImageDestinationFinalize},
    }, 3);
    ApolloLog(@"[OriginalGIF] hook installed (camera-roll GIFs upload animated)");
}
