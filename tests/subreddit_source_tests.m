#import <Foundation/Foundation.h>

// PRODUCTION_HELPERS

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

int main(void) {
    @autoreleasepool {
        NSString *source = @"18_19\n"
                           "  valid_name  \n"
                           "Subreddits working as of Dec/2024\n"
                           "two words\n"
                           "r/prefixed\n"
                           "emoji_🚫\n"
                           "a\n"
                           "ab\n"
                           "de\n"
                           "it\n"
                           "abcdefghijklmnopqrstu\n"
                           "abcdefghijklmnopqrstuv\n"
                           "\n";
        NSArray<NSString *> *parsed = ApolloSubredditListLines(source);
        NSArray<NSString *> *expected = @[
            @"18_19",
            @"valid_name",
            @"ab",
            @"de",
            @"it",
            @"abcdefghijklmnopqrstu",
        ];
        Check([parsed isEqualToArray:expected],
              @"parser must retain valid names and discard metadata or invalid names");
        Check(ApolloSubredditListLines(nil).count == 0, @"nil source must be empty");
        Check(ApolloSubredditListLines(@"").count == 0, @"empty source must be empty");
        NSLog(@"PASS: subreddit source validation");
    }
    return 0;
}
