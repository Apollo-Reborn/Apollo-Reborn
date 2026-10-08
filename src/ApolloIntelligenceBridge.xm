// Optional Siri framework bridge. No App Intents/Swift linkage is introduced
// into the normal iOS 14 tweak. All capture is inactive without the framework
// and the explicit content-indexing preference.
#import "ApolloCommon.h"
#import "ApolloAccountCredentials.h"
#import "Tweak.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const ApolloSiriEnabledKey = @"ApolloSiriContentEnabled";

extern "C" NSString *ApolloSiriCurrentAccount(void) {
    if (![NSThread isMainThread]) return nil;
    // sharedClient is Apollo's APPLICATION-ONLY bootstrap client, not the
    // selected account. Reuse the tweak's status-bearing account resolver.
    NSString *name = nil;
    ApolloPersistedAccountIdentityStatus status = ApolloResolveLiveActiveAccountIdentity(&name);
    if (status == ApolloPersistedAccountIdentityUnknown) {
        status = ApolloResolvePersistedActiveAccountIdentity(&name);
    }
    if (status == ApolloPersistedAccountIdentitySignedIn && name.length) return name;
    // nil = unresolved (do not clear a cold-start catalogue); empty = signed out.
    return status == ApolloPersistedAccountIdentitySignedOut ? @"" : nil;
}

static UIViewController *ApolloSiriFindSearch(UIViewController *controller) {
    if ([controller isKindOfClass:objc_getClass("_TtC6Apollo20SearchViewController")]) return controller;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *match = ApolloSiriFindSearch(child);
        if (match) return match;
    }
    return nil;
}

extern "C" UIViewController *ApolloSiriPrepareNativeSearch(void) {
    if (![NSThread isMainThread]) return nil;
    UIViewController *search = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            search = ApolloSiriFindSearch(window.rootViewController);
            if (search) break;
        }
        if (search) break;
    }
    if (!search) return nil;
    // Do not dismiss a compose/login/modal screen and risk losing user work.
    for (UIViewController *parent = search; parent; parent = parent.parentViewController) {
        if (parent.presentedViewController) return nil;
    }
    UITabBarController *tabs = search.tabBarController;
    UIViewController *selected = tabs.selectedViewController;
    if (selected.presentedViewController ||
        ([selected isKindOfClass:UINavigationController.class] && ((UINavigationController *)selected).topViewController.presentedViewController)) return nil;
    UIViewController *tab = search;
    while (tab.parentViewController && tab.parentViewController != tabs) tab = tab.parentViewController;
    if (tabs) tabs.selectedViewController = tab;
    [search.navigationController popToViewController:search animated:NO];
    [search loadViewIfNeeded];
    return search;
}

extern "C" BOOL ApolloSiriOpenNativeSearch(NSString *query) {
    if (![NSThread isMainThread] || ![query isKindOfClass:NSString.class] || !query.length) return NO;
    UIViewController *search = ApolloSiriPrepareNativeSearch();
    if (!search || search.navigationController.transitionCoordinator) return NO;
    SEL changed = @selector(searchBar:textDidChange:);
    SEL submit = @selector(searchBarSearchButtonClicked:);
    if (![search respondsToSelector:changed] || ![search respondsToSelector:submit]) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(search), "searchBar");
    id candidate = ivar ? object_getIvar(search, ivar) : search.navigationItem.titleView;
    if (![candidate isKindOfClass:UISearchBar.class]) return NO;
    UISearchBar *bar = candidate;
    // Use the same path as typing and pressing Search. Never write Swift String
    // ivars or send /search through the URL router (that opens a web viewer).
    bar.text = query;
    ((void (*)(id, SEL, id, id))objc_msgSend)(search, changed, bar, query);
    ((void (*)(id, SEL, id))objc_msgSend)(search, submit, bar);
    ApolloLog(@"[Siri] Submitted native search");
    return YES;
}

