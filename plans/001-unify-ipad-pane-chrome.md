# Plan 001: Unify the adaptive iPad pane chrome

> **7 September 2026:** Incorporated with revisions into [Plan 002](002-ipad-pane-redesign.md).
> See [implementation results](003-ipad-pane-implementation-results.md) for the
> delivered chrome, system Find choice, geometry fixes and remaining release gates.
> The historical fixed 54-point requirement and narrow file allowlist below are
> superseded by Plan 002 and the user's authorization to implement the full redesign.

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report—do not improvise. When done, update this plan's status row in
> `plans/README.md` unless a reviewer says they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 2ada38e..HEAD -- Makefile src/ipad/ApolloPaneInstall.xm src/ipad/ApolloPaneLayout.h src/ipad/ApolloPaneSplitViewController.h src/ipad/ApolloPaneSplitViewController.m src/ipad/ApolloPaneRouter.xm src/ApolloLiquidGlass.xm src/ApolloFindInComments.xm src/ApolloSubredditHeaders.xm src/ApolloSimDebugTap.xm IPAD_PANE_PR_886_IMPLEMENTATION.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding. A semantic
> mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L (multi-day, including simulator matrix)
- **Risk**: MED — navigation and search behavior are preserved, but the work
  coordinates several UIKit-owned surfaces across resize/rotation transitions.
- **Depends on**: none
- **Category**: tech-debt / direction
- **Planned at**: commit `2ada38e`, 2026-09-04

## Why this matters

PR #886 successfully re-hosts Apollo's real list and detail controllers, but it
does not yet give their chrome a single visual policy. In the 13-inch landscape
comments state, four independent owners produce five equal-weight islands: the
tab controller's floating destination bar, the primary navigation row, the
detail title capsule, Apollo's comments-search toolbar, and the detail action
capsule. Their frames are technically valid, but the result has no clear
information hierarchy and immersive artwork makes the primary row look like a
separate floating banner.

After this plan, pane mode has one deterministic chrome model:

1. exactly one global destination surface (sidebar when wide by default,
   otherwise the system top tab bar),
2. exactly one aligned context row per visible content pane,
3. search replaces the detail row's normal contents while active instead of
   adding another row,
4. only interactive title controls receive a title capsule, and
5. immersive artwork begins below pane chrome instead of becoming its substrate.

The behavior must remain opt-in, iPad-only, and unchanged when pane mode is off.

## Target layout matrix

| State | Destination surface | Primary context | Detail context | Search behavior |
|---|---|---|---|---|
| Wide regular (13-inch landscape / sufficiently wide Stage Manager) | Sidebar preferred on first presentation | One 54-pt row | One 54-pt row | Replaces detail context content |
| Medium regular (11-inch landscape, 13-inch portrait) | UIKit top tab bar is allowed | One row below it | One aligned row below it | Replaces detail context content |
| Narrow regular / compact (iPad mini portrait, narrow Stage Manager, Slide Over) | UIKit-selected tab presentation | Existing collapsed Apollo stack | No second simultaneous row | Existing one-column search behavior |
| Empty detail | Same width policy | One row if the primary needs it | No orphan title/action capsules | Not shown |
| Settings / Inbox / Search tabs | Same width policy | Native list title/actions | Native detail title/actions | No Home/comments-specific policy |

The width decision must use the selected tab controller's actual content bounds,
not `UIScreen.mainScreen`. Use a named constant derived from the layout
invariant, not a device-name check: the sidebar is preferred only when its width,
the 340-pt minimum primary, the separator, and a useful detail width all fit.
Start the spike around 1180 points and adjust from hierarchy measurements.

## Current state

### Architectural intent already recorded

- `docs/ipad-pane-layout-plan.md:571-584` calls full-width chrome assumptions
  the branch's "largest hidden cost" and names a planned `ApolloPaneChrome.xm`
  reconciliation layer. That file does not exist at commit `2ada38e`.
- `docs/ipad-pane-layout-plan.md:737-742` already recommends replacing the
  hand-rolled comments search toolbar with `UIFindInteraction` and spiking
  `UINavigationItemStyleBrowser` for pane density.
