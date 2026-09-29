#import <Foundation/Foundation.h>
#import "ApolloBarkIconResolver.h"

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"BarkIconResolverTestFailure"
                                       reason:message
                                     userInfo:nil];
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Require([ApolloBarkResolvedHostedIconName(@"mechapollo") isEqualToString:@"mechapollo"],
                @"keeps a hosted alternate icon");
        Require([ApolloBarkResolvedHostedIconName(@"burnt-orange") isEqualToString:@"burnt-orange"],
                @"keeps the hosted classic used by the Nuclear Sunset mapping");
        Require([ApolloBarkResolvedHostedIconName(@"bajader-apollos") isEqualToString:@"default"],
                @"falls back for issue 694's missing icon");
        Require([ApolloBarkResolvedHostedIconName(@"future-unhosted-icon") isEqualToString:@"default"],
                @"falls back for future unhosted icons");
        Require([ApolloBarkResolvedHostedIconName(nil) isEqualToString:@"default"],
                @"falls back for the stock icon");
        Require([ApolloBarkResolvedHostedIconName(@42) isEqualToString:@"default"],
                @"falls back for malformed persisted values");
        for (int index = 1; index < argc; index++) {
            NSString *missingName = [NSString stringWithUTF8String:argv[index]];
            Require([ApolloBarkResolvedHostedIconName(missingName) isEqualToString:@"default"],
                    [NSString stringWithFormat:@"falls back for selectable icon without hosted PNG: %@",
                                               missingName]);
        }
        NSLog(@"bark_icon_resolver_tests passed");
    }
    return 0;
}
