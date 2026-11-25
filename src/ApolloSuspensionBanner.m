#import "ApolloSuspensionBanner.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloAccountSuspension.h"
#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWebJSON.h" // ApolloWebJSONOptionalReadBackoff
#import "UserDefaultConstants.h" // UDKeyAccountSuspensions

// The red of the bar on Reddit's website. Fixed rather than themed: it marks an
// account problem, and white text keeps a 6:1 contrast on it in light and dark.
static UIColor *ApolloSuspensionBannerRed(void) {
    return [UIColor colorWithRed:0.69 green:0.165 blue:0.12 alpha:1.0];
}

// How often the banner may go up is ApolloSuspensionBannerIsDue's call
// (ApolloAccountSuspension.h): an unprompted one (launch, a return to the app,
// an account switch) once per account every six hours, with Reddit's answer
// about the account changing starting that over; a limit once when it starts,
// and once more on coming back to the app after a while away during it.
// The banner goes in the app's window, under anything presented over it (the
// What's New sheet at launch, the account switcher, a composer, an alert) and
// under the Touch ID & Passcode lock. A request made while the screen is
// covered waits for it to clear, checking this often, for at most this many
// checks (five minutes), then gives up.
static const NSTimeInterval kApolloSuspensionBannerCoveredCheckInterval = 0.75;
static const NSUInteger kApolloSuspensionBannerCoveredChecks = 400;

@interface ApolloSuspensionBannerView : UIView
@property (nonatomic, copy) NSString *account;            // lowercased username it was shown for
@property (nonatomic, copy) dispatch_block_t tapHandler;
@property (nonatomic, copy) dispatch_block_t dismissHandler;
@end

@implementation ApolloSuspensionBannerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_swipedUp:)];
        swipe.direction = UISwipeGestureRecognizerDirectionUp;
        [self addGestureRecognizer:swipe];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_tapped:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)apollo_swipedUp:(__unused UISwipeGestureRecognizer *)recognizer {
    if (self.dismissHandler) self.dismissHandler();
}

- (void)apollo_tapped:(__unused UITapGestureRecognizer *)recognizer {
    if (self.tapHandler) self.tapHandler();
}

// VoiceOver's double tap.
- (BOOL)accessibilityActivate {
    if (!self.tapHandler) return NO;
    self.tapHandler();
    return YES;
}

@end

// Main thread only, like everything below.
static __weak ApolloSuspensionBannerView *sApolloSuspensionBanner = nil;
// Lowercased username -> when its banner last went up (timeIntervalSinceReferenceDate).
static NSMutableDictionary<NSString *, NSNumber *> *sApolloSuspensionBannerShownAt = nil;
// Lowercased username -> when the limit its banner last named resets (same
// clock), so that limit is announced once.
static NSMutableDictionary<NSString *, NSNumber *> *sApolloSuspensionBannerAnnouncedLimitEnd = nil;

static UIWindow *ApolloSuspensionBannerWindow(void) {
    UIWindow *keyWindow = ApolloKeyWindow();
    if (keyWindow && !keyWindow.isHidden) return keyWindow;
    for (UIWindow *window in ApolloAllWindows()) {
        if (!window.isHidden && window.windowScene.activationState == UISceneActivationStateForegroundActive) return window;
    }
    return nil;
}

static void ApolloSuspensionBannerDismiss(ApolloSuspensionBannerView *banner, BOOL animated) {
    if (!banner || banner.superview == nil) return;
    banner.tapHandler = nil;
    banner.dismissHandler = nil;
    if (sApolloSuspensionBanner == banner) sApolloSuspensionBanner = nil;
    if (!animated) {
        [banner removeFromSuperview];
        return;
    }
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    CGFloat lift = CGRectGetMaxY(banner.frame) + 12.0;
    [UIView animateWithDuration:reduceMotion ? 0.15 : 0.25
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        if (reduceMotion) banner.alpha = 0.0;
        else banner.transform = CGAffineTransformMakeTranslation(0.0, -lift);
    } completion:^(__unused BOOL finished) {
        [banner removeFromSuperview];
    }];
}