- `docs/ipad-pane-layout-plan.md:748-780` selects UIKit's tab sidebar as the
  one persistent destination surface, while retaining UIKit's adaptive top tab
  presentation when the sidebar is collapsed or unavailable.

### The four current chrome owners

1. `src/ipad/ApolloPaneInstall.xm:377-433` sets
   `tabBarController.mode = UITabBarControllerModeTabSidebar`. UIKit still lets
   the sidebar be minimized into `_UIFloatingTabBar`, so pane mode can show the
   global 44-pt tab strip above both pane nav bars.
2. `src/ipad/ApolloPaneSplitViewController.m:2067-2076` installs Apollo's
   original navigation controller as the primary and constructs a second real
   Apollo navigation controller for detail. This is correct and must remain;
   the work is a policy over these controllers, not their replacement.
3. `src/ApolloLiquidGlass.xm:1126-1162` recenters every title control and creates
   a glass capsule for Jump Bars *and plain titles*. This turns passive labels
   such as “21 Comments”, “Settings”, and “Apollo Reborn” into button-like
   islands in pane mode.
4. `Headers/ObjC/_TtC6Apollo21ASTableViewController.h:20-41` exposes Apollo's
   search state and `upperToolbar`; `src/ApolloFindInComments.xm:3-49` preserves
   Apollo's native comments-search pipeline. Runtime inspection on the 13-inch
   simulator measured the comments toolbar at `(detailX, navMaxY, detailWidth,
   45)`—a separate row below the 54-pt detail navigation bar.

### Geometry is already correct

Do not reopen the solved frame problem. The column host in
`src/ipad/ApolloPaneSplitViewController.m:492-515` deliberately aligns the
detail navigation controller to the primary's real frame without writing
layout inputs from `viewDidLayoutSubviews`. Live hierarchy measurements at
1376×1032 show:

```text
floating tabs: y=32, height=44       (only while sidebar is hidden)
primary nav:   y=86, height=54
detail nav:    y=86, height=54
comments find: y=140, height=45      (while comments search is active)
```

With the sidebar visible, all three navigation bars (sidebar, primary, detail)
start at y=32 and are 54 points high. Preserve these alignment invariants.

### Immersive art currently owns the chrome substrate

`src/ApolloSubredditHeaders.xm:1711-1772` derives an ambient background region
from the table's complete adjusted top inset and explicitly describes that inset
as “the full chrome above the table header.” In a pane, that makes one column's
content art paint underneath its navigation row while the neighboring detail
row uses a different page/media substrate. Pane mode needs a boundary at the
navigation bar's bottom; non-pane and iPhone immersive behavior must not change.

### Applicable repo conventions

- Gate every new runtime path with `ApolloPaneLayoutActive()` or
  `ApolloPaneLayoutEnabled()`; the feature is opt-in and dormant on iPhone.
- Use `ApolloLog` for privacy-safe diagnostics.
- Derive geometry from the owning view/window, never `UIScreen.mainScreen`.
- Do not make layout-driving writes from `layoutSubviews`; use safe-area,
  transition, navigation-settlement, or coalesced next-run-loop callbacks.
- Preserve Apollo's real navigation controllers and native push/pop methods.
- Use 4-space indentation and same-line braces.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Device build | `make package` | exit 0; a package is produced with the pinned iOS 26 SDK |
| Simulator loop | `scripts/run-in-sim.sh --glass --dark` | exit 0; Apollo launches and pane hooks log as installed |
| Relaunch | `scripts/run-in-sim.sh --no-build --glass --dark` | exit 0; Apollo relaunches without rebuilding |
| Verify injection | `xcrun simctl spawn "$(cat .sim/device.txt)" log show --last 2m --predicate 'subsystem == "apollofix"'` | contains ApolloFix/pane module-load lines |
| View hierarchy | `echo dump > /tmp/apollofix-tap.txt && xcrun simctl spawn "$(cat .sim/device.txt)" notifyutil -p apollofix.debugtap` | `/tmp/apollofix-dump.txt` is refreshed |

`./.sim/backup.zip`, when present, contains live credentials. It is ignored and
may be used by the simulator script, but must never be printed, inspected,
copied into `plans/`, or committed.

