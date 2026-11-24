#import "ApolloGQLLegacy.h"
#import "ApolloGQLRichText.h"
#import <time.h>

#pragma mark - Reading a GraphQL answer

// GraphQL sends null for anything absent, so every read goes through these.
static id ApolloGQLValue(id container, NSString *key) {
    if (![container isKindOfClass:[NSDictionary class]]) return nil;
    id value = ((NSDictionary *)container)[key];
    return value == [NSNull null] ? nil : value;
}

static NSDictionary *ApolloGQLDict(id container, NSString *key) {
    id value = ApolloGQLValue(container, key);
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSArray *ApolloGQLArray(id container, NSString *key) {
    id value = ApolloGQLValue(container, key);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

static NSString *ApolloGQLString(id container, NSString *key) {
    id value = ApolloGQLValue(container, key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSNumber *ApolloGQLNumber(id container, NSString *key) {
    id value = ApolloGQLValue(container, key);
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static BOOL ApolloGQLBool(id container, NSString *key) {
    return [ApolloGQLNumber(container, key) boolValue];
}

static id ApolloGQLOrNull(id value) {
    return value ?: [NSNull null];
}

// "2026-11-23T16:30:35.456000+0000" as Unix seconds, the way the legacy API
// gives created_utc (whole seconds).
static NSNumber *ApolloGQLEpoch(NSString *iso) {
    if (![iso isKindOfClass:[NSString class]] || iso.length < 19) return nil;
    int year, month, day, hour, minute, second;
    if (sscanf(iso.UTF8String, "%4d-%2d-%2dT%2d:%2d:%2d", &year, &month, &day, &hour, &minute, &second) != 6) return nil;
    struct tm parts = {0};
    parts.tm_year = year - 1900;
    parts.tm_mon = month - 1;
    parts.tm_mday = day;
    parts.tm_hour = hour;
    parts.tm_min = minute;
    parts.tm_sec = second;
    time_t seconds = timegm(&parts);
    NSString *tail = [iso substringFromIndex:19];
    NSRange sign = [tail rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"+-"]];
    if (sign.location != NSNotFound) {
        NSString *digits = [[tail substringFromIndex:sign.location + 1] stringByReplacingOccurrencesOfString:@":" withString:@""];
        if (digits.length >= 4) {
            int offset = [[digits substringToIndex:2] intValue] * 3600 + [[digits substringWithRange:NSMakeRange(2, 2)] intValue] * 60;
            seconds -= [tail characterAtIndex:sign.location] == '+' ? offset : -offset;
        }
    }
    return @((double)seconds);
}

#pragma mark - Escaping

// Without raw_json=1 the legacy API escapes &, < and > in every string it
// sends, URLs included, and Apollo unescapes them.
static NSString *ApolloGQLEscapeLegacyString(NSString *text) {
    if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"&<>"]].location == NSNotFound) return text;
    NSMutableString *out = [text mutableCopy];
    [out replaceOccurrencesOfString:@"&" withString:@"&amp;" options:NSLiteralSearch range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"<" withString:@"&lt;" options:NSLiteralSearch range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@">" withString:@"&gt;" options:NSLiteralSearch range:NSMakeRange(0, out.length)];
    return out;
}

static id ApolloGQLEscapeLegacyValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return ApolloGQLEscapeLegacyString(value);
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[value count]];
        for (id item in value) [out addObject:ApolloGQLEscapeLegacyValue(item)];
        return out;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[value count]];
        for (id key in (NSDictionary *)value) out[key] = ApolloGQLEscapeLegacyValue(((NSDictionary *)value)[key]);
        return out;
    }
    return value;
}

#pragma mark - Images

// A GraphQL MediaSource ({url, dimensions{width, height}}) as a legacy image
// ({url, width, height}), or nil without a URL.
static NSDictionary *ApolloGQLLegacyImage(NSDictionary *source) {
    NSString *url = ApolloGQLString(source, @"url");
    if (url.length == 0) return nil;
    NSDictionary *dimensions = ApolloGQLDict(source, @"dimensions");
    return @{ @"url": url,
              @"width": ApolloGQLNumber(dimensions, @"width") ?: @0,
              @"height": ApolloGQLNumber(dimensions, @"height") ?: @0 };
}

static NSArray<NSString *> *ApolloGQLImageSizes(void) {
    return @[ @"small", @"medium", @"large", @"xlarge", @"xxlarge", @"xxxlarge" ];
}

// {source, resolutions} from a set of sized images keyed `<prefix>source`,
// `<prefix>small`, … (a StillMedia has no prefix; animated ones are "gif_" and
// "mp4_"). nil without a source.
static NSDictionary *ApolloGQLLegacyImageSet(NSDictionary *sizes, NSString *prefix) {
    NSDictionary *source = ApolloGQLLegacyImage(ApolloGQLDict(sizes, [prefix stringByAppendingString:@"source"]));
    if (!source) return nil;
    NSMutableArray<NSDictionary *> *resolutions = [NSMutableArray array];
    for (NSString *size in ApolloGQLImageSizes()) {
        NSDictionary *image = ApolloGQLLegacyImage(ApolloGQLDict(sizes, [prefix stringByAppendingString:size]));
        if (image) [resolutions addObject:image];
    }
    return @{ @"source": source, @"resolutions": resolutions };
}

// The legacy `preview` for a post's media, or nil when it has no still image.
static NSDictionary *ApolloGQLLegacyPreview(NSDictionary *media, BOOL nsfw) {
    NSDictionary *still = ApolloGQLLegacyImageSet(ApolloGQLDict(media, @"still"), @"");
    if (!still) return nil;
    NSMutableDictionary *variants = [NSMutableDictionary dictionary];
    NSDictionary *animated = ApolloGQLDict(media, @"animated");
    NSDictionary *gif = ApolloGQLLegacyImageSet(animated, @"gif_");
    NSDictionary *mp4 = ApolloGQLLegacyImageSet(animated, @"mp4_");
    if (gif) variants[@"gif"] = gif;
    if (mp4) variants[@"mp4"] = mp4;
    NSDictionary *obfuscated = ApolloGQLLegacyImageSet(ApolloGQLDict(media, @"obfuscated_still"), @"");
    if (obfuscated) {
        variants[@"obfuscated"] = obfuscated;
        if (nsfw) variants[@"nsfw"] = obfuscated;
    }
    NSMutableDictionary *image = [still mutableCopy];
    image[@"variants"] = variants;
    // The legacy id is the image's file name without its extension.
    NSString *file = [NSURLComponents componentsWithString:still[@"source"][@"url"]].path.lastPathComponent;
    image[@"id"] = file.stringByDeletingPathExtension ?: @"";
    NSString *hint = ApolloGQLString(media, @"typeHint");
    BOOL enabled = [hint isEqualToString:@"IMAGE"] || [hint isEqualToString:@"GIFVIDEO"];
    return @{ @"images": @[ image ], @"enabled": @(enabled) };
}

