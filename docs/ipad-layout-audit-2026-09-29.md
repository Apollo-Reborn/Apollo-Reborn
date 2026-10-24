# iPad integration and layout audit — 2026-09-29

## Branch selection and integration

Worktree: `/Users/jordan/Developer/Apollo-Reborn-ipad`

Branch: `codex/ipad-layout-audit`

The linked pull requests form a cumulative stack, not competing implementations:

| PR | Contribution | Head |
| --- | --- | --- |
| [1054](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1054) | Opt-in containers and detail routing | `5017991` |
| [1055](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1055) | Navigation ownership and compact transitions | `70cc449` |
| [1056](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1056) | Selection, lazy loading, tab coordination | `b50a41b` |
| [1057](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1057) | Chrome, search, readable width, resize scheduling | `0edbff3` |
| [1058](https://github.com/Apollo-Reborn/Apollo-Reborn/pull/1058) | Simulator probes, tests, engineering records | `81f4946` |

Git ancestry confirms all four preceding heads are ancestors of #1058. This worktree branches directly from #1058 and merges main `448f4c5a3c19ff9d7229aa65409c38f27a92727e` in merge commit `9294a15`. An existing older rebased worktree, `Apollo-Reborn-ipad-test`, was inspected and left unchanged.

Integration keeps the pane stack's per-controller search state while adapting main's newer search cancellation, reappearance, comments-search and drag-release handling. It also combines scene-aware cold routes with backup-document opening, retains main's navigation-transition fixes alongside pane reduced-motion/RTL handling, preserves isolated simulator command channels, and updates the subreddit placeholder helper call to its current signature.

## Duo work worth reusing

Reviewed [apollo/duo-compatibility](https://github.com/IllIIllIllIllII/Apollo-Reborn/tree/07132af1c9823eb63d3e7064753b3f8f487ed354), through `07132af`. These are source-review recommendations; they are not claims of iPad runtime validation or wholesale adoption.

1. **Settings footer geometry and scroll stability.** `src/settings/ApolloSettingsForm.m` measures a footer using its own view width, includes safe-area/margin geometry in its cache key, schedules remeasurement after geometry changes, and preserves the reader's scroll offset through updates. This is directly relevant to iPad because `ApolloPaneColumnHostViewController` changes additional safe-area insets to cap readable content at 680pt (760pt for accessibility text), even when the table's bounds stay the same. Port the focused form changes with rotation, divider and large-text verification.
2. **Stop modal scroll ownership at the first controller.** [Commit c713be7](https://github.com/IllIIllIllIllII/Apollo-Reborn/commit/c713be7d33d163a99800bf0c924b1c84381a8ded) changes `ApolloActionsUpdateScrollOwner` and `ApolloResolveTabBarControllerForScrollView` to follow controller containment rather than continuing through a modal's responder chain into its presenter. The same old traversal remains in the merged iPad branch. This is a small candidate for shared upstream code, especially for subreddit/account sheets and popovers.
3. **Avoid a zero-width constraint before title content has measured.** Duo's `ApolloLiquidGlass.xm` checks the natural title width before fitting it. A newly adopted JumpBar can otherwise keep its temporary zero width through subsequent layout. Check applicability against pane unified chrome before porting: this stack deliberately suppresses some ordinary title glass. The related early fitting of owned text titles in [commit 07132af](https://github.com/IllIIllIllIllII/Apollo-Reborn/commit/07132af1c9823eb63d3e7064753b3f8f487ed354) already has equivalent executable logic in current main and the merged branch; it does not need another port.
4. **Use the assigned scene's canvas.** `ApolloDeviceDisplay.m` uses the scene's coordinate space (effective geometry on iOS 26+) and explicitly avoids enlarging multitasking windows to the physical screen. `ApolloDeviceGeometry.m` prefers the anchor's scene and centralizes geometry. This is a useful shared design for Stage Manager/external-display work; explicit originating-scene routing in this iPad stack should remain authoritative.

Do not wholesale import Duo's split controller, rail, device identity remapping or hinge rules. They bring a second navigation/container owner and phone-specific assumptions. The reusable opportunities above are separable from those features. In particular, margin-based chrome insets need iPad-specific review because readable margins are not necessarily occluded screen regions.

## Validation

- Simulator build with internal Logos generator: passed.
- Simulator dylib UUID: `69D80F5E-E863-4AF4-A1E8-5520A1FD2855` (arm64).
- Base IPA SHA-256: `549a843a546298a3db5f1673606c7720bdc0d0bd32e86bc8ca925f7869544d01`.
- Pane geometry policy: 146,781 width/capacity combinations and RTL cases passed.
- Pane settlement lifecycle: readiness, replacement, deadline, cancellation and deallocation passed.
- Device package build (`make package -j8`, iOS 26.0 SDK, iOS 14 floor): passed; local package `packages/com.apollo.reborn_3.8.5-1+debug_iphoneos-arm.deb`.
- Runtime matrix: five profiles, with measured portrait and landscape app geometry as recorded below.

Only iOS 27.0 simulator runtime is installed on this machine. Simulator observations do not validate physical-device performance, hardware input, APNs, FFmpeg remux, or older iPadOS versions. Narrow-window/forced-trait probes must be identified separately from actual system window resizing.

The default iPadOS 27 windowed-app environment rejects the debug bridge's programmatic orientation request. Device Hub exposes no scriptable windows/menus here, and installed idb HID cannot load SimulatorKit at its old Xcode path. A separate **simulator-only shell requesting fullscreen** (`UIRequiresFullScreen=YES`, re-signed locally) permits landscape scene geometry. Inspection shows iPadOS 27 presents that landscape-shaped app window within a still-portrait device display: these are valid landscape app-layout observations, **not physical-device orientation coverage or a true fullscreen display rotation**. Captures labelled `fullscreen` refer to the metadata override; initial windowed portrait captures retain the original shell. No production plist changed. Restored local data supports live feeds/comments but initially leaves Account signed out; authenticated profile/inbox coverage must not be inferred from a working feed.

## Reproduced findings

### P1 — Mini portrait initially strands Posts on an empty detail

On iPad mini A17 Pro at 744×1133pt, with multi-column enabled, launch Posts and dismiss What's New. The primary list has a 0×0 frame; UIKit resolves secondary-only without marking the split collapsed. The empty detail says to select a post, but Show List is disabled and a measured tap does nothing. Later transition diagnostics report `blocked=0 active=0 pending=0`, so an active animation does not adequately explain the idle state. Settings/Search can reveal their primary as overlays; this is not evidence that every tab is permanently inaccessible.

Evidence: `.sim/ipad-validation/evidence/mini-portrait-home/` and `mini-portrait-show-list/` (screenshots, accessibility and pane snapshots). Investigate `apollo_refreshShowPrimaryItem` and its completion/appearance refreshes in `src/ipad/ApolloPaneSplitViewController.m`; the item stores an enabled state derived from transition state, but a later idle predicate alone does not re-enable it.

### P2 — Primary title overlaps the pane-layout button

On iPad Air 11 at 820×1180pt, Home loads live posts, but the Home title capsule is partly covered by the pane-layout button. It persists with comments open in the adjacent detail pane. The title and actual action controls need one shared fitting policy at narrow primary widths.

Evidence: `.sim/ipad-validation/evidence/air11-portrait-home/` and `air11-portrait-comments/`. Relevant integration surfaces are `ApolloPaneChrome.m`, `ApolloLiquidGlass.xm` and main's newer `ApolloNavigationTitlePresentation.xm`.

### P2 — Duplicate Find controls in comments

The same Air 11 comments view has two magnifying-glass controls in its detail navigation bar. `ApolloPaneChrome.m` installs an explicit `ApolloPaneFindComments` item while current main also supplies the comments `UISearchController`, which pane policy places as an integrated button. These need a single owner, including the corresponding keyboard Find path and classic/non-glass behavior.

Evidence: `.sim/ipad-validation/evidence/air11-portrait-comments/`. Live posts and comments loaded successfully; this is a UI integration defect rather than a credentials/network failure.

### P2 — Settings mixes different text-scaling policies

With the largest system accessibility text size on Pro 13, injected Settings rows grow and wrap without clipping while native rows and tweak form text remain much smaller. The pane hook's `ApolloRootSettingsPreparePaneText` uses `UIFont preferredFontForTextStyle:` directly; tweak forms intentionally use `ApolloSettingsFont` to follow Apollo's own Appearance preference. The visual mismatch is reproduced, but it is not evidence that Apollo's existing native screens promised system Dynamic Type support. Align the pane additions with an explicit app-wide accessibility/text-size policy.

Evidence: `.sim/ipad-validation/evidence/pro13-portrait-largest-text/`.

## Runtime matrix and successful checks

| Simulator profile | Portrait app bounds (pt) | Landscape app bounds (pt) | Representative coverage |
| --- | --- | --- | --- |
| iPad mini A17 Pro | 744×1133 | 1133×744 | Cold launch, Show List, Settings, Search, image thread retained on return to portrait |
| iPad Air 11 M3 | 820×1180 | 1180×820 | Live feed/comments, Search, signed-out Account, Settings → Apollo Reborn, orientation roundtrip |
| iPad Pro 11 M4 | 834×1210 | 1210×834 | Alternate 11-inch aspect ratio, live feed and comments |
| iPad Pro 13 M4 | 1032×1376 | 1376×1032 | Live feed/comments/media, Settings, dark mode, largest system text, width and compact-navigation probes |
| iPad 9th generation (10.2-inch) | 810×1080 | 1080×810 | Older 4:3/home-button profile, live image-post/comments and Settings |

The 10.5-inch Pro profile was rejected by the installed iOS 27 runtime; the supported 10.2-inch iPad provides the older 4:3 coverage. All examined snapshots confirm one loaded tweak copy and five installed panes. Captures with failed orientation requests (`mini-landscape-home`, the initial `pro13-fullscreen-landscape-home` and `pro13-fullscreen-landscape-comments`) still have portrait bounds and are **excluded** from landscape coverage. The Pro 13 and mini `fullscreen-landscape-settled` captures establish their landscape measurements.

Successful targeted checks:

- Live feeds and comment threads load; both text and image posts render in detail.
- Air 11 keeps Settings → Apollo Reborn selected across landscape → portrait; observed form footers wrap without clipping.
- Mini keeps an open image thread through landscape → portrait. Show List works after this roundtrip; the cold-start failure above remains independently reproduced.
- Pro 13 handles 340/480pt width requests and forced compact → accessibility Back → expanded. Primary depth remains two, detail clears as expected, and snapshots show no queued navigation or active settlement watchdogs. Forced compact traits are a navigation probe, not a real Stage Manager resize.
- Dark theme renders readable comments/media. Largest system text produces the inconsistency described above, without clipping the injected multiline Settings rows.
- The pane menu's Comfortable choice came from restored preferences. Selecting Compact produces thumbnail/list rows; large feed images in earlier captures are not evidence of a broken density toggle.
- A detail-anchored share-sheet presenter probe displays its popover inside the detail column on Pro 13. This validates the probe's presentation/anchor, not every native sharing route or share destination; nothing was sent.
- A Pro 11 control run with panes disabled renders the native full-width feed. Its snapshot records one tweak copy and zero panes.

Authenticated profile/inbox, composing/replying, physical rotation, actual continuous window resize, multiple simultaneous app scenes, external display, hardware keyboard/pointer, VoiceOver and physical-device performance remain unverified. The audit does not certify that every Apollo feature works. Modal-scroll isolation and footer-cache improvements from Duo remain reviewed borrowing candidates, not runtime-proven fixes applied here.

Raw screenshots, view/accessibility hierarchies, snapshots, and the local verification notes are retained under `.sim/ipad-validation/`: 51 complete evidence bundles, including the explicitly excluded early rotation attempts. The device-interaction workflow required checking the rendered screen and hierarchy after interaction; filenames alone were not accepted as proof of state or orientation. Existing Search/Siri simulators and the older iPad worktree were left unchanged.

One additional follow-up is deliberately unconfirmed: `pro11-deeplink-ipad` shows possible subreddit-header/title clipping beneath the sidebar after URL routing. It was not recaptured after the transition settled, so it is not counted among the four reproduced findings.
