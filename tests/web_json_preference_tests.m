#import <Foundation/Foundation.h>
#import "ApolloWebJSONPreference.h"

static NSUInteger checks;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Check(!ApolloWebJSONLaunchShouldEnable(NO, NO, NO),
              @"a fresh install stays disabled");
        Check(ApolloWebJSONLaunchShouldEnable(YES, NO, NO),
              @"an enabled preference stays enabled without a stored session");
        Check(ApolloWebJSONLaunchShouldEnable(YES, YES, YES),
              @"the enabled preference remains authoritative over stale metadata");
        Check(ApolloWebJSONLaunchShouldEnable(NO, YES, NO),
              @"a legacy stored web session repairs the old disabled state");
        Check(!ApolloWebJSONLaunchShouldEnable(NO, YES, YES),
              @"an explicit opt-out survives launch with stored web sessions");
        Check(!ApolloWebJSONLaunchShouldEnable(NO, NO, YES),
              @"an explicit opt-out stays disabled without stored sessions");

        printf("PASS: %lu API-Key-Free launch preference checks\n",
               (unsigned long)checks);
    }
    return 0;
}
