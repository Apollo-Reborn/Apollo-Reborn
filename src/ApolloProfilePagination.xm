// A profile response belongs to the pagination object that requested it.
//
// Apollo 1.15.11's ProfileViewController refresh clears `overview` and replaces
// `pagination`, including when the profile tab changes accounts. Its native
// fetchNextPage completion does not check either state: it stores the returned
// pagination, appends to the current overview and starts a ListAdapter batch.
// Issue #1064 crashed in that batch, inside ASMutableElementMap insertion.
// Reject the obsolete response BEFORE that Swift completion mutates the model.
//
// Requests can start on ASDK's batch-fetch queue. UI/Swift ivar access remains
// on main; a locked, weak-key identity map connects background requests to the
// profile and generation recorded on main. No usernames or credentials are
// retained, and other RDKClient overview consumers pass through unchanged.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

typedef void (^ApolloProfileOverviewCompletion)(NSArray *items, id pagination, NSError *error);

@interface ApolloProfilePageState : NSObject
@property (nonatomic) NSUInteger generation;
@property (nonatomic, strong) id pagination;
@end
@implementation ApolloProfilePageState
@end

@interface ApolloProfilePageBinding : NSObject
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic) NSUInteger generation;
@end
@implementation ApolloProfilePageBinding
@end

static char kApolloProfilePageStateKey;
static NSHashTable<UIViewController *> *sApolloProfilePageOwners;
static NSMapTable<id, ApolloProfilePageBinding *> *sApolloProfilePageBindings;

static id ApolloProfilePageObjectIvar(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    return ivar ? object_getIvar(object, ivar) : nil;
}

static id ApolloProfileCurrentPagination(UIViewController *owner) {
    return ApolloProfilePageObjectIvar(owner, "pagination");
}

