# Duo tabletop video

Run `scripts/run-in-sim.sh --glass` and, separately, `--no-glass` on the
iPhone Duo and confirm `[DuoVideo] tabletop video hooks installed` in the
`apollofix` log. The tile frames match; only the material changes (glass
versus a translucent fill). Use Device Hub's actual Open / Partially Open /
Closed and rotation controls. A video with Apollo's full playback bar (for
example a Reddit-hosted video) is required; Apollo's GIF-style MP4 viewer has
no playback bar and stays native.

0. On Duo, confirm Apollo Reborn → Features has no iPhone Duo settings page
   and settings search has no iphone-duo route. Tabletop layout is always on
   for partly folded portrait playback; there is no preference to enable.
1. Open a video while the inner display is flat in portrait. Confirm the
   ordinary fullscreen layout, native auto-hide, seek and playback controls.
2. Partially fold the display. Confirm the picture aspect-fits above the
   division, including a tall portrait clip. Close remains in the upper left.
3. Confirm the lower panel shows a glass timeline capsule first, then wide
   rounded 15-second back, a wider play/pause, and 15-second forward. Under
   those is a row of shorter rounded tiles: mute, Share Link, Download Video,
   Playback Speed and AirPlay. Elapsed and remaining times sit inside the
   capsule, on a thin track. Liquid Glass uses the glass material for the
   capsule and the tiles; a classic build uses the same frames as translucent
   fills. Share Link and Download Video run the same actions as the video
   long-press menu. Playback Speed opens that menu's speed submenu. AirPlay
   must remain tappable without a receiver, and tapping it opens the system
   route picker. Post actions stay below.
4. The transport hides on its own after a few seconds. A tap on the video or
   the empty lower panel brings it back, and a tap on empty space hides it
   again. Pause/resume, seek, skip in each direction, mute/unmute, share,
   download, and change playback speed. The transport stays up while a control
   is in use, including for the whole scrub, and time updates do not collapse
   the layout. Close and the Reddit row stay visible the whole time.
5. Unfold during playback and while paused. Confirm immediate native layout
   restoration without restarting, seeking, muting or unpausing the player.
6. Rotate to landscape/book posture and close onto the cover display. Confirm
   native layouts, then reopen portrait and partially fold again.
7. Dismiss/reopen the viewer and page through video/photo gallery items. Photos
   retain native sizing and no tabletop controls leak between pages.
8. Check hold-to-speed and swipe-to-dismiss in the upper panel, VoiceOver
   control labels, and Picture in Picture entry/return. On a real device with
   an available receiver, check the native AirPlay route picker.
9. Check flat Duo and ordinary iPhone playback for regressions. Capture the
   active Duo inner display, not the inactive cover display, for evidence.

Host checks: `sh tests/run_duo_video_geometry_tests.sh`,
`sh tests/run_duo_rail_layout_tests.sh`, and
`sh tests/run_duo_fold_playback_tests.sh`.

## Validation recorded 2026-10-29

- PASS: pinned device package (iOS 26.0 SDK / iOS 14 floor) and current
  simulator build; geometry checks, 40 rail-layout checks, 19 fold-playback checks.
- PASS on iPhone Duo / iOS 27.1 in Device Hub: landscape and portrait clips
  fit above the horizontal fold; large icons; controls stay visible beyond
  native timeout; pause/play icon state; 15-second rewind and forward; native
  compact layout returns on flat unfolding while preserving pause/position;
  refolding and book rotation switch layouts correctly; dismiss/reopen works.
- NOT CERTIFIED: AirPlay receiver routing, VoiceOver, PiP, hold-to-speed,
  gallery transitions, and ordinary iPhone runtime regression checks.
- BASELINE ISSUE: a paused shared video can become black on a full transition
  to the cover display and remain black after reopening. Reproduced in a fresh
  compact player that never entered tabletop mode. This is independent of the
  new layout; partial-fold to flat-unfold playback does not show this problem.

### Sound / AirPlay row revision

- PASS: geometry checks cover equal utility tiles, separation from the timeline,
  minimum 44pt tap heights, and containment at 320×240, 637×321.5 and 919×540.
- PASS in Device Hub: Sound and AirPlay remain visible in matching labeled
  tiles; mute/unmute retains the native action and glyph; unfolding removes the
  utility row and returns native controls, and refolding recreates it.
- AirPlay uses AVRoutePickerView's native button across the entire tile. Verified
  hit testing with simulator bridge and Device Hub input; the simulator did not
  present its routes UI. Real-device picker presentation and receiver routing
  remain unverified. No replacement or simulated routes dialog is provided.

### Netflix-style timeline revision

- Replaced the floating timeline/time labels with one rounded 52pt panel.
  Elapsed time, the native scrubber, and remaining time share a center line.
  The active track uses Apollo's theme accent; original slider colors restore
  when leaving tabletop mode.
- Removed Sound/AirPlay captions and shortened their icon-only row to 52pt.
  Playback, timeline, and utility rows share edges with 8pt vertical gaps.
- PASS: geometry containment and non-overlap checks at all supported test sizes,
  including 58pt minimum timestamp widths; simulator visual inspection; pause;
  native-HID scrub from 0:22 to 0:04; flat-unfold restores native layout/colors
  while remaining paused; refolding restores the revised panel.

### Duo settings / opt-in playback

- Historical: the 2026-10-29 validation covered an opt-in Tabletop Video
  Controls toggle on a Duo-only settings page that also mirrored Landscape
  Feed Layout and Subreddit Panel Style.
- Current: tabletop is standard behavior whenever the fold geometry
  qualifies. The Duo settings page, preference key, and layout-change
  notification are gone. Subreddit Panel Style stays under Subreddits; Landscape
  Feed Layout stays as the in-feed control.
