#import "ApolloUpdateChecker.h"
#import "ApolloUpdateManifest.h"
#import "ApolloUpdateManifestCache.h"
#import "ApolloUpdatePromptViewController.h"
#import "ApolloCommon.h"
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"
#import "Version.h"
#import <UIKit/UIKit.h>

static NSString *const kUpdateManifestURL =
    @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/release-manifest.json";
static const NSTimeInterval kUpdateCheckInterval = 15 * 60;
static const NSTimeInterval kUpdateFailureRetryInterval = 5 * 60;
static const NSTimeInterval kUpdateReminderInterval = 24 * 60 * 60;

// Main-thread state.
static ApolloUpdateInfo *sAvailableUpdate;   // newer than the installed build, else nil
static BOOL sUpToDate;                       // last fetch found nothing newer
static BOOL sChecking;                       // the one manifest fetch in flight, automatic or manual
// Status callbacks of manual checks riding on that fetch; non-empty means its outcome is shown.
static NSMutableArray<dispatch_block_t> *sManualWaiters;
static BOOL sPromptPending;                  // an auto-prompt retry chain is running
static NSUInteger sPromptGeneration;         // bumped to cancel whichever chain is running
static NSString *sPromptedVersion;           // already prompted for this version this launch
static NSTimer *sCheckTimer;                 // one-shot; exists only while active and checks are enabled
static BOOL sRestoredCachedResult;

static void ApolloUpdateScheduleNextCheck(void);
static void ApolloUpdateCancelCheckTimer(void);
static void ApolloUpdateObserveInactivity(void);

static NSString *ApolloUpdateInstalledVersion(void) {
    return ApolloUpdateNormalizedVersion(@(TWEAK_VERSION));
}

// Sim builds carry no ARBuildVariant stamp and the manifest matches the current
// version, so let the sim script inject both to exercise the update UI. "unstamped"
// models an IPA with an injected .deb and no release stamp; any other deb-* value
// models a package-manager install.
static NSString *ApolloUpdateRawVariant(void) {
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_UPDATE_BUILD_VARIANT");
    if (override && *override) return strcmp(override, "unstamped") == 0 ? @"deb-rootful" : @(override);
#endif
    return ApolloBuildVariant();
}

// A .deb's ARVariant marker ("deb-rootful"/"deb-rootless") is also baked into IPAs
// that had the .deb injected without a release stamp (local and test builds). Only a
// real jailbreak install resolves that marker from the absolute jailbreak roots
// ApolloBundledResourcePath falls back to (/var/jb/... or /Library/...); an injected
// IPA resolves it inside the app container. Those users update through their package
// manager, so the feature stays off for them.
static BOOL ApolloUpdateIsJailbreakInstall(void) {
    if (![ApolloUpdateRawVariant() hasPrefix:@"deb-"]) return NO;
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_UPDATE_BUILD_VARIANT");
    if (override && *override) return strcmp(override, "unstamped") != 0;
#endif
    static BOOL jailbreak;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *marker = ApolloBundledResourcePath(@"ARVariant", @"txt");
        jailbreak = [marker hasPrefix:@"/var/jb/"] || [marker hasPrefix:@"/Library/"];
        ApolloLog(@"[update] deb marker=%@ bundle=%@ -> jailbreak=%d",
                  marker, [NSBundle mainBundle].bundlePath, jailbreak);
    });
    return jailbreak;
}

// The manifest `variants` key of a stamped release build ("standard", "glass", ...), else nil.
static NSString *ApolloUpdateReleaseVariantKey(void) {
    return ApolloUpdateManifestKeyForBuildVariant(ApolloUpdateRawVariant());
}

// How much of the update this build can hand to a sideloader. A sideloaded IPA with an injected
// .deb and no release stamp can't tell Liquid Glass / icons-only / no-extensions builds apart
// (a runtime guess is wrong for some of them, silently), so it only gets its sideloader apps
// opened. Dev and unrecognized builds get the release page alone.
static ApolloUpdateHandoff ApolloUpdateInstallHandoff(void) {
    if (ApolloUpdateReleaseVariantKey()) return ApolloUpdateHandoffExact;
    if ([ApolloUpdateRawVariant() hasPrefix:@"deb-"] && !ApolloUpdateIsJailbreakInstall()) return ApolloUpdateHandoffOpenApp;
    return ApolloUpdateHandoffNone;
}