static NSData *ApolloSiriListingData(id response) {
    if (![response isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *data = response[@"data"];
    if (![data isKindOfClass:NSDictionary.class]) return nil;
    NSArray *children = data[@"children"];
    if (![children isKindOfClass:NSArray.class] || children.count > 500) return nil;
    // Forward only the explicit content allowlist, never the original response,
    // credentials, private messages or arbitrary server dictionaries.
    NSArray *keys = @[@"name", @"title", @"subreddit", @"author", @"selftext", @"permalink",
                      @"created_utc", @"over_18", @"over18", @"hidden", @"subreddit_type", @"removed_by_category",
                      @"display_name", @"public_description", @"user_is_subscriber",
                      @"score", @"num_comments", @"domain"];
    NSMutableArray *records = [NSMutableArray array];
    for (id child in children) {
        if (![child isKindOfClass:NSDictionary.class]) continue;
        NSString *kind = child[@"kind"];
        if (!([kind isEqual:@"t3"] || [kind isEqual:@"t5"])) continue;
        NSDictionary *source = child[@"data"];
        if (![source isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObject:kind forKey:@"kind"];
        for (NSString *key in keys) {
            id value = source[key];
            if ([value isKindOfClass:NSString.class]) {
                NSUInteger limit = [key isEqual:@"selftext"] ? 2048 : 512;
                record[key] = [value length] > limit ? [value substringToIndex:limit] : value;
            } else if ([value isKindOfClass:NSNumber.class]) {
                record[key] = value;
            }
        }
        [records addObject:record];
    }
    NSData *payload = [NSJSONSerialization dataWithJSONObject:records options:0 error:nil];
    return payload.length <= 2 * 1024 * 1024 ? payload : nil;
}

static void ApolloSiriCaptureListing(id client, id response) {
    Class bridge = NSClassFromString(@"ApolloContentBridge");
    if (!bridge || ![[NSUserDefaults standardUserDefaults] boolForKey:ApolloSiriEnabledKey]) return;
    NSData *payload = ApolloSiriListingData(response);
    if (!payload) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // An old account's network response must not repopulate the new account.
        if (client != ApolloActiveAccountClient()) return;
        NSString *account = ApolloSiriCurrentAccount();
        if (!account.length) return; // No collection during anonymous browsing.
        SEL receive = NSSelectorFromString(@"receiveListing:account:");
        if ([bridge respondsToSelector:receive]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(bridge, receive, payload, account);
        }
    });
}

// One bounded read through Apollo's own authenticated RDK client. getPath is
// the GET specialization of taskWithMethod:path:parameters:completion:, whose
// completion is ^(NSHTTPURLResponse *, id responseObject, NSError *) — THREE
// arguments (same ABI ApolloCommentSubmitFailure.xm uses). A two-argument block
// here reads the JSON dictionary as the error and crashes on `error.code`.
// Keep authentication/token refresh inside Apollo, never copy credentials to Swift.
extern "C" id ApolloSiriFetchContent(NSString *kind, NSString *query, NSString *after,
                                      void (^completion)(NSData *, NSString *, NSInteger)) {
    if (![NSThread isMainThread] || !completion) return nil;
    id client = ApolloActiveAccountClient();
    NSString *account = [ApolloSiriCurrentAccount() copy];
    SEL get = NSSelectorFromString(@"getPath:parameters:completion:");
    if (!account.length || ![client respondsToSelector:get]) { completion(nil, nil, 1); return nil; }
    SEL remaining = NSSelectorFromString(@"rateLimitedRequestsRemaining");
    SEL used = NSSelectorFromString(@"rateLimitedRequestsUsed");
    SEL reset = NSSelectorFromString(@"timeUntilRateLimitReset");
    if ([client respondsToSelector:remaining] && [client respondsToSelector:used] && [client respondsToSelector:reset] &&
        ((NSUInteger (*)(id, SEL))objc_msgSend)(client, used) > 0 &&
        ((NSUInteger (*)(id, SEL))objc_msgSend)(client, remaining) == 0 &&
        ((double (*)(id, SEL))objc_msgSend)(client, reset) > 0) {
        completion(nil, nil, 2); return nil;
    }
    NSString *path = nil;
    NSMutableDictionary *parameters = [@{@"limit": @100, @"raw_json": @1} mutableCopy];
    if ([kind isEqualToString:@"search"]) {
        if (!query.length || query.length > 512) { completion(nil, nil, 4); return nil; }
        path = @"search";
        parameters[@"q"] = query;
        parameters[@"type"] = @"link";
        parameters[@"sort"] = @"relevance";
        parameters[@"include_over_18"] = @NO;
        parameters[@"limit"] = @25;
    } else if ([kind isEqualToString:@"subscriptions"]) {
        path = @"subreddits/mine/subscriber";
        if (after.length) {
            if (after.length > 80 || [after rangeOfCharacterFromSet:
                [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet]].location != NSNotFound) {
                completion(nil, nil, 4); return nil;
            }
            parameters[@"after"] = after;
        }
    } else { completion(nil, nil, 4); return nil; }
    void (^callback)(NSHTTPURLResponse *, id, NSError *) = ^(NSHTTPURLResponse *http, id response, NSError *error) {
        NSInteger status = [http isKindOfClass:NSHTTPURLResponse.class] ? http.statusCode : 0;
        BOOL failed = error != nil || (status != 0 && (status < 200 || status >= 300));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (client != ApolloActiveAccountClient() || ![account isEqualToString:ApolloSiriCurrentAccount()]) {
                completion(nil, nil, 5); return;
            }
            if (failed) {
                BOOL limited = status == 429 || ([error isKindOfClass:NSError.class] && error.code == 429);
                completion(nil, nil, limited ? 2 : 3); return;
            }
            NSData *payload = ApolloSiriListingData(response);
            if (!payload) { completion(nil, nil, 4); return; }
            // ApolloSiriListingData validated response and response[@"data"] as dictionaries.
            id next = ((NSDictionary *)response)[@"data"][@"after"];
            completion(payload, [next isKindOfClass:NSString.class] ? next : nil, 0);
        });
    };
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)(client, get, path, parameters, callback);
}

