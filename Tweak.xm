#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/utsname.h>
#import <Security/Security.h>

#import "fishhook.h"
#import "ApolloCommon.h"
#import "ApolloRedditMediaUpload.h"
#import "ApolloState.h"
#import "Tweak.h"
#import "CustomAPIViewController.h"
#import "UserDefaultConstants.h"
#import "Defaults.h"
#import "UIWindow+Apollo.h"

// MARK: - Sideload Fixes

static NSDictionary *stripGroupAccessAttr(CFDictionaryRef attributes) {
    NSMutableDictionary *newAttributes = [[NSMutableDictionary alloc] initWithDictionary:(__bridge id)attributes];
    [newAttributes removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return newAttributes;
}

// Ultra/Pro status: Valet (SharedGroupValet) stores these in the keychain.
// Key names are obfuscated. Valet's internal service name includes the full initializer description.
static NSString *const kValetServiceSubstring = @"com.christianselig.Apollo";

// Map of obfuscated Valet account keys -> override values (from RE of isApolloUltraEnabled/isApolloProEnabled)
static NSString *ValetOverrideValue(NSString *account) {
    static NSDictionary *overrideMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrideMap = @{
            @"meganotifs":              @"affirmative", // Ultra
            @"seconds_since2":          @"1473982",     // Pro
            @"rep_seconds_since2":      @"1473982",     // Pro (alternate?)
            @"pixelpalfoodtokensgiven": @"affirmative", // Community icons
            @"rep_seconds_after2":      @"1482118",     // SPCA Animals icon pack
        };
    });
    return overrideMap[account];
}

static BOOL IsValetQuery(NSDictionary *query) {
    NSString *service = query[(__bridge id)kSecAttrService];
    return service && [service containsString:kValetServiceSubstring];
}

static BOOL IsUltraProOverrideKey(NSDictionary *query) {
    NSString *account = query[(__bridge id)kSecAttrAccount];
    if (!account) return NO;
    if (!IsValetQuery(query)) return NO;
    return ValetOverrideValue(account) != nil;
}

static NSData *OverrideDataForAccount(NSString *account) {
    NSString *value = ValetOverrideValue(account);
    return [value dataUsingEncoding:NSUTF8StringEncoding];
}

static void *SecItemAdd_orig;
static OSStatus SecItemAdd_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemAdd_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemCopyMatching_orig;
static OSStatus SecItemCopyMatching_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);

    // Intercept Ultra/Pro Valet reads and return override values
    if (IsUltraProOverrideKey(strippedQuery)) {
        NSString *account = strippedQuery[(__bridge id)kSecAttrAccount];
        if (result) {
            NSData *overrideData = OverrideDataForAccount(account);
            if (strippedQuery[(__bridge id)kSecReturnAttributes]) {
                *result = (__bridge_retained CFTypeRef)@{
                    (__bridge id)kSecAttrAccount: account,
                    (__bridge id)kSecValueData: overrideData,
                };
            } else {
                *result = (__bridge_retained CFTypeRef)overrideData;
            }
        }
        return errSecSuccess;
    }

    return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemCopyMatching_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemUpdate_orig;
static OSStatus SecItemUpdate_replacement(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);

    // Block attempts to disable Ultra/Pro
    if (IsUltraProOverrideKey(strippedQuery)) {
        return errSecSuccess;
    }

    return ((OSStatus (*)(CFDictionaryRef, CFDictionaryRef))SecItemUpdate_orig)((__bridge CFDictionaryRef)strippedQuery, attributesToUpdate);
}

// --- Device detection (for Pixel Pals and Dynamic Island behaviour) ---
// Apollo's device model mapper (sub_1007a3cdc) only recognizes models up to iPhone 14 Pro Max.
// Newer models return "unknown" (0x3f) and get no Pixel Pals.
// Remap newer machine identifiers to "iPhone15,2" (iPhone 14 Pro) so Apollo
// treats them as Dynamic Island devices and enables full Pixel Pals + FauxCutOutView.
static void *uname_orig;
static int uname_replacement(struct utsname *buf) {
    int ret = ((int (*)(struct utsname *))uname_orig)(buf);
    if (ret != 0) return ret;

    // iPhone15,4+ are all unrecognized by Apollo's mapper.
    // Map Dynamic Island models to iPhone15,2 (iPhone 14 Pro) and notch models to iPhone14,7 (iPhone 14)
    static NSDictionary *modelRemap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *di    = @"iPhone15,2";  // iPhone 14 Pro (Dynamic Island)
        NSString *notch = @"iPhone14,7";  // iPhone 14 (notch)

        modelRemap = @{
            @"iPhone15,4": di,    // iPhone 15
            @"iPhone15,5": di,    // iPhone 15 Plus
            @"iPhone16,1": di,    // iPhone 15 Pro
            @"iPhone16,2": di,    // iPhone 15 Pro Max
            @"iPhone17,1": di,    // iPhone 16 Pro
            @"iPhone17,2": di,    // iPhone 16 Pro Max
            @"iPhone17,3": di,    // iPhone 16
            @"iPhone17,4": di,    // iPhone 16 Plus
            @"iPhone17,5": notch, // iPhone 16e
            @"iPhone18,1": di,    // iPhone 17 Pro
            @"iPhone18,2": di,    // iPhone 17 Pro Max
            @"iPhone18,3": di,    // iPhone 17
            @"iPhone18,4": di,    // iPhone Air
            @"iPhone18,5": notch, // iPhone 17e
        };
    });

    NSString *machine = @(buf->machine);
    NSString *remap = modelRemap[machine];
    if (remap) {
        strlcpy(buf->machine, remap.UTF8String, sizeof(buf->machine));
    }
    return ret;
}

// MARK: - API / Network

static NSString *const announcementUrl = @"apollogur.download/api/apollonouncement";

static NSArray *const blockedUrls = @[
    @"apollopushserver.xyz",
    @"beta.apollonotifications.com",
    @"apolloreq.com",
    @"notify.bugsnag.com",
    @"sessions.bugsnag.com",
    @"api.mixpanel.com",
    @"api.statsig.com",
    @"telemetrydeck.com",
    @"apollogur.download/api/easter_sale",
    @"apollogur.download/api/html_codes",
    @"apollogur.download/api/refund_screen_config",
    @"apollogur.download/api/goodbye_wallpaper"
];

// Cache storing subreddit list source URLs -> response body
static NSCache<NSString *, NSString *> *subredditListCache;
static NSString *sLatestRedditBearerToken = nil;
static NSMutableDictionary<NSString *, NSString *> *sRedditUploadAssetIDByURL = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *sRedditUploadInfoByAssetID = nil;
static NSMutableSet<NSString *> *sRedditCommentDiagnosticDelegateClasses = nil;
static NSString *sRecentRedditNativeSubmitAssetID = nil;
static NSString *sRecentRedditNativeSubmitSubreddit = nil;
static NSString *sRecentRedditNativeSubmitTitle = nil;
static NSString *sRecentRedditNativeSubmitWebSocketURL = nil;
static NSString *sRecentRedditNativeSubmitUserSubmittedPage = nil;
static NSString *sRecentRedditNativeSubmitPermalink = nil;
static NSString *sRecentRedditNativeSubmitFullName = nil;
static NSDate *sRecentRedditNativeSubmitSuccessUntil = nil;
static BOOL sRecentRedditNativeSubmitResolverStarted = NO;
static BOOL sRecentRedditNativeSubmitBannerShown = NO;
static UIView *sRedditNativeSubmitBanner = nil;
static char kApolloRedditCommentResponseDataKey;
static char kApolloRedditSubmitResponseDataKey;

static NSTimeInterval const kApolloRecentRedditNativeSubmitSuccessTTL = 30.0;

static NSObject *ApolloRedditUploadAssetMapLock(void);
static NSString *ApolloFormEncodeComponent(NSString *component);
static void ApolloStartResolvingRedditNativeSubmitPermalink(NSDictionary *submitInfo);
static void ApolloShowRedditNativeSubmitBannerIfReady(void);

static void ApolloRecordSuccessfulRedditNativeSubmit(NSString *assetID, NSString *subreddit, NSString *title, NSString *webSocketURL, NSString *userSubmittedPage) {
    NSDate *expiresAt = [NSDate dateWithTimeIntervalSinceNow:kApolloRecentRedditNativeSubmitSuccessTTL];
    NSMutableDictionary *submitInfo = [NSMutableDictionary dictionary];
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        sRecentRedditNativeSubmitAssetID = [assetID copy];
        sRecentRedditNativeSubmitSubreddit = [subreddit copy];
        sRecentRedditNativeSubmitTitle = [title copy];
        sRecentRedditNativeSubmitWebSocketURL = [webSocketURL copy];
        sRecentRedditNativeSubmitUserSubmittedPage = [userSubmittedPage copy];
        sRecentRedditNativeSubmitPermalink = nil;
        sRecentRedditNativeSubmitFullName = nil;
        sRecentRedditNativeSubmitSuccessUntil = expiresAt;
        sRecentRedditNativeSubmitResolverStarted = NO;
        sRecentRedditNativeSubmitBannerShown = NO;

        if (sRecentRedditNativeSubmitAssetID.length > 0) submitInfo[@"assetID"] = sRecentRedditNativeSubmitAssetID;
        if (sRecentRedditNativeSubmitSubreddit.length > 0) submitInfo[@"subreddit"] = sRecentRedditNativeSubmitSubreddit;
        if (sRecentRedditNativeSubmitTitle.length > 0) submitInfo[@"title"] = sRecentRedditNativeSubmitTitle;
        if (sRecentRedditNativeSubmitWebSocketURL.length > 0) submitInfo[@"webSocketURL"] = sRecentRedditNativeSubmitWebSocketURL;
        if (sRecentRedditNativeSubmitUserSubmittedPage.length > 0) submitInfo[@"userSubmittedPage"] = sRecentRedditNativeSubmitUserSubmittedPage;
    }

    ApolloLog(@"[RedditUpload] Recorded native submit success marker assetID=%@ sr=%@ titlePresent=%@ websocket=%@ expiresIn=%.0fs",
              assetID.length > 0 ? assetID : @"(missing)",
              subreddit.length > 0 ? subreddit : @"(missing)",
              title.length > 0 ? @"yes" : @"no",
              webSocketURL.length > 0 ? @"yes" : @"no",
              kApolloRecentRedditNativeSubmitSuccessTTL);

    ApolloStartResolvingRedditNativeSubmitPermalink(submitInfo);
}

static NSDictionary *ApolloRecentSuccessfulRedditNativeSubmitInfo(void) {
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRecentRedditNativeSubmitSuccessUntil || [sRecentRedditNativeSubmitSuccessUntil timeIntervalSinceNow] <= 0) {
            sRecentRedditNativeSubmitAssetID = nil;
            sRecentRedditNativeSubmitSubreddit = nil;
            sRecentRedditNativeSubmitTitle = nil;
            sRecentRedditNativeSubmitWebSocketURL = nil;
            sRecentRedditNativeSubmitUserSubmittedPage = nil;
            sRecentRedditNativeSubmitPermalink = nil;
            sRecentRedditNativeSubmitFullName = nil;
            sRecentRedditNativeSubmitSuccessUntil = nil;
            sRecentRedditNativeSubmitResolverStarted = NO;
            sRecentRedditNativeSubmitBannerShown = NO;
            return nil;
        }

        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if (sRecentRedditNativeSubmitAssetID.length > 0) {
            info[@"assetID"] = sRecentRedditNativeSubmitAssetID;
        }
        if (sRecentRedditNativeSubmitSubreddit.length > 0) {
            info[@"subreddit"] = sRecentRedditNativeSubmitSubreddit;
        }
        if (sRecentRedditNativeSubmitTitle.length > 0) {
            info[@"title"] = sRecentRedditNativeSubmitTitle;
        }
        if (sRecentRedditNativeSubmitWebSocketURL.length > 0) {
            info[@"webSocketURL"] = sRecentRedditNativeSubmitWebSocketURL;
        }
        if (sRecentRedditNativeSubmitUserSubmittedPage.length > 0) {
            info[@"userSubmittedPage"] = sRecentRedditNativeSubmitUserSubmittedPage;
        }
        if (sRecentRedditNativeSubmitPermalink.length > 0) {
            info[@"permalink"] = sRecentRedditNativeSubmitPermalink;
        }
        if (sRecentRedditNativeSubmitFullName.length > 0) {
            info[@"fullName"] = sRecentRedditNativeSubmitFullName;
        }
        info[@"secondsRemaining"] = @([sRecentRedditNativeSubmitSuccessUntil timeIntervalSinceNow]);
        info[@"resolverStarted"] = @(sRecentRedditNativeSubmitResolverStarted);
        info[@"bannerShown"] = @(sRecentRedditNativeSubmitBannerShown);
        return info;
    }
}

static BOOL ApolloShouldSuppressFalseRedditNativeSubmitAlert(NSString *alertTitle, NSString *alertMessage, NSDictionary **outInfo) {
    if (!sUseRedditNativeImageUpload) {
        return NO;
    }
    if (![alertTitle isKindOfClass:[NSString class]] || ![alertMessage isKindOfClass:[NSString class]]) {
        return NO;
    }

    BOOL titleMatches = [alertTitle isEqualToString:@"Server Error"] || [alertTitle isEqualToString:@"Error Submitting"];
    BOOL messageMatches = [alertMessage rangeOfString:@"There was an error submitting" options:NSCaseInsensitiveSearch].location != NSNotFound &&
                          [alertMessage rangeOfString:@"post" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (!titleMatches || !messageMatches) {
        return NO;
    }

    NSDictionary *info = ApolloRecentSuccessfulRedditNativeSubmitInfo();
    if (!info) {
        return NO;
    }

    if (outInfo) {
        *outInfo = info;
    }
    return YES;
}

@interface ApolloRedditNativeSubmitBannerTarget : NSObject
@property (nonatomic, strong) NSURL *url;
@end

@implementation ApolloRedditNativeSubmitBannerTarget
- (void)bannerTapped:(id)sender {
    NSURL *url = self.url;
    if (sRedditNativeSubmitBanner) {
        UIView *banner = sRedditNativeSubmitBanner;
        sRedditNativeSubmitBanner = nil;
        [UIView animateWithDuration:0.18 animations:^{
            banner.alpha = 0.0;
            banner.transform = CGAffineTransformMakeTranslation(0.0, -16.0);
        } completion:^(__unused BOOL finished) {
            [banner removeFromSuperview];
        }];
    }
    if (url) {
        ApolloRouteResolvedURLViaApolloScheme(url);
    }
}
@end

static UIWindow *ApolloActiveKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }

    UIWindow *keyWindow = [[UIApplication sharedApplication] valueForKey:@"keyWindow"];
    if (keyWindow) {
        return keyWindow;
    }

    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

