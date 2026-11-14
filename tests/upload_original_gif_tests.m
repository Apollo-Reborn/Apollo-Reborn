// Host tests for the camera-roll GIF store (src/ApolloUploadOriginalGIF.m, #1663).
// run_upload_original_gif_tests.sh pastes the production store and the ImageIO
// capture hooks in below and points the hooks' "original" functions at the real
// ImageIO calls, so each pick runs through the same chain Apollo's picker
// completion (FUN_1001ce9b4) uses.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#import "ApolloUploadOriginalGIF.h"

static NSMutableArray<NSString *> *sLogLines;
#define ApolloLog(...) [sLogLines addObject:[NSString stringWithFormat:__VA_ARGS__]]

// The composer an upload comes from (ApolloMarkdownToolbarGif.xm in the app).
static id sTestComposer = nil;
static id ApolloActiveCommentComposer(void) { return sTestComposer; }

// INSERT_PRODUCTION_STORE

static int sFailures = 0;
static int sChecks = 0;
#define CHECK(cond, ...) do { sChecks++; if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); } } while (0)

static NSURL *sWorkDirectory;

static CGImageRef SolidImage(uint32_t rgb) {
    const size_t side = 48;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, side * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(context, ((rgb >> 16) & 0xff) / 255.0, ((rgb >> 8) & 0xff) / 255.0, (rgb & 0xff) / 255.0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, side, side));
    // A corner mark so the frame isn't a single flat color.
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 8, 8));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return image;
}

// An animated GIF with one frame per color.
static NSData *GIFWithFrames(NSArray<NSNumber *> *colors) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("com.compuserve.gif"), colors.count, NULL);
    NSDictionary *frameProperties = @{ (__bridge NSString *)kCGImagePropertyGIFDictionary: @{ (__bridge NSString *)kCGImagePropertyGIFDelayTime: @0.1 } };
    for (NSNumber *color in colors) {
        CGImageRef image = SolidImage(color.unsignedIntValue);
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)frameProperties);
        CGImageRelease(image);
    }
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return data;
}

static NSData *PNGOfColor(uint32_t rgb) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    CGImageRef image = SolidImage(rgb);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageRelease(image);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return data;
}

// The item provider's temporary copy of a pick.
static NSURL *PickedFile(NSData *data, NSString *extension) {
    NSURL *url = [sWorkDirectory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension]];
    [data writeToURL:url atomically:YES];
    return url;
}

// Apollo's prep for one pick (FUN_1001ce9b4): open the file, take a thumbnail of
// image 0 (max 2000 px), write a one-image JPEG. The item provider deletes its
// file once the completion returns, so the copy must already be kept by then.
static NSData *ApolloPrep(NSURL *pickedURL) {
    CGImageSourceRef source = hooked_CGImageSourceCreateWithURL((__bridge CFURLRef)pickedURL, NULL);
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @2000,
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    NSMutableData *jpeg = [NSMutableData data];
    CGImageDestinationRef destination = hooked_CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
    CGImageDestinationAddImage(destination, thumbnail, (__bridge CFDictionaryRef)@{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.75 });
    hooked_CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(thumbnail);
    CFRelease(source);
    [[NSFileManager defaultManager] removeItemAtURL:pickedURL error:nil];
    return [jpeg copy];
}

static NSUInteger KeptFileCount(void) {
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:ApolloOriginalGIFDirectory().path error:nil].count;
}

static NSUInteger EntryCount(void) {
    @synchronized([ApolloOriginalGIFEntry class]) { return sApolloOriginalGIFEntries.count; }
}

static void ResetStore(void) {
    @synchronized([ApolloOriginalGIFEntry class]) {
        for (ApolloOriginalGIFEntry *entry in sApolloOriginalGIFEntries) {
            if (entry.gifFileURL) [[NSFileManager defaultManager] removeItemAtURL:entry.gifFileURL error:nil];
        }
        [sApolloOriginalGIFEntries removeAllObjects];
    }
    [sLogLines removeAllObjects];
}

static BOOL LogContains(NSString *needle) {
    for (NSString *line in sLogLines) if ([line containsString:needle]) return YES;
    return NO;
}