// Reddit's message about the suspension is a private message from u/reddit, so
// a tap goes to the Inbox tab. The tab is found by its item's name, the same
// identity ApolloChatsFilter uses for its badge: an icon-only tab bar drops the
// title and keeps the name in the accessibility label.
static void ApolloSuspensionBannerOpenInbox(UIWindow *window) {
    UIViewController *tabs = ApolloMainTabBarControllerForScene(window.windowScene);
    if (![tabs isKindOfClass:[UITabBarController class]]) {
        ApolloLog(@"[Suspension] banner tapped; no tab bar controller to open the Inbox in");
        return;
    }
    // Something is presented over the tabs (a composer, Settings): switching
    // the tab underneath would only confuse where it's dismissed to.
    if (tabs.presentedViewController) {
        ApolloLog(@"[Suspension] banner tapped under a presented screen; leaving the tabs alone");
        return;
    }
    UITabBarController *tabBarController = (UITabBarController *)tabs;
    for (UIViewController *child in tabBarController.viewControllers) {
        UITabBarItem *item = child.tabBarItem;
        NSString *name = item.title.length > 0 ? item.title : item.accessibilityLabel;
        if (name.length == 0 || [name caseInsensitiveCompare:@"Inbox"] != NSOrderedSame) continue;
        tabBarController.selectedViewController = child;
        ApolloLog(@"[Suspension] banner tapped; Inbox tab selected");
        return;
    }
    ApolloLog(@"[Suspension] banner tapped; Inbox tab not found among %lu tabs", (unsigned long)tabBarController.viewControllers.count);
}

static void ApolloSuspensionBannerPresent(NSString *account, NSString *title, NSString *detail, UIWindow *window) {
    ApolloSuspensionBannerDismiss(sApolloSuspensionBanner, NO);

    ApolloSuspensionBannerView *banner = [[ApolloSuspensionBannerView alloc] initWithFrame:CGRectZero];
    banner.account = account;
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.backgroundColor = ApolloSuspensionBannerRed();
    banner.layer.cornerRadius = 14.0;
    banner.layer.cornerCurve = kCACornerCurveContinuous;
    banner.layer.shadowColor = UIColor.blackColor.CGColor;
    banner.layer.shadowOpacity = 0.22;
    banner.layer.shadowRadius = 10.0;
    banner.layer.shadowOffset = CGSizeMake(0.0, 4.0);
    banner.isAccessibilityElement = YES;
    banner.accessibilityTraits = UIAccessibilityTraitButton;
    banner.accessibilityLabel = detail.length > 0 ? [NSString stringWithFormat:@"%@. %@", title, detail] : title;
    banner.accessibilityHint = @"Opens your inbox";
    [window addSubview:banner];
    sApolloSuspensionBanner = banner;

    UIImageSymbolConfiguration *glyphConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.octagon.fill" withConfiguration:glyphConfiguration]];
    glyph.tintColor = UIColor.whiteColor;
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    [glyph setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [glyph setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = ApolloThemeRuntimeFont([UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]);
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.numberOfLines = 1;
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.8;
    titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel ]];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = 2.0;
    if (detail.length > 0) {
        UILabel *detailLabel = [[UILabel alloc] init];
        detailLabel.text = detail;
        detailLabel.font = ApolloThemeRuntimeFont([UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular]);
        detailLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
        detailLabel.numberOfLines = 2;
        [text addArrangedSubview:detailLabel];
    }

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ glyph, text ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.userInteractionEnabled = NO;
    [banner addSubview:row];

    UILayoutGuide *safe = window.safeAreaLayoutGuide;
    // As wide as the screen allows up to a comfortable reading width, centered
    // in the safe area (clear of the Duo's side rail and the notch in landscape).
    NSLayoutConstraint *fill = [banner.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-20.0];
    fill.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
        [row.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0],
        [row.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14.0],
        [row.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-14.0],
        [banner.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6.0],
        [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [banner.widthAnchor constraintLessThanOrEqualToConstant:560.0],
        [banner.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:10.0],
        [banner.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-10.0],
        fill,
    ]];
    [window layoutIfNeeded];

    __weak ApolloSuspensionBannerView *weakBanner = banner;
    __weak UIWindow *weakWindow = window;
    banner.dismissHandler = ^{
        ApolloSuspensionBannerDismiss(weakBanner, YES);
    };
    banner.tapHandler = ^{
        UIWindow *strongWindow = weakWindow;
        ApolloSuspensionBannerDismiss(weakBanner, YES);
        if (strongWindow) ApolloSuspensionBannerOpenInbox(strongWindow);
    };

    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    if (reduceMotion) banner.alpha = 0.0;
    else banner.transform = CGAffineTransformMakeTranslation(0.0, -(CGRectGetMaxY(banner.frame) + 12.0));
    [UIView animateWithDuration:reduceMotion ? 0.18 : 0.45
                          delay:0.0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        banner.alpha = 1.0;
        banner.transform = CGAffineTransformIdentity;
    } completion:nil];

    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeWarning];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, banner.accessibilityLabel);

    // Two lines to read, and it explains something the user didn't expect.
    NSTimeInterval visible = UIAccessibilityIsVoiceOverRunning() ? 12.0 : 8.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(visible * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSuspensionBannerDismiss(weakBanner, YES);
    });
}