## Scope

**In scope** (the only source files to modify):

- `Makefile`
- `src/ipad/ApolloPaneChrome.h` (create)
- `src/ipad/ApolloPaneChrome.xm` (create)
- `src/ipad/ApolloPaneInstall.xm`
- `src/ipad/ApolloPaneLayout.h`
- `src/ipad/ApolloPaneSplitViewController.h`
- `src/ipad/ApolloPaneSplitViewController.m`
- `src/ipad/ApolloPaneRouter.xm`
- `src/ApolloLiquidGlass.xm`
- `src/ApolloFindInComments.xm`
- `src/ApolloSubredditHeaders.xm`
- `src/ApolloSimDebugTap.xm`
- `IPAD_PANE_PR_886_IMPLEMENTATION.md`
- `plans/README.md`

**Out of scope** (do not touch):

- Pane routing, history, selection, collapse/expand topology, or readable-width
  behavior except to call the chrome policy after existing settlement points.
- Replacing either navigation controller or copying Apollo navigation items into
  a custom toolbar.
- Global/iPhone Liquid Glass title behavior.
- Global removal of subreddit/profile immersive headers.
- Theme colors, Theme Manager, settings-form geometry, feed/comment cell layout,
  or the divider drag affordance.
- Any new user-facing setting in the first implementation. Width/state policy
  should be deterministic before adding preferences.

## Git workflow

- Work on a child branch such as `fix/886-ipad-pane-chrome` from the current PR
  branch.
- Use one commit per logical unit; existing commit messages use imperative form,
  e.g. `Prevent iPad detail forms from snapping after display`.
- Do not push or open a PR unless the operator explicitly asks.

## Steps

### Step 1: Add a pane-chrome policy owner and simulator diagnostics

Create `ApolloPaneChrome.h/.xm`, add it to `ApolloReborn_FILES`, and make it the
single owner of visual chrome decisions. It should accept the active pane and
its primary/detail navigation controllers, derive these state inputs, and apply
idempotently:

- pane active vs collapsed,
- actual pane/content width,
- sidebar visible vs top tab bar visible,
- primary/detail top controllers,
- comments-search inactive vs active,
- immersive-header active vs ordinary content.

Expose narrow functions such as `ApolloPaneChromeRefresh(pane, reason)` and
queries used by `ApolloLiquidGlass.xm` / `ApolloSubredditHeaders.xm`; do not make
those global modules rediscover pane ownership by scanning windows.

Call refresh from existing stable lifecycle points: after pane installation,
after navigation settles in `ApolloPaneRouter.xm`, and from the pane's existing
safe-area/transition/display-state callbacks. Coalesce duplicate refreshes onto
the next main run-loop turn and log only when the resolved state changes.

Add a simulator-only `chromedump` command that writes/logs: content width,
collapsed state, sidebar hidden state, destination presentation, primary/detail
nav frames, active search host/frame, and count of pane title-glass views. Do not
log any title/search text.

**Verify**: simulator build and `chromedump` succeed. Repeating `chromedump`
without a state change reports identical values and produces no repeated policy
mutation logs.

### Step 2: Prefer the destination sidebar only when the layout is truly wide

At pane installation and after width-class/size transitions, prefer
`tabBarController.sidebar.hidden = NO` only when all of these are true:

- pane mode is active and expanded,
- the tab sidebar is available,
- actual content width satisfies the named wide-layout invariant,
- this scene has not recorded an explicit user collapse for the current wide
  presentation.

Observe sidebar visibility changes through the public sidebar delegate callback
where available, without replacing another non-nil delegate. If reliable
explicit-vs-programmatic intent cannot be distinguished on iPadOS 18–26, apply
the preference once per scene on first wide presentation and never force it
again. A user pressing UIKit's sidebar toggle must remain able to collapse it.

Do not force a sidebar in 13-inch portrait, iPad mini portrait, narrow Stage
Manager, or when doing so would violate the 340-pt primary minimum plus useful
detail width. Do not use device names or screen bounds.

