# iPad pane audit — 7 September 2026

Source baseline: `fa5ddcb`, branch `je/ipad-pane-layout`.
Implementation roadmap: [Plan 002](002-ipad-pane-redesign.md).

## Assessment

The branch is a credible compatibility foundation, but it is not yet a complete
iPad product redesign. It preserves much of Apollo's behavior successfully while
putting phone-oriented content and independently managed chrome next to each
other. Correct containment and aligned bar origins are necessary; they do not
establish good density, a clear hierarchy, natural gestures, or smooth resizing.

Keep the real Apollo navigation controllers, the single UIKit destination
surface, per-tab browsing state, conservative routing, and semantic selection.
Invest in a pane-specific presentation policy and a smaller, explicit navigation
state model. Replacing Apollo's rendering stack wholesale would discard useful
behavior before the actual bottlenecks have been measured.

## Evidence and limits

This audit examined both supplied plans, the PR #886 verification tracker, all
pane modules' responsibilities and principal navigation/layout paths, and their
interactions with Liquid Glass, immersive subreddit headers, comments find,
tab minimization, shared URL routing, and the Swift ivar bridge. Apple API
behavior was checked against current documentation and the pinned iOS 26 headers.
No production source was changed, and no new build or device performance run was
performed for this documentation task.

Evidence labels below:

- **Code:** an implementation behavior or missing contract visible in this
  revision. A described failure path is not automatically a reproduced user bug.
- **Visual:** observed in local screenshots, with their provenance stated.
- **Risk:** a plausible integration/performance problem requiring a focused test.
- **Gap:** coverage or product behavior the existing work does not establish.

Historical images inspected: `.sim/pr886-merged-13-landscape.png`,
`.sim/pr886-merged-13-portrait.png`, and `.sim/pr886-merged-mini-settings.png`.
Their filenames are not proof of orientation, point dimensions, or build revision.
They show stacked search/navigation surfaces, passive title capsules, tall feed
media repeated in detail, a strong full-card selection outline, and large empty
detail regions. These are useful design evidence, not current-HEAD geometry tests.

A limited live check also launched the **previously installed baked build** on
`PR886-iPad13`, iOS 27 Simulator. Logs confirmed panes installed on all five tabs.
Its initial pane bounds were 1032×1376 points. The captured Home hierarchy had a
108-point primary navigation bar containing search and a 54-point empty-detail
bar, both beginning at y=86. That shows why the old plan's universal equal-height
54-point assertion needs a new baseline; it does not prove a regression in HEAD.
The baked dylib's source revision was not verified.

Local evidence is under `.sim/ipad-audit-2026-09-07/`: `evidence.json`,
`baked-build-home.png`, and `baked-build-geometry.txt`. An initial launch wrongly
added environment injection to an already baked app; its failure was excluded as
a harness error. Normal launch succeeded. The resulting local crash prompt was
dismissed with Not Now; no report was sent or deleted. The debug command file was
restored and the previously shut-down iPad simulator was shut down again. No
content gestures or account mutations were used. Screenshots remain ignored.

The tracker explicitly leaves presentation, accessibility, multiwindow/device
coverage, and the performance soak open at
`IPAD_PANE_PR_886_IMPLEMENTATION.md:567`. Its earlier microbenchmarks and discrete
resize checks are not measurements of live-drag hitches or sustained device load.

## What is already strong

- `ApolloPaneRouting.m` shares cold/warm classification, uses explicit destination
  classes, and preserves rightward continuation. Settings/Profile index policy
  is an intentional source-based exception to the destination allowlist.
- `ApolloPaneInstall.xm:165` stages controller changes with identity checks,
  rollback snapshots, and simulator fault injection.
- `ApolloPaneLayout.m:11` distinguishes requested/enabled/active state and uses
  weak navigation-owner registration for temporarily detached tab hierarchies.
