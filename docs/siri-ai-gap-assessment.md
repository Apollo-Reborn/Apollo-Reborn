# Siri AI and Spotlight: assessment and implementation sequence

Reviewed 2026-09-25 against Xcode 27.0 (27A266a), Apple's current documentation,
and the WIP merged with upstream `b92a722`. This document distinguishes source
implementation, historical test evidence, and behavior that still needs testing
on the real signed Apollo installation. Proposed limits below are starting
budgets, not measured performance claims.

## 2026-09-28 deep dive: Apple sample code patterns

Downloaded and read all five Apple sample projects for App Intents/Siri AI:
UnicornChat (messages, session 240), CometCal (calendar, code-along 344),
CosmoTunes (music/clock, session 343), PhotosDomainExample and
AppIntentsTravelTracking. Reddit posts have no schema domain (Messages requires
the whole send/draft/edit/unsend group; Browser/Reader/Journaling are
Shortcuts-only), so the canonical entities stay custom `IndexedEntity` types
reached through `.system.open`; the notes projection stays an opt-in experiment.

| Sample pattern | Where Apple shows it | Applied here |
| --- | --- | --- |
| Child content reached through parent + annotations, not indexed separately | UnicornChat `MessageRow`, blog note on attendees | New `ApolloCommentEntity` (plain `AppEntity`) + `OpenApolloCommentIntent` (`.system.open`); comment cells annotated |
| Lazily loaded large values | `LandmarkEntity.crowdStatus` (`@DeferredProperty`) | `ApolloPostEntity.loadedComments`: top 40 comments Apollo already loaded, from memory, never a network call |
| Header annotated with the container entity, rows annotated separately, single focus on `NSUserActivity` | CosmoTunes `PlaylistDetailView`, `NowPlayingView`, Photos `AssetDetailView` | Detail screen: post on its user activity only; `CommentsHeaderCellNode` annotated as the post; each comment row annotated |
| Annotate whatever is on screen | All samples | Memory-only `ApolloSessionContext` makes posts opened from links/inbox resolvable (previously required a captured listing) |
| Spotlight client state committed with the batch | CosmoTunes `CoreSpotlightWrapper` | `beginBatch` + `endIndexBatch(expectedClientState:newClientState:)`; mismatch (wiped/restored index) forces one rebuild |
| Donate from UI tap sites only; delete stale donations | CosmoTunes `DonationManager`, `IntentDonationManager` docs | Donation skipped when an intent drove navigation (10s window); donations deleted on hide/delete and on account/opt-out change |
| `requestValueDialog` on open targets | `OpenPlaylistIntent`, `OpenLandmarkIntent` | Post/subreddit/comment open intents |
| `numericFormat`, supported property types (`URL`, `Int?`) | TrailEntity, LandmarkEntity | Types have numeric formats; post adds link, score, comment count, linked site |
| Plain-text `DataRepresentation` alongside richer representations | LandmarkEntity, SongEntity | Post/comment export URL first, then full readable text |
| `IntentDialog(full:supporting:)` for voice-only devices | ClosestLandmarkIntent | Both post-result actions |
| `searchKeywords` in descriptions | CosmoTunes intents | In-app search intent |

Deliberately not copied: CosmoTunes uses `.system.search`, which the iOS 27 SDK
deprecates for `.system.searchInApp` (kept). Samples index into
`CSSearchableIndex.default()`, contradicting Apple's own "named index outside
prototyping" guidance (kept the named index). Apollo inbox notifications are
delivered by the remote push service, so the notification `appEntityIdentifiers`
pattern has no local hook yet.

Privacy scope of the new context: gated by the same content opt-in and account
fingerprint; public, non-NSFW, non-hidden posts only; deleted/removed comments
excluded; memory-only (50 posts, 5 threads × 500 comments), cleared on account
change, opt-out, hide/delete; never persisted, indexed or logged.

Device test additions (with indexing on):

1. Open a post from a link (not a feed), ask "what is this post about?". Log:
   `Owned activity annotated` without a prior listing capture.
2. On a thread, scroll so only a few comments show, ask "what are people saying
   in the comments?" — compare against comments not on screen. Logs:
   `Loaded comments added to session context count=…`.
