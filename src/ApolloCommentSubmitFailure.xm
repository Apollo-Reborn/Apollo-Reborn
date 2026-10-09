// Explain why a comment didn't post.
//
// When Reddit refuses a comment for a reason RedditKit doesn't recognize, Apollo shows
// "Server Error — There was an error submitting the post, this probably means Reddit had a
// little hiccup. Try again shortly." That is what you get for commenting on a post the
// moderators removed after you opened it, on a thread that got locked, under a deleted post or
// comment… None of those are hiccups, and Retry can never succeed.
//
// How Apollo gets there (Hopper, Apollo 1.15.11):
//  - -[RDKResponseSerializer responseObjectForResponse:data:error:] turns only a fixed set of
//    answers into an NSError in RDKClientErrorDomain (+[RDKClient errorFromStatusCode:
//    responseString:extraInfo:]): json.errors RATELIMIT → 204, TOO_OLD → 206, BAD_CAPTCHA → 201, …;
//    HTTP 403 → 402, 404 → 404, 5xx → 501-504. Any other json.errors code passes through as an
//    ordinary response object, which -[RDKClient submitComment:onThingWithFullName:completion:]
//    parses into no comment and reports as (nil, nil).
//  - commentSubmitted(_:composeViewController:replyingTo:comment:error:) — shared by the comments
//    list, its header and comment rows, and the feed's PostCellActionTaker — shows an alert
//    whenever the comment is nil. One helper (sub_1001b2338) picks its text: no error → "Server
//    Error" + the hiccup line; 204 → "Posting Too Often"; 402 (HTTP 403) → "Authentication Error"
//    + "Reddit thinks there's something weird with your account…"; any other code → "Error
//    Submitting" + "…Reddit might be down/having trouble. Code: N". The caller then adds Copy
//    Text / Retry / Delete. The alert is built synchronously inside the RDKClient completion, on
//    the main thread (the same window ApolloPostedCommentInsert relies on).
//
// So this module:
//  1. notes Reddit's own answer to each POST api/comment (json.errors code + message, HTTP
//     status), keyed by the thing being replied to;
//  2. when a submit fails, looks the thread up through the client that posted (API-key and
//     API-key-free accounts alike) before passing the result on: removed / locked / archived
//     post, a removed or locked parent comment, a subreddit ban or comment restriction — plus where
//     the moderators' reason is (their stickied comment on the post, or the author's inbox) when the
//     post was removed. When the thread shows none of that,
//     Reddit's own answer is used (THREAD_LOCKED, TOO_OLD, DELETED_LINK, or its message);
//  3. while that result is being handed to Apollo, swaps the alert's title and message for the
//     explanation. The actions stay Apollo's own, so Copy Text still keeps the comment.
// When nothing explains the failure, Apollo's alert is left exactly as it was.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloAccountCredentials.h"

// RedditKit's RDKObjectCompletionBlock: the parsed RDKComment (or nil) and an error.
typedef void (^ApolloCommentFailureSubmitCompletion)(id object, NSError *error);
// RedditKit's request completion (getPath:/postPath: → taskWithMethod:path:parameters:completion:).
typedef void (^ApolloCommentFailureTaskCompletion)(NSHTTPURLResponse *response, id responseObject, NSError *error);

// RedditKit's error codes (RDKClientErrorDomain; Hopper: the +[RDKClient …Error] factories).
static NSString *const kApolloCommentFailureRDKErrorDomain = @"RDKClientErrorDomain";
static const NSInteger kApolloCommentFailureAuthRequiredCode = 1;     // not signed in / bad OAuth
static const NSInteger kApolloCommentFailureRateLimitedCode = 204;    // RATELIMIT → "Posting Too Often"
static const NSInteger kApolloCommentFailureArchivedCode = 206;       // TOO_OLD
static const NSInteger kApolloCommentFailureReSignInCode = 400;       // account needs signing in again
// (402 is HTTP 403 — Apollo's "Authentication Error"; looked up like any other refusal.)
static const NSInteger kApolloCommentFailureServerErrorFirstCode = 501; // HTTP 500 … 504
static const NSInteger kApolloCommentFailureServerErrorLastCode = 504;