static NSURL *ApolloRedditPermalinkURLFromString(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) {
        return nil;
    }

    NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return nil;
    }

    NSString *urlString = trimmed;
    if ([urlString hasPrefix:@"/r/"] || [urlString hasPrefix:@"/comments/"]) {
        urlString = [@"https://reddit.com" stringByAppendingString:urlString];
    } else if ([urlString hasPrefix:@"//reddit.com"] || [urlString hasPrefix:@"//www.reddit.com"] || [urlString hasPrefix:@"//old.reddit.com"]) {
        urlString = [@"https:" stringByAppendingString:urlString];
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *host = components.host.lowercaseString;
    NSString *path = components.path;
    if (([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) && [path rangeOfString:@"/comments/"].location != NSNotFound) {
        components.scheme = @"https";
        components.host = @"reddit.com";
        return components.URL;
    }

    return nil;
}

static NSURL *ApolloRedditPermalinkURLFromObject(id object) {
    if ([object isKindOfClass:[NSString class]]) {
        return ApolloRedditPermalinkURLFromString((NSString *)object);
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        NSArray *preferredKeys = @[@"target_permalink", @"permalink", @"redirect", @"redirect_url", @"url", @"location"];
        for (NSString *key in preferredKeys) {
            NSURL *url = ApolloRedditPermalinkURLFromObject(dict[key]);
            if (url) return url;
        }
        for (id key in dict) {
            NSURL *url = ApolloRedditPermalinkURLFromObject(dict[key]);
            if (url) return url;
        }
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            NSURL *url = ApolloRedditPermalinkURLFromObject(item);
            if (url) return url;
        }
    }
    return nil;
}

static BOOL ApolloObjectContainsString(id object, NSString *needle) {
    if (needle.length == 0 || !object) {
        return NO;
    }
    if ([object isKindOfClass:[NSString class]]) {
        return [(NSString *)object rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)object) {
            if (ApolloObjectContainsString(key, needle) || ApolloObjectContainsString([(NSDictionary *)object objectForKey:key], needle)) {
                return YES;
            }
        }
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            if (ApolloObjectContainsString(item, needle)) {
                return YES;
            }
        }
    }
    return NO;
}

static NSString *ApolloUsernameFromSubmittedPage(NSString *userSubmittedPage) {
    NSURLComponents *components = [NSURLComponents componentsWithString:userSubmittedPage];
    NSArray<NSString *> *parts = components.path.pathComponents;
    for (NSUInteger index = 0; index + 1 < parts.count; index++) {
        NSString *part = parts[index];
        if ([part isEqualToString:@"user"] || [part isEqualToString:@"u"]) {
            NSString *username = parts[index + 1];
            return [username isEqualToString:@"/"] ? nil : username;
        }
    }
    return nil;
}

static BOOL ApolloListingPostMatchesNativeSubmit(NSDictionary *postData, NSDictionary *submitInfo) {
    if (![postData isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSString *assetID = [submitInfo[@"assetID"] isKindOfClass:[NSString class]] ? submitInfo[@"assetID"] : nil;
    if (assetID.length > 0 && ApolloObjectContainsString(postData, assetID)) {
        return YES;
    }

    NSString *title = [submitInfo[@"title"] isKindOfClass:[NSString class]] ? submitInfo[@"title"] : nil;
    NSString *postTitle = [postData[@"title"] isKindOfClass:[NSString class]] ? postData[@"title"] : nil;
    if (title.length == 0 || ![postTitle isEqualToString:title]) {
        return NO;
    }

    NSString *expectedAuthor = ApolloUsernameFromSubmittedPage(submitInfo[@"userSubmittedPage"]);
    NSString *postAuthor = [postData[@"author"] isKindOfClass:[NSString class]] ? postData[@"author"] : nil;
    return expectedAuthor.length == 0 || [postAuthor caseInsensitiveCompare:expectedAuthor] == NSOrderedSame;
}

static void ApolloShowRedditNativeSubmitBanner(NSURL *permalinkURL) {
    if (!permalinkURL) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = ApolloActiveKeyWindow();
        if (!window) {
            ApolloLog(@"[RedditUpload] Could not show native submit banner: no active window");
            return;
        }

        if (sRedditNativeSubmitBanner) {
            [sRedditNativeSubmitBanner removeFromSuperview];
            sRedditNativeSubmitBanner = nil;
        }

        CGFloat safeTop = window.safeAreaInsets.top;
        CGFloat margin = 14.0;
        CGFloat height = 46.0;
        UIControl *banner = [[UIControl alloc] initWithFrame:CGRectMake(margin, safeTop + 26.0, CGRectGetWidth(window.bounds) - margin * 2.0, height)];
        banner.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        banner.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:0.96];
        banner.layer.cornerRadius = height / 2.0;
        banner.layer.cornerCurve = kCACornerCurveContinuous;
        banner.layer.shadowColor = UIColor.blackColor.CGColor;
        banner.layer.shadowOpacity = 0.25;
        banner.layer.shadowRadius = 10.0;
        banner.layer.shadowOffset = CGSizeMake(0.0, 4.0);

        UIStackView *contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
        contentStack.axis = UILayoutConstraintAxisHorizontal;
        contentStack.alignment = UIStackViewAlignmentCenter;
        contentStack.distribution = UIStackViewDistributionFill;
        contentStack.spacing = 12.0;
        contentStack.userInteractionEnabled = NO;
        contentStack.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *checkmarkLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        checkmarkLabel.text = @"\u2713";
        checkmarkLabel.textColor = UIColor.whiteColor;
        checkmarkLabel.textAlignment = NSTextAlignmentCenter;
        checkmarkLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightRegular];
        [contentStack addArrangedSubview:checkmarkLabel];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.text = @"Posted! Tap to view.";
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.82;
        [contentStack addArrangedSubview:label];

        [banner addSubview:contentStack];
        [NSLayoutConstraint activateConstraints:@[
            [contentStack.centerXAnchor constraintEqualToAnchor:banner.centerXAnchor],
            [contentStack.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
            [contentStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:banner.leadingAnchor constant:18.0],
            [contentStack.trailingAnchor constraintLessThanOrEqualToAnchor:banner.trailingAnchor constant:-18.0]
        ]];

        ApolloRedditNativeSubmitBannerTarget *target = [ApolloRedditNativeSubmitBannerTarget new];
        target.url = permalinkURL;
        [banner addTarget:target action:@selector(bannerTapped:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(banner, @selector(bannerTapped:), target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        banner.alpha = 0.0;
        banner.transform = CGAffineTransformMakeTranslation(0.0, -16.0);
        [window addSubview:banner];
        sRedditNativeSubmitBanner = banner;

        if (@available(iOS 10.0, *)) {
            UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
            [feedback prepare];
            [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
        }

        [UIView animateWithDuration:0.22 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            banner.alpha = 1.0;
            banner.transform = CGAffineTransformIdentity;
        } completion:nil];

        ApolloLog(@"[RedditUpload] Showing native submit success banner url=%@", permalinkURL.absoluteString);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (sRedditNativeSubmitBanner != banner) {
                return;
            }
            sRedditNativeSubmitBanner = nil;
            [UIView animateWithDuration:0.2 animations:^{
                banner.alpha = 0.0;
                banner.transform = CGAffineTransformMakeTranslation(0.0, -16.0);
            } completion:^(__unused BOOL finished) {
                [banner removeFromSuperview];
            }];
        });
    });
}

static void ApolloStoreResolvedRedditNativeSubmitPermalink(NSURL *permalinkURL, NSString *fullName, NSString *source, NSString *assetID) {
    if (!permalinkURL) {
        return;
    }

    BOOL shouldShow = NO;
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (assetID.length > 0 && sRecentRedditNativeSubmitAssetID.length > 0 && ![assetID isEqualToString:sRecentRedditNativeSubmitAssetID]) {
            ApolloLog(@"[RedditUpload] Ignoring permalink for stale native submit assetID=%@ current=%@", assetID, sRecentRedditNativeSubmitAssetID ?: @"(missing)");
            return;
        }
        sRecentRedditNativeSubmitPermalink = [permalinkURL.absoluteString copy];
        sRecentRedditNativeSubmitFullName = [fullName copy];
        if (!sRecentRedditNativeSubmitBannerShown) {
            sRecentRedditNativeSubmitBannerShown = YES;
            shouldShow = YES;
        }
    }

    ApolloLog(@"[RedditUpload] Resolved native submit permalink assetID=%@ source=%@ fullName=%@ permalink=%@",
              assetID ?: @"(missing)",
              source ?: @"(unknown)",
              fullName ?: @"(missing)",
              permalinkURL.absoluteString ?: @"(missing)");
    if (shouldShow) {
        ApolloShowRedditNativeSubmitBanner(permalinkURL);
    }
}

static void ApolloResolveRedditNativeSubmitFromListing(NSDictionary *submitInfo, NSUInteger attempt) {
    NSString *assetID = [submitInfo[@"assetID"] isKindOfClass:[NSString class]] ? submitInfo[@"assetID"] : nil;
    NSString *subreddit = [submitInfo[@"subreddit"] isKindOfClass:[NSString class]] ? submitInfo[@"subreddit"] : nil;
    if (subreddit.length == 0 || sLatestRedditBearerToken.length == 0) {
        return;
    }

    NSString *escapedSubreddit = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/new.json", escapedSubreddit ?: subreddit]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"limit" value:@"25"],
        [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"]
    ];
    NSURL *url = components.URL;
    if (!url) {
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
    request.HTTPMethod = @"GET";
    [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
    NSString *userAgent = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }

    ApolloLog(@"[RedditUpload] Resolving native submit via listing assetID=%@ sr=%@ attempt=%lu", assetID ?: @"(missing)", subreddit, (unsigned long)attempt);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || statusCode < 200 || statusCode >= 300 || data.length == 0) {
            ApolloLog(@"[RedditUpload] Listing permalink resolve failed assetID=%@ status=%ld error=%@", assetID ?: @"(missing)", (long)statusCode, error.localizedDescription ?: @"(none)");
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        NSDictionary *listingData = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
        NSArray *children = [listingData[@"children"] isKindOfClass:[NSArray class]] ? listingData[@"children"] : nil;
        for (id child in children) {
            NSDictionary *childDict = [child isKindOfClass:[NSDictionary class]] ? child : nil;
            NSDictionary *postData = [childDict[@"data"] isKindOfClass:[NSDictionary class]] ? childDict[@"data"] : nil;
            if (!ApolloListingPostMatchesNativeSubmit(postData, submitInfo)) {
                continue;
            }

            NSString *permalink = [postData[@"permalink"] isKindOfClass:[NSString class]] ? postData[@"permalink"] : nil;
            NSURL *permalinkURL = ApolloRedditPermalinkURLFromString(permalink);
            NSString *fullName = [postData[@"name"] isKindOfClass:[NSString class]] ? postData[@"name"] : nil;
            if (permalinkURL) {
                ApolloStoreResolvedRedditNativeSubmitPermalink(permalinkURL, fullName, @"listing", assetID);
                return;
            }
        }

        ApolloLog(@"[RedditUpload] Listing permalink resolve did not find post assetID=%@ sr=%@ attempt=%lu parseError=%@", assetID ?: @"(missing)", subreddit, (unsigned long)attempt, jsonError.localizedDescription ?: @"(none)");
    }];
    [task resume];
}

static void ApolloScheduleRedditNativeSubmitListingFallback(NSDictionary *submitInfo) {
    NSArray<NSNumber *> *delays = @[@3.0, @7.0, @14.0, @28.0, @45.0];
    for (NSUInteger index = 0; index < delays.count; index++) {
        NSTimeInterval delay = delays[index].doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @synchronized(ApolloRedditUploadAssetMapLock()) {
                NSString *assetID = [submitInfo[@"assetID"] isKindOfClass:[NSString class]] ? submitInfo[@"assetID"] : nil;
                if (assetID.length > 0 && sRecentRedditNativeSubmitAssetID.length > 0 && ![assetID isEqualToString:sRecentRedditNativeSubmitAssetID]) {
                    return;
                }
                if (sRecentRedditNativeSubmitPermalink.length > 0) {
                    return;
                }
            }
            ApolloResolveRedditNativeSubmitFromListing(submitInfo, index + 1);
        });
    }
}

static void ApolloStartResolvingRedditNativeSubmitPermalink(NSDictionary *submitInfo) {
    if (submitInfo.count == 0) {
        return;
    }

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (sRecentRedditNativeSubmitResolverStarted) {
            return;
        }
        sRecentRedditNativeSubmitResolverStarted = YES;
    }

    ApolloScheduleRedditNativeSubmitListingFallback(submitInfo);

    NSString *webSocketURLString = [submitInfo[@"webSocketURL"] isKindOfClass:[NSString class]] ? submitInfo[@"webSocketURL"] : nil;
    NSString *assetID = [submitInfo[@"assetID"] isKindOfClass:[NSString class]] ? submitInfo[@"assetID"] : nil;
    NSURL *webSocketURL = [NSURL URLWithString:webSocketURLString];
    if (webSocketURLString.length == 0 || !webSocketURL) {
        return;
    }

    if (@available(iOS 13.0, *)) {
        ApolloLog(@"[RedditUpload] Resolving native submit via websocket assetID=%@", assetID ?: @"(missing)");
        NSURLSessionWebSocketTask *task = [[NSURLSession sharedSession] webSocketTaskWithURL:webSocketURL];
        __block BOOL finished = NO;
        [task resume];
        [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
            if (finished) {
                return;
            }
            finished = YES;

            NSString *messageString = nil;
            if (message.type == NSURLSessionWebSocketMessageTypeString) {
                messageString = message.string;
            } else if (message.data.length > 0) {
                messageString = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
            }
            [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];

            if (error || messageString.length == 0) {
                ApolloLog(@"[RedditUpload] Websocket permalink resolve failed assetID=%@ error=%@", assetID ?: @"(missing)", error.localizedDescription ?: @"empty message");
                return;
            }

            NSURL *permalinkURL = nil;
            NSData *messageData = [messageString dataUsingEncoding:NSUTF8StringEncoding];
            id json = messageData.length > 0 ? [NSJSONSerialization JSONObjectWithData:messageData options:0 error:nil] : nil;
            if (json) {
                permalinkURL = ApolloRedditPermalinkURLFromObject(json);
            }
            if (!permalinkURL) {
                permalinkURL = ApolloRedditPermalinkURLFromString(messageString);
            }

            if (permalinkURL) {
                ApolloStoreResolvedRedditNativeSubmitPermalink(permalinkURL, nil, @"websocket", assetID);
            } else {
                ApolloLog(@"[RedditUpload] Websocket did not include permalink assetID=%@ message=%@", assetID ?: @"(missing)", messageString);
            }
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (!finished) {
                finished = YES;
                [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
                ApolloLog(@"[RedditUpload] Websocket permalink resolve timed out assetID=%@", assetID ?: @"(missing)");
            }
        });
    }
}

static void ApolloShowRedditNativeSubmitBannerIfReady(void) {
    NSDictionary *info = ApolloRecentSuccessfulRedditNativeSubmitInfo();
    NSString *permalink = [info[@"permalink"] isKindOfClass:[NSString class]] ? info[@"permalink"] : nil;
    NSURL *permalinkURL = ApolloRedditPermalinkURLFromString(permalink);
    if (permalinkURL) {
        @synchronized(ApolloRedditUploadAssetMapLock()) {
            if (sRecentRedditNativeSubmitBannerShown) {
                return;
            }
            sRecentRedditNativeSubmitBannerShown = YES;
        }
        ApolloShowRedditNativeSubmitBanner(permalinkURL);
    }
}

static void ApolloLogPostSubmitWatcherTypeEncoding(void) {
    Class watcherClass = objc_getClass("_TtC6Apollo17PostSubmitWatcher");
    SEL selector = NSSelectorFromString(@"postSubmittedWithLinkID:subreddit:errorCode:errorUserInfo:secondsRemaining:composingViewControllerNavigationController:");
    Method method = watcherClass ? class_getInstanceMethod(watcherClass, selector) : NULL;
    const char *typeEncoding = method ? method_getTypeEncoding(method) : NULL;
    ApolloLog(@"[RedditUpload] PostSubmitWatcher class=%@ selectorFound=%@ typeEncoding=%s",
              watcherClass ? NSStringFromClass(watcherClass) : @"(missing)",
              method ? @"yes" : @"no",
              typeEncoding ?: "(missing)");
}

