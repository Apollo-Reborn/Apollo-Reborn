// ApolloOfflinePages.xm: see ApolloOfflinePages.h.

#import <SafariServices/SafariServices.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloOfflineMode.h"
#import "ApolloOfflinePages.h"

// MARK: - Saving

// While saving, leave out what makes news pages 10-20 MB and does nothing
// offline: third-party scripts, frames and requests (ads, trackers, embeds),
// plus fonts, audio/video and pings. The article's own HTML, styles and
// images still load.
static NSString *const kApolloOfflineSaveRules = @"["
    "{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"script\",\"document\",\"raw\"],\"load-type\":[\"third-party\"]},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"font\",\"media\",\"popup\",\"websocket\",\"ping\"]},\"action\":{\"type\":\"block\"}}"
    "]";

// Run just before archiving: the rendered page stays, everything that would
// run, play or frame other sites offline goes (and so do its resources).
// Consent dialogs, paywall nags and pinned banners are removed too: their
// buttons need scripts, so offline they'd cover the article for good.
static NSString *const kApolloOfflineCleanupScript =
    @"(function(){"
     "document.querySelectorAll('script,noscript,iframe,video,audio,object,embed,link[rel=preload],link[rel=prefetch]')"
     ".forEach(function(e){e.remove();});"
     // Never the page itself: sites put consent class names on <html>, and
     // some wrap the whole article in a fixed container.
     "var keep=function(e){return e===document.documentElement||e===document.body||"
     "!!e.querySelector('article,main,h1,[itemprop=articleBody]');};"
     "document.querySelectorAll('body [aria-modal=true],body [role=dialog],body [id*=consent i],body [class*=consent i],"
     "body [id*=onetrust i],body [class*=onetrust i],body [id^=sp_message],body [class*=cookie-banner i],"
     "body [id*=cookie-banner i],body [class*=modal-backdrop i]')"
     ".forEach(function(e){if(!keep(e))e.remove();});"
     "Array.prototype.forEach.call(document.querySelectorAll('body *'),function(e){"
     "if(!e.isConnected||keep(e))return;var s=getComputedStyle(e);"
     "if(s.position==='fixed'||(s.position==='sticky'&&((parseInt(s.zIndex,10)||0)>=10||e.offsetHeight>window.innerHeight*0.3))){e.remove();}"
     "});"
     "[document.documentElement,document.body].forEach(function(e){if(!e)return;"
     "e.style.setProperty('overflow','auto','important');e.style.setProperty('position','static','important');"
     "e.style.setProperty('height','auto','important');});"
     "document.querySelectorAll('img[loading=lazy]').forEach(function(i){i.removeAttribute('loading');});"
     "return true;})();";

static WKContentRuleList *sApolloOfflineSaveRuleList;
static BOOL sApolloOfflineSaveRulesSettled; // compiled or failed

// Up to kApolloOfflinePageWorkers off-screen web views loading pages side by
// side (each is its own web content process). Main thread only.
static const NSUInteger kApolloOfflinePageWorkers = 3;

@class ApolloOfflinePageSaver;

// One off-screen web view, one page at a time.
@interface ApolloOfflinePageWorker : NSObject <WKNavigationDelegate>
@property (nonatomic, weak) ApolloOfflinePageSaver *saver;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) void (^current)(NSData *);
@property (nonatomic) NSUInteger generation;
- (void)load:(NSURL *)url done:(void (^)(NSData *))done;
- (void)stop;
@end

@interface ApolloOfflinePageSaver : NSObject
@property (nonatomic, strong) NSMutableArray<NSArray *> *queue; // @[ url, done ]
@property (nonatomic, strong) NSMutableArray<ApolloOfflinePageWorker *> *workers;
@property (nonatomic) BOOL waitingForRules;
+ (instancetype)shared;
- (void)workerFinished:(ApolloOfflinePageWorker *)worker;
@end

@implementation ApolloOfflinePageWorker

- (WKWebView *)makeWebView {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // A throwaway store: saving pages leaves no cookies or site data behind.
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll; // never play sound
    configuration.allowsInlineMediaPlayback = YES;
    if (sApolloOfflineSaveRuleList) [configuration.userContentController addContentRuleList:sApolloOfflineSaveRuleList];
    // Phone-sized, so the archive is the page's mobile layout.
    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 390, 844) configuration:configuration];
    webView.navigationDelegate = self;
    webView.userInteractionEnabled = NO;
    webView.accessibilityElementsHidden = YES;
    return webView;
}

