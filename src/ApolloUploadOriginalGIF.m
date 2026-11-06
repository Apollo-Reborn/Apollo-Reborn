#import "ApolloUploadOriginalGIF.h"

#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

#import "ApolloCommon.h"
#import "ApolloMarkdownToolbarGif.h"
#import "fishhook.h"

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
@property (nonatomic, strong) NSURL *gifURL;
@property (nonatomic) size_t frameCount;
@property (nonatomic) const void *destination;
@property (nonatomic, strong) NSMutableData *destinationData;
@end

@implementation ApolloOriginalGIFCapture
@end

@interface ApolloOriginalGIFEntry : NSObject
@property (nonatomic, copy) NSData *jpegDigest;
@property (nonatomic, strong) NSURL *gifFileURL;
@property (nonatomic, strong) NSDate *createdAt;
@end

@implementation ApolloOriginalGIFEntry
@end

static NSMutableArray<ApolloOriginalGIFEntry *> *sApolloOriginalGIFEntries = nil;

static CGImageSourceRef (*orig_CGImageSourceCreateWithURL)(CFURLRef, CFDictionaryRef) = NULL;
static CGImageDestinationRef (*orig_CGImageDestinationCreateWithData)(CFMutableDataRef, CFStringRef, size_t, CFDictionaryRef) = NULL;
static bool (*orig_CGImageDestinationFinalize)(CGImageDestinationRef) = NULL;

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

// Caller holds the entries lock.
static void ApolloOriginalGIFPruneLocked(void) {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kApolloOriginalGIFLifetime];
    NSMutableIndexSet *stale = [NSMutableIndexSet indexSet];
    [sApolloOriginalGIFEntries enumerateObjectsUsingBlock:^(ApolloOriginalGIFEntry *entry, NSUInteger idx, __unused BOOL *stop) {
        if ([entry.createdAt compare:cutoff] == NSOrderedAscending) [stale addIndex:idx];
    }];
    NSUInteger live = sApolloOriginalGIFEntries.count - stale.count;
    for (NSUInteger idx = 0; idx < sApolloOriginalGIFEntries.count && live > kApolloOriginalGIFMaxEntries; idx++) {
        if ([stale containsIndex:idx]) continue;
        [stale addIndex:idx];   // oldest first
        live--;
    }
    [[sApolloOriginalGIFEntries objectsAtIndexes:stale] enumerateObjectsUsingBlock:^(ApolloOriginalGIFEntry *entry, __unused NSUInteger idx, __unused BOOL *stop) {
        [[NSFileManager defaultManager] removeItemAtURL:entry.gifFileURL error:nil];
    }];
    [sApolloOriginalGIFEntries removeObjectsAtIndexes:stale];
}

// Apollo's JPEG is final: copy the GIF out of the item provider's temporary file
// (deleted once its completion returns) and file it under the JPEG's digest.
static void ApolloOriginalGIFRemember(NSData *jpegData, NSURL *gifURL, size_t frameCount) {
    // Comments only: the post composer (galleries, video posters) and chat keep
    // Apollo's still for now.
    if (ApolloActiveCommentComposerSubreddit().length == 0) return;
    NSNumber *size = nil;
    [gifURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > kApolloOriginalGIFMaxBytes) {
        ApolloLog(@"[OriginalGIF] GIF is %@ bytes (limit %llu); uploading Apollo's still instead", size ?: @"?", kApolloOriginalGIFMaxBytes);
        return;
    }
    NSData *digest = ApolloOriginalGIFDigest(jpegData);
    if (!digest) return;

    NSURL *directory = ApolloOriginalGIFDirectory();
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *copyURL = [directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"gif"]];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtURL:gifURL toURL:copyURL error:&copyError]) {
        ApolloLog(@"[OriginalGIF] Could not keep the picked GIF (%@); uploading Apollo's still", copyError.localizedDescription ?: @"copy failed");
        return;
    }

    ApolloOriginalGIFEntry *entry = [ApolloOriginalGIFEntry new];
    entry.jpegDigest = digest;
    entry.gifFileURL = copyURL;
    entry.createdAt = [NSDate date];
    @synchronized([ApolloOriginalGIFEntry class]) {
        if (!sApolloOriginalGIFEntries) sApolloOriginalGIFEntries = [NSMutableArray array];
        [sApolloOriginalGIFEntries addObject:entry];
        ApolloOriginalGIFPruneLocked();
    }
    ApolloLog(@"[OriginalGIF] Kept picked GIF (%zu frames, %@ bytes) behind Apollo's %lu-byte still",
              frameCount, size, (unsigned long)jpegData.length);
}

// Removes and returns the oldest entry for this JPEG. Two GIFs with the same
// first frame produce the same JPEG; consuming in pick order gives each upload
// its own GIF instead of both getting the newest.
static ApolloOriginalGIFEntry *ApolloOriginalGIFTakeEntryForDigest(NSData *digest) {
    if (!digest) return nil;
    @synchronized([ApolloOriginalGIFEntry class]) {
        ApolloOriginalGIFPruneLocked();
        NSUInteger index = [sApolloOriginalGIFEntries indexOfObjectPassingTest:^BOOL(ApolloOriginalGIFEntry *entry, __unused NSUInteger idx, __unused BOOL *stop) {
            return [entry.jpegDigest isEqualToData:digest];
        }];
        if (index == NSNotFound) return nil;
        // Hold it strongly before the array lets go (a for-in variable isn't retained).
        ApolloOriginalGIFEntry *entry = sApolloOriginalGIFEntries[index];
        [sApolloOriginalGIFEntries removeObjectAtIndex:index];
        return entry;
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
    // The file has to outlive the upload task, so it stays in this launch's
    // folder (cleared on the next launch).
    ApolloOriginalGIFEntry *entry = ApolloOriginalGIFTakeEntryForDigest(ApolloOriginalGIFDigest(body));
    if (!entry || ![[NSFileManager defaultManager] fileExistsAtPath:entry.gifFileURL.path]) return nil;
    return entry.gifFileURL;
}

#pragma mark - Rebound ImageIO calls (Apollo's image only)

// Start of a pass: a picked file opened for upload prep (Apollo's three photo
// pickers are the only callers in its image). Only an animated GIF
// starts a capture; any other source clears a stale one on this thread.
static CGImageSourceRef hooked_CGImageSourceCreateWithURL(CFURLRef url, CFDictionaryRef options) {
    CGImageSourceRef source = orig_CGImageSourceCreateWithURL(url, options);
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    [threadState removeObjectForKey:kApolloOriginalGIFCaptureKey];
    if (!source || !url) return source;
    CFStringRef type = CGImageSourceGetType(source);
    if (!type || !CFEqual(type, CFSTR("com.compuserve.gif"))) return source;
    size_t frames = CGImageSourceGetCount(source);
    if (frames < 2) return source;   // a single-frame GIF loses nothing as a JPEG

    ApolloOriginalGIFCapture *capture = [ApolloOriginalGIFCapture new];
    capture.gifURL = (__bridge NSURL *)url;
    capture.frameCount = frames;
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
