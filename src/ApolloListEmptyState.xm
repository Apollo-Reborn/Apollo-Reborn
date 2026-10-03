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

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

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
// object the controller passes to RedditKit for it, and what it lists.
typedef struct {
    Class controllerClass;
    Ivar adapterIvar;
    Ivar paginationIvar;
    ApolloListKind kind;
} ApolloListSlot;

@interface ApolloListLoadState : NSObject
@property (nonatomic) ApolloListKind kind;
@property (nonatomic) ApolloListOutcome outcome;
@property (nonatomic, copy) NSString *username;
@property (nonatomic) BOOL timeFiltered;
@end

@implementation ApolloListLoadState
@end

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
static id ApolloListAdapterForPagination(id pagination, ApolloListKind *kind) {
    if (!pagination) return nil;
    for (UIViewController *controller in sListControllers) {
        for (NSUInteger i = 0; i < sListSlotCount; i++) {
            ApolloListSlot slot = sListSlots[i];
            if (![controller isKindOfClass:slot.controllerClass]) continue;
            void *current = *(void **)((uint8_t *)(__bridge void *)controller + ivar_getOffset(slot.paginationIvar));
            if (current != (__bridge void *)pagination) continue;
            if (kind) *kind = slot.kind;
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

// After Apollo has handled a first page that ended `outcome`. Apollo shows
// whichever page arrives last, so the outcome goes on the list's current
// state even if a newer first page has started since this one.
static void ApolloListFinishFirstPage(id adapter, NSString *path, ApolloListOutcome outcome, NSError *error) {
    ApolloListLoadState *state = ApolloListStateFor(adapter);
    if (!state || outcome == ApolloListOutcomeNone) return;
    ApolloLog(@"[ListEmptyState] First page of %@ %@; %@", path,
              outcome == ApolloListOutcomeFailed ? [NSString stringWithFormat:@"failed (%@ %ld)", error.domain, (long)error.code] : @"was empty",
              ApolloListStateShowsMessage(state) ? @"showing a message instead of the loading spinner"
                                                 : @"asking the list for Apollo's empty state");
    if (outcome == ApolloListOutcomeFailed) ApolloListEndRefreshing(adapter);
    ApolloListApply(adapter);
    // Posts: let Apollo pick its own empty state ("No submitted posts", a
    // subreddit's issue). A failure it has nothing for comes back as a
    // spinner, which the spinner hook replaces again.
    if (state.kind == ApolloListKindPosts) ApolloListReevaluateEmptyView(adapter);
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
    ApolloListKind kind = ApolloListKindPosts;
    id adapter = ApolloListAdapterForPagination(pagination, &kind);
    if (!adapter) return %orig;

    ApolloListLoadState *state = [ApolloListLoadState new];
    state.kind = kind;
    if (kind == ApolloListKindUserComments) {
        state.username = ApolloUsernameFromListingPath(path);
        NSString *time = [pagination respondsToSelector:@selector(dictionaryValue)] ? [pagination dictionaryValue][@"t"] : nil;
        state.timeFiltered = [time isKindOfClass:NSString.class] && time.length > 0 && ![time isEqualToString:@"all"];
    }
    objc_setAssociatedObject(adapter, &kApolloListStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloListApply(adapter);

    __weak id weakAdapter = adapter;
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
                ApolloListStateFor(strongAdapter).outcome = outcome;
                ApolloListFinishFirstPage(strongAdapter, path, outcome, error);
            });
            return;
        }
        // Record the outcome before Apollo handles the page: ListAdapter can
        // re-install its spinner synchronously inside that call.
        id strongAdapter = weakAdapter;
        ApolloListStateFor(strongAdapter).outcome = outcome;
        completion(items, nextPagination, error);
        ApolloListFinishFirstPage(strongAdapter, path, outcome, error);
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

static BOOL ApolloListAddSlot(Class controllerClass, const char *adapterName, const char *paginationName, ApolloListKind kind) {
    Ivar adapterIvar = class_getInstanceVariable(controllerClass, adapterName);
    Ivar paginationIvar = class_getInstanceVariable(controllerClass, paginationName);
    if (!adapterIvar || !paginationIvar || sListSlotCount >= sizeof(sListSlots) / sizeof(sListSlots[0])) return NO;
    ApolloListSlot slot;
    slot.controllerClass = controllerClass;
    slot.adapterIvar = adapterIvar;
    slot.paginationIvar = paginationIvar;
    slot.kind = kind;
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
        !ApolloListAddSlot(commentsClass, "listAdapter", "currentPagination", ApolloListKindUserComments) ||
        !ApolloListAddSlot(postsClass, "listAdapter", "$__lazy_storage_$_pagination", ApolloListKindPosts) ||
        !ApolloListAddSlot(friendsClass, "friendsLinksListAdapter", "friendsLinksPagination", ApolloListKindFriendsPosts) ||
        !ApolloListAddSlot(friendsClass, "friendsCommentsListAdapter", "friendsCommentsPagination", ApolloListKindFriendsComments)) {
        ApolloLog(@"[ListEmptyState] Apollo's list screens changed shape; empty states not installed");
        return;
    }
    sEmptySpinnerClass = spinnerClass;
    sListControllers = [NSHashTable weakObjectsHashTable];
    %init(ApolloListEmptyStateHooks, ApolloCommentsListController = commentsClass,
          ApolloPostsListController = postsClass, ApolloFriendsListController = friendsClass,
          ApolloListEmptySpinner = spinnerClass);
    ApolloLog(@"[ListEmptyState] Comments, Posts and Friends empty state hooks installed");
}