static BOOL ApolloIsAuthorizationHeader(NSString *field) {
    return [field isKindOfClass:[NSString class]] && [field caseInsensitiveCompare:@"Authorization"] == NSOrderedSame;
}

static void ApolloCaptureRedditBearerTokenFromAuthorization(NSString *authorization, NSString *source) {
    if (![authorization isKindOfClass:[NSString class]]) {
        return;
    }

    NSRange bearerRange = [authorization rangeOfString:@"Bearer " options:NSCaseInsensitiveSearch | NSAnchoredSearch];
    if (bearerRange.location == NSNotFound) {
        return;
    }

    NSString *token = [[authorization substringFromIndex:NSMaxRange(bearerRange)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (token.length == 0 || [token isEqualToString:sLatestRedditBearerToken]) {
        return;
    }

    sLatestRedditBearerToken = [token copy];
    ApolloLog(@"[RedditUpload] Captured Reddit bearer token from %@", source ?: @"unknown source");
}

static void ApolloCaptureRedditBearerTokenFromHeaderDictionary(NSDictionary *headers, NSString *source) {
    if (![headers isKindOfClass:[NSDictionary class]]) {
        return;
    }

    for (id key in headers) {
        if (![key isKindOfClass:[NSString class]] || !ApolloIsAuthorizationHeader((NSString *)key)) {
            continue;
        }
        id value = headers[key];
        if ([value isKindOfClass:[NSString class]]) {
            ApolloCaptureRedditBearerTokenFromAuthorization((NSString *)value, source);
        }
        return;
    }
}

static void ApolloCaptureRedditBearerTokenFromRequest(NSURLRequest *request, NSString *source) {
    if (![request isKindOfClass:[NSURLRequest class]]) {
        return;
    }

    NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
    ApolloCaptureRedditBearerTokenFromAuthorization(authorization, source);

    if (sUseRedditNativeImageUpload) {
        NSURL *url = request.URL;
        if ([url.host isEqualToString:@"oauth.reddit.com"] || [url.host isEqualToString:@"www.reddit.com"]) {
            ApolloLog(@"[RedditUpload] Reddit request via %@: %@%@ auth=%@ tokenCached=%@",
                      source ?: @"unknown",
                      url.host ?: @"(no-host)",
                      url.path ?: @"",
                      authorization.length > 0 ? @"present" : @"missing",
                      sLatestRedditBearerToken.length > 0 ? @"yes" : @"no");
        }
    }
}

static BOOL ApolloStringContainsRedditUploadedMedia(NSString *text) {
    return [text isKindOfClass:[NSString class]] && [text containsString:@"reddit-uploaded-media.s3-accelerate.amazonaws.com"];
}

static BOOL ApolloIsRedditCommentRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) {
        return NO;
    }

    NSURL *url = request.URL;
    return [url.host isEqualToString:@"oauth.reddit.com"] && [url.path isEqualToString:@"/api/comment"];
}

static BOOL ApolloIsRedditSubmitRequest(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) {
        return NO;
    }

    NSURL *url = request.URL;
    return [url.host isEqualToString:@"oauth.reddit.com"] && [url.path isEqualToString:@"/api/submit"];
}

static BOOL ApolloIsRedditCommentTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) {
        return NO;
    }

    return ApolloIsRedditCommentRequest(task.originalRequest) || ApolloIsRedditCommentRequest(task.currentRequest);
}

static BOOL ApolloIsRedditSubmitTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) {
        return NO;
    }

    return ApolloIsRedditSubmitRequest(task.originalRequest) || ApolloIsRedditSubmitRequest(task.currentRequest);
}

static void ApolloAppendRedditCommentResponseData(NSURLSessionTask *task, NSData *data) {
    if (!ApolloIsRedditCommentTask(task) || data.length == 0) {
        return;
    }

    NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditCommentResponseDataKey);
    if (!responseData) {
        responseData = [NSMutableData data];
        objc_setAssociatedObject(task, &kApolloRedditCommentResponseDataKey, responseData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [responseData appendData:data];
}

static void ApolloAppendRedditSubmitResponseData(NSURLSessionTask *task, NSData *data) {
    if (!ApolloIsRedditSubmitTask(task) || data.length == 0) {
        return;
    }

    NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditSubmitResponseDataKey);
    if (!responseData) {
        responseData = [NSMutableData data];
        objc_setAssociatedObject(task, &kApolloRedditSubmitResponseDataKey, responseData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [responseData appendData:data];
}

static NSString *ApolloRedditUploadExtensionForMIMEType(NSString *mimeType) {
    if ([mimeType isEqualToString:@"image/png"]) return @"png";
    if ([mimeType isEqualToString:@"image/gif"]) return @"gif";
    if ([mimeType isEqualToString:@"image/webp"]) return @"webp";
    if ([mimeType isEqualToString:@"image/heic"]) return @"heic";
    if ([mimeType isEqualToString:@"image/heif"]) return @"heif";
    return @"jpeg";
}

static NSString *ApolloDecodedRedditMediaURLString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return nil;
    }

    NSString *decoded = [urlString stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    return decoded;
}

static NSString *ApolloHTMLEscapedString(NSString *string) {
    if (![string isKindOfClass:[NSString class]]) {
        return @"";
    }

    NSString *escaped = [string stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"&#39;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return escaped;
}

static NSString *ApolloMediaURLFromRedditMediaMetadata(NSDictionary *mediaMetadata, NSString *assetID, BOOL requireValid, NSString **outStatus) {
    if (outStatus) {
        *outStatus = nil;
    }
    if (![mediaMetadata isKindOfClass:[NSDictionary class]] || assetID.length == 0) {
        return nil;
    }

    NSDictionary *entry = [mediaMetadata[assetID] isKindOfClass:[NSDictionary class]] ? mediaMetadata[assetID] : nil;
    if (!entry) {
        return nil;
    }

    NSString *status = [entry[@"status"] isKindOfClass:[NSString class]] ? entry[@"status"] : nil;
    if (outStatus) {
        *outStatus = status;
    }
    if (requireValid && ![status isEqualToString:@"valid"]) {
        return nil;
    }

    NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
    NSString *urlString = nil;
    if (source) {
        urlString = [source[@"u"] isKindOfClass:[NSString class]] ? source[@"u"] : nil;
        if (!urlString) urlString = [source[@"gif"] isKindOfClass:[NSString class]] ? source[@"gif"] : nil;
        if (!urlString) urlString = [source[@"mp4"] isKindOfClass:[NSString class]] ? source[@"mp4"] : nil;
    }

    NSArray *previews = [entry[@"p"] isKindOfClass:[NSArray class]] ? entry[@"p"] : nil;
    if (!urlString && previews.count > 0) {
        NSDictionary *preview = [previews.lastObject isKindOfClass:[NSDictionary class]] ? previews.lastObject : nil;
        urlString = [preview[@"u"] isKindOfClass:[NSString class]] ? preview[@"u"] : nil;
    }

    return ApolloDecodedRedditMediaURLString(urlString);
}

static NSString *ApolloRedditUploadFallbackURLForAssetID(NSString *assetID) {
    if (assetID.length == 0) {
        return nil;
    }

    NSString *extension = nil;
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        NSDictionary *info = sRedditUploadInfoByAssetID[assetID];
        extension = [info[@"extension"] isKindOfClass:[NSString class]] ? info[@"extension"] : nil;
    }
    if (extension.length == 0) {
        extension = @"jpeg";
    }

    return [NSString stringWithFormat:@"https://i.redd.it/%@.%@", assetID, extension];
}

static NSString *ApolloAssetIDForRedditUploadedMediaURL(NSString *urlString);
static NSString *ApolloFormDecodeComponent(NSString *component);
static NSString *ApolloHostForRedditMediaURL(NSString *urlString);

static NSMutableDictionary *ApolloRedditMediaSubmitContextFromRequest(NSURLRequest *request) {
    if (!ApolloIsRedditSubmitRequest(request)) {
        return nil;
    }

    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) {
        return nil;
    }

    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    if (!ApolloStringContainsRedditUploadedMedia(body)) {
        return nil;
    }

    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    NSArray<NSString *> *pairs = [body componentsSeparatedByString:@"&"];
    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *rawKey = equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location];
        NSString *rawValue = equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1];
        NSString *key = ApolloFormDecodeComponent(rawKey);
        NSString *value = ApolloFormDecodeComponent(rawValue);

        if ([key isEqualToString:@"sr"] && value.length > 0) {
            context[@"subreddit"] = value;
        } else if ([key isEqualToString:@"title"] && value.length > 0) {
            context[@"title"] = value;
        } else if ([key isEqualToString:@"url"] && ApolloStringContainsRedditUploadedMedia(value)) {
            context[@"stagedURL"] = value;
            NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(value);
            if (assetID.length > 0) {
                context[@"assetID"] = assetID;
                NSString *displayURL = ApolloRedditUploadFallbackURLForAssetID(assetID);
                if (displayURL.length > 0) {
                    context[@"displayURL"] = displayURL;
                }
            }
        }
    }

    return context.count > 0 ? context : nil;
}

static NSString *ApolloAssetIDFromRedditSubmitWebSocketURL(NSString *webSocketURLString) {
    if (webSocketURLString.length == 0) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:webSocketURLString];
    NSArray<NSString *> *pathComponents = components.path.pathComponents;
    NSString *lastComponent = pathComponents.lastObject;
    if (lastComponent.length == 0 || [lastComponent isEqualToString:@"/"] || [lastComponent isEqualToString:@"rte_images"]) {
        return nil;
    }

    return lastComponent;
}

static NSData *ApolloWrappedRedditSubmitResponseData(NSData *data, NSURLRequest *request, BOOL *outWrapped) {
    if (outWrapped) {
        *outWrapped = NO;
    }
    if (data.length == 0) {
        return data;
    }

    NSMutableDictionary *context = ApolloRedditMediaSubmitContextFromRequest(request);
    if (!context) {
        return data;
    }

    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
    NSMutableDictionary *root = [json isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)json mutableCopy] : nil;
    NSMutableDictionary *jsonDict = [root[@"json"] isKindOfClass:[NSDictionary class]] ? [root[@"json"] mutableCopy] : nil;
    NSMutableDictionary *dataDict = [jsonDict[@"data"] isKindOfClass:[NSDictionary class]] ? [jsonDict[@"data"] mutableCopy] : nil;
    NSArray *errors = [jsonDict[@"errors"] isKindOfClass:[NSArray class]] ? jsonDict[@"errors"] : nil;
    if (!root || !jsonDict || !dataDict || errors.count > 0) {
        if (errors.count > 0) {
            ApolloLog(@"[RedditUpload] /api/submit returned real Reddit errors; leaving response unchanged: %@", errors);
        }
        return data;
    }

    NSString *existingURL = [dataDict[@"url"] isKindOfClass:[NSString class]] ? dataDict[@"url"] : nil;
    if (existingURL.length > 0) {
        return data;
    }

    NSString *webSocketURL = [dataDict[@"websocket_url"] isKindOfClass:[NSString class]] ? dataDict[@"websocket_url"] : nil;
    NSString *userSubmittedPage = [dataDict[@"user_submitted_page"] isKindOfClass:[NSString class]] ? dataDict[@"user_submitted_page"] : nil;
    if (webSocketURL.length == 0 && userSubmittedPage.length == 0) {
        return data;
    }

    NSString *assetID = [context[@"assetID"] isKindOfClass:[NSString class]] ? context[@"assetID"] : nil;
    if (assetID.length == 0) {
        assetID = ApolloAssetIDFromRedditSubmitWebSocketURL(webSocketURL);
    }
    NSString *displayURL = [context[@"displayURL"] isKindOfClass:[NSString class]] ? context[@"displayURL"] : ApolloRedditUploadFallbackURLForAssetID(assetID);
    NSString *successURL = displayURL.length > 0 ? displayURL : userSubmittedPage;
    if (successURL.length == 0) {
        return data;
    }

    dataDict[@"url"] = successURL;
    if (displayURL.length > 0) {
        dataDict[@"media_url"] = displayURL;
    }

    jsonDict[@"errors"] = @[];
    jsonDict[@"data"] = dataDict;
    root[@"json"] = jsonDict;

    NSData *wrappedData = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    if (wrappedData.length == 0) {
        return data;
    }

    if (outWrapped) {
        *outWrapped = YES;
    }
    NSString *subreddit = [context[@"subreddit"] isKindOfClass:[NSString class]] ? context[@"subreddit"] : nil;
    NSString *title = [context[@"title"] isKindOfClass:[NSString class]] ? context[@"title"] : nil;
    ApolloRecordSuccessfulRedditNativeSubmit(assetID, subreddit, title, webSocketURL, userSubmittedPage);
    ApolloLog(@"[RedditUpload] Normalized /api/submit success response for Apollo assetID=%@ sr=%@ titlePresent=%@ nonBlocking=yes urlHost=%@ bodyBytes=%lu",
              assetID ?: @"(missing)",
              subreddit ?: @"(missing)",
              title.length > 0 ? @"yes" : @"no",
              ApolloHostForRedditMediaURL(successURL) ?: @"(missing)",
              (unsigned long)wrappedData.length);
    return wrappedData;
}

static BOOL ApolloStringIsRedditDisplayMediaURL(NSString *text) {
    return [text isKindOfClass:[NSString class]] &&
           ([text hasPrefix:@"https://preview.redd.it/"] || [text hasPrefix:@"https://i.redd.it/"]);
}

static NSString *ApolloRedditMediaURLByStrippingQuery(NSString *urlString) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(urlString);
    if (decoded.length == 0) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:decoded];
    NSString *host = components.host;
    if (([host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"i.redd.it"]) && components.path.length > 0) {
        components.query = nil;
        components.fragment = nil;
        return components.URL.absoluteString ?: decoded;
    }

    return decoded;
}

static NSString *ApolloHostForRedditMediaURL(NSString *urlString) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(urlString);
    if (decoded.length == 0) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:decoded];
    return components.host.lowercaseString;
}

static NSString *ApolloCanonicalDisplayURLForRedditMedia(NSString *assetID, NSString *authoritativeURL, NSString *mediaStatus) {
    NSString *decoded = ApolloDecodedRedditMediaURLString(authoritativeURL);
    NSString *authoritativeHost = ApolloHostForRedditMediaURL(decoded);
    if ([mediaStatus isEqualToString:@"valid"] && [authoritativeHost isEqualToString:@"i.redd.it"] && decoded.length > 0) {
        return ApolloRedditMediaURLByStrippingQuery(decoded);
    }

    NSString *fallbackURL = ApolloRedditUploadFallbackURLForAssetID(assetID);
    if (fallbackURL.length > 0) {
        return fallbackURL;
    }

    BOOL hasValidPreviewURL = [mediaStatus isEqualToString:@"valid"] && [authoritativeHost isEqualToString:@"preview.redd.it"];
    if (hasValidPreviewURL && decoded.length > 0) {
        return ApolloRedditMediaURLByStrippingQuery(decoded);
    }

    return ApolloRedditMediaURLByStrippingQuery(decoded);
}

