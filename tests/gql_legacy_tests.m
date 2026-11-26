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
// same comments. tests/fixtures/graphql/subreddits.json holds three subreddits:
// what SubredditInfoByName answered and the legacy /r/<sub>/about.json keys.

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

static NSDictionary *MinimalPost(NSDictionary *overrides);

static void TestSearchListing(void) {
    // A search answer's posts are whole, like PostsByIds'; its cursor rides in
    // the Listing's `after`.
    NSDictionary *profilePost = MinimalPost(@{ @"id": @"t3_onprofile", @"subreddit": [NSNull null] });
    NSDictionary *answer = @{ @"data": @{ @"search": @{ @"general": @{ @"posts": @{
        @"edges": @[ @{ @"node": MinimalPost(@{ @"id": @"t3_one" }) }, @{ @"node": profilePost }, @{ @"node": [NSNull null] }, @{ @"node": MinimalPost(@{ @"id": @"t3_two" }) } ],
        @"pageInfo": @{ @"endCursor": @"MjQ=", @"hasNextPage": @YES } } } } } };
    NSDictionary *listing = ApolloGQLLegacySearchListing(answer, YES);
    NSArray *children = listing[@"data"][@"children"];
    CHECK([listing[@"kind"] isEqualToString:@"Listing"] && children.count == 2 && [children[0][@"kind"] isEqualToString:@"t3"] &&
          [children[0][@"data"][@"name"] isEqualToString:@"t3_one"] && [children[1][@"data"][@"name"] isEqualToString:@"t3_two"], @"the posts, in order (%@)", [children valueForKeyPath:@"data.name"]);
    NSString *after = listing[@"data"][@"after"];
    CHECK([ApolloGQLSearchAfterCursor(after) isEqualToString:@"MjQ="] && ![after hasPrefix:@"t3_"], @"the cursor as the next page's after (%@)", after);
    NSMutableDictionary *last = [answer mutableCopy];
    last[@"data"] = @{ @"search": @{ @"general": @{ @"posts": @{ @"edges": @[], @"pageInfo": @{ @"endCursor": @"MjQ=", @"hasNextPage": @NO } } } } };
    NSDictionary *lastListing = ApolloGQLLegacySearchListing(last, YES);
    CHECK([lastListing[@"data"][@"children"] isEqualToArray:@[]] && lastListing[@"data"][@"after"] == [NSNull null], @"no results, no next page");
    CHECK(ApolloGQLLegacySearchListing(@{ @"data": @{ @"search": [NSNull null] } }, YES) == nil && ApolloGQLLegacySearchListing(@{}, YES) == nil, @"not a search answer");
    for (id notToken in @[ @"t3_abc", @"gqlafter", @"gqlafterzz", @"", [NSNull null] ]) {
        CHECK(ApolloGQLSearchAfterCursor(notToken) == nil, @"%@ isn't a search cursor", notToken);
    }
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

#pragma mark - Subreddits against the legacy answer

static void TestSubredditsAgainstLegacy(NSString *repoRoot) {
    NSData *data = [NSData dataWithContentsOfFile:[repoRoot stringByAppendingPathComponent:@"tests/fixtures/graphql/subreddits.json"]];
    NSDictionary *fixture = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSArray<NSDictionary *> *subreddits = fixture[@"subreddits"];
    CHECK(subreddits.count == 3, @"fixture has its three subreddits (%lu)", (unsigned long)subreddits.count);
    NSMutableDictionary<NSString *, NSDictionary *> *byKind = [NSMutableDictionary dictionary];
    for (NSDictionary *subreddit in subreddits) {
        NSString *kind = subreddit[@"kind"];
        NSDictionary *about = ApolloGQLLegacySubredditAbout(@{ @"data": @{ @"subredditInfoByName": subreddit[@"graphql"] } }, YES);
        CHECK([about[@"kind"] isEqualToString:@"t5"] && [about[@"data"] isKindOfClass:[NSDictionary class]], @"%@ is a t5 thing", kind);
        NSDictionary *ours = about[@"data"], *legacy = subreddit[@"legacy"];
        if (!ours) continue;
        byKind[kind] = ours;
        NSMutableArray<NSString *> *differences = [NSMutableArray array];
        for (NSString *key in [legacy.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (!ours[key]) { [differences addObject:[key stringByAppendingString:@" is missing"]]; continue; }
            Compare(ours[key], legacy[key], key, kind, differences);
        }
        CHECK(differences.count == 0, @"the %@ subreddit differs from the legacy answer:\n  %@", kind, [differences componentsJoinedByString:@"\n  "]);
    }
    CHECK([byKind[@"links-and-text"][@"submission_type"] isEqualToString:@"any"] && [byKind[@"links-only"][@"submission_type"] isEqualToString:@"link"] &&
          [byKind[@"text-only"][@"submission_type"] isEqualToString:@"self"], @"the three kinds of subreddit");
    // The community icon is the uploaded image itself (GraphQL's is signed for
    // 64 pixels); a subreddit with only an old-style icon has none.
    NSString *icon = byKind[@"links-and-text"][@"community_icon"];
    CHECK([icon hasPrefix:@"https://styles.redditmedia.com/"] && ![icon containsString:@"?"], @"full-size community icon (%@)", icon);
    CHECK([byKind[@"links-only"][@"community_icon"] isEqualToString:@""] && [byKind[@"links-only"][@"icon_img"] hasPrefix:@"https://"],
          @"old-style icon only (%@)", byKind[@"links-only"][@"icon_img"]);
    // GraphQL has no posting note: the keys are absent, so Apollo's composer
    // shows the sidebar (it reads submitText, then subredditDescription).
    CHECK(byKind[@"links-and-text"][@"submit_text"] == nil && byKind[@"links-and-text"][@"submit_text_html"] == nil, @"no submit text");
    CHECK([byKind[@"links-and-text"][@"allowed_media_in_comments"] isEqualToArray:(@[ @"static", @"expression" ])], @"comment media kinds (%@)",
          byKind[@"links-and-text"][@"allowed_media_in_comments"]);

    // The account's own state and flair in the subreddit.
    NSMutableDictionary *joined = [subreddits.firstObject[@"graphql"] mutableCopy];
    joined[@"isSubscribed"] = @YES;
    joined[@"modPermissions"] = @{ @"isAllAllowed": @YES };
    joined[@"authorFlair"] = @{ @"text": @"Mine", @"richtext": @"[{\"e\":\"text\",\"t\":\"Mine\"}]", @"textColor": @"DARK", @"template": @{ @"id": @"abc" } };
    NSDictionary *mine = ApolloGQLLegacySubredditData(joined, YES);
    CHECK([mine[@"user_is_subscriber"] isEqual:@YES] && [mine[@"user_is_moderator"] isEqual:@YES], @"joined and moderating");
    CHECK([mine[@"user_flair_text"] isEqualToString:@"Mine"] && [mine[@"user_flair_template_id"] isEqualToString:@"abc"] &&
          [mine[@"user_flair_type"] isEqualToString:@"richtext"], @"the account's flair (%@)", mine[@"user_flair_text"]);
    NSDictionary *escaped = ApolloGQLLegacySubredditData(subreddits.firstObject[@"graphql"], NO);
    CHECK([escaped[@"description"] hasSuffix:@"&amp; &lt;three&gt;."] && [escaped[@"description_html"] hasPrefix:@"&lt;!-- SC_OFF --&gt;"], @"escaped without raw_json");

    // Answers that aren't a subreddit.
    CHECK(ApolloGQLLegacySubredditAbout(@{ @"data": @{ @"subredditInfoByName": [NSNull null] } }, YES) == nil, @"a subreddit GraphQL won't show");
    CHECK(ApolloGQLLegacySubredditData(@{ @"id": @"t2_user", @"name": @"x" }, YES) == nil && ApolloGQLLegacySubredditData(nil, YES) == nil, @"not a subreddit");
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
    NSArray *ids = ApolloGQLFeedPostFullnames(feed, NO, &after);
    CHECK([ids isEqualToArray:(@[ @"t3_one", @"t3_two" ])], @"posts only, once each (%@)", ids);
    CHECK([after isEqualToString:@"t3_two"], @"the cursor is the base64 of the last fullname (%@)", after);
    CHECK([ApolloGQLFeedCursorForFullname(@"t3_two") isEqualToString:@"dDNfdHdv"], @"and back");
    CHECK(ApolloGQLFeedCursorForFullname(nil) == nil && ApolloGQLFeedCursorForFullname(@"") == nil, @"no cursor for a first page");

    NSDictionary *last = ParseJSON(@"{\"data\":{\"subredditV3\":{\"elements\":{\"edges\":[],\"pageInfo\":{\"endCursor\":null}}}}}");
    CHECK([ApolloGQLFeedPostFullnames(last, NO, &after) isEqualToArray:@[]] && after == nil, @"an empty last page");
    NSDictionary *done = ParseJSON(@"{\"data\":{\"subredditV3\":{\"elements\":{\"edges\":[],\"pageInfo\":{\"endCursor\":\"dDNfdHdv\",\"hasNextPage\":false}}}}}");
    ApolloGQLFeedPostFullnames(done, NO, &after);
    CHECK(after == nil, @"hasNextPage false ends the feed");
    NSDictionary *opaque = ParseJSON(@"{\"data\":{\"subredditV3\":{\"elements\":{\"edges\":[],\"pageInfo\":{\"endCursor\":\"bm90IGEgZnVsbG5hbWU=\"}}}}}");
    ApolloGQLFeedPostFullnames(opaque, NO, &after);
    CHECK(after == nil, @"a cursor that isn't a fullname can't become a legacy `after`");
    CHECK(ApolloGQLFeedPostFullnames(ParseJSON(@"{\"data\":{\"subredditV3\":null}}"), NO, &after) == nil, @"no feed at all");
    CHECK(ApolloGQLFeedPostFullnames(@{}, NO, NULL) == nil, @"no data");

    // Home can mix in posts Reddit suggests from subreddits the account hasn't
    // joined. A suggested row says why it's there and offers Join; a joined
    // subreddit's has no context, or a hidden "subscribed…" one.
    NSDictionary *home = ParseJSON(@"{\"data\":{\"homeV3\":{\"elements\":{\"edges\":["
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_joined\",\"adPayload\":null,\"groupRecommendationContext\":null,"
            "\"cells\":[{\"__typename\":\"MetadataCell\",\"isJoinButtonShown\":false}]}},"
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_suggested\",\"adPayload\":null,"
            "\"groupRecommendationContext\":{\"isContextHidden\":false,\"typeIdentifier\":\"generative_recs_user_to_post\"},"
            "\"cells\":[{\"__typename\":\"RichtextRecommendationContextCell\"},{\"__typename\":\"MetadataCell\",\"isJoinButtonShown\":true}]}},"
        "{\"node\":{\"__typename\":\"ContentForwardCommunityRecommendationsFeedUnit\",\"id\":\"x\"}},"
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_subscribed\",\"adPayload\":null,"
            "\"groupRecommendationContext\":{\"isContextHidden\":true,\"typeIdentifier\":\"subscribed_new_sort\"},"
            "\"cells\":[{\"__typename\":\"RichtextRecommendationContextCell\"},{\"__typename\":\"MetadataCell\",\"isJoinButtonShown\":false}]}},"
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_nocontext\",\"adPayload\":null,\"groupRecommendationContext\":null,"
            "\"cells\":[{\"__typename\":\"MetadataCell\",\"isJoinButtonShown\":true}]}},"
        "{\"node\":{\"__typename\":\"CellGroup\",\"groupId\":\"t3_last\",\"adPayload\":null,"
            "\"groupRecommendationContext\":{\"isContextHidden\":false,\"typeIdentifier\":\"responsivesimilar\"},\"cells\":[]}}"
        "],\"pageInfo\":{\"endCursor\":\"dDNfbGFzdA==\"}}}}}");
    NSArray *joined = ApolloGQLFeedPostFullnames(home, YES, &after);
    CHECK([joined isEqualToArray:(@[ @"t3_joined", @"t3_subscribed" ])], @"only the joined subreddits' posts (%@)", joined);
    CHECK([after isEqualToString:@"t3_last"], @"the next page still starts after the page's last row, shown or not (%@)", after);
    NSArray *everything = ApolloGQLFeedPostFullnames(home, NO, &after);
    CHECK(everything.count == 5, @"a subreddit's feed keeps every post (%@)", everything);

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
    // Old sidebars: a link with empty text stays empty, one without a text
    // field shows its address, and a heading mark on its own renders nothing.
    CheckHTML(@"{\"document\":[{\"e\":\"par\",\"c\":[{\"e\":\"link\",\"t\":\"\",\"u\":\"/topBegin\"},{\"e\":\"link\",\"u\":\"https://a.example/\"}]},{\"e\":\"h\",\"l\":1,\"c\":[]}]}",
              @"<p><a href=\"/topBegin\"></a><a href=\"https://a.example/\">https://a.example/</a></p>", @"empty links and headings");

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
    for (NSString *path in @[ @"r/all/hot", @"r/all", @"r/mod/new", @"r/friends", @"r/random", @"r/apple+ios/hot", @"r/all-apple/hot",
                              @"r/u_someone/hot", @"r/all/about", @"r/popular/about", @"r/u_someone/about", @"r/apple+ios/about", @"r/apple/about/rules", @"r/apple/comments", @"r/apple/wiki", @"", @"about", @"best", @"user/x/submitted",
                              @"r/apple/wiki/index", @"r/a/hot" ]) {
        CHECK(ApolloGQLRequestForLegacy(@"GET", path, nil) == nil, @"%@ isn't a feed GraphQL answers", path);
        CHECK(!ApolloGQLCanAnswerPath(@"GET", path), @"%@ by path", path);
    }
    CHECK(ApolloGQLCanAnswerPath(@"GET", @"/r/apple/hot.json") && ApolloGQLCanAnswerPath(@"get", @"api/info.json?id=t1_x"), @"by path alone");
    // The route table's endpoint patterns ("*" is one subreddit, post or
    // account) count by path, for the Routes screen; no request is planned
    // from one.
    for (NSString *pattern in @[ @"/r/*/hot", @"/r/*", @"/r/*/about", @"/r/*/search", @"/comments/*", @"/r/*/comments/*", @"/user/*/submitted" ]) {
        CHECK(ApolloGQLCanAnswerPath(@"GET", pattern), @"%@ is an endpoint GraphQL answers", pattern);
        CHECK(ApolloGQLRequestForLegacy(@"GET", pattern, @{ @"q": @"x" }) == nil, @"but %@ isn't a request", pattern);
    }
    CHECK(!ApolloGQLCanAnswerPath(@"GET", @"/r/+/hot") && !ApolloGQLCanAnswerPath(@"GET", @"/r/all/*") && !ApolloGQLCanAnswerPath(@"GET", @"/user/*/overview") &&
          !ApolloGQLCanAnswerPath(@"GET", @"/*"), @"patterns of endpoints it doesn't answer");
    CHECK(!ApolloGQLCanAnswerPath(@"POST", @"/r/apple/hot.json") && !ApolloGQLCanAnswerPath(@"POST", @"comments/abc.json"), @"not these");

    // Home: a sort on its own. Not "best", which GraphQL fills with suggestions.
    ApolloGQLRequest *homeHot = ApolloGQLRequestForLegacy(@"GET", @"hot.json", @{ @"api_type": @"json", @"limit": @25 });
    CHECK(homeHot.kind == ApolloGQLRequestKindHomeFeed && [homeHot.sort isEqualToString:@"HOT"] && homeHot.subreddit == nil && homeHot.limit == 25,
          @"Home, hot (%@)", homeHot.sort);
    CHECK([ApolloGQLFeedOperation(homeHot) isEqualToString:@"HomeFeedSdui"] && [ApolloGQLFeedVariables(homeHot, nil) isEqualToDictionary:(@{ @"sort": @"HOT" })],
          @"Home's operation and variables (%@)", ApolloGQLFeedVariables(homeHot, nil));
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"best.json", @{ @"limit": @25 }) == nil && !ApolloGQLCanAnswerPath(@"GET", @"best.json"), @"Home's best keeps its routes");
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"r/apple/best", nil).sort isEqualToString:@"BEST"], @"a subreddit's best is still answered");
    ApolloGQLRequest *homeTop = ApolloGQLRequestForLegacy(@"GET", @"/top/.json", @{ @"t": @"month", @"after": @"t3_last" });
    CHECK(homeTop.kind == ApolloGQLRequestKindHomeFeed && [ApolloGQLFeedVariables(homeTop, homeTop.after) isEqualToDictionary:
           (@{ @"sort": @"TOP", @"time": @"MONTH", @"after": @"dDNfbGFzdA==" })], @"Home, top of the month, next page (%@)", ApolloGQLFeedVariables(homeTop, homeTop.after));
    for (NSString *sort in @[ @"new", @"rising", @"controversial" ]) {
        CHECK(ApolloGQLRequestForLegacy(@"GET", sort, nil).kind == ApolloGQLRequestKindHomeFeed && ApolloGQLCanAnswerPath(@"GET", [sort stringByAppendingString:@".json"]),
              @"Home, %@", sort);
    }
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"hot", @{ @"before": @"t3_x" }) == nil && !ApolloGQLCanAnswerPath(@"POST", @"hot.json"), @"Home reads forwards only");
    CHECK(ApolloGQLOperationHash(ApolloGQLOperationHomeFeed).length == 64, @"HomeFeedSdui is a known operation");

    // Popular: a feed query of its own, without a subreddit.
    ApolloGQLRequest *popular = ApolloGQLRequestForLegacy(@"GET", @"r/popular/top.json", @{ @"t": @"week", @"limit": @25 });
    CHECK(popular.kind == ApolloGQLRequestKindPopularFeed && [ApolloGQLFeedOperation(popular) isEqualToString:@"PopularFeedSdui"] &&
          [ApolloGQLFeedVariables(popular, nil) isEqualToDictionary:(@{ @"sort": @"TOP", @"time": @"WEEK" })], @"popular, top of the week (%@)", ApolloGQLFeedVariables(popular, nil));
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"/r/Popular/.json", nil).sort isEqualToString:@"HOT"] && ApolloGQLCanAnswerPath(@"GET", @"r/popular/rising.json"),
          @"popular, bare and by path");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"r/popular/hot", @{ @"geo_filter": @"GLOBAL" }).kind == ApolloGQLRequestKindPopularFeed &&
          ApolloGQLRequestForLegacy(@"GET", @"r/popular/hot", @{ @"geo_filter": @"CA" }) == nil, @"popular for one country keeps its routes");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"r/popular/hot", @{ @"before": @"t3_x" }) == nil, @"popular: forwards only");

    // A search for posts.
    ApolloGQLRequest *search = ApolloGQLRequestForLegacy(@"GET", @"search.json", @{ @"q": @" iphone battery ", @"sort": @"top", @"t": @"week", @"restrict_sr": @"false",
                                                                                  @"limit": @25, @"include_over_18": @"on" });
    CHECK(search.kind == ApolloGQLRequestKindSearchPosts && [search.searchQuery isEqualToString:@"iphone battery"] && [search.searchSort isEqualToString:@"TOP"],
          @"a search (%@ %@)", search.searchQuery, search.searchSort);
    NSDictionary *searchVariables = ApolloGQLSearchPostsVariables(search);
    CHECK([searchVariables isEqualToDictionary:(@{ @"query": @"iphone battery", @"productSurface": @"SEARCH", @"sort": @"TOP",
                                                   @"filters": @[ @{ @"key": @"nsfw", @"value": @"1" }, @{ @"key": @"time_range", @"value": @"week" } ] })],
          @"search variables (%@)", searchVariables);
    ApolloGQLRequest *inSubreddit = ApolloGQLRequestForLegacy(@"GET", @"r/Apple/search.json", @{ @"q": @"battery", @"restrict_sr": @"true", @"t": @"all" });
    CHECK([inSubreddit.searchQuery isEqualToString:@"battery subreddit:Apple"] && [inSubreddit.searchSort isEqualToString:@"RELEVANCE"] && inSubreddit.searchRange == nil,
          @"a search of one subreddit, by relevance, all time (%@)", inSubreddit.searchQuery);
    CHECK([ApolloGQLSearchPostsVariables(inSubreddit)[@"filters"] isEqualToArray:@[]] && ApolloGQLSearchPostsVariables(inSubreddit)[@"afterCursor"] == nil, @"no filters, first page");
    CHECK([ApolloGQLRequestForLegacy(@"GET", @"r/apple/search", @{ @"q": @"battery" }).searchQuery isEqualToString:@"battery"], @"without restrict_sr it searches everything");
    NSString *nextPage = ApolloGQLSearchAfterToken(@"MjQ=");
    ApolloGQLRequest *page2 = ApolloGQLRequestForLegacy(@"GET", @"search", @{ @"q": @"battery", @"after": nextPage });
    CHECK([page2.searchCursor isEqualToString:@"MjQ="] && [ApolloGQLSearchPostsVariables(page2)[@"afterCursor"] isEqualToString:@"MjQ="], @"the next page by the cursor (%@)", page2.searchCursor);
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"search", @{ @"q": @"battery", @"after": @"t3_abc" }) == nil, @"a page after one the legacy API sent keeps its routes");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"search", @{ @"q": @"  " }) == nil && ApolloGQLRequestForLegacy(@"GET", @"search", @{ @"q": @"x", @"type": @"sr" }) == nil &&
          ApolloGQLRequestForLegacy(@"GET", @"search", @{ @"q": @"x", @"type": @"user" }) == nil && ApolloGQLRequestForLegacy(@"GET", @"search", @{ @"q": @"x", @"sort": @"best" }) == nil,
          @"nothing to search, other kinds of result, unknown sort");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"search", @{ @"q": @"x", @"type": @"link" }).kind == ApolloGQLRequestKindSearchPosts, @"type=link is a post search");
    for (NSString *path in @[ @"subreddits/search", @"users/search", @"r/apple+ios/search", @"r/all/search", @"api/search_subreddits", @"search/extra" ]) {
        CHECK(!ApolloGQLCanAnswerPath(@"GET", path), @"%@ isn't a post search GraphQL answers", path);
    }
    CHECK(!ApolloGQLCanAnswerPath(@"POST", @"search.json") && ApolloGQLOperationHash(ApolloGQLOperationSearchPosts).length == 64, @"reads only; a known operation");

    // The Posts list of a profile.
    ApolloGQLRequest *userPosts = ApolloGQLRequestForLegacy(@"GET", @"user/Some-One_1/submitted.json", @{ @"api_type": @"json", @"limit": @25 });
    CHECK(userPosts.kind == ApolloGQLRequestKindUserPosts && [userPosts.username isEqualToString:@"Some-One_1"] && [ApolloGQLFeedOperation(userPosts) isEqualToString:@"SubmittedPostsFeedSdui"],
          @"a profile's posts (%@)", userPosts.username);
    CHECK([ApolloGQLFeedVariables(userPosts, nil) isEqualToDictionary:(@{ @"username": @"Some-One_1", @"sort": @"NEW" })], @"newest first by default (%@)", ApolloGQLFeedVariables(userPosts, nil));
    ApolloGQLRequest *userTop = ApolloGQLRequestForLegacy(@"GET", @"/user/someone/submitted/", @{ @"sort": @"top", @"after": @"t3_last" });
    CHECK([ApolloGQLFeedVariables(userTop, userTop.after) isEqualToDictionary:(@{ @"username": @"someone", @"sort": @"TOP", @"time": @"ALL", @"after": @"dDNfbGFzdA==" })],
          @"top of all time, next page (%@)", ApolloGQLFeedVariables(userTop, userTop.after));
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"user/someone/submitted", @{ @"sort": @"rising" }) == nil &&
          ApolloGQLRequestForLegacy(@"GET", @"user/someone/submitted", @{ @"before": @"t3_x" }) == nil, @"no such sort, no backwards paging");
    for (NSString *path in @[ @"user/someone/overview", @"user/someone/about", @"user/someone/saved/top", @"user/ab/submitted",
                              @"user/some.one/submitted", @"user/someone/submitted/extra", @"u/someone/submitted" ]) {
        CHECK(!ApolloGQLCanAnswerPath(@"GET", path), @"%@ isn't a profile's posts", path);
    }

    // A subreddit's details.
    ApolloGQLRequest *about = ApolloGQLRequestForLegacy(@"GET", @"r/Apple/about.json", @{ @"api_type": @"json", @"raw_json": @1 });
    CHECK(about.kind == ApolloGQLRequestKindSubredditAbout && [about.subreddit isEqualToString:@"Apple"] && about.rawJSON, @"a subreddit's details (%@)", about.subreddit);
    CHECK([ApolloGQLSubredditInfoVariables(about) isEqualToDictionary:(@{ @"subredditName": @"Apple", @"includeRecapFields": @NO, @"includeDevvitData": @NO })],
          @"its variables (%@)", ApolloGQLSubredditInfoVariables(about));
    CHECK(ApolloGQLCanAnswerPath(@"GET", @"/r/apple/about/.json") && !ApolloGQLCanAnswerPath(@"POST", @"r/apple/about.json"), @"details by path, reads only");
    CHECK(ApolloGQLOperationHash(ApolloGQLOperationSubredditInfo).length == 64, @"SubredditInfoByName is a known operation");
    CHECK(ApolloGQLOperationHash(ApolloGQLOperationPopularFeed).length == 64, @"PopularFeedSdui is a known operation");

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
    NSDictionary *first = ApolloGQLFeedVariables(hot, nil), *next = ApolloGQLFeedVariables(top, top.after);
    CHECK([ApolloGQLFeedOperation(hot) isEqualToString:@"SubredditFeedSdui"], @"a subreddit's feed operation");
    CHECK([first isEqualToDictionary:(@{ @"subredditName": @"Apple", @"sort": @"HOT" })], @"first page variables (%@)", first);
    CHECK([next isEqualToDictionary:(@{ @"subredditName": @"apple", @"sort": @"TOP", @"time": @"WEEK", @"after": @"dDNfbGFzdA==" })], @"next page variables (%@)", next);
    CHECK(ApolloGQLPostsByIdsBatch == 50, @"batch size");
}

