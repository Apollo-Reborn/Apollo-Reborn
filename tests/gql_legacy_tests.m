#import <Foundation/Foundation.h>
#import "ApolloGQLLegacy.h"
#import "ApolloGQLPlan.h"
#import "ApolloGQLRichText.h"

// The GraphQL route's Foundation-only half (src/graphql/): the request plan and
// the conversion of GraphQL answers into the legacy JSON Apollo asked for.
//
// tests/fixtures/graphql/posts.json holds ten posts captured through both
// routes for the same ids, one per kind of post: what PostsByIds answered, and
// the keys Apollo and the tweak read from what /api/info.json answered. Those
// keys are the ones Apollo's RedditKit maps for a link (the "data.<key>"
// strings in the 1.15.11 binary) plus the media, flair and gallery keys the
// tweak's own readers of listing JSON use.

static int sFailures = 0;

#define CHECK(cond, ...) do { \
    if (!(cond)) { sFailures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [NSString stringWithFormat:__VA_ARGS__].UTF8String); } \
} while (0)

static id ParseJSON(NSString *json) {
    return [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}

#pragma mark - Posts against the legacy answer

// Where the two routes legitimately differ, by the path of the value:
// - image URLs are signed per route, so URLs compare without their query;
// - a gallery image's full-size URL is i.redd.it on GraphQL and a signed
//   preview.redd.it one on the legacy route (same file);
// - the legacy API crops some preview sizes to another height;
// - an embed's thumbnail is Reddit's copy instead of the provider's, and its
//   iframe lacks the legacy "enablejsapi=1";
// - GraphQL has no vote total for a poll the account hasn't voted in.
static BOOL PathIsExempt(NSString *path, NSString *kind) {
    if ([path hasSuffix:@".s.u"]) return YES;
    if ([path hasSuffix:@"resolutions[].height"] || [path hasSuffix:@".p[].y"]) return YES;
    if ([path containsString:@"oembed.thumbnail_"]) return YES;
    if ([path hasSuffix:@"poll_data.total_vote_count"] && [kind isEqualToString:@"poll-open"]) return YES;
    return NO;
}

static id Loosened(id value, NSString *path) {
    if (![value isKindOfClass:[NSString class]]) return value;
    NSString *text = value;
    if ([path hasSuffix:@"oembed.html"] || [path hasSuffix:@"embed.content"]) {
        text = [text stringByReplacingOccurrencesOfString:@"&amp;enablejsapi=1" withString:@""];
        return [text stringByReplacingOccurrencesOfString:@"&enablejsapi=1" withString:@""];
    }
    if ([text hasPrefix:@"http"] && ![path hasSuffix:@".url_overridden_by_dest"] && ![path isEqualToString:@"url"]) {
        NSRange query = [text rangeOfString:@"?"];
        if (query.location != NSNotFound) return [text substringToIndex:query.location];
    }
    return text;
}

static void ComparePost(NSDictionary *ours, NSDictionary *legacy, NSString *prefix, NSString *kind, NSMutableArray<NSString *> *differences);

static void Compare(id ours, id theirs, NSString *path, NSString *kind, NSMutableArray<NSString *> *differences) {
    if (PathIsExempt(path, kind)) return;
    // The post a crosspost shares is a post of its own, with the same keys kept.
    if ([path hasSuffix:@"crosspost_parent_list[]"] && [ours isKindOfClass:[NSDictionary class]] && [theirs isKindOfClass:[NSDictionary class]]) {
        ComparePost(ours, theirs, [path stringByAppendingString:@"."], kind, differences);
        return;
    }
    if ([ours isKindOfClass:[NSDictionary class]] && [theirs isKindOfClass:[NSDictionary class]]) {
        NSMutableSet *keys = [NSMutableSet setWithArray:[ours allKeys]];
        [keys addObjectsFromArray:[theirs allKeys]];
        for (NSString *key in [keys.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *child = [path stringByAppendingFormat:@".%@", key];
            // A gallery's metadata is keyed by media id.
            NSString *reported = [path hasSuffix:@"media_metadata"] ? [path stringByAppendingString:@".*"] : child;
            if (PathIsExempt(reported, kind)) continue;
            if (!ours[key]) [differences addObject:[NSString stringWithFormat:@"%@ is missing (legacy: %@)", child, theirs[key]]];
            else if (!theirs[key]) [differences addObject:[NSString stringWithFormat:@"%@ isn't in the legacy answer (ours: %@)", child, ours[key]]];
            else Compare(ours[key], theirs[key], reported, kind, differences);
        }
        return;
    }
    if ([ours isKindOfClass:[NSArray class]] && [theirs isKindOfClass:[NSArray class]]) {
        if ([ours count] != [theirs count]) {
            [differences addObject:[NSString stringWithFormat:@"%@ has %lu items, legacy %lu", path, (unsigned long)[ours count], (unsigned long)[theirs count]]];
            return;
        }
        for (NSUInteger i = 0; i < [ours count]; i++) Compare(ours[i], theirs[i], [path stringByAppendingString:@"[]"], kind, differences);
        return;
    }
    id a = Loosened(ours, path), b = Loosened(theirs, path);
    BOOL same = [a isKindOfClass:[NSNumber class]] && [b isKindOfClass:[NSNumber class]]
        ? fabs([a doubleValue] - [b doubleValue]) < 0.0001 : [a isEqual:b];
    if (!same) [differences addObject:[NSString stringWithFormat:@"%@: ours %@, legacy %@", path, a, b]];
}

// Every key the fixture kept from the legacy answer, against ours.
static void ComparePost(NSDictionary *ours, NSDictionary *legacy, NSString *prefix, NSString *kind, NSMutableArray<NSString *> *differences) {
    for (NSString *key in [legacy.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id theirs = legacy[key];
        // Whether a post without flair reports these as "" / "dark" or as null
        // varies by subreddit, and nothing reads them without a flair.
        if (theirs == [NSNull null] && ([key isEqualToString:@"link_flair_background_color"] || [key isEqualToString:@"link_flair_text_color"])) continue;
        NSString *path = [prefix stringByAppendingString:key];
        if (!ours[key]) { [differences addObject:[path stringByAppendingString:@" is missing"]]; continue; }
        Compare(ours[key], theirs, path, kind, differences);
    }
}

static void TestPostsAgainstLegacy(NSString *repoRoot) {
    NSData *data = [NSData dataWithContentsOfFile:[repoRoot stringByAppendingPathComponent:@"tests/fixtures/graphql/posts.json"]];
    NSDictionary *fixture = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSArray *posts = fixture[@"posts"];
    CHECK(posts.count == 10, @"fixture has its ten posts (%lu)", (unsigned long)posts.count);
    NSMutableSet<NSString *> *kinds = [NSMutableSet set];
    for (NSDictionary *post in posts) {
        NSString *kind = post[@"kind"];
        [kinds addObject:kind];
        NSDictionary *legacy = post[@"legacy"];
        NSDictionary *ours = ApolloGQLLegacyLinkData(post[@"graphql"], [post[@"raw_json"] boolValue]);
        CHECK(ours != nil, @"%@ renders", kind);
        NSMutableArray<NSString *> *differences = [NSMutableArray array];
        ComparePost(ours, legacy, @"", kind, differences);
        CHECK(differences.count == 0, @"%@ post differs from the legacy answer:\n  %@", kind, [differences componentsJoinedByString:@"\n  "]);
    }
    NSSet *expected = [NSSet setWithArray:@[ @"image", @"gallery", @"video", @"embed", @"link", @"self", @"gif", @"poll", @"poll-open", @"crosspost" ]];
    CHECK([kinds isEqualToSet:expected], @"every kind of post is covered (%@)", kinds);
}

#pragma mark - Post details

static NSDictionary *MinimalPost(NSDictionary *overrides) {
    NSMutableDictionary *post = [@{
        @"id": @"t3_abc123", @"postTitle": @"Cats & <dogs>", @"permalink": @"/r/test/comments/abc123/cats/",
        @"url": @"https://example.com/a?x=1&y=2", @"domain": @"example.com", @"isSelfPost": @NO,
        @"createdAt": @"2026-11-23T16:30:35.456000+0000", @"score": @12, @"upvoteRatio": @0.8311688311688312,
        @"voteState": @"NONE", @"commentCount": @3,
        @"subreddit": @{ @"id": @"t5_x", @"name": @"test", @"prefixedName": @"r/test", @"type": @"PUBLIC", @"subscribersCount": @1234.0 },
        @"authorInfo": @{ @"id": @"t2_u", @"name": @"someone" },
    } mutableCopy];
    [post addEntriesFromDictionary:overrides ?: @{}];
    return post;
}

static void TestPostBasics(void) {
    NSDictionary *escaped = ApolloGQLLegacyLinkData(MinimalPost(nil), NO);
    NSDictionary *raw = ApolloGQLLegacyLinkData(MinimalPost(nil), YES);
    CHECK([escaped[@"title"] isEqualToString:@"Cats &amp; &lt;dogs&gt;"], @"escaped like the legacy API without raw_json (%@)", escaped[@"title"]);
    CHECK([raw[@"title"] isEqualToString:@"Cats & <dogs>"], @"raw_json=1 leaves it");
    CHECK([escaped[@"url"] isEqualToString:@"https://example.com/a?x=1&amp;y=2"], @"URLs are escaped too (%@)", escaped[@"url"]);
    CHECK([raw[@"id"] isEqualToString:@"abc123"] && [raw[@"name"] isEqualToString:@"t3_abc123"], @"id and fullname");
    CHECK([raw[@"created_utc"] doubleValue] == 1795451435.0, @"created_utc in whole seconds (%@)", raw[@"created_utc"]);
    CHECK([raw[@"edited"] isEqual:@NO] && raw[@"likes"] == [NSNull null], @"unedited, no vote");
    CHECK([raw[@"upvote_ratio"] doubleValue] == 0.83, @"ratio rounded like the legacy API (%@)", raw[@"upvote_ratio"]);
    CHECK([raw[@"thumbnail"] isEqualToString:@"default"] && raw[@"post_hint"] == nil, @"a link without a preview");
    CHECK([raw[@"subreddit_type"] isEqualToString:@"public"] && [raw[@"subreddit_subscribers"] isEqual:@1234], @"subreddit");
    CHECK([raw[@"selftext"] isEqualToString:@""] && raw[@"selftext_html"] == [NSNull null], @"no body");

    NSDictionary *voted = ApolloGQLLegacyLinkData(MinimalPost(@{ @"voteState": @"UP", @"editedAt": @"2026-11-23T17:00:00.000000+0000",
        @"distinguishedAs": @"MODERATOR", @"suggestedCommentSort": @"QA", @"removedByCategory": @"MODERATOR", @"isSaved": @YES }), YES);
    CHECK([voted[@"likes"] isEqual:@YES] && [voted[@"edited"] doubleValue] == 1795453200.0, @"upvoted and edited (%@)", voted[@"edited"]);
    CHECK([voted[@"distinguished"] isEqualToString:@"moderator"] && [voted[@"suggested_sort"] isEqualToString:@"qa"], @"lowercased enums");
    CHECK([voted[@"removed_by_category"] isEqualToString:@"moderator"] && [voted[@"saved"] isEqual:@YES], @"removed and saved");
    NSDictionary *down = ApolloGQLLegacyLinkData(MinimalPost(@{ @"voteState": @"DOWN", @"suggestedCommentSort": @"BLANK" }), YES);
    CHECK([down[@"likes"] isEqual:@NO] && down[@"suggested_sort"] == [NSNull null], @"downvoted, no suggested sort");

    NSMutableDictionary *deleted = [MinimalPost(nil) mutableCopy];
    deleted[@"authorInfo"] = [NSNull null];
    NSDictionary *byNobody = ApolloGQLLegacyLinkData(deleted, YES);
    CHECK([byNobody[@"author"] isEqualToString:@"[deleted]"] && byNobody[@"author_fullname"] == nil, @"a deleted account");

    CHECK(ApolloGQLLegacyLinkData(@{ @"postTitle": @"no id" }, YES) == nil, @"no id, no post");
    CHECK(ApolloGQLLegacyLinkData(@{ @"id": @"t1_comment" }, YES) == nil, @"not a post");
}

// The legacy fallback_url isn't in GraphQL's answer. It's the top rendition
// next to the scrubber file, named by its short side.
static void TestVideoFallback(void) {
    NSDictionary *(^video)(NSString *, NSArray *, NSNumber *, NSNumber *) = ^(NSString *scrubber, NSArray *shortSides, NSNumber *width, NSNumber *height) {
        NSMutableArray *permutations = [NSMutableArray array];
        for (NSNumber *side in shortSides) {
            [permutations addObject:@{ @"source": @{ @"dimensions": @{ @"width": side, @"height": @(side.integerValue * 2) } } }];
        }
        NSDictionary *media = @{ @"typeHint": @"VIDEO",
            @"streaming": @{ @"hlsUrl": @"https://v.redd.it/vid1/HLSPlaylist.m3u8?a=1", @"dashUrl": @"https://v.redd.it/vid1/DASHPlaylist.mpd?a=1",
                             @"scrubberMediaUrl": scrubber ?: [NSNull null], @"duration": @7, @"isGif": @NO,
                             @"dimensions": @{ @"width": width, @"height": height } },
            @"packagedMedia": permutations.count ? @{ @"playbackMp4s": @{ @"permutations": permutations } } : [NSNull null] };
        return ApolloGQLLegacyLinkData(MinimalPost(@{ @"media": media, @"domain": @"v.redd.it" }), YES)[@"media"][@"reddit_video"];
    };
    NSDictionary *portrait = video(@"https://v.redd.it/vid1/CMAF_96.mp4", @[ @220, @480, @1080 ], @1080, @1920);
    CHECK([portrait[@"fallback_url"] isEqualToString:@"https://v.redd.it/vid1/CMAF_1080.mp4?source=fallback"], @"portrait 1080 (%@)", portrait[@"fallback_url"]);
    CHECK([portrait[@"has_audio"] isEqual:@YES] && [portrait[@"is_gif"] isEqual:@NO] && [portrait[@"duration"] isEqual:@7], @"video facts");
    CHECK([portrait[@"hls_url"] hasPrefix:@"https://v.redd.it/vid1/HLSPlaylist.m3u8"], @"hls");
    NSDictionary *dash = video(@"https://v.redd.it/vid1/DASH_96.mp4", @[ @360, @720 ], @1280, @720);
    CHECK([dash[@"fallback_url"] isEqualToString:@"https://v.redd.it/vid1/DASH_720.mp4?source=fallback"], @"older DASH_ files (%@)", dash[@"fallback_url"]);
    NSDictionary *noRenditions = video(@"https://v.redd.it/vid1/CMAF_96.mp4", @[], @406, @720);
    CHECK([noRenditions[@"fallback_url"] isEqualToString:@"https://v.redd.it/vid1/CMAF_360.mp4?source=fallback"], @"short side snapped to the ladder (%@)", noRenditions[@"fallback_url"]);
    NSDictionary *noScrubber = video(nil, @[ @480 ], @480, @640);
    CHECK([noScrubber[@"fallback_url"] isEqualToString:@"https://v.redd.it/vid1/CMAF_480.mp4?source=fallback"], @"folder from the playlist (%@)", noScrubber[@"fallback_url"]);
}

#pragma mark - Listings and feeds

static void TestListingAndFeed(void) {
    NSDictionary *listing = ApolloGQLLegacyListing(@[ ApolloGQLLegacyThing(@"t3", @{ @"name": @"t3_a" }) ], @"t3_a");
    CHECK([listing[@"kind"] isEqualToString:@"Listing"] && [listing[@"data"][@"after"] isEqualToString:@"t3_a"], @"listing");
    CHECK([listing[@"data"][@"dist"] isEqual:@1] && listing[@"data"][@"before"] == [NSNull null], @"dist and before");
    CHECK([listing[@"data"][@"children"][0][@"kind"] isEqualToString:@"t3"], @"children are things");
    CHECK(ApolloGQLLegacyListing(@[], nil)[@"data"][@"after"] == [NSNull null], @"last page");
    CHECK([NSJSONSerialization isValidJSONObject:listing], @"serializes");

    // A feed answer: a sort bar, posts, an ad, a recommendations unit.
    NSDictionary *feed = ParseJSON(@"{\"data\":{\"subredditV3\":{\"elements\":{\"dist\":5,\"edges\":["
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"sortcell\",\"adPayload\":null}},"
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_one\",\"adPayload\":null}},"
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_ad\",\"adPayload\":{\"isBlank\":false}}},"
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_two\",\"adPayload\":null}},"
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_one\",\"adPayload\":null}},"
        "{\"node\":{\"__typename\":\"CarouselCommunityRecommendationsFeedUnit\"}}],"
        "\"pageInfo\":{\"endCursor\":\"dDNfdHdv\"}}}}}");
    NSString *after = @"unset";
    NSArray *ids = ApolloGQLFeedPostFullnames(feed, &after);
    CHECK([ids isEqualToArray:(@[ @"t3_one", @"t3_two" ])], @"posts only, once each (%@)", ids);
    CHECK([after isEqualToString:@"t3_two"], @"the cursor is the base64 of the last fullname (%@)", after);
    CHECK([ApolloGQLFeedCursorForFullname(@"t3_two") isEqualToString:@"dDNfdHdv"], @"and back");
    CHECK(ApolloGQLFeedCursorForFullname(nil) == nil && ApolloGQLFeedCursorForFullname(@"") == nil, @"no cursor for a first page");

    NSDictionary *last = ParseJSON(@"{\"data\":{\"subredditV3\":{\"elements\":{\"edges\":[],\"pageInfo\":{\"endCursor\":null}}}}}");
    CHECK([ApolloGQLFeedPostFullnames(last, &after) isEqualToArray:@[]] && after == nil, @"an empty last page");
    NSDictionary *done = ParseJSON(@"{\"data\":{\"subredditV3\":{\"elements\":{\"edges\":[],\"pageInfo\":{\"endCursor\":\"dDNfdHdv\",\"hasNextPage\":false}}}}}");
    ApolloGQLFeedPostFullnames(done, &after);
    CHECK(after == nil, @"hasNextPage false ends the feed");
    NSDictionary *opaque = ParseJSON(@"{\"data\":{\"subredditV3\":{\"elements\":{\"edges\":[],\"pageInfo\":{\"endCursor\":\"bm90IGEgZnVsbG5hbWU=\"}}}}}");
    ApolloGQLFeedPostFullnames(opaque, &after);
    CHECK(after == nil, @"a cursor that isn't a fullname can't become a legacy `after`");
    CHECK(ApolloGQLFeedPostFullnames(ParseJSON(@"{\"data\":{\"subredditV3\":null}}"), &after) == nil, @"no feed at all");
    CHECK(ApolloGQLFeedPostFullnames(@{}, NULL) == nil, @"no data");

    NSDictionary *answer = @{ @"data": @{ @"postsInfoByIds": @[ MinimalPost(@{ @"id": @"t3_b" }), [NSNull null], MinimalPost(@{ @"id": @"t3_a" }) ] } };
    NSArray *things = ApolloGQLLegacyLinksFromPostsByIds(answer, @[ @"t3_a", @"t3_missing", @"t3_b" ], YES);
    CHECK(things.count == 2 && [things[0][@"data"][@"name"] isEqualToString:@"t3_a"] && [things[1][@"data"][@"name"] isEqualToString:@"t3_b"],
          @"in the order asked for, without the ones Reddit didn't return");
    CHECK([things[0][@"kind"] isEqualToString:@"t3"], @"as t3 things");
    CHECK(ApolloGQLLegacyLinksFromPostsByIds(@{ @"data": @{} }, @[ @"t3_a" ], YES) == nil, @"not a PostsByIds answer");

    CHECK([ApolloGQLAnswerErrorMessage(ParseJSON(@"{\"errors\":[{\"message\":\"PersistedQueryNotFound\"}]}")) isEqualToString:@"PersistedQueryNotFound"], @"error message");
    CHECK(ApolloGQLAnswerErrorMessage(@{ @"data": @{} }) == nil && ApolloGQLAnswerErrorMessage(nil) == nil, @"no errors");
}

#pragma mark - Rich text

static void CheckHTML(NSString *documentJSON, NSString *expectedInner, NSString *what) {
    NSString *html = ApolloGQLRichTextHTML(documentJSON, nil, NO);
    NSString *expected = [NSString stringWithFormat:@"<div class=\"md\">%@\n</div>", expectedInner];
    CHECK([html isEqualToString:expected], @"%@:\n  got  %@\n  want %@", what, html, expected);
}

// The HTML follows what Reddit's Markdown renderer emits; the paragraph, link
// and emphasis forms here matched Reddit's own selftext_html byte for byte on
// the 13 captured self posts (apart from a trailing space Reddit keeps).
static void TestRichText(void) {
    CheckHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"One.\"}]},{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"Two.\"}]}]}",
              @"<p>One.</p>\n\n<p>Two.</p>", @"paragraphs");
    CheckHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"a bold italic code x\",\"f\":[[1,2,4],[2,7,6],[64,14,4]]}]}]}",
              @"<p>a <strong>bold</strong> <em>italic</em> <code>code</code> x</p>", @"format ranges");
    CheckHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"both struck up\",\"f\":[[3,0,4],[8,5,6],[32,12,2]]}]}]}",
              @"<p><strong><em>both</em></strong> <del>struck</del> <sup>up</sup></p>", @"combined and other marks");
    CheckHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"Tom & \\\"Jerry\\\" <3 it's\"}]}]}",
              @"<p>Tom &amp; &quot;Jerry&quot; &lt;3 it&#39;s</p>", @"escaping");
    CheckHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"link\",\"t\":\"a site\",\"u\":\"https://example.com/?a=1&b=2\"},{\"e\":\"text\",\"t\":\" \"},"
               "{\"e\":\"r/\",\"t\":\"apple\",\"l\":false},{\"e\":\"text\",\"t\":\" \"},{\"e\":\"u/\",\"t\":\"someone\",\"l\":true}]}]}",
              @"<p><a href=\"https://example.com/?a=1&amp;b=2\">a site</a> <a href=\"/r/apple\">r/apple</a> <a href=\"/u/someone\">/u/someone</a></p>",
              @"links, subreddits and users");
    CheckHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"spoilertext\",\"c\":[{\"e\":\"text\",\"t\":\"secret\"}]},{\"e\":\"br\"},{\"e\":\"text\",\"t\":\"next\"}]}]}",
              @"<p><span class=\"md-spoiler-text\">secret</span><br/>\nnext</p>", @"spoiler and line break");
    CheckHTML(@"{\"document\":[{\"e\":\"h\",\"l\":2,\"c\":[{\"e\":\"raw\",\"t\":\"Title\"}]},{\"e\":\"hr\"},"
               "{\"e\":\"blockquote\",\"c\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"quoted\"}]}]}]}",
              @"<h2>Title</h2>\n\n<hr/>\n\n<blockquote>\n<p>quoted</p>\n</blockquote>", @"heading, rule, quote");
    CheckHTML(@"{\"document\":[{\"e\":\"list\",\"o\":false,\"c\":[{\"e\":\"li\",\"c\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"one\"}]}]},"
               "{\"e\":\"li\",\"c\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"two\"}]},{\"e\":\"list\",\"o\":true,\"c\":[{\"e\":\"li\",\"c\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"inner\"}]}]}]}]}]}]}",
              @"<ul>\n<li>one</li>\n<li>two\n\n<ol>\n<li>inner</li>\n</ol></li>\n</ul>", @"lists");
    CheckHTML(@"{\"document\":[{\"e\":\"code\",\"c\":[{\"e\":\"raw\",\"t\":\"if (a < b) {\"},{\"e\":\"raw\",\"t\":\"}\"}]}]}",
              @"<pre><code>if (a &lt; b) {\n}\n</code></pre>", @"code block");
    CheckHTML(@"{\"document\":[{\"e\":\"table\",\"h\":[{\"a\":\"L\",\"c\":[{\"e\":\"text\",\"t\":\"A\"}]},{\"a\":\"C\",\"c\":[{\"e\":\"text\",\"t\":\"B\"}]}],"
               "\"c\":[[{\"c\":[{\"e\":\"text\",\"t\":\"1\"}]},{\"c\":[{\"e\":\"text\",\"t\":\"2\"}]}]]}]}",
              @"<table><thead>\n<tr>\n<th align=\"left\">A</th>\n<th align=\"center\">B</th>\n</tr>\n</thead><tbody>\n<tr>\n<td align=\"left\">1</td>\n<td align=\"center\">2</td>\n</tr>\n</tbody></table>",
              @"table");
    // Ranges that overlap or run past the text are clipped, not thrown on.
    CheckHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"abcdef\",\"f\":[[1,0,4],[2,2,3],[1,4,99],[1,50,2],[\"x\",0,1]]}]}]}",
              @"<p><strong>abcd</strong><em>e</em><strong>f</strong></p>", @"malformed ranges");
    // Something this list doesn't know: its children, or its text.
    CheckHTML(@"{\"document\":[{\"e\":\"newblock\",\"c\":[{\"e\":\"par\",\"c\":[{\"e\":\"newinline\",\"t\":\"kept\"}]}]}]}", @"<p>kept</p>", @"unknown elements");

    NSArray *media = @[ @{ @"id": @"img1", @"url": @"https://i.redd.it/img1.png" } ];
    NSString *image = ApolloGQLRichTextHTML(@"{\"document\":[{\"e\":\"img\",\"id\":\"img1\",\"c\":\"A caption\"},{\"e\":\"gif\",\"id\":\"giphy|XYZ|downsized\"},{\"e\":\"img\",\"id\":\"gone\"}]}", media, NO);
    CHECK([image isEqualToString:@"<div class=\"md\"><p><a href=\"https://i.redd.it/img1.png\">https://i.redd.it/img1.png</a></p>\n\n<p>A caption</p>\n\n"
           "<p><a href=\"https://giphy.com/gifs/XYZ\">https://giphy.com/gifs/XYZ</a></p>\n</div>"], @"embedded media become links (%@)", image);

    NSString *selfPost = ApolloGQLRichTextHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"text\",\"t\":\"Hi\"}]}]}", nil, YES);
    CHECK([selfPost isEqualToString:@"<!-- SC_OFF --><div class=\"md\"><p>Hi</p>\n</div><!-- SC_ON -->"], @"a post's body has Reddit's markers (%@)", selfPost);
    CHECK(ApolloGQLRichTextHTML(@"not json", nil, NO) == nil && ApolloGQLRichTextHTML(nil, nil, NO) == nil, @"unreadable document");
    CHECK(ApolloGQLRichTextHTML(@"{\"document\":[]}", nil, NO) == nil && ApolloGQLRichTextHTML(@"[1,2]", nil, NO) == nil, @"empty or wrong shape");
    NSString *plain = ApolloGQLPlainTextHTML(@"One *line*\nsame paragraph\n\n\nTwo & <b>", NO);
    CHECK([plain isEqualToString:@"<div class=\"md\"><p>One *line*<br/>\nsame paragraph</p>\n\n<p>Two &amp; &lt;b&gt;</p>\n</div>"], @"plain fallback (%@)", plain);
    CHECK(ApolloGQLPlainTextHTML(@"  \n\n ", NO) == nil && ApolloGQLPlainTextHTML(nil, NO) == nil, @"nothing to show");
}