3. Ask "send this comment to <contact>" while one
   comment dominates the screen; expect its text and reddit.com link.
4. Open a post from Siri ("open <post>"), then check logs show
   `Donation skipped; navigation came from an intent`.

## 2026-09-28 best-practice alignment

Re-checked against Apple's current App Intents documentation ("Apple Intelligence
and Siri AI", "Making app entities available in Spotlight", "Providing contextual
cues", "Displaying static and interactive snippets", the `.system` search/open
schema pages) and WWDC26 sessions 240/343/344. What the docs settle:

- **Siri acts only through schemas.** Apple Intelligence builds its toolbox from
  schema intents/entities and uses only schema-defined properties. The custom
  `SearchApolloPostsIntent` card has no schema and will not be chosen
  conversationally; there is no public "return search results" schema. Stop
  treating that as a routing bug.
- **`searchInApp` is navigation by contract** ("navigates to search results",
  implemented as a `ShowInAppSearchResultsIntent`). "Find posts about X in
  Apollo" opening native search is the correct, documented outcome.
- **In-Siri results come from the Spotlight semantic index.** "Apple Intelligence
  uses the semantic search capabilities of Spotlight to find your app's content,
  even when someone describes it vaguely," then presents entities with their
  `DisplayRepresentation` and opens them via the entity's `OpenIntent`. That is
  the Things mechanism. Test phrasing must ask about content, not ask to search.
- **Snippets are not guaranteed in Siri AI:** "the system might not display
  IntentDialog or ShowsSnippetView." `SnippetIntent.reload()` *presents* a snippet
  when absent and dismisses others, so never call it from generic refresh paths.
- **Use `indexingKey`/synonyms** so the semantic index gets structured text and
  spoken aliases; **make entities `Transferable`** for cross-app requests;
  **honour targeted `reindexEntities(for:)`**; **donate** real user actions
  through schema intents via `IntentDonationManager`, sparingly.

Implemented in this pass:

| Change | Why |
| --- | --- |
| Proof `OpenApolloProofSubredditIntent` no longer `.system.open`; proof entity renamed and removed from the default index | A second subreddit open action whose query only matched r/ApolloReborn competed with the real one — the most likely cause of "open boutiquebluray" falling through to search. Intent type/parameter IDs kept for existing shortcuts |
| Community display title (`t5.title`) stored as `displayTitle`; used for `DisplayRepresentation.synonyms`, `alternateNames`, keywords and local spoken matching | Siri hears "Boutique Blu-ray", not "boutiquebluray"; the bridge already forwarded the field |
| `TypeDisplayRepresentation` synonyms (Post/Thread, Subreddit/Community/Sub); "Subscribed Subreddit" → "Subreddit" | Matches how people name the type |
| `@Property(indexingKey:)` for post text/date and community description | Documented path into the semantic index |
| `Transferable` on post (HTTPS permalink, then title+link text) and subreddit (permalink) | "Send this post to …"; never exports `apollo://` |
| `SearchApolloProofIntent` explicitly `ShowInAppSearchResultsIntent` with `.general` scope | Matches Apple's schema template |
| Incremental Spotlight publication with a persisted SHA-256 checkpoint; batched upserts; no delete-and-rebuild on each launch; targeted reindex | Addresses finding 3 below; full rebuild only on scope/projection change or system reindex-all |
| Removed `SnippetIntent.reload()` from refresh/suppress; suppress/experiment toggle revalidate bindings instead of `clear()` | Finding 5 and 7 below |
| Detail-view open donates `OpenApolloPostIntent` once per post view | Behavioural signal for Apple Intelligence |

Revised device test (after install, indexing on, browse, refresh subscriptions):

1. "Open Boutique Blu-ray in Apollo Reborn" and "Open the boutiquebluray subreddit
   in Apollo" — expect `Query started: Subscribed subreddit …` then
   `Open subscribed subreddit action started` in the log.
2. Content retrieval, not search: "Show me the Apollo post about <distinctive
   words from a post you scrolled past>", "What was that Reddit post about
   <topic> I saw in Apollo?" Expect Siri-presented post entities; tapping one
   runs `Open post action`.
3. "Search Apollo for mechanical keyboards" — native search (by design).
4. In a post: "Send this to <contact>" — expect the reddit.com link.
5. Spotlight: search a community by display title (e.g. "Boutique Blu-ray").

