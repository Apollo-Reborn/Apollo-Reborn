#import "ApolloAccountSwitchLink.h"
#import "ApolloAccountSwitchLinkStore.h"
#import "ApolloAccountSwitcherViewController.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloToast.h"
#import "settings/ApolloBackupDocument.h"
#import "ApolloDirectChatWeb.h"
#import "settings/ApolloSettingsRouter.h"
#import <QuartzCore/QuartzCore.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Modern mailbox notification destinations deliberately use Reborn-owned URLs
// instead of pretending to be legacy Reddit messages:
//
//   apollo://reborn/chat
//   apollo://reborn/chat/room/<opaque-room-id>
//   apollo://reborn/modmail/all/<opaque-conversation-id>
//
// The path after `chat` is already Reddit Chat's path. For Modmail, replace the
// Reborn-only `modmail` route component with Reddit's real `mail` component.
// Keeping this translation in one place means Bark taps, APNs taps, widgets,
// and manually opened URLs all follow the same validated route.
static NSDictionary<NSString *, NSString *> *ApolloModernMailboxRouteFromURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] ||
        ![[url.scheme lowercaseString] isEqualToString:@"apollo"] ||
        ![[url.host lowercaseString] isEqualToString:@"reborn"]) return nil;

    NSString *path = url.path ?: @"";
    if ([path isEqualToString:@"/chat"] || [path hasPrefix:@"/chat/"]) {
        return @{ @"kind": @"chat", @"path": path };
    }
    if ([path isEqualToString:@"/modmail"] || [path hasPrefix:@"/modmail/"]) {
        NSString *suffix = [path substringFromIndex:[@"/modmail" length]];
        NSString *mailPath = suffix.length > 0
            ? [@"/mail" stringByAppendingString:suffix] : @"/mail/all";
        return @{ @"kind": @"modmail", @"path": mailPath };
    }
    return nil;
}

static NSString *ApolloQuickActionNameFromURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if (![[url.scheme lowercaseString] isEqualToString:@"apollo"]) return nil;

    NSString *host = [[url.host lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![host isEqualToString:@"reborn"]) return nil;

    NSString *path = [[url.path lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (path.length == 0) return nil;

    // apollo://reborn/settings/<route-id> opens a specific Reborn settings
    // screen (route ids live in ApolloSettingsRouter). Only claim registered
    // routes — claiming a URL we can't perform swallows it.
    if ([path hasPrefix:@"settings/"]) {
        NSString *routeId = [path substringFromIndex:@"settings/".length];
        return ApolloSettingsRouteExists(routeId) ? path : nil;
    }

    // Only the actions we actually route below. Popular/All are opened by the
    // widget via Apollo's native apollo://reddit.com/r/popular|all URLs (host
    // "reddit.com", not "reborn"), so we must NOT claim them here — claiming a
    // URL we can't perform swallows it and then retries until it gives up.
    if ([path isEqualToString:@"search"] ||
        [path isEqualToString:@"home"] ||
        [path isEqualToString:@"inbox"] ||
        [path isEqualToString:@"profile"] ||
        [path isEqualToString:@"settings"]) {
        return path;
    }

    return nil;
}

// The navigation controller of the tab bar's selected tab, or nil.
static UINavigationController *ApolloQuickActionsSelectedNavigationController(id tabBarController) {
    if (![tabBarController isKindOfClass:[UITabBarController class]]) return nil;
    UIViewController *selected = [(UITabBarController *)tabBarController selectedViewController];
    // Pane tabs own a split container; ordinary tabs remain unchanged.
    return ApolloNavigationControllerForTabChild(selected);
}

// Opens Apollo's front-page feed (the aggregated "Posts from subscriptions"
// listing), NOT the subreddit picker list that goToHomeTab lands on.
//
// goToHomeTab only switches to the Home tab, whose root is a
// RedditListViewController — a table whose first row (section 0, row 0) is the
// "Home" entry ("Posts from subscriptions"). Selecting that row is exactly what
// a user tap does, so we drive Apollo's own navigation by calling its
// tableView:didSelectRowAtIndexPath: with that index path. This reuses Apollo's
// real push logic instead of trying to construct a PostsViewController (its
// PostsType.home initializer is a Swift enum that can't be built from ObjC).
static BOOL ApolloQuickActionsOpenHomeFeed(id tabBarController) {
    // Switch to the Home tab so the navigation we drive is the visible one.
    if ([tabBarController respondsToSelector:@selector(goToHomeTab)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(tabBarController, @selector(goToHomeTab));
        } @catch (NSException *exception) {
            ApolloLogError(@"[QuickActions] goToHomeTab threw: %@", exception);
        }
    }

    UINavigationController *nav = ApolloQuickActionsSelectedNavigationController(tabBarController);
    if (!nav) {
        ApolloLog(@"[QuickActions] Home: no navigation controller for selected tab of %@", tabBarController);
        return NO;
    }

    // Pop back to the list root so the "Home" row is the controller we drive.
    [nav popToRootViewControllerAnimated:NO];
    UIViewController *root = nav.viewControllers.firstObject;

    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    if (!listClass || ![root isMemberOfClass:listClass]) {
        ApolloLog(@"[QuickActions] Home: root is not RedditListViewController (%@)", root);
        return NO;
    }

    UITableView *tableView = nil;
    if ([root respondsToSelector:@selector(tableView)]) {
        @try {
            tableView = ((UITableView *(*)(id, SEL))objc_msgSend)(root, @selector(tableView));
        } @catch (NSException *exception) {
            ApolloLogError(@"[QuickActions] Home: failed reading tableView: %@", exception);
        }
    }

    if (![root respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        ApolloLog(@"[QuickActions] Home: %@ does not respond to tableView:didSelectRowAtIndexPath:", root);
        return NO;
    }

    NSIndexPath *homeIndexPath = [NSIndexPath indexPathForRow:0 inSection:0];
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(root, @selector(tableView:didSelectRowAtIndexPath:), tableView, homeIndexPath);
        ApolloLog(@"[QuickActions] Opened Home front-page feed via RedditListViewController row 0");
        return YES;
    } @catch (NSException *exception) {
        ApolloLogError(@"[QuickActions] Home: failed selecting front-page row: %@", exception);
        return NO;
    }
}

static BOOL ApolloQuickActionsPerformNow(NSString *action, UIWindowScene *originatingScene) {
    id tabBarController = ApolloMainTabBarControllerForScene(originatingScene);
    if (!tabBarController) {
        return NO;
    }

    // "settings/<route-id>" pushes a Reborn settings screen (deep link).
    if ([action hasPrefix:@"settings/"]) {
        return ApolloSettingsRouteOpenNowInScene([action substringFromIndex:@"settings/".length],
                                                  originatingScene);
    }

    // "home" opens the actual front-page feed (posts), not the picker list.
    if ([action isEqualToString:@"home"]) {
        return ApolloQuickActionsOpenHomeFeed(tabBarController);
    }

    // Remaining quick actions map directly to ApolloTabBarController tab selectors.
    SEL selector = NULL;
    if ([action isEqualToString:@"search"]) {
        selector = @selector(goToSearchTab);
    } else if ([action isEqualToString:@"inbox"]) {
        selector = @selector(goToInboxTab);
    } else if ([action isEqualToString:@"profile"]) {
        selector = @selector(goToProfileTab);
    } else if ([action isEqualToString:@"settings"]) {
        selector = @selector(goToSettingsTab);
    }

    if (!selector || ![tabBarController respondsToSelector:selector]) {
        ApolloLog(@"[QuickActions] Tab controller %@ does not respond to %@", tabBarController, NSStringFromSelector(selector));
        return NO;
    }

    @try {
        ((void (*)(id, SEL))objc_msgSend)(tabBarController, selector);
        ApolloLog(@"[QuickActions] Performed %@", action);
    } @catch (NSException *exception) {
        ApolloLogError(@"[QuickActions] Failed performing %@: %@", action, exception);
        return NO;
    }

    return YES;
}

static BOOL ApolloQuickActionsOpenModernMailboxNow(NSDictionary<NSString *, NSString *> *route,
                                                    UIWindowScene *originatingScene) {
    id tabBarController = ApolloMainTabBarControllerForScene(originatingScene);
    if (!tabBarController) return NO;

    if ([tabBarController respondsToSelector:@selector(goToInboxTab)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(tabBarController, @selector(goToInboxTab));
        } @catch (NSException *exception) {
            ApolloLog(@"[QuickActions] Modern mailbox could not select Inbox: %@", exception);
            return NO;
        }
    }

    UINavigationController *navigationController = ApolloQuickActionsSelectedNavigationController(tabBarController);
    if (!navigationController) return NO;

    NSString *kind = route[@"kind"];
    NSString *path = route[@"path"];
    UIViewController *mailbox = [kind isEqualToString:@"modmail"]
        ? ApolloCreateModernModmailViewControllerForPath(path)
        : ApolloCreateStandaloneInboxChatHub(path);
    if (!mailbox) return NO;

    // A notification is a fresh destination, not another layer on top of an
    // existing Inbox detail. Reset to Boxes before opening it so Back has one
    // predictable place to return to.
    [navigationController popToRootViewControllerAnimated:NO];
    [navigationController pushViewController:mailbox animated:NO];
    ApolloLog(@"[QuickActions] Opened modern %@ notification destination",
              [kind isEqualToString:@"modmail"] ? @"Modmail" : @"Chat");
    return YES;
}

// Retries `perform` every 250ms (the tab bar controller may not exist yet on a
// cold launch from a URL), giving up after `maxRetries` retries and then
// running `giveUp` (optional).
static void ApolloQuickActionsRetryUpTo(NSString *description, NSUInteger maxRetries, BOOL (^perform)(void),
                                        void (^giveUp)(void), NSUInteger attempt) {
    if (perform()) return;
    if (attempt >= maxRetries) {
        ApolloLog(@"[QuickActions] Gave up %@", description);
        if (giveUp) giveUp();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloQuickActionsRetryUpTo(description, maxRetries, perform, giveUp, attempt + 1);
    });
}

static void ApolloQuickActionsRetry(NSString *description, BOOL (^perform)(void), NSUInteger attempt) {
    ApolloQuickActionsRetryUpTo(description, 8, perform, nil, attempt);
}

#pragma mark - Shortcut account-switch links

// apollo://reborn/account/<username>?key=<secret> (ApolloAccountSwitchLink.h).
// Every account/... link is claimed, valid or not, so Apollo's native router
// never sees one. Log hygiene: never the key, the link or the username — only
// the verdict and counts.

static ApolloAccountSwitchLinkLockout sApolloAccountLinkLockout;

static void ApolloAccountLinkShowRejected(void) {
    // One message for every rejection: it never says whether the account exists.
    ApolloShowToastWithStyle(@"Account switch link rejected", nil, ApolloToastStyleError, nil);
}

static void ApolloAccountLinkShowOutcome(ApolloAccountLinkSwitchOutcome outcome, NSString *displayName) {
    switch (outcome) {
        case ApolloAccountLinkSwitchOutcomeSwitched:
            // The success haptic already played in ApolloAccountSwitcherDriveLiveSwitch.
            ApolloShowToast([NSString stringWithFormat:@"Switched to u/%@", displayName]);
            break;
        case ApolloAccountLinkSwitchOutcomeAlreadyActive:
            ApolloShowToastWithStyle([NSString stringWithFormat:@"Already using u/%@", displayName], nil, ApolloToastStyleInfo, nil);
            break;
        case ApolloAccountLinkSwitchOutcomeUnknownAccount:
            ApolloAccountLinkShowRejected();
            break;
        case ApolloAccountLinkSwitchOutcomeBusy:
            ApolloShowToastWithStyle(@"Couldn't switch accounts", @"Close the open screen and try again.", ApolloToastStyleError, nil);
            break;
        case ApolloAccountLinkSwitchOutcomeFailed:
            ApolloShowToastWithStyle(@"Couldn't switch accounts", nil, ApolloToastStyleError, nil);
            break;
    }
}

static void ApolloAccountLinkPerform(NSString *username, NSString *key) {
    BOOL enabled = sAccountSwitchLinksEnabled;
    NSString *storedKey = enabled ? ApolloAccountSwitchLinkStoredKey() : nil;
    ApolloAccountSwitchLinkVerdict verdict = ApolloAccountSwitchLinkEvaluate(enabled, sApolloAccountLinkLockout.lockedOut,
                                                                             storedKey, key, username);
    switch (verdict) {
        case ApolloAccountSwitchLinkVerdictIgnore:
            ApolloLog(@"[AccountLink] Ignored: locked out until relaunch");
            return;
        case ApolloAccountSwitchLinkVerdictRejectDisabled:
            ApolloLog(@"[AccountLink] Rejected: feature off");
            ApolloAccountLinkShowRejected();
            return;
        case ApolloAccountSwitchLinkVerdictRejectKey: {
            BOOL lockedOut = ApolloAccountSwitchLinkLockoutRecordFailure(&sApolloAccountLinkLockout, CACurrentMediaTime());
            ApolloLog(@"[AccountLink] Rejected: %@ key (%lu in window)%@", key.length ? @"wrong" : @"missing",
                      (unsigned long)sApolloAccountLinkLockout.count, lockedOut ? @"; locked out until relaunch" : @"");
            ApolloAccountLinkShowRejected();
            return;
        }
        case ApolloAccountSwitchLinkVerdictRejectUsername:
            ApolloLog(@"[AccountLink] Rejected: no usable username");
            ApolloAccountLinkShowRejected();
            return;
        case ApolloAccountSwitchLinkVerdictAccept:
            break;
    }

    ApolloLog(@"[AccountLink] Accepted; switching");
    // Up to 6s: on a cold start the account list loads after the tab bar.
    ApolloQuickActionsRetryUpTo(@"switching account from a link", 24, ^BOOL{
        return ApolloAccountSwitcherSwitchToUsername(username, ^(ApolloAccountLinkSwitchOutcome outcome, NSString *displayName) {
            ApolloAccountLinkShowOutcome(outcome, displayName);
        });
    }, ^{
        ApolloAccountLinkShowOutcome(ApolloAccountLinkSwitchOutcomeFailed, nil);
    }, 0);
}

static BOOL ApolloQuickActionsHandleAccountLink(NSURL *url) {
    NSString *username = nil;
    NSString *key = nil;
    if (!ApolloAccountSwitchLinkParse(url, &username, &key)) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloAccountLinkPerform(username, key);
    });
    return YES;
}

