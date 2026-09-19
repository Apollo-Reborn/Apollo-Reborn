# Context menu customization verification

PR #1131 targets Apollo Reborn 3.7.1 and Apollo 1.15.11. Checks below were
performed on 2026-09-14. The catalogue describes actions the native builder
can offer, including conditional actions. It is not a union of all action
kinds in the application. “All” is a settings-only overview of the four
catalogues; it never becomes a runtime context.

## Binary checks

Hopper's connector was unavailable in this session. Equivalent checks used
`llvm-objdump` disassembly and Objective-C class/category metadata from Apollo.
Relative selector references were resolved through Mach-O chained fixups.

| Context | Tap implementation(s) | Builder |
| --- | --- | --- |
| Feed | PostsViewController `moreOptionsBarButtonItemTappedWithSender:` at `0x1005a93bc` | `0x1005c06d4` |
| Post | LargePostCellNode at `0x10030a35c`, CompactPostCellNode at `0x1007e5868`, RichMediaNode at `0x10058c37c`; `moreOptionsButtonTappedWithSender:` | `0x100325e84` |
| Post (Comments) | CommentsViewController `moreOptionsBarButtonItemTappedWithSender:` at `0x100718198` | `0x100727984` |
| Comment | CommentCellNode `moreOptionsTappedWithSender:` at `0x100508eec` | `0x1005ee890` |

Each builder's calls to the native action insertion function `0x100795634`
were inspected, including conditional kind selection. Corrections:

- Feed: remove speculative Trending/Mute/Moderator entries; add Exclude
  Subscriptions (222).
- Post: remove Select Text/Copy Text/Block; add Set Flair (47) and Mute/Unmute
  Notifications (251/252).
- Post (Comments): remove Hide/Copy Text/Moderator; add Set Flair and
  Mute/Unmute Notifications.
- Comment: remove Copy Text/Collapse/Subreddit/View Post/Block; keep conditional
  View All Replies, Parent Comment, Translate, Edit/Delete; add notification muting.

ActionController table selectors exist: row count at `0x1007985a4`, cell
construction at `0x10079ee04`, selection at `0x10079f65c`. Selection forwards to
`0x10079f330`, which derives the handler key from the selected action rather
than indexing a parallel handler array. The native Action buffer uses a 0x20
header and 0x30 stride (kind at +0, String fields at +8 and +0x18, accessory at
+0x28). Native actions are compacted only when uniquely referenced. Removed
String bridge words are released through Swift's runtime; surviving elements
transfer ownership without an extra retain/release.

A host Swift harness exercised the same 0x30 element layout and bridge-release
sequence 10,000 times with inline/heap titles and nil/non-nil subtitles. It
verified the surviving action and normal array destruction without a crash.
A Foundation model harness checked untouched defaults, visibility without
sorting, observed native preview order, per-context isolation, explicit
reordering, reset, duplicate/unknown IDs and malformed stored arrays. Only the
UIKit icon renderer was stubbed for the host build.

### Moderator menus (2026-09-17)

- Apollo flags its moderator sheets on the ActionController itself
  (`isShowingOnlyModeratorActions`, read by the glass renderer already); the
  owner reads the same ivar through `class_getInstanceVariable` and lets a
  moderator context claim only such a sheet (and such a sheet take only a
  moderator context).
