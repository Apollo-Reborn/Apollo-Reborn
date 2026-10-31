<!--
Outside contributors: read the pull request rules first:
https://github.com/Apollo-Reborn/Apollo-Reborn/blob/main/CONTRIBUTING.md#pull-request-rules

A bot checks this description when you open the PR (a draft is checked when you mark it ready for review).
If anything is missing it closes the PR and lists what to add. Edit this description to add it and the PR reopens by itself.

Maintainers: the check skips your PRs, so replace this with your usual description.
-->

## Type

<!-- Tick one. It decides which sections below you need. -->

- [ ] Bug fix
- [ ] Feature (agreed on its issue)
- [ ] Refactor (no change in behavior, agreed on its issue)

## Issue

Closes #

## What this changes

<!-- What was wrong or missing, and how this change fixes or adds it. -->

## Steps

<!-- Bug fix: the exact steps that show the bug on current main, starting from a fresh launch. Feature: the steps to try it. Refactor: leave this empty. -->

1.
2.
3.

## Before

<!-- Bug fix: drag in a screenshot (layout or color changes) or a screen recording (anything that moves or happens over time) of the bug on current main, without your change. Feature: optional. Refactor: leave this empty. -->

## After

<!-- Bug fix: the same steps with your change. Feature: the feature in use. Refactor: leave this empty. Recordings at normal speed, please. -->

## How I checked nothing changed

<!-- Refactor only: what you ran or compared to make sure everything behaves the same. -->

## Tested on

<!-- Fill in every row: the model, the iOS version, whether it was a real device or a simulator, and the result. Simulators are fine; see "Testing in the iOS Simulator" in CONTRIBUTING.md. Both iPhone rows are always needed. If the change can't affect iPad or iPhone Duo (say, a network-only fix), write `N/A: <why>` in that row's Result column. -->

| Device | Model | iOS | Real device or simulator | Result |
|---|---|---|---|---|
| Older or smaller iPhone | | | | |
| Newer or larger iPhone | | | | |
| iPad | | | | |
| iPhone Duo | | | | |

## Checklist

- [ ] Bug fix: I reproduced the bug myself on current `main` before changing anything. Feature or refactor: a maintainer agreed to it on the linked issue.
- [ ] I ran this change in the app myself, and the After media (or, for a refactor, my notes above) shows the result.
- [ ] If it touches animations, transitions, gestures, scrolling, media playback, haptics or the keyboard, a person tried it, not only an agent. If that needed a real device and I didn't have one, I said so above.
- [ ] I tested both the Standard and the Liquid Glass build.
- [ ] `make package` (the device build) passes on current `main`. The simulator build alone isn't enough.
- [ ] I've read every line of this diff and can explain why each change is needed.
- [ ] This PR does one thing, and the branch has no unrelated changes, `CHANGELOG.md` edits, screenshots, videos, backups or build output.