static BOOL ApolloQuickActionsHandleURL(NSURL *url, UIWindowScene *originatingScene) {
    if (ApolloBackupDocumentHandleURL(url)) return YES;
    if (ApolloQuickActionsHandleAccountLink(url)) return YES;
    NSDictionary<NSString *, NSString *> *mailboxRoute = ApolloModernMailboxRouteFromURL(url);
    if (mailboxRoute) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloQuickActionsRetry(@"opening modern mailbox notification destination", ^BOOL{
                return ApolloQuickActionsOpenModernMailboxNow(mailboxRoute, originatingScene);
            }, 0);
        });
        return YES;
    }

    NSString *action = ApolloQuickActionNameFromURL(url);
    if (!action) return NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloQuickActionsRetry([@"performing " stringByAppendingString:action], ^BOOL{
            return ApolloQuickActionsPerformNow(action, originatingScene);
        }, 0);
    });
    return YES;
}

%hook _TtC6Apollo11AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig(application, launchOptions);
    ApolloBackupDocumentHandleURL(launchOptions[UIApplicationLaunchOptionsURLKey]);
    return result;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    if (ApolloQuickActionsHandleURL(url, nil)) {
        return YES;
    }
    return %orig(application, url, options);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    NSDictionary *userInfo = response.notification.request.content.userInfo;
    NSString *rawURL = [userInfo[@"apollo_deep_link"] isKindOfClass:[NSString class]]
        ? userInfo[@"apollo_deep_link"] : nil;
    if (!rawURL.length && [userInfo[@"url"] isKindOfClass:[NSString class]]) {
        rawURL = userInfo[@"url"];
    }

    NSURL *url = rawURL.length > 0 ? [NSURL URLWithString:rawURL] : nil;
    if (ApolloQuickActionsHandleURL(url, nil)) {
        ApolloLog(@"[QuickActions] Handled modern mailbox APNs destination");
        if (completionHandler) completionHandler();
        return;
    }
    %orig(center, response, completionHandler);
}