- (void)load:(NSURL *)url done:(void (^)(NSData *))done {
    self.current = done;
    NSUInteger generation = ++self.generation;
    if (!self.webView) self.webView = [self makeWebView];
    // In the window but off screen, so WebKit doesn't throttle it as hidden.
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (window && self.webView.superview != window) {
        self.webView.frame = CGRectMake(-4000, 0, 390, 844);
        [window insertSubview:self.webView atIndex:0];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 20;
    [self.webView loadRequest:request];
    // Pages full of trackers may never "finish": archive what's there at 20 s.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.generation != generation || !self.current) return;
        [self.webView stopLoading];
        [self archiveGeneration:generation];
    });
}

// Drops the page being loaded (its caller gets nil) and the web view.
- (void)stop {
    [self.webView stopLoading];
    [self.webView removeFromSuperview];
    self.webView = nil;
    [self finish:nil generation:self.generation];
}

- (void)finish:(NSData *)archive generation:(NSUInteger)generation {
    if (self.generation != generation || !self.current) return;
    void (^done)(NSData *) = self.current;
    self.current = nil;
    done(archive);
    [self.saver workerFinished:self];
}

- (void)archiveGeneration:(NSUInteger)generation {
    if (self.generation != generation || !self.current) return;
    if (self.webView.URL == nil || self.webView.title.length == 0) {
        [self finish:nil generation:generation];
        return;
    }
    WKWebView *webView = self.webView;
    [webView evaluateJavaScript:kApolloOfflineCleanupScript completionHandler:^(__unused id result, __unused NSError *scriptError) {
        if (self.generation != generation || !self.current) return;
        [webView createWebArchiveDataWithCompletionHandler:^(NSData *data, NSError *error) {
            if (error) ApolloLog(@"[Offline] page archive failed: %@", error.localizedDescription);
            [self finish:error ? nil : data generation:generation];
        }];
    }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSUInteger generation = self.generation;
    // A moment for late images and layout scripts.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self archiveGeneration:generation];
    });
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    [self finish:nil generation:self.generation];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    [self archiveGeneration:self.generation];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self.webView removeFromSuperview];
    self.webView = nil;
    [self finish:nil generation:self.generation];
}

// Only the page itself: no app links or downloads while saving.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *scheme = action.request.URL.scheme.lowercaseString;
    BOOL web = [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"about"];
    decisionHandler(web && !action.shouldPerformDownload ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

@end

@implementation ApolloOfflinePageSaver

+ (instancetype)shared {
    static ApolloOfflinePageSaver *saver;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        saver = [ApolloOfflinePageSaver new];
        saver.queue = [NSMutableArray array];
        saver.workers = [NSMutableArray array];
        for (NSUInteger i = 0; i < kApolloOfflinePageWorkers; i++) {
            ApolloOfflinePageWorker *worker = [ApolloOfflinePageWorker new];
            worker.saver = saver;
            [saver.workers addObject:worker];
        }
        [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"ApolloOfflineSaveRules"
                                                         encodedContentRuleList:kApolloOfflineSaveRules
                                                              completionHandler:^(WKContentRuleList *list, NSError *error) {
            if (error) ApolloLog(@"[Offline] page rules didn't compile: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                sApolloOfflineSaveRuleList = list;
                sApolloOfflineSaveRulesSettled = YES;
            });
        }];
    });
    return saver;
}

- (void)enqueue:(NSURL *)url done:(void (^)(NSData *))done {
    [self.queue addObject:@[ url, [done copy] ]];
    if (!self.waitingForRules) [self next];
}

- (void)next {
    // The save rules compile once, asynchronously; give them a moment so the
    // first pages aren't saved without them.
    static NSUInteger waits;
    if (!sApolloOfflineSaveRulesSettled && waits < 30 && self.queue.count > 0) {
        waits++;
        self.waitingForRules = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.waitingForRules = NO;
            [self next];
        });
        return;
    }
    for (ApolloOfflinePageWorker *worker in self.workers) {
        if (self.queue.count == 0) break;
        if (worker.current) continue;
        NSArray *item = self.queue.firstObject;
        [self.queue removeObjectAtIndex:0];
        [worker load:item[0] done:item[1]];
    }
}

- (void)workerFinished:(ApolloOfflinePageWorker *)worker {
    if (self.queue.count > 0) {
        [self next];
        return;
    }
    // Nothing left for it: let the web view (and its web content process) go.
    [worker.webView removeFromSuperview];
    worker.webView = nil;
}

- (void)cancelAll {
    NSArray<NSArray *> *queued = [self.queue copy];
    [self.queue removeAllObjects];
    for (NSArray *item in queued) ((void (^)(NSData *))item[1])(nil);
    for (ApolloOfflinePageWorker *worker in self.workers) {
        if (worker.current) [worker stop];
    }
}

@end

