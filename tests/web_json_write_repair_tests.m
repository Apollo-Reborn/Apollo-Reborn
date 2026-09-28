// Host-side regression harness for src/ApolloWebJSONWriteRepair.m: feeds captured
// degraded /api/editusertext and /api/comment shapes through the real repair and
// asserts the modern shape that comes out. One scenario per process (the module
// keeps its pending-write state in statics).
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import "ApolloWebJSONWriteRepair.h"

#pragma mark - Stubs the module takes from the rest of the tweak

static NSString *gWebSessionUsername = nil;
static NSString *gActiveUsername = @"ActiveUser";
static NSDictionary *gPrefetchResult = nil;
static NSUInteger gPrefetchCalls = 0;

NSString *ApolloActiveWebSessionUsername(void) { return gWebSessionUsername; }
NSString *ApolloActiveAccountUsername(void) { return gActiveUsername; }
void ApolloWebJSONPrefetchModernThingData(NSString *fullname, void (^completion)(NSDictionary *data)) {
    (void)fullname;
    gPrefetchCalls++;
    if (gPrefetchResult) completion(gPrefetchResult);
}

#pragma mark - Model doubles (same property names + Mantle key map as RedditKit)

@interface WJFakeFlair : NSObject
@property (nonatomic, copy) NSString *flairType;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *emojiLabel;
@property (nonatomic, copy) NSURL *imageURL;
+ (NSDictionary *)JSONKeyPathsByPropertyKey;
@end
@implementation WJFakeFlair
+ (NSDictionary *)JSONKeyPathsByPropertyKey {
    return @{ @"flairType": @"e", @"text": @"t", @"emojiLabel": @"a", @"imageURL": @"u" };
}
@end

@interface WJFakeComment : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *kindName;
@property (nonatomic, copy) NSString *fullName;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *authorFullName;
@property (nonatomic, copy) NSString *body;
@property (nonatomic, copy) NSString *bodyHTML;
@property (nonatomic, strong) NSDate *createdUTC;
@property (nonatomic, strong) NSDate *edited;
@property (nonatomic, strong) NSDate *bannedAt;
@property (nonatomic) long long score;
@property (nonatomic) long long upvotes;
@property (nonatomic) long long downvotes;
@property (nonatomic) unsigned long long voteStatus;
@property (nonatomic) unsigned long long distinguished;
@property (nonatomic) unsigned long long gilded;
@property (nonatomic) BOOL stickied;
@property (nonatomic) BOOL isLocked;
@property (nonatomic) BOOL scoreHidden;
@property (nonatomic, copy) NSString *subreddit;
@property (nonatomic, copy) NSString *subredditID;
@property (nonatomic, copy) NSString *linkID;
@property (nonatomic, copy) NSString *parentID;
@property (nonatomic, copy) NSString *authorFlairPlaintext;
@property (nonatomic, strong) NSArray *authorFlairRichtext;
@property (nonatomic, strong) NSArray *awards;
@property (nonatomic, strong) NSArray *replies;
@property (nonatomic, copy) NSString *submissionContentText;
+ (NSDictionary *)JSONKeyPathsByPropertyKey;
@end
@implementation WJFakeComment
+ (NSDictionary *)JSONKeyPathsByPropertyKey {
    return @{
        @"identifier": @"data.id", @"kindName": @"kind", @"author": @"data.author",
        @"authorFullName": @"data.author_fullname", @"body": @"data.body", @"bodyHTML": @"data.body_html",
        @"createdUTC": @"data.created_utc", @"edited": @"data.edited", @"bannedAt": @"data.banned_at_utc",
        @"score": @"data.score", @"upvotes": @"data.ups", @"downvotes": @"data.downs",
        @"voteStatus": @"data.likes", @"distinguished": @"data.distinguished", @"gilded": @"data.gilded",
        @"stickied": @"data.stickied", @"isLocked": @"data.locked", @"scoreHidden": @"data.score_hidden",
        @"subreddit": @"data.subreddit", @"subredditID": @"data.subreddit_id", @"linkID": @"data.link_id",
        @"parentID": @"data.parent_id", @"authorFlairPlaintext": @"data.author_flair_text",
        @"authorFlairRichtext": @"data.author_flair_richtext", @"awards": @"data.all_awardings",
        @"replies": @"data.replies", @"submissionContentText": @"data.contentText",
    };
}
@end

