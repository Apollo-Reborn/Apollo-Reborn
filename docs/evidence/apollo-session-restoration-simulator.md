# Session restoration simulator evidence

![Apollo feed before termination, during cold launch, and after restoration](apollo-session-restoration-simulator.gif)

This capture is from the real Apollo 1.15.11 app shell running the freshly built
Apollo Reborn tweak on an iPhone 16 Pro simulator with iOS 27 in non-Glass mode.
The account tab was cropped from the published GIF to avoid exposing account
identity; no application behavior was removed from the sequence.

## Exercised path

1. Apollo displayed the Home feed and persisted top-row identity `t3_1x9alu4`.
2. Another app foregrounded, allowing Apollo's normal background lifecycle to
   save the reading snapshot.
3. Apollo was explicitly terminated to model iOS process eviction.
4. Apollo was cold-launched.
5. The restored process logged `Cold launch has a recent reading session` and
   then `Restored feed anchor t3_1x9alu4`; the same feed position is visible at
   the end of the GIF.

## Evidence boundary

This demonstrates simulator cold restoration of the Home feed and its
identity-based top-row anchor. It does **not** claim physical-device acceptance,
hours-long elapsed-time testing, subreddit/multireddit restoration, or the
open-post/comment-anchor path. Those remain explicit acceptance items before an
upstream pull request.
