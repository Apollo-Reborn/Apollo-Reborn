// Profile lists that load nothing show a message instead of a spinner forever.
//
// Reddit answers a profile's comments or posts listing with an empty page for
// every viewer except the owner when the owner hides that history from their
// profile (Reddit's own site says "u/x likes to keep their comments hidden").
// Many accounts do: nearly half of a sample of recent r/all commenters (11 of
// 24) returned no comments to anyone else. Several of Apollo 1.15.11's list
// screens never leave their loading spinner when a first page comes back with
// nothing, or fails:
//
//   * UserCommentsViewController (a profile's Comments) and FriendsViewController
//     (its Posts and Comments tabs) have no empty state at all. Their ListAdapter
//     data sources answer emptyView(for:) with AutoThemedSpinner() every time.
//     The comments completion also returns early on an error, without ending a
//     pull to refresh.
//   * PostsViewController (a profile's Posts, Upvoted, Downvoted and Hidden, and
//     Home, subreddit and multireddit feeds) has real empty states ("No
//     submitted posts", "No posts in Home", "r/x has been set to private ..."),
//     picked once its pagination is nil or the subreddit has an issue. But
//     ListAdapter only asks for the empty view while updating the list, and
//     handleNewLinks(_:withPagination:error:) doesn't update an empty list, so
//     the spinner it got while loading stays up. A failure with no known issue
//     picks the spinner again.
//
// Each of these lists hands RedditKit the pagination object it keeps for itself
// on a first page, and every one of their listings goes through
// -[RDKClient listingTaskWithPath:parameters:pagination:completion:], so that
// call identifies the list and reports how its first page ended:
//
//   * Posts: once the page has been handled, ask ListAdapter to re-evaluate the
//     list (tableNode:numberOfRowsInSection: schedules its empty-view pass), so
//     Apollo's own empty state replaces the spinner.
//   * The other lists with nothing in them, and any of them after a failure:
//     while that outcome stands, hide each spinner ListAdapter installs as the
//     list's empty view (it removes and re-creates the view on every update)
//     and show a message styled like Apollo's EmptyStateLabel in its place.
//
// A new first page (pull to refresh, a sort change) brings the spinner back
// until it finishes.
//
// Rate limit (issues #1649, #1664): Reddit refuses every request from an
// API-Key-Free session once its ten-minute budget is spent, until the window
// resets. ApolloWebJSON then holds the account (ApolloWebJSONOptionalReadBackoff)
// and a toast says to try again in a few minutes, but a list whose first page
// failed stayed on "Pull down to try again" until the user did. A first page
// that fails while Reddit holds the account that sent it now says it will load
// once the limit resets, and the list reloads itself (through its own pull to
// refresh action) when that account's hold ends, or as soon as the app is back
// in the foreground after that. Each list waits on its own request's account:
// switching to another account ends the wait, and an older first page that
// finishes after a newer one has started leaves the list to the newer one.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import "ApolloAccountCredentials.h"

@interface RDKPagination : NSObject
@property (copy, nonatomic) NSString *after;
- (NSDictionary *)dictionaryValue;
@end

@interface RDKClient : NSObject
@end

typedef void (^ApolloListPageCompletion)(NSArray *items, RDKPagination *nextPagination, NSError *error);

typedef NS_ENUM(NSInteger, ApolloListKind) {
    ApolloListKindUserComments = 0,
    ApolloListKindPosts,           // Apollo has its own empty states
    ApolloListKindFriendsPosts,
    ApolloListKindFriendsComments,
};

typedef NS_ENUM(NSInteger, ApolloListOutcome) {
    ApolloListOutcomeNone = 0, // no first page has finished: Apollo's spinner is right
    ApolloListOutcomeEmpty,    // the first page had nothing and no next page
    ApolloListOutcomeFailed,   // the first page failed
};

// One ListAdapter-backed list on a controller: the adapter, the pagination
// object the controller passes to RedditKit for it, what it lists, and the
// action its pull to refresh sends (it ignores the sender).
typedef struct {
    Class controllerClass;
    Ivar adapterIvar;
    Ivar paginationIvar;
    ApolloListKind kind;
    SEL refreshSelector;
} ApolloListSlot;