**Verify**: cold 1376×1032 launch resolves `destination=sidebar`; manually
collapsing it resolves `destination=top-tabs` and stays collapsed through a tab
switch. At 1032×1376 and narrower widths, UIKit's top-tab/overlay adaptation
remains reachable.

### Step 3: Make pane navigation items read as one context row

For visible primary/detail items in expanded pane mode, spike
`UINavigationItemStyleBrowser` (iOS 16+) and retain it only if it produces these
measured outcomes on both iPadOS 26 and 27:

- titles align on the same baseline,
- the primary Jump Bar still opens and searches correctly,
- Back and all native trailing actions remain reachable,
- no title/action overlap at 340-pt primary width or with Dynamic Type,
- push/pop/interactive-pop animations remain native.

Regardless of whether browser style survives the spike, change the pane-active
Liquid Glass rule so passive plain titles do not get the custom title capsule.
Keep capsules for genuinely interactive custom title controls such as Apollo's
Home Jump Bar. Preserve current behavior outside active pane mode.

Normal comments chrome should be one detail nav row: a low-emphasis plain
“Comments” title (or the native title without its capsule) plus the existing
trailing action group. Move the numeric comment count out of navigation identity
only if this can be done without fabricating model data; otherwise keep the
native text but remove its button-like capsule. Never rewrite unrelated screen
titles.

**Verify**: in Home, Settings, Inbox, and a comments thread, `chromedump`
reports primary/detail bars with equal `minY` and height within 0.5 pt, and zero
plain-title glass views. The interactive Home Jump Bar still has one title-glass
view and remains tappable.

### Step 4: Make comments search replace, not stack

Keep Apollo's existing comments matching, highlight, next/previous, multi-term,
and scroll-watchdog behavior in `ApolloFindInComments.xm`. Change only its pane
presentation.

Preferred implementation order:

1. Spike a `UIFindInteraction` adapter around Apollo's existing search session.
   Use the system find navigator only if the adapter can preserve match count,
   current result, next/previous, comma-separated terms, keyboard Command-F,
   and the existing cancellation/scroll watchdog.
2. If that cannot be achieved without reimplementing Apollo's matcher, retain
   `ApolloSearchToolbar` but re-host it inside the detail navigation row while
   search is active. Hide/suppress the normal detail title and action group for
   the duration, restore them atomically on dismissal, and keep the detail
   content's top edge unchanged.

On iOS 26+, a `UISearchController` with integrated/integrated-button placement
is acceptable only if it feeds Apollo's existing matcher rather than creating a
second search state. On iOS 18–25, use the retained toolbar takeover fallback.
Do not leave both search systems live.

The active state invariant is: one search surface, in the existing 54-pt detail
context row, with no additional 45-pt row and no simultaneously visible comments
title/actions. Dismissal restores the normal row without a width/height snap.

**Verify**: before and during comments search, `chromedump` reports the same
detail content `minY`; during search there is exactly one visible search host and
no separate `ApolloSearchToolbar` below the nav bar. Query edit, comma-separated
terms, next, previous, wrap-around, keyboard dismissal, rotation, and a user
scroll during the watchdog all preserve current behavior.

### Step 5: Bound immersive artwork below pane chrome

In active expanded pane mode only, make the subreddit ambient/header artwork's
top visible boundary start at the owning navigation bar's bottom. The navigation
row should use one stable theme/material treatment independent of whether the
primary shows a banner and whether the detail shows media. Preserve the banner
inside feed content and preserve all current non-pane/iPhone immersive behavior.

Do not hardcode the global tab bar height or status-bar height. Ask the pane
chrome owner for the resolved content boundary derived from the owning nav bar
frame. Keep the existing brightness sampling for any interactive control that
still overlays art below that boundary.

**Verify**: switching between Native/Classic/immersive header modes does not
change nav-bar frames. In immersive Home with empty detail and with comments
open, artwork begins below both context bars and neither bar's substrate changes
color independently. Scrolling still collapses/reveals header content without a
flash or gap.

### Step 6: Run the complete layout matrix and update the PR tracker

Exercise, at minimum:

- 13-inch: portrait and landscape; sidebar shown and manually hidden; empty
  detail, media comments, self-post comments, active comments search, Settings
  detail, Inbox detail.
