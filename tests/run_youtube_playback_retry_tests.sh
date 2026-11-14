#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# The two page scripts (play() watcher, retry), run in node.
node "$root/tests/youtube_playback_retry_tests.js"

# The native decision (player frame only, one retry per playback), compiled on the Mac.
tmp=$(mktemp -d /tmp/apollo-youtube-playback-tests.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'src/ApolloYouTubePlayback.m').read_text()
start, end = '// BEGIN_YOUTUBE_RETRY_DECISION', '// END_YOUTUBE_RETRY_DECISION'
a = source.find(start); b = source.find(end, a)
if a < 0 or b < 0:
    sys.exit(f'run_youtube_playback_retry_tests: markers {start!r} / {end!r} not found in ApolloYouTubePlayback.m')
fixture = (root / 'tests/youtube_playback_decision_tests.m').read_text()
(out / 'tests.m').write_text(fixture.replace('// INSERT_PRODUCTION_DECISION', source[a:b]))
PY
xcrun --sdk macosx clang -fobjc-arc -Wall -I "$root/src" -framework Foundation -framework WebKit "$tmp/tests.m" -o "$tmp/tests"
"$tmp/tests"