## Recommendation

Keep one canonical content model for posts and communities, with a bounded local
catalogue feeding Spotlight, App Entity queries, result snippets, and onscreen
annotations. Separate explicit live searches from persistent indexing. Add
cross-app text/URL transfer before expanding into mutations.

The largest uncertainty is conversational Siri discovery, not SwiftUI rendering.
Apple's public domains cover system search/open, but have no Reddit/social-post
domain. Browser and Reader schemas are explicitly Shortcuts-only. A custom
App Intent appearing in Shortcuts does not establish arbitrary natural-language
Siri support. These distinctions follow Apple's [schema catalogue][domains].

The existing Notes projection is useful as an isolated experiment, but do not
make it the production identity of Reddit posts based on compilation alone.
Test whether it improves actual queries and whether Siri incorrectly treats
other people's posts as editable personal notes. Preserve the existing opt-in
experiment while collecting that evidence.

## What the comparison apps demonstrate

[Things][things] integrates Spotlight content with Siri and supports conversational
follow-ups. Its own release notes describe limits around dates, lists, and
system-selected results. [OmniFocus][omni] maps its tasks/projects/folders onto
the Reminders model; its announcement explicitly describes capabilities Siri
still cannot understand. These are strong examples of supported schema adoption,
not evidence that every arbitrary app action becomes conversational.

The [linked App Schemas article][article] points to Apple's
[CometCal code-along][codealong]. That is the useful implementation pattern:
typed entities, donated content, correctly shaped actions, and view annotations.
Its Calendar schema fits calendar data; that does not establish the right schema
for Reddit. API conclusions here use Apple documentation and the installed SDK.

## Capability coverage

| Experience | Current WIP | Gap / recommended next step |
| --- | --- | --- |
| Spotlight communities | Stable entities, queries, explicit five-page subscription refresh | Real-account verification; favorite/selected communities; refresh freshness independent of post expiry |
| Spotlight posts | Eligible loaded listings; 1,000 posts, 30 days, public/non-NSFW only | Subscription-aware collection and bounded seeding; incremental disk/index updates |
| Semantic content retrieval | Title/body metadata reaches Core Spotlight | Local `records(query:)` is substring matching, not semantic retrieval; evaluate actual Spotlight recall independently |
| Siri opens a post/community | `.system.open` intents and native routes | Warm/cold Spotlight activation and spoken references on final signed bundle |
| Siri searches inside Apollo | `.system.searchInApp` opens native search | No returned card on this path; current schema is specifically navigation to in-app results |
| Search with SwiftUI card | Custom `SearchApolloPostsIntent`, ten output entities, three visible rows | Arbitrary conversational selection of this action unproven; explicit App Shortcut phrase is a separate route |
| Follow-up conversation | Stable result identities exist | Test "open the second one", refinement, and return-to-results; add typed actions where useful |
| Onscreen post context | Large/compact feed nodes plus post detail activity annotated | Cold detail-only content, gallery, comments, community screens, modal and reuse lifecycle |
| Cross-app content | No `Transferable` implementation on content entities | Export canonical HTTPS URL and readable text; validate "send this" and "remind me about this" |
| Save / unsave / subscribe / vote | No Siri intents for these operations | Implement explicit typed App Intents and card controls; free-form Siri support needs a matching public contract or demonstrated behavior |
| Compose / reply / chat | No integration | Later feature; drafts, recipient/target disambiguation and reviewed send; do not force public posts into messaging schemas |
| Visual Intelligence | No value query | Optional screenshot/camera search destination using `IntentValueQuery`; separate from Apollo's own onscreen context |
| Action button / Shortcuts / Spotlight actions | Five App Shortcuts, including proof actions | Product naming, useful entity parameters and localized phrases while preserving existing identifiers |
| Proactive suggestions | Shortcut registration, no action-donation policy | Donate meaningful user actions sparingly; do not create a shortcut for every indexed post |
| In-app conversational search | Not implemented here | Optional later `SpotlightSearchTool` + Foundation Models feature; not a mechanism for registering an action with Siri |
| Distribution and older OS versions | Manually injected iOS 27 framework; standard tweak retains iOS 14 | Production packaging, final bundle-ID metadata, signer preservation and version-gated loading |