- Entry points (Hopper, all already hooked by the glass renderer for its
  source-view capture, so the arm/disarm sits inside those hooks — one hook per
  selector): `-[PostsViewController moderatorBarButtonItemTappedWithSender:]`
  (subreddit); `-[LargePostCellNode moderatorOptionsButtonTappedWithSender:]`
  0x10030a3e4, `-[CompactPostCellNode …]` 0x1007e58fc, the
  `moderatorBannerNodeTappedWithSender:` on both cell nodes, `RichMediaNode`
  0x10058c450 and `CommentsHeaderCellNode` 0x10056d8b4, and
  `-[CommentsViewController moderatorBarButtonItemTappedWithSender:]` (post);
  `-[CommentCellNode moderatorBannerNodeTappedWithSender:]` 0x100508c54 and
  the comment cell's own shield `-[CommentCellNode modButtonTappedWithSender:]`
  0x100508c6c → `sub_10050a200` → `sub_1005485bc(comment, sectionController,
  navigationController, closure)` (comment; the shield had no hook before —
  added). Modmail's `-[PrivateMessageViewController
  modActionsBarButtonItemTappedWithSender:]` stays untouched.
- The Moderator row (kind 124) of a ••• sheet opens the object's moderator
  sheet only after the ••• sheet has dismissed, so the tap hooks' synchronous
  arm can't cover it: the glass action handler and the legacy `willSelect`
  (native row whose kind is 124) call `ApolloActionMenuArmModeratorFollowUp`,
  which arms the post's or comment's moderator context (from the parent
  sheet's own context) inside the usual 2 s arm window; a non-moderator sheet
  arriving first leaves it armed, a moderator sheet claims it.
- Captured kinds (moderator of r/ApolloReborn, glass sim 26.5): subreddit
  shield `164,163,166,167,168,169,178,203,165,170,171,172,209,175,210,179,177,
  186,162`; post shield = post ••• Moderator row = comments nav-bar shield
  `126,128,125,138,140,216,145,153,142,130,155,162`; comment shield = comment
  ••• Moderator row `126,128,125,130,142,161,155,162`. Toggle pairs share an
  item (Approve/Reapprove, Lock/Unlock 142/143/146/152, Sticky/Unsticky,
  Mark/Unmark OC …); the post's Set Post Flair item now also carries kind 145
  (the moderator's) next to 47 (your own post's).

## Behavior contracts

- Opening settings, switching menus, and changing visibility do not create a
  saved order. Native rows and tweak rows receive ranks only after a drag.
- The feed's Submit Post row (kind 51 — on Liquid Glass with the Polls feature
  on, the Photo/Link/Text/Poll button row that `ApolloSubmitPostTypesMenu`
  swaps in) is LOCKED (`ApolloActionMenuItem.locked`): never listed for
  editing, always first in a resolved or saved order, never in the hidden
  set. A stored layout that predates the lock is normalised on read
  (`ApolloActionMenuLockedFirst`). The ••• preview shows the button row when
  that is what the menu shows, and the footer says the row stays put.
- In the settings screen, the drag completion and Reset apply the visibility
  diff (`visibilityDidChange`: the Reset row appearing or disappearing)
  BEFORE rebuilding the items section: `rebuildSectionContainingRowID:`
  re-snapshots every section's visibility while reloading only one, so the
  other order tripped UITableView's batch-update assertion on an untouched
  menu's first drag (section 3 went 0 → 1 rows). Found in the glass sim on
  2026-09-14 (KSCrash report, `_Bug_Detected_In_Client_Of_UITableView_Invalid_
  Number_Of_Rows_In_Section`) and fixed; the visibility-tap path was never
  affected (`reloadRowWithID:` does not re-snapshot).
- Rows are tap-to-check (checkmark in the accent, drag grip to its right,
  both in one accessory view; the All overview drops the grip). A tap restyles
  the tapped cell IN PLACE (`styleItemCell:forItem:hidden:`, checkmark fading
  over 0.2 s) and never reloads the row: the earlier switch rows showed that a
  reload swaps the cell out under the finger (device recording, 2026-09-14
  23:07) and re-resolves the estimates of rows above the viewport.
- The ••• button top-right IS the preview (there is no pinned card any
  more — it took a third of the screen). Tapping it opens the menu being
  edited as Apollo would open it right now, with the saved order and
  visibility applied: on Liquid Glass a real UIMenu on the bar button
  (`ApolloAMBuildGlassPreviewMenu`, rows styled by the renderer's own
  `ApolloNativeActionMenuPreviewAction`, the feed's Submit Post as the
  Photo/Link/Text/Poll row via `ApolloSubmitPostTypesMenu`, Gallery View in
  its own inline section), built on every open through
  `UIDeferredMenuElement`'s uncached provider; before glass a sheet drawn
  after the classic ActionController (`ApolloAMPreviewSheetViewController`:
  10pt insets, 58pt accent rows, chevron on Submit Post, Cancel card, tweak
  rows appended below Apollo's as the legacy path does). Rows the menu
  doesn't offer right now are dimmed, not dropped, so a moved row is always
  where it was put; All has no preview (the button is disabled).
- Item rows have EXACT heights (`itemRowHeightWithSubtitle:` — one template
  cell per variant, cached per cell width and content size category). UIKit
  self-sized the rows from a 52 pt estimate;
  subtitled rows are taller, so any batch update re-resolved the estimates of
  rows above the viewport and scrolled the list several rows on every
  visibility change while scrolled down (sim recording, 2026-09-15 02:11).
  After the change a tap deep in the list moves nothing but its row's
  checkmark and dimming (frame-diff of the list region: ~3 vs 8–26 before).
- Glass specs with a custom `buildElement` (Gallery View's combined section,
  the profile Hidden & Deleted row, Sticky as Subreddit) place their own
  element. `ApolloActionMenuInjectMenuElements` now diffs the children before
  and after the builder runs, tags what it inserted with the spec, and — only
  under a saved order — re-homes those elements at the spec's rank
  (`ApolloActionMenuRankedInsertionIndex`, shared with the declarative path).
  Before this, Gallery View ignored the saved order on glass: with
  `submit, subscribe, spec.GalleryView, …` stored, the sheet still showed
  Gallery View above Unsubscribe (sim, 2026-09-14). Unranked builders keep
  their own placement.
- The settings list includes only that builder's supported actions; conditional
  entries say “Shown when available.” The ••• preview dims rows the menu didn't offer last time.
- All's taps affect every supporting context; mixed visibility is labelled.
  All has no reorder controls. Individual menus can override the choice.
- Reset removes the saved order and hidden set. Unknown native kinds remain
  visible. If a layout would hide every native row, the sheet shows all native
  rows so the menu stays usable.
- A tap context is scoped to its handler and captured on the presented
  controller before UIKit defers legacy table callbacks. No unrelated sheet
  can claim a leftover tap after the handler returns.
- The legacy path prepares its layout before reading row count or frame.
  Tweak-added legacy rows remain appended, as required by the existing native
  cell dequeue contract. Their relative order is customizable; the footer
  describes this limitation.


- The settings screen is a hub list (All Menus; the four ••• menus; the three
  moderator menus, each row with its glyph and a "Default" / "Custom order ·
  N hidden" summary) that pushes one editor per menu
  (`ApolloActionMenuEditorViewController initWithContext:`). Each editor is
  also a settings route (`action-menus-<context>`) so settings search still
  indexes every action and opens the right editor; the hub keeps the
  `action-menus` route. On every return the hub refreshes the rows' summaries
  IN PLACE (`cellForRowID:` → detail text), never by reloading: a
  `rebuildForm` there reset the footers to UIKit's estimates and the form
  base's footer re-measure animated them back while the interactive pop was
  still running — rows and footers visibly collapsed into each other during a
  swipe back from All Menus (device recording + log, 2026-09-18:
  `[SettingsForm] footer 0 is 23.0pt tall but its view fits 52.0pt`).
- Hub rows are disclosure rows with the form layer's new opt-in
  `detailAsSubtitle` (Subtitle-style cell, own reuse pool, detail wraps):
  as a trailing value "Custom order · 1 hidden" truncated beside
  "Post (Comments)" on the iOS 27 sim. No other screen opts in.
- Moderator menus are three more contexts (Moderator (Subreddit) / (Post) /
  (Comment)) with the same rules: no stored layout means untouched; only a
  moderator-flagged sheet applies a moderator layout; the settings preview
  draws them in the moderator tint with destructive rows red, behind a shield
  bar button instead of •••; All lists their items too.

## Reviewer checklist

Full branch reviewed against freshly fetched upstream main `4683371` (3.7.1).

### Nick

1. Guard width: context capture precedes the Glass-enabled gate, so legacy
   presentation still binds the tap. Unrelated controllers retain original
   behavior; unknown kinds and empty filtered native menus remain visible.
2. Existing behavior: no rank exists without a saved drag order. Visibility-only
   Glass testing preserved native survivor order. Feed Gallery placement and
   Post (Comments) Deleted Comments were observed with customization absent.
   Theme separator/accent helpers and the settings route are retained.
3. Object identity: context and slot state attach to the exact ActionController;
   no title, post body or username lookup selects the customized menu.
4. Failure: empty snapshots are ignored; unsupported/malformed preference values
   are filtered. Missing Swift runtime/shared storage logs and skips mutation.
   Runtime symbol resolution is process-invariant; no network result is cached.
5. Teardown: preview views are table-owned, outgoing animation views are removed;
   disappearance finishes the animator and clears pending refreshes. Associated
   slot state dies with its controller. No timers or window overlays added.
6. Stale completions: preview generation checked before queued refresh; changing
   menu invalidates queued work. Drag completion reads current form identities
   and does not replay captured index paths or a captured layout.
7. Threads: catalog cache is synchronized. Tap arm/take/disarm are main-thread
   confined; table/presentation/settings callbacks own UIKit/state writes.
   No new Texture or URLSession callbacks.
8. Cancelled pop: tap hooks use @try/@finally; viewWillDisappear clears pending
   preview state even without viewDidAppear. Runtime scenario is reported below.
9. Modes: see matrix below. New symbols (eye, pin.circle, square.grid.2x2,
   line.horizontal.3) and drag/animator APIs predate iOS 14. Device floor builds.
10. Hot paths: work is bounded to <=512 native actions, normally a few dozen;
    no network waits or synchronous dispatch. Catalog cached; unchanged snapshot
    avoids defaults writes. No decoded-image cache introduced.
11. Hook scoping: existing ActionMenu table owner performs remapping. Presentation
    capture routes through NativeActionMenus' existing presentation owner. The
    six ••• tap selectors and `-[ActionController viewWillAppear:]` are hooked
    ONCE: `ApolloNativeActionMenus.xm`'s existing hooks (source-view capture,
    lifecycle fallback) arm/disarm the menu context in `@try/@finally` and call
    the memoised prepare first thing — `ApolloActionMenu.xm` no longer adds a
    second hook on any of those selectors. Selector/ivar checks are detailed
    above.
12. Description: updated around supported catalogues, visibility-only defaults,
    All overview and legacy injected-row limitation; removed old claims about
    last-visible-row protection and unrun mode tests.

### Jordan

1. Account isolation: layouts are intentionally app-wide user preferences. The
   preview stores only generic action IDs, no account content/credentials, and
   never controls native availability. Every actual menu uses its own builder.
2. Toggle-off: visibility applies at next menu construction; there is no retained
   menu feature instance, parked view or background activity to disable. Preview
   updates immediately, and Reset removes hidden/order preferences.
3. Hot hooks: no new process-wide class hook. Existing presentation owner adds
   a cheap exact ActionController check before its Glass gate deliberately.
4. Scope: menu state is controller-associated. Only the synchronous tap handoff
   is global, main-thread confined and cleared in finally; no retry loops.
5. In-flight: preview generation and weak ownership prevent old refresh delivery;
   no network/filter/page/account completion added.
6. Predicates: All iterates all four valid contexts; unsupported actions are
   excluded using native-builder membership. Reset and hidden checks share the
   same context enumeration, with no title-based runtime routing.
7. Memory pressure: no parked web views or image cache. Preview caps at eight
   displayed rows and replaces/removes outgoing views. Catalog has four entries;
   no growing off-screen pool requiring memory-warning eviction.
8. Ownership: weak callback captures; retained/copied associated values. Swift
   unique-storage guard and releases for removed String fields checked by host
   harness and live legacy reordered Share selection. Frame layout is confined
   to tweak-owned UIView/UITableViewCell subclasses, no layout hook writes.
9. Affordances: searched history/changelog for restored menu affordances. Existing
   icon sizing, Deleted Comments and Gallery registry behavior retained; nothing
   hidden by default and unknown native actions remain visible.
10. Comments/tripwires: documented buffer offsets, ownership, legacy capture and
    injected-row placement; shared-storage failure logs. Corrected the old
    Foundation-only claim and async arming comment.
11. Device validation: physical device, memory-pressure instrumentation and
    account A→B→A were not available/run. No WebKit gesture/parked-view population
    is introduced. These are not represented as passed simulator checks.
12. Shared-code compatibility: synthetic merge results recorded with Verification
    below; no upstream push or merge is performed by those checks.


## Verification results and limits

- Device build: `THEOS=/Users/kurisu/theos make package`, pinned iOS 26.0 SDK,
  iOS 14 deployment target; package `com.apollo.reborn_3.7.1-4+debug_iphoneos-arm.deb`.
- Simulator build: simulator:clang:latest:15.0, internal Logos generator,
  APOLLO_SIM_BUILD=1, ad-hoc signing. Final build and launches passed.
- Complete code tree synthetic merges passed against main `4683371`, sibling
  #1048 `351dd15` and #1128 `eb710f2`; `git diff --check` and script syntax passed.
- iPhone 16 Pro / iOS 26.5 Glass: native Post visibility-only Upvote hiding
  preserved survivor order. Final explicit-order test produced kinds
  `15,124,7,5,12,42,44,239,241,17,1,122,123,2`, with Upvote (3) hidden.
- iPhone 16 Pro / iOS 26.5 non-Glass: official 3.7.1 NOEXTENSIONS IPA with
  original linked SDK 16.2, not a downgraded Glass binary. Untouched native
  sheet observed; final reordered/hidden sheet matched the same sequence above.
  Tapping relocated Share opened the system share sheet (nothing sent).
  Both styles logged Action-menu registry hooks installed and context=post.
- Settings on Glass: picker contexts, supported lists, Upvote visibility,
  independent Post/Post (Comments) state and pinned preview scrolling observed.
- iPad Pro 13-inch / iOS 26.5, WebJSONEnabled YES with no credentials:
  launch log confirmed keyless mode; settings and anchored picker worked.
  All→Author OFF logged only post/post-detail/comment writes; Post→Author ON
  produced “Shown in Some Menus” in All. All has no preview or drag grips.
  Final build: short back swipe (2,500→55,500 over 900ms) left settings open;
  subsequent Upvote tap updated preview. Reset This Menu logged removal of
  the Post customization. Pinned preview remained visible while scrolling.
- Host model and Swift ownership harnesses passed (described above).

Later on 2026-09-14 (glass sim, Apollo-Sim2, signed in as a moderator): a
completed drag gesture on an UNTOUCHED menu (Comment: Upvote above Moderator)
crashed the first build with the batch-update assertion above; after the fix
the same drag saved `upvote, moderator, downvote, …`, the Reset row appeared,
and tapping Reset This Menu removed the layout with the app alive. Dragging
Subscribe above Gallery View in the Feed menu saved `submit, subscribe,
spec.GalleryView, …` — the locked row normalised to the head. The Feed preview
drew the four new-post buttons above Gallery View, matching the device menu.

Not verified: Reset All by tapping its UI; authenticated
web-JSON menu browsing; two-account A→B→A; iPad simultaneous feed/detail menus;
physical-device memory/gesture testing. The short back gesture above is a smoke
test, not instrumented proof of every interactive cancellation callback. Desktop
accessibility testing became unavailable when the Mac locked. These gaps are
explicitly outstanding; the complete runtime matrix is not claimed passed.
