# iOS 26 / two-build sunset rollout

## Decision and rationale

After 4.0.x, Apollo Reborn supports iOS 26+ with one system appearance. The two
current downloads are Apollo Reborn and Apollo Reborn No Extensions. Both use
Liquid Glass and include alternate icons; extensions are the only product split.

Maintainer feedback is that the classic variants' usage does not justify the
cost of supporting and testing two UIKit appearances. Six release IPAs and a
runtime classic switch also multiply packaging, settings, documentation and
upgrade combinations. Keeping a classic switch inside the two new downloads
would retain that cost, so this change removes its startup overrides and the
classic-specific implementations they selected.

No telemetry percentage is asserted here. The heartbeat records packaging
variant and OS, not the active Glass/classic preference. Preserve old channel
values for historical installations and reports; current public names do not
require new `glass` / `glass-noext` technical IDs.

## Before merge

- Choose and publish the final **4.0.x** release from the existing supported
  code line. Keep that code/tag available for archived builds or an exceptional
  maintenance fix; do not apply this branch's iOS 26 floor to it.
- Let its source update finish on main before merging this PR. This branch
  intentionally does not edit generated `apps*.json` or invent future assets.
  The first current source update snapshots the final legacy state present at
  that time. If another 4.0.x patch ships first, rebase onto its source update.
- Put the cutoff and migration instructions in that release's What's New,
  changelog and announcement. Explain that Glass off and older iOS remain on
  4.0.x, that existing data is retained when updating with the same signed app
  identity, and that uninstalling is unnecessary. Recommend a backup first.
- Decide whether to backport a retirement-aware in-app notice/current-feed
  handoff to 4.0.x. Old shipped clients cannot learn a new URL from extra fields
  in their manifest; the protected old feed is the compatibility guarantee.

## Before the first 4.1+ release

- Prepare release metadata normally: `control` at 4.1+, strictly increased
  `app.buildVersion`, a matching release changelog and curated What's New.
  The release preflight deliberately refuses to ship this code as 4.0.x.
- In **apolloreborn-site**, change `main.js` to consume
  `release-manifest-v2.json` at both its source-domain and raw-GitHub fallbacks.
  Remove the Glass chooser and expose only the two current names.
- Update the installation wizard, wiki, README and FAQ. Remove the promise that
  every old variant gets the same updates. Derive current download links from
  the manifest, not hardcoded filenames.
- Provide a clearly labelled legacy download route for classic appearance and
  older iOS, pinned to the final 4.0.x release rather than `/releases/latest`.
- Verify the hosting/source mirror actually serves the new manifest and
  `distribution/legacy/` snapshots; these routes were not deployed by this PR.
  Keep the original manifest URL on 4.0.x, with no redirect to v2.
- Keep legacy telemetry/report channel values accepted. Since stamps stay the
  same, no new-channel backend rollout or history rewrite is needed.

## Release verification

Automated checks:

```bash
python3 -B tests/release_sunset_tests.py
bash tests/run_executable_sdk_tests.sh
bash tests/run_update_manifest_tests.sh
bash tests/run_update_manifest_cache_tests.sh
bash tests/run_update_checker_tests.sh
make package
scripts/build_release_variants.sh --ipa ./Apollo.ipa --deb ./packages/<tweak>.deb
scripts/validate_release_variants.sh ./dist/out
```

Manual gates:

- On iOS 26 and the current newer OS, test iPhone and iPad, light/dark, navigation,
  search/cancel, composer/keyboard, Inbox switcher, Gallery controls and themes.
  Include Duo's open/closed layouts; retain its SDK 27.1 executable stamp.
- Upgrade from a final 4.0.x Glass build with the same bundle/signing identity.
  Confirm API keys, accounts, settings, icon and extension choice survive.
- Upgrade/restore a backup whose old `LiquidGlassEnabled` value is false. No
  classic switch or compatibility override should return; Setup Assistant
  offers light/dark/system appearance only. The Classic *preference preset*,
  optional iPad layout and classic tab-scroll behavior remain separate features.
- Validate normal build widgets, manual/legacy Safari extensions and Open in
  Apollo. Validate that No Extensions has no `.appex` bundles.
- Check existing sources and new installs in AltStore Classic, SideStore and
  Feather: iOS 26 gets the current build; older iOS cannot install it and retains
  access to the final 4.0.x build. Check legacy snapshot imports where applicable.
- Verify old clients still read a legacy global version and matching old assets;
  current clients read two variants and enforce the minimum OS, including caches.
- Test both publication paths: non-draft dispatch and manually published draft.
  No source may advertise an unpublished asset, and no archived build number or
  historical OS requirement may change.

## Boundaries retained intentionally

`IsLiquidGlass()` now describes runtime/executable capability, not a preference.
Its remaining guards protect hosted apps or private UIKit hook installation.
Class/selector, accessibility, Reduce Transparency and layout checks are not
obsolete appearance variants. Native Apollo action sheets that still exist on
current iOS remain supported; the word "legacy" in such code does not imply an
archived distribution. Historical changelog entries are not rewritten.

No current standalone jailbreak packages are published. The rootful `.deb` is
still an internal injection intermediate and symbol source. A future supported
jailbreak product would require a separate packaging/design decision.