Apple documents [interactive snippets][snippets], [onscreen annotations][context],
and [Visual Intelligence][visual] as distinct integration surfaces. The
[Siri overview session][siri-session] also demonstrates entity content transfer.
Its testing sequence is useful here: intent execution, Shortcuts, Spotlight,
then complete Siri interactions.

Apple's [SpotlightSearchTool session][llm-search] covers retrieval and reasoning
inside an app's Foundation Models session. It can reuse this catalogue later,
but should not be confused with Siri's schema-based discovery of Apollo actions.

Do not add unrelated new APIs simply to complete a checklist. For example,
Apple's [RelevantEntities][relevance] contexts currently target audio/workout
suggestions; they are not a general subreddit recommendation channel.
Cross-device identity/ownership and long-running execution matter only once a
specific workflow requires them. Reddit IDs already provide stable domain IDs;
account eligibility must still be checked at execution time.

## Source findings that affect the design

1. **Search and the Siri card are separate actions.**
   `siri/Sources/SearchApolloProofIntent.swift` adopts `.system.searchInApp` and
   calls native navigation, returning no results or snippet.
   `Content/SearchApolloPostsIntent.swift` returns entities and a `SnippetIntent`
   but has no schema. Preserve both existing type names and App Shortcut phrases.
   Apple's [searchInApp contract][search-schema] is navigation; do not silently
   repurpose it into a background-only search service. An experiment may add a
   result card while retaining navigation, but whether Siri displays it must be
   measured. The installed public Swift interface confirms `.system.search` is
   deprecated in favor of `.system.searchInApp`; no general public background
   Reddit-search schema was found.

2. **The catalogue is not subscription-scoped.**
   `ApolloContentRecord.parse` checks subscription state for community records
   only. All eligible post listings can enter through
   `ApolloSiriCaptureListing`, regardless of community membership.
   `refreshSubscriptions()` fetches community metadata, not posts. Unsubscribing
   suppresses the community record, not its posts. Introduce source provenance
   and explicit collection eligibility before describing this as an index of
   subscribed posts.

3. **Bounded storage still performs repeated whole-store work.**
   `ApolloContentCatalog.ingest` copies state, prunes/sorts, and atomically encodes
   the whole JSON snapshot for every payload. The 500 ms coalescing in
   `ApolloContentService.scheduleSync` applies to Spotlight work, not these disk
   commits. `publish` sends all retained entities each time; `resetIndex` starts
   true every process, causing delete/rebuild on the first synchronization.
   Both per-ID reindex methods ignore their identifier argument and rebuild all
   content. No timing measurements currently justify calling this fast at scale.

4. **Explicit search requires permanent indexing.**
   `liveSearch` calls `enabledAccount`, persists fetched matches, and resolves
   card rows from the catalogue. Disabling content indexing therefore prevents
   a live result card. Use a bounded temporary search-result store, scoped to the
   current account/session. Let the indexing policy independently decide what,
   if anything, enters persistent storage.

5. **Onscreen context depends on already captured catalogue rows.**
   `ApolloOnscreenBridge.update` resolves via `snippetRecords`; a directly opened
   uncaptured post cannot be annotated even though it is visible. Comments have
   no separate entity. The suppression path calls `clear()`, which removes all
   view bindings; the subsequent `refresh()` cannot reconstruct those bindings.
   Feed rows that remain visible need rebinding or selective invalidation.
   Audit modal coverage and background transitions as well as view exit: a view
   remaining in a window does not by itself mean it is the relevant foreground
   context. Avoid repeating account resolution from every detail layout pass.

6. **Annotations alone do not export content.**
   The post entity has title/body/author fields but no transferable public URL or
   text representation. Add these using Apple's supported transfer contracts.
   Use HTTPS Reddit permalinks for sharing; retain `apollo://` for local native
   navigation. Capture post excerpts honestly: the current body limit is 2,048
   characters, and outbound article content/comments are not in the catalogue.