%end

// While YES, UISceneConnectionOptions hides account-switch links, so Apollo's
// own cold-start handling in -scene:willConnectToSession:options: never routes
// one natively.
static BOOL sApolloHideAccountLinksFromConnectionOptions = NO;

%hook UISceneConnectionOptions

- (NSSet<UIOpenURLContext *> *)URLContexts {
    NSSet<UIOpenURLContext *> *contexts = %orig;
    if (!sApolloHideAccountLinksFromConnectionOptions || contexts.count == 0) return contexts;
    return [contexts objectsPassingTest:^BOOL(UIOpenURLContext *context, __unused BOOL *stop) {
        return !ApolloAccountSwitchLinkIsAccountURL(context.URL);
    }];
}

%end

%hook _TtC6Apollo13SceneDelegate

- (void)scene:(UIScene *)scene
 willConnectToSession:(UISceneSession *)session
             options:(UISceneConnectionOptions *)connectionOptions {
    // A cold launch from an account-switch link: take it here (it waits for
    // the tab bar via the retry loop) and keep it away from native startup.
    for (UIOpenURLContext *context in connectionOptions.URLContexts) {
        ApolloQuickActionsHandleAccountLink(context.URL);
    }
    sApolloHideAccountLinksFromConnectionOptions = YES;
    %orig(scene, session, connectionOptions);
    sApolloHideAccountLinksFromConnectionOptions = NO;

    // Native Apollo consumes its own connection options before the pane
    // installer wraps the tab children. Reborn-owned routes are not known to
    // Apollo, so claim them here and queue their existing retry-based handler.
    // The async hop makes this independent of Logos hook ordering: pane
    // installation will have completed before the first attempt runs.
    for (UIOpenURLContext *context in connectionOptions.URLContexts) {
        // Account-switch links were already taken before %orig.
        if (ApolloAccountSwitchLinkIsAccountURL(context.URL)) continue;
        if (ApolloQuickActionsHandleURL(context.URL, (UIWindowScene *)scene)) {
            ApolloLog(@"[QuickActions] Queued Reborn cold URL route");
        }
    }

    UNNotificationResponse *response = connectionOptions.notificationResponse;
    NSDictionary *userInfo = response.notification.request.content.userInfo;
    NSString *rawURL = [userInfo[@"apollo_deep_link"] isKindOfClass:[NSString class]]
        ? userInfo[@"apollo_deep_link"] : nil;
    if (!rawURL.length && [userInfo[@"url"] isKindOfClass:[NSString class]]) {
        rawURL = userInfo[@"url"];
    }
    if (rawURL.length > 0 && ApolloQuickActionsHandleURL([NSURL URLWithString:rawURL],
                                                          (UIWindowScene *)scene)) {
        ApolloLog(@"[QuickActions] Queued Reborn cold notification route");
    }

#if APOLLO_SIM_BUILD
    NSString *injectedURL =
        NSProcessInfo.processInfo.environment[@"APOLLO_SIM_COLD_REBORN_URL"];
    if (injectedURL.length > 0 &&
        ApolloQuickActionsHandleURL([NSURL URLWithString:injectedURL], (UIWindowScene *)scene)) {
        ApolloLog(@"[QuickActions] Queued simulator-injected Reborn cold route");
    }
#endif
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet *)URLContexts {
    NSMutableSet *unhandledContexts = [NSMutableSet setWithCapacity:URLContexts.count];
    BOOL handledAny = NO;

    for (id context in URLContexts) {
        NSURL *url = nil;
        @try {
            if ([context respondsToSelector:@selector(URL)]) {
                url = ((NSURL *(*)(id, SEL))objc_msgSend)(context, @selector(URL));
            }
        } @catch (NSException *exception) {
            ApolloLogError(@"[QuickActions] Failed reading URL context: %@", exception);
        }

        if (ApolloQuickActionsHandleURL(url, (UIWindowScene *)scene)) {
            handledAny = YES;
        } else if (context) {
            [unhandledContexts addObject:context];
        }
    }

    if (unhandledContexts.count > 0) {
        %orig(scene, unhandledContexts);
    } else if (!handledAny) {
        %orig(scene, URLContexts);
    }
}

%end
