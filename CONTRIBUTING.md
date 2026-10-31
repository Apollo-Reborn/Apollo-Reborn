# Contributing

This project is an iOS tweak built with [Theos](https://theos.dev/) and [Logos](https://theos.dev/docs/logos-syntax.html). Development relies heavily on reverse engineering Apollo's binary, so an AI-assisted workflow with MCP (Model Context Protocol) tools can be super helpful.

## Pull Request Rules

These apply to pull requests from anyone outside the core team (anyone without write access to this repo).

Using AI to write a change is fine; this repo's own [AGENTS.md](AGENTS.md) is written for it. What we can't take is a fix nobody ran: a guess at a bug you never saw, or a change you never tried in the app. Those take longer to review than to write, and they tend to ship new bugs. So every PR needs:

1. **A linked issue.** Put `Closes #123` in the description. If there's no issue yet, open one first. For a feature, a refactor or a big change, wait for a maintainer to agree on the issue before you build it.
2. **A reproduction (bug fixes).** You saw the bug yourself on current `main` (or the latest release) before changing anything, and the PR lists the steps. If you can't reproduce it, say so on the issue instead of opening a PR with a guess. For a feature, list the steps to try it instead.
3. **Before and after media.** A screenshot for a layout or color change, a screen recording at normal speed for anything that moves or happens over time: first the bug on current `main`, then the same steps with your change. A feature needs the after; a refactor has nothing to show, so it says how you checked that nothing changed instead. Drag media into the PR description; don't commit it to the branch.
4. **Testing on a range of devices.** An older or smaller iPhone (say an SE or 13 mini on iOS 17 or 18), a newer or larger iPhone (a Pro Max on iOS 26 or 27), an iPad, and the iPhone Duo, across both the Standard and the Liquid Glass build. Simulators count, including the iPhone Duo simulator (Xcode 27.1 or later); see [Testing in the iOS Simulator](#testing-in-the-ios-simulator). Say which you used. Both iPhones are always needed; if the change can't affect iPad or iPhone Duo (say, a network-only fix), write `N/A: <why>` for that row instead of making up a result.
5. **A person tried it.** Changes to animations, transitions, gestures, scrolling, media playback, haptics or keyboard behavior must be tried by a person, not only checked through an agent's screenshots. Gestures, scrolling performance, audio and haptics need a physical device. If you can't test on a device, say so: the PR can still be reviewed, but it won't merge until someone has (one of us, or a tester using the PR's test IPA).
6. **A passing device build.** `make package` has to pass on current `main`. The simulator build compiles less, so a change can pass there and still break the release.
7. **One change per PR,** with no unrelated changes, and nothing in the branch but the change: no screenshots, videos or build output.
8. **You can explain every line.** Reviewers will ask why a change is there.

The [pull request template](.github/pull_request_template.md) has a section for each of these; tick whether your PR is a bug fix, a feature or a refactor, and it tells you which ones apply. When you open a PR, a bot checks it. If anything is missing, it closes the PR with a comment listing what to add; edit the PR description to add it and the PR reopens on its own. Drafts aren't checked until you mark them ready for review, and PRs that only change docs are skipped.

A few more things:

- **Several PRs at once.** Separate fixes go in separate PRs, but each one says whether it depends on or conflicts with your others. Stack a PR on another only as a last resort: it still targets `main`, its description starts with "Depends on #N (stacked; the new work is the last K commits)", it stays a draft until the parent merges, and you rebase it yourself.
- **Batch your pushes.** Each push to an outside PR needs one of us to approve its test build, so push fixes together rather than one at a time.
- **Don't edit `CHANGELOG.md`.** Release notes are written from PR descriptions at release time.
- **Never commit** settings backup zips (they contain live account credentials), API keys, or Apollo binaries and IPAs.

Repeatedly opening PRs that skip these rules can get you blocked from the repo.

## Getting Started

```bash
# Clone and init submodules
git submodule update --init --recursive

# Build
make package
```

**Required SDK.** Device `make package` defaults to `iphone:clang:26.0:14.0`, preserving iOS 14 support even when newer SDKs are installed. CI selects Xcode 26.0.1, which includes this SDK. On a Mac with newer Xcode, install a genuine 26.0 SDK under Theos:

```bash
cp -R "/Applications/Xcode_26.x.x.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk" \
      "$THEOS/sdks/iPhoneOS26.0.sdk"
```

Prefer extracting your own Apple-issued SDK. If unavailable, check [theos/sdks](https://github.com/theos/sdks), then [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs), for the required version. Verify `SDKSettings.json` → `Version`; renaming an older SDK does not upgrade it. Theos matches the folder name `iPhoneOS<version>.sdk`. A downloaded Simulator runtime is not a device SDK.

A developer-only newer-SDK build requires an explicit compatible deployment target, for example `make package APOLLO_DEVICE_SDK=27.1 APOLLO_DEVICE_DEPLOY=15.0`. SDK 27.1 requires iOS 15 or newer; this artifact does **not** support iOS 14. The Makefile rejects alternate SDK pins without an explicit iOS 15-or-newer floor; check the selected SDK for any higher minimum. Keep the default 26.0/14.0 combination for releases.

Explicit command-line `TARGET` remains authoritative. The simulator script supplies `TARGET=simulator:clang:latest:15.0`, independent of device defaults. See [AGENTS.md](AGENTS.md) for the SDK rationale.

## Testing in the iOS Simulator

You don't need a physical device to iterate on most changes. `scripts/run-in-sim.sh` builds the tweak for the iOS Simulator and launches Apollo with it injected, so a code change goes from edit to running app in seconds — no IPA, no certificates, no sideloading.

```bash
scripts/run-in-sim.sh              # build the sim tweak, prepare Apollo, launch it injected
scripts/run-in-sim.sh --no-build   # relaunch without rebuilding (e.g. after killing the app)
scripts/run-in-sim.sh --logs       # also stream the tweak's ApolloLog output after launch
scripts/run-in-sim.sh --fresh-app  # re-prepare the app after dropping in a new apollo-base.ipa
scripts/run-in-sim.sh --dark       # boot the simulator in dark mode (--light forces light)
scripts/run-in-sim.sh --glass      # apply the iOS 26 Liquid Glass patch (--no-glass disables)
scripts/run-in-sim.sh --backup B.zip  # preload a settings backup (API keys + account)
```

Requirements: Xcode with an iOS Simulator runtime installed, and the same `apollo-base.ipa` used for device builds in the repo root. The first run prepares a cached, simulator-compatible copy of Apollo under `./.sim/` (a few seconds); subsequent runs reuse it.

How it works, briefly: Apollo's App Store binary is built for device iOS, so the script rewrites each Mach-O's platform tag to iOS-Simulator and re-signs it ad-hoc (the arm64 code is identical on an Apple Silicon Mac). The tweak itself is built against the simulator SDK with Logos's *internal* generator — pure ObjC-runtime swizzling with no CydiaSubstrate dependency — and with `APOLLO_SIM_BUILD=1`, which skips the device-only FFmpegKit libraries. It's then injected with `DYLD_INSERT_LIBRARIES`.

**Liquid Glass.** By default the simulator shows the standard (pre-iOS-26) Apollo UI, because the base IPA is linked against an older SDK. Pass `--glass` to apply the Liquid Glass patch (guest `LC_BUILD_VERSION` sdk **27.1** — iOS 26 chrome plus iPhone Duo full-bleed). It reuses `patch.sh --liquid-glass`. A cached `.sim` shell at sdk 19.0 will be regenerated. Toggling `--glass` / `--no-glass` re-prepares the app.

**Custom bundle id.** If your installed device build is rebranded, run the simulator under the same id so behavior matches: `BUNDLE_ID=com.example.MyBuild scripts/run-in-sim.sh`. The script rebrands the cached app (app + every extension) to that id and caches it; switching ids triggers one re-prepare. You can also override `SIM_DEVICE_TYPE`, `SIM_RUNTIME`, and `SIM_NAME`.

**Preload a settings backup.** A fresh simulator install has no API key, so Reddit content won't load. Point `--backup` at a `.zip` exported from **Settings → Backup Settings** and the script loads its API keys and browsing session into the simulator before launch, so feeds and most features populate:

```bash
scripts/run-in-sim.sh --backup ~/Downloads/Apollo_Backup_20260609.zip
# combine with a custom id + dark mode to mirror your device exactly:
BUNDLE_ID=com.example.MyBuild scripts/run-in-sim.sh --backup ~/Downloads/Apollo_Backup_20260609.zip --dark
```

Or drop the zip at `./.sim/backup.zip` once and it's auto-loaded on every run (no `--backup` needed) — handy for letting an AI agent test signed-in flows without re-specifying the path.

This restores your **API keys, app-only session, and your signed-in Reddit account** — so profile, inbox, and voting work in the simulator, not just browsing. Apollo loads accounts from the keychain (via Valet), and an ad-hoc-signed simulator app can't reach the real keychain, so the tweak virtualizes it: `Backup Settings` now captures Apollo's keychain account items into the backup (`keychain.plist`), and in the simulator the tweak serves them from a file-backed store. **This needs a backup exported by a build that includes this feature** — older backups have no `keychain.plist`, so the account won't restore (you'll see a note to that effect) and the Account tab stays at "sign in"; everything else still loads. Re-export a backup from your device to capture the account.

A backup `.zip` now contains your live Reddit **account credentials** (keychain) in addition to API keys — keep it out of the repo (the `./.sim/` working dir is gitignored) and don't commit one.

**Optional — automate the UI with idb.** To inspect and screenshot programmatically, install Facebook's [idb](https://fbidb.io/): `brew install facebook/fb/idb-companion`, then install the `fb-idb` Python client **into a Python 3.11 venv** (it relies on an asyncio API removed in Python 3.12+ — `uv venv ~/.idb-venv --python 3.11 && uv pip install --python ~/.idb-venv/bin/python fb-idb` works well if you have `uv`). Point the script at it and pass `--drive` to capture the accessibility tree and a screenshot after launch:

```bash
python3.11 -m venv ~/.idb-venv && ~/.idb-venv/bin/pip install fb-idb
IDB=~/.idb-venv/bin/idb scripts/run-in-sim.sh --drive   # writes ./.sim/uitree.json and ./.sim/screenshot.png
```

**Xcode 27 / Device Hub.** Simulator.app was replaced by Device Hub (`com.apple.dt.Devices`); the script opens Device Hub only; it does not automatically fall back to Simulator.app if Device Hub is unavailable. `--drive`'s screenshot is taken via `simctl io screenshot` rather than idb — idb_companion's screenshot RPC returns "No Image available to encode" against Xcode 27's iOS-27 sims. `idb ui describe-all` (the accessibility tree) still works fine. idb's HID commands (`idb ui tap`/`text`/swipe) are currently broken under Xcode 27: idb_companion 1.1.8 hardcodes `SimulatorKit.framework` at the pre-27 path (`Contents/Developer/Library/PrivateFrameworks/`), which Xcode 27 moved to `Contents/SharedFrameworks/`, and Xcode.app's bundle is write-protected so it can't be symlinked back. Until idb_companion ships a fix, drive taps manually in Device Hub.

**What the simulator can't test:** push notifications (so Live Activities push-to-start needs a real device), the FFmpeg-based v.redd.it audio remux (compiled out of sim builds), and any other genuinely device-only behavior. Validate those on a device IPA. Everything else — settings, navigation, Liquid Glass, layout, media playback UI — works in the simulator, which runs the same iOS version family as a modern device.

## Agent-Assisted Development

This project includes an [AGENTS.md](AGENTS.md) file that gives coding agents full context about the codebase, conventions, and RE techniques.

## Disassembler MCP Setup

A disassembler with MCP support lets agents query the binary directly. This guide covers [Hopper Disassembler](https://www.hopperapp.com/) which has one built in, but other tools like Ghidra work too.

1. **Install Hopper** from [hopperapp.com](https://www.hopperapp.com/).
2. **Open Apollo's binary** in Hopper (extract from the `.ipa` → `Payload/Apollo.app/Apollo`).
3. **Configure the MCP server** in your coding agent's MCP config using the STDIO transport protocol (syntax varies):

```json
{
    "mcpServers": {
        "HopperMCPServer": {
            "command": "/Applications/Hopper Disassembler.app/Contents/MacOS/HopperMCPServer",
            "args": [],
            "env": {}
        }
    }
}
```

See [AGENTS.md](AGENTS.md) for detailed Hopper MCP tools and investigation patterns.

## Apple Developer Docs MCP Setup

The [apple-docs-mcp](https://github.com/kimsungwhee/apple-docs-mcp) server gives agents live access to Apple Developer documentation, WWDC transcripts, and framework symbol search.

```json
{
    "mcpServers": {
        "apple-dev": {
            "command": "npx",
            "args": ["-y", "apple-docs-mcp@latest"]
        }
    }
}
```

## iOS 26 Runtime Headers (for Liquid Glass work)

For iOS 26 / Liquid Glass-specific tweaks, clone these into the repo root so agents can grep them directly. Both are gitignored.

```bash
# RuntimeBrowser-style ObjC headers for every framework
git clone https://github.com/qingralf/iOS26-Runtime-Headers.git

# IDA-style decompilation of iOS 26.1. The full repo is huge; sparse-checkout
# just UIKitCore.framework (the only slice that's typically needed).
git clone --depth 1 --filter=blob:none --sparse https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore.git
cd iPhone18-3_26.1_23B85_Restore
git sparse-checkout set System/Library/PrivateFrameworks/UIKitCore.framework
cd ..
```

See [AGENTS.md](AGENTS.md) for usage notes.

## Adding a New Feature

Tips for prompting effectively:

**Describe the behavior, not the implementation** — focus on what you want from the user's perspective.

> "When I scroll past an unmuted video in comments, the audio stops. Can you make it keep playing?"

**Provide runtime context** — paste crash backtraces, `ApolloLog` console output, and screenshots so the agent can diagnose quickly.