// How long a failed submit may wait for the thread lookup before Apollo's alert shows anyway.
static const NSTimeInterval kApolloCommentFailureLookupBudget = 5.0;
// How long Reddit's noted answer stays claimable by its submit's completion.
static const NSTimeInterval kApolloCommentFailureReplyTTL = 60.0;

#pragma mark - Reddit's answer to the POST

@interface ApolloCommentFailureReply : NSObject
@property (nonatomic, copy) NSString *code;      // json.errors[0][0], e.g. THREAD_LOCKED
@property (nonatomic, copy) NSString *message;   // json.errors[0][1], Reddit's own wording
@property (nonatomic, assign) NSInteger status;  // HTTP status (0 = no response)
@property (nonatomic, strong) NSDate *date;
@end

@implementation ApolloCommentFailureReply
@end

// thing_id → Reddit's answer to the latest POST api/comment on it, when that answer was a
// failure. Written from the request's completion queue and claimed by the submit completion,
// so every access is @synchronized. Each POST replaces (or, on success, clears) its thing's
// entry, and entries past the TTL are pruned on every write.
static NSMutableDictionary<NSString *, ApolloCommentFailureReply *> *ApolloCommentFailureReplies(void) {
    static NSMutableDictionary *replies = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ replies = [NSMutableDictionary dictionary]; });
    return replies;
}

static void ApolloCommentFailureStoreReply(NSString *thingID, ApolloCommentFailureReply *reply) {
    NSMutableDictionary *replies = ApolloCommentFailureReplies();
    @synchronized (replies) {
        for (NSString *key in replies.allKeys) {
            ApolloCommentFailureReply *old = replies[key];
            if (-[old.date timeIntervalSinceNow] > kApolloCommentFailureReplyTTL) [replies removeObjectForKey:key];
        }
        if (reply) replies[thingID] = reply;
        else [replies removeObjectForKey:thingID];
    }
}

static ApolloCommentFailureReply *ApolloCommentFailureClaimReply(NSString *thingID) {
    if (thingID.length == 0) return nil;
    NSMutableDictionary *replies = ApolloCommentFailureReplies();
    @synchronized (replies) {
        ApolloCommentFailureReply *reply = replies[thingID];
        [replies removeObjectForKey:thingID];
        if (reply && -[reply.date timeIntervalSinceNow] > kApolloCommentFailureReplyTTL) return nil;
        return reply;
    }
}

// nil when the POST went through (HTTP 200, no json.errors, no transport error).
static ApolloCommentFailureReply *ApolloCommentFailureReplyFrom(NSHTTPURLResponse *response, id responseObject, NSError *error) {
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? response.statusCode : 0;
    NSString *code = nil;
    NSString *message = nil;
    NSDictionary *json = [responseObject isKindOfClass:[NSDictionary class]] ? responseObject[@"json"] : nil;
    NSArray *errors = [json isKindOfClass:[NSDictionary class]] ? json[@"errors"] : nil;
    NSArray *first = ([errors isKindOfClass:[NSArray class]] && errors.count > 0) ? errors[0] : nil;
    if ([first isKindOfClass:[NSArray class]]) {
        if (first.count > 0 && [first[0] isKindOfClass:[NSString class]]) code = first[0];
        if (first.count > 1 && [first[1] isKindOfClass:[NSString class]]) message = first[1];
    }
    if (status == 200 && code.length == 0 && !error) return nil;

    ApolloCommentFailureReply *reply = [ApolloCommentFailureReply new];
    reply.code = code;
    reply.message = message;
    reply.status = status;
    reply.date = [NSDate date];
    return reply;
}

// RedditKit hands postPath: the bare relative path.
static BOOL ApolloCommentFailureIsCommentPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return NO;
    NSString *p = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    if ([p hasSuffix:@".json"]) p = [p substringToIndex:p.length - 5];
    return [p isEqualToString:@"api/comment"];
}

#pragma mark - Thread lookup