int main(void) {
    @autoreleasepool {
        sLogLines = [NSMutableArray array];
        orig_CGImageSourceCreateWithURL = CGImageSourceCreateWithURL;
        orig_CGImageDestinationCreateWithData = CGImageDestinationCreateWithData;
        orig_CGImageDestinationFinalize = CGImageDestinationFinalize;
        sWorkDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:sWorkDirectory withIntermediateDirectories:YES attributes:nil error:nil];

        const uint32_t red = 0xd02020, green = 0x20b040, blue = 0x2040d0, yellow = 0xe0c020;
        // A and B: different animations with the same first frame.
        NSData *gifA = GIFWithFrames(@[@(red), @(green)]);
        NSData *gifB = GIFWithFrames(@[@(red), @(blue)]);
        NSData *gifC = GIFWithFrames(@[@(yellow), @(green)]);
        CHECK(![gifA isEqualToData:gifB], @"fixture: A and B must differ");

        sTestComposer = [NSObject new];

        // Precondition for the rest: A's and B's JPEGs are byte-identical, so the
        // JPEG alone can't say which pick an upload is.
        NSData *jpegA = ApolloPrep(PickedFile(gifA, @"gif"));
        NSData *jpegB = ApolloPrep(PickedFile(gifB, @"gif"));
        CHECK(jpegA.length > 0 && [jpegA isEqualToData:jpegB], @"fixture: A and B must make the same JPEG (%lu vs %lu bytes)", (unsigned long)jpegA.length, (unsigned long)jpegB.length);
        ResetStore();

        // 1. One GIF: the upload gets that GIF, once.
        {
            NSData *jpeg = ApolloPrep(PickedFile(gifA, @"gif"));
            CHECK(KeptFileCount() == 1, @"single: one kept file, got %lu", (unsigned long)KeptFileCount());
            NSData *upload = ApolloUploadOriginalGIFDataForBody(jpeg);
            CHECK([upload isEqualToData:gifA], @"single: upload should be A's GIF");
            CHECK(ApolloUploadOriginalGIFDataForBody(jpeg) == nil, @"single: a second upload of the same still must not get a GIF");
            CHECK(KeptFileCount() == 0 && EntryCount() == 0, @"single: store and folder empty after the upload");
        }

        // 2. Two different GIFs with the same first frame, uploaded out of pick
        //    order (B's upload looked up first). Neither may get the other's GIF:
        //    both upload Apollo's still, and nothing is left behind.
        {
            ResetStore();
            NSData *jA = ApolloPrep(PickedFile(gifA, @"gif"));
            NSData *jB = ApolloPrep(PickedFile(gifB, @"gif"));
            CHECK(EntryCount() == 2 && KeptFileCount() == 2, @"pair: two kept picks");
            NSData *first = ApolloUploadOriginalGIFDataForBody(jB);
            CHECK(first == nil, @"pair: B's upload (first) got %@ instead of the still", [first isEqualToData:gifA] ? @"A's GIF" : @"a GIF");
            NSData *second = ApolloUploadOriginalGIFDataForBody(jA);
            CHECK(second == nil, @"pair: A's upload (second) got %@ instead of the still", [second isEqualToData:gifB] ? @"B's GIF" : @"a GIF");
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"pair: store and folder empty after both uploads");
            CHECK(LogContains(@"made the same still from different images"), @"pair: logs why it kept the still");
        }

        // 2b. Same, prepared in the other order (Apollo prepares a pick's photos in
        //     parallel), uploaded A first.
        {
            ResetStore();
            NSData *jB = ApolloPrep(PickedFile(gifB, @"gif"));
            NSData *jA = ApolloPrep(PickedFile(gifA, @"gif"));
            CHECK(ApolloUploadOriginalGIFDataForBody(jA) == nil, @"pair reversed: A's upload must be the still");
            CHECK(ApolloUploadOriginalGIFDataForBody(jB) == nil, @"pair reversed: B's upload must be the still");
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"pair reversed: nothing left behind");
        }

        // 3. The same GIF picked twice: either copy is right, both stay animated.
        {
            ResetStore();
            NSData *j1 = ApolloPrep(PickedFile(gifA, @"gif"));
            NSData *j2 = ApolloPrep(PickedFile(gifA, @"gif"));
            CHECK([ApolloUploadOriginalGIFDataForBody(j2) isEqualToData:gifA], @"same GIF twice: first upload animated");
            CHECK([ApolloUploadOriginalGIFDataForBody(j1) isEqualToData:gifA], @"same GIF twice: second upload animated");
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"same GIF twice: nothing left behind");
        }

        // 4. Different first frames: the JPEGs tell the picks apart, so uploads
        //    in any order get their own GIF.
        {
            ResetStore();
            NSData *jA = ApolloPrep(PickedFile(gifA, @"gif"));
            NSData *jC = ApolloPrep(PickedFile(gifC, @"gif"));
            CHECK(![jA isEqualToData:jC], @"fixture: A and C make different JPEGs");
            CHECK([ApolloUploadOriginalGIFDataForBody(jC) isEqualToData:gifC], @"distinct: C's upload gets C");
            CHECK([ApolloUploadOriginalGIFDataForBody(jA) isEqualToData:gifA], @"distinct: A's upload gets A");
        }

        // 5. A still whose JPEG matches a kept GIF's can't claim the GIF.
        {
            ResetStore();
            NSData *jA = ApolloPrep(PickedFile(gifA, @"gif"));
            ApolloOriginalGIFRemember(jA, nil, 0);   // a still pick that made the same JPEG
            CHECK(ApolloUploadOriginalGIFDataForBody(jA) == nil, @"still match: first upload must be the still");
            CHECK(ApolloUploadOriginalGIFDataForBody(jA) == nil, @"still match: second upload must be the still");
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"still match: nothing left behind");
        }

        // 5b. A plain still pick goes through the chain, keeps no file, and its
        //     upload consumes its entry.
        {
            ResetStore();
            NSData *jpeg = ApolloPrep(PickedFile(PNGOfColor(blue), @"png"));
            CHECK(EntryCount() == 1 && KeptFileCount() == 0, @"still: one entry, no kept file");
            CHECK(ApolloUploadOriginalGIFDataForBody(jpeg) == nil, @"still: upload stays the still");
            CHECK(EntryCount() == 0, @"still: entry consumed by its upload");
        }

        // 5c. The still filed before the GIF: still no guess, for either upload.
        {
            ResetStore();
            NSData *jA = jpegA;
            ApolloOriginalGIFRemember(jA, nil, 0);
            ApolloPrep(PickedFile(gifA, @"gif"));
            CHECK(ApolloUploadOriginalGIFDataForBody(jA) == nil, @"still first: first upload must be the still");
            CHECK(ApolloUploadOriginalGIFDataForBody(jA) == nil, @"still first: second upload must be the still");
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"still first: nothing left behind");
        }

        // 6. Draft discarded before its upload ran: the next composer's pick with
        //    the same first frame gets its own GIF, and the old copy is deleted.
        {
            ResetStore();
            @autoreleasepool {
                sTestComposer = [NSObject new];
                ApolloPrep(PickedFile(gifA, @"gif"));
                CHECK(KeptFileCount() == 1, @"discarded: A kept");
                sTestComposer = [NSObject new];   // the first composer closes, a new reply opens
            }
            NSData *jB = ApolloPrep(PickedFile(gifB, @"gif"));
            CHECK(KeptFileCount() == 1, @"discarded: A's copy deleted when B was picked, got %lu files", (unsigned long)KeptFileCount());
            CHECK([ApolloUploadOriginalGIFDataForBody(jB) isEqualToData:gifB], @"discarded: B's upload gets B, not A");
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"discarded: nothing left behind");
            CHECK(LogContains(@"no longer open"), @"discarded: logs the dropped pick");
        }

        // 6b. The composer is gone and the next one uploads a still of that frame:
        //     the old GIF can't be matched from the new composer.
        {
            ResetStore();
            NSData *jA = nil;
            @autoreleasepool {
                sTestComposer = [NSObject new];
                jA = ApolloPrep(PickedFile(gifA, @"gif"));
                sTestComposer = nil;   // closed; nothing else open
            }
            CHECK(ApolloUploadOriginalGIFDataForBody(jA) == nil, @"closed: no composer, no GIF");
            sTestComposer = [NSObject new];
            CHECK(ApolloUploadOriginalGIFDataForBody(jA) == nil, @"closed: a new composer's upload of that still gets no GIF");
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"closed: the dead composer's pick was dropped");
        }

        // 6c. The earlier composer is still alive (kept around after it closed)
        //     when a new one opens: its pick is dropped all the same.
        {
            ResetStore();
            id earlierComposer = [NSObject new];
            sTestComposer = earlierComposer;
            ApolloPrep(PickedFile(gifA, @"gif"));
            sTestComposer = [NSObject new];
            NSData *jB = ApolloPrep(PickedFile(gifB, @"gif"));
            CHECK(KeptFileCount() == 1, @"earlier composer alive: A's copy deleted when B was picked, got %lu files", (unsigned long)KeptFileCount());
            CHECK([ApolloUploadOriginalGIFDataForBody(jB) isEqualToData:gifB], @"earlier composer alive: B's upload gets B");
            sTestComposer = earlierComposer;   // even back in the earlier composer, A is gone
            CHECK(ApolloUploadOriginalGIFDataForBody(jpegA) == nil, @"earlier composer alive: A was dropped");
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"earlier composer alive: nothing left behind");
            sTestComposer = [NSObject new];
        }

        // 7. Same composer, a GIF whose upload never ran, then a different GIF with
        //    the same first frame: the new upload can't be tied to one pick, so it
        //    keeps the still rather than risk A's GIF.
        {
            ResetStore();
            ApolloPrep(PickedFile(gifA, @"gif"));
            NSData *jB = ApolloPrep(PickedFile(gifB, @"gif"));
            CHECK(ApolloUploadOriginalGIFDataForBody(jB) == nil, @"leftover: B's upload is the still, never A's GIF");
        }

        // 8. An ambiguous JPEG is settled once its picks are uploaded: a later lone
        //    pick of that GIF in the same composer is animated again.
        {
            ResetStore();
            NSData *jA = ApolloPrep(PickedFile(gifA, @"gif"));
            ApolloPrep(PickedFile(gifB, @"gif"));
            ApolloUploadOriginalGIFDataForBody(jA);
            ApolloUploadOriginalGIFDataForBody(jA);
            NSData *again = ApolloPrep(PickedFile(gifA, @"gif"));
            CHECK([ApolloUploadOriginalGIFDataForBody(again) isEqualToData:gifA], @"after ambiguity: a lone pick is animated again");
        }

        // 9. File-backed uploads (uploadTaskWithRequest:fromFile:) follow the same rules.
        {
            ResetStore();
            NSData *jA = ApolloPrep(PickedFile(gifA, @"gif"));
            NSURL *body = PickedFile(jA, @"jpg");
            NSURL *gifFile = ApolloUploadOriginalGIFFileForBodyFile(body);
            CHECK(gifFile && [[NSData dataWithContentsOfURL:gifFile] isEqualToData:gifA], @"fromFile: single pick gets its GIF file");
            CHECK(EntryCount() == 0 && KeptFileCount() == 1, @"fromFile: the caller owns the file until it releases it");
            ApolloUploadOriginalGIFReleaseFile(gifFile);
            CHECK(KeptFileCount() == 0, @"fromFile: releasing deletes the kept copy");

            // The still-only branch releases straight away instead of uploading it.
            ResetStore();
            NSData *jStill = ApolloPrep(PickedFile(gifB, @"gif"));
            NSURL *unsent = ApolloUploadOriginalGIFFileForBodyFile(PickedFile(jStill, @"jpg"));
            CHECK(unsent != nil, @"fromFile still branch: a file was handed out");
            ApolloUploadOriginalGIFReleaseFile(unsent);
            CHECK(KeptFileCount() == 0 && EntryCount() == 0, @"fromFile still branch: nothing left behind");

            // Repeated file uploads in one launch leave the folder empty.
            for (NSUInteger round = 0; round < 5; round++) {
                ResetStore();
                NSData *jRound = ApolloPrep(PickedFile(round % 2 ? gifC : gifA, @"gif"));
                NSURL *roundFile = ApolloUploadOriginalGIFFileForBodyFile(PickedFile(jRound, @"jpg"));
                CHECK([[NSData dataWithContentsOfURL:roundFile] isEqualToData:(round % 2 ? gifC : gifA)], @"fromFile round %lu: gets its own GIF", (unsigned long)round);
                ApolloUploadOriginalGIFReleaseFile(roundFile);
            }
            CHECK(KeptFileCount() == 0 && EntryCount() == 0, @"fromFile: 5 uploads in one launch leave the folder empty");

            // Release never touches a file outside the store's folder.
            NSURL *outside = PickedFile(gifA, @"gif");
            ApolloUploadOriginalGIFReleaseFile(outside);
            CHECK([[NSFileManager defaultManager] fileExistsAtPath:outside.path], @"release ignores files the store didn't create");

            ResetStore();
            NSData *jPairA = ApolloPrep(PickedFile(gifA, @"gif"));
            ApolloPrep(PickedFile(gifB, @"gif"));
            NSURL *pairBody = PickedFile(jPairA, @"jpg");
            CHECK(ApolloUploadOriginalGIFFileForBodyFile(pairBody) == nil, @"fromFile: ambiguous pair, first upload is the still");
            CHECK(ApolloUploadOriginalGIFFileForBodyFile(pairBody) == nil, @"fromFile: ambiguous pair, second upload is the still");
            CHECK(KeptFileCount() == 0, @"fromFile: nothing left behind");
        }

        // 10. Outside a comment composer nothing is kept.
        {
            ResetStore();
            sTestComposer = nil;
            NSData *jA = ApolloPrep(PickedFile(gifA, @"gif"));
            CHECK(EntryCount() == 0 && KeptFileCount() == 0, @"no composer: nothing kept");
            CHECK(ApolloUploadOriginalGIFDataForBody(jA) == nil, @"no composer: upload is the still");
        }

        ResetStore();
        [[NSFileManager defaultManager] removeItemAtURL:sWorkDirectory error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:ApolloOriginalGIFDirectory() error:nil];
        printf("%d checks, %d failures\n", sChecks, sFailures);
        return sFailures == 0 ? 0 : 1;
    }
}