static BOOL ApolloUpdateAutomaticChecksEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyAutomaticUpdateChecks];
}

BOOL ApolloUpdateChecksAvailable(void) {
    return !ApolloUpdateIsJailbreakInstall();
}

#pragma mark - Fetch

static NSURL *ApolloUpdateManifestURL(void) {
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_UPDATE_MANIFEST_URL");
    if (override && *override) return [NSURL URLWithString:@(override)];
#endif
    return [NSURL URLWithString:kUpdateManifestURL];
}

static ApolloUpdateManifestCache *ApolloUpdateCache(void) {
    static ApolloUpdateManifestCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[ApolloUpdateManifestCache alloc] init]; });
    return cache;
}

// Ephemeral with a fixed User-Agent: no cookies or implicit URL cache. Only the
// public manifest and its ETag are saved by ApolloUpdateManifestCache; the default
// CFNetwork UA (app name + OS build) isn't sent to GitHub.
static NSURLSession *ApolloUpdateSession(void) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPShouldSetCookies = NO;
    config.HTTPCookieStorage = nil;
    config.URLCache = nil;
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 30;
    config.HTTPAdditionalHeaders = @{@"User-Agent": @"Apollo-Reborn"};
    return [NSURLSession sessionWithConfiguration:config];
}

static void ApolloUpdateFetchLatest(void (^completion)(ApolloUpdateInfo *latest)) {
    NSURL *url = ApolloUpdateManifestURL();
    NSString *variantKey = ApolloUpdateReleaseVariantKey();
    ApolloUpdateHandoff handoff = ApolloUpdateInstallHandoff();
    NSURLRequest *request = [ApolloUpdateCache() requestForURL:url variantKey:variantKey];
    NSURLSession *session = ApolloUpdateSession();

    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Cache state and check/prompt state share the main queue. A 304 reuses only the
            // validated payload paired with the validator actually sent on this request.
            ApolloUpdateInfo *latest = error ? nil : [ApolloUpdateCache() infoForResponse:response data:data
                                                                                request:request variantKey:variantKey];
            latest.handoff = handoff;
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            ApolloLog(@"[update] fetch status=%ld error=%@ latest=%@ variant=%@ handoff=%ld",
                      (long)status, error.localizedDescription ?: @"none", latest.version ?: @"none", variantKey ?: @"none", (long)handoff);
            completion(latest);
        });
    }] resume];
    [session finishTasksAndInvalidate];
}

// Fetched when the update sheet appears: the source JSON carries the notes of every release
// (apps[].versions[].localizedDescription).
void ApolloUpdateFetchReleaseNotes(ApolloUpdateInfo *info, void (^completion)(NSArray<ApolloUpdateReleaseNotes *> *notes)) {
    NSURL *url = info.notesSourceURL;
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_UPDATE_NOTES_URL");
    if (override && *override) url = [NSURL URLWithString:@(override)];
#endif
    if (!url) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); }); return; }
    NSString *installed = ApolloUpdateInstalledVersion();
    NSString *latest = info.version;
    NSURLSession *session = ApolloUpdateSession();
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSArray<ApolloUpdateReleaseNotes *> *notes = nil;
        if (data && !error && (status == 200 || url.isFileURL)) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:NSDictionary.class]) notes = ApolloUpdateReleaseNotesFromSource(json, installed, latest);
        }
        ApolloLog(@"[update] notes fetch status=%ld error=%@ releases=%ld",
                  (long)status, error.localizedDescription ?: @"none", (long)(notes ? notes.count : -1));
        dispatch_async(dispatch_get_main_queue(), ^{ completion(notes); });
    }] resume];
    [session finishTasksAndInvalidate];
}

static void ApolloUpdateApplyResult(ApolloUpdateInfo *latest) {
    BOOL newer = ApolloUpdateCompareVersions(ApolloUpdateInstalledVersion(), latest.version) == NSOrderedAscending;
    sAvailableUpdate = newer ? latest : nil;
    sUpToDate = !newer;
}

#pragma mark - Presentation

