#import <Foundation/Foundation.h>

#import "ApolloRedditVideoPlaylist.h"

// Host-side tests for ApolloRedditVideoPlaylist.m (v.redd.it master playlist
// recovery, issues #1698 #1714 #1716 #1720 #1721). Fixtures in
// tests/fixtures/reddit_video were captured from v.redd.it on 2026-11-15:
// cmaf_with_audio.mpd + cmaf_with_audio_master.m3u8 are the DASH manifest and
// the real HLS master of the same video (104411312s1i1, the #1721 post);
// cmaf_silent.mpd drops its audio set, legacy_dash_names.mpd renames one file
// to the pre-CMAF DASH_ scheme, s3_access_denied.xml is the 403 body.

static int sFailures = 0;
static NSString *sFixtures = nil;

static void Expect(BOOL condition, NSString *label) {
    if (!condition) {
        sFailures++;
        fprintf(stderr, "FAIL: %s\n", label.UTF8String);
    }
}

static NSData *Fixture(NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:[sFixtures stringByAppendingPathComponent:name]];
    if (!data) {
        fprintf(stderr, "missing fixture %s\n", name.UTF8String);
        exit(2);
    }
    return data;
}

static NSString *Text(NSData *data) {
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

// Lines of a master playlist, normalized for comparison: the STREAM-INF lines
// reduced to RESOLUTION + URI, the EXT-X-MEDIA lines to their URI.
static NSArray<NSString *> *Lines(NSString *playlist) {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [playlist componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length) [lines addObject:line];
    }
    return lines;
}

static NSSet<NSString *> *VariantURIs(NSString *playlist) {
    NSMutableSet *uris = [NSMutableSet set];
    for (NSString *line in Lines(playlist)) {
        if (![line hasPrefix:@"#"]) [uris addObject:line];
    }
    return uris;
}

static NSSet<NSString *> *AudioURIs(NSString *playlist) {
    NSMutableSet *uris = [NSMutableSet set];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^#EXT-X-MEDIA:URI=\"([^\"]+)\",TYPE=AUDIO"
                                                                        options:NSRegularExpressionAnchorsMatchLines error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:playlist options:0 range:NSMakeRange(0, playlist.length)]) {
        [uris addObject:[playlist substringWithRange:[m rangeAtIndex:1]]];
    }
    return uris;
}

static NSSet<NSString *> *Resolutions(NSString *playlist) {
    NSMutableSet *set = [NSMutableSet set];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"RESOLUTION=([0-9]+x[0-9]+)" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:playlist options:0 range:NSMakeRange(0, playlist.length)]) {
        [set addObject:[playlist substringWithRange:[m rangeAtIndex:1]]];
    }
    return set;
}

static void TestURLMatching(void) {
    NSString *signed1 = @"https://v.redd.it/104411312s1i1/HLSPlaylist.m3u8?a=1797375335%2CMjYw%3D%3D&v=1&f=sd";
    Expect([ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:signed1]) isEqualToString:@"104411312s1i1"], @"signed master URL");
    Expect([ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"https://v.redd.it/abcd1234/HLSPlaylist.m3u8"]) isEqualToString:@"abcd1234"], @"unsigned master URL");
    Expect([ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"https://V.REDD.IT/abcd1234/HLSPlaylist.m3u8"]) isEqualToString:@"abcd1234"], @"host is case-insensitive");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"http://v.redd.it/abcd1234/HLSPlaylist.m3u8"]) == nil, @"http is left alone");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"video-player://v.redd.it/abcd1234/HLSPlaylist.m3u8"]) == nil, @"resource-loader scheme is left alone");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"https://v.redd.it/abcd1234/CMAF_720.m3u8"]) == nil, @"variant playlist is left alone");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"https://v.redd.it/abcd1234/DASHPlaylist.mpd"]) == nil, @"DASH manifest is left alone");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"https://v.redd.it/abcd1234/HLSPlaylist.m3u8x"]) == nil, @"suffix must be exact");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"https://v.redd.it/a/b/HLSPlaylist.m3u8"]) == nil, @"one path segment only");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"https://v.redd.it.evil.com/abcd1234/HLSPlaylist.m3u8"]) == nil, @"lookalike host");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL([NSURL URLWithString:@"https://preview.redd.it/abcd1234.gif?format=mp4"]) == nil, @"GIF mp4 previews are left alone");
    Expect(ApolloRedditVideoIDFromMasterPlaylistURL(nil) == nil, @"nil URL");
    Expect([ApolloRedditVideoDASHManifestURL(@"abcd1234").absoluteString isEqualToString:@"https://v.redd.it/abcd1234/DASHPlaylist.mpd"], @"DASH URL");
}

static void TestPlaylistDetection(void) {
    Expect(ApolloRedditVideoDataIsHLSPlaylist(Fixture(@"cmaf_with_audio_master.m3u8")), @"real master is a playlist");
    Expect(!ApolloRedditVideoDataIsHLSPlaylist(Fixture(@"s3_access_denied.xml")), @"S3 403 body is not a playlist");
    Expect(!ApolloRedditVideoDataIsHLSPlaylist([@"Access denied" dataUsingEncoding:NSUTF8StringEncoding]), @"plain 403 body is not a playlist");
    Expect(!ApolloRedditVideoDataIsHLSPlaylist(nil), @"nil data");
    Expect(!ApolloRedditVideoDataIsHLSPlaylist([NSData data]), @"empty data");
    NSMutableData *bom = [NSMutableData dataWithBytes:"\xEF\xBB\xBF\n#EXTM3U\n" length:12];
    Expect(ApolloRedditVideoDataIsHLSPlaylist(bom), @"BOM + newline before #EXTM3U");
}

