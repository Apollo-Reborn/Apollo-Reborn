#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <Security/SecBase.h>
#import <objc/message.h>

@class CASpringAnimation;

// On iOS 26, NSLog redacts strings, so use os_log: https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-26-release-notes#NSLog
// Uses a dedicated subsystem so OSLogStore can efficiently filter our entries.
//
// These wrappers exist for the PERSISTED levels, the ones Export Debug Logs and
// the bug-report flow read back from OSLogStore. They take an NSString format
// and publish the whole message as one public string, so every %@ shows up in
// a user's export without a per-argument %{public} annotation:
//   ApolloLog       DEFAULT  The normal level for diagnostics.
//   ApolloLogError  ERROR    A real failure in our process: an NSError from a
//                            request/IO/parse, an exception caught in a hook.
//   ApolloLogFault  FAULT    A broken invariant / should-never-happen state.
//                            Use sparingly.
// These levels are on unless the subsystem is deliberately switched off (log
// config, a logging profile, OSLogPreferences), so there is no level check up
// front: the line is always formatted, once, into a non-autoreleased string
// inside its own autorelease pool (see ApolloLogEmit), and os_log_with_type
// does its usual check after that.
//
// The in-memory levels have no wrapper: call os_log_info / os_log_debug
// directly with ApolloFixLog() and a C-literal format that starts with
// "[ApolloFix] [Tag] ". They never reach exports and belong to chatty call
// sites and hot paths (per cell, per layout pass, per scroll tick, per touch).
// Debug is off unless something asks for it (log stream --level debug, log
// config, a profile), and Apple's macros check the level before touching the
// arguments, so a disabled debug line costs one os_log_type_enabled call and
// its arguments are not evaluated (no side effects in log arguments). An
// enabled direct call is ~2.5-3x cheaper than the wrapper and never builds an
// NSString, so a hot path that must stay in exports calls os_log /
// os_log_error directly too. In every direct call each dynamic string or
// object needs %{public}@ / %{public}s, or it is <private> in exports;
// integers, floats, bools and %p are public by default.
#define ApolloLog(fmt, ...) ApolloLogEmit(OS_LOG_TYPE_DEFAULT, @"[ApolloFix] " fmt, ##__VA_ARGS__)
#define ApolloLogError(fmt, ...) ApolloLogEmit(OS_LOG_TYPE_ERROR, @"[ApolloFix] " fmt, ##__VA_ARGS__)
#define ApolloLogFault(fmt, ...) ApolloLogEmit(OS_LOG_TYPE_FAULT, @"[ApolloFix] " fmt, ##__VA_ARGS__)