7. **Snippet redraws have a good foundation, but lifecycle needs tightening.**
   `ApolloPostResultsSnippetIntent` reads stored records without repeating network
   searches; retain this behavior. `ApolloContentBridge.refresh` calls the static
   snippet `reload()` for every observed defaults/activation event. Apple's
   [snippet lifecycle documentation][snippets] says reload can present a snippet
   when absent and dismiss another snippet. Scope reloads to the relevant
   presentation and test defaults changes outside a search. The existing views
   use semantic fonts and proper intent buttons; improvements should focus on
   actionable content, an "Open results in Apollo" control, explicit cached/live
   status, and real Dynamic Type/VoiceOver verification.

8. **Packaging success and conversational discovery are separate gates.**
   `scripts/inject-siri-proof.sh` extracts host-level metadata and phrase assets
   for the final bundle ID; preserve that approach. The framework requires iOS
   27 and is not included by a normal `make package`. Hostless tests hardcode
   `com.christianselig.Apollo`, while the historical phone build uses
   `com.jte.ApolloReborn`; parameterize the test target. The historical
   AppIntentsTesting service entitlement failure remains unverified on the
   current toolchain; use the existing real-app UI runner if it persists.

## Performant indexing architecture

### Collection and refresh

Start with all eligible subscribed communities and a rolling sample of posts,
rather than fetching every subreddit on a timer. Initially keep the existing
1,000-post / 500-community bounds until measurements support raising them.
Keep post expiry at 30 days initially; independently refresh community membership
so a still-subscribed community does not vanish merely because it was not opened.

Capture already received subscribed-feed responses first, adding zero requests
to scrolling. An explicit initial refresh can reuse an authenticated home/feed
listing through Apollo's client. Proposed budget: at most three 100-item pages,
one request in flight, cancellation on scope changes, and a persisted next-refresh
time. This is a sample, not exhaustive coverage. A busy home feed favors popular
communities, so use a small rotating allocation for selected/favorite communities
if measurements show poor coverage. Count those requests inside the same budget;
do not multiply the budget by subscription count.

Reuse Apollo's account/token and rate-limit management. Give foreground browsing
priority; back off on network failures and throttling. Begin with explicit refresh
and budgeted foreground opportunities. Background refresh can be added after
validating host registration and scheduling on the signed app, but freshness
must not depend on guaranteed periodic iOS execution.

Track why a record exists: subscribed-feed sample, explicitly saved/read content,
or temporary search result. Only the first is enabled by the subscription-index
policy; saved/read history can be separate opt-ins. Unsubscribe removes that
source, preserving a record only if another enabled source still justifies it.
Hidden/deleted/ineligible records override all collection sources.

### Persistence and Spotlight projection

Keep a serial owner for data mutations and enqueue bounded immutable payloads
from the native hook. Verify the parser callback thread and keep expensive work
off the main thread. A bounded queue must preserve removals and account changes
even when ordinary capture batches are coalesced or dropped.

At the current scale, first add dirty-record tracking and batched commits to the
JSON store; replacing it with SQLite is not itself a performance result. Measure
this implementation at its caps. If larger coverage is needed, migrate to SQLite
with incremental transactions, indexed lookups, and optional FTS, preserving IDs.
Either backend should maintain an outbox of changed and removed IDs, content
revision/hash, account generation, and successful publication checkpoint.

Publish only changed records in bounded batches. Acknowledge the outbox after
Core Spotlight completes; replay safely after interruption. Handle record expiry
updates with a deliberate cadence instead of treating every repeated observation
as a reason to republish all text. Complete privacy/account invalidations promptly,
with a generation check preventing late old-account writes. Use full rebuild only
for actual recovery/migration; honor the requested IDs for targeted reindexing.
Apple provides [IndexedEntityQuery][reindex] for system-requested recovery.

Store normalized titles, short selftext, author, subreddit, canonical URL, dates,
and source eligibility. Avoid full comment trees, crawled linked articles, media
downloads, or an embeddings pipeline in the scrolling path. Core Spotlight is the
system search projection; the local store remains authoritative for resolution,
deletion, and source text.

### Proposed measurement gates

- Zero extra network requests from feed scrolling or snippet redraws.
- One bounded storage transaction per coalesced capture burst; unchanged content
  does not cause repeated full Spotlight publication.
- At 1,000 posts / 500 communities, record p50/p95 ingestion, local lookup, bytes
  written, RSS, and number of Spotlight upserts/deletes. Test repeated identical
  pages as well as new data and deletion storms.