// Manual checks present over whatever is on top. Automatic prompts additionally
// require that nothing modal is showing (What's New, share sheets, composers).
static UIViewController *ApolloUpdatePresenter(BOOL onlyOverBaseUI) {
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return nil;
    UIViewController *top = nil;
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.isKeyWindow) { top = [window visibleViewController]; break; }
    }
    if (!top || top.isBeingPresented || top.isBeingDismissed || top.presentedViewController) return nil;
    if (onlyOverBaseUI) {
        for (UIViewController *vc = top; vc; vc = vc.parentViewController) {
            if (vc.presentingViewController) return nil;
        }
    }
    return top;
}

static void ApolloUpdateShowAlert(NSString *title, NSString *message) {
    UIViewController *presenter = ApolloUpdatePresenter(NO);
    if (!presenter) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void ApolloUpdatePresentSheet(ApolloUpdateInfo *info, UIViewController *presenter, BOOL offerSkip) {
    ApolloUpdatePromptViewController *sheet =
        [[ApolloUpdatePromptViewController alloc] initWithInfo:info
                                              installedVersion:ApolloUpdateInstalledVersion()
                                                     offerSkip:offerSkip];
    sheet.onSkip = ^{
        [[NSUserDefaults standardUserDefaults] setObject:info.version forKey:UDKeyUpdateSkippedVersion];
    };
    sheet.onLater = ^{
        // Reminder timing is independent of network freshness. A different release can still
        // prompt at the next check, while this version stays quiet across process restarts.
        [[NSUserDefaults standardUserDefaults] setObject:@{@"version": info.version, @"date": [NSDate date]}
                                                 forKey:UDKeyUpdateDeferredReminder];
        if ([sPromptedVersion isEqualToString:info.version]) sPromptedVersion = nil;
        ApolloLog(@"[update] reminder deferred for %@ for 24 hours", info.version);
    };
    [sheet presentOverViewController:presenter];
}

#pragma mark - Automatic check

// Defaults can come from an older build or a restored backup. Invalid dates and
// a clock moved backwards must not postpone checks indefinitely.
static NSTimeInterval ApolloUpdateRemainingInterval(id stored, NSDate *now, NSTimeInterval interval) {
    if (![stored isKindOfClass:NSDate.class]) return 0;
    NSTimeInterval elapsed = [now timeIntervalSinceDate:stored];
    return elapsed >= 0 && elapsed < interval ? interval - elapsed : 0;
}

static BOOL ApolloUpdateReminderDeferred(NSString *version) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyUpdateDeferredReminder];
    if (![stored isKindOfClass:NSDictionary.class] || ![stored[@"version"] isEqual:version]) return NO;
    return ApolloUpdateRemainingInterval(stored[@"date"], [NSDate date], kUpdateReminderInterval) > 0;
}

static BOOL ApolloUpdateCanCheckAutomatically(void) {
    return [UIApplication sharedApplication].applicationState == UIApplicationStateActive &&
           ApolloUpdateAutomaticChecksEnabled() && ApolloUpdateInstallHandoff() != ApolloUpdateHandoffNone;
}

static NSTimeInterval ApolloUpdateNextCheckDelay(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *now = [NSDate date];
    return MAX(ApolloUpdateRemainingInterval([defaults objectForKey:UDKeyUpdateLastCheck], now, kUpdateCheckInterval),
               ApolloUpdateRemainingInterval([defaults objectForKey:UDKeyUpdateLastFailure], now, kUpdateFailureRetryInterval));
}

static void ApolloUpdateCancelCheckTimer(void) {
    [sCheckTimer invalidate];
    sCheckTimer = nil;
}

static void ApolloUpdateScheduleNextCheck(void) {
    ApolloUpdateCancelCheckTimer();
    if (!ApolloUpdateCanCheckAutomatically() || sChecking) return;
    NSTimeInterval delay = MAX(1, ApolloUpdateNextCheckDelay());
    sCheckTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        ApolloUpdateCheckIfNeeded();
    }];
    sCheckTimer.tolerance = MIN(30, delay * 0.05);
    [[NSRunLoop mainRunLoop] addTimer:sCheckTimer forMode:NSRunLoopCommonModes];
}