#pragma mark - Video

// The legacy API names a v.redd.it video's files by the short side of the
// rendition ("CMAF_1080.mp4" for 1080x1920 and for 1920x1080), from this ladder.
static NSInteger ApolloGQLVideoRendition(NSDictionary *media, NSDictionary *streaming) {
    NSInteger shortSide = 0;
    NSArray *permutations = ApolloGQLArray(ApolloGQLDict(ApolloGQLDict(media, @"packagedMedia"), @"playbackMp4s"), @"permutations");
    for (id permutation in permutations) {
        NSDictionary *dimensions = ApolloGQLDict(ApolloGQLDict(permutation, @"source"), @"dimensions");
        NSInteger side = MIN([ApolloGQLNumber(dimensions, @"width") integerValue], [ApolloGQLNumber(dimensions, @"height") integerValue]);
        shortSide = MAX(shortSide, side);
    }
    if (shortSide == 0) {
        NSDictionary *dimensions = ApolloGQLDict(streaming, @"dimensions");
        shortSide = MIN([ApolloGQLNumber(dimensions, @"width") integerValue], [ApolloGQLNumber(dimensions, @"height") integerValue]);
    }
    static const NSInteger ladder[] = { 1080, 720, 480, 360, 270, 220 };
    for (size_t i = 0; i < sizeof(ladder) / sizeof(ladder[0]); i++) {
        if (shortSide >= ladder[i]) return ladder[i];
    }
    return shortSide > 0 ? 220 : 0;
}

// The legacy `reddit_video` for a post hosted on v.redd.it, or nil.
static NSDictionary *ApolloGQLLegacyRedditVideo(NSDictionary *media) {
    NSDictionary *streaming = ApolloGQLDict(media, @"streaming");
    NSString *hls = ApolloGQLString(streaming, @"hlsUrl");
    NSString *dash = ApolloGQLString(streaming, @"dashUrl");
    if (hls.length == 0 && dash.length == 0) return nil;
    NSDictionary *dimensions = ApolloGQLDict(streaming, @"dimensions");
    NSString *scrubber = ApolloGQLString(streaming, @"scrubberMediaUrl");
    BOOL isGif = ApolloGQLBool(streaming, @"isGif");
    NSInteger rendition = ApolloGQLVideoRendition(media, streaming);

    // "https://v.redd.it/<id>/CMAF_96.mp4" names the folder and whether the
    // files are CMAF_ or DASH_; the fallback is the top rendition next to it.
    NSString *fallback = nil;
    NSURLComponents *base = [NSURLComponents componentsWithString:scrubber.length ? scrubber : (dash.length ? dash : hls)];
    NSString *folder = base.path.stringByDeletingLastPathComponent;
    if (base.host.length > 0 && folder.length > 1 && rendition > 0) {
        NSString *family = [scrubber.lastPathComponent hasPrefix:@"DASH_"] ? @"DASH" : @"CMAF";
        fallback = [NSString stringWithFormat:@"https://%@%@/%@_%ld.mp4?source=fallback", base.host, folder, family, (long)rendition];
    }
    if (fallback.length == 0) fallback = ApolloGQLString(ApolloGQLDict(media, @"download"), @"url");

    static NSDictionary<NSNumber *, NSNumber *> *bitrates;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bitrates = @{ @1080: @5000, @720: @2400, @480: @1200, @360: @800, @270: @450, @220: @300 };
    });
    NSMutableDictionary *video = [NSMutableDictionary dictionary];
    video[@"bitrate_kbps"] = bitrates[@(rendition)] ?: @0;
    if (fallback.length > 0) video[@"fallback_url"] = fallback;
    // GraphQL doesn't say whether a video has sound. Reddit's silent "GIF"
    // videos are marked, so everything else is taken to have it.
    video[@"has_audio"] = @(!isGif);
    video[@"height"] = ApolloGQLNumber(dimensions, @"height") ?: @0;
    video[@"width"] = ApolloGQLNumber(dimensions, @"width") ?: @0;
    if (scrubber.length > 0) video[@"scrubber_media_url"] = scrubber;
    if (dash.length > 0) video[@"dash_url"] = dash;
    video[@"duration"] = ApolloGQLNumber(streaming, @"duration") ?: @0;
    if (hls.length > 0) video[@"hls_url"] = hls;
    video[@"is_gif"] = @(isGif);
    video[@"transcoding_status"] = @"completed";
    return video;
}

#pragma mark - Flair, gallery, poll

// The legacy flair keys under `prefix` ("link_flair" or "author_flair").
static void ApolloGQLAddLegacyFlair(NSMutableDictionary *data, NSString *prefix, NSDictionary *flair) {
    BOOL linkFlair = [prefix isEqualToString:@"link_flair"];
    NSArray *richtext = nil;
    NSString *richtextJSON = ApolloGQLString(flair, @"richtext");
    if (richtextJSON.length > 0) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[richtextJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if ([parsed isKindOfClass:[NSArray class]]) richtext = parsed;
    }
    NSDictionary *template = ApolloGQLDict(flair, @"template");
    NSString *background = ApolloGQLString(template, @"backgroundColor").lowercaseString;
    NSString *textColor = ApolloGQLString(flair, @"textColor").lowercaseString;
    id (^key)(NSString *) = ^id(NSString *suffix) { return [NSString stringWithFormat:@"%@_%@", prefix, suffix]; };
    data[key(@"text")] = ApolloGQLOrNull(ApolloGQLString(flair, @"text"));
    data[key(@"richtext")] = richtext ?: @[];
    data[key(@"type")] = richtext.count > 0 ? @"richtext" : @"text";
    // A flair without a template, and a post with no flair at all, still have
    // these two in the legacy answer.
    BOOL defaults = linkFlair || flair != nil;
    data[key(@"background_color")] = background ?: (defaults ? (id)@"" : [NSNull null]);
    data[key(@"text_color")] = textColor ?: (defaults ? (id)@"dark" : [NSNull null]);
    NSString *templateID = ApolloGQLString(template, @"id");
    if (templateID.length > 0 || !linkFlair) data[key(@"template_id")] = ApolloGQLOrNull(templateID);
    data[key(@"css_class")] = [NSNull null];
}

