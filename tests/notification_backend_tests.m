#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

#import "ApolloNotificationBackend.h"
#import "ApolloAccountCredentials.h"
#import "UserDefaultConstants.h"

// Only the unrelated account/Bark inputs are stubbed. The executable compiles
// the real configuration getters and request rewrite from the feature module.
NSString *sRedditClientId = @"";
NSString *sRedditClientSecret = @"";
NSString *sRedirectURI = @"";
NSString *sUserAgent = @"";
BOOL ApolloBarkModeActive(void) { return NO; }
NSURL *ApolloBarkEffectivePushURL(void) { return nil; }
ApolloAccountCredentialEntry *ApolloAccountCredentialsFor(__unused NSString *username) { return nil; }

static NSUserDefaults *sTestDefaults;
static NSString *sTestDomain;

static id TestStandardUserDefaults(__unused id self, __unused SEL selector) {
    return sTestDefaults;
}

static void Require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "notification_backend_tests: %s\n", message);
        abort();
    }
}

static NSDictionary *Configuration(NSUInteger generation) {
    return @{
        UDKeyNotificationBackendURL: [NSString stringWithFormat:@" https://backend-%lu.example:8443/// \n", (unsigned long)generation],
        UDKeyNotificationBackendRegistrationToken: [NSString stringWithFormat:@" token-%lu \n", (unsigned long)generation],
    };
}

static void SetConfiguration(NSDictionary *configuration) {
    [sTestDefaults setPersistentDomain:configuration forName:sTestDomain];
    // Exercise the old invalidation trigger even on hosts that coalesce their
    // defaults notifications. This may run alongside every request worker.
    [[NSNotificationCenter defaultCenter] postNotificationName:NSUserDefaultsDidChangeNotification object:sTestDefaults];
}

static NSMutableURLRequest *RegistrationRequest(void) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://apollonotifications.com/v1/live_activities?existing=1"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [@"original body" dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"preserved" forHTTPHeaderField:@"X-Existing"];
    return request;
}

static void CheckRewrittenRequest(NSURLRequest *rewritten, NSURLRequest *original) {
    Require(rewritten != nil, "a configured legacy backend must be rewritten");
    NSString *host = rewritten.URL.host;
    Require([host hasPrefix:@"backend-"] && [host hasSuffix:@".example"], "unexpected rewritten host");
    NSString *generation = [[host componentsSeparatedByString:@"."][0] substringFromIndex:@"backend-".length];
    NSString *expectedToken = [@"token-" stringByAppendingString:generation];
    Require([[rewritten valueForHTTPHeaderField:@"X-Registration-Token"] isEqualToString:expectedToken], "backend and token must come from the same defaults snapshot");
    Require([rewritten.URL.scheme isEqualToString:@"https"] && rewritten.URL.port.integerValue == 8443, "backend scheme and port must be applied");
    Require([rewritten.URL.path isEqualToString:original.URL.path] && [rewritten.URL.query isEqualToString:original.URL.query], "rewrite must preserve path and query");
    Require([rewritten.HTTPMethod isEqualToString:original.HTTPMethod] && [rewritten.HTTPBody isEqualToData:original.HTTPBody], "rewrite must preserve method and body");
    Require([[rewritten valueForHTTPHeaderField:@"X-Existing"] isEqualToString:@"preserved"], "rewrite must preserve unrelated headers");
}

