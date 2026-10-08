// ApolloRedgifsMissingDuration.m — see ApolloRedgifsMissingDuration.h.

#import "ApolloRedgifsMissingDuration.h"
#import "ApolloCommon.h"
#import <libkern/OSByteOrder.h>
#import <math.h>
#import <stdio.h>
#import <string.h>

// Filled in when the video's header can't be read. Apollo's duration formatter
// (0x1007da9c0) shows anything below 0 or from 1,000,000 s up as "-:--", its
// placeholder for a length it can't show; a large positive value gets there
// without handing any other reader a negative length.
static const double kApolloRedgifsUnknownDuration = 1000000.0;

// The first read covers ftyp + moov when the file keeps moov up front (moov was
// 16-44 KB in the files checked); when moov follows the media data, the second
// read only needs moov's header and its first child, mvhd.
static const NSUInteger kApolloRedgifsHeadReadLength = 64 * 1024;
static const NSUInteger kApolloRedgifsMoovReadLength = 16 * 1024;
// Apollo shows the post only after this completes, so a stalled media host
// must not hold it for the default 60 s.
static const NSTimeInterval kApolloRedgifsHeaderReadTimeout = 8.0;
// Larger than any real mp4 box; guards the offset arithmetic below.
static const uint64_t kApolloRedgifsMaxBoxSize = 1ULL << 40;

// `seconds` is 0 when no length was read. `settled` is YES when a retry would
// get the same answer (a length, or a file whose header has none readable) and
// NO when the read itself failed (network, HTTP status), which a later lookup
// should try again.
typedef void (^ApolloRedgifsSecondsCompletion)(double seconds, BOOL settled, NSString *detail);

// Settled answers by video URL: the length, or kApolloRedgifsUnknownDuration for
// a header with none. Apollo looks the same gif up over and over (compact
// thumbnails re-fetch it on every pass: about 30 lookups per gif in two minutes
// of scrolling in the simulator), and each lookup would read the header again.
static NSCache<NSString *, NSNumber *> *ApolloRedgifsKnownLengths(void) {
    static NSCache<NSString *, NSNumber *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
    });
    return cache;
}

#pragma mark - mp4 header

// Seconds from the mvhd box among the children of a moov box. `offset` is the
// first child; `end` is the end of the moov box, clipped to the bytes read.
static double ApolloRedgifsMovieSeconds(const uint8_t *bytes, uint64_t offset, uint64_t end) {
    while (offset + 8 <= end) {
        uint64_t size = OSReadBigInt32(bytes, offset);
        uint64_t headerLength = 8;
        if (size == 1) {
            if (offset + 16 > end) return 0;
            size = OSReadBigInt64(bytes, offset + 8);
            headerLength = 16;
        }
        if (memcmp(bytes + offset + 4, "mvhd", 4) == 0) {
            // version (1 byte) + flags (3), then creation and modification
            // times, timescale and duration: 32-bit times and duration in
            // version 0, 64-bit in version 1.
            uint64_t p = offset + headerLength;
            if (p + 4 > end) return 0;
            uint64_t timescale = 0, duration = 0;
            if (bytes[p] == 1) {
                if (p + 32 > end) return 0;
                timescale = OSReadBigInt32(bytes, p + 20);
                duration = OSReadBigInt64(bytes, p + 24);
                if (duration == UINT64_MAX) return 0;
            } else if (bytes[p] == 0) {
                if (p + 20 > end) return 0;
                timescale = OSReadBigInt32(bytes, p + 12);
                duration = OSReadBigInt32(bytes, p + 16);
                if (duration == UINT32_MAX) return 0;
            } else {
                return 0;
            }
            if (timescale == 0 || duration == 0) return 0;
            double seconds = (double)duration / (double)timescale;
            return (isfinite(seconds) && seconds < kApolloRedgifsUnknownDuration) ? seconds : 0;
        }
        if (size < headerLength || size > end - offset) return 0;
        offset += size;
    }
    return 0;
}

typedef struct {
    double seconds;          // > 0 once mvhd was read
    uint64_t nextBoxOffset;  // file offset of a box that starts past the bytes read, else 0
    BOOL isMP4;              // the bytes read as mp4 boxes (from the file start: ftyp first)
} ApolloRedgifsMP4Scan;

