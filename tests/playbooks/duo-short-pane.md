# Duo short pane (another window above Apollo)

On a real iPhone Duo, a Picture in Picture video or a second app can sit on the
inner display's top part, with Apollo in the bottom pane. The window then keeps
the full width but its height drops below 600pt. `ApolloDuoSplitIsShortPane()`
is YES and `ApolloDuoCurrentMode()` is Phone (0). On device, the pane split is
uneven when the display is flat (in the user's screenshots the video took a bit
less than half). Partially folded, it splits evenly at the hinge. Code must read
the live window/scene geometry and `reservedRegionsOfKind:divisionRegionKind`,
and never a hard-coded pane height.

## Reproducing in the simulator

The iOS 27.3 simulator cannot tile a second app or PiP on the Duo's inner
display. Device Hub has no multitasking control, and synthesized host mouse
events are off limits. Use the sim-only SimDebugTap stand-in instead
(`src/ApolloSimDebugTap.xm`, `APOLLO_SIM_BUILD` only):

```sh
U=8285ABEF-2CED-4594-9E03-2B61337A8D5B   # iPhone Duo, iOS 27.3
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
THEOS=$HOME/theos SIM_NAME="iPhone Duo" scripts/run-in-sim.sh --glass
tap() { printf '%s' "$1" > /tmp/apollofix-tap.txt; xcrun simctl spawn $U notifyutil -p apollofix.debugtap; }
tap "openurl https://www.reddit.com/r/EarthPorn"   # load an image feed first, full screen
tap "shortpane 440"   # window = (0, sceneH-440, sceneW, 440); default height 440
tap "duogeom"         # logs mode, window/screen/safe area, tab bar, feed tables + cells
tap "shortpane off"   # restore the full scene
xcrun simctl io $U screenshot --display=3 inner.png   # inner display
xcrun simctl spawn $U log show --last 1m --predicate 'subsystem == "apollofix"' | grep -E 'DuoFeed|DuoMeasure|duogeom' -A8
```

What `shortpane` does, so its artifacts are not mistaken for app bugs:

- It sends `viewWillTransitionToSize:` with a minimal animating coordinator to
  the root, then sets the window frame inside an animation. Apollo's split and
  rail code therefore runs the same resize path as a real pane change, including
  `sDuoSplitTargetSize`.
- A sim-only `-[UIWindow setFrame:]` override keeps the pane frame in place.
  Otherwise `ApolloDeviceFillWindowToActiveCanvas` snaps it back
  (`[DeviceDisplay] Fitting window 669x440 to assigned scene 669x951`).
- UIKit computes the root controller's content overlay insets as if the window
  began at the scene origin. That kept the full display's 82pt top status inset
  as an empty band above the nav bar. Sim-only hooks on
  `-_setContentOverlayInsets:` and its `andLeftMargin:rightMargin:` variant
  clamp the root to the window's own safe area. On a device the pane is its own
  scene and has no such band.
- SimDebugTap tap coordinates are window coordinates. In the pane, subtract
  the window's y origin (for example, at 440 the y origin is 511).
- Reddit often rate-limits the sim (HTTP 429, "Couldn't load posts"). Wait a
  minute or two and open the feed again, at full size, before `shortpane`.

## Measured in the simulator (inner display 669x951pt, portrait)

| shortpane | window frame | root safe area | bottom tab bar | feed table safe area |
|---|---|---|---|---|
| 440 | {0,511,669,440} | {0,0,34,0} | y 375, h 65 | {68,0,65,0} |
| 468 | {0,483,669,468} | {0,0,34,0} | y 403, h 65 | {68,0,65,0} |
| 565 | {0,386,669,565} | {0,0,34,0} | y 482, h 83 | {68,0,83,0} |

In all three: mode=0 (Phone), unfolded=0, shortPane=1, sideBar=0,
`ApolloDuoUsesCoverContentInsets()`=1, size classes regular width / compact
height. The bottom tab bar is native. No trailing rail is visible.

## Trailing clip (fixed)

Symptom: the feed's media stopped 84pt short of the pane's trailing edge, at
585/669 ≈ 0.875 of the width, while the nav bar spanned the full width.

Cause: the full-to-pane resize calls `ApolloDuoRailFeedContentWidth`, which
returned `ApolloDuoSplitTransitionContentWidth(table, 72 + 12)`. A 669x440
target is landscape-shaped, so that helper assumed a trailing rail and
subtracted 84pt (`[DuoMeasure] desired=585.0 measured=585.0 resize=1`). The
table's bounds width never changes (669 before and after), so Texture never
measures again and the 585pt nodes stayed in 669pt cells.

Fix: `src/ApolloDuoRailCore.m` passes a rail inset of 0 when
`ApolloDuoSplitIsShortPane()`. After the fix: `desired=669.0 measured=669.0`,
and node width matches cell width.

## Checks

1. Full-screen portrait feed: images span the full width; `duogeom` reports feedWidth=0.
2. `shortpane 440`, `468` and `565`: no black band at the trailing edge, cell width = node width.
   The Feed Layout control is present. Original and Focused both fit the pane.
3. `shortpane off`: back to full-screen portrait with no leftover insets.
4. Landscape (real trailing rail) and the cover display: unchanged rail
   reservations (the inset is still 84pt when the window is not a short pane).
