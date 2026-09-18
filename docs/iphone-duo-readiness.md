# iPhone Duo readiness

Apollo Reborn is a Theos/Logos tweak injected into stock Apollo (last App Store
build, 2023). Apollo's own layout and device mapper stop at iPhone 14-era
geometry. Apple's iPhone Duo (foldable, expected ~5.4" outer / ~7.6" inner,
iOS 27.1) will exercise size-class changes, dual scenes, horizontal safe
areas, and hinge reserved regions that neither Apollo nor most of this tweak
were written for.

This is a maintainer plan, not a rewrite. Steps 1–5 are implemented
(device identity + live island geometry, floating tabs / Liquid Glass
scene chrome, feed/post size-class layouts, gallery/media hinge
avoidance, then the 27.1 *tweak* SDK pin with a 26.0 CI fallback).
A follow-on **screen-fill** pass (section 6) addresses the Duo sim
letterbox: the *guest* Apollo binary still advertised SDK 19.0 / 26.

## What is already true in the tweak

| Area | Today | Duo risk |
| --- | --- | --- |
| Device identity (`uname` fishhook in `Tweak.xm`) | Apollo's mapper (`sub_1007a3cdc`) only knows models through iPhone 14 Pro Max. The tweak remaps newer IDs so Pixel Pals / `FauxCutOutView` turn on. **Step 1:** unrecognized iPhones default to the 14 Pro (island) identity; only known notch-only models (16e / 17e) stay on the 14 (notch) identity. No more closed whitelist of every 15/16/17/18 ID. | Process-wide identity is still a single string. A Duo that launches on the inner panel cannot be "island" and "notch" at once. Per-window chrome must keep using live geometry. |
| Dynamic Island chrome | Apollo hardcodes 14 Pro positions (`FauxCutOutView` y=11.5, 125×37). **Step 1:** shift from `-[UIScreen _exclusionArea]` on the *window scene's* screen; hide faux cutout / pals / tap overlay when that screen has no pill-shaped cutout. Dropped the `safeAreaInsets.top == 59` proportional fallback (wrong on iPhone Air / iOS 27, #826). | A hinge or vertical reserved bar must not pass the pill sanity check (it should not). Full `ArrangementView` / `reservedRegions` avoidance is step 4. |
| Floating tabs (`ApolloFloatingTabs.xm`) | **Step 2:** overlay is created on `ApolloDevicePreferredWindowScene()` (never `UIScreen.mainScreen.bounds`). It rebinds on `UISceneDidActivate` and relayouts on safe-area / size-class / bounds changes. Dock, tuck, close target, fan-out, and hold-to-preview use `ApolloDeviceChromeInsetsForView` (safe area + hinge-sized layout-margin extra, not the everyday 16pt). | Overlay is still one window / one scene. A hinge that UIKit does not report as safe area or extra margin is covered for **media/PiP** in step 4; floating-tab bubbles still rely on chrome insets only. |
| Liquid Glass (`ApolloLiquidGlass.xm`) | **Step 2:** nav-title left/right limits use the same chrome insets, so a hinge-adjacent strip shrinks the title/capsule. Pixel snapping uses the window scene's scale. iPad floating-tab placement stays idiom-gated (`ApolloIPadTabBarBottom.xm`). | Inner Duo is still an iPhone idiom with Regular width. Do not turn on the iPad tab-bar-to-bottom path. Action-pill internals are local to the bar-button view (UIKit places the item). |
| Gallery / media (`ApolloGalleryViewController.m`, `ApolloGalleryImageViewer.m`, `ApolloPictureInPicture.xm`) | **Step 4:** chrome / footer / PiP clamp use `ApolloDeviceMediaInsetsForView` (safe area + hinge-sized layout-margin extra). C geometry helpers stay; the reserved-rect list is always empty. `UIArrangementViewController` is detected but unused — media is full-bleed, not a primary/secondary pair. | Do **not** call UIKit `reservedRegions` — it SIGSEGVs on Duo even with window+scene during first CA commit (x0=NULL at +0x10). A hinge UIKit never reports as layoutMargins / safe area still cannot be guessed from `_exclusionArea`. |
| Feed / posts | **Primary open-Duo chrome is the concept mock + rail:** current **feed** on the left, selected **post + comments** on the right. Slim rail: Home, Popular, All, **My Subreddits** (not Saved), Profile, Settings. My Subreddits is list\|feed while picking; a sub tap dismisses the directory and pins that sub’s posts leading. Opening a post is feed\|comments. Compact stays the stock tab bar + single column. Do **not** wrap tabs in `UISplitViewController`. | Cover display has no companion UI. Inbox is not a rail item. |
| Toolchain | **Step 5:** device `make package` pins `iphone:clang:27.1:14.0` when `iPhoneOS27.1.sdk` exists; otherwise `26.0:14.0`. Sim: unchanged `latest` / 15.0. **Screen-fill:** `--liquid-glass` now sets the *guest* `LC_BUILD_VERSION` sdk to **27.1** (still min 15.0) so Duo grants a full canvas; `IsLiquidGlass()` remains major >= 19. | A 27.1 Simulator runtime is not a device SDK. Cached `.sim/glass-base.ipa` at 19.0 must be regenerated. Classic (no glass) guests stay letterboxed. CI (Xcode 26.0.1) stays on the tweak 26.0 fallback. |