// One entry of a legacy media_metadata dictionary, for a GraphQL image asset
// ({id, url, width, height, mimetype, small…xxxlarge}): what a gallery item and
// an image embedded in a comment both have.
static NSDictionary *ApolloGQLLegacyMediaMetadata(NSDictionary *media) {
    NSString *mediaID = ApolloGQLString(media, @"id") ?: @"";
    NSMutableArray<NSDictionary *> *previews = [NSMutableArray array];
    for (NSString *size in ApolloGQLImageSizes()) {
        NSDictionary *image = ApolloGQLLegacyImage(ApolloGQLDict(media, size));
        if (image) [previews addObject:@{ @"x": image[@"width"], @"y": image[@"height"], @"u": image[@"url"] }];
    }
    NSString *mimetype = ApolloGQLString(media, @"mimetype") ?: @"image/jpeg";
    NSString *url = ApolloGQLString(media, @"url") ?: @"";
    NSNumber *width = ApolloGQLNumber(media, @"width") ?: @0, *height = ApolloGQLNumber(media, @"height") ?: @0;
    BOOL animated = [mimetype isEqualToString:@"image/gif"] || [ApolloGQLString(media, @"__typename") hasPrefix:@"Animated"];
    NSMutableDictionary *source = [@{ @"x": width, @"y": height } mutableCopy];
    if (animated) {
        source[@"gif"] = url;
        NSString *mp4 = ApolloGQLString(ApolloGQLDict(media, @"mp4_source"), @"url") ?: ApolloGQLString(media, @"mp4Url");
        if (mp4.length > 0) source[@"mp4"] = mp4;
    } else {
        source[@"u"] = url;
    }
    NSString *status = ApolloGQLString(media, @"status").lowercaseString ?: @"valid";
    return @{ @"status": status, @"e": animated ? @"AnimatedImage" : @"Image", @"m": mimetype,
              @"p": previews, @"s": source, @"id": mediaID };
}

// Adds is_gallery, gallery_data and media_metadata for a gallery post.
static void ApolloGQLAddLegacyGallery(NSMutableDictionary *data, NSDictionary *gallery) {
    NSArray *items = ApolloGQLArray(gallery, @"items");
    if (items.count == 0) return;
    NSMutableArray<NSDictionary *> *galleryItems = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary *> *metadata = [NSMutableDictionary dictionary];
    for (id item in items) {
        NSDictionary *media = ApolloGQLDict(item, @"media");
        NSString *mediaID = ApolloGQLString(media, @"id");
        if (mediaID.length == 0) continue;
        NSMutableDictionary *galleryItem = [NSMutableDictionary dictionary];
        galleryItem[@"media_id"] = mediaID;
        NSString *itemID = ApolloGQLString(item, @"id");
        galleryItem[@"id"] = itemID.length > 0 ? @(itemID.longLongValue) : @0;
        NSString *caption = ApolloGQLString(item, @"caption");
        if (caption.length > 0) galleryItem[@"caption"] = caption;
        NSString *outbound = ApolloGQLString(item, @"outboundUrl");
        if (outbound.length > 0) galleryItem[@"outbound_url"] = outbound;
        galleryItem[@"is_deleted"] = @NO;
        [galleryItems addObject:galleryItem];

        metadata[mediaID] = ApolloGQLLegacyMediaMetadata(media);
    }
    if (galleryItems.count == 0) return;
    data[@"is_gallery"] = @YES;
    data[@"gallery_data"] = @{ @"items": galleryItems };
    data[@"media_metadata"] = metadata;
}

// The legacy poll_data. GraphQL leaves the vote counts out until the account
// has voted or the poll has closed, and has no total of its own.
static NSDictionary *ApolloGQLLegacyPoll(NSDictionary *poll) {
    NSArray *options = ApolloGQLArray(poll, @"options");
    if (!options) return nil;
    NSMutableArray<NSDictionary *> *legacyOptions = [NSMutableArray array];
    long long total = 0;
    for (id option in options) {
        NSString *optionID = ApolloGQLString(option, @"id");
        if (optionID.length == 0) continue;
        NSMutableDictionary *legacy = [@{ @"text": ApolloGQLString(option, @"text") ?: @"", @"id": optionID } mutableCopy];
        NSNumber *votes = ApolloGQLNumber(option, @"voteCount");
        if (votes) {
            legacy[@"vote_count"] = votes;
            total += votes.longLongValue;
        }
        [legacyOptions addObject:legacy];
    }
    // Milliseconds, with the fraction the legacy API keeps ("…:02.842000+0000").
    NSString *endsAt = ApolloGQLString(poll, @"votingEndsAt");
    NSNumber *ends = ApolloGQLEpoch(endsAt);
    long long endMilliseconds = ends.longLongValue * 1000;
    if (ends && endsAt.length > 23 && [endsAt characterAtIndex:19] == '.') {
        endMilliseconds += [[endsAt substringWithRange:NSMakeRange(20, 3)] longLongValue];
    }
    NSNumber *reported = ApolloGQLNumber(poll, @"totalVoteCount");
    return @{
        @"prediction_status": [NSNull null], @"total_stake_amount": [NSNull null],
        @"voting_end_timestamp": @(endMilliseconds),
        @"options": legacyOptions, @"vote_updates_remained": [NSNull null], @"is_prediction": @NO,
        @"resolved_option_id": [NSNull null], @"user_won_amount": [NSNull null],
        @"user_selection": ApolloGQLOrNull(ApolloGQLString(poll, @"selectedOptionId")),
        @"total_vote_count": reported ?: @(total), @"tournament_id": [NSNull null],
    };
}

#pragma mark - Posts

static NSString *ApolloGQLLegacySort(NSString *sort) {
    if (sort.length == 0 || [sort isEqualToString:@"BLANK"]) return nil;
    NSString *lower = sort.lowercaseString;
    return [lower isEqualToString:@"best"] ? @"confidence" : lower;
}