// The active account as Reddit spells it, for the title; `fallback` otherwise.
static NSString *ApolloSuspensionBannerDisplayName(NSString *fallback) {
    id client = ApolloActiveAccountClient();
    id name = nil;
    @try { name = [client valueForKeyPath:@"currentUser.username"]; }
    @catch (__unused NSException *e) { name = nil; }
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name caseInsensitiveCompare:fallback] == NSOrderedSame) return name;
    return fallback;
}

// The account Apollo has selected right now. AccountManager changes its live
// selection before the defaults mirror ApolloActiveAccountUsername reads is
// written, so the live one is asked first (an account switch lands here).
static NSString *ApolloSuspensionBannerActiveAccount(void) {
    NSString *live = nil;
    if (ApolloResolveLiveActiveAccountIdentity(&live) == ApolloPersistedAccountIdentitySignedIn && live.length > 0) {
        return live.lowercaseString;
    }
    return ApolloActiveAccountUsername().lowercaseString;
}

// A request waiting for the screen to clear. Main thread only.
static BOOL sApolloSuspensionBannerPending = NO;
static ApolloSuspensionBannerOccasion sApolloSuspensionBannerPendingOccasion = ApolloSuspensionBannerOccasionUnprompted;
static NSString *sApolloSuspensionBannerPendingReason = nil;
static NSUInteger sApolloSuspensionBannerPendingChecksLeft = 0;

// Whether something is presented over the app's own screens, or on its way in
// or out. The banner would sit behind it, and a tap meant for the banner would
// land on whatever covers it.
static BOOL ApolloSuspensionBannerScreenIsCovered(UIWindow *window) {
    UIViewController *root = window.rootViewController;
    if (!root) return YES;
    if (root.presentedViewController != nil || root.transitionCoordinator != nil) return YES;
    // Touch ID & Passcode: while Apollo is locked its Padlock keeps a blur
    // (Padlock.blurOverlayView, a PadlockBlurView) over the whole window. A
    // banner added now would sit above it and name the account on a locked app.
    static Class padlockBlurClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ padlockBlurClass = objc_getClass("_TtC6Apollo15PadlockBlurView"); });
    if (padlockBlurClass) {
        for (UIView *subview in window.subviews) {
            if ([subview isKindOfClass:padlockBlurClass] && !subview.hidden && subview.alpha > 0.01) return YES;
        }
    }
    return NO;
}

static BOOL ApolloSuspensionBannerShow(NSString *reason, ApolloSuspensionBannerOccasion occasion);

// Of two requests waiting for the screen, the one to keep: a limit starting is
// news, a reminder of one is next, and an unprompted banner gives way to both.
static ApolloSuspensionBannerOccasion ApolloSuspensionBannerStrongerOccasion(ApolloSuspensionBannerOccasion a,
                                                                           ApolloSuspensionBannerOccasion b) {
    if (a == ApolloSuspensionBannerOccasionLimitStarted || b == ApolloSuspensionBannerOccasionLimitStarted) {
        return ApolloSuspensionBannerOccasionLimitStarted;
    }
    if (a == ApolloSuspensionBannerOccasionBackDuringLimit || b == ApolloSuspensionBannerOccasionBackDuringLimit) {
        return ApolloSuspensionBannerOccasionBackDuringLimit;
    }
    return ApolloSuspensionBannerOccasionUnprompted;
}

