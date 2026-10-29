# Distribution

Releases after **4.0.x** require **iOS 26 or later** and use Liquid Glass. There
are two current products:

| Product | Release asset | Source | Internal stamp / manifest key |
| --- | --- | --- | --- |
| Apollo Reborn | `Apollo-Reborn-<version>.ipa` | `apps_glass.json` | `glass` / `glass` |
| Apollo Reborn No Extensions | `Apollo-Reborn-<version>-NOEXTENSIONS.ipa` | `apps_noext_glass.json` | `glass-noext` / `noExtensionsGlass` |

Both include the alternate icon catalog. The normal build includes widgets,
Safari extensions and Apollo's other working app extensions. No Extensions
removes all `.appex` bundles, including widgets, to reduce App ID usage.
Changing the public names does not change the app bundle identifier, source
identifiers, subscribed Glass source URLs or anonymous usage channel stamps.

Classic appearance, icons-only builds, older iOS and standalone rootful/rootless
jailbreak packages end on **4.0.x**. Those release assets remain available.
The internal rootful `.deb` is still built to inject the tweak into the two IPAs;
it is not a third current product. Debug symbols remain release assets.

## Build and verification

```bash
make package
scripts/build_release_variants.sh --ipa ./Apollo.ipa --deb ./packages/<tweak>.deb
scripts/validate_release_variants.sh ./dist/out
```

The release builder uses `cyan` for injection and `cyan -e` for No Extensions.
It builds the widget extension once, then composes each IPA in one patch pass:
backup document registration, ProMotion, Substrate repair, version stamping,
OAuth URL schemes, Liquid Glass binary/assets, and the variant stamp. The normal
build additionally receives the widget, Safari and Open in Apollo repairs.

Both the app's `MinimumOSVersion` and Mach-O minimum are **26.0**. Keep the
main executable's **SDK 27.1** stamp: it enables Glass and Duo's full-width
canvas. Raising the deployment floor does not justify lowering that SDK stamp.
The validator checks the actual executable, icon metadata, variant stamp,
extension contents, ProMotion and absence of extra/stale IPAs.

The device tweak build defaults to SDK 26.0 and deployment target 26.0. A local
newer device SDK can be selected with `APOLLO_DEVICE_SDK`. The simulator uses its
current SDK, deployment target 26.0 and Glass by default. Old SDK compatibility
workarounds and `--no-glass` are not supported in this line.

## Version metadata

`control` supplies the tweak/marketing version. `distribution/config.json`
supplies a strictly increasing `app.buildVersion`. The packaged IPA and source
JSON must agree exactly on both numbers. Release preparation updates those
numbers; this migration does not claim that an unpublished release exists.
Release preflight rejects 4.0.x versions on this branch. Prepare a **4.1+** version,
a matching changelog section and a new build number before shipping.

Historical `versions` entries retain their original build numbers, descriptions,
dates, URLs and OS requirements. Only new 4.1+ version entries declare
`minOSVersion: "26.0"`; do not apply that restriction to an entire source and
hide its older installable versions. The asset parser treats suffixless IPAs as
classic through 4.0.x and Glass from 4.1 onward.

## Source generation and legacy protection

`python3 scripts/update_source_json.py` runs only after stable assets have been
published. It verifies that the newest stable current release has both IPAs and
matches `control` before writing any source. Drafts, prereleases, partial asset
sets and stale metadata cannot replace the stable feed.

The first current publication:

1. Copies the two existing Glass source files into `distribution/legacy/` before
   updating them. These are snapshots of the final 4.0.x feeds, including history.
2. Keeps `release-manifest.json` on its existing legacy release and six variants,
   changing its Glass source links to those snapshots. Old clients still read
   this URL and do not understand minimum OS or retired variant rules.
3. Updates only the two active Glass sources and generates
   `release-manifest-v2.json` with schema 2, two variants, minimum iOS 26 and no
   standalone package downloads.

The four retired root source files are left untouched. Subsequent current
publications must not rewrite the snapshots, retired sources or legacy release.
The generator fails if an archive disagrees with the legacy manifest or a
previously published IPA would acquire a different build number.

The original manifest URL is deliberately not redirected to v2. A redirect or
an extra JSON field cannot teach an already-installed old parser to enforce an
OS floor: it reads the global release version first, even when its variant is
missing. Likewise, do not put a current global version beside old download URLs.

## In-app updates and existing subscribers

Current apps read `release-manifest-v2.json`. Its minimum OS is checked for
network results and persisted/304 cache results before an update is offered.
A missing retired variant or an unknown schema cannot inherit the global latest
version. Unstamped injected builds retain their limited, non-variant handoff.

Existing Glass source subscriptions continue at their original URLs. Their
sideloader can see current versions on supported iOS and historical versions
for older iOS. Verify this selection with the supported installers before release.
Old in-app updaters stay on the final 4.0.x feed; they do **not** automatically
learn the new endpoint. Use the final 4.0.x announcement and website to explain
migration. A retirement notice or eligible-Glass updater handoff can also be
backported to the 4.0.x maintenance branch before its final release.

The current update sheet retains the existing cadence, snooze/skip behavior,
release notes and sideloader chooser. See `src/ApolloUpdateChecker.m` and the
host harnesses under `tests/`.

## GitHub Actions

`release-ipa-variants.yml` and `pr-build-ipa.yml` build and validate the same two
IPAs. Public releases attach the two IPAs and matching dSYMs. The rootless build
and public `.deb` artifacts are retired; rootful injection remains internal.
The manual Build IPA workflow also always applies Glass and has no icons-only
or classic appearance option.

A non-draft main release regenerates sources inline. Publishing a draft through
the GitHub UI triggers `publish-sources.yml`. Both paths stage the active pair,
v2 manifest, protected legacy manifest and legacy snapshots. They must remain
aligned. Draft release assets never enter the stable sources.

## Installer source URLs

Use the existing raw GitHub URLs (or the site's configured source mirror):

```text
https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps_glass.json
https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/main/apps_noext_glass.json
```

AltStore Classic and SideStore use `source?url=<encoded-source-URL>` links with
schemes `altstore-classic` and `sidestore`. Feather uses
`feather://source/<source-URL>`. Direct install handoffs remain
`feather://install/<IPA-URL>` and `flarestore://downloadApp=<IPA-URL>`.
Apollo Reborn does not support AltStore PAL.

## Rollout

Follow [the sunset checklist](docs/ios26-sunset-rollout.md) before merging or
publishing. The website is a separate repository and must switch its chooser
and manifest consumer alongside the first current release.

## Hosted Base IPA

The release workflow consumes a public URL for a decrypted Apollo base IPA.
No R2 credentials are required. For a locally prepared, already-injected
`Apollo-base.ipa`, `build-ipa.sh` prefers the repo-local injector; `cyan` is needed
for the stock-IPA release flow.