static WJFakeComment *WJEditedComment(void) {
    WJFakeFlair *text = [WJFakeFlair new];
    text.flairType = @"text"; text.text = @"hi";
    WJFakeFlair *emoji = [WJFakeFlair new];
    emoji.flairType = @"emoji"; emoji.emojiLabel = @":x:"; emoji.imageURL = [NSURL URLWithString:@"https://e/x.png"];

    WJFakeComment *c = [WJFakeComment new];
    c.identifier = @"abc"; c.kindName = @"t1"; c.fullName = @"t1_abc";
    c.author = @"Someone"; c.authorFullName = @"t2_1";
    c.body = @"old body"; c.bodyHTML = @"<div class=\"md\"><p>old body</p></div>";
    c.createdUTC = [NSDate dateWithTimeIntervalSince1970:1700000000];
    c.bannedAt = [NSDate dateWithTimeIntervalSince1970:0];
    c.score = 42; c.upvotes = 42; c.voteStatus = 0; c.distinguished = 1; c.gilded = 0;
    c.stickied = NO; c.isLocked = NO; c.scoreHidden = NO;
    c.subreddit = @"test"; c.subredditID = @"t5_x"; c.linkID = @"t3_link"; c.parentID = @"t3_link";
    c.authorFlairPlaintext = @"hi:x:"; c.authorFlairRichtext = @[text, emoji];
    c.awards = @[[NSObject new]]; c.replies = @[];
    c.submissionContentText = @"must not leak";
    return c;
}

#pragma mark - Response builders

static NSHTTPURLResponse *WJResponse(NSString *path) {
    NSURL *url = [NSURL URLWithString:[@"https://oauth.reddit.com" stringByAppendingString:path]];
    return [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
                                     headerFields:@{ @"Content-Type": @"application/json" }];
}

static NSDictionary *WJEnvelope(NSArray *things, NSArray *errors) {
    return @{ @"json": @{ @"errors": errors ?: @[], @"data": @{ @"things": things } } };
}

static NSDictionary *WJLegacyThing(NSString *fullname, NSString *author, NSString *permalink,
                                   NSString *parent, NSString *link, NSString *text) {
    NSString *content = [NSString stringWithFormat:
        @"<div class=\"thing id-%@ comment\" data-fullname=\"%@\" data-author=\"%@\" data-permalink=\"%@\">"
        @"<div class=\"md\"><p>%@</p></div></div>", fullname, fullname, author, permalink, text];
    NSString *kind = [fullname hasPrefix:@"t3_"] ? @"t3" : @"t1";
    return @{ @"kind": kind, @"data": @{
        @"id": fullname, @"parent": parent, @"link": link, @"content": content,
        @"contentText": text, @"contentHTML": [NSString stringWithFormat:@"<div class=\"md\"><p>%@</p></div>", text],
        @"replies": @"" } };
}

static NSDictionary *WJThingData(id out) {
    id root = [out isKindOfClass:[NSData class]] ? [NSJSONSerialization JSONObjectWithData:out options:0 error:NULL] : out;
    NSArray *things = root[@"json"][@"data"][@"things"];
    return things.count ? things[0][@"data"] : nil;
}

#pragma mark - Assertions

