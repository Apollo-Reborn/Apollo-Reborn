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
//
// tests/fixtures/graphql/comments.json holds two threads the same way: rows of
// what PostComments answered, and the legacy /comments/<id>.json data of the
// same comments.

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
    // Comments:
    // - the legacy API no longer describes a Giphy embed ("status": "invalid");
    //   GraphQL has the GIF itself;
    // - a deleted comment's score isn't in the GraphQL answer.
    if ([kind isEqualToString:@"giphy"] && [path hasPrefix:@"media_metadata"]) return YES;
    if ([kind isEqualToString:@"deleted"] && ([path isEqualToString:@"score"] || [path isEqualToString:@"ups"])) return YES;
    return NO;
}

static id Loosened(id value, NSString *path) {
    if (![value isKindOfClass:[NSString class]]) return value;
    NSString *text = value;
    // An image a comment embeds is the file's own i.redd.it address on GraphQL
    // and a signed preview.redd.it one on the legacy route (same file).
    if ([path isEqualToString:@"body"] || [path isEqualToString:@"body_html"]) {
        NSRegularExpression *preview = [NSRegularExpression regularExpressionWithPattern:@"https://preview\\.redd\\.it/([A-Za-z0-9]+\\.[a-z]+)\\?[^\\s\"<]*"
                                                                                 options:0 error:NULL];
        return [preview stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"https://i.redd.it/$1"];
    }
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

#pragma mark - Comments against the legacy answer

// Every comment under `things`, by fullname, and the "load more" rows.
static void FlattenComments(NSArray *things, NSMutableDictionary<NSString *, NSDictionary *> *comments, NSMutableArray<NSDictionary *> *mores) {
    for (NSDictionary *thing in things) {
        if ([thing[@"kind"] isEqualToString:@"more"]) { [mores addObject:thing[@"data"]]; continue; }
        comments[thing[@"data"][@"name"]] = thing[@"data"];
        id replies = thing[@"data"][@"replies"];
        if ([replies isKindOfClass:[NSDictionary class]]) FlattenComments(replies[@"data"][@"children"], comments, mores);
    }
}

// "t1_a(t1_b(t1_c) more) t1_d": a thread's shape.
static NSString *CommentShape(NSArray *things) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *thing in things) {
        if ([thing[@"kind"] isEqualToString:@"more"]) { [parts addObject:@"more"]; continue; }
        id replies = thing[@"data"][@"replies"];
        [parts addObject:[replies isKindOfClass:[NSDictionary class]]
            ? [NSString stringWithFormat:@"%@(%@)", thing[@"data"][@"name"], CommentShape(replies[@"data"][@"children"])]
            : thing[@"data"][@"name"]];
    }
    return [parts componentsJoinedByString:@" "];
}

static NSArray<NSDictionary *> *CommentsFixtureThreads(NSString *repoRoot) {
    NSData *data = [NSData dataWithContentsOfFile:[repoRoot stringByAppendingPathComponent:@"tests/fixtures/graphql/comments.json"]];
    NSDictionary *fixture = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return fixture[@"threads"];
}

