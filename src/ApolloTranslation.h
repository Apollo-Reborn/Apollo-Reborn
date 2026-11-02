#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const ApolloRichPreviewTranslationDidUpdateNotification;

BOOL ApolloRichPreviewTranslationShouldTranslateForNode(id node);
NSString *ApolloRichPreviewTranslatedTextIfAvailable(NSURL *url, NSString *field, NSString *sourceText, id ownerNode);

// Settles a vote-reconfigured comment/header cell's body back to its cached
// translation. Called by the vote-flicker module immediately before each of
// its synchronous display flushes, so a flush can never paint the
// untranslated text a vote's node rebuild briefly leaves behind. Exact-gate
// no-op when the body already shows the translation.
BOOL ApolloTranslationReapplySynchronouslyForVoteReconfigure(id cellNode);

// Preserves the exact on-screen translated comment body while Apollo replaces
// its Texture node during a vote. The returned opaque token must be removed
// with ApolloTranslationRemoveVoteBodyCover after the replacement settles.
id ApolloTranslationInstallVoteBodyCover(id cellNode);
void ApolloTranslationRemoveVoteBodyCover(id coverToken);
// Warms the same snapshot cache and briefly presents the identical cover so
// Core Animation commits its layer before a vote. Safe to call for every
// visible comment; it is an exact no-op outside translated mode or when this
// cell/fullname already has a ready cover.
void ApolloTranslationPrimeVoteBodySnapshot(id cellNode);
void ApolloTranslationDiscardVoteBodySnapshot(id cellNode);

// Maps the stored LibreTranslate URL setting to a usable endpoint: empty —
// or the dead libretranslate.de public instance the tweak defaulted to before
// it shut down (issue #995) — becomes the current default instance. Callers:
// %ctor settings load, backup-restore statics re-sync, settings screen.
// extern "C": defined in ApolloTranslation.xm (ObjC++) but also called from
// plain ObjC (.m) TUs, so it needs unmangled linkage.
__BEGIN_DECLS
NSString *ApolloNormalizedLibreTranslateURLSetting(NSString *stored);

// True when LibreTranslate cannot work as currently configured: the effective
// URL points at a keyed public instance and no API key is entered. Keyless
// self-hosted instances return NO. Shared by the request leg's fail-fast, the
// cross-provider fallback chooser, and the settings screen's key warning.
BOOL ApolloLibreTranslateNeedsAPIKey(void);

// `text` without the per-item translation line ("Translated from …" / "Show
// translation" / "Translate") appended under a comment body, or nil when
// `text` doesn't end with one. Lets a module that rebuilds a comment body on
// every measure (deleted comments) leave that line alone instead of stripping
// it and racing translation's re-add.
NSAttributedString *ApolloTranslationTextByRemovingTrailingMarker(NSAttributedString *text);

// "N more replies" (ApolloLoadMoreComments.xm). Main thread only.
//
// Translates the not-yet-inserted comments in `things` (RDKComment objects;
// anything else is ignored) when `commentsController`'s thread is showing
// translations. Returns NO, and never calls `completion`, when nothing needs
// a translation; otherwise calls `completion` once on the main queue when the
// first few (the rows that land on screen) have finished — cached, skipped or
// failed. The rest are requested too, without being waited for. It never
// gives up by itself: the caller bounds the wait.
BOOL ApolloTranslationPrefetchCommentsForInsertion(id commentsController, NSArray *things, void (^completion)(void));

// While the returned token is armed, a comment cell Apollo builds for one of
// `things` gets its cached translation written into its body text node at
// creation, before Texture measures the row, so the row is inserted at its
// translated height. Returns nil when no comment in `things` has a cached
// translation to use. Disarm with the token (nil is a no-op).
id ApolloTranslationArmInsertedComments(id commentsController, NSArray *things);
void ApolloTranslationDisarmInsertedComments(id token);
__END_DECLS

#if APOLLO_SIM_BUILD
// Sim debug-bridge probe (see ApolloSimDebugTap.xm): run `text` through a
// translation provider leg and ApolloLog the outcome, bypassing all UI/feed
// gating. `spec` is "<google|libre|auto> <text>"; auto = the user-selected
// provider with the normal cross-provider fallback.
void ApolloTranslationDebugProbe(NSString *spec);
#endif
