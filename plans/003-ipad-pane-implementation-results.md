# iPad pane redesign — implementation and verification

Date: 7 September 2026. Branch: `je/ipad-pane-layout`, starting at `fa5ddcb`.
Scope: all fourteen work packages in [Plan 002](002-ipad-pane-redesign.md),
covering all seventeen [audit findings](ipad-pane-audit-2026-09-07.md) and the
revised outcomes of [Plan 001](001-unify-ipad-pane-chrome.md).

The implementation is in the working tree. This is an experimental build, not a
claim that the release matrix or physical-device performance gates have passed.
No improve skill was used for this implementation.

## What changed

The destination surface stays UIKit's native tab/sidebar controller with Apollo's
five original tab identities. Each tab has two content columns: a compact native
selection list and a separate native reading/navigation stack. UIKit collapses
those columns for narrow windows. The production eligibility remains opt-in on
iPadOS 18 and later; the device tweak still builds with an iOS 14 deployment floor.

Passive titles no longer acquire custom glass capsules in expanded panes. Search
uses the native navigation item, with a discoverable button when inactive. Thread
Find uses one `UIFindInteraction`/`UIFindSession` adapter over Apollo's existing
matcher, count, highlights and previous/next actions; its old extra toolbar is
suppressed. The system may dock Find by the keyboard. This intentionally replaces
Plan 001's fixed-height search takeover proposal.

The detail host follows the actual tab content guide and context-row geometry.
Comments media starts below that context row; immersive profile/community artwork
is covered above its resolved content boundary. Settings insets are additive.
Text comments/header nodes use a readable width while media keeps its full
aspect-correct layout. Apollo/Texture remains responsible for content measurement
and scroll anchoring; the implementation does not reload entire tables per drag.

## Work-package accounting

“Implemented” below describes source delivered, not every exit test in Plan 002.

| Work | Implementation | Verification and limits |
|---|---|---|
| W01 | Structured privacy-safe snapshots, capture script with IPA hash/dylib UUID/runtime and one-copy check; opt-in signposts and counters | Simulator artifacts captured. Selection interval ends at the next display-link callback, not a measured render-server presentation. Physical baseline remains open. |
| W02 | Required runtime-contract preflight; weak scene/nav/item registrations; public scene notifications including hidden tabs; scoped native entry translation; exact typed AppDelegate tab save/restore; gallery/recovered-link origin preserved | Native subreddit URL routing and second-window post delivery passed. Forced required-capability failure left stock containment with zero panes. Full scene/rollback matrix is tracked below. |
| W03 | Shared bounded weak-owner settlement observer; cancellable generation-based geometry scheduling; lifecycle cancellation; native semantic PostsType identity; existing latest-intent/source validation retained | Host tests cover replacement, missing completion/deadline, cancellation and owner deallocation. Latest queued selection won the simulator gate test. |
| W04 | Pure finite width policy; separate preferred/resolved widths; RTL edge and drag sign; cancellation restores saved intent; secondary minimum on iOS 26; visible-only display-paced divider | 146,781 geometry combinations plus RTL cases passed. Live divider produced zero layout passes/writes in all four hidden tabs. Actual continuous window resize remains separate from trait probes. |
| W05 | Dedicated chrome policy; native search placement; plain passive titles; bounded artwork; stable expanded hide-on-scroll; first-wide sidebar preference | Home/comments and compact screenshots inspected. Native tab content guide fixed top-tab overlap. Full OS/theme/accessibility matrix remains open. |
| W06 | Per-comments-controller query/node/range/generation and cancellation; one system Find adapter; synchronous matcher context restored in `@finally` | Real typed Find query showed highlights and “2 of 3”; next/previous/dismiss exercised. IME, hardware keyboard and independent two-scene Find require further coverage. |
| W07 | Pane-local native compact node factory; persisted Compact/Comfortable choice without changing phone's global style; restrained selected background; contextual empty states | Compact native feed/media thread inspected at multiple primary widths. Native NSFW, filtering and action implementations retained; exhaustive content matrix remains open. |
| W08 | Progress-driven native interactive root return, reversible cancellation; nested detail retains Apollo pop; exclusive root/divider recognizer ownership; RTL and Reduce Motion animator paths | Root commit/cancellation tested. Compact nested Back commit and cancellation both verified interactive; two queued selections settled to the newest detail root with no pending gate. |
| W09 | Extracted column host; additive Settings readable insets; background-safe captured prose constraints and colors; media excluded from text cap | Media remains below chrome and full width. Long code/inline-image/selection/async anchor scenarios need device/content coverage. |
| W10 | Weak focused column, single `scrollsToTop` target; Cmd-F and Cmd-Option-1/2 focus; Ctrl-Option width controls; accessibility escape, adjustable divider/reset, dynamic selection contrast; scene-scoped presentation paths; multiline self-sizing injected Settings rows | Touch/system Find exercised. Largest accessibility text at 340pt exposed and verified the Settings-row fix. Native Apollo rows still have inconsistent Dynamic Type support; complete accessibility/peripheral acceptance remains open. |
| W11 | Weak navigation-item lookup; selected-tab minimize predicate; cached chrome actions; no hidden-tab drag broadcast; on-demand display links; cancellation on background/disconnect and conservative memory handling | Hidden tabs stayed idle during drag. A fresh 11.29-second idle comparison had unchanged layout/write/loaded counts, zero watchdogs and zero pending navigation. Device hitch/allocations/50-cycle and ten-minute soak gates remain open. |
| W12 | Updated plan status, current architecture notes, evidence and release limitations | Documentation is reconciled. This package's release certification remains open until the required matrix is actually run. |
| W13 | Public sidebar footer with bounded pinned communities, URL drag/drop, scene-local opening and explicit Open in New Window; all five tab indices retained | New-window integration created a second five-pane scene and opened the requested post, preserving the original scene's detail. Real RedditList remains the editor for multireddits/full organization. Drag/drop and indirect-input coverage remain open. |
| W14 | Simulator-only real-phone eligibility flag, local bounds/effective traits, retained phone idiom and native phone tabs; actual IPA metadata inspected | Cold narrow phone launch found and fixed a UIKit wrapper routing loop. Responsive launch with five panes and zero settled watchdogs verified. No shipping foldable support claim. |

