# Duo portrait-lock compatibility (#1707)

## Expected behavior

On the unfolded inner display, neither native Media Viewer nor the gallery viewer offers “Tap to Rotate” or acts on an obsolete rotation offer. Apollo does not attempt to enforce its portrait lock there. On the folded cover display, both settings behave exactly as before. Saved switch values must never change merely because the device folds.

Settings → General → Smart Rotation Lock (screen title: Portrait Lock) explains the cover-display limitation for both settings on Duo. Ordinary iPhone and iPad explanations are unchanged.

## Host and build checks

Run the portrait-lock regression runners under `tests/`, plus Duo compatibility, device identity, and gallery regressions. Build both the default device target (iOS 26 SDK, iOS 14 deployment) and the simulator target (current SDK, iOS 15 deployment). A simulator cannot validate the real motion-sensor trigger.

## Physical Duo — required before claiming the motion bug fixed

For each viewer (native images, GIFs and videos; gallery images, GIFs and videos):

1. Enable Smart Rotation Lock and Portrait Lock Buddy; enable iOS Portrait Orientation Lock.
2. Folded, turn the device sideways. Confirm the normal rotation offer remains functional, then rotate back. Compare against the unmodified build; gallery retains its existing preference semantics.
3. With an offer visible, unfold the phone. The offer must disappear, be inaccessible to VoiceOver, and stop accepting taps.
4. Remain unfolded and rotate through portrait and both landscapes. No image/video/GIF rotation offer may appear. Repeat face-up and tabletop poses.
5. Open new media while already unfolded, and swipe through native and gallery pages. No offer may appear, including after media finishes loading or playback controls fade.
6. Fold again without closing the viewer or relaunching Apollo. Turn the device and confirm the normal offer can appear and work again; do not accept a stale inner-display offer.
7. Fold/unfold rapidly with a gallery hide animation and orientation debounce pending. No delayed callback may revive an inner prompt or hide a newer legitimate cover offer.
8. Accept a folded gallery rotation offer, unfold, then dismiss. The gallery must not force the inner display back to portrait.
9. Repeat with iOS Portrait Orientation Lock off; ordinary auto-rotation remains available unfolded and no misleading prompt appears.
10. Repeat with each Apollo switch independently off, then both off. Saved values remain exactly as selected after folding and after relaunch.
11. Dismiss media to the feed after each pose transition. Check normal navigation, layout, playback and orientation behavior; no unrelated tabletop controls should be changed by this fix.

## Settings UI

- On Duo, open Portrait Lock folded and unfolded. Both original explanations and their cover-only notes are visible, wrap fully, and do not overlap the next row.
- Fold/unfold while this screen stays open, rotate, and test large text, light/dark appearance, and a custom theme. Check footer readability and VoiceOver text.
- Toggle both switches in either pose. Fold back and confirm the native choices are preserved.
- On ordinary iPhone and iPad, verify native footer text and switch behavior are unchanged.

## Validation record (2026-11-13)

- PASS: all three focused runners (`run_native_portrait_lock_tests.sh`, `run_gallery_portrait_lock_tests.sh`, `run_portrait_lock_settings_tests.sh`). They execute extracted production hooks/methods with Foundation-only doubles, including live transitions and delayed callbacks; native/gallery runners use ASan/UBSan.
- PASS: existing Duo compatibility (24 checks), device identity (48), gallery geometry (31), gallery startup (205), and gallery media actions (48) suites.
- PASS: device package and current-SDK simulator builds using `THEOS="$HOME/theos" gmake` (the host's older `make` stalled in an unrelated extension sub-build). Device deployment metadata is iOS 14.0. Caveat: although the target selects SDK `26.0`, this machine's pre-existing `iPhoneOS26.0.sdk/SDKSettings.json` identifies its contents as **26.5**, also reflected in the built dylib. This is not evidence of an exact iOS 26.0 SDK build; the local SDK needs correcting or exact-SDK CI validation before release. No SDK files were changed by this fix.
- PASS: rebuilt tweak launches on the iPhone Duo / iOS 27.2 simulator; the existing hardware and unfolded predicates return YES on the inner display. Calling the installed native button's alpha-hook implementation on a UIControl probe clamps both 1.0 and 0.5 requests to zero. This is a synthetic hook check, not an actual sensor-triggered offer.
- PASS: native Portrait Lock footer titles include both notes at runtime. Rendered inner-display footers measure 78 and 94.3 points at default text size. Screenshots checked in light/default text and dark/accessibility-large text: explanations wrap without clipping or overlap. QA captures are outside the repository at `/tmp/apollo-1707-settings-inner.png` and `/tmp/apollo-1707-settings-dark-large.png`.
- NOT RUN: physical sensor matrix; real fold/unfold with a motion-triggered offer; ordinary-device runtime UI; custom themes/VoiceOver. Host tests cover policy pass-through and stale-callback cases but cannot replace these checks.

## Reporting

Record device/runtime/build and mark each exercised case pass/fail. Simulator hook loading and settings screenshots are not evidence for motion correctness. If no physical Duo is available, explicitly leave the physical matrix unverified.
