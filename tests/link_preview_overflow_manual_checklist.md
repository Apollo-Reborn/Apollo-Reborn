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

Texture installs inherited lifecycle stubs in `+initialize`. Initializing the two
classes before `%init` prevents those stubs from replacing the Logos hooks.
The simulator's internal hook generator and the device's Substrate generator
both need this check.

## Simulator and physical device

1. Open Home with uncached website, Twitter, and Bluesky previews. Let compact
   placeholders become full cards. Metadata and controls must remain below the
   cards without opening a post and returning.
2. Scroll rapidly in both directions while previews load, then stop. Recovery
   should wait for scrolling to settle, without repeated flickering or reloads.
3. Repeat refreshes and revisit cards. Later growth must still recover when a
   node is retained, and a reused index path must not reload an unrelated post.
4. Repeat with large accessibility text, rotation, and animated transitions.
   An overlap that resolves before the deferred reload must not reload the row.
5. Confirm menu controls work and healthy cards do not repeatedly reload. Profile
   main-thread work on a physical device with many link cards before merging.

## Validation recorded for PR #1191

- Host regression checks: 23 passed, including unchanged layouts, child growth
  with a fixed host height, retained nodes, budget expiry, scrolling, animations,
  corrected overlap, footer overlap, offscreen cancellation, row replacement,
  exceptions, and collection batch completion.
- Simulator build passed. iOS 27 Home cold-cache website preview loaded with its
  controls below it. Runtime inspection confirmed the installed `layoutDidFinish`
  implementation belongs to the tweak after Texture initialization.
- Physical-device validation remains pending: a paired iPhone was available,
  but the Mac had no valid signing identity for installing this build.