static void ApolloSiriChangeEligibility(id client, NSArray *identifiers, BOOL allow) {
    if (!identifiers.count || !NSClassFromString(@"ApolloContentBridge")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (client != ApolloActiveAccountClient()) return;
        NSString *account = ApolloSiriCurrentAccount();
        if (!account.length) return;
        Class bridge = NSClassFromString(@"ApolloContentBridge");
        SEL selector = NSSelectorFromString(allow ? @"allowIdentifiers:account:" : @"suppressIdentifiers:account:");
        if ([bridge respondsToSelector:selector]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(bridge, selector, identifiers, account);
        }
    });
}

static NSString *ApolloSiriPostFullName(id object) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), "link");
    id link = ivar ? object_getIvar(object, ivar) : nil;
    SEL selector = @selector(fullName);
    if (![link respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(link, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static void ApolloSiriAnnotateView(UIView *view, NSString *fullName, NSUserActivity *activity, BOOL detail) {
    Class bridge = NSClassFromString(@"ApolloOnscreenBridge");
    if (!bridge || !view) return;
    if (!fullName) {
        SEL hide = NSSelectorFromString(@"hideView:");
        if ([bridge respondsToSelector:hide]) ((void (*)(id, SEL, id))objc_msgSend)(bridge, hide, view);
        return;
    }
    SEL show = NSSelectorFromString(@"showPost:inView:activity:detail:");
    if ([bridge respondsToSelector:show]) {
        ((void (*)(id, SEL, id, id, id, BOOL))objc_msgSend)(bridge, show, fullName, view, activity, detail);
    }
}

static void ApolloSiriAnnotateNode(id node, BOOL visible) {
    if (![NSThread isMainThread] || !NSClassFromString(@"ApolloOnscreenBridge")) return;
    // Visible-state callbacks run after ASDK loads the view; don't create one
    // when clearing a node which was never loaded.
    SEL loaded = NSSelectorFromString(@"isNodeLoaded");
    if (![node respondsToSelector:loaded] || !((BOOL (*)(id, SEL))objc_msgSend)(node, loaded)) return;
    UIView *view = ((id (*)(id, SEL))objc_msgSend)(node, @selector(view));
    ApolloSiriAnnotateView(view, visible ? ApolloSiriPostFullName(node) : nil, nil, NO);
}

// MARK: - Session context (opened post + loaded comments)
//
// Memory-only context in the Siri framework so onscreen annotations resolve for
// ANY post the person opens (not only ones a listing captured) and for the
// comments Apollo already loaded. Nothing here makes a network request; values
// come from Apollo's own model objects and mirror Reddit's JSON keys so the
// Swift side reuses one parser with the same eligibility rules.

static id ApolloSiriSend(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static void ApolloSiriSetString(NSMutableDictionary *dict, NSString *key, id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class]) return;
    dict[key] = [value length] > limit ? [value substringToIndex:limit] : value;
}

static void ApolloSiriSetInteger(NSMutableDictionary *dict, NSString *key, id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) dict[key] = @(((long long (*)(id, SEL))objc_msgSend)(object, selector));
}

static void ApolloSiriSetBool(NSMutableDictionary *dict, NSString *key, id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) dict[key] = @(((BOOL (*)(id, SEL))objc_msgSend)(object, selector));
}

