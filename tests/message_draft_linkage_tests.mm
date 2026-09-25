#import <Foundation/Foundation.h>

#import "ApolloMessageDraftStore.h"

// This translation unit is Objective-C++. The production Direct Chat module is
// Objective-C++, while the store stays Objective-C; linking this call catches
// an accidental C++ name-mangling regression in the public header.
int main(void) {
    @autoreleasepool {
        NSString *key = ApolloMessageDraftOpaqueKey(@"alice", @"web:/chat/room/example");
        if (key.length != 64) return 1;
    }
    puts("message_draft_linkage_tests: Objective-C++ linkage passed");
    return 0;
}
