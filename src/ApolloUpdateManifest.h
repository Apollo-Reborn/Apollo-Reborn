// Parsing half of the in-app update check: release-manifest.json -> the
// installed build's variant. Foundation-only so tests/run_update_manifest_tests.sh
// can compile it on the host; the fetch + UI live in ApolloUpdateChecker.{h,m}.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// How far an update can be handed to a sideloader for the installed build.
typedef NS_ENUM(NSInteger, ApolloUpdateHandoff) {
    // A dev or unrecognized build: the release page is all there is.
    ApolloUpdateHandoffNone,
    // A sideloaded build that doesn't know which release variant it is (an injected .deb with no
    // stamp). Any variant-specific link could swap it for the wrong build, so the sideloader apps
    // are only opened and the user picks the update there.
    ApolloUpdateHandoffOpenApp,
    // A stamped release variant: source / IPA links for exactly that build.
    ApolloUpdateHandoffExact,
};

// The newest published release, resolved for the installed build variant.
@interface ApolloUpdateInfo : NSObject
@property (nonatomic, copy) NSString *version;                    // "3.9.0"
@property (nonatomic, strong, nullable) NSURL *releaseURL;        // release notes page
// nil unless the installed build is a known release variant.
@property (nonatomic, strong, nullable) NSURL *sourceURL;         // that variant's AltStore-style source
@property (nonatomic, strong, nullable) NSURL *downloadURL;       // that variant's IPA
// Where the changelog is read from: the variant's source, else the standard build's. The notes
// text is the same for every variant, and it is only displayed, never handed to a sideloader.
@property (nonatomic, strong, nullable) NSURL *notesSourceURL;
// Set by the caller, which knows how the installed build was stamped; defaults to None.
@property (nonatomic) ApolloUpdateHandoff handoff;
@end

typedef NS_ENUM(NSInteger, ApolloUpdateSideloader) {
    ApolloUpdateSideloaderAltStore,
    ApolloUpdateSideloaderSideStore,
    ApolloUpdateSideloaderFeather,
    ApolloUpdateSideloaderFlareStore,
};

// One line of a release's notes. The source JSON stores them as plain text: an optional
// intro line, then "Features" / "Fixes" style headings over "- " bullets that end with a
// credit like "(#1260: @user)".
typedef NS_ENUM(NSInteger, ApolloUpdateNoteKind) {
    ApolloUpdateNoteKindParagraph,
    ApolloUpdateNoteKindHeading,
    ApolloUpdateNoteKindBullet,
};

@interface ApolloUpdateNoteBlock : NSObject
@property (nonatomic) ApolloUpdateNoteKind kind;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *credit;   // "#1260: @user", without the parentheses
@end

// The notes of one published release.
@interface ApolloUpdateReleaseNotes : NSObject
@property (nonatomic, copy) NSString *version;
@property (nonatomic, strong, nullable) NSDate *date;
@property (nonatomic, copy) NSArray<ApolloUpdateNoteBlock *> *blocks;
@end

#ifdef __cplusplus
extern "C" {
#endif

// release-manifest.json variant key for a stamped ARBuildVariant ("ipa" ->
// "standard", "glass-noext" -> "noExtensionsGlass", ...). nil for .deb, dev and
// unrecognized builds, which have no sideloaded IPA to update.
NSString *_Nullable ApolloUpdateManifestKeyForBuildVariant(NSString *_Nullable buildVariant);

// "3.9.0" from "v3.9.0" or "3.9.0-4": no leading "v", no dpkg "-<digits>" revision (a lettered
// suffix such as "3.9.0b" is a different version and stays). The one place that rule lives for
// the update check, so the compare and the What's New coordination can't drift apart.
NSString *ApolloUpdateNormalizedVersion(NSString *version);

// Numeric dotted compare of tweak versions. Tolerates a leading "v" and a dpkg
// "-<digits>" revision; a non-numeric component reads as 0 (no pre-release
// ordering — releases here are plain x.y.z).
NSComparisonResult ApolloUpdateCompareVersions(NSString *a, NSString *b);

// nil when `manifest` isn't a usable release-manifest.json. `variantKey` may be
// nil, in which case sourceURL/downloadURL stay unset (notesSourceURL then comes from the
// standard variant). Non-https URLs are dropped.
ApolloUpdateInfo *_Nullable ApolloUpdateInfoFromManifest(id _Nullable manifest,
                                                         NSString *_Nullable variantKey);

// The URL that asks `sideloader` to add the given AltStore-style source. nil for FlareStore,
// which is handed the IPA instead.
NSURL *_Nullable ApolloUpdateSideloaderSourceURL(ApolloUpdateSideloader sideloader, NSURL *sourceURL);

// The URL that makes `sideloader` download `ipaURL` straight away, whether or not the source
// is added (feather://install/, flarestore://downloadApp=). nil for AltStore and SideStore,
// which have no such link; callers use the source link there.
NSURL *_Nullable ApolloUpdateSideloaderInstallURL(ApolloUpdateSideloader sideloader, NSURL *ipaURL);

// The bare scheme (altstore-classic://, ...): opens the app and nothing else.
NSURL *ApolloUpdateSideloaderLaunchURL(ApolloUpdateSideloader sideloader);

// What a chooser row opens: the IPA link, else the source link, for an exactly known variant;
// otherwise just the app.
NSURL *ApolloUpdateSideloaderHandoffURL(ApolloUpdateSideloader sideloader, ApolloUpdateInfo *info);

// Splits one release's plain-text notes into headings, bullets and paragraphs. A heading is
// a non-bullet line that sits directly above a bullet; a bullet's trailing "(#123: @user)"
// becomes its `credit`.
NSArray<ApolloUpdateNoteBlock *> *ApolloUpdateParseReleaseNotes(NSString *_Nullable text);

// The notes for every release newer than `installedVersion` up to `latestVersion`, newest
// first (at most 8), from an AltStore-style source JSON (apps[].versions[].localizedDescription).
// Falls back to the app's top-level versionDescription when there is no versions list.
// Empty when the source has nothing in that range.
NSArray<ApolloUpdateReleaseNotes *> *ApolloUpdateReleaseNotesFromSource(id _Nullable sourceJSON,
                                                                        NSString *installedVersion,
                                                                        NSString *latestVersion);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
