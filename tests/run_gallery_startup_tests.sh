#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-gallery-startup-tests.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Exercise the actual implementation. Only environment imports and the Logos
# registration are removed; the parser, snapshot guards and batching stay intact.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
feed = (root / 'src/ApolloGalleryFeed.m').read_text()
source = (root / 'src/ApolloGallerySource.xm').read_text()
marker = '#pragma mark - Preserve parser input while Apollo builds source posts'
if source.count(marker) != 1:
    raise SystemExit('Cannot uniquely locate Gallery source hook boundary')
for name, content in [('GalleryFeedProduction.inc', feed),
                      ('GallerySourceProduction.inc', source.split(marker)[0])]:
    out.joinpath(name).write_text('\n'.join(line for line in content.splitlines()
                                            if not line.startswith('#import ')))
PY

xcrun --sdk macosx clang++ -fobjc-arc -fblocks -Wall -Werror \
    -Wno-nullability-completeness \
    -framework Foundation -framework CoreGraphics \
    -I "$test_build_dir" -I "$test_repo_root/src" \
    "$test_repo_root/tests/gallery_startup_tests.mm" \
    -o "$test_build_dir/gallery_startup_tests"
"$test_build_dir/gallery_startup_tests"