// The unescaped `data` of a t3 thing. `depth` stops a crosspost of a crosspost
// of … from recursing without end.
static NSMutableDictionary<NSString *, id> *ApolloGQLLegacyLinkDataUnescaped(NSDictionary *post, NSUInteger depth) {
    NSString *fullname = ApolloGQLString(post, @"id");
    if (![fullname hasPrefix:@"t3_"] || fullname.length <= 3) return nil;
    NSString *id36 = [fullname substringFromIndex:3];
    NSDictionary *subreddit = ApolloGQLDict(post, @"subreddit");
    NSDictionary *author = ApolloGQLDict(post, @"authorInfo");
    NSDictionary *media = ApolloGQLDict(post, @"media");
    NSDictionary *content = ApolloGQLDict(post, @"content");
    NSString *typeHint = ApolloGQLString(media, @"typeHint");
    BOOL isSelf = ApolloGQLBool(post, @"isSelfPost");
    BOOL nsfw = ApolloGQLBool(post, @"isNsfw");
    NSString *url = ApolloGQLString(post, @"url") ?: @"";
    NSString *domain = ApolloGQLString(post, @"domain") ?: @"";
    NSMutableDictionary<NSString *, id> *data = [NSMutableDictionary dictionary];

    // Identity and where it lives.
    data[@"id"] = id36;
    data[@"name"] = fullname;
    data[@"title"] = ApolloGQLString(post, @"postTitle") ?: @"";
    data[@"permalink"] = ApolloGQLString(post, @"permalink") ?: @"";
    data[@"url"] = url;
    if (!isSelf) data[@"url_overridden_by_dest"] = url;
    data[@"domain"] = domain;
    data[@"is_reddit_media_domain"] = @([domain isEqualToString:@"i.redd.it"] || [domain isEqualToString:@"v.redd.it"]);
    NSString *subredditName = ApolloGQLString(subreddit, @"name") ?: @"";
    data[@"subreddit"] = subredditName;
    data[@"subreddit_id"] = ApolloGQLString(subreddit, @"id") ?: @"";
    data[@"subreddit_name_prefixed"] = ApolloGQLString(subreddit, @"prefixedName") ?: [@"r/" stringByAppendingString:subredditName];
    data[@"subreddit_type"] = ApolloGQLString(subreddit, @"type").lowercaseString ?: @"public";
    data[@"subreddit_subscribers"] = @([ApolloGQLNumber(subreddit, @"subscribersCount") longLongValue]);
    data[@"quarantine"] = @(ApolloGQLBool(subreddit, @"isQuarantined"));

    // Author. A deleted account has no authorInfo.
    NSString *authorName = ApolloGQLString(author, @"name");
    data[@"author"] = authorName.length > 0 ? authorName : @"[deleted]";
    NSString *authorID = ApolloGQLString(author, @"id");
    if (authorID.length > 0) data[@"author_fullname"] = authorID;
    data[@"author_is_blocked"] = @(ApolloGQLBool(post, @"isAuthorBlocked"));
    data[@"author_premium"] = @NO;
    data[@"author_patreon_flair"] = @NO;
    ApolloGQLAddLegacyFlair(data, @"author_flair", ApolloGQLDict(post, @"authorFlair"));
    ApolloGQLAddLegacyFlair(data, @"link_flair", ApolloGQLDict(post, @"flair"));

    // Text. Apollo draws the body from the HTML; the Markdown is what it edits
    // and quotes.
    data[@"is_self"] = @(isSelf);
    NSString *markdown = ApolloGQLString(content, @"markdown") ?: @"";
    NSString *html = nil;
    if (markdown.length > 0) {
        html = ApolloGQLRichTextHTML(ApolloGQLString(content, @"richtext"), ApolloGQLArray(content, @"richtextMedia"), YES)
            ?: ApolloGQLPlainTextHTML(markdown, YES);
    }
    // The legacy API ends a poll post's text with a link to the poll.
    if (ApolloGQLDict(post, @"poll")) {
        NSString *pollURL = [@"https://www.reddit.com/poll/" stringByAppendingString:id36];
        markdown = [markdown stringByAppendingFormat:@"\n\n[View Poll](%@)", pollURL];
        NSString *link = [NSString stringWithFormat:@"<p><a href=\"%@\">View Poll</a></p>", pollURL];
        NSString *closing = @"\n</div><!-- SC_ON -->";
        html = [html hasSuffix:closing]
            ? [NSString stringWithFormat:@"%@\n\n%@%@", [html substringToIndex:html.length - closing.length], link, closing]
            : [NSString stringWithFormat:@"<!-- SC_OFF --><div class=\"md\">%@%@", link, closing];
    }
    data[@"selftext"] = markdown;
    data[@"selftext_html"] = ApolloGQLOrNull(html);

    // Times, score and the account's own state.
    NSNumber *created = ApolloGQLEpoch(ApolloGQLString(post, @"createdAt")) ?: @0;
    data[@"created"] = created;
    data[@"created_utc"] = created;
    NSNumber *edited = ApolloGQLEpoch(ApolloGQLString(post, @"editedAt"));
    data[@"edited"] = edited ?: (id)@NO;
    NSNumber *score = ApolloGQLNumber(post, @"score") ?: @0;
    data[@"score"] = @(score.longLongValue);
    data[@"ups"] = @(score.longLongValue);
    data[@"downs"] = @0;
    data[@"upvote_ratio"] = @(round([ApolloGQLNumber(post, @"upvoteRatio") doubleValue] * 100.0) / 100.0);
    data[@"hide_score"] = @(ApolloGQLBool(post, @"isScoreHidden"));
    NSString *vote = ApolloGQLString(post, @"voteState");
    data[@"likes"] = [vote isEqualToString:@"UP"] ? (id)@YES : [vote isEqualToString:@"DOWN"] ? (id)@NO : [NSNull null];
    data[@"saved"] = @(ApolloGQLBool(post, @"isSaved"));
    data[@"hidden"] = @(ApolloGQLBool(post, @"isHidden"));
    data[@"clicked"] = @NO;
    data[@"visited"] = @NO;
    data[@"num_comments"] = @([ApolloGQLNumber(post, @"commentCount") longLongValue]);
    data[@"num_crossposts"] = @([ApolloGQLNumber(post, @"crosspostCount") longLongValue]);

    // Flags.
    data[@"over_18"] = @(nsfw);
    data[@"spoiler"] = @(ApolloGQLBool(post, @"isSpoiler"));
    data[@"locked"] = @(ApolloGQLBool(post, @"isLocked"));
    data[@"stickied"] = @(ApolloGQLBool(post, @"isStickied"));
    data[@"archived"] = @(ApolloGQLBool(post, @"isArchived"));
    data[@"pinned"] = @NO;
    data[@"contest_mode"] = @(ApolloGQLBool(post, @"isContestMode"));
    data[@"is_crosspostable"] = @(ApolloGQLBool(post, @"isCrosspostable"));
    data[@"can_gild"] = @NO;
    data[@"is_original_content"] = @NO;
    data[@"is_meta"] = @NO;
    data[@"media_only"] = @NO;
    data[@"is_robot_indexable"] = @YES;
    data[@"no_follow"] = @NO;
    data[@"send_replies"] = @YES;
    data[@"allow_live_comments"] = @NO;
    data[@"is_created_from_ads_ui"] = @NO;
    data[@"distinguished"] = ApolloGQLOrNull(ApolloGQLString(post, @"distinguishedAs").lowercaseString);
    data[@"suggested_sort"] = ApolloGQLOrNull(ApolloGQLLegacySort(ApolloGQLString(post, @"suggestedCommentSort")));
    data[@"removed_by_category"] = ApolloGQLOrNull(ApolloGQLString(post, @"removedByCategory").lowercaseString);

    // Awards and moderation: what an account that isn't a moderator of the
    // subreddit gets from the legacy API, which no longer reports awards.
    data[@"total_awards_received"] = @0;
    data[@"all_awardings"] = @[];
    data[@"awarders"] = @[];
    data[@"gilded"] = @0;
    data[@"gildings"] = @{};
    data[@"top_awarded_type"] = [NSNull null];
    data[@"can_mod_post"] = @(ApolloGQLDict(subreddit, @"modPermissions") != nil);
    data[@"mod_reports"] = @[];
    data[@"user_reports"] = @[];
    for (NSString *key in @[ @"approved_at_utc", @"approved_by", @"banned_at_utc", @"banned_by", @"mod_note", @"mod_reason_by",
                             @"mod_reason_title", @"num_reports", @"removal_reason", @"removed_by", @"report_reasons",
                             @"view_count", @"category", @"content_categories", @"discussion_type" ]) {
        data[key] = [NSNull null];
    }
    data[@"treatment_tags"] = @[];
    data[@"pwls"] = @6;
    data[@"wls"] = @6;

    // Thumbnail: a URL, or the words the legacy API uses when there's none.
    NSDictionary *thumbnail = ApolloGQLLegacyImage(ApolloGQLDict(post, @"thumbnail"));
    if (isSelf) {
        data[@"thumbnail"] = @"self";
    } else if (thumbnail) {
        data[@"thumbnail"] = thumbnail[@"url"];
    } else {
        data[@"thumbnail"] = @"default";
    }
    data[@"thumbnail_width"] = (!isSelf && thumbnail) ? thumbnail[@"width"] : [NSNull null];
    data[@"thumbnail_height"] = (!isSelf && thumbnail) ? thumbnail[@"height"] : [NSNull null];

    // Media. The legacy post_hint is what Apollo picks its post layout by.
    NSDictionary *preview = ApolloGQLLegacyPreview(media, nsfw);
    if (preview) data[@"preview"] = preview;
    NSDictionary *redditVideo = [typeHint isEqualToString:@"VIDEO"] ? ApolloGQLLegacyRedditVideo(media) : nil;
    NSDictionary *embed = ApolloGQLDict(media, @"video");
    NSString *embedHTML = ApolloGQLString(embed, @"embedHtml");
    NSString *postHint = nil;
    data[@"is_video"] = @(redditVideo != nil);
    data[@"media_embed"] = @{};
    data[@"secure_media_embed"] = @{};
    data[@"media"] = [NSNull null];
    data[@"secure_media"] = [NSNull null];
    if (redditVideo) {
        postHint = @"hosted:video";
        data[@"media"] = @{ @"reddit_video": redditVideo };
        data[@"secure_media"] = @{ @"reddit_video": redditVideo };
    } else if ([typeHint isEqualToString:@"IMAGE"] || [typeHint isEqualToString:@"GIFVIDEO"]) {
        postHint = @"image";
    } else if ([typeHint isEqualToString:@"EMBED"] && embedHTML.length > 0) {
        postHint = @"rich:video";
        NSDictionary *attribution = ApolloGQLDict(embed, @"attribution");
        NSDictionary *dimensions = ApolloGQLDict(embed, @"dimensions");
        NSNumber *width = ApolloGQLNumber(dimensions, @"width") ?: @0, *height = ApolloGQLNumber(dimensions, @"height") ?: @0;
        NSMutableDictionary *oembed = [@{ @"version": @"1.0", @"type": @"video", @"html": embedHTML, @"width": width, @"height": height } mutableCopy];
        NSDictionary<NSString *, NSString *> *attributionKeys = @{ @"provider_url": @"providerUrl", @"provider_name": @"providerName",
                                                                    @"title": @"title", @"author_name": @"authorName",
                                                                    @"author_url": @"authorUrl", @"description": @"description" };
        for (NSString *legacyKey in attributionKeys) {
            NSString *value = ApolloGQLString(attribution, attributionKeys[legacyKey]);
            if (value.length > 0) oembed[legacyKey] = value;
        }
        NSDictionary *still = preview ? ((NSArray *)preview[@"images"]).firstObject[@"source"] : nil;
        if (still) {
            oembed[@"thumbnail_url"] = still[@"url"];
            oembed[@"thumbnail_width"] = still[@"width"];
            oembed[@"thumbnail_height"] = still[@"height"];
        }
        NSDictionary *legacyMedia = @{ @"type": domain, @"oembed": oembed };
        data[@"media"] = legacyMedia;
        data[@"secure_media"] = legacyMedia;
        NSDictionary *legacyEmbed = @{ @"content": embedHTML, @"width": width, @"height": height, @"scrolling": @NO };
        data[@"media_embed"] = legacyEmbed;
        NSMutableDictionary *secureEmbed = [legacyEmbed mutableCopy];
        secureEmbed[@"media_domain_url"] = [@"https://www.redditmedia.com/mediaembed/" stringByAppendingString:id36];
        data[@"secure_media_embed"] = secureEmbed;
    } else if (preview) {
        postHint = isSelf ? @"self" : @"link";
    }
    if (postHint) data[@"post_hint"] = postHint;

    ApolloGQLAddLegacyGallery(data, ApolloGQLDict(post, @"gallery"));
    NSDictionary *poll = ApolloGQLLegacyPoll(ApolloGQLDict(post, @"poll"));
    if (poll) data[@"poll_data"] = poll;

    // A crosspost carries the post it shares, whole.
    NSDictionary *root = ApolloGQLDict(ApolloGQLDict(post, @"crosspostRoot"), @"post");
    NSMutableDictionary *parent = depth < 2 ? ApolloGQLLegacyLinkDataUnescaped(root, depth + 1) : nil;
    if (parent) {
        data[@"crosspost_parent"] = parent[@"name"];
        data[@"crosspost_parent_list"] = @[ parent ];
    }
    return data;
}

