// Get a post through when Reddit wants a captcha from an API-Key-Free account.
//
// Reddit makes new and low-karma accounts solve a captcha before they can post, but only on the
// cookie route: POST www.reddit.com/api/submit answers HTTP 200 with
//   {"json": {"errors": [["BAD_CAPTCHA", "That was a tricky one. Why don't you try that again.", "captcha"]]}}
// while the same account's /api/needs_captcha is false, and the same submit is taken, on
// oauth.reddit.com with the desktop web client's token (the one the website itself posts with).
// Checked 2026-11-25 with a submit that can't post (empty title): the cookie answers BAD_CAPTCHA,
// the desktop token answers NO_TEXT "Post title is required". The mobile web client's token (the
// one moderator requests use) gets Reddit's 403 block page there, so it's no use for this.
//
// Apollo can't show a captcha, so on main every retry failed the same way, and the composer called
// it "Server Error — … this probably means Reddit had a little hiccup. Try again shortly."
//
// How Apollo gets there (Ghidra, Apollo 1.15.11):
//  - -[RDKResponseSerializer responseObjectForResponse:data:error:] (0x1000439ec) runs
//    +[RDKClient errorFromResponseObject:] on every JSON answer. A json.errors code containing
//    "BAD_CAPTCHA" (0x100a2b5a1) becomes +[RDKClient invalidCaptchaError] (RDKClientErrorDomain
//    201), and the serializer then drops the parsed body: the task completes with (nil, 201).
//  - -[RDKClient linkSubmissionTaskWithParameters:completion:] (0x10003adf4, self and link posts)
//    and the crosspost submit (0x10003afe4) are the only senders of
//    "api/submit?validate_on_submit=True" (0x100c2a8a0).
//    Their task blocks ignore the task's error: they pass the caller json.data and
//    -errorFromLinkSubmissionResponseObject: of the body (0x10003bc40), which is nil for a nil
//    body. So the composer gets no link and no error.
//  - ComposePostViewController's completion (0x100783e70) shows "no link, no error" ~2 s later as
//    the generic "Server Error" alert with Delete / Retry (0x100748418). A 499 error from
//    -errorFromLinkSubmissionResponseObject: (each json.errors entry → userInfo submission_errors
//    {issue: -formattedIssueTitleFromIssueCode:, issue_description, area}) takes the path Reddit's
//    other submit refusals already use (e.g. "Flair Must be Added"): the composer comes back with
//    the draft, under an "<issue>" alert reading "<Area> issue for r/<sub>. <issue_description>"
//    with OK (0x10074915c / 0x100748720).
//
// So this module, for an API-Key-Free submit that came back as error 201 with no body:
//  1. sends the request Reddit refused once more, unchanged but for its address and credentials:
//     oauth.reddit.com with the account's desktop web bearer (ApolloWebJSONDesktopWebBearer) in
//     place of www.reddit.com with the cookie. It is the request as it went out, so a media post
//     keeps the body the upload code already built (ApolloImageUploadHost.xm). Whatever Reddit
//     answers (the post, or its own refusal: flair required, posting too often…) goes to Apollo
//     as the submit's answer;
//  2. when that can't be done (no token, the token refused twice, or the captcha asked for there
//     too), hands the api/submit task block a BAD_CAPTCHA entry with a description of what to do,
//     and names the issue ("Captcha Required") in -formattedIssueTitleFromIssueCode:, so Apollo's
//     own 499 path explains it instead of the hiccup alert.
// An API-key submit never reaches any of this: its response URL carries no API-Key-Free route
// marker, so it keeps Apollo's alert as before.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloWebJSON.h"
#import "ApolloWebJSONRoutes.h"
#import "ApolloWebSessionStore.h"

// RedditKit's request completion (postPath: → taskWithMethod:path:parameters:completion:), which
// is also AFNetworking's for -dataTaskWithRequest:completionHandler:.
typedef void (^ApolloPostSubmitFailureTaskCompletion)(NSHTTPURLResponse *response, id responseObject, NSError *error);