// One first page of one list. A new first page (load, pull to refresh, sort)
// replaces the list's state, so a state also identifies the request it was
// made for.
@interface ApolloListLoadState : NSObject
@property (nonatomic) ApolloListKind kind;
@property (nonatomic) ApolloListOutcome outcome;
@property (nonatomic, copy) NSString *username;
@property (nonatomic) BOOL timeFiltered;
// The API-Key-Free account that sent this first page, lowercased; nil for an
// API-key account.
@property (nonatomic, copy) NSString *account;
// The first page failed while Reddit was rate-limiting `account`; the list
// reloads itself once that account's limit resets (see the header).
@property (nonatomic) BOOL waitingForRateLimit;
@property (nonatomic, weak) id adapter;
@property (nonatomic, weak) id controller;
@property (nonatomic) SEL refreshSelector;
@end

@implementation ApolloListLoadState
@end

#pragma mark - Rate-limit decisions

// Foundation-only, so tests/run_list_rate_limit_tests.sh runs this block as is
// (from the ApolloListKind enum to the end marker below).

// How long after an account's hold ends its waiting lists reload. The hold
// ends by this device's clock; a reload that reached Reddit just before its own
// window turned over would be refused, and a refusal right before a reset holds
// for a whole new window.
static NSTimeInterval const kApolloListRateLimitRetryMargin = 5.0;

// What Reddit's hold on the account that sent this list's first page has left;
// 0 when none is running, and always for an API-key account.
static NSTimeInterval ApolloListStateHold(ApolloListLoadState *state) {
    return state.account.length > 0 ? ApolloWebJSONOptionalReadBackoff(state.account) : 0;
}

// Records how the first page `request` stands for ended, if it still owns its
// list (`current` is the list's state now). A newer first page replaces the
// state, and an older request finishing after it must neither mark the newer
// one waiting nor clear its wait: that returns NO and leaves `current` alone.
// A first page that failed while Reddit held its account, on a list with
// nothing in it yet, waits for the hold to end; a list that still shows posts
// keeps them and isn't reloaded under the reader.
static BOOL ApolloListRecordOutcome(ApolloListLoadState *current, ApolloListLoadState *request,
                                    ApolloListOutcome outcome, BOOL listEmpty) {
    if (!request || current != request) return NO;
    request.outcome = outcome;
    request.waitingForRateLimit = outcome == ApolloListOutcomeFailed && listEmpty && ApolloListStateHold(request) > 0;
    return YES;
}

typedef NS_ENUM(NSInteger, ApolloListRetryAction) {
    ApolloListRetryActionNone = 0, // not waiting on a rate limit
    ApolloListRetryActionWait,     // its account's hold is still running
    ApolloListRetryActionLater,    // the hold is over, but the app isn't active
    ApolloListRetryActionReload,
    ApolloListRetryActionDiscard,  // another account is active now
};

// What a pass does with one list, judged by the account that sent its first
// page and that account's own hold. `activeAccount` is the lowercased username
// of the account active now, of either kind (nil when none is signed in). After
// a switch the list's request belongs to an account that's no longer active, so
// it stops waiting rather than reload as someone else.
static ApolloListRetryAction ApolloListRetryActionFor(ApolloListLoadState *state, NSString *activeAccount, BOOL appActive) {
    if (!state.waitingForRateLimit || state.outcome != ApolloListOutcomeFailed) return ApolloListRetryActionNone;
    if (activeAccount.length == 0 || ![state.account isEqualToString:activeAccount]) return ApolloListRetryActionDiscard;
    if (ApolloListStateHold(state) > 0) return ApolloListRetryActionWait;
    return appActive ? ApolloListRetryActionReload : ApolloListRetryActionLater;
}