## Phased work

### 1. Device identity + live island geometry — this change

- Unrecognized `iPhone*` machine IDs remap to `iPhone15,2` unless they are a
  known notch exception (`src/ApolloDeviceIdentity.h`).
- Island rect / Pixel Pal shift / chrome visibility live in
  `src/ApolloDeviceGeometry.{h,m}` and key off the window's scene screen.
- Feed-search's last-resort `59.0` top inset is gone; it reads a live window
  safe area instead (`ApolloSearchInPlace.xm`).

Do **not** expand this step into ArrangementView, size-class feed rewrites, or
an SDK bump.

### 2. Floating tabs + Liquid Glass follow the active scene — done

- Overlay binds to the foreground `UIWindowScene` (`ApolloDeviceGeometry`).
  No scene yet → `CGRectZero` window, then `window.windowScene =` on
  `UISceneDidActivate`. `mainScreen.bounds` is not a geometry source.
- Root overlay VC relayouts on rotation, `safeAreaInsetsDidChange`,
  horizontal/vertical size-class changes, and bounds changes.
- Dock / tucked sliver / close target / preview / fan-out use
  `ApolloDeviceChromeInsetsForView` so horizontal safe areas and
  hinge-sized layout-margin extras apply. Standard 16pt system margins
  do **not** push bubbles inward on a normal iPhone
  (`src/ApolloDeviceChromeInsets.h`).
- Liquid Glass title fitting uses the same insets; search-cancel reservation
  no longer re-subtracts `layoutMargins.right` on top of that.

Do **not** expand this step into feed size-class layouts, ArrangementView,
or an SDK bump.

### 3. Feed / post size-class layouts — done

- Inventory: stock Apollo has almost no `horizontalSizeClass` /
  `UISplitViewController` usage. `ApolloAutoHideMetaFeeds` already walked
  split columns defensively; it now also treats a nav child whose view is
  still in the window as visible (the tiled feed).
- Regular + usable width ≥ 652pt (`320+12+320`):
  - list only / feed only → leading half on Duo-wide / rail-active canvases
    (never a full-bleed column across the hinge); Plus landscape still centers
    unless the Duo rail is active. Leading extra is at least the rail width
    so row text cannot start under the rail. The shared navigation bar is
    pinned to the owning pane (leading when the feed is alone, trailing
    when the top VC is the tiled detail) so titles do not sit on the hinge.
  - feed + comments → tiled **feed | comments** (primary mock reading pair)
  - list + feed → tiled **list | feed** (My Subreddits directory). Tapping
    a subreddit dismisses the directory from the stack but retains the
    list VC so Subs can restore `@[savedList, feed]`. That sub's posts
    sit in the leading half. Opening a topic is `feed | comments` (or
    any reading-detail pane).
- Compact, unspecified, or Regular-but-narrow → stacked (UIKit's existing
  push). Swipe-up media-pane comments never tile.