## Audit finding disposition

| Finding | Source resolution |
|---|---|
| A01 | `ApolloPaneChrome`, native navigation search and controller-owned system Find |
| A02 | Native compact feed-node creation within the primary pane; explicit comfortable option |
| A03 | Geometry policy, usable width excluding visible sidebar, secondary minimum |
| A04 | Native percent-driven root Back and restored nested detail recognizers |
| A05 | Generation/idempotence-aware `ApolloPaneGeometryScheduler` |
| A06 | Bounded `ApolloPaneTransitionObserver` and scene lifecycle cancellation |
| A07 | Shared physical-leading policy for LTR/RTL geometry and controls |
| A08 | Preferred width saved independently of resolved width and restored on cancellation |
| A09 | Display-paced updates on the visible pane; hidden panes consume preference on appearance |
| A10 | Per-controller Find state and scoped synchronous matcher context |
| A11 | Originating scene API and typed native AppDelegate tab exchange in `@try/@finally` |
| A12 | Bootstrap capability contract required before atomic installation |
| A13 | Host, geometry, observer, chrome, content, focus, sidebar and diagnostics extracted; logical navigation state remains with the owning split |
| A14 | Native PostsType semantic identity rather than display titles |
| A15 | Additive Settings contribution plus captured Texture text constraints; media stays wide |
| A16 | Weak ownership lookup, cached chrome/menu work and selected-tab scroll policy |
| A17 | Input ownership implemented and explicit validation gates retained; device smoothness remains unproven |

## Important integration fixes found while implementing

1. Apollo's AppDelegate tab ivar has a Swift type encoding, despite holding a
   strong Optional UIKit object. An Objective-C `@`-encoding check rejected real
   routes. The typed Swift bridge now exchanges/restores the exact value after
   validating the known class/neighbor layout.
2. UIKit's compact merge can push a navigation wrapper containing the exact
   secondary host. Routing that structural transfer as a Settings destination
   caused a cold-narrow launch loop. Exact host containment now bypasses the
   application queue and is excluded from logical primary stack counts.
3. Re-enabling Apollo's recognizer during an active root return allowed two pop
   drivers to compete. Root tracking now owns its recognizer states until its
   interactive transition commits or cancels.
4. iOS 26+ floating tabs do not make the legacy `tabBar.hidden` property a reliable
   content-boundary test. The host uses the public `contentLayoutGuide`.
5. Comments' extended top edge let video paint behind context chrome. Expanded
   comments now suppress that edge and restore the original policy when compact.
6. A new compact primary selection used to push above UIKit's bridge while the
   old detail branch remained alive. The same root-replacement policy now applies
   in compact and expanded presentations. Synthetic nested Back races verify
   cancellation and commit both retain the newest selection in the detail stack.
7. Apollo did not consume a pane link from cold scene connection options, and
   optional scene-delegate activation hooks were insufficient. A URL-only activity
   is claimed once on UIKit's public scene activation notification. The same
   lifecycle registration cancels work on hidden tabs without loading views.
8. Injected root Settings rows clipped large Dynamic Type labels inside fixed
   52-point heights. The existing root Settings owner now uses multiline native
   self-sizing rows at accessibility categories, with normal/pane-off sizing
   preserved. No second General-screen remapper was introduced.

## Delivered build