// One waiting request at a time; a newer one makes the older check a no-op.
static NSUInteger sApolloSuspensionBannerPendingGeneration = 0;

static void ApolloSuspensionBannerCheckPending(NSUInteger generation) {
    if (!sApolloSuspensionBannerPending || generation != sApolloSuspensionBannerPendingGeneration) return;
    UIWindow *window = ApolloSuspensionBannerWindow();
    BOOL covered = !window || ApolloSuspensionBannerScreenIsCovered(window);
    if (covered && sApolloSuspensionBannerPendingChecksLeft > 0) {
        sApolloSuspensionBannerPendingChecksLeft--;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSuspensionBannerCoveredCheckInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ApolloSuspensionBannerCheckPending(generation); });
        return;
    }
    ApolloSuspensionBannerOccasion occasion = sApolloSuspensionBannerPendingOccasion;
    NSString *reason = sApolloSuspensionBannerPendingReason;
    sApolloSuspensionBannerPending = NO;
    sApolloSuspensionBannerPendingOccasion = ApolloSuspensionBannerOccasionUnprompted;
    sApolloSuspensionBannerPendingReason = nil;
    if (covered) {
        ApolloLog(@"[Suspension] banner gave up waiting for the screen to clear (%@)", reason);
        return;
    }
    ApolloSuspensionBannerShow(reason, occasion);
}

static void ApolloSuspensionBannerWaitForScreen(NSString *reason, ApolloSuspensionBannerOccasion occasion) {
    sApolloSuspensionBannerPendingOccasion = sApolloSuspensionBannerPending
        ? ApolloSuspensionBannerStrongerOccasion(sApolloSuspensionBannerPendingOccasion, occasion) : occasion;
    sApolloSuspensionBannerPendingReason = [reason copy];
    if (sApolloSuspensionBannerPending) return;
    sApolloSuspensionBannerPending = YES;
    sApolloSuspensionBannerPendingChecksLeft = kApolloSuspensionBannerCoveredChecks;
    NSUInteger generation = ++sApolloSuspensionBannerPendingGeneration;
    ApolloLog(@"[Suspension] banner waiting for the screen to clear (%@)", reason);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloSuspensionBannerCoveredCheckInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ApolloSuspensionBannerCheckPending(generation); });
}

// Shows the banner for the active account when it's suspended and one is due
// (ApolloSuspensionBannerIsDue), now or once the screen is clear. Returns
// whether that account is suspended (shown, waiting to be shown, or not due).
static BOOL ApolloSuspensionBannerShow(NSString *reason, ApolloSuspensionBannerOccasion occasion) {
    NSString *account = ApolloSuspensionBannerActiveAccount();
    ApolloSuspensionBannerView *visible = sApolloSuspensionBanner;
    if (account.length == 0 || !ApolloAccountIsSuspended(account)) {
        // Whatever is up or waiting belongs to another account, or to a
        // suspension that ended.
        sApolloSuspensionBannerPending = NO;
        sApolloSuspensionBannerPendingOccasion = ApolloSuspensionBannerOccasionUnprompted;
        sApolloSuspensionBannerPendingReason = nil;
        if (visible) ApolloSuspensionBannerDismiss(visible, YES);
        return NO;
    }
    if (visible && ![visible.account isEqualToString:account]) ApolloSuspensionBannerDismiss(visible, NO);

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!sApolloSuspensionBannerShownAt) sApolloSuspensionBannerShownAt = [NSMutableDictionary dictionary];
    if (!sApolloSuspensionBannerAnnouncedLimitEnd) sApolloSuspensionBannerAnnouncedLimitEnd = [NSMutableDictionary dictionary];
    // While Reddit is refusing the account's requests the banner says that and
    // for how long; read now, since the banner may have waited for the screen.
    NSTimeInterval limited = ApolloWebJSONOptionalReadBackoff(account);
    NSTimeInterval limitEndsAt = limited > 0 ? now + limited : 0;
    if (!ApolloSuspensionBannerIsDue(occasion, now, sApolloSuspensionBannerShownAt[account].doubleValue, limitEndsAt,
                                     sApolloSuspensionBannerAnnouncedLimitEnd[account].doubleValue)) {
        return YES;
    }

    UIWindow *window = ApolloSuspensionBannerWindow();
    if (!window || ApolloSuspensionBannerScreenIsCovered(window)) {
        ApolloSuspensionBannerWaitForScreen(reason, occasion);
        return YES;
    }
    sApolloSuspensionBannerShownAt[account] = @(now);
    // Whatever brought it up, a banner that names the limit has announced it.
    if (limited > 0) sApolloSuspensionBannerAnnouncedLimitEnd[account] = @(limitEndsAt);

    NSString *title = [NSString stringWithFormat:@"Reddit suspended u/%@", ApolloSuspensionBannerDisplayName(account)];
    NSString *left = ApolloAccountSuspensionTimeLeftText(account);
    NSString *detail = nil;
    if (limited > 0) {
        NSString *wait = limited < 60.0 ? @"under a minute"
            : [NSString stringWithFormat:@"about %lu min", (unsigned long)ceil(limited / 60.0)];
        detail = [NSString stringWithFormat:@"Reddit limits suspended accounts. Try again in %@.", wait];
    } else {
        detail = left ? [NSString stringWithFormat:@"%@. Reddit's message is in your inbox.", left]
                      : @"Reddit's message is in your inbox.";
    }
    ApolloSuspensionBannerPresent(account, title, detail, window);
    ApolloLog(@"[Suspension] banner shown for u/%@ (%@; %@%@)", account, reason, left ?: @"no end date",
              limited > 0 ? @"; rate limited" : @"");
    return YES;
}

