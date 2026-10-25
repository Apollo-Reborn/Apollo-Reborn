#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-duo-fold-playback.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Extract the shipping capture/resume code, not a second implementation of it.
# Views, video nodes, layers, players and the delayed resume are doubled by the
# Foundation-only harness.
python3 - "$test_repo_root" "$test_build_dir" "${1:-$test_repo_root/src/ApolloDuoSplitView.xm}" <<'PY'
from pathlib import Path
import sys

root, output, source_path = map(Path, sys.argv[1:])
source = source_path.read_text()
start = source.index('static AVPlayer *ApolloDuoVideoNodePlayer(id node) {')
end = source.index('static void ApolloDuoSplitClose(', start)
test = (root / 'tests/duo_fold_playback_tests.m').read_text()
marker = '// INCLUDE_PRODUCTION_FOLD_PLAYBACK'
assert test.count(marker) == 1, 'fold playback insertion marker missing or duplicated'
(output / 'DuoFoldPlayback.m').write_text(test.replace(marker, source[start:end]))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    "$test_build_dir/DuoFoldPlayback.m" -o "$test_build_dir/duo_fold_playback_tests"
"$test_build_dir/duo_fold_playback_tests"