// Walks the top-level boxes of mp4 bytes that start at file offset `start`,
// looking for moov/mvhd. Bytes from the start of the file must open with ftyp,
// so an error page or anything else that isn't an mp4 is never read as one.
static ApolloRedgifsMP4Scan ApolloRedgifsScanMP4(NSData *data, uint64_t start) {
    ApolloRedgifsMP4Scan scan = {0, 0, NO};
    const uint8_t *bytes = data.bytes;
    uint64_t length = data.length;
    uint64_t offset = 0;
    while (offset + 8 <= length) {
        uint64_t size = OSReadBigInt32(bytes, offset);
        uint64_t headerLength = 8;
        if (size == 1) {
            if (offset + 16 > length) break;
            size = OSReadBigInt64(bytes, offset + 8);
            headerLength = 16;
        }
        const uint8_t *type = bytes + offset + 4;
        if (start == 0 && offset == 0 && memcmp(type, "ftyp", 4) != 0) return scan;
        scan.isMP4 = YES;
        // 0 = the box runs to the end of the file, so there's nothing after it.
        if (size < headerLength || size > kApolloRedgifsMaxBoxSize) return scan;
        if (memcmp(type, "moov", 4) == 0) {
            scan.seconds = ApolloRedgifsMovieSeconds(bytes, offset + headerLength, MIN(offset + size, length));
            return scan;
        }
        offset += size;
    }
    // Ran out of bytes before moov: typically mdat first, moov at the end.
    if (offset > 0) scan.nextBoxOffset = start + offset;
    return scan;
}

// File offset of the first byte in a ranged response: the Content-Range start
// for 206, 0 when the server ignored the range and sent the whole file.
static BOOL ApolloRedgifsResponseStart(NSHTTPURLResponse *response, uint64_t *start) {
    if (response.statusCode == 200) {
        *start = 0;
        return YES;
    }
    if (response.statusCode != 206) return NO;
    NSString *range = [response valueForHTTPHeaderField:@"Content-Range"];
    unsigned long long value = 0;
    if (range.length == 0 || sscanf(range.UTF8String, "bytes %llu-", &value) != 1) return NO;
    *start = value;
    return YES;
}

// Reads the length of the mp4 at `videoURL` from its header: `length` bytes
// from `start`, then (once, when `mayFollow`) the moov box that the first read
// found starting past its bytes. `done` runs once, on the factory session's
// delegate queue.
static void ApolloRedgifsReadVideoSeconds(NSURL *videoURL,
                                          uint64_t start,
                                          NSUInteger length,
                                          BOOL mayFollow,
                                          ApolloRedgifsLookupTaskFactory factory,
                                          ApolloRedgifsSecondsCompletion done) {
    NSMutableURLRequest *read = [NSMutableURLRequest requestWithURL:videoURL
                                                        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                    timeoutInterval:kApolloRedgifsHeaderReadTimeout];
    [read setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", start, start + length - 1]
        forHTTPHeaderField:@"Range"];

    NSURLSessionDataTask *task = factory(read, ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        uint64_t dataStart = 0;
        if (error || !http || data.length == 0 || !ApolloRedgifsResponseStart(http, &dataStart)) {
            done(0, NO, [NSString stringWithFormat:@"header read failed: HTTP %ld, error %ld",
                         (long)http.statusCode, (long)error.code]);
            return;
        }
        ApolloRedgifsMP4Scan scan = ApolloRedgifsScanMP4(data, dataStart);
        if (scan.seconds > 0) {
            done(scan.seconds, YES, dataStart == 0 ? @"moov at the start of the file" : @"moov after the media data");
            return;
        }
        if (mayFollow && scan.nextBoxOffset > dataStart) {
            ApolloRedgifsReadVideoSeconds(videoURL, scan.nextBoxOffset, kApolloRedgifsMoovReadLength, NO, factory, done);
            return;
        }
        // Only an mp4 without a readable mvhd is settled; anything else (a
        // captive portal's page, say) is a failed read.
        done(0, scan.isMP4, scan.isMP4 ? @"no readable mvhd box" : @"the response is not an mp4");
    });
    if (!task) {
        done(0, NO, @"could not create the header read");
        return;
    }
    [task resume];
}

#pragma mark - gif record

// The response's "gif" object when RedGIFs left its duration out (null or
// absent); nil for errors and for records Apollo already decodes. `root`
// receives the whole (mutable) response for re-serializing.
static NSMutableDictionary *ApolloRedgifsGifMissingDuration(NSData *data,
                                                           NSURLResponse *response,
                                                           NSError *error,
                                                           NSMutableDictionary **root) {
    if (error || data.length == 0) return nil;
    if (![response isKindOfClass:[NSHTTPURLResponse class]] || ((NSHTTPURLResponse *)response).statusCode != 200) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *gif = json[@"gif"];
    if (![gif isKindOfClass:[NSDictionary class]]) return nil;
    id duration = gif[@"duration"];
    if (duration && ![duration isKindOfClass:[NSNull class]]) return nil;
    *root = json;
    return gif;
}