void ApolloOfflineSaveWebPage(NSURL *url, void (^done)(NSData *archive)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ApolloOfflinePageSaver shared] enqueue:url done:^(NSData *archive) {
            ApolloLog(@"[Offline] page %@ %@", url.host ?: @"?",
                      archive ? [NSString stringWithFormat:@"saved (%lu bytes)", (unsigned long)archive.length] : @"not saved");
            done(archive);
        }];
    });
}

void ApolloOfflineCancelWebPageSaves(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[ApolloOfflinePageSaver shared] cancelAll]; });
}

// MARK: - Reading offline

@interface ApolloOfflinePageViewController : UIViewController <WKNavigationDelegate>
- (instancetype)initWithURL:(NSURL *)url archive:(NSData *)archive;
@end

@implementation ApolloOfflinePageViewController {
    NSURL *_url;
    NSData *_archive;
    WKWebView *_webView;
}

- (instancetype)initWithURL:(NSURL *)url archive:(NSData *)archive {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _url = url;
        _archive = archive;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    _webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _webView.navigationDelegate = self;
    [self.view addSubview:_webView];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self action:@selector(close)];
    self.navigationItem.title = _url.host;
    self.navigationItem.prompt = @"Saved for offline";
    [_webView loadData:_archive MIMEType:@"application/x-webarchive" characterEncodingName:@"utf-8" baseURL:_url];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView.title.length > 0) self.navigationItem.title = webView.title;
}

// Links inside the page open another saved page if there is one; otherwise
// say it isn't saved rather than failing silently.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (action.navigationType != WKNavigationTypeLinkActivated) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    decisionHandler(WKNavigationActionPolicyCancel);
    NSURL *target = action.request.URL;
    NSData *saved = target ? [[ApolloOfflineLibrary sharedLibrary] pageArchiveForURL:target] : nil;
    if (saved) {
        [self.navigationController pushViewController:[[ApolloOfflinePageViewController alloc] initWithURL:target archive:saved] animated:YES];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Not Saved for Offline"
                                                                   message:@"This link wasn't part of your offline download. It'll open once you're back online."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static const void *kApolloOfflineSafariURLKey = &kApolloOfflineSafariURLKey;

// The saved-page reader for `url`, while serving, or nil.
static UIViewController *ApolloOfflinePageReaderForURL(NSURL *url) {
    if (!ApolloOfflineModeIsServing() || !url) return nil;
    NSData *archive = [[ApolloOfflineLibrary sharedLibrary] pageArchiveForURL:url];
    ApolloLog(@"[Offline] link %@: %@", url.host ?: @"?", archive ? @"opening the saved page" : @"not saved");
    if (!archive) return nil;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:
        [[ApolloOfflinePageViewController alloc] initWithURL:url archive:archive]];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    return navigation;
}

// The saved-page reader to show instead of `controller` (Apollo's in-app
// browser), while serving.
static UIViewController *ApolloOfflinePageReplacement(UIViewController *controller) {
    if (!ApolloOfflineModeIsServing() || ![controller isKindOfClass:[SFSafariViewController class]]) return nil;
    return ApolloOfflinePageReaderForURL(objc_getAssociatedObject(controller, kApolloOfflineSafariURLKey));
}

static UIViewController *ApolloOfflineTopViewController(void) {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

%hook SFSafariViewController

- (instancetype)initWithURL:(NSURL *)URL configuration:(SFSafariViewControllerConfiguration *)configuration {
    SFSafariViewController *controller = %orig;
    if (controller && URL) objc_setAssociatedObject(controller, kApolloOfflineSafariURLKey, URL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return controller;
}

- (instancetype)initWithURL:(NSURL *)URL entersReaderIfAvailable:(BOOL)entersReaderIfAvailable {
    SFSafariViewController *controller = %orig;
    if (controller && URL) objc_setAssociatedObject(controller, kApolloOfflineSafariURLKey, URL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return controller;
}

%end

// Apollo's "open links in Safari" setting hands the URL to the Safari app,
// which offline would only show an error: open the saved page here instead.
%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {
    NSString *scheme = url.scheme.lowercaseString;
    UIViewController *reader = ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])
        ? ApolloOfflinePageReaderForURL(url) : nil;
    UIViewController *top = reader ? ApolloOfflineTopViewController() : nil;
    if (reader && top) {
        [top presentViewController:reader animated:YES completion:nil];
        if (completion) completion(YES);
        return;
    }
    %orig;
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(void (^)(void))completion {
    UIViewController *replacement = ApolloOfflinePageReplacement(controller);
    if (replacement) {
        %orig(replacement, animated, completion);
        return;
    }
    %orig;
}

%end
