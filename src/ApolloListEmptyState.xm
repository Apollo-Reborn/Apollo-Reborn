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
// in the foreground after that. Each list waits on its own request's account,
// and switching to another account ends the wait. Like the outcome, the wait
// follows whichever first page Apollo shows: the one that arrives last.
//
// Content warning (a "gated" subreddit, see ApolloGatedSubreddit.h): Reddit
// answers every read of some communities (r/Drugs) with HTTP 403 and a warning
// until the account has accepted it once. RedditKit has no error for that
// reason, so the feed was a failed load like any other, and pulling down
// failed again for as long as the account hadn't accepted the warning
// somewhere else. A subreddit's first page that fails this way says so
// instead, with a button that shows Reddit's warning. "Continue" there sends
// what Reddit's own warning page sends, with the web session of the account
// that asked, and reloads the list; an account with no web session stored is
// sent to Reddit to accept it there. Nothing is sent before that tap.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import "ApolloAccountCredentials.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloClasses.h"
#import "ApolloGatedSubreddit.h"
#import "ApolloState.h"

extern "C" void ApolloSwiftAssignOptionalString(void *storage, const char *utf8Value);
extern "C" void ApolloSwiftAssignString(void *storage, const char *utf8Value);

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
// The account that sent this first page, of either kind, lowercased.
@property (nonatomic, copy) NSString *requestUsername;
// The first page failed because Reddit holds `gateSubreddit` behind a warning
// this account hasn't accepted: the warning's text. nil for any other outcome.
@property (nonatomic, copy) NSString *gateWarning;
@property (nonatomic, copy) NSString *gateSubreddit;
// The warning came back right after this account accepted it from here.
@property (nonatomic) BOOL gateStillShown;
// The accepting request is on its way; the list shows its spinner meanwhile.
@property (nonatomic) BOOL gateAccepting;
// It couldn't be sent: what to say in place of the usual line.
@property (nonatomic, copy) NSString *gateFailure;
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

// Records how a first page of the list whose state this is ended. Apollo shows
// whichever first page arrives last, so its outcome goes on the list's current
// state even if a newer first page has started since, and the wait follows it:
// a late page that brought posts clears it, a late failure on an empty list
// sets it. A first page that failed while Reddit held the list's account, on a
// list with nothing in it yet, waits for the hold to end; a list that still
// shows posts keeps them and isn't reloaded under the reader.
static void ApolloListRecordOutcome(ApolloListLoadState *state, ApolloListOutcome outcome, BOOL listEmpty) {
    if (!state) return;
    state.outcome = outcome;
    state.waitingForRateLimit = outcome == ApolloListOutcomeFailed && listEmpty && ApolloListStateHold(state) > 0;
}

// Records whether the first page whose outcome was just recorded on `state`
// failed on Reddit's warning for one subreddit. `warning` is the text from the
// failure (nil for any other failure), `subreddit` the one subreddit the page
// was for (nil for Home, a "+" list, a profile). `acceptedSubreddit` is the
// subreddit this account accepted the warning for from this list just before
// the page was asked for, if it did: the same warning again means Reddit
// didn't take it. A gated page doesn't wait on a rate limit: only accepting
// the warning changes its answer.
static void ApolloListRecordGate(ApolloListLoadState *state, NSString *warning, NSString *subreddit, NSString *acceptedSubreddit) {
    if (!state) return;
    BOOL gated = state.outcome == ApolloListOutcomeFailed && state.kind == ApolloListKindPosts && warning.length > 0 && subreddit.length > 0;
    state.gateWarning = gated ? warning : nil;
    state.gateSubreddit = gated ? subreddit : nil;
    state.gateStillShown = gated && acceptedSubreddit.length > 0 && [acceptedSubreddit caseInsensitiveCompare:subreddit] == NSOrderedSame;
    state.gateAccepting = NO;
    state.gateFailure = nil;
    if (gated) state.waitingForRateLimit = NO;
}

