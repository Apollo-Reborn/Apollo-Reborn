<!--
Outside contributors: read the pull request rules first:
https://github.com/Apollo-Reborn/Apollo-Reborn/blob/main/CONTRIBUTING.md#pull-request-rules

A bot checks this description when you open the PR (a draft is checked when you mark it ready for review). It also checks the PR's size on every push, drafts included: over 500 lines it's labelled until a maintainer agrees, but stays open.
If anything is missing it closes the PR and lists what to add. Edit this description to add it and the PR reopens by itself; you can't reopen it with the button.

Maintainers: the check skips your PRs, so replace this with your usual description.
-->

## Type

<!-- Tick one. It decides which sections below you need. -->

- [ ] Bug fix
- [ ] Feature
- [ ] Refactor (no change in behavior)

## Issue

<!--
Bug fix: the GitHub issue. Write `Closes #123` only if this fully fixes it (merging closes the issue); otherwise `Related to #123` (a report from the app or report.apolloreborn.app opens an issue for you).

Feature: `Closes #123` or a link to its request, like https://request.apolloreborn.app/posts/123.

Refactor: none needed; link an issue only if there is one.
-->

Closes #

## What this changes

<!-- What was wrong or missing, and how this change fixes or adds it. Refactor: what it changes and why it's worth doing. -->

## Steps

<!-- Bug fix: the exact steps that show the bug on current main, starting from a fresh launch. Feature: the steps to try it. Refactor: leave this empty. -->

1.
2.
3.

## Before

<!-- Bug fix: drag in a screenshot (layout or color changes) or a screen recording (anything that moves or happens over time) of the bug on current main, without your change. Feature: optional. Refactor: leave this empty. If you ticked "Needs a device tester" below, write `N/A: <why you can't record it>` instead. -->

## After

<!-- Bug fix: the same steps with your change. Feature: the feature in use. Refactor: leave this empty. Recordings at normal speed, please. If you ticked "Needs a device tester" below, write `N/A: <why you can't record it>` instead. -->

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

<!-- Tick a box only when it's true. If you can't try the change on the device it affects (for example, if you don't have the device needed), leave the first three unticked, tick "Needs a device tester" at the end, and say why under Before and After. The PR stays open and a maintainer with the device tries it before it merges. -->

- [ ] Bug fix only: I reproduced the bug myself on current `main` before changing anything.
- [ ] I ran this change in the app myself, and the After media (or, for a refactor, my notes above) shows the result.
- [ ] If it touches animations, transitions, gestures, scrolling, media playback, haptics or the keyboard, a person tried it, not only an agent.
- [ ] I tested both the Standard and the Liquid Glass build.
- [ ] `make package` (the device build) passes on current `main`. The simulator build alone isn't enough.
- [ ] I've read every line of this diff and can explain why each change is needed.
- [ ] This PR does one thing, and the branch has no unrelated changes, `CHANGELOG.md` edits, screenshots, videos, backups or build output. Any refactoring is only what this change needs, and "What this changes" mentions it.
- [ ] Needs a device tester: I couldn't try this on the device it affects. <!-- Only check this if it's true -->