NSDictionary<NSString *, id> *ApolloGQLLegacyLinkData(NSDictionary *post, BOOL rawJSON) {
    NSMutableDictionary<NSString *, id> *data = ApolloGQLLegacyLinkDataUnescaped(post, 0);
    if (!data) return nil;
    return rawJSON ? data : ApolloGQLEscapeLegacyValue(data);
}

NSDictionary<NSString *, id> *ApolloGQLLegacyThing(NSString *kind, NSDictionary *data) {
    return @{ @"kind": kind, @"data": data };
}

NSDictionary<NSString *, id> *ApolloGQLLegacyListing(NSArray<NSDictionary *> *children, NSString *after) {
    return @{ @"kind": @"Listing",
              @"data": @{ @"after": ApolloGQLOrNull(after.length > 0 ? after : nil), @"dist": @(children.count), @"modhash": @"",
                          @"geo_filter": @"", @"children": children, @"before": [NSNull null] } };
}

NSArray<NSDictionary *> *ApolloGQLLegacyLinksFromPostsByIds(NSDictionary *answer, NSArray<NSString *> *fullnames, BOOL rawJSON) {
    NSArray *posts = ApolloGQLArray(ApolloGQLDict(answer, @"data"), @"postsInfoByIds");
    if (!posts) return nil;
    NSMutableDictionary<NSString *, NSDictionary *> *byName = [NSMutableDictionary dictionary];
    for (id post in posts) {
        NSDictionary *data = [post isKindOfClass:[NSDictionary class]] ? ApolloGQLLegacyLinkData(post, rawJSON) : nil;
        if (data) byName[ApolloGQLString(post, @"id")] = data;
    }
    NSMutableArray<NSDictionary *> *things = [NSMutableArray array];
    for (NSString *fullname in fullnames) {
        NSDictionary *data = byName[fullname];
        if (data) [things addObject:ApolloGQLLegacyThing(@"t3", data)];
    }
    return things;
}