// The line a gated list shows above its button.
static NSString *ApolloListGateText(ApolloListLoadState *state) {
    if (state.gateFailure.length > 0) return state.gateFailure;
    if (state.gateStillShown) return @"Reddit still shows its content warning for this community.";
    return @"Reddit shows a content warning before this community.";
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

// Defined below this block (the tests define their own): wall-clock time now,
// a wall-clock dispatch_after on main, and the pass itself.
static NSTimeInterval ApolloListWallClockNow(void);
static void ApolloListAfterWallClock(NSTimeInterval delay, dispatch_block_t block);
static void ApolloListRetryRateLimitedLists(void);

// Wall-clock time the earliest pending pass is due; 0 when none is.
static NSTimeInterval sListRateLimitRetryAt;

// Schedules a pass `delay` seconds from now unless one is already due no later
// (that pass plans the next one from the holds as they are then). A list that
// starts waiting on a shorter hold, such as another account's after a switch,
// moves the next pass earlier instead of waiting behind a longer one. A pass
// that fires after an earlier one has run finds nothing left or plans again.
// Wall-clock time, so a device that sleeps through the reset reloads as soon
// as the app runs again. Main thread.
static void ApolloListScheduleRateLimitRetry(NSTimeInterval delay) {
    delay = MAX(delay, 0.0);
    NSTimeInterval at = ApolloListWallClockNow() + delay;
    if (sListRateLimitRetryAt > 0 && sListRateLimitRetryAt <= at + 1.0) return;
    sListRateLimitRetryAt = at;
    ApolloListAfterWallClock(delay, ^{
        if (sListRateLimitRetryAt == at) sListRateLimitRetryAt = 0;
        ApolloListRetryRateLimitedLists();
    });
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
// On the spinner: the gated list's line and button (a UIView).
static char kApolloListGateViewKey;
// On the controller: the subreddit this list just accepted Reddit's warning
// for (NSString), until its next first page ends.
static char kApolloListGateAcceptedKey;

// State lives on the ListAdapter, so a screen with two lists (Friends) keeps
// one per list.
static ApolloListLoadState *ApolloListStateFor(id adapter) {
    return adapter ? objc_getAssociatedObject(adapter, &kApolloListStateKey) : nil;
}

// Posts with no posts get Apollo's own label instead (see the header).
static BOOL ApolloListStateShowsMessage(ApolloListLoadState *state) {
    // While Reddit's warning is being accepted the spinner is the right thing.
    if (state.gateAccepting) return NO;
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

static void ApolloListRemoveGateView(UIView *spinner) {
    UIView *gate = objc_getAssociatedObject(spinner, &kApolloListGateViewKey);
    if (!gate) return;
    [gate removeFromSuperview];
    objc_setAssociatedObject(spinner, &kApolloListGateViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloListRemoveMessage(UIView *spinner) {
    UILabel *message = objc_getAssociatedObject(spinner, &kApolloListMessageKey);
    [message removeFromSuperview];
    objc_setAssociatedObject(spinner, &kApolloListMessageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloListRemoveGateView(spinner);
}

static void ApolloListRestoreSpinner(UIView *spinner) {
    ApolloListRemoveMessage(spinner);
    if (![objc_getAssociatedObject(spinner, &kApolloListHidSpinnerKey) boolValue]) return;
    objc_setAssociatedObject(spinner, &kApolloListHidSpinnerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    spinner.hidden = NO;
    [(UIActivityIndicatorView *)spinner startAnimating];
}

static void ApolloListPresentGateWarning(id adapter);

// Holds a gated list's line and button in the table. It takes touches for the
// button and nothing else: the frame it is given is the spinner's, which can be
// shorter than the two together (the button then hangs below it) and can lie
// over the subreddit's header, whose own button has to stay tappable, and a
// pull on the line has to reach the table.
@interface ApolloListGateView : UIView
@end

@implementation ApolloListGateView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:UIControl.class] && !subview.hidden && CGRectContainsPoint(subview.frame, point)) return YES;
    }
    return NO;
}

@end

// A gated list: the line that says so and a button that shows Reddit's
// warning, in the frame ListAdapter gave the spinner.
static void ApolloListShowGate(UIView *spinner, ApolloListLoadState *state) {
    UIView *host = spinner.superview;
    UILabel *plain = objc_getAssociatedObject(spinner, &kApolloListMessageKey);
    [plain removeFromSuperview];
    objc_setAssociatedObject(spinner, &kApolloListMessageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *gate = objc_getAssociatedObject(spinner, &kApolloListGateViewKey);
    UILabel *label = nil;
    if (!gate) {
        gate = [ApolloListGateView new];
        label = [UILabel new];
        label.tag = 1;
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = ApolloThemeRuntimeFont([UIFont systemFontOfSize:15.0]);
        label.textColor = ApolloThemeSubredditListSecondaryTextColor() ?: UIColor.secondaryLabelColor;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:@"View Warning" forState:UIControlStateNormal];
        button.titleLabel.font = ApolloThemeRuntimeFont([UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]);
        // A title alone is an 18-point-high target. The insets make it 44
        // (UIButtonConfiguration, their replacement, needs iOS 15).
        button.contentEdgeInsets = UIEdgeInsetsMake(13.0, 24.0, 13.0, 24.0);
        // The accent resolves against the table the button sits in (a
        // dynamic provider color; see AGENTS.md).
        button.tintColor = ApolloThemeAccentColor() ?: host.tintColor;
        // The state is looked up at the tap: the list may have a newer one.
        id adapter = state.adapter;
        __weak id weakAdapter = adapter;
        [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            ApolloListPresentGateWarning(weakAdapter);
        }] forControlEvents:UIControlEventTouchUpInside];
        // The line sits where the plain message does, centered in the frame,
        // and the button hangs under it. Centering the two together would
        // lift the line, and under a tall subreddit header on a short screen
        // (the Duo's cover) the frame's upper part is the header's.
        label.translatesAutoresizingMaskIntoConstraints = NO;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [gate addSubview:label];
        [gate addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [label.centerXAnchor constraintEqualToAnchor:gate.centerXAnchor],
            [label.centerYAnchor constraintEqualToAnchor:gate.centerYAnchor],
            [label.widthAnchor constraintLessThanOrEqualToAnchor:gate.widthAnchor],
            [button.centerXAnchor constraintEqualToAnchor:gate.centerXAnchor],
            // The title sits 6 points under the line; the button's top inset
            // reaches up over the gap.
            [button.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:-7.0],
        ]];
        objc_setAssociatedObject(spinner, &kApolloListGateViewKey, gate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        label = [gate viewWithTag:1];
    }
    label.text = ApolloListGateText(state);
    gate.frame = spinner.frame;
    gate.autoresizingMask = spinner.autoresizingMask;
    if (gate.superview != host) [host insertSubview:gate aboveSubview:spinner];

    if (!spinner.hidden) {
        objc_setAssociatedObject(spinner, &kApolloListHidSpinnerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        spinner.hidden = YES;
    }
    [(UIActivityIndicatorView *)spinner stopAnimating];
}

static void ApolloListShowMessage(UIView *spinner, ApolloListLoadState *state) {
    UIView *host = spinner.superview;
    if (!host) return;
    if (state.gateWarning.length > 0) {
        ApolloListShowGate(spinner, state);
        return;
    }
    ApolloListRemoveGateView(spinner);
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

#pragma mark - Reddit's content warning

// Reddit answers the warning form with a redirect to the subreddit's own web
// page. That page is of no use here (the list asks for the subreddit itself
// next), so the redirect stops at its answer.
@interface ApolloGatedNoRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation ApolloGatedNoRedirectDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
        completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

// `base` as one of the account's own web requests. The probe mark keeps the
// transport hooks off a request that carries its own cookie; it never reaches
// the wire.
static NSMutableURLRequest *ApolloGatedSessionRequest(NSURLRequest *base, ApolloWebSessionEntry *session) {
    NSMutableURLRequest *request = [base mutableCopy];
    request.URL = ApolloWebJSONProbeURL(base.URL);
    request.HTTPShouldHandleCookies = NO;
    request.timeoutInterval = 20.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [request setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"Apollo iOS") forHTTPHeaderField:@"User-Agent"];
    return request;
}

// Sends what "continue" on Reddit's warning page for `subreddit` sends, as
// `username`: the page first, for the form it carries, then that form
// (ApolloGatedAcceptRequest). `completion` runs on main with whether the list
// should reload: Reddit answered the form with anything but an error, or its
// page had no warning form to send (the account has accepted it since, from
// another list or another device; nothing is posted then). Whether the
// subreddit is open to the account now is for that reload to find out. NO when
// Reddit couldn't be reached or refused the form. Only ever called from the
// warning's "Continue".
static void ApolloGatedSendAccept(NSString *username, NSString *subreddit, void (^completion)(BOOL reload)) {
    ApolloWebSessionEntry *session = ApolloWebSessionPollFor(username);
    NSURL *pageURL = ApolloGatedPageURL(subreddit);
    if (session.cookieHeader.length == 0 || !pageURL) {
        ApolloLog(@"[GatedSubreddit] Nothing sent for r/%@: u/%@ has no web session stored", subreddit, username);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPCookieStorage = nil;
    NSURLSession *urlSession = [NSURLSession sessionWithConfiguration:configuration
                                                             delegate:[ApolloGatedNoRedirectDelegate new] delegateQueue:nil];
    void (^finish)(BOOL, NSString *) = ^(BOOL reload, NSString *detail) {
        // The session holds its delegate until it is invalidated.
        [urlSession finishTasksAndInvalidate];
        ApolloLog(@"[GatedSubreddit] Accepting Reddit's warning for r/%@ as u/%@: %@", subreddit, username, detail);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(reload); });
    };
    NSURLRequest *page = ApolloGatedSessionRequest([NSURLRequest requestWithURL:pageURL], session);
    [[urlSession dataTaskWithRequest:page completionHandler:^(NSData *pageData, NSURLResponse *pageResponse, NSError *pageError) {
        NSInteger pageStatus = [pageResponse isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)pageResponse).statusCode : -1;
        if (pageError || pageStatus < 0) {
            finish(NO, [NSString stringWithFormat:@"Reddit's warning page didn't load (%@ %ld)", pageError.domain ?: @"no response", (long)pageError.code]);
            return;
        }
        NSURLRequest *form = ApolloGatedAcceptRequest(pageData, pageURL, subreddit);
        if (!form) {
            finish(YES, [NSString stringWithFormat:@"Reddit's page had no warning form to send (HTTP %ld, %lu bytes); reloading the list",
                         (long)pageStatus, (unsigned long)pageData.length]);
            return;
        }
        NSMutableURLRequest *accept = ApolloGatedSessionRequest(form, session);
        [accept setValue:@"https://old.reddit.com" forHTTPHeaderField:@"Origin"];
        [accept setValue:pageURL.absoluteString forHTTPHeaderField:@"Referer"];
        [[urlSession dataTaskWithRequest:accept completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : -1;
            BOOL taken = !error && status >= 200 && status < 400;
            finish(taken, [NSString stringWithFormat:@"the form answered HTTP %ld%@", (long)status,
                           error ? [NSString stringWithFormat:@" (%@ %ld)", error.domain, (long)error.code] : @""]);
        }] resume];
    }] resume];
}

