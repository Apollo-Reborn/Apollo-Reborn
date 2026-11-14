#!/bin/bash
# Host tests for the camera-roll GIF store (#1663): compiles the production store
# and ImageIO capture hooks from src/ApolloUploadOriginalGIF.m into
# tests/upload_original_gif_tests.m and runs real GIFs through them on the Mac.
set -euo pipefail
gif_root=$(cd "$(dirname "$0")/.." && pwd)
gif_tmp=$(mktemp -d /tmp/apollo-upload-original-gif-tests.XXXXXX)
trap 'rm -rf "$gif_tmp"' EXIT
python3 - "$gif_root" "$gif_tmp" <<'PY'
from pathlib import Path
import sys

root, out = map(Path, sys.argv[1:])
source = (root / 'src/ApolloUploadOriginalGIF.m').read_text()
start, end = '// BEGIN_ORIGINAL_GIF_STORE', '// END_ORIGINAL_GIF_STORE'
a = source.find(start)
b = source.find(end, a)
if a < 0 or b < 0:
    sys.exit(f'run_upload_original_gif_tests: markers {start!r} / {end!r} not found in ApolloUploadOriginalGIF.m')
fixture = (root / 'tests/upload_original_gif_tests.m').read_text()
fixture = fixture.replace('// INSERT_PRODUCTION_STORE', source[a:b])
(out / 'tests.m').write_text(fixture)
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wno-unused-function \
    -I "$gif_root/src" -framework Foundation -framework ImageIO -framework CoreGraphics \
    "$gif_tmp/tests.m" -o "$gif_tmp/tests"
"$gif_tmp/tests"