static NSString *ApolloMediaAssetIDFromComment(NSDictionary *comment) {
    NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
    NSString *assetID = [mediaMetadata.allKeys.firstObject isKindOfClass:[NSString class]] ? mediaMetadata.allKeys.firstObject : nil;
    return assetID;
}

static NSString *ApolloBestDisplayURLForRedditComment(NSDictionary *comment, BOOL allowFallback, NSString **outAssetID, NSString **outStatus) {
    if (outAssetID) {
        *outAssetID = nil;
    }
    if (outStatus) {
        *outStatus = nil;
    }

    NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
    NSString *assetID = ApolloMediaAssetIDFromComment(comment);
    if (outAssetID) {
        *outAssetID = assetID;
    }

    NSString *status = nil;
    NSString *mediaURL = ApolloMediaURLFromRedditMediaMetadata(mediaMetadata, assetID, YES, &status);
    if (outStatus) {
        *outStatus = status;
    }
    if (mediaURL.length > 0) {
        return mediaURL;
    }

    NSString *body = [comment[@"body"] isKindOfClass:[NSString class]] ? comment[@"body"] : nil;
    if (ApolloStringIsRedditDisplayMediaURL(body)) {
        return ApolloDecodedRedditMediaURLString(body);
    }

    return allowFallback ? ApolloRedditUploadFallbackURLForAssetID(assetID) : nil;
}

static void ApolloPopulateRedditCommentDisplayBody(NSMutableDictionary *comment, NSString *mediaURL) {
    if (mediaURL.length == 0) {
        return;
    }

    NSString *body = [comment[@"body"] isKindOfClass:[NSString class]] ? comment[@"body"] : nil;
    BOOL shouldReplaceBody = body.length == 0 || [body containsString:@"Processing img "] || ApolloStringContainsRedditUploadedMedia(body) || ApolloStringIsRedditDisplayMediaURL(body);
    if (shouldReplaceBody) {
        comment[@"body"] = mediaURL;
    }

    NSString *bodyHTML = [comment[@"body_html"] isKindOfClass:[NSString class]] ? comment[@"body_html"] : nil;
    if (bodyHTML.length == 0 || [bodyHTML containsString:@"Processing img "] || ApolloStringContainsRedditUploadedMedia(bodyHTML) || ApolloStringIsRedditDisplayMediaURL(bodyHTML) || [bodyHTML containsString:@"preview.redd.it/"] || [bodyHTML containsString:@"i.redd.it/"]) {
        NSString *escapedURL = ApolloHTMLEscapedString(mediaURL);
        NSString *visibleURL = [ApolloDecodedRedditMediaURLString(mediaURL) stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
        visibleURL = [visibleURL stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
        comment[@"body_html"] = [NSString stringWithFormat:@"<div class=\"md\"><p><a href=\"%@\">%@</a></p>\n</div>", escapedURL, visibleURL ?: escapedURL];
    }
}

static NSMutableDictionary *ApolloCommentFromAPIInfoResponseData(NSData *data, NSString *fullName) {
    if (data.length == 0 || fullName.length == 0) {
        return nil;
    }

    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *listingData = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
    NSArray *children = [listingData[@"children"] isKindOfClass:[NSArray class]] ? listingData[@"children"] : nil;
    for (id child in children) {
        NSDictionary *childDict = [child isKindOfClass:[NSDictionary class]] ? child : nil;
        NSDictionary *comment = [childDict[@"data"] isKindOfClass:[NSDictionary class]] ? childDict[@"data"] : nil;
        NSString *name = [comment[@"name"] isKindOfClass:[NSString class]] ? comment[@"name"] : nil;
        if ([name isEqualToString:fullName]) {
            return [comment mutableCopy];
        }
    }

    return nil;
}

static NSMutableDictionary *ApolloHydratedRedditComment(NSDictionary *comment) {
    NSString *fullName = [comment[@"name"] isKindOfClass:[NSString class]] ? comment[@"name"] : nil;
    if (![fullName hasPrefix:@"t1_"] || sLatestRedditBearerToken.length == 0) {
        return nil;
    }

    NSString *assetID = nil;
    NSString *status = nil;
    NSString *currentMediaURL = ApolloBestDisplayURLForRedditComment(comment, NO, &assetID, &status);
    if (currentMediaURL.length > 0 || assetID.length == 0 || ![status isEqualToString:@"unprocessed"]) {
        return nil;
    }

    NSString *encodedFullName = [fullName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[@"https://oauth.reddit.com/api/info?id=" stringByAppendingString:encodedFullName ?: fullName]];
    if (!url) {
        return nil;
    }

    NSUInteger maxAttempts = 5;
    for (NSUInteger attempt = 1; attempt <= maxAttempts; attempt++) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:1.2];
        request.HTTPMethod = @"GET";
        [request setValue:[@"Bearer " stringByAppendingString:sLatestRedditBearerToken] forHTTPHeaderField:@"Authorization"];
        NSString *userAgent = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
        if (userAgent.length > 0) {
            [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
        }

        __block NSData *responseData = nil;
        __block NSURLResponse *response = nil;
        __block NSError *requestError = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *taskResponse, NSError *error) {
            responseData = data;
            response = taskResponse;
            requestError = error;
            dispatch_semaphore_signal(semaphore);
        }];
        [task resume];

        long waitResult = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (waitResult == 0 && !requestError && statusCode >= 200 && statusCode < 300) {
            NSMutableDictionary *hydratedComment = ApolloCommentFromAPIInfoResponseData(responseData, fullName);
            NSString *hydratedAssetID = nil;
            NSString *hydratedStatus = nil;
            NSString *hydratedURL = ApolloBestDisplayURLForRedditComment(hydratedComment, NO, &hydratedAssetID, &hydratedStatus);
            if (hydratedURL.length > 0) {
                ApolloLog(@"[RedditUpload] Hydrated /api/comment media URL for %@ assetID=%@ attempt=%lu", fullName, hydratedAssetID ?: @"(none)", (unsigned long)attempt);
                return hydratedComment;
            }
            ApolloLog(@"[RedditUpload] /api/comment media still %@ for %@ assetID=%@ attempt=%lu", hydratedStatus ?: @"unknown", fullName, hydratedAssetID ?: assetID, (unsigned long)attempt);
        } else {
            ApolloLog(@"[RedditUpload] /api/comment media hydration attempt %lu failed status=%ld error=%@", (unsigned long)attempt, (long)statusCode, requestError.localizedDescription ?: (waitResult == 0 ? @"(none)" : @"timed out"));
        }

        if (attempt < maxAttempts) {
            [NSThread sleepForTimeInterval:0.35];
        }
    }

    return nil;
}

static NSData *ApolloWrappedRedditCommentResponseData(NSData *data, BOOL *outWrapped) {
    if (outWrapped) {
        *outWrapped = NO;
    }
    if (data.length == 0) {
        return data;
    }

    NSError *jsonError = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return data;
    }

    NSMutableDictionary *comment = [(NSDictionary *)json mutableCopy];
    if ([comment[@"json"] isKindOfClass:[NSDictionary class]]) {
        return data;
    }

    NSString *fullName = [comment[@"name"] isKindOfClass:[NSString class]] ? comment[@"name"] : nil;
    if (![fullName hasPrefix:@"t1_"]) {
        return data;
    }

    NSMutableDictionary *hydratedComment = ApolloHydratedRedditComment(comment);
    if (hydratedComment) {
        comment = hydratedComment;
    }

    NSString *assetID = nil;
    NSString *mediaStatus = nil;
    NSString *mediaURL = ApolloBestDisplayURLForRedditComment(comment, YES, &assetID, &mediaStatus);
    if (mediaURL.length > 0) {
        NSString *fallbackURL = ApolloRedditUploadFallbackURLForAssetID(assetID);
        NSString *cardURL = ApolloCanonicalDisplayURLForRedditMedia(assetID, mediaURL, mediaStatus);
        NSString *resolvedCardURL = cardURL ?: mediaURL;
        ApolloPopulateRedditCommentDisplayBody(comment, resolvedCardURL);
        ApolloLog(@"[RedditUpload] Apollo comment media card URL for %@ assetID=%@ status=%@ cardHost=%@ fallbackHost=%@ authoritativeHost=%@ cardLen=%lu fallbackLen=%lu authoritativeLen=%lu card=%@ fallback=%@ authoritative=%@",
                  fullName,
                  assetID ?: @"(none)",
                  mediaStatus ?: @"fallback",
                  ApolloHostForRedditMediaURL(resolvedCardURL) ?: @"(none)",
                  ApolloHostForRedditMediaURL(fallbackURL) ?: @"(none)",
                  ApolloHostForRedditMediaURL(mediaURL) ?: @"(none)",
                  (unsigned long)resolvedCardURL.length,
                  (unsigned long)fallbackURL.length,
                  (unsigned long)mediaURL.length,
                  resolvedCardURL,
                  fallbackURL ?: @"(none)",
                  mediaURL);
    }

    if (![comment[@"body"] isKindOfClass:[NSString class]]) {
        NSDictionary *mediaMetadata = [comment[@"media_metadata"] isKindOfClass:[NSDictionary class]] ? comment[@"media_metadata"] : nil;
        NSString *mediaID = mediaMetadata.allKeys.firstObject;
        comment[@"body"] = mediaID.length > 0 ? [NSString stringWithFormat:@"*Processing img %@...*", mediaID] : @"";
    }
    if (![comment[@"body_html"] isKindOfClass:[NSString class]]) {
        comment[@"body_html"] = @"";
    }

    NSDictionary *wrapped = @{
        @"json": @{
            @"errors": @[],
            @"data": @{
                @"things": @[ @{ @"kind": @"t1", @"data": comment } ]
            }
        }
    };

    NSData *wrappedData = [NSJSONSerialization dataWithJSONObject:wrapped options:0 error:nil];
    if (wrappedData.length == 0) {
        return data;
    }

    if (outWrapped) {
        *outWrapped = YES;
    }
    return wrappedData;
}

static void ApolloLogRedditCommentResponse(NSURLSessionTask *task, NSError *error) {
    if (!ApolloIsRedditCommentTask(task)) {
        return;
    }

    NSHTTPURLResponse *httpResponse = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)task.response : nil;
    NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditCommentResponseDataKey);
    NSString *body = responseData.length > 0 ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
    if (body.length > 4096) {
        body = [[body substringToIndex:4096] stringByAppendingString:@"...<truncated>"];
    }

    ApolloLog(@"[RedditUpload] /api/comment completed status=%ld error=%@ body=%@",
              (long)httpResponse.statusCode,
              error.localizedDescription ?: @"(none)",
              body.length > 0 ? body : @"(empty)");
}

static void ApolloLogRedditSubmitResponse(NSURLSessionTask *task, NSError *error) {
    if (!ApolloIsRedditSubmitTask(task)) {
        return;
    }

    NSHTTPURLResponse *httpResponse = [task.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)task.response : nil;
    NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditSubmitResponseDataKey);
    NSString *body = responseData.length > 0 ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"";
    if (body.length > 4096) {
        body = [[body substringToIndex:4096] stringByAppendingString:@"...<truncated>"];
    }

    ApolloLog(@"[RedditUpload] /api/submit completed status=%ld error=%@ body=%@",
              (long)httpResponse.statusCode,
              error.localizedDescription ?: @"(none)",
              body.length > 0 ? body : @"(empty)");
}

static void ApolloInstallRedditCommentDiagnosticsForDelegate(id delegate) {
    if (!delegate) {
        return;
    }

    Class cls = object_getClass(delegate);
    if (!cls) {
        return;
    }

    NSString *classKey = NSStringFromClass(cls);
    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditCommentDiagnosticDelegateClasses) {
            sRedditCommentDiagnosticDelegateClasses = [[NSMutableSet alloc] init];
        }
        if ([sRedditCommentDiagnosticDelegateClasses containsObject:classKey]) {
            return;
        }
        [sRedditCommentDiagnosticDelegateClasses addObject:classKey];
    }

    SEL didReceiveDataSelector = @selector(URLSession:dataTask:didReceiveData:);
    Method didReceiveDataMethod = class_getInstanceMethod(cls, didReceiveDataSelector);
    IMP originalDidReceiveDataIMP = didReceiveDataMethod ? method_getImplementation(didReceiveDataMethod) : NULL;
    const char *didReceiveDataTypes = didReceiveDataMethod ? method_getTypeEncoding(didReceiveDataMethod) : "v@:@@@";
    IMP didReceiveDataIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data) {
        if (ApolloIsRedditCommentTask(dataTask)) {
            ApolloAppendRedditCommentResponseData(dataTask, data);
            return;
        }
        if (ApolloIsRedditSubmitTask(dataTask)) {
            ApolloAppendRedditSubmitResponseData(dataTask, data);
            return;
        }
        if (originalDidReceiveDataIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, dataTask, data);
        }
    });
    class_replaceMethod(cls, didReceiveDataSelector, didReceiveDataIMP, didReceiveDataTypes);

    SEL didCompleteSelector = @selector(URLSession:task:didCompleteWithError:);
    Method didCompleteMethod = class_getInstanceMethod(cls, didCompleteSelector);
    IMP originalDidCompleteIMP = didCompleteMethod ? method_getImplementation(didCompleteMethod) : NULL;
    const char *didCompleteTypes = didCompleteMethod ? method_getTypeEncoding(didCompleteMethod) : "v@:@@@";
    IMP didCompleteIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
        if (ApolloIsRedditCommentTask(task)) {
            ApolloLogRedditCommentResponse(task, error);
            NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditCommentResponseDataKey);
            BOOL wrapped = NO;
            NSData *dataForApollo = ApolloWrappedRedditCommentResponseData(responseData, &wrapped);
            if (dataForApollo.length > 0 && originalDidReceiveDataIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, (NSURLSessionDataTask *)task, dataForApollo);
                ApolloLog(@"[RedditUpload] Delivered %@ /api/comment response to Apollo (%lu bytes)", wrapped ? @"wrapped" : @"original", (unsigned long)dataForApollo.length);
            }
            objc_setAssociatedObject(task, &kApolloRedditCommentResponseDataKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        if (ApolloIsRedditSubmitTask(task)) {
            ApolloLogRedditSubmitResponse(task, error);
            NSMutableData *responseData = objc_getAssociatedObject(task, &kApolloRedditSubmitResponseDataKey);
            if (responseData.length > 0 && originalDidReceiveDataIMP) {
                BOOL wrapped = NO;
                NSURLRequest *submitRequest = task.originalRequest ?: task.currentRequest;
                NSData *dataForApollo = ApolloWrappedRedditSubmitResponseData(responseData, submitRequest, &wrapped);
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, (NSURLSessionDataTask *)task, dataForApollo ?: responseData);
                ApolloLog(@"[RedditUpload] Delivered %@ /api/submit response to Apollo (%lu bytes)", wrapped ? @"wrapped" : @"original", (unsigned long)(dataForApollo ?: responseData).length);
            }
            objc_setAssociatedObject(task, &kApolloRedditSubmitResponseDataKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        if (originalDidCompleteIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
        }
    });
    class_replaceMethod(cls, didCompleteSelector, didCompleteIMP, didCompleteTypes);

    ApolloLog(@"[RedditUpload] Installed Reddit upload response diagnostics on delegate class %@", classKey);
}