// "Continue" on the warning: the list shows its spinner while the form goes
// out, then reloads through its own pull to refresh action.
static void ApolloListAcceptGate(id adapter, ApolloListLoadState *state) {
    NSString *username = state.requestUsername, *subreddit = state.gateSubreddit;
    if (!adapter || username.length == 0 || subreddit.length == 0 || state.gateAccepting) return;
    state.gateAccepting = YES;
    state.gateFailure = nil;
    ApolloListApply(adapter);
    __weak id weakAdapter = adapter;
    ApolloGatedSendAccept(username, subreddit, ^(BOOL reload) {
        id strongAdapter = weakAdapter;
        // A first page asked for since (a pull to refresh, an account switch)
        // has a state of its own, and this answer isn't about it.
        if (!strongAdapter || ApolloListStateFor(strongAdapter) != state) return;
        state.gateAccepting = NO;
        UIViewController *controller = state.controller;
        SEL refresh = state.refreshSelector;
        if (!reload) {
            state.gateFailure = @"Couldn't reach Reddit to accept its content warning.";
            ApolloListApply(strongAdapter);
            return;
        }
        if (!controller || !refresh || ![controller respondsToSelector:refresh]) {
            state.gateFailure = @"Pull down to load this community.";
            ApolloListApply(strongAdapter);
            return;
        }
        // If the next first page is gated all the same, it says so.
        objc_setAssociatedObject(controller, &kApolloListGateAcceptedKey, subreddit, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ((void (*)(id, SEL, id))objc_msgSend)(controller, refresh, nil);
    });
}

#if APOLLO_SIM_BUILD
// Sim debug bridge ("gatedsession off|on"): show the warning as an account
// with no web session stored gets it, without removing anyone's session.
static BOOL sApolloGatedSimNoSession;
extern "C" void ApolloGatedSubredditSimSetNoSession(BOOL noSession) {
    sApolloGatedSimNoSession = noSession;
    ApolloLog(@"[GatedSubreddit] Sim: warnings are shown %@", noSession ? @"as for an account with no web session" : @"normally");
}
#endif

// The gated list's button: Reddit's own words for the subreddit, and the
// choice. Accepting takes the web session of the account that asked for the
// list, which an API-Key-Free account always has and an API-key account
// usually does (the one kept for polls and chat). Without one there's nothing
// to send the form with, so the warning points at Reddit instead.
static void ApolloListPresentGateWarning(id adapter) {
    ApolloListLoadState *state = ApolloListStateFor(adapter);
    if (state.gateWarning.length == 0 || state.gateSubreddit.length == 0 || state.gateAccepting) return;
    UIViewController *controller = state.controller;
    if (!controller.viewIfLoaded.window || controller.presentedViewController) return;
    NSString *subreddit = state.gateSubreddit;
    BOOL canAccept = state.requestUsername.length > 0 && ApolloWebSessionPollFor(state.requestUsername).cookieHeader.length > 0;
#if APOLLO_SIM_BUILD
    if (sApolloGatedSimNoSession) canAccept = NO;
#endif
    NSString *message = canAccept ? state.gateWarning
                                  : [state.gateWarning stringByAppendingString:@"\n\nAccept this on Reddit, then pull down here to reload."];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[@"r/" stringByAppendingString:subreddit]
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now" style:UIAlertActionStyleCancel handler:nil]];
    __weak id weakAdapter = adapter;
    UIAlertAction *proceed = nil;
    if (canAccept) {
        proceed = [UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            id strongAdapter = weakAdapter;
            // Still the first page the warning was shown for.
            if (strongAdapter && ApolloListStateFor(strongAdapter) == state) ApolloListAcceptGate(strongAdapter, state);
        }];
    } else {
        proceed = [UIAlertAction actionWithTitle:@"Open Reddit" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.reddit.com/r/%@/", subreddit]];
            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }];
    }
    [alert addAction:proceed];
    alert.preferredAction = proceed;
    ApolloLog(@"[GatedSubreddit] Showing Reddit's warning for r/%@ (%@)", subreddit,
              canAccept ? @"Continue accepts it here" : @"no web session for the account, Open Reddit");
    [controller presentViewController:alert animated:YES completion:nil];
}