// Stops whichever prompt chain is waiting for a quiet moment (a newer result or a manual check
// supersedes it) without letting it touch the state of the chain that replaces it.
static void ApolloUpdateCancelPendingPrompt(void) {
    sPromptGeneration++;
    sPromptPending = NO;
}

static void ApolloUpdateObserveInactivity(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            ApolloUpdateCancelCheckTimer();
            ApolloUpdateCancelPendingPrompt();
        }];
    });
}

// Retries because What's New and other launch UI may still be on screen. Keep
// the fetched result when retries run out: the next activation/check can retry
// presentation without discarding a successful check or redownloading its data.
static void ApolloUpdateAttemptPrompt(ApolloUpdateInfo *info, NSUInteger generation, NSArray<NSNumber *> *delays) {
    if (delays.count == 0) {
        sPromptPending = NO;
        return;
    }
    NSTimeInterval delay = delays.firstObject.doubleValue;
    NSArray<NSNumber *> *rest = [delays subarrayWithRange:NSMakeRange(1, delays.count - 1)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sPromptGeneration) return;   // superseded by a newer result or a manual check
        if (!ApolloUpdateCanCheckAutomatically() || ApolloUpdateReminderDeferred(info.version)) {
            sPromptPending = NO;
            return;
        }
        UIViewController *presenter = ApolloUpdatePresenter(YES);
        if (!presenter) { ApolloUpdateAttemptPrompt(info, generation, rest); return; }
        sPromptPending = NO;
        sPromptedVersion = info.version;
        ApolloLog(@"[update] prompting for %@", info.version);
        ApolloUpdatePresentSheet(info, presenter, YES);
    });
}

// Prompt as soon as the check finds an update, retrying while other launch UI is up. What's
// New shows first when it's due (a new install or upgrade) and takes a couple of seconds to
// claim the screen, so give it room then; either way a blocked chain just retries next foreground.
static NSArray<NSNumber *> *ApolloUpdatePromptDelays(void) {
    NSString *seen = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyLastSeenWhatsNewVersion];
    BOOL whatsNewDue = ![seen isEqualToString:ApolloUpdateInstalledVersion()];
    return whatsNewDue ? @[@2.5, @4, @8] : @[@0, @1, @2, @4, @8];
}

static void ApolloUpdateMaybePrompt(void) {
    ApolloUpdateInfo *info = sAvailableUpdate;
    if (!info || sPromptPending || [sPromptedVersion isEqualToString:info.version]) return;
    if (sManualWaiters.count) return;   // the manual check in flight presents (and records) its own result
    if (!ApolloUpdateCanCheckAutomatically() || ApolloUpdateReminderDeferred(info.version)) return;
    if ([[[NSUserDefaults standardUserDefaults] stringForKey:UDKeyUpdateSkippedVersion] isEqualToString:info.version]) return;
    sPromptPending = YES;
    ApolloUpdateAttemptPrompt(info, sPromptGeneration, ApolloUpdatePromptDelays());
}

#pragma mark - Fetch coordination

// Presents the outcome of a manual check: a failure, the update sheet, or "up to date".
static void ApolloUpdateFinishManualCheck(ApolloUpdateInfo *latest) {
    if (!latest) {
        ApolloUpdateShowAlert(@"Couldn't Check for Updates", @"Check your connection and try again.");
    } else if (sAvailableUpdate) {
        UIViewController *presenter = ApolloUpdatePresenter(NO);
        if (presenter) {
            sPromptedVersion = sAvailableUpdate.version;  // the auto prompt needn't repeat this
            ApolloUpdatePresentSheet(sAvailableUpdate, presenter, NO);
        }
    } else {
        ApolloUpdateShowAlert(@"You're Up to Date",
                              [NSString stringWithFormat:@"Apollo-Reborn %@ is the latest version.",
                               ApolloUpdateInstalledVersion()]);
    }
}