static NSRegularExpression *ApolloRedditUploadedMediaURLRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
                regex = [[NSRegularExpression alloc] initWithPattern:@"https://reddit-uploaded-media\\.s3-accelerate\\.amazonaws\\.com/[^\\s\\])<>]+"
                                                                                                     options:0
                                                                                                         error:nil];
    });
    return regex;
}

static NSObject *ApolloRedditUploadAssetMapLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static void ApolloRecordRedditUploadedMediaAssetID(NSURL *imageURL, NSString *assetID) {
    NSString *urlString = imageURL.absoluteString;
    if (urlString.length == 0 || assetID.length == 0) {
        return;
    }

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditUploadAssetIDByURL) {
            sRedditUploadAssetIDByURL = [[NSMutableDictionary alloc] init];
        }
        sRedditUploadAssetIDByURL[urlString] = assetID;
    }
}

static void ApolloRecordRedditUploadedMediaInfo(NSURL *imageURL, NSString *assetID, NSString *mimeType) {
    NSString *urlString = imageURL.absoluteString;
    if (assetID.length == 0) {
        return;
    }

    NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(nil, mimeType);
    NSString *extension = ApolloRedditUploadExtensionForMIMEType(resolvedMIMEType);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"assetID"] = assetID;
    info[@"mimeType"] = resolvedMIMEType ?: @"image/jpeg";
    info[@"extension"] = extension ?: @"jpeg";
    if (urlString.length > 0) {
        info[@"stagedURL"] = urlString;
    }

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        if (!sRedditUploadInfoByAssetID) {
            sRedditUploadInfoByAssetID = [[NSMutableDictionary alloc] init];
        }
        sRedditUploadInfoByAssetID[assetID] = info;
    }
}

static NSString *ApolloAssetIDForRedditUploadedMediaURL(NSString *urlString) {
    if (urlString.length == 0) {
        return nil;
    }

    @synchronized(ApolloRedditUploadAssetMapLock()) {
        return sRedditUploadAssetIDByURL[urlString];
    }
}

static NSString *ApolloFormDecodeComponent(NSString *component) {
    NSString *plusDecoded = [component stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return plusDecoded.stringByRemovingPercentEncoding ?: plusDecoded;
}

static NSString *ApolloFormEncodeComponent(NSString *component) {
    static NSCharacterSet *allowed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet alphanumericCharacterSet];
        [set addCharactersInString:@"-._~"];
        allowed = [set copy];
    });
    return [component stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *ApolloCommentTextByWrappingRedditUploadedMediaURLs(NSString *text) {
    if (!ApolloStringContainsRedditUploadedMedia(text)) {
        return text;
    }

    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    if (!regex) {
        return text;
    }

    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) {
        return text;
    }

    NSMutableString *rewritten = [text mutableCopy];
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSRange range = match.range;
        if (range.location >= 2) {
            NSString *prefix = [text substringWithRange:NSMakeRange(range.location - 2, 2)];
            if ([prefix isEqualToString:@"]("]) {
                continue;
            }
        }

        NSString *url = [text substringWithRange:range];
        NSString *replacement = [NSString stringWithFormat:@"[image](%@)", url];
        [rewritten replaceCharactersInRange:range withString:replacement];
    }
    return rewritten;
}

static NSDictionary *ApolloRedditRichTextParagraphBlock(NSString *text) {
    NSString *trimmedText = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedText.length == 0) {
        return nil;
    }
    return @{ @"e": @"par", @"c": @[ @{ @"e": @"text", @"t": trimmedText } ] };
}

static NSData *ApolloRedditRichTextCommentJSONDataForText(NSString *text) {
    NSRegularExpression *regex = ApolloRedditUploadedMediaURLRegex();
    NSArray<NSTextCheckingResult *> *matches = regex ? [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
    if (matches.count == 0) {
        return nil;
    }

    NSMutableArray<NSDictionary *> *blocks = [NSMutableArray array];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.range.location > cursor) {
            NSString *prefix = [text substringWithRange:NSMakeRange(cursor, match.range.location - cursor)];
            NSDictionary *paragraph = ApolloRedditRichTextParagraphBlock(prefix);
            if (paragraph) {
                [blocks addObject:paragraph];
            }
        }

        NSString *mediaURL = [text substringWithRange:match.range];
        NSString *assetID = ApolloAssetIDForRedditUploadedMediaURL(mediaURL);
        if (assetID.length == 0) {
            ApolloLog(@"[RedditUpload] No asset ID recorded for uploaded media URL; falling back to markdown rewrite: %@", mediaURL);
            return nil;
        }

        [blocks addObject:@{ @"e": @"img", @"id": assetID, @"c": @"" }];
        cursor = NSMaxRange(match.range);
    }

    if (cursor < text.length) {
        NSString *suffix = [text substringFromIndex:cursor];
        NSDictionary *paragraph = ApolloRedditRichTextParagraphBlock(suffix);
        if (paragraph) {
            [blocks addObject:paragraph];
        }
    }

    if (blocks.count == 0) {
        return nil;
    }

    NSDictionary *document = @{ @"document": blocks };
    return [NSJSONSerialization dataWithJSONObject:document options:0 error:nil];
}

static NSURLRequest *ApolloRequestByRewritingRedditMediaComment(NSURLRequest *request) {
    if (!sUseRedditNativeImageUpload || ![request isKindOfClass:[NSURLRequest class]]) {
        return nil;
    }

    NSURL *url = request.URL;
    if (![url.host isEqualToString:@"oauth.reddit.com"] || ![url.path isEqualToString:@"/api/comment"]) {
        return nil;
    }

    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) {
        ApolloLog(@"[RedditUpload] /api/comment contains no HTTPBody to inspect for Reddit media attachment");
        return nil;
    }

    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    if (!ApolloStringContainsRedditUploadedMedia(body)) {
        return nil;
    }

    NSArray<NSString *> *pairs = [body componentsSeparatedByString:@"&"];
    NSMutableArray<NSString *> *rewrittenPairs = [NSMutableArray arrayWithCapacity:pairs.count + 2];
    BOOL changed = NO;
    BOOL wroteReturnRichTextJSON = NO;
    NSString *richTextJSONString = nil;

    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *rawKey = equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location];
        NSString *rawValue = equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1];
        NSString *key = ApolloFormDecodeComponent(rawKey);
        NSString *value = ApolloFormDecodeComponent(rawValue);

        if ([key isEqualToString:@"text"] && ApolloStringContainsRedditUploadedMedia(value)) {
            NSData *richTextJSONData = ApolloRedditRichTextCommentJSONDataForText(value);
            if (richTextJSONData.length > 0) {
                richTextJSONString = [[NSString alloc] initWithData:richTextJSONData encoding:NSUTF8StringEncoding];
                if (richTextJSONString.length > 0) {
                    ApolloLog(@"[RedditUpload] Rewriting /api/comment text to richtext_json uploaded Reddit media");
                    ApolloLog(@"[RedditUpload] richtext_json payload: %@", richTextJSONString);
                    changed = YES;
                    continue;
                }
            }

            NSString *rewrittenValue = ApolloCommentTextByWrappingRedditUploadedMediaURLs(value);
            if (![rewrittenValue isEqualToString:value]) {
                ApolloLog(@"[RedditUpload] Rewriting /api/comment text to markdown-link uploaded Reddit media fallback");
                value = rewrittenValue;
                changed = YES;
            }
        }

        if ([key isEqualToString:@"return_rtjson"]) {
            value = @"true";
            wroteReturnRichTextJSON = YES;
        }

        NSString *encodedPair = [NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)];
        [rewrittenPairs addObject:encodedPair];
    }

    if (richTextJSONString.length > 0) {
        NSString *richTextPair = [NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"richtext_json"), ApolloFormEncodeComponent(richTextJSONString)];
        [rewrittenPairs addObject:richTextPair];
        if (!wroteReturnRichTextJSON) {
            NSString *returnRichTextPair = [NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"return_rtjson"), ApolloFormEncodeComponent(@"true")];
            [rewrittenPairs addObject:returnRichTextPair];
        }
    }

    if (!changed) {
        ApolloLog(@"[RedditUpload] /api/comment already had uploaded Reddit media but no rewrite was needed");
        return nil;
    }

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    NSData *newBody = [[rewrittenPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [modifiedRequest setHTTPBody:newBody];
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
    return modifiedRequest;
}

static NSURLRequest *ApolloRequestByRewritingRedditMediaSubmit(NSURLRequest *request) {
    if (!sUseRedditNativeImageUpload || !ApolloIsRedditSubmitRequest(request)) {
        return nil;
    }

    NSData *bodyData = request.HTTPBody;
    if (bodyData.length == 0) {
        ApolloLog(@"[RedditUpload] /api/submit contains no HTTPBody to inspect for Reddit media attachment");
        return nil;
    }

    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
    if (!ApolloStringContainsRedditUploadedMedia(body)) {
        return nil;
    }

    NSArray<NSString *> *pairs = [body componentsSeparatedByString:@"&"];
    NSMutableArray<NSString *> *rewrittenPairs = [NSMutableArray arrayWithCapacity:pairs.count + 2];
    BOOL changed = NO;
    BOOL wroteKind = NO;
    BOOL wroteAPIType = NO;
    BOOL wroteValidateOnSubmit = NO;
    NSString *assetID = nil;
    NSString *originalKind = nil;
    NSString *subreddit = nil;
    NSString *title = nil;
    NSString *stagedURLHost = nil;

    for (NSString *pair in pairs) {
        NSRange equals = [pair rangeOfString:@"="];
        NSString *rawKey = equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location];
        NSString *rawValue = equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1];
        NSString *key = ApolloFormDecodeComponent(rawKey);
        NSString *value = ApolloFormDecodeComponent(rawValue);

        if ([key isEqualToString:@"sr"]) {
            subreddit = value;
        } else if ([key isEqualToString:@"title"]) {
            title = value;
        }

        if ([key isEqualToString:@"url"] && ApolloStringContainsRedditUploadedMedia(value)) {
            assetID = ApolloAssetIDForRedditUploadedMediaURL(value);
            stagedURLHost = ApolloHostForRedditMediaURL(value);
            if (assetID.length == 0) {
                ApolloLog(@"[RedditUpload] /api/submit found uploaded Reddit media URL but no recorded asset ID; preserving staged URL for image submit: %@", value);
            }
        } else if ([key isEqualToString:@"kind"]) {
            originalKind = value;
            wroteKind = YES;
            if (![value isEqualToString:@"image"]) {
                value = @"image";
                changed = YES;
            }
        } else if ([key isEqualToString:@"api_type"]) {
            wroteAPIType = YES;
            if (![value isEqualToString:@"json"]) {
                value = @"json";
                changed = YES;
            }
        } else if ([key isEqualToString:@"validate_on_submit"]) {
            wroteValidateOnSubmit = YES;
            if (![value isEqualToString:@"false"] && ![value isEqualToString:@"False"] && ![value isEqualToString:@"0"]) {
                value = @"false";
                changed = YES;
            }
        }

        NSString *encodedPair = [NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(key), ApolloFormEncodeComponent(value)];
        [rewrittenPairs addObject:encodedPair];
    }

    if (!wroteKind) {
        NSString *kindPair = [NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"kind"), ApolloFormEncodeComponent(@"image")];
        [rewrittenPairs addObject:kindPair];
        changed = YES;
    }

    if (!wroteValidateOnSubmit) {
        NSString *validatePair = [NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"validate_on_submit"), ApolloFormEncodeComponent(@"false")];
        [rewrittenPairs addObject:validatePair];
        changed = YES;
    }

    if (!wroteAPIType) {
        NSString *apiTypePair = [NSString stringWithFormat:@"%@=%@", ApolloFormEncodeComponent(@"api_type"), ApolloFormEncodeComponent(@"json")];
        [rewrittenPairs addObject:apiTypePair];
        changed = YES;
    }

    if (!changed) {
        return nil;
    }

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    NSData *newBody = [[rewrittenPairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [modifiedRequest setHTTPBody:newBody];
    [modifiedRequest setValue:[NSString stringWithFormat:@"%lu", (unsigned long)newBody.length] forHTTPHeaderField:@"Content-Length"];
    ApolloLog(@"[RedditUpload] Rewriting /api/submit uploaded Reddit media to image post assetID=%@ originalKind=%@ urlHost=%@ sr=%@ titlePresent=%@ validateOnSubmit=%@ bodyBytes=%lu",
              assetID ?: @"(missing)",
              originalKind ?: @"(missing)",
              stagedURLHost ?: @"(missing)",
              subreddit.length > 0 ? subreddit : @"(missing)",
              title.length > 0 ? @"yes" : @"no",
              @"false",
              (unsigned long)newBody.length);
    return modifiedRequest;
}

static NSURLRequest *ApolloRedditUploadFastFailRequest(void) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:1/apollo-reddit-upload"]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 1.0;
    return request;
}

static NSHTTPURLResponse *ApolloSyntheticImgurHTTPResponse(NSURL *url) {
    return [[NSHTTPURLResponse alloc] initWithURL:url
                                      statusCode:200
                                     HTTPVersion:@"HTTP/1.1"
                                    headerFields:@{@"Content-Type": @"application/json"}];
}

static void ApolloCompleteRedditNativeImageUpload(NSData *imageData,
                                                  NSString *filename,
                                                  NSString *mimeType,
                                                  NSURL *originalURL,
                                                  void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *userAgent = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;

    ApolloUploadImageDataToReddit(imageData, filename, mimeType, token, userAgent, ^(NSURL *imageURL, NSString *assetID, NSString *webSocketURL, NSError *error) {
        if (error || !imageURL || assetID.length == 0) {
            ApolloLog(@"[RedditUpload] Upload failed: %@", error.localizedDescription);
            completionHandler(nil, nil, error ?: [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:50 userInfo:@{NSLocalizedDescriptionKey: @"Reddit media upload did not return a URL and asset ID"}]);
            return;
        }

        NSString *resolvedMIMEType = ApolloMediaMIMETypeForFilename(filename, mimeType);
        ApolloRecordRedditUploadedMediaAssetID(imageURL, assetID);
        ApolloRecordRedditUploadedMediaInfo(imageURL, assetID, resolvedMIMEType);

        if (webSocketURL.length > 0) {
            ApolloLog(@"[RedditUpload] WebSocket URL: %@", webSocketURL);
        }

        NSData *jsonData = ApolloSyntheticImgurUploadResponseData(imageURL, resolvedMIMEType);
        NSHTTPURLResponse *response = ApolloSyntheticImgurHTTPResponse(originalURL ?: imageURL);
        completionHandler(jsonData, response, nil);
    });
}

// Replace Reddit API client ID
%hook RDKOAuthCredential

- (NSString *)clientIdentifier {
    return sRedditClientId;
}

- (NSURL *)redirectURI {
    NSString *customURI = [sRedirectURI length] > 0 ? sRedirectURI : defaultRedirectURI;
    return [NSURL URLWithString:customURI];
}

%end

%hook RDKClient

- (NSString *)userAgent {
    NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
    return customUA;
}

// Defensive guard: bail out if the response isn't a dictionary. Apollo otherwise
// crashes with "unrecognized selector" when it does `response[@"kind"]` on a string.
- (NSArray *)objectsFromListingResponse:(id)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[ListingResponse] Non-dict response of class %@; returning nil to avoid crash", NSStringFromClass([response class]));
        return nil;
    }
    return %orig;
}

%end

// Same defensive guard for the sibling pagination call. Apollo's listing block calls
// both +[RDKPagination paginationFromListingResponse:] and the above on the same
// response; pagination crashes on `[response valueForKeyPath:@"data.before"]`.
%hook RDKPagination