- 11-inch: portrait and landscape; same empty/comments/search states.
- iPad mini: portrait and landscape; confirm the system chooses overlay/collapse
  before either pane becomes unusably narrow.
- Stage Manager/narrow window equivalents: widths around the policy threshold
  and at 480 points; resize across the threshold in both directions.
- Light and dark appearance; stock and custom theme; Header Style modes; largest
  practical Dynamic Type size.
- Rotate/rescale while search is active, while a detail push transition is
  settling, and after manually resizing the primary divider.

For each state, capture a screenshot and `chromedump` under `.sim/`. Record the
matrix and exact filenames in `IPAD_PANE_PR_886_IMPLEMENTATION.md`; never commit
screenshots or the backup.

**Verify**: `make package` exits 0, the simulator matrix passes all invariants,
and `git status --short` lists only in-scope source/doc changes plus the plan
status update.

## Test plan

There is no automated test suite; use the simulator and simulator-only structured
diagnostics as the regression harness.

For every matrix state, verify these machine-readable invariants:

- `destination` is exactly `sidebar` or `top-tabs`, never both visible.
- When two panes are visible, primary/detail nav `minY` and height differ by no
  more than 0.5 point.
- At most one context row contributes to each pane's content inset.
- Activating comments search does not change detail content `minY`.
- Active search has one search host; normal title/actions are absent until it
  dismisses.
- Plain pane titles create zero custom glass capsules; the Home Jump Bar creates
  exactly one.
- Compact/collapsed mode reports no simultaneous secondary chrome owner.

Manual behavior checks still required: every button/menu works, keyboard focus
lands in search, Command-F opens it, next/previous selection stays visible, Back
and forward history work, and sidebar show/hide remains user-controlled.

## Done criteria

- [ ] `make package` exits 0.
- [ ] `scripts/run-in-sim.sh --glass --dark` exits 0 and injection logs confirm
      all pane/chrome hooks loaded.
- [ ] The complete device/width/state matrix is recorded in
      `IPAD_PANE_PR_886_IMPLEMENTATION.md` with `.sim/` screenshot/dump names.
- [ ] Wide cold launch prefers the sidebar; user collapse is respected.
- [ ] Every expanded two-pane state has one aligned context row per pane.
- [ ] Comments search replaces detail context content and does not add vertical
      chrome height.
- [ ] Passive pane titles have no custom Liquid Glass capsule; interactive Home
      Jump Bar behavior is unchanged.
- [ ] Pane-mode immersive artwork starts below chrome; iPhone and pane-off
      immersive behavior is unchanged.
- [ ] No files outside the in-scope list are modified.
- [ ] `plans/README.md` status is updated.

## STOP conditions

Stop and report back—do not improvise—if:

- In-scope current code no longer matches the ownership/geometry described above.
- Preserving Apollo's matcher requires replacing or synthesizing its private
  `commentsSearch` Swift storage.
- Search takeover cannot preserve current keyboard, next/previous, result count,
  and dismissal semantics after two reasonable approaches.
- Browser-style navigation loses any native action, breaks the Home Jump Bar, or
  overlaps at the 340-pt primary minimum; reject that spike and keep navigator
  style rather than patching UIKit's private views.
- Detecting explicit sidebar intent would require private UIKit selectors. Fall
  back to once-per-scene wide preference instead.
- The immersive boundary requires changing feed/comment cell measurement or
  Texture layout. The fix must stay at the background/chrome layer.
- Any change would affect iPhone or pane-disabled behavior.
- A verification failure persists after two reasonable fixes.

## Maintenance notes

- Reviewers should reject geometry derived from `UIScreen.mainScreen`, writes
  from `layoutSubviews`, or window-wide view scans. The pane object already knows
  both navigation controllers and is the correct source of state.
- Keep structured `chromedump` output privacy-safe: frames, class names, booleans,
  and counts only—never titles, subreddit names, search text, or account data.
- Any future detail route must opt into the same context-row policy; do not add
  screen-specific title/search hacks in the route module.
- If Apple changes tab-sidebar defaults, update only the destination-placement
  arm of `ApolloPaneChrome`; title/search/immersive rules should remain stable.
