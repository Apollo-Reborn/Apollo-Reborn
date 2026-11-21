#import "ApolloRedditVideoPlaylist.h"

// See the header for why this exists. Everything here is pure Foundation.

NSString *ApolloRedditVideoIDFromMasterPlaylistURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) return nil;
    if (![url.host.lowercaseString isEqualToString:@"v.redd.it"]) return nil;
    // "/<id>/HLSPlaylist.m3u8" → ["/", "<id>", "HLSPlaylist.m3u8"]
    NSArray<NSString *> *parts = url.path.pathComponents;
    if (parts.count != 3 || ![parts[2] isEqualToString:@"HLSPlaylist.m3u8"]) return nil;
    NSString *videoID = parts[1];
    if (videoID.length < 4 || videoID.length > 32) return nil;
    NSCharacterSet *invalid = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    if ([videoID rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return videoID;
}

NSURL *ApolloRedditVideoDASHManifestURL(NSString *videoID) {
    if (videoID.length == 0) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://v.redd.it/%@/DASHPlaylist.mpd", videoID]];
}

BOOL ApolloRedditVideoDataIsHLSPlaylist(NSData *data) {
    if (data.length < 7) return NO;
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length, i = 0;
    if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) i = 3;
    while (i < length && (bytes[i] == ' ' || bytes[i] == '\t' || bytes[i] == '\r' || bytes[i] == '\n')) i++;
    return length - i >= 7 && memcmp(bytes + i, "#EXTM3U", 7) == 0;
}

// MARK: - DASH manifest parsing

@interface ApolloRedditDASHRepresentation : NSObject
@property (nonatomic, copy) NSString *kind;      // "video" / "audio"
@property (nonatomic, copy) NSString *baseURL;   // e.g. CMAF_720.mp4
@property (nonatomic, copy) NSString *codecs;
@property (nonatomic) long long bandwidth;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) double frameRate;
@end

@implementation ApolloRedditDASHRepresentation
@end

@interface ApolloRedditDASHParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<ApolloRedditDASHRepresentation *> *representations;
@property (nonatomic, copy) NSString *adaptationKind;
@property (nonatomic, copy) NSString *adaptationFrameRate;
@property (nonatomic, strong) ApolloRedditDASHRepresentation *current;
@property (nonatomic, strong) NSMutableString *text;
@end

static double ApolloRedditDASHFrameRate(NSString *value) {
    // "15360/512" (rational) or "30" / "29.97".
    if (value.length == 0) return 0;
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"/"];
    double numerator = parts.firstObject.doubleValue;
    double denominator = parts.count == 2 ? parts[1].doubleValue : 1;
    return denominator > 0 ? numerator / denominator : 0;
}

static NSString *ApolloRedditDASHKind(NSString *contentType, NSString *mimeType) {
    NSString *type = contentType.lowercaseString;
    if ([type isEqualToString:@"video"] || [type isEqualToString:@"audio"]) return type;
    NSString *mime = mimeType.lowercaseString;
    if ([mime hasPrefix:@"video/"]) return @"video";
    if ([mime hasPrefix:@"audio/"]) return @"audio";
    return nil;
}

@implementation ApolloRedditDASHParser

