#!/bin/sh
set -eu

test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-gallery-portrait-lock.XXXXXX")
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

# Execute the shipping offer/debounce/tap methods and lifecycle entry points.
# Only UIKit presentation, sensors, pose and the dispatch clock are doubled.
python3 - "$test_repo_root" "$test_build_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'src/ApolloGalleryImageViewer.m').read_text()
def between(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]
def method(signature):
    begin = source.index(signature)
    opening = source.index('{', begin)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]
(output / 'GalleryRotationProperties.inc').write_text(between(
    '@property (nonatomic, strong) UIButton *rotateOfferButton;',
    '@property (nonatomic, strong) UIPanGestureRecognizer *dismissPan;'))
(output / 'GalleryRotationMethods.inc').write_text(between(
    'static BOOL ApolloGallerySmartRotationLockEnabled(void)',
    '- (void)apollo_requestInterfaceOrientation:'))
# The rest of layout only deals with paging/playback; keep the real entry prefix
# through chrome layout, which includes both zero-size and resize paths.
layout = between('- (void)viewDidLayoutSubviews {\n    [super viewDidLayoutSubviews];',
                 '    [self apollo_layoutChrome];')
(output / 'GalleryRotationLifecycle.inc').write_text(
    method('- (void)viewDidAppear:(BOOL)animated') + '\n' +
    method('- (void)viewWillDisappear:(BOOL)animated') + '\n' +
    layout + '    [self apollo_layoutChrome];\n}\n')
PY

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation -framework CoreGraphics \
    -I "$test_build_dir" "$test_repo_root/tests/gallery_portrait_lock_tests.m" \
    -o "$test_build_dir/gallery_portrait_lock_tests"
"$test_build_dir/gallery_portrait_lock_tests"
