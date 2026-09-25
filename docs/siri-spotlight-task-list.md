# Apollo Siri & Spotlight implementation

Started: 2026-09-19. This is an integration in the real sideloaded Apollo app,
not a standalone test app. Existing automation runners may drive Apollo.

2026-09-25 review: WIP preserved on `feature/siri-spotlight-integration` and
merged with all 39 upstream commits through `b92a722`. See the
[Siri AI gap assessment](siri-ai-gap-assessment.md) for the current capability
matrix, subscription-index design, performance gaps, and prioritized next work.
The implementation/evidence checkboxes below remain historical; the assessment
does not mark unverified Siri behavior as complete.

2026-09-25 device feedback and acceptance target:

- User confirmed a real indexed post appears in Spotlight and opens correctly.
- Subreddit Spotlight lookup returned nothing. Reproduced locally with Reddit's
  native community `over18` field: the bridge omitted it and the catalogue
  incorrectly required the post field `over_18`. Corrected both and replaced the
  inaccurate community fixture; all 41 catalogue assertions, the device Siri
  framework build, and `make package` pass. Package: `3.8.0-2+debug`. This fix
  has not yet been installed on the phone.
- The intended Siri experience is a natural-language request producing an
  interactive card inside Siri, like the supplied Things example. A successful
  Shortcuts execution only validates the action/card implementation; it is not
  acceptance of conversational Siri integration. The user reported a prompt to
  enable shortcuts; its exact wording/context is still needed for diagnosis.
- Finish the current device baseline before reworking collection for unread/new
  posts from subscriptions, as agreed with the user.

## Approach

Persist a bounded catalogue of Reddit content, expose stable post/subreddit
App Entities, and project eligible records into Core Spotlight. Native Reddit
search remains the fresh/server-backed path. Reuse entity identities for result
snippets and onscreen context. Keep experimental schema representations separate
from canonical records; test behaviour rather than assuming Apple's intended
app categories are a limitation.

Normal release builds must retain the iOS 14 floor. The opt-in ApolloSiri
framework/test IPA remains iOS 27-only until back-deployment is designed.
Preserve installed Apollo data, saved shortcuts, and existing intent identifiers.

## 1. Foundation and native navigation

- [x] Inspect current packaging proof and document the implementation plan.
- [x] Replace browser-bound search URLs with native Apollo search navigation
      (implementation built; end-to-end navigation verification below).
- [x] Add a versioned, bounded, persistent post/subreddit catalogue with stable IDs.
- [x] Add deterministic tests for persistence, deduplication, search, retention,
      privacy filtering and account isolation.
- [x] Add capture of eligible content from Apollo's listing parser without
      crawling Reddit or creating extra requests during feed scrolling.
      Real-account capture verification is still pending.
- [x] Keep collection opt-in; provide disable/clear controls before collecting
      personal content. Never log credentials, post text or search terms.

## 2. Real Spotlight content

- [x] Add real subreddit and post entities backed by the persistent catalogue;
      preserve the proof entity/action identifiers for existing shortcuts.
- [x] Capture eligible loaded post/subscription listings; add an explicit bounded
      subscription refresh (five pages / 500 communities).
- [ ] Backfill favourites and saved/read history beyond observed listings.
- [x] Coalesce listing bursts into batched, ID-stable upserts and removal of
      evicted IDs. Current bounded snapshots are re-upserted; changed-record-only
      optimization is deferred.
- [x] Implement hide/delete/unsubscribe invalidation with persistent tombstones,
      expiry, clear/disable, account scoping and system-requested reindexing.
      Never erase unrelated legacy index entries; device lifecycle tests remain.
- [ ] Resolve indexed IDs after cold launch and open the native post/subreddit.
- [ ] Verify real post-title searches in Spotlight on the signed phone build.

## 3. Result snippets and live search

- [x] Add a read-only local post search action returning real entities and a
      compact result snippet with native open actions.
- [x] Add bounded live Reddit search through Apollo's existing client, handling
      authentication, cancellation, rate limits and empty/error results.
- [ ] Test Shortcuts, Spotlight action execution, and spoken/typed Siri separately.
      A successful Shortcuts card is not proof of Siri AI discovery.

## 4. Read-only schema experiment

- [x] Inspect shipping SDK contracts for a suitable schema-backed representation
      of posts (including notes if useful); no pretend write/delete capabilities.