- Test IPA: `packages/Apollo-Pane-Redesign-Test.ipa` (local, unsigned for distribution).
- Device package: `packages/com.apollo.reborn_3.6.0-18+debug_iphoneos-arm.deb`.
- IPA SHA-256: `d5a76c198e1c7c3017ccb9ac15f97627d8b09fa10a4a73afd2eb3e6742a2dc53`.
- Final simulator dylib UUID: `1D5BD226-DCA7-4909-8F2D-F39E282D694C`.
- Device/simulator builds and `git diff --check` pass; host geometry/settlement tests pass.
- IPA ZIP integrity passes; exactly one tweak entry is present under the base
  app's existing `ApolloImprovedCustomApi.dylib` name. The injector updates that
  alias rather than adding a second tweak load.
- Device packaging includes the Liquid Glass patch and both Safari extensions.

The phone-off control required rebooting this iOS 27 simulator to clear a retained
development launch environment. Captures named `phone-probe-still-enabled`,
`stock-phone-explicit-off`, and `stock-phone-direct-launch` are failed control
attempts, not pane-off evidence. The `stock-phone-rebooted` snapshot verifies
phone idiom, one loaded tweak, and zero pane containers.

## Reproduction and evidence

Run `scripts/test-ipad-pane-policy.sh` for the actual pure geometry policy and
Foundation settlement observer. Run `make package` for the pinned device target.
Simulator builds use the documented latest-SDK/internal-Logos path, with exactly
one baked tweak copy; do not also set `DYLD_INSERT_LIBRARIES`.

```sh
SIM_NAME=PR886-iPad13 WORK_DIR=./.sim/pane-redesign scripts/run-in-sim.sh --glass
python3 scripts/capture-ipad-pane-state.py \
  --device A078A116-02A9-4EB1-B381-5FF2F29510C2 --label final

SIM_NAME=Pane-Adaptive-Phone \
  SIM_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  WORK_DIR=./.sim/pane-phone SIMCTL_CHILD_APOLLO_SIM_ADAPTIVE_PHONE=1 \
  scripts/run-in-sim.sh --glass
```

Ignored local evidence includes:

- `.sim/pane-redesign/evidence/20260907-124715-wide-media/`
- `.sim/pane-redesign/evidence/20260907-124804-width-340/`
- `.sim/pane-phone/evidence/20260907-130306-cold-narrow-fixed/`
- `.sim/pane-redesign/evidence/20260907-131557-receiving-scene-verified/`
- `.sim/pane-redesign/evidence/20260907-132211-compact-race-settled/`
- `.sim/pane-redesign/compact-races.log` (verified native interaction and final stack)
- `.sim/pane-redesign/idle-check.json` (fresh snapshots, no debugger attached during interval)
- `.sim/pane-redesign/evidence/20260907-132657-settings-ax-fixed/`
- `.sim/pane-redesign/evidence/20260907-133944-final-review/`
- `.sim/pane-redesign/evidence/20260907-134620-final-clean/`
- `.sim/pane-phone/evidence/20260907-133143-required-capability-failure/`
- `.sim/pane-phone/evidence/20260907-133958-stock-phone-rebooted/`
- `/tmp/apollo-pane-find-real.png` (typed system Find, native highlights/count)
- `/tmp/apollo-pane-media-bounded.png` (media/context boundary)
- `/tmp/apollo-pane-phone-sample.txt` (pre-fix cold-launch loop diagnosis)

Snapshots intentionally omit account identifiers, model descriptions, titles,
URLs, and Find queries. Screenshots can contain ordinary visible Reddit content;
review them before sharing. Existing simulator account data was preserved; no
credential backup was exported or checked in.

The test devices were shut down, normal text/contrast/dark appearance and the
original 480pt width preference were restored, and the prior debug command was
restored. The iPad simulator retained three inactive test window sessions after
destruction requests; its original session was preserved. These are simulator
data-container state, not contents of the packaged IPA.
The last navigation-bar screenshot tap triggered Apollo's native theme shortcut;
`final-clean` therefore shows light mode. The native `Theme` preference was
restored to `dark` with the simulator stopped, preserving other preferences.
Use `final-review` for the verified dark presentation.

## Release gates remain explicit

The existing PR #886 A–G gates are not closed by this implementation. In particular:

- Physical 60/120 Hz Time Profiler/Animation Hitches/Allocations runs and soak.
- Supported iPadOS 18/26, mini/11/13-inch, pane-off and non-glass combinations.
- Actual continuous window resizing/external display; a forced compact trait is
  only a topology probe. `simctl screenConfig geometry` rejected the requested
  custom geometry on this runtime, so that attempt is not resize evidence.
- Complete accessibility, keyboard, pointer, IME and media/PiP/presentation matrix.
- Multi-scene lifecycle, restoration and fault-injection combinations.

Do not promote the experiment or claim “buttery smooth” until those results are
recorded. Foldable preparation shares the pane core while keeping the phone idiom;
Apple has not supplied a foldable device contract to certify against.