#pragma mark - Authors

static void TestAuthorRecords(void) {
    // The picture GraphQL names is signed for 50 pixels. A snoo Reddit drew is
    // a 256-pixel square at the address without its query; an upload isn't.
    CHECK([ApolloGQLLegacyAuthorIconURL(@"https://preview.redd.it/snoovatar/avatars/11111111-2222-3333-4444-555555555555-headshot.png?width=50&height=50&auto=webp&s=abc")
           isEqualToString:@"https://i.redd.it/snoovatar/avatars/11111111-2222-3333-4444-555555555555-headshot.png"], @"builder snoo");
    CHECK([ApolloGQLLegacyAuthorIconURL(@"https://styles.redditmedia.com/t5_abc/styles/profileIcon_snoo11111111-2222-3333-4444-555555555555-headshot-f.png?width=50&height=50&frame=1&auto=webp&crop=50%3A50%2Csmart&s=abc")
           isEqualToString:@"https://styles.redditmedia.com/t5_abc/styles/profileIcon_snoo11111111-2222-3333-4444-555555555555-headshot-f.png"], @"profile snoo");
    NSString *collectible = @"https://styles.redditmedia.com/t5_abc/styles/profileIcon_snoo-nftv2_bmZ0_rare_11111111-2222-3333-4444-555555555555-headshot.png";
    CHECK([ApolloGQLLegacyAuthorIconURL([collectible stringByAppendingString:@"?width=50&height=50&frame=1&s=abc"]) isEqualToString:collectible],
          @"a collectible keeps the name its frame is read from");
    NSString *upload = @"https://styles.redditmedia.com/t5_abc/styles/profileIcon_abc123.jpg?width=50&height=50&frame=1&auto=webp&crop=50%3A50%2Csmart&s=abc";
    CHECK([ApolloGQLLegacyAuthorIconURL(upload) isEqualToString:upload], @"an upload keeps the signed small picture");
    NSString *plain = @"https://www.redditstatic.com/avatars/defaults/v2/avatar_default_6.png";
    CHECK([ApolloGQLLegacyAuthorIconURL(plain) isEqualToString:plain], @"default avatar");
    CHECK(ApolloGQLLegacyAuthorIconURL(nil) == nil && ApolloGQLLegacyAuthorIconURL(@"") == nil, @"no address");

    // A post, the post it crossposts, and a thread's comments: every author
    // once, in the shape /api/user_data_by_account_ids answers with.
    NSDictionary *answer = ParseJSON([NSString stringWithFormat:@"{\"data\":{\"postsInfoByIds\":[{\"id\":\"t3_a\","
        "\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_one\",\"name\":\"PostAuthor\",\"iconSmall\":{\"url\":\"%@\"}},"
        "\"crosspostRoot\":{\"post\":{\"id\":\"t3_b\",\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_two\",\"name\":\"RootAuthor\","
        "\"iconSmall\":{\"url\":\"%@\"}}}}},"
        "{\"id\":\"t3_c\",\"authorInfo\":{\"__typename\":\"DeletedRedditor\",\"id\":null,\"name\":\"[deleted]\"}},"
        "{\"id\":\"t3_d\",\"authorInfo\":null}],"
        "\"postInfoById\":{\"commentForest\":{\"trees\":["
        "{\"node\":{\"id\":\"t1_x\",\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_three\",\"name\":\"Commenter\",\"iconSmall\":{\"url\":\"%@\"}}}},"
        "{\"node\":{\"id\":\"t1_y\",\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_one\",\"name\":\"PostAuthor\",\"iconSmall\":{\"url\":\"%@\"}}}},"
        "{\"node\":{\"id\":\"t1_z\",\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_four\",\"name\":\"NoPicture\",\"iconSmall\":null}}}]}}}}",
        upload, plain, [collectible stringByAppendingString:@"?width=50&height=50&s=abc"], upload]);
    NSDictionary *records = ApolloGQLLegacyAuthorRecords(answer);
    CHECK(records.count == 3, @"three authors with a picture (%@)", records.allKeys);
    CHECK([records[@"t2_one"] isEqualToDictionary:(@{ @"name": @"PostAuthor", @"profile_img": upload })], @"post author (%@)", records[@"t2_one"]);
    CHECK([records[@"t2_two"] isEqualToDictionary:(@{ @"name": @"RootAuthor", @"profile_img": plain })], @"crosspost root author");
    CHECK([records[@"t2_three"] isEqualToDictionary:(@{ @"name": @"Commenter", @"profile_img": collectible })], @"comment author");
    CHECK(records[@"t2_four"] == nil, @"no picture, no record");
    CHECK(ApolloGQLLegacyAuthorRecords(nil).count == 0 && ApolloGQLLegacyAuthorRecords(@{ @"errors": @[] }).count == 0, @"nothing to read");
    CHECK([NSJSONSerialization isValidJSONObject:records], @"serializes");
}