// The only place the manifest is fetched. Whoever asks while a fetch is already in flight shares
// it: a manual check that arrives during an automatic one still gets its result shown.
static void ApolloUpdateStartFetch(void) {
    if (sChecking) return;
    ApolloUpdateObserveInactivity();
    ApolloUpdateCancelCheckTimer();
    sChecking = YES;
    ApolloUpdateFetchLatest(^(ApolloUpdateInfo *latest) {
        sChecking = NO;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (latest) {
            ApolloUpdateCancelPendingPrompt();   // a chain still waiting holds the previous result
            ApolloUpdateApplyResult(latest);
            [defaults setObject:[NSDate date] forKey:UDKeyUpdateLastCheck];
            [defaults removeObjectForKey:UDKeyUpdateLastFailure];
        } else {
            // A failed request does not make old data fresh. Persist a separate short
            // backoff so switching apps or relaunching while offline cannot hammer GitHub.
            [defaults setObject:[NSDate date] forKey:UDKeyUpdateLastFailure];
        }
        ApolloUpdateScheduleNextCheck();
        NSArray<dispatch_block_t> *waiters = [sManualWaiters copy];
        [sManualWaiters removeAllObjects];
        if (waiters.count == 0) {
            // A known update remains useful offline, including when its Later snooze has
            // expired. Presentation timing must not depend on a successful network retry.
            ApolloUpdateMaybePrompt();
            return;
        }
        for (dispatch_block_t statusChanged in waiters) statusChanged();
        ApolloUpdateFinishManualCheck(latest);
    });
}

void ApolloUpdateCheckIfNeeded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloUpdateObserveInactivity();
        ApolloUpdateCancelCheckTimer();
#if APOLLO_SIM_BUILD
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        // APOLLO_UPDATE_RESET=1 forgets check/reminder throttles and Skip, once per launch.
        static dispatch_once_t resetOnce;
        dispatch_once(&resetOnce, ^{
            if (!getenv("APOLLO_UPDATE_RESET")) return;
            [defaults removeObjectForKey:UDKeyUpdateLastCheck];
            [defaults removeObjectForKey:UDKeyUpdateLastFailure];
            [defaults removeObjectForKey:UDKeyUpdateDeferredReminder];
            [defaults removeObjectForKey:UDKeyUpdateSkippedVersion];
        });
#endif
        if (!ApolloUpdateCanCheckAutomatically()) {
            ApolloUpdateCancelPendingPrompt();
            return;
        }
        if (sChecking) return;

        if (!sRestoredCachedResult) {
            sRestoredCachedResult = YES;
            ApolloUpdateInfo *cached = [ApolloUpdateCache() cachedInfoForURL:ApolloUpdateManifestURL()
                                                                 variantKey:ApolloUpdateReleaseVariantKey()];
            if (cached) {
                cached.handoff = ApolloUpdateInstallHandoff();
                ApolloUpdateApplyResult(cached);   // never advances the last-success timestamp
            }
        }

        // The same deadline drives foreground checks and the active-only timer. Keep checking
        // even after Later/Skip so a different release can be discovered in this process.
        NSTimeInterval remaining = ApolloUpdateNextCheckDelay();
        if (remaining > 0) {
            ApolloLog(@"[update] auto check: next request in %.0f seconds", remaining);
            ApolloUpdateMaybePrompt();
            ApolloUpdateScheduleNextCheck();
            return;
        }

        ApolloLog(@"[update] auto check: fetching");
        ApolloUpdateStartFetch();
    });
}

#pragma mark - Manual check

void ApolloUpdateCheckNow(void (^statusChanged)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // The user is asking right now, so an automatic prompt still waiting for a quiet moment
        // is superseded: its sheet would otherwise land on top of this check's result.
        ApolloUpdateCancelPendingPrompt();
        if (!sManualWaiters) sManualWaiters = [NSMutableArray array];
        dispatch_block_t waiter = [statusChanged copy];
        if (!waiter) waiter = ^{};   // still marks the check as manual
        [sManualWaiters addObject:waiter];
        ApolloUpdateStartFetch();             // joins the fetch in flight, if any; either way sChecking is set
        if (statusChanged) statusChanged();   // "Checking…"
    });
}

NSString *ApolloUpdateStatusText(void) {
    if (sChecking) return @"Checking…";
    if (sAvailableUpdate) return [NSString stringWithFormat:@"v%@ available", sAvailableUpdate.version];
    return sUpToDate ? @"Up to date" : nil;
}
