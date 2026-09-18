# iPhone Duo readiness

Apollo Reborn is a Theos/Logos tweak injected into stock Apollo (last App Store
build, 2023). Apollo's own layout and device mapper stop at iPhone 14-era
geometry. Apple's iPhone Duo (foldable, expected ~5.4" outer / ~7.6" inner,
iOS 27.1) will exercise size-class changes, dual scenes, horizontal safe
areas, and hinge reserved regions that neither Apollo nor most of this tweak
were written for.

This is a maintainer plan, not a rewrite. Steps 1 and 2 (device identity +
live island geometry, then floating tabs / Liquid Glass scene chrome) are
implemented. Steps 3–5 stay queued.

## What is already true in the tweak

| Area | Today | Duo risk |
| --- | --- | --- |
| Device identity (`uname` fishhook in `Tweak.xm`) | Apollo's mapper (`sub_1007a3cdc`) only knows models through iPhone 14 Pro Max. The tweak remaps newer IDs so Pixel Pals / `FauxCutOutView` turn on. **Step 1:** unrecognized iPhones default to the 14 Pro (island) identity; only known notch-only models (16e / 17e) stay on the 14 (notch) identity. No more closed whitelist of every 15/16/17/18 ID. | Process-wide identity is still a single string. A Duo that launches on the inner panel cannot be "island" and "notch" at once. Per-window chrome must keep using live geometry. |
| Dynamic Island chrome | Apollo hardcodes 14 Pro positions (`FauxCutOutView` y=11.5, 125×37). **Step 1:** shift from `-[UIScreen _exclusionArea]` on the *window scene's* screen; hide faux cutout / pals / tap overlay when that screen has no pill-shaped cutout. Dropped the `safeAreaInsets.top == 59` proportional fallback (wrong on iPhone Air / iOS 27, #826). | A hinge or vertical reserved bar must not pass the pill sanity check (it should not). Full `ArrangementView` / `reservedRegions` avoidance is step 4. |
| Floating tabs (`ApolloFloatingTabs.xm`) | **Step 2:** overlay is created on `ApolloDevicePreferredWindowScene()` (never `UIScreen.mainScreen.bounds`). It rebinds on `UISceneDidActivate` and relayouts on safe-area / size-class / bounds changes. Dock, tuck, close target, fan-out, and hold-to-preview use `ApolloDeviceChromeInsetsForView` (safe area + hinge-sized layout-margin extra, not the everyday 16pt). | Overlay is still one window / one scene. A hinge that UIKit does not report as safe area or extra margin is step 4 (`reservedRegions`). PiP still has a `mainScreen` last-resort frame — out of step 2 scope. |
| Liquid Glass (`ApolloLiquidGlass.xm`) | **Step 2:** nav-title left/right limits use the same chrome insets, so a hinge-adjacent strip shrinks the title/capsule. Pixel snapping uses the window scene's scale. iPad floating-tab placement stays idiom-gated (`ApolloIPadTabBarBottom.xm`). | Inner Duo is still an iPhone idiom with Regular width. Do not turn on the iPad tab-bar-to-bottom path. Action-pill internals are local to the bar-button view (UIKit places the item). |
| Gallery / media (`ApolloGalleryViewController.m`, `ApolloGalleryImageViewer.m`) | Column count follows view width; viewer chrome uses `safeAreaInsets` including left/right. | No hinge avoidance; full-bleed viewers can draw under a fold. **Step 4.** |
| Feed / posts | Almost no `horizontalSizeClass` / `UISplitViewController` usage. `traitCollectionDidChange:` is mostly appearance. Devvit posts already react to width-class changes. | Inner 7.6" will look like a wide iPhone, not an iPad. Compact-only feed metrics will stretch. **Step 3.** |
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

### 3. Feed / post size-class layouts

- Inventory feed, compact post, comments header, and settings form widths.
- Prefer the view's `traitCollection.horizontalSizeClass` and readable
  content / layout margins over idiom checks. Duo inner is Regular-width
  iPhone, not iPad — do not turn on `ApolloIPadTabBarBottom` there.
- Split-view is optional and stock-Apollo-shaped; do not invent a sidebar
  unless Apollo already has a Regular-width path worth unlocking.

### 4. Gallery / media hinge avoidance

- Keep using live `safeAreaInsets` (already the viewer path).
- When iOS 27.1 `ArrangementView` / reserved regions are available, inset
  full-bleed gallery, MediaViewer, and PiP so content is not under the fold.
- Until that SDK exists, treat a non-pill `_exclusionArea` as "do not draw
  island chrome" only — do not guess a hinge rectangle.

### 5. Toolchain toward iOS 27.1

- Pin a 27.1 SDK the same way AGENTS.md pins 26.0 (`$THEOS/sdks`), without
  raising the device deployment floor past 14.0.
- Simulator stays on `latest` (do not pair an old Simulator SDK with a newer
  clang).
- Gate new 27.1-only calls with availability / `respondsToSelector:`.

## Testing

The cloud Linux VM cannot run Theos or the iOS Simulator. Validate on a Mac:

```bash
# Host-side identity + chrome-inset math (no UIKit)
tests/run_device_identity_tests.sh

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
- Note Regular-width feed stretch — that is step 3, not a step 1–2
  regression. Gallery/media under the fold is step 4.

Device IPA remains required for APNs, FFmpeg v.redd.it remux, and anything
the sim stubs.

## Residual risks

- Stock Apollo may still assume a single phone-sized window. Steps 1–2
  cannot fix feed column math or media viewers.
- `_exclusionArea` is private. If it disappears or starts returning hinge
  rects, the pill sanity check fails closed (no shift, hide tweak chrome).
- `uname` remapping is process-wide, happens on arbitrary threads, and does
  not consult UIKit. Later layout uses the live window's cutout.
- iOS 27.1 APIs are unavailable in the pinned 26.0 SDK. Do not call them
  until step 5.