- (instancetype)init {
    if ((self = [super init])) _representations = [NSMutableArray array];
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    if ([name isEqualToString:@"AdaptationSet"]) {
        self.adaptationKind = ApolloRedditDASHKind(attributes[@"contentType"], attributes[@"mimeType"]);
        self.adaptationFrameRate = attributes[@"frameRate"] ?: attributes[@"maxFrameRate"];
    } else if ([name isEqualToString:@"Representation"]) {
        ApolloRedditDASHRepresentation *rep = [ApolloRedditDASHRepresentation new];
        rep.kind = ApolloRedditDASHKind(nil, attributes[@"mimeType"]) ?: self.adaptationKind;
        rep.codecs = attributes[@"codecs"];
        rep.bandwidth = attributes[@"bandwidth"].longLongValue;
        rep.width = attributes[@"width"].integerValue;
        rep.height = attributes[@"height"].integerValue;
        rep.frameRate = ApolloRedditDASHFrameRate(attributes[@"frameRate"] ?: self.adaptationFrameRate);
        self.current = rep;
    } else if ([name isEqualToString:@"BaseURL"] && self.current) {
        self.text = [NSMutableString string];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.text appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qualifiedName {
    if ([name isEqualToString:@"BaseURL"] && self.current) {
        self.current.baseURL = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        self.text = nil;
    } else if ([name isEqualToString:@"Representation"]) {
        if (self.current) [self.representations addObject:self.current];
        self.current = nil;
    } else if ([name isEqualToString:@"AdaptationSet"]) {
        self.adaptationKind = nil;
        self.adaptationFrameRate = nil;
    }
}

@end

// MARK: - Master playlist synthesis

// "CMAF_720.mp4" → "CMAF_720.m3u8" when the name is a CMAF video file;
// "CMAF_AUDIO_128.mp4" → "CMAF_AUDIO_128.m3u8" for audio. nil otherwise.
static NSString *ApolloRedditVariantPlaylistName(NSString *baseURL, BOOL audio) {
    static NSRegularExpression *videoPattern, *audioPattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        videoPattern = [NSRegularExpression regularExpressionWithPattern:@"^CMAF_[0-9]+\\.mp4$" options:0 error:nil];
        audioPattern = [NSRegularExpression regularExpressionWithPattern:@"^CMAF_AUDIO_[0-9]+\\.mp4$" options:0 error:nil];
    });
    if (baseURL.length == 0) return nil;
    NSRegularExpression *pattern = audio ? audioPattern : videoPattern;
    if (![pattern firstMatchInString:baseURL options:0 range:NSMakeRange(0, baseURL.length)]) return nil;
    return [[baseURL stringByDeletingPathExtension] stringByAppendingPathExtension:@"m3u8"];
}

static NSString *ApolloRedditFrameRateString(double frameRate) {
    if (frameRate <= 0) return nil;
    double rounded = round(frameRate);
    if (fabs(frameRate - rounded) < 0.0005) return [NSString stringWithFormat:@"%.0f", rounded];
    return [NSString stringWithFormat:@"%.3f", frameRate];
}

