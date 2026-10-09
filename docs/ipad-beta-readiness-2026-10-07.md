# iPad Layout beta readiness — 7 October 2026

Recommendation: close to an opt-in beta, but finish the integration and release
checks below before shipping this branch. Keep the layout off by default and
retain the existing welcome/opt-out flow.

Integration update — 9 October 2026: current main `931223e` is now integrated.
The shared-source conflicts were resolved while retaining pane-specific
scene routing, search sessions and header geometry, and adopting main's shared
runtime helpers and updated settings. Simulator and device package builds pass,
as do the pane-policy checks and 46 executable-SDK/Liquid Glass checks. Physical
device, keyboard and release-readiness gaps below remain independent of this
merge. The latest mini portrait capture also shows a feed title obscured by the
top tabs; that remains an open chrome issue.

## Before shipping

1. Complete the targeted UI regression checks for the 9 October main integration,
   and repeat them when shared navigation, search, settings or media code changes.
   The previously missing main commits are incorporated through `931223e`.
2. Fix the reproduced portrait sidebar-to-Settings toolbar overlap. The Settings
   navigation bar stays at y=32 while the top tabs occupy y=36, causing overlap.
   It settles only after further navigation. Reproduced in the welcome audit and
   again in the sidebar-badge audit; this is a current defect, not just an old
   audit note. Evidence:
   `.sim/sidebar-audit/evidence/sidebar-badge/candidate1/settings-portrait-overlap.png`.
3. Complete a physical-iPad smoke test: cold start, opt-in/opt-out, rotation,
   small multitasking windows/continuous resize, keyboard navigation, media
   open/close and Inbox. Recheck a mini/11-inch width and a supported released
   iPadOS version. The latest visual passes use the existing 13-inch iOS 27
   simulator; device compilation alone does not verify device behavior.

## Current evidence

- The 13-inch simulator passes the recent feed/profile/subreddit collapsing
  headers, sidebar transitions, full-width Gallery and Gallery Back checks.
- The beta invitation passes actual first-run, Try Later/no-repeat, Try Now
  followed by relaunch, existing opt-in, debug replay and portrait/landscape.
- The sidebar follows the native unread badge, including 1, 42 and 99+ updates,
  clearing at 0/nil, and preservation through sidebar/top-tab and rotation
  changes. Temporary badge fixtures restore the original value and do not
  create or mark messages read.
- The native directory, feed position and favourites are retained. Subreddits
  uses an outlined grid with template-asset metrics matching the other rows.
- Host policy checks pass: 146,781 geometry combinations/RTL cases, title
  geometry and transition readiness/replacement/deadline/cancellation/lifetime.
- Simulator and device package builds pass.

Earlier size-matrix notes remain useful history, but their unresolved findings
must not be presented as current failures without retesting, nor treated as
cleared just because the 13-inch layout now looks good. Multi-scene/external
display, hardware input and older iPadOS coverage are still limited.