@interface ApolloCommentFailureContext : NSObject
@property (nonatomic, copy) NSString *thingID;       // what the comment replied to (t3_ post / t1_ comment)
@property (nonatomic, copy) NSString *username;      // the posting account
@property (nonatomic, strong) ApolloCommentFailureReply *reply;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, copy) NSDictionary *parent;    // t1 data, when replying to a comment
@property (nonatomic, copy) NSDictionary *post;      // t3 data
@property (nonatomic, assign) BOOL moderatorCommented; // a stickied moderator removal note on the post
@property (nonatomic, copy) NSDictionary *subreddit; // /r/<sub>/about data
@end

@implementation ApolloCommentFailureContext
@end

@interface ApolloCommentFailureExplanation : NSObject
@property (nonatomic, copy) NSString *kind;          // for the log
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
// YES when read off the thread itself (removed / locked / archived / banned …) rather than taken
// from Reddit's answer alone. Only these replace Apollo's 403 alert, whose account-check advice is
// the right answer when the thread is fine.
@property (nonatomic, assign) BOOL fromThreadState;
@end

@implementation ApolloCommentFailureExplanation
@end

static NSString *ApolloCommentFailureString(NSDictionary *dict, NSString *key) {
    id value = [dict isKindOfClass:[NSDictionary class]] ? dict[key] : nil;
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0 ? value : nil;
}

static BOOL ApolloCommentFailureBool(NSDictionary *dict, NSString *key) {
    id value = [dict isKindOfClass:[NSDictionary class]] ? dict[key] : nil;
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

// The posting account: each account owns its RDKClient, so its currentUser is the true identity
// even when the composer posted as a different account than the active one.
static NSString *ApolloCommentFailureClientUsername(id client) {
    id user = nil;
    if ([client respondsToSelector:@selector(currentUser)]) {
        @try { user = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser)); }
        @catch (__unused NSException *e) { user = nil; }
    }
    id name = nil;
    if ([user respondsToSelector:@selector(username)]) {
        @try { name = ((id (*)(id, SEL))objc_msgSend)(user, @selector(username)); }
        @catch (__unused NSException *e) { name = nil; }
    }
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) return name;
    return ApolloActiveAccountUsername();
}

// A GET through the posting client, so auth, keyless routing and token refresh all follow that
// account exactly as Apollo's own reads do. Delivers on the main thread.
static void ApolloCommentFailureGET(id client, NSString *path, NSDictionary *parameters, void (^completion)(NSInteger status, id json)) {
    SEL selector = @selector(getPath:parameters:completion:);
    if (![client respondsToSelector:selector]) {
        completion(0, nil);
        return;
    }
    ApolloCommentFailureTaskCompletion taskCompletion = ^(NSHTTPURLResponse *response, id responseObject, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? response.statusCode : 0;
        id json = error ? nil : responseObject;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloLog(@"[CommentFailure] GET %@ → HTTP %ld%@", path, (long)status, error ? @" (error)" : @"");
            completion(status, json);
        });
    };
    @try {
        ((id (*)(id, SEL, id, id, id))objc_msgSend)(client, selector, path, parameters, taskCompletion);
    } @catch (NSException *e) {
        ApolloLogError(@"[CommentFailure] GET %@ threw: %@", path, e.reason);
        completion(0, nil);
    }
}

// {kind:"Listing", data:{children:[{kind, data}]}} → the first child's data.
static NSDictionary *ApolloCommentFailureFirstChild(id listing) {
    NSDictionary *data = [listing isKindOfClass:[NSDictionary class]] ? listing[@"data"] : nil;
    NSArray *children = [data isKindOfClass:[NSDictionary class]] ? data[@"children"] : nil;
    NSDictionary *first = ([children isKindOfClass:[NSArray class]] && children.count > 0) ? children[0] : nil;
    NSDictionary *thing = [first isKindOfClass:[NSDictionary class]] ? first[@"data"] : nil;
    return [thing isKindOfClass:[NSDictionary class]] ? thing : nil;
}