// Sorts the lists a pass found into `reload` and `discard`, and returns how
// long until the next pass is due: the earliest hold still running among the
// lists that wait, plus the margin. -1 when none waits on a hold.
static NSTimeInterval ApolloListPlanRetry(NSArray<ApolloListLoadState *> *states, NSString *activeAccount, BOOL appActive,
                                          NSMutableArray<ApolloListLoadState *> *reload,
                                          NSMutableArray<ApolloListLoadState *> *discard) {
    NSTimeInterval next = -1;
    for (ApolloListLoadState *state in states) {
        switch (ApolloListRetryActionFor(state, activeAccount, appActive)) {
            case ApolloListRetryActionWait: {
                NSTimeInterval due = ApolloListStateHold(state) + kApolloListRateLimitRetryMargin;
                if (next < 0 || due < next) next = due;
                break;
            }
            case ApolloListRetryActionReload: [reload addObject:state]; break;
            case ApolloListRetryActionDiscard: [discard addObject:state]; break;
            case ApolloListRetryActionLater:
            case ApolloListRetryActionNone: break;
        }
    }
    return next;
}

// End of the rate-limit decisions.

static ApolloListSlot sListSlots[4];
static NSUInteger sListSlotCount;
static Class sEmptySpinnerClass;
static Ivar sAdapterEmptyViewIvar;
// Live controllers that own one of the lists, so a request can be matched to
// the list that made it.
static NSHashTable<UIViewController *> *sListControllers;

static char kApolloListStateKey;
static char kApolloListMessageKey;
static char kApolloListHidSpinnerKey;

// State lives on the ListAdapter, so a screen with two lists (Friends) keeps
// one per list.
static ApolloListLoadState *ApolloListStateFor(id adapter) {
    return adapter ? objc_getAssociatedObject(adapter, &kApolloListStateKey) : nil;
}

// Posts with no posts get Apollo's own label instead (see the header).
static BOOL ApolloListStateShowsMessage(ApolloListLoadState *state) {
    if (state.outcome == ApolloListOutcomeFailed) return YES;
    return state.outcome == ApolloListOutcomeEmpty && state.kind != ApolloListKindPosts;
}

// The adapter of the list whose pagination this is. Compared as raw pointers:
// Posts keeps its pagination in lazy storage whose "not created yet" state is
// the non-pointer value 1, so it can't go through object_getIvar.
static id ApolloListAdapterForPagination(id pagination, ApolloListSlot *outSlot, UIViewController **outController) {
    if (!pagination) return nil;
    for (UIViewController *controller in sListControllers) {
        for (NSUInteger i = 0; i < sListSlotCount; i++) {
            ApolloListSlot slot = sListSlots[i];
            if (![controller isKindOfClass:slot.controllerClass]) continue;
            void *current = *(void **)((uint8_t *)(__bridge void *)controller + ivar_getOffset(slot.paginationIvar));
            if (current != (__bridge void *)pagination) continue;
            if (outSlot) *outSlot = slot;
            if (outController) *outController = controller;
            return object_getIvar(controller, slot.adapterIvar);
        }
    }
    return nil;
}

// The ListAdapter driving the table a view sits in (the table node's data
// source), or nil for any other table.
static id ApolloListAdapterForTableView(UIView *tableView) {
    if (![tableView respondsToSelector:@selector(tableNode)]) return nil;
    id tableNode = ((id (*)(id, SEL))objc_msgSend)(tableView, @selector(tableNode));
    return [tableNode respondsToSelector:@selector(dataSource)] ? ((id (*)(id, SEL))objc_msgSend)(tableNode, @selector(dataSource)) : nil;
}

// The spinner ListAdapter currently has installed as the list's empty view.
static UIView *ApolloListInstalledSpinner(id adapter) {
    id emptyView = adapter ? object_getIvar(adapter, sAdapterEmptyViewIvar) : nil;
    return [emptyView isKindOfClass:sEmptySpinnerClass] ? emptyView : nil;
}

// ListAdapter's tableNode:numberOfRowsInSection: schedules its empty-view pass,
// which removes the old empty view and asks the data source for a new one.
static void ApolloListReevaluateEmptyView(id adapter) {
    UIView *tableView = ApolloListInstalledSpinner(adapter).superview;
    if (![tableView respondsToSelector:@selector(tableNode)]) return;
    id tableNode = ((id (*)(id, SEL))objc_msgSend)(tableView, @selector(tableNode));
    SEL rowsSelector = @selector(tableNode:numberOfRowsInSection:);
    if (![adapter respondsToSelector:rowsSelector]) return;
    ((NSInteger (*)(id, SEL, id, NSInteger))objc_msgSend)(adapter, rowsSelector, tableNode, 0);
}