+ (instancetype)paginationFromListingResponse:(id)response {
    if (![response isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[ListingResponse] Non-dict response of class %@; skipping pagination", NSStringFromClass([response class]));
        return nil;
    }
    return %orig;
}

%end

// Randomise the trending subreddits list
%hook NSBundle
-(NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)ext {
    NSURL *url = %orig;
    if ([name isEqualToString:@"trending-subreddits"] && [ext isEqualToString:@"plist"]) {
        NSURL *subredditListURL = [NSURL URLWithString:sTrendingSubredditsSource];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        // ex: 2023-9-28 (28th September 2023)
        [formatter setDateFormat:@"yyyy-M-d"];

        /*
            - Parse plist
            - Select random list of subreddits from the dict
            - Add today's date to the dict, with the list as the value
            - Return plist as a new file
        */
        NSMutableDictionary *fallbackDict = [[NSDictionary dictionaryWithContentsOfURL:url] mutableCopy];
        // Select random array from dict
        NSArray *fallbackKeys = [fallbackDict allKeys];
        NSString *randomFallbackKey = fallbackKeys[arc4random_uniform((uint32_t)[fallbackKeys count])];
        NSArray *fallbackArray = fallbackDict[randomFallbackKey];
        if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]) {
            fallbackArray = [fallbackArray arrayByAddingObject:@"RandNSFW"];
        }
        [fallbackDict setObject:fallbackArray forKey:[formatter stringFromDate:[NSDate date]]];

        NSURL * (^writeDict)(NSMutableDictionary *d) = ^(NSMutableDictionary *d){
            // write new file
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"trending-custom.plist"];
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil]; // remove in case it exists
            [d writeToFile:tempPath atomically:YES];
            return [NSURL fileURLWithPath:tempPath];
        };

        __block NSError *error = nil;
        __block NSString *subredditListContent = nil;

        // Try fetching the subreddit list from the source URL, with timeout of 5 seconds
        // FIXME: Blocks the UI during the splash screen
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        NSURLRequest *request = [NSURLRequest requestWithURL:subredditListURL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:5.0];
        NSURLSession *session = [NSURLSession sharedSession];
        NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
            if (e) {
                error = e;
            } else {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                if (httpResponse.statusCode == 200) {
                    subredditListContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                }
            }
            dispatch_semaphore_signal(semaphore);
        }];
        [dataTask resume];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        // Use fallback dict if there was an error
        if (error || ![subredditListContent length]) {
            return writeDict(fallbackDict);
        }

        // Parse into array
        NSMutableArray<NSString *> *subreddits = [[subredditListContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy];
        [subreddits filterUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (subreddits.count == 0) {
            return writeDict(fallbackDict);
        }

        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        // Randomize and limit subreddits
        bool limitSubreddits = [sTrendingSubredditsLimit length] > 0;
        if (limitSubreddits && [sTrendingSubredditsLimit integerValue] < subreddits.count) {
            NSUInteger count = [sTrendingSubredditsLimit integerValue];
            NSMutableArray<NSString *> *randomSubreddits = [NSMutableArray arrayWithCapacity:count];
            for (NSUInteger i = 0; i < count; i++) {
                NSUInteger randomIndex = arc4random_uniform((uint32_t)subreddits.count);
                [randomSubreddits addObject:subreddits[randomIndex]];
                // Remove to prevent duplicates
                [subreddits removeObjectAtIndex:randomIndex];
            }
            subreddits = randomSubreddits;
        }

        if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRandNsfw]) {
            [subreddits addObject:@"RandNSFW"];
        }
        [dict setObject:subreddits forKey:[formatter stringFromDate:[NSDate date]]];
        return writeDict(dict);
    }
    return url;
}
%end

// Does not work on iOS 26+
%hook NSURL

// Rewrite x.com links as twitter.com
- (NSString *)host {
    NSString *originalHost = %orig;
    if (originalHost && [originalHost isEqualToString:@"x.com"]) {
        return @"twitter.com";
    }
    return originalHost;
}
%end

// Implementation derived from https://github.com/ichitaso/ApolloPatcher/blob/v0.0.5/Tweak.x
// Credits to @ichitaso for the original implementation

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (ApolloIsAuthorizationHeader(field)) {
        ApolloCaptureRedditBearerTokenFromAuthorization(value, @"NSMutableURLRequest setValue:forHTTPHeaderField:");
    }
    %orig;
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (ApolloIsAuthorizationHeader(field)) {
        ApolloCaptureRedditBearerTokenFromAuthorization(value, @"NSMutableURLRequest addValue:forHTTPHeaderField:");
    }
    %orig;
}

%end

%hook NSURLSessionConfiguration

- (void)setHTTPAdditionalHeaders:(NSDictionary *)HTTPAdditionalHeaders {
    ApolloCaptureRedditBearerTokenFromHeaderDictionary(HTTPAdditionalHeaders, @"NSURLSessionConfiguration HTTPAdditionalHeaders");
    %orig;
}

%end

@interface NSURLSession (Private)
- (BOOL)isJSONResponse:(NSURLResponse *)response;
@end

// Strip RapidAPI-specific headers when redirecting to direct Imgur API
static void StripRapidAPIHeaders(NSMutableURLRequest *request) {
    [request setValue:nil forHTTPHeaderField:@"X-RapidAPI-Key"];
    [request setValue:nil forHTTPHeaderField:@"X-RapidAPI-Host"];
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    ApolloCaptureRedditBearerTokenFromRequest(request, @"NSURLSession dataTaskWithRequest:");

    NSURLRequest *redditMediaSubmitRequest = ApolloRequestByRewritingRedditMediaSubmit(request);
    if (redditMediaSubmitRequest) {
        ApolloInstallRedditCommentDiagnosticsForDelegate(self.delegate);
        return %orig(redditMediaSubmitRequest);
    }

    NSURLRequest *redditMediaCommentRequest = ApolloRequestByRewritingRedditMediaComment(request);
    if (redditMediaCommentRequest) {
        ApolloInstallRedditCommentDiagnosticsForDelegate(self.delegate);
        return %orig(redditMediaCommentRequest);
    }

    NSURL *url = [request URL];
    NSURL *subredditListURL;

    // Reroute URL-shaped search queries to /api/info?url=<URL>. Reddit's /search.json
    // 302-redirects URL-shaped queries to /submit.json (and on to /login), producing
    // a non-Listing response that crashes Apollo's parser. /api/info returns a proper
    // Listing for both Reddit and external URLs.
    BOOL isPostSearch = [url.host isEqualToString:@"oauth.reddit.com"] &&
        ([url.path isEqualToString:@"/search.json"] ||
         ([url.path hasPrefix:@"/r/"] && [url.path hasSuffix:@"/search.json"]));
    if (isPostSearch) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *q = nil;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"q"]) {
                q = item.value;
                break;
            }
        }
        if (q.length > 0 && ([q hasPrefix:@"http://"] || [q hasPrefix:@"https://"])) {
            NSURLComponents *rewritten = [[NSURLComponents alloc] init];
            rewritten.scheme = @"https";
            rewritten.host = @"oauth.reddit.com";
            rewritten.path = @"/api/info.json";
            rewritten.queryItems = @[
                [NSURLQueryItem queryItemWithName:@"url" value:q],
                [NSURLQueryItem queryItemWithName:@"raw_json" value:@"1"],
            ];
            NSMutableURLRequest *modifiedRequest = [request mutableCopy];
            [modifiedRequest setURL:rewritten.URL];
            ApolloLog(@"[URLSearch] Rerouting URL search to /api/info.json. Original: %@ Rewritten: %@", url.absoluteString, rewritten.URL.absoluteString);
            return %orig(modifiedRequest);
        }
    }

    // Determine whether request is for random subreddit
    if ([url.host isEqualToString:@"oauth.reddit.com"] && [url.path hasPrefix:@"/r/random/"]) {
        if (![sRandomSubredditsSource length]) {
            return %orig;
        }
        subredditListURL = [NSURL URLWithString:sRandomSubredditsSource];
    } else if ([url.host isEqualToString:@"oauth.reddit.com"] && [url.path hasPrefix:@"/r/randnsfw/"]) {
        if (![sRandNsfwSubredditsSource length]) {
            return %orig;
        }
        subredditListURL = [NSURL URLWithString:sRandNsfwSubredditsSource];
    } else {
        return %orig;
    }

    NSError *error = nil;
    // Check cache
    NSString *subredditListContent = [subredditListCache objectForKey:subredditListURL.absoluteString];
    bool updateCache = false;

    if (!subredditListContent) {
        // Not in cache, so fetch subreddit list from source URL
        // FIXME: The current implementation blocks the UI, but the prefetching in initializeRandomSources() should help
        subredditListContent = [NSString stringWithContentsOfURL:subredditListURL encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            return %orig;
        }
        updateCache = true;
    }

    // Parse the content into a list of strings
    NSArray<NSString *> *subreddits = [subredditListContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    subreddits = [subreddits filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (subreddits.count == 0) {
        return %orig;
    }

    if (updateCache) {
        [subredditListCache setObject:subredditListContent forKey:subredditListURL.absoluteString];
    }

    // Pick a random subreddit, then modify the request URL to use that subreddit, simulating a 302 redirect in Reddit's original API behaviour
    NSString *randomSubreddit = subreddits[arc4random_uniform((uint32_t)subreddits.count)];
    NSString *urlString = [url absoluteString];
    NSString *newUrlString = [urlString stringByReplacingOccurrencesOfString:@"/random/" withString:[NSString stringWithFormat:@"/%@/", randomSubreddit]];
    newUrlString = [newUrlString stringByReplacingOccurrencesOfString:@"/randnsfw/" withString:[NSString stringWithFormat:@"/%@/", randomSubreddit]];

    NSMutableURLRequest *modifiedRequest = [request mutableCopy];
    [modifiedRequest setURL:[NSURL URLWithString:newUrlString]];
    return %orig(modifiedRequest);
}

// Imgur Delete and album creation
- (NSURLSessionDataTask*)dataTaskWithRequest:(NSURLRequest*)request completionHandler:(void (^)(NSData*, NSURLResponse*, NSError*))completionHandler {
    ApolloCaptureRedditBearerTokenFromRequest(request, @"NSURLSession dataTaskWithRequest:completionHandler:");

    NSURLRequest *redditMediaSubmitRequest = ApolloRequestByRewritingRedditMediaSubmit(request);
    if (redditMediaSubmitRequest) {
        void (^wrappedSubmitCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            NSString *body = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (body.length > 4096) {
                body = [[body substringToIndex:4096] stringByAppendingString:@"...<truncated>"];
            }
            ApolloLog(@"[RedditUpload] /api/submit completion status=%ld error=%@ body=%@",
                      (long)statusCode,
                      error.localizedDescription ?: @"(none)",
                      body.length > 0 ? body : @"(empty)");
            BOOL wrapped = NO;
            NSData *dataForApollo = ApolloWrappedRedditSubmitResponseData(data, redditMediaSubmitRequest, &wrapped);
            if (wrapped) {
                ApolloLog(@"[RedditUpload] Delivered wrapped /api/submit completion response to Apollo (%lu bytes)", (unsigned long)dataForApollo.length);
            }
            completionHandler(dataForApollo ?: data, response, error);
        };
        return %orig(redditMediaSubmitRequest, wrappedSubmitCompletionHandler);
    }

    NSURLRequest *redditMediaCommentRequest = ApolloRequestByRewritingRedditMediaComment(request);
    if (redditMediaCommentRequest) {
        void (^wrappedCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            NSString *body = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (body.length > 4096) {
                body = [[body substringToIndex:4096] stringByAppendingString:@"...<truncated>"];
            }
            BOOL wrapped = NO;
            NSData *dataForApollo = ApolloWrappedRedditCommentResponseData(data, &wrapped);
            ApolloLog(@"[RedditUpload] /api/comment completion status=%ld error=%@ body=%@",
                      (long)statusCode,
                      error.localizedDescription ?: @"(none)",
                      body.length > 0 ? body : @"(empty)");
            if (wrapped) {
                ApolloLog(@"[RedditUpload] Delivered wrapped /api/comment completion response to Apollo (%lu bytes)", (unsigned long)dataForApollo.length);
            }
            completionHandler(dataForApollo ?: data, response, error);
        };
        return %orig(redditMediaCommentRequest, wrappedCompletionHandler);
    }

    NSURL *url = [request URL];
    NSString *host = [url host];
    NSString *path = [url path];

    if ([host isEqualToString:@"imgur-apiv3.p.rapidapi.com"] && [path hasPrefix:@"/3/album"]) {
        // Album creation needs body format conversion (form-urlencoded → JSON)
        // URL redirect and auth are handled by _onqueue_resume
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        [modifiedRequest setURL:[NSURL URLWithString:[@"https://api.imgur.com" stringByAppendingString:path]]];
        StripRapidAPIHeaders(modifiedRequest);
        NSString *bodyString = [[NSString alloc] initWithData:modifiedRequest.HTTPBody encoding:NSUTF8StringEncoding];
        NSArray *components = [bodyString componentsSeparatedByString:@"="];
        if (components.count == 2 && [components[0] isEqualToString:@"deletehashes"]) {
            NSString *deleteHashes = components[1];
            NSArray *hashes = [deleteHashes componentsSeparatedByString:@","];
            NSDictionary *jsonBody = @{@"deletehashes": hashes};
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:nil];
            [modifiedRequest setHTTPBody:jsonData];
            [modifiedRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        }
        return %orig(modifiedRequest, completionHandler);
    } else if ([host isEqualToString:@"api.redgifs.com"] && [path isEqualToString:@"/v2/oauth/client"]) {
        // Redirect to the new temporary token endpoint
        NSMutableURLRequest *modifiedRequest = [request mutableCopy];
        NSURL *newURL = [NSURL URLWithString:@"https://api.redgifs.com/v2/auth/temporary"];
        [modifiedRequest setURL:newURL];
        [modifiedRequest setHTTPMethod:@"GET"];
        [modifiedRequest setHTTPBody:nil];
        [modifiedRequest setValue:nil forHTTPHeaderField:@"Content-Type"];
        [modifiedRequest setValue:nil forHTTPHeaderField:@"Content-Length"];

        void (^newCompletionHandler)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data) {
                NSError *jsonError = nil;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (!jsonError && json[@"token"]) {
                    // Transform response to match Apollo's format from '/v2/oauth/client'
                    NSDictionary *oauthResponse = @{
                        @"access_token": json[@"token"],
                        @"token_type": @"Bearer",
                        @"expires_in": @(82800), // 23 hours
                        @"scope": @"read"
                    };
                    NSData *transformedData = [NSJSONSerialization dataWithJSONObject:oauthResponse options:0 error:nil];
                    completionHandler(transformedData, response, error);
                    return;
                }
            }
            completionHandler(data, response, error);
        };
        return %orig(modifiedRequest, newCompletionHandler);
    }
    return %orig;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    ApolloCaptureRedditBearerTokenFromRequest(request, @"NSURLSession uploadTaskWithRequest:fromData:");

    if (!sUseRedditNativeImageUpload || !completionHandler || !ApolloIsImgurImageUploadRequest(request)) {
        return %orig;
    }

    ApolloLog(@"[RedditUpload] Upload hook matched data upload: tokenCached=%@", sLatestRedditBearerToken.length > 0 ? @"yes" : @"no");

    if (sLatestRedditBearerToken.length == 0) {
        ApolloLog(@"[RedditUpload] No captured Reddit bearer token yet; using Imgur upload");
        return %orig;
    }

    NSString *mimeType = ApolloMediaMIMETypeForFilename(nil, [request valueForHTTPHeaderField:@"Content-Type"]);
    NSString *extension = @"jpg";
    if ([mimeType isEqualToString:@"image/png"]) extension = @"png";
    else if ([mimeType isEqualToString:@"image/gif"]) extension = @"gif";
    else if ([mimeType isEqualToString:@"video/mp4"]) extension = @"mp4";
    else if ([mimeType isEqualToString:@"video/quicktime"]) extension = @"mov";
    NSString *filename = [@"apollo-upload" stringByAppendingPathExtension:extension];

    ApolloLog(@"[RedditUpload] Intercepting Imgur data upload (%lu bytes)", (unsigned long)bodyData.length);

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        ApolloCompleteRedditNativeImageUpload(bodyData, filename, mimeType, request.URL, completionHandler);
    };
    return %orig(ApolloRedditUploadFastFailRequest(), bodyData ?: [NSData data], wrappedHandler);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    ApolloCaptureRedditBearerTokenFromRequest(request, @"NSURLSession uploadTaskWithRequest:fromFile:");

    if (!sUseRedditNativeImageUpload || !completionHandler || !ApolloIsImgurImageUploadRequest(request)) {
        return %orig;
    }

    ApolloLog(@"[RedditUpload] Upload hook matched file upload: tokenCached=%@", sLatestRedditBearerToken.length > 0 ? @"yes" : @"no");

    if (sLatestRedditBearerToken.length == 0) {
        ApolloLog(@"[RedditUpload] No captured Reddit bearer token yet; using Imgur upload");
        return %orig;
    }

    NSString *filename = fileURL.lastPathComponent.length > 0 ? fileURL.lastPathComponent : @"apollo-upload.jpg";
    NSString *mimeType = ApolloMediaMIMETypeForFilename(filename, [request valueForHTTPHeaderField:@"Content-Type"]);

    ApolloLog(@"[RedditUpload] Intercepting Imgur file upload: %@", filename);

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        NSError *readError = nil;
        NSData *imageData = [NSData dataWithContentsOfURL:fileURL options:0 error:&readError];
        if (readError || imageData.length == 0) {
            ApolloLog(@"[RedditUpload] Could not read upload file: %@", readError.localizedDescription);
            completionHandler(nil, nil, readError ?: [NSError errorWithDomain:@"ApolloRedditMediaUpload" code:51 userInfo:@{NSLocalizedDescriptionKey: @"Upload file was empty"}]);
            return;
        }
        ApolloCompleteRedditNativeImageUpload(imageData, filename, mimeType, request.URL, completionHandler);
    };
    return %orig(ApolloRedditUploadFastFailRequest(), fileURL, wrappedHandler);
}