#pragma mark - Comments

// A "load more" row's cursor rides in the legacy `more` thing's one child id,
// which Apollo sends back untouched as /api/morechildren's `children`. The id
// is made of the characters a real comment id has (0-9, a-z), so nothing that
// handles it as one can trip on it: this prefix, then the hex of
// "<depth>:<cursor>".
static NSString *const kApolloGQLMoreTokenPrefix = @"gqlmore";

NSString *ApolloGQLMoreToken(NSString *cursor, NSInteger depth) {
    NSData *bytes = [[NSString stringWithFormat:@"%ld:%@", (long)depth, cursor] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *token = [kApolloGQLMoreTokenPrefix mutableCopy];
    const uint8_t *raw = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) [token appendFormat:@"%02x", raw[i]];
    return token;
}

static int ApolloGQLHexValue(unichar character) {
    if (character >= '0' && character <= '9') return character - '0';
    if (character >= 'a' && character <= 'f') return character - 'a' + 10;
    return -1;
}

NSString *ApolloGQLMoreTokenCursor(NSString *token, NSInteger *depth) {
    if (![token isKindOfClass:[NSString class]] || ![token hasPrefix:kApolloGQLMoreTokenPrefix]) return nil;
    NSString *hex = [token substringFromIndex:kApolloGQLMoreTokenPrefix.length];
    if (hex.length == 0 || hex.length % 2 != 0) return nil;
    NSMutableData *bytes = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i < hex.length; i += 2) {
        int high = ApolloGQLHexValue([hex characterAtIndex:i]), low = ApolloGQLHexValue([hex characterAtIndex:i + 1]);
        if (high < 0 || low < 0) return nil;
        uint8_t byte = (uint8_t)(high << 4 | low);
        [bytes appendBytes:&byte length:1];
    }
    NSString *text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    NSRange colon = [text rangeOfString:@":"];
    if (!text || colon.location == NSNotFound || colon.location == 0 || colon.location + 1 >= text.length) return nil;
    if (depth) *depth = MAX(0, [[text substringToIndex:colon.location] integerValue]);
    return [text substringFromIndex:colon.location + 1];
}

// A comment's Markdown the way the legacy API sends it: an image the comment
// embeds ("![img](<media id>)") is its URL. A Giphy embed stays as typed.
static NSString *ApolloGQLLegacyCommentBody(NSString *markdown, NSArray *media) {
    if ([markdown rangeOfString:@"]("].location == NSNotFound) return markdown;
    NSMutableString *body = [markdown mutableCopy];
    for (id asset in media) {
        NSString *mediaID = ApolloGQLString(asset, @"id"), *url = ApolloGQLString(asset, @"url");
        if (mediaID.length == 0 || url.length == 0 || [mediaID hasPrefix:@"giphy|"]) continue;
        for (NSString *kind in @[ @"img", @"gif", @"video" ]) {
            [body replaceOccurrencesOfString:[NSString stringWithFormat:@"![%@](%@)", kind, mediaID] withString:url
                                     options:NSLiteralSearch range:NSMakeRange(0, body.length)];
        }
    }
    return body;
}