static ApolloProfilePageState *ApolloProfilePageStateForOwner(UIViewController *owner) {
    ApolloProfilePageState *state = objc_getAssociatedObject(owner, &kApolloProfilePageStateKey);
    if (!state && owner) {
        state = [ApolloProfilePageState new];
        state.generation = 1;
        objc_setAssociatedObject(owner, &kApolloProfilePageStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static void ApolloProfilePageCompleteOldBatch(UIViewController *owner) {
    // This is the same ASBatchContext completed by Apollo's captured Swift
    // fetchNextPage completion. Complete it AT RESET, never when an old response
    // arrives: by then the same context may belong to a new account's fetch.
    // ASDK's completeBatchFetching:NO leaves the context fetching; YES frees it
    // for future pages. No table mutation or synthetic native response is needed.
    id node = ApolloProfilePageObjectIvar(owner, "tableNode");
    if (![node respondsToSelector:@selector(isNodeLoaded)] ||
        !((BOOL (*)(id, SEL))objc_msgSend)(node, @selector(isNodeLoaded))) return;
    if (![node respondsToSelector:@selector(view)]) return;
    id table = ((id (*)(id, SEL))objc_msgSend)(node, @selector(view));
    SEL contextSelector = NSSelectorFromString(@"batchContext");
    if (![table respondsToSelector:contextSelector]) return;
    id context = ((id (*)(id, SEL))objc_msgSend)(table, contextSelector);
    SEL fetchingSelector = NSSelectorFromString(@"isFetching");
    SEL completeSelector = NSSelectorFromString(@"completeBatchFetching:");
    if ([context respondsToSelector:fetchingSelector] &&
        [context respondsToSelector:completeSelector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(context, fetchingSelector)) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(context, completeSelector, YES);
    }
}

static void ApolloProfilePageBeginReset(UIViewController *owner) {
    ApolloProfilePageState *state = ApolloProfilePageStateForOwner(owner);
    state.generation++;
    state.pagination = nil;
    ApolloProfilePageCompleteOldBatch(owner);
}

static ApolloProfilePageBinding *ApolloProfilePageBindCurrent(UIViewController *owner) {
    id pagination = ApolloProfileCurrentPagination(owner);
    if (!pagination) return nil;
    ApolloProfilePageState *state = ApolloProfilePageStateForOwner(owner);
    if (state.pagination && state.pagination != pagination) {
        // Covers a native reset reached without the refresh-control selector,
        // e.g. a pushed profile becoming the active account. Accepted responses
        // update state.pagination explicitly below, so a normal next page does
        // not enter this reset path.
        ApolloProfilePageBeginReset(owner);
    }
    state.pagination = pagination;
    ApolloProfilePageBinding *binding = [ApolloProfilePageBinding new];
    binding.owner = owner;
    binding.generation = state.generation;
    @synchronized (sApolloProfilePageBindings) {
        [sApolloProfilePageBindings setObject:binding forKey:pagination];
    }
    return binding;
}

static ApolloProfilePageBinding *ApolloProfilePageBindingForRequest(id pagination) {
    if (!pagination) return nil;
    if ([NSThread isMainThread]) {
        UIViewController *match = nil;
        for (UIViewController *owner in sApolloProfilePageOwners) {
            if (ApolloProfileCurrentPagination(owner) != pagination) continue;
            // Native profiles allocate their own pagination; do not guess an
            // owner if another implementation shares one between controllers.
            if (match) return nil;
            match = owner;
        }
        return match ? ApolloProfilePageBindCurrent(match) : nil;
    }
    @synchronized (sApolloProfilePageBindings) {
        return [sApolloProfilePageBindings objectForKey:pagination];
    }
}

static ApolloProfileOverviewCompletion ApolloProfilePageWrapCompletion(
    id pagination, ApolloProfileOverviewCompletion completion) {
    if (!completion) return nil;
    ApolloProfilePageBinding *binding = ApolloProfilePageBindingForRequest(pagination);
    if (!binding) return completion;
    __block BOOL delivered = NO;
    return ^(NSArray *items, id nextPagination, NSError *error) {
        dispatch_block_t deliver = ^{
            if (delivered) return;
            delivered = YES;
            UIViewController *owner = binding.owner;
            ApolloProfilePageState *state = ApolloProfilePageStateForOwner(owner);
            if (!owner || state.generation != binding.generation ||
                state.pagination != pagination || ApolloProfileCurrentPagination(owner) != pagination) {
                ApolloLog(@"[ProfilePagination] Discarded a response from an obsolete profile load");
                return;
            }
            // Completing ASBatchContext can schedule the next fetch on its
            // background queue before this call returns. Publish the proposed
            // page first; delivery still checks the actual native ivar on main,
            // so a rejected/error result cannot make this provisional page valid.
            if (nextPagination) {
                @synchronized (sApolloProfilePageBindings) {
                    [sApolloProfilePageBindings setObject:binding forKey:nextPagination];
                }
            }
            completion(items, nextPagination, error);
            if (state.generation == binding.generation) {
                // Native completion synchronously replaces the pagination and
                // completes its ASBatchContext. Publish the new object for the
                // next request, which ASDK may start on a background queue.
                state.pagination = ApolloProfileCurrentPagination(owner);
                ApolloProfilePageBindCurrent(owner);
            }
        };
        if ([NSThread isMainThread]) deliver();
        else dispatch_async(dispatch_get_main_queue(), deliver);
    };
}

static BOOL ApolloProfilePageIsAccountTab(UIViewController *owner) {
    UINavigationController *navigation = owner.navigationController;
    return navigation && navigation.viewControllers.firstObject == owner &&
        [owner.tabBarController.viewControllers containsObject:navigation];
}

@interface ApolloProfilePaginationController : UIViewController
@end

%group ApolloProfilePaginationHooks

%hook ApolloProfilePaginationController

- (void)viewDidLoad {
    [sApolloProfilePageOwners addObject:self];
    ApolloProfilePageBindCurrent(self);
    %orig;
    ApolloProfilePageBindCurrent(self);
}

- (void)refreshControlActivatedWithSender:(id)sender {
    id oldPagination = ApolloProfileCurrentPagination(self);
    ApolloProfilePageBeginReset(self);
    %orig;
    if (ApolloProfileCurrentPagination(self) != oldPagination) ApolloProfilePageBindCurrent(self);
}

- (void)redditAccountChangedWithNotification:(id)notification {
    id oldPagination = ApolloProfileCurrentPagination(self);
    // The persistent account tab also resets when signing out; that native
    // path may leave the old pagination object in place. Invalidate its epoch
    // before calling Apollo, without decoding the Swift ProfileType enum.
    if (ApolloProfilePageIsAccountTab(self)) ApolloProfilePageBeginReset(self);
    %orig;
    if (ApolloProfileCurrentPagination(self) != oldPagination) ApolloProfilePageBindCurrent(self);
}

%end

%hook RDKClient

- (id)overviewOfUserWithUsername:(id)username pagination:(id)pagination completion:(ApolloProfileOverviewCompletion)completion {
    return %orig(username, pagination, ApolloProfilePageWrapCompletion(pagination, completion));
}

%end

%end

%ctor {
    Class profileClass = NSClassFromString(@"Apollo.ProfileViewController");
    if (!profileClass) profileClass = NSClassFromString(@"_TtC6Apollo21ProfileViewController");
    if (!profileClass || !class_getInstanceVariable(profileClass, "pagination") ||
        !class_getInstanceMethod(NSClassFromString(@"RDKClient"),
            @selector(overviewOfUserWithUsername:pagination:completion:))) return;
    sApolloProfilePageOwners = [NSHashTable weakObjectsHashTable];
    sApolloProfilePageBindings = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                                    valueOptions:NSPointerFunctionsStrongMemory];
    %init(ApolloProfilePaginationHooks, ApolloProfilePaginationController = profileClass);
    ApolloLog(@"[ProfilePagination] Profile response ownership guard installed");
}
