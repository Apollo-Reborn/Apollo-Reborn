# Siri & Spotlight (iOS 27, optional)

An opt-in App Intents integration that makes Apollo content available to
Spotlight and Siri on iOS 27. It ships as a separate `ApolloSiri.framework`
injected into Apollo; the normal Theos build, release workflows and the
tweak's iOS 14 floor are unchanged. Without the framework, the tweak-side
hooks in `src/ApolloIntelligenceBridge.xm` are no-ops.

## Packaging

Requires Xcode 27 (iOS 27 SDK) and XcodeGen. Build a normal Apollo Reborn IPA
first (see the root `AGENTS.md`), then:

```sh
scripts/inject-siri-proof.sh --ipa Apollo-Reborn.ipa -o Apollo-Siri.ipa
```

The output is an unsigned, iOS 27-only IPA; sign it with your usual signer.
The script extracts App Intents metadata for the IPA's bundle ID, so set the
final bundle ID before injecting. `--app <Apollo.app> --sdk iphonesimulator`
injects into a prepared simulator bundle in place.

## What it does

Everything is off until **Settings → Apollo Reborn → Privacy → Siri &
Spotlight → Index Apollo Content** is enabled.

| Feature | How |
| --- | --- |
| Spotlight posts and subscribed communities | `IndexedEntity` types in a named index, fed from listings Apollo already loads (no extra requests); explicit subscription refresh |
| Open from Spotlight / Siri | `.system.open` intents routed through Apollo's native URL router |
| "Search Apollo for …" | `.system.searchInApp` intent driving Apollo's native search screen |
| Onscreen context ("summarize this post", "send this to …") | Feed rows and the post header annotated with post entities; detail screen's `NSUserActivity` carries the open post; entities export HTTPS permalink + plain text |
| Shortcuts actions | Search Apollo Posts / Find Indexed Apollo Posts (interactive result card), indexing on/off, status, refresh subscriptions |

Eligibility: signed-in account only; public, non-NSFW, non-hidden, non-removed
posts; subscribed public communities. Bounded to 1,000 posts / 500 communities
for 30 days, scoped to a one-way account fingerprint, excluded from backups.
Hide/delete/unsubscribe removes content (with tombstones against stale
listings); account change or opt-out clears the index and intent donations.
Spotlight publication is incremental and committed with CoreSpotlight client
state, so an index wiped by the system triggers one rebuild.

## Known limitations

- Siri routes "open <subreddit>" to in-app search rather than resolving the
  community entity, and sometimes just opens Apollo without running an action.
  Logs show Siri never queries the subreddit entities in these cases.
- The interactive result card only appears via Shortcuts; Siri has no schema
  for "return search results" and may not display custom snippets.
- Comment context (`ApolloCommentEntity`, `ApolloPostEntity.loadedComments`,
  comment-row annotations) is implemented but comments do not currently reach
  the session store on device, so Siri only sees on-screen comments. Diagnose
  from the `CommentSectionController` capture in `ApolloIntelligenceBridge.xm`
  forward.
- No schema domain fits Reddit posts, so posts are custom entities rather than
  schema entities; Siri's handling of them is best-effort.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/Content/ApolloContentCatalog.swift` | Foundation-only persistent catalogue (parsing, eligibility, tombstones, retention) |
| `Sources/Content/ApolloSessionContext.swift` | Foundation-only memory store for opened posts and loaded comments |
| `Sources/Content/ApolloContentService.swift` | Actor owning the catalogue, session, Spotlight publication; ObjC bridge for the tweak |
| `Sources/Content/ApolloContentEntities.swift` | Post/subreddit/comment entities, queries, open intents |
| `Sources/Content/ApolloOnscreenBridge.swift` | View / user-activity annotations and UI-initiated donations |
| `Sources/SearchApolloIntent.swift`, `ApolloSiriNavigation.swift` | Native search and URL routing |
| `CatalogTests/` | Host-side tests: `bash scripts/test-siri-catalog.sh` |

## Debugging

All diagnostics use the `apollofix` subsystem with a `[Siri]` prefix and never
include content, IDs, search terms or account data. They appear in Apollo
Reborn → Advanced → Export Debug Logs (export before force-quitting). A
`Query started: …` line means a system surface asked for entities; it doesn't
by itself prove Siri used them.