static NSString *const kApolloPostSubmitFailureRDKErrorDomain = @"RDKClientErrorDomain";
// +[RDKClient invalidCaptchaError]: json.errors code containing BAD_CAPTCHA.
static const NSInteger kApolloPostSubmitFailureInvalidCaptchaCode = 201;
static NSString *const kApolloPostSubmitFailureCaptchaIssue = @"BAD_CAPTCHA";
// Sends with the desktop web bearer per submit: the second one follows a refused token (a stale
// token_v2 is replaced by a minted bearer, ApolloWebJSONInvalidateDesktopWebBearer).
static const NSUInteger kApolloPostSubmitFailureWebTokenSends = 2;

// The task -postPath: returned for a submit, for its completion to read the request back from.
// Set on the caller's thread once RedditKit returns it and read by the completion on the main
// thread, hence atomic.
@interface ApolloPostSubmitFailureSend : NSObject
@property (atomic, strong) NSURLSessionTask *task;
@end

@implementation ApolloPostSubmitFailureSend
@end

// RedditKit hands postPath: a relative path, and this one comes with its query:
// "api/submit?validate_on_submit=True" (0x100c2a8a0).
static BOOL ApolloPostSubmitFailureIsSubmitPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return NO;
    NSString *p = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    NSRange query = [p rangeOfString:@"?"];
    if (query.location != NSNotFound) p = [p substringToIndex:query.location];
    if ([p hasSuffix:@".json"]) p = [p substringToIndex:p.length - 5];
    return [p isEqualToString:@"api/submit"];
}

// RedditKit's answer for a json.errors code containing BAD_CAPTCHA: its captcha error, no body.
static BOOL ApolloPostSubmitFailureIsCaptcha(id responseObject, NSError *error) {
    return !responseObject && [error.domain isEqualToString:kApolloPostSubmitFailureRDKErrorDomain] &&
        error.code == kApolloPostSubmitFailureInvalidCaptchaCode;
}

// YES for the answer described above from a request the API-Key-Free layer sent for a web-session
// account (it stamps the route on the URL; an API-key request carries no marker).
static BOOL ApolloPostSubmitFailureIsKeylessCaptcha(NSHTTPURLResponse *response, id responseObject, NSError *error) {
    if (!ApolloPostSubmitFailureIsCaptcha(responseObject, error)) return NO;
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return NO;
    return ApolloWebJSONRouteFromURL(response.URL) >= 0;
}

// Reddit's answer as -errorFromLinkSubmissionResponseObject: reads it. Apollo shows the entry as
// "<Area> issue for r/<sub>. <description>", so the description follows that sentence.
static NSDictionary *ApolloPostSubmitFailureCaptchaAnswer(void) {
    NSString *description = @"Reddit wants a captcha from this account, and Apollo can't show one. "
                            @"Post from reddit.com for now.";
    return @{ @"json": @{ @"errors": @[ @[ kApolloPostSubmitFailureCaptchaIssue, description, @"captcha" ] ] } };
}

// The posting account: each account owns its RDKClient, so its currentUser is the true identity
// even when the composer posts as a different account than the active one.
static NSString *ApolloPostSubmitFailureClientUsername(id client) {
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
    return ApolloActiveWebSessionUsername();
}

