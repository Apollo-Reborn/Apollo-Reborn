# Deleted Comments Manual Validation

- Open a comments thread with visible `[deleted]` or `[removed]` comments and confirm recovered bodies render with a red recovery badge.
- Open a comments thread where removed replies are hidden behind "more replies" and confirm recoverable deleted children appear inline.
- Toggle "Show Deleted Comments" off, reload the same thread, and confirm Apollo returns to its native deleted/removed output.
- Confirm normal user flair and moderator flair do not receive the recovered-comment red badge styling.
- With tap-to-reveal enabled, confirm the SHOW chip uses your selected Apollo theme accent (not grey/white).
- Tap SHOW on a hidden recovered comment and confirm the revealed body gets a theme-colored background highlight that fades out over ~10 seconds.
- Confirm inline markdown/editor SPOILER pills elsewhere in the app pick up the theme accent chip styling.
- Repeat theme chip and reveal fade checks in dark mode and with a non-default accent theme.