static void ApolloSiriSetCreated(NSMutableDictionary *dict, id object) {
    id created = ApolloSiriSend(object, @"createdUTC");
    if ([created isKindOfClass:NSDate.class]) dict[@"created_utc"] = @([(NSDate *)created timeIntervalSince1970]);
}

static void ApolloSiriForward(NSString *selectorName, id payloadObject) {
    Class bridge = NSClassFromString(@"ApolloContentBridge");
    SEL selector = NSSelectorFromString(selectorName);
    if (!bridge || ![bridge respondsToSelector:selector]) return;
    NSString *account = ApolloSiriCurrentAccount();
    if (!account.length) return; // No context during anonymous browsing.
    NSData *payload = [NSJSONSerialization dataWithJSONObject:payloadObject options:0 error:nil];
    if (payload) ((void (*)(id, SEL, id, id))objc_msgSend)(bridge, selector, payload, account);
}

static void ApolloSiriObserveOpenedPost(id link) {
    if (![NSThread isMainThread] || !link || ![[NSUserDefaults standardUserDefaults] boolForKey:ApolloSiriEnabledKey]) return;
    NSString *fullName = ApolloSiriSend(link, @"fullName");
    if (![fullName isKindOfClass:NSString.class] || !fullName.length) return;
    NSMutableDictionary *post = [@{@"kind": @"t3", @"name": fullName} mutableCopy];
    ApolloSiriSetString(post, @"title", ApolloSiriSend(link, @"title"), 512);
    ApolloSiriSetString(post, @"selftext", ApolloSiriSend(link, @"selfText"), 2048);
    ApolloSiriSetString(post, @"author", ApolloSiriSend(link, @"author"), 64);
    ApolloSiriSetString(post, @"subreddit", ApolloSiriSend(link, @"subreddit"), 64);
    ApolloSiriSetString(post, @"subreddit_type", ApolloSiriSend(link, @"subredditType"), 32);
    ApolloSiriSetString(post, @"domain", ApolloSiriSend(link, @"domain"), 253);
    ApolloSiriSetBool(post, @"over_18", link, @"NSFW");
    ApolloSiriSetBool(post, @"hidden", link, @"hidden");
    ApolloSiriSetInteger(post, @"score", link, @"score");
    ApolloSiriSetInteger(post, @"num_comments", link, @"totalComments");
    ApolloSiriSetCreated(post, link);
    ApolloSiriForward(@"observePost:account:", post);
}

// Texture loads comment cells ahead of the visible range. Capture those
// loaded comments (not the entire fetched tree), coalescing a burst into one
// hand-off; cap per flush like the listing allowlist.
static NSMutableArray *sApolloSiriPendingComments;
static NSUInteger sApolloSiriCommentOrder;
static BOOL sApolloSiriCommentFlushScheduled;

static void ApolloSiriFlushComments(void) {
    sApolloSiriCommentFlushScheduled = NO;
    NSArray *batch = [sApolloSiriPendingComments copy];
    [sApolloSiriPendingComments removeAllObjects];
    for (NSUInteger start = 0; start < batch.count; start += 500) {
        ApolloSiriForward(@"observeComments:account:", [batch subarrayWithRange:NSMakeRange(start, MIN(500, batch.count - start))]);
    }
}

