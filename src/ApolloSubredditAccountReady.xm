// ApolloSubredditAccountReady.xm
//
// The subreddit list can finish its initial load before AccountManager restores
// the active account. In that ordering it keeps Reddit's default list until the
// user pulls to refresh. Apollo has its own account-change handler, but registers
// it during viewDidLoad; catch only a transition that lands inside that setup
// window, then leave all later account switches to the native handler.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloSubredditAccountRefresh.h"

static NSString *const kApolloCurrentAccountChangedNotification =
    @"com.christianselig.RedditCurrentAccountChanged";
static NSString *const kApolloAccountChangedNotification =
    @"com.christianselig.RedditAccountChanged";
static char kApolloSubredditAccountRefreshCoordinatorKey;
static char kApolloSubredditAccountObserverTokensKey;

static void ApolloSubredditRemoveTemporaryAccountObservers(id controller) {
    NSArray *tokens = objc_getAssociatedObject(controller, &kApolloSubredditAccountObserverTokensKey);
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (id token in tokens) {
        [center removeObserver:token];
    }
    objc_setAssociatedObject(controller, &kApolloSubredditAccountObserverTokensKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%group ApolloSubredditAccountReady

%hook _TtC6Apollo24RedditListViewController

- (void)viewDidLoad {
    // Observe before Apollo starts its first load so an account transition that
    // lands during the native viewDidLoad cannot slip through the gap.
    __weak UIViewController *weakController = (UIViewController *)self;
    ApolloSubredditAccountRefreshCoordinator *coordinator =
        [[ApolloSubredditAccountRefreshCoordinator alloc]
            initWithScheduler:^(dispatch_block_t work) {
                dispatch_async(dispatch_get_main_queue(), work);
            }
            refresh:^{
                UIViewController *controller = weakController;
                if (!controller || !controller.isViewLoaded) return;

                SEL refreshSelector = NSSelectorFromString(@"refreshControlActivated:");
                if (![controller respondsToSelector:refreshSelector]) {
                    ApolloLog(@"[SubredditAccountReady] native refresh action is unavailable");
                    return;
                }

                ApolloLog(@"[SubredditAccountReady] reloading list after account became ready");
                ((void (*)(id, SEL, id))objc_msgSend)(controller, refreshSelector, nil);
            }];
    objc_setAssociatedObject(self, &kApolloSubredditAccountRefreshCoordinatorKey,
                             coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak ApolloSubredditAccountRefreshCoordinator *weakCoordinator = coordinator;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    id currentAccountToken =
        [center addObserverForName:kApolloCurrentAccountChangedNotification
                           object:nil
                            queue:nil
                       usingBlock:^(NSNotification *notification) {
                           (void)notification;
                           [weakCoordinator requestRefresh];
                       }];
    id accountToken =
        [center addObserverForName:kApolloAccountChangedNotification
                           object:nil
                            queue:nil
                       usingBlock:^(NSNotification *notification) {
                           (void)notification;
                           [weakCoordinator requestRefresh];
                       }];
    objc_setAssociatedObject(self, &kApolloSubredditAccountObserverTokensKey,
                             @[currentAccountToken, accountToken],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    %orig;

    // Apollo's native account-change observer is ready now. Staying registered
    // would duplicate its reload on every ordinary account switch.
    ApolloSubredditRemoveTemporaryAccountObservers(self);
    ApolloSubredditAccountRefreshCoordinator *settledCoordinator =
        objc_getAssociatedObject(self, &kApolloSubredditAccountRefreshCoordinatorKey);
    [settledCoordinator disarm];
}

- (void)redditAccountChangedWithNotification:(id)notification {
    // Native viewDidLoad registers this handler partway through its work. If it
    // saw the same transition, cancel our earlier queued fallback so the list
    // performs exactly one reload.
    ApolloSubredditAccountRefreshCoordinator *coordinator =
        objc_getAssociatedObject(self, &kApolloSubredditAccountRefreshCoordinatorKey);
    [coordinator nativeRefreshHandled];
    %orig(notification);
}

- (void)dealloc {
    ApolloSubredditRemoveTemporaryAccountObservers(self);
    %orig;
}

%end

%end

%ctor {
    if (objc_getClass("_TtC6Apollo24RedditListViewController")) {
        %init(ApolloSubredditAccountReady);
    }
}