// After the outcome of a first page is on the list's state: whether it failed
// on Reddit's warning (the failure's NSError carries it, see the RDKClient
// class-method hook below).
static void ApolloListNoteGate(id adapter, UIViewController *controller, NSString *path, NSError *error) {
    ApolloListLoadState *state = ApolloListStateFor(adapter);
    id carried = error.userInfo[ApolloGatedSubredditWarningKey];
    NSString *warning = [carried isKindOfClass:NSString.class] ? carried : nil;
    NSString *accepted = controller ? objc_getAssociatedObject(controller, &kApolloListGateAcceptedKey) : nil;
    if (accepted) objc_setAssociatedObject(controller, &kApolloListGateAcceptedKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloListRecordGate(state, warning, warning ? ApolloGatedSubredditFromListingPath(path) : nil, accepted);
    if (state.gateWarning.length > 0) {
        ApolloLog(@"[GatedSubreddit] r/%@ is behind Reddit's content warning for u/%@%@", state.gateSubreddit,
                  state.requestUsername ?: @"-", state.gateStillShown ? @" (again, right after accepting it)" : @"");
    }
}

#pragma mark - Reload once Reddit's rate limit resets

static NSTimeInterval ApolloListWallClockNow(void) {
    return [[NSDate date] timeIntervalSince1970];
}

static void ApolloListAfterWallClock(NSTimeInterval delay, dispatch_block_t block) {
    dispatch_after(dispatch_walltime(NULL, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
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
        // Nothing reloads under the reader: a list that has posts again keeps them.
        if (!ApolloListInstalledSpinner(state.adapter)) continue;
        id controller = state.controller;
        SEL refresh = state.refreshSelector;
        if (!controller || !refresh || ![controller respondsToSelector:refresh]) continue;
        ApolloLog(@"[ListEmptyState] Reddit's rate limit on u/%@ has reset; reloading %@ (%@)", state.account,
                  NSStringFromClass([controller class]), NSStringFromSelector(refresh));
        ((void (*)(id, SEL, id))objc_msgSend)(controller, refresh, nil);
    }
}

// After Apollo has handled a first page that ended `outcome`. Apollo shows
// whichever page arrives last, so the outcome goes on the list's current
// state even if a newer first page has started since this one.
static void ApolloListFinishFirstPage(id adapter, NSString *path, ApolloListOutcome outcome, NSError *error) {
    ApolloListLoadState *state = ApolloListStateFor(adapter);
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

// The account sending a first page, of either kind, lowercased; nil when
// nobody is signed in. Found the way ApolloListRequestAccount finds it.
static NSString *ApolloListRequestUsername(id client) {
    id user = [client respondsToSelector:@selector(currentUser)] ? ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser)) : nil;
    NSString *username = [user respondsToSelector:@selector(username)] ? ((id (*)(id, SEL))objc_msgSend)(user, @selector(username)) : nil;
    if (![username isKindOfClass:NSString.class] || username.length == 0) username = ApolloListActiveAccount();
    return username.length > 0 ? username.lowercaseString : nil;
}

// "user/<name>/comments.json" -> "<name>".
static NSString *ApolloUsernameFromListingPath(NSString *path) {
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSUInteger index = [parts indexOfObject:@"user"];
    return index != NSNotFound && index + 1 < parts.count ? parts[index + 1] : nil;
}

// Defined in Tweak.xm, next to the /r/random request rewrite.
NSString *ApolloRandomPickExcluding(BOOL nsfw, NSString *excluded);

// For a Random listing path ("r/random/best.json"): 1 for Random, 2 for Random
// NSFW, else 0, with the index of the "random" component in `parts`.
static NSInteger ApolloListRandomKind(NSArray<NSString *> *parts, NSUInteger *nameIndex) {
    NSUInteger index = 0;
    while (index < parts.count && parts[index].length == 0) index++; // leading "/"
    if (index + 1 >= parts.count || ![parts[index] isEqualToString:@"r"]) return 0;
    NSString *name = parts[index + 1].stringByDeletingPathExtension.lowercaseString;
    NSInteger kind = [name isEqualToString:@"random"] ? 1 : [name isEqualToString:@"randnsfw"] ? 2 : 0;
    if (kind && nameIndex) *nameIndex = index + 1;
    return kind;
}

// A Random feed's first page came back with no posts (a banned or private
// pick). Apollo only learns a random feed's community from a loaded post, so
// both places it names the feed keep the previous community:
//   * the error text ("r/x has been banned ..."), built from the Swift
//     randomSubredditName (see the message switch at 0x10059b668), and
//   * the title, the JumpBar's dropDownTitle and nameLabel.
// Called before Apollo handles the page: point randomSubredditName at the pick.
static void ApolloListNameFailedRandomPick(UIViewController *controller, NSString *pick) {
    ptrdiff_t offset = controller ? ApolloIvarOffset(object_getClass(controller), "randomSubredditName") : -1;
    if (offset < 0) {
        ApolloLog(@"[Random] PostsViewController.randomSubredditName not found; error text keeps the old name");
        return;
    }
    NSString *previous = ApolloReadSwiftStringIvar(controller, "randomSubredditName");
    ApolloSwiftAssignOptionalString((uint8_t *)(__bridge void *)controller + offset, pick.UTF8String);
    ApolloLog(@"[Random] failed random listing: randomSubredditName %@ -> %@", previous ?: @"nil", pick);
}

// Called after Apollo handled that page: title the feed with the pick, as
// Apollo's own success path (0x1005b1504) does: the navigation item's title
// (which ApolloSubredditHeaders reads) and the JumpBar's.
static void ApolloListTitleFailedRandomPick(UIViewController *controller, NSString *pick) {
    controller.navigationItem.title = pick;
    // The success path then runs 0x1005988e0, which for a Random feed sets
    // searchBarPlaceholder to "Search r/<randomSubredditName>" and puts it on
    // searchTextField as an attributed placeholder (0x1002bd100).
    NSString *placeholder = [@"Search r/" stringByAppendingString:pick];
    ptrdiff_t placeholderOffset = controller ? ApolloIvarOffset(object_getClass(controller), "searchBarPlaceholder") : -1;
    if (placeholderOffset >= 0) ApolloSwiftAssignString((uint8_t *)(__bridge void *)controller + placeholderOffset, placeholder.UTF8String);
    UITextField *searchField = controller ? ApolloObjectIvar(controller, "searchTextField") : nil;
    NSAttributedString *oldPlaceholder = [searchField isKindOfClass:UITextField.class] ? searchField.attributedPlaceholder : nil;
    if (oldPlaceholder.length > 0) {
        searchField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder
            attributes:[oldPlaceholder attributesAtIndex:0 effectiveRange:NULL]];
    }
    UIView *jumpBar = controller ? ApolloObjectIvar(controller, "jumpBar") : nil;
    if (!ApolloClassJumpBar || ![jumpBar isKindOfClass:ApolloClassJumpBar]) {
        ApolloLog(@"[Random] no JumpBar on the random feed; title keeps the old name");
        return;
    }
    ptrdiff_t titleOffset = ApolloIvarOffset(object_getClass(jumpBar), "dropDownTitle");
    if (titleOffset >= 0) ApolloSwiftAssignString((uint8_t *)(__bridge void *)jumpBar + titleOffset, pick.UTF8String);
    // -setText:, as dropDownTitle's didSet (0x10062d154) does. Not
    // -setAttributedText:: ApolloThemeRuntime keeps a label's attributed text
    // and re-applies it, which would outlast Apollo's next title.
    UILabel *label = ApolloObjectIvar(jumpBar, "nameLabel");
    if ([label isKindOfClass:UILabel.class]) {
        ApolloLog(@"[Random] failed random listing: title %@ -> %@", label.text ?: @"nil", pick);
        label.text = pick;
    }
    [jumpBar invalidateIntrinsicContentSize];
    [jumpBar setNeedsLayout];
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
    state.requestUsername = ApolloListRequestUsername(self);
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

    // Random / Random NSFW: pick this feed's next community here, where the
    // feed is known, leaving out the one it shows (its randomSubredditName,
    // which a failed pick also sets below), and send Apollo's path to it.
    // Apollo still handles the page as a random listing and names the feed
    // from its posts.
    NSMutableArray<NSString *> *pathParts = [[path componentsSeparatedByString:@"/"] mutableCopy];
    NSUInteger randomNameIndex = 0;
    NSInteger randomKind = kind == ApolloListKindPosts ? ApolloListRandomKind(pathParts, &randomNameIndex) : 0;
    NSString *randomPick = nil;
    if (randomKind) {
        NSString *shown = ApolloReadSwiftStringIvar(controller, "randomSubredditName");
        randomPick = ApolloRandomPickExcluding(randomKind == 2, shown);
        if (randomPick.length > 0) {
            NSString *extension = pathParts[randomNameIndex].pathExtension;
            pathParts[randomNameIndex] = extension.length > 0 ? [randomPick stringByAppendingPathExtension:extension] : randomPick;
            NSString *randomPath = [pathParts componentsJoinedByString:@"/"];
            ApolloLog(@"[Random] feed %p shows %@: %@ -> %@", controller, shown ?: @"nothing", path, randomPath);
            path = randomPath;
        } else {
            ApolloLog(@"[Random] feed %p: no list loaded; %@ goes out unchanged", controller, path);
        }
    }
    __weak UIViewController *weakController = controller;
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
                ApolloListRecordOutcome(ApolloListStateFor(strongAdapter), outcome, ApolloListInstalledSpinner(strongAdapter) != nil);
                ApolloListNoteGate(strongAdapter, weakController, path, error);
                ApolloListFinishFirstPage(strongAdapter, path, outcome, error);
            });
            return;
        }
        // Record the outcome before Apollo handles the page: ListAdapter can
        // re-install its spinner synchronously inside that call.
        id strongAdapter = weakAdapter;
        ApolloListRecordOutcome(ApolloListStateFor(strongAdapter), outcome, ApolloListInstalledSpinner(strongAdapter) != nil);
        UIViewController *strongController = weakController;
        ApolloListNoteGate(strongAdapter, strongController, path, error);
        NSString *failedPick = items.count == 0 ? randomPick : nil;
        if (failedPick.length > 0) ApolloListNameFailedRandomPick(strongController, failedPick);
        completion(items, nextPagination, error);
        if (failedPick.length > 0) ApolloListTitleFailedRandomPick(strongController, failedPick);
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