// The tweak's own reads (Community Highlights, a subreddit's header) are whole
// URLs: a ".json" path with its parameters in the query.
static void TestPlanForOwnReads(void) {
    ApolloGQLRequest *hot = ApolloGQLRequestForLegacy(@"GET", @"/r/apple/hot.json?limit=15&raw_json=1", nil);
    CHECK(hot.kind == ApolloGQLRequestKindSubredditFeed && [hot.subreddit isEqualToString:@"apple"] && [hot.sort isEqualToString:@"HOT"] &&
          hot.limit == 15 && hot.rawJSON, @"Highlights' feed read (%ld %@ %@ %ld)", (long)hot.kind, hot.subreddit, hot.sort, (long)hot.limit);
    ApolloGQLRequest *hotOAuth = ApolloGQLRequestForLegacy(@"GET", @"/r/apple/hot?limit=15&raw_json=1", nil);
    CHECK(hotOAuth.kind == ApolloGQLRequestKindSubredditFeed && hotOAuth.limit == 15, @"the same read as oauth.reddit.com spells it");
    ApolloGQLRequest *info = ApolloGQLRequestForLegacy(@"GET", @"/api/info.json?id=t3_a,t3_b&raw_json=1", nil);
    CHECK(info.kind == ApolloGQLRequestKindPostsInfo && [info.fullnames isEqualToArray:(@[ @"t3_a", @"t3_b" ])] && info.rawJSON,
          @"Highlights' post lookup (%@)", info.fullnames);
    ApolloGQLRequest *about = ApolloGQLRequestForLegacy(@"GET", @"/r/apple/about.json?raw_json=1", nil);
    CHECK(about.kind == ApolloGQLRequestKindSubredditAbout && [about.subreddit isEqualToString:@"apple"] && about.rawJSON, @"a header's details");
    ApolloGQLRequest *linked = ApolloGQLRequestForLegacy(@"GET", @"/comments/abc123.json?raw_json=1&limit=1", nil);
    CHECK(linked.kind == ApolloGQLRequestKindComments && [linked.linkFullname isEqualToString:@"t3_abc123"] && linked.rawJSON,
          @"a link preview's post (%@)", linked.linkFullname);
    CHECK([ApolloGQLPostCommentsVariables(linked)[@"count"] isEqual:@1], @"with one comment, not a page (%@)", ApolloGQLPostCommentsVariables(linked));
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/comments/abc123/.json?raw_json=1&limit=1", nil).kind == ApolloGQLRequestKindComments,
          @"the same lookup as oauth.reddit.com spells it");
    // Lookups GraphQL has no single query for keep their routes.
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/api/info.json?raw_json=1&sr_name=apple,pics", nil) == nil, @"subreddits by name");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/about.json?raw_json=1", nil) == nil, @"a profile's summary");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/api/user_data_by_account_ids.json?ids=t2_a&raw_json=1", nil) == nil, @"account lookups");
}

