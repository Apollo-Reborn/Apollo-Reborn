# Siri and Spotlight integration inside Apollo

This is an opt-in iOS 27 proof embedded in the **real Apollo application**.
There is no standalone app target, replacement executable, or new extension.
The normal Theos build and its iOS 14 deployment target are unchanged.

For the 2026-09-25 review against shipping Siri AI and the merged upstream code,
see the [gap assessment and implementation sequence](../docs/siri-ai-gap-assessment.md).

**Current discovery test (2026-09-25):** the five App Shortcut phrase registrations
are disabled at the user's request. The provider publishes an empty catalogue;
App Intent type names, schema conformances, entity IDs, and snippet implementations
are retained. Packaging removes this proof's old phrase assets and verifies zero
`autoShortcuts` in both host and framework metadata. The next device test is natural
Siri invocation and Spotlight, not triggering a registered shortcut phrase.
Ordinary intent actions can still appear in the Shortcuts editor; this does not
mean the removed phrase registrations have returned.

**2026-09-28:** aligned with Apple's documented Siri AI model — see the
[best-practice section](../docs/siri-ai-gap-assessment.md#2026-09-28-best-practice-alignment).
In-Siri results come from the semantic index, not from the custom card action;
the fixed proof no longer competes as a `.system.open` subreddit action.
A follow-up [sample-code deep dive](../docs/siri-ai-gap-assessment.md#2026-09-28-deep-dive-apple-sample-code-patterns)
added comment entities, memory-only session context for opened posts/loaded
comments, Spotlight client-state batching and UI-only donations.

## Current implementation (2026-09-19)

The integration now has a bounded persistent content catalogue, native search,
interactive result snippets and an opt-in schema experiment. Progress and remaining work live in
[`docs/siri-spotlight-task-list.md`](../docs/siri-spotlight-task-list.md).

- **Search Apollo** calls Apollo's native search-bar callbacks and verifies the
  resulting `PostsSearchResultsViewController` and query activity. It never
  routes a search URL to a browser and refuses to dismiss a presented sheet.
  Empty criteria explicitly prompt for a query first. This navigation action
  does not return the separate post-result snippet.
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

This is experimental. Real post and subreddit Spotlight discovery now pass
user device testing. Lifecycle checks, unread/subscription collection and Siri
discovery comparisons remain in the task list. Natural search currently opens
Apollo search; natural subreddit opening incorrectly falls through to search.
The observed onscreen summary does not yet prove entity resolution.

Run the Foundation-only catalogue checks with `bash scripts/test-siri-catalog.sh`.
All 51 assertions pass, including spoken subreddit names with spaces/hyphens.
The updated device framework builds. Actual
simulator Shortcuts execution verified warm Unicode/cold native search, two-row
synthetic snippets, native Comments routing and disable/clear. The simulator-only
fixture flag is not compiled into device builds. Live Reddit search through
the snippet-returning action still needs device validation.

## Diagnosing conversational Siri

The `apollofix` / `SiriProof` log category now separates:

- `Onscreen detail` binding, eligibility, view annotation and activity annotation.
- `Query started/completed/failed` for post, subscribed subreddit and experimental
  note queries. Completion includes a result count, never identifiers or text.
- Open action execution, search-in-app navigation, snippet-returning search and
  snippet view execution. Returning a snippet view is not proof Siri displayed it.

Detail events use notice level and appear in Apollo Reborn > Advanced > Export
Debug Logs. Export immediately after the test without force-quitting; this export
reads the current process's log. Feed-row events use debug level to avoid noisy
persistent logs during scrolling. All new messages contain only fixed stage
labels and counts, never search terms, titles, account identifiers or body text.

Keep Experimental Notes Schema off for the first run. Type an exact indexed
subreddit name in Siri, then speak its spaced/hyphenated name. For context, open
a short indexed text post, scroll its body offscreen and ask about that body.
Record the time and response, then export logs. An annotation only proves we
offered context; a query callback proves access by a system consumer (which may
also be Spotlight or Shortcuts). Neither alone proves Siri used it in its answer,
and cached system content can mean no fresh callback. Compare the answer against
content unavailable in the visible screen before claiming stronger awareness.

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
- The five former App Shortcut phrase registrations are disabled. Underlying
  intents remain available; existing user-authored shortcuts are not deleted.

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
extracts host-level App Intents metadata using Apollo's actual bundle identifier.
It removes old proof phrase assets and skips phrase training. This is more than
copying framework metadata.
The resulting **unsigned proof IPA requires iOS 27**. Sign it through the usual
Apollo sideloading workflow, including the embedded framework.

Use the final intended bundle ID before running the script. A signer that changes
Apollo's bundle ID afterward may invalidate the generated host metadata; that
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
2. Enable content indexing, browse public posts, and refresh subscribed communities.
   Confirm the catalogue contains real posts and communities.
3. Find a real post and community in Spotlight and open each. Repeat after
   terminating Apollo. Record OS version, signer, and final bundle identifier.
4. Ask Siri naturally to search in the installed app and to open indexed content.
   Record whether it invokes a schema intent, presents results, or fails. Do not
   treat an existing user-authored shortcut being invoked as schema discovery.
5. With an indexed post visible, ask about that post. Test follow-up references
   and compare the optional Notes projection separately with the same content.
6. The target is a natural request returning actionable results inside Siri.
   Rendering an intent's card through diagnostic tooling alone does not pass.

Continue recording actual device evidence in the task list. Real-content and
Siri AI behaviour remain separate acceptance gates from the fixed proof.