- [x] Add an explicitly labelled, opt-in experimental adapter with separate IDs
      and an isolated index namespace. Only one representation indexed at a time.
- [ ] Compare canonical versus schema-backed entities using the same small set of
      public posts: exact title, paraphrase, subreddit, date and follow-up requests.
- [ ] Record discovery, returned IDs, snippets and inappropriate inferred actions.
      Keep or discard the adapter based on observed behaviour, not review policy.

## 5. Onscreen context

- [x] Implement current post/detail activity annotations with the active entity ID.
- [x] Implement visible feed annotations using UIKit's entity association APIs.
- [ ] Test “this post” and “the second one”, including reuse, scrolling and account
      changes. No stale context after leaving a screen.

## Verification and deployment

- [x] Discover existing phone automation runner; confirm device/runner identity.
- [x] Build the framework and normal Theos device package.
- [x] Run host-side catalogue tests.
- [x] Complete simulator navigation checks: warm Unicode search, cold spaced
      search, and a result-card tap to native Comments.
- [x] Package into Apollo; sign with ApolloSign. Use USB/Xcode installation as
      available, without uninstalling or wiping the user's Apollo data.
- [ ] Verify browsing, native search (including spaces/Unicode), warm/cold entity
      opening, real Spotlight results, disable/clear and account isolation.
- [x] Record evidence and limitations below; do not mark Siri behaviour passed
      solely from successful compilation or metadata extraction.

## Reference material

