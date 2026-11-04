#!/bin/sh
set -eu

overlay_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
overlay_build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-native-search-overlay.XXXXXX")
trap 'rm -rf -- "$overlay_build"' EXIT HUP INT TERM

# Compile the production policy helper itself, then exercise the lifecycle and
# geometry combinations that distinguish a fullscreen-overlay return from a
# normal navigation appearance.
python3 - "$overlay_root" "$overlay_build" <<'PY'
from pathlib import Path
import sys

root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloSearchNativeBar.xm').read_text()
start = source.index('// MARK: - Overlay return policy')
end = source.index('// MARK: - End overlay return policy', start)
helper = source[start:end]
fixture = (root / 'tests/native_search_overlay_return_tests.m').read_text()
prefix = '#import <Foundation/Foundation.h>\n#import <CoreGraphics/CoreGraphics.h>\n#include <math.h>\n'
(build / 'native_search_overlay_return_tests.m').write_text(prefix + helper + '\n' + fixture)
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework CoreGraphics \
    "$overlay_build/native_search_overlay_return_tests.m" \
    -o "$overlay_build/native_search_overlay_return_tests"
"$overlay_build/native_search_overlay_return_tests"
