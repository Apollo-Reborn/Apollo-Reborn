# Duo autoplay visibility

The native feed and ASVideoNode midpoint checks assume a horizontal bottom tab bar.
They subtract its bounds height from the window height. On an SDK 27.1 Duo layout,
the right-side tab bar is as tall as the window. The resulting negative-height
rectangle accepts midpoints behind the navigation bar and rejects visible media.

`ApolloVideoVisibility.m` extends the existing PiP midpoint policy into one shared
window-coordinate predicate. It uses the actual visible navigation/tab bar frames,
including a right-side bar, without changing layout or autoplay/player settings.
PiP now uses that predicate too. The existing Mach-O metadata helper provides the
UUID guard, also reused by MaintainerTint, instead of a second UUID parser.

The predicate walks the selected tab's attached, visible containment tree. Duo
hides the outer navigation bar when columns open; each column's actual bar sets
the cutoff only within its content pane. The secondary surface and bar can extend
under the primary; horizontal safe-area insets identify the pane, as in
`ApolloDuoPostsDetailPane`. Choosing only the active detail stack would miss the
other column in a paired feed/comments layout. Hidden or transparent view
ancestors exclude their bars from occlusion.

Run `tests/run_video_visibility_tests.sh` for host coverage of the production
predicate, including hidden outer bars, unequal column bar heights, hidden
ancestors, side rails and ordinary phone bars. The harness uses Foundation view
stand-ins and real CoreGraphics geometry under AddressSanitizer and UBSan.

The closed-source feed helpers cannot call a source-level replacement directly.
Following the existing image-scoped fishhook and caller-guard pattern in
`ApolloMaintainerTint.m`, the patch rebinds CGRectContainsPoint only in the pinned
Apollo and AsyncDisplayKit images. It repairs only their five verified autoplay
call sites, only for a vertical tab bar, and only when the legacy rectangle matches
the owning window. All other checks call CoreGraphics unchanged. Image UUIDs,
branch instructions and the actual rebound import slot are validated before the
sites become eligible. A different native IPA needs new verified guards.

## Runtime regression probe

`tests/duo_video_visibility_probe.m` calls the actual bundled ASVideoNode predicate
at several window positions. Its video has a zero local origin to isolate the
tab-height issue from Apollo's separate frame-versus-bounds conversion quirk.
The 49-point control is a diagnostic experiment, not a hardcoded production fix.

Compile the probe as an arm64 simulator dylib against UIKit, Foundation and
CoreGraphics, ad-hoc sign it, and load it into the dedicated Apollo simulator with
LLDB after the app has finished launching. It writes
`Documents/autoplay-visible-probe.json` in the app data container. Check that result:

```sh
python3 tests/check_duo_video_visibility.py /path/to/autoplay-visible-probe.json
```

Before the patch, a fully visible video at y=200 is rejected while a video at y=25
is accepted with only 44.5% visible below the measured navigation bar. The same
check passes after the patch. Run on the front and inner displays. Restart the QA
app after probing to unload the diagnostic dylib.