- Initial engineering targets: under 2 ms main-thread capture overhead and under
  50 ms warm local-query p95 on the supported test phone. These need measurement;
  Spotlight scheduling/semantic processing is external to the app's latency.
- Scrolling traces show no new hitches; scope changes, cancellation, failed index
  publication and app termination cannot revive removed records.

## Implementation order and acceptance

| Order | Work | Acceptance evidence |
| --- | --- | --- |
| 1 | Establish real Siri/Spotlight baseline with final signed bundle; parameterize test bundle ID | Real public post/community opens from Spotlight warm and cold; record exact Siri utterance, chosen action, result entities and presentation |
| 2 | Separate temporary live results from indexing; add text/URL transfer; fix annotation/reload lifecycle | Search card works with indexing off; no durable capture in that mode; "send this post" exports correct content; hide one row preserves other visible bindings |
| 3 | Add subscription provenance, budgeted seeding, dirty-record persistence/index publication | Subscription-scoped sampling, strict request budget, unchanged-page cost, unsubscribe and account-switch race tests |
| 4 | Complete card and onscreen coverage | Card row/open-all actions, readable light/dark/Dynamic Type states; direct-link detail, feed, gallery and comments contexts tested independently |
| 5 | Expand typed actions and discovery experiments | Save/unsave/open subreddit/prepare reply work through explicit actions; report which natural Siri phrases actually resolve; canonical vs Notes test uses identical data |
| 6 | Package supported feature and optional integrations | Final-ID metadata survives signing/update, normal iOS 14 build remains valid, version gates verified; Visual Intelligence only after core flows pass |

For phase 1, test these separately: exact App Shortcut phrase, a free-form search
request, Spotlight lookup, "open the second one", "what is this post about?",
and cross-app sharing. Repeat with app terminated, indexing disabled, account
changed, and no network. Record whether Siri returns a custom card, its own
presentation, or opens Apollo. A successful Shortcuts run cannot substitute for
this evidence; neither can a framework load log.

Keep new network and write actions explicit. For future posting/replies, create
a reviewable draft before submission, preserve pending compose UI, and account
for intent retries. Do not promise public Reddit actions are covered by Apple's
messaging schema simply because their payload contains text.

## Verification in this review

- WIP checkpoint: `d523e19` on `feature/siri-spotlight-integration`.
- Upstream integration: `4523dc9`, merging all 39 commits through `b92a722` with
  no conflicts. Local `main` fast-forwarded to the same upstream commit.
- `bash scripts/test-siri-catalog.sh`: all 37 assertions passed.
- Release `ApolloSiri` framework build for `iphoneos`: passed with Xcode 27.
- `make package`: passed; package `com.apollo.reborn_3.8.0-1+debug_iphoneos-arm.deb`.
  Existing upstream availability warnings remain in gallery/navigation/settings
  code; this was a successful build, not a warning-free compatibility audit.
- No new device or Siri execution was performed in this review. Historical
  simulator/card evidence remains in [the implementation log](siri-spotlight-task-list.md).
- This review adds a roadmap, not implementations of the gaps above. The unrelated
  untracked worker dependency documentation was left untouched and uncommitted.

[domains]: https://developer.apple.com/documentation/appintents/app-schema-domains
[things]: https://culturedcode.com/things/blog/2026/09/things-for-os-27-and-siri-ai/
[omni]: https://www.omnigroup.com/blog/ready-for-os-27
[article]: https://blakecrosley.com/blog/app-schemas-siri-ios-27
[codealong]: https://developer.apple.com/videos/play/wwdc2026/344/
[siri-session]: https://developer.apple.com/videos/play/wwdc2026/240/
[search-schema]: https://developer.apple.com/documentation/appintents/appschema/systemintent/searchinapp
[snippets]: https://developer.apple.com/documentation/appintents/displaying-static-and-interactive-snippets
[context]: https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri
[visual]: https://developer.apple.com/documentation/appintents/app-schema-domain-visual-intelligence
[relevance]: https://developer.apple.com/documentation/appintents/donations-and-discovery
[reindex]: https://developer.apple.com/documentation/appintents/indexedentityquery
[llm-search]: https://developer.apple.com/videos/play/wwdc2026/246/
