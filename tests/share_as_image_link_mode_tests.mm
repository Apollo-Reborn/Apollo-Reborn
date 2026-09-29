#import <Foundation/Foundation.h>
#import "ApolloShareAsImageLinkMode.h"

static NSUInteger sChecks;

static void Check(BOOL condition, NSString *message) {
    sChecks++;
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

@interface LinkModeTestComment : NSObject
@property (nonatomic, strong) id result;
@property (nonatomic) BOOL shouldThrow;
@property (nonatomic) NSInteger observedContext;
@end

@implementation LinkModeTestComment
- (id)urlWithContext:(NSInteger)context {
    self.observedContext = context;
    if (self.shouldThrow) [NSException raise:@"TestException" format:@"expected"];
    return self.result;
}
@end

static NSUserDefaults *FreshDefaults(void) {
    NSString *suite = [@"ApolloShareAsImageLinkModeTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    return [[NSUserDefaults alloc] initWithSuiteName:suite];
}

int main(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = FreshDefaults();
        Check(ApolloShareLinkModeRead(defaults, NO) == ApolloShareLinkModeNone,
              @"a fresh post share defaults to no link");
        [defaults setBool:YES forKey:ApolloShareLinkLegacyEnabledKey];
        Check(ApolloShareLinkModeRead(defaults, YES) == ApolloShareLinkModePost,
              @"the legacy enabled preference migrates to post link");
        [defaults setBool:NO forKey:ApolloShareLinkLegacyEnabledKey];
        Check(ApolloShareLinkModeRead(defaults, YES) == ApolloShareLinkModeNone,
              @"the legacy disabled preference migrates to no link");

        ApolloShareLinkModeWrite(defaults, ApolloShareLinkModeComment);
        Check(ApolloShareLinkModeRead(defaults, YES) == ApolloShareLinkModeComment,
              @"comment shares retain the saved comment-link choice");
        Check(ApolloShareLinkModeRead(defaults, NO) == ApolloShareLinkModePost,
              @"post shares map a saved comment-link choice to post link");
        Check([defaults boolForKey:ApolloShareLinkLegacyEnabledKey],
              @"a comment-link choice keeps older share modules enabled");
        ApolloShareLinkModeWrite(defaults, ApolloShareLinkModeNone);
        Check(![defaults boolForKey:ApolloShareLinkLegacyEnabledKey],
              @"a no-link choice disables the legacy boolean too");

        [defaults setObject:@99 forKey:ApolloShareLinkModePreferenceKey];
        [defaults setBool:YES forKey:ApolloShareLinkLegacyEnabledKey];
        Check(ApolloShareLinkModeRead(defaults, YES) == ApolloShareLinkModePost,
              @"an invalid new value safely falls back to the legacy preference");

        NSURL *postURL = [NSURL URLWithString:@"/r/test/comments/post123/title/"];
        LinkModeTestComment *comment = [LinkModeTestComment new];
        comment.result = [NSURL URLWithString:@"/r/test/comments/post123/title/comment456/"];
        NSURL *resolved = ApolloShareLinkCommentURL(comment, postURL);
        Check([resolved.absoluteString isEqualToString:@"https://www.reddit.com/r/test/comments/post123/title/comment456/"] &&
              comment.observedContext == 0,
              @"a relative comment permalink is preferred and made absolute");
        Check(ApolloShareLinkURLForMode(ApolloShareLinkModeNone, comment, postURL) == nil,
              @"no-link mode attaches nothing on either export path");
        Check([[ApolloShareLinkURLForMode(ApolloShareLinkModePost, comment, postURL) absoluteString]
               isEqualToString:@"https://www.reddit.com/r/test/comments/post123/title/"],
              @"post-link mode ignores an available comment");
        Check([[ApolloShareLinkURLForMode(ApolloShareLinkModeComment, comment, postURL) absoluteString]
               isEqualToString:@"https://www.reddit.com/r/test/comments/post123/title/comment456/"],
              @"comment-link mode resolves the comment for image and video exports");

        comment.result = @"not a URL";
        Check([[ApolloShareLinkCommentURL(comment, postURL) absoluteString]
               isEqualToString:@"https://www.reddit.com/r/test/comments/post123/title/"],
              @"a malformed comment result falls back to the post permalink");
        comment.result = [NSURL URLWithString:@"https://example.com/r/test/comments/post123/title/comment456/"];
        Check([[ApolloShareLinkCommentURL(comment, postURL) absoluteString]
               isEqualToString:@"https://www.reddit.com/r/test/comments/post123/title/"],
              @"an off-site result cannot replace the Reddit post permalink");
        comment.shouldThrow = YES;
        Check([[ApolloShareLinkCommentURL(comment, postURL) absoluteString]
               isEqualToString:@"https://www.reddit.com/r/test/comments/post123/title/"],
              @"an exception while resolving a comment falls back to the post permalink");
        Check([[ApolloShareLinkCommentURL(nil, postURL) absoluteString]
               isEqualToString:@"https://www.reddit.com/r/test/comments/post123/title/"],
              @"a missing comment falls back to the post permalink");
    }

    printf("share-as-image link mode checks passed (%lu)\n", (unsigned long)sChecks);
    return 0;
}