// Removal reasons are usually posted as a stickied moderator comment. The alert only says it's
// there (quoting it took most of a small screen); the thread shows the text. Many subs also
// sticky a standing AutoModerator comment (rules, welcome, bot notices) on every post, which is
// not a reason, so it has to be a removal note: Reddit posts those as <Sub>-ModTeam, and mods
// and AutoModerator word them as a removal.
static BOOL ApolloCommentFailureHasRemovalComment(id commentsListing) {
    NSDictionary *data = [commentsListing isKindOfClass:[NSDictionary class]] ? commentsListing[@"data"] : nil;
    NSArray *children = [data isKindOfClass:[NSDictionary class]] ? data[@"children"] : nil;
    if (![children isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *child in children) {
        NSDictionary *comment = [child isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
        if (![comment isKindOfClass:[NSDictionary class]]) continue;
        if (!ApolloCommentFailureBool(comment, @"stickied") ||
            ![ApolloCommentFailureString(comment, @"distinguished") isEqualToString:@"moderator"]) continue;
        NSString *author = ApolloCommentFailureString(comment, @"author");
        NSString *body = ApolloCommentFailureString(comment, @"body");
        if ([author hasSuffix:@"-ModTeam"] ||
            (body && [body rangeOfString:@"remov" options:NSCaseInsensitiveSearch].location != NSNotFound)) return YES;
    }
    return NO;
}

// `hint` (optional) follows the reason in the same paragraph.
static ApolloCommentFailureExplanation *ApolloCommentFailureMake(NSString *kind, NSString *title, NSString *reason, NSString *hint) {
    ApolloCommentFailureExplanation *explanation = [ApolloCommentFailureExplanation new];
    explanation.kind = kind;
    explanation.title = title;
    NSMutableString *message = [reason mutableCopy];
    if (hint.length > 0) [message appendFormat:@" %@", hint];
    [message appendString:@"\n\nYour comment wasn't posted. Tap Copy Text to keep it."];
    explanation.message = message;
    return explanation;
}

static ApolloCommentFailureExplanation *ApolloCommentFailureExplainStateUnmarked(ApolloCommentFailureContext *ctx);

// What the thread itself says. nil when nothing in it stops this account from commenting.
static ApolloCommentFailureExplanation *ApolloCommentFailureExplainState(ApolloCommentFailureContext *ctx) {
    ApolloCommentFailureExplanation *explanation = ApolloCommentFailureExplainStateUnmarked(ctx);
    explanation.fromThreadState = YES;
    return explanation;
}

// Only states that really block a comment are claimed: a deleted post or comment can still take
// replies (Reddit refuses those with DELETED_LINK / DELETED_COMMENT, read from its answer below),
// and the subreddit's moderators can still comment on removed and locked threads.
static ApolloCommentFailureExplanation *ApolloCommentFailureExplainStateUnmarked(ApolloCommentFailureContext *ctx) {
    NSDictionary *post = ctx.post;
    NSDictionary *parent = ctx.parent;
    NSString *subreddit = ApolloCommentFailureString(post, @"subreddit") ?: ApolloCommentFailureString(parent, @"subreddit");
    NSString *moderators = subreddit ? [NSString stringWithFormat:@"the moderators of r/%@", subreddit] : @"the moderators";
    NSString *Moderators = subreddit ? [NSString stringWithFormat:@"The moderators of r/%@", subreddit] : @"The moderators";
    NSString *author = ApolloCommentFailureString(post, @"author");
    BOOL ownPost = author && ctx.username && [author caseInsensitiveCompare:ctx.username] == NSOrderedSame;
    NSString *thePost = ownPost ? @"Your post" : @"This post";
    BOOL canModerate = ApolloCommentFailureBool(post, @"can_mod_post") || ApolloCommentFailureBool(ctx.subreddit, @"user_is_moderator");
    // Where the removal reason is. The thread on screen can predate the moderators' comment (it
    // did in the original report: "0 Comments"), hence the refresh hint. Without one, a reason
    // sent to the author can only be in their inbox.
    NSString *reasonHint = ctx.moderatorCommented ? @"They left a comment on it explaining why (pull to refresh if you don't see it)."
                         : ownPost ? @"If they sent a reason, it's in your inbox." : nil;

    if (post) {
        NSString *removedBy = ApolloCommentFailureString(post, @"removed_by_category");
        BOOL deleted = [removedBy isEqualToString:@"deleted"] || [removedBy isEqualToString:@"author"];
        if (removedBy && !deleted && !canModerate) {
            if ([removedBy isEqualToString:@"moderator"]) {
                return ApolloCommentFailureMake(@"post-removed-moderator", @"Post Removed",
                    [NSString stringWithFormat:@"%@ was removed by %@, so it can't take new comments.", thePost, moderators],
                    reasonHint);
            }
            if ([removedBy isEqualToString:@"automod_filtered"]) {
                return ApolloCommentFailureMake(@"post-removed-automod", @"Post Awaiting Approval",
                    [NSString stringWithFormat:@"%@ was held by AutoModerator for %@ to review, so it can't take comments until they approve it.",
                        thePost, moderators],
                    ctx.moderatorCommented ? reasonHint : nil);
            }
            if ([removedBy isEqualToString:@"reddit"]) {
                return ApolloCommentFailureMake(@"post-removed-filters", @"Post Removed",
                    [NSString stringWithFormat:@"%@ was removed by Reddit's filters, so it can't take new comments.", thePost], nil);
            }
            // Reddit's own teams. Any other (newer) category gets no attribution rather than a guess.
            static NSSet<NSString *> *adminCategories = nil;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                adminCategories = [NSSet setWithArray:@[ @"anti_evil_ops", @"community_ops", @"legal_operations",
                                                         @"copyright_takedown", @"content_takedown" ]];
            });
            NSString *reason = [adminCategories containsObject:removedBy]
                ? [NSString stringWithFormat:@"%@ was removed by Reddit, so it can't take new comments.", thePost]
                : [NSString stringWithFormat:@"%@ was removed, so it can't take new comments.", thePost];
            return ApolloCommentFailureMake([@"post-removed-" stringByAppendingString:removedBy], @"Post Removed", reason, nil);
        }
        if (ApolloCommentFailureBool(post, @"locked") && !canModerate) {
            return ApolloCommentFailureMake(@"post-locked", @"Comments Locked",
                [NSString stringWithFormat:@"%@ locked this thread, so it can't take new comments.", Moderators], nil);
        }
        if (ApolloCommentFailureBool(post, @"archived")) {
            return ApolloCommentFailureMake(@"post-archived", @"Post Archived",
                @"This post is archived, so it can't take new comments.", nil);
        }
    }

    if (parent && !canModerate) {
        if ([ApolloCommentFailureString(parent, @"body") isEqualToString:@"[removed]"]) {
            return ApolloCommentFailureMake(@"parent-removed", @"Comment Removed",
                [NSString stringWithFormat:@"The comment you're replying to was removed by %@, so it can't take replies.", moderators], nil);
        }
        if (ApolloCommentFailureBool(parent, @"locked")) {
            return ApolloCommentFailureMake(@"parent-locked", @"Replies Locked",
                [NSString stringWithFormat:@"%@ locked the comment you're replying to, so it can't take replies.", Moderators], nil);
        }
    }

    NSDictionary *about = ctx.subreddit;
    if (about && subreddit) {
        if (ApolloCommentFailureBool(about, @"user_is_banned")) {
            return ApolloCommentFailureMake(@"banned", [NSString stringWithFormat:@"Banned from r/%@", subreddit],
                [NSString stringWithFormat:@"You're banned from r/%@, so you can't comment there.", subreddit], nil);
        }
        if (ApolloCommentFailureBool(about, @"restrict_commenting") &&
            !ApolloCommentFailureBool(about, @"user_is_contributor") && !ApolloCommentFailureBool(about, @"user_is_moderator")) {
            return ApolloCommentFailureMake(@"restricted", @"Commenting Restricted",
                [NSString stringWithFormat:@"Only approved users can comment in r/%@.", subreddit], nil);
        }
    }
    return nil;
}

