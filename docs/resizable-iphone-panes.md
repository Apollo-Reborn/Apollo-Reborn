# Resizable iPhone panes (experimental)

Settings → Apollo Reborn → Interface → **Multi-Column Layout (Experimental)**.
The setting defaults to OFF and applies after quitting and reopening Apollo.
It is available on iPadOS 18+ and iOS 27 phones. Turning it off restores Apollo's
ordinary navigation hierarchy on the next launch.

With the setting on, UIKit adapts the same split controllers using the inherited
size classes and actual available space. Narrow windows collapse to one browsing
path; expanded windows show the list and detail side by side. No phone model,
fold posture, orientation, screen dimensions, or idiom spoofing chooses columns.
The device/OS check is only a capability gate for installing the experiment.
The phone simulator override has been removed; tests use the persisted setting.

## Prepare and run

Apollo is a closed-source legacy executable. Compiling the injected tweak with a
new SDK does not change the main app's linked SDK. iOS 27's resizing opt-in must
also be present on that main executable. The following explicit options patch
its linked-SDK declaration to at least 27.0, preserve its deployment target and
platform, retain its existing scene/launch-screen configuration, declare all four
orientations and indirect input, and remove full-screen requirements. This is a
compatibility patch, not a recompilation of Apollo or a hardware-support guarantee.
The options include the existing Liquid Glass preparation; normal release variants
keep their current behavior.

```sh
WORK_DIR=./.sim/pane-redesign SIM_NAME=Resizable-iPhone \
    scripts/run-in-sim.sh --resizable
# Then enable Multi-Column Layout in Interface and quit/reopen Apollo.
# Enter resize mode using Device Hub's toolbar.

./patch.sh ./Apollo-base.ipa --resizable --fix-safari-extension \
    -o /tmp/Apollo-resizable-base.ipa
# Inject the freshly built tweak using build-ipa.sh before signing/sideloading.
```

Run `--resizable` on subsequent simulator invocations too. Omitting it prepares
an ordinary shell again. Do not hold a `devicectl appResize start` session while
trying to enter resize mode from Device Hub: the external session owns that mode.
Wait for Apollo to finish launching before starting resize mode.

## Verification

- The iPad review stack through #1058 has exactly the same Git tree as #886 at
  `b6305b4559c16aa59dbe90506fccef17aadada14`. #1053 is simulator tooling;
  #1054–#1057 are runtime slices; #1058 contains probes, tests, and audit records.
- Each runtime slice compiles and links for the simulator. The final pure geometry
  policy and transition-observer lifecycle tests pass.
- On an iOS 27 iPhone 17 Pro simulator (phone idiom throughout), setting OFF
  installed zero panes; setting ON installed five; narrow launch collapsed.
- Actual resize-session transitions through 402×874, 820×900, 600×800, 1161×680,
  402×874, and 1161×680 collapsed/expanded the selected Settings pane correctly.
  The list/detail stack depths returned to 1/1 on expansion and 2/1 on collapse,
  preserving the open detail. Every settled sample had zero pending navigation
  and zero transition watchdogs. Screenshots confirmed adjacent panes at 1161×680.
- App-shell tests verify platform/deployment-target/code preservation, repeatable
  patching, no SDK downgrades, and rejection of malformed binaries before writes.

These are simulator navigation/resize checks, not frame-rate measurements or
foldable hardware validation. Signed-in feed/media behavior, real-device iPhone
Mirroring, and actual foldable hardware still need validation. Existing iPad
release gates are recorded in `plans/003-ipad-pane-implementation-results.md`.

Apple documents resizable iPhone apps that retain their phone idiom and recommends
size classes and surrounding view dimensions for layout:
[Modernize your UIKit app (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/278/).