// Apollo returns before ending a pull to refresh when a first page fails.
static void ApolloListEndRefreshing(id adapter) {
    UIScrollView *tableView = (UIScrollView *)ApolloListInstalledSpinner(adapter).superview;
    if (![tableView isKindOfClass:UIScrollView.class]) return;
    UIRefreshControl *refreshControl = tableView.refreshControl;
    for (UIView *subview in tableView.subviews) {
        if (refreshControl) break;
        if ([subview isKindOfClass:UIRefreshControl.class]) refreshControl = (UIRefreshControl *)subview;
    }
    if (refreshControl.refreshing) [refreshControl endRefreshing];
}

static NSString *ApolloListMessageText(ApolloListLoadState *state) {
    BOOL comments = state.kind == ApolloListKindUserComments || state.kind == ApolloListKindFriendsComments;
    if (state.outcome == ApolloListOutcomeFailed && state.waitingForRateLimit) {
        return comments ? @"Reddit's rate limit was reached.\nComments will load when it resets."
                        : @"Reddit's rate limit was reached.\nPosts will load when it resets.";
    }
    if (state.outcome == ApolloListOutcomeFailed) {
        return comments ? @"Couldn't load comments.\nPull down to try again." : @"Couldn't load posts.\nPull down to try again.";
    }
    if (state.kind == ApolloListKindFriendsPosts) return @"No posts from friends";
    if (state.kind == ApolloListKindFriendsComments) return @"No comments from friends";
    if (state.timeFiltered) return @"No comments in this time range";
    if (state.username.length == 0) return @"No comments to show.\nThis user may keep their comments hidden.";
    // U+2060 WORD JOINER: UILabel otherwise wraps between "u/" and the name.
    return [NSString stringWithFormat:@"No comments to show.\nu/\u2060%@ may keep their comments hidden.", state.username];
}