- `ApolloPaneSplitViewController.m:3154` coalesces cross-column intents and checks
  source lineage before replay. Primary selection uses stable model identifiers
  where available, not only an index path.
- The detail host constrains Apollo's real navigation controller to usable
  column bounds. Production `viewDidLayoutSubviews` no longer drives geometry.
- View loading is deferred for unvisited pane tabs; width preferences are stored
  per scene; the divider is a real accessible control.
- Forward-history writes use a small typed Swift bridge, with more defensive
  class/layout checks than a raw Objective-C object cast.

These are regression requirements for the redesign, not tasks to implement again.

## Findings

### A01 — P1 — Chrome has no common presentation owner

**Code + Visual.** `ApolloPaneInstall.xm:400` selects tab-sidebar mode;
`ApolloLiquidGlass.xm:1142` independently recenters title controls and builds
capsules for plain labels; `ApolloSubredditHeaders.xm:1711` derives artwork extent
from the complete adjusted top inset; comments search has its own toolbar/session.
There is still no `ApolloPaneChrome` module.

The result can be individually valid components with equal visual emphasis:
global destinations, context titles, search, actions, and artwork. The old chrome
plan correctly identifies the problem, but needs to cover primary search as well
as comments find and must account for the latest merged search implementation.

**Outcome:** one scene destination policy and one per-pane chrome policy, with
plain context labels, discoverable interactive controls, explicit search scope,
and a consistent theme/material boundary above content.

### A02 — P1 — Content density still treats the feed as a phone canvas

**Visual + Gap.** Inspected images show a tall image consuming most of the master
column while detail repeats the same image. Persistent native selection can draw
a bright outline around that entire tall cell. The list is supposed to support
rapid comparison and selection, but it offers very little scannable content.
The current router and host reuse the existing cells without a pane density policy.

**Outcome:** evaluate Apollo's existing compact feed rendering for a pane-local
list presentation: bounded thumbnails, readable titles, small metadata, subdued
persistent selection, and a distinct keyboard-focus indicator. Preserve an
explicit user's comfortable/media-rich preference. Do not change the global
phone setting to achieve a local layout. A cell factory/measurement spike is
required before promising this can be isolated safely.

### A03 — P1 — Width policy protects primary more explicitly than detail

**Code + Risk.** `ApolloPaneSplitViewController.m:960` and `:2116` request a
340–480-point primary and a 0.42 fraction, later converted to an absolute scene
preference. There is no comparable useful-detail minimum or content/height-aware
presentation policy. UIKit may resolve a different size from these preferences.
The existing code correctly handles hidden/overlay primary, but does not prove
that both visible columns are usable at every intermediate width.

**Outcome:** solve for two useful content panes before preferring the global
sidebar. Derive the decision from actual available bounds, content requirements,
Dynamic Type, and resolved UIKit presentation. Do not use device-model or
orientation buckets as production policy. iOS 26 provides
`minimumSecondaryColumnWidth`; its availability must be checked for iPadOS 18–25.

### A04 — P1 — Compact Back loses direct manipulation and deeper swipe Back

**Code.** `ApolloPaneSplitViewController.m:3832` disables primary/detail UIKit
interactive-pop recognizers and both Apollo left-edge recognizers while compact
detail chrome is active. Its replacement pan is allowed only at detail depth one
(`:4111`) and acts only when the finger lifts (`:4145`). It does not animate with
gesture progress. At depth greater than one, these disabled Back recognizers
remain disabled and the root-only replacement refuses the gesture. Buttons may
still work; the ordinary swipe navigation is no longer equivalent to Apollo.

**Outcome:** restore native interactive pop within detail. Give the column-root
return one interactive transition owner with real cancellation and final-state
reconciliation. Explicitly arbitrate forward, row swipe, media pan, and divider
gestures. This is important for iPad narrow windows now and fold/unfold later.

### A05 — P1 — Geometry refresh can latch in a waiting state