#pragma mark - The account's lists and a profile's comments

static void TestOwnPostsAndUserComments(void) {
    // Upvoted, downvoted and hidden posts: whole posts under identity.<list>Posts.
    NSDictionary *upvoted = ParseJSON(@"{\"data\":{\"identity\":{\"upvotedPosts\":{\"edges\":["
        "{\"node\":{\"__typename\":\"SubredditPost\",\"id\":\"t3_one\",\"postTitle\":\"First\",\"permalink\":\"/r/test/comments/one/first/\","
        "\"subreddit\":{\"id\":\"t5_x\",\"name\":\"test\",\"prefixedName\":\"r/test\"},\"voteState\":\"UP\",\"score\":5,\"createdAt\":\"2026-11-25T16:30:30.145000+0000\"}},"
        "{\"node\":{\"__typename\":\"SubredditPost\",\"id\":\"t3_two\",\"postTitle\":\"Second\",\"permalink\":\"/r/test/comments/two/second/\","
        "\"subreddit\":{\"id\":\"t5_x\",\"name\":\"test\",\"prefixedName\":\"r/test\"},\"voteState\":\"UP\",\"score\":7,\"createdAt\":\"2026-11-25T16:30:30.145000+0000\"}}],"
        "\"pageInfo\":{\"endCursor\":\"dDNfdHdv\",\"hasNextPage\":true}}}}}");
    NSDictionary *listing = ApolloGQLLegacyOwnPostsListing(upvoted, @"upvoted", YES);
    NSArray *children = listing[@"data"][@"children"];
    CHECK(children.count == 2 && [children[0][@"kind"] isEqualToString:@"t3"] && [children[1][@"data"][@"name"] isEqualToString:@"t3_two"],
          @"upvoted posts in order (%@)", [children valueForKeyPath:@"data.name"]);
    CHECK([children[0][@"data"][@"likes"] isEqual:@YES] && [children[0][@"data"][@"title"] isEqualToString:@"First"], @"each one a whole post");
    CHECK([listing[@"data"][@"after"] isEqualToString:@"t3_two"], @"the next page starts after the last post (%@)", listing[@"data"][@"after"]);
    CHECK(ApolloGQLLegacyOwnPostsListing(upvoted, @"hidden", YES) == nil, @"another list isn't in this answer");
    NSDictionary *none = ParseJSON(@"{\"data\":{\"identity\":{\"hiddenPosts\":{\"edges\":[],\"pageInfo\":{\"endCursor\":null,\"hasNextPage\":false}}}}}");
    NSDictionary *empty = ApolloGQLLegacyOwnPostsListing(none, @"hidden", YES);
    CHECK(empty && [empty[@"data"][@"children"] count] == 0 && empty[@"data"][@"after"] == [NSNull null], @"an empty list is a real answer");
    CHECK(ApolloGQLLegacyOwnPostsListing(ParseJSON(@"{\"data\":{\"identity\":null}}"), @"upvoted", YES) == nil, @"no identity, no list");

    // A profile's comments: the page of ids names each comment's post, and
    // LiveCommentsByIds has the comments, in whatever order it likes.
    NSDictionary *page = ParseJSON(@"{\"data\":{\"redditorInfoByName\":{\"__typename\":\"Redditor\",\"comments\":{\"edges\":["
        "{\"node\":{\"id\":\"t1_aaa\",\"postInfo\":{\"id\":\"t3_one\",\"title\":\"Fish & <chips>\",\"subreddit\":{\"prefixedName\":\"r/test\"}}}},"
        "{\"node\":{\"id\":\"t1_bbb\",\"postInfo\":{\"id\":\"t3_two\",\"title\":\"Second\",\"subreddit\":{\"prefixedName\":\"r/other\"}}}},"
        "{\"node\":{\"id\":\"t1_gone\",\"postInfo\":{\"id\":\"t3_two\",\"title\":\"Second\",\"subreddit\":{\"prefixedName\":\"r/other\"}}}}],"
        "\"pageInfo\":{\"endCursor\":\"dDFfYmJi\",\"hasNextPage\":true}}}}}");
    NSDictionary *comments = ParseJSON(@"{\"data\":{\"commentsByIds\":["
        "{\"__typename\":\"Comment\",\"id\":\"t1_bbb\",\"permalink\":\"/r/other/comments/two/second/bbb/\",\"score\":3,\"voteState\":\"NONE\","
        "\"createdAt\":\"2026-11-25T16:30:30.145000+0000\",\"content\":{\"markdown\":\"Later\",\"richtext\":null,\"richtextMedia\":[]},"
        "\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_u\",\"name\":\"Someone\"}},"
        "{\"__typename\":\"Comment\",\"id\":\"t1_aaa\",\"permalink\":\"/r/test/comments/one/first/aaa/\",\"score\":9,\"voteState\":\"UP\",\"isOP\":true,"
        "\"createdAt\":\"2026-11-25T16:30:30.145000+0000\",\"content\":{\"markdown\":\"Earlier\",\"richtext\":null,\"richtextMedia\":[]},"
        "\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_u\",\"name\":\"Someone\"}}]}}");
    NSString *next = @"unset";
    NSArray *fullnames = ApolloGQLUserCommentFullnames(page, &next);
    CHECK([fullnames isEqualToArray:(@[ @"t1_aaa", @"t1_bbb", @"t1_gone" ])] && [next isEqualToString:@"t1_bbb"], @"comment ids and the next page (%@ %@)", fullnames, next);
    NSDictionary *profile = ApolloGQLLegacyUserCommentsListing(page, comments, YES);
    NSArray *things = profile[@"data"][@"children"];
    CHECK(things.count == 2 && [things[0][@"kind"] isEqualToString:@"t1"], @"the comments LiveCommentsByIds had (%lu)", (unsigned long)things.count);
    NSDictionary *first = things.firstObject[@"data"];
    CHECK([first[@"name"] isEqualToString:@"t1_aaa"] && [things[1][@"data"][@"name"] isEqualToString:@"t1_bbb"], @"in the profile's order, not the answer's");
    CHECK([first[@"link_id"] isEqualToString:@"t3_one"] && [first[@"link_title"] isEqualToString:@"Fish & <chips>"] &&
          [first[@"subreddit"] isEqualToString:@"test"] && [first[@"subreddit_name_prefixed"] isEqualToString:@"r/test"],
          @"each comment's post and subreddit (%@ %@ %@)", first[@"link_id"], first[@"link_title"], first[@"subreddit"]);
    CHECK([first[@"link_permalink"] isEqualToString:@"https://www.reddit.com/r/test/comments/one/first/"] &&
          [first[@"permalink"] isEqualToString:@"/r/test/comments/one/first/aaa/"], @"the thread's address (%@)", first[@"link_permalink"]);
    CHECK([first[@"body"] isEqualToString:@"Earlier"] && [first[@"likes"] isEqual:@YES] && [first[@"is_submitter"] isEqual:@YES] &&
          [first[@"author"] isEqualToString:@"Someone"] && [first[@"replies"] isEqual:@""] && [first[@"parent_id"] isEqualToString:@"t3_one"],
          @"the comment itself");
    CHECK(first[@"link_author"] == nil, @"what GraphQL doesn't say is absent");
    CHECK([profile[@"data"][@"after"] isEqualToString:@"t1_bbb"], @"the next page starts after the page's last comment");
    NSDictionary *escaped = ApolloGQLLegacyUserCommentsListing(page, comments, NO);
    CHECK([escaped[@"data"][@"children"][0][@"data"][@"link_title"] isEqualToString:@"Fish &amp; &lt;chips&gt;"], @"escaped without raw_json");
    NSDictionary *hidden = ParseJSON(@"{\"data\":{\"redditorInfoByName\":{\"comments\":{\"edges\":[],\"pageInfo\":{\"endCursor\":null,\"hasNextPage\":false}}}}}");
    CHECK([ApolloGQLUserCommentFullnames(hidden, NULL) count] == 0 && [ApolloGQLLegacyUserCommentsListing(hidden, @{}, YES)[@"data"][@"children"] count] == 0,
          @"a profile that hides its comments is an empty page");
    CHECK(ApolloGQLUserCommentFullnames(ParseJSON(@"{\"data\":{\"redditorInfoByName\":null}}"), NULL) == nil, @"no such account, no list");
}