static void TestCommentsAgainstLegacy(NSString *repoRoot) {
    NSArray<NSDictionary *> *threads = CommentsFixtureThreads(repoRoot);
    CHECK(threads.count == 2, @"fixture has its two threads (%lu)", (unsigned long)threads.count);
    NSMutableSet<NSString *> *kinds = [NSMutableSet set];
    for (NSDictionary *thread in threads) {
        NSString *name = thread[@"thread"];
        NSDictionary *linkThing = ApolloGQLLegacyThing(@"t3", thread[@"link"]);
        NSArray *page = ApolloGQLLegacyCommentsPage(thread[@"graphql"], linkThing, YES);
        CHECK(page.count == 2, @"%@: a post listing and a comment listing", name);
        if (page.count != 2) continue;
        CHECK([page[0][@"data"][@"children"] isEqualToArray:@[ linkThing ]] && [page[0][@"data"][@"dist"] isEqual:@1], @"%@: the post comes first", name);
        CHECK([page[1][@"kind"] isEqualToString:@"Listing"] && page[1][@"data"][@"after"] == [NSNull null], @"%@: comments are a Listing", name);
        NSMutableDictionary<NSString *, NSDictionary *> *ours = [NSMutableDictionary dictionary];
        NSMutableArray<NSDictionary *> *mores = [NSMutableArray array];
        FlattenComments(page[1][@"data"][@"children"], ours, mores);
        NSDictionary<NSString *, NSDictionary *> *legacy = thread[@"legacy"];
        CHECK(ours.count == legacy.count, @"%@: every comment once (%lu, legacy %lu)", name, (unsigned long)ours.count, (unsigned long)legacy.count);
        for (NSString *fullname in [legacy.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *kind = thread[@"kinds"][fullname] ?: @"plain";
            [kinds addObject:kind];
            NSDictionary *comment = ours[fullname];
            CHECK(comment != nil, @"%@: %@ (%@) is in the thread", name, fullname, kind);
            if (!comment) continue;
            NSMutableArray<NSString *> *differences = [NSMutableArray array];
            for (NSString *key in [legacy[fullname].allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                // A flair that is only a CSS class (old Reddit's) isn't in
                // GraphQL; the legacy API gives it colours but no text, and
                // nothing reads the colours of a flair without text.
                if (legacy[fullname][@"author_flair_text"] == [NSNull null] &&
                    ([key isEqualToString:@"author_flair_background_color"] || [key isEqualToString:@"author_flair_text_color"])) continue;
                if (!comment[key]) { [differences addObject:[key stringByAppendingString:@" is missing"]]; continue; }
                Compare(comment[key], legacy[fullname][key], key, kind, differences);
            }
            CHECK(differences.count == 0, @"%@: the %@ comment %@ differs from the legacy answer:\n  %@", name, kind, fullname,
                  [differences componentsJoinedByString:@"\n  "]);
        }
    }
    NSSet *expected = [NSSet setWithArray:@[ @"plain", @"image", @"giphy", @"collapsed", @"score-hidden", @"op-reply", @"more", @"deleted", @"flair", @"edited" ]];
    CHECK([kinds isEqualToSet:expected], @"every kind of comment is covered (%@)", kinds);
}

static void TestCommentThreads(NSString *repoRoot) {
    NSArray<NSDictionary *> *threads = CommentsFixtureThreads(repoRoot);
    if (threads.count != 2) return;
    NSDictionary *pics = threads[0], *mega = threads[1];

    // Rows in reading order with a depth and a parent become nested replies.
    NSArray *page = ApolloGQLLegacyCommentsPage(pics[@"graphql"], ApolloGQLLegacyThing(@"t3", pics[@"link"]), YES);
    NSString *shape = CommentShape(page[1][@"data"][@"children"]);
    CHECK([shape isEqualToString:@"t1_19t36jz9s846c(t1_19t37auzy2omc(t1_19t37tecl8izk)) t1_19t431jhx1ezl t1_19t3awfe4ars2 "
           "t1_19t3ia29toizk(more) t1_19t36fnmizswy t1_19t37tjtiqcdg"], @"thread shape (%@)", shape);
    NSMutableDictionary<NSString *, NSDictionary *> *comments = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *mores = [NSMutableArray array];
    FlattenComments(page[1][@"data"][@"children"], comments, mores);
    CHECK([comments[@"t1_19t431jhx1ezl"][@"replies"] isEqual:@""], @"no replies is an empty string, as the legacy API has it");
    NSDictionary *replies = comments[@"t1_19t36jz9s846c"][@"replies"];
    CHECK([replies[@"kind"] isEqualToString:@"Listing"] && replies[@"data"][@"dist"] == [NSNull null], @"replies are a Listing without a count");
    CHECK([comments[@"t1_19t37tecl8izk"][@"parent_id"] isEqualToString:@"t1_19t37auzy2omc"] && [comments[@"t1_19t37tecl8izk"][@"depth"] isEqual:@2],
          @"a reply names its parent and depth");
    CHECK([comments[@"t1_19t36jz9s846c"][@"parent_id"] isEqualToString:@"t3_1y3u73f"] && [comments[@"t1_19t36jz9s846c"][@"link_id"] isEqualToString:@"t3_1y3u73f"],
          @"a top-level comment's parent is the post");
    CHECK([comments[@"t1_19t36jz9s846c"][@"subreddit_type"] isEqualToString:pics[@"link"][@"subreddit_type"]], @"the subreddit's type comes from the post");
    // An embedded image: its address in the Markdown, its sizes in media_metadata.
    NSDictionary *image = comments[@"t1_19t3awfe4ars2"];
    CHECK([image[@"body"] hasSuffix:@"\n\nhttps://i.redd.it/fwgjbaio1g3i1.jpeg"], @"image address in the body (%@)", image[@"body"]);
    CHECK([image[@"media_metadata"][@"fwgjbaio1g3i1"][@"s"][@"u"] isEqualToString:@"https://i.redd.it/fwgjbaio1g3i1.jpeg"] &&
          [image[@"media_metadata"][@"fwgjbaio1g3i1"][@"e"] isEqualToString:@"Image"], @"image metadata");
    // A Giphy embed stays as typed, links to its page, and has the GIF Apollo
    // plays inline (-[RDKComment inlineGiphyIDsToURLs] reads s.mp4, then s.gif).
    NSDictionary *giphy = comments[@"t1_19t37tjtiqcdg"];
    CHECK([giphy[@"body"] isEqualToString:@"![gif](giphy|W7KqOEzpG9iC9H58zc)"], @"giphy body (%@)", giphy[@"body"]);
    CHECK([giphy[@"body_html"] containsString:@"<a href=\"https://giphy.com/gifs/W7KqOEzpG9iC9H58zc\" target=\"_blank\">"], @"giphy link (%@)", giphy[@"body_html"]);
    CHECK([giphy[@"media_metadata"][@"giphy|W7KqOEzpG9iC9H58zc"][@"s"][@"gif"] hasPrefix:@"https://"], @"giphy GIF address");

    // A "load more" row: a legacy `more` thing whose one child id carries the
    // cursor and the row's depth.
    CHECK(mores.count == 1, @"one load-more row (%lu)", (unsigned long)mores.count);
    NSDictionary *more = mores.firstObject;
    NSString *token = [more[@"children"] firstObject];
    CHECK([more[@"count"] isEqual:@2] && [more[@"parent_id"] isEqualToString:@"t1_19t3ia29toizk"] && [more[@"depth"] isEqual:@1], @"more row (%@)", more);
    CHECK([more[@"children"] count] == 1 && [more[@"id"] isEqualToString:token] && [more[@"name"] isEqualToString:[@"t1_" stringByAppendingString:token]],
          @"its id, name and one child are the token");
    NSInteger depth = -1;
    NSString *cursor = ApolloGQLMoreTokenCursor(token, &depth);
    CHECK([cursor isEqualToString:@"commenttree:fixture1,::1:ex:,X;<b$\"N'v"] && depth == 1, @"the token gives the cursor back (%@, %ld)", cursor, (long)depth);
    NSCharacterSet *notID = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyz"] invertedSet];
    CHECK([token rangeOfCharacterFromSet:notID].location == NSNotFound, @"the token is made of a comment id's characters");

    // A deleted comment has no id in the answer; its reply names it. The
    // thread's last row loads more top-level comments.
    NSArray *megaPage = ApolloGQLLegacyCommentsPage(mega[@"graphql"], ApolloGQLLegacyThing(@"t3", mega[@"link"]), YES);
    NSString *megaShape = CommentShape(megaPage[1][@"data"][@"children"]);
    CHECK([megaShape isEqualToString:@"t1_19ss7cj2tvste(t1_19ss7jrolipwl(t1_19ss8gxzp1lls)) t1_19ss7h66alw9t t1_19ss8fv9tgdcx(t1_19ss8hjpxqvtw) more"],
          @"thread with a deleted comment (%@)", megaShape);
    [comments removeAllObjects];
    [mores removeAllObjects];
    FlattenComments(megaPage[1][@"data"][@"children"], comments, mores);
    NSDictionary *deleted = comments[@"t1_19ss7jrolipwl"];
    CHECK([deleted[@"author"] isEqualToString:@"[deleted]"] && [deleted[@"body"] isEqualToString:@"[deleted]"] && deleted[@"author_fullname"] == nil,
          @"what Apollo reads as a deleted comment (%@ / %@)", deleted[@"author"], deleted[@"body"]);
    CHECK([deleted[@"permalink"] isEqualToString:@"/r/apple/comments/1xyr1v3/post_title/19ss7jrolipwl/"], @"its permalink is the thread's plus its id (%@)", deleted[@"permalink"]);
    CHECK([mores.firstObject[@"parent_id"] isEqualToString:@"t3_1xyr1v3"] && [mores.firstObject[@"depth"] isEqual:@0] && [mores.firstObject[@"count"] isEqual:@326],
          @"the thread's own load-more row (%@)", mores.firstObject);

    // The same rows as the answer to a "load more" tap: flat, each naming its
    // parent, depths counted from the row's.
    NSDictionary *moreChildren = ApolloGQLLegacyMoreChildren(mega[@"graphql"], 3, YES);
    NSArray<NSDictionary *> *things = moreChildren[@"json"][@"data"][@"things"];
    CHECK([moreChildren[@"json"][@"errors"] isEqualToArray:@[]] && things.count == 7, @"morechildren body (%lu things)", (unsigned long)things.count);
    NSMutableArray<NSString *> *flat = [NSMutableArray array];
    for (NSDictionary *thing in things) {
        [flat addObject:[NSString stringWithFormat:@"%@:%@<%@@%@", thing[@"kind"], [thing[@"kind"] isEqualToString:@"more"] ? @"-" : thing[@"data"][@"name"],
                         thing[@"data"][@"parent_id"], thing[@"data"][@"depth"]]];
        if ([thing[@"kind"] isEqualToString:@"t1"]) CHECK([thing[@"data"][@"replies"] isEqual:@""], @"flat things carry no replies");
    }
    NSArray *expected = @[ @"t1:t1_19ss7cj2tvste<t3_1xyr1v3@3", @"t1:t1_19ss7jrolipwl<t1_19ss7cj2tvste@4", @"t1:t1_19ss8gxzp1lls<t1_19ss7jrolipwl@5",
                           @"t1:t1_19ss7h66alw9t<t3_1xyr1v3@3", @"t1:t1_19ss8fv9tgdcx<t3_1xyr1v3@3", @"t1:t1_19ss8hjpxqvtw<t1_19ss8fv9tgdcx@4",
                           @"more:-<t3_1xyr1v3@3" ];
    CHECK([flat isEqualToArray:expected], @"flat order, parents and depths (%@)", flat);

    // Without raw_json=1 every string is escaped, the HTML included.
    NSArray *escaped = ApolloGQLLegacyCommentsPage(pics[@"graphql"], ApolloGQLLegacyThing(@"t3", pics[@"link"]), NO);
    [comments removeAllObjects];
    [mores removeAllObjects];
    FlattenComments(escaped[1][@"data"][@"children"], comments, mores);
    CHECK([comments[@"t1_19t431jhx1ezl"][@"body"] isEqualToString:@"Comment 4 says this &amp; &lt;that&gt;."], @"escaped body (%@)", comments[@"t1_19t431jhx1ezl"][@"body"]);
    CHECK([comments[@"t1_19t431jhx1ezl"][@"body_html"] isEqualToString:@"&lt;div class=\"md\"&gt;&lt;p&gt;Comment 4 says this &amp;amp; &amp;lt;that&amp;gt;.&lt;/p&gt;\n&lt;/div&gt;"],
          @"escaped HTML (%@)", comments[@"t1_19t431jhx1ezl"][@"body_html"]);

    // Answers that aren't a thread.
    CHECK(ApolloGQLLegacyCommentsPage(@{ @"data": @{ @"postInfoById": [NSNull null] } }, ApolloGQLLegacyThing(@"t3", pics[@"link"]), YES) == nil, @"no post");
    CHECK(ApolloGQLLegacyCommentsPage(@{ @"data": @{ @"postInfoById": @{ @"id": @"t3_x" } } }, ApolloGQLLegacyThing(@"t3", pics[@"link"]), YES) == nil, @"no comment list");
    CHECK(ApolloGQLLegacyMoreChildren(@{ @"errors": @[ @{ @"message": @"nope" } ] }, 0, YES) == nil, @"an error answer");
    NSArray *empty = ApolloGQLLegacyCommentsPage(@{ @"data": @{ @"postInfoById": @{ @"id": @"t3_x", @"commentForest": @{ @"trees": @[] } } } },
                                                 ApolloGQLLegacyThing(@"t3", pics[@"link"]), YES);
    CHECK([empty[1][@"data"][@"children"] isEqualToArray:@[]], @"a thread without comments");
}

static void TestMoreToken(void) {
    for (NSString *cursor in @[ @"commenttree:8530017d,::3:d1:t1_19t3ia29toizk", @"a:b,c|d\"e'f\\g h\n", @"ünïcödé ✓", @":" ]) {
        NSInteger depth = -1;
        NSString *back = ApolloGQLMoreTokenCursor(ApolloGQLMoreToken(cursor, 7), &depth);
        CHECK([back isEqualToString:cursor] && depth == 7, @"round trip of %@ (%@, %ld)", cursor, back, (long)depth);
    }
    CHECK([ApolloGQLMoreTokenCursor(ApolloGQLMoreToken(@"x", 0), NULL) isEqualToString:@"x"], @"depth is optional");
    // Real comment ids, and anything else that isn't a token.
    for (id notToken in @[ @"19t3ia29toizk", @"abc,def", @"", @"gqlmore", @"gqlmorezz", @"gqlmore3", @"gqlmore78", @"gqlmore3a78", @"gqlmore313a",
                           @"GQLMORE313a78", @42, [NSNull null] ]) {
        CHECK(ApolloGQLMoreTokenCursor(notToken, NULL) == nil, @"%@ isn't a token", notToken);
    }
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
           "<p><a href=\"https://giphy.com/gifs/XYZ\" target=\"_blank\">https://giphy.com/gifs/XYZ</a></p>\n</div>"], @"embedded media become links (%@)", image);
    // A Giphy embed links to its page even when the answer lists the GIF.
    NSString *listed = ApolloGQLRichTextHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"gif\",\"id\":\"giphy|XYZ\"}]}]}",
                                             @[ @{ @"id": @"giphy|XYZ", @"url": @"https://external-preview.redd.it/x.gif" } ], NO);
    CHECK([listed isEqualToString:@"<div class=\"md\"><p><a href=\"https://giphy.com/gifs/XYZ\" target=\"_blank\">https://giphy.com/gifs/XYZ</a></p>\n</div>"],
          @"giphy page over the listed GIF (%@)", listed);

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
                              @"r/u_someone/hot", @"r/apple/about", @"r/apple/comments", @"r/apple/search", @"hot", @"best", @"user/x/submitted",
                              @"r/apple/wiki/index", @"r/a/hot" ]) {
        CHECK(ApolloGQLRequestForLegacy(@"GET", path, nil) == nil, @"%@ isn't a single subreddit's feed", path);
        CHECK(!ApolloGQLCanAnswerPath(@"GET", path), @"%@ by path", path);
    }
    CHECK(ApolloGQLCanAnswerPath(@"GET", @"/r/apple/hot.json") && ApolloGQLCanAnswerPath(@"get", @"api/info.json?id=t1_x"), @"by path alone");
    CHECK(!ApolloGQLCanAnswerPath(@"POST", @"/r/apple/hot.json") && !ApolloGQLCanAnswerPath(@"POST", @"comments/abc.json"), @"not these");

    // A thread.
    ApolloGQLRequest *thread = ApolloGQLRequestForLegacy(@"GET", @"comments/1y3u73f.json", @{ @"sort": @"top", @"limit": @500, @"raw_json": @1 });
    CHECK(thread.kind == ApolloGQLRequestKindComments && [thread.linkFullname isEqualToString:@"t3_1y3u73f"] && [thread.commentSort isEqualToString:@"TOP"],
          @"a thread (%@ %@)", thread.linkFullname, thread.commentSort);
    CHECK(thread.limit == 500 && thread.rawJSON, @"its limit and raw_json");
    NSDictionary *threadVariables = ApolloGQLPostCommentsVariables(thread);
    CHECK([threadVariables isEqualToDictionary:(@{ @"id": @"t3_1y3u73f", @"sortType": @"TOP", @"includePremiumAvatarTreatment": @NO,
                                                   @"includeConsistencyToken": @NO })], @"Reddit's own page size for a big limit (%@)", threadVariables);
    ApolloGQLRequest *small = ApolloGQLRequestForLegacy(@"GET", @"/r/Pics/comments/1y3u73f/some_title/.json?limit=50", nil);
    CHECK(small.kind == ApolloGQLRequestKindComments && [small.linkFullname isEqualToString:@"t3_1y3u73f"] && [small.commentSort isEqualToString:@"CONFIDENCE"],
          @"a thread by its permalink, Reddit's default sort (%@ %@)", small.linkFullname, small.commentSort);
    CHECK([ApolloGQLPostCommentsVariables(small)[@"count"] isEqual:@50], @"a small limit is the count");
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"comments/abc/", @{ @"sort": @"confidence" }).commentSort isEqualToString:@"CONFIDENCE"] &&
          [ApolloGQLRequestForLegacy(@"GET", @"comments/abc", @{ @"sort": @"QA" }).commentSort isEqualToString:@"QA"] &&
          [ApolloGQLRequestForLegacy(@"GET", @"comments/abc", @{ @"sort": @"old" }).commentSort isEqualToString:@"OLD"], @"comment sorts");
    for (NSString *sort in @[ @"hot", @"random", @"live", @"nonsense" ]) {
        CHECK(ApolloGQLRequestForLegacy(@"GET", @"comments/abc", @{ @"sort": sort }) == nil, @"GraphQL has no %@ sort", sort);
    }
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"comments/abc/_/def.json", @{ @"context": @3 }) == nil &&
          ApolloGQLRequestForLegacy(@"GET", @"r/pics/comments/abc/title/def", nil) == nil, @"a thread opened at one comment");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"comments/abc", @{ @"comment": @"def" }) == nil &&
          ApolloGQLRequestForLegacy(@"GET", @"comments/abc?context=3", nil) == nil, @"or by ?comment= / ?context=");
    for (NSString *path in @[ @"comments", @"comments/AB!", @"comments/abcdefghijklmnop", @"user/x/comments", @"r/pics/comments", @"api/comment" ]) {
        CHECK(!ApolloGQLCanAnswerPath(@"GET", path), @"%@ isn't a thread", path);
    }

    // The replies behind a "load more" row.
    NSString *token = ApolloGQLMoreToken(@"commenttree:x,::2:ex:,X;abc", 2);
    NSDictionary *moreParameters = @{ @"api_type": @"json", @"children": token, @"id": [@"t1_" stringByAppendingString:token],
                                      @"limit_children": @NO, @"link_id": @"t3_1y3u73f", @"sort": @"top" };
    ApolloGQLRequest *more = ApolloGQLRequestForLegacy(@"POST", @"api/morechildren.json", moreParameters);
    CHECK(more.kind == ApolloGQLRequestKindMoreComments && [more.linkFullname isEqualToString:@"t3_1y3u73f"] && [more.commentSort isEqualToString:@"TOP"],
          @"load more (%@ %@)", more.linkFullname, more.commentSort);
    CHECK([more.moreCursor isEqualToString:@"commenttree:x,::2:ex:,X;abc"] && more.moreDepth == 2, @"its cursor and depth (%@ %ld)", more.moreCursor, (long)more.moreDepth);
    NSDictionary *moreVariables = ApolloGQLPostCommentsVariables(more);
    CHECK([moreVariables[@"after"] isEqualToString:@"commenttree:x,::2:ex:,X;abc"] && [moreVariables[@"count"] isEqual:@200] &&
          [moreVariables[@"id"] isEqualToString:@"t3_1y3u73f"], @"load-more variables (%@)", moreVariables);
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"api/morechildren", moreParameters).kind == ApolloGQLRequestKindMoreComments, @"as a GET too");
    NSMutableDictionary *real = [moreParameters mutableCopy];
    real[@"children"] = @"19t3s4u8py882,19t3h6s58c36o";
    CHECK(ApolloGQLRequestForLegacy(@"POST", @"api/morechildren", real) == nil, @"a row of a thread the legacy API sent keeps its routes");
    NSMutableDictionary *noLink = [moreParameters mutableCopy];
    noLink[@"link_id"] = @"t1_abc";
    CHECK(ApolloGQLRequestForLegacy(@"POST", @"api/morechildren", noLink) == nil, @"needs the post");
    NSMutableDictionary *hotSort = [moreParameters mutableCopy];
    hotSort[@"sort"] = @"hot";
    CHECK(ApolloGQLRequestForLegacy(@"POST", @"api/morechildren", hotSort) == nil, @"and a sort GraphQL has");
    CHECK(ApolloGQLCanAnswerPath(@"POST", @"api/morechildren.json") && ApolloGQLCanAnswerPath(@"GET", @"/api/morechildren/.json") &&
          ApolloGQLCanAnswerPath(@"GET", @"comments/abc.json") && ApolloGQLCanAnswerPath(@"GET", @"/r/pics/comments/abc/title/"), @"threads by path alone");
    CHECK(ApolloGQLOperationHash(ApolloGQLOperationPostComments).length == 64, @"PostComments is a known operation");

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
        TestCommentsAgainstLegacy(@(argv[1]));
        TestCommentThreads(@(argv[1]));
        TestMoreToken();
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