- Column frames use `ApolloDeviceChromeExtra` (hinge-sized layout-margin
  extra only) so children still apply their own `safeAreaInsets`.
- Opening another post from the still-visible feed replaces the comments
  column instead of pushing a third screen.
- Do **not** turn on `ApolloIPadTabBarBottom` on iPhone idiom Regular.

Do **not** expand this step into ArrangementView / reservedRegions or an
SDK bump.

### 4. Gallery / media hinge avoidance — done

- Do **not** wrap media in `UIArrangementViewController`. Do **not** call
  UIKit `reservedRegions` / `reservedRegionsForKind:options:` — probing
  kinds 0..2 on a normal navigation view SIGSEGVs on the Duo sim even
  after `view.window` and `windowScene` are set (first CA commit,
  `x0=NULL` at +0x10). That is not an NSException.
- Soft-degrade: `ApolloReservedCollect` returns 0 / zero margins, so
  `ApolloDeviceMediaInsetsForView` equals `ApolloDeviceChromeInsetsForView`
  (safe area + hinge-sized layout-margin extra). iOS 14 builds unchanged.
- A center hinge is a **gap**, not left+right edge insets (those would
  collapse the whole viewer). Edge-flush camera / island occlusions max
  with chrome so an island already inside `safe.top` is not double-counted.
- Gallery viewer chrome, gallery footer, MediaPage close button, fullscreen
  PiP button, and the in-app PiP card use that path.
  `UIArrangementViewController` is logged if present and left unused —
  wrapping the pager would break presentation / swipe-up / PiP.
- On open Duo, `MediaViewerController` (and the presented MediaPage) pin
  to the trailing half — the same rect as the comments/detail pane — so
  an image opened from the right post does not sit under the hinge.
  `MediaPage` / `MediaViewer` disappear and
  `MediaViewerPresentationController dismissalTransitionDidEnd` call
  `ApolloFeedSplitReapplyVisible()` at 0.05s and 0.2s so the two-pane
  split returns after swipe-dismiss. `reservedRegions` stays unused.
- `_exclusionArea` is still island-only (pill sanity). A non-pill rect is
  not treated as a hinge.

### 5. Toolchain toward iOS 27.1 — done

- Device pin (Makefile, only when `TARGET` is not on the command line):
  `iphone:clang:27.1:14.0` if `iPhoneOS27.1.sdk` exists in `$THEOS/sdks`
  (`THEOS_SDKS_PATH`) or `$(xcode-select -p)/Platforms/iPhoneOS.platform/Developer/SDKs`;
  else `iphone:clang:26.0:14.0`. Floor stays `:14.0`. Override with
  `APOLLO_DEVICE_SDK=27.1` or `26.0`.
- Theos matches the **folder name** `iPhoneOS<version>.sdk` (see
  `$THEOS/makefiles/targets/_common/darwin_head.mk`). The unversioned
  `iPhoneOS.sdk` does not satisfy a `27.1` pin.
- **Do not** copy Xcode 26.6's `iPhoneOS.sdk` (or any 26.x device SDK) to
  `$THEOS/sdks/iPhoneOS27.1.sdk`. An iOS 27.1 Simulator runtime
  (`com.apple.CoreSimulator.SimRuntime.iOS-27-1`) is not this SDK. Confirm
  `SDKSettings.json` → `Version` is `27.1` before copying from an Xcode
  that actually ships the 27.1 *device* SDK.
- Simulator stays on `latest` / `DEPLOY_MIN=15.0` (`scripts/run-in-sim.sh`).
  Do not pair an old Simulator SDK with a newer clang.
- CI workflows still `xcode-select` Xcode 26.0.1 and do not install 27.1.
  The Makefile fallback keeps those builds on 26.0. When a runner later
  ships a real `iPhoneOS27.1.sdk`, the pin flips without a workflow change.
- Do **not** call `reservedRegions` from the launch / first-layout path.
  A window+scene guard was not enough on Duo. Revisit only with a
  documented-safe UIKit API after compiling against a real
  `iPhoneOS27.1.sdk` — never reintroduce a delayed probe in a crash fix.