static void TestSavedList(void) {
    // The list names posts and comments together, by id, in its own order.
    NSDictionary *page = ParseJSON(@"{\"data\":{\"savedV3\":{\"elements\":{\"dist\":4,\"edges\":["
        "{\"__typename\":\"FeedElementEdge\",\"node\":{\"__typename\":\"SubredditPost\",\"id\":\"t3_one\"}},"
        "{\"__typename\":\"FeedElementEdge\",\"node\":{\"__typename\":\"Comment\",\"id\":\"t1_aaa\"}},"
        "{\"__typename\":\"FeedElementEdge\",\"node\":{\"__typename\":\"Comment\",\"id\":\"t1_orphan\"}},"
        "{\"__typename\":\"FeedElementEdge\",\"node\":{\"__typename\":\"SubredditPost\",\"id\":\"t3_gone\"}}],"
        "\"pageInfo\":{\"endCursor\":\"dDNfZ29uZQ==\"}}}}}");
    BOOL more = NO;
    NSArray *fullnames = ApolloGQLSavedFullnames(page, &more);
    CHECK([fullnames isEqualToArray:(@[ @"t3_one", @"t1_aaa", @"t1_orphan", @"t3_gone" ])] && more, @"saved ids in order, with a page after (%@ %d)", fullnames, more);
    NSDictionary *last = ParseJSON(@"{\"data\":{\"savedV3\":{\"elements\":{\"dist\":0,\"edges\":[],\"pageInfo\":{\"endCursor\":\"\"}}}}}");
    more = YES;
    CHECK([ApolloGQLSavedFullnames(last, &more) isEqualToArray:@[]] && !more, @"an empty list is a real answer, and the last page");
    CHECK(ApolloGQLSavedFullnames(ParseJSON(@"{\"errors\":[{\"message\":\"internal error\"}],\"data\":{\"savedV3\":{\"elements\":null}}}"), NULL) == nil,
          @"GraphQL's own error isn't an empty list");
    CHECK(ApolloGQLSavedFullnames(ParseJSON(@"{\"data\":{\"savedV3\":{\"elements\":{\"edges\":[{\"node\":{\"__typename\":\"CellGroup\",\"id\":\"c29ydA==\"}}],"
                                             "\"pageInfo\":{\"endCursor\":\"\"}}}}}"), NULL) == nil, @"rows of another shape aren't an empty list either");

    // The comments, and from their permalinks the posts they're on.
    NSDictionary *comments = ParseJSON(@"{\"data\":{\"commentsByIds\":["
        "{\"__typename\":\"Comment\",\"id\":\"t1_orphan\",\"permalink\":\"/user/Some_One/comments/lost/a_title/orphan/\",\"score\":2,\"voteState\":\"NONE\","
        "\"createdAt\":\"2026-11-25T16:30:30.145000+0000\",\"content\":{\"markdown\":\"Kept\",\"richtext\":null,\"richtextMedia\":[]},"
        "\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_u\",\"name\":\"Someone\"}},"
        "{\"__typename\":\"Comment\",\"id\":\"t1_aaa\",\"permalink\":\"/r/test/comments/two/second_post/aaa/\",\"score\":9,\"voteState\":\"UP\",\"isSaved\":false,"
        "\"createdAt\":\"2026-11-25T16:30:30.145000+0000\",\"content\":{\"markdown\":\"Saved words\",\"richtext\":null,\"richtextMedia\":[]},"
        "\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_u\",\"name\":\"Someone\"}}]}}");
    NSArray *threads = ApolloGQLCommentPostFullnames(@[ comments ]);
    CHECK([threads isEqualToArray:(@[ @"t3_lost", @"t3_two" ])], @"the posts the comments are on (%@)", threads);
    NSDictionary *posts = ParseJSON(@"{\"data\":{\"postsInfoByIds\":["
        "{\"__typename\":\"SubredditPost\",\"id\":\"t3_two\",\"postTitle\":\"Fish & <chips>\",\"permalink\":\"/r/test/comments/two/second_post/\","
        "\"url\":\"https://example.com/two\",\"commentCount\":385,\"isNsfw\":true,\"authorInfo\":{\"__typename\":\"Redditor\",\"id\":\"t2_p\",\"name\":\"Poster\"},"
        "\"subreddit\":{\"id\":\"t5_x\",\"name\":\"test\",\"prefixedName\":\"r/test\",\"isQuarantined\":false},\"createdAt\":\"2026-11-25T16:30:30.145000+0000\"},"
        "{\"__typename\":\"SubredditPost\",\"id\":\"t3_one\",\"postTitle\":\"First\",\"permalink\":\"/r/test/comments/one/first/\",\"isSaved\":false,"
        "\"subreddit\":{\"id\":\"t5_x\",\"name\":\"test\",\"prefixedName\":\"r/test\"},\"voteState\":\"UP\",\"score\":5,\"createdAt\":\"2026-11-25T16:30:30.145000+0000\"}]}}");
    CHECK(ApolloGQLLegacySavedListing(fullnames, @[ posts ], @[ comments ], nil, YES) == nil, @"no page with a saved post missing from the lookups");
    CHECK(ApolloGQLLegacySavedListing((@[ @"t3_one", @"t1_aaa", @"t1_never" ]), @[ posts ], @[ comments ], nil, YES) == nil,
          @"no page with a saved comment missing from the lookups");
    fullnames = @[ @"t3_one", @"t1_aaa", @"t1_orphan" ];
    NSDictionary *listing = ApolloGQLLegacySavedListing(fullnames, @[ posts ], @[ comments ], @"t1_orphan", YES);
    NSArray *things = listing[@"data"][@"children"];
    CHECK(things.count == 3 && [[things valueForKey:@"kind"] isEqualToArray:(@[ @"t3", @"t1", @"t1" ])] &&
          [[things valueForKeyPath:@"data.name"] isEqualToArray:(@[ @"t3_one", @"t1_aaa", @"t1_orphan" ])],
          @"posts and comments in the list's order (%@)", [things valueForKeyPath:@"data.name"]);
    CHECK([listing[@"data"][@"after"] isEqualToString:@"t1_orphan"], @"the next page's start is the caller's to say (%@)", listing[@"data"][@"after"]);
    NSDictionary *post = things[0][@"data"], *comment = things[1][@"data"], *orphan = things[2][@"data"];
    CHECK([post[@"title"] isEqualToString:@"First"] && [post[@"saved"] isEqual:@YES] && [post[@"likes"] isEqual:@YES], @"a whole post, marked saved");
    CHECK([comment[@"body"] isEqualToString:@"Saved words"] && [comment[@"saved"] isEqual:@YES] && [comment[@"likes"] isEqual:@YES] &&
          [comment[@"replies"] isEqual:@""], @"the comment itself, marked saved");
    CHECK([comment[@"link_id"] isEqualToString:@"t3_two"] && [comment[@"parent_id"] isEqualToString:@"t3_two"] &&
          [comment[@"link_title"] isEqualToString:@"Fish & <chips>"] && [comment[@"link_author"] isEqualToString:@"Poster"] &&
          [comment[@"link_url"] isEqualToString:@"https://example.com/two"] && [comment[@"num_comments"] isEqual:@385] && [comment[@"over_18"] isEqual:@YES] &&
          [comment[@"quarantine"] isEqual:@NO], @"its post's details (%@ %@ %@)", comment[@"link_title"], comment[@"link_author"], comment[@"num_comments"]);
    CHECK([comment[@"subreddit"] isEqualToString:@"test"] && [comment[@"subreddit_id"] isEqualToString:@"t5_x"] &&
          [comment[@"subreddit_name_prefixed"] isEqualToString:@"r/test"] &&
          [comment[@"link_permalink"] isEqualToString:@"https://www.reddit.com/r/test/comments/two/second_post/"], @"its subreddit and thread (%@)", comment[@"link_permalink"]);
    CHECK([orphan[@"link_id"] isEqualToString:@"t3_lost"] && [orphan[@"subreddit"] isEqualToString:@"u_Some_One"] && [orphan[@"link_title"] isEqualToString:@""] &&
          orphan[@"link_author"] == nil && [orphan[@"body"] isEqualToString:@"Kept"],
          @"a comment whose post is gone keeps what its permalink says (%@ %@)", orphan[@"link_id"], orphan[@"subreddit"]);
    NSDictionary *escaped = ApolloGQLLegacySavedListing(fullnames, @[ posts ], @[ comments ], nil, NO);
    CHECK([escaped[@"data"][@"children"][1][@"data"][@"link_title"] isEqualToString:@"Fish &amp; &lt;chips&gt;"] && escaped[@"data"][@"after"] == [NSNull null],
          @"escaped without raw_json, and a last page");
    CHECK([ApolloGQLLegacySavedListing(@[], @[], @[], nil, YES)[@"data"][@"children"] count] == 0, @"nothing saved");
}