// What Reddit said, when the thread itself doesn't explain it. nil keeps Apollo's alert.
static ApolloCommentFailureExplanation *ApolloCommentFailureExplainReply(ApolloCommentFailureContext *ctx) {
    ApolloCommentFailureReply *reply = ctx.reply;
    NSString *code = reply.code.uppercaseString;
    if ([code isEqualToString:@"THREAD_LOCKED"]) {
        return ApolloCommentFailureMake(@"reply-locked", @"Comments Locked",
            @"This thread is locked, so it can't take new comments.", nil);
    }
    BOOL rdkError = [ctx.error.domain isEqualToString:kApolloCommentFailureRDKErrorDomain];
    if ([code isEqualToString:@"TOO_OLD"] || (rdkError && ctx.error.code == kApolloCommentFailureArchivedCode)) {
        return ApolloCommentFailureMake(@"reply-archived", @"Post Archived",
            @"This post is archived, so it can't take new comments.", nil);
    }
    if ([code isEqualToString:@"DELETED_LINK"]) {
        return ApolloCommentFailureMake(@"reply-post-deleted", @"Post Deleted",
            @"This post was deleted, so it can't take new comments.", nil);
    }
    if ([code isEqualToString:@"DELETED_COMMENT"]) {
        return ApolloCommentFailureMake(@"reply-parent-deleted", @"Comment Deleted",
            @"The comment you're replying to was deleted, so it can't take replies.", nil);
    }
    // Apollo's own "Posting Too Often" alert covers these already.
    if ([code isEqualToString:@"RATELIMIT"]) return nil;
    NSString *said = [reply.message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (said.length > 0) {
        said = [[said substringToIndex:1].uppercaseString stringByAppendingString:[said substringFromIndex:1]];
        if (![said hasSuffix:@"."] && ![said hasSuffix:@"!"] && ![said hasSuffix:@"?"]) said = [said stringByAppendingString:@"."];
        return ApolloCommentFailureMake([@"reply-" stringByAppendingString:code ?: @"message"], @"Comment Rejected",
            [NSString stringWithFormat:@"Reddit said: “%@”", said], nil);
    }
    return nil;
}

static BOOL ApolloCommentFailureShouldLookUp(NSString *thingID, ApolloCommentFailureReply *reply, NSError *error) {
    // Only comments on posts and comments; a t4 (message) reply has its own UI.
    if (![thingID hasPrefix:@"t3_"] && ![thingID hasPrefix:@"t1_"]) return NO;
    // A real server error IS the hiccup Apollo describes, and the lookup would only stall on it.
    if (reply.status >= 500) return NO;
    if (!error) return YES;
    // Offline / timed out: the lookup would fail the same way, and Apollo's alert is right.
    if (![error.domain isEqualToString:kApolloCommentFailureRDKErrorDomain]) return NO;
    // Rate limit and sign-in problems: Apollo's alert already says what happened.
    if (error.code == kApolloCommentFailureAuthRequiredCode || error.code == kApolloCommentFailureRateLimitedCode ||
        error.code == kApolloCommentFailureReSignInCode) return NO;
    if (error.code >= kApolloCommentFailureServerErrorFirstCode && error.code <= kApolloCommentFailureServerErrorLastCode) return NO;
    return YES;
}

// Runs on the main thread; `done` fires exactly once, on the main thread, within the budget.
static void ApolloCommentFailureLookUp(id client, ApolloCommentFailureContext *ctx,
                                      void (^done)(ApolloCommentFailureExplanation *explanation)) {
    __block BOOL finished = NO;
    void (^finish)(NSString *) = ^(NSString *how) {
        if (finished) return;
        finished = YES;
        ApolloCommentFailureExplanation *explanation = ApolloCommentFailureExplainState(ctx) ?: ApolloCommentFailureExplainReply(ctx);
        ApolloLog(@"[CommentFailure] %@ on %@: %@ (post=%@ parent=%@ modComment=%@ sub=%@ reddit=%@/%ld)",
                  how, ctx.thingID, explanation.kind ?: @"unexplained — keeping Apollo's alert",
                  ctx.post ? @"yes" : @"no", ctx.parent ? @"yes" : @"no", ctx.moderatorCommented ? @"yes" : @"no",
                  ctx.subreddit ? @"yes" : @"no", ctx.reply.code ?: @"-", (long)ctx.reply.status);
        done(explanation);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloCommentFailureLookupBudget * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(@"lookup timed out"); });

    void (^lookUpSubreddit)(void) = ^{
        NSString *subreddit = ApolloCommentFailureString(ctx.post, @"subreddit") ?: ApolloCommentFailureString(ctx.parent, @"subreddit");
        if (finished || subreddit.length == 0 || ApolloCommentFailureExplainState(ctx)) {
            finish(@"looked up");
            return;
        }
        NSString *path = [NSString stringWithFormat:@"r/%@/about", subreddit];
        ApolloCommentFailureGET(client, path, @{ @"raw_json": @"1" }, ^(NSInteger status, id json) {
            NSDictionary *about = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            if ([about isKindOfClass:[NSDictionary class]]) ctx.subreddit = about;
            finish(@"looked up");
        });
    };

    void (^lookUpPost)(NSString *) = ^(NSString *linkFullName) {
        if (finished) return;
        if (![linkFullName hasPrefix:@"t3_"] || linkFullName.length <= 3) {
            lookUpSubreddit();
            return;
        }
        // One read returns the post (removed_by_category / locked / archived) and its first
        // top-level comments, where a stickied removal reason sits.
        NSString *path = [@"comments/" stringByAppendingString:[linkFullName substringFromIndex:3]];
        ApolloCommentFailureGET(client, path, @{ @"limit": @"3", @"depth": @"1", @"raw_json": @"1" }, ^(NSInteger status, id json) {
            NSArray *listings = [json isKindOfClass:[NSArray class]] ? json : nil;
            if (listings.count > 0) ctx.post = ApolloCommentFailureFirstChild(listings[0]);
            if (listings.count > 1) ctx.moderatorCommented = ApolloCommentFailureHasRemovalComment(listings[1]);
            lookUpSubreddit();
        });
    };

    if ([ctx.thingID hasPrefix:@"t1_"]) {
        ApolloCommentFailureGET(client, @"api/info", @{ @"id": ctx.thingID, @"raw_json": @"1" }, ^(NSInteger status, id json) {
            ctx.parent = ApolloCommentFailureFirstChild(json);
            lookUpPost(ApolloCommentFailureString(ctx.parent, @"link_id"));
        });
    } else {
        lookUpPost(ctx.thingID);
    }
}