**Code + failure-path risk.** The host's refresh at
`ApolloPaneSplitViewController.m:727` and the pane's refresh at `:2793` set a
waiting flag and clear it only inside a transition completion. They ignore the
registration result and retain no coordinator generation/identity for recovery.
A completion that does not arrive leaves subsequent coordinator-backed refreshes
skipped. The navigation queue already acknowledges late/rejected registration
at `:3061`, so the policies are inconsistent.

Apple's return value reports whether animations were queued; **a completion can
still run after NO**. Therefore a repair must be idempotent, not run an immediate
second mutation whenever NO is returned. Recover once safe, invalidate obsolete
coordinator callbacks, and never write geometry into an active layout pass.
[API contract](https://developer.apple.com/documentation/uikit/uiviewcontrollertransitioncoordinator/animate(alongsidetransition:completion:)).

### A06 — P1 — Transition polling has no lifecycle-bounded termination

**Code + Risk.** `ApolloPaneRouter.xm:170` polls while a coordinator exists, first
every 50 ms and later every 250 ms. It does not first ask whether its pop token
has already settled. Compact reconciliation at
`ApolloPaneSplitViewController.m:1788`, compact Back at `:4060`, and topology-gate
recovery at `:4219` have additional polling loops. Several capture the pane and
controller stacks strongly. The recursive compact Back block releases its cycle
only on settlement.

These are not proven idle CPU or leak regressions in normal navigation. However,
a stuck native flag/coordinator or disconnected scene can retain state and keep
waking the main queue. Reducing cadence is not a lifetime bound.

**Outcome:** one cancellable observer/watchdog per actual transaction, weak
lifetime ownership, token checks before every reschedule, scene-disconnect
cancellation, and a measured deadline. Expiry must retain the last valid UI and
drop unsafe work rather than force a stack mutation through UIKit's transition.

### A07 — P1 — Divider assumes leading means physical left

**Code.** `apollo_layoutColumnGrabber` (`:2515`) maps a leading primary directly
to its `maxX`, and `apollo_dividerPanChanged:` (`:2638`) maps leading to positive
x translation. In a right-to-left layout, leading is normally physical right.
The adjacency check can hide the divider or place it at the wrong boundary;
drag direction can reverse. Compact Back has a separate direction check, so
there is no shared physical-edge resolution.

**Outcome:** compute physical primary side from effective layout direction plus
`primaryEdge`, and use it consistently for boundary, drag, pointer, and keyboard
semantics. Test inherited and explicitly forced semantic directions.

### A08 — P2 — Cancelled divider drag does not restore the prior preference

**Code.** `:2638` stores the resolved `primaryColumnWidth` as the pan start.
Cancellation republishes that value as the preferred width. If the saved
preference was 480 but UIKit resolved 340 in a constrained window, beginning and
cancelling a drag can leave the scene preference at 340. The persisted value is
unchanged, so live state and next launch can also disagree.

**Outcome:** separately capture the original preference and the resolved drag
origin. Use the latter for smooth motion, and restore the former on cancellation.
Ignore nonfinite input. Commit a preference only for an intentional completed
adjustment.

### A09 — P2 — Every divider sample broadcasts geometry to every tab

**Code + unmeasured cost.** `apollo_publishPreferredPrimaryWidth:persist:`
(`:2615`) iterates all pane children on every changed gesture event. Each changed
preferred width schedules geometry on a loaded pane. Unvisited tabs stay lazy,
which is good; previously visited but hidden tabs can still do work. The host
then refreshes readable width and sibling geometry.

**Outcome:** apply live drag width to the visible pane at most once per display
frame when measurements justify coalescing. Publish the final preference to
siblings at commit, or mark their version dirty and apply before next display.
Do not redraw/reflow hidden tabs simply to keep a scalar preference synchronized.

### A10 — P1 — Comments find state is process-global

**Code.** `ApolloFindInComments.xm:105` has one current VC, match node/range, and
generation. Query edits set the VC; next/previous do not bind their receiver as
the current VC. Any comments controller's `viewDidDisappear:` cancels the global
generation. Two scenes, or returning to an earlier search after searching in
another tab, can cancel the wrong watchdog or pair a match from one controller
with another controller's table. Its synchronous capture/multi-term flags also
lack `@try/@finally` cleanup.

**Outcome:** associated per-comments-controller session state, with receiver-bound
next/previous, local cancellation, and stack-safe synchronous capture scope.
Match-node membership must be verified against that session's table. Keep the
native matcher; fix its ownership before adding another presentation adapter.

### A11 — P1 — Shared native URL routing still pins an arbitrary scene

**Code.** `ApolloCommon.m:626` populates AppDelegate's tab controller from the
first suitable member of unordered `connectedScenes`, only when the ivar is nil.
`ApolloRouteURLThroughApp` has no originating scene argument. Gallery and deleted
comments call it from visible controllers (`ApolloGalleryImageViewer.m:2222`,
`ApolloDeletedCommentsUI.xm:2631`). Opening a link in scene B can consequently
target scene A even though newer custom settings/mailbox routes are scene-aware.

**Outcome:** carry the originating scene through these callers and the native
entry adapter. Any temporary AppDelegate compatibility binding needs an exact
save/restore scope; prefer the scene-native entry path where verified. Do not
retain one global scene as the permanent route destination.

### A12 — P1 — Installer readiness is independent of router readiness

**Code + compatibility risk.** The router ctor at `ApolloPaneRouter.xm:1078`
refuses installation if required classes are missing. The scene installer ctor
at `ApolloPaneInstall.xm:506` independently requires only the scene delegate and
feature gate. There is no shared preflight asserting the routing hooks/bridge
contracts succeeded before tab children are replaced. A missing class can leave
structural panes without the behavior they depend on.

**Outcome:** resolve required capabilities in one bootstrap before containment
mutation. Keep optional chrome features independent. Failure in one scene must
not deactivate a successfully installed sibling scene. A process-level Active
flag may be a fast aggregate, but cannot be the sole owner-specific authorization.

### A13 — P2 — Too many responsibilities and implicit states in one container

**Code.** The split implementation is 4,457 lines, with host geometry, placeholder
UI, selection identity, resize persistence, navigation serialization, compact
stack repair, gestures, theming, and simulator probes. Its private ivar section
at `:969` contains many interdependent flags, stack snapshots, generations, and
lineage tokens. Comments retain contradictory earlier geometry approaches.

Line count itself is not a performance bug. The problem is that ownership and
valid transitions are difficult to inspect, while fixes tend to add another
flag or delayed repair. The existing successful behavior should be captured as
invariants before extraction.

**Outcome:** a scene coordinator, a topology/navigation state owner, a geometry
policy, a chrome owner, and a selection owner with narrow contracts. Extract by
responsibility, not arbitrary source chunks, and do not rebuild controllers merely
to change presentation.

### A14 — P2 — Display text participates in navigation identity

**Code + Risk.** `ApolloPaneSplitViewController.m:102` combines a raw byte at
`currentPostsType + 0x20` with the displayed navigation title. The global
`UINavigationItem.setTitle:` hook (`ApolloPaneRouter.xm:1065`) scans every live
pane/window to find its owner before reconciling. This is event-driven, not a
per-scroll scan, but becomes dangerous to extend as a general chrome mechanism.
Title restyling/localization is coupled to stale-detail invalidation, and two
semantically different destinations with the same displayed name can collide.

**Outcome:** use a semantic feed/account generation from verified source entry
points; use a typed identity where available. Keep presentation text out of the
long-term identity contract. Replace owner discovery with weak direct registration.
Validate all remaining private Swift storage assumptions at bootstrap; the Swift
bridge handles ARC/representation, but cannot prove the passed pointer's type.

### A15 — P2 — Readable width is conservative but not complete

**Code + Risk.** `:576–721` narrows self-post comments and Settings tables using
`additionalSafeAreaInsets`. Media threads keep full-width prose because their
header shares the table. Async header discovery has no dedicated readiness
event; an initially unknown self-post can remain unconstrained until a later
geometry event. Once classified, the controller identity latches the decision.
Restoring saved absolute insets (`:632`) could overwrite another owner's later
left/right changes.

**Outcome:** explicitly own an inset contribution, invalidate classification on
content readiness/change, and test the first frame of async comments as well as
forms. A later per-row readable measure can retain wide media with readable
comment text, but requires a separate Texture measurement spike, not blanket
table narrowing.

### A16 — P2 — Broad chrome work and tab-minimize policy need profiling

**Code + Risk.** The Liquid Glass title gate (`ApolloLiquidGlass.xm:1097–1218`)
folds a capped navigation-bar subtree fingerprint before some full refreshes.
Full refreshes allocate candidates, measure/recenter, and manage a visual effect
view. There are already caches and deferred writes; do not report this as an
unoptimized per-frame rebuild without traces.

`ApolloAutoHideTabBar.xm:341` scans all tabs' navigation controllers to choose a
single tab-minimize policy. Its allocation-free fast path is already implemented,
but hidden columns can participate in a scene-wide visual decision. Pane mode
needs an explicit scroll/chrome owner and stable bar geometry.

**Outcome:** measure call counts and duration, eliminate passive-title effects,
cache only stable owner references, and avoid unrelated pane refreshes. Profile
Texture measurement, material rendering, and media decode separately before
choosing a remedy.

### A17 — P1 — Desktop input and release performance remain unproven

**Gap.** The pane adds two Option-arrow width commands (`:2685`) but no explicit
focused-column policy or pane-owned `scrollsToTop` arbitration. These commands
need testing against text-field word navigation. Divider simultaneous recognition
at `:4136` permits any other recognizer when one belongs to the divider; the
44×64 hit area overlaps content. Pointer introspection is not a real drag test.

There is no pane-level memory-warning/disconnect cleanup contract and no recorded
device hitch trace. Native UIKit may handle some behaviors correctly; absence of
a custom hook is not proof of failure.

**Outcome:** test and specify keyboard, VoiceOver, pointer, Reduce Motion, RTL,
modal focus, status-bar tap, scene lifecycle, memory pressure, and long sessions.
Use standard controls where possible and add targeted code only for a failing or
new product requirement.

## Corrections to the older plans

| Previous assumption | Current conclusion |
|---|---|
| Three Home content columns; other routes not extended | Current implementation has two content columns per tab, plus the system destination surface, and expanded routing. |
| UIKit collapse gives stock navigation for free | The current branch needs substantial compact reconciliation; swipe behavior is not equivalent. |
| All cross-column destinations must use native push | Current detail-root replacement intentionally uses `setViewControllers:animated:NO`; continuation uses native push. Preserve the distinction. |
| Geometry is solved; every row is 54 points | Preserve the proven host, but rebaseline merged search/OS behavior and distinguish context row from total nav/search container. |
| UIFindInteraction is a switch on a generic scroll view | Arbitrary Texture content needs an interaction delegate and find session; native find can be keyboard-docked or inline. |
| iPadOS 14–17 receives a degraded pane layout | The production capability gate is now iPadOS 18+. |
| Multiwindow is mostly plumbing because the plist permits it | Session ownership, routing, find state, and lifecycle still need verification and fixes. |
| Passing discrete resize and a hot-predicate benchmark establishes performance | Continuous resizing, render hitches, sustained media, device memory and thermal behavior are still open. |

The new roadmap absorbs Plan 001's useful visual work and expands its scope.
Its old source-file allowlist and STOP conditions describe that earlier task;
they do not limit this explicitly requested wider audit and plan.