static void TestPlanForLists(void) {
    ApolloGQLRequest *upvoted = ApolloGQLRequestForLegacy(@"GET", @"user/Some_One/upvoted.json", (@{ @"limit": @25, @"raw_json": @1 }));
    CHECK(upvoted.kind == ApolloGQLRequestKindOwnPosts && [upvoted.username isEqualToString:@"Some_One"] && [upvoted.ownList isEqualToString:@"upvoted"] &&
          upvoted.rawJSON, @"the account's upvoted posts (%ld %@ %@)", (long)upvoted.kind, upvoted.username, upvoted.ownList);
    CHECK([ApolloGQLOwnPostsOperation(upvoted) isEqualToString:@"UpvotedPosts"] && [ApolloGQLOwnPostsVariables(upvoted) isEqualToDictionary:@{}], @"first page");
    CHECK(ApolloGQLRequestIsForAccount(upvoted, @"some_one") && !ApolloGQLRequestIsForAccount(upvoted, @"another") && !ApolloGQLRequestIsForAccount(upvoted, nil),
          @"only the account's own list");
    ApolloGQLRequest *hidden = ApolloGQLRequestForLegacy(@"GET", @"/user/someone/hidden", (@{ @"after": @"t3_last" }));
    CHECK([ApolloGQLOwnPostsOperation(hidden) isEqualToString:@"HiddenPosts"] &&
          [ApolloGQLOwnPostsVariables(hidden) isEqualToDictionary:(@{ @"after": @"dDNfbGFzdA==" })], @"a later page (%@)", ApolloGQLOwnPostsVariables(hidden));
    CHECK([ApolloGQLOwnPostsOperation(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/downvoted", nil)) isEqualToString:@"DownvotedPosts"], @"downvoted");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/upvoted", (@{ @"sort": @"top" })) == nil, @"GraphQL has these newest first only");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/upvoted", (@{ @"after": @"t1_x" })) == nil, @"a page after something that isn't a post");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/overview", nil) == nil && ApolloGQLRequestForLegacy(@"GET", @"/user/someone/gilded", nil) == nil,
          @"lists GraphQL isn't asked for");

    // The saved list, as Apollo asks for it at launch and from its Saved screen.
    ApolloGQLRequest *saved = ApolloGQLRequestForLegacy(@"GET", @"user/Some_One/saved.json", (@{ @"api_type": @"json", @"limit": @100, @"raw_json": @1 }));
    CHECK(saved.kind == ApolloGQLRequestKindOwnSaved && [saved.username isEqualToString:@"Some_One"] && saved.limit == 100 && saved.after == nil && saved.rawJSON,
          @"the account's saved list (%ld %@ %ld)", (long)saved.kind, saved.username, (long)saved.limit);
    CHECK([ApolloGQLSavedVariables(saved.after) isEqualToDictionary:@{}], @"first page");
    ApolloGQLRequest *screen = ApolloGQLRequestForLegacy(@"GET", @"user/Some_One/saved/(null).json", (@{ @"limit": @12, @"after": @"t1_last" }));
    CHECK(screen.kind == ApolloGQLRequestKindOwnSaved && screen.limit == 12 && [ApolloGQLSavedVariables(screen.after) isEqualToDictionary:(@{ @"after": @"dDFfbGFzdA==" })],
          @"the Saved screen's path, a page after a comment (%ld %@)", (long)screen.kind, ApolloGQLSavedVariables(screen.after));
    CHECK([ApolloGQLSavedVariables(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/saved", (@{ @"after": @"t3_last" })).after)
           isEqualToDictionary:(@{ @"after": @"dDNfbGFzdA==" })], @"a page after a post");
    CHECK(ApolloGQLRequestIsForAccount(saved, @"some_one") && !ApolloGQLRequestIsForAccount(saved, @"another") && !ApolloGQLRequestIsForAccount(saved, nil),
          @"only the account's own saved list");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/saved", (@{ @"type": @"comments" })) == nil &&
          ApolloGQLRequestForLegacy(@"GET", @"/user/someone/saved", (@{ @"sr": @"apple" })) == nil &&
          ApolloGQLRequestForLegacy(@"GET", @"/user/someone/saved", (@{ @"sort": @"top" })) == nil &&
          ApolloGQLRequestForLegacy(@"GET", @"/user/someone/saved", (@{ @"before": @"t3_x" })) == nil &&
          ApolloGQLRequestForLegacy(@"GET", @"/user/someone/saved", (@{ @"after": @"t5_x" })) == nil, @"a saved list cut down, re-sorted or paged another way");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/saved/top", nil) == nil && ApolloGQLRequestForLegacy(@"GET", @"/user/someone/upvoted/(null)", nil) == nil &&
          ApolloGQLRequestForLegacy(@"POST", @"/user/someone/saved", nil) == nil, @"only the two paths Apollo reads it by");

    ApolloGQLRequest *comments = ApolloGQLRequestForLegacy(@"GET", @"user/Some_One/comments.json", (@{ @"sort": @"top", @"t": @"week", @"after": @"t1_last", @"limit": @25 }));
    NSDictionary *expected = @{ @"name": @"Some_One", @"sort": @"TOP", @"range": @"WEEK", @"after": @"dDFfbGFzdA==" };
    CHECK(ApolloGQLRequestIsForAccount(comments, @"another"), @"anyone's comments");
    CHECK(comments.kind == ApolloGQLRequestKindUserComments && [ApolloGQLUserCommentsVariables(comments) isEqualToDictionary:expected],
          @"a profile's comments (%@)", ApolloGQLUserCommentsVariables(comments));
    CHECK([ApolloGQLUserCommentsVariables(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/comments", nil)) isEqualToDictionary:(@{ @"name": @"someone", @"sort": @"NEW" })],
          @"newest first by default");
    CHECK([ApolloGQLUserCommentsVariables(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/comments", (@{ @"sort": @"top" })))[@"range"] isEqualToString:@"ALL"],
          @"top of all time by default");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/comments", (@{ @"before": @"t1_x" })) == nil, @"a page asked for by before");
    CHECK(ApolloGQLRequestForLegacy(@"GET", @"/user/someone/comments", (@{ @"after": @"t3_x" })) == nil, @"a page after something that isn't a comment");
    NSDictionary *byIds = ApolloGQLCommentsByIdsVariables(@[ @"t1_a" ]);
    CHECK([byIds[@"ids"] isEqualToArray:(@[ @"t1_a" ])] && [byIds[@"includePremiumAvatarTreatment"] isEqual:@NO], @"comments by id (%@)", byIds);

    CHECK(ApolloGQLCanAnswerPath(@"GET", @"/user/*/saved") && ApolloGQLCanAnswerPath(@"GET", @"/user/*/saved/(null)") &&
          !ApolloGQLCanAnswerPath(@"GET", @"/user/*/m/*/hot") && !ApolloGQLCanAnswerPath(@"GET", @"/api/multi/mine"), @"saved, and not multireddits");
    CHECK(ApolloGQLCanAnswerPath(@"GET", @"/user/*/comments") && ApolloGQLCanAnswerPath(@"GET", @"/user/*/upvoted") &&
          !ApolloGQLCanAnswerPath(@"GET", @"/subreddits/search") && !ApolloGQLCanAnswerPath(@"GET", @"/subreddits/mine/subscriber"), @"endpoint patterns");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: gql_legacy_tests <repo root>\n"); return 2; }
        TestPostsAgainstLegacy(@(argv[1]));
        TestCommentsAgainstLegacy(@(argv[1]));
        TestSubredditsAgainstLegacy(@(argv[1]));
        TestCommentThreads(@(argv[1]));
        TestMoreToken();
        TestSearchListing();
        TestPostBasics();
        TestVideoFallback();
        TestListingAndFeed();
        TestRichText();
        TestPlan();
        TestAuthorRecords();
        TestPlanForOwnReads();
        TestOwnPostsAndUserComments();
        TestSavedList();
        TestPlanForLists();
    }
    if (sFailures) {
        fprintf(stderr, "%d failure(s)\n", sFailures);
        return 1;
    }
    printf("gql legacy tests passed\n");
    return 0;
}