%group ApolloGatedSubredditHooks

%hook RDKClient

// RedditKit turns an error answer into an NSError here (called by
// -[RDKResponseSerializer responseObjectForResponse:data:error:] for every
// JSON answer). It knows the reasons "private", "banned" and "quarantined"; a
// gated subreddit's answer comes out as a plain HTTP 403. Reddit's warning
// rides on that error so the list that asked can show it. Runs on the
// serializer's queue; nothing here touches shared state.
+ (id)errorFromResponseObject:(id)responseObject {
    NSError *error = %orig;
    // Only an answer RedditKit made an error for (a gated one has "error":
    // 403). Anything it let through stays as it was.
    if (![error isKindOfClass:NSError.class]) return error;
    NSString *warning = ApolloGatedWarningFromResponseObject(responseObject);
    return warning ? ApolloGatedErrorWithWarning(error, warning) : error;
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
    // Without RedditKit's error method a gated subreddit's failure carries no
    // warning, and its list stays the plain failed load it was.
    if (class_getClassMethod(clientClass, @selector(errorFromResponseObject:))) {
        %init(ApolloGatedSubredditHooks);
        ApolloLog(@"[GatedSubreddit] Content warning hook installed (+[RDKClient errorFromResponseObject:])");
    } else {
        ApolloLog(@"[GatedSubreddit] +[RDKClient errorFromResponseObject:] not found; content warning hook NOT installed");
    }
}
