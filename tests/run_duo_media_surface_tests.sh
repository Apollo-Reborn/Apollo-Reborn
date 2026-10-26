#!/bin/sh
set -eu
surface_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
surface_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-media-surface.XXXXXX")
trap 'rm -rf -- "$surface_build"' EXIT HUP INT TERM

# Execute the shipping surface decision and YouTube loading re-pin, with UIKit
# views swapped for AppKit's so the constraint handling runs on real Auto
# Layout. An optional source path lets the same checks run against another
# revision.
python3 - "$surface_root" "$surface_build" "${1:-$surface_root/src/ApolloDuoSplitView.xm}" <<'PY'
from pathlib import Path
import sys
root, build, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
signature = 'static UIView *ApolloDuoSplitMediaSurface('
start = source.index(signature)
function = source[start:source.index('\n}', start) + 2]
signature = 'static void ApolloDuoSplitCoverYouTubeLoading('
start = source.index(signature)
function += '\n' + source[start:source.index('\n}', start) + 2]
fixture = (root / 'tests/duo_media_surface_tests.m').read_text()
(build / 'duo_media_surface_tests.m').write_text(
    fixture.replace('// INCLUDE_PRODUCTION_MEDIA_SURFACE', function))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework AppKit \
    "$surface_build/duo_media_surface_tests.m" -o "$surface_build/duo_media_surface_tests"
"$surface_build/duo_media_surface_tests"