#pragma mark - Swapping the alert text

// The explanation for the alert Apollo is about to build. Set only while a failed submit's
// completion runs (Apollo builds its alert synchronously inside it) and restored right after,
// so no other alert can pick it up. Main-thread only.
static ApolloCommentFailureExplanation *sApolloCommentFailureActiveExplanation = nil;

// Apollo's submit-failure texts (see the header note). "Posting Too Often" is never replaced. The
// 403 alert ("Authentication Error" — check your account) is replaced only by what the thread
// itself shows: a locked or removed thread answers 403 too, but so does an account Reddit wants
// verified, and then Apollo's advice is the right one.
static BOOL ApolloCommentFailureCanReplaceAlert(NSString *title, NSString *message, ApolloCommentFailureExplanation *explanation) {
    if (![title isKindOfClass:[NSString class]] || ![message isKindOfClass:[NSString class]]) return NO;
    if ([title isEqualToString:@"Server Error"] && [message hasPrefix:@"There was an error submitting the post"]) return YES;
    if ([title isEqualToString:@"Error Submitting"] && [message hasPrefix:@"There was an error trying to submit"]) return YES;
    if ([title isEqualToString:@"Authentication Error"] && [message hasPrefix:@"Reddit thinks there's something weird with your account"]) {
        return explanation.fromThreadState;
    }
    return NO;
}