NSData *ApolloRedditVideoMasterPlaylistFromDASH(NSData *mpdData) {
    if (mpdData.length == 0) return nil;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:mpdData];
    ApolloRedditDASHParser *delegate = [ApolloRedditDASHParser new];
    parser.delegate = delegate;
    parser.shouldResolveExternalEntities = NO;
    if (![parser parse]) return nil;

    NSMutableArray<ApolloRedditDASHRepresentation *> *videos = [NSMutableArray array];
    NSMutableArray<ApolloRedditDASHRepresentation *> *audios = [NSMutableArray array];
    for (ApolloRedditDASHRepresentation *rep in delegate.representations) {
        BOOL audio = [rep.kind isEqualToString:@"audio"];
        if (!audio && ![rep.kind isEqualToString:@"video"]) continue;
        // Every file must be CMAF-named; a single unexpected name means this is
        // not the layout we know how to map, so build nothing.
        if (!ApolloRedditVariantPlaylistName(rep.baseURL, audio)) return nil;
        if (!audio && (rep.width <= 0 || rep.height <= 0 || rep.bandwidth <= 0)) return nil;
        [(audio ? audios : videos) addObject:rep];
    }
    if (videos.count == 0) return nil;

    // Reddit lists audio from the higher bitrate down and pairs every video
    // variant with every audio group. Variants go out ascending by height,
    // except that the first one listed is the one AVPlayer starts on: like
    // Reddit's own master, start on the 480 rung (else the tallest at or below
    // 480, else the smallest).
    [audios sortUsingComparator:^NSComparisonResult(ApolloRedditDASHRepresentation *a, ApolloRedditDASHRepresentation *b) {
        return a.bandwidth == b.bandwidth ? NSOrderedSame : (a.bandwidth > b.bandwidth ? NSOrderedAscending : NSOrderedDescending);
    }];
    [videos sortUsingComparator:^NSComparisonResult(ApolloRedditDASHRepresentation *a, ApolloRedditDASHRepresentation *b) {
        NSInteger ha = MIN(a.width, a.height), hb = MIN(b.width, b.height);
        if (ha != hb) return ha < hb ? NSOrderedAscending : NSOrderedDescending;
        return a.bandwidth < b.bandwidth ? NSOrderedAscending : (a.bandwidth > b.bandwidth ? NSOrderedDescending : NSOrderedSame);
    }];
    ApolloRedditDASHRepresentation *start = videos.firstObject;
    for (ApolloRedditDASHRepresentation *rep in videos) {
        if (MIN(rep.width, rep.height) <= 480) start = rep;
    }
    NSMutableArray<ApolloRedditDASHRepresentation *> *ordered = [NSMutableArray arrayWithObject:start];
    for (ApolloRedditDASHRepresentation *rep in videos) {
        if (rep != start) [ordered addObject:rep];
    }

    NSMutableString *out = [NSMutableString stringWithString:@"#EXTM3U\n#EXT-X-VERSION:4\n"];
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (NSUInteger idx = 0; idx < audios.count; idx++) {
        NSString *group = [NSString stringWithFormat:@"audio-%lu", (unsigned long)idx];
        [groups addObject:group];
        [out appendFormat:@"#EXT-X-MEDIA:URI=\"%@\",TYPE=AUDIO,GROUP-ID=\"%@\",NAME=\"audio 0\",DEFAULT=YES,AUTOSELECT=YES\n",
                          ApolloRedditVariantPlaylistName(audios[idx].baseURL, YES), group];
    }

    void (^appendVariant)(ApolloRedditDASHRepresentation *, ApolloRedditDASHRepresentation *, NSString *) =
        ^(ApolloRedditDASHRepresentation *video, ApolloRedditDASHRepresentation *audio, NSString *group) {
        long long bandwidth = video.bandwidth + audio.bandwidth;
        NSMutableString *line = [NSMutableString stringWithFormat:
            @"#EXT-X-STREAM-INF:PROGRAM-ID=0,CLOSED-CAPTIONS=NONE,BANDWIDTH=%lld,AVERAGE-BANDWIDTH=%lld,RESOLUTION=%ldx%ld",
            bandwidth, bandwidth, (long)video.width, (long)video.height];
        NSString *frameRate = ApolloRedditFrameRateString(video.frameRate);
        if (frameRate) [line appendFormat:@",FRAME-RATE=%@", frameRate];
        NSMutableArray<NSString *> *codecs = [NSMutableArray array];
        if (video.codecs.length) [codecs addObject:video.codecs];
        if (audio.codecs.length) [codecs addObject:audio.codecs];
        if (codecs.count) [line appendFormat:@",CODECS=\"%@\"", [codecs componentsJoinedByString:@","]];
        if (group) [line appendFormat:@",AUDIO=\"%@\"", group];
        [out appendFormat:@"%@\n%@\n", line, ApolloRedditVariantPlaylistName(video.baseURL, NO)];
    };

    if (audios.count == 0) {
        // Silent clip: video-only variants (Apollo then labels it GIF, which is right).
        for (ApolloRedditDASHRepresentation *video in ordered) appendVariant(video, nil, nil);
    } else {
        for (NSUInteger g = 0; g < audios.count; g++) {
            for (ApolloRedditDASHRepresentation *video in ordered) appendVariant(video, audios[g], groups[g]);
        }
    }
    return [out dataUsingEncoding:NSUTF8StringEncoding];
}
