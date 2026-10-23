#import "ApolloSearchVisitRecording.h"
#import "ApolloSearchRecents.h"
#import "ApolloClasses.h"
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Shared native PostsType discriminator.
extern NSInteger ApolloPostsTypeTagFromViewController(UIViewController *controller);

extern "C" void *ApolloSwiftCopyFirstObjectArrayElement(const void *storage);

// Apollo 1.15.11 stores PostsType.subreddit's Swift String in its first two
// words and the enum tag at +0x20. Read that model, not a title that can still
// describe the previous page while the new subreddit is loading.
NSString *ApolloNamedSubredditForPostsController(UIViewController *controller) {
    if (!ApolloClassPostsViewController || ![controller isKindOfClass:ApolloClassPostsViewController]) return nil;
    ptrdiff_t offset = ApolloIvarOffset(controller.class, "currentPostsType");
    if (offset < 0 || (size_t)offset + 0x21 > class_getInstanceSize(controller.class)) return nil;
    const uint8_t *storage = (const uint8_t *)(__bridge const void *)controller + offset;
    if (storage[0x20] != 0) return nil;
    uint64_t words[2] = {0, 0};
    memcpy(words, storage, sizeof(words));
    NSString *name = ApolloDecodeSwiftString(words[0], words[1]);
    if (!name.length || [@[@"all", @"popular", @"mod", @"random", @"randnsfw"] containsObject:name.lowercaseString]) return nil;
    return name;
}

@interface ApolloSearchVisitState : NSObject
@property(nonatomic) NSInteger postsType;
@property(nonatomic, weak) id firstLink;
@property(nonatomic, weak) id staleRandomLink;
@property(nonatomic, copy) NSString *subredditName;
@end
@implementation ApolloSearchVisitState
@end

static id ApolloSearchFirstFeedLink(UIViewController *controller) {
    // Swift's non-optional Array is one pointer-sized stored value. Validate
    // the ivar's presence/bounds, then let Swift read its class-reference array.
    ptrdiff_t offset = ApolloIvarOffset(controller.class, "links");
    if (offset < 0 || (size_t)offset + sizeof(void *) > class_getInstanceSize(controller.class)) return nil;
    const void *storage = (const uint8_t *)(__bridge const void *)controller + offset;
    id link = (__bridge_transfer id)ApolloSwiftCopyFirstObjectArrayElement(storage);
    return ApolloClassRDKLink && [link isKindOfClass:ApolloClassRDKLink] ? link : nil;
}

static char kSearchVisitState;
static void ApolloSearchRecordVisibleSubreddit(UIViewController *controller, BOOL appeared) {
    if (!NSThread.isMainThread || !controller.viewIfLoaded.window ||
        controller.navigationController.topViewController != controller) return;
    ApolloSearchVisitState *state = objc_getAssociatedObject(controller, &kSearchVisitState);
    if (!state) {
        state = [[ApolloSearchVisitState alloc] init];
        state.postsType = -1;
        objc_setAssociatedObject(controller, &kSearchVisitState, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSInteger tag = ApolloPostsTypeTagFromViewController(controller);
    id firstLink = ApolloSearchFirstFeedLink(controller);
    if (tag == 5 && state.postsType != 5) {
        // The title dropdown can reuse a controller before its new request
        // replaces links. Do not record the old named feed as Random's result.
        state.staleRandomLink = firstLink == state.firstLink ? firstLink : nil;
    } else if (tag != 5 || firstLink != state.staleRandomLink) {
        state.staleRandomLink = nil;
    }
    state.postsType = tag;
    state.firstLink = firstLink;

    NSString *name = ApolloNamedSubredditForPostsController(controller);
    if (!name.length && tag == 5 && firstLink && firstLink != state.staleRandomLink &&
        [firstLink respondsToSelector:@selector(subreddit)]) {
        // Our Random URL rewrite resolves the listing while Apollo keeps the
        // Random title and leaves its about/name fields empty. The loaded link
        // model identifies the destination; aggregate/profile feeds never use
        // this fallback.
        id resolved = ((id (*)(id, SEL))objc_msgSend)(firstLink, @selector(subreddit));
        if ([resolved isKindOfClass:NSString.class]) name = resolved;
    }
    NSString *previous = state.subredditName;
    if (!appeared && (name == previous || [name isEqualToString:previous])) return;
    state.subredditName = name;
    if (name.length) ApolloSearchRecordVisit(name);
}

@interface ApolloSearchVisitedPosts : UIViewController @end
%group ApolloSearchVisitHooks
%hook ApolloSearchVisitedPosts
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloSearchRecordVisibleSubreddit(self, YES);
}
- (void)viewDidLayoutSubviews {
    %orig;
    // The title dropdown can reuse the visible Posts controller without a
    // navigation callback. Observe identity only; never change layout here.
    ApolloSearchRecordVisibleSubreddit(self, NO);
}
%end
%end

%ctor {
    if (ApolloClassPostsViewController)
        %init(ApolloSearchVisitHooks, ApolloSearchVisitedPosts = ApolloClassPostsViewController);
}