// "Unproxy" Imgur requests
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if ([url.host isEqualToString:@"apollogur.download"]) {
        NSString *imageID = [url.lastPathComponent stringByDeletingPathExtension];

        if (sProxyImgurDDG && [url.path hasPrefix:@"/api/image"]) {
            // Fabricate an API response with a DDG-proxied link, skipping api.imgur.com
            // entirely (also regionally blocked). .jpg is a neutral default; Imgur serves
            // the correct format regardless and DDG handles both static and animated content.
            NSString *imgurJPG = [NSString stringWithFormat:@"https://i.imgur.com/%@.jpg", imageID];
            NSString *ddgProxied = [@"https://external-content.duckduckgo.com/iu/?u=" stringByAppendingString:
                [imgurJPG stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

            // Match the real Imgur API shape so Unbox's required-key decoding succeeds.
            NSDictionary *syntheticResponse = @{
                @"status": @200,
                @"success": @YES,
                @"data": @{
                    @"id": imageID,
                    @"deletehash": @"",
                    @"account_id": [NSNull null],
                    @"account_url": [NSNull null],
                    @"ad_type": [NSNull null],
                    @"ad_url": [NSNull null],
                    @"title": [NSNull null],
                    @"description": [NSNull null],
                    @"name": @"",
                    @"type": @"image/jpeg",
                    @"width": @1920,
                    @"height": @1080,
                    @"size": @0,
                    @"views": @0,
                    @"section": [NSNull null],
                    @"vote": [NSNull null],
                    @"bandwidth": @0,
                    @"animated": @NO,
                    @"favorite": @NO,
                    @"in_gallery": @NO,
                    @"in_most_viral": @NO,
                    @"has_sound": @NO,
                    @"is_ad": @NO,
                    @"nsfw": [NSNull null],
                    @"link": ddgProxied,
                    @"tags": @[],
                    @"datetime": @0,
                    @"mp4": @"",
                    @"hls": @""
                }
            };
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:syntheticResponse options:0 error:nil];
            NSHTTPURLResponse *fakeHTTPResponse = [[NSHTTPURLResponse alloc] initWithURL:url
                                                                              statusCode:200
                                                                             HTTPVersion:@"HTTP/1.1"
                                                                            headerFields:@{@"Content-Type": @"application/json"}];

            ApolloLog(@"[ImgurProxy] Fabricating response for %@", imageID);

            // Route the task to a fast-failing URL; wrapper delivers the synthetic data.
            void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {
                completionHandler(jsonData, fakeHTTPResponse, nil);
            };
            return %orig([NSURL URLWithString:@"http://127.0.0.1:1"], wrappedHandler);
        }

        NSURL *modifiedURL;

        if ([url.path hasPrefix:@"/api/image"]) {
            // Access the modified URL to get the actual data
            modifiedURL = [NSURL URLWithString:[@"https://api.imgur.com/3/image/" stringByAppendingString:imageID]];
        } else if ([url.path hasPrefix:@"/api/album"]) {
            // Parse new URL format with title (/album/some-album-title-<albumid>)
            NSRange range = [imageID rangeOfString:@"-" options:NSBackwardsSearch];
            if (range.location != NSNotFound) {
                imageID = [imageID substringFromIndex:range.location + 1];
            }
            modifiedURL = [NSURL URLWithString:[@"https://api.imgur.com/3/album/" stringByAppendingString:imageID]];
        }

        if (modifiedURL) {
            return %orig(modifiedURL, completionHandler);
        }
    }
    return %orig;
}

%new
- (BOOL)isJSONResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];
        if (contentType && [contentType rangeOfString:@"application/json" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

%end

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)viewControllerToPresent;
        NSDictionary *submitInfo = nil;
        if (ApolloShouldSuppressFalseRedditNativeSubmitAlert(alert.title, alert.message, &submitInfo)) {
            ApolloLog(@"[RedditUpload] Suppressed false native submit alert assetID=%@ sr=%@ alertTitle=%@ secondsRemaining=%.1f",
                      submitInfo[@"assetID"] ?: @"(missing)",
                      submitInfo[@"subreddit"] ?: @"(missing)",
                      alert.title ?: @"(missing)",
                      [submitInfo[@"secondsRemaining"] doubleValue]);
            ApolloShowRedditNativeSubmitBannerIfReady();
            if (completion) {
                completion();
            }
            return;
        }
    }

    %orig;
}

%end

// Implementation derived from https://github.com/EthanArbuckle/Apollo-CustomApiCredentials/blob/main/Tweak.m
// Credits to @EthanArbuckle for the original implementation

@interface __NSCFLocalSessionTask : NSObject <NSCopying, NSProgressReporting>
@end

%hook __NSCFLocalSessionTask

