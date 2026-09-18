# iPhone Duo readiness

Apollo Reborn is a Theos/Logos tweak injected into stock Apollo (last App Store
build, 2023). Apollo's own layout and device mapper stop at iPhone 14-era
geometry. Apple's iPhone Duo (foldable, expected ~5.4" outer / ~7.6" inner,
iOS 27.1) will exercise size-class changes, dual scenes, horizontal safe
areas, and hinge reserved regions that neither Apollo nor most of this tweak
were written for.

This is a maintainer plan, not a rewrite. Steps 1–4 (device identity + live
island geometry, floating tabs / Liquid Glass scene chrome, feed/post
size-class layouts, then gallery/media hinge avoidance) are implemented.
Step 5 (iOS 27.1 SDK pin) stays queued.

## What is already true in the tweak

| Area | Today | Duo risk |
| --- | --- | --- |
| Device identity (`uname` fishhook in `Tweak.xm`) | Apollo's mapper (`sub_1007a3cdc`) only knows models through iPhone 14 Pro Max. The tweak remaps newer IDs so Pixel Pals / `FauxCutOutView` turn on. **Step 1:** unrecognized iPhones default to the 14 Pro (island) identity; only known notch-only models (16e / 17e) stay on the 14 (notch) identity. No more closed whitelist of every 15/16/17/18 ID. | Process-wide identity is still a single string. A Duo that launches on the inner panel cannot be "island" and "notch" at once. Per-window chrome must keep using live geometry. |
| Dynamic Island chrome | Apollo hardcodes 14 Pro positions (`FauxCutOutView` y=11.5, 125×37). **Step 1:** shift from `-[UIScreen _exclusionArea]` on the *window scene's* screen; hide faux cutout / pals / tap overlay when that screen has no pill-shaped cutout. Dropped the `safeAreaInsets.top == 59` proportional fallback (wrong on iPhone Air / iOS 27, #826). | A hinge or vertical reserved bar must not pass the pill sanity check (it should not). Full `ArrangementView` / `reservedRegions` avoidance is step 4. |
| Floating tabs (`ApolloFloatingTabs.xm`) | **Step 2:** overlay is created on `ApolloDevicePreferredWindowScene()` (never `UIScreen.mainScreen.bounds`). It rebinds on `UISceneDidActivate` and relayouts on safe-area / size-class / bounds changes. Dock, tuck, close target, fan-out, and hold-to-preview use `ApolloDeviceChromeInsetsForView` (safe area + hinge-sized layout-margin extra, not the everyday 16pt). | Overlay is still one window / one scene. A hinge that UIKit does not report as safe area or extra margin is covered for **media/PiP** in step 4; floating-tab bubbles still rely on chrome insets only. |
| Liquid Glass (`ApolloLiquidGlass.xm`) | **Step 2:** nav-title left/right limits use the same chrome insets, so a hinge-adjacent strip shrinks the title/capsule. Pixel snapping uses the window scene's scale. iPad floating-tab placement stays idiom-gated (`ApolloIPadTabBarBottom.xm`). | Inner Duo is still an iPhone idiom with Regular width. Do not turn on the iPad tab-bar-to-bottom path. Action-pill internals are local to the bar-button view (UIKit places the item). |
| Gallery / media (`ApolloGalleryViewController.m`, `ApolloGalleryImageViewer.m`, `ApolloPictureInPicture.xm`) | **Step 4:** chrome / footer / PiP clamp use `ApolloDeviceMediaInsetsForView` (chrome insets max'd with edge-flush reserved regions). A center hinge is a gap, not fake left+right insets: the gallery transport sits on the larger remaining side; MediaPage close + PiP buttons shift off the rect. Gallery columns go even when a (possibly inactive) division exists. `UIArrangementViewController` is detected but unused — media is full-bleed, not a primary/secondary pair. | Runtime `reservedRegions` spelling/kind values are probed (0..2). A hinge UIKit never reports still cannot be guessed from `_exclusionArea`. SDK pin is step 5. |
| Feed / posts | **Step 3:** no stock Regular-width split to unlock. The tweak tiles inside `_TtC6Apollo26ApolloNavigationController` when the horizontal size class is Regular and the usable width is at least two 320pt columns (`ApolloFeedSplitLayout.h`). Compact stays a single column. Feed VCs (Posts / LitePosts / Saved / search results) sit leading; `CommentsViewController` sits trailing. Swipe-up pane comments are skipped. Tab children stay Apollo navs — do **not** wrap them in `UISplitViewController`. `ApolloIPadTabBarBottom` stays idiom-gated. | Profile / inbox / settings pushes stay stacked. Feed cells that size from the screen instead of their view may still stretch inside a column. Hinge pixels that are not extra layout margin are step 4. |
| Toolchain | Device: `TARGET := iphone:clang:26.0:14.0`. Sim: `latest` / iOS 15.0 floor. Liquid Glass needs a glass-patched guest (SDK 19+/26+) plus iOS 26+ runtime. | Duo-specific reserved-region / full-bleed APIs are iOS 27.1. Do not bump the pinned 26.0 SDK until that SDK is actually available to Theos **and** we still need iOS 14 device builds. **Step 5.** |

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
  - feed only → centered, capped at 700pt
  - feed + comments → tiled leading | trailing
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

- Do **not** pin `TARGET` to 27.1 (step 5). The 26.0 SDK has no
  `reservedRegions` headers, so the call is entirely runtime:
  `respondsToSelector:` for `reservedRegionsForKind:options:` (and two
  spelling fallbacks), kind probe `0..2`, options bit 0 = includeInactive.
- Soft-degrade: missing selector → empty rect list →
  `ApolloDeviceMediaInsetsForView` equals `ApolloDeviceChromeInsetsForView`
  (safe area + hinge-sized layout-margin extra). iOS 14 builds unchanged.
- A center hinge is a **gap**, not left+right edge insets (those would
  collapse the whole viewer). Edge-flush camera / island occlusions max
  with chrome so an island already inside `safe.top` is not double-counted.
- Gallery viewer chrome, gallery footer, MediaPage close button, fullscreen
  PiP button, and the in-app PiP card use that path.
  `UIArrangementViewController` is logged if present and left unused —
  wrapping the pager would break presentation / swipe-up / PiP.
- `_exclusionArea` is still island-only (pill sanity). A non-pill rect is
  not treated as a hinge.

### 5. Toolchain toward iOS 27.1

- Pin a 27.1 SDK the same way AGENTS.md pins 26.0 (`$THEOS/sdks`), without
  raising the device deployment floor past 14.0.
- Simulator stays on `latest` (do not pair an old Simulator SDK with a newer
  clang).
- Gate new 27.1-only calls with availability / `respondsToSelector:`.

## Testing

The cloud Linux VM cannot run Theos or the iOS Simulator. Validate on a Mac:

```bash
# Host-side identity + chrome-inset + feed-split + reserved-region math (no UIKit)
tests/run_device_identity_tests.sh
tests/run_feed_split_layout_tests.sh
tests/run_reserved_region_tests.sh

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

Confirm feed | comments size-class layout (step 3):

- Compact portrait (any phone): opening a post still covers the feed.
- Regular landscape (Plus/Max sim, or Duo inner Regular): opening a post
  keeps the feed on the leading side and comments on the trailing side.
  `[FeedSplit] mode=tiled` in `apollofix` logs.
- Regular with no post open: feed is a centered column (`mode=centered`),
  not a 900pt+ stretched list.
- Fold / rotate Regular → Compact: comments go full width; feed leaves.
- Tap a second post in the still-visible feed: comments column replaces,
  back still returns to the feed.
- Swipe-up-for-comments media pane is unchanged (sheet, not a tile).
- iPad "Move Tab Bar to Bottom" stays off on iPhone.

Confirm gallery / media hinge avoidance (step 4):

- Pre-27.1 sim: gallery Done / transport and PiP corners match today's
  safe-area layout (chrome extra is 0 on a normal iPhone). Log:
  `[MediaHinge] reservedRegions unavailable; chrome/safe-area fallback`.
- PiP last-resort window is created from `ApolloDevicePreferredScreen()`,
  not a raw `mainScreen.bounds` read.
- When a Duo sim / 27.1 runtime exists: open Gallery and MediaViewer on
  the inner display, partially fold. Transport / close / PiP card stay
  off the division strip. Log: `[MediaHinge] reservedRegions selector=…`.
- Gallery grid uses an even column count while a division region exists.
- Flat (inactive zero-width division) does not change columns or chrome.

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
- iOS 27.1 `reservedRegions` is called only through `objc_msgSend` after
  `respondsToSelector:`. Kind raw values and the exact selector spelling
  may still drift when the 27.1 SDK ships — step 5 should replace the
  probe with real headers if they differ.
- `UIArrangementViewController` is intentionally not adopted for
  MediaViewer / gallery (full-bleed pager, not a primary/secondary pair).