static void TestSettingsChangesAndRetainedValues(void) {
    SetConfiguration(Configuration(1));
    NSURL *heldURL = ApolloNotificationBackendBaseURL();
    NSString *heldToken = ApolloNotificationBackendRegistrationToken();
    Require(ApolloIsNotificationBackendConfigured(), "valid backend should be configured");
    Require([heldURL.absoluteString isEqualToString:@"https://backend-1.example:8443"], "base URL whitespace and trailing slashes must be trimmed");
    Require([heldToken isEqualToString:@"token-1"], "token whitespace must be trimmed");

    SetConfiguration(Configuration(2));
    NSMutableURLRequest *request = RegistrationRequest();
    CheckRewrittenRequest(ApolloRewriteRequestForNotificationBackend(request), request);
    Require([ApolloNotificationBackendBaseURL().host isEqualToString:@"backend-2.example"], "getters must see settings changes immediately");
    Require([ApolloNotificationBackendRegistrationToken() isEqualToString:@"token-2"], "token getter must see settings changes immediately");
    Require([[NSURLComponents componentsWithURL:heldURL resolvingAgainstBaseURL:NO].host isEqualToString:@"backend-1.example"] && [heldToken isEqualToString:@"token-1"], "previously returned values must survive later settings changes");
    Require([request.URL.host isEqualToString:@"apollonotifications.com"] && [request valueForHTTPHeaderField:@"X-Registration-Token"] == nil, "rewrite must leave the original request unchanged");

    SetConfiguration(@{});
    Require(!ApolloIsNotificationBackendConfigured() && ApolloNotificationBackendBaseURL() == nil, "removed backend must disable rewriting immediately");
    Require(ApolloRewriteRequestForNotificationBackend(request) == nil && ApolloNotificationBackendRegistrationToken() == nil, "removed configuration must not leave stale values");

    for (id invalid in @[@"file:///tmp/backend", @"https://", @"   /  ", @[@"https://invalid.example"]]) {
        SetConfiguration(@{UDKeyNotificationBackendURL: invalid});
        Require(!ApolloIsNotificationBackendConfigured(), "invalid backend should be rejected");
    }
}

static void TestConcurrentSettingsAndRewrites(void) {
    SetConfiguration(Configuration(1));
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t start = dispatch_semaphore_create(0);
    // A writer replaces URL and token together while six request workers read,
    // retain, and bridge their values. Tests both lifetime and paired snapshots.
    dispatch_group_async(group, queue, ^{
        dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER);
        for (NSUInteger iteration = 0; iteration < 3000; iteration++) {
            @autoreleasepool {
                SetConfiguration(Configuration(iteration + 2));
            }
        }
    });
    for (NSUInteger worker = 0; worker < 6; worker++) {
        dispatch_group_async(group, queue, ^{
            dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER);
            for (NSUInteger iteration = 0; iteration < 2000; iteration++) {
                @autoreleasepool {
                    NSURL *heldURL = ApolloNotificationBackendBaseURL();
                    NSString *heldToken = ApolloNotificationBackendRegistrationToken();
                    NSMutableURLRequest *request = RegistrationRequest();
                    CheckRewrittenRequest(ApolloRewriteRequestForNotificationBackend(request), request);
                    if (iteration % 100 == 0) usleep(100);
                    Require([NSURLComponents componentsWithURL:heldURL resolvingAgainstBaseURL:NO].host.length > 0 && heldToken.length > 0, "retained values must remain usable across concurrent replacement");
                }
            }
        });
    }
    for (NSUInteger worker = 0; worker < 7; worker++) dispatch_semaphore_signal(start);
    Require(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) == 0, "concurrent configuration stress timed out");
}

int main(void) {
    @autoreleasepool {
        sTestDomain = [@"app.apolloreborn.notification-backend-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        sTestDefaults = [[NSUserDefaults alloc] initWithSuiteName:sTestDomain];
        Method standardDefaults = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        IMP originalDefaults = method_setImplementation(standardDefaults, (IMP)TestStandardUserDefaults);
        TestSettingsChangesAndRetainedValues();
        TestConcurrentSettingsAndRewrites();
        method_setImplementation(standardDefaults, originalDefaults);
        [sTestDefaults removePersistentDomainForName:sTestDomain];
        puts("notification_backend_tests: settings/lifetime checks and 12,000 concurrent rewrites passed");
    }
    return 0;
}