- (void)_onqueue_resume {
    // Grab the request url
    NSURLRequest *request =  [self valueForKey:@"_originalRequest"];
    NSURLRequest *currentRequest = [self valueForKey:@"_currentRequest"];
    ApolloCaptureRedditBearerTokenFromRequest(request, @"__NSCFLocalSessionTask _originalRequest");
    ApolloCaptureRedditBearerTokenFromRequest(currentRequest, @"__NSCFLocalSessionTask _currentRequest");

    NSURLRequest *redditMediaRequest = ApolloRequestByRewritingRedditMediaSubmit(request) ?: ApolloRequestByRewritingRedditMediaSubmit(currentRequest);
    if (!redditMediaRequest) {
        redditMediaRequest = ApolloRequestByRewritingRedditMediaComment(request) ?: ApolloRequestByRewritingRedditMediaComment(currentRequest);
    }
    if (redditMediaRequest) {
        [self setValue:redditMediaRequest forKey:@"_originalRequest"];
        [self setValue:redditMediaRequest forKey:@"_currentRequest"];
        request = redditMediaRequest;
    } else if (!request) {
        request = currentRequest;
    }

    NSURL *requestURL = request.URL;
    NSString *requestString = requestURL.absoluteString;

    // Drop blocked URLs
    for (NSString *blockedUrl in blockedUrls) {
        if ([requestString containsString:blockedUrl]) {
            return;
        }
    }
    if (sBlockAnnouncements && [requestString containsString:announcementUrl]) {
        return;
    }

    // Redirect RapidAPI-proxied Imgur requests to direct Imgur API.
    // This handles upload tasks (where body data is attached to the task, not the request)
    // as well as any other Imgur requests not caught by NSURLSession data task hooks.
    if ([requestURL.host isEqualToString:@"imgur-apiv3.p.rapidapi.com"]) {
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        NSString *newURLString = [requestString stringByReplacingOccurrencesOfString:@"imgur-apiv3.p.rapidapi.com" withString:@"api.imgur.com"];
        [mutableRequest setURL:[NSURL URLWithString:newURLString]];
        [mutableRequest setValue:[@"Client-ID " stringByAppendingString:sImgurClientId] forHTTPHeaderField:@"Authorization"];
        StripRapidAPIHeaders(mutableRequest);
        if ([requestURL.path isEqualToString:@"/3/image"]) {
            [mutableRequest setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
        }
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    } else if ([requestURL.host isEqualToString:@"api.imgur.com"]) {
        // Already redirected — either by the branch above (re-entry) or by NSURLSession
        // data task hooks (album creation, apollogur unproxy).
        // Only modify if auth not already set: redundant mutableCopy+setValue on upload
        // tasks disrupts the internal body data reference, causing empty uploads.
        NSString *existingAuth = [request valueForHTTPHeaderField:@"Authorization"];
        if (![existingAuth hasPrefix:@"Client-ID "]) {
            NSMutableURLRequest *mutableRequest = [request mutableCopy];
            [mutableRequest setValue:[@"Client-ID " stringByAppendingString:sImgurClientId] forHTTPHeaderField:@"Authorization"];
            StripRapidAPIHeaders(mutableRequest);
            if ([requestURL.path isEqualToString:@"/3/image"]) {
                [mutableRequest setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
            }
            [self setValue:mutableRequest forKey:@"_originalRequest"];
            [self setValue:mutableRequest forKey:@"_currentRequest"];
        }
    } else if ([requestURL.host isEqualToString:@"oauth.reddit.com"] || [requestURL.host isEqualToString:@"www.reddit.com"]) {
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        NSString *customUA = [sUserAgent length] > 0 ? sUserAgent : defaultUserAgent;
        [mutableRequest setValue:customUA forHTTPHeaderField:@"User-Agent"];
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
    } else if (sProxyImgurDDG
               && ([requestURL.host isEqualToString:@"imgur.com"] || [requestURL.host hasSuffix:@".imgur.com"])
               && ![requestURL.host isEqualToString:@"api.imgur.com"]) {
        // Proxy direct Imgur content URLs through DuckDuckGo. DDG can't serve .mp4/.gifv,
        // so rewrite those to .gif first.
        NSString *imgurURL = requestString;
        if ([imgurURL hasSuffix:@".mp4"] || [imgurURL hasSuffix:@".gifv"]) {
            imgurURL = [[imgurURL stringByDeletingPathExtension] stringByAppendingPathExtension:@"gif"];
        }
        NSString *proxyURLString = [@"https://external-content.duckduckgo.com/iu/?u=" stringByAppendingString:
            [imgurURL stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
        NSMutableURLRequest *mutableRequest = [request mutableCopy];
        [mutableRequest setURL:[NSURL URLWithString:proxyURLString]];
        [self setValue:mutableRequest forKey:@"_originalRequest"];
        [self setValue:mutableRequest forKey:@"_currentRequest"];
        ApolloLog(@"[ImgurProxy] Proxying %@ via DuckDuckGo", requestString);
    }

    %orig;
}

%end

// Unlock "Artificial Superintelligence" Pixel Pal (normally requires Carrot Weather app installed)
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if ([[url scheme] isEqualToString:@"carrotweather"]) {
        return YES;
    }
    return %orig;
}
%end

// --- Dynamic Island frame correction for newer devices ---
// All DI element positions are hardcoded for iPhone 14 Pro (safeAreaInsets.top=59):
//   sub_10030afa0: FauxCutOutView y=11.5, w=125, h=37
//   sub_10030c880: PixelPalView y=-2.0
//   sub_10030d6c4: tap overlay y=11.0, w=125, h=37, cornerRadius=18.5
// On devices with different safe area insets, compute the correct DI Y position.
// The gap between DI bottom and safe area scales proportionally with safeTop.
// Y is floored to the nearest half-pixel to match the baseline's sub-pixel alignment.
%hook _TtC6Apollo15ThemeableWindow

- (void)layoutSubviews {
    %orig;

    UIWindow *window = (UIWindow *)self;
    CGFloat nativeScale = [UIScreen mainScreen].nativeScale;
    if (nativeScale != [UIScreen mainScreen].scale) return;

    CGFloat safeTop = window.safeAreaInsets.top;
    if (safeTop < 50.0 || fabs(safeTop - 59.0) < 0.5) return;

    // Compute correct Y: gap scales proportionally, floor to half-pixel.
    // Baseline (14 Pro): safeTop=59, y=11.5, gap=10.5, y at half-pixel (34.5px@3x).
    CGFloat scaledGap = 10.5 * safeTop / 59.0;
    CGFloat halfPx = 0.5 / nativeScale;
    CGFloat correctY = floor((safeTop - 37.0 - scaledGap) / halfPx) * halfPx;
    CGFloat shift = correctY - 11.5;

    // Shift FauxCutOutView — %orig sets y=11.5 via sub_10030afa0
    Ivar fauxIvar = class_getInstanceVariable(object_getClass(self), "fauxCutOutView");
    if (!fauxIvar) return;
    UIView *fauxView = object_getIvar(self, fauxIvar);
    if (!fauxView || CGRectIsEmpty(fauxView.frame)) return;

    CGRect fauxFrame = fauxView.frame;
    if (fabs(fauxFrame.origin.y - 11.5) < 0.5) {
        fauxFrame.origin.y = correctY;
        fauxView.frame = fauxFrame;

        // Clip to continuous (squircle) corners to match hardware DI shape
        fauxView.clipsToBounds = YES;
        fauxView.layer.cornerRadius = CGRectGetHeight(fauxView.bounds) * 0.5;
        fauxView.layer.cornerCurve = kCACornerCurveContinuous;

        ApolloLog(@"[PixelPals] FauxCutOutView y: 11.5 → %.3f (safeTop=%.1f, gap=%.3f, shift=%.3f)",
                  correctY, safeTop, scaledGap, shift);
    }

    // Shift PixelPalView — %orig sets y=-2.0 via sub_10030c880
    Ivar palIvar = class_getInstanceVariable(object_getClass(self), "pixelPalView");
    if (!palIvar) return;
    UIView *palView = object_getIvar(self, palIvar);
    if (!palView || CGRectIsEmpty(palView.frame)) return;

    CGRect palFrame = palView.frame;
    if (fabs(palFrame.origin.y - (-2.0)) < 0.5) {
        palFrame.origin.y = -2.0 + shift;
        palView.frame = palFrame;
        ApolloLog(@"[PixelPals] PixelPalView y: -2.0 → %.3f", palFrame.origin.y);
    }
}

// Tap overlay (sub_10030d6c4) — created at y=11.0, 125×37, cornerRadius=18.5
- (void)addSubview:(UIView *)view {
    %orig;

    UIWindow *window = (UIWindow *)self;
    CGFloat safeTop = window.safeAreaInsets.top;
    if (safeTop < 50.0 || fabs(safeTop - 59.0) < 0.5) return;
    CGFloat nativeScale = [UIScreen mainScreen].nativeScale;
    if (nativeScale != [UIScreen mainScreen].scale) return;

    if (![view isMemberOfClass:[UIView class]]) return;
    CGRect f = view.frame;
    if (fabs(f.size.width - 125.0) > 0.5 || fabs(f.size.height - 37.0) > 0.5) return;
    if (!view.clipsToBounds || view.layer.cornerRadius < 18.0) return;

    CGFloat scaledGap = 10.5 * safeTop / 59.0;
    CGFloat halfPx = 0.5 / nativeScale;
    CGFloat correctY = floor((safeTop - 37.0 - scaledGap) / halfPx) * halfPx;
    CGFloat shift = correctY - 11.5;

    ApolloLog(@"[PixelPals] Tap overlay y: %.1f → %.3f", f.origin.y, f.origin.y + shift);
    f.origin.y += shift;
    view.frame = f;
}

%end

// Reddit API can returns "error" as a dict (e.g. {"reason":"UNAUTHORIZED",...})
// instead of a numeric code. Multiple Apollo code paths call [dict[@"error"] integerValue]
// on the response, including unhookable block invokes. Adding integerValue to NSDictionary
// prevents the unrecognized selector crash everywhere; returning 0 means no error code
// matches, so normal error handling proceeds.
%hook NSDictionary
%new
- (NSInteger)integerValue {
    return 0;
}
%end

// Pre-fetches random subreddit lists in background
static void initializeRandomSources() {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *sources = @[sRandNsfwSubredditsSource, sRandomSubredditsSource];
        for (NSString *source in sources) {
            if (![source length]) {
                continue;
            }
            NSURL *subredditListURL = [NSURL URLWithString:source];
            NSError *error = nil;
            NSString *subredditListContent = [NSString stringWithContentsOfURL:subredditListURL encoding:NSUTF8StringEncoding error:&error];
            if (error) {
                continue;
            }

            NSArray<NSString *> *subreddits = [subredditListContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            subreddits = [subreddits filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
            if (subreddits.count == 0) {
                continue;
            }

            [subredditListCache setObject:subredditListContent forKey:subredditListURL.absoluteString];
        }
    });
}

// MARK: - Constructor
%ctor {
    subredditListCache = [NSCache new];

    NSDictionary *defaultValues = @{UDKeyBlockAnnouncements: @YES,
                                    UDKeyEnableFLEX: @NO,
                                    UDKeyTrendingSubredditsLimit: @"5",
                                    UDKeyShowRandNsfw: @NO,
                                    UDKeyRandomSubredditsSource: defaultRandomSubredditsSource,
                                    UDKeyRandNsfwSubredditsSource: @"",
                                    UDKeyTrendingSubredditsSource: defaultTrendingSubredditsSource,
                                    UDKeyReadPostMaxCount: @0,
                                    UDKeyShowRecentlyReadThumbnails: @YES,
                                    UDKeyPreferredGIFFallbackFormat: @1,
                                    UDKeyUnmuteCommentsVideos: @0,
                                    UDKeyProxyImgurDDG: @NO,
                                    UDKeyUseRedditNativeImageUpload: @NO,
                                    UDKeyEnableBulkTranslation: @NO,
                                    UDKeyAutoTranslateOnAppear: @YES,
                                    UDKeyTranslatePostTitles: @NO,
                                    UDKeyTranslationTargetLanguage: @"",
                                    UDKeyTranslationProviderUserSelected: @NO,
                                    UDKeyLibreTranslateURL: @"https://libretranslate.de/translate",
                                    UDKeyLibreTranslateAPIKey: @"",
                                    UDKeyTranslationSkipLanguages: @[],
                                    UDKeyTagFilterEnabled: @NO,
                                    UDKeyTagFilterMode: @"blur",
                                    UDKeyTagFilterNSFW: @YES,
                                    UDKeyTagFilterSpoiler: @YES,
                                    UDKeyTagFilterSubredditOverrides: @{}};
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaultValues];

    sRedditClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedditClientId] ?: @"" copy];
    sImgurClientId = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyImgurClientId] ?: @"" copy];
    sRedirectURI = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRedirectURI] ?: @"" copy];
    sUserAgent = (NSString *)[[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyUserAgent] ?: @"" copy];
    sBlockAnnouncements = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyBlockAnnouncements];
    sShowRecentlyReadThumbnails = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyShowRecentlyReadThumbnails];
    sPreferredGIFFallbackFormat = ([[NSUserDefaults standardUserDefaults] integerForKey:UDKeyPreferredGIFFallbackFormat] == 0) ? 0 : 1;
    sReadPostMaxCount = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyReadPostMaxCount];
    sUnmuteCommentsVideos = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyUnmuteCommentsVideos];
    sProxyImgurDDG = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyProxyImgurDDG];
    sUseRedditNativeImageUpload = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseRedditNativeImageUpload];
    sEnableBulkTranslation = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableBulkTranslation];
    sAutoTranslateOnAppear = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutoTranslateOnAppear];
    sTranslatePostTitles = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTranslatePostTitles];

    NSString *targetLanguage = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTranslationTargetLanguage];
    sTranslationTargetLanguage = [targetLanguage length] > 0 ? [targetLanguage copy] : nil;

    // Provider: only "google" or "libre" are supported. Migrate any older
    // "apple" value to "google" so existing users land on a working provider.
    NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSDictionary *persistentDomain = bundleID.length > 0 ? [standardDefaults persistentDomainForName:bundleID] : nil;
    id providerValue = [persistentDomain objectForKey:UDKeyTranslationProvider];
    NSString *provider = [providerValue isKindOfClass:[NSString class]] ? (NSString *)providerValue : nil;

    if ([provider isEqualToString:@"libre"]) {
        sTranslationProvider = @"libre";
    } else if ([provider isEqualToString:@"google"]) {
        sTranslationProvider = @"google";
    } else {
        // Unset, unrecognized, or legacy "apple" — default to Google.
        sTranslationProvider = @"google";
        [standardDefaults setObject:sTranslationProvider forKey:UDKeyTranslationProvider];
        [standardDefaults setBool:NO forKey:UDKeyTranslationProviderUserSelected];
    }

    NSString *libreURL = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyLibreTranslateURL];
    sLibreTranslateURL = [libreURL length] > 0 ? [libreURL copy] : @"https://libretranslate.de/translate";

    NSString *libreAPIKey = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyLibreTranslateAPIKey];
    sLibreTranslateAPIKey = [libreAPIKey length] > 0 ? [libreAPIKey copy] : nil;

    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTranslationSkipLanguages];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        if ([raw isKindOfClass:[NSArray class]]) {
            for (id v in (NSArray *)raw) {
                if (![v isKindOfClass:[NSString class]]) continue;
                NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
                if (s.length == 0) continue;
                NSRange dash = [s rangeOfString:@"-"];
                NSRange under = [s rangeOfString:@"_"];
                NSUInteger split = NSNotFound;
                if (dash.location != NSNotFound) split = dash.location;
                if (under.location != NSNotFound) split = (split == NSNotFound) ? under.location : MIN(split, under.location);
                if (split != NSNotFound && split > 0) s = [s substringToIndex:split];
                if (s.length > 0 && ![clean containsObject:s]) [clean addObject:s];
            }
        }
        sTranslationSkipLanguages = [clean copy];
    }

    // Tag filter feature hydration.
    sTagFilterEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterEnabled];
    sTagFilterNSFW = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterNSFW];
    sTagFilterSpoiler = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyTagFilterSpoiler];
    {
        NSString *mode = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTagFilterMode];
        if ([mode isKindOfClass:[NSString class]] && ([mode isEqualToString:@"hide"] || [mode isEqualToString:@"blur"])) {
            sTagFilterMode = [mode copy];
        } else {
            sTagFilterMode = @"blur";
        }
    }
    {
        id raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTagFilterSubredditOverrides];
        NSMutableDictionary<NSString *, NSDictionary *> *clean = [NSMutableDictionary dictionary];
        if ([raw isKindOfClass:[NSDictionary class]]) {
            for (id key in (NSDictionary *)raw) {
                if (![key isKindOfClass:[NSString class]]) continue;
                NSString *sub = [(NSString *)key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
                if (sub.length == 0) continue;
                id v = ((NSDictionary *)raw)[key];
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                clean[sub] = (NSDictionary *)v;
            }
        }
        sTagFilterSubredditOverrides = [clean copy];
    }

    // Trim ReadPostIDs if over configured max
    if (sReadPostMaxCount > 0) {
        NSArray *postIDs = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"ReadPostIDs"];
        if (postIDs && (NSInteger)postIDs.count > sReadPostMaxCount) {
            NSArray *trimmed = [postIDs subarrayWithRange:NSMakeRange(postIDs.count - (NSUInteger)sReadPostMaxCount, (NSUInteger)sReadPostMaxCount)];
            [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:@"ReadPostIDs"];
            ApolloLog(@"[RecentlyRead] Trimmed ReadPostIDs from %lu to %ld entries", (unsigned long)postIDs.count, (long)sReadPostMaxCount);
        }
    }

    sRandomSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRandomSubredditsSource];
    sRandNsfwSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyRandNsfwSubredditsSource];
    sTrendingSubredditsSource = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTrendingSubredditsSource];
    sTrendingSubredditsLimit = (NSString *)[[NSUserDefaults standardUserDefaults] objectForKey:UDKeyTrendingSubredditsLimit];

    %init;
    ApolloLogPostSubmitWatcherTypeEncoding();

    // Ultra pre-migration
    [[NSUserDefaults standardUserDefaults] setObject:@"ya" forKey:@"awesome_notifications"];

    NSUserDefaults *sharedSuite = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"];
    if (sharedSuite) {
        // Ultra/Pro flags
        [sharedSuite setBool:YES forKey:@"UMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"ProMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"SPMigrationOccurred"];
        [sharedSuite setBool:YES forKey:@"CommMigrationOccurred"];

        // Secret icon flags
        [sharedSuite setBool:YES forKey:@"HasUnlockedBeanVault"];  // Beans (Black Friday 2022)
        [sharedSuite setBool:YES forKey:@"SlothkunUnlocked"];      // Slothkun
        [sharedSuite setBool:YES forKey:@"iJustineUnlocked"];      // iJustine (sekrit: wrappingpaper)
        [sharedSuite setBool:YES forKey:@"UnitedStatesUnlocked"];  // America! (sekrit: america)
        [sharedSuite setBool:YES forKey:@"UnitedStates2Unlocked"]; // Super America (sekrit: superamerica)
        [sharedSuite setBool:YES forKey:@"UnitedKingdomUnlocked"]; // UK (sekrit: hughlaurie)
        [sharedSuite setBool:YES forKey:@"TLDTodayUnlocked"];      // Yo. Jonathan Here. (sekrit: tld/jellyfish/crispy)
        [sharedSuite setBool:YES forKey:@"ApolloBookProUnlocked"]; // ApolloBook Pro (sekrit: apollobookpro)
        [sharedSuite setBool:YES forKey:@"UnlockedWallpapers"];    // Wallpapers
        [sharedSuite setBool:YES forKey:@"ATPUnlocked"];           // ATP (sekrit: atp)
        [sharedSuite setBool:YES forKey:@"PhilUnlocked"];          // Phil Schiller (sekrit: phil/throatpunch)
        [sharedSuite setBool:YES forKey:@"CanadaUnlocked"];        // Canada D'Eh (sekrit: canadadeh)
        [sharedSuite setBool:YES forKey:@"UkraineUnlocked"];       // Ukraine (sekrit: ukraine)
        [sharedSuite setBool:YES forKey:@"ErnestUnlocked"];        // Ernest (sekrit: ernest)
        [sharedSuite setBool:YES forKey:@"SusUnlocked"];           // Sus/Among Us (sekrit: sus)
        [sharedSuite setBool:YES forKey:@"Dave2DUnlocked"];        // Dave2D (sekrit: dave2d)
        [sharedSuite setBool:YES forKey:@"MKBHDUnlocked"];         // MKBHD (sekrit: keith)
        [sharedSuite setBool:YES forKey:@"PeachyUnlocked"];        // Peachy (sekrit: neonpeach)
        [sharedSuite setBool:YES forKey:@"LinusUnlocked"];         // Linus Tech Tips (sekrit: livelaughliao)
        [sharedSuite setBool:YES forKey:@"AndruUnlocked"];         // Andru Edwards (sekrit: andru/prowrestler)
        [sharedSuite setBool:YES forKey:@"EAPUnlocked"];           // Icons Drop Test (sekrit: everythingapplepro)
        [sharedSuite setBool:YES forKey:@"ReneUnlocked"];          // Rene Ritchie (sekrit: rene/montrealbagels)
        [sharedSuite setBool:YES forKey:@"SnazzyUnlocked"];        // Snazzy Labs (sekrit: margaret)
    }

    // Unlock Chumbus theme (normally requires 1000 boop button taps in Theme Settings)
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"airprint-active"];

    // Suppress wallpaper prompt
    NSDate *dateIn90d = [NSDate dateWithTimeIntervalSinceNow:60*60*24*90];
    [[NSUserDefaults standardUserDefaults] setObject:dateIn90d forKey:@"WallpaperPromptMostRecent2"];

    // Sideload fixes
    rebind_symbols((struct rebinding[4]) {
        {"SecItemAdd", (void *)SecItemAdd_replacement, (void **)&SecItemAdd_orig},
        {"SecItemCopyMatching", (void *)SecItemCopyMatching_replacement, (void **)&SecItemCopyMatching_orig},
        {"SecItemUpdate", (void *)SecItemUpdate_replacement, (void **)&SecItemUpdate_orig},
        {"uname", (void *)uname_replacement, (void **)&uname_orig}
    }, 4);

    if ([[NSUserDefaults standardUserDefaults] boolForKey:UDKeyEnableFLEX]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[%c(FLEXManager) performSelector:@selector(sharedManager)] performSelector:@selector(showExplorer)];
        });
    }

    initializeRandomSources();

    // Redirect user to Custom API settings if no API credentials are set
    if ([sRedditClientId length] == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *mainWindow = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).windows.firstObject;
            UITabBarController *tabBarController = (UITabBarController *)mainWindow.rootViewController;
            // Navigate to Settings tab
            tabBarController.selectedViewController = [tabBarController.viewControllers lastObject];
            UINavigationController *settingsNavController = (UINavigationController *) tabBarController.selectedViewController;

            // Push Custom API directly
            CustomAPIViewController *vc = [[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            [settingsNavController pushViewController:vc animated:YES];
        });
    }
}