Install notes for maintainers: AGENTS.md / CONTRIBUTING.md "Required SDK".

### 6. Fill the inner Duo display — this change

Root cause of the "phone column on the left of a large Duo frame":
iPhone Duo letterboxes the **guest Apollo binary** from its
`LC_BUILD_VERSION` SDK, not from the tweak's Theos pin.

| Guest SDK (vtool) | Duo inner canvas |
| --- | --- |
| stock Apollo (iOS 16) or glass `19.0` | Phone-sized column, black/chrome unused |
| iOS 27.0 | More room, still gaps |
| iOS 27.1 | Full-bleed to the screen edges |

`--liquid-glass` used `vtool -set-build-version ios 15.0 19.0`. That
flips `IsLiquidGlass()` (major >= 19) but Duo still treats the app as
pre-27. The bump is now `ios 15.0 27.1`. Classic / icons-only builds are
unchanged (no SDK bump → still letterboxed; use `--glass`).

Runtime belt (`src/ApolloDeviceDisplay.{h,m,xm}`):

- Prefer the largest foreground scene when two attached screens look like
  inner+cover (area ratio >= 1.25). Single-screen iPhone / iPad keep the
  first-active scene (no Stage Manager surprise).
- Raise `sizeRestrictions` and `requestGeometryUpdate` when those
  selectors exist; resize `ThemeableWindow` to the scene/screen canvas
  if it is still a phone column.
- Floating-tab overlay binds to **the app window's scene**, not a
  different preferred scene, so a full-size passthrough window cannot
  sit on the unused chrome and eat hits. `canBecomeKeyWindow` stays NO.
- Do **not** wrap the app in `UISplitViewController`. FeedSplit tiles
  inside `ApolloNavigationController` once Regular width actually
  occurs on the filled canvas.
- **Primary open-Duo chrome (concept mock + rail):** current
  destination **feed** on the left (Home / Popular / All / selected
  subreddit; sort pills stay Apollo’s Hot/New/Top/Rising), selected
  **post + comments** on the right. Wide canvases use a hinge-aware
  ~50/50 split. The previous “list | feed as the only primary chrome”
  ask is superseded.
- Slim rail, top → bottom: Home, Popular, All, **My Subreddits**,
  then Profile and Settings at the bottom. My Subreddits overlays the
  subscriptions list in the left pane with the current feed on the
  right; tapping a subreddit dismisses the directory (list retained)
  and pins that sub's posts leading. Tapping Subs again restores
  list|feed. Opening a topic tiles feed | comments (or any
  reading-detail pane). Compact and ordinary Plus landscape keep the
  stock tab bar.

Cover / outer display: no second Apollo UI. The cover is left alone
aside from not stealing the key window or overlay. Dual `simctl io`
displays (LCD vs LCD-1) still need `--display` when screenshotting.

Verify on a Mac:

```bash
# Cached .sim/glass-base.ipa at sdk 19.0 will be regenerated.
SIM_NAME="Apollo Duo" \
SIM_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-27-1 \
scripts/run-in-sim.sh --glass --fresh-app --logs
```

Expect `[DeviceDisplay] canvas fill hook installed` and `[DuoRail]
shown`. The UI must span the **inner** display (not a phone column)
with the slim rail on the leading edge. Home / Popular / All should
put that **feed in the left pane**. Opening a post tiles **feed |
comments** (`[FeedSplit] mode=tiled pair=feed-comments`). My
Subreddits shows the list leading (`pair=list-feed`); tapping a
subreddit dismisses the directory and pins that sub's posts leading.
Opening a post is `pair=feed-comments`.
`vtool -show-build .sim/Payload/Apollo.app/Apollo` should report `sdk 27.1`.

## Testing

The cloud Linux VM cannot run Theos or the iOS Simulator. Validate on a Mac:

```bash
# Host-side identity + chrome-inset + feed-split + reserved-region + canvas math
tests/run_device_identity_tests.sh
tests/run_feed_split_layout_tests.sh
tests/run_reserved_region_tests.sh
tests/run_device_display_tests.sh
tests/run_duo_rail_layout_tests.sh

# Default inner loop
scripts/run-in-sim.sh --logs

# Known island / notch sims (names vary by Xcode)
SIM_DEVICE_TYPE=iPhone-16-Pro scripts/run-in-sim.sh --logs
SIM_DEVICE_TYPE=iPhone-16e scripts/run-in-sim.sh --logs   # notch exception
SIM_DEVICE_TYPE=iPhone-Air scripts/run-in-sim.sh --logs   # #826 geometry

# Optional: glass chrome + floating tabs
scripts/run-in-sim.sh --glass --logs
```

Confirm floating tabs / Liquid Glass (step 2):

- Enable Floating Tabs; keep a post; rotate and (if available) change
  simulated size. Bubbles stay on the scene edges, not `mainScreen`.
- Landscape: dock/tuck/✕ sit inside the horizontal safe area.
- Liquid Glass: long titles truncate before the leading/trailing chrome;
  search cancel still fits.
- `[FloatingTabs] Overlay window created (scene=yes)` / `Overlay rebound`
  in `apollofix` logs.

Confirm feed size-class layout (step 3 + open Duo):

- Compact portrait (any phone): stock tab bar; opening a subreddit or
  post still covers the previous screen. No rail.
- Regular / Duo inner open: slim rail + **feed | comments** after a
  post (`[FeedSplit] mode=tiled pair=feed-comments`). Home / Popular /
  All switch feeds and stay **leading-half** when alone (`mode=centered`).
  My Subreddits is `pair=list-feed` while picking; tapping a subreddit
  puts that sub's posts in the left half (list retained). Tapping Subs
  again restores the directory. Opening a topic is `pair=feed-comments`
  (any reading-detail pane), not a full-screen push. List/feed text
  starts after the rail; nav titles live in the owning pane, not on
  the hinge. No ghosted duplicate rows after a sub pick or post open.
- A center reserved hinge should sit in the gutter, not under a
  title or comment.
- List-only or feed-only on the stack (no pair): leading half
  (`mode=centered`, Duo-wide / rail), not a 900pt+ column across the fold.
- Fold / rotate Regular → Compact: comments go full width; feed leaves.
- Tap a second post in the still-visible feed: comments column replaces,
  back still returns to the feed.
- Swipe-up-for-comments media pane is unchanged (sheet, not a tile).
- iPad "Move Tab Bar to Bottom" stays off on iPhone.

Confirm gallery / media hinge avoidance (step 4):

- Gallery Done / transport and PiP corners use chrome / safe-area /
  layoutMargins (reserved-rect list is always empty). Launch on Duo must
  not SIGSEGV in UIKit reservedRegions.
- PiP last-resort window is created from `ApolloDevicePreferredScreen()`,
  not a raw `mainScreen.bounds` read.
- When a Duo sim / 27.1 runtime exists: open Gallery and MediaViewer on
  the inner display, partially fold. Transport / close / PiP card stay
  off a hinge that UIKit reports as safe area or extra layout margin.
- Open a topic (feed left, post right), tap the image in the right pane:
  MediaViewer stays in the trailing half. Swipe-dismiss: two-pane split
  returns (feed does not stretch across the hinge; rail stays in its
  column, not floating on a full-bleed list).
- Gallery grid column-count stays on the chrome-only path (no division
  probe) until a safe reserved-region API exists.

Confirm Pixel Pals / faux cutout:

- 14 Pro baseline: no y-shift (island matches Apollo's 11.5).
- Newer island phones: pals sit on the live cutout, not a 59pt rule.
- 16e / 17e: no faux island.
- Display Zoom and landscape: island rect still tracks `_exclusionArea`.
- `subsystem == "apollofix"` logs `[PixelPals] island cutout …` once.

When a Duo simulator or device exists:

- Launch folded and unfolded; fold while a feed, comments, gallery, and a
  floating tab are open.
- Confirm the faux island is only on the panel that has a pill cutout.
- Fold with a floating tab open: overlay should follow the active scene;
  slivers should not rest in a hinge strip that UIKit reports as safe area
  or extra layout margin.
- Gallery / MediaViewer / PiP should already clear a reserved-region
  hinge. A fold UIKit does not report is still unfixable without guessing.
  Regular-width feed | comments should already tile.

Device IPA remains required for APNs, FFmpeg v.redd.it remux, and anything
the sim stubs.

## Residual risks

- Stock Apollo may still assume a single phone-sized window. Steps 1–4
  cannot invent a hinge UIKit does not expose as reservedRegions, safe
  area, or extra layout margin.
- Feed | comments tiling keeps the real nav stack (so floating tabs, URL
  routing, and swipe-up capture still see `ApolloNavigationController`),
  but it fights Apollo's push/pop animator for one layout pass. If a
  transition looks wrong, check that apply is skipped while
  `transitionCoordinator` is set.
- Plus/Max landscape is Regular, so those users now get the two-pane
  feed | comments layout. That is intentional, not a Duo-only gate.
- Some Texture / post cells may still size from the screen width rather
  than the column. Devvit already reacts to size-class changes.
- `_exclusionArea` is private. If it disappears or starts returning hinge
  rects, the pill sanity check fails closed (no shift, hide tweak chrome).
- `uname` remapping is process-wide, happens on arbitrary threads, and does
  not consult UIKit. Later layout uses the live window's cutout.
- Do **not** call iOS 27.1 `reservedRegions` (any selector spelling) from
  this tweak. Window+scene is not a sufficient guard: first CA commit on
  Duo still SIGSEGVs (`x0=NULL` at +0x10). C geometry helpers stay; gutters
  come from layoutMargins / chrome. Do not add a delayed probe.
- A 27.1 device SDK may set `MinimumDeploymentTarget` to 15.0 the same
  way later 26/27 SDKs did. We still pass `:14.0`. If clang starts
  hard-failing that combination, keep the 26.0 fallback for ship builds
  rather than raising the floor.
- `UIArrangementViewController` is intentionally not adopted for
  MediaViewer / gallery (full-bleed pager, not a primary/secondary pair).
- Duo full-bleed is a **guest SDK** advertisement. Runtime window fill
  cannot enlarge a scene UIKit has already letterboxed if the system
  refuses `requestGeometryUpdate`. Classic / `--liquid-glass-icons`
  builds stay in the phone column until they are glass-patched.
- SDK 27.1 also opts the guest into Duo's vertical navigation / toolbar
  placement. Apollo's custom nav may look different from 19.0 glass;
  report leftovers rather than fighting UIKit's chrome.
- Cover display: no companion UI. Screenshot `simctl io` may pick LCD
  vs LCD-1 — pass the display id. Touches on the unused chrome should
  fall through the floating-tab overlay (`hitTest` + same-scene bind).
- Apollo's Posts-tab second tap still pops to the list (list-only
  leading on Duo). That is stock navigation, not a three-column keep.
- The Duo rail hides the stock tab bar (and `_UITabContainerView` when
  present). Inbox is not a rail item; open it from the inbox destination
  Apollo already owns. Auto-hide-on-scroll will not unhide the tab bar
  while the rail is active.
- Sort pills (Hot/New/Top/Rising) stay Apollo's existing feed chrome —
  the rail does not reimplement them.
- list | feed is the My Subreddits directory. A sub tap dismisses it
  from the visible stack but retains the list VC; Subs restores
  `@[savedList, feed]`. Opening a topic is feed | comments (or any
  reading-detail pane). Do **not** add UIView `layoutSubviews`
  frame-lock hooks (they freeze scroll and buttons).
- The slim rail is painted on the tab controller. FeedSplit leading
  extra is at least `ApolloDuoRailWidth` so columns start to its right.
  Tab-level `additionalSafeAreaInsets.left` is not used for Posts
  (Texture ignored it; UIKit tables would double-count). Profile /
  Settings navs still get that inset. The shared `UINavigationBar`
  stays full-width from the rail; only the title control is shifted
  into the owning pane (shrinking the bar onto comments ghosted the
  post title). Apply is skipped while a column scroll view is
  tracking/decelerating. Subs must not call `goToHomeTab` — that
  popped/reset the stack and re-dismissed the restored directory.