static void TestRebuildWithAudio(void) {
    NSString *rebuilt = Text(ApolloRedditVideoMasterPlaylistFromDASH(Fixture(@"cmaf_with_audio.mpd")));
    NSString *real = Text(Fixture(@"cmaf_with_audio_master.m3u8"));
    Expect(rebuilt != nil, @"rebuilds a master from a CMAF manifest");
    if (!rebuilt) return;
    Expect([rebuilt hasPrefix:@"#EXTM3U\n#EXT-X-VERSION:4\n"], @"header");
    Expect([VariantURIs(rebuilt) isEqualToSet:VariantURIs(real)], @"same variant playlists as Reddit's master");
    Expect([AudioURIs(rebuilt) isEqualToSet:AudioURIs(real)], @"same audio renditions as Reddit's master");
    Expect([Resolutions(rebuilt) isEqualToSet:Resolutions(real)], @"same resolutions as Reddit's master");
    // Apollo's RedditVideoIdentifier and the tweak's CMAF audio regex both read
    // the EXT-X-MEDIA line in Reddit's attribute order.
    Expect([rebuilt containsString:@"#EXT-X-MEDIA:URI=\"CMAF_AUDIO_128.m3u8\",TYPE=AUDIO,GROUP-ID="], @"Reddit-shaped audio line");
    NSRegularExpression *cmafAudio = [NSRegularExpression regularExpressionWithPattern:@"#EXT-X-MEDIA:.*?\"((?:HLS|CMAF)_AUDIO.*?)\\.m3u8" options:0 error:nil];
    Expect([cmafAudio numberOfMatchesInString:rebuilt options:0 range:NSMakeRange(0, rebuilt.length)] == 2, @"tweak CMAF audio regex sees both renditions");
    // 2 audio groups x 5 video rungs, like Reddit's.
    NSUInteger streams = [rebuilt componentsSeparatedByString:@"#EXT-X-STREAM-INF:"].count - 1;
    Expect(streams == 10, [NSString stringWithFormat:@"10 stream entries (got %lu)", (unsigned long)streams]);
    Expect([rebuilt containsString:@"CODECS=\"avc1.4d401f,mp4a.40.2\""], @"video + audio codecs");
    Expect([rebuilt containsString:@"FRAME-RATE=30,"], @"15360/512 frame rate → 30");
    // The first variant (what AVPlayer starts on) is the 480 rung, like Reddit's.
    NSArray *lines = Lines(rebuilt);
    NSUInteger firstURI = NSNotFound;
    for (NSUInteger i = 0; i < lines.count; i++) {
        if (![lines[i] hasPrefix:@"#"]) { firstURI = i; break; }
    }
    Expect(firstURI != NSNotFound && [lines[firstURI] isEqualToString:@"CMAF_480.m3u8"], @"starts on the 480 rung");
    // Bandwidth = video + higher audio for the first entry (1107502 + 132329).
    Expect([rebuilt containsString:@"BANDWIDTH=1239831,"], @"bandwidth adds the audio rendition");
}

static void TestRebuildSilent(void) {
    NSString *rebuilt = Text(ApolloRedditVideoMasterPlaylistFromDASH(Fixture(@"cmaf_silent.mpd")));
    Expect(rebuilt != nil, @"rebuilds a silent clip");
    if (!rebuilt) return;
    Expect(![rebuilt containsString:@"EXT-X-MEDIA"], @"no audio rendition for a silent clip");
    Expect(![rebuilt containsString:@"TYPE=AUDIO"], @"nothing for Apollo to read as audio (GIF pill stays right)");
    Expect(![rebuilt containsString:@"AUDIO="], @"no audio group reference");
    Expect(![rebuilt containsString:@"mp4a"], @"video-only codecs");
    NSUInteger streams = [rebuilt componentsSeparatedByString:@"#EXT-X-STREAM-INF:"].count - 1;
    Expect(streams == 5, @"one entry per video rung");
}

static void TestRefusals(void) {
    Expect(ApolloRedditVideoMasterPlaylistFromDASH(Fixture(@"legacy_dash_names.mpd")) == nil, @"legacy DASH_ names are not guessed at");
    Expect(ApolloRedditVideoMasterPlaylistFromDASH(Fixture(@"s3_access_denied.xml")) == nil, @"403 body builds nothing");
    Expect(ApolloRedditVideoMasterPlaylistFromDASH([@"not xml" dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"garbage builds nothing");
    Expect(ApolloRedditVideoMasterPlaylistFromDASH(nil) == nil, @"nil builds nothing");
    NSString *audioOnly = @"<MPD><Period><AdaptationSet contentType=\"audio\"><Representation bandwidth=\"1\" codecs=\"mp4a.40.2\" id=\"1\" mimeType=\"audio/mp4\"><BaseURL>CMAF_AUDIO_64.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>";
    Expect(ApolloRedditVideoMasterPlaylistFromDASH([audioOnly dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"audio-only manifest builds nothing");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        sFixtures = argc > 1 ? @(argv[1]) : @"tests/fixtures/reddit_video";
        TestURLMatching();
        TestPlaylistDetection();
        TestRebuildWithAudio();
        TestRebuildSilent();
        TestRefusals();
        if (sFailures) {
            fprintf(stderr, "%d failure(s)\n", sFailures);
            return 1;
        }
        printf("reddit_video_playlist_tests: all passed\n");
        return 0;
    }
}