// The unescaped `data` of a t1 thing, without its replies. `fullname` is the
// comment's (a deleted comment's node doesn't say), `post` the answer's
// postInfoById (the thread's id and subreddit).
static NSMutableDictionary<NSString *, id> *ApolloGQLLegacyCommentData(NSDictionary *node, NSString *fullname, NSString *parentFullname,
                                                                       NSInteger depth, NSDictionary *post, NSString *subredditType,
                                                                       NSString *threadPermalink) {
    if (![fullname hasPrefix:@"t1_"] || fullname.length <= 3) return nil;
    NSDictionary *subreddit = ApolloGQLDict(post, @"subreddit");
    NSDictionary *author = ApolloGQLDict(node, @"authorInfo");
    NSDictionary *content = ApolloGQLDict(node, @"content");
    NSMutableDictionary<NSString *, id> *data = [NSMutableDictionary dictionary];

    // Identity and where it sits.
    data[@"id"] = [fullname substringFromIndex:3];
    data[@"name"] = fullname;
    data[@"parent_id"] = parentFullname;
    data[@"link_id"] = ApolloGQLString(post, @"id") ?: @"";
    data[@"depth"] = @(depth);
    // A deleted comment's node has no permalink; it is the thread's plus the id.
    data[@"permalink"] = ApolloGQLString(node, @"permalink")
        ?: (threadPermalink.length > 0 ? [NSString stringWithFormat:@"%@%@/", threadPermalink, data[@"id"]] : @"");
    NSString *subredditName = ApolloGQLString(subreddit, @"name") ?: @"";
    data[@"subreddit"] = subredditName;
    data[@"subreddit_id"] = ApolloGQLString(subreddit, @"id") ?: @"";
    data[@"subreddit_name_prefixed"] = ApolloGQLString(subreddit, @"prefixedName") ?: [@"r/" stringByAppendingString:subredditName];
    data[@"subreddit_type"] = subredditType;

    // Author. A deleted or removed comment, and one from a deleted account,
    // have no authorInfo. Apollo reads a deleted comment as author "[deleted]"
    // with the body "[deleted]", and a moderator's removal as "[removed]"
    // (-[RDKComment isDeleted], -isModeratorRemoved).
    NSString *authorName = ApolloGQLString(author, @"name");
    data[@"author"] = authorName.length > 0 ? authorName : @"[deleted]";
    NSString *authorID = ApolloGQLString(author, @"id");
    if (authorID.length > 0) data[@"author_fullname"] = authorID;
    data[@"author_is_blocked"] = @(ApolloGQLBool(author, @"isBlocked"));
    if (ApolloGQLBool(author, @"isCakeDayNow")) data[@"author_cakeday"] = @YES;
    data[@"author_premium"] = @NO;
    data[@"author_patreon_flair"] = @NO;
    data[@"is_submitter"] = @(ApolloGQLBool(node, @"isOP"));
    ApolloGQLAddLegacyFlair(data, @"author_flair", ApolloGQLDict(node, @"authorFlair"));

    // Text. Apollo draws the comment from the HTML; the Markdown is what it
    // edits, quotes and copies.
    NSArray *media = ApolloGQLArray(content, @"richtextMedia");
    NSString *markdown = ApolloGQLString(content, @"markdown");
    NSString *html = nil;
    if (markdown.length > 0) {
        html = ApolloGQLRichTextHTML(ApolloGQLString(content, @"richtext"), media, NO);
    } else {
        NSString *removedBy = ApolloGQLString(node, @"removedByCategory");
        BOOL removed = ApolloGQLBool(node, @"isRemoved") || (removedBy.length > 0 && ![removedBy isEqualToString:@"DELETED"]);
        markdown = removed ? @"[removed]" : (authorName.length > 0 ? @"" : @"[deleted]");
    }
    data[@"body"] = ApolloGQLLegacyCommentBody(markdown, media);
    data[@"body_html"] = html ?: ApolloGQLPlainTextHTML(markdown, NO) ?: @"<div class=\"md\"></div>";
    if (media.count > 0) {
        NSMutableDictionary<NSString *, NSDictionary *> *metadata = [NSMutableDictionary dictionary];
        for (id asset in media) {
            NSString *mediaID = ApolloGQLString(asset, @"id");
            if (mediaID.length > 0) metadata[mediaID] = ApolloGQLLegacyMediaMetadata(asset);
        }
        if (metadata.count > 0) data[@"media_metadata"] = metadata;
    }

    // Times, score and the account's own state.
    NSNumber *created = ApolloGQLEpoch(ApolloGQLString(node, @"createdAt")) ?: @0;
    data[@"created"] = created;
    data[@"created_utc"] = created;
    data[@"edited"] = ApolloGQLEpoch(ApolloGQLString(node, @"editedAt")) ?: (id)@NO;
    BOOL scoreHidden = ApolloGQLBool(node, @"isScoreHidden");
    long long score = ApolloGQLNumber(node, @"score") ? [ApolloGQLNumber(node, @"score") longLongValue] : 1;
    data[@"score"] = @(score);
    data[@"ups"] = @(score);
    data[@"downs"] = @0;
    data[@"score_hidden"] = @(scoreHidden);
    data[@"controversiality"] = @0;
    NSString *vote = ApolloGQLString(node, @"voteState");
    data[@"likes"] = [vote isEqualToString:@"UP"] ? (id)@YES : [vote isEqualToString:@"DOWN"] ? (id)@NO : [NSNull null];
    data[@"saved"] = @(ApolloGQLBool(node, @"isSaved"));

    // Flags.
    data[@"archived"] = @(ApolloGQLBool(node, @"isArchived"));
    data[@"locked"] = @(ApolloGQLBool(node, @"isLocked"));
    data[@"stickied"] = @(ApolloGQLBool(node, @"isStickied"));
    data[@"distinguished"] = ApolloGQLOrNull(ApolloGQLString(node, @"distinguishedAs").lowercaseString);
    BOOL collapsed = ApolloGQLBool(node, @"isInitiallyCollapsed");
    data[@"collapsed"] = @(collapsed);
    // "DELETED" for a deleted comment, as the legacy API has it.
    NSString *collapsedReason = ApolloGQLString(node, @"initiallyCollapsedReason")
        ?: (authorName.length == 0 ? ApolloGQLString(node, @"removedByCategory") : nil);
    data[@"collapsed_reason"] = [NSNull null];
    data[@"collapsed_reason_code"] = ApolloGQLOrNull(collapsed ? collapsedReason : nil);
    data[@"collapsed_because_crowd_control"] = [NSNull null];
    data[@"can_gild"] = @NO;
    data[@"can_mod_post"] = @NO;
    data[@"send_replies"] = @YES;
    data[@"no_follow"] = @NO;

    // Awards and moderation, as for a post: what an account that isn't a
    // moderator of the subreddit gets from the legacy API.
    data[@"all_awardings"] = @[];
    data[@"awarders"] = @[];
    data[@"gildings"] = @{};
    data[@"gilded"] = @0;
    data[@"total_awards_received"] = @0;
    data[@"treatment_tags"] = @[];
    data[@"user_reports"] = @[];
    data[@"mod_reports"] = @[];
    for (NSString *key in @[ @"approved_at_utc", @"approved_by", @"banned_at_utc", @"banned_by", @"mod_note", @"mod_reason_by",
                             @"mod_reason_title", @"num_reports", @"report_reasons", @"removal_reason", @"top_awarded_type",
                             @"associated_award", @"unrepliable_reason", @"comment_type" ]) {
        data[key] = [NSNull null];
    }
    return data;
}

// A comment's replies, or the comments under a post: a Listing without a count.
static NSDictionary *ApolloGQLLegacyCommentListing(NSArray *children) {
    return @{ @"kind": @"Listing",
              @"data": @{ @"after": [NSNull null], @"dist": [NSNull null], @"modhash": @"", @"geo_filter": @"",
                          @"children": children, @"before": [NSNull null] } };
}

// A deleted comment's fullname. Its node has no id; its replies, which follow it
// one level down, name it as their parent. nil when it has none in the answer
// (nothing hangs off it, so the row is left out).
static NSString *ApolloGQLDeletedCommentFullname(NSArray *rows, NSUInteger index) {
    NSInteger depth = [ApolloGQLNumber(rows[index], @"depth") integerValue];
    for (NSUInteger next = index + 1; next < rows.count; next++) {
        NSInteger nextDepth = [ApolloGQLNumber(rows[next], @"depth") integerValue];
        if (nextDepth <= depth) return nil;
        if (nextDepth == depth + 1) return ApolloGQLString(rows[next], @"parentId");
    }
    return nil;
}