- [Things OS 27 launch](https://culturedcode.com/things/blog/2026/09/things-for-os-27-and-siri-ai/)
- [Drafts 54 launch](https://forums.getdrafts.com/t/drafts-54-released-os-27-ready-chat-console-improved-dictation/16991)
- [Apple: advanced App Intents integration](https://developer.apple.com/videos/play/wwdc2026/343/)
- [Apple: schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
- [Apple: LLM search using Core Spotlight](https://developer.apple.com/videos/play/wwdc2026/246/)

## Evidence / handoff

Before this work: user verified the fixed community snippet and native subreddit
opening on-device. Search still fell into Apollo's web viewer. No real post
catalogue, subscriptions indexing, or onscreen annotations were implemented.

2026-09-19 implementation notes:

- First store is a bounded, versioned atomic JSON snapshot, not a full Reddit
  mirror. Limits: 1,000 posts, 500 subscribed communities, 30-day retention;
  title/body limits and an 8 MiB disk bound. SQLite remains a future option if
  measured workloads outgrow this bounded store; stable IDs do not depend on it.
- `bash scripts/test-siri-catalog.sh`: 37 deterministic assertions passed,
  including suppression persistence, stale-response rejection, t5 alias recovery,
  fresh reallow, account isolation, retention and routing.
- Settings > Apollo Reborn > Privacy > Siri & Spotlight now provides enable/clear,
  status, subscription refresh and an explicitly labelled schema experiment.
  Shortcuts also exposes these core operations. Five stable App Shortcuts total;
  no new per-record shortcut donations.
- `IndexedEntityQuery` supports reindexing; entity-backed searchable items carry
  expiry. Account notifications clear old scope; unresolved identity fails closed
  without treating an unreadable account as a logout.
- Hide/delete/unsubscribe requests conservatively remove affected IDs immediately;
  persisted tombstones block stale listing resurrection. Successful unhide/subscribe
  permits fresh metadata, never restores old cached text. Complete subscription
  refreshes reconcile missing entries; truncated/failed refreshes do not.
  Real-device mutation observation remains unverified. Full saved/read-history
  and favourites backfill is not implemented.
- Search Apollo Posts uses the current native authenticated RDK client, one GET
  capped at 25 results, returning up to ten eligible entities and three visible
  snippet rows. Cancellation, a 20-second request timeout, rate-limit checks,
  concurrent-request rejection and account-change rejection are implemented.
  Authentication remains owned by Apollo; no credentials enter the catalogue.
- Snippet redraws are catalogue reads, not repeated searches or index writes.
  Native open buttons reuse canonical IDs. Onscreen annotations are limited to
  visible eligible records, invalidated on hide/account changes and view exit.
  These hooks compile; Siri's “this/second one” interpretation is not yet proven.
- Experimental notes projection is OFF by default, uses separate IDs and index
  namespace, and replaces (rather than duplicates) canonical post indexing.
  Apple's shipping SDK schema database and metadata validator confirmed the
  required note/folder/account contracts. Optional folders/accounts resolve empty;
  no write/delete intents are declared. Discovery quality remains an experiment.
- Existing phone runner recovered into an isolated ignored workdir and compiled
  using its existing identity. Phone connected via USB, but passcode-locked; no
  attempt made to bypass the lock or change device settings.
- Dedicated `Apollo-Siri-Content` simulator created, with the real Apollo app,
  embedded tweak and framework. First launch caught an off-main notification
  callback assertion; observers changed to explicit main-queue delivery. Corrected
  app launches with both tweak hooks and Siri framework confirmed in runtime logs.
- Actual Search App Shortcut now prompts when its criteria is empty. Reacquiring
  the system-owned text field fixed the runner's stale snapshot: warm `café iPhone`
  and cold `mechanical keyboards` executions both reached native results with
  exact queries, Search tab selected and no WebView. Evidence in ignored
  `.sim-siri-e2e.wOqs9s`: `NativeUnicodeSubmit.xcresult`, `NativeColdSearch.xcresult`,
  `native-unicode-result.png`, `native-cold-result.png`. No simulator credentials:
  routing passed, fetching actual Reddit results is not claimed.
- Actual Find Indexed Posts execution rendered two clearly synthetic post rows;
  a row tap opened native Comments, with the result card dismissed via Done.
  In-app settings showed two posts; switching indexing off and rerunning the action
  produced zero results. Evidence: `IndexedSnippet.xcresult`, `IndexDisabled.xcresult`,
  `indexed-snippet.png`, `indexed-native-destination.png`, `index-settings.png`,
  `index-disabled-result.png` in the same ignored workdir. Synthetic mode is compiled
  only into the simulator framework and never substitutes credentials or Reddit.
- Final settings test switched canonical → experimental notes → canonical with
  indexing enabled, then left both toggles off. `SchemaRoundTrip.xcresult` and
  `schema-round-trip-evidence` capture the status transitions. This used an empty
  catalogue; it verifies controls/mode synchronization, not discovery quality or
  removal/replacement of populated Spotlight search results.
- Actual Search Posts execution failed gracefully with indexing disabled, then
  with indexing ON and no credentials displayed “Sign in to Apollo before
  searching Reddit.” No crash or process replacement. `SignedOutLiveEnabled.xcresult`
  and `signed-out-live-enabled-evidence` capture the latter. Final simulator
  settings: indexing OFF, experiment OFF; runner sessions completed.
- ApolloSign signed the updated build and CoreDevice installed it in place on
  the connected phone as `com.jte.ApolloReborn`. No uninstall or data wipe.
  Signed artifact: `/Users/jordan/Developer/apollosign/output/Apollo-Reborn-signed.ipa`.
  Latest install: 2026-09-19, package `3.7.1-7+debug`, including result snippets,
  native fetch bridge, settings, annotations and experimental notes projection.
  SHA-256: `0c3a6c616a70a9557be90ddc218db2544b75df03c2412397c40494f5c2c19a3a`.
  Strict deep signature verification passed. Device tweak remains iOS 14 / SDK26;
  optional framework is iOS 27 / SDK27. Synthetic fixture strings are absent from
  the device framework. Final simulator PID 36222 logged framework load and sync.
  Phone launch, real-account capture and Spotlight verification remain pending
  because the device is passcode-locked. Content collection remains off by default.

## Next phone checks

1. Unlock and launch Apollo; confirm the existing account and browsing still work.
2. Run Search Apollo, supply a query, and confirm native results (not a browser).
3. In Apollo Reborn settings > Privacy > Siri & Spotlight, enable Index Apollo
   Content. Browse a public, non-NSFW feed, then Refresh Subscribed Communities.
   Check whether real post/community counts increase.
4. Search Spotlight for a distinctive loaded post title; tap its result. Repeat
   after terminating Apollo. Verify native post/subreddit destinations.
5. Turn indexing off; confirm zero catalogue counts and eventual removal of this
   integration's results. The old fixed community proof is intentionally separate.
6. With explicit user coordination, check account switching, hidden content and
   unsubscribe invalidation before enabling broader collection by default.
7. Run Find Indexed Posts and Search Posts separately; check snippets and native
   row navigation. Compare canonical versus Experimental Notes Schema discovery
   with identical public posts; test typed/spoken Siri and onscreen references.