static NSURL *ApolloRedgifsMP4URL(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSURL *url = [NSURL URLWithString:value];
    if (url.host.length == 0) return nil;
    return [url.pathExtension.lowercaseString isEqualToString:@"mp4"] ? url : nil;
}

// The mp4 to read the length from: urls.sd, the smaller mobile rendition
// (every null-duration video checked had one that loads; urls.hd was gone for
// 9 of 44), else urls.hd. nil unless urls.hd is an mp4: image records (type 2)
// carry .jpg renditions instead.
static NSURL *ApolloRedgifsVideoURL(NSDictionary *gif) {
    NSDictionary *urls = gif[@"urls"];
    if (![urls isKindOfClass:[NSDictionary class]]) return nil;
    NSURL *hd = ApolloRedgifsMP4URL(urls[@"hd"]);
    if (!hd) return nil;
    return ApolloRedgifsMP4URL(urls[@"sd"]) ?: hd;
}

#pragma mark - Entry point

ApolloRedgifsLookupCompletion ApolloRedgifsCompletionFillingMissingDuration(NSURLSession *session,
                                                                           NSURLRequest *request,
                                                                           ApolloRedgifsLookupCompletion completion,
                                                                           ApolloRedgifsLookupTaskFactory factory) {
    if (!completion || !factory) return completion;
    NSURL *url = request.URL;
    if (![url.host isEqualToString:@"api.redgifs.com"]) return completion;
    // "/", "v2", "gifs", "<id>": a single gif, not /v2/gifs/search and friends.
    NSArray<NSString *> *parts = url.pathComponents;
    if (parts.count != 4 || ![parts[1] isEqualToString:@"v2"] || ![parts[2] isEqualToString:@"gifs"]) return completion;
    // ApolloHostedVideo (Share as Video, Share as Image, Gallery View) looks
    // gifs up on the shared session and never reads the duration.
    if (session == [NSURLSession sharedSession]) return completion;

    return ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableDictionary *root = nil;
        NSMutableDictionary *gif = ApolloRedgifsGifMissingDuration(data, response, error, &root);
        if (!gif) {
            completion(data, response, error);
            return;
        }
        NSURL *videoURL = ApolloRedgifsVideoURL(gif);
        if (!videoURL) {
            ApolloLog(@"[RedgifsDuration] RedGIFs record without a duration is not a video (urls.hd isn't an mp4, e.g. an image); leaving it to Apollo's error card");
            completion(data, response, error);
            return;
        }

        void (^fillIn)(double) = ^(double seconds) {
            gif[@"duration"] = @(seconds);
            NSData *repaired = [NSJSONSerialization dataWithJSONObject:root
                                                               options:NSJSONWritingWithoutEscapingSlashes
                                                                 error:nil];
            completion(repaired.length > 0 ? repaired : data, response, error);
        };

        NSString *cacheKey = videoURL.absoluteString;
        NSNumber *known = [ApolloRedgifsKnownLengths() objectForKey:cacheKey];
        if (known) {
            os_log_debug(ApolloFixLog(), "[ApolloFix] [RedgifsDuration] Filled in %.3f s read earlier for this video", known.doubleValue);
            fillIn(known.doubleValue);
            return;
        }

        ApolloLog(@"[RedgifsDuration] RedGIFs sent a video without a duration; reading its length from the video header");
        ApolloRedgifsReadVideoSeconds(videoURL, 0, kApolloRedgifsHeadReadLength, YES, factory, ^(double seconds, BOOL settled, NSString *detail) {
            double filled = seconds > 0 ? seconds : kApolloRedgifsUnknownDuration;
            if (settled) [ApolloRedgifsKnownLengths() setObject:@(filled) forKey:cacheKey];
            if (seconds > 0) {
                ApolloLog(@"[RedgifsDuration] Filled in %.3f s from the video header (%@)", seconds, detail);
            } else {
                ApolloLog(@"[RedgifsDuration] Could not read the video length (%@); filled in the unknown-length placeholder%@",
                          detail, settled ? @"" : @", will retry on the next lookup");
            }
            fillIn(filled);
        });
    };
}

__attribute__((constructor)) static void ApolloRedgifsMissingDurationInit(void) {
    ApolloLog(@"[RedgifsDuration] ctor: missing-duration repair armed (runs from the NSURLSession hook in Tweak.xm)");
}