static int gFailures = 0;
#define WJ_ASSERT(cond, fmt, ...) do { if (!(cond)) { gFailures++; \
    NSLog(@"FAIL line %d: %@", __LINE__, [NSString stringWithFormat:(fmt), ##__VA_ARGS__]); } } while (0)
#define WJ_ASSERT_EQ(actual, expected) WJ_ASSERT([(actual) isEqual:(expected)] || ((actual) == nil && (expected) == nil), \
                                                 @"%s = %@, expected %@", #actual, (actual), (expected))

static double WJMilliseconds(uint64_t ticks) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    return (double)ticks * tb.numer / tb.denom / 1e6;
}

#pragma mark - Scenarios

static void WJAssertFilledFromModel(NSDictionary *td, NSString *newBody) {
    WJ_ASSERT_EQ(td[@"name"], @"t1_abc");
    WJ_ASSERT_EQ(td[@"id"], @"abc");
    WJ_ASSERT_EQ(td[@"author"], @"Someone");
    WJ_ASSERT_EQ(td[@"author_fullname"], @"t2_1");
    WJ_ASSERT_EQ(td[@"created_utc"], @1700000000);
    WJ_ASSERT_EQ(td[@"created"], @1700000000);
    WJ_ASSERT_EQ(td[@"score"], @42);
    WJ_ASSERT_EQ(td[@"likes"], @YES);
    WJ_ASSERT_EQ(td[@"distinguished"], @"moderator");
    WJ_ASSERT_EQ(td[@"subreddit"], @"test");
    WJ_ASSERT_EQ(td[@"subreddit_id"], @"t5_x");
    WJ_ASSERT_EQ(td[@"link_id"], @"t3_link");
    WJ_ASSERT_EQ(td[@"parent_id"], @"t3_link");
    WJ_ASSERT_EQ(td[@"permalink"], @"/r/test/comments/link/_/abc/");
    WJ_ASSERT_EQ(td[@"author_flair_text"], @"hi:x:");
    NSArray *richtext = @[ @{ @"e": @"text", @"t": @"hi" }, @{ @"e": @"emoji", @"a": @":x:", @"u": @"https://e/x.png" } ];
    WJ_ASSERT_EQ(td[@"author_flair_richtext"], richtext);
    WJ_ASSERT_EQ(td[@"replies"], @"");
    WJ_ASSERT_EQ(td[@"body"], newBody);
    WJ_ASSERT([td[@"body_html"] containsString:newBody], @"body_html lacks the new text: %@", td[@"body_html"]);
    WJ_ASSERT([td[@"edited"] isKindOfClass:[NSNumber class]] && [td[@"edited"] doubleValue] > 1700000000, @"edited = %@", td[@"edited"]);
    WJ_ASSERT(td[@"banned_at_utc"] == nil, @"epoch-zero banned_at leaked: %@", td[@"banned_at_utc"]);
    WJ_ASSERT(td[@"all_awardings"] == nil, @"unreversible awards leaked: %@", td[@"all_awardings"]);
    WJ_ASSERT(td[@"contentText"] == nil, @"legacy field leaked from the model: %@", td[@"contentText"]);
}

static void ScenarioLegacyEditCaptured(void) {
    ApolloWebJSONNoteCommentEditContext(nil, @"new body", WJEditedComment());
    NSDictionary *thing = WJLegacyThing(@"t1_abc", @"Someone", @"/r/test/comments/link/slug/abc/", @"t3_link", @"t3_link", @"new body");
    uint64_t t0 = mach_absolute_time();
    id out = ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/editusertext"), WJEnvelope(@[thing], nil));
    double ms = WJMilliseconds(mach_absolute_time() - t0);
    WJ_ASSERT(ms < 100, @"repair took %.1f ms", ms);
    WJ_ASSERT_EQ(out[@"json"][@"data"][@"things"][0][@"kind"], @"t1");
    WJAssertFilledFromModel(WJThingData(out), @"new body");
    WJ_ASSERT(gPrefetchCalls == 0, @"comment edit started a prefetch");
}

static void ScenarioModernDegradedEditCaptured(void) {
    ApolloWebJSONNoteCommentEditContext(nil, @"new body", WJEditedComment());
    // The wild degraded payload keeps body + identity, drops author/created/score/location.
    NSDictionary *thing = @{ @"kind": @"t1", @"data": @{ @"id": @"abc", @"name": @"t1_abc", @"body": @"new body",
                                                        @"body_html": @"<div class=\"md\"><p>new body</p></div>",
                                                        @"likes": [NSNull null], @"gilded": @3 } };
    id out = ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/editusertext"), WJEnvelope(@[thing], nil));
    NSDictionary *td = WJThingData(out);
    WJAssertFilledFromModel(td, @"new body");
    WJ_ASSERT_EQ(td[@"gilded"], @3); // what the payload kept stays Reddit's word
}

static void ScenarioModernEditKeepsResponseScore(void) {
    ApolloWebJSONNoteCommentEditContext(nil, @"new body", WJEditedComment());
    NSDictionary *thing = @{ @"kind": @"t1", @"data": @{ @"id": @"abc", @"name": @"t1_abc", @"body": @"new body",
                                                        @"body_html": @"x", @"score": @7 } };
    NSDictionary *td = WJThingData(ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/editusertext"), WJEnvelope(@[thing], nil)));
    WJ_ASSERT_EQ(td[@"score"], @7);
    WJ_ASSERT_EQ(td[@"author"], @"Someone");
    WJ_ASSERT_EQ(td[@"created_utc"], @1700000000);
}

static void ScenarioLegacyEditUncaptured(void) {
    NSDictionary *thing = WJLegacyThing(@"t1_abc", @"Someone", @"/r/test/comments/link/slug/abc/", @"t3_link", @"t3_link", @"new body");
    uint64_t t0 = mach_absolute_time();
    NSDictionary *td = WJThingData(ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/editusertext"), WJEnvelope(@[thing], nil)));
    WJ_ASSERT(WJMilliseconds(mach_absolute_time() - t0) < 100, @"uncaptured edit waited");
    WJ_ASSERT_EQ(td[@"author"], @"Someone");
    WJ_ASSERT_EQ(td[@"body"], @"new body");
    WJ_ASSERT_EQ(td[@"score"], @1);
    WJ_ASSERT_EQ(td[@"subreddit"], @"test");
    WJ_ASSERT_EQ(td[@"link_id"], @"t3_link");
    WJ_ASSERT([td[@"created_utc"] doubleValue] > 1700000000, @"created_utc = %@", td[@"created_utc"]);
    WJ_ASSERT(gPrefetchCalls == 0, @"uncaptured edit started a prefetch");
}

static void ScenarioLegacyCreate(void) {
    ApolloWebJSONNoteCommentWriteContext(nil, @"hello", @"test", @"t5_x", @"t3_link", @"t1_parent");
    NSDictionary *thing = WJLegacyThing(@"t1_new", @"Someone", @"/r/test/comments/link/slug/new/", @"t1_parent", @"t3_link", @"hello");
    id out = ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/comment"), WJEnvelope(@[thing], nil));
    NSDictionary *td = WJThingData(out);
    WJ_ASSERT_EQ(td[@"name"], @"t1_new");
    WJ_ASSERT_EQ(td[@"author"], @"Someone");
    WJ_ASSERT_EQ(td[@"body"], @"hello");
    WJ_ASSERT_EQ(td[@"score"], @1);
    WJ_ASSERT_EQ(td[@"likes"], @YES);
    WJ_ASSERT_EQ(td[@"parent_id"], @"t1_parent");
    WJ_ASSERT_EQ(td[@"link_id"], @"t3_link");
    WJ_ASSERT_EQ(td[@"subreddit"], @"test");
    WJ_ASSERT_EQ(td[@"subreddit_id"], @"t5_x");
    WJ_ASSERT_EQ(td[@"edited"], @NO);
}

static void ScenarioModernHealthyNoop(void) {
    NSDictionary *thing = @{ @"kind": @"t1", @"data": @{ @"id": @"abc", @"name": @"t1_abc", @"author": @"Someone",
                                                        @"body": @"x", @"body_html": @"x", @"score": @3, @"created_utc": @1700000000,
                                                        @"created": @1700000000, @"subreddit": @"test", @"link_id": @"t3_link",
                                                        @"parent_id": @"t3_link", @"permalink": @"/r/test/comments/link/_/abc/" } };
    NSDictionary *envelope = WJEnvelope(@[thing], nil);
    id out = ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/comment"), envelope);
    WJ_ASSERT(out == envelope, @"healthy modern response was rewritten");
}

static void ScenarioErrorEnvelopeUntouched(void) {
    ApolloWebJSONNoteCommentEditContext(nil, @"new body", WJEditedComment());
    NSDictionary *thing = WJLegacyThing(@"t1_abc", @"Someone", @"/r/test/comments/link/slug/abc/", @"t3_link", @"t3_link", @"new body");
    NSDictionary *envelope = WJEnvelope(@[thing], @[@[@"RATELIMIT", @"slow down", @"ratelimit"]]);
    id out = ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/editusertext"), envelope);
    WJ_ASSERT(out == envelope, @"error envelope was rewritten");
}

static void ScenarioDataInDataOut(void) {
    ApolloWebJSONNoteCommentEditContext(nil, @"new body", WJEditedComment());
    NSDictionary *thing = WJLegacyThing(@"t1_abc", @"Someone", @"/r/test/comments/link/slug/abc/", @"t3_link", @"t3_link", @"new body");
    NSData *in = [NSJSONSerialization dataWithJSONObject:WJEnvelope(@[thing], nil) options:0 error:NULL];
    id out = ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/editusertext"), in);
    WJ_ASSERT([out isKindOfClass:[NSData class]], @"NSData in, %@ out", [out class]);
    WJAssertFilledFromModel(WJThingData(out), @"new body");
}

static void ScenarioSelfTextEditPrefetched(void) {
    gPrefetchResult = @{ @"id": @"link", @"name": @"t3_link", @"title": @"A post", @"author": @"Someone",
                         @"selftext": @"old text", @"selftext_html": @"old", @"score": @5, @"subreddit": @"test",
                         @"created_utc": @1700000000 };
    ApolloWebJSONNoteSelfTextEditContext(nil, @"new text", @"t3_link");
    WJ_ASSERT(gPrefetchCalls == 1, @"prefetch calls = %lu", (unsigned long)gPrefetchCalls);
    NSDictionary *thing = WJLegacyThing(@"t3_link", @"Someone", @"/r/test/comments/link/slug/", @"", @"t3_link", @"new text");
    id out = ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/editusertext"), WJEnvelope(@[thing], nil));
    NSDictionary *td = WJThingData(out);
    WJ_ASSERT_EQ(out[@"json"][@"data"][@"things"][0][@"kind"], @"t3");
    WJ_ASSERT_EQ(td[@"title"], @"A post");
    WJ_ASSERT_EQ(td[@"score"], @5);
    WJ_ASSERT_EQ(td[@"selftext"], @"new text");
    WJ_ASSERT([td[@"selftext_html"] containsString:@"new text"], @"selftext_html = %@", td[@"selftext_html"]);
    WJ_ASSERT([td[@"edited"] doubleValue] > 1700000000, @"edited = %@", td[@"edited"]);
}

static void ScenarioSelfTextEditPrefetchPending(void) {
    gPrefetchResult = nil; // never lands
    ApolloWebJSONNoteSelfTextEditContext(nil, @"new text", @"t3_link");
    NSDictionary *thing = WJLegacyThing(@"t3_link", @"Someone", @"/r/test/comments/link/slug/", @"", @"t3_link", @"new text");
    NSDictionary *envelope = WJEnvelope(@[thing], nil);
    uint64_t t0 = mach_absolute_time();
    id out = ApolloWebJSONFixupWriteResponseObject(WJResponse(@"/api/editusertext"), envelope);
    WJ_ASSERT(WJMilliseconds(mach_absolute_time() - t0) < 100, @"pending prefetch was waited on");
    WJ_ASSERT(out == envelope, @"unrepairable self-text edit was rewritten");
}

static void ScenarioSelfTextCaptureIgnoresComments(void) {
    ApolloWebJSONNoteSelfTextEditContext(nil, @"new body", @"t1_abc");
    WJ_ASSERT(gPrefetchCalls == 0, @"a t1 thing_id started a self-text prefetch");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { NSLog(@"usage: %s <scenario>", argv[0]); return 2; }
        NSString *scenario = @(argv[1]);
        NSDictionary<NSString *, void (^)(void)> *scenarios = @{
            @"legacy-edit-captured": ^{ ScenarioLegacyEditCaptured(); },
            @"modern-degraded-edit-captured": ^{ ScenarioModernDegradedEditCaptured(); },
            @"modern-edit-keeps-response-score": ^{ ScenarioModernEditKeepsResponseScore(); },
            @"legacy-edit-uncaptured": ^{ ScenarioLegacyEditUncaptured(); },
            @"legacy-create": ^{ ScenarioLegacyCreate(); },
            @"modern-healthy-noop": ^{ ScenarioModernHealthyNoop(); },
            @"error-envelope-untouched": ^{ ScenarioErrorEnvelopeUntouched(); },
            @"data-in-data-out": ^{ ScenarioDataInDataOut(); },
            @"selftext-edit-prefetched": ^{ ScenarioSelfTextEditPrefetched(); },
            @"selftext-edit-prefetch-pending": ^{ ScenarioSelfTextEditPrefetchPending(); },
            @"selftext-capture-ignores-comments": ^{ ScenarioSelfTextCaptureIgnoresComments(); },
        };
        void (^run)(void) = scenarios[scenario];
        if (!run) { NSLog(@"unknown scenario %@", scenario); return 2; }
        run();
        if (gFailures) { NSLog(@"%@: %d failure(s)", scenario, gFailures); return 1; }
        NSLog(@"%@: ok", scenario);
        return 0;
    }
}