__BEGIN_DECLS
os_log_t ApolloFixLog(void);
// Formats and emits one log line. Call through the ApolloLog* macros.
void ApolloLogEmit(os_log_type_t type, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
NSString *ApolloCollectLogs(void);

// --- Row-measure re-entrancy guard (issues #831/#833/#838/#839/#841) ---
// Main-thread depth of UITableView row-height passes currently on the stack
// (maintained by the ASTableView tableView:heightForRowAtIndexPath: hook in
// ApolloInlineLinkPreviews.xm). While a pass is in progress, UIKit is inside
// its row-data (re)validation (-[UISectionRowData refreshWithSection:...] /
// endUpdates); calling ANY UITableView geometry query (indexPathForCell:,
// rectForRowAtIndexPath:, indexPathsForVisibleRows, ...) from tweak code at
// that moment makes UIKit start a NESTED full-section validation — one extra
// ~48-frame nesting level per row — until the main thread's 1MB stack
// overflows (EXC_BAD_ACCESS on a stack-guard address, crashing whatever
// innocent code runs at the boundary). Any tweak code that can run inside a
// row measure (layoutSpecThatFits:, text-setter hooks, ...) must check
// ApolloRowMeasureInProgress() before touching table geometry and decline or
// defer instead.
BOOL ApolloRowMeasureInProgress(void);
void ApolloRowMeasureWillBegin(void);
void ApolloRowMeasureDidEnd(void);
NSString *ApolloCollectAILogs(void);

// One-shot immutable Security dictionaries for the generic-password shapes
// shared by the tweak. Callers own the returned dictionary.
CFDictionaryRef ApolloCreateGenericPasswordIdentity(CFStringRef service,
                                                     CFStringRef account) CF_RETURNS_RETAINED;
CFDictionaryRef ApolloCreateGenericPasswordDataQuery(CFStringRef service,
                                                      CFStringRef account) CF_RETURNS_RETAINED;
OSStatus ApolloUpsertGenericPasswordData(CFStringRef service,
                                         CFStringRef account,
                                         NSData *data,
                                         CFStringRef accessible);

// Starts a data request whose response is bounded before and during transfer.
// HTTP errors and an advertised/actual body larger than maximumBytes fail the
// task. responseValidator may reject a 2xx response (for example by MIME type)
// before any bytes are accepted. Completion is delivered exactly once on
// completionQueue (the main queue when nil), including cancellation.
typedef NSError *(^ApolloBoundedDataResponseValidator)(NSHTTPURLResponse *response);
typedef void (^ApolloBoundedDataCompletion)(NSData *data,
                                            NSHTTPURLResponse *response,
                                            NSError *error);
NSURLSessionDataTask *ApolloStartBoundedDataRequest(
    NSURLRequest *request,
    NSUInteger maximumBytes,
    ApolloBoundedDataResponseValidator responseValidator,
    dispatch_queue_t completionQueue,
    ApolloBoundedDataCompletion completion);

BOOL IsLiquidGlass(void);

NSURL *ApolloURLByConvertingResolvedURLToApolloScheme(NSURL *url);
BOOL ApolloRouteResolvedURLViaApolloScheme(NSURL *resolvedURL);
void ApolloFlushReadPostIDsToDefaults(void);
UITableView *ApolloInheritedSettingsThemeSourceTableView(UITableViewController *controller);
UIColor *ApolloInheritedSettingsBackgroundColor(UITableViewController *controller);
void ApolloApplyInheritedSettingsTableTheme(UITableViewController *controller);

// YES if sourceTable is nil or detached from its window. A covered (non-
// topmost) nav stack screen stops getting traitCollectionDidChange:, so its
// cells' colors can be stale — callers sampling a cell's color from an
// inherited source table should check this before trusting the sample.
BOOL ApolloThemeSourceTableIsStale(UITableView *sourceTable);
UIImage *ApolloEmojiSettingsIcon(NSString *emoji, UIColor *backgroundColor, CGFloat size);
UIImage *ApolloBuyMeACoffeeSettingsIcon(CGFloat size);
UIImage *ApolloRebornOptionsSettingsIcon(CGFloat size);

// Baseline-aligned SF Symbol as an attributed string, sized to `font` and
// tinted `tint`. Returns nil if the symbol can't load, so callers can fall
// back to a plain-text glyph. Shared by ApolloAISummary.xm/ApolloPollVoting.xm.
NSAttributedString *ApolloSymbolAttachment(NSString *symbolName, UIFont *font, UIColor *tint);

// Resolve a path to a bundled tweak resource across the install layouts we
// support (jailbreak rootful/rootless, Sideloadly/cyan/azule deb fuse, and
// inject-deb-local.sh). Returns nil if no layout has the file.
NSString *ApolloBundledResourcePath(NSString *baseName, NSString *extension);

// Renders a bundled single-page PDF (`baseName`.pdf in Resources/) into a
// template UIImage at the device scale, so contributed vector icons stay crisp
// on every screen instead of shipping as fixed-scale PNGs. `maxSize` bounds the
// result while preserving aspect ratio; pass CGSizeZero for the PDF's natural
// size. Results are cached per name+size. Returns nil when the resource isn't
// staged in this install layout, so callers can fall back to an SF Symbol.
UIImage *ApolloBundledPDFTemplateImage(NSString *baseName, CGSize maxSize);

// Monotonic milliseconds (CACurrentMediaTime-based); ~ns-cheap. Used by the
// trailing-debounce relayout schedulers (InlineImages, LinkPreviews).
double ApolloPerfNowMs(void);

// Decoded backing-store size of `image` in bytes — the number an image cache's
// totalCostLimit has to be given for the limit to mean anything. A
// totalCostLimit with cost-less insertions never evicts by bytes at all.
// Prefers the CGImage's real row stride; falls back to points x scale^2 x 4 for
// CIImage-backed images that have no bitmap yet. Saturates instead of wrapping.
NSUInteger ApolloImageByteCost(UIImage *image);

// The build variant string sent with the anonymous usage heartbeat, e.g.
// "glass", "deb-rootless". The source of truth is stamped at package time (IPA
// variants set Info.plist "ARBuildVariant"; .deb installs drop an "ARVariant.txt"
// resource). Falls back to "unknown" when no marker is present (dev builds).
NSString *ApolloBuildVariant(void);

// Returns YES when a link-card title is a numeric-ID-style junk string —
// contains at least one digit but no letters at all (e.g. the scraped
// "285023 289273 400021448" title from a single-page-app page). Used to decide
// when to substitute a website name for an unhelpful machine-scraped title.
BOOL ApolloIsJunkNumericTitle(NSString *title);

// Derives a presentable website name from a host ("fifa.com" -> "FIFA",
// "news.bbc.co.uk" -> "BBC", "theverge.com" -> "Theverge"). Short registrable
// labels are uppercased as acronyms; longer ones are title-cased. Returns nil
// when no usable name can be derived (e.g. a raw IP host).
NSString *ApolloWebsiteNameFromHost(NSString *host);

// Returns the URL string a LinkButtonNode is presenting, by reading either
// the obj-c .url getter (older iOS) or the urlTextNode's attributed text
// (iOS 26+ where the Swift URL ivar is no longer ObjC-bridged). May return
// nil if neither path yields a usable string.
NSString *ApolloGetLinkButtonNodeURLString(id linkButtonNode);
void ApolloPresentWebURLFromViewController(UIViewController *presenter, NSURL *url);
// Route a reddit URL through Apollo's own AppDelegate URL handler (native post/
// subreddit/user views). Returns NO if the handler is unavailable — fall back to
// ApolloPresentWebURLFromViewController.
BOOL ApolloRouteURLThroughApp(NSURL *url);

// Returns all UIWindows across every connected UIWindowScene.
// Use instead of the deprecated UIApplication.windows property.
NSArray<UIWindow *> *ApolloAllWindows(void);
// The key window, preferring a foreground-active scene's (each iPad scene can
// have its own key window), else any key window; nil when none is key (e.g.
// mid scene transition) — callers keep their own fallback policy.
// This is app-global state: on multi-window iPad it is the window the user
// last interacted with, not necessarily the one a given piece of UI lives in.
// When a view or view controller is in scope, use its view.window instead.
UIWindow *ApolloKeyWindow(void);
// Refresh title geometry/capsules on one known bar after a local content or
// action change. Never walks the window/page hierarchy (no-op off Liquid Glass).
void ApolloNavigationTitlesRefreshBar(UINavigationBar *bar);
// Global appearance changes (e.g. Header Style) must refresh every live bar.
// Local title owners should use the bar-scoped entry point above instead.
void ApolloNavigationTitlesRefresh(void);
// Settle new content before display, preserving the control, width constraint
// and same-host glass. sameItem also preserves the active action-avoidance spring.
void ApolloNavigationTitleGlassRefreshContent(UIView *titleControl, BOOL sameItem);
// Capture the currently displayed title before publishing action widths, then
// settle collision geometry with the pill's spring. Nil spring means immediate
// placement (Reduce Motion, page teardown or nonanimated updates).
void ApolloNavigationTitleActionsWillChange(UINavigationBar *bar);
void ApolloNavigationTitleActionsDidChange(UINavigationBar *bar, CASpringAnimation *spring);
// Keeps the Liquid Glass title capsule in sync with a custom title view's
// independently-faded content (defined in ApolloLiquidGlass.xm; no-op off LG).
void ApolloNavigationTitleGlassSetContentAlpha(UIView *contentView, CGFloat alpha);
// Re-run the title capsule install/recentre for every title control in the bar (used when a
// navigation transition settles). ApolloLiquidGlass.xm.
void ApolloNavigationTitleGlassRefreshNavigationBar(UINavigationBar *bar);
// YES through interactive push/pop setup and UIKit's completion cleanup (Liquid Glass only).
BOOL ApolloNavTransitionInFlight(void);

// Apollo's main ApolloTabBarController, found via the scene/app delegate's
// tabBarController ivar or by walking window root VCs. Returns nil while the
// UI is still coming up (e.g. cold launch from a URL) — callers should retry.
UIViewController *ApolloMainTabBarController(void);

// Returns YES for Apple's out-of-process share/compose controllers that the
// tweak must never traverse or mutate. Their class names end in
// "ComposeViewController" (e.g. MFMessageComposeViewController), so loose
// suffix matchers misidentify them as Apollo composers and crash when the
// GIF/composer machinery pokes at the remote view hierarchy (issue #366).
// Resolved via objc_getClass so we don't link MessageUI/Social.
BOOL ApolloIsSystemShareComposeController(UIViewController *controller);
// YES when the iOS app is running on visionOS (Apple Vision Pro).
BOOL ApolloIsRunningOnVisionOS(void);

// Present the tweak's fullscreen zoomable image-album viewer (implemented in
// ApolloInlineImages). Items are dictionaries with an @"url" NSURL; despite
// the name it is a generic viewer, not ImageChest-specific. Returns NO when
// items is empty or no presenter could be found from sourceView.
BOOL ApolloPresentImageChestItems(NSArray<NSDictionary *> *items, UIView *sourceView, NSInteger initialIndex);
// Profile-only viewer chrome and native save confirmation.
BOOL ApolloPresentProfileBanner(NSURL *url, UIView *sourceView);
// Returns the generator so the caller can retain it through presentation.
id ApolloPlayPreviewOpenedFeedback(UIView *sourceView);
// As above, but albumURL is the album's page URL when known — it enables the
// viewer's "Share Album Link" action; pass nil otherwise.
BOOL ApolloPresentImageChestItemsWithAlbumURL(NSArray<NSDictionary *> *items, UIView *sourceView, NSInteger initialIndex, NSURL *albumURL);

// Convert between a UIColor and a 6-digit "RRGGBB" hex string. The parser
// tolerates an optional leading '#'; it returns nil for anything that isn't
// exactly six hex digits. The serializer emits uppercase, no '#'. Shared by
// the link-preview card color picker and any other free-form color UI.
UIColor *ApolloColorFromHexString(NSString *hex);
NSString *ApolloHexStringFromColor(UIColor *color);

// Returns YES when a fill color is light enough that dark (black) text reads
// better on top of it than white. Uses Rec.601 luminance. Used to auto-contrast
// the link-preview card text against an arbitrary user-picked card color.
BOOL ApolloColorIsLight(UIColor *color);

// Maps a legacy ApolloLinkPreviewCardColor preset enum value to its UIColor.
// Retained only to migrate a pre-existing preset selection into the new
// free-form hex color the first time a user runs a build with the picker.
UIColor *ApolloLinkPreviewPresetColor(NSInteger preset);

// Packs a hex color into the render-safe snapshot format used by
// sLinkPreviewCardColorPacked: 0 for nil/invalid/empty, otherwise
// (1<<24) | (R<<16) | (G<<8) | B.
uint32_t ApolloPackedColorFromHexString(NSString *hex);

// Canonical setter for the link-preview card color. Normalizes `hex` (nil for
// invalid/empty = Default) and updates BOTH sLinkPreviewCardColorHex (the
// main-thread NSString used by UI/persistence) and the render-safe packed
// snapshot for the renderer. Call on the main thread.
void ApolloSetLinkPreviewCardColorHex(NSString *hex);

// Whether the experimental native Polls feature (voting + creation) is enabled.
// Off by default; toggled from Settings → Polls (UDKeyPollsEnabled). All poll
// entry points — the poll-node tap handler, remembered-vote reconciliation, the
// compose "Poll" post type, and the quick-menu Poll entry — gate on this, so
// with it off the tweak leaves Apollo's stock behavior completely untouched.
BOOL ApolloPollsFeatureEnabled(void);

// ApolloPollCompose: quick post-type picker for the subreddit "..." menu.
// Returns an inline UIMenu (ControlGroup-style icon row: Photo/Link/Text/Poll,
// filtered by the current subreddit's submission rules) that replaces the
// plain "Submit Post" row, or nil to keep the stock row. `selectRow` re-fires
// the original Submit Post action; the tapped type is applied to the compose
// sheet's segmented control when it appears. Called from
// ApolloNativeActionMenuBuildMenu when it hits actionKind 51 (Submit Post).
UIMenu *ApolloSubmitPostTypesMenu(id actionController, void (^selectRow)(void));
// One of the tweak's bundled custom new-post symbols ("custom.photo.badge.plus",
// …) from ApolloPollSymbols.bundle, or nil when the bundle is unavailable —
// callers fall back to a stock SF Symbol. Shared with the Action Menus settings
// preview so its mock of the quick new-post buttons shows the real glyphs.
UIImage *ApolloPollComposeSymbol(NSString *symbolName);

// Container keychain mirror (Tweak.xm): the Valet items the real keychain could not persist
// on a keychain-broken sideload, so a backup taken there still carries the signed-in account.
// Returns an array of { "service", "account", "data" } dicts (empty when the mirror is dormant).
NSArray<NSDictionary *> *ApolloKeychainMirrorItemsForBackup(void);

// Append a login-persistence diagnostic line to the cross-launch buffer in the app container.
// Mirrors the line into a file that survives force-quit, so Export Debug Logs carries the
// session that actually signed the user out. Safe to call from any thread; never logs secrets.
void ApolloAppendLoginDiag(NSString *line);

// Append an iOS 27 list/tab-bar geometry diagnostic to a bounded cross-launch
// buffer. Export Debug Logs prepends this buffer so the foregrounding session
// that produced a stale inset remains available even if Apollo is later killed.
// Never include post titles, account names, URLs, or other user content.
void ApolloAppendListLayoutDiag(NSString *line);

// iOS 26+ Liquid Glass: the tab bar's real expanded/collapsed state, read from
// the visual provider's stored `_currentMorphTarget` (0 expanded, 1 mid-morph,
// 2 minimized). UITabBar's own `_isMinimized` accessor is guarded by an
// Apple-app assertion (UIKit literally checks for Photos), so calling it from a
// sideloaded app crashes — the runtime ivar read is the only safe path.
// Returns NSNotFound with *known = NO when the private layout is missing
// (future iOS). Callers must treat unknown as "assume nothing" and fail OPEN
// (accept UIKit's writes), never as "expanded" — fighting UIKit per frame on a
// wrong guess is worse than missing one correction. Main-thread only.
id ApolloTabBarVisualProvider(UITabBar *tabBar);
NSInteger ApolloTabBarVisualMorphTarget(UITabBar *tabBar, BOOL *known);

// One-byte Swift Bool stored property on the tab bar's visual provider (e.g.
// "isAnimatingCollapsedState"). Swift ivars carry no useful ObjC type encoding
// (RuntimeBrowser shows `void`), so this mirrors UIKit's own one-byte
// read/write of the exported ivar offset. *known = NO when the ivar is gone.
// Main-thread only.
BOOL ApolloTabBarVisualProviderBoolIvar(UITabBar *tabBar, const char *name, BOOL *known);

// Dev-only login-persistence debug (see Tweak.xm): a report of where the account keychain item
// lives (each copy's access group / size / protection class), and a FLEX-gated action that
// poisons/restores the account item's protection class to reproduce the -25300 on demand. Both
// also write to the diag log.
NSString *ApolloDebugAccountKeychainReport(void);
NSString *ApolloDebugPoisonAccountAccessibility(void);

// Marks a tweak-created text node/label as our own UI chrome (AI summary pill,
// injected affordances, ...). Content pipelines that scan the view/node tree
// for USER content (e.g. translation's post-body candidate scan) must skip
// marked objects — otherwise tweak UI can be mistaken for the post body.
void ApolloMarkTweakUITextNode(id node);
BOOL ApolloTextNodeIsTweakUI(id node);

// fishhook consolidation. Every rebind_symbols() call walks all ~2k images
// loaded on iOS 26, so the modules below hand their bindings to the single call
// in Tweak.xm's %ctor instead of each rebinding from its own constructor. The
// direction has to be a pull: constructors run in link order and Tweak.xm links
// first, so a registry those modules pushed into would always be flushed before
// they filled it. Each function writes its bindings at `out` and returns how
// many it wrote; ApolloRebornMaxAppendedRebindings bounds the caller's array.
// swift_allocObject stays out of this batch: ApolloSwiftSingletonCapture is its
// only owner and rebinds just the image that defines each captured class.
// ApolloImageUploadHost's ImageIO bindings likewise rebind only Apollo's image.
struct rebinding;
enum { ApolloRebornMaxAppendedRebindings = 5 };
size_t ApolloPhotoComposerAppendRebindings(struct rebinding *out);
void ApolloImageUploadHostInstallRebindings(void);
__END_DECLS

// Sends a zero-argument object getter when `object` implements it, else nil.
static inline id ApolloSendObject(id object, SEL selector) {
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

// method_setImplementation(method, imp) for a method found on cls. When cls owns
// the method, class_replaceMethod makes the same change but flushes only cls's
// subtree; method_setImplementation does not know the class and flushes the
// method cache of every realized class (~0.4 ms once the app is running).
// An inherited method still goes through method_setImplementation unchanged.
static inline IMP ApolloSetMethodImplementation(Class cls, Method method, IMP imp) {
    SEL name = method_getName(method);
    if (class_getInstanceMethod(cls, name) == method &&
        class_getInstanceMethod(class_getSuperclass(cls), name) != method) {
        return class_replaceMethod(cls, name, imp, method_getTypeEncoding(method));
    }
    return method_setImplementation(method, imp);
}