// The things of a PostComments answer. GraphQL lists a thread's rows in reading
// order, each with its depth and its parent's id; a row is a comment or a
// "load more" marker (a cursor and a count). `nested` puts each comment's
// replies inside it (/comments/<id>.json); otherwise the list stays flat, every
// row pointing at its parent (/api/morechildren's `things`).
static NSArray<NSDictionary *> *ApolloGQLLegacyCommentThings(NSDictionary *answer, NSDictionary *link, NSInteger baseDepth,
                                                             BOOL nested, BOOL rawJSON) {
    NSDictionary *post = ApolloGQLDict(ApolloGQLDict(answer, @"data"), @"postInfoById");
    NSString *linkFullname = ApolloGQLString(post, @"id");
    NSArray *rows = ApolloGQLArray(ApolloGQLDict(post, @"commentForest"), @"trees");
    if (![linkFullname hasPrefix:@"t3_"] || !rows) return nil;
    NSString *subredditType = [link[@"subreddit_type"] isKindOfClass:[NSString class]] ? link[@"subreddit_type"] : @"public";
    // "/r/<sub>/comments/<id>/<slug>/": the post's permalink, or any comment's
    // without its own id.
    NSString *threadPermalink = [link[@"permalink"] isKindOfClass:[NSString class]] ? link[@"permalink"] : nil;
    for (NSUInteger index = 0; index < rows.count && threadPermalink.length == 0; index++) {
        NSString *permalink = ApolloGQLString(ApolloGQLDict(rows[index], @"node"), @"permalink");
        NSArray<NSString *> *parts = [permalink componentsSeparatedByString:@"/"];
        // "", "r", sub, "comments", id, slug, comment id, "".
        if (parts.count == 8) threadPermalink = [[[parts subarrayWithRange:NSMakeRange(0, 6)] componentsJoinedByString:@"/"] stringByAppendingString:@"/"];
    }

    NSMutableArray<NSDictionary *> *top = [NSMutableArray array], *flat = [NSMutableArray array];
    NSMutableArray<NSMutableDictionary *> *comments = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray *> *repliesOf = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < rows.count; index++) {
        id row = rows[index];
        NSDictionary *node = ApolloGQLDict(row, @"node"), *more = ApolloGQLDict(row, @"more");
        NSString *parent = ApolloGQLString(row, @"parentId");
        NSInteger depth = baseDepth + MAX(0, [ApolloGQLNumber(row, @"depth") integerValue]);
        NSDictionary *thing = nil;
        if (node) {
            NSString *fullname = ApolloGQLString(node, @"id") ?: ApolloGQLDeletedCommentFullname(rows, index);
            NSMutableDictionary *data = ApolloGQLLegacyCommentData(node, fullname, parent ?: linkFullname, depth, post, subredditType,
                                                                   threadPermalink);
            if (!data || repliesOf[data[@"name"]]) continue;
            repliesOf[data[@"name"]] = [NSMutableArray array];
            [comments addObject:data];
            thing = ApolloGQLLegacyThing(@"t1", data);
        } else if (more) {
            NSString *cursor = ApolloGQLString(more, @"cursor");
            if (cursor.length == 0) continue;
            NSString *token = ApolloGQLMoreToken(cursor, depth);
            // A row whose count Reddit didn't work out still has replies behind it.
            NSInteger count = MAX(1, [ApolloGQLNumber(more, @"count") integerValue]);
            thing = ApolloGQLLegacyThing(@"more", @{ @"count": @(count), @"name": [@"t1_" stringByAppendingString:token], @"id": token,
                                                     @"parent_id": parent ?: linkFullname, @"depth": @(depth), @"children": @[ token ] });
        } else {
            continue;
        }
        [flat addObject:thing];
        [(parent ? repliesOf[parent] : nil) ?: top addObject:thing];
    }
    for (NSMutableDictionary *data in comments) {
        NSArray *replies = repliesOf[data[@"name"]];
        data[@"replies"] = nested && replies.count > 0 ? (id)ApolloGQLLegacyCommentListing(replies) : @"";
    }
    NSArray<NSDictionary *> *things = nested ? top : flat;
    return rawJSON ? things : ApolloGQLEscapeLegacyValue(things);
}

NSArray *ApolloGQLLegacyCommentsPage(NSDictionary *answer, NSDictionary *linkThing, BOOL rawJSON) {
    NSDictionary *link = [linkThing[@"data"] isKindOfClass:[NSDictionary class]] ? linkThing[@"data"] : nil;
    NSArray<NSDictionary *> *comments = ApolloGQLLegacyCommentThings(answer, link, 0, YES, rawJSON);
    if (!comments || !link) return nil;
    return @[ ApolloGQLLegacyListing(@[ linkThing ], nil), ApolloGQLLegacyCommentListing(comments) ];
}

NSDictionary *ApolloGQLLegacyMoreChildren(NSDictionary *answer, NSInteger depth, BOOL rawJSON) {
    NSArray<NSDictionary *> *things = ApolloGQLLegacyCommentThings(answer, nil, depth, NO, rawJSON);
    if (!things) return nil;
    return @{ @"json": @{ @"errors": @[], @"data": @{ @"things": things } } };
}

#pragma mark - Feeds

// The feed's connection ({edges, pageInfo}) wherever the query put it
// (data.subredditV3.elements for a subreddit, data.homeV3.elements for Home).
static NSDictionary *ApolloGQLFeedConnection(id node, NSUInteger depth) {
    if (![node isKindOfClass:[NSDictionary class]] || depth > 4) return nil;
    NSDictionary *dictionary = node;
    if ([dictionary[@"edges"] isKindOfClass:[NSArray class]] && dictionary[@"pageInfo"]) return dictionary;
    for (id key in dictionary) {
        NSDictionary *found = ApolloGQLFeedConnection(dictionary[key], depth + 1);
        if (found) return found;
    }
    return nil;
}

// Whether a feed row is a post Reddit suggests from a subreddit the account
// hasn't joined. Such a row says why it is there (a recommendation context that
// is shown) and offers a Join button; a joined subreddit's post has no context,
// or a hidden "subscribed…" one, and no button (37 suggested and 29 joined rows
// agreed on both, 2026-11-24).
static BOOL ApolloGQLFeedRowIsSuggested(NSDictionary *node) {
    NSDictionary *context = ApolloGQLDict(node, @"groupRecommendationContext");
    if (context && !ApolloGQLBool(context, @"isContextHidden") && ![ApolloGQLString(context, @"typeIdentifier") hasPrefix:@"subscribed"]) return YES;
    for (id cell in ApolloGQLArray(node, @"cells")) {
        if ([ApolloGQLString(cell, @"__typename") isEqualToString:@"MetadataCell"]) return ApolloGQLBool(cell, @"isJoinButtonShown");
    }
    return NO;
}

NSArray<NSString *> *ApolloGQLFeedPostFullnames(NSDictionary *answer, BOOL joinedOnly, NSString **nextAfter) {
    if (nextAfter) *nextAfter = nil;
    NSDictionary *connection = ApolloGQLFeedConnection(ApolloGQLDict(answer, @"data"), 0);
    if (!connection) return nil;
    NSMutableArray<NSString *> *fullnames = [NSMutableArray array];
    for (id edge in connection[@"edges"]) {
        NSDictionary *node = ApolloGQLDict(edge, @"node");
        NSString *group = ApolloGQLString(node, @"groupId");
        // An ad is a cell group with a post's id and an adPayload.
        if (![group hasPrefix:@"t3_"] || ApolloGQLValue(node, @"adPayload") != nil) continue;
        if (joinedOnly && ApolloGQLFeedRowIsSuggested(node)) continue;
        if (![fullnames containsObject:group]) [fullnames addObject:group];
    }
    NSDictionary *pageInfo = ApolloGQLDict(connection, @"pageInfo");
    NSNumber *hasNext = ApolloGQLNumber(pageInfo, @"hasNextPage");
    NSString *cursor = ApolloGQLString(pageInfo, @"endCursor");
    if (nextAfter && cursor.length > 0 && (!hasNext || hasNext.boolValue)) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:cursor options:0];
        NSString *fullname = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
        if ([fullname hasPrefix:@"t3_"]) *nextAfter = fullname;
    }
    return fullnames;
}

NSString *ApolloGQLFeedCursorForFullname(NSString *fullname) {
    if (![fullname isKindOfClass:[NSString class]] || fullname.length == 0) return nil;
    return [[fullname dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
}

NSString *ApolloGQLAnswerErrorMessage(id answer) {
    NSArray *errors = ApolloGQLArray(answer, @"errors");
    if (errors.count == 0) return nil;
    return ApolloGQLString(errors.firstObject, @"message") ?: @"unknown error";
}