static void ApolloSiriObserveComment(id comment) {
    if (![NSThread isMainThread] || !comment || !NSClassFromString(@"ApolloContentBridge") ||
        ![[NSUserDefaults standardUserDefaults] boolForKey:ApolloSiriEnabledKey]) return;
    NSString *fullName = ApolloSiriSend(comment, @"fullName");
    NSString *linkID = ApolloSiriSend(comment, @"linkID");
    if (![fullName isKindOfClass:NSString.class] || ![linkID isKindOfClass:NSString.class]) return;
    NSMutableDictionary *record = [@{@"name": fullName, @"link_id": linkID,
                                     @"order": @(sApolloSiriCommentOrder++)} mutableCopy];
    ApolloSiriSetString(record, @"subreddit", ApolloSiriSend(comment, @"subreddit"), 64);
    ApolloSiriSetString(record, @"author", ApolloSiriSend(comment, @"author"), 64);
    ApolloSiriSetString(record, @"body", ApolloSiriSend(comment, @"body"), 2000);
    ApolloSiriSetInteger(record, @"score", comment, @"score");
    ApolloSiriSetInteger(record, @"depth", comment, @"depth");
    ApolloSiriSetCreated(record, comment);
    NSString *author = record[@"author"], *linkAuthor = ApolloSiriSend(comment, @"linkAuthor");
    record[@"is_submitter"] = @([linkAuthor isKindOfClass:NSString.class] && author.length &&
                                [author caseInsensitiveCompare:linkAuthor] == NSOrderedSame);
    if (!sApolloSiriPendingComments) sApolloSiriPendingComments = [NSMutableArray array];
    if (sApolloSiriPendingComments.count >= 2000) return;
    [sApolloSiriPendingComments addObject:record];
    if (sApolloSiriCommentFlushScheduled) return;
    sApolloSiriCommentFlushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSiriFlushComments();
    });
}

static void ApolloSiriAnnotateCommentNode(id node, BOOL visible) {
    Class bridge = NSClassFromString(@"ApolloOnscreenBridge");
    if (![NSThread isMainThread] || !bridge) return;
    SEL loaded = NSSelectorFromString(@"isNodeLoaded");
    if (![node respondsToSelector:loaded] || !((BOOL (*)(id, SEL))objc_msgSend)(node, loaded)) return;
    UIView *view = ((id (*)(id, SEL))objc_msgSend)(node, @selector(view));
    Ivar ivar = class_getInstanceVariable(object_getClass(node), "comment");
    id comment = ivar ? object_getIvar(node, ivar) : nil;
    NSString *fullName = visible ? ApolloSiriSend(comment, @"fullName") : nil;
    if (![fullName isKindOfClass:NSString.class]) {
        SEL hide = NSSelectorFromString(@"hideView:");
        if (view && [bridge respondsToSelector:hide]) ((void (*)(id, SEL, id))objc_msgSend)(bridge, hide, view);
        return;
    }
    SEL show = NSSelectorFromString(@"showComment:inView:");
    if (view && [bridge respondsToSelector:show]) ((void (*)(id, SEL, id, id))objc_msgSend)(bridge, show, fullName, view);
}

static char ApolloSiriDetailVisibleKey;
static void ApolloSiriAnnotateDetail(UIViewController *controller) {
    if (![NSThread isMainThread] || ![objc_getAssociatedObject(controller, &ApolloSiriDetailVisibleKey) boolValue]) return;
    ApolloSiriAnnotateView(controller.viewIfLoaded, ApolloSiriPostFullName(controller), controller.userActivity, YES);
}

%group ApolloSiriContentHooks
%hook RDKClient
- (NSArray *)objectsFromListingResponse:(id)response {
    NSArray *result = %orig;
    ApolloSiriCaptureListing(self, response);
    return result;
}

