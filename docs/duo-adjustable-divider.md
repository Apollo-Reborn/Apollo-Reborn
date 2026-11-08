# Duo Posts divider

On the flat inner display in landscape, hold the three-dot grip for 0.25 seconds,
then drag horizontally. The feed and thread keep their existing controllers and
resize through UISplitViewController. Other tabs and collapsed layouts keep their
existing behavior. The feature is available whenever both Posts panes are visible.

- The central grip has a 44-point hit target; a quick swipe does not activate it.
  Touches that start on the grip belong to it, so scrolling, taps and the thread's
  back swipe don't begin there. This is deliberate: sharing touches with UIKit's
  recognizers is what made earlier drags unstable.
- Its pill stays visible with a subdued theme tint and outline when idle, and
  becomes solid theme color while held. An opaque backing in the theme's card
  color keeps media from obscuring the dots in either appearance.
- Double-tap the grip to restore 50/50. VoiceOver activation deliberately does
  not, so a double-tap can't discard the saved width; use Equal Widths instead.
- Grab and release use light impact feedback. Movement uses selection feedback
  every 2 percentage points, with hysteresis and an 80 ms rate limit. Landmarks
  use a distinct impact and a guide.
- Release confirmation always plays, even immediately after a movement tick.
  Reaching either width limit gives one stronger tap; moving at least 6 points
  back into the range rearms that edge. Starting at an edge doesn't repeat it.
- The held background is black at 20% opacity, matching the native account
  switcher's UIDimmingView observed on iOS 27.1. Fade duration is 0.18 seconds;
  Reduce Motion removes that animation. The grip and value label stay above it.
- A release within 6 points of a legal 1/3, 40%, 50%, or 60% position snaps there.
  Other releases retain their exact position. Both columns retain at least 320
  points of usable width, including the thread's trailing rail reservation.
- The ratio bubble previews the snapped release destination shown by the guide.
- Only successful releases persist `DuoDividerFeedShare`. The active fold takes
  precedence; returning flat restores the saved ratio. Interruption cancels and
  restores the saved geometry without a confirmation haptic.
- VoiceOver exposes adjustable width and an Equal Widths action.

`ApolloDuoSplitDivider` owns its recognizer and temporary views. It does not
inspect or disable UIKit's private resize/context-menu recognizers. A display
link coalesces touch samples and checks whether a fold, navigation, presentation,
or geometry change has invalidated the drag. Host layout positions only the
owned grip; column-width writes happen from the gesture/display-link path.

Validation:

- `tests/run_duo_divider_geometry_tests.sh`: bounds, arbitrary widths, valid snap
  targets, 2% tick spacing and jitter hysteresis, with ASan/UBSan.
- Existing Duo rail, full-thread layout, and compatibility harnesses.
- Simulator and iOS 26 SDK device package builds.
- Apollo-Sim-Duo: hold activation, dimming, live image/text reflow, free release,
  quick-swipe rejection, saved width after relaunch, cancellation while folding,
  and restoration when returned flat. Simulator screenshots are under the local,
  ignored `.sim/divider-review/` directory.
- Physical iPhone Duo: haptic strength and feel, and continuous-drag
  performance.
