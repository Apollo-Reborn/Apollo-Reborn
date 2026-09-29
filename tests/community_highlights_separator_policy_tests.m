#import <Foundation/Foundation.h>

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"CommunityHighlightsSeparatorPolicyFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

int main(void) {
    @autoreleasepool {
        // Home/All and unrelated live feeds must never inherit another
        // subreddit's process-wide de-duplication state.
        Require(!ApolloHLSeparatorRowShouldCollapse(1, NO, NO, 0, 0),
                @"an ineligible Home first separator stays visible");
        Require(!ApolloHLSeparatorRowShouldCollapse(3, NO, YES, 3, 0),
                @"ineligible feeds ignore cached sticky counts");

        // Cold load assumes the common two-sticky layout until REST publishes N.
        Require(ApolloHLSeparatorRowShouldCollapse(1, YES, NO, 0, 0),
                @"cold subreddit load collapses the first orphan");
        Require(!ApolloHLSeparatorRowShouldCollapse(3, YES, NO, 0, 0),
                @"cold fallback keeps a single breaker");

        Require(!ApolloHLSeparatorRowShouldCollapse(1, YES, YES, 1, 0),
                @"one sticky keeps its only breaker");
        Require(ApolloHLSeparatorRowShouldCollapse(1, YES, YES, 2, 0),
                @"two stickies collapse the first orphan");
        Require(!ApolloHLSeparatorRowShouldCollapse(3, YES, YES, 2, 0),
                @"two stickies keep the final breaker");
        Require(ApolloHLSeparatorRowShouldCollapse(1, YES, YES, 3, 0) &&
                ApolloHLSeparatorRowShouldCollapse(3, YES, YES, 3, 0) &&
                !ApolloHLSeparatorRowShouldCollapse(5, YES, YES, 3, 0),
                @"three stickies keep exactly the final breaker");

        // Bit set means the feed owns that interactive sticky, so its trailing
        // breaker stays while collapsed siblings lose theirs.
        Require(!ApolloHLSeparatorRowShouldCollapse(1, YES, YES, 2, 0x1),
                @"visible first interactive sticky keeps its breaker");
        Require(ApolloHLSeparatorRowShouldCollapse(3, YES, YES, 2, 0x1),
                @"collapsed second sticky loses its orphan");
        Require(!ApolloHLSeparatorRowShouldCollapse(5, YES, YES, 2, 0x1),
                @"rows after the sticky run stay untouched");

        puts("community_highlights_separator_policy_tests passed");
    }
    return 0;
}
