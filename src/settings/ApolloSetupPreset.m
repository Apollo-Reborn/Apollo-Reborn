#import "settings/ApolloSetupPreset.h"
#import "UserDefaultConstants.h"

@implementation ApolloSetupPreset

- (instancetype)initWithIdentifier:(NSString *)identifier title:(NSString *)title
                         subtitle:(NSString *)subtitle highlights:(NSArray<NSString *> *)highlights
                           values:(NSDictionary<NSString *, id> *)values {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _title = [title copy];
        _subtitle = [subtitle copy];
        _highlights = [highlights copy];
        _values = [values copy];
    }
    return self;
}

+ (NSArray<ApolloSetupPreset *> *)allPresets {
    static NSArray *presets;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *result = [NSMutableArray array];
        NSArray *identifiers = @[@"classic", @"balanced", @"full"];
        NSArray *titles = @[@"Classic", @"Balanced", @"Full Featured"];
        NSArray *subtitles = @[
            @"The familiar Apollo experience, with the fixes needed to keep it working.",
            @"Useful Reborn improvements with a familiar layout.",
            @"A richer interface with more Reborn tools enabled."
        ];
        NSArray *highlights = @[
            @[@"Original profiles and subreddit list", @"Simple links and comment media", @"Compatibility and media fixes"],
            @[@"Inline images and swipeable galleries", @"Link previews and expanded profiles", @"Video scrubber and hold for speed"],
            @[@"Everything in Balanced", @"Avatars, colour flairs and subreddit headers", @"Floating post tabs and richer feed shortcuts"]
        ];
        for (NSUInteger index = 0; index < identifiers.count; index++) {
            BOOL enhanced = index != 0;
            BOOL full = index == 2;
            // Same owned key set in every preset: Full -> Classic must reset
            // Full's additions. Credentials, privacy, native gestures, filters,
            // sound, experimental services, AI and translation stay independent.
            NSDictionary *values = @{
                UDKeyEnableInlineImages: @(enhanced),
                UDKeyFeedGalleryCarousel: @(enhanced),
                UDKeyFeedTextPostThumbnails: @(enhanced),
                // ApolloLinkPreviewMode: Off=0, Compact=1, Full=2.
                UDKeyLinkPreviewBodyMode: @(enhanced ? 2 : 0),
                UDKeyLinkPreviewCommentsMode: @(full ? 2 : enhanced ? 1 : 0),
                UDKeyShowDetailedProfiles: @(enhanced),
                UDKeySubredditListEnhancements: @(enhanced),
                UDKeyModernSubredditDividers: @(enhanced),
                // Feed icons Classic=0, SoftTile=3; Rows=0, SideBySide=2.
                UDKeySubredditFeedIconStyle: @(full ? 3 : 0),
                UDKeySubredditFeedLayout: @(full ? 2 : 0),
                UDKeyShowUserAvatars: @(full),
                UDKeyEnableFlairColors: @(full),
                UDKeyShowSubredditHeaders: @(full),
                UDKeyFloatingPostTabs: @(full),
                UDKeyFeedVideoScrubber: @(enhanced),
                UDKeyVideoHoldSpeedEnabled: @(enhanced),
                UDKeyIconRowMagnifier: @(enhanced),
                UDKeyInfoRowTapUpvote: @(enhanced),
                UDKeyInfoRowTapComments: @(enhanced),
                UDKeyInfoRowPopupMode: @(enhanced),
                UDKeyInfoRowTapTranslation: @(enhanced),
                UDKeyScrollReturnButton: @(enhanced),
                UDKeyLiveCommentsFollow: @(enhanced),
            };
            [result addObject:[[self alloc] initWithIdentifier:identifiers[index] title:titles[index]
                subtitle:subtitles[index] highlights:highlights[index] values:values]];
        }
        presets = [result copy];
    });
    return presets;
}

+ (instancetype)presetWithIdentifier:(NSString *)identifier {
    for (ApolloSetupPreset *preset in self.allPresets) {
        if ([preset.identifier isEqualToString:identifier]) return preset;
    }
    return nil;
}

@end

static BOOL ApolloSetupHasUserPreferences(NSDictionary *domain, BOOL group) {
    for (NSString *key in domain) {
        // Apple's language/keyboard bookkeeping is not an Apollo installation.
        if ([key hasPrefix:@"Apple"] || [key isEqualToString:@"NSInterfaceStyle"] ||
            [key isEqualToString:@"NSLanguages"] ||
            [key hasPrefix:@"com.apple."]) continue;
        if (group && [key hasPrefix:@"ApolloReborn.themeLaunch"]) continue;
        return YES;
    }
    return NO;
}

ApolloSetupState ApolloSetupInitialState(NSDictionary *mainDomain, NSDictionary *groupDomain) {
    id stored = mainDomain[UDKeySetupAssistantState];
    if (stored) {
        if ([stored isKindOfClass:NSNumber.class]) {
            NSInteger state = [stored integerValue];
            if (state >= ApolloSetupStatePending && state <= ApolloSetupStateExistingInstall) return state;
        }
        return ApolloSetupStateExistingInstall;
    }
    // Conservative migration: unfamiliar Apollo prefs also indicate an existing
    // user. Never assume a keyless/signed-out user is a new installation.
    return ApolloSetupHasUserPreferences(mainDomain, NO) || ApolloSetupHasUserPreferences(groupDomain, YES)
        ? ApolloSetupStateExistingInstall : ApolloSetupStatePending;
}

NSDictionary<NSString *, id> *ApolloSetupMainAppearanceValues(ApolloSetupAppearance appearance) {
    // RE: sub_10068beb0 reads ThemeSwitchMode from standard defaults;
    // manual/automatic/time are its tokens. Explicit appearance disables the
    // old brightness/schedule switch without deleting the saved configuration.
    if (appearance < ApolloSetupAppearanceSystem || appearance > ApolloSetupAppearanceDark) return @{};
    return @{ @"ThemeSwitchMode": @"manual" };
}

NSDictionary<NSString *, id> *ApolloSetupGroupAppearanceValues(ApolloSetupAppearance appearance) {
    // RE: SettingsThemeViewController.useSystemLightDarkModeToggled writes
    // UseSystemLightDarkMode in the group suite. ThemeManager reads Theme's
    // light/dark string there for its manual fallback.
    if (appearance == ApolloSetupAppearanceSystem) return @{ @"UseSystemLightDarkMode": @YES };
    if (appearance == ApolloSetupAppearanceLight || appearance == ApolloSetupAppearanceDark) {
        return @{ @"UseSystemLightDarkMode": @NO,
                  @"Theme": appearance == ApolloSetupAppearanceDark ? @"dark" : @"light" };
    }
    return @{};
}

BOOL ApolloSetupWriteValues(NSUserDefaults *defaults, NSDictionary<NSString *, id> *values) {
    BOOL changed = NO;
    for (NSString *key in values) {
        if (![[defaults objectForKey:key] isEqual:values[key]]) {
            changed = YES;
        }
        // Pin even a registered default, so future default changes don't
        // silently change the user's chosen starting point.
        [defaults setObject:values[key] forKey:key];
    }
    return changed;
}