// All native single/bulk hide and subscribe wrappers converge here. Observe
// their existing request; never issue an additional mutation. Its completion
// ABI is ^(NSError *), as documented by ApolloSubredditHeaders' native RE.
- (id)basicPostTaskWithPath:(id)path parameters:(id)parameters completion:(id)completion {
    if (!NSClassFromString(@"ApolloContentBridge") ||
        ![[NSUserDefaults standardUserDefaults] boolForKey:ApolloSiriEnabledKey] ||
        ![path isKindOfClass:NSString.class] || ![parameters isKindOfClass:NSDictionary.class]) return %orig;
    NSString *route = [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    BOOL allow = [route isEqualToString:@"api/unhide"];
    NSString *ids = nil;
    BOOL names = NO;
    if ([route isEqualToString:@"api/hide"] || allow || [route isEqualToString:@"api/del"]) {
        ids = parameters[@"id"];
    } else if ([route isEqualToString:@"api/subscribe"]) {
        NSString *action = parameters[@"action"];
        if (!([action isEqual:@"sub"] || [action isEqual:@"unsub"])) return %orig;
        allow = [action isEqual:@"sub"];
        names = [parameters[@"sr_name"] isKindOfClass:NSString.class];
        ids = parameters[names ? @"sr_name" : @"sr"];
    }
    if (![ids isKindOfClass:NSString.class] || !ids.length || ids.length > 200000) return %orig;
    NSMutableArray *identifiers = [NSMutableArray array];
    for (NSString *identifier in [ids componentsSeparatedByString:@","]) {
        if (identifiers.count >= 2000) break;
        [identifiers addObject:names ? [@"r/" stringByAppendingString:identifier] : identifier];
    }
    if (!allow) {
        // Conservative removal starts when the user requests it, even if the
        // network fails. Persistent tombstones reject older listing responses.
        ApolloSiriChangeEligibility(self, identifiers, NO);
        return %orig;
    }
    void (^originalCompletion)(NSError *) = completion;
    // Logos self is unsafe-unretained; the asynchronous completion owns this
    // client until it has finished reading the request's account context.
    id client = self;
    void (^wrapped)(NSError *) = ^(NSError *error) {
        if (!error) ApolloSiriChangeEligibility(client, identifiers, YES);
        if (originalCompletion) originalCompletion(error);
    };
    return %orig(path, parameters, wrapped);
}
%end
%end

%group ApolloSiriOnscreenHooks
%hook _TtC6Apollo22CommentsViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    objc_setAssociatedObject(self, &ApolloSiriDetailVisibleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Ivar linkIvar = class_getInstanceVariable(object_getClass(self), "link");
    ApolloSiriObserveOpenedPost(linkIvar ? object_getIvar(self, linkIvar) : nil);
    ApolloSiriAnnotateDetail((UIViewController *)self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    // Read/annotation only: no frame, bounds or layout-driving writes.
    ApolloSiriAnnotateDetail((UIViewController *)self);
}
- (void)viewWillDisappear:(BOOL)animated {
    objc_setAssociatedObject(self, &ApolloSiriDetailVisibleKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSiriAnnotateView(((UIViewController *)self).viewIfLoaded, nil, nil, YES);
    %orig;
}
%end
// The post header row in the detail screen (Apple: annotate the header with
// the container entity, separately from the comment rows below it).
%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didEnterVisibleState { %orig; ApolloSiriAnnotateNode(self, YES); }
- (void)didExitVisibleState { ApolloSiriAnnotateNode(self, NO); %orig; }
%end
%hook _TtC6Apollo15CommentCellNode
// Swift's designated CommentSectionController initializer bypasses ObjC
// -init, so that hook never captured comments. Texture's didLoad runs for
// each loaded cell, including cells prepared ahead of the visible range.
- (void)didLoad {
    %orig;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:ApolloSiriEnabledKey]) return;
    // A queued block must not retain Logos' unsafe-unretained self. Cells can
    // disappear during collapse/scroll churn before the main queue drains.
    __weak id weakNode = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id node = weakNode;
        Ivar ivar = node ? class_getInstanceVariable(object_getClass(node), "comment") : NULL;
        ApolloSiriObserveComment(ivar ? object_getIvar(node, ivar) : nil);
    });
}
- (void)didEnterVisibleState { %orig; ApolloSiriAnnotateCommentNode(self, YES); }
- (void)didExitVisibleState { ApolloSiriAnnotateCommentNode(self, NO); %orig; }
%end
%hook _TtC6Apollo17LargePostCellNode
- (void)didEnterVisibleState { %orig; ApolloSiriAnnotateNode(self, YES); }
- (void)didExitVisibleState { ApolloSiriAnnotateNode(self, NO); %orig; }
%end
%hook _TtC6Apollo19CompactPostCellNode
- (void)didEnterVisibleState { %orig; ApolloSiriAnnotateNode(self, YES); }
- (void)didExitVisibleState { ApolloSiriAnnotateNode(self, NO); %orig; }
%end
%end

%ctor {
    // dyld maps launch images and registers their ObjC classes before running
    // initializers. Normal IPAs do not embed this optional framework, so they
    // should not install Siri hooks on feeds, comments or network parsing.
    if (!NSClassFromString(@"ApolloContentBridge")) return;
    %init(ApolloSiriContentHooks);
    %init(ApolloSiriOnscreenHooks);
}