static void ApolloCommentFailureDeliver(ApolloCommentFailureSubmitCompletion completion, id object, NSError *error,
                                        ApolloCommentFailureExplanation *explanation) {
    ApolloCommentFailureExplanation *previous = sApolloCommentFailureActiveExplanation;
    sApolloCommentFailureActiveExplanation = explanation;
    @try {
        completion(object, error);
    } @finally {
        if (explanation && sApolloCommentFailureActiveExplanation == explanation) {
            ApolloLog(@"[CommentFailure] Apollo built no submit alert for %@ — explanation unused", explanation.kind);
        }
        sApolloCommentFailureActiveExplanation = previous;
    }
}

// ApolloSubredditIndexPolish.xm hooks this factory too (it rewrites the Hide-row alert's
// message); the two match disjoint alerts, so their order doesn't matter.
%hook UIAlertController

+ (id)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(UIAlertControllerStyle)preferredStyle {
    // Process-wide: bail first unless a failed comment submit is being delivered right now.
    if (!NSThread.isMainThread) return %orig;
    ApolloCommentFailureExplanation *explanation = sApolloCommentFailureActiveExplanation;
    if (!explanation || !ApolloCommentFailureCanReplaceAlert(title, message, explanation)) return %orig;
    sApolloCommentFailureActiveExplanation = nil;  // one alert per failure
    ApolloLog(@"[CommentFailure] replaced Apollo's \"%@\" alert with \"%@\" (%@)", title, explanation.title, explanation.kind);
    return %orig(explanation.title, explanation.message, preferredStyle);
}

