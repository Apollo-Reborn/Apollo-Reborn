#import "ApolloShareAsImageLinkMode.h"
#import <objc/message.h>

NSString *const ApolloShareLinkModePreferenceKey = @"ApolloShareAsImageLinkMode";
NSString *const ApolloShareLinkLegacyEnabledKey = @"ApolloShareAsImageIncludeLink";

static BOOL ApolloShareLinkModeIsValid(NSInteger rawValue) {
    return rawValue >= ApolloShareLinkModeNone && rawValue <= ApolloShareLinkModeComment;
}

ApolloShareLinkMode ApolloShareLinkModeRead(NSUserDefaults *defaults, BOOL hasComment) {

    id stored = [defaults objectForKey:ApolloShareLinkModePreferenceKey];
    ApolloShareLinkMode mode;
    if ([stored isKindOfClass:NSNumber.class] && ApolloShareLinkModeIsValid([stored integerValue])) {
        mode = (ApolloShareLinkMode)[stored integerValue];
    } else {
        mode = [defaults boolForKey:ApolloShareLinkLegacyEnabledKey]
            ? ApolloShareLinkModePost : ApolloShareLinkModeNone;
    }

    // Comment is not an available destination on a post share. Do not write the
    // mapped value back: the next comment share should still remember Comment.
    if (!hasComment && mode == ApolloShareLinkModeComment) return ApolloShareLinkModePost;
    return mode;
}

void ApolloShareLinkModeWrite(NSUserDefaults *defaults, ApolloShareLinkMode mode) {
    if (!ApolloShareLinkModeIsValid(mode)) mode = ApolloShareLinkModeNone;
    [defaults setInteger:mode forKey:ApolloShareLinkModePreferenceKey];
    [defaults setBool:(mode != ApolloShareLinkModeNone) forKey:ApolloShareLinkLegacyEnabledKey];
}

NSURL *ApolloShareLinkAbsoluteURL(NSURL *url) {
    if (url.scheme.length > 0 && url.host.length > 0) return url;
    NSString *path = url.absoluteString ?: @"";
    if (path.length == 0) return nil;
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    return [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:path]];
}

static BOOL ApolloShareLinkIsRedditCommentURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return NO;
    if (!([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) return NO;
    return [url.path rangeOfString:@"/comments/" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

NSURL *ApolloShareLinkCommentURL(id comment, NSURL *postURL) {
    NSURL *fallback = ApolloShareLinkAbsoluteURL(postURL);
    if (![comment respondsToSelector:@selector(urlWithContext:)]) return fallback;

    @try {
        id value = ((id (*)(id, SEL, NSInteger))objc_msgSend)(comment, @selector(urlWithContext:), 0);
        NSURL *commentURL = ApolloShareLinkAbsoluteURL([value isKindOfClass:NSURL.class] ? value : nil);
        return ApolloShareLinkIsRedditCommentURL(commentURL) ? commentURL : fallback;
    } @catch (__unused NSException *exception) {
        return fallback;
    }
}

NSURL *ApolloShareLinkURLForMode(ApolloShareLinkMode mode, id comment, NSURL *postURL) {
    if (mode == ApolloShareLinkModeNone) return nil;
    if (mode == ApolloShareLinkModeComment) return ApolloShareLinkCommentURL(comment, postURL);
    return ApolloShareLinkAbsoluteURL(postURL);
}