// `sent` (the cookie request Reddit refused, as the transport sent it) as the same request to
// oauth.reddit.com with `bearer`. nil unless it's a submit at its usual path: /api/submit, or the
// gallery endpoint the upload code turns a multi-image post into.
static NSURLRequest *ApolloPostSubmitFailureWebTokenRequest(NSURLRequest *sent, NSString *bearer) {
    NSURL *url = sent.URL;
    NSString *host = url.host.lowercaseString;
    // www.reddit.com after the cookie rewrite; oauth.reddit.com if the task kept RedditKit's own.
    if ((![host isEqualToString:@"www.reddit.com"] && ![host isEqualToString:@"oauth.reddit.com"]) || bearer.length == 0) return nil;
    if (![sent.HTTPMethod.uppercaseString isEqualToString:@"POST"] || sent.HTTPBody.length == 0) return nil;
    static NSSet<NSString *> *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        paths = [NSSet setWithArray:@[ @"/api/submit", @"/api/submit_gallery_post", @"/api/submit_gallery_post.json" ]];
    });
    if (![paths containsObject:url.path ?: @""]) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.host = @"oauth.reddit.com";
    components.fragment = nil;
    NSURL *oauthURL = components.URL;
    if (!oauthURL) return nil;
    NSMutableURLRequest *request = [sent mutableCopy];
    // The probe marker first, the bearer second: the marker keeps the transport hooks off a
    // request this module authenticates itself (no rewrite back to the cookie, no User-Agent
    // stamp over the browser one the cookie request already carries), and keeps the bearer-capture
    // hook (ApolloImageUploadHost.xm) from taking the web session's token for Apollo's own.
    request.URL = ApolloWebJSONProbeURL(oauthURL);
    [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    // What the rewrite added for the cookie (ApolloWebJSONRewriteRequest).
    for (NSString *field in @[ @"Cookie", @"X-Modhash", @"Origin", @"Referer",
                               @"Sec-Fetch-Site", @"Sec-Fetch-Mode", @"Sec-Fetch-Dest" ]) {
        [request setValue:nil forHTTPHeaderField:field];
    }
    request.HTTPShouldHandleCookies = NO;
    return request;
}

// json.errors[0][0] of a submit answer, for the log.
static NSString *ApolloPostSubmitFailureFirstErrorCode(id responseObject) {
    NSDictionary *json = [responseObject isKindOfClass:[NSDictionary class]] ? responseObject[@"json"] : nil;
    NSArray *errors = [json isKindOfClass:[NSDictionary class]] ? json[@"errors"] : nil;
    NSArray *first = ([errors isKindOfClass:[NSArray class]] && errors.count > 0) ? errors[0] : nil;
    id code = ([first isKindOfClass:[NSArray class]] && first.count > 0) ? first[0] : nil;
    return [code isKindOfClass:[NSString class]] ? code : nil;
}

// Sends `sent` with the account's desktop web bearer. Exactly one of the two blocks runs, once,
// on the main thread: `answered` with Reddit's answer to that send, or `gaveUp` when it couldn't
// be sent that way or Reddit refused the token (or still asked for the captcha).
static void ApolloPostSubmitFailureSendWithWebToken(id client, NSString *username, NSURLRequest *sent, NSUInteger sendsLeft,
                                                    ApolloPostSubmitFailureTaskCompletion answered, void (^gaveUp)(NSString *why)) {
    // The bearer may need minting, which waits on the network.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *bearer = ApolloWebJSONDesktopWebBearer(username);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURLRequest *request = ApolloPostSubmitFailureWebTokenRequest(sent, bearer);
            SEL selector = @selector(dataTaskWithRequest:completionHandler:);
            if (!request || ![client respondsToSelector:selector]) {
                gaveUp(bearer.length == 0 ? @"no website token for the account" : @"not a submit it can resend");
                return;
            }
            ApolloPostSubmitFailureTaskCompletion taskCompletion = ^(NSHTTPURLResponse *response, id responseObject, NSError *error) {
                dispatch_block_t deliver = ^{
                    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? response.statusCode : 0;
                    // A 401 or Reddit's 403 block page. A 403 with a JSON body is its answer to
                    // the post (a suspended account, say), and goes to Apollo below.
                    if (status == 401 || ApolloWebJSONRouteResponseIsBlockPage(response)) {
                        // Reddit refused the token itself; nothing was posted. The next bearer is another one.
                        ApolloWebJSONInvalidateDesktopWebBearer(username, bearer);
                        if (sendsLeft > 1) {
                            ApolloLog(@"[PostSubmitFailure] oauth.reddit.com refused the website token (HTTP %ld) — sending once more with another", (long)status);
                            ApolloPostSubmitFailureSendWithWebToken(client, username, sent, sendsLeft - 1, answered, gaveUp);
                        } else {
                            gaveUp([NSString stringWithFormat:@"oauth.reddit.com refused the website token (HTTP %ld)", (long)status]);
                        }
                        return;
                    }
                    if (ApolloPostSubmitFailureIsCaptcha(responseObject, error)) {
                        gaveUp(@"Reddit asked for the captcha there too");
                        return;
                    }
                    NSString *code = ApolloPostSubmitFailureFirstErrorCode(responseObject);
                    ApolloLog(@"[PostSubmitFailure] the website-token submit answered HTTP %ld: %@", (long)status,
                              code ?: (error ? [NSString stringWithFormat:@"error %@/%ld", error.domain, (long)error.code]
                                             : (responseObject ? @"no errors" : @"no body")));
                    answered(response, responseObject, error);
                };
                if (NSThread.isMainThread) deliver();
                else dispatch_async(dispatch_get_main_queue(), deliver);
            };
            // Through the client's own session, so RedditKit's serializer and the upload code's
            // submit handling (the media post's link ID) see this answer as they would the first.
            NSURLSessionTask *task = nil;
            @try {
                task = ((id (*)(id, SEL, id, id))objc_msgSend)(client, selector, request, taskCompletion);
            } @catch (NSException *e) {
                ApolloLogError(@"[PostSubmitFailure] creating the website-token submit threw: %@", e.reason);
            }
            if (![task isKindOfClass:[NSURLSessionTask class]]) {
                gaveUp(@"the request couldn't be created");
                return;
            }
            [task resume];
        });
    });
}

