#import <Foundation/Foundation.h>
#import "settings/ApolloSetupPreset.h"
#import "UserDefaultConstants.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Check(ApolloSetupInitialState(@{}, @{}) == ApolloSetupStatePending, @"new install starts setup");
        Check(ApolloSetupInitialState(@{@"AppleLanguages": @[@"en"], @"NSInterfaceStyle": @"Dark"}, @{}) == ApolloSetupStatePending,
            @"OS housekeeping does not turn a new install into an upgrade");
        Check(ApolloSetupInitialState(@{UDKeySideloadFlagsStamp: @"old"}, @{}) == ApolloSetupStateExistingInstall,
            @"signed-out upgrade keeps its settings");
        Check(ApolloSetupInitialState(@{}, @{@"Theme": @"dark"}) == ApolloSetupStateExistingInstall,
            @"group-only customization is preserved");
        Check(ApolloSetupInitialState(@{@"FutureApolloPreference": @NO}, @{}) == ApolloSetupStateExistingInstall,
            @"unfamiliar persisted preferences conservatively suppress first-run setup");
        Check(ApolloSetupInitialState(@{UDKeyNSFWBlurOverride: @1}, @{}) == ApolloSetupStateExistingInstall,
            @"NSFW preferences are not confused with Foundation housekeeping");
        Check(ApolloSetupInitialState(@{}, @{@"ApolloReborn.themeLaunchAttemptStartedAt": @123}) == ApolloSetupStatePending,
            @"theme launch bookkeeping alone is not user configuration");
        Check(ApolloSetupInitialState(@{UDKeyRedditClientId: @"example"}, @{}) == ApolloSetupStateExistingInstall,
            @"old credential-only backup does not run setup");
        for (NSNumber *state in @[@1, @2, @3, @4]) {
            Check(ApolloSetupInitialState(@{UDKeySetupAssistantState: state, UDKeyRedditClientId: @"example"}, @{}) == state.integerValue,
                @"lifecycle marker survives sign-in, skip, completion and upgrades");
        }
        for (id invalid in @[@0, @5, @"pending", @[], @{}]) {
            Check(ApolloSetupInitialState(@{UDKeySetupAssistantState: invalid}, @{}) == ApolloSetupStateExistingInstall,
                @"unknown or invalid state never resets a user to first-run setup");
        }

        NSArray<ApolloSetupPreset *> *presets = ApolloSetupPreset.allPresets;
        Check(presets.count == 3, @"three curated starting points");
        Check([ApolloSetupPreset presetWithIdentifier:@"missing"] == nil, @"unknown preset does not apply arbitrary defaults");
        NSSet *owned = [NSSet setWithArray:presets.firstObject.values.allKeys];
        NSSet *protected = [NSSet setWithArray:@[
            UDKeyRedditClientId, UDKeyRedditClientSecret, UDKeyPerAccountCredentials,
            UDKeyLiquidGlassEnabled, UDKeyCrashCaptureEnabled, UDKeyDisableUsageHeartbeat,
            UDKeyEnableAISummaries, UDKeyEnableBulkTranslation, UDKeyShowDeletedComments,
            UDKeyWebJSONEnabled, UDKeyUseModernRedditChat, UDKeyUseModernRedditModmail,
            UDKeyUnmuteFeedVideos, UDKeyNSFWBlurOverride, UDKeyPerAccountFavoritesEnabled,
            UDKeyTabBarSwipeNavigation, UDKeyAutomaticBackupsEnabled,
        ]];
        for (ApolloSetupPreset *preset in presets) {
            Check([owned isEqualToSet:[NSSet setWithArray:preset.values.allKeys]], @"every preset reverses the others' owned features");
            Check(![owned intersectsSet:protected], @"feature presets do not change authentication, privacy, filters, sound or opt-in services");
        }
        NSString *suite = [@"app.apolloreborn.setup-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        [defaults removePersistentDomainForName:suite];
        [defaults registerDefaults:presets[1].values];
        Check(!ApolloSetupWriteValues(defaults, presets[1].values), @"matching registered defaults need no restart");
        Check([defaults persistentDomainForName:suite].count == owned.count, @"chosen values are pinned even when matching registration defaults");
        [defaults setObject:@"example-credential" forKey:UDKeyRedditClientId];
        [defaults setBool:YES forKey:UDKeyEnableAISummaries];
        Check(ApolloSetupWriteValues(defaults, presets[2].values), @"Full adds visible features");
        Check(ApolloSetupWriteValues(defaults, presets[0].values), @"Classic reverses Full");
        Check([defaults boolForKey:UDKeyShowUserAvatars] == NO && [defaults boolForKey:UDKeyFloatingPostTabs] == NO &&
            [defaults boolForKey:UDKeyEnableInlineImages] == NO, @"switching back does not leave Full additions enabled");
        Check([[defaults stringForKey:UDKeyRedditClientId] isEqualToString:@"example-credential"] && [defaults boolForKey:UDKeyEnableAISummaries],
            @"applying presets preserves unrelated existing choices");
        Check(!ApolloSetupWriteValues(defaults, @{}), @"Keep My Settings makes no changes");
        Check(!ApolloSetupWriteValues(defaults, presets[0].values), @"applying the same preset is idempotent");
        [defaults removePersistentDomainForName:suite];

        Check(ApolloSetupMainAppearanceValues(ApolloSetupAppearanceUnchanged).count == 0 &&
            ApolloSetupGroupAppearanceValues(ApolloSetupAppearanceUnchanged).count == 0, @"Keep Current preserves brightness and schedule rules");
        Check(ApolloSetupMainAppearanceValues(42).count == 0 && ApolloSetupGroupAppearanceValues(42).count == 0,
            @"invalid appearance is a no-op");
        for (NSNumber *mode in @[@0, @1, @2]) {
            Check([ApolloSetupMainAppearanceValues(mode.integerValue)[@"ThemeSwitchMode"] isEqual:@"manual"],
                @"explicit appearance disables native automatic scheduling");
        }
        Check([ApolloSetupGroupAppearanceValues(ApolloSetupAppearanceSystem)[@"UseSystemLightDarkMode"] boolValue],
            @"System follows device appearance");
        Check([ApolloSetupGroupAppearanceValues(ApolloSetupAppearanceLight)[@"Theme"] isEqual:@"light"] &&
            ![ApolloSetupGroupAppearanceValues(ApolloSetupAppearanceLight)[@"UseSystemLightDarkMode"] boolValue], @"Light is fixed");
        Check([ApolloSetupGroupAppearanceValues(ApolloSetupAppearanceDark)[@"Theme"] isEqual:@"dark"] &&
            ![ApolloSetupGroupAppearanceValues(ApolloSetupAppearanceDark)[@"UseSystemLightDarkMode"] boolValue], @"Dark is fixed");
        printf("PASS: %lu setup lifecycle, preset and appearance checks\n", (unsigned long)checks);
    }
    return 0;
}
