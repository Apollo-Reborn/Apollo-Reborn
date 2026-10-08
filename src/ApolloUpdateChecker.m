#import "ApolloUpdateChecker.h"
#import "ApolloUpdateManifest.h"
#import "ApolloUpdatePromptViewController.h"
#import "ApolloCommon.h"
#import "UIWindow+Apollo.h"
#import "UserDefaultConstants.h"
#import "Version.h"
#import <UIKit/UIKit.h>

static NSString *const kUpdateManifestURL =
    @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/release-manifest.json";
static const NSTimeInterval kUpdateCheckInterval = 24 * 60 * 60;

// Main-thread state.
static ApolloUpdateInfo *sAvailableUpdate;   // newer than the installed build, else nil
static BOOL sUpToDate;                       // last fetch found nothing newer
static BOOL sChecking;                       // the one manifest fetch in flight, automatic or manual
// Status callbacks of manual checks riding on that fetch; non-empty means its outcome is shown.
static NSMutableArray<dispatch_block_t> *sManualWaiters;
static BOOL sPromptPending;                  // an auto-prompt retry chain is running
static NSUInteger sPromptGeneration;         // bumped to cancel whichever chain is running
static NSString *sPromptedVersion;           // already prompted for this version this launch

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

// Ephemeral with a fixed User-Agent: no cookies, no cache on disk, and the
// default CFNetwork UA (app name + OS build) isn't sent to GitHub.
static NSURLSession *ApolloUpdateSession(void) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPShouldSetCookies = NO;
    config.timeoutIntervalForRequest = 15;
    config.HTTPAdditionalHeaders = @{@"User-Agent": @"Apollo-Reborn"};
    return [NSURLSession sessionWithConfiguration:config];
}

static void ApolloUpdateFetchLatest(void (^completion)(ApolloUpdateInfo *latest)) {
    NSURL *url = [NSURL URLWithString:kUpdateManifestURL];
#if APOLLO_SIM_BUILD
    const char *override = getenv("APOLLO_UPDATE_MANIFEST_URL");
    if (override && *override) url = [NSURL URLWithString:@(override)];
#endif
    NSString *variantKey = ApolloUpdateReleaseVariantKey();
    ApolloUpdateHandoff handoff = ApolloUpdateInstallHandoff();

    NSURLSession *session = ApolloUpdateSession();

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        ApolloUpdateInfo *latest = nil;
        // A file:// URL (sim override only) has no HTTP status.
        if (data && !error && (status == 200 || url.isFileURL)) {
            latest = ApolloUpdateInfoFromManifest([NSJSONSerialization JSONObjectWithData:data options:0 error:NULL],
                                                  variantKey);
            latest.handoff = handoff;
        }
        ApolloLog(@"[update] fetch status=%ld error=%@ latest=%@ variant=%@ handoff=%ld",
                  (long)status, error.localizedDescription ?: @"none", latest.version ?: @"none", variantKey ?: @"none", (long)handoff);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(latest); });
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
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:UDKeyUpdateLastCheck];
}

#pragma mark - Presentation

// Manual checks present over whatever is on top. Automatic prompts additionally
// require that nothing modal is showing (What's New, share sheets, composers).
static UIViewController *ApolloUpdatePresenter(BOOL onlyOverBaseUI) {
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
    [sheet presentOverViewController:presenter];
}

#pragma mark - Automatic check

// Stops whichever prompt chain is waiting for a quiet moment (a newer result or a manual check
// supersedes it) without letting it touch the state of the chain that replaces it.
static void ApolloUpdateCancelPendingPrompt(void) {
    sPromptGeneration++;
    sPromptPending = NO;
}

// Retries because What's New and other launch UI may still be on screen; if
// every attempt is blocked, forget the check time so the next foreground retries.
static void ApolloUpdateAttemptPrompt(ApolloUpdateInfo *info, NSUInteger generation, NSArray<NSNumber *> *delays) {
    if (delays.count == 0) {
        sPromptPending = NO;
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:UDKeyUpdateLastCheck];
        return;
    }
    NSTimeInterval delay = delays.firstObject.doubleValue;
    NSArray<NSNumber *> *rest = [delays subarrayWithRange:NSMakeRange(1, delays.count - 1)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != sPromptGeneration) return;   // superseded by a newer result or a manual check
        if (!ApolloUpdateAutomaticChecksEnabled()) {   // switched off while waiting for a quiet moment
            sPromptPending = NO;
            ApolloLog(@"[update] auto prompt dropped: automatic checks turned off");
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
    if (!ApolloUpdateAutomaticChecksEnabled()) return;
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
        sPromptedVersion = sAvailableUpdate.version;  // the auto prompt needn't repeat this
        UIViewController *presenter = ApolloUpdatePresenter(NO);
        if (presenter) ApolloUpdatePresentSheet(sAvailableUpdate, presenter, NO);
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
    sChecking = YES;
    ApolloUpdateFetchLatest(^(ApolloUpdateInfo *latest) {
        sChecking = NO;
        if (latest) {
            ApolloUpdateCancelPendingPrompt();   // a chain still waiting holds the previous result
            ApolloUpdateApplyResult(latest);
        }
        NSArray<dispatch_block_t> *waiters = [sManualWaiters copy];
        [sManualWaiters removeAllObjects];
        if (waiters.count == 0) {
            if (latest) ApolloUpdateMaybePrompt();   // an automatic failure stays due, retried next foreground
            return;
        }
        for (dispatch_block_t statusChanged in waiters) statusChanged();
        ApolloUpdateFinishManualCheck(latest);
    });
}

void ApolloUpdateCheckIfNeeded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
#if APOLLO_SIM_BUILD
        // APOLLO_UPDATE_RESET=1 forgets the daily throttle and skipped version, once per launch.
        static dispatch_once_t resetOnce;
        dispatch_once(&resetOnce, ^{
            if (!getenv("APOLLO_UPDATE_RESET")) return;
            [defaults removeObjectForKey:UDKeyUpdateLastCheck];
            [defaults removeObjectForKey:UDKeyUpdateSkippedVersion];
        });
#endif
        if (!ApolloUpdateAutomaticChecksEnabled()) { ApolloLog(@"[update] auto check: off"); return; }
        // Jailbroken .deb installs update through their package manager, and dev builds have
        // nothing to hand off.
        ApolloUpdateHandoff handoff = ApolloUpdateInstallHandoff();
        if (handoff == ApolloUpdateHandoffNone) {
            ApolloLog(@"[update] auto check: nothing to hand off (raw=%@ available=%d)",
                      ApolloUpdateRawVariant(), ApolloUpdateChecksAvailable());
            return;
        }

        // Due once a day, whether or not an update is already known: a long-lived process would
        // otherwise never learn of a release newer than the first one it found. A restored
        // backup can leave any type in this key, so only an NSDate counts.
        id stored = [defaults objectForKey:UDKeyUpdateLastCheck];
        NSDate *last = [stored isKindOfClass:NSDate.class] ? stored : nil;
        NSTimeInterval sinceLast = last ? -last.timeIntervalSinceNow : 0;
        if (last && sinceLast >= 0 && sinceLast < kUpdateCheckInterval) {
            ApolloLog(@"[update] auto check: throttled (%.0f min since last)", sinceLast / 60);
            ApolloUpdateMaybePrompt();   // a prompt that couldn't show earlier may be able to now
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
