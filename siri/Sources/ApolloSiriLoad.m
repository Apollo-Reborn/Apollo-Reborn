#import <Foundation/Foundation.h>
#import <ApolloSiri/ApolloSiri-Swift.h>

// Apollo's executable is not rebuilt. Start on its main queue after dyld has
// loaded the framework, without replacing its app/scene delegates or main().
__attribute__((constructor)) static void ApolloSiriLoad(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [ApolloSiriBootstrap prepare];
    });
}
