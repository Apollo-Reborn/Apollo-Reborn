# Rich link card recovery

Run `tests/run_link_preview_overflow_tests.sh` for deterministic scheduling and
reload regressions. It extracts the shipping functions and uses UIKit doubles;
it does not measure device scrolling performance or exercise Texture itself.

## Texture initialization regression

On a cold launch, verify `LinkButtonNode`'s `layoutDidFinish` implementation points
to the tweak after Texture has initialized the class, rather than Texture's
`StubImplementationWithNoArgs`. Verify `didEnterVisibleState` on both
`LinkButtonNode` and `LinkButtonTweetInfoNode` as well. Trigger an applied layout
and visibility transition to confirm the hooks execute.

`ASDisplayNode` adds missing lifecycle methods to itself in `+initialize` using
`class_addMethod`; it does not replace existing hooks. Initializing before `%init`
makes those inherited methods available to the simulator's internal Logos
generator, which otherwise skips selectors absent from the method lists.
This corrects simulator hook installation, not a demonstrated device hook failure.
Simulator captures from before this initialization change are not an equivalent
comparison with device behavior.

## Simulator and physical device

1. Open Home with uncached website, Twitter, and Bluesky previews. Let compact
   placeholders become full cards. Metadata and controls must remain below the
   cards without opening a post and returning.
2. Scroll rapidly in both directions while previews load, then stop. Cards must
   stay inside their allocated bounds and resize during scrolling,
   without repeated flickering or row reloads. Deferred reloads for other overlap
   cases must still wait for a settled layout.
3. Repeat refreshes and revisit cards. Later growth must still recover when a
   node is retained, and a reused index path must not reload an unrelated post.
4. Repeat with large accessibility text, rotation, and animated transitions.
   An overlap that resolves before the deferred reload must not reload the row.
5. Confirm menu controls work and healthy cards do not repeatedly reload. Profile
   main-thread work on a physical device with many link cards before merging.
6. In a comment thread, repeat with the post header and comments containing one
   or multiple links. In Full mode, a single link may grow from compact after
   attachment; multiple eligible links must retain their compact layout.
7. Vote, collapse/expand, scroll away/back, and reopen that thread repeatedly.
   Controls must stay clear, cards must settle at the correct height, and neither
   healthy layouts nor canceled growth may cause repeated resizing or reloads.

## Validation recorded for PR #1191

- Host regression checks: 32 passed, including unchanged layouts, child growth
  with a fixed host height, retained nodes, budget expiry, scrolling, animations,
  corrected overlap, footer overlap, offscreen cancellation, row replacement,
  exceptions, collection batch completion, and coalesced feed-size updates during
  scrolling with cancellation and reattachment.
- Simulator build passed. The NASA Far-Infrared Telescope post naturally reproduced
  the overlap in Home: a 104pt host contained 294.67pt content until scrolling stopped.
  The revised build passed a controlled cold-load/offscreen-entry check on the same
  card, with clipping enabled and no painted footer overlap in 768 sampled frames.
  The controlled replay did not reproduce the natural failure's full duration.
- Runtime inspection confirmed the installed `layoutDidFinish` implementation
  belongs to the tweak after Texture initialization.
- Local device packaging reached linking but failed on Apple's Translation Swift
  symbols with the current SDK/toolchain; no device-build pass is claimed.
- Physical-device validation remains pending: a paired iPhone was available,
  but the Mac had no valid signing identity for installing this build.

## Hosted-cell follow-up validation

- Simulator build and all 78 host regression checks passed. The runner now
  extracts the shipping ownership and invalidation helpers as well as the
  scheduler. It covers comment/header/feed cells in both containers, membership
  checks outside layout, multiple links, canceled growth, and reattachment.
- A separate iOS 27 simulator fixture called the built helper with real Texture
  table and collection cells. Two children grew, shrank, and expanded the rows
  through 160/340/80/340pt; footers stayed within the rows. Each pair of child
  invalidations produced one queued measurement, with none during the helper
  call. Unhosted and unregistered cells were rejected.
- That fixture used generic `ASCellNode` subclasses and reported dragging through
  a test override. It did not exercise Apollo comment rendering, actual scrolling,
  or voting. Real-thread single/multi-link voting and collapse/expand checks,
  and physical-device validation, remain pending.
