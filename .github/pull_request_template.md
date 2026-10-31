<!--
Outside contributors: read the pull request rules first:
https://github.com/Apollo-Reborn/Apollo-Reborn/blob/main/CONTRIBUTING.md#pull-request-rules

A bot checks every section below when you open the PR (a draft is checked when you mark it ready for review).
If anything is missing it closes the PR and lists what to add. Edit this description to add it and the PR reopens by itself.

Maintainers: the check skips your PRs, so replace this with your usual description.
-->

## Issue

Closes #

## What this fixes

<!-- What was wrong, and how this change fixes it. -->

## Steps to reproduce

<!-- The exact steps that show the bug on current main, starting from a fresh launch. For a new feature: the steps to try it. -->

1.
2.
3.

## Before

<!-- Drag in a screenshot (layout or color changes) or a screen recording (anything that moves or happens over time) of the bug on current main, without your change. -->

## After

<!-- The same steps with your change. -->

## Tested on

<!-- Fill in every row: the model, the iOS version, whether it was a real device or a simulator, and the result. Simulators are fine; see "Testing in the iOS Simulator" in CONTRIBUTING.md. -->

| Device | Model | iOS | Real device or simulator | Result |
|---|---|---|---|---|
| Older or smaller iPhone | | | | |
| Newer or larger iPhone | | | | |
| iPad | | | | |
| iPhone Duo | | | | |

## Checklist

- [ ] I reproduced the bug myself on current `main` before changing anything, and the Before media shows it.
- [ ] I ran this change in the app, and the After media shows it working.
- [ ] I tested both the Standard and the Liquid Glass build.
- [ ] `make package` (the device build) passes on current `main`. The simulator build alone isn't enough.
- [ ] I've read every line of this diff and can explain why each change is needed.
- [ ] This PR fixes one thing, and the branch has no unrelated changes, screenshots, videos or build output.
