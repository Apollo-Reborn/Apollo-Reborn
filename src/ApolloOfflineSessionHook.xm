// ApolloOfflineSessionHook.xm
//
// Puts Offline Mode's URL protocol (ApolloOfflineURLProtocol, in
// ApolloOfflineMode.xm) in front of every NSURLSession as it's created, so the
// offline library can answer that session's requests.
//
// Its own file, first in the Makefile's list, so this hook is installed before
// any other module's %ctor runs. Sessions are fixed at creation: one made in an
// earlier %ctor (Reborn's avatar cache builds its two sessions at launch) would
// otherwise never see the protocol, and its requests would just fail offline.
//
// Hooked at session creation, not at +defaultSessionConfiguration: Apollo's
// RedditKit client is an AFHTTPSessionManager restored from the account
// archive, whose configuration is decoded rather than built from
// +defaultSessionConfiguration (verified in the sim: its comment and listing
// reads never reached a config-hooked protocol). Every session is created
// here, so this covers the archived client, PINRemoteImage and the rest.

#import <Foundation/Foundation.h>

// A copy of `configuration` with the offline protocol first, or the original
// when it already has it or is a background configuration (those can't run
// custom protocols). The class is looked up by name: it lives in a file that
// loads later, but in the same image, so it's always there by now.
static NSURLSessionConfiguration *ApolloOfflineConfigurationWithProtocol(NSURLSessionConfiguration *configuration) {
    Class protocol = NSClassFromString(@"ApolloOfflineURLProtocol");
    if (!protocol || !configuration || configuration.identifier.length > 0) return configuration;
    NSArray *existing = configuration.protocolClasses ?: @[];
    if ([existing containsObject:protocol]) return configuration;
    NSURLSessionConfiguration *copy = [configuration copy];
    NSMutableArray *protocols = [NSMutableArray arrayWithArray:existing];
    [protocols insertObject:protocol atIndex:0];
    copy.protocolClasses = protocols;
    return copy;
}

%hook NSURLSession

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    return %orig(ApolloOfflineConfigurationWithProtocol(configuration));
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    return %orig(ApolloOfflineConfigurationWithProtocol(configuration), delegate, queue);
}

%end

%ctor {
    %init;
}