%end

#pragma mark - Hooks

%hook RDKClient

// Every write goes through here; only comment submits are noted. Reddit's json.errors never
// reach the submit completion (RedditKit parses them into "no comment"), so read them here.
- (id)postPath:(NSString *)path parameters:(id)parameters completion:(ApolloCommentFailureTaskCompletion)completion {
    if (!completion || !ApolloCommentFailureIsCommentPath(path)) return %orig;
    NSDictionary *params = [parameters isKindOfClass:[NSDictionary class]] ? parameters : nil;
    NSString *thingID = [params[@"thing_id"] isKindOfClass:[NSString class]] ? [params[@"thing_id"] copy] : nil;
    if (thingID.length == 0) return %orig;
    ApolloCommentFailureTaskCompletion wrapped = ^(NSHTTPURLResponse *response, id responseObject, NSError *error) {
        @try {
            ApolloCommentFailureReply *reply = ApolloCommentFailureReplyFrom(response, responseObject, error);
            ApolloCommentFailureStoreReply(thingID, reply);
            if (reply) {
                ApolloLog(@"[CommentFailure] Reddit answered the comment on %@: HTTP %ld, code %@",
                          thingID, (long)reply.status, reply.code ?: @"-");
            }
        } @catch (NSException *e) {
            ApolloLogError(@"[CommentFailure] noting the api/comment answer threw: %@", e.reason);
        }
        completion(response, responseObject, error);
    };
    return %orig(path, parameters, wrapped);
}

// The comment submit funnel (onLink: / asReplyToComment: tail-call it). ApolloPostedCommentInsert,
// ApolloOwnCommentFlair and ApolloWebJSONIdentity hook it too; they only observe and pass the
// completion through, so holding a FAILED result back for the lookup delays them equally and
// order stays irrelevant. Successful results are never held.
- (id)submitComment:(id)body onThingWithFullName:(id)fullName completion:(ApolloCommentFailureSubmitCompletion)completion {
    if (!completion) return %orig;
    NSString *thingID = [fullName isKindOfClass:[NSString class]] ? [fullName copy] : nil;
    __weak id weakClient = self;
    ApolloCommentFailureSubmitCompletion wrapped = ^(id object, NSError *error) {
        ApolloCommentFailureReply *reply = ApolloCommentFailureClaimReply(thingID);
        id client = weakClient;
        if (object || !client || !NSThread.isMainThread || !ApolloCommentFailureShouldLookUp(thingID, reply, error)) {
            completion(object, error);
            return;
        }
        ApolloCommentFailureContext *ctx = [ApolloCommentFailureContext new];
        ctx.thingID = thingID;
        ctx.username = ApolloCommentFailureClientUsername(client);
        ctx.reply = reply;
        ctx.error = error;
        ApolloLogError(@"[CommentFailure] comment on %@ failed (error %@/%ld, reddit %@/%ld) — looking the thread up",
                  thingID, error.domain ?: @"-", (long)error.code, reply.code ?: @"-", (long)reply.status);
        ApolloCommentFailureLookUp(client, ctx, ^(ApolloCommentFailureExplanation *explanation) {
            ApolloCommentFailureDeliver(completion, object, error, explanation);
        });
    };
    return %orig(body, fullName, wrapped);
}

%end

%ctor {
    %init;
    ApolloLog(@"[CommentFailure] hooks installed (RDKClient postPath:/submitComment:onThingWithFullName:, UIAlertController alertControllerWithTitle:message:preferredStyle:)");
}