#pragma mark - Plan

static void TestPlan(void) {
    // /api/info for posts.
    ApolloGQLRequest *info = ApolloGQLRequestForLegacy(@"GET", @"api/info.json", @{ @"id": @"t3_a,t3_b, t3_a", @"raw_json": @1 });
    CHECK(info.kind == ApolloGQLRequestKindPostsInfo && [info.fullnames isEqualToArray:(@[ @"t3_a", @"t3_b" ])], @"post ids, once each (%@)", info.fullnames);
    CHECK(info.rawJSON, @"raw_json carried");
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"/api/info/.json?id=t3_q", nil).fullnames isEqualToArray:@[ @"t3_q" ]], @"ids from the path's query");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"api/info.json", @{ @"id": @"t3_a,t1_b" }) == nil, @"comments aren't answered");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"api/info.json", @{ @"id": @"t5_2qh1f" }) == nil, @"nor subreddits");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"api/info.json", @{ @"url": @"https://example.com" }) == nil, @"nor lookups by URL");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"api/info.json", @{}) == nil, @"nothing asked");
    NSMutableArray *many = [NSMutableArray array];
    for (int i = 0; i < 101; i++) [many addObject:[NSString stringWithFormat:@"t3_%d", i]];
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"api/info.json", @{ @"id": [many componentsJoinedByString:@","] }) == nil, @"more than Reddit's 100");
    CHECK(ApolloGQLRequestForLegacy(@"POST", @"api/info.json", @{ @"id": @"t3_a" }) == nil, @"reads only");

    // Subreddit feeds.
    ApolloGQLRequest *hot = ApolloGQLRequestForLegacy(@"GET", @"r/Apple/hot.json", @{ @"limit": @"25", @"api_type": @"json" });
    CHECK(hot.kind == ApolloGQLRequestKindSubredditFeed && [hot.subreddit isEqualToString:@"Apple"] && [hot.sort isEqualToString:@"HOT"],
          @"hot (%@ %@)", hot.subreddit, hot.sort);
    CHECK(hot.timeRange == nil && hot.after == nil && hot.limit == 25 && !hot.rawJSON, @"hot has no range");
    ApolloGQLRequest *top = ApolloGQLRequestForLegacy(@"GET", @"/r/apple/top/.json?t=WEEK", @{ @"after": @"t3_last", @"limit": @500 });
    CHECK([top.sort isEqualToString:@"TOP"] && [top.timeRange isEqualToString:@"WEEK"] && [top.after isEqualToString:@"t3_last"] && top.limit == 100,
          @"top of the week, next page (%@ %@ %@ %ld)", top.sort, top.timeRange, top.after, (long)top.limit);
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"r/apple/controversial", nil).timeRange isEqualToString:@"DAY"], @"Reddit's default range");
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"r/apple", nil).sort isEqualToString:@"HOT"], @"a bare subreddit is hot");
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"r/apple/.json", nil).sort isEqualToString:@"HOT"], @"with RedditKit's /.json");
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"r/apple/new", nil).sort isEqualToString:@"NEW"] &&
          [ApolloGQLRequestForLegacy(@"GET", @"r/apple/rising", nil).sort isEqualToString:@"RISING"] &&
          [ApolloGQLRequestForLegacy(@"GET", @"r/apple/best", nil).sort isEqualToString:@"BEST"], @"the other sorts");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"r/apple/hot", @{ @"before": @"t3_x" }) == nil, @"no backwards paging");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"r/apple/hot", @{ @"after": @"t1_x" }) == nil, @"only a post can be a feed cursor");
    for (NSString *path in @[ @"r/all/hot", @"r/popular", @"r/mod/new", @"r/friends", @"r/random", @"r/apple+ios/hot", @"r/all-apple/hot",
                              @"r/u_someone/hot", @"r/apple/about", @"r/apple/comments/abc", @"r/apple/search", @"hot", @"best", @"user/x/submitted",
                              @"r/apple/wiki/index", @"r/a/hot" ]) {
        CHECK(ApolloGQLRequestForLegacy(@"GET", path, nil) == nil, @"%@ isn't a single subreddit's feed", path);
        CHECK(!ApolloGQLCanAnswerPath(@"GET", path), @"%@ by path", path);
    }
    CHECK(ApolloGQLCanAnswerPath(@"GET", @"/r/apple/hot.json") && ApolloGQLCanAnswerPath(@"get", @"api/info.json?id=t1_x"), @"by path alone");
    CHECK(!ApolloGQLCanAnswerPath(@"POST", @"/r/apple/hot.json") && !ApolloGQLCanAnswerPath(@"GET", @"api/morechildren"), @"not these");

    // Operations.
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:ApolloGQLOperationBody(ApolloGQLOperationPostsByIds, ApolloGQLPostsByIdsVariables(@[ @"t3_a" ])) options:0 error:NULL];
    CHECK([body[@"operationName"] isEqualToString:@"PostsByIds"] && [body[@"variables"][@"ids"] isEqualToArray:@[ @"t3_a" ]], @"body");
    NSString *hash = body[@"extensions"][@"persistedQuery"][@"sha256Hash"];
    CHECK(hash.length == 64 && [body[@"extensions"][@"persistedQuery"][@"version"] isEqual:@1] && body[@"query"] == nil, @"a persisted query, no query text");
    CHECK(ApolloGQLOperationBody(@"NotAnOperation", @{}) == nil && ApolloGQLOperationHash(@"NotAnOperation") == nil, @"unknown operation");
    NSDictionary *first = ApolloGQLSubredditFeedVariables(hot, nil), *next = ApolloGQLSubredditFeedVariables(top, top.after);
    CHECK([first isEqualToDictionary:(@{ @"subredditName": @"Apple", @"sort": @"HOT" })], @"first page variables (%@)", first);
    CHECK([next isEqualToDictionary:(@{ @"subredditName": @"apple", @"sort": @"TOP", @"time": @"WEEK", @"after": @"dDNfbGFzdA==" })], @"next page variables (%@)", next);
    CHECK(ApolloGQLPostsByIdsBatch == 30, @"batch size");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: gql_legacy_tests <repo root>\n"); return 2; }
        TestPostsAgainstLegacy(@(argv[1]));
        TestPostBasics();
        TestVideoFallback();
        TestListingAndFeed();
        TestRichText();
        TestPlan();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("gql legacy tests passed\n");
    return 0;
}