BOOL ApolloSuspensionBannerShowForRateLimit(BOOL backAfterAway) {
    if (!NSThread.isMainThread) return NO;
    return backAfterAway ? ApolloSuspensionBannerShow(@"back during the rate limit", ApolloSuspensionBannerOccasionBackDuringLimit)
                         : ApolloSuspensionBannerShow(@"rate limit", ApolloSuspensionBannerOccasionLimitStarted);
}

void ApolloSuspensionBannerInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *main = [NSOperationQueue mainQueue];
        // Reddit's answer about an account changed: show it for the active one,
        // or take the banner down when its suspension is over.
        [center addObserverForName:ApolloAccountSuspensionDidChangeNotification object:nil queue:main
                        usingBlock:^(NSNotification *note) {
            NSString *username = note.userInfo[@"username"];
            ApolloLog(@"[Suspension] u/%@ is %@", username,
                      ApolloAccountIsSuspended(username)
                          ? [NSString stringWithFormat:@"suspended by Reddit (%@)", ApolloAccountSuspensionTimeLeftText(username) ?: @"no end date"]
                          : @"not suspended any more");
            // News about the account, so the quiet period since its last
            // banner doesn't apply.
            if ([username isKindOfClass:[NSString class]]) [sApolloSuspensionBannerShownAt removeObjectForKey:username];
            ApolloSuspensionBannerShow(@"suspension changed", ApolloSuspensionBannerOccasionUnprompted);
        }];
        // Launch and every return to the app, from what the last launch stored.
        // A beat later, so it drops in over a drawn screen.
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main
                        usingBlock:^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ApolloSuspensionBannerShow(@"app active", ApolloSuspensionBannerOccasionUnprompted);
            });
        }];
        // Switching accounts: the new one's banner, or the old one's taken down.
        // After the switcher has closed, so the banner isn't lost behind it.
        void (^accountChanged)(NSNotification *) = ^(__unused NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ApolloSuspensionBannerShow(@"account switch", ApolloSuspensionBannerOccasionUnprompted);
            });
        };
        [center addObserverForName:@"com.christianselig.RedditCurrentAccountChanged" object:nil queue:main usingBlock:accountChanged];
        [center addObserverForName:@"com.christianselig.RedditAccountChanged" object:nil queue:main usingBlock:accountChanged];

        // Accounts removed since the last launch leave nothing stored. Only
        // when something is stored (so a launch with no suspended account
        // doesn't read the account list for this), and only on a full read of
        // that list: an unreadable one isn't an empty one.
        if ([[NSUserDefaults standardUserDefaults] dictionaryForKey:UDKeyAccountSuspensions].count > 0) {
            NSSet<NSString *> *accounts = nil;
            if (ApolloResolvePersistedAccountUsernames(&accounts) && accounts) ApolloAccountSuspensionKeepOnly(accounts);
        }
        ApolloLog(@"[Suspension] banner observers installed");
    });
}
