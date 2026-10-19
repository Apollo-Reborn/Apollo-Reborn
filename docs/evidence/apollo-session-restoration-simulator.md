# Session restoration simulator evidence

![Apollo comments before termination, during cold launch, and after restoration](apollo-session-restoration-simulator.gif)

This capture is from the real Apollo 1.15.11 app shell running the freshly built
Apollo Reborn tweak on an iPhone 16 Pro simulator with iOS 27 in non-Glass mode.
The account tab was cropped from the published GIF to avoid exposing account
identity; no application behavior was removed from the sequence.

## Exercised path

1. Apollo displayed a scrolled comments screen for post `t3_1x9alu4` and the
   background lifecycle persisted visible comment identity `t1_phjnt7p`.
2. The saved feed item was deliberately replaced with nonexistent
   `t3_missing`, reproducing the case where a refreshed feed no longer contains
   the post that was open.
3. Apollo was explicitly terminated to model iOS process eviction, then
   cold-launched.
4. The restored process logged `Cold launch has a recent reading session` at
   `19:28:57.621` and `Restored post anchor t1_phjnt7p` at `19:28:59.475`.
5. The same comments viewport is visible before termination and after the cold
   launch. The account tab is cropped from the GIF; no application behavior is
   removed from the sequence.

## Evidence boundary

This demonstrates simulator cold restoration of an open post and its
identity-based visible-comment anchor even when the saved feed anchor is no
longer available. It does **not** claim physical-device acceptance or
hours-long elapsed-time testing. Physical-device acceptance remains required
before any upstream pull request.