%hook RDKClient

// Every RedditKit write goes through here; only api/submit is touched (ApolloCommentSubmitFailure
// handles api/comment the same way, so the two never act on one request).
- (id)postPath:(NSString *)path parameters:(id)parameters completion:(ApolloPostSubmitFailureTaskCompletion)completion {
    if (!completion || !ApolloPostSubmitFailureIsSubmitPath(path)) return %orig;
    ApolloPostSubmitFailureSend *send = [ApolloPostSubmitFailureSend new];
    __weak id weakClient = self;
    ApolloPostSubmitFailureTaskCompletion wrapped = ^(NSHTTPURLResponse *response, id responseObject, NSError *error) {
        NSURLSessionTask *task = send.task;
        send.task = nil;
        if (!ApolloPostSubmitFailureIsKeylessCaptcha(response, responseObject, error)) {
            completion(response, responseObject, error);
            return;
        }
        // The error stays in what's passed on, for any caller that reads it; the api/submit
        // blocks read the body.
        void (^explain)(NSString *) = ^(NSString *why) {
            ApolloLog(@"[PostSubmitFailure] not sent with the website token (%@) — passing the captcha on as a submission error", why);
            completion(response, ApolloPostSubmitFailureCaptchaAnswer(), error);
        };
        id client = weakClient;
        // The request as the transport sent it: the cookie rewrite, and for a media post the
        // body the upload code built. Whichever of the task's two still holds that body.
        NSURLRequest *sent = task.currentRequest.HTTPBody.length > 0 ? task.currentRequest : task.originalRequest;
        NSString *username = client ? ApolloPostSubmitFailureClientUsername(client) : nil;
        if (!sent || username.length == 0) {
            explain(@"the refused request isn't on hand");
            return;
        }
        ApolloLog(@"[PostSubmitFailure] Reddit wants a captcha for this API-Key-Free submit (HTTP %ld) — sending it again with the website token",
                  (long)response.statusCode);
        ApolloPostSubmitFailureSendWithWebToken(client, username, sent, kApolloPostSubmitFailureWebTokenSends, completion, explain);
    };
    id task = %orig(path, parameters, wrapped);
    if ([task isKindOfClass:[NSURLSessionTask class]]) send.task = task;
    return task;
}

// Apollo's table (0x100c34368) has no title for BAD_CAPTCHA and would show the bare code.
- (id)formattedIssueTitleFromIssueCode:(id)code {
    if ([code isKindOfClass:[NSString class]] && [code isEqualToString:kApolloPostSubmitFailureCaptchaIssue]) {
        return @"Captcha Required";
    }
    return %orig;
}

%end

%ctor {
    %init;
    ApolloLog(@"[PostSubmitFailure] hooks installed (RDKClient postPath:parameters:completion:, formattedIssueTitleFromIssueCode:)");
}
