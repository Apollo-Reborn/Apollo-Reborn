// Explain a post that Reddit refused because the account has to solve a captcha (API-Key-Free).
//
// Reddit makes new and low-karma accounts solve a captcha before they can post. Over the
// API-Key-Free (cookie) route it then answers POST www.reddit.com/api/submit with HTTP 200 and
//   {"json": {"errors": [["BAD_CAPTCHA", "That was a tricky one. Why don't you try that again.", "captcha"]]}}
// Apollo can't show a captcha, so every retry fails the same way, yet the composer calls it
// "Server Error — … this probably means Reddit had a little hiccup. Try again shortly."
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
// So this module:
//  1. hands the api/submit task block Reddit's answer back when an API-Key-Free submit came back
//     as error 201 with no body, with a description of what to do instead of Reddit's riddle;
//  2. names the BAD_CAPTCHA issue ("Captcha Required") in -formattedIssueTitleFromIssueCode:.
// An API-key submit never reaches either change: its response URL carries no API-Key-Free route
// marker, and RedditKit turns its BAD_CAPTCHA (if Reddit ever sent one) into error 201 before
// -errorFromLinkSubmissionResponseObject: could read it, so it keeps Apollo's alert as before.

#import <Foundation/Foundation.h>
#import "ApolloCommon.h"
#import "ApolloWebJSON.h"

// RedditKit's request completion (postPath: → taskWithMethod:path:parameters:completion:).
typedef void (^ApolloPostSubmitFailureTaskCompletion)(NSHTTPURLResponse *response, id responseObject, NSError *error);

static NSString *const kApolloPostSubmitFailureRDKErrorDomain = @"RDKClientErrorDomain";
// +[RDKClient invalidCaptchaError]: json.errors code containing BAD_CAPTCHA.
static const NSInteger kApolloPostSubmitFailureInvalidCaptchaCode = 201;
static NSString *const kApolloPostSubmitFailureCaptchaIssue = @"BAD_CAPTCHA";

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

// YES for the answer described above: RedditKit's captcha error, no body left, and a request the
// API-Key-Free layer sent for a web-session account (it stamps the route on the URL; an API-key
// request carries no marker).
static BOOL ApolloPostSubmitFailureIsKeylessCaptcha(NSHTTPURLResponse *response, id responseObject, NSError *error) {
    if (responseObject || ![error.domain isEqualToString:kApolloPostSubmitFailureRDKErrorDomain] ||
        error.code != kApolloPostSubmitFailureInvalidCaptchaCode) return NO;
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

%hook RDKClient

// Every RedditKit write goes through here; only api/submit is touched (ApolloCommentSubmitFailure
// handles api/comment the same way, so the two never act on one request).
- (id)postPath:(NSString *)path parameters:(id)parameters completion:(ApolloPostSubmitFailureTaskCompletion)completion {
    if (!completion || !ApolloPostSubmitFailureIsSubmitPath(path)) return %orig;
    ApolloPostSubmitFailureTaskCompletion wrapped = ^(NSHTTPURLResponse *response, id responseObject, NSError *error) {
        if (ApolloPostSubmitFailureIsKeylessCaptcha(response, responseObject, error)) {
            ApolloLog(@"[PostSubmitFailure] Reddit wants a captcha for this API-Key-Free submit (HTTP %ld) — passing it on as a submission error",
                      (long)response.statusCode);
            // The error stays, for any caller that reads it; the api/submit blocks read the body.
            completion(response, ApolloPostSubmitFailureCaptchaAnswer(), error);
            return;
        }
        completion(response, responseObject, error);
    };
    return %orig(path, parameters, wrapped);
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