static void ApolloListRemoveMessage(UIView *spinner) {
    UILabel *message = objc_getAssociatedObject(spinner, &kApolloListMessageKey);
    [message removeFromSuperview];
    objc_setAssociatedObject(spinner, &kApolloListMessageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloListRestoreSpinner(UIView *spinner) {
    ApolloListRemoveMessage(spinner);
    if (![objc_getAssociatedObject(spinner, &kApolloListHidSpinnerKey) boolValue]) return;
    objc_setAssociatedObject(spinner, &kApolloListHidSpinnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    spinner.hidden = NO;
    [(UIActivityIndicatorView *)spinner startAnimating];
}

static void ApolloListShowMessage(UIView *spinner, ApolloListLoadState *state) {
    UIView *host = spinner.superview;
    if (!host) return;
    UILabel *message = objc_getAssociatedObject(spinner, &kApolloListMessageKey);
    if (!message) {
        // Apollo's EmptyStateLabel ("No submitted posts"): 15pt regular, its
        // secondary text color, centered, in the frame ListAdapter gave the
        // spinner (250x200 centered in the table, flexible width and height).
        message = [UILabel new];
        message.numberOfLines = 0;
        message.textAlignment = NSTextAlignmentCenter;
        message.font = ApolloThemeRuntimeFont([UIFont systemFontOfSize:15.0]);
        message.textColor = ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor;
        objc_setAssociatedObject(spinner, &kApolloListMessageKey, message, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    message.text = ApolloListMessageText(state);
    message.frame = spinner.frame;
    message.autoresizingMask = spinner.autoresizingMask;
    if (message.superview != host) [host insertSubview:message aboveSubview:spinner];

    if (!spinner.hidden) {
        objc_setAssociatedObject(spinner, &kApolloListHidSpinnerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        spinner.hidden = YES;
    }
    [(UIActivityIndicatorView *)spinner stopAnimating];
}

static void ApolloListApply(id adapter) {
    UIView *spinner = ApolloListInstalledSpinner(adapter);
    if (!spinner.superview) return;
    ApolloListLoadState *state = ApolloListStateFor(adapter);
    if (ApolloListStateShowsMessage(state)) {
        ApolloListShowMessage(spinner, state);
    } else {
        ApolloListRestoreSpinner(spinner);
    }
}

#pragma mark - Reload once Reddit's rate limit resets

// Wall-clock time (since 1970) the pending pass is due; 0 when none is.
static NSTimeInterval sListRateLimitRetryAt;

static void ApolloListRetryRateLimitedLists(void);

// Schedules a pass `delay` seconds from now unless one is already due no later
// (that pass plans the next one from the holds as they are then), so a long
// hold on one account never postpones another account's reload. Wall-clock
// time, so a device that sleeps through the reset reloads as soon as the app
// runs again. Main thread.
static void ApolloListScheduleRateLimitRetry(NSTimeInterval delay) {
    delay = MAX(delay, 0.0);
    NSTimeInterval at = [[NSDate date] timeIntervalSince1970] + delay;
    if (sListRateLimitRetryAt > 0 && sListRateLimitRetryAt <= at + 1.0) return;
    sListRateLimitRetryAt = at;
    dispatch_after(dispatch_walltime(NULL, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sListRateLimitRetryAt == at) sListRateLimitRetryAt = 0;
        ApolloListRetryRateLimitedLists();
    });
}

// The lowercased username of the account active now, of either kind. Reads
// AccountManager's live selection: on its account-change notification that has
// already moved, while the defaults copy ApolloActiveWebSessionUsername() reads
// is written afterwards.
static NSString *ApolloListActiveAccount(void) {
    NSString *username = nil;
    NSString *persisted = ApolloActiveWebSessionUsername().lowercaseString;
    if (ApolloResolveLiveActiveAccountIdentity(&username) == ApolloPersistedAccountIdentitySignedIn && username.length > 0) {
        if (![username.lowercaseString isEqualToString:persisted ?: @""]) {
            ApolloLog(@"[ListEmptyState] Active account is u/%@ (the saved selection still says u/%@)", username, persisted ?: @"-");
        }
        return username.lowercaseString;
    }
    return persisted;
}

// Runs on each scheduled pass, on UIApplicationDidBecomeActiveNotification and
// after an account switch. Every waiting list is judged by its own account's
// hold (ApolloListPlanRetry): it reloads once that hold has ended and the app
// is active, keeps waiting while it runs, and stops waiting once another
// account is active (it shows "Pull down to try again" instead). Lists off
// screen reload too: each is one request right after a reset, and the
// alternative is the user finding it still failed when they go back to it.
// Main thread.
static void ApolloListRetryRateLimitedLists(void) {
    NSMutableArray<ApolloListLoadState *> *states = [NSMutableArray array];
    for (UIViewController *controller in sListControllers.allObjects) {
        for (NSUInteger i = 0; i < sListSlotCount; i++) {
            ApolloListSlot slot = sListSlots[i];
            if (![controller isKindOfClass:slot.controllerClass]) continue;
            ApolloListLoadState *state = ApolloListStateFor(object_getIvar(controller, slot.adapterIvar));
            if (state.waitingForRateLimit) [states addObject:state];
        }
    }
    if (states.count == 0) return;
    NSString *activeAccount = ApolloListActiveAccount();
    BOOL appActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    NSMutableArray<ApolloListLoadState *> *reload = [NSMutableArray array];
    NSMutableArray<ApolloListLoadState *> *discard = [NSMutableArray array];
    NSTimeInterval next = ApolloListPlanRetry(states, activeAccount, appActive, reload, discard);
    for (ApolloListLoadState *state in discard) {
        state.waitingForRateLimit = NO;
        ApolloLog(@"[ListEmptyState] u/%@ is no longer the active account; its failed list stops waiting for the rate limit",
                  state.account);
        ApolloListApply(state.adapter);
    }
    if (next >= 0) {
        ApolloLog(@"[ListEmptyState] Reddit's rate limit still holds; checking again in %.0fs", next);
        ApolloListScheduleRateLimitRetry(next);
    }
    for (ApolloListLoadState *state in reload) {
        state.waitingForRateLimit = NO;
        id controller = state.controller;
        SEL refresh = state.refreshSelector;
        if (!controller || !refresh || ![controller respondsToSelector:refresh]) continue;
        ApolloLog(@"[ListEmptyState] Reddit's rate limit on u/%@ has reset; reloading %@ (%@)", state.account,
                  NSStringFromClass([controller class]), NSStringFromSelector(refresh));
        ((void (*)(id, SEL, id))objc_msgSend)(controller, refresh, nil);
    }
}

// After Apollo has handled the first page `request` stands for. `owns` is NO
// when a newer first page replaced the list's state while this one was in
// flight: that page's own completion settles the list, so this one changes
// nothing (Apollo still got the page).
static void ApolloListFinishFirstPage(id adapter, ApolloListLoadState *request, BOOL owns, NSString *path,
                                      ApolloListOutcome outcome, NSError *error) {
    if (!owns) {
        ApolloLog(@"[ListEmptyState] First page of %@ finished after a newer one started; leaving the list to the newer one", path);
        return;
    }
    ApolloListLoadState *state = request;
    if (!state || outcome == ApolloListOutcomeNone) return;
    NSTimeInterval hold = ApolloListStateHold(state);
    ApolloLog(@"[ListEmptyState] First page of %@ %@; %@%@", path,
              outcome == ApolloListOutcomeFailed ? [NSString stringWithFormat:@"failed (%@ %ld)", error.domain, (long)error.code] : @"was empty",
              ApolloListStateShowsMessage(state) ? @"showing a message instead of the loading spinner"
                                                 : @"asking the list for Apollo's empty state",
              state.waitingForRateLimit ? [NSString stringWithFormat:@"; reloading when Reddit's rate limit on u/%@ resets in %.0fs",
                                                                     state.account, hold] : @"");
    if (state.waitingForRateLimit) ApolloListScheduleRateLimitRetry(hold + kApolloListRateLimitRetryMargin);
    if (outcome == ApolloListOutcomeFailed) ApolloListEndRefreshing(adapter);
    ApolloListApply(adapter);
    // Posts: let Apollo pick its own empty state ("No submitted posts", a
    // subreddit's issue). A failure it has nothing for comes back as a
    // spinner, which the spinner hook replaces again.
    if (state.kind == ApolloListKindPosts) ApolloListReevaluateEmptyView(adapter);
}

// The API-Key-Free account sending a first page, lowercased, or nil for an
// API-key account: the requesting client's own user, or the active account
// when RedditKit hasn't set that user yet (early in launch).
static NSString *ApolloListRequestAccount(id client) {
    id user = [client respondsToSelector:@selector(currentUser)] ? ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser)) : nil;
    NSString *username = [user respondsToSelector:@selector(username)] ? ((id (*)(id, SEL))objc_msgSend)(user, @selector(username)) : nil;
    if (![username isKindOfClass:NSString.class] || username.length == 0) username = ApolloListActiveAccount();
    return username.length > 0 && ApolloWebSessionFor(username) ? username.lowercaseString : nil;
}

// "user/<name>/comments.json" -> "<name>".
static NSString *ApolloUsernameFromListingPath(NSString *path) {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSUInteger index = [parts indexOfObject:@"user"];
    return index != NSNotFound && index + 1 < parts.count ? parts[index + 1] : nil;
}

static void ApolloListRegisterController(UIViewController *controller) {
    [sListControllers addObject:controller];
}

@interface ApolloCommentsListController : UIViewController
@end

@interface ApolloPostsListController : UIViewController
@end

@interface ApolloFriendsListController : UIViewController
@end

@interface ApolloListEmptySpinner : UIActivityIndicatorView
@end

%group ApolloListEmptyStateHooks

// Register before Apollo's viewDidLoad: that's where the first page is requested.
%hook ApolloCommentsListController
- (void)viewDidLoad {
    ApolloListRegisterController(self);
    %orig;
}
%end

%hook ApolloPostsListController
- (void)viewDidLoad {
    ApolloListRegisterController(self);
    %orig;
}
%end

%hook ApolloFriendsListController
- (void)viewDidLoad {
    ApolloListRegisterController(self);
    %orig;
}
%end

%hook RDKClient

- (id)listingTaskWithPath:(NSString *)path parameters:(id)parameters pagination:(RDKPagination *)pagination completion:(ApolloListPageCompletion)completion {
    // First pages start on main (load, refresh, sort); later pages can start
    // on ASDK's batch-fetch queue and only ever append.
    if (!completion || ![NSThread isMainThread] || !pagination || pagination.after.length > 0) return %orig;
    ApolloListSlot slot;
    UIViewController *controller = nil;
    id adapter = ApolloListAdapterForPagination(pagination, &slot, &controller);
    if (!adapter) return %orig;
    ApolloListKind kind = slot.kind;

    ApolloListLoadState *state = [ApolloListLoadState new];
    state.kind = kind;
    state.account = ApolloListRequestAccount(self);
    state.adapter = adapter;
    state.controller = controller;
    state.refreshSelector = slot.refreshSelector;
    if (kind == ApolloListKindUserComments) {
        state.username = ApolloUsernameFromListingPath(path);
        NSString *time = [pagination respondsToSelector:@selector(dictionaryValue)] ? [pagination dictionaryValue][@"t"] : nil;
        state.timeFiltered = [time isKindOfClass:NSString.class] && time.length > 0 && ![time isEqualToString:@"all"];
    }
    objc_setAssociatedObject(adapter, &kApolloListStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloListApply(adapter);

    // The completion keeps this request's own state: if a newer first page
    // replaces it before this one finishes, this one only hands Apollo its page.
    __weak id weakAdapter = adapter;
    ApolloListLoadState *requestState = state;
    ApolloListPageCompletion wrapped = ^(NSArray *items, RDKPagination *nextPagination, NSError *error) {
        ApolloListOutcome outcome = ApolloListOutcomeNone;
        if (!items || error) {
            outcome = ApolloListOutcomeFailed;
        } else if (items.count == 0 && !nextPagination) {
            outcome = ApolloListOutcomeEmpty;
        }
        if (![NSThread isMainThread]) {
            // RedditKit delivers listings on main; if that ever changes, keep
            // this bookkeeping and the UIKit work it leads to on main anyway.
            completion(items, nextPagination, error);
            dispatch_async(dispatch_get_main_queue(), ^{
                id strongAdapter = weakAdapter;
                BOOL owns = ApolloListRecordOutcome(ApolloListStateFor(strongAdapter), requestState, outcome,
                                                    ApolloListInstalledSpinner(strongAdapter) != nil);
                ApolloListFinishFirstPage(strongAdapter, requestState, owns, path, outcome, error);
            });
            return;
        }
        // Record the outcome before Apollo handles the page: ListAdapter can
        // re-install its spinner synchronously inside that call.
        id strongAdapter = weakAdapter;
        BOOL owns = ApolloListRecordOutcome(ApolloListStateFor(strongAdapter), requestState, outcome,
                                            ApolloListInstalledSpinner(strongAdapter) != nil);
        completion(items, nextPagination, error);
        ApolloListFinishFirstPage(strongAdapter, requestState, owns, path, outcome, error);
    };
    return %orig(path, parameters, pagination, wrapped);
}

%end

%hook ApolloListEmptySpinner

- (void)didMoveToSuperview {
    %orig;
    UIView *spinner = (UIView *)self;
    if (!spinner.superview) {
        // ListAdapter removes its empty view before every update.
        ApolloListRemoveMessage(spinner);
        return;
    }
    if (sListControllers.count == 0 || ![spinner.superview isKindOfClass:UITableView.class]) return;
    id adapter = ApolloListAdapterForTableView(spinner.superview);
    if (!ApolloListStateShowsMessage(ApolloListStateFor(adapter))) return;
    // ListAdapter frames the view and stores it as its emptyView right after
    // inserting it; act once it has.
    __weak id weakAdapter = adapter;
    __weak UIView *weakSpinner = spinner;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongAdapter = weakAdapter;
        UIView *strongSpinner = weakSpinner;
        if (!strongAdapter || !strongSpinner.superview) return;
        if (ApolloListInstalledSpinner(strongAdapter) != strongSpinner) return;
        ApolloListApply(strongAdapter);
    });
}

%end

%end

// `refreshName` is the list's pull to refresh action; a binary without it
// keeps the empty states, just not the reload after a rate limit.
static BOOL ApolloListAddSlot(Class controllerClass, const char *adapterName, const char *paginationName, ApolloListKind kind,
                              const char *refreshName) {
    Ivar adapterIvar = class_getInstanceVariable(controllerClass, adapterName);
    Ivar paginationIvar = class_getInstanceVariable(controllerClass, paginationName);
    if (!adapterIvar || !paginationIvar || sListSlotCount >= sizeof(sListSlots) / sizeof(sListSlots[0])) return NO;
    ApolloListSlot slot;
    slot.controllerClass = controllerClass;
    slot.adapterIvar = adapterIvar;
    slot.paginationIvar = paginationIvar;
    slot.kind = kind;
    SEL refresh = sel_registerName(refreshName);
    slot.refreshSelector = class_getInstanceMethod(controllerClass, refresh) ? refresh : NULL;
    if (!slot.refreshSelector) ApolloLog(@"[ListEmptyState] %s has no -%s; its list won't reload after a rate limit", class_getName(controllerClass), refreshName);
    sListSlots[sListSlotCount++] = slot;
    return YES;
}

%ctor {
    Class commentsClass = objc_getClass("_TtC6Apollo26UserCommentsViewController");
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    Class friendsClass = objc_getClass("_TtC6Apollo21FriendsViewController");
    Class spinnerClass = objc_getClass("_TtC6Apollo17AutoThemedSpinner");
    Class adapterClass = objc_getClass("_TtC6Apollo11ListAdapter");
    Class clientClass = objc_getClass("RDKClient");
    sAdapterEmptyViewIvar = adapterClass ? class_getInstanceVariable(adapterClass, "emptyView") : NULL;
    if (!commentsClass || !postsClass || !friendsClass || !spinnerClass || !sAdapterEmptyViewIvar ||
        !class_getInstanceMethod(clientClass, @selector(listingTaskWithPath:parameters:pagination:completion:)) ||
        !ApolloListAddSlot(commentsClass, "listAdapter", "currentPagination", ApolloListKindUserComments,
                           "refreshControlActivatedWithSender:") ||
        !ApolloListAddSlot(postsClass, "listAdapter", "$__lazy_storage_$_pagination", ApolloListKindPosts,
                           "refreshControlActivatedWithSender:") ||
        !ApolloListAddSlot(friendsClass, "friendsLinksListAdapter", "friendsLinksPagination", ApolloListKindFriendsPosts,
                           "friendsLinksRefreshControlActivatedWithSender:") ||
        !ApolloListAddSlot(friendsClass, "friendsCommentsListAdapter", "friendsCommentsPagination", ApolloListKindFriendsComments,
                           "friendsCommentsRefreshControlActivatedWithSender:")) {
        ApolloLog(@"[ListEmptyState] Apollo's list screens changed shape; empty states not installed");
        return;
    }
    sEmptySpinnerClass = spinnerClass;
    sListControllers = [NSHashTable weakObjectsHashTable];
    %init(ApolloListEmptyStateHooks, ApolloCommentsListController = commentsClass,
          ApolloPostsListController = postsClass, ApolloFriendsListController = friendsClass,
          ApolloListEmptySpinner = spinnerClass);
    // A reset that came while the app was in the background reloads the
    // waiting lists when it comes back (see ApolloListRetryRateLimitedLists).
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloListRetryRateLimitedLists();
    }];
    // After an account switch, lists still waiting on the previous account's
    // limit stop waiting right away. Apollo posts these while it switches, so
    // the pass runs once it has.
    for (NSString *name in @[ @"com.christianselig.RedditCurrentAccountChanged", @"com.christianselig.RedditAccountChanged" ]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ ApolloListRetryRateLimitedLists(); });
        }];
    }
    ApolloLog(@"[ListEmptyState] Comments, Posts and Friends empty state hooks installed (reload after a rate limit)");
}
