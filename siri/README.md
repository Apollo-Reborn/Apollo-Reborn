# Siri and Spotlight integration inside Apollo

This is an opt-in iOS 27 proof embedded in the **real Apollo application**.
There is no standalone app target, replacement executable, or new extension.
The normal Theos build and its iOS 14 deployment target are unchanged.

## Current implementation (2026-09-19)

The integration now has a bounded persistent content catalogue, native search,
interactive result snippets and an opt-in schema experiment. Progress and remaining work live in
[`docs/siri-spotlight-task-list.md`](../docs/siri-spotlight-task-list.md).

- **Search Apollo** calls Apollo's native search-bar callbacks and verifies the
  resulting `PostsSearchResultsViewController` and query activity. It never
  routes a search URL to a browser and refuses to dismiss a presented sheet.
  An empty App Shortcut invocation explicitly asks for a query first.
- **Set Apollo Content Indexing** is an explicit Shortcuts action. It defaults
  off. Enable it before browsing; disable it to clear this integration's local
  catalogue and post/subreddit entities. Existing legacy indexes and the original
  fixed community proof are not erased.
- **Apollo Content Index Status** reports current catalogue counts or a sync
  error. **Find Indexed Apollo Posts** returns up to ten locally matching posts
  and a compact snippet with native open buttons. **Search Apollo Posts** fetches
  a bounded set through Apollo's authenticated client and returns the same card.
- Apollo Reborn > Privacy > **Siri & Spotlight** provides enable/clear, counts,
  explicit subscription refresh and the off-by-default notes-schema experiment.
- The listing hook forwards allowlisted metadata without extra requests. Only
  signed-in, public, non-NSFW, non-hidden, non-removed posts and public subscribed
  communities qualify. Anonymous browsing isn't captured. This capture point
  includes loaded listing results; it doesn't backfill all saved/read history.
- A versioned atomic JSON catalogue holds at most 1,000 posts and 500 communities
  for 30 days. It is excluded from backups and stores an account fingerprint,
  not credentials. Account changes clear the previous scope.
- Entity-backed Spotlight items have expiry dates; synchronization removes
  evicted records and supports system-requested reindexing. Queries resolve from
  disk after a cold launch. Post and community open actions reuse native routes.
- Hide/delete/unsubscribe observation persists tombstones against stale responses.
  Successful unhide/subscribe permits fresh metadata. Subscription refresh only
  reconciles missing entries after a complete fetch (five-page / 500-item cap).
- Visible post nodes and detail activities receive UIKit App Entity annotations.
  These use only currently eligible catalogue records and clear on view exit or
  privacy/account invalidation. Siri reference resolution still needs device tests.
- **Experimental Notes Schema** projects posts into an isolated index namespace;
  only one post representation is indexed at a time. It is read-only and declares
  no note create/edit/delete intents. Metadata validation passes; improved Siri
  discovery is a hypothesis, not a verified result.

This is experimental. Full favourites/saved/read-history backfill, real-account
capture verification, lifecycle/device checks and Siri discovery comparisons
remain in the task list. Siri AI discovery is a separate acceptance gate.

Run the Foundation-only catalogue checks with `bash scripts/test-siri-catalog.sh`.
All 37 assertions pass. The updated framework and Theos builds compile. Actual
simulator Shortcuts execution verified warm Unicode/cold native search, two-row
synthetic snippets, native Comments routing and disable/clear. The simulator-only
fixture flag is not compiled into device builds. Real-account capture/Spotlight
and live Reddit search validation is pending an unlocked phone.

## Preserved packaging proof

- One fixed `IndexedEntity`: `r/ApolloReborn`, with stable identifier
  `reddit:subreddit:apolloreborn` and a string/entity query.
- **Open Apollo Subreddit**: the iOS 27 `.system.open` schema, foreground
  execution in Apollo, and an `apollo://` URL delivered through the tweak's
  existing in-process `ApolloRouteURLThroughApp` router.
- **Search Apollo**: the `.system.searchInApp` schema; now uses native search
  instead of the previously browser-bound URL handler.
- **Show Apollo Community**: returns the fixed entity, dialog, and static SwiftUI
  snippet. Running it explicitly indexes that one public entity in Spotlight.
- Three original App Shortcuts with phrases using the host application's name,
  plus Find Indexed Posts and Search Posts. No per-post shortcuts are donated.

The fixed proof remains available independently of content indexing.
Search requires Apollo's normal API/account setup. The fixed snippet does not.
Diagnostics use the `apollofix` subsystem and never log search terms.

## Packaging

Requires Xcode 27 with the iOS 27 SDK, XcodeGen, and the repo's usual build tools.
First build a normal Apollo-Reborn IPA using `make package`, `patch.sh` (including
`--fix-safari-extension`), and `build-ipa.sh` as documented in the root AGENTS.md.
Then:

```sh
scripts/inject-siri-proof.sh --ipa /path/to/Apollo-Reborn.ipa -o packages/Apollo-Siri-Proof.ipa
```

The output must not already exist. The input IPA is preserved. The script builds
`ApolloSiri.framework`, embeds it in Apollo, adds its Mach-O load command, and
extracts host-level App Intents metadata and spoken-phrase assets using Apollo's
actual bundle identifier and name. This is more than copying framework metadata.
The resulting **unsigned proof IPA requires iOS 27**. Sign it through the usual
Apollo sideloading workflow, including the embedded framework.

Use the final intended bundle ID before running the script. A signer that changes
Apollo's bundle ID afterward may invalidate the generated phrase metadata; that
signing workflow still needs verification. Do not assume a successful framework
load proves system discovery or that arbitrary sideloaders preserve all metadata.

For an already prepared simulator Apollo bundle:

```sh
scripts/inject-siri-proof.sh --app .sim-siri-proof/Payload/Apollo.app --sdk iphonesimulator
```

`--app` modifies that bundle in place; re-sign the framework and application,
then reinstall. The normal simulator script injects the tweak through a launch
environment variable. For system-driven cold launches, the simulator tweak must
also be embedded/loaded in the Apollo bundle; the device IPA already loads its
tweak normally. Keep this experiment separate from the standard `.sim` cache.

## Historical packaging verification (2026-09-17)

Passed:

- Regular Theos package build, device and simulator framework compilation.
- Apple metadata extraction recognizes the intents, entity, and App Shortcuts;
  host phrase training uses `Apollo` and `com.christianselig.Apollo`.
- Real Apollo launches on the iOS 27 simulator with the framework embedded.
  Logs show `Framework loaded in Apollo` and shortcut parameter refresh.
- Actual Apollo UI capture shows the existing Apollo Reborn settings screen.
- ApolloSign USB installation on the real iOS 27 phone, framework loading,
  all three actions appearing in Shortcuts, and the Show Community snippet
  rendering (user-confirmed screenshots).

The initial handoff-based navigation only opened Apollo: that handler expects
`openinapollo.com` query links, not ordinary Reddit URLs. Open/search now use
`apollo://reddit.com/…` through the existing tweak router instead (the canonical
host is important: `www.reddit.com` can fall through to Apollo's web viewer). This
revision's native subreddit opening and community snippet were subsequently
confirmed by the user. The search URL still opened a browser and is now replaced
by the native-search bridge above. Action/entity identifiers are unchanged.

Follow-up status is recorded in the task list. Native warm/cold search and
synthetic result-card routing now pass simulator UI tests. Real-content Spotlight
activation and Siri/Apple Intelligence behavior remain unverified. ApolloSign's
`com.jte.ApolloReborn` setup is verified when metadata is generated for its
final bundle ID and display name before signing.

`ApolloSiriTests` is a hostless XCTest **bundle**, not an application. It imports
AppIntentsTesting and addresses the installed Apollo by bundle identifier; it does
not link the proof framework. It compiles, but this Xcode 27 simulator rejected
the test-service connection before Apollo execution with `transportCancelled`.
The underlying service log says `XCTest internal client entitlement validation
failed: com.apple.private.dt.xctest.internal-client should be true`. No private
entitlement workaround was added. This is a test-harness blocker, not evidence
that Apollo action execution works or fails. The existing UI automation runner
subsequently exercised actual Shortcuts cards successfully; see the current
task-list evidence rather than treating this historical harness failure as final.

## Device acceptance checklist

1. Sign/install the proof as Apollo, launch it once, and verify normal browsing.
   Check the `apollofix` / `SiriProof` logs for framework loading.
2. Find Apollo in Shortcuts. Confirm the three original proof shortcuts plus
   Find Indexed Posts and Search Posts. Merely seeing legacy actions does not pass.
3. Run **Show Apollo Community**. Verify the returned entity, dialog, and snippet.
   Run it again and search Spotlight for `ApolloReborn`; check for one result.
4. Run **Open Apollo Subreddit**, then **Search Apollo** with a known term.
   Confirm navigation stays inside this Apollo installation and the query is
   preserved. Test both warm execution and after force-quitting Apollo.
5. Ask Siri “Show the community in Apollo”, “Open the community in Apollo”, and
   “Search Apollo”. Check entity/dialog results; Siri may choose not to display
   a custom snippet in every presentation or Apple Intelligence configuration.
6. Tap the Spotlight entity and verify it opens the subreddit in Apollo.
   Repeat after a reboot. Record OS version, signer, and final bundle identifier.

Continue recording actual device evidence in the task list. Real-content and
Siri AI behaviour remain separate acceptance gates from the fixed proof.
