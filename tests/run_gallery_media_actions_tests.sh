#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-gallery-actions.XXXXXX")
trap 'rm -f "$test_build_dir"/*; rmdir "$test_build_dir"' EXIT HUP INT TERM

# Exercise the shipping snapshot, menu and dismissal state machine. UIKit
# presentation and I/O are doubled so this runs on the host without an app.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys

root, build = map(Path, sys.argv[1:])
source = (root / 'src/ApolloGalleryMediaActions.m').read_text()
def between(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

(build / 'GalleryMediaActionsAPI.inc').write_text(
    (root / 'src/ApolloGalleryMediaActions.h').read_text().replace('#import <UIKit/UIKit.h>', ''))
(build / 'GalleryMediaActionsSnapshot.inc').write_text(
    between('@interface ApolloGalleryActionItemSnapshot', 'static void ApolloGalleryRemoveShareDirectory'))
(build / 'GalleryMediaActionsPrivate.inc').write_text(
    between('@interface ApolloGalleryMediaActions ()', '@implementation ApolloGalleryMediaActions'))
(build / 'GalleryMediaActionsMethods.inc').write_text(
    between('- (instancetype)initWithItem:', '- (void)shareOriginalImageData:'))
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework CoreGraphics -framework ImageIO -I "$test_build_dir" -I "$test_repo_root/src" \
    "$test_repo_root/tests/gallery_media_actions_tests.m" -o "$test_build_dir/test"
"$test_build_dir/test"
