#import <Foundation/Foundation.h>

#import "ApolloDeletedCommentsData.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"DeletedCommentsRaceTestFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

int main(void) {
    @autoreleasepool {
        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        const NSUInteger iterations = 5000;

        for (NSUInteger writer = 0; writer < 4; writer++) {
            dispatch_group_async(group, queue, ^{
                NSURLRequest *request = [NSURLRequest requestWithURL:
                    [NSURL URLWithString:@"https://oauth.reddit.com/r/test/comments/thread-race/title/"]];
                for (NSUInteger index = 0; index < iterations; index++) {
                    @autoreleasepool {
                        ApolloDeletedCommentsHandleRequestObservation(request, @"race writer");
                    }
                }
            });
        }

        for (NSUInteger reader = 0; reader < 2; reader++) {
            dispatch_group_async(group, queue, ^{
                NSURLRequest *request = [NSURLRequest requestWithURL:
                    [NSURL URLWithString:@"https://oauth.reddit.com/api/morechildren"]];
                for (NSUInteger index = 0; index < iterations; index++) {
                    @autoreleasepool {
                        ApolloDeletedCommentsURLSessionCompletion original =
                            ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {};
                        ApolloDeletedCommentsURLSessionCompletion wrapped =
                            ApolloDeletedCommentsMaybeWrapCompletion(request, original);
                        Require(wrapped != nil, @"morechildren fallback keeps a completion");
                    }
                }
            });
        }

        Require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
                @"concurrent observed-link stress test completed");
        NSLog(@"deleted_comments_observed_link_race_tests passed");
    }
    return 0;
}
